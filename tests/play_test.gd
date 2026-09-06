extends SceneTree

## 实机玩法冒烟：新开局 → 真实运转 12 游戏秒 → 跨午夜日结 → 存读档。
## 运行方式：godot --headless --path <项目> --script tests/play_test.gd
## 与 smoke_test 的区别：本测试真正 new_game()（不暂停），村民 AI/生产/幸福度日结全部实跑。
## 迭代10/11 追加：建筑升级（含存读档回环）、冬季取暖烧柴、生食腐坏、新手保护期。
## 断言用 _expect()：失败时打印 [FAIL]，run_gate 以此判 NO-GO。

var _fails := 0

func _expect(cond: bool, msg: String) -> void:
	if cond:
		print("   [ok] ", msg)
	else:
		_fails += 1
		print("   [FAIL] ", msg)

func _initialize() -> void:
	print("=== PLAY TEST START ===")
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	# 1. 新开局（不暂停，真实运转）
	main.new_game()
	await process_frame
	print("1. 新开局: 已开始=%s 暂停=%s 幸福度=%d" % [
		main.is_game_started(), paused, int(main.resources.happiness)])

	# 2. 自动招工是否生效（放置自动招 1 人）
	var grid = main.grid
	var placed := 0
	var lumber_conf := BuildingCatalog.find_by_id(&"lumber")
	for x in range(0, grid.width, 3):
		for y in range(0, grid.height, 3):
			var c := Vector2i(x, y)
			if grid.can_place(c, Vector2i.ONE, lumber_conf):
				main.placer.selected = lumber_conf
				main.placer._try_place(c)
				placed += 1
				break
		if placed > 0:
			break
	await process_frame
	print("2. 放置伐木场: %d 座, 在职工人 %d" % [placed, _present_workers(main)])

	# 3. 真实运转 720 帧（12 游戏秒，村民应去上班/吃饭/走动）
	var frames := 0
	while frames < 720:
		await process_frame
		frames += 1
	print("3. 运转 720 帧后状态：")
	for v in main.villagers_root.get_children():
		print("   ", v.display_name, " → ", v.state_text(), " 饥饿 ", int(v.hunger))
	var any_working := false
	for v in main.villagers_root.get_children():
		if v.state == v.State.WORKING:
			any_working = true
	print("4. 有村民在工作中: ", any_working)

	# 4. 推进到跨午夜（日结 happiness/市场/移民闸实跑一次）
	main.time_mgr.time_of_day = 0.999
	for i in 30:
		await process_frame
	print("5. 跨日完成: 第%d天 全局幸福 %d 村民数 %d" % [
		main.time_mgr.day, int(main.resources.happiness), main.villagers_root.get_child_count()])

	# 4.5 事件系统效果解释器（工匠+1人 / 行商扣食加金 / 节日 buff / 暴雨排期）
	var pop_before: int = main.villagers_root.get_child_count()
	var gold_before: int = main.resources.get_amount(main.resources.Type.GOLD)
	var food_before: int = main.resources.get_amount(main.resources.Type.FOOD)
	main.event_mgr.apply_effects({"villager": 1})
	main.event_mgr.apply_effects({"gold": 12, "food": -10})
	main.event_mgr.apply_effects({"mood": 10, "rain_tomorrow": true})
	print("4.5 事件效果: 人口 %d→%d 金 %d→%d 食 %d→%d 暴雨日=%d 节日buff=%d/%d" % [
		pop_before, main.villagers_root.get_child_count(),
		gold_before, main.resources.get_amount(main.resources.Type.GOLD),
		food_before, main.resources.get_amount(main.resources.Type.FOOD),
		main.event_mgr.halt_day, main.event_mgr.mood_bonus, main.event_mgr.mood_days_left])

	# 4.6 建筑升级：扣资源、提级、工位与产速变化
	var lb = null
	for b in main.buildings_root.get_children():
		if String(b.data.get("id", "")) == "lumber":
			lb = b
	if lb == null:
		_expect(false, "找得到刚放置的伐木场（升级测试前提）")
	else:
		var lv0: int = lb.level
		var slots0: int = lb.eff_workers()
		var cycle0: float = lb.eff_interval()
		# 给够升级钱再升，避免因资源不足让断言失去意义
		main.resources.add(main.resources.Type.WOOD, 100)
		var wood0: int = main.resources.get_amount(main.resources.Type.WOOD)
		var ok_up: bool = main.upgrade_building(lb)
		_expect(ok_up, "伐木场升级成功")
		_expect(lb.level == lv0 + 1, "等级 %d → %d" % [lv0, lb.level])
		_expect(lb.eff_workers() > slots0,
			"工位 %d → %d（升级开出新岗位）" % [slots0, lb.eff_workers()])
		_expect(lb.eff_interval() < cycle0,
			"生产周期 %.2f → %.2f 秒（提速生效）" % [cycle0, lb.eff_interval()])
		_expect(main.resources.get_amount(main.resources.Type.WOOD) < wood0, "升级扣掉了木材")
		_expect(lb.total_investment().size() > 0, "总投入可结算（拆除退款按它折半）")
		# 满级后不再可升
		while lb.can_upgrade():
			main.resources.add(main.resources.Type.WOOD, 200)
			main.resources.add(main.resources.Type.STONE, 200)
			main.upgrade_building(lb)
		_expect(lb.level == lb.max_level(), "升到满级 Lv%d" % lb.level)
		_expect(not main.upgrade_building(lb), "满级后再升级返回 false（不白扣资源）")

	# 4.7 冬季取暖：有住户的房子每天烧柴，木材归零则挨冻
	var house_conf := BuildingCatalog.find_by_id(&"house")
	var houses := 0
	for x in range(0, grid.width):
		for y in range(0, grid.height):
			if houses >= 2:
				break
			var hc := Vector2i(x, y)
			if grid.can_place(hc, Vector2i.ONE, house_conf):
				main.placer.selected = house_conf
				main.placer._try_place(hc)
				houses += 1
		if houses >= 2:
			break
	main.reassign_homes()
	await process_frame
	var season_backup: int = main.time_mgr.season
	main.time_mgr.season = TimeManager.Season.WINTER
	_expect(main.winter_heat_need() > 0, "冬季取暖需求 %d 木/天 > 0" % main.winter_heat_need())
	main.resources.add(main.resources.Type.WOOD, 50)
	var wood_before: int = main.resources.get_amount(main.resources.Type.WOOD)
	main._winter_heating()
	_expect(main.resources.get_amount(main.resources.Type.WOOD) < wood_before,
		"取暖烧掉木材 %d → %d" % [wood_before, main.resources.get_amount(main.resources.Type.WOOD)])
	_expect(main._cold_homes.is_empty(), "木材充足时无人挨冻")
	# 木材清零 → 挨冻集合非空
	main.resources.try_spend([[main.resources.Type.WOOD,
		main.resources.get_amount(main.resources.Type.WOOD)]])
	main._winter_heating()
	_expect(not main._cold_homes.is_empty(), "木材耗尽时有住户挨冻（幸福 −15 生效）")
	main._cold_homes.clear()
	main.time_mgr.season = season_backup

	# 4.8 生食腐坏：超过保鲜线的部分才烂，冬季不腐
	main.resources.add(main.resources.Type.FOOD, 300)
	var food_hi: int = main.resources.get_amount(main.resources.Type.FOOD)
	main._food_spoilage()
	var food_after: int = main.resources.get_amount(main.resources.Type.FOOD)
	_expect(food_after < food_hi, "囤积的生食会腐坏 %d → %d" % [food_hi, food_after])
	main.time_mgr.season = TimeManager.Season.WINTER
	var food_w: int = main.resources.get_amount(main.resources.Type.FOOD)
	main._food_spoilage()
	_expect(main.resources.get_amount(main.resources.Type.FOOD) == food_w, "冬季生食不腐坏")
	main.time_mgr.season = season_backup

	# 4.9 日流水记账与概览数据（概览面板读的就是这几个量）
	main.resources.roll_day()
	var in0: int = int(main.resources.last_in.get(main.resources.Type.WOOD, 0))
	main.resources.add(main.resources.Type.WOOD, 7)
	main.resources.try_spend([[main.resources.Type.WOOD, 3]])
	_expect(int(main.resources.flow_in.get(main.resources.Type.WOOD, 0)) >= 7, "add 记进项流水")
	_expect(int(main.resources.flow_out.get(main.resources.Type.WOOD, 0)) >= 3, "try_spend 记出项流水")
	main.resources.roll_day()
	_expect(main.resources.net_yesterday(main.resources.Type.WOOD) == 4,
		"昨日净额 = 7−3 = 4（实得 %d）" % main.resources.net_yesterday(main.resources.Type.WOOD))
	_expect(main.resources.flow_in.is_empty() and main.resources.flow_out.is_empty(),
		"跨日后今日流水清零重新开账")
	_expect(in0 >= 0, "roll_day 前后 last_in 可读")
	_expect(main.food_days_left() > 0.0, "存粮天数 %.1f 天可估算" % main.food_days_left())
	var idle_report: Dictionary = main.idle_building_report()
	_expect(idle_report is Dictionary, "停工盘点返回字典（%d 类）" % idle_report.size())
	# 概览面板能开且文本非空（迭代8 的教训：面板建出来了但根本没渲染内容）
	main.hud._toggle_overview_panel()
	_expect(main.hud._overview_panel.visible, "概览面板可打开")
	_expect(main.hud._overview_list.text.length() > 20, "概览面板有实际内容")
	main.hud._toggle_overview_panel()
	_expect(not main.hud._overview_panel.visible, "概览面板可关闭")

	# 4.10 村民特长：出生即有、影响班组效率、能跟着存档回来
	var traits_seen := {}
	for v in main.villagers_root.get_children():
		traits_seen[String(v.trait_id)] = true
		if not Villager.TRAITS.has(v.trait_id):
			_expect(false, "村民特长 %s 未定义" % v.trait_id)
	_expect(not traits_seen.is_empty(), "全体村民都带特长（%d 种在场）" % traits_seen.size())
	if lb != null and not lb.workers.is_empty():
		var w = lb.workers[0]
		w.trait_id = &"diligent"
		w.state = Villager.State.WORKING
		w.workplace = lb
		var power_d: float = lb.crew_power()
		w.trait_id = &"frail"
		var power_f: float = lb.crew_power()
		_expect(power_d > power_f,
			"勤劳班组人力 %.2f > 体弱 %.2f（特长真的改变产速）" % [power_d, power_f])
		w.trait_id = &"cheerful"
		_expect(w.mood_bonus() > 0.0, "乐观村民带幸福偏移")

	# 4.11 原料优先级：改优先级 = 改节点顺序（生产结算先到先得的那个"先"）
	var bake_conf := BuildingCatalog.find_by_id(&"bakery")
	var bakes: Array = []
	for x in range(0, grid.width):
		for y in range(0, grid.height):
			if bakes.size() >= 2:
				break
			var bc := Vector2i(x, y)
			if grid.can_place(bc, bake_conf.get("size", Vector2i.ONE), bake_conf):
				main.placer.selected = bake_conf
				main.resources.add(main.resources.Type.WOOD, 40)
				main.resources.add(main.resources.Type.STONE, 20)
				main.placer._try_place(bc)
				var nb = grid.building_at(bc)
				if nb != null:
					bakes.append(nb)
		if bakes.size() >= 2:
			break
	if bakes.size() >= 2:
		var first = bakes[0]
		var second = bakes[1]
		_expect(first.get_index() < second.get_index(), "同优先级时保持放置顺序")
		main.set_building_priority(second, 0)  # 后建的调成「高」
		_expect(second.get_index() < first.get_index(),
			"调高优先级后排到前面（先拿原料）：idx %d < %d"
			% [second.get_index(), first.get_index()])
		main.set_building_priority(second, 2)  # 再调成「低」
		_expect(second.get_index() > first.get_index(), "调低优先级后排到后面")
		main.set_building_priority(second, 1)
		_expect(second.priority == 1, "优先级可以调回常规")
	else:
		_expect(false, "放得下两座面包房（优先级测试前提）")

	# 4.12 粮仓：抬高生食保鲜线，超线才腐坏
	var keep_before: int = main.food_keep_line()
	var gran_conf := BuildingCatalog.find_by_id(&"granary")
	var placed_gran := false
	for x in range(0, grid.width):
		for y in range(0, grid.height):
			if placed_gran:
				break
			var gc := Vector2i(x, y)
			if grid.can_place(gc, gran_conf.get("size", Vector2i.ONE), gran_conf):
				main.placer.selected = gran_conf
				main.resources.add(main.resources.Type.WOOD, 40)
				main.resources.add(main.resources.Type.STONE, 20)
				main.placer._try_place(gc)
				placed_gran = grid.building_at(gc) != null
		if placed_gran:
			break
	_expect(placed_gran, "放下一座粮仓")
	_expect(main.granary_capacity() > 0, "粮仓保鲜容量 %d > 0" % main.granary_capacity())
	_expect(main.food_keep_line() > keep_before,
		"保鲜线 %d → %d（粮仓抬高）" % [keep_before, main.food_keep_line()])
	# 保鲜线以内的生食不腐坏
	main.time_mgr.season = TimeManager.Season.SPRING
	var target: int = main.food_keep_line()
	var cur: int = main.resources.get_amount(main.resources.Type.FOOD)
	if cur > target:
		main.resources.try_spend([[main.resources.Type.FOOD, cur - target]])
	else:
		main.resources.add(main.resources.Type.FOOD, target - cur)
	main._food_spoilage()
	_expect(main.resources.get_amount(main.resources.Type.FOOD) == target,
		"保鲜线以内（%d）的生食不腐坏" % target)

	# 4.13 野狼来袭：实机生成 → 跑几帧 → 撤退清场（时代Ⅱ~Ⅲ 的早期威胁）
	main.raid._spawn_raid(2)
	await process_frame
	_expect(main.raid.raid_active, "野狼袭击已开始")
	_expect(main.raid.raid_kind == &"wolf", "时代Ⅱ 生成的是野狼（实为 %s）" % main.raid.raid_kind)
	_expect(main.raid.enemies.size() >= 1, "场上有 %d 只狼" % main.raid.enemies.size())
	var all_wolves := true
	for e in main.raid.enemies:
		if not e.is_wolf() or e.hp != Enemy.WOLF_MAX_HP:
			all_wolves = false
	_expect(all_wolves, "全部单位是野狼且血量为野狼血上限")
	_expect(String(main.raid.banner_text).length() > 0, "挂出了狼群横幅")
	for i in 90:
		await process_frame
	_expect(main.raid.raid_active or main.raid.enemies.is_empty(),
		"跑 90 帧后袭击状态自洽（未卡死）")
	main.raid.retreat()
	_expect(not main.raid.raid_active and main.raid.enemies.is_empty(), "撤退清场干净")
	# 强盗分支仍然可用（不能因为加了狼把原有路径改坏）
	main.raid._spawn_raid(4)
	await process_frame
	_expect(main.raid.raid_kind == &"bandit", "时代Ⅳ 生成的是强盗")
	var all_bandits := true
	for e in main.raid.enemies:
		if e.is_wolf():
			all_bandits = false
	_expect(all_bandits, "强盗分支未被野狼改动污染")
	main.raid.retreat()

	# 4.14 篝火：冬季集中供暖比每户各烧省，且口径与实际扣费一致
	var fire_conf := BuildingCatalog.find_by_id(&"bonfire")
	var need_no_fire: int = 0
	main.time_mgr.season = TimeManager.Season.WINTER
	need_no_fire = main.winter_heat_need()
	var placed_fire := false
	# 把篝火放在某栋有人住的房子旁边（半径内即可覆盖）。
	# 地图是每局随机生成的，某一栋房子四周恰好没空位是正常情况——
	# 所以遍历全部住房、并把搜索窗放宽到 ±4 格（篝火半径 5，覆盖仍成立）
	var occupied_homes: Array = []
	for b in main.buildings_root.get_children():
		if b.eff_housing() > 0 and not b.residents.is_empty():
			occupied_homes.append(b)
	_expect(not occupied_homes.is_empty(), "至少有一栋住着人的房子（篝火测试前提）")
	for home_b in occupied_homes:
		if placed_fire:
			break
		for dx in range(-4, 5):
			if placed_fire:
				break
			for dy in range(-4, 5):
				var fc: Vector2i = home_b.origin + Vector2i(dx, dy)  # home_b 无类型，显式标类型
				if not grid.in_bounds(fc.x, fc.y):
					continue
				if not grid.can_place(fc, Vector2i.ONE, fire_conf):
					continue
				main.placer.selected = fire_conf
				main.resources.add(main.resources.Type.WOOD, 30)
				main.placer._try_place(fc)
				if grid.building_at(fc) != null:
					placed_fire = true
					break
	_expect(placed_fire, "在住房旁放下一堆篝火（已遍历全部住房 ±4 格）")
	if placed_fire:
		var need_with_fire: int = main.winter_heat_need()
		# 直接校验记账公式：总需求 = 篝火固定木柴 + 照不到的住房各自烧的
		var fires: Array = []
		for b in main.buildings_root.get_children():
			if b.eff_scare_radius() > 0.0 and b.data.get("warms", false):
				fires.append(b)
		var covered := 0
		var uncovered_need := 0
		for b in main.buildings_root.get_children():
			if b.eff_housing() <= 0 or b.residents.is_empty():
				continue
			var warm := false
			for fb in fires:
				if b.world_pos().distance_to(fb.world_pos()) \
						<= fb.eff_scare_radius() * GridManager.TILE:
					warm = true
			if warm:
				covered += 1
			else:
				uncovered_need += 1 if b.residents.size() <= 3 else 2
		_expect(covered >= 1, "篝火覆盖了 %d 户住房" % covered)
		var plan0: Dictionary = main.heating_plan()
		var expect_need: int = int(plan0["fires"].size()) * 2 + uncovered_need
		_expect(need_with_fire == expect_need,
			"取暖口径 = 点着的篝火 %d×2 + 未覆盖 %d = %d（实得 %d；无火时为 %d）"
			% [plan0["fires"].size(), uncovered_need, expect_need, need_with_fire, need_no_fire])
		_expect(int(plan0["houses"].size()) + covered <= occupied_homes.size() + 1,
			"排布计划里的住房数自洽（自烧 %d + 被覆盖 %d ≈ 有人住的 %d）"
			% [plan0["houses"].size(), covered, occupied_homes.size()])
		main.resources.add(main.resources.Type.WOOD, 100)
		var wood_b: int = main.resources.get_amount(main.resources.Type.WOOD)
		main._winter_heating()
		var actually_burned: int = wood_b - main.resources.get_amount(main.resources.Type.WOOD)
		_expect(actually_burned == need_with_fire,
			"预告口径与实际扣费一致：预告 %d，实扣 %d" % [need_with_fire, actually_burned])
		_expect(main._cold_homes.is_empty(), "木材充足时篝火覆盖下无人挨冻")
		main._cold_homes.clear()
		# 一户都暖不到的篝火不该在冬天白白烧柴（远处为防狼建的火不是隐形税）
		var plan: Dictionary = main.heating_plan()
		var lit_all_useful := true
		for lf in plan["fires"]:
			var warms_someone := false
			for hb in main.buildings_root.get_children():
				if hb.eff_housing() <= 0 or hb.residents.is_empty():
					continue
				if hb.world_pos().distance_to(lf.world_pos()) \
						<= lf.eff_scare_radius() * GridManager.TILE:
					warms_someone = true
			if not warms_someone:
				lit_all_useful = false
		_expect(lit_all_useful, "计划点着的篝火每一堆都至少暖到 1 户（不做隐形税）")
	main.time_mgr.season = TimeManager.Season.SPRING

	# 4.15 学堂：实机点化一名住在半径内的村民（先生在岗 + 有家才算）
	var school_conf := BuildingCatalog.find_by_id(&"school")
	var school_b = null
	for home_b2 in occupied_homes:
		if school_b != null:
			break
		# 学堂占 2×2，窗口收得太紧会在某些随机图上找不到落点而假失败。
		# 点化半径 6 格，窗口放到 ±6 依然保证"住在学区内"这个前提成立
		for dx2 in range(-6, 7):
			if school_b != null:
				break
			for dy2 in range(-6, 7):
				var sc: Vector2i = home_b2.origin + Vector2i(dx2, dy2)
				if not grid.in_bounds(sc.x, sc.y):
					continue
				if not grid.can_place(sc, school_conf.get("size", Vector2i.ONE), school_conf):
					continue
				main.placer.selected = school_conf
				main.resources.add(main.resources.Type.WOOD, 40)
				main.resources.add(main.resources.Type.STONE, 30)
				main.placer._try_place(sc)
				var nb2 = grid.building_at(sc)
				if nb2 != null:
					school_b = nb2
					break
	_expect(school_b != null, "放下一座学堂")
	if school_b != null:
		school_b.worked_today = true  # 先生今天到过岗
		# 找一个住在学区内的村民，强制设成"寻常"，看它能不能学到手艺
		var pupil = null
		for v in main.villagers_root.get_children():
			if v.home != null and is_instance_valid(v.home) \
					and v.home.world_pos().distance_to(school_b.world_pos()) \
						<= school_b.eff_teach_radius() * GridManager.TILE:
				pupil = v
				break
		_expect(pupil != null, "学区内有住着的村民（点化测试前提）")
		if pupil != null:
			# 名额是每天随机轮转的（防止树序最老的村民垄断），所以要让被测者
			# 成为唯一候选，否则断言会随机被别人抢走名额而假失败
			for v in main.villagers_root.get_children():
				v.trait_id = &"cheerful"  # 乐观不在 TEACHABLE 里，进不了课堂
			pupil.trait_id = &"plain"
			main._school_teaching()
			_expect(pupil.trait_id in Villager.LEARNABLE,
				"学区内的寻常村民学到了手艺（实为 %s）" % pupil.trait_id)
			# 先生没到岗就不上课
			pupil.trait_id = &"frail"
			school_b.worked_today = false
			main._school_teaching()
			_expect(pupil.trait_id == &"frail", "先生没到岗时不上课")
			school_b.worked_today = true
			main._school_teaching()
			_expect(pupil.trait_id == &"plain", "体弱者先被调理成寻常")

	# 4.16 顾问提示：按紧急度给出"现在最该干什么"，且各级别都能被触发到
	# 无房是最高优先级（2 级告急）
	var homes_backup := {}
	for v in main.villagers_root.get_children():
		homes_backup[v] = v.home
		if v.home != null and is_instance_valid(v.home):
			v.home.residents.erase(v)
		v.home = null
	var h_homeless: Dictionary = main.advisor_hint()
	_expect(int(h_homeless.get("level", -1)) == 2 and String(h_homeless.get("text", "")).contains("露宿"),
		"无房时顾问给 2 级告急：%s" % h_homeless.get("text", "(空)"))
	for v in main.villagers_root.get_children():
		v.home = homes_backup.get(v, null)
		if v.home != null and is_instance_valid(v.home) and not v.home.residents.has(v):
			v.home.residents.append(v)
	# 断粮优先于低级提示
	var food_backup: int = main.resources.get_amount(main.resources.Type.FOOD)
	var bread_backup: int = main.resources.get_amount(main.resources.Type.BREAD)
	main.resources.try_spend([[main.resources.Type.FOOD, food_backup]])
	main.resources.try_spend([[main.resources.Type.BREAD, bread_backup]])
	var h_food: Dictionary = main.advisor_hint()
	_expect(int(h_food.get("level", -1)) == 2 and String(h_food.get("text", "")).contains("存粮"),
		"断粮时顾问给 2 级告急：%s" % h_food.get("text", "(空)"))
	main.resources.add(main.resources.Type.FOOD, food_backup + 400)
	# 生食囤积应触发 0 级"建粮仓/面包房"提示（此时无房/断粮都已恢复）
	main.time_mgr.season = TimeManager.Season.SPRING
	var h_any: Dictionary = main.advisor_hint()
	_expect(h_any.has("text"), "常态下顾问仍能给出建议：%s" % h_any.get("text", "(空)"))
	_expect(int(h_any.get("level", 9)) <= 2, "顾问级别在 0~2 内")
	main.resources.try_spend([[main.resources.Type.FOOD,
		maxi(0, main.resources.get_amount(main.resources.Type.FOOD) - food_backup)]])
	# 人口为 0 时不给提示（覆灭面板才是正主）
	var saved_villagers: Array = main.villagers_root.get_children()
	for v in saved_villagers:
		main.villagers_root.remove_child(v)
	_expect(main.advisor_hint().is_empty(), "人口为 0 时顾问闭嘴（覆灭面板负责）")
	for v in saved_villagers:
		main.villagers_root.add_child(v)

	# 4.17 城堡三期工程：放下地基不加冕，升到王城才加冕
	var castle_conf := BuildingCatalog.find_by_id(&"castle")
	var castle_b = null
	for x in range(0, grid.width):
		if castle_b != null:
			break
		for y in range(0, grid.height):
			var cc := Vector2i(x, y)
			if not grid.can_place(cc, castle_conf.get("size", Vector2i.ONE), castle_conf):
				continue
			main.resources.add(main.resources.Type.WOOD, 200)
			main.resources.add(main.resources.Type.STONE, 200)
			main.resources.add(main.resources.Type.GOLD, 200)
			main.placer.selected = castle_conf
			main.placer._try_place(cc)
			var nb3 = grid.building_at(cc)
			if nb3 != null:
				castle_b = nb3
				break
	_expect(castle_b != null, "放下城堡地基")
	if castle_b != null:
		_expect(not main.crowned, "地基落成时还没加冕（原先是放下即通关）")
		_expect(castle_b.eff_castle_bonus() > 0.0,
			"地基就给全体幸福 +%d（攒资源的过程有反馈）" % int(castle_b.eff_castle_bonus()))
		var stage1: float = castle_b.eff_castle_bonus()
		main.resources.add(main.resources.Type.WOOD, 300)
		main.resources.add(main.resources.Type.STONE, 300)
		main.resources.add(main.resources.Type.GOLD, 300)
		main.upgrade_building(castle_b)
		_expect(castle_b.eff_castle_bonus() > stage1,
			"第二期幸福加成提升到 +%d" % int(castle_b.eff_castle_bonus()))
		_expect(not main.crowned, "第二期仍未加冕")
		while castle_b.can_upgrade():
			main.resources.add(main.resources.Type.WOOD, 300)
			main.resources.add(main.resources.Type.STONE, 300)
			main.resources.add(main.resources.Type.GOLD, 300)
			main.upgrade_building(castle_b)
		_expect(main.crowned, "王城落成即加冕")
		_expect(is_equal_approx(castle_b.eff_castle_bonus(), 10.0),
			"加冕后全体幸福 +%d" % int(castle_b.eff_castle_bonus()))
		# 加冕后日结不该重复触发（crowned 是一次性的）
		main._update_happiness()
		_expect(main.crowned, "加冕状态稳定")

	# 5. 存读档回环
	main.save_game("test_play.json")
	var ok: bool = main.load_game(main.save_dir + "test_play.json")
	await process_frame
	print("6. 存读档回环: ", ok, " 建筑数 ", main.buildings_root.get_child_count(),
		" 村民数 ", main.villagers_root.get_child_count())
	# 升级等级必须跟着存档回来，否则读档等于把玩家的升级投入清零
	var max_lv_after := 0
	for b in main.buildings_root.get_children():
		max_lv_after = maxi(max_lv_after, int(b.level))
	_expect(max_lv_after >= 2, "读档后仍有 Lv%d 建筑（等级入档生效）" % max_lv_after)
	var trait_ok := true
	for v in main.villagers_root.get_children():
		if not Villager.TRAITS.has(v.trait_id):
			trait_ok = false
	_expect(trait_ok, "读档后全体村民特长仍是合法值（特长入档生效）")
	var prio_ok := true
	for b in main.buildings_root.get_children():
		if b.priority < 0 or b.priority > 2:
			prio_ok = false
	_expect(prio_ok, "读档后建筑优先级都在 0~2（优先级入档生效）")
	_expect(main.granary_capacity() > 0, "读档后粮仓仍在（保鲜容量 %d）" % main.granary_capacity())
	DirAccess.remove_absolute(main.save_dir + "test_play.json")

	print("=== PLAY TEST END ===")
	if _fails > 0:
		print("[FAIL] play_test 断言失败 %d 条" % _fails)
	quit(1 if _fails > 0 else 0)

func _present_workers(main) -> int:
	var n := 0
	for b in main.buildings_root.get_children():
		n += b.workers.size()
	return n
