extends Node
class_name ResourceManager

## 全局资源池（采用共享库存，不做搬运物流）。
## 建造扣费、生产产出、村民吃饭都走这里。
##
## 资源分四类（CATEGORIES）：食物 / 原料 / 产物 / 财富。
## 分类只影响显示（顶栏折叠、月度面板分节），生产逻辑一律按具体类型走。
## 新增一种资源 = 在 Type 末尾追加 + 写进 NAMES 与某个分类。**必须追加在末尾**：
## 存档 stock 以 str(枚举值) 为键，往中间插一个会把老存档的库存全部错位。

enum Type {
	WOOD, FOOD, WHEAT, FLOUR, BREAD, STONE, GOLD, WOOL, CLOTHES, BEER,
	MEAT, HIDE, LEATHER, CLAY, BRICK, CHARCOAL, IRON_ORE, IRON, TOOLS,
	HERB, MEDICINE, SALT, HONEY, CURED_MEAT,
}

const NAMES := {
	Type.WOOD: "木材", Type.FOOD: "食物", Type.WHEAT: "小麦",
	Type.FLOUR: "面粉", Type.BREAD: "面包", Type.STONE: "石料", Type.GOLD: "金币",
	Type.WOOL: "羊毛", Type.CLOTHES: "衣服", Type.BEER: "啤酒",
	Type.MEAT: "肉类", Type.HIDE: "兽皮", Type.LEATHER: "皮革",
	Type.CLAY: "黏土", Type.BRICK: "砖块", Type.CHARCOAL: "木炭",
	Type.IRON_ORE: "铁矿石", Type.IRON: "铁锭", Type.TOOLS: "铁器",
	Type.HERB: "草药", Type.MEDICINE: "药剂", Type.SALT: "海盐", Type.HONEY: "蜂蜜",
	Type.CURED_MEAT: "腌肉",
}

## 月度面板的分节顺序（键即分节 id，值为该节包含的资源，按显示顺序）
const CATEGORIES: Array[Dictionary] = [
	{"id": "food", "name": "食物",
		"types": [Type.FOOD, Type.MEAT, Type.BREAD, Type.CURED_MEAT, Type.HONEY, Type.SALT]},
	{"id": "raw", "name": "原料",
		"types": [Type.WOOD, Type.STONE, Type.CLAY, Type.IRON_ORE,
			Type.WHEAT, Type.WOOL, Type.HIDE, Type.HERB]},
	{"id": "goods", "name": "产物",
		"types": [Type.FLOUR, Type.CHARCOAL, Type.BRICK, Type.IRON, Type.TOOLS,
			Type.LEATHER, Type.CLOTHES, Type.BEER, Type.MEDICINE]},
	{"id": "wealth", "name": "财富", "types": [Type.GOLD]},
]

## 顶栏常驻的核心资源；其余资源"有库存或有流水"才占位置，
## 否则 23 种资源一字排开会把顶栏挤爆，前期还全是 0
const CORE_TYPES: Array[int] = [Type.WOOD, Type.FOOD, Type.BREAD, Type.STONE, Type.GOLD]

## 能吃的东西：按这个顺序优先消耗，值为回复的饥饿度。
## 面包回满、肉次之、生食一半——加工链越深，同一份原料喂饱的人越多
const EDIBLE_RESTORE: Array[Array] = [
	[Type.BREAD, 100.0], [Type.CURED_MEAT, 90.0], [Type.MEAT, 80.0],
	[Type.HONEY, 60.0], [Type.FOOD, 50.0],
]

## 会腐坏的生鲜（超过保鲜线的部分每天按这个比例烂掉）。
## 肉比生食烂得快——这正是腌肉坊（海盐）与粮仓存在的理由
const PERISHABLE := {Type.FOOD: 0.2, Type.MEAT: 0.3}

## 每月 = 5 天（与一个季节等长）。月度面板按这个窗口做滚动平均
const MONTH_DAYS := 5

signal changed

var stock: Dictionary = {}
## 日流水记账：所有进出都从 add/try_spend/try_consume 走，所以在这里记一笔就够了。
## 面板显示的是「昨日」的完整一天（今天还没过完，实时数会一直跳）。
var flow_in: Dictionary = {}    # 今日进项累计
var flow_out: Dictionary = {}   # 今日出项累计
var last_in: Dictionary = {}    # 昨日进项（概览面板读它）
var last_out: Dictionary = {}   # 昨日出项
## 最近 MONTH_DAYS 天的完整流水（每项 {"in": {}, "out": {}}），月度面板的数据源
var day_history: Array[Dictionary] = []
## 全局平均幸福度（main 每天计算一次写入），建筑产量加成读它
var happiness := 50.0

func _ready() -> void:
	reset()

## 清空库存并给开局物资（新游戏时调用）
func reset() -> void:
	flow_in.clear()
	flow_out.clear()
	last_in.clear()
	last_out.clear()
	day_history.clear()
	for t in Type.values():
		stock[t] = 0
	stock[Type.WOOD] = 40
	stock[Type.FOOD] = 30
	happiness = 50.0
	changed.emit()

func get_amount(t: int) -> int:
	return stock.get(t, 0)

func add(t: int, amount: int) -> void:
	stock[t] = get_amount(t) + amount
	if amount > 0:
		flow_in[t] = int(flow_in.get(t, 0)) + amount
	changed.emit()

## 跨日：把今天的流水冻结为「昨日」并推进月度窗口，重新开账（main._on_new_day 末尾调用）
func roll_day() -> void:
	last_in = flow_in.duplicate()
	last_out = flow_out.duplicate()
	day_history.push_back({"in": last_in.duplicate(), "out": last_out.duplicate()})
	while day_history.size() > MONTH_DAYS:
		day_history.pop_front()
	flow_in.clear()
	flow_out.clear()

## 昨日净额（进 − 出），概览面板与资源栏箭头用
func net_yesterday(t: int) -> int:
	return int(last_in.get(t, 0)) - int(last_out.get(t, 0))

# ---------- 月度口径（群星式「每月变动」） ----------

## 已记满几天（不足一个月时按已有天数折算，别把第 1 天的收入当整月）
func history_days() -> int:
	return day_history.size()

func _month_sum(key: String, t: int) -> float:
	if day_history.is_empty():
		return 0.0
	var total := 0.0
	for d in day_history:
		var m: Dictionary = d[key]
		total += float(m.get(t, 0))
	return total / float(day_history.size()) * float(MONTH_DAYS)

## 折算到整月的进项 / 出项 / 净额（最近 MONTH_DAYS 天的日均 × 5）
func month_in(t: int) -> float:
	return _month_sum("in", t)

func month_out(t: int) -> float:
	return _month_sum("out", t)

func month_net(t: int) -> float:
	return month_in(t) - month_out(t)

## 这种资源值不值得占顶栏一格：核心资源常驻，其余有库存或这个月动过才显示
func is_relevant(t: int) -> bool:
	if t in CORE_TYPES:
		return true
	if get_amount(t) > 0:
		return true
	return not is_zero_approx(month_in(t)) or not is_zero_approx(month_out(t))

## costs 格式：[ [类型, 数量], ... ]
func has_all(costs: Array) -> bool:
	for c in costs:
		if get_amount(c[0]) < c[1]:
			return false
	return true

## 尝试扣一组资源，不足则不动并返回 false
func try_spend(costs: Array) -> bool:
	if not has_all(costs):
		return false
	for c in costs:
		stock[c[0]] = get_amount(c[0]) - c[1]
		if int(c[1]) > 0:
			flow_out[c[0]] = int(flow_out.get(c[0], 0)) + int(c[1])
	changed.emit()
	return true

## 尝试消耗单个资源（村民吃饭用）
func try_consume(t: int, amount: int = 1) -> bool:
	if get_amount(t) < amount:
		return false
	stock[t] -= amount
	flow_out[t] = int(flow_out.get(t, 0)) + amount
	changed.emit()
	return true

## 可吃的东西总量（面包/肉/蜂蜜/生食都算；具体吃哪个由 EDIBLE_RESTORE 顺序决定）
func edible_amount() -> int:
	var total := 0
	for entry in EDIBLE_RESTORE:
		total += get_amount(int(entry[0]))
	return total

## 库存能提供的饥饿度总量（存粮天数用；按各自的回复值加权，不是简单数个数）
func edible_supply() -> float:
	var total := 0.0
	for entry in EDIBLE_RESTORE:
		total += float(get_amount(int(entry[0]))) * float(entry[1])
	return total
