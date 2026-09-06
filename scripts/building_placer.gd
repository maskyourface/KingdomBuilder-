extends Node2D
class_name BuildingPlacer

## 建造交互：选中建筑后鼠标跟随预览（绿=可放，红=不可放），
## 左键放置并扣资源，右键取消选择；未选中时右键拆建筑/拆路（建筑退一半造价）。
## 交通方式（土路/木桥/石板路/山道）是特殊条目：铺进 grid.road_type，不占建筑位。

## placed(building)：建筑放置成功传实例；土路传 null（土路不是 Building）。
signal placed(building)
signal demolished
## 未选中建筑时左键点击地图，请求查看该格建筑详情
signal inspect_requested(cell: Vector2i)
## 放置失败（资源不足/选址不符/位置被占），msg 为给玩家看的中文原因
signal place_failed(msg: String)

var grid: GridManager
var resources: ResourceManager
var time_mgr: TimeManager
var buildings_root: Node2D  # 建筑实例挂这个节点下

var selected: Dictionary = {}  # 当前选中的建筑配置，空 = 未选中
var mouse_cell := Vector2i.ZERO
var raid = null  # RaidManager，由 main 注入，透传给 Building.setup
var _dragging := false  # 按住左键连放（drag_place 条目：土路/小屋/麦田/城墙/城门）
var _drag_warned := false  # 一次按下（单击或一次拖动）最多提示一次放置失败
var _pending_demolish := Vector2i(-1, -1)  # 待确认拆除的建筑格（再按一次右键才真拆）
var _road_removing := false  # 右键拖动拆路中

func select(data: Dictionary) -> void:
	selected = data
	_dragging = false
	_drag_warned = false
	_pending_demolish = Vector2i(-1, -1)
	_road_removing = false
	queue_redraw()

func cancel() -> void:
	selected = {}
	_dragging = false
	_drag_warned = false
	_pending_demolish = Vector2i(-1, -1)
	_road_removing = false
	queue_redraw()

func handle_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		mouse_cell = grid.world_to_cell(get_global_mouse_position())
		if _road_removing and grid.has_road(mouse_cell):
			grid.remove_road(mouse_cell)  # 按住右键拖动，连续拆路（不逐格发信号）
		if _dragging and not selected.is_empty():
			# 拖动连放：失败静默跳过继续拖，但每次按下最多提示一次原因
			if not _try_place(mouse_cell) and not _drag_warned:
				_drag_warned = true
				_warn_place_failed(mouse_cell)
		if not selected.is_empty() or _pending_demolish.x >= 0 or _road_removing:
			queue_redraw()
		return

	var mb := event as InputEventMouseButton
	if mb == null:
		return
	if not mb.pressed:
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = false
		elif mb.button_index == MOUSE_BUTTON_RIGHT:
			_road_removing = false  # 松开右键：结束拖动拆路
		return
	mouse_cell = grid.world_to_cell(get_global_mouse_position())
	if mb.button_index == MOUSE_BUTTON_LEFT:
		_drag_warned = false  # 新的一次按下重新计数
		if _pending_demolish.x >= 0 or _road_removing:
			_pending_demolish = Vector2i(-1, -1)  # 左键任何行为都取消待确认/拆路
			_road_removing = false
			queue_redraw()
		if not selected.is_empty():
			if not _try_place(mouse_cell):
				_drag_warned = true
				_warn_place_failed(mouse_cell)
			if selected.get("drag_place", false):
				_dragging = true
		else:
			inspect_requested.emit(mouse_cell)
	elif mb.button_index == MOUSE_BUTTON_RIGHT:
		if selected.is_empty():
			if grid.has_road(mouse_cell):
				grid.remove_road(mouse_cell)  # 该格有路：先拆路，按住拖动可连续拆
				_road_removing = true  # 拆路不动工人/住房分配，不发 demolished
			elif grid.building_at(mouse_cell) != null:
				var pb = grid.building_at(mouse_cell)
				if _pending_demolish == pb.origin:
					_try_demolish(pb.origin)  # 二次按同一建筑：确认真拆
					_pending_demolish = Vector2i(-1, -1)
				else:
					_pending_demolish = pb.origin  # 首按只高亮整座建筑待确认
				queue_redraw()
			else:
				# 点到空地：取消待确认（目标可能已被强盗拆毁，红框不残留）
				_pending_demolish = Vector2i(-1, -1)
				queue_redraw()
		else:
			cancel()

## 放置失败原因提示（二分：买不起 / 选址不符）
func _warn_place_failed(cell: Vector2i) -> void:
	var what: String = selected.get("name", "建筑")
	if not resources.has_all(selected.get("cost", [])):
		place_failed.emit("资源不足，造不起%s" % what)
		return
	for pair in [["needs_berry", "浆果丛"], ["needs_forest", "森林"],
			["needs_mountain", "石林"], ["needs_water", "水域"],
			["needs_clay", "黏土滩"], ["needs_iron", "铁矿脉"]]:
		if selected.get(pair[0], false) \
				and not grid.has_adjacent_terrain(cell, _terrain_type_of(pair[1])):
			place_failed.emit("%s 需建在%s 2 格内" % [what, pair[1]])
			return
	if selected.get("is_road", false):
		place_failed.emit(_road_hint())
		return
	place_failed.emit("此处无法放置%s（只能建在平原草地上）" % what)

func _terrain_type_of(name_cn: String) -> int:
	match name_cn:
		"浆果丛":
			return GridManager.TileType.BERRY
		"森林":
			return GridManager.TileType.FOREST
		"石林":
			return GridManager.TileType.MOUNTAIN
		"水域":
			return GridManager.TileType.WATER
		"黏土滩":
			return GridManager.TileType.CLAY
		"铁矿脉":
			return GridManager.TileType.IRON
	return GridManager.TileType.GRASS

## 每种交通方式的可铺地形各不相同，铺错地方要说清楚是哪一种铺错了
func _road_hint() -> String:
	match GridManager.road_kind_of(selected):
		GridManager.RoadType.BRIDGE:
			return "木桥只能架在水域上（一格一格铺过去）"
		GridManager.RoadType.PASS:
			return "山道只能开在石林/铁矿脉上"
		GridManager.RoadType.STONE:
			return "石板路铺在草地/耕地/森林上；可以直接盖在已有土路上升级"
		_:
			return "土路可铺在草地/耕地上（可穿森林）；水域要架桥、石林要开山道"

## 放置。返回 true 表示成功；失败原因经 _warn_place_failed / place_failed 播报
func _try_place(cell: Vector2i) -> bool:
	if selected.get("is_road", false):
		var kind := GridManager.road_kind_of(selected)
		if grid.can_place_road(cell, kind) and resources.try_spend(selected.get("cost", [])):
			grid.place_road(cell, kind)
			placed.emit(null)
			return true
		return false

	var size: Vector2i = selected.get("size", Vector2i.ONE)
	if not grid.can_place(cell, size, selected):
		return false
	if not resources.try_spend(selected.get("cost", [])):
		return false

	var b := Building.new()
	b.setup(selected, cell, resources, time_mgr, raid, grid)
	buildings_root.add_child(b)
	grid.occupy_area(cell, size, b)
	if selected.get("converts_to_farm", false):
		grid.convert_to_farmland(cell, size)
	placed.emit(b)
	return true

func _try_demolish(cell: Vector2i) -> void:
	var b = grid.building_at(cell)
	if b != null:
		_remove_building(b, true)  # 手动拆除退一半造价
	elif grid.has_road(cell):
		grid.remove_road(cell)  # 拆路不影响工人/住房分配，与拖动拆路一样不发 demolished


## 被强盗拆毁：不退款。供 RaidManager 调用。
func destroy_building(b) -> void:
	if is_instance_valid(b):
		_remove_building(b, false)


func _remove_building(b, refund: bool) -> void:
	# 立即解除工人/住户的反向引用（queue_free 是延迟的，不能等它）
	for w in b.workers:
		if is_instance_valid(w):
			w.workplace = null
			w.work_cell = Vector2i(-1, -1)
			if w.state == Villager.State.WORKING:
				w.state = Villager.State.IDLE
			if b.data.get("trains_guards", false) and w.role == Villager.Role.GUARD:
				w.role = Villager.Role.COMMONER  # 兵营被拆：当场退役，别等午夜结算
	for r in b.residents:
		if is_instance_valid(r):
			r.home = null
			r.home_cell = Vector2i(-1, -1)
			if r.state == Villager.State.RESTING:
				r.state = Villager.State.IDLE
	# 麦田拆除后恢复草地
	if b.data.get("converts_to_farm", false):
		grid.revert_to_grass(b.origin, b.data.get("size", Vector2i.ONE))
	if refund:
		for c in b.total_investment():
			resources.add(c[0], int(c[1]) / 2)
	grid.free_area(b.origin, b.data.get("size", Vector2i.ONE))
	b.queue_free()
	demolished.emit()

func _can_place_at(cell: Vector2i) -> bool:
	if selected.get("is_road", false):
		return grid.can_place_road(cell, GridManager.road_kind_of(selected))
	return grid.can_place(cell, selected.get("size", Vector2i.ONE), selected)

func _draw() -> void:
	if _pending_demolish.x >= 0:
		# 待确认拆除：按建筑 footprint 画红色半透明框，再按一次右键才真拆
		var pb = grid.building_at(_pending_demolish)
		if pb != null:
			var psize: Vector2i = pb.data.get("size", Vector2i.ONE)
			var pending_rect := Rect2(_pending_demolish.x * GridManager.TILE,
				_pending_demolish.y * GridManager.TILE,
				psize.x * GridManager.TILE, psize.y * GridManager.TILE)
			draw_rect(pending_rect, Color(1.0, 0.2, 0.2, 0.4))
			draw_rect(pending_rect, Color.WHITE, false)
	if selected.is_empty():
		return
	var size: Vector2i = selected.get("size", Vector2i.ONE)
	var rect := Rect2(mouse_cell.x * GridManager.TILE, mouse_cell.y * GridManager.TILE,
		size.x * GridManager.TILE, size.y * GridManager.TILE)
	var ok: bool = _can_place_at(mouse_cell) and resources.has_all(selected.get("cost", []))
	var color := Color(0.2, 1.0, 0.2, 0.4) if ok else Color(1.0, 0.2, 0.2, 0.4)
	# 放置前就把光环/工作范围画出来：这游戏的空间决策几乎全是"够不够得着"，
	# 原先必须先放下再点开详情才看得到范围，等于让玩家盲放一次再拆
	_draw_preview_range(rect)
	draw_rect(rect, color)
	draw_rect(rect, Color.WHITE, false)

## 预览范围：光环建筑（水井/教堂/酒馆/篝火）画光环半径，
## 资源建筑（采集/伐木/采石/植树/渔屋）画方形工作窗口，与放置后的显示口径一致
func _draw_preview_range(rect: Rect2) -> void:
	var size: Vector2i = selected.get("size", Vector2i.ONE)
	var aura := float(selected.get("aura_radius", 0.0))
	var work := float(selected.get("work_radius", 0.0))
	var scare := float(selected.get("scares_wolves", 0.0))
	var teach := float(selected.get("teach_radius", 0.0))
	if teach > 0.0:
		# 学区圈：学堂/大学放歪一格就点化不到住户，放之前必须看得见
		var center3 := rect.get_center()
		draw_circle(center3, teach * GridManager.TILE, Color(0.5, 0.75, 1.0, 0.10))
		draw_arc(center3, teach * GridManager.TILE, 0.0, TAU, 48, Color(0.5, 0.75, 1.0, 0.65), 2.0)
	if aura > 0.0:
		var center := rect.get_center()
		draw_circle(center, aura * GridManager.TILE, Color(1.0, 0.95, 0.5, 0.10))
		draw_arc(center, aura * GridManager.TILE, 0.0, TAU, 48, Color(1.0, 0.95, 0.5, 0.6), 2.0)
	if scare > 0.0:
		var center2 := rect.get_center()
		draw_circle(center2, scare * GridManager.TILE, Color(1.0, 0.6, 0.25, 0.10))
		draw_arc(center2, scare * GridManager.TILE, 0.0, TAU, 48, Color(1.0, 0.6, 0.25, 0.65), 2.0)
	if work > 0.0:
		# 方形窗口：与 Building._draw 的工作区显示、以及实际采集扫描窗口三者一致
		var wrect := Rect2((mouse_cell.x - work) * GridManager.TILE,
			(mouse_cell.y - work) * GridManager.TILE,
			(size.x + work * 2.0) * GridManager.TILE, (size.y + work * 2.0) * GridManager.TILE)
		var fill := Color(1.0, 0.95, 0.5, 0.08)
		var ring := Color(1.0, 0.95, 0.5, 0.5)
		if String(selected.get("depletes", "")) == "forest" \
				or String(selected.get("plants", "")) == "forest":
			fill = Color(0.2, 0.9, 0.3, 0.08)
			ring = Color(0.2, 0.9, 0.3, 0.5)
		draw_rect(wrect, fill)
		draw_rect(wrect, ring, false, 2.0)
