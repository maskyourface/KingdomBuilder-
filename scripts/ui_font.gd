class_name UiFont

## 界面样式工具：中文字体加载 + 整套深色木质主题。
## 字体优先用项目内置字体（随游戏导出，跨平台可用），
## 其次按平台尝试常见系统字体，最后回退 Godot 默认字体。

static var _font: Font = null

const FONT_PATHS := [
	"res://fonts/NotoSansCJKsc-Regular.otf",   # 项目内置（推荐，导出时打包）
	"C:/Windows/Fonts/msyh.ttc",               # Windows 微软雅黑
	"C:/Windows/Fonts/simhei.ttf",             # Windows 黑体
	"/System/Library/Fonts/PingFang.ttc",      # macOS 苹方
	"/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",  # Linux Noto
	"/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",            # Linux 文泉驿
]

static func get_font() -> Font:
	if _font != null:
		return _font
	for p in FONT_PATHS:
		var exists := ResourceLoader.exists(p) if p.begins_with("res://") \
			else FileAccess.file_exists(p)
		if not exists:
			continue
		var font := FontFile.new()
		if font.load_dynamic_font(p) == OK:
			_font = font
			print("界面字体：", p)
			return _font
	print("警告：没有找到中文字体，界面中文可能无法显示")
	_font = ThemeDB.fallback_font
	return _font

## 整套界面主题：深色半透明面板 + 木质按钮，圆角描边
static func make_theme() -> Theme:
	var theme := Theme.new()
	theme.default_font = get_font()
	theme.default_font_size = 15

	# 面板：深棕底 + 描边 + 圆角
	var panel := StyleBoxFlat.new()
	panel.bg_color = Color(0.13, 0.10, 0.08, 0.92)
	panel.border_color = Color(0.45, 0.35, 0.22)
	panel.set_border_width_all(2)
	panel.set_corner_radius_all(8)
	panel.set_content_margin_all(12)
	theme.set_stylebox(&"panel", &"PanelContainer", panel)
	theme.set_stylebox(&"panel", &"Panel", panel)

	# 按钮三态
	var normal := _make_button_style(Color(0.28, 0.22, 0.15))
	var hover := _make_button_style(Color(0.38, 0.30, 0.20))
	var pressed := _make_button_style(Color(0.20, 0.16, 0.11))
	theme.set_stylebox(&"normal", &"Button", normal)
	theme.set_stylebox(&"hover", &"Button", hover)
	theme.set_stylebox(&"pressed", &"Button", pressed)
	theme.set_stylebox(&"focus", &"Button", StyleBoxEmpty.new())  # 去掉焦点虚线框
	theme.set_color(&"font_color", &"Button", Color(0.95, 0.90, 0.78))
	theme.set_color(&"font_hover_color", &"Button", Color(1.0, 0.97, 0.88))

	theme.set_color(&"font_color", &"Label", Color(0.92, 0.88, 0.78))
	return theme

static func _make_button_style(bg: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = Color(0.45, 0.35, 0.22)
	s.set_border_width_all(1)
	s.set_corner_radius_all(6)
	s.set_content_margin_all(8)
	return s

static func apply(root: Control) -> void:
	root.theme = make_theme()
