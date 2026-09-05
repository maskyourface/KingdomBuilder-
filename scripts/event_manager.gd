extends Node
class_name EventManager
## 随机事件系统（时代Ⅰ起）：商队/节日/暴雨/流浪者……给前期每天一个决策点。
## 事件卡弹出即暂停（选完恢复），与袭击、菜单、覆灭面板互斥（已暂停时绝不弹卡）。
## game 为主控 main.gd，无类型注入（照 raid_manager 模式，避免 class_name 循环依赖）。

var game = null
var time: TimeManager = null
var rng := RandomNumberGenerator.new()

var next_event_day := -1     # 下一次事件可能发生的天数（-1 = 未排期）
var rainy_day := -1          # 暴雨停产日（该日农田/渔屋 no_prod_today，main 负责置位）
var mood_bonus := 0          # 节日等事件的全体幸福加成
var mood_days_left := 0
var card_open := false       # 事件卡是否正在显示
var _paused_by_card := false
var _current: Dictionary = {}
var _last_event_day := {}    # 事件 id → 上次出现的天数（冷却）

## 事件定义：era=最低时代；options 为可选行动（effects 由 apply_effects 解释）
const EVENTS: Array[Dictionary] = [
	{
		"id": "artisan", "era": 1, "title": "流浪工匠",
		"desc": "一位流浪工匠在村口徘徊，愿意用一双巧手换一口饭吃。",
		"options": [
			{"label": "收留他（+1 村民）", "effects": {"villager": 1}},
			{"label": "给他 3 食物作盘缠", "effects": {"food": -3}},
		],
	},
	{
		"id": "merchant", "era": 1, "title": "行商队",
		"desc": "一支行商队路过，愿意出 12 金买下 10 份食物。",
		"options": [
			{"label": "卖给他们（-10 食物，+12 金）", "effects": {"food": -10, "gold": 12}},
			{"label": "婉拒", "effects": {}},
		],
	},
	{
		"id": "feast", "era": 1, "title": "丰收的传闻",
		"desc": "村民们提议办一场丰收祭。欢宴能让所有人明天干劲十足。",
		"options": [
			{"label": "办宴（-6 食物，幸福 +10）", "effects": {"food": -6, "mood": 10}},
			{"label": "这次算了", "effects": {}},
		],
	},
	{
		"id": "rain", "era": 1, "title": "乌云压顶",
		"desc": "天色阴沉，看样子明天有暴雨——田野里的活计明天是干不成了。",
		"options": [
			{"label": "知道了（明日农田/渔屋停产）", "effects": {"rain_tomorrow": true}},
		],
	},
	{
		"id": "lost_sheep", "era": 2, "title": "走失的羊群",
		"desc": "几只走失的羊晃进了村子，在谷仓边咩咩直叫。",
		"options": [
			{"label": "留下剪毛（+4 羊毛）", "effects": {"wool": 4}},
			{"label": "宰了打牙祭（+4 食物）", "effects": {"food": 4}},
		],
	},
	{
		"id": "hunter", "era": 2, "title": "猎户来投",
		"desc": "一位猎户听说了这里的安居，想带着弓箭在村里定居。",
		"options": [
			{"label": "欢迎（+1 村民）", "effects": {"villager": 1}},
			{"label": "婉拒", "effects": {}},
		],
	},
]
const COOLDOWN_DAYS := 8

var _layer: CanvasLayer
var _dim: ColorRect
var _panel: PanelContainer
var _card_title: Label
var _card_desc: Label
var _options_box: VBoxContainer

func setup(p_game) -> void:
	game = p_game
	time = game.time_mgr
	rng.randomize()
	process_mode = Node.PROCESS_MODE_ALWAYS  # 事件卡在暂停状态下仍要能点
	_build_card()

## 每日调用（main._on_new_day）：士气递减 + 排期 + 弹卡
func on_new_day(era: int) -> void:
	if card_open or game.raid.raid_active or not game.is_game_started():
		return
	if rainy_day >= 0 and time.day > rainy_day:
		rainy_day = -1  # 暴雨日已过，清理标记
	if next_event_day < 0:
		next_event_day = time.day + rng.randi_range(2, 4)
		return
	if time.day < next_event_day:
		return
	next_event_day = time.day + rng.randi_range(2, 4)
	_try_open(era)

## 节日 buff 递减（main 在幸福度结算后调用）
func tick_mood() -> void:
	if mood_days_left > 0:
		mood_days_left -= 1
		if mood_days_left <= 0:
			mood_bonus = 0

func _try_open(era: int) -> void:
	var pool := []
	for e in EVENTS:
		if int(e.get("era", 1)) > era:
			continue
		if time.day - int(_last_event_day.get(e["id"], -99)) < COOLDOWN_DAYS:
			continue
		pool.append(e)
	if pool.is_empty():
		return
	var ev: Dictionary = pool[rng.randi_range(0, pool.size() - 1)]
	_last_event_day[ev["id"]] = time.day
	_open_card(ev)

## 事件效果统一解释器（play_test 也直接调它做断言）
func apply_effects(effects: Dictionary) -> void:
	var res: ResourceManager = game.resources
	if effects.has("villager"):
		for i in int(effects["villager"]):
			game.spawn_villager()
	if effects.has("food"):
		var n := int(effects["food"])
		if n >= 0:
			res.add(ResourceManager.Type.FOOD, n)
		elif not res.try_spend([[ResourceManager.Type.FOOD, -n]]):
			pass  # 食物不够：卖/办宴失败，无副作用（选项弹出前已尽量预判）
	if effects.has("gold"):
		res.add(ResourceManager.Type.GOLD, int(effects["gold"]))
	if effects.has("wool"):
		res.add(ResourceManager.Type.WOOL, int(effects["wool"]))
	if effects.has("mood"):
		mood_bonus = int(effects["mood"])
		mood_days_left = 1  # 当前日结算时生效，次日凌晨递减
	if effects.get("rain_tomorrow", false):
		rainy_day = time.day + 1

func _build_card() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 30  # 高于 HUD(1) 与主菜单(10)
	add_child(_layer)
	_dim = ColorRect.new()
	_dim.color = Color(0, 0, 0, 0.5)
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.visible = false
	_layer.add_child(_dim)
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.visible = false
	_layer.add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 10)
	box.custom_minimum_size = Vector2(380, 0)
	_panel.add_child(box)
	_card_title = Label.new()
	_card_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_card_title.add_theme_font_size_override(&"font_size", 24)
	_card_title.add_theme_color_override(&"font_color", Color(1.0, 0.9, 0.6))
	box.add_child(_card_title)
	_card_desc = Label.new()
	_card_desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_card_desc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_card_desc)
	_options_box = VBoxContainer.new()
	_options_box.add_theme_constant_override(&"separation", 8)
	box.add_child(_options_box)

func _open_card(ev: Dictionary) -> void:
	_current = ev
	card_open = true
	_card_title.text = ev["title"]
	_card_desc.text = ev["desc"]
	for child in _options_box.get_children():
		child.queue_free()
	for opt in ev["options"]:
		var btn := Button.new()
		btn.text = opt["label"]
		btn.pressed.connect(_choose.bind(opt))
		_options_box.add_child(btn)
	_dim.visible = true
	_panel.visible = true
	get_tree().paused = true  # 事件卡是模态：暂停等玩家选择（用户指定交互）

func _choose(opt: Dictionary) -> void:
	apply_effects(opt.get("effects", {}))
	_close_card()

func _close_card() -> void:
	_dim.visible = false
	_panel.visible = false
	card_open = false
	get_tree().paused = false
