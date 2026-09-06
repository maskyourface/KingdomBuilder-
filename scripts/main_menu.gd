extends CanvasLayer
class_name MainMenu

## 开始菜单：开始游戏 / 继续 / 读取（选存档）/ 设置（占位）/ 结束游戏。
## 游戏进行中按 ESC 也会打开本菜单。菜单打开时游戏暂停。
## 新开一局一定先经过「缔造新世界」面板（地图大小 / 地图类型 / 资源丰度 / 世界种子），
## 选项直接来自 WorldConfig 的三张静态表——那边加一条，这里自动多一个按钮。

var main = null  # Main（main.gd，脚本方法动态调用：start_or_continue / load_and_play 等）

var _menu_panel: PanelContainer
var _load_panel: PanelContainer
var _settings_panel: PanelContainer
var _save_list: VBoxContainer
var _start_btn: Button
var _new_btn: Button
var _resume_btn: Button
var _tomenu_btn: Button
var _status_label: Label

# 新世界面板
var _world_panel: PanelContainer
var _world_cfg: WorldConfig = WorldConfig.new()
var _opt_buttons := {}   # 板块 key → [ {btn, id}, ... ]
var _opt_descs := {}     # 板块 key → 该板块的说明 Label
var _seed_edit: LineEdit
var _world_summary: Label

func setup(p_main) -> void:
	# 游戏暂停时菜单仍要响应输入
	process_mode = Node.PROCESS_MODE_ALWAYS
	main = p_main
	_build_ui()

func _build_ui() -> void:
	layer = 10  # 画在游戏 HUD 之上

	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(root)

	# 中文字体：优先项目内置，其次系统字体（见 ui_font.gd）
	UiFont.apply(root)

	# 半透明黑色背景，挡住后面的游戏画面和鼠标点击
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.55)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	# ---- 主菜单面板 ----
	_menu_panel = PanelContainer.new()
	_menu_panel.set_anchors_preset(Control.PRESET_CENTER)
	_menu_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_menu_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	root.add_child(_menu_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 10)
	_menu_panel.add_child(box)

	var title := Label.new()
	title.text = "中世纪王国建设"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override(&"font_size", 36)
	box.add_child(title)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 20)
	box.add_child(gap)

	_start_btn = _make_button(box, "开始游戏", main.start_or_continue)
	_new_btn = _make_button(box, "新游戏", show_world_panel)
	_resume_btn = _make_button(box, "返回游戏", main.resume_play)
	_tomenu_btn = _make_button(box, "返回主菜单", main.return_to_menu)
	_make_button(box, "读取", show_load_panel)
	_make_button(box, "设置", _show_settings)
	_make_button(box, "结束游戏", main.quit_game)

	# 状态提示（读档失败等原因显示在这里）
	_status_label = Label.new()
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.add_theme_color_override(&"font_color", Color(1.0, 0.5, 0.4))
	box.add_child(_status_label)

	# ---- 读取面板（选择存档） ----
	_load_panel = PanelContainer.new()
	_load_panel.set_anchors_preset(Control.PRESET_CENTER)
	_load_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_load_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_load_panel.visible = false
	root.add_child(_load_panel)
	var load_box := VBoxContainer.new()
	load_box.add_theme_constant_override(&"separation", 8)
	_load_panel.add_child(load_box)
	var load_title := Label.new()
	load_title.text = "—— 选择存档 ——"
	load_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	load_box.add_child(load_title)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(380, 240)
	load_box.add_child(scroll)
	_save_list = VBoxContainer.new()
	_save_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_save_list)
	# 数据安全出口：自动存档被覆盖前总会留一份 .bak；走独立路径（不进存档列表）
	_make_button(load_box, "恢复上次自动存档备份", _on_restore_bak)
	_make_button(load_box, "返回", show_menu)

	# ---- 新世界面板（开局前的世界设置） ----
	_build_world_panel(root)

	# ---- 设置面板（占位） ----
	_settings_panel = PanelContainer.new()
	_settings_panel.set_anchors_preset(Control.PRESET_CENTER)
	_settings_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_settings_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_settings_panel.visible = false
	root.add_child(_settings_panel)
	var settings_box := VBoxContainer.new()
	settings_box.add_theme_constant_override(&"separation", 8)
	_settings_panel.add_child(settings_box)
	var settings_label := Label.new()
	settings_label.text = "设置功能暂未开放，敬请期待"
	settings_box.add_child(settings_label)
	_make_button(settings_box, "返回", show_menu)

func _make_button(parent: Control, text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(220, 40)
	b.pressed.connect(action)
	parent.add_child(b)
	return b

# ---------- 面板切换 ----------

## 菜单打开时游戏已暂停，main 收不到输入，ESC 由这里处理（process_mode=ALWAYS）
func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.keycode != KEY_ESCAPE or key.echo:
		return
	if not visible:
		return
	if _load_panel.visible or _settings_panel.visible or _world_panel.visible:
		show_menu()  # 子面板先退回主面板
	elif main.is_game_started():
		main.resume_play()

## 在主菜单底部显示一条提示（如读档失败原因）
func set_status(text: String) -> void:
	_status_label.text = text

func show_menu() -> void:
	visible = true
	_menu_panel.visible = true
	_load_panel.visible = false
	_settings_panel.visible = false
	_world_panel.visible = false
	_status_label.text = ""
	var started: bool = main.is_game_started()
	# 游戏进行中：显示「返回游戏」「返回主菜单」，隐藏主按钮
	# 未开始：主按钮按有无存档显示「继续游戏」或「开始游戏」，有存档时另给「新游戏」
	_resume_btn.visible = started
	_tomenu_btn.visible = started
	_start_btn.visible = not started
	_new_btn.visible = not started and not main.get_save_list().is_empty()
	if not started:
		_start_btn.text = "继续游戏" if not main.get_save_list().is_empty() else "开始游戏"

func show_load_panel() -> void:
	_menu_panel.visible = false
	_settings_panel.visible = false
	_world_panel.visible = false
	_load_panel.visible = true
	_refresh_save_list()

## 打开「缔造新世界」面板（主菜单的新游戏、以及无存档时的开始游戏都走这里）
func show_world_panel() -> void:
	visible = true
	_menu_panel.visible = false
	_settings_panel.visible = false
	_load_panel.visible = false
	_world_panel.visible = true
	_refresh_world_panel()

func _show_settings() -> void:
	_menu_panel.visible = false
	_load_panel.visible = false
	_world_panel.visible = false
	_settings_panel.visible = true

# ---------- 存档列表 ----------

func _refresh_save_list() -> void:
	for child in _save_list.get_children():
		child.queue_free()
	var saves: Array = main.get_save_list()
	if saves.is_empty():
		var empty := Label.new()
		empty.text = "暂无存档"
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_save_list.add_child(empty)
		return
	for s in saves:
		var row := HBoxContainer.new()
		row.add_theme_constant_override(&"separation", 8)
		_save_list.add_child(row)
		var label := Label.new()
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var ver: int = int(s.get("version", 0))  # 缺 version 的坏档按不兼容处理
		var stale := ver != 5
		label.text = "%s｜第%d天｜人口%d%s\n%s" % [
			str(s["name"]).trim_suffix(".json"), s["day"], s["pop"],
			"（版本不兼容）" if stale else "",
			Time.get_datetime_string_from_unix_time(s["time"]),
		]
		row.add_child(label)
		var load_btn := Button.new()
		load_btn.text = "读取"
		load_btn.pressed.connect(main.load_and_play.bind(s["path"]))
		load_btn.disabled = stale
		row.add_child(load_btn)
		var del_btn := Button.new()
		del_btn.text = "删除"
		del_btn.pressed.connect(_on_delete_save.bind(s["path"]))
		row.add_child(del_btn)

func _on_delete_save(path: String) -> void:
	main.delete_save(path)
	_refresh_save_list()

## 恢复上次自动存档备份（autosave.json 被覆盖前的旧档）。
## 直调 load_and_play，绕开 open_load_menu 的保护性自动存档；
## 坏档/缺文件由 load_game 的版本与结构预校验拒绝并在状态行提示
func _on_restore_bak() -> void:
	var bak: String = main.save_dir + "autosave.bak.json"
	if not FileAccess.file_exists(bak):
		set_status("还没有可用的自动存档备份")
		show_menu()  # 状态行挂在主面板，退回去才可见
		return
	main.load_and_play(bak)

# ---------- 缔造新世界 ----------

## 面板结构：三个选项板块（大小/类型/丰度）+ 世界种子 + 摘要行。
## 每个板块一行按钮 + 一行说明；按钮由 WorldConfig 的静态表生成，
## 所以给 WorldConfig 加一种地形，这里不用改一行代码。
func _build_world_panel(root: Control) -> void:
	_world_panel = PanelContainer.new()
	_world_panel.set_anchors_preset(Control.PRESET_CENTER)
	_world_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_world_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_world_panel.visible = false
	root.add_child(_world_panel)

	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 6)
	box.custom_minimum_size = Vector2(560, 0)
	_world_panel.add_child(box)

	var title := Label.new()
	title.text = "—— 缔造新世界 ——"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override(&"font_size", 24)
	box.add_child(title)

	_build_option_block(box, "size", "地图大小", WorldConfig.SIZES)
	_build_option_block(box, "terrain", "地图类型", WorldConfig.TERRAINS)
	_build_option_block(box, "richness", "资源丰度", WorldConfig.RICHNESS)

	# 世界种子：留空/填 0 = 每局随机；填同一个数字必得同一张地图
	var seed_row := HBoxContainer.new()
	seed_row.add_theme_constant_override(&"separation", 8)
	box.add_child(seed_row)
	var seed_title := Label.new()
	seed_title.text = "世界种子"
	seed_title.custom_minimum_size = Vector2(80, 0)
	seed_row.add_child(seed_title)
	_seed_edit = LineEdit.new()
	_seed_edit.placeholder_text = "留空 = 随机；填同一个数字必得同一张地图"
	_seed_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_seed_edit.text_changed.connect(_on_seed_changed)
	seed_row.add_child(_seed_edit)
	var dice := Button.new()
	dice.text = "随机"
	dice.pressed.connect(_on_roll_seed)
	seed_row.add_child(dice)

	_world_summary = Label.new()
	_world_summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_world_summary.add_theme_color_override(&"font_color", Color(0.8, 0.9, 0.7))
	box.add_child(_world_summary)

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override(&"separation", 10)
	actions.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(actions)
	_make_button(actions, "开始建国", _on_start_world)
	_make_button(actions, "返回", show_menu)

## 一个选项板块：标题 + 一排按钮 + 一行当前选项的说明
func _build_option_block(parent: Control, key: String, title_text: String,
		table: Array[Dictionary]) -> void:
	var head := Label.new()
	head.text = title_text
	head.add_theme_color_override(&"font_color", Color(0.85, 0.85, 0.95))
	parent.add_child(head)

	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 6)
	parent.add_child(row)
	var entries: Array = []
	for d in table:
		var b := Button.new()
		b.text = String(d["name"])
		b.custom_minimum_size = Vector2(120, 34)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.pressed.connect(_on_option_picked.bind(key, d["id"]))
		row.add_child(b)
		entries.append({"btn": b, "id": d["id"]})
	_opt_buttons[key] = entries

	var desc := Label.new()
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(540, 34)
	desc.add_theme_color_override(&"font_color", Color(0.75, 0.75, 0.75))
	parent.add_child(desc)
	_opt_descs[key] = desc

func _on_option_picked(key: String, id: StringName) -> void:
	match key:
		"size":
			_world_cfg.size_id = id
		"terrain":
			_world_cfg.terrain_id = id
		_:
			_world_cfg.richness_id = id
	_refresh_world_panel()

func _on_seed_changed(text: String) -> void:
	# 非数字一律当 0（= 随机），不弹错误打断填写
	_world_cfg.world_seed = int(text.strip_edges()) if text.strip_edges().is_valid_int() else 0
	_refresh_summary()

func _on_roll_seed() -> void:
	_world_cfg.world_seed = randi_range(1, 999999)
	_seed_edit.text = str(_world_cfg.world_seed)
	_refresh_summary()

func _on_start_world() -> void:
	visible = false
	main.new_game(_world_cfg)

## 刷新选中态高亮与三行说明（选项一变就调，唯一的显示口径）
func _refresh_world_panel() -> void:
	_refresh_block("size", _world_cfg.size_id, _world_cfg.size_data())
	_refresh_block("terrain", _world_cfg.terrain_id, _world_cfg.terrain_data())
	_refresh_block("richness", _world_cfg.richness_id, _world_cfg.richness_data())
	_refresh_summary()

func _refresh_block(key: String, current: StringName, data: Dictionary) -> void:
	for e in _opt_buttons.get(key, []):
		var b: Button = e["btn"]
		var picked: bool = e["id"] == current
		b.modulate = Color(1.0, 0.95, 0.6) if picked else Color(0.75, 0.75, 0.75)
	var desc: Label = _opt_descs[key]
	desc.text = String(data.get("desc", ""))

func _refresh_summary() -> void:
	var seed_text := "随机" if _world_cfg.world_seed == 0 else str(_world_cfg.world_seed)
	_world_summary.text = "%s　│　%d×%d 格　│　种子 %s" % [
		_world_cfg.summary(), _world_cfg.map_width(), _world_cfg.map_height(), seed_text]
