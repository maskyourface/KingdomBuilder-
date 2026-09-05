extends Node2D
class_name Villager

## 村民：白天去工作点上班，晚上回家休息，饿了就吃东西。
## 面包回满饥饿度，生食只回一半——面包链因此有经济价值。
## 移动走 A* 寻路，土路上速度 +60%。
## 时代需求：衣服（时代Ⅱ起，每日结算时自动从库存领取，穿 8~12 天磨损坏）。
## 卫兵：分配到兵营的村民变为 GUARD，白天驻守，强盗来袭时主动出击。
## 平民遇袭会逃回家（箭塔射手除外，他们在塔内作战）。
## workplace / home / raid 保持无类型，避免循环引用。

enum State { IDLE, MOVING, WORKING, RESTING, EATING, FLEEING, FIGHTING }
enum Purpose { NONE, TO_WORK, TO_HOME, WANDER, TO_FLEE, TO_FIGHT }
enum Role { COMMONER, GUARD }

## 死亡/离开时发出（main 连接后弹 toast 通知玩家）
signal died(villager, reason: String)

const SPEED := 60.0
const ROAD_MULTIPLIER := 1.6
const HUNGER_RATE := 100.0 / 240.0  # 约 4 分钟饿满
const HUNGRY_AT := 60.0
const BREAD_RESTORE := 100.0        # 面包：回满
const FOOD_RESTORE := 50.0          # 生食：回一半
const REPATH_INTERVAL := 1.0        # 寻路失败后的重试间隔（秒）
const FLEE_RADIUS := 8.0            # 强盗进入这个范围（格）平民就逃
const GUARD_AGGRO_RADIUS := 10.0    # 卫兵主动迎击范围（格）
const GUARD_MAX_HP := 120
const GUARD_DAMAGE := 12            # 每秒一次近战
const MELEE_RANGE := 1.5            # 近战距离（格）

var grid: GridManager
var resources: ResourceManager
var time_mgr: TimeManager
var raid = null                     # RaidManager，由 main 注入

var uid := 0
var state: State = State.IDLE
var hunger := 0.0
var happiness := 50.0          # 幸福度 0~100，每天由 main 结算
var last_ate_bread := false    # 今天是否吃了面包（幸福度加分项）
var has_clothes := false       # 是否穿着衣服（时代Ⅱ起的需求）
var clothes_days := 0          # 身上的衣服还能穿几天
var role: Role = Role.COMMONER
var hp := GUARD_MAX_HP         # 卫兵战斗用；平民不会被强盗主动攻击
var display_name := "村民"
var workplace = null                  # Building 或 null
var work_cell := Vector2i(-1, -1)     # 工作站位缓存（每次出发前会重新校验）
var home = null                       # Building（小屋）或 null
var home_cell := Vector2i(-1, -1)

var _path: Array[Vector2i] = []
var _path_index := 0
var _purpose: Purpose = Purpose.NONE
var _wait := 0.0
var _eat_time := 0.0
var _fight_time := 0.0
var _fight_target = null              # Enemy 或 null
var _hurt_fx := 0.0
var _draw_sig := -1                   # 重绘节流：外观签名（状态/饥饿档/受击/血条档/脉冲相位）

func setup(p_grid: GridManager, p_resources: ResourceManager,
		p_time: TimeManager, start_cell: Vector2i, p_raid = null) -> void:
	grid = p_grid
	resources = p_resources
	time_mgr = p_time
	raid = p_raid
	position = grid.cell_center(start_cell)

func _process(delta: float) -> void:
	if _hurt_fx > 0.0:
		_hurt_fx -= delta
	hunger += delta * HUNGER_RATE
	if hunger >= 100.0:
		_die()
		return

	match state:
		State.IDLE:
			_decide_next(delta)
		State.MOVING:
			_follow_path(delta)
			# 赶路途中也感知威胁（逃难路上不重复决策，免得每帧重寻路）
			if _purpose != Purpose.TO_FLEE and _should_flee():
				_flee()
		State.WORKING:
			if not is_instance_valid(workplace) or time_mgr.is_night():
				state = State.IDLE
			elif hunger >= HUNGRY_AT and resources.edible_amount() > 0:
				state = State.EATING
			elif _should_flee():
				state = State.IDLE  # 下一帧走逃跑决策
			elif role == Role.GUARD and _find_enemy() != null:
				state = State.IDLE  # 卫兵发现敌情，转入追击决策
		State.RESTING:
			if not time_mgr.is_night():
				state = State.IDLE
			elif hunger >= HUNGRY_AT and resources.edible_amount() > 0:
				state = State.EATING
			elif _should_flee() or (role == Role.GUARD and _find_enemy() != null):
				state = State.IDLE  # 夜袭：睡觉的人也要醒（平民逃跑/卫兵迎战）
		State.EATING:
			_eat_time += delta
			if _eat_time >= 2.0:
				_eat_time = 0.0
				if resources.try_consume(ResourceManager.Type.BREAD):
					hunger = maxf(0.0, hunger - BREAD_RESTORE)
					last_ate_bread = true
				elif resources.try_consume(ResourceManager.Type.FOOD):
					hunger = maxf(0.0, hunger - FOOD_RESTORE)
				state = State.IDLE
		State.FLEEING:
			# 躲避也要吃饭：有粮先吃，否则袭击期间会"满仓饿死"
			if hunger >= HUNGRY_AT and resources.edible_amount() > 0:
				state = State.EATING
				return
			# 原地躲避；威胁解除后恢复
			_wait -= delta
			if _wait <= 0.0:
				_wait = 0.5
				if not _should_flee():
					state = State.IDLE
		State.FIGHTING:
			# 战斗中饿到临界也先垫肚子，吃完重新决策（卫兵不会饿死在战场上）
			if hunger >= HUNGRY_AT and resources.edible_amount() > 0:
				state = State.EATING
			else:
				_fight_tick(delta)

	# 重绘节流：只有状态/饥饿档位/受击/血条档/脉冲相位变化才重绘
	# （250 人口时无条件每帧重绘 ≈ 3~5ms/帧的常驻成本）
	var sig := int(state) * 100000 + int(hunger / 5.0) * 100
	if _hurt_fx > 0.0:
		sig += 50
	if role == Role.GUARD:
		sig += int(hp / 10.0)
	if state == State.WORKING or state == State.FIGHTING:
		sig += (int(Time.get_ticks_msec() / 125.0)) % 2  # 工作/战斗金色脉冲 8Hz
	if sig != _draw_sig:
		_draw_sig = sig
		queue_redraw()

## 死亡/移除前解除所有反向引用，避免建筑里留下"僵尸工人"；
## reason 会通过 died 信号通知 main 弹提示（饿死/战死/离开）
func _die(reason: String = "饿死了") -> void:
	print("%s %s" % [display_name, reason])
	died.emit(self, reason)
	if is_instance_valid(workplace):
		workplace.workers.erase(self)
	if is_instance_valid(home):
		home.residents.erase(self)
	queue_free()

## 被敌人攻击（卫兵互殴用）；死亡走统一清理
func take_damage(amount: int, _from = null) -> void:
	hp -= amount
	_hurt_fx = 0.2
	if hp <= 0:
		_die("战死了")

# ---------- 威胁感知 ----------

## 附近有没有强盗。箭塔射手不逃跑（在塔内作战）；卫兵永不逃跑
func _should_flee() -> bool:
	if role == Role.GUARD:
		return false
	if is_instance_valid(workplace) and workplace.data.get("shoots_range", 0.0) > 0.0:
		return false
	return _find_enemy(FLEE_RADIUS) != null

## 半径（格）内最近的强盗，没有则 null
func _find_enemy(radius := GUARD_AGGRO_RADIUS):
	if raid == null or not raid.raid_active:
		return null
	var best = null
	var best_d := radius * GridManager.TILE
	for e in raid.enemies:
		if not is_instance_valid(e):
			continue
		var d := position.distance_to(e.position)
		if d < best_d:
			best = e
			best_d = d
	return best

# ---------- 决策 ----------

func _decide_next(delta: float) -> void:
	_wait -= delta
	if _wait > 0.0:
		return  # 节流：寻路失败后不会每帧重跑 A*
	if hunger >= HUNGRY_AT and resources.edible_amount() > 0:
		state = State.EATING
		return
	if _should_flee():
		_flee()
		return
	# 卫兵优先迎战（夜袭也要出击，放在昼夜判断之前）
	if role == Role.GUARD:
		var enemy = _find_enemy()
		if enemy != null:
			_fight_target = enemy
			var enemy_cell := grid.world_to_cell(enemy.position)
			if position.distance_to(enemy.position) <= MELEE_RANGE * GridManager.TILE:
				state = State.FIGHTING
				_fight_time = 0.0
			else:
				_start_move(enemy_cell, Purpose.TO_FIGHT)
			return
	if time_mgr.is_night():
		if is_instance_valid(home):
			_go_to_home()
		else:
			_wander()
		return
	if is_instance_valid(workplace):
		_go_to_work()
	else:
		_wander()

func _flee() -> void:
	if is_instance_valid(home):
		home_cell = grid.find_adjacent_walkable(home.origin, home.data.get("size", Vector2i.ONE))
		if home_cell.x >= 0 and grid.world_to_cell(position) != home_cell:
			_start_move(home_cell, Purpose.TO_FLEE)
			return
	# 没家或已经到家：原地躲避
	state = State.FLEEING
	_wait = 0.5

## 每次出发前重新计算工作位：被新建筑盖住的老格子不会永久卡死
func _go_to_work() -> void:
	work_cell = grid.find_adjacent_walkable(workplace.origin,
		workplace.data.get("size", Vector2i.ONE))
	if work_cell.x < 0:
		_wait = REPATH_INTERVAL  # 建筑被围死，稍后重试
		return
	_start_move(work_cell, Purpose.TO_WORK)

func _go_to_home() -> void:
	home_cell = grid.find_adjacent_walkable(home.origin,
		home.data.get("size", Vector2i.ONE))
	if home_cell.x < 0:
		_wait = REPATH_INTERVAL
		return
	_start_move(home_cell, Purpose.TO_HOME)

## 闲逛限制在身边 10 格内，避免后期大量跨图 O(V²) 寻路
func _wander() -> void:
	_start_move(grid.random_walkable_cell_near(grid.world_to_cell(position), 10), Purpose.WANDER)

func _start_move(cell: Vector2i, purpose: Purpose) -> void:
	var from := grid.world_to_cell(position)
	_path = grid.find_path(from, cell)
	if _path.is_empty():
		state = State.IDLE
		_wait = REPATH_INTERVAL  # 失败也节流，所有目的统一
		return
	_path_index = 0
	_purpose = purpose
	state = State.MOVING

func _follow_path(delta: float) -> void:
	var speed := SPEED
	if grid.has_road(grid.world_to_cell(position)):
		speed *= ROAD_MULTIPLIER
	var target := grid.cell_center(_path[_path_index])
	position = position.move_toward(target, speed * delta)
	if position.distance_to(target) < 2.0:
		_path_index += 1
		if _path_index >= _path.size():
			_on_arrived()

func _on_arrived() -> void:
	match _purpose:
		Purpose.TO_WORK:
			state = State.WORKING
		Purpose.TO_HOME, Purpose.TO_FLEE:
			state = State.RESTING if _purpose == Purpose.TO_HOME else State.FLEEING
			_wait = 0.5
		Purpose.TO_FIGHT:
			if is_instance_valid(_fight_target) \
					and position.distance_to(_fight_target.position) <= MELEE_RANGE * GridManager.TILE:
				state = State.FIGHTING
				_fight_time = 0.0
			else:
				state = State.IDLE  # 目标跑了，重新决策（追击有节流）
		_:
			state = State.IDLE
			_wait = randf_range(1.0, 3.0)

## 卫兵近战：每秒一刀，目标死了/跑了就重新决策
func _fight_tick(delta: float) -> void:
	if not is_instance_valid(_fight_target):
		_fight_target = null
		state = State.IDLE
		return
	if position.distance_to(_fight_target.position) > MELEE_RANGE * GridManager.TILE:
		state = State.IDLE  # 目标脱离近战距离，回到追击决策
		return
	_fight_time += delta
	if _fight_time >= 1.0:
		_fight_time = 0.0
		_fight_target.take_damage(GUARD_DAMAGE, self)

## 当前状态的中文描述，村民列表/详情界面用
func state_text() -> String:
	match state:
		State.WORKING:
			if is_instance_valid(workplace):
				if role == Role.GUARD:
					return "守卫中（%s）" % workplace.data.get("name", "")
				return "工作中（%s）" % workplace.data.get("name", "")
			return "守卫中" if role == Role.GUARD else "工作中"
		State.RESTING:
			return "在家休息"
		State.EATING:
			return "吃饭中"
		State.FLEEING:
			return "躲避强盗"
		State.FIGHTING:
			return "与强盗搏斗"
		State.MOVING:
			match _purpose:
				Purpose.TO_WORK: return "去上班的路上"
				Purpose.TO_HOME: return "回家路上"
				Purpose.TO_FLEE: return "逃难中"
				Purpose.TO_FIGHT: return "追击强盗"
				_: return "闲逛中"
	return "闲着"

func _draw() -> void:
	# 身体颜色随饥饿度变化：吃饱偏白，饿了偏红；被打时闪红
	var t := clampf(hunger / 100.0, 0.0, 1.0)
	var body := Color(1.0, 1.0 - t * 0.6, 1.0 - t * 0.6)
	if _hurt_fx > 0.0:
		body = Color(1.0, 0.2, 0.2)
	draw_circle(Vector2.ZERO, 6.0, body)
	# 头：卫兵戴钢盔
	var head := Color(0.7, 0.72, 0.78) if role == Role.GUARD else Color(0.95, 0.85, 0.7)
	draw_circle(Vector2(0, -8), 4.0, head)

	# 头顶状态指示灯：工作=绿，吃饭=橙，休息=蓝，赶路=浅灰，战斗=红，逃难=黄，闲着=灰
	var dot_color: Color
	match state:
		State.WORKING: dot_color = Color(0.2, 0.9, 0.2)
		State.EATING: dot_color = Color(1.0, 0.6, 0.1)
		State.RESTING: dot_color = Color(0.3, 0.5, 1.0)
		State.MOVING: dot_color = Color(0.8, 0.8, 0.8)
		State.FLEEING: dot_color = Color(1.0, 0.9, 0.2)
		State.FIGHTING: dot_color = Color(1.0, 0.15, 0.15)
		_: dot_color = Color(0.5, 0.5, 0.5)
	draw_circle(Vector2(10, -14), 3.0, dot_color)

	# 工作/战斗中画一个跳动的金色光点，一眼看出"这个人在干活/拼命"
	if state == State.WORKING or state == State.FIGHTING:
		var pulse := (sin(Time.get_ticks_msec() / 200.0) + 1.0) * 0.5
		var glow := Color(1.0, 0.3, 0.2, 0.4) if state == State.FIGHTING else Color(1.0, 0.9, 0.2, 0.35)
		draw_circle(Vector2(10, -14), 4.0 + pulse * 3.0, glow)

	# 卫兵血条（不满才显示）
	if role == Role.GUARD and hp < GUARD_MAX_HP:
		var ratio := clampf(float(hp) / float(GUARD_MAX_HP), 0.0, 1.0)
		draw_rect(Rect2(Vector2(-8, -18), Vector2(16, 3)), Color(0.2, 0.2, 0.2))
		draw_rect(Rect2(Vector2(-8, -18), Vector2(16 * ratio, 3)), Color(0.3, 0.9, 0.3))
