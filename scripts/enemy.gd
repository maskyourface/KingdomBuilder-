extends Node2D
class_name Enemy

## 敌对单位。两种：
## - 强盗（bandit，时代Ⅳ 起）：奔向最近的住房/市场抢劫，被墙挡住就拆墙，
##   被卫兵/箭塔攻击就反击，得手后撤回地图边缘消失。
## - 野狼（wolf，时代Ⅱ~Ⅲ）：血薄、不拆墙、只叼食物与羊毛，专挑食物产线与粮仓；
##   怕火——被篝火照到的建筑不会被盯上，误闯进火光范围的狼直接夹尾巴跑。
##   目的是让时代Ⅰ~Ⅲ 不再是"零风险挂机"，同时给「篝火」这个布局决策一个存在理由。
## 两者共用同一套调度/撤退/士气/箭塔索敌机制，只在目标选择与战利品上分叉。
## 不吃道路加速、不主动追平民。寻路用 for_enemy 规则（城门不可走）。

enum State { SEEK, ATTACK, PILLAGE, FIGHT, LEAVE }

const SPEED := 60.0          # 无道路加成
const MAX_HP := 60
const WOLF_MAX_HP := 30      # 野狼血薄：一座箭塔三发即可，卫兵两下就赶走
const WOLF_SPEED := 78.0     # 狼跑得比强盗快，逃跑的村民真的跑不过
const WOLF_PILLAGE_TIME := 3.0
## 野狼盯的是"吃的"：食物产线与存粮的地方（不碰住房、不进市场）。
## 肉类产线（猎人小屋/腌肉坊）在这里，让新的肉食经济和狼群威胁挂上钩
const WOLF_TARGET_IDS: Array[String] = [
	"pasture", "gatherer", "fisher", "farm", "granary", "hunter", "curing_house",
]
const DAMAGE := 8            # 对卫兵每秒一次
const SIEGE_DAMAGE := 15     # 拆墙每秒一次
const MELEE_RANGE := 1.5     # 格
const PILLAGE_TIME := 5.0    # 抢劫引导秒数
const REPATH_INTERVAL := 1.0

var grid: GridManager
var resources: ResourceManager
var raid = null              # RaidManager

var kind: StringName = &"bandit"  # bandit（强盗）/ wolf（野狼）
var hp := MAX_HP
var state: State = State.SEEK
var target_building = null   # 抢劫目标（住房/市场）或要拆的墙
var _did_pillage := false

var _path: Array[Vector2i] = []
var _path_index := 0
var _wait := 0.0
var _channel := 0.0          # 抢劫/拆墙进度
var _fight_target = null     # 正在互殴的卫兵（Villager，无类型）
var _hurt_fx := 0.0
var _draw_sig := -1          # 重绘节流：外观签名

func setup(p_grid: GridManager, p_resources: ResourceManager,
		p_raid, start_cell: Vector2i, p_kind: StringName = &"bandit") -> void:
	grid = p_grid
	resources = p_resources
	raid = p_raid
	kind = p_kind
	hp = max_hp()
	position = grid.cell_center(start_cell)

func is_wolf() -> bool:
	return kind == &"wolf"

func max_hp() -> int:
	return WOLF_MAX_HP if is_wolf() else MAX_HP

func move_speed() -> float:
	return WOLF_SPEED if is_wolf() else SPEED

## 这个位置是否被点着的篝火照到（野狼专用；篝火半径吃建筑等级加成）
func _in_firelight(pos: Vector2) -> bool:
	if raid == null or raid.buildings_root == null:
		return false
	for b in raid.buildings_root.get_children():
		var r: float = b.eff_scare_radius()
		if r <= 0.0:
			continue
		if pos.distance_to(b.world_pos()) <= r * GridManager.TILE:
			return true
	return false

func _process(delta: float) -> void:
	if _hurt_fx > 0.0:
		_hurt_fx -= delta
	# 野狼怕火：误闯进篝火照到的范围就掉头跑（撤离中的不再重复判定）
	if is_wolf() and state != State.LEAVE and _in_firelight(position):
		_start_leave()
	match state:
		State.SEEK:
			_seek(delta)
		State.ATTACK:
			_attack_building(delta)
		State.PILLAGE:
			_pillage_tick(delta)
		State.FIGHT:
			_fight_tick(delta)
		State.LEAVE:
			_leave_tick(delta)
	# 重绘节流：状态/血量档/受击变化才重绘；引导条/战斗动画 8Hz
	var sig := int(state) * 10000 + int(hp / 10.0) * 100
	if _hurt_fx > 0.0:
		sig += 50
	if state == State.PILLAGE or state == State.ATTACK or state == State.FIGHT:
		sig += (int(Time.get_ticks_msec() / 125.0)) % 2
	if sig != _draw_sig:
		_draw_sig = sig
		queue_redraw()

func take_damage(amount: int, from = null) -> void:
	hp -= amount
	_hurt_fx = 0.2
	if hp <= 0:
		if raid != null:
			raid.on_enemy_died(self)
		queue_free()
		return
	# 反击：被打了就打回去（得手撤退中的也一样会自卫）
	if from != null and is_instance_valid(from) and from is Villager:
		_fight_target = from
		state = State.FIGHT

# ---------- 抢劫 ----------

func _seek(delta: float) -> void:
	if _path.is_empty():
		_wait -= delta
		if _wait > 0.0:
			return
		_plan_route()
		return
	_follow_path(delta)

## 选目标并寻路；被围死就找最近的城墙/城门来拆
func _plan_route() -> void:
	_wait = REPATH_INTERVAL
	if not is_instance_valid(target_building) or not _valid_target(target_building):
		target_building = _pick_target()
	if target_building == null:
		_start_leave()
		return
	var size: Vector2i = target_building.data.get("size", Vector2i.ONE)
	var dest := grid.find_adjacent_walkable(target_building.origin, size, true)
	if dest.x < 0:
		_try_siege()
		return
	_path = grid.find_path(grid.world_to_cell(position), dest, true)
	if _path.is_empty():
		_try_siege()

## 这座建筑是不是本单位的合法目标（强盗抢住房/市场，野狼叼食物产线与粮仓）
func _valid_target(b) -> bool:
	if b == null or not is_instance_valid(b):
		return false
	if is_wolf():
		if not (String(b.data.get("id", "")) in WOLF_TARGET_IDS):
			return false
		return not _in_firelight(b.world_pos())  # 被火照到的不敢碰
	return b.data.get("housing", 0) > 0 or b.data.get("auto_sells", false)

## 找最近的可抢建筑
func _pick_target():
	var best = null
	var best_d := 1e30
	for b in raid.buildings_root.get_children():
		if not _valid_target(b):
			continue
		var d := position.distance_squared_to(b.position)
		if d < best_d:
			best = b
			best_d = d
	return best

## 拆墙：找最近的城墙/城门，走到旁边开打；连墙都摸不到就撤
func _try_siege() -> void:
	if is_wolf():
		_start_leave()  # 狼不会拆墙：进不去就走
		return
	var wall = raid.find_nearest_wall(position)
	if wall == null:
		_start_leave()
		return
	target_building = wall
	var dest := grid.find_adjacent_walkable(wall.origin, wall.data.get("size", Vector2i.ONE), true)
	if dest.x < 0:
		_start_leave()
		return
	_path = grid.find_path(grid.world_to_cell(position), dest, true)
	if _path.is_empty():
		_start_leave()
		return
	# 保持 SEEK 状态沿路走过去，_on_arrived 到位后自然转 ATTACK（避免隔空拆墙）
	state = State.SEEK

func _follow_path(delta: float) -> void:
	var target := grid.cell_center(_path[_path_index])
	position = position.move_toward(target, move_speed() * delta)
	if position.distance_to(target) < 2.0:
		_path_index += 1
		if _path_index < _path.size():
			return
		_path = []
		_on_arrived()

func _on_arrived() -> void:
	match state:
		State.LEAVE:
			raid.on_enemy_left(self)
			queue_free()
		State.FIGHT:
			pass  # 追到目标所在格，下一帧 _fight_tick 判断距离
		_:
			# SEEK / 拆墙途中到达目标
			if not is_instance_valid(target_building):
				state = State.SEEK
				return
			if state == State.ATTACK or target_building.data.get("is_wall", false) \
					or target_building.data.get("is_gate", false):
				state = State.ATTACK
			else:
				state = State.PILLAGE
			_channel = 0.0

## 拆墙：每秒一下，墙塌了重新规划
func _attack_building(delta: float) -> void:
	if not is_instance_valid(target_building):
		state = State.SEEK
		return
	# 只许贴身拆墙，防止任何路径下出现隔空拆迁
	if position.distance_to(target_building.world_pos()) > MELEE_RANGE * GridManager.TILE:
		state = State.SEEK
		return
	_channel += delta
	if _channel < 1.0:
		return
	_channel = 0.0
	if target_building.take_damage(SIEGE_DAMAGE):
		raid.destroy_building(target_building)
		target_building = null
		state = State.SEEK  # 墙塌了，重新寻路（抢劫或撤离）

## 抢劫引导：5 秒偷走库存的一成，然后跑路
func _pillage_tick(delta: float) -> void:
	if not is_instance_valid(target_building):
		state = State.SEEK
		return
	_channel += delta
	if _channel < (WOLF_PILLAGE_TIME if is_wolf() else PILLAGE_TIME):
		return
	if is_wolf():
		_wolf_loot()
		return
	var got := 0
	var want_food := maxi(1, resources.get_amount(ResourceManager.Type.FOOD) / 10)
	if resources.try_consume(ResourceManager.Type.FOOD, want_food):
		got += want_food
	var want_bread := maxi(1, resources.get_amount(ResourceManager.Type.BREAD) / 10)
	if resources.try_consume(ResourceManager.Type.BREAD, want_bread):
		got += want_bread
	if raid.has_market():
		var want_gold := maxi(1, resources.get_amount(ResourceManager.Type.GOLD) / 10)
		if resources.try_consume(ResourceManager.Type.GOLD, want_gold):
			got += want_gold
	if got > 0:
		_did_pillage = true
		raid.register_pillage()
	_start_leave()

## 野狼的战利品：叼走一点生食，牧羊场还会咬死羊（掉羊毛）。
## 量比强盗小得多——它是"持续骚扰 + 逼你布置篝火"，不是一次抄家。
func _wolf_loot() -> void:
	var got := 0
	var want_food: int = maxi(2, resources.get_amount(ResourceManager.Type.FOOD) / 20)
	if resources.try_consume(ResourceManager.Type.FOOD, want_food):
		got += want_food
	if is_instance_valid(target_building) \
			and String(target_building.data.get("id", "")) == "pasture":
		var want_wool: int = maxi(1, resources.get_amount(ResourceManager.Type.WOOL) / 10)
		if resources.try_consume(ResourceManager.Type.WOOL, want_wool):
			got += want_wool
	if got > 0:
		_did_pillage = true
		raid.register_pillage()
	_start_leave()

# ---------- 战斗 ----------

func _fight_tick(delta: float) -> void:
	if not is_instance_valid(_fight_target):
		_fight_target = null
		# 打完了：抢过了就撤，没抢继续抢
		if _did_pillage:
			_start_leave()
		else:
			state = State.SEEK
			_plan_route()
		return
	var dist := position.distance_to(_fight_target.position)
	if dist > MELEE_RANGE * GridManager.TILE:
		# 追一小步（节流复用 _wait）
		_wait -= delta
		if _wait <= 0.0:
			_wait = REPATH_INTERVAL
			_path = grid.find_path(grid.world_to_cell(position),
				grid.world_to_cell(_fight_target.position), true)
			_path_index = 0
		if not _path.is_empty():
			_follow_path(delta)
		return
	_channel += delta
	if _channel >= 1.0:
		_channel = 0.0
		_fight_target.take_damage(DAMAGE, self)

# ---------- 撤离 ----------

func _start_leave() -> void:
	state = State.LEAVE
	_path = []

func _leave_tick(delta: float) -> void:
	if _path.is_empty():
		_wait -= delta
		if _wait > 0.0:
			return
		_wait = REPATH_INTERVAL
		var edge := grid.random_edge_cell(true)
		_path = grid.find_path(grid.world_to_cell(position), edge, true)
		_path_index = 0
		if _path.is_empty():
			_try_siege()  # 被围死了，拆墙突围
			if state == State.LEAVE:
				# 实在没路可拆：原地消失（防止卡死单位）
				raid.on_enemy_left(self)
				queue_free()
		return
	_follow_path(delta)

func _draw() -> void:
	var body := Color(0.55, 0.15, 0.12)
	if is_wolf():
		body = Color(0.42, 0.42, 0.46)  # 灰狼：和红头巾强盗一眼可分
	if _hurt_fx > 0.0:
		body = Color(1.0, 0.3, 0.2)
	draw_circle(Vector2.ZERO, 6.0, body)
	if is_wolf():
		# 两只尖耳朵
		draw_colored_polygon(PackedVector2Array([Vector2(-5, -5), Vector2(-2, -11),
			Vector2(-1, -4)]), body)
		draw_colored_polygon(PackedVector2Array([Vector2(5, -5), Vector2(2, -11),
			Vector2(1, -4)]), body)
	else:
		draw_circle(Vector2(0, -8), 4.0, Color(0.3, 0.2, 0.15))  # 头巾
	# 抢劫引导条
	if state == State.PILLAGE:
		var ratio := clampf(_channel / (WOLF_PILLAGE_TIME if is_wolf() else PILLAGE_TIME), 0.0, 1.0)
		draw_rect(Rect2(Vector2(-8, -22), Vector2(16, 3)), Color(0.2, 0.2, 0.2))
		draw_rect(Rect2(Vector2(-8, -22), Vector2(16 * ratio, 3)), Color(1.0, 0.8, 0.2))
	# 血条
	var hp_ratio := clampf(float(hp) / float(max_hp()), 0.0, 1.0)
	draw_rect(Rect2(Vector2(-8, -18), Vector2(16, 3)), Color(0.2, 0.2, 0.2))
	draw_rect(Rect2(Vector2(-8, -18), Vector2(16 * hp_ratio, 3)), Color(0.9, 0.2, 0.2))
