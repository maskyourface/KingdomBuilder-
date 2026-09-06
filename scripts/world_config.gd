extends RefCounted
class_name WorldConfig

## 开局世界设置：地图大小 / 地形类型 / 资源丰度 / 随机种子。
## 进入游戏前由「新世界」界面填写，交给 GridManager.apply_config() 生成地图。
## 纯数据 + 三张静态表，新增一个尺寸或地形 = 加一条字典，界面自动多出一个选项。
##
## 权重口径：TERRAINS 里的 water/mountain/forest 是「占全图的目标比例」，
## berry/clay/iron 是「资源地块占陆地的目标比例」。生成器用分位数取阈值，
## 所以这些比例是实际结果而不是"大概齐"——换地形类型时地貌差异一眼可见。

const SIZES: Array[Dictionary] = [
	{
		"id": &"small", "name": "小片领地", "w": 40, "h": 40,
		"desc": "40×40。什么都在走路 20 秒内，通勤不是问题，适合短局",
	},
	{
		"id": &"medium", "name": "标准王国", "w": 56, "h": 56,
		"desc": "56×56。默认尺寸：四类地形都摊得开，也还看得过来",
	},
	{
		"id": &"large", "name": "辽阔疆域", "w": 76, "h": 76,
		"desc": "76×76。资源分散在远处，道路与桥梁从「锦上添花」变成刚需",
	},
]

## elev = 高程噪声频率倍率（越大地块越碎），moist = 湿度噪声频率倍率
const TERRAINS: Array[Dictionary] = [
	{
		"id": &"plains", "name": "大平原",
		"water": 0.05, "mountain": 0.04, "forest": 0.12,
		"berry": 0.016, "clay": 0.010, "iron": 0.006,
		"elev": 0.75, "moist": 1.0,
		"desc": "一望无际的可建设用地。森林稀少 → 木材必须靠植树场循环，别指望砍到底",
	},
	{
		"id": &"forest", "name": "密林",
		"water": 0.05, "mountain": 0.05, "forest": 0.38,
		"berry": 0.030, "clay": 0.008, "iron": 0.008,
		"elev": 1.0, "moist": 0.85,
		"desc": "森林与浆果丛遍地，木材食物开局宽裕；但平地零碎，规划城区要先砍出空间",
	},
	{
		"id": &"lakeland", "name": "湖沼之乡",
		"water": 0.19, "mountain": 0.03, "forest": 0.16,
		"berry": 0.018, "clay": 0.026, "iron": 0.004,
		"elev": 1.25, "moist": 1.1,
		"desc": "水网密布：渔业与黏土极丰，冬天不愁食物；陆路被水切碎，桥梁是生命线",
	},
	{
		"id": &"highland", "name": "高地丘陵",
		"water": 0.06, "mountain": 0.17, "forest": 0.14,
		"berry": 0.012, "clay": 0.008, "iron": 0.022,
		"elev": 1.35, "moist": 1.0,
		"desc": "石料与铁矿的宝库，防御工事管够；山脊挡路，山道开通前处处绕远",
	},
]

const RICHNESS: Array[Dictionary] = [
	{"id": &"sparse", "name": "贫瘠", "mult": 0.6,
		"desc": "资源地块只有六成。每一格森林都得算着用"},
	{"id": &"normal", "name": "适中", "mult": 1.0,
		"desc": "标准分布，推荐第一次开局选它"},
	{"id": &"rich", "name": "富饶", "mult": 1.5,
		"desc": "资源地块多五成。适合专心体验建造与流程"},
]

var size_id: StringName = &"medium"
var terrain_id: StringName = &"plains"
var richness_id: StringName = &"normal"
## 0 = 每局随机；非 0 时同一个种子必定生成同一张地图
var world_seed := 0

static func _find(table: Array[Dictionary], id: StringName) -> Dictionary:
	for d in table:
		if d["id"] == id:
			return d
	return table[0]

func size_data() -> Dictionary:
	return _find(SIZES, size_id)

func terrain_data() -> Dictionary:
	return _find(TERRAINS, terrain_id)

func richness_data() -> Dictionary:
	return _find(RICHNESS, richness_id)

func map_width() -> int:
	return int(size_data()["w"])

func map_height() -> int:
	return int(size_data()["h"])

## 资源地块（浆果/黏土/铁矿）的实际目标比例 = 地形基准 × 丰度倍率
func resource_ratio(key: String) -> float:
	return float(terrain_data().get(key, 0.0)) * float(richness_data()["mult"])

## 一句话总结（世界设置界面底部与存档信息里都用它）
func summary() -> String:
	return "%s · %s · %s" % [
		size_data()["name"], terrain_data()["name"], richness_data()["name"]]

func to_dict() -> Dictionary:
	return {
		"size": String(size_id), "terrain": String(terrain_id),
		"richness": String(richness_id), "seed": world_seed,
	}

static func from_dict(d: Dictionary) -> WorldConfig:
	var cfg := WorldConfig.new()
	cfg.size_id = StringName(str(d.get("size", "medium")))
	cfg.terrain_id = StringName(str(d.get("terrain", "plains")))
	cfg.richness_id = StringName(str(d.get("richness", "normal")))
	cfg.world_seed = int(d.get("seed", 0))
	return cfg
