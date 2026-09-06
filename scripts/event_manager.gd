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
var _current: Dictionary = {}
var _last_event_day := {}    # 事件 id → 上次出现的天数（冷却）

## 事件定义：era=最低时代；options 为可选行动（effects 由 apply_effects 解释）
const EVENTS: Array[Dictionary] = [
	{
		"id": "snow_aid", "era": 1, "winter": true, "title": "雪中送炭",
		"desc": "风雪里，邻村的猎人送来了一批过冬的口粮。",
		"options": [{"label": "收下（+6 食物）", "effects": {"food": 6}}]},
	{
		"id": "artisan", "era": 1, "title": "流浪工匠",
		"desc": "一位流浪工匠在村口徘徊，愿意用一双巧手换一口饭吃。",
		"options": [
			{"label": "收留他（+1 村民）", "effects": {"villager": 1}},
			{"label": "给他 3 食物作盘缠（次日幸福 +2）", "effects": {"food": -3, "mood": 2}},
		],
	},
	{
		"id": "merchant", "era": 2, "title": "行商队",
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
	if game.villagers_root.get_child_count() == 0:
		return  # 空国不弹事件（覆灭面板才是正主）
	if rainy_day >= 0 and time.day > rainy_day:
		rainy_day = -1  # 暴雨日已过，清理标记
	if next_event_day < 0:
		# 首张事件卡推迟到第 6 天之后，不与六步引导抢注意力
		next_event_day = time.day + rng.randi_range(2, 4) + (4 if time.day <= 4 else 0)
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

## 跨局状态清零：新开局/读档必须调用，否则上局的暴雨排期、节日 buff、
## 事件冷却会变成"幽灵状态"污染新的一局
func reset() -> void:
	next_event_day = -1
	rainy_day = -1
	mood_bonus = 0
	mood_days_left = 0
	_last_event_day.clear()
	card_open = false

func _try_open(era: int) -> void:
	var pool := []
	for e in EVENTS:
		if int(e.get("era", 1)) > era:
			continue
		if bool(e.get("winter", false)) != time.is_winter():
			continue  # 雪中送炭只在冬季，其余不在冬季（与袭击的冬季休战互补）
		if e["id"] == "rain" and game._count_building("farm") == 0 				and game._count_building("fisher") == 0:
			continue  # 没有可停产的建筑，暴雨卡是零效果浪费
		if time.day - int(_last_event_day.get(e["id"], -99)) < COOLDOWN_DAYS:
			continue
		pool.append(e)
	if pool.is_empty():
		return
	var ev: Dictionary = pool[rng.randi_range(0, pool.size() - 1)]
	_last_event_day[ev["id"]] = time.day
	_open_card(ev)

## 事件效果统一解释器（play_test 也直接调它做断言）。
## 原子性：先一次性预扣所有负向资源，任一不足则整单放弃（绝不白给正向效果）
func apply_effects(effects: Dictionary) -> bool:
	var res: ResourceManager = game.resources
	var costs: Array = []
	for k in effects:
		if int(effects[k]) < 0 and k in ["food", "gold", "wood", "stone", "wool", "clothes", "beer"]:
			costs.append([_resource_type(k), -int(effects[k])])
	if not costs.is_empty() and not res.has_all(costs):
		return false
	if not res.try_spend(costs):
		return false
	if effects.has("villager"):
		for i in int(effects["villager"]):
			game.spawn_villager()
		game.reassign_homes()  # 有空房即刻入住，不吃"无房 -30"的第一晚
	for k in effects:
		var n := int(effects[k])
		if n <= 0:
			continue
		match k:
			"food": res.add(ResourceManager.Type.FOOD, n)
			"gold": res.add(ResourceManager.Type.GOLD, n)
			"wool": res.add(ResourceManager.Type.WOOL, n)
			"wood": res.add(ResourceManager.Type.WOOD, n)
			"stone": res.add(ResourceManager.Type.STONE, n)
			"clothes": res.add(ResourceManager.Type.CLOTHES, n)
			"beer": res.add(ResourceManager.Type.BEER, n)
	if effects.has("mood"):
		mood_bonus = int(effects["mood"])
		mood_days_left = 1
	if effects.get("rain_tomorrow", false):
		rainy_day = time.day + 1
	return true

func _resource_type(name: String) -> int:
	match name:
		"food": return ResourceManager.Type.FOOD
		"gold": return ResourceManager.Type.GOLD
		"wood": return ResourceManager.Type.WOOD
		"stone": return ResourceManager.Type.STONE
		"wool": return ResourceManager.Type.WOOL
		"clothes": return ResourceManager.Type.CLOTHES
		"beer": return ResourceManager.Type.BEER
	return -1

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
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
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
	var pop: int = game.villagers_root.get_child_count()
	var has_room: bool = game._housing_capacity() > pop
	for opt in ev["options"]:
		var btn := Button.new()
		var fx: Dictionary = opt.get("effects", {})
		btn.text = opt["label"]
		# 收留类选项需要住房空位（否则新村民无房 -30，还会压垮幸福均值）
		if fx.has("villager") and not has_room:
			btn.disabled = true
			btn.text += "（需住房空位）"
		# 负向资源买不起的选项同样置灰
		for k in fx:
			if int(fx[k]) < 0:
				var rt := _resource_type(k)
				if rt >= 0 and game.resources.get_amount(rt) < -int(fx[k]):
					btn.disabled = true
					btn.text += "（资源不足）"
		btn.pressed.connect(_choose.bind(opt))
		_options_box.add_child(btn)
	_dim.visible = true
	_panel.visible = true
	get_tree().paused = true  # 事件卡是模态：暂停等玩家选择（用户指定交互）

func _choose(opt: Dictionary) -> void:
	if not apply_effects(opt.get("effects", {})):
		hud_toast("资源不足，无法执行该选择")
		return
	hud_toast("「%s」：%s（已生效）" % [_current["title"], opt["label"]], 4.0)
	_close_card()

## 事件卡没有 game.hud 的直接引用，经 main 转发 toast
func hud_toast(text: String, seconds := 4.0) -> void:
	if game != null and game.hud != null:
		game.hud.show_toast(text, seconds)

func _close_card() -> void:
	_dim.visible = false
	_panel.visible = false
	card_open = false
	game._panning = false  # 暂停期间松开的中键事件被吞，防平移卡死
	get_tree().paused = false
