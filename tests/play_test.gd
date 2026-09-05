extends SceneTree

## 实机玩法冒烟：新开局 → 真实运转 12 游戏秒 → 跨午夜日结 → 存读档。
## 运行方式：godot --headless --path <项目> --script tests/play_test.gd
## 与 smoke_test 的区别：本测试真正 new_game()（不暂停），村民 AI/生产/幸福度日结全部实跑。

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
		main.event_mgr.rainy_day, main.event_mgr.mood_bonus, main.event_mgr.mood_days_left])

	# 5. 存读档回环
	main.save_game("test_play.json")
	var ok: bool = main.load_game(main.save_dir + "test_play.json")
	await process_frame
	print("6. 存读档回环: ", ok, " 建筑数 ", main.buildings_root.get_child_count(),
		" 村民数 ", main.villagers_root.get_child_count())
	DirAccess.remove_absolute(main.save_dir + "test_play.json")

	print("=== PLAY TEST END ===")
	quit()

func _present_workers(main) -> int:
	var n := 0
	for b in main.buildings_root.get_children():
		n += b.workers.size()
	return n
