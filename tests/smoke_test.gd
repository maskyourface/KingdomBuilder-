extends SceneTree

## 无头冒烟测试：启动主场景 → 开始游戏 → 放建筑 → 派人 → 存档 → 读档。
## 运行方式：godot --headless --path <项目> --script tests/smoke_test.gd
## 只写 test_save.json，不动玩家的存档。

func _initialize() -> void:
	print("=== SMOKE TEST START ===")
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame

	# 1. 菜单状态
	print("1. 存档列表: ", main.get_save_list().size(), " 个")
	main.start_or_continue()
	await process_frame
	print("2. 游戏已开始: ", main.is_game_started(), " 暂停: ", paused)

	# 2. 找一个能放伐木场的格子（草地且邻近森林）
	var grid = main.grid
	var placed := false
	for x in grid.width:
		for y in grid.height:
			var cell := Vector2i(x, y)
			var lumber := BuildingCatalog.find_by_id(&"lumber")
			if grid.can_place(cell, Vector2i.ONE, lumber):
				main.placer.selected = lumber
				main.placer._try_place(cell)
				placed = grid.building_at(cell) != null
				print("3. 放置伐木场 @", cell, ": ", placed)
				break
		if placed:
			break

	# 3. 派工人
	var b = null
	for bb in main.buildings_root.get_children():
		b = bb
	if b != null:
		main.assign_worker(b)
		print("4. 派工后工人数: ", b.workers.size())

	# 4. 存档
	main.save_game("test_save.json")
	var path: String = main.save_dir + "test_save.json"
	print("5. 存档文件存在: ", FileAccess.file_exists(path))

	# 5. 读档
	var ok: bool = main.load_game(path)
	await process_frame
	print("6. 读档结果: ", ok)
	print("7. 读档后建筑数: ", main.buildings_root.get_child_count(),
		" 村民数: ", main.villagers_root.get_child_count())
	for bb in main.buildings_root.get_children():
		print("8. 建筑 ", bb.data.get("name"), " 工人数: ", bb.workers.size())

	# 6. 跑 3 秒真实模拟，看生产和村民状态机有没有崩
	var frames := 0
	while frames < 180:
		await process_frame
		frames += 1
	print("9. 模拟 180 帧后村民状态:")
	for v in main.villagers_root.get_children():
		print("   ", v.display_name, " → ", v.state_text(), " 饥饿 ", int(v.hunger))

	# 清理测试存档
	DirAccess.remove_absolute(path)
	print("=== SMOKE TEST END ===")
	quit()
