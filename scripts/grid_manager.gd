extends Node2D
class_name GridManager

## 网格地图：逻辑数据（地形、建筑占用、路面）存在数组里，
## _draw() 只负责把数据画出来。放置判定、寻路全查数据层。
## 地形种类：草地（可建可走）、森林（可走，资源地块不可建设）、水域（不可建不可走）、
## 山地（不可建不可走，采石场要挨着它）、耕地（麦田转化而来）、
## 浆果丛（可走，资源地块）、黏土滩（可走，资源地块，砖窑要挨着它）、
## 铁矿脉（不可建不可走，长在山里，矿场要挨着它）。
##
## 地图生成：两张 fBm 噪声（高程 + 湿度）+ 分位数取阈值。
## 分位数的好处是"目标比例即实际比例"——WorldConfig 里写 19% 水域就真的是 19%，
## 换地形预设时地貌差异确定可见，不像固定阈值那样受噪声分布摆布。
## 生成末尾有一道"开局保证"：中心必有一片空地，且 12 格内四类资源地形齐全，
## 杜绝"开局周围没有浆果丛/森林，第一座建筑无处可放"的死图。

const TILE := 32
const INF := 1 << 30

enum TileType { GRASS, FOREST, WATER, MOUNTAIN, FARMLAND, BERRY, CLAY, IRON }

## 路面类型：不同交通方式走不同地形、不同速度、不同造价。
## NONE 以外的值都算"有路"（has_road），寻路加权与移速倍率见下面两张表。
enum RoadType { NONE, DIRT, BRIDGE, STONE, PASS }

const ROAD_KIND_IDS := {
	"dirt": RoadType.DIRT, "bridge": RoadType.BRIDGE,
	"stone": RoadType.STONE, "pass": RoadType.PASS,
}

const ROAD_NAMES := {
	RoadType.DIRT: "土路", RoadType.BRIDGE: "木桥",
	RoadType.STONE: "石板路", RoadType.PASS: "山道",
}

const ROAD_COLORS := {
	RoadType.DIRT: Color(0.72, 0.62, 0.45),
	RoadType.BRIDGE: Color(0.55, 0.38, 0.22),
	RoadType.STONE: Color(0.62, 0.62, 0.66),
	RoadType.PASS: Color(0.5, 0.46, 0.4),
}

## 寻路代价（越小村民越愿意绕过来走）与移速倍率（与代价同向，别让两者打架）
const ROAD_MOVE_COSTS := {
	RoadType.NONE: 100, RoadType.DIRT: 65, RoadType.BRIDGE: 80,
	RoadType.STONE: 45, RoadType.PASS: 85,
}
const ROAD_SPEEDS := {
	RoadType.NONE: 1.0, RoadType.DIRT: 1.6, RoadType.BRIDGE: 1.25,
	RoadType.STONE: 2.1, RoadType.PASS: 1.15,
}

const BASE_MOVE_COST := 100
## A* 启发式的单格下界：必须 ≤ 所有可能代价，否则会高估、路径不再最优
const MIN_MOVE_COST := 45

const TILE_COLORS: Dictionary = {
	TileType.GRASS: Color(0.45, 0.75, 0.35),
	TileType.FOREST: Color(0.15, 0.45, 0.15),
	TileType.WATER: Color(0.25, 0.45, 0.8),
	TileType.MOUNTAIN: Color(0.55, 0.55, 0.6),
	TileType.FARMLAND: Color(0.6, 0.45, 0.25),
	TileType.BERRY: Color(0.55, 0.3, 0.45),
	TileType.CLAY: Color(0.72, 0.5, 0.34),
	TileType.IRON: Color(0.42, 0.36, 0.36),
}

@export var width := 56
@export var height := 56

var config: WorldConfig = WorldConfig.new()

var terrain: Array[int] = []
var occupancy: Array = []      # Building 或 null
var road_type: Array[int] = [] # RoadType
var spawn_center := Vector2i(-1, -1)  # 开局镜头/首建议落点
var _jitter: Array[float] = []  # 每格一个确定性随机值，渲染抖动用

func _ready() -> void:
	generate_map()

## 读档后地图尺寸可能变了：重铺渲染抖动表并重挑出生点。
## 抖动表长度必须始终等于 width*height，否则 _draw 会越界
func rebuild_jitter() -> void:
	var n := width * height
	_jitter.clear()
	_jitter.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = config.world_seed if config.world_seed != 0 else n
	for i in n:
		_jitter[i] = rng.randf()
	spawn_center = _pick_spawn_center()
	queue_redraw()

func _idx(x: int, y: int) -> int:
	return x * height + y

# ---------- 地图生成 ----------

## 换一套世界参数（新游戏前调用）；尺寸随之改变，随后必须重新 generate_map
func apply_config(cfg: WorldConfig) -> void:
	config = cfg
	width = cfg.map_width()
	height = cfg.map_height()

func generate_map() -> void:
	var n := width * height
	var world_seed: int = config.world_seed if config.world_seed != 0 else randi()
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed

	terrain.clear()
	occupancy.clear()
	road_type.clear()
	_jitter.clear()
	terrain.resize(n)
	road_type.resize(n)
	occupancy.resize(n)
	_jitter.resize(n)
	for i in n:
		terrain[i] = TileType.GRASS
		road_type[i] = RoadType.NONE
		occupancy[i] = null
		_jitter[i] = rng.randf()

	var conf: Dictionary = config.terrain_data()
	var elev := _noise_field(world_seed, 0.030 * float(conf.get("elev", 1.0)), 4)
	var moist := _noise_field(world_seed + 7717, 0.036 * float(conf.get("moist", 1.0)), 3)

	# 高程分位数 → 水域（最低的一批）与山地（最高的一批）
	var elev_sorted := elev.duplicate()
	elev_sorted.sort()
	var water_thr := _quantile(elev_sorted, float(conf.get("water", 0.06)))
	var mount_thr := _quantile(elev_sorted, 1.0 - float(conf.get("mountain", 0.05)))
	for i in n:
		if elev[i] <= water_thr:
			terrain[i] = TileType.WATER
		elif elev[i] >= mount_thr:
			terrain[i] = TileType.MOUNTAIN

	# 湿度分位数 → 陆地里最湿的一批变森林（森林比例按全图口径给）
	var forest_target := int(n * float(conf.get("forest", 0.15)))
	_assign_top(_land_scores(moist, TileType.GRASS), forest_target, TileType.FOREST)

	# 资源地块：浆果贴森林、黏土贴水、铁矿在山里（丰度倍率已含在 resource_ratio 里）
	var land := _count_land()
	_assign_top(_berry_scores(rng), int(land * config.resource_ratio("berry")), TileType.BERRY)
	_assign_top(_clay_scores(rng), int(land * config.resource_ratio("clay")), TileType.CLAY)
	_assign_top(_iron_scores(rng), int(n * config.resource_ratio("iron")), TileType.IRON)

	_guarantee_start_area(rng)
	queue_redraw()

## 一张 fBm 噪声场（归一到该图自身的取值范围无所谓，后面全走分位数）
func _noise_field(field_seed: int, freq: float, octaves: int) -> Array[float]:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = field_seed
	noise.frequency = freq
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	var out: Array[float] = []
	out.resize(width * height)
	for x in width:
		for y in height:
			out[_idx(x, y)] = noise.get_noise_2d(float(x), float(y))
	return out

## 已排序数组的 q 分位（q 取 0~1）
func _quantile(sorted_values: Array[float], q: float) -> float:
	if sorted_values.is_empty():
		return 0.0
	var i := clampi(int(float(sorted_values.size()) * clampf(q, 0.0, 1.0)),
		0, sorted_values.size() - 1)
	return sorted_values[i]

## [[分数, 格索引], ...]，按分数降序取前 k 个改成 type
func _assign_top(pairs: Array, k: int, type: TileType) -> void:
	if k <= 0 or pairs.is_empty():
		return
	pairs.sort_custom(_score_desc)
	for i in mini(k, pairs.size()):
		terrain[int(pairs[i][1])] = type

func _score_desc(a: Array, b: Array) -> bool:
	return a[0] > b[0]

## 指定地形的格子按 field 打分（森林选址用湿度）
func _land_scores(field: Array[float], only: TileType) -> Array:
	var out: Array = []
	for i in terrain.size():
		if terrain[i] == only:
			out.append([field[i], i])
	return out

## 浆果丛：只长草地，越靠近森林分越高（采集小屋自然贴着林边）
func _berry_scores(rng: RandomNumberGenerator) -> Array:
	var out: Array = []
	for x in width:
		for y in height:
			var i := _idx(x, y)
			if terrain[i] != TileType.GRASS:
				continue
			var near := _neighbor_count(x, y, TileType.FOREST, 2)
			if near == 0:
				continue
			out.append([float(near) + rng.randf() * 3.0, i])
	return out

## 黏土滩：只长草地，且要挨着水（河滩淤积）
func _clay_scores(rng: RandomNumberGenerator) -> Array:
	var out: Array = []
	for x in width:
		for y in height:
			var i := _idx(x, y)
			if terrain[i] != TileType.GRASS:
				continue
			var near := _neighbor_count(x, y, TileType.WATER, 2)
			if near == 0:
				continue
			out.append([float(near) + rng.randf() * 2.0, i])
	return out

## 铁矿脉：长在山体内部（周围山越多分越高，避免孤零零一格铁矿卡在平地边）
func _iron_scores(rng: RandomNumberGenerator) -> Array:
	var out: Array = []
	for x in width:
		for y in height:
			var i := _idx(x, y)
			if terrain[i] != TileType.MOUNTAIN:
				continue
			out.append([float(_neighbor_count(x, y, TileType.MOUNTAIN, 1)) + rng.randf(), i])
	return out

func _neighbor_count(x: int, y: int, type: TileType, radius: int) -> int:
	var c := 0
	for nx in range(x - radius, x + radius + 1):
		for ny in range(y - radius, y + radius + 1):
			if in_bounds(nx, ny) and terrain[_idx(nx, ny)] == type:
				c += 1
	return c

func _count_land() -> int:
	var c := 0
	for i in terrain.size():
		if terrain[i] != TileType.WATER and terrain[i] != TileType.MOUNTAIN:
			c += 1
	return c

# ---------- 开局保证 ----------

const START_PLAZA_RADIUS := 3   # 中心必定清出的空地半径
const START_SCAN_RADIUS := 12   # 四类资源必须出现在这个半径内
const RESOURCE_GUARANTEES: Array[Dictionary] = [
	{"type": TileType.FOREST, "size": 3},
	{"type": TileType.WATER, "size": 2},
	{"type": TileType.MOUNTAIN, "size": 2},
	{"type": TileType.BERRY, "size": 1},
]

## 选一个中心空地，再补齐附近缺的资源地形。
## 没有这一步，随机地图会稳定产出一小撮"开局无处可建 / 没有浆果丛"的死图，
## 玩家只能重开——那不是难度，是浪费时间。
func _guarantee_start_area(rng: RandomNumberGenerator) -> void:
	spawn_center = _pick_spawn_center()
	for x in range(spawn_center.x - START_PLAZA_RADIUS, spawn_center.x + START_PLAZA_RADIUS + 1):
		for y in range(spawn_center.y - START_PLAZA_RADIUS, spawn_center.y + START_PLAZA_RADIUS + 1):
			if in_bounds(x, y) and Vector2(x - spawn_center.x, y - spawn_center.y).length() \
					<= float(START_PLAZA_RADIUS):
				terrain[_idx(x, y)] = TileType.GRASS
	for req in RESOURCE_GUARANTEES:
		var t: int = int(req["type"])
		if _has_within(spawn_center, t, START_SCAN_RADIUS):
			continue
		_carve_patch(rng, t, int(req["size"]))

## 地图中部扫一遍，挑周围草地最多的那一格当出生点
func _pick_spawn_center() -> Vector2i:
	var best := Vector2i(width / 2, height / 2)
	var best_score := -1
	var margin_x := maxi(START_SCAN_RADIUS, width / 5)
	var margin_y := maxi(START_SCAN_RADIUS, height / 5)
	for x in range(margin_x, width - margin_x, 2):
		for y in range(margin_y, height - margin_y, 2):
			var score := _neighbor_count(x, y, TileType.GRASS, START_PLAZA_RADIUS + 1)
			if score > best_score:
				best_score = score
				best = Vector2i(x, y)
	return best

func _has_within(center: Vector2i, type: int, radius: int) -> bool:
	for x in range(center.x - radius, center.x + radius + 1):
		for y in range(center.y - radius, center.y + radius + 1):
			if in_bounds(x, y) and terrain[_idx(x, y)] == type:
				return true
	return false

## 在广场外、扫描半径内挖一小块指定地形（补齐缺失的资源）
func _carve_patch(rng: RandomNumberGenerator, type: int, radius: int) -> void:
	for attempt in 200:
		var ang := rng.randf() * TAU
		var dist := rng.randf_range(float(START_PLAZA_RADIUS + radius + 2),
			float(START_SCAN_RADIUS - radius))
		var c := spawn_center + Vector2i(Vector2.RIGHT.rotated(ang) * dist)
		if not in_bounds(c.x, c.y):
			continue
		for x in range(c.x - radius, c.x + radius + 1):
			for y in range(c.y - radius, c.y + radius + 1):
				if in_bounds(x, y) and Vector2(x - c.x, y - c.y).length() <= float(radius):
					terrain[_idx(x, y)] = type
		return

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

## 可行走：不是水/山/铁矿，或者上面架了桥/开了山道；没被建筑占。
## 例外：城门村民可以走、敌人不能走；for_enemy=true 供强盗寻路。
## 桥与山道对强盗同样有效——修桥就是给自己开门，这个代价必须让玩家感觉到。
func is_walkable(cell: Vector2i, for_enemy := false) -> bool:
	if not in_bounds(cell.x, cell.y):
		return false
	var i := _idx(cell.x, cell.y)
	if not _terrain_passable(terrain[i], road_type[i]):
		return false
	var b = occupancy[i]
	if b == null:
		return true
	return b.data.get("is_gate", false) and not for_enemy

## 地形本身能不能过（先看路面：桥跨水、山道翻山）
func _terrain_passable(t: int, road: int) -> bool:
	if t == TileType.WATER:
		return road == RoadType.BRIDGE
	if t == TileType.MOUNTAIN or t == TileType.IRON:
		return road == RoadType.PASS
	return true

## 附近 radius 格内是否有指定地形（建筑选址判定）
func has_adjacent_terrain(cell: Vector2i, type: TileType, radius := 2) -> bool:
	for x in range(cell.x - radius, cell.x + radius + 1):
		for y in range(cell.y - radius, cell.y + radius + 1):
			if in_bounds(x, y) and terrain[_idx(x, y)] == type:
				return true
	return false

# ---------- 建筑放置 ----------

## 通用选址判定：建设用地只能是平原（草地）+ 满足建筑的邻近地形要求。
## 森林/浆果丛/黏土滩是资源地块，与水域/石林一样不可建设（农场规则由此统一满足）
func can_place(origin: Vector2i, size: Vector2i, data: Dictionary) -> bool:
	for x in size.x:
		for y in size.y:
			var c := origin + Vector2i(x, y)
			if not in_bounds(c.x, c.y):
				return false
			var i := _idx(c.x, c.y)
			if terrain[i] != TileType.GRASS:
				return false
			if occupancy[i] != null or road_type[i] != RoadType.NONE:
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
	if data.get("needs_clay", false) \
			and not has_adjacent_terrain(origin, TileType.CLAY):
		return false
	if data.get("needs_iron", false) \
			and not has_adjacent_terrain(origin, TileType.IRON):
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
## 永远跳过被建筑占用的格子；avoid_road=true 时再跳过路面格（种树不长在路上）
func find_random_terrain_near(origin: Vector2i, size: Vector2i, type: TileType,
		radius: int, avoid_road := false) -> Vector2i:
	for attempt in 40:
		var c := Vector2i(
			clampi(origin.x + randi_range(-radius, radius + size.x - 1), 0, width - 1),
			clampi(origin.y + randi_range(-radius, radius + size.y - 1), 0, height - 1))
		var ti := _idx(c.x, c.y)
		if terrain[ti] != type or occupancy[ti] != null:
			continue
		if avoid_road and road_type[ti] != RoadType.NONE:
			continue
		return c
	# 线性兜底：环形区域穷举（资源只剩最后几格时随机采样会 ~44% 漏检）
	for x in range(origin.x - radius, origin.x + size.x + radius):
		for y in range(origin.y - radius, origin.y + size.y + radius):
			if not in_bounds(x, y):
				continue
			var ti := _idx(x, y)
			if terrain[ti] == type and occupancy[ti] == null \
					and not (avoid_road and road_type[ti] != RoadType.NONE):
				return Vector2i(x, y)
	return Vector2i(-1, -1)

## 直接改写一格地形（森林消耗/种植用）；占用与路面不受影响
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

# ---------- 路面 ----------

## 目录条目的 road_kind 字符串 → RoadType（缺省按土路，老存档/老条目安全降级）
static func road_kind_of(data: Dictionary) -> int:
	return int(ROAD_KIND_IDS.get(str(data.get("road_kind", "dirt")), RoadType.DIRT))

func road_at(cell: Vector2i) -> int:
	if not in_bounds(cell.x, cell.y):
		return RoadType.NONE
	return road_type[_idx(cell.x, cell.y)]

func has_road(cell: Vector2i) -> bool:
	return road_at(cell) != RoadType.NONE

## 该格路面给村民的移速倍率（无路 = 1.0）
func road_speed(cell: Vector2i) -> float:
	return float(ROAD_SPEEDS.get(road_at(cell), 1.0))

## 每种交通方式各有各的可铺地形；石板路额外允许直接盖在土路上（原地升级，不用先拆）
func can_place_road(cell: Vector2i, kind := RoadType.DIRT) -> bool:
	if not in_bounds(cell.x, cell.y):
		return false
	var i := _idx(cell.x, cell.y)
	if occupancy[i] != null:
		return false
	var t: int = terrain[i]
	var here: int = road_type[i]
	match kind:
		RoadType.BRIDGE:
			return t == TileType.WATER and here == RoadType.NONE
		RoadType.PASS:
			return (t == TileType.MOUNTAIN or t == TileType.IRON) and here == RoadType.NONE
		RoadType.STONE:
			return _is_dry_roadbed(t) and (here == RoadType.NONE or here == RoadType.DIRT)
		_:
			return _is_dry_roadbed(t) and here == RoadType.NONE

## 陆路可铺的地面：土路可穿过森林成为林间小径；资源地块（浆果/黏土）不铺，留给采集
func _is_dry_roadbed(t: int) -> bool:
	return t == TileType.GRASS or t == TileType.FARMLAND or t == TileType.FOREST

func place_road(cell: Vector2i, kind := RoadType.DIRT) -> void:
	road_type[_idx(cell.x, cell.y)] = kind
	queue_redraw()

func remove_road(cell: Vector2i) -> void:
	road_type[_idx(cell.x, cell.y)] = RoadType.NONE
	queue_redraw()

# ---------- A* 寻路（4 方向，曼哈顿启发；二叉堆开列表 + 懒惰删除，O(E log V)） ----------
# 路面加权：见 ROAD_MOVE_COSTS——村民寻路会主动绕走路（与路上的移速倍率对应）

func _move_cost(cell: Vector2i, for_enemy := false) -> int:
	# 强盗不吃路面加权：他们没有路上加速，土路不该变成引进箭塔走廊的诱饵
	if for_enemy:
		return BASE_MOVE_COST
	return int(ROAD_MOVE_COSTS.get(road_at(cell), BASE_MOVE_COST))

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
	# 曼哈顿距离 × 最小单格代价，保证可采纳（不高估）且引导搜索偏向路面。
	# 加了石板路以后下界从 65 降到 45——忘了同步这个常量就会开始返回次优路径
	return (absi(a.x - b.x) + absi(a.y - b.y)) * MIN_MOVE_COST

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
	_draw_terrain_blobs(TileType.IRON)
	_draw_terrain_blobs(TileType.CLAY)
	_draw_terrain_blobs(TileType.BERRY)
	_draw_terrain_blobs(TileType.FOREST)
	# 耕地保持整齐的方块（农田本来就是人犁出来的）
	for x in width:
		for y in height:
			if terrain[_idx(x, y)] == TileType.FARMLAND:
				draw_rect(Rect2(x * TILE + 1, y * TILE + 1, TILE - 2, TILE - 2),
					TILE_COLORS[TileType.FARMLAND])
	_draw_roads()

## 路面：同类相连画连接条 + 中心圆点；每种交通方式一个颜色，一眼看出路网等级
func _draw_roads() -> void:
	for x in width:
		for y in height:
			var i := _idx(x, y)
			var kind: int = road_type[i]
			if kind == RoadType.NONE:
				continue
			var col: Color = ROAD_COLORS.get(kind, ROAD_COLORS[RoadType.DIRT])
			var c := Vector2(x * TILE + TILE / 2.0, y * TILE + TILE / 2.0)
			# 桥要有桥板的样子：先铺一块底板，再画栏杆
			if kind == RoadType.BRIDGE:
				draw_rect(Rect2(c - Vector2(TILE / 2.0, 7), Vector2(TILE, 14)), col.darkened(0.2))
			for d in [Vector2i.RIGHT, Vector2i.DOWN]:
				var n: Vector2i = Vector2i(x, y) + d
				if not in_bounds(n.x, n.y) or road_type[_idx(n.x, n.y)] == RoadType.NONE:
					continue
				if d == Vector2i.RIGHT:
					draw_rect(Rect2(c - Vector2(0, 5), Vector2(TILE, 10)), col)
				else:
					draw_rect(Rect2(c - Vector2(5, 0), Vector2(10, TILE)), col)
			draw_circle(c, 6.0, col)
			if kind == RoadType.STONE:
				# 石板路加两道浅色缝，和土路区分开
				draw_line(c + Vector2(-6, -3), c + Vector2(6, -3), col.lightened(0.25), 1.2)
				draw_line(c + Vector2(-6, 3), c + Vector2(6, 3), col.lightened(0.25), 1.2)
			elif kind == RoadType.PASS:
				draw_line(c + Vector2(-5, 4), c + Vector2(0, -4), col.lightened(0.3), 1.4)
				draw_line(c + Vector2(0, -4), c + Vector2(5, 4), col.lightened(0.3), 1.4)

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
	# 地块标识物：让各种资源地形一眼可辨
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
				TileType.CLAY:
					_draw_clay_pit(c, j)
				TileType.IRON:
					_draw_iron_vein(c, j)

## 平原：稀疏草簇（约 1/3 的格子，确定性抖动），让「可建设用地」有质感又不喧宾夺主
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

## 水域：两道弧形波纹（浅色），静帧也有「水」的观感
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

## 黏土滩：湿泥坑 + 几道横向淤积纹
func _draw_clay_pit(c: Vector2, j: float) -> void:
	var mud := Color(0.55, 0.36, 0.22)
	draw_circle(c + Vector2(0, 1), 7.0 + j * 1.5, mud)
	var wet := Color(0.78, 0.58, 0.4, 0.8)
	draw_line(c + Vector2(-6, -2), c + Vector2(5, -3), wet, 1.4)
	draw_line(c + Vector2(-5, 3), c + Vector2(6, 2), wet, 1.4)

## 铁矿脉：灰岩上一道锈红矿脉 + 两点矿星
func _draw_iron_vein(c: Vector2, j: float) -> void:
	var rock := Color(0.38, 0.34, 0.34)
	draw_colored_polygon([c + Vector2(-8, 8), c + Vector2(-2, -9 - j * 3), c + Vector2(7, 8)], rock)
	var rust := Color(0.72, 0.38, 0.2)
	draw_line(c + Vector2(-5, 5), c + Vector2(2, -5), rust, 2.0)
	draw_circle(c + Vector2(4, 3), 1.8, rust)
	draw_circle(c + Vector2(-2, 6), 1.5, rust.lightened(0.15))

## 斑块中心：格中心 + 由该格随机值决定的微小偏移，打破棋盘感
func _blob_center(x: int, y: int, i: int) -> Vector2:
	var j: float = _jitter[i]
	return Vector2(x * TILE + TILE / 2.0, y * TILE + TILE / 2.0) \
		+ Vector2.RIGHT.rotated(j * TAU) * 3.0
