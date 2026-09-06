extends SceneTree

## 菜单按钮链路测试：模拟「点击」主按钮和 ESC，验证暂停/恢复状态机，
## 以及开局必经的「缔造新世界」面板 → new_game(cfg) 这条链路。
## godot --headless --path <项目> --script tests/menu_test.gd

var _pass := 0
var _fail := 0

func _expect(cond: bool, what: String) -> void:
	if cond:
		_pass += 1
		print("  [PASS] %s" % what)
	else:
		_fail += 1
		print("  [FAIL] %s" % what)

func _initialize() -> void:
	print("=== MENU TEST START ===")
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	print("启动后: 菜单可见=%s 暂停=%s" % [main.menu.visible, paused])
	_expect(main.menu.visible and paused, "启动停在主菜单且游戏暂停")

	# 主按钮（无存档 = 开始游戏）：不再直接进游戏，而是先打开世界设置面板
	main.menu._start_btn.pressed.emit()
	await process_frame
	print("点主按钮后: 菜单可见=%s 世界面板=%s 已开始=%s"
		% [main.menu.visible, main.menu._world_panel.visible, main.is_game_started()])
	_expect(main.menu._world_panel.visible, "无存档时主按钮打开「缔造新世界」面板")
	_expect(not main.is_game_started(), "世界还没确认，游戏尚未开始")

	# 在面板里换一套世界参数：小地图 + 密林 + 固定种子（种子固定才好复现）
	main.menu._on_option_picked("size", &"small")
	main.menu._on_option_picked("terrain", &"forest")
	main.menu._on_seed_changed("12345")
	_expect(main.menu._world_cfg.size_id == &"small", "选中了小地图")
	_expect(main.menu._world_cfg.terrain_id == &"forest", "选中了密林地形")
	_expect(main.menu._world_cfg.world_seed == 12345, "种子已写入配置")

	# 开始建国：地图应按所选尺寸重建，且镜头对准出生广场
	main.menu._on_start_world()
	await process_frame
	var want_w: int = main.menu._world_cfg.map_width()
	print("开始建国后: 地图=%dx%d 已开始=%s 暂停=%s"
		% [main.grid.width, main.grid.height, main.is_game_started(), paused])
	_expect(main.grid.width == want_w, "地图宽度按所选尺寸重建（%d）" % want_w)
	_expect(main.grid.terrain.size() == main.grid.width * main.grid.height,
		"地形数组长度与新尺寸一致")
	_expect(main.is_game_started() and not paused, "确认后游戏开始且已解除暂停")
	_expect(main.grid.spawn_center.x >= 0, "生成了出生广场坐标")

	# 模拟 ESC 打开菜单
	var esc := InputEventKey.new()
	esc.pressed = true
	esc.keycode = KEY_ESCAPE
	main._unhandled_input(esc)
	await process_frame
	print("ESC 后: 菜单可见=%s 暂停=%s" % [main.menu.visible, paused])
	_expect(main.menu.visible and paused, "ESC 回到菜单并暂停")

	# 模拟点击「返回游戏」
	main.menu._resume_btn.pressed.emit()
	await process_frame
	print("点返回游戏后: 菜单可见=%s 暂停=%s" % [main.menu.visible, paused])
	_expect(not main.menu.visible and not paused, "返回游戏恢复运行")

	# 检查按钮在暂停下是否能收到 GUI 输入（process_mode 继承链）
	var b = main.menu._start_btn
	var n = b
	var chain := []
	while n != null:
		chain.append("%s:%d" % [n.name, n.process_mode])
		n = n.get_parent()
	print("按钮 process_mode 链: ", " <- ".join(chain))

	print("=== 断言统计：PASS=%d FAIL=%d ===" % [_pass, _fail])
	print("=== MENU TEST END ===")
	if _fail > 0:
		print("[FAIL] menu_test 断言失败 %d 条" % _fail)
		quit(1)
		return
	quit()
