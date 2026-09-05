extends SceneTree

## 菜单按钮链路测试：模拟"点击"主按钮和 ESC，验证暂停/恢复状态机。
## godot --headless --path <项目> --script tests/menu_test.gd

func _initialize() -> void:
	print("=== MENU TEST START ===")
	var main = load("res://scenes/main.tscn").instantiate()
	root.add_child(main)
	await process_frame
	await process_frame
	print("启动后: 菜单可见=%s 暂停=%s" % [main.menu.visible, paused])

	# 模拟点击主按钮（开始游戏/继续游戏）
	main.menu._start_btn.pressed.emit()
	await process_frame
	print("点主按钮后: 菜单可见=%s 暂停=%s 已开始=%s" % [main.menu.visible, paused, main.is_game_started()])

	# 模拟 ESC 打开菜单
	var esc := InputEventKey.new()
	esc.pressed = true
	esc.keycode = KEY_ESCAPE
	main._unhandled_input(esc)
	await process_frame
	print("ESC 后: 菜单可见=%s 暂停=%s" % [main.menu.visible, paused])

	# 模拟点击「返回游戏」
	main.menu._resume_btn.pressed.emit()
	await process_frame
	print("点返回游戏后: 菜单可见=%s 暂停=%s" % [main.menu.visible, paused])

	# 检查按钮在暂停下是否能收到 GUI 输入（process_mode 继承链）
	var b = main.menu._start_btn
	var n = b
	var chain := []
	while n != null:
		chain.append("%s:%d" % [n.name, n.process_mode])
		n = n.get_parent()
	print("按钮 process_mode 链: ", " <- ".join(chain))

	print("=== MENU TEST END ===")
	quit()
