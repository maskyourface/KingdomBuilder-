extends Node
class_name EventManager
## 随机事件系统（时代Ⅰ起）：商队/节日/暴雨/流浪者……给前期每天一个决策点。
## 事件卡弹出即暂停（选完恢复），与袭击、菜单、覆灭面板互斥（已暂停时绝不弹卡）。
## game 为主控 main.gd，无类型注入（照 raid_manager 模式，避免 class_name 循环依赖）。

var game = null
var time: TimeManager = null
var rng := RandomNumberGenerator.new()

var next_event_day := -1     # 下一次事件可能发生的天数（-1 = 未排期）
## 天灾停产：halt_day 当天，halt_ids 里的建筑 id 全部停产（main 负责置位到 Building）。
## 从"只有暴雨停农田"泛化成"任何事件都能点名停任何建筑"，山崩/寒潮才写得出来。
var halt_day := -1
var halt_ids: Array = []
var halt_reason := ""        # 详情面板停产行显示的原因（"暴雨"/"山崩"…）
var mood_bonus := 0          # 节日等事件的全体幸福加成
var mood_days_left := 0
var card_open := false       # 事件卡是否正在显示
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
	{
		"id": "wolves", "era": 1, "title": "夜半狼嚎",
		"desc": "夜里传来狼嚎，田边和栏圈外留下一圈踩踏的脚印。今晚要不要点起火把？",
		"options": [
			{"label": "点火把守夜（−3 木材）", "effects": {"wood": -3}},
			{"label": "不管它们（可能丢粮）", "effects": {"lose": {"food": 8}}},
		],
	},
	{
		"id": "granary_pest", "era": 1, "title": "粮堆生虫",
		"desc": "存粮的角落起了虫。老人说得换新桶，不然这一堆迟早全烂。",
		"options": [
			{"label": "打新桶重装（−3 木材）", "effects": {"wood": -3}},
			{"label": "将就着吃", "effects": {"lose": {"food": 6}, "mood": -4}},
		],
	},
	{
		"id": "cold_snap", "era": 1, "title": "寒潮南下",
		"desc": "北风比往年来得早。明天要么让大家窝在屋里，要么顶着风照常出工。",
		"options": [
			{"label": "让大家躲进屋（明日采集/麦田停产）",
				"effects": {"halt": {"ids": ["gatherer", "farm"], "reason": "寒潮"}}},
			{"label": "照常出工（全体幸福 −6）", "effects": {"mood": -6}},
		],
	},
	{
		"id": "stonecutter", "era": 1, "title": "路过的石匠",
		"desc": "一位石匠推着独轮车路过，车上是他凿好的石料，只想换点干粮上路。",
		"options": [
			{"label": "换他的石料（−5 食物，+4 石料）", "effects": {"food": -5, "stone": 4}},
			{"label": "婉拒", "effects": {}},
		],
	},
	{
		"id": "settlers", "era": 1, "title": "拓荒者营地",
		"desc": "几个拓荒者在河湾扎了营，说再往北走就撑不住了，愿意留下工具换口粮。",
		"options": [
			{"label": "接济他们（−6 食物，+8 木材 +2 石料）",
				"effects": {"food": -6, "wood": 8, "stone": 2}},
			{"label": "送他们上路", "effects": {}},
		],
	},
	{
		"id": "rockslide", "era": 2, "title": "山崩",
		"desc": "山道上塌下一片碎石，采石的路被堵住了。",
		"options": [
			{"label": "组织人手清理（−6 木材）", "effects": {"wood": -6}},
			{"label": "先绕开（明日采石场停产）",
				"effects": {"halt": {"ids": ["quarry"], "reason": "山崩"}}},
		],
	},
]
const COOLDOWN_DAYS := 8

## 这张事件卡点名停产的建筑，村里到底有没有？一座都没有就别弹（零效果浪费玩家一次暂停）
func _halt_targets_exist(e: Dictionary) -> bool:
	for opt in e.get("options", []):
		var fx: Dictionary = opt.get("effects", {})
		var ids: Array = []
		if fx.has("halt"):
			ids = fx["halt"].get("ids", [])
		elif fx.get("rain_tomorrow", false):
			ids = ["farm"]
		if ids.is_empty():
			continue  # 这个选项不停产，不构成"零效果"
		var found := false
		for bid in ids:
			if game._count_building(String(bid)) > 0:
				found = true
		if not found:
			return false
	return true

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
	if halt_day >= 0 and time.day > halt_day:
		halt_day = -1   # 停产日已过，清理标记
		halt_ids = []
		halt_reason = ""
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

## 跨局状态清零：新开局/读档必须调用，否则上局的暴雨排期、节日 buff、
## 事件冷却会变成"幽灵状态"污染新的一局
func reset() -> void:
	next_event_day = -1
	halt_day = -1
	halt_ids = []
	halt_reason = ""
	mood_bonus = 0
	mood_days_left = 0
	_last_event_day.clear()
	card_open = false

func _try_open(era: int) -> void:
	var pool := []
	for e in EVENTS:
		if int(e.get("era", 1)) > era:
			continue
		if not _halt_targets_exist(e):
			continue  # 点名停产的建筑一座都没有 → 这张卡是零效果浪费，不弹
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
		if int(effects[k]) < 0 and k in ["food", "gold", "wood", "stone", "wool",
				"clothes", "beer", "bread", "wheat", "flour"]:
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
	# lose：惩罚类扣除，有多少扣多少（不像负向资源那样"买不起就整单放弃"，
	# 否则"不管它们"这种恶果选项会因为穷而变成免费午餐）
	var lose: Dictionary = effects.get("lose", {})
	for k in lose:
		var lt := _resource_type(String(k))
		if lt < 0:
			continue
		res.try_spend([[lt, mini(int(lose[k]), res.get_amount(lt))]])
	if effects.has("halt"):
		var h: Dictionary = effects["halt"]
		halt_day = time.day + 1
		halt_ids = h.get("ids", [])
		halt_reason = String(h.get("reason", "天灾"))
	if effects.get("rain_tomorrow", false):
		halt_day = time.day + 1
		halt_ids = ["farm"]
		halt_reason = "暴雨"
	return true

func _resource_type(name: String) -> int:
	match name:
		"food": return ResourceManager.Type.FOOD
		"bread": return ResourceManager.Type.BREAD
		"wheat": return ResourceManager.Type.WHEAT
		"flour": return ResourceManager.Type.FLOUR
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
			if k == "lose" or k == "halt":
				continue  # 惩罚/停产是后果不是花费，不参与"买不买得起"的置灰
			if int(fx[k]) < 0:
				var rt := _resource_type(String(k))
				if rt >= 0 and game.resources.get_amount(rt) < -int(fx[k]):
					btn.disabled = true
					btn.text += "（资源不足）"
		btn.pressed.connect(_choose.bind(opt))
		_options_box.add_child(btn)
	# 兜底：事件卡是模态暂停的，若所有选项都因资源/住房不足被置灰，游戏就卡死了。
	# 这里补一个永远可选的退路，保证任何局面下都点得出去。
	var any_enabled := false
	for btn in _options_box.get_children():
		if not btn.disabled:
			any_enabled = true
	if not any_enabled:
		var fallback := Button.new()
		fallback.text = "无能为力，听天由命"
		fallback.pressed.connect(_choose.bind({"label": "听天由命", "effects": {}}))
		_options_box.add_child(fallback)
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
