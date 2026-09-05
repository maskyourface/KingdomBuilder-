extends CanvasLayer
class_name HUD

## 界面：顶部资源栏、可开关的建造大菜单、村民列表、建筑/村民详情面板。
## 全部代码创建，不需要在编辑器里摆控件。

var resources: ResourceManager
var time_mgr: TimeManager
var placer: BuildingPlacer
var main = null           # Main（main.gd，脚本方法动态调用：save_game / assign_worker / current_era 等）
var villagers_root: Node2D
var raid = null           # RaidManager：渲染袭击横幅（main 注入）

var _resource_label: Label
var _time_label: Label
var _pop_btn: Button            # 点击循环定位空闲村民
var _era_label: Label
var _hap_label: Label

# 建造菜单
var _build_panel: PanelContainer
var _build_buttons: Array = []  # [ {btn, data}, ... ] 用于时代锁定刷新
var _build_refresh := 0.0

# 横幅（袭击状态）与 toast（临时通知，最多 3 条堆叠）
var _banner_panel: PanelContainer
var _banner_label: Label
var _toasts: Array = []  # [{label:Label, panel:PanelContainer, timer:float}]
var _toast_box: VBoxContainer
var _last_era := 0
var _hap_bad := false          # 幸福度红色预警当前状态（变化才改主题色）
var _last_day := -1            # 时间字符串缓存基准（换天/换季/倍速变化才重建）
var _last_season := -1
var _last_time_scale := 1.0    # ×N 徽标随 Space 即时刷新用
var _res_dirty := true         # resources.changed 只置脏，每帧最多重建一次资源栏字符串

# 新手引导（四步；第 4 步要等伐木场攒木头：39 木支出 > 开局 30 木，文案已说明）
const GUIDE_STEPS: Array[String] = [
	"第 1 步：开「建造菜单」放采集小屋（贴着紫红色的浆果丛），解决吃饭",
	"第 2 步：放伐木场（贴着深绿的森林），木材是建造货币",
	"第 3 步：选小屋按住左键拖动连放 3 座——移民要有房才来（右上幸福度会回涨）",
	"第 4 步：攒够木 10 后建植树场让森林循环再生（另外开一块麦田；按空格 ×4 等伐木场出货）",
	"第 5 步：放渔屋（贴着蓝色的水域）——食物第二条产线，冬天也不停",
	"第 6 步：建一口水井（木3 石2）放在住房旁边，周围住户幸福 +5",
]
# 建造菜单分组（红警式分类 Tab）
const BUILD_GROUP_NAMES := {
	"food": "食物", "resource": "资源", "life": "民生", "produce": "生产", "defense": "防御",
}
var _current_tab := "food"
var _grids := {}
var _tab_buttons := {}

var _guide_panel: PanelContainer
var _guide_title: Label
var _guide_body: Label
var _guide_step := -1

# 覆灭面板（王国覆灭时的唯一出口）
var _log_panel: PanelContainer
var _log_list: Label
var _log_lines: Array[String] = []
var _log_visible := false
var _collapse_panel: PanelContainer
var _collapse_dim: ColorRect

# 建筑详情
var _details_panel: PanelContainer
var _details_title: Label
var _details_info: Label
var _details_progress: ProgressBar
var _status_label: Label
var _worker_label: Label
var _housing_label: Label
var _sale_label: Label
var _current_building = null

# 村民列表 + 村民详情
var _villager_panel: PanelContainer
var _villager_list: VBoxContainer
var _list_buttons: Array = []   # 与「筛选+排序后」的村民一一对应（非全体）
var _filter_idle := false       # 筛选：只看空闲（无工作）
var _filter_homeless := false   # 筛选：只看无房（home 为空或已失效）
var _sort_mode := 0             # 排序：0=默认 1=按名字 2=按饥饿降序
var _list_sig := ""             # 列表 uid 签名（含顺序）：与当前集合不一致才重建
var _vlist_title: Label         # 标题行（附加"显示 M/共 N"）
var _filter_idle_cb: CheckButton
var _filter_homeless_cb: CheckButton
var _sort_btn: Button
var _vdetail_panel: PanelContainer
var _vd_title: Label
var _vd_state: Label
var _vd_hunger: ProgressBar
var _vd_work: Label
var _vd_home: Label
var _current_villager: Villager = null

func setup(p_resources: ResourceManager, p_time: TimeManager, p_placer: BuildingPlacer,
		p_main, p_villagers_root: Node2D, p_raid = null) -> void:
	resources = p_resources
	time_mgr = p_time
	placer = p_placer
	main = p_main
	villagers_root = p_villagers_root
	raid = p_raid
	_build_ui()
	resources.changed.connect(_mark_resources_dirty)
	_mark_resources_dirty()

func _build_ui() -> void:
	# CanvasLayer 本身没有 theme，需要一个 Control 根节点承载主题和控件
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	# 中文字体：优先项目内置，其次系统字体（见 ui_font.gd）
	UiFont.apply(root)

	# ---- 顶部栏（两行：状态+按钮 / 资源栏，避免 720p 下按钮被挤出屏幕） ----
	var top := PanelContainer.new()
	top.set_anchors_preset(Control.PRESET_TOP_WIDE)
	root.add_child(top)
	var top_col := VBoxContainer.new()
	top_col.add_theme_constant_override(&"separation", 2)
	top.add_child(top_col)
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override(&"separation", 10)  # 顶栏最坏组合接近 1280，间距收紧
	top_col.add_child(top_row)

	_time_label = Label.new()
	top_row.add_child(_time_label)
	_era_label = Label.new()
	_era_label.clip_text = true
	_era_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_era_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL  # 最坏文案 1329px>1280 的兜底
	top_row.add_child(_era_label)
	_pop_btn = Button.new()
	_pop_btn.flat = true
	_pop_btn.focus_mode = Control.FOCUS_NONE
	_pop_btn.pressed.connect(main.focus_next_idle)
	top_row.add_child(_pop_btn)
	_hap_label = Label.new()
	top_row.add_child(_hap_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top_row.add_child(spacer)

	var build_toggle := Button.new()
	build_toggle.text = "建造菜单"
	build_toggle.pressed.connect(_toggle_build_menu)
	top_row.add_child(build_toggle)
	var villager_toggle := Button.new()
	villager_toggle.text = "村民列表"
	villager_toggle.pressed.connect(_toggle_villager_panel)
	top_row.add_child(villager_toggle)
	var log_btn := Button.new()
	log_btn.text = "日志"
	log_btn.pressed.connect(_toggle_log_panel)
	top_row.add_child(log_btn)
	var fill_btn := Button.new()
	fill_btn.text = "招满"
	fill_btn.pressed.connect(main.assign_all_workers)
	top_row.add_child(fill_btn)
	var save_btn := Button.new()
	save_btn.text = "保存"
	save_btn.pressed.connect(main.save_game)
	top_row.add_child(save_btn)
	var load_btn := Button.new()
	load_btn.text = "读取"
	load_btn.pressed.connect(main.open_load_menu)
	top_row.add_child(load_btn)

	var res_row := HBoxContainer.new()
	res_row.add_theme_constant_override(&"separation", 16)
	top_col.add_child(res_row)
	_resource_label = Label.new()
	res_row.add_child(_resource_label)

	# ---- 袭击横幅（顶栏下方居中，常驻直到 raid 清空 banner_text） ----
	_banner_panel = PanelContainer.new()
	_banner_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_banner_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_banner_panel.offset_top = 66.0
	_banner_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE  # 别挡住下方的地图点击
	_banner_panel.visible = false
	root.add_child(_banner_panel)
	_banner_label = Label.new()
	_banner_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner_label.add_theme_color_override(&"font_color", Color(1.0, 0.5, 0.4))
	_banner_label.add_theme_font_size_override(&"font_size", 18)
	_banner_panel.add_child(_banner_label)

	# ---- 临时通知 toast 容器（横幅下方居中，最多 3 条堆叠，逐条倒计时自动消失） ----
	_toast_box = VBoxContainer.new()
	_toast_box.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast_box.offset_top = 112.0
	_toast_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_toast_box)

	# ---- 建造大菜单（左侧，默认隐藏；带滚动，20 个条目不会被 720p 裁掉） ----
	_build_panel = PanelContainer.new()
	_build_panel.set_anchors_preset(Control.PRESET_CENTER_LEFT)
	_build_panel.offset_left = 12
	_build_panel.offset_top = -235
	_build_panel.offset_bottom = 235
	_build_panel.visible = false
	root.add_child(_build_panel)
	var menu_box := VBoxContainer.new()
	menu_box.add_theme_constant_override(&"separation", 8)
	_build_panel.add_child(menu_box)
	var menu_title := Label.new()
	menu_title.text = "—— 建造 ——"
	menu_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	menu_box.add_child(menu_title)
	var build_scroll := ScrollContainer.new()
	build_scroll.custom_minimum_size = Vector2(272, 400)
	build_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	menu_box.add_child(build_scroll)
	# 红警式分组：顶部分类 Tab，一次只显示一组建筑
	var tab_row := HBoxContainer.new()
	tab_row.add_theme_constant_override(&"separation", 4)
	menu_box.add_child(tab_row)
	var groups_box := VBoxContainer.new()
	groups_box.add_theme_constant_override(&"separation", 6)
	build_scroll.add_child(groups_box)
	for g in BUILD_GROUP_NAMES:
		var tab_btn := Button.new()
		tab_btn.text = BUILD_GROUP_NAMES[g]
		tab_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tab_btn.focus_mode = Control.FOCUS_NONE
		tab_btn.pressed.connect(_switch_tab.bind(g))
		tab_row.add_child(tab_btn)
		_tab_buttons[g] = tab_btn
		var g_grid := GridContainer.new()
		g_grid.columns = 2
		g_grid.add_theme_constant_override(&"h_separation", 6)
		g_grid.add_theme_constant_override(&"v_separation", 6)
		groups_box.add_child(g_grid)
		_grids[g] = g_grid
	for data in BuildingCatalog.ALL:
		var btn := Button.new()
		btn.custom_minimum_size = Vector2(120, 48)
		btn.pressed.connect(_on_build_button.bind(data))
		_grids[data.get("group", "produce")].add_child(btn)
		_build_buttons.append({"btn": btn, "data": data})
	_apply_tab_style()
	_refresh_build_buttons()

	# ---- 村民列表（左下，bottom 钉在底部提示条上方，默认隐藏） ----
	_villager_panel = PanelContainer.new()
	_villager_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_villager_panel.offset_left = 12
	_villager_panel.offset_top = -360
	_villager_panel.offset_bottom = -32
	_villager_panel.visible = false
	root.add_child(_villager_panel)
	var vlist_box := VBoxContainer.new()
	_villager_panel.add_child(vlist_box)
	_vlist_title = Label.new()
	_vlist_title.text = "—— 村民 ——"
	_vlist_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vlist_box.add_child(_vlist_title)
	# 筛选/排序行：CheckButton 切过滤、Button 循环排序；变化即失效签名强制重建
	var filter_row := HBoxContainer.new()
	filter_row.add_theme_constant_override(&"separation", 4)
	vlist_box.add_child(filter_row)
	_filter_idle_cb = CheckButton.new()
	_filter_idle_cb.text = "只看空闲"
	_filter_idle_cb.focus_mode = Control.FOCUS_NONE
	_filter_idle_cb.toggled.connect(_on_filter_idle_toggled)
	filter_row.add_child(_filter_idle_cb)
	_filter_homeless_cb = CheckButton.new()
	_filter_homeless_cb.text = "只看无房"
	_filter_homeless_cb.focus_mode = Control.FOCUS_NONE
	_filter_homeless_cb.toggled.connect(_on_filter_homeless_toggled)
	filter_row.add_child(_filter_homeless_cb)
	_sort_btn = Button.new()
	_sort_btn.text = "排序：默认"
	_sort_btn.focus_mode = Control.FOCUS_NONE
	_sort_btn.pressed.connect(_on_sort_pressed)
	filter_row.add_child(_sort_btn)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(260, 230)
	vlist_box.add_child(scroll)
	_villager_list = VBoxContainer.new()
	_villager_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_villager_list)

	# ---- 建筑详情面板（右侧，默认隐藏） ----
	_details_panel = PanelContainer.new()
	_details_panel.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	_details_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_details_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_details_panel.offset_left = -200
	_details_panel.offset_right = -12
	_details_panel.offset_top = -140
	_details_panel.offset_bottom = 140
	_details_panel.visible = false
	root.add_child(_details_panel)
	var detail_box := VBoxContainer.new()
	detail_box.add_theme_constant_override(&"separation", 6)
	_details_panel.add_child(detail_box)

	_details_title = Label.new()
	_details_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	detail_box.add_child(_details_title)
	_details_info = Label.new()
	_details_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_box.add_child(_details_info)
	_details_progress = ProgressBar.new()
	_details_progress.max_value = 100.0
	_details_progress.show_percentage = false
	detail_box.add_child(_details_progress)

	# 停工原因（缺原料/缺工人/冬季）——只在实际停工时显示
	_status_label = Label.new()
	_status_label.add_theme_color_override(&"font_color", Color(1.0, 0.6, 0.3))
	_status_label.visible = false
	detail_box.add_child(_status_label)

	var worker_row := HBoxContainer.new()
	worker_row.alignment = BoxContainer.ALIGNMENT_CENTER
	detail_box.add_child(worker_row)
	var minus_btn := Button.new()
	minus_btn.text = "−"
	minus_btn.pressed.connect(_on_unassign_worker)
	worker_row.add_child(minus_btn)
	_worker_label = Label.new()
	worker_row.add_child(_worker_label)
	var plus_btn := Button.new()
	plus_btn.text = "＋"
	plus_btn.pressed.connect(_on_assign_worker)
	worker_row.add_child(plus_btn)

	_housing_label = Label.new()
	detail_box.add_child(_housing_label)

	# 市场昨日成交战报（只对市场显示）
	_sale_label = Label.new()
	_sale_label.visible = false
	detail_box.add_child(_sale_label)

	var demolish_btn := Button.new()
	demolish_btn.text = "拆除（退一半造价）"
	demolish_btn.pressed.connect(_on_demolish_current)
	detail_box.add_child(demolish_btn)
	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.pressed.connect(main.clear_building_inspect)  # 关闭同时清掉工作区域圈
	detail_box.add_child(close_btn)

	# ---- 村民详情面板（右侧，与建筑详情同位置、互斥显示） ----
	_vdetail_panel = PanelContainer.new()
	_vdetail_panel.set_anchors_preset(Control.PRESET_CENTER_RIGHT)
	_vdetail_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_vdetail_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_vdetail_panel.offset_left = -200
	_vdetail_panel.offset_right = -12
	_vdetail_panel.offset_top = -140
	_vdetail_panel.offset_bottom = 140
	_vdetail_panel.visible = false
	root.add_child(_vdetail_panel)
	var vd_box := VBoxContainer.new()
	vd_box.add_theme_constant_override(&"separation", 6)
	_vdetail_panel.add_child(vd_box)

	_vd_title = Label.new()
	_vd_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vd_box.add_child(_vd_title)
	_vd_state = Label.new()
	vd_box.add_child(_vd_state)
	var hunger_title := Label.new()
	hunger_title.text = "饥饿度"
	vd_box.add_child(hunger_title)
	_vd_hunger = ProgressBar.new()
	_vd_hunger.max_value = 100.0
	vd_box.add_child(_vd_hunger)
	_vd_work = Label.new()
	vd_box.add_child(_vd_work)
	_vd_home = Label.new()
	vd_box.add_child(_vd_home)

	var fire_btn := Button.new()
	fire_btn.text = "解除工作"
	fire_btn.pressed.connect(_on_fire_villager)
	vd_box.add_child(fire_btn)
	var vd_close_btn := Button.new()
	vd_close_btn.text = "关闭"
	vd_close_btn.pressed.connect(func(): _vdetail_panel.visible = false)
	vd_box.add_child(vd_close_btn)

	# ---- 新手引导面板（左下角，前 3 天四步；纯展示不挡点击） ----
	_guide_panel = PanelContainer.new()
	_guide_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_guide_panel.offset_left = 12
	_guide_panel.offset_bottom = -32
	_guide_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN  # 底边钉住向上展开，否则整面板出屏
	_guide_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_guide_panel)
	var guide_box := VBoxContainer.new()
	guide_box.add_theme_constant_override(&"separation", 2)
	_guide_panel.add_child(guide_box)
	_guide_title = Label.new()
	_guide_title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_guide_title.add_theme_color_override(&"font_color", Color(0.7, 0.95, 0.6))
	_guide_title.add_theme_font_size_override(&"font_size", 14)
	guide_box.add_child(_guide_title)
	_guide_body = Label.new()
	_guide_body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_guide_body.add_theme_color_override(&"font_color", Color(0.92, 0.88, 0.78))
	guide_box.add_child(_guide_body)
	_guide_panel.visible = false

	# ---- 通知日志（最近 20 条消息，toast 会丢所以留档） ----
	_log_panel = PanelContainer.new()
	_log_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_log_panel.offset_right = -12
	_log_panel.offset_bottom = -32
	_log_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_log_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_log_panel.visible = false
	root.add_child(_log_panel)
	_log_list = Label.new()
	_log_list.add_theme_font_size_override(&"font_size", 13)
	_log_panel.add_child(_log_list)

	# ---- 覆灭面板（全屏遮罩；王国覆灭时的唯一出口） ----
	_collapse_dim = ColorRect.new()
	_collapse_dim.color = Color(0, 0, 0, 0.62)
	_collapse_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_collapse_dim.mouse_filter = Control.MOUSE_FILTER_STOP  # 挡住底下的地图与按钮
	_collapse_dim.visible = false
	root.add_child(_collapse_dim)
	_collapse_panel = PanelContainer.new()
	_collapse_panel.set_anchors_preset(Control.PRESET_CENTER)
	_collapse_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_collapse_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_collapse_panel.visible = false
	_collapse_panel.z_index = 50
	root.add_child(_collapse_panel)
	var collapse_box := VBoxContainer.new()
	collapse_box.add_theme_constant_override(&"separation", 10)
	_collapse_panel.add_child(collapse_box)
	var collapse_title := Label.new()
	collapse_title.text = "王国覆灭了"
	collapse_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	collapse_title.add_theme_font_size_override(&"font_size", 30)
	collapse_title.add_theme_color_override(&"font_color", Color(1.0, 0.4, 0.35))
	collapse_box.add_child(collapse_title)
	var collapse_info := Label.new()
	collapse_info.text = "村民已全部离开：没有木材重建住房，也没有存粮吸引移民。"
	collapse_info.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	collapse_box.add_child(collapse_info)
	var collapse_tip := Label.new()
	collapse_tip.text = "可以从灾前的存档继续，或者开一个新王国。"
	collapse_tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	collapse_box.add_child(collapse_tip)
	var collapse_load := Button.new()
	collapse_load.text = "读取存档"
	collapse_load.pressed.connect(func(): main.open_load_menu(false))  # 死档绝不能顶进 autosave
	collapse_box.add_child(collapse_load)
	var collapse_new := Button.new()
	collapse_new.text = "新游戏"
	collapse_new.pressed.connect(main.new_game)
	collapse_box.add_child(collapse_new)
	var collapse_ignore := Button.new()
	collapse_ignore.text = "继续观望"
	collapse_ignore.pressed.connect(hide_collapse_panel)
	collapse_box.add_child(collapse_ignore)

	# ---- 底部提示 ----
	var hint := Label.new()
	hint.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	hint.offset_top = -28
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hint.text = "左键放置/查看 · 右键取消/两次确认拆除/拖动拆路 · 中键拖动平移 · 空格倍速 · P 暂停 · B 建造 · L 村民 · WASD/滚轮"
	root.add_child(hint)
	# 按钮不抢焦点：否则点过按钮后 Space（ui_accept）会被焦点按钮吃掉，
	# 倍速失效不说，焦点在「保存」上还会连发存档
	_disable_focus_recursive(root)

## 覆灭面板显隐
func show_collapse_panel() -> void:
	_collapse_dim.visible = true
	_collapse_panel.visible = true

func hide_collapse_panel() -> void:
	_collapse_dim.visible = false
	_collapse_panel.visible = false

# ---------- 建造菜单 ----------

func _toggle_build_menu() -> void:
	_build_panel.visible = not _build_panel.visible
	if _build_panel.visible:
		_villager_panel.visible = false

func _on_build_button(data: Dictionary) -> void:
	placer.select(data)
	main.clear_building_inspect()  # 选中建造即收起工作区域圈，避免"绿圈+高亮+预览"三层叠加
	# 菜单保持打开：换建筑类型不再"右键取消→重开菜单"点三次；面板吞掉自身点击不会误放

## 按当前时代刷新建造按钮：未解锁的禁用并标注解锁时代
func _refresh_build_buttons() -> void:
	var era: int = main.current_era()
	for entry in _build_buttons:
		var btn: Button = entry["btn"]
		var data: Dictionary = entry["data"]
		var min_era: int = data.get("min_era", 1)
		if era >= min_era:
			btn.disabled = false
			btn.text = "%s\n%s%s" % [data["name"], _cost_text(data.get("cost", [])),
				_terrain_hint(data)]
		else:
			btn.disabled = true
			btn.text = "%s\n%s解锁" % [data["name"], main.ERA_NAMES[min_era - 1]]

## 建造按钮上的选址提示（需林/需浆果/需石林；建设用地只能是平原草地）
func _terrain_hint(data: Dictionary) -> String:
	if data.get("needs_forest", false):
		return "·需森林"
	if data.get("needs_berry", false):
		return "·需浆果"
	if data.get("needs_mountain", false):
		return "·需石林"
	if data.get("needs_water", false):
		return "·需水域"
	return ""

func _switch_tab(group: String) -> void:
	_current_tab = group
	_apply_tab_style()

func _apply_tab_style() -> void:
	for g in _tab_buttons:
		_tab_buttons[g].disabled = (g == _current_tab)
		_tab_buttons[g].text = (BUILD_GROUP_NAMES[g] + " ▼") if g == _current_tab else BUILD_GROUP_NAMES[g]
	for g in _grids:
		_grids[g].visible = (g == _current_tab)


# ---------- 横幅与通知 ----------

## 递归禁掉 HUD 全部按钮的键盘焦点（Space=ui_accept 不再被焦点按钮消费）
func _disable_focus_recursive(node: Node) -> void:
	if node is Button:
		(node as Button).focus_mode = Control.FOCUS_NONE
	for child in node.get_children():
		_disable_focus_recursive(child)

## 临时通知（自动消失，最多同时 3 条堆叠）。时代升级、村民离开、袭击战果等都走这里
func show_toast(text: String, seconds := 4.0) -> void:
	_log_lines.append(text)
	if _log_lines.size() > 20:
		_log_lines.pop_front()
	if _log_visible:
		_refresh_log_panel()
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE  # 别挡住下方的地图点击
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = text
	label.add_theme_color_override(&"font_color", Color(1.0, 0.9, 0.6))
	panel.add_child(label)
	_toast_box.add_child(panel)
	_toasts.append({"label": label, "panel": panel, "timer": seconds})
	if _toasts.size() > 5:
		var oldest: Dictionary = _toasts.pop_front()
		oldest["panel"].queue_free()

func _toggle_log_panel() -> void:
	_log_visible = not _log_visible
	_log_panel.visible = _log_visible
	if _log_visible:
		_refresh_log_panel()

func _refresh_log_panel() -> void:
	if _log_lines.is_empty():
		_log_list.text = "（暂无消息）"
		return
	var parts := PackedStringArray()
	var start := maxi(0, _log_lines.size() - 12)  # 最多显示最近 12 条，防压住详情面板
	for i in range(start, _log_lines.size()):
		parts.append("· " + _log_lines[i])
	if start > 0:
		parts.insert(0, "…（更早 %d 条略）" % start)
	_log_list.text = "\n".join(parts)

## 城堡落成：加冕提示（main._on_placed 调用）
func show_coronation() -> void:
	show_toast("加冕为王！王国诞生了，之后可继续自由建设", 8.0)

## 读档/新游戏后强制重建村民列表按钮（防止按钮绑着已释放的旧村民）
func invalidate_villager_list() -> void:
	_list_buttons.clear()
	_list_sig = ""  # 签名一并失效：新实例 uid 不同本来就会重建，这里兜底保证必定重建
	_last_era = 0  # 新游戏/读档后重置时代提示基准，避免弹假"进入XX时代"

# ---------- 村民列表 / 村民详情 ----------

func _toggle_villager_panel() -> void:
	_villager_panel.visible = not _villager_panel.visible
	if _villager_panel.visible:
		_build_panel.visible = false
		_list_buttons.clear()  # 强制重建，防止读档后按钮绑着旧村民
		_list_sig = ""         # 签名一并失效，否则签名命中会跳过重建 → 空按钮越界
		_refresh_villager_list()

## 排序按钮循环文案（与 _sort_mode 一一对应）
const SORT_LABELS: Array[String] = ["排序：默认", "排序：名字", "排序：饥饿"]

## 筛选/排序变化：置标志并失效签名，下一次 0.5s 低频刷新即按新条件重建列表
func _on_filter_idle_toggled(pressed: bool) -> void:
	_filter_idle = pressed
	_list_sig = ""

func _on_filter_homeless_toggled(pressed: bool) -> void:
	_filter_homeless = pressed
	_list_sig = ""

func _on_sort_pressed() -> void:
	_sort_mode = (_sort_mode + 1) % SORT_LABELS.size()
	_sort_btn.text = SORT_LABELS[_sort_mode]
	_list_sig = ""

## 先过滤（空闲=无工作；无房=home 空或失效）再排序；uid 签名（含顺序）与当前集合
## 不一致才重建按钮，否则只刷文字（不打断悬停和滚动）
func _refresh_villager_list() -> void:
	var all_villagers := villagers_root.get_children()
	var villagers: Array = []
	for v in all_villagers:
		if _filter_idle and v.workplace != null:
			continue  # 只看空闲：剔除已有工作的（与顶栏"空闲"计数同口径）
		if _filter_homeless and v.home != null and is_instance_valid(v.home):
			continue  # 只看无房：剔除有住所的（home 被拆掉失效的仍算无房）
		villagers.append(v)
	match _sort_mode:
		1:
			villagers.sort_custom(func(a, b): return a.display_name < b.display_name)
		2:
			villagers.sort_custom(func(a, b): return a.hunger > b.hunger)
	# 签名=当前（过滤+排序后）序列的 uid 串：饿死/离开/读档/换序都会改变签名 → 重建重绑
	var sig := "none"  # 空集合哨兵：与初始 _list_sig("") 区分，0 人口时也能亮出空提示
	if not villagers.is_empty():
		var ids := PackedStringArray()
		for v in villagers:
			ids.append(str(v.get_instance_id()))
		sig = ",".join(ids)  # String.join(PackedStringArray)——4.4 的 PackedStringArray 无 join 成员
	if sig != _list_sig:
		_list_sig = sig
		for child in _villager_list.get_children():
			child.queue_free()
		_list_buttons.clear()
		if villagers.is_empty():
			var empty_label := Label.new()
			empty_label.text = "（无匹配村民）"
			_villager_list.add_child(empty_label)
		else:
			for v in villagers:
				var btn := Button.new()
				btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
				btn.focus_mode = Control.FOCUS_NONE
				btn.pressed.connect(main.focus_villager.bind(v))
				_villager_list.add_child(btn)
				_list_buttons.append(btn)
	for i in villagers.size():
		var v = villagers[i]
		_list_buttons[i].text = "%s｜%s｜饥饿%d%%" % [v.display_name, v.state_text(), int(v.hunger)]
	_vlist_title.text = "—— 村民 ——（显示 %d/共 %d）" % [villagers.size(), all_villagers.size()]

func show_villager(v: Villager) -> void:
	_current_villager = v
	_details_panel.visible = false
	_current_building = null
	if v == null:
		_vdetail_panel.visible = false
		return
	_vdetail_panel.visible = true
	_refresh_villager_details()

func _refresh_villager_details() -> void:
	if _current_villager == null or not is_instance_valid(_current_villager):
		_vdetail_panel.visible = false
		_current_villager = null
		return
	var v := _current_villager
	_vd_title.text = v.display_name
	_vd_state.text = "状态：%s　幸福度：%d" % [v.state_text(), int(v.happiness)]
	_vd_hunger.value = v.hunger
	if v.workplace != null and is_instance_valid(v.workplace):
		_vd_work.text = "工作：%s" % v.workplace.data.get("name", "")
	else:
		_vd_work.text = "工作：无业"
	if v.home != null and is_instance_valid(v.home):
		_vd_home.text = "住所：小屋"
	else:
		_vd_home.text = "住所：无家可归"

func _on_fire_villager() -> void:
	if _current_villager != null and is_instance_valid(_current_villager):
		main.unassign_villager(_current_villager)
		_refresh_villager_details()

# ---------- 建筑详情 ----------

## main 在地图上点到建筑时调用；传 null 则关闭面板
func show_building(b) -> void:
	_current_building = b
	_vdetail_panel.visible = false
	_current_villager = null
	if b == null:
		_details_panel.visible = false
		return
	_details_title.text = b.data.get("name", "建筑")
	_details_info.text = _describe(b.data)
	_details_panel.visible = true
	_refresh_details()

func _describe(data: Dictionary) -> String:
	var lines := PackedStringArray()
	# 作用说明（catalog 的 desc 字段）：每个建筑是干什么的，一眼明确
	if data.has("desc"):
		lines.append("作用：%s" % data["desc"])
	lines.append("造价：%s" % _cost_text(data.get("cost", [])))
	if data.get("produces", false):
		var recipe := ""
		var inputs: Array = data.get("inputs", [])
		if not inputs.is_empty():
			recipe += _cost_text(inputs) + " → "
		recipe += _cost_text(data.get("outputs", []))
		lines.append("生产：%s / %d秒" % [recipe, int(data.get("interval", 5.0))])
		if data.get("no_winter", false):
			lines.append("冬季停产")
	else:
		lines.append("无生产")
	if data.get("needs_forest", false): lines.append("选址：需邻近森林")
	if data.get("needs_mountain", false): lines.append("选址：需邻近石林")
	if data.get("needs_berry", false): lines.append("选址：需邻近浆果丛")
	if data.get("needs_water", false): lines.append("选址：需邻近水域")
	return "\n".join(lines)

func _refresh_details() -> void:
	if _current_building == null or not is_instance_valid(_current_building):
		_details_panel.visible = false
		_current_building = null
		return
	var b = _current_building
	var max_workers: int = b.data.get("workers", 0)
	_worker_label.text = "工人 %d/%d" % [b.workers.size(), max_workers]
	_worker_label.get_parent().visible = max_workers > 0
	_details_progress.visible = b.data.get("produces", false)
	_details_progress.value = b.progress() * 100.0
	_refresh_status_line(b)
	var housing: int = b.data.get("housing", 0)
	_housing_label.visible = housing > 0
	if housing > 0:
		_housing_label.text = "住户 %d/%d" % [b.residents.size(), housing]
	_refresh_sale_line(b)

## 停工原因提示：缺原料 / 缺工人 / 冬季停产 / 服务建筑未生效（正常时隐藏）
func _refresh_status_line(b) -> void:
	var status := ""
	if b.data.get("produces", false):
		if b.data.get("no_winter", false) and time_mgr.is_winter():
			status = "❄ 冬季停产"
		elif b.no_prod_today:
			status = "⛈ 暴雨停产（今日）"
		elif b.depleted:
			status = "周边森林已耗尽，停产中（建植树场补种）"
		elif not resources.has_all(b.data.get("inputs", [])) \
				and not (b.data.get("inputs", []) as Array).is_empty():
			status = "缺原料，停工中"
		else:
			var need: int = b.data.get("workers", 0)
			if need > 0:
				var present: int = b._count_present_workers()
				if present < need:
					status = "缺工人（%d/%d 在岗）" % [present, need]
	elif not b.data.get("aura_kind", "").is_empty() \
			or b.data.get("auto_sells", false) or b.data.has("auto_buys"):
		# 教堂/酒馆/市场/贸易站：没人在岗=今天信仰/娱乐/买卖全不生效
		var need2: int = b.data.get("workers", 0)
		if need2 > 0 and not b.worked_today:
			var present2: int = b._count_present_workers()
			status = "缺工人（%d/%d 在岗），今日不生效" % [present2, need2]
	# 资源地块余量：伐木场显示剩余森林，植树场显示可种草地（提前排产，不再沉默停产）
	if b.data.get("depletes", "") == "forest":
		var left: int = b.count_terrain_near(GridManager.TileType.FOREST)
		var left_text := "周边森林 %d 格" % left
		if left <= 5:
			left_text += "（将耗尽，建议补植树场）"
		status = left_text if status.is_empty() else status + "｜" + left_text
	elif b.data.get("plants", "") == "forest":
		var free: int = b.count_terrain_near(GridManager.TileType.GRASS, true)
		status = ("周边可种草地 %d 格" % free) if status.is_empty() \
			else status + "｜可种草地 %d" % free
	_status_label.visible = not status.is_empty()
	_status_label.text = status

## 市场/贸易站的昨日成交/收购（main._market_trading 每天写入 last_sale）
func _refresh_sale_line(b) -> void:
	if not (b.data.get("auto_sells", false) or b.data.has("auto_buys")) \
			or b.last_sale.is_empty():
		_sale_label.visible = false
		return
	var items: Dictionary = b.last_sale.get("items", {})
	var parts := PackedStringArray()
	for t in items:
		if ResourceManager.NAMES.has(t):
			parts.append("%s×%d" % [ResourceManager.NAMES[t], items[t]])
	if parts.is_empty():
		_sale_label.visible = false
		return
	var gold: int = int(b.last_sale.get("gold", 0))
	if gold < 0:
		_sale_label.text = "昨日收购：%s，−%d 金" % ["、".join(parts), -gold]
	else:
		_sale_label.text = "昨日成交：%s，+%d 金" % ["、".join(parts), gold]
	_sale_label.visible = true

func _on_assign_worker() -> void:
	if _current_building != null and is_instance_valid(_current_building):
		main.assign_worker(_current_building)
		_refresh_details()

func _on_unassign_worker() -> void:
	if _current_building != null and is_instance_valid(_current_building):
		main.unassign_worker(_current_building)
		_refresh_details()

func _on_demolish_current() -> void:
	if _current_building != null and is_instance_valid(_current_building):
		placer._try_demolish(_current_building.origin)
	_details_panel.visible = false
	_current_building = null

# ---------- 常规刷新 ----------

## 造价文本用单字资源名：建造按钮 120px 宽装得下城堡"木100、石80、金50"
const COST_SHORT := {
	ResourceManager.Type.WOOD: "木", ResourceManager.Type.FOOD: "食",
	ResourceManager.Type.WHEAT: "麦", ResourceManager.Type.FLOUR: "粉",
	ResourceManager.Type.BREAD: "包", ResourceManager.Type.STONE: "石",
	ResourceManager.Type.GOLD: "金", ResourceManager.Type.WOOL: "毛",
	ResourceManager.Type.CLOTHES: "衣", ResourceManager.Type.BEER: "酒",
}

func _cost_text(costs: Array) -> String:
	var parts := PackedStringArray()
	for c in costs:
		parts.append("%s%d" % [COST_SHORT.get(c[0], "?"), c[1]])
	return "、".join(parts) if not parts.is_empty() else "免费"

func _process(delta: float) -> void:
	# 每帧只做轻量活：横幅状态与 toast 倒计时（重文案全部下沉到 0.5s 低频块）
	# 袭击横幅：raid.banner_text 非空即常驻显示（预警/来袭）
	if Engine.time_scale <= 0.0 and main.is_game_started():
			_banner_label.text = "⏸ 已暂停（按 P 继续）"
			_banner_panel.visible = true
	elif raid != null and not String(raid.banner_text).is_empty():
		if _banner_label.text != String(raid.banner_text):
			_banner_label.text = raid.banner_text
		_banner_panel.visible = true
	else:
		_banner_panel.visible = false
	# toast 倒计时（逐条独立，倒序遍历便于移除；用真实时间，×4 时提示不会一闪而过）
	var real_delta := delta / maxf(1.0, Engine.time_scale)
	for i in range(_toasts.size() - 1, -1, -1):
		var t: Dictionary = _toasts[i]
		t["timer"] = float(t["timer"]) - real_delta
		if t["timer"] <= 0.0:
			t["panel"].queue_free()
			_toasts.remove_at(i)
	# 资源栏：脏标记每帧最多重建一次
	if _res_dirty:
		_refresh_resources()
	if _details_panel.visible:
		_refresh_details()
	if _vdetail_panel.visible:
		_refresh_villager_details()
	# 每 0.5 秒刷新一次低频内容（统计/目标行/幸福度/建造按钮/村民列表）
	_build_refresh -= delta
	if _build_refresh <= 0.0:
		_build_refresh = 0.5
		_refresh_lowfreq(main.current_era())
		if _villager_panel.visible:
			_refresh_villager_list()

## 低频刷新（0.5s 一次）：人口统计、时代目标行、幸福度——250 人口时每帧全扫太浪费
func _refresh_lowfreq(era: int) -> void:
	# 时间：入冬临近时给出倒计时提示（换天/换季/倍速变化时才重建字符串）
	if time_mgr.day != _last_day or time_mgr.season != _last_season \
			or Engine.time_scale != _last_time_scale:
		_last_day = time_mgr.day
		_last_season = time_mgr.season
		_last_time_scale = Engine.time_scale
		var until_winter := time_mgr.days_until_winter()
		if time_mgr.is_winter():
			_time_label.text = "%s（冬季中）" % time_mgr.day_text()
		elif until_winter <= 5:
			_time_label.text = "%s｜距冬季%d天" % [time_mgr.day_text(), until_winter]
		else:
			_time_label.text = time_mgr.day_text()
		if Engine.time_scale > 1.0:
			_time_label.text += "  ×%d" % int(Engine.time_scale)
	# 人口统计
	var idle := 0
	var homeless := 0
	for v in villagers_root.get_children():
		if v.workplace == null:
			idle += 1
		if v.home == null or not is_instance_valid(v.home):
			homeless += 1
	_pop_btn.text = "人口 %d｜空闲 %d｜无房 %d" % [villagers_root.get_child_count(), idle, homeless]
	# 时代目标行（带进度数字；无房预警优先）
	var goal: String = main.era_goal_progress()
	if homeless > 0:
		goal = "⚠ 先建小屋安置村民（无房 %d）· %s" % [homeless, goal]
	_era_label.text = "%s · %s" % [main.ERA_NAMES[era - 1], goal]
	# 幸福度 + <40 红色预警
	_hap_label.text = "幸福度 %d" % int(resources.happiness)
	var hap_bad := resources.happiness < 40.0
	if hap_bad != _hap_bad:
		_hap_bad = hap_bad
		if hap_bad:
			_hap_label.add_theme_color_override(&"font_color", Color(1.0, 0.45, 0.4))
		else:
			_hap_label.remove_theme_color_override(&"font_color")
	# 时代提示：只在升级时弹（人口跌落导致的降级静默更新基准即可）
	if _last_era == 0:
		_last_era = era
	elif era != _last_era:
		var upgraded := era > _last_era
		_last_era = era
		if upgraded:
			var t := "进入%s！%s" % [main.ERA_NAMES[era - 1], main.era_goal_progress()]
			if era == 2:
				t += "（提示：先建采石场贴着石林备石料）"
			show_toast(t, 7.0)
	_refresh_build_buttons()
	# 新手引导：显示当前步骤；只在与村民列表重叠时让位（建造菜单在上方，可共存）
	var step := int(main.tutorial_step())
	if step != _guide_step:
		_guide_step = step
		if step > 0:
			_guide_title.text = "▶ 引导 %d/6" % step
			_guide_body.text = GUIDE_STEPS[step - 1]
	_guide_panel.visible = step > 0 and not _villager_panel.visible

## resources.changed 高频信号（每次产出/消费都发）：只置脏，_process 每帧最多重建一次
func _mark_resources_dirty() -> void:
	_res_dirty = true

func _refresh_resources() -> void:
	var parts := PackedStringArray()
	for t in ResourceManager.Type.values():
		parts.append("%s %d" % [ResourceManager.NAMES[t], resources.get_amount(t)])
	_resource_label.text = "  ".join(parts)
	_res_dirty = false
