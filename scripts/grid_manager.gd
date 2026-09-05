extends Node2D
class_name GridManager

## 网格地图：逻辑数据（地形、建筑占用、道路）存在数组里，
## _draw() 只负责把数据画出来。放置判定、寻路全查数据层。
## 地形种类：草地（可建可走）、森林（可走，资源地块不可建设）、水域（不可建不可走）、
## 山地（不可建不可走，采石场要挨着它）、耕地（麦田转化而来）、
## 浆果丛（可走，资源地块不可建设，采集小屋要挨着它）。

const TILE := 32
const ROAD_COLOR := Color(0.72, 0.62, 0.45)
const INF := 1 << 30

enum TileType { GRASS, FOREST, WATER, MOUNTAIN, FARMLAND, BERRY }

const TILE_COLORS: Dictionary = {
	TileType.GRASS: Color(0.45, 0.75, 0.35),
	TileType.FOREST: Color(0.15, 0.45, 0.15),
	TileType.WATER: Color(0.25, 0.45, 0.8),
	TileType.MOUNTAIN: Color(0.55, 0.55, 0.6),
	TileType.FARMLAND: Color(0.6, 0.45, 0.25),
	TileType.BERRY: Color(0.55, 0.3, 0.45),
}

@export var width := 48
@export var height := 48
@export_range(0.0, 0.5) var forest_ratio := 0.15
@export_range(0.0, 0.3) var water_ratio := 0.06

var terrain: Array[int] = []
var occupancy: Array = []      # Building 或 null
var roads: Array[bool] = []
var _jitter: Array[float] = []  # 每格一个确定性随机值，渲染抖动用

func _ready() -> void:
	generate_map()

func _idx(x: int, y: int) -> int:
	return x * height + y

func generate_map() -> void:
	terrain.clear()
	occupancy.clear()
	roads.clear()
	_jitter.clear()
	for i in width * height:
		terrain.append(TileType.GRASS)
		occupancy.append(null)
		roads.append(false)
		_jitter.append(randf())

	# 水域：几个圆斑
	var water_blobs := int(width * height * water_ratio / 12.0)
	for i in water_blobs:
		_paint_blob(TileType.WATER, randi_range(2, 3))
	# 山地：1~3 块，采石场的目标
	for i in randi_range(1, 3):
		_paint_blob(TileType.MOUNTAIN, randi_range(2, 3))
	# 森林：更多的小斑块
	var forest_blobs := int(width * height * forest_ratio / 8.0)
	for i in forest_blobs:
		_paint_blob(TileType.FOREST, randi_range(2, 4))
	# 浆果丛：小点，采集小屋的目标
	for i in randi_range(2, 4):
		_paint_blob(TileType.BERRY, randi_range(1, 2))
	queue_redraw()

func _paint_blob(type: TileType, radius: int) -> void:
	var cx := randi_range(0, width - 1)
	var cy := randi_range(0, height - 1)
	for x in range(cx - radius, cx + radius + 1):
		for y in range(cy - radius, cy + radius + 1):
			if in_bounds(x, y) and Vector2(x - cx, y - cy).length() <= radius:
				# 浆果丛只长在草地上，不覆盖其他地形
				if type == TileType.BERRY and terrain[_idx(x, y)] != TileType.GRASS:
					continue
				terrain[_idx(x, y)] = type

# ---------- 坐标 ----------

func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < width and y < height

func world_to_cell(world: Vector2) -> Vector2i:
	return Vector2i(floori(world.x / TILE), floori(world.y / TILE))

func cell_center(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * TILE + TILE / 2.0, cell.y * TILE + TILE / 2.0)

# ---------- 查询 ----------

func tile_type_at(cell: Vector2i) -> int:
	if not in_bounds(cell.x, cell.y):
		return TileType.WATER
	return terrain[_idx(cell.x, cell.y)]

func building_at(cell: Vector2i) -> Variant:  # Building 或 null
	if not in_bounds(cell.x, cell.y):
		return null
	return occupancy[_idx(cell.x, cell.y)]

## 可行走：不是水、不是山、没被建筑占（道路不影响行走）
## 例外：城门村民可以走、敌人不能走；for_enemy=true 供强盗寻路
func is_walkable(cell: Vector2i, for_enemy := false) -> bool:
	if not in_bounds(cell.x, cell.y):
		return false
	var t: int = terrain[_idx(cell.x, cell.y)]
	if t == TileType.WATER or t == TileType.MOUNTAIN:
		return false
	var b = occupancy[_idx(cell.x, cell.y)]
	if b == null:
		return true
	return b.data.get("is_gate", false) and not for_enemy

## 附近 radius 格内是否有指定地形（建筑选址判定）
func has_adjacent_terrain(cell: Vector2i, type: TileType, radius := 2) -> bool:
	for x in range(cell.x - radius, cell.x + radius + 1):
		for y in range(cell.y - radius, cell.y + radius + 1):
			if in_bounds(x, y) and terrain[_idx(x, y)] == type:
				return true
	return false

# ---------- 建筑放置 ----------

## 通用选址判定：建设用地只能是平原（草地）+ 满足建筑的邻近地形要求。
## 森林/浆果丛是资源地块，与水域/石林一样不可建设（农场规则由此统一满足）
func can_place(origin: Vector2i, size: Vector2i, data: Dictionary) -> bool:
	for x in size.x:
		for y in size.y:
			var c := origin + Vector2i(x, y)
			if not in_bounds(c.x, c.y):
				return false
			var i := _idx(c.x, c.y)
			var t: int = terrain[i]
			if t != TileType.GRASS:
				return false
			if occupancy[i] != null or roads[i]:
				return false
	if data.get("needs_forest", false) \
			and not has_adjacent_terrain(origin, TileType.FOREST):
		return false
	if data.get("needs_mountain", false) \
			and not has_adjacent_terrain(origin, TileType.MOUNTAIN):
		return false
	if data.get("needs_berry", false) \
			and not has_adjacent_terrain(origin, TileType.BERRY):
		return false
	if data.get("needs_water", false) \
			and not has_adjacent_terrain(origin, TileType.WATER):
		return false
	return true

func occupy_area(origin: Vector2i, size: Vector2i, building) -> void:
	for x in size.x:
		for y in size.y:
			occupancy[_idx(origin.x + x, origin.y + y)] = building

func free_area(origin: Vector2i, size: Vector2i) -> void:
	for x in size.x:
		for y in size.y:
			occupancy[_idx(origin.x + x, origin.y + y)] = null

func reset_occupancy() -> void:
	for i in occupancy.size():
		occupancy[i] = null

## 在建筑周边随机找一个指定地形格（伐木砍树/植树场种树用）；找不到返回 (-1,-1)。
## 先随机采样 40 次，全部落空再做一次线性穷举兜底——资源将尽时不会概率性漏检。
## 永远跳过被建筑占用的格子；avoid_road=true 时再跳过道路格（种树不长在路上）
func find_random_terrain_near(origin: Vector2i, size: Vector2i, type: TileType,
		radius: int, avoid_road := false) -> Vector2i:
	for attempt in 40:
		var c := Vector2i(
			clampi(origin.x + randi_range(-radius, radius + size.x - 1), 0, width - 1),
			clampi(origin.y + randi_range(-radius, radius + size.y - 1), 0, height - 1))
		var ti := _idx(c.x, c.y)
		if terrain[ti] != type or occupancy[ti] != null:
			continue
		if avoid_road and roads[ti]:
			continue
		return c
	# 线性兜底：环形区域穷举（资源只剩最后几格时随机采样会 ~44% 漏检）
	for x in range(origin.x - radius, origin.x + size.x + radius):
		for y in range(origin.y - radius, origin.y + size.y + radius):
			if not in_bounds(x, y):
				continue
			var ti := _idx(x, y)
			if terrain[ti] == type and occupancy[ti] == null \
					and not (avoid_road and roads[ti]):
				return Vector2i(x, y)
	return Vector2i(-1, -1)

## 直接改写一格地形（森林消耗/种植用）；占用与道路不受影响
func set_terrain(cell: Vector2i, type: TileType) -> void:
	if not in_bounds(cell.x, cell.y):
		return
	terrain[_idx(cell.x, cell.y)] = type
	queue_redraw()

## 麦田放置后把地块变成耕地
func convert_to_farmland(origin: Vector2i, size: Vector2i) -> void:
	for x in size.x:
		for y in size.y:
			terrain[_idx(origin.x + x, origin.y + y)] = TileType.FARMLAND
	queue_redraw()

## 拆掉麦田后恢复为草地（耕地不再不可逆）
func revert_to_grass(origin: Vector2i, size: Vector2i) -> void:
	for x in size.x:
		for y in size.y:
			var i := _idx(origin.x + x, origin.y + y)
			if terrain[i] == TileType.FARMLAND:
				terrain[i] = TileType.GRASS
	queue_redraw()

## 找建筑占地旁边一个可行走格（村民的工作位/家门口）
func find_adjacent_walkable(origin: Vector2i, size: Vector2i, for_enemy := false) -> Vector2i:
	for x in range(origin.x - 1, origin.x + size.x + 1):
		for y in range(origin.y - 1, origin.y + size.y + 1):
			var inside := x >= origin.x and x < origin.x + size.x \
				and y >= origin.y and y < origin.y + size.y
			if not inside and is_walkable(Vector2i(x, y), for_enemy):
				return Vector2i(x, y)
	return Vector2i(-1, -1)

# ---------- 道路 ----------

func has_road(cell: Vector2i) -> bool:
	return in_bounds(cell.x, cell.y) and roads[_idx(cell.x, cell.y)]

func can_place_road(cell: Vector2i) -> bool:
	if not in_bounds(cell.x, cell.y):
		return false
	var i := _idx(cell.x, cell.y)
	# 土路可穿过森林成为林间小径（水域/石林仍不可铺路，桥梁留待后续）
	return (terrain[i] == TileType.GRASS or terrain[i] == TileType.FARMLAND
		or terrain[i] == TileType.FOREST) \
		and occupancy[i] == null and not roads[i]

func place_road(cell: Vector2i) -> void:
	roads[_idx(cell.x, cell.y)] = true
	queue_redraw()

func remove_road(cell: Vector2i) -> void:
	roads[_idx(cell.x, cell.y)] = false
	queue_redraw()

# ---------- A* 寻路（4 方向，曼哈顿启发；二叉堆开列表 + 懒惰删除，O(E log V)） ----------
# 路面加权：土路格代价 65、其他 100——村民寻路会主动绕走路（与路上 +60% 速度对应）

const ROAD_MOVE_COST := 65
const BASE_MOVE_COST := 100

func _move_cost(cell: Vector2i, for_enemy := false) -> int:
	# 强盗不吃路面加权：他们没有路上加速，土路不该变成引进箭塔走廊的诱饵
	if for_enemy:
		return BASE_MOVE_COST
	return ROAD_MOVE_COST if has_road(cell) else BASE_MOVE_COST

func find_path(from: Vector2i, to: Vector2i, for_enemy := false) -> Array[Vector2i]:
	if from == to:
		return [to]
	# 条目为 [f值, 格]；松弛改进时允许重复入堆，出堆遇已 closed 的陈旧条目直接跳过
	var heap: Array = []
	var came_from := {}
	var g_score := {from: 0}
	var closed := {}
	_heap_push(heap, _heuristic(from, to), from)
	while not heap.is_empty():
		var current: Vector2i = _heap_pop(heap)
		if closed.has(current):
			continue
		if current == to:
			return _reconstruct_path(came_from, current)
		closed[current] = true
		for n in _walkable_neighbors(current, for_enemy):
			if closed.has(n):
				continue
			var tentative: int = g_score[current] + _move_cost(n, for_enemy)
			if tentative < g_score.get(n, INF):
				came_from[n] = current
				g_score[n] = tentative
				_heap_push(heap, tentative + _heuristic(n, to), n)
	return []

## 最小堆入堆（按 f 值上浮）
func _heap_push(heap: Array, f: int, cell: Vector2i) -> void:
	heap.append([f, cell])
	var i := heap.size() - 1
	while i > 0:
		var parent := (i - 1) >> 1
		if heap[parent][0] <= heap[i][0]:
			break
		var tmp = heap[parent]
		heap[parent] = heap[i]
		heap[i] = tmp
		i = parent

## 最小堆出堆（堆顶下沉），返回 f 最小的格
func _heap_pop(heap: Array) -> Vector2i:
	var top: Vector2i = heap[0][1]
	var last = heap.pop_back()
	if not heap.is_empty():
		heap[0] = last
		var i := 0
		while true:
			var l := i * 2 + 1
			var r := i * 2 + 2
			var smallest := i
			if l < heap.size() and heap[l][0] < heap[smallest][0]:
				smallest = l
			if r < heap.size() and heap[r][0] < heap[smallest][0]:
				smallest = r
			if smallest == i:
				break
			var tmp = heap[smallest]
			heap[smallest] = heap[i]
			heap[i] = tmp
			i = smallest
	return top

func _heuristic(a: Vector2i, b: Vector2i) -> int:
	# 曼哈顿距离 × 最小单格代价（65），保证可采纳（不高估）且引导搜索偏向路面
	return (absi(a.x - b.x) + absi(a.y - b.y)) * ROAD_MOVE_COST

func _walkable_neighbors(cell: Vector2i, for_enemy := false) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for d in [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.DOWN, Vector2i.UP]:
		var n: Vector2i = cell + d
		if is_walkable(n, for_enemy):
			result.append(n)
	return result

func _reconstruct_path(came_from: Dictionary, current: Vector2i) -> Array[Vector2i]:
	var path: Array[Vector2i] = [current]
	while came_from.has(current):
		current = came_from[current]
		path.push_front(current)
	return path

func random_walkable_cell() -> Vector2i:
	for i in 100:
		var c := Vector2i(randi_range(0, width - 1), randi_range(0, height - 1))
		if is_walkable(c):
			return c
	return Vector2i.ZERO

## 附近随机一个可行走格（村民闲逛用，避免全图跨图寻路）；找不到再全局随机
func random_walkable_cell_near(center: Vector2i, radius: int) -> Vector2i:
	for i in 50:
		var c := Vector2i(
			clampi(center.x + randi_range(-radius, radius), 0, width - 1),
			clampi(center.y + randi_range(-radius, radius), 0, height - 1))
		if is_walkable(c):
			return c
	return random_walkable_cell()

## 地图边缘随机一个可行走格（强盗出生/撤退用）
func random_edge_cell(for_enemy := false) -> Vector2i:
	for i in 200:
		var c := Vector2i.ZERO
		match randi_range(0, 3):
			0: c = Vector2i(0, randi_range(0, height - 1))
			1: c = Vector2i(width - 1, randi_range(0, height - 1))
			2: c = Vector2i(randi_range(0, width - 1), 0)
			_: c = Vector2i(randi_range(0, width - 1), height - 1)
		if is_walkable(c, for_enemy):
			return c
	return Vector2i.ZERO

# ---------- 显示（无格线、有机斑块渲染；逻辑仍是网格） ----------

func _draw() -> void:
	if terrain.is_empty():
		return
	# 草地铺满整图作底色
	draw_rect(Rect2(0, 0, width * TILE, height * TILE), TILE_COLORS[TileType.GRASS])
	# 平原草簇（先画，被其他地块盖住也无妨）
	_draw_grass_detail()
	# 其他地形画成圆形软斑块，重叠后边缘自然；再叠加各自的地块标识物
	_draw_terrain_blobs(TileType.WATER)
	_draw_terrain_blobs(TileType.MOUNTAIN)
	_draw_terrain_blobs(TileType.BERRY)
	_draw_terrain_blobs(TileType.FOREST)
	# 耕地保持整齐的方块（农田本来就是人犁出来的）
	for x in width:
		for y in height:
			if terrain[_idx(x, y)] == TileType.FARMLAND:
				draw_rect(Rect2(x * TILE + 1, y * TILE + 1, TILE - 2, TILE - 2),
					TILE_COLORS[TileType.FARMLAND])
	# 道路：连接条 + 中心圆点，连成小径
	for x in width:
		for y in height:
			var i := _idx(x, y)
			if not roads[i]:
				continue
			var c := Vector2(x * TILE + TILE / 2.0, y * TILE + TILE / 2.0)
			for d in [Vector2i.RIGHT, Vector2i.DOWN]:
				var n: Vector2i = Vector2i(x, y) + d
				if in_bounds(n.x, n.y) and roads[_idx(n.x, n.y)]:
					if d == Vector2i.RIGHT:
						draw_rect(Rect2(c - Vector2(0, 5), Vector2(TILE, 10)), ROAD_COLOR)
					else:
						draw_rect(Rect2(c - Vector2(5, 0), Vector2(10, TILE)), ROAD_COLOR)
			draw_circle(c, 6.0, ROAD_COLOR)

## 某种地形画两层圆：外层半透明大圆晕开，内层实心核心，带随机抖动
func _draw_terrain_blobs(type: TileType) -> void:
	var base: Color = TILE_COLORS[type]
	# 外层晕染
	for x in width:
		for y in height:
			var i := _idx(x, y)
			if terrain[i] != type:
				continue
			var c := _blob_center(x, y, i)
			draw_circle(c, TILE * 0.82, Color(base, 0.45))
	# 实心核心
	for x in width:
		for y in height:
			var i := _idx(x, y)
			if terrain[i] != type:
				continue
			var c := _blob_center(x, y, i)
			var col := base.lightened((_jitter[i] - 0.5) * 0.12)
			draw_circle(c, TILE * 0.68, col)
	# 地块标识物：让四种资源地形一眼可辨
	for x in width:
		for y in height:
			var i := _idx(x, y)
			if terrain[i] != type:
				continue
			var c := _blob_center(x, y, i)
			var j: float = _jitter[i]
			match type:
				TileType.FOREST:
					_draw_tree(c, j)
				TileType.WATER:
					_draw_waves(c, j)
				TileType.MOUNTAIN:
					_draw_stone_spikes(c, j)
				TileType.BERRY:
					_draw_berry_bush(c, j)

## 平原：稀疏草簇（约 1/3 的格子，确定性抖动），让"可建设用地"有质感又不喧宾夺主
func _draw_grass_detail() -> void:
	var dark := TILE_COLORS[TileType.GRASS].darkened(0.18)
	for x in width:
		for y in height:
			var i := _idx(x, y)
			if terrain[i] != TileType.GRASS or _jitter[i] > 0.34:
				continue
			var c := _blob_center(x, y, i)
			for k in 3:
				var off := Vector2((float(k) - 1.0) * 4.0 + (_jitter[i] - 0.5) * 3.0,
					2.0 - float(k % 2) * 2.0)
				draw_line(c + off + Vector2(0, 3), c + off - Vector2(0, 3), dark, 1.2)

## 森林：一棵小树（树干 + 两层三角树冠），随机偏转与大小
func _draw_tree(c: Vector2, j: float) -> void:
	var s := 0.85 + j * 0.4
	var trunk := Color(0.36, 0.24, 0.12)
	draw_rect(Rect2(c + Vector2(-1.5 * s, 2.0 * s), Vector2(3.0 * s, 5.0 * s)), trunk)
	var dark := Color(0.12, 0.38, 0.14)
	var light := Color(0.18, 0.5, 0.18)
	draw_colored_polygon([c + Vector2(0, -13 * s), c + Vector2(-8 * s, 1 * s), c + Vector2(8 * s, 1 * s)], dark)
	draw_colored_polygon([c + Vector2(0, -8 * s), c + Vector2(-6 * s, 4 * s), c + Vector2(6 * s, 4 * s)], light)

## 水域：两道弧形波纹（浅色），静帧也有"水"的观感
func _draw_waves(c: Vector2, j: float) -> void:
	var wave := Color(0.62, 0.78, 0.95, 0.65)
	var y0 := -4.0 + j * 3.0
	draw_arc(c + Vector2(-2, y0), 6.0, PI * 1.15, PI * 1.85, 8, wave, 1.4)
	draw_arc(c + Vector2(3, y0 + 7.0), 5.0, PI * 1.15, PI * 1.85, 8, wave, 1.2)

## 石林：2~3 根灰色石笋尖峰，高低错落
func _draw_stone_spikes(c: Vector2, j: float) -> void:
	var light := Color(0.68, 0.68, 0.72)
	var dark := Color(0.5, 0.5, 0.56)
	draw_colored_polygon([c + Vector2(-7, 9), c + Vector2(-3, -10 - j * 4), c + Vector2(1, 9)], light)
	draw_colored_polygon([c + Vector2(-1, 9), c + Vector2(4, -6 + j * 3), c + Vector2(8, 9)], dark)
	draw_colored_polygon([c + Vector2(2, 9), c + Vector2(6, -2 - j * 2), c + Vector2(9, 9)], light.darkened(0.05))

## 浆果丛：深绿灌木 + 三颗红果
func _draw_berry_bush(c: Vector2, j: float) -> void:
	var bush := Color(0.16, 0.42, 0.2)
	draw_circle(c + Vector2(-3, 2), 5.5 + j * 1.5, bush)
	draw_circle(c + Vector2(4, 3), 4.5, bush.darkened(0.1))
	draw_circle(c + Vector2(0, -2), 4.0, bush.lightened(0.08))
	var berry := Color(0.85, 0.2, 0.25)
	draw_circle(c + Vector2(-3, 0), 1.6, berry)
	draw_circle(c + Vector2(3, 4), 1.6, berry)
	draw_circle(c + Vector2(1, -3), 1.6, berry)

## 斑块中心：格中心 + 由该格随机值决定的微小偏移，打破棋盘感
func _blob_center(x: int, y: int, i: int) -> Vector2:
	var j: float = _jitter[i]
	return Vector2(x * TILE + TILE / 2.0, y * TILE + TILE / 2.0) \
		+ Vector2.RIGHT.rotated(j * TAU) * 3.0
