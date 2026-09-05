extends Node2D
class_name Building

## 一个已放置的建筑实例：存数据和位置，自己跑生产计时器。
## workers 是"需求人数"：产量按在岗人数比例缩放，
## 满员才满速，1/2 人在岗只有一半速度。
## 资源采集：depletes="forest" 的建筑（伐木场）每产一轮消耗工作范围内一格森林，
## 周边耗尽即停产；plants="forest" 的建筑（植树场）每轮在周边草地种出一格森林。

static var _next_uid := 1

var uid := 0
var data: Dictionary
var origin: Vector2i

var resources: ResourceManager
var time_mgr: TimeManager
var raid = null               # RaidManager，由 main 注入（箭塔索敌用，可为 null）
var grid: GridManager = null  # GridManager，由 main 注入（森林消耗/种植、工作区域显示用）

var workers: Array = []     # 被分配来上班的 Villager
var residents: Array = []   # 住在这里的 Villager（小屋用）

var timer := 0.0            # 生产进度计时（存档用）
var hp := -1                # -1 = 不可破坏；城墙/城门有耐久，存档用
var last_sale := {}         # 市场：昨日成交 {"gold":int, "items":{type:int}}（详情面板显示）
var worked_today := false   # 今天是否有人到过岗（白天累计，午夜日结消费后复位；
							# 日结发生在深夜、现场点在岗数恒为 0，必须用这个标记）
var depleted := false       # 资源采集建筑（伐木场）周边资源耗尽，停工中
var no_prod_today := false  # 暴雨等事件导致的当日停产（main 每日置位，次日日结时复位）
var show_work_area := false # 被选中查看详情时画工作区域圈（main 置位/复位）

var _depleted_check_cd := 0.0  # 耗尽后的复查节流
var _res_check_cd := 0.0       # 资源余量复查节流（未停产 0.5s / 停产 2s）
var _cycles_since_cut := 0     # 伐木计数：每 depletes_every 轮才砍一格树

var _shot_cd := 0.0         # 箭塔射击冷却
var _shot_fx := 0.0         # 射击线特效剩余时间
var _shot_target := Vector2.ZERO  # 特效目标（本地坐标）

static func alloc_uid() -> int:
	var id := _next_uid
	_next_uid += 1
	return id

## 读档时把 uid 计数器推进到已有最大 uid 之后，避免冲突
static func bump_uid_past(used_uid: int) -> void:
	_next_uid = maxi(_next_uid, used_uid + 1)

func setup(p_data: Dictionary, p_origin: Vector2i,
		p_resources: ResourceManager, p_time: TimeManager, p_raid = null,
		p_grid: GridManager = null) -> void:
	data = p_data
	origin = p_origin
	resources = p_resources
	time_mgr = p_time
	raid = p_raid
	grid = p_grid
	hp = int(data.get("hp", -1))
	uid = alloc_uid()
	position = Vector2(origin.x * GridManager.TILE, origin.y * GridManager.TILE)

## 占地中心的世界坐标（光环距离、袭击瞄准用）
func world_pos() -> Vector2:
	var size: Vector2i = data.get("size", Vector2i.ONE)
	return position + Vector2(size.x, size.y) * GridManager.TILE / 2.0

func _process(delta: float) -> void:
	# 白天有人到岗就记一天出勤（幸福度光环/市场日结都在深夜跑，现场点人数恒为 0）
	if _count_present_workers() > 0:
		worked_today = true
	_update_shooting(delta)
	if not data.get("produces", false):
		return
	# 冬天农田/采集停产
	if data.get("no_winter", false) and time_mgr.is_winter():
		return
	# 资源地块采集：伐木场周边森林砍光就停产（详情面板提示"周边森林已耗尽"）；
	# 停产后每 2 秒复查一次，植树场补种后自动复产；未停产时 0.5 秒节流复查
	if data.get("depletes", "") == "forest":
		_res_check_cd -= delta
		if _res_check_cd <= 0.0:
			_res_check_cd = 2.0 if depleted else 0.5
			depleted = _terrain_near(GridManager.TileType.FOREST).x < 0
		if depleted:
			return
	if no_prod_today:
		return  # 暴雨等事件停产（出勤照记，村民仍算到过岗）
	# 原料不够就停工等待
	var inputs: Array = data.get("inputs", [])
	if not resources.has_all(inputs):
		return

	# 幸福度 ≥70：全民干劲足，生产 +20%
	var rate := 1.2 if resources.happiness >= 70.0 else 1.0

	var max_workers: int = data.get("workers", 0)
	if max_workers > 0:
		var present := _count_present_workers()
		if present == 0:
			return
		# 按在岗比例推进：1/2 人 = 半速
		timer += delta * rate * float(present) / float(max_workers)
	else:
		timer += delta * rate

	if timer >= data.get("interval", 5.0):
		timer = 0.0
		resources.try_spend(inputs)
		for out in data.get("outputs", []):
			resources.add(out[0], out[1])
		_consume_or_plant()

func _count_present_workers() -> int:
	var n := 0
	for w in workers:
		if is_instance_valid(w) and w.state == Villager.State.WORKING and w.workplace == self:
			n += 1
	return n

## 工作半径内随机找一个指定地形格；找不到返回 (-1,-1)
func _terrain_near(type: int) -> Vector2i:
	if grid == null:
		return Vector2i(-1, -1)
	var wr := int(float(data.get("work_radius", 2.0)))
	return grid.find_random_terrain_near(origin, data.get("size", Vector2i.ONE), type, wr)

## 工作半径内指定地形的格数（详情面板"剩余可砍/可种"用；跳过建筑占格）
func count_terrain_near(type: int, avoid_road := false) -> int:
	if grid == null:
		return 0
	var wr := int(float(data.get("work_radius", 2.0)))
	var size: Vector2i = data.get("size", Vector2i.ONE)
	var n := 0
	for x in range(origin.x - wr, origin.x + size.x + wr):
		for y in range(origin.y - wr, origin.y + size.y + wr):
			var tc := Vector2i(x, y)
			if not grid.in_bounds(x, y) or grid.tile_type_at(tc) != type:
				continue
			if grid.building_at(tc) != null:
				continue
			if avoid_road and grid.has_road(tc):
				continue
			n += 1
	return n

## 生产完成后的资源地块结算：伐木场每 depletes_every 轮砍一格森林，植树场每轮种一格
func _consume_or_plant() -> void:
	if grid == null:
		return
	if data.get("depletes", "") == "forest":
		_cycles_since_cut += 1
		if _cycles_since_cut < int(data.get("depletes_every", 10)):
			return
		_cycles_since_cut = 0
		var t := _terrain_near(GridManager.TileType.FOREST)
		if t.x >= 0:
			grid.set_terrain(t, GridManager.TileType.GRASS)
	if data.get("plants", "") == "forest":
		# 种树避开道路与建筑占格
		var g := _terrain_near_road_free(GridManager.TileType.GRASS)
		if g.x >= 0:
			grid.set_terrain(g, GridManager.TileType.FOREST)

func _terrain_near_road_free(type: int) -> Vector2i:
	if grid == null:
		return Vector2i(-1, -1)
	var wr := int(float(data.get("work_radius", 2.0)))
	return grid.find_random_terrain_near(origin, data.get("size", Vector2i.ONE), type, wr, true)

## 受攻击（仅城墙/城门等有耐久的建筑）；返回 true 表示被摧毁
func take_damage(amount: int) -> bool:
	if hp < 0:
		return false
	hp -= amount
	queue_redraw()
	return hp <= 0

## 箭塔：有人在岗时自动射击射程内的强盗（补刀优先）
func _update_shooting(delta: float) -> void:
	var range_cells := float(data.get("shoots_range", 0.0))
	if range_cells <= 0.0:
		return
	if _shot_fx > 0.0:
		_shot_fx -= delta
		queue_redraw()
	if raid == null or not raid.raid_active:
		return
	if _count_present_workers() == 0:
		return
	_shot_cd -= delta
	if _shot_cd > 0.0:
		return
	var bsize: Vector2i = data.get("size", Vector2i.ONE)
	var center := Vector2(bsize) * GridManager.TILE * 0.5  # 本地坐标中心
	var world_center := position + center
	var best = null
	var best_hp := 1 << 30
	var best_d := 0.0
	var max_d := range_cells * GridManager.TILE
	for e in raid.enemies:
		if not is_instance_valid(e):
			continue
		var d := world_center.distance_to(e.position)
		if d > max_d:
			continue
		# 补刀优先：射程内选血量最低者（并列取更近），减少多塔齐射过杀
		if best == null or e.hp < best_hp or (e.hp == best_hp and d < best_d):
			best = e
			best_hp = e.hp
			best_d = d
	if best == null:
		return
	_shot_cd = float(data.get("shoots_interval", 1.5))
	_shot_fx = 0.15
	_shot_target = best.position - position
	best.take_damage(int(data.get("shoots_damage", 10)), self)
	queue_redraw()

## 生产进度 0~1，详情面板的进度条用；不生产或停工时返回当前值
func progress() -> float:
	if not data.get("produces", false):
		return 0.0
	return clampf(timer / data.get("interval", 5.0), 0.0, 1.0)

func _draw() -> void:
	var size: Vector2i = data.get("size", Vector2i.ONE)
	var rect := Rect2(Vector2(2, 2),
		Vector2(size.x * GridManager.TILE - 4, size.y * GridManager.TILE - 4))
	# 工作区域可视化：选中资源建筑时按 7×7 窗口画方形工作区（与实际砍伐/种植窗口一致），
	# 伐木场还高亮范围内每格森林
	if show_work_area and grid != null:
		var wr := float(data.get("work_radius", 0.0))
		if wr > 0.0:
			var fill := Color(1.0, 0.95, 0.5, 0.10)
			var ring := Color(1.0, 0.95, 0.5, 0.55)
			if data.get("depletes", "") == "forest":
				fill = Color(0.2, 0.9, 0.3, 0.10)
				ring = Color(0.2, 0.9, 0.3, 0.5)
			var wrect := Rect2((origin.x - wr) * GridManager.TILE - position.x,
				(origin.y - wr) * GridManager.TILE - position.y,
				(size.x + wr * 2) * GridManager.TILE, (size.y + wr * 2) * GridManager.TILE)
			draw_rect(wrect, fill)
			draw_rect(wrect, ring, false, 2.0)
			if data.get("depletes", "") == "forest":
				var wr_i := int(wr)
				for x in range(origin.x - wr_i, origin.x + size.x + wr_i):
					for y in range(origin.y - wr_i, origin.y + size.y + wr_i):
						var tc := Vector2i(x, y)
						if grid.in_bounds(x, y) \
								and grid.tile_type_at(tc) == GridManager.TileType.FOREST:
							draw_rect(Rect2(x * GridManager.TILE + 2 - position.x,
								y * GridManager.TILE + 2 - position.y,
								GridManager.TILE - 4, GridManager.TILE - 4),
								Color(0.35, 1.0, 0.4, 0.30))
	var style := StyleBoxFlat.new()
	style.bg_color = data.get("color", Color.GRAY)
	style.border_color = Color(0, 0, 0, 0.45)
	style.set_border_width_all(1)
	style.set_corner_radius_all(5)
	draw_style_box(style, rect)
	# 建筑名称（带阴影），小建筑用小字号
	var bname: String = data.get("name", "")
	var font_size := 12 if size.x <= 1 else 14
	var font := UiFont.get_font()
	var text_pos := Vector2(rect.position.x, rect.get_center().y + font_size * 0.35)
	draw_string(font, text_pos + Vector2(1, 1), bname,
		HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, font_size, Color(0, 0, 0, 0.7))
	draw_string(font, text_pos, bname,
		HORIZONTAL_ALIGNMENT_CENTER, rect.size.x, font_size, Color(1, 1, 1, 0.95))
	# 城墙/城门血条（受损才显示）
	var max_hp := int(data.get("hp", -1))
	if hp >= 0 and hp < max_hp:
		var ratio := clampf(float(hp) / float(maxi(max_hp, 1)), 0.0, 1.0)
		draw_rect(Rect2(rect.position + Vector2(0, -5), Vector2(rect.size.x, 3)), Color(0.2, 0.2, 0.2))
		draw_rect(Rect2(rect.position + Vector2(0, -5), Vector2(rect.size.x * ratio, 3)), Color(0.3, 0.9, 0.3))
	# 箭塔射击特效：一条从塔心到目标的短暂亮线
	if _shot_fx > 0.0:
		draw_line(rect.get_center(), _shot_target, Color(1.0, 0.9, 0.3, 0.8), 2.0)
