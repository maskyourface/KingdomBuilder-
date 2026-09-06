extends Node2D

## 主控：创建并连接所有子系统，处理镜头、工作/住房分配、人口增长、存档。
## 存档 v4 读写实现已拆至 save_manager.gd（SaveManager，_ready 注入），本文件仅保留 facade。
## 存档 v4：含版本号、地图尺寸校验、建筑 uid/耐久、生产计时、
## 村民个体（位置/饥饿/衣着/职业/工作/住房关系）、袭击排期与加冕状态。
## v3 → v4：新增羊毛/衣服/啤酒资源、市场金币、袭击系统；新字段读档一律 .get 默认值。

## 时代系统：按人口进阶。时代Ⅰ=拓荒营地 … 时代Ⅴ=王国
const ERA_NAMES: Array[String] = ["拓荒营地", "村庄", "城镇", "城邦", "王国"]
const ERA_POP := [0, 15, 40, 100, 250]
const ERA_GOALS: Array[String] = [
	"目标：存粮过冬，人口达到 15",
	"目标：人口达到 40，让村民穿上衣服",
	"目标：人口达到 100，满足信仰与娱乐",
	"目标：人口达到 250，建立防御",
	"目标：建成城堡，加冕为王",
]

const MARKET_DAILY_CAP := 20    # 每市场每天最多卖 20 金
const TRADE_GOLD_RESERVE := 50  # 贸易站收购时给金币留的保底（=城堡造价的金币部分）
const GUARD_WAGE := 1           # 卫兵军饷（金/天）
const GUARD_HEAL_PER_DAY := 40  # 在岗卫兵每天回血量
const CLOTHES_WEAR_MIN := 8     # 一件衣服穿 8~12 天
const CLOTHES_WEAR_MAX := 12

var grid: GridManager
var resources: ResourceManager
var time_mgr: TimeManager
var placer: BuildingPlacer
var hud: HUD
var camera: Camera2D
var buildings_root: Node2D
var villagers_root: Node2D
var menu: MainMenu
var raid: RaidManager
var event_mgr: EventManager  # 随机事件（前期决策点；事件卡模态暂停）
var day_tint: CanvasModulate  # 昼夜色温（夜晚变暗，让时间流动可见）
var _idle_focus_idx := 0  # 点顶栏「空闲」循环定位空闲村民
var crowned := false  # 已建成城堡、举行过加冕（入档；之后沙盒继续）

var save_mgr: SaveManager  # 存档/读档实现（save_manager.gd）；save_dir 转发见存档区 facade
var _game_started := false
var _villager_seq := 0
var _last_season := -1  # 换季提示用（入冬 toast）
var _panning := false   # 按住中键拖动平移镜头中
var _paused_speed := 2.0  # P 暂停前的倍速档位

func _ready() -> void:
	# 资源 → 时间 → 地图 → 放置器 → 界面，注意创建顺序（有依赖）
	resources = ResourceManager.new()
	add_child(resources)

	time_mgr = TimeManager.new()
	add_child(time_mgr)

	grid = GridManager.new()
	add_child(grid)

	buildings_root = Node2D.new()
	buildings_root.name = "Buildings"
	add_child(buildings_root)

	villagers_root = Node2D.new()
	villagers_root.name = "Villagers"
	add_child(villagers_root)

	placer = BuildingPlacer.new()
	placer.grid = grid
	placer.resources = resources
	placer.time_mgr = time_mgr
	placer.buildings_root = buildings_root
	add_child(placer)
	raid = RaidManager.new()
	add_child(raid)
	raid.setup(self, grid, placer, buildings_root, villagers_root, resources, time_mgr)
	placer.raid = raid
	event_mgr = EventManager.new()
	add_child(event_mgr)
	event_mgr.setup(self)

	placer.placed.connect(_on_placed)
	placer.demolished.connect(_on_construction_changed)
	placer.inspect_requested.connect(_on_inspect)
	placer.place_failed.connect(_on_place_failed)

	hud = HUD.new()
	add_child(hud)
	hud.setup(resources, time_mgr, placer, self, villagers_root, raid)

	camera = Camera2D.new()
	camera.position = Vector2(grid.width, grid.height) * GridManager.TILE / 2.0
	add_child(camera)
	camera.make_current()

	# 昼夜色温：白天全亮 → 黄昏偏橙 → 夜晚蓝暗（只影响世界画布，UI 在独立层不受影响）
	day_tint = CanvasModulate.new()
	day_tint.color = Color(1, 1, 1)
	add_child(day_tint)

	# 开局 5 个村民
	for i in 5:
		spawn_villager()

	time_mgr.new_day.connect(_on_new_day)

	# 存档管理器：目录判定/原子写/.bak 轮转/读档恢复都在 save_manager.gd（hud 后、菜单前创建）
	save_mgr = SaveManager.new()
	add_child(save_mgr)
	save_mgr.setup(self)

	# 开始菜单（暂停游戏，等玩家选择）
	menu = MainMenu.new()
	add_child(menu)
	menu.setup(self)
	show_menu()

func spawn_villager(quiet := false) -> void:
	_villager_seq += 1
	var v := Villager.new()
	v.uid = _villager_seq
	v.display_name = "村民%d号" % _villager_seq
	if not quiet and _game_started:
		hud.show_toast("新村民 %s 来到了王国（人口 %d）" % [v.display_name,
			villagers_root.get_child_count() + 1], 3.0)  # 移民是核心正反馈，必须播报
	# 出生点优先落在某栋住房旁，而不是全图随机乱放，省去新村民长途跋涉
	var start := grid.random_walkable_cell()
	var homes: Array = []
	for b in buildings_root.get_children():
		if int(b.data.get("housing", 0)) > 0:
			homes.append(b)
	if not homes.is_empty():
		var hb = homes.pick_random()
		var c := grid.find_adjacent_walkable(hb.origin, hb.data.get("size", Vector2i.ONE))
		if c.x >= 0:
			start = c
	v.setup(grid, resources, time_mgr, start, raid)
	v.died.connect(_on_villager_died)
	villagers_root.add_child(v)

## 村民死亡/离开的可见通知（饿死/战死/迁移都经 Villager.died 信号到这）
func _on_villager_died(v, reason: String) -> void:
	hud.show_toast("%s %s" % [v.display_name, reason], 5.0)

func _on_new_day() -> void:
	cleanup_assignments()
	_distribute_clothes()
	_update_happiness()
	event_mgr.tick_mood()  # 节日 buff 当晚结算生效，次日凌晨递减
	_market_trading()
	_guard_daily()
	raid.on_new_day(current_era())
	event_mgr.on_new_day(current_era())
	# 暴雨日：农田与渔屋今天停产（昨天的事件卡已预告）
	var rain := event_mgr.rainy_day == time_mgr.day
	for b in buildings_root.get_children():
		var bid: String = String(b.data.get("id", ""))
		# 暴雨停农田；渔屋是冬季唯一食物产线且"暴雨浇不干河"，不停
		b.no_prod_today = rain and bid == "farm"
	# 换季提示（入冬最重要：农田/采集停产）
	if time_mgr.season != _last_season:
		if _last_season != -1 and time_mgr.season == TimeManager.Season.WINTER and hud != null:
			hud.show_toast("❄ 冬季来临：农田与采集停产，靠存粮过冬（磨坊/面包房仍开工）", 6.0)
		_last_season = time_mgr.season
	# 幸福度过低：每天一个村民离开（软失败状态；_die 内部会打印并弹 toast）。
	# 离队者有优先级：先无房者、再幸福度最低者，卫兵尽量不抽
	if resources.happiness < 40.0 and villagers_root.get_child_count() > 1:
		var leaving = _pick_leaving_villager()
		if leaving != null:
			leaving._die("因幸福度过低离开了王国")
	# 人口增长：存粮够 + 住房有空位 → 来新移民；时代≥3 且幸福≥70 提速到最多 3 人/天
	var pop := villagers_root.get_child_count()
	# 移民闸：冬季口粮需求翻倍；maxi(...,4) 消除「0 人口时 0>=0 恒真 → 移民来了就饿死」的隐怪循环
	var food_need := pop * (4 if time_mgr.is_winter() else 2)
	if resources.edible_amount() >= maxi(food_need, 4) and _housing_capacity() > pop:
		spawn_villager()
		# 时代Ⅰ提前提速：幸福≥60（有房+水井即可达成）就给第 2 人/天，
		# 把"第一个 10 分钟全在等移民"的前期空窗砍掉一半
		if current_era() == 1 and resources.happiness >= 60.0 and _housing_capacity() > pop + 1 \
				and resources.happiness < 70.0:
			spawn_villager()
		if resources.happiness >= 70.0 and _housing_capacity() > pop + 1:
			spawn_villager()
			if current_era() >= 3 and _housing_capacity() > pop + 2:
				spawn_villager()
				# 时代Ⅳ第 4 人/天：3 人/天会把加冕拖到 ~104 分钟（模拟外推），4 人/天 ≈ 87 分钟
				if current_era() >= 4 and _housing_capacity() > pop + 3:
					spawn_villager()
	reassign_homes()
	# 昨日出勤记录已消费完毕，统一复位，按新的一天重新累计
	for b in buildings_root.get_children():
		b.worked_today = false
	_check_collapse()

## 幸福度过低时的离队者选择：优先无房者，其次幸福度最低者；卫兵尽量不抽
func _pick_leaving_villager():
	var candidates: Array = []
	for v in villagers_root.get_children():
		if v.role != Villager.Role.GUARD:
			candidates.append(v)
	if candidates.is_empty():
		return null
	for v in candidates:
		if v.home == null or not is_instance_valid(v.home):
			return v
	var worst = candidates[0]
	for v in candidates:
		if v.happiness < worst.happiness:
			worst = v
	return worst

## 当前时代（1~5），按人口判定
func current_era() -> int:
	var pop := villagers_root.get_child_count()
	var era := 1
	for i in ERA_POP.size():
		if pop >= ERA_POP[i]:
			era = i + 1
	return era

## 时代目标行带进度数字（资源用单字，给顶栏省宽度）
func era_goal_progress() -> String:
	var pop := villagers_root.get_child_count()
	match current_era():
		1:
			return "人口 %d/15" % pop
		2:
			var dressed := 0
			for v in villagers_root.get_children():
				if v.has_clothes:
					dressed += 1
			return "人口 %d/40 · 有衣 %d/%d" % [pop, dressed, pop]
		3:
			return "人口 %d/100 · 教堂 %d · 酒馆 %d" % [pop, _count_building("church"), _count_building("tavern")]
		4:
			var guards := 0
			for v in villagers_root.get_children():
				if v.role == Villager.Role.GUARD:
					guards += 1
			return "人口 %d/250 · 卫兵 %d · 箭塔 %d" % [pop, guards, _count_building("watchtower")]
		_:
			if crowned:
				return "已加冕，自由建设"
			return "木 %d/100 · 石 %d/80 · 金 %d/50" % [
				resources.get_amount(ResourceManager.Type.WOOD),
				resources.get_amount(ResourceManager.Type.STONE),
				resources.get_amount(ResourceManager.Type.GOLD)]

func _count_building(id: String) -> int:
	var n := 0
	for b in buildings_root.get_children():
		if String(b.data.get("id", "")) == id:
			n += 1
	return n

## 新手引导：前 6 天的六步目标（纯派生、零状态）。0 = 已完成/隐藏，1~6 = 当前步
func tutorial_step() -> int:
	# 六步引导覆盖前 6 天；第 4 步要等伐木场攒木头（39 木支出 > 开局 40 木的富余很快被花掉）
	if time_mgr.day > 6 or not _game_started:
		return 0
	if _count_building("gatherer") == 0:
		return 1  # 采集小屋：先解决吃饭
	if _count_building("lumber") == 0:
		return 2  # 伐木场：木材是建造货币
	if _count_building("house") < 3:
		return 3  # 住房：解除幸福度死亡螺旋、吸引移民
	if _count_building("nursery") == 0:
		return 4  # 植树场：让森林循环再生（麦田不算完成——首次森林耗尽在等它）
	if _count_building("fisher") == 0:
		return 5  # 渔屋：食物第二条产线，冬季不断
	if _count_building("well") == 0:
		return 6  # 水井：幸福光环
	return 0

# ---------- 引导里程碑奖励（每完成一步发一份资源，前期正反馈） ----------

const TUTORIAL_REWARDS := {
	1: [[ResourceManager.Type.FOOD, 6]],
	2: [[ResourceManager.Type.WOOD, 6]],
	3: [[ResourceManager.Type.FOOD, 8]],
	4: [[ResourceManager.Type.WOOD, 6]],
	5: [[ResourceManager.Type.FOOD, 6]],
	6: [[ResourceManager.Type.STONE, 3]],
}
var _tutorial_last := 0  # 上次所处的引导步（-1=读档恢复，不补发奖励）
var _tutorial_claimed := {}  # 已发过奖励的引导步（防拆了重建反复领）

func _check_tutorial_reward(step: int) -> void:
	if _tutorial_last == -1:
		_tutorial_last = step  # 读档恢复：不补发奖励，避免幽灵 toast 与重复发奖
		return
	var completed := -1
	if step > _tutorial_last:
		completed = step - 1  # 进入新步骤 = 完成了上一步
	elif step == 0 and _tutorial_last >= 1 and _tutorial_last <= 6:
		completed = _tutorial_last  # 引导毕业：最后所处步骤视为完成（覆盖跳序完成）
	if completed >= 1 and not _tutorial_claimed.has(completed):
		_tutorial_claimed[completed] = true
		var reward: Array = TUTORIAL_REWARDS.get(completed, [])
		if not reward.is_empty():
			var parts := PackedStringArray()
			for e in reward:
				resources.add(e[0], e[1])
				parts.append("%s+%d" % [ResourceManager.NAMES[e[0]], e[1]])
			hud.show_toast("完成引导第 %d 步！奖励：%s" % [completed, "、".join(parts)], 4.0)
	_tutorial_last = step

# ---------- 覆灭判定 ----------

var _collapse_days := 0     # 连续满足"覆灭条件"的天数
var _collapse_shown := false  # 覆灭面板本次开局只弹一次

## 王国覆灭：人口归零且存粮低于移民闸下限（4）。
## 0 人口时没有任何产能、拆建筑也退不出食物——这个状态在数学上不可恢复，
## 木头多少都救不回来（建房要人，移民要粮），所以不设木头门槛。
## 连续 2 天成立才弹（第一天先给一条倒计时 toast）；袭击进行中不判定
func _check_collapse() -> void:
	var doomed := villagers_root.get_child_count() == 0 \
		and resources.edible_amount() < 4 \
		and not raid.raid_active
	_collapse_days = _collapse_days + 1 if doomed else 0
	if _collapse_days >= 2 and not _collapse_shown and _game_started:
		_collapse_shown = true
		hud.show_collapse_panel()
	elif _collapse_days == 1 and _game_started:
		hud.show_toast("王国已空无一人，若无转机明日将覆灭（可读取存档）", 6.0)

## 自动存档（活着才存）：覆灭态的空档不该顶掉 autosave.json 里的好档
func _autosave_if_alive() -> void:
	if _game_started and villagers_root.get_child_count() > 0:
		save_game(SaveManager.AUTOSAVE)

## 每天结算一次每个村民的幸福度，写入全局平均值。
## 光环类需求（水井/教堂/酒馆）以「住所是否在覆盖半径内」判定，无家可归者吃不到光环。
func _update_happiness() -> void:
	var era := current_era()
	var villagers := villagers_root.get_children()
	# —— 第一遍：光环覆盖集合 ——
	var well_set := {}
	var faith_set := {}
	var castle_bonus := 0.0
	var taverns: Array = []
	for b in buildings_root.get_children():
		var kind := String(b.data.get("aura_kind", ""))
		if kind.is_empty():
			continue
		if int(b.data.get("workers", 0)) > 0 and not b.worked_today:
			continue  # 需要工人的光环建筑（教堂/酒馆）白天没人到岗就不生效
		if kind == "castle":
			castle_bonus = 10.0  # 城堡是全局加成，不看距离
			continue
		var radius := int(b.data.get("aura_radius", 0))
		if radius <= 0:
			continue
		if kind == "fun":
			# 酒馆要扣啤酒，单独处理；时代跌破Ⅲ后娱乐分不再结算，也别再白扣啤酒
			if era >= 3:
				taverns.append(b)
			continue
		var target: Dictionary = well_set if kind == "well" else faith_set
		for v in villagers:
			if _in_aura(v, b, radius):
				target[v] = true
	# —— 酒馆娱乐：每馆日服务上限，啤酒不足则当天该馆全体无加成 ——
	var fun_set := {}
	for t in taverns:
		var covered: Array = []
		for v in villagers:
			if _in_aura(v, t, int(t.data.get("aura_radius", 0))):
				covered.append(v)
		covered.shuffle()  # 名额随机轮转，别让树序最老的村民垄断娱乐
		# 服务上限随时代扩容（时代3:8 / 4:16 / 5:32），否则大人口下娱乐不可达；
		# 啤酒不够时按库存允许部分服务（ceil(人数/2)≤库存 ⟺ 人数≤库存×2），不再全有全无
		var serve_cap: int = int(t.data.get("serves", 0)) * (1 << maxi(0, era - 3))
		var served: int = mini(mini(covered.size(), serve_cap),
				resources.get_amount(ResourceManager.Type.BEER) * 2)
		if served <= 0:
			continue
		var cost := int(ceili(served / 2.0))
		if resources.try_spend([[ResourceManager.Type.BEER, cost]]):
			for v in covered.slice(0, served):
				fun_set[v] = true
	# —— 第二遍：逐人结算 ——
	var total := 0.0
	for v in villagers:
		var h := 50.0
		if v.home != null and is_instance_valid(v.home):
			h += 10
		else:
			h -= 30
		if v.last_ate_bread:
			h += 10
		if v.hunger > Villager.HUNGRY_AT:
			h -= 20
		if well_set.has(v):
			h += 5
		if era >= 2:
			h += 10.0 if v.has_clothes else -10.0
		if era >= 3:
			# 袭击当天全民逃难、福利建筑必然停摆，缺席惩罚与士气惩罚不叠加。
			# 日结发生在"次日零点"（day 已自增），袭击日=昨天，必须用 day-1 判定；
			# 跨天进行的袭击 raid_active 仍为真，一并豁免
			var raid_day: bool = raid.raid_active or raid.raid_started_day == time_mgr.day - 1
			h += 10.0 if faith_set.has(v) else (0.0 if raid_day else -5.0)
			h += 10.0 if fun_set.has(v) else (0.0 if raid_day else -5.0)
		h += castle_bonus
		if raid.raid_mood_days_left > 0:
			h += raid.raid_mood_bonus
		if event_mgr.mood_days_left > 0:
			h += event_mgr.mood_bonus
		v.happiness = clampf(h, 0.0, 100.0)
		v.last_ate_bread = false
		total += v.happiness
	resources.happiness = total / maxf(1.0, float(villagers.size()))

## 住所是否在建筑光环半径内；无家可归者不算
func _in_aura(v, b, radius: int) -> bool:
	if v.home == null or not is_instance_valid(v.home):
		return false
	return v.home.world_pos().distance_to(b.world_pos()) <= radius * GridManager.TILE

## 时代Ⅱ起：每天清晨给没衣服的村民发一件（库存够的话），衣服穿 8~12 天后破损
func _distribute_clothes() -> void:
	for v in villagers_root.get_children():
		if v.has_clothes:
			v.clothes_days -= 1
			if v.clothes_days <= 0:
				v.has_clothes = false
		if not v.has_clothes and current_era() >= 2 \
				and resources.try_spend([[ResourceManager.Type.CLOTHES, 1]]):
			v.has_clothes = true
			v.clothes_days = randi_range(CLOTHES_WEAR_MIN, CLOTHES_WEAR_MAX)

## 市场（时代Ⅳ）：每天清晨自动卖出富余产物换金币，每市场每天上限 20 金
func _market_trading() -> void:
	var pop := villagers_root.get_child_count()
	# 保留线：库存低于这个数量不卖。面包只留 pop（它与移民囤粮线 pop*2 脱钩，
	# 否则面包永远压在囤粮线下卖不出去）；生食仍留两天的量
	var reserves := {
		ResourceManager.Type.BREAD: pop,
		ResourceManager.Type.FOOD: pop * 2,
		ResourceManager.Type.CLOTHES: pop,
		ResourceManager.Type.BEER: 10,
	}
	# 单价（贵的先卖，尽量凑满每日上限）
	var prices := {
		ResourceManager.Type.CLOTHES: 3,
		ResourceManager.Type.BEER: 3,
		ResourceManager.Type.BREAD: 2,
		ResourceManager.Type.FOOD: 1,
	}
	var order := [ResourceManager.Type.CLOTHES, ResourceManager.Type.BEER,
		ResourceManager.Type.BREAD, ResourceManager.Type.FOOD]
	for b in buildings_root.get_children():
		if not b.data.get("auto_sells", false):
			continue
		if int(b.data.get("workers", 0)) > 0 and not b.worked_today:
			# 停工日清空战报，详情面板不挂 N 天前的旧数据
			b.last_sale = {"gold": 0, "items": {}}
			continue
		var gold := 0
		var sold := {}
		for t in order:
			var price := int(prices.get(t, 0))
			if price <= 0:
				continue
			var surplus: int = resources.get_amount(t) - int(reserves.get(t, 0))
			var day_cap: int = int(b.data.get("sell_cap", MARKET_DAILY_CAP))  # 货摊 8 / 市场 20
			var n: int = mini(surplus, (day_cap - gold) / price)
			if n <= 0:
				continue
			if resources.try_spend([[t, n]]):
				gold += n * price
				sold[t] = n
		if gold > 0:
			resources.add(ResourceManager.Type.GOLD, gold)
		b.last_sale = {"gold": gold, "items": sold}
	# —— 贸易站（时代Ⅴ）：用金币收购石料/木材，给金币一个持续出口、缓解城堡石料瓶颈 ——
	for b in buildings_root.get_children():
		var buys: Array = b.data.get("auto_buys", [])
		if buys.is_empty():
			continue
		if int(b.data.get("workers", 0)) > 0 and not b.worked_today:
			b.last_sale = {"gold": 0, "items": {}}
			continue
		var spent := 0
		var bought := {}
		for entry in buys:
			var res_type: int = entry[0]
			var price := int(entry[1])
			var cap := int(entry[2])
			if price <= 0 or cap <= 0:
				continue
			# 单站日支出上限 40 金（≈两个市场的日收入）；金币低于保底 50 不买，不动加冕基金
			var budget := mini(cap * price, 40 - spent)  # 金币口径
			var affordable: int = (resources.get_amount(ResourceManager.Type.GOLD) - TRADE_GOLD_RESERVE) / price  # 件数口径
			var n: int = mini(budget / price, affordable)
			if n <= 0:
				continue
			if resources.try_spend([[ResourceManager.Type.GOLD, n * price]]):
				resources.add(res_type, n)
				spent += n * price
				bought[res_type] = n
		b.last_sale = {"gold": -spent, "items": bought}

## 卫兵日结：兵营没了或发不出军饷就脱下军装；在岗卫兵每天回血
func _guard_daily() -> void:
	var unpaid := 0  # 当天因断饷脱装的人数
	for v in villagers_root.get_children():
		if v.role != Villager.Role.GUARD:
			continue
		if v.workplace == null or not is_instance_valid(v.workplace) \
				or not v.workplace.data.get("trains_guards", false):
			v.role = Villager.Role.COMMONER
			continue
		if not resources.try_spend([[ResourceManager.Type.GOLD, GUARD_WAGE]]):
			print("%s 因军饷不足脱下军装" % v.display_name)
			v.role = Villager.Role.COMMONER
			unpaid += 1
			continue
		v.hp = mini(v.hp + GUARD_HEAL_PER_DAY, Villager.GUARD_MAX_HP)
	# 断饷退役集中播报一次，别让玩家漏看经济崩了
	if unpaid > 0 and hud != null:
		hud.show_toast("%d 名卫兵因军饷不足退役" % unpaid, 4.0)

## 放置完成（土路传 null）：刷新分配；城堡落成触发加冕
func _on_placed(b) -> void:
	if b == null:
		return  # 土路不影响工人/住房分配，无需刷新（拖动铺路每格都会触发这里）
	_on_construction_changed()
	_check_tutorial_reward(tutorial_step())
	if b != null and int(b.data.get("workers", 0)) > 0 and b.workers.is_empty() \
			and not b.data.get("trains_guards", false):
		assign_worker(b, true)  # 放置生产/功能建筑自动招 1 名工人（失败不刷屏）
	if b != null and not crowned and String(b.data.get("aura_kind", "")) == "castle":
		crowned = true
		hud.show_coronation()

func _on_construction_changed() -> void:
	cleanup_assignments()
	reassign_homes()
	_check_tutorial_reward(tutorial_step())

## 左键点击地图：优先选中点到的村民，其次查看建筑
var _inspected = null  # 当前被查看详情的建筑（画工作区域圈用）

func _on_inspect(cell: Vector2i) -> void:
	var world := grid.cell_center(cell)
	var best: Villager = null
	var best_dist := 24.0  # 点击判定半径（像素）
	for v in villagers_root.get_children():
		var d: float = v.position.distance_to(world)
		if d < best_dist:
			best = v
			best_dist = d
	if best != null:
		_set_inspected_building(null)  # 看村民时不画建筑工作区
		hud.show_villager(best)
	else:
		var b = grid.building_at(cell)
		_set_inspected_building(b)
		hud.show_building(b)

## 工作区域可视化：选中资源建筑（伐木场/植树场/采集小屋/采石场）时画工作圈
func _set_inspected_building(b) -> void:
	if _inspected != null and is_instance_valid(_inspected):
		_inspected.show_work_area = false
	_inspected = b
	if b != null and is_instance_valid(b):
		b.show_work_area = true

## 详情面板关闭/建筑被拆时清掉工作区域圈
func clear_building_inspect() -> void:
	_set_inspected_building(null)
	hud.show_building(null)

## 点顶栏「空闲」：镜头循环跳到下一个空闲村民并打开详情
func focus_next_idle() -> void:
	var idle := []
	for v in villagers_root.get_children():
		if v.workplace == null:
			idle.append(v)
	if idle.is_empty():
		hud.show_toast("当前没有空闲村民", 2.0)
		return
	var v = idle[_idle_focus_idx % idle.size()]
	_idle_focus_idx += 1
	camera.position = v.position
	hud.show_villager(v)

func _on_place_failed(msg: String) -> void:
	hud.show_toast(msg, 2.5)

## 村民列表里点某个村民：镜头移过去并打开详情
func focus_villager(v: Villager) -> void:
	if is_instance_valid(v):
		camera.position = v.position
		hud.show_villager(v)

## 解除某个村民的工作（村民详情面板调用）
func unassign_villager(v: Villager) -> void:
	if v.workplace != null and is_instance_valid(v.workplace):
		v.workplace.workers.erase(v)
	v.workplace = null
	v.work_cell = Vector2i(-1, -1)
	v.role = Villager.Role.COMMONER  # 手动解除工作同样退役
	if v.state == Villager.State.WORKING:
		v.state = Villager.State.IDLE

# ---------- 工作分配（手动，详情面板 +/− 按钮调用） ----------

## 只清理失效引用（村民饿死、建筑被拆），不自动分配
func cleanup_assignments() -> void:
	for b in buildings_root.get_children():
		b.workers = b.workers.filter(func(w): return is_instance_valid(w))
	for v in villagers_root.get_children():
		if v.workplace != null and not is_instance_valid(v.workplace):
			v.workplace = null
			v.work_cell = Vector2i(-1, -1)

## 给建筑增加一名工人；没有空闲村民或岗位已满则无效（有多名空闲时就近挑选）
func assign_worker(b, silent := false) -> void:
	var max_workers: int = b.data.get("workers", 0)
	if max_workers <= 0:
		return
	if b.workers.size() >= max_workers:
		if not silent:
			hud.show_toast("岗位已满", 2.0)
		return
	var v := _find_unemployed_villager(b)
	if v == null:
		if not silent:
			hud.show_toast("没有空闲村民——等移民，或看看引导里还缺什么", 2.5)
		return
	var cell := grid.find_adjacent_walkable(b.origin, b.data.get("size", Vector2i.ONE))
	if cell.x < 0:
		if not silent:
			hud.show_toast("建筑四周被堵死，进不去人", 2.5)
		return  # 建筑四周被堵死，进不去人
	b.workers.append(v)
	v.workplace = b
	v.work_cell = cell
	# 进兵营 = 参军（保留原有 hp，退役再入伍不再等于免费医疗）
	if b.data.get("trains_guards", false):
		v.role = Villager.Role.GUARD

## 撤掉建筑的一名工人
func unassign_worker(b) -> void:
	b.workers = b.workers.filter(func(w): return is_instance_valid(w))
	if b.workers.is_empty():
		return
	var v = b.workers.pop_back()
	v.workplace = null
	v.work_cell = Vector2i(-1, -1)
	v.role = Villager.Role.COMMONER  # 离开兵营 = 退役
	if v.state == Villager.State.WORKING:
		v.state = Villager.State.IDLE

## 一键招满的产业链优先级：食物/原料链最先补人，避免树序把人全填进后期建筑饿死全村
const ASSIGN_PRIORITY: Array[String] = [
	"gatherer", "fisher", "farm", "lumber", "nursery", "quarry", "mill", "bakery",
	"pasture", "weaver", "brewery", "church", "tavern", "market", "stall", "trade_post", "watchtower",
]

## 顶栏「一键招满」：按产业链优先级轮转补人（每栋先到 1 人再补满），无空闲村民即停
func assign_all_workers() -> void:
	var order := {}
	for i in ASSIGN_PRIORITY.size():
		order[ASSIGN_PRIORITY[i]] = i
	var pending: Array = []
	for b in buildings_root.get_children():
		var max_workers: int = b.data.get("workers", 0)
		if max_workers <= 0 or b.workers.size() >= max_workers:
			continue
		if b.data.get("trains_guards", false):
			continue  # 卫兵仍需手动指派，避免一键征兵
		pending.append(b)
	pending.sort_custom(func(a, b):
		var pa: int = order.get(String(a.data.get("id", "")), 99)
		var pb: int = order.get(String(b.data.get("id", "")), 99)
		return pa < pb)
	var rounds := 0
	var total := 0
	var progress := true
	while progress and rounds < 500:
		rounds += 1
		progress = false
		for b in pending:
			var max_workers: int = b.data.get("workers", 0)
			if max_workers <= 0 or b.workers.size() >= max_workers:
				continue
			var before: int = b.workers.size()
			assign_worker(b, true)
			if b.workers.size() > before:
				progress = true
				total += 1
		# 每轮结束若一轮里一次都没招到人，说明没有空闲村民了

## 找一名无业村民；near 非 null 时选离 near（建筑）最近的，否则取首个命中
func _find_unemployed_villager(near = null) -> Villager:
	var best: Villager = null
	var best_d := INF
	for v in villagers_root.get_children():
		if v.workplace != null:
			continue
		if near == null:
			return v
		var d: float = near.world_pos().distance_to(v.position)
		if d < best_d:
			best_d = d
			best = v
	return best

# ---------- 住房分配 ----------

func reassign_homes() -> void:
	for b in buildings_root.get_children():
		b.residents = b.residents.filter(func(w): return is_instance_valid(w))
	for v in villagers_root.get_children():
		if v.home != null and not is_instance_valid(v.home):
			v.home = null
			v.home_cell = Vector2i(-1, -1)
	for b in buildings_root.get_children():
		var capacity: int = b.data.get("housing", 0)
		while b.residents.size() < capacity:
			var v := _find_homeless_villager(b)
			if v == null:
				break  # 没有无房村民了：跳出本栋继续外层；不能 return，会掐死下面的通勤调剂
			var cell := grid.find_adjacent_walkable(b.origin, b.data.get("size", Vector2i.ONE))
			if cell.x < 0:
				break
			b.residents.append(v)
			v.home = b
			v.home_cell = cell
	_rebalance_long_commuters()

## 通勤调剂：住所离工作点太远的村民，搬到离工作点更近的空位，
## 不再"一个村民绑死一个远房"每天长途跋涉。每天最多搬 2 人，防来回折腾。
const COMMUTE_LIMIT_TILES := 8  # 住所到工作点超过 8 格视为长途通勤

func _rebalance_long_commuters() -> void:
	# 每次搬迁都严格缩短人-岗距离（单调，无振荡），上限与空位数挂钩：
	# 满员 0 空位时无事可做，空位多时放开手速（实测 2 人/天要 84 天才收敛完）
	var vacancies := 0
	for b in buildings_root.get_children():
		var cap: int = b.data.get("housing", 0)
		if cap > 0:
			vacancies += maxi(0, cap - b.residents.size())
	var moved := 0
	var moved_max := maxi(2, vacancies)
	for v in villagers_root.get_children():
		if moved >= moved_max:
			break
		if v.home == null or not is_instance_valid(v.home) \
				or v.workplace == null or not is_instance_valid(v.workplace):
			continue
		var old_d: float = v.home.world_pos().distance_to(v.workplace.world_pos())
		if old_d <= COMMUTE_LIMIT_TILES * GridManager.TILE:
			continue
		var best_b = null
		var best_d := old_d
		for b in buildings_root.get_children():
			if b == v.home or int(b.data.get("housing", 0)) <= 0:
				continue
			if b.residents.size() >= int(b.data.get("housing", 0)):
				continue
			var d: float = b.world_pos().distance_to(v.workplace.world_pos())
			if d < best_d:
				best_d = d
				best_b = b
		if best_b != null:
			v.home.residents.erase(v)
			best_b.residents.append(v)
			v.home = best_b
			v.home_cell = grid.find_adjacent_walkable(best_b.origin,
				best_b.data.get("size", Vector2i.ONE))
			moved += 1

## 找一名无房村民；near 非 null 时选离 near（建筑）最近的，否则取首个命中
func _find_homeless_villager(near = null) -> Villager:
	var best: Villager = null
	var best_d := INF
	for v in villagers_root.get_children():
		if v.home != null:
			continue
		if near == null:
			return v
		var d: float = near.world_pos().distance_to(v.position)
		if d < best_d:
			best_d = d
			best = v
	return best

func _housing_capacity() -> int:
	var total := 0
	for b in buildings_root.get_children():
		total += int(b.data.get("housing", 0))
	return total

# ---------- 菜单控制 ----------

func is_game_started() -> bool:
	return _game_started

func show_menu() -> void:
	_panning = false  # 暂停/菜单可能吞掉松开事件，防中键平移卡死
	hud.visible = false  # 进菜单时隐藏游戏 HUD
	Engine.time_scale = 1.0  # 倍速跨菜单/读档不复位会让暂停语义混乱
	menu.show_menu()
	get_tree().paused = true

## 关闭菜单，恢复游戏
func resume_play() -> void:
	menu.visible = false
	hud.visible = true
	get_tree().paused = false

## 返回主菜单：强制自动存档（覆灭态不存，防死档顶掉好档），游戏标记为未开始
func return_to_menu() -> void:
	_autosave_if_alive()
	_game_started = false
	hud.show_building(null)
	show_menu()

## 开新游戏：清空世界重新生成（不覆盖旧存档，退出时会存 autosave）
func new_game() -> void:
	Engine.time_scale = 1.0
	_collapse_days = 0
	_collapse_shown = false
	_tutorial_last = 0
	_tutorial_claimed.clear()
	event_mgr.reset()
	hud.hide_collapse_panel()
	for v in villagers_root.get_children():
		v.free()
	for b in buildings_root.get_children():
		b.free()
	placer.cancel()
	# 重置袭击与加冕状态
	crowned = false
	raid.retreat()
	raid.next_raid_day = -1
	raid.raid_pending = false
	raid.raid_started_day = -1
	raid.raid_mood_bonus = 0
	raid.raid_mood_days_left = 0
	raid.raid_warned = false  # 清掉可能挂着的「明日来袭」预警状态
	raid.banner_text = ""
	grid.generate_map()
	resources.reset()
	time_mgr.day = 1
	time_mgr.time_of_day = 0.3
	time_mgr.season = TimeManager.Season.SPRING
	_last_season = time_mgr.season  # 防读档/重开时误弹"冬季来临"
	_villager_seq = 0
	for i in 5:
		spawn_villager()
	# 开局先日结一次幸福度，否则要等到次日清晨前顶栏显示的都是假的中性值 50
	_update_happiness()
	hud.invalidate_villager_list()
	_game_started = true
	resume_play()

## 菜单主按钮：有存档 = 继续游戏（读最新档），无存档 = 开始新游戏
func start_or_continue() -> void:
	var saves := get_save_list()
	if saves.is_empty():
		_game_started = true
		_update_happiness()  # 无存档开局是新手唯一入口：立刻结算出真实幸福度（无房=20），别显示假 50
		hud.invalidate_villager_list()
		resume_play()
	else:
		load_and_play(saves[0]["path"])

## HUD 里的「读取」按钮：先把当前进度写进自动存档（防止误触回滚丢进度），再打开选存档面板。
## autosave_first=false 供覆灭面板的"读取存档"使用：死档绝不能顶进 autosave.json
func open_load_menu(autosave_first := true) -> void:
	# 袭击进行中不自动存档：save_game 会把 raid_active 强制结算成撤退，等于用读档面板白嫖一次无敌
	if autosave_first and _game_started and not raid.raid_active 			and villagers_root.get_child_count() > 0:
		save_game(SaveManager.AUTOSAVE)  # 覆灭态的死档不顶 autosave（与 _autosave_if_alive 同口径）
	hud.hide_collapse_panel()  # 覆灭面板与读取面板同为中心锚点，打开读取时收起遮罩
	menu.show_menu()
	menu.show_load_panel()
	get_tree().paused = true

func load_and_play(path: String) -> void:
	if load_game(path):
		Engine.time_scale = 1.0
		_collapse_days = 0
		_collapse_shown = false
		_tutorial_last = -1  # 读档不补发引导奖励
		event_mgr.reset()
		hud.hide_collapse_panel()
		_game_started = true
		resume_play()
	else:
		menu.show_menu()
		menu.set_status("该存档无法读取（版本不兼容或已损坏）")

## 结束游戏：强制自动存档后退出
func quit_game() -> void:
	_autosave_if_alive()
	get_tree().quit()

## 点窗口右上角 X 关闭时也会走到这里，同样强制存档
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and _game_started:
		_autosave_if_alive()

# ---------- 存档 / 读档 facade（实现已拆至 save_manager.gd，SaveManager 于 _ready 注入） ----------

## 存档目录（只读转发 SaveManager.save_dir）
var save_dir: String:
	get:
		return save_mgr.save_dir

## 保存。slot_name 为空时按当前时间生成新存档文件
func save_game(slot_name := "") -> void:
	save_mgr.save_game(slot_name)

## 读档，成功返回 true。带版本号与字段校验，坏档不会崩
func load_game(path: String) -> bool:
	return save_mgr.load_game(path)

## 列出所有存档（按保存时间倒序），供菜单选择
func get_save_list() -> Array:
	return save_mgr.get_save_list()

func delete_save(path: String) -> void:
	save_mgr.delete_save(path)

# ---------- 镜头 ----------

func _process(delta: float) -> void:
	# 用物理键位，非 QWERTY 键盘布局也能用
	var dir := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W): dir.y -= 1
	if Input.is_physical_key_pressed(KEY_S): dir.y += 1
	if Input.is_physical_key_pressed(KEY_A): dir.x -= 1
	if Input.is_physical_key_pressed(KEY_D): dir.x += 1
	if dir != Vector2.ZERO:
		camera.position += dir.normalized() * 500 * delta / camera.zoom.x
	# 昼夜色温：让一天的时间流动肉眼可见（白天亮 → 黄昏橙 → 夜晚蓝暗 → 黎明回暖）
	var tod := time_mgr.time_of_day
	var col := Color(1, 1, 1)
	var night := Color(0.5, 0.55, 0.8)
	if tod < 0.15:
		col = night
	elif tod < 0.2:
		col = night.lerp(Color(1, 1, 1), (tod - 0.15) / 0.05)
	elif tod < 0.7:
		col = Color(1, 1, 1)
	elif tod < 0.8:
		col = Color(1, 1, 1).lerp(Color(1.0, 0.82, 0.62), (tod - 0.7) / 0.1)
	elif tod < 0.85:
		col = Color(1.0, 0.82, 0.62).lerp(night, (tod - 0.8) / 0.05)
	else:
		col = night
	day_tint.color = day_tint.color.lerp(col, clampf(delta * 3.0, 0.0, 1.0))
	# 袭击警告横幅（傍晚到点挂出）
	raid.tick(current_era())

func _unhandled_input(event: InputEvent) -> void:
	# ESC：放置模式下先取消放置，否则开关菜单（游戏未开始时不许关掉主菜单；长按不重复触发）
	var key := event as InputEventKey
	if key != null and key.pressed and key.keycode == KEY_ESCAPE and not key.echo:
		if not placer.selected.is_empty():
			placer.cancel()
		elif placer._pending_demolish.x >= 0:
			placer.cancel()  # 只清待确认拆除的红框
		elif menu.visible:
			if _game_started:
				resume_play()
		else:
			show_menu()
		return
	# 空格：1×/2×/4× 循环倍速（项目无 Timer/音效依赖，仅寻路负载在 4× 下需留意）
	if key != null and key.pressed and key.keycode == KEY_SPACE and not key.echo and _game_started:
		if Engine.time_scale <= 0.0:
			Engine.time_scale = _paused_speed  # 暂停中按空格 = 恢复
		else:
			Engine.time_scale = 1.0 if Engine.time_scale >= 4.0 else Engine.time_scale * 2.0
		hud.show_toast("游戏速度 ×%d" % int(Engine.time_scale), 1.5)
		return
	# 快捷键：B 建造菜单 / L 村民列表
	if key != null and key.pressed and not key.echo and _game_started:
		if key.keycode == KEY_B:
			hud._toggle_build_menu()
			return
		if key.keycode == KEY_L:
			hud._toggle_villager_panel()
			return
	# P：暂停/恢复（暂停前记住倍速，恢复原样；time_scale=0 时 delta=0，全游戏冻结但输入仍响应）
	if key != null and key.pressed and key.keycode == KEY_P and not key.echo and _game_started:
		if Engine.time_scale <= 0.0:
			Engine.time_scale = _paused_speed
			hud.show_toast("继续（×%d）" % int(Engine.time_scale), 1.5)
		else:
			_paused_speed = Engine.time_scale
			Engine.time_scale = 0.0
			hud.show_toast("已暂停（按 P 继续）", 3.0)
		return
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed:
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at_mouse(1.1)
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at_mouse(1.0 / 1.1)
			return
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_panning = true  # 按住中键拖动平移镜头
			return
	elif mb != null and not mb.pressed and mb.button_index == MOUSE_BUTTON_MIDDLE:
		_panning = false
		return
	if event is InputEventMouseMotion and _panning:
		camera.position -= event.relative / camera.zoom.x
		return
	placer.handle_input(event)

## 以鼠标位置为锚点缩放（缩放前后鼠标下的世界点保持不动，RTS 标准手感）
func _zoom_at_mouse(factor: float) -> void:
	var before := get_global_mouse_position()
	camera.zoom = (camera.zoom * factor).clamp(Vector2(0.4, 0.4), Vector2(3.0, 3.0))
	var after := get_global_mouse_position()
	camera.position += before - after
