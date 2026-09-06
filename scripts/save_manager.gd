extends Node
class_name SaveManager

## 存档 v5 读写：原子写（.tmp→校验→rename）、自动存档 .bak 轮转、多槽列表与读档恢复。
## v4 → v5：世界设置（尺寸/地形/丰度/种子）入档，roads 由 bool 升为 RoadType 整数。
## 地图尺寸不再要求与当前配置一致——读档会按存档里的世界设置把地图重建成存档的尺寸。
## game 为主控 main.gd，无类型注入（与 raid_manager 同模式，避免 class_name 循环依赖）。

const SAVE_VERSION := 5
const AUTOSAVE := "autosave.json"

var game = null  # 主控 main.gd（main 无 class_name，保持无类型避免循环依赖）
var save_dir := ""


## 持有主控并确定存档目录：导出后放在游戏 exe 同级的 saves/ 下；编辑器里放在项目 saves/ 下
func setup(p_game) -> void:
	game = p_game
	if OS.has_feature("editor"):
		save_dir = ProjectSettings.globalize_path("res://") + "saves/"
	else:
		save_dir = OS.get_executable_path().get_base_dir() + "/saves/"
	DirAccess.make_dir_recursive_absolute(save_dir)


## 保存。slot_name 为空时按当前时间生成新存档文件
func save_game(slot_name := "") -> void:
	if slot_name.is_empty():
		slot_name = "存档_%s.json" % Time.get_datetime_string_from_system().replace(":", "-")
	# 袭击进行中存档 = 强盗撤退，只保留 next_raid_day
	if game.raid.raid_active:
		game.raid.retreat()
	var building_list: Array = []
	for b in game.buildings_root.get_children():
		building_list.append({
			"uid": b.uid,
			"id": String(b.data["id"]),
			"level": b.level,
			"priority": b.priority,
			"origin": [b.origin.x, b.origin.y],
			"timer": b.timer,
			"hp": b.hp,
			"worked_today": b.worked_today,  # 深夜读档时教堂/酒馆/市场的当日有效性
		})
	var villager_list: Array = []
	for v in game.villagers_root.get_children():
		var cell: Vector2i = game.grid.world_to_cell(v.position)
		villager_list.append({
			"uid": v.uid,
			"name": v.display_name,
			"cell": [cell.x, cell.y],
			"hunger": v.hunger,
			"happiness": v.happiness,
			"ate_bread": v.last_ate_bread,
			"workplace": v.workplace.uid if is_instance_valid(v.workplace) else -1,
			"home": v.home.uid if is_instance_valid(v.home) else -1,
			"role": int(v.role),
			"trait": String(v.trait_id),
			"hp": v.hp,
			"has_clothes": v.has_clothes,
			"clothes_days": v.clothes_days,
		})
	var stock := {}
	for t in ResourceManager.Type.values():
		stock[str(t)] = game.resources.get_amount(t)
	var data := {
		"version": SAVE_VERSION,
		"save_name": slot_name,
		"saved_at": int(Time.get_unix_time_from_system()),
		"width": game.grid.width,
		"height": game.grid.height,
		"world": game.grid.config.to_dict(),
		"day": game.time_mgr.day,
		"time_of_day": game.time_mgr.time_of_day,
		"terrain": Array(game.grid.terrain),
		"roads": Array(game.grid.road_type),
		"stock": stock,
		"happiness": game.resources.happiness,
		"buildings": building_list,
		"villagers": villager_list,
		"villager_seq": game._villager_seq,
		"villager_count": game.villagers_root.get_child_count(),  # 兼容菜单列表显示
		"crowned": game.crowned,
		"next_raid_day": game.raid.next_raid_day,
		"raid_pending": game.raid.raid_pending,
		"raid_started_day": game.raid.raid_started_day,
		"raid_mood_bonus": game.raid.raid_mood_bonus,
		"raid_mood_days_left": game.raid.raid_mood_days_left,
	}
	var path := save_dir + slot_name
	# 原子写：先写 .tmp，全部成功后再改名顶替旧档；中途失败只打印原因，旧档原封不动
	var tmp_path := path + ".tmp"
	var f := FileAccess.open(tmp_path, FileAccess.WRITE)
	if f == null:
		print("存档失败：无法写临时文件 %s（错误码 %d）" % [tmp_path, FileAccess.get_open_error()])
		return
	f.store_string(JSON.stringify(data, "\t"))
	var write_err := f.get_error()
	f.close()
	if write_err != OK:
		# 磁盘满/IO 错误会产生截断档，绝不能让它顶替旧档
		print("存档失败：写入临时文件出错（错误码 %d），旧档保留" % write_err)
		DirAccess.remove_absolute(tmp_path)
		return
	# 覆盖自动存档前，把上一份 autosave 留成 autosave.bak.json，多一层回退保险
	if slot_name == AUTOSAVE and FileAccess.file_exists(path):
		var bak := FileAccess.open(save_dir + "autosave.bak.json", FileAccess.WRITE)
		if bak == null:
			print("备份旧自动存档失败（错误码 %d），继续写主档" % FileAccess.get_open_error())
		else:
			bak.store_buffer(FileAccess.get_file_as_bytes(path))
			bak.close()
	var err := DirAccess.rename_absolute(tmp_path, path)
	if err != OK:
		print("存档失败：临时文件改名失败（错误码 %d），旧档保留" % err)
		return
	print("已存档：", path)

## 列出所有存档（按保存时间倒序），供菜单选择
func get_save_list() -> Array:
	var result := []
	var dir := DirAccess.open(save_dir)
	if dir == null:
		return result
	for file in dir.get_files():
		if not file.ends_with(".json") or file == "autosave.bak.json":
			continue  # .bak 是回退保险，不作为可选存档展示
		var path := save_dir + file
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		# 合法 JSON 但不是对象（数组/数字等）的坏档同样跳过，别在启动扫描时把 _ready 炸掉
		if parsed == null or not parsed is Dictionary:
			continue
		result.append({
			"path": path,
			"name": parsed.get("save_name", file),
			"day": int(parsed.get("day", 0)),
			"pop": int(parsed.get("villager_count", 0)),
			"time": int(parsed.get("saved_at", 0)),
			"version": int(parsed.get("version", 0)),
		})
	result.sort_custom(func(a, b): return a["time"] > b["time"])
	return result


func delete_save(path: String) -> void:
	DirAccess.remove_absolute(path)


## 读档，成功返回 true。带版本号与字段校验，坏档不会崩
func load_game(path: String) -> bool:
	if not FileAccess.file_exists(path):
		print("没有找到存档")
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if parsed == null or not parsed is Dictionary:
		print("存档损坏：不是有效的 JSON")
		return false
	var data: Dictionary = parsed

	# 版本与结构校验
	if int(data.get("version", 0)) != SAVE_VERSION:
		print("存档版本不兼容（当前游戏 v%d，存档 v%d）" % [SAVE_VERSION, int(data.get("version", 0))])
		return false
	# 世界设置入档后，存档自带尺寸：读档按存档重建地图，而不是要求当前配置刚好对得上
	var saved_w := int(data.get("width", 0))
	var saved_h := int(data.get("height", 0))
	if saved_w <= 0 or saved_h <= 0:
		print("存档地图尺寸异常")
		return false
	var terrain_data: Array = data.get("terrain", [])
	var roads_data: Array = data.get("roads", [])
	if terrain_data.size() != saved_w * saved_h:
		print("存档地形数据长度异常")
		return false
	if roads_data.size() != terrain_data.size():
		roads_data = []
		roads_data.resize(terrain_data.size())
		roads_data.fill(0)

	# 结构预校验：在销毁现有世界之前剔除坏条目，避免半途报错留下残局
	var building_entries: Array = data.get("buildings", [])
	var villager_entries: Array = data.get("villagers", [])
	if not (building_entries is Array) or not (villager_entries is Array):
		print("存档损坏：buildings/villagers 结构异常")
		return false

	# 袭击进行中读档 = 强盗撤退（与存档策略一致）
	game.raid.retreat()

	# 立即销毁旧实体（不用延迟的 queue_free，避免新旧同帧共存）
	for v in game.villagers_root.get_children():
		v.free()
	for b in game.buildings_root.get_children():
		b.free()
	game.placer.cancel()

	# 地图数据（先按存档恢复世界设置与尺寸，再灌地形/路面；顺序反了 _idx 会算错）
	game.grid.config = WorldConfig.from_dict(data.get("world", {}))
	game.grid.width = saved_w
	game.grid.height = saved_h
	game.grid.terrain.clear()
	game.grid.road_type.clear()
	game.grid.occupancy.clear()
	for t in terrain_data:
		game.grid.terrain.append(int(t))
	for r in roads_data:
		game.grid.road_type.append(int(r))
	game.grid.occupancy.resize(terrain_data.size())
	game.grid.rebuild_jitter()
	game.grid.reset_occupancy()
	game.grid.queue_redraw()

	# 时间（坏档数值域防御：day<1 会让季节取模出负数，time_of_day>1 会直接跳天）
	game.time_mgr.day = maxi(1, int(data.get("day", 1)))
	game.time_mgr.time_of_day = clampf(float(data.get("time_of_day", 0.3)), 0.0, 0.999)
	game.time_mgr.season = int((game.time_mgr.day - 1) / game.time_mgr.days_per_season) % 4
	game._last_season = game.time_mgr.season  # 读入冬季档不该弹"冬季来临"提示

	# 袭击与加冕状态（旧档没有这些字段，一律默认值）
	game.crowned = bool(data.get("crowned", false))
	game.raid.next_raid_day = int(data.get("next_raid_day", -1))
	game.raid.raid_pending = bool(data.get("raid_pending", false))
	game.raid.raid_started_day = int(data.get("raid_started_day", -1))
	game.raid.raid_mood_bonus = int(data.get("raid_mood_bonus", 0))
	game.raid.raid_mood_days_left = int(data.get("raid_mood_days_left", 0))
	game.raid.raid_warned = false  # 读档后重新走预警流程，别沿用写档外的残留横幅状态
	game.raid.banner_text = ""

	# 资源
	var stock_data: Dictionary = data.get("stock", {})
	for t in ResourceManager.Type.values():
		game.resources.stock[t] = int(stock_data.get(str(t), 0))
	game.resources.happiness = float(data.get("happiness", 50.0))
	game.resources.changed.emit()

	# 建筑：先全部建好，登记 uid → 实例，供村民恢复关系
	var buildings_by_uid := {}
	for bd in building_entries:
		if not (bd is Dictionary):
			continue  # 坏条目（合法 JSON 但不是对象）直接剔除，别让 .get 调用报错
		# id 先转 String 再造 StringName：坏档里 id 可能是数字/布尔，直转会运行时报错
		var catalog := BuildingCatalog.find_by_id(StringName(String(bd.get("id", ""))))
		if catalog.is_empty():
			continue
		var origin_arr = bd.get("origin", null)
		if not (origin_arr is Array and origin_arr.size() >= 2):
			continue
		var origin := Vector2i(int(origin_arr[0]), int(origin_arr[1]))
		if not game.grid.in_bounds(origin.x, origin.y):
			continue
		var bsize: Vector2i = catalog.get("size", Vector2i.ONE)
		if origin.x + bsize.x > game.grid.width or origin.y + bsize.y > game.grid.height:
			continue  # footprint 越出地图边缘，防止 occupy_area 越界写
		var b := Building.new()
		b.setup(catalog, origin, game.resources, game.time_mgr, game.raid, game.grid)
		b.uid = int(bd.get("uid", b.uid))
		Building.bump_uid_past(b.uid)
		# 等级先恢复，hp 才有正确的生效上限可钳制（升级会抬高城墙耐久上限）
		b.level = clampi(int(bd.get("level", 1)), 1, b.max_level())
		b.priority = clampi(int(bd.get("priority", 1)), 0, 2)
		b.timer = float(bd.get("timer", 0.0))
		b.hp = int(bd.get("hp", b.eff_max_hp()))
		b.worked_today = bool(bd.get("worked_today", false))
		game.buildings_root.add_child(b)
		game.grid.occupy_area(origin, catalog.get("size", Vector2i.ONE), b)
		buildings_by_uid[b.uid] = b

	# 村民：恢复位置、饥饿、工作/住房关系；工作位/家门口重新计算
	game._villager_seq = int(data.get("villager_seq", 0))
	for vd in villager_entries:
		if not (vd is Dictionary):
			continue  # 坏条目（合法 JSON 但不是对象）直接剔除，别让 .get 调用报错
		var v := Villager.new()
		game._villager_seq += 1
		v.uid = int(vd.get("uid", game._villager_seq))
		game._villager_seq = maxi(game._villager_seq, v.uid)
		# 坏档的 name 可能是数字/布尔：显式转 String，防止世界销毁后读档中途崩
		v.display_name = String(vd.get("name", "村民%d号" % v.uid))
		var cell_arr = vd.get("cell", null)
		if not (cell_arr is Array and cell_arr.size() >= 2):
			v.free()
			continue
		var cell := Vector2i(int(cell_arr[0]), int(cell_arr[1]))
		if not game.grid.is_walkable(cell):
			cell = game.grid.random_walkable_cell()
		v.setup(game.grid, game.resources, game.time_mgr, cell, game.raid)
		v.died.connect(game._on_villager_died)
		v.hunger = float(vd.get("hunger", 0.0))
		v.happiness = float(vd.get("happiness", 50.0))
		v.last_ate_bread = bool(vd.get("ate_bread", false))
		v.role = Villager.Role.GUARD if int(vd.get("role", 0)) == Villager.Role.GUARD else Villager.Role.COMMONER
		# 特长：坏档/旧档（v4 无该键）一律回落到"寻常"，绝不因为一个字段崩掉读档
		var tid := StringName(String(vd.get("trait", "plain")))
		v.trait_id = tid if Villager.TRAITS.has(tid) else &"plain"
		v.hp = int(vd.get("hp", v.guard_max_hp()))
		v.has_clothes = bool(vd.get("has_clothes", false))
		v.clothes_days = int(vd.get("clothes_days", 0))
		game.villagers_root.add_child(v)
		# 恢复工作关系
		var wuid := int(vd.get("workplace", -1))
		if buildings_by_uid.has(wuid):
			var wb = buildings_by_uid[wuid]
			var max_workers: int = wb.eff_workers()
			if wb.workers.size() < max_workers:
				wb.workers.append(v)
				v.workplace = wb
				v.work_cell = game.grid.find_adjacent_walkable(wb.origin, wb.data.get("size", Vector2i.ONE))
		# 恢复住房关系
		var huid := int(vd.get("home", -1))
		if buildings_by_uid.has(huid):
			var hb = buildings_by_uid[huid]
			var capacity: int = hb.eff_housing()
			if hb.residents.size() < capacity:
				hb.residents.append(v)
				v.home = hb
				v.home_cell = game.grid.find_adjacent_walkable(hb.origin, hb.data.get("size", Vector2i.ONE))

	game.reassign_homes()
	game.resort_buildings()  # 按读回来的优先级重排结算顺序（存档顺序理应已排好，这里兜底）
	# 关掉可能开着的详情面板；村民列表按钮强制重建
	game.hud.show_building(null)
	game.hud.invalidate_villager_list()
	print("读档完成")
	return true
