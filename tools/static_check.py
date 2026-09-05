#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
KingdomBuilder 启发式静态检查（迭代2）
=====================================
对 scripts/ 与 tests/ 下的 .gd 文件做纯文本启发式检查（不运行 Godot）：

[A] 跨脚本调用契约：解析每个 class_name 脚本的 func 定义（名字+形参个数+形参类型+
    返回类型），结合项目内「已知对象类型映射」扫描全部 obj.method(...) 调用点，
    报告「调用了不存在的函数」「参数个数不符」「参数类型明显不符（疑似顺序错误）」。
    迭代2：对象映射补全 —— RaidManager.game → Main（main.gd），
    使 game.add_child / game.hud.show_toast 等迭代1新增调用面纳入检查（见 [A] 末尾
    「关键调用面逐点核验」）。
[B] 幽灵属性：收集每个 class_name 的 var/const/enum/signal 成员，扫描对可解析为
    项目类的变量的 `.attr` 访问，报告成员不存在的疑似点（内置成员/方法白名单过滤）。
[C] 字典键一致性：building_catalog.gd 的 data 字典键集合 vs 全代码对建筑目录字典的
    查询键（*.data.get / data.get[限 building.gd、hud.gd] / selected.get[placer] /
    catalog.get[main]）。
[D] 存档对称性：main.gd save_game 写入的 JSON 键 vs load_game/get_save_list 读取的键
    差集。迭代2：对新增字段 happiness / raid_pending / raid_started_day 单独复跑
    「两侧必须同时出现」的断言。
[E] 信号契约（迭代2新增）：解析各脚本 signal 声明（含形参个数），对全部 .emit(...)
    校验「信号已声明 + 实参个数与声明一致」，对全部 .connect(...) 校验
    「信号存在 + 目标方法存在 + 目标方法必填/最多个数与（信号形参 + bind 实参）兼容」
    （如 villager.gd 的 died vs main.gd 的 _on_villager_died）；并对
    main_menu._make_button 的 Callable 间接连接做同规则校验；信号声明/emit/connect
    三方对账，无监听者的信号以 INFO 提示。
[F] GDScript 语法粗检（迭代2新增）：逐文件检查
    ① 缩进混用（行内 Tab+空格、文件级 Tab 风格 vs 空格风格）；
    ② 字符串未闭合（行尾仍处于字符串内）；
    ③ 代码区出现全角标点（复制粘贴笔误）；
    ④ match 语句头缺冒号、match 分支缺冒号（兼容「模式: 内联语句」单行写法）；
    ⑤ func 签名括号配平且完整（可解析出形参与返回类型）；
    ⑥ if/elif/else/for/while/match/func/class 块语句缺冒号（自动合并括号续行与反斜杠续行）。

局限（启发式，必然存在漏报与误报，最终以人工核对为准）：
- 不做完整 GDScript 类型分析，靠正则+括号配平；
- 无类型标注的变量只有命中「已知对象类型映射」才检查；函数参数（含 lambda 参数）
  在其作用域内遮蔽映射，避免把局部同名变量误当成全局对象；
- Godot 内置成员/方法只覆盖常用白名单（白名单太宽会漏报、太窄会误报）；
- 参数「顺序」只能靠形参类型与实参推断类型明显冲突时提示，不能完全确定；
- 经 Callable 变量/参数转发的连接（如 _make_button 内部 b.pressed.connect(action)）
  无法静态追踪到具体方法，[E] 只能对该模式的「调用点实参」做校验；
- 未知内置信号（白名单外）跳过参数个数校验；
- [F] 为粗检：多行字符串仅按三引号简单追踪，pattern 换行等冷门写法未覆盖。

用法：python tools/static_check.py
输出：控制台 + tools/static_check_report.txt（[A]~[D] 输出格式与迭代1保持兼容）
"""

import os
import re
import sys
import datetime

# ----------------------------------------------------------------------------
# 路径
# ----------------------------------------------------------------------------
TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(TOOL_DIR)
SCAN_DIRS = [os.path.join(PROJECT, "scripts"), os.path.join(PROJECT, "tests")]
CATALOG_FILE = os.path.join(PROJECT, "scripts", "building_catalog.gd")
REPORT_FILE = os.path.join(TOOL_DIR, "static_check_report.txt")

# ----------------------------------------------------------------------------
# 项目内已知对象类型映射（任务指定 + 人工补充）
# 变量名 -> 项目类名。main.gd 没有 class_name，映射为伪类 Main。
# 迭代2补全：raid_manager.gd 以无类型成员 `game` 持有 main.gd 实例
# （注释明示"避免 class_name 循环依赖"），不补映射则 game.hud.show_toast 等
# 迭代1新增调用面完全脱离静态检查。
# 优先级：本映射 > 局部类型推断 > 成员声明类型。
# ----------------------------------------------------------------------------
PROJECT_TYPE_MAP = {
    "hud": "HUD",
    "main": "Main",
    "game": "Main",        # 迭代2新增：RaidManager.game → main.gd
    "time_mgr": "TimeManager",
    "time": "TimeManager",
    "raid": "RaidManager",
    "placer": "BuildingPlacer",
    "grid": "GridManager",
    "resources": "ResourceManager",
    "menu": "MainMenu",
    "v": "Villager",
    "villager": "Villager",
    "e": "Enemy",
    "b": "Building",
    "building": "Building",
}

# Godot 单例（其成员不做检查）
GODOT_SINGLETONS = {
    "Time", "Input", "OS", "Engine", "JSON", "ProjectSettings", "ThemeDB",
    "ResourceLoader", "DirAccess", "FileAccess", "RenderingServer", "TextServer",
    "AudioServer", "DisplayServer",
}

# Godot 内置类/结构名（其成员不做检查；也用于实参类型推断）
GODOT_BUILTIN_TYPES = {
    "Vector2", "Vector2i", "Vector3", "Vector3i", "Rect2", "Rect2i", "Color",
    "Transform2D", "Node", "Node2D", "Node3D", "Control", "CanvasLayer",
    "CanvasItem", "Sprite2D", "Camera2D", "Label", "Button", "PanelContainer",
    "Panel", "VBoxContainer", "HBoxContainer", "GridContainer", "ScrollContainer",
    "StyleBoxFlat", "StyleBoxEmpty", "Theme", "Font", "FontFile", "Image",
    "Texture2D", "InputEvent", "InputEventKey", "InputEventMouseButton",
    "InputEventMouseMotion", "SceneTree", "PackedStringArray", "PackedInt32Array",
    "PackedFloat32Array", "RandomNumberGenerator", "Callable", "Signal",
    "StringName", "Object", "RefCounted", "Resource", "ProgressBar", "RichTextLabel",
    "Tree", "ColorRect", "Timer", "Array", "Dictionary", "String", "int", "float",
    "bool", "void", "Variant", "NodePath",
}

# 常用内置信号 -> 形参个数（白名单外者跳过参数校验）
BUILTIN_SIGNALS = {
    "pressed": 0, "button_down": 0, "button_up": 0, "toggled": 1,
    "text_changed": 1, "text_submitted": 1, "item_selected": 1,
    "value_changed": 1, "timeout": 0, "ready": 0, "tree_entered": 0,
    "tree_exited": 0, "visibility_changed": 0, "child_entered_tree": 1,
    "resized": 0, "focus_entered": 0, "focus_exited": 0, "gui_input": 1,
    "mouse_entered": 0, "mouse_exited": 0, "draw": 0, "item_draw": 0,
}

# Godot 常用内置「属性/成员」白名单（Node/CanvasItem/Control/输入事件等）
BUILTIN_MEMBERS = {
    # Node / CanvasItem / Node2D / CanvasLayer
    "name", "position", "rotation", "rotation_degrees", "scale", "visible",
    "modulate", "self_modulate", "z_index", "layer", "process_mode", "owner",
    "scene_file_path", "process_priority",
    # Camera2D
    "zoom", "offset", "current", "enabled",
    # Control
    "size", "custom_minimum_size", "minimum_size", "text", "pressed", "disabled",
    "alignment", "autowrap_mode", "horizontal_alignment", "vertical_alignment",
    "mouse_filter", "size_flags_horizontal", "size_flags_vertical", "theme",
    "columns", "value", "min_value", "max_value", "step", "show_percentage",
    "offset_left", "offset_top", "offset_right", "offset_bottom",
    "anchor_left", "anchor_top", "anchor_right", "anchor_bottom",
    "color", "font", "font_size", "editable", "placeholder_text", "tooltip_text",
    # 输入事件
    "keycode", "physical_keycode", "key_label", "unicode", "echo", "button_index",
    "button_mask", "double_click", "factor", "global_position", "relative",
    # SceneTree
    "paused", "root", "current_scene",
    # 项目中常见的通用字段名（防把常见数据字段误报；与任务指定清单一致）
    "data", "hp", "workers", "residents", "uid", "origin", "timer", "hunger",
    "happiness", "width", "height", "terrain", "roads", "stock", "changed",
    "meta", "index", "x", "y", "z",
}

# Godot 常用内置「方法」白名单
BUILTIN_METHODS = {
    # 节点树
    "queue_free", "free", "add_child", "remove_child", "get_children", "get_child",
    "get_child_count", "get_parent", "get_tree", "get_node", "get_node_or_null",
    "has_node", "is_instance_valid", "is_inside_tree", "reparent", "move_child",
    "set_process", "get_viewport", "get_global_mouse_position", "warp_mouse",
    # 绘制
    "queue_redraw", "draw_circle", "draw_rect", "draw_line", "draw_string",
    "draw_style_box", "draw_colored_polygon", "draw_arc", "draw_texture",
    "draw_dashed_line", "draw_multiline_string",
    # 变换/几何
    "distance_to", "distance_squared_to", "move_toward", "normalized", "clamp",
    "rotated", "length", "length_squared", "lerp", "dot", "cross", "angle",
    "direction_to", "lightened", "darkened", "floor", "ceil", "abs", "sign",
    "snapped", "min", "max", "get_center", "has_point", "grow", "intersects",
    "limit_length", "bounce", "reflect", "slide", "project", "orthogonal",
    # 主题/样式
    "set_anchors_preset", "set_anchors_and_offsets_preset",
    "add_theme_constant_override", "add_theme_font_size_override",
    "add_theme_color_override", "add_theme_stylebox_override",
    "add_theme_font_override", "set_border_width_all", "set_corner_radius_all",
    "set_content_margin_all", "get_theme_constant", "make_current",
    "remove_theme_color_override",
    # 信号/Callable/对象
    "connect", "disconnect", "emit", "emit_signal", "bind", "call", "call_deferred",
    "callv", "set", "get", "new", "is_connected", "get_instance_id",
    # 容器/字符串
    "is_empty", "append", "append_array", "erase", "insert", "clear", "has",
    "find", "size", "count", "duplicate", "filter", "map", "reduce", "any", "all",
    "sort", "sort_custom", "shuffle", "pick_random", "pop_back", "pop_front",
    "push_back", "push_front", "resize", "fill", "slice", "reverse", "bsearch",
    "join", "begins_with", "ends_with", "contains", "trim_prefix", "trim_suffix",
    "strip_edges", "split", "replace", "replacen", "to_int", "to_float", "to_upper",
    "to_lower", "is_valid", "is_valid_int", "is_valid_float", "pad_decimals",
    "get_slice", "format", "hash", "capitalize", "length",
    # 文件/目录/JSON/时间
    "open", "file_exists", "dir_exists", "get_file_as_string", "store_string",
    "store_line", "get_line", "close", "parse_string", "stringify", "parse",
    "make_dir_recursive_absolute", "make_dir", "remove_absolute", "remove",
    "get_files", "get_next", "list_dir_begin", "list_dir_end", "globalize_path",
    "localize_path", "get_executable_path", "get_base_dir", "has_feature",
    "get_datetime_string_from_system", "get_unix_time_from_system",
    "get_datetime_string_from_unix_time", "get_ticks_msec", "get_ticks_usec",
    # 资源/字体/渲染
    "exists", "load_dynamic_font", "instantiate", "get_rid",
    # 随机数
    "randomize", "randi", "randf", "randi_range", "randf_range", "randfn",
    # 枚举/字典遍历
    "values", "keys", "items", "get_or_add", "merge", "find_key",
}

LITERAL_TYPE = {"true": "bool", "false": "bool", "null": "null"}

# 代码区出现即报错的全角标点（字符串/注释内不算）
FULLWIDTH_PUNCT = "（）：；，！？【】「」『』、＂＂％"

# 实参类型兼容性判定（param_type <- arg_type）
def type_compatible(param_t, arg_t, class_extends):
    """class_extends: 项目类 -> 其 extends 链（含自身），用于继承判断"""
    if param_t is None or arg_t is None or arg_t == "null" or param_t == "Variant":
        return True
    if param_t == arg_t:
        return True
    arg_builtin = arg_t in GODOT_BUILTIN_TYPES or arg_t in GODOT_SINGLETONS
    arg_project = (not arg_builtin) and re.match(r"^[A-Z]", arg_t) is not None

    # 项目类实参：与形参类型比较继承链
    if arg_project:
        chain = class_extends.get(arg_t, {arg_t})
        return param_t in chain

    # 标量形参
    if param_t in ("int", "float", "bool", "String", "StringName"):
        if arg_t in ("int", "float"):
            if param_t == "float":
                return True          # int -> float 允许
            if param_t == "int":
                return arg_t == "int"  # float -> int 可疑
            return False             # 数值 -> bool 可疑
        if arg_t in ("String", "StringName"):
            return param_t in ("String", "StringName")
        if arg_t in ("Vector2", "Vector2i", "Color", "Dictionary", "Array"):
            return False
        return True  # 未知/其他，放行
    # 内置结构形参
    if param_t in ("Vector2", "Vector2i", "Color", "Dictionary", "Array"):
        if arg_t in ("Vector2", "Vector2i", "Color", "Dictionary", "Array"):
            return param_t == arg_t
        if arg_t in ("int", "float", "bool", "String", "StringName"):
            return False
        return True  # 其余（推断不出）放行
    return True


# ----------------------------------------------------------------------------
# 词法辅助：注释剥离、语句续行合并
# ----------------------------------------------------------------------------
def strip_comment(line):
    out = []
    in_str = None
    i = 0
    while i < len(line):
        c = line[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < len(line):
                out.append(line[i + 1])
                i += 2
                continue
            if c == in_str:
                in_str = None
        else:
            if c in ("\"", "'"):
                in_str = c
                out.append(c)
            elif c == "#":
                break
            else:
                out.append(c)
        i += 1
    return "".join(out)


def bracket_delta(line):
    delta = 0
    in_str = None
    i = 0
    while i < len(line):
        c = line[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == in_str:
                in_str = None
        elif c in ("\"", "'"):
            in_str = c
        elif c in "([{":
            delta += 1
        elif c in ")]}":
            delta -= 1
        i += 1
    return delta


def logical_lines(text):
    """合并括号未闭合的续行，剥离注释。返回 [(起始行号, 逻辑行)]"""
    result = []
    buf, start, depth = "", None, 0
    for idx, raw in enumerate(text.splitlines(), 1):
        code = strip_comment(raw)
        if buf:
            buf += " " + code.strip()
        else:
            if not code.strip():
                continue
            buf, start = code, idx
        depth += bracket_delta(code)
        if depth <= 0:
            result.append((start, buf))
            buf, start, depth = "", None, 0
    if buf:
        result.append((start, buf))
    return result


def logical_blocks(text):
    """[F] 专用：在 logical_lines 基础上再合并反斜杠续行。
    返回 [(起始行号, 结束行号, 逻辑块文本)]。"""
    result = []
    buf, start, depth = "", None, 0
    total = len(text.splitlines())
    for idx, raw in enumerate(text.splitlines(), 1):
        code = strip_comment(raw)
        s = code.strip()
        if buf:
            if s:
                buf += " " + s
        else:
            if not s:
                continue
            buf, start = code, idx
        depth += bracket_delta(code)
        if s.endswith("\\"):
            buf = buf.rstrip()[:-1].rstrip()  # 摘掉续行符，继续吞下一行
            continue
        if depth <= 0:
            result.append((start, idx, buf))
            buf, start, depth = "", None, 0
    if buf:
        result.append((start, total, buf))
    return result


def split_top(s, sep=","):
    """按顶层分隔符切分（忽略括号与字符串内）"""
    parts, depth, cur, in_str = [], 0, "", None
    i = 0
    while i < len(s):
        c = s[i]
        if in_str:
            cur += c
            if c == "\\":
                cur += s[i + 1] if i + 1 < len(s) else ""
                i += 2
                continue
            if c == in_str:
                in_str = None
        elif c in ("\"", "'"):
            in_str = c
            cur += c
        elif c in "([{":
            depth += 1
            cur += c
        elif c in ")]}":
            depth -= 1
            cur += c
        elif c == sep and depth == 0:
            parts.append(cur)
            cur = ""
        else:
            cur += c
        i += 1
    if cur.strip():
        parts.append(cur)
    return [p.strip() for p in parts]


def parse_params(s):
    params = []
    for p in split_top(s):
        if not p:
            continue
        has_default = "=" in p
        head = p.split("=")[0].strip()
        name = head.split(":")[0].strip()
        ptype = head.split(":", 1)[1].strip() if ":" in head else None
        if ptype:
            ptype = re.sub(r"\[.*", "", ptype).strip()
        params.append((name, ptype, has_default))
    return params


def find_call_end_str(s, open_pos):
    """s[open_pos] 必须是 '('，返回与之配平的 ')' 下标；找不到返回 None"""
    depth = 0
    in_str = None
    i = open_pos
    while i < len(s):
        c = s[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == in_str:
                in_str = None
        elif c in ("\"", "'"):
            in_str = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def has_top_level_colon(s):
    """字符串外、括号深度 0 处是否存在冒号"""
    depth = 0
    in_str = None
    i = 0
    while i < len(s):
        c = s[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == in_str:
                in_str = None
        elif c in ("\"", "'"):
            in_str = c
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == ":" and depth == 0:
            return True
        i += 1
    return False


# ----------------------------------------------------------------------------
# GDScript 脚本解析
# ----------------------------------------------------------------------------
class FuncDef:
    def __init__(self, name, line, params, static=False):
        self.name = name
        self.line = line
        self.static = static
        self.params = params
        self.ret = None

    @property
    def required(self):
        return sum(1 for _, _, d in self.params if not d)

    @property
    def total(self):
        return len(self.params)


class ScriptDef:
    def __init__(self, path):
        self.path = path
        self.base = os.path.splitext(os.path.basename(path))[0]
        self.file = os.path.basename(path)
        self.class_name = None
        self.extends = None
        self.funcs = {}
        self.members = {}
        self.member_types = {}
        self.enums = {}
        self.enum_values = {}
        self.signals = {}       # 迭代2：name -> {"line": ln, "n": 形参个数, "raw": 声明形参原文}
        self.lines = []
        self.func_ranges = []   # [(start_line, end_line, {param_names})]

    @property
    def disp(self):
        if self.class_name:
            return self.class_name
        if self.base == "main":
            return "Main(main.gd)"
        return self.base

    @property
    def self_type(self):
        if self.class_name:
            return self.class_name
        if self.base == "main":
            return "Main"
        return self.extends


FUNC_RE = re.compile(r"^(static\s+)?func\s+(\w+)\s*\((.*)\)\s*(?:->\s*([\w\[\].]+))?\s*:?\s*$")
SIGNAL_RE = re.compile(r"^signal\s+(\w+)\s*(?:\((.*)\))?\s*$")
FUNC_FULL_RE = re.compile(r"^(static\s+)?func\s+\w+\s*\(.*\)\s*(?:->\s*[\w\[\].]+)?\s*:\s*$")
BLOCK_KEYWORD_RE = re.compile(r"^(if|elif|else|for|while|match|func|class)\b")
MATCH_HEADER_RE = re.compile(r"^(\s*)match\s+\S.*$")


def parse_member_decl(stripped):
    # 允许 @export / @export_range(...) / @onready 等装饰器前缀
    m = re.match(r"^(?:@[\w.]+(?:\([^)]*\))?\s+)*(?:static\s+)?(var|const)\s+(\w+)\s*(.*)$", stripped)
    if not m:
        return None
    kind = m.group(1)
    name = m.group(2)
    rest = m.group(3).strip()
    ptype = None
    init = None
    if rest.startswith(":"):
        body = rest[1:]
        eq = find_top_eq(body)
        if eq >= 0:
            ptype = body[:eq].strip()
            init = body[eq + 1:].strip()
        else:
            ptype = body.strip()
    elif rest.startswith(":="):
        init = rest[2:].strip()
    elif rest.startswith("="):
        init = rest[1:].strip()
    if ptype:
        ptype = re.sub(r"\[.*", "", ptype).strip() or None
    return kind, name, ptype, init


def find_top_eq(s):
    depth = 0
    in_str = None
    i = 0
    while i < len(s):
        c = s[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == in_str:
                in_str = None
        elif c in ("\"", "'"):
            in_str = c
        elif c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "=" and depth == 0:
            if i + 1 < len(s) and s[i + 1] == "=":
                i += 2
                continue
            return i
        i += 1
    return -1


def parse_script(path):
    sc = ScriptDef(path)
    with open(path, "r", encoding="utf-8") as f:
        text = f.read()
    sc.lines = text.splitlines()
    lls = logical_lines(text)

    cur_enum = None
    for ln, line in lls:
        stripped = line.strip()
        indent = len(line) - len(line.lstrip())

        m = re.match(r"^class_name\s+(\w+)", stripped)
        if m and indent == 0:
            sc.class_name = m.group(1)
            continue
        m = re.match(r"^extends\s+([\w.]+)", stripped)
        if m and indent == 0:
            sc.extends = m.group(1)
            continue

        if cur_enum is not None:
            inner = stripped.rstrip("}").strip()
            for item in inner.split(","):
                item = item.strip().split("=")[0].strip()
                if item and re.match(r"^\w+$", item):
                    sc.enums[cur_enum].append(item)
                    sc.enum_values[item] = cur_enum
            if "}" in stripped:
                cur_enum = None
            continue

        fm = FUNC_RE.match(stripped)
        if fm and indent == 0:
            fn = FuncDef(fm.group(2), ln, parse_params(fm.group(3)),
                         static=bool(fm.group(1)))
            if fm.group(4):
                fn.ret = re.sub(r"\[.*", "", fm.group(4)).strip()
            sc.funcs[fn.name] = fn
            continue

        if indent == 0:
            decl = parse_member_decl(stripped)
            if decl:
                kind, name, ptype, init = decl
                sc.members[name] = kind
                if ptype:
                    sc.member_types[name] = ptype
                elif init:
                    mm = re.match(r"^(\w+)\.new\(", init)
                    if mm:
                        sc.member_types[name] = mm.group(1)
                    else:
                        mm = re.match(r"^(\w+)\.(\w+)$", init)
                        if mm:
                            sc.member_types[name] = "%s.%s" % (mm.group(1), mm.group(2))
                continue
            m = SIGNAL_RE.match(stripped)
            if m:
                name = m.group(1)
                sc.members[name] = "signal"
                raw_params = (m.group(2) or "").strip()
                sc.signals[name] = {
                    "line": ln,
                    "n": len([p for p in split_top(raw_params) if p.strip()]),
                    "raw": raw_params,
                }
                continue
            m = re.match(r"^enum\s+(\w+)\s*\{(.*)\}", stripped)
            if m:
                ename = m.group(1)
                sc.enums[ename] = []
                for item in m.group(2).split(","):
                    item = item.strip().split("=")[0].strip()
                    if item:
                        sc.enums[ename].append(item)
                        sc.enum_values[item] = ename
                continue
            m = re.match(r"^enum\s+(\w+)\s*\{", stripped)
            if m:
                ename = m.group(1)
                sc.enums[ename] = []
                cur_enum = ename
                continue

    # 函数行范围（用于局部参数遮蔽判断）
    ordered = [(fn.line, fn) for fn in sc.funcs.values()]
    ordered.sort()
    for i, (start, fn) in enumerate(ordered):
        end = ordered[i + 1][0] - 1 if i + 1 < len(ordered) else len(sc.lines) + 1
        sc.func_ranges.append((start, end, {p for p, _, _ in fn.params}))
    return sc


# ----------------------------------------------------------------------------
# 检查器
# ----------------------------------------------------------------------------
class Checker:
    CHAIN_RE = re.compile(r"([A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)+)(\s*\()?")
    STRING_MASK = re.compile(r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'')
    LAMBDA_RE = re.compile(r"\bfunc\s*\(([^)]*)\)")
    EMIT_RE = re.compile(
        r"(?:([A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)*)\s*\.)?"
        r"([A-Za-z_]\w+)\s*\.\s*emit\s*\(")
    CONNECT_RE = re.compile(
        r"(?:([A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)*)\s*\.)?"
        r"([A-Za-z_]\w+)\s*\.\s*connect\s*\(")

    def __init__(self, scripts):
        self.scripts = scripts
        self.class_map = {}
        for sc in scripts.values():
            if sc.class_name:
                self.class_map[sc.class_name] = sc
        self.main_script = scripts.get("main")
        self.findings = []
        self.infos = []
        # 项目类继承链（含自身）
        self.class_extends = {}
        for cname, sc in self.class_map.items():
            chain = {cname}
            cur = sc
            while cur and cur.extends:
                chain.add(cur.extends)
                nxt = self.resolve_class(cur.extends)
                if nxt is cur or nxt is None:
                    break
                cur = nxt
            self.class_extends[cname] = chain
        if self.main_script:
            chain = {"Main"}
            cur = self.main_script
            while cur and cur.extends:
                chain.add(cur.extends)
                nxt = self.resolve_class(cur.extends)
                if nxt is None:
                    break
                cur = nxt
            self.class_extends["Main"] = chain

    def resolve_class(self, tname):
        if not tname:
            return None
        t = tname.strip()
        if t == "Main":
            return self.main_script
        return self.class_map.get(t)

    def find_member(self, sc, name):
        seen = set()
        while sc and id(sc) not in seen:
            seen.add(id(sc))
            if name in sc.members:
                return ("member", sc.members[name], sc.member_types.get(name))
            if name in sc.funcs:
                return ("func", None, None)
            if name in sc.enums:
                return ("enum", None, None)
            if name in sc.enum_values:
                return ("enum_value", None, None)
            sc = self.resolve_class(sc.extends)
        return None

    def add(self, level, sc, line, msg):
        self.findings.append((level, sc.file, line, msg))

    # ---------- 表达式类型推断（启发式） ----------
    def infer_expr_type(self, expr, sc, local_types):
        expr = expr.strip()
        if not expr:
            return None
        if expr == "self":
            return sc.self_type
        if expr in LITERAL_TYPE:
            return LITERAL_TYPE[expr]
        if re.match(r'^"[^"]*"$', expr) or re.match(r"^'[^']*'$", expr):
            return "String"
        if re.match(r'^&"', expr):
            return "StringName"
        if re.match(r"^[-+]?(\d+\.?\d*|\.\d+)$", expr):
            return "float" if "." in expr else "int"
        if expr.startswith("["):
            return "Array"
        if expr.startswith("{"):
            return "Dictionary"
        m = re.match(r"^(Vector2i?|Color|Rect2i?)\s*\(", expr)
        if m:
            return m.group(1)
        m = re.match(r"^(\w+)\.new\s*\(", expr)
        if m:
            return m.group(1)
        m = re.match(r"^(\w+)\.(\w+)\s*\(.*\)$", expr)
        if m:
            base_t = self.infer_expr_type(m.group(1), sc, local_types)
            bsc = self.resolve_class(base_t)
            if bsc and m.group(2) in bsc.funcs:
                return bsc.funcs[m.group(2)].ret
            return None
        if expr.startswith("(") and expr.endswith(")"):
            return self.infer_expr_type(expr[1:-1], sc, local_types)
        m = re.match(r"^(int|float|str|bool|String|StringName|Vector2i)\s*\(.*\)$", expr)
        if m:
            return {"str": "String"}.get(m.group(1), m.group(1))
        if re.match(r"^\w+$", expr):
            if expr in PROJECT_TYPE_MAP:
                return PROJECT_TYPE_MAP[expr]
            if expr in local_types:
                return local_types[expr]
            if sc:
                mem = self.find_member(sc, expr)
                if mem:
                    return mem[2]
            return None
        return None

    def collect_local_types(self, sc):
        lt = {}
        # 带类型标注的形参（全文件近似）
        for fn in sc.funcs.values():
            for pname, ptype, _ in fn.params:
                if ptype:
                    lt[pname] = ptype
        for ln, line in logical_lines("\n".join(sc.lines)):
            stripped = line.strip()
            m = re.match(r"^(?:var|const)\s+(\w+)\s*:\s*([\w\[\].]+)\s*(?::?=|$)", stripped)
            if m:
                lt[m.group(1)] = re.sub(r"\[.*", "", m.group(2)).strip()
                continue
            m = re.match(r"^(?:var|const)\s+(\w+)\s*:=\s*(.+)$", stripped)
            if m:
                t = self.infer_expr_type(m.group(2), sc, lt)
                if t:
                    lt.setdefault(m.group(1), t)
        return lt

    # ---------- 链式访问检查 ----------
    def check_chains(self, sc, line_no, line, local_types, shadowed):
        code = self.STRING_MASK.sub('""', line)
        for m in self.CHAIN_RE.finditer(code):
            chain = re.sub(r"\s+", "", m.group(1))
            is_call = bool(m.group(2))
            start = m.start()
            if start > 0 and code[start - 1] == ".":
                continue
            parts = chain.split(".")
            head = parts[0]

            cur_sc = None
            cur_t = None
            is_enum = None
            enum_owner = None

            if head in shadowed:
                continue  # 局部参数/lambda 参数遮蔽，不按全局映射检查
            if head == "self":
                cur_t = sc.self_type
                cur_sc = self.resolve_class(cur_t)
            elif head in self.class_map or (head == "Main" and self.main_script):
                cur_sc = self.resolve_class(head)
                cur_t = head
            elif re.match(r"^[A-Z]", head):
                if head in GODOT_SINGLETONS or head in GODOT_BUILTIN_TYPES:
                    continue
                cur_t = head  # 未知大写名（可能是裸枚举名），成员按白名单保守放行
            else:
                if head in PROJECT_TYPE_MAP:
                    cur_t = PROJECT_TYPE_MAP[head]
                elif head in local_types:
                    cur_t = local_types[head]
                elif sc:
                    mem = self.find_member(sc, head)
                    if mem:
                        cur_t = mem[2] or ("Unknown" if mem[0] == "member" else None)
                cur_sc = self.resolve_class(cur_t)
                if cur_sc is None:
                    if cur_t is None:
                        continue
                    if cur_t in GODOT_BUILTIN_TYPES or cur_t in GODOT_SINGLETONS:
                        continue
                    if cur_t in ("int", "float", "bool", "String", "Array",
                                 "Dictionary", "Variant", "StringName"):
                        continue
                    mm = re.match(r"^(\w+)\.(\w+)$", cur_t)
                    if mm:
                        owner = self.resolve_class(mm.group(1))
                        if owner and mm.group(2) in owner.enums:
                            is_enum = mm.group(2)
                            enum_owner = owner
                        else:
                            continue
                    else:
                        continue

            for i, attr in enumerate(parts[1:], 1):
                last = (i == len(parts) - 1)
                if cur_sc is not None:
                    mem = self.find_member(cur_sc, attr)
                    if mem is None:
                        # 内置成员/方法白名单兜底
                        if attr in BUILTIN_MEMBERS or attr in BUILTIN_METHODS:
                            cur_sc = None
                            cur_t = None
                            continue
                        kind = "函数" if is_call else "属性/成员"
                        self.add("ERROR", sc, line_no,
                                 "在 %s 上%s「%s.%s」不存在（定义见 %s）"
                                 % (cur_sc.disp, kind, ".".join(parts[:i]), attr, cur_sc.file))
                        cur_sc = None
                        cur_t = None
                        continue
                    kind, _, mtype = mem
                    if kind == "func":
                        fn = cur_sc.funcs.get(attr)
                        if last and is_call:
                            open_pos = m.end(2) - 1
                            close = self.find_call_end(code, open_pos)
                            if close is not None:
                                args = split_top(code[open_pos + 1:close])
                                args = [a for a in args if a != ""]
                                self.check_call_args(sc, line_no, cur_sc, fn, args, local_types)
                            cur_sc = None
                            cur_t = None
                        elif not last:
                            nxt = parts[i + 1] if i + 1 < len(parts) else None
                            if nxt in ("bind", "connect", "call", "emit"):
                                cur_sc = None  # Callable 引用
                                cur_t = None
                            else:
                                cur_t = fn.ret if fn else None
                                cur_sc = self.resolve_class(cur_t)
                        else:
                            cur_sc = None  # 无括号的函数引用（Callable）
                            cur_t = None
                    elif kind == "enum":
                        is_enum = attr
                        enum_owner = cur_sc
                        cur_sc = None
                    elif kind == "enum_value":
                        cur_sc = None
                        cur_t = None
                    else:  # member（var/const/signal）
                        if mtype and self.resolve_class(mtype):
                            cur_sc = self.resolve_class(mtype)
                            cur_t = mtype
                        elif mtype and re.match(r"^\w+\.\w+$", mtype):
                            mm = re.match(r"^(\w+)\.(\w+)$", mtype)
                            owner = self.resolve_class(mm.group(1))
                            if owner and mm.group(2) in owner.enums:
                                is_enum = mm.group(2)
                                enum_owner = owner
                            cur_sc = None
                        else:
                            cur_sc = None
                            cur_t = mtype
                elif is_enum is not None:
                    if attr not in enum_owner.enums.get(is_enum, []) and attr not in BUILTIN_METHODS:
                        self.add("ERROR", sc, line_no,
                                 "枚举 %s.%s 中不存在值「%s」（定义见 %s）"
                                 % (enum_owner.disp, is_enum, attr, enum_owner.file))
                    is_enum = None
                    cur_t = None
                else:
                    # 内置/未知类型上的成员：白名单放行，未知成员保守放行
                    if cur_t in GODOT_BUILTIN_TYPES or cur_t in GODOT_SINGLETONS:
                        break
                    if attr in BUILTIN_MEMBERS or attr in BUILTIN_METHODS:
                        cur_t = None
                        continue
                    break

    def find_call_end(self, code, open_pos):
        return find_call_end_str(code, open_pos)

    def check_call_args(self, caller_sc, line_no, owner_sc, fn, args, local_types):
        n = len(args)
        label = "%s.%s()" % (owner_sc.disp, fn.name)
        if n < fn.required:
            self.add("ERROR", caller_sc, line_no,
                     "%s 参数不足：传 %d 个，必填形参 %d 个（共 %d 个，其余带默认值）（定义见 %s:%d）"
                     % (label, n, fn.required, fn.total, owner_sc.file, fn.line))
            return
        if n > fn.total:
            self.add("ERROR", caller_sc, line_no,
                     "%s 参数过多：传 %d 个，形参最多 %d 个（定义见 %s:%d）"
                     % (label, n, fn.total, owner_sc.file, fn.line))
            return
        for idx, (pname, ptype, _) in enumerate(fn.params):
            if idx >= n or ptype is None:
                continue
            arg_t = self.infer_expr_type(args[idx], caller_sc, local_types)
            if arg_t is None or arg_t == "null" or arg_t == "void":
                continue
            if not type_compatible(ptype, arg_t, self.class_extends):
                self.add("WARN", caller_sc, line_no,
                         "%s 形参 %d「%s: %s」收到推断类型 %s —— 类型明显不符，疑似实参顺序/取值错误（定义见 %s:%d）"
                         % (label, idx + 1, pname, ptype, arg_t, owner_sc.file, fn.line))


def shadowed_for_line(sc, ln, line):
    """本语句的遮蔽名：所在函数形参 + 行内 lambda 形参"""
    shadowed = set()
    for start, end, params in sc.func_ranges:
        if start <= ln <= end:
            shadowed |= params
            break
    for lm in Checker.LAMBDA_RE.finditer(line):
        shadowed |= {p.split(":")[0].strip()
                     for p in split_top(lm.group(1)) if p.strip()}
    return shadowed


def resolve_chain_type(ck, sc, parts, local_types, shadowed):
    """静默解析一条属性链的末端类型（用于信号 emit/connect 检查）。
    返回 ("project", ScriptDef) / ("builtin", 类型名) / None。"""
    head = parts[0]
    cur_sc = None
    cur_t = None
    if head in shadowed:
        return None
    if head == "self":
        cur_t = sc.self_type
        cur_sc = ck.resolve_class(cur_t)
    elif head in ck.class_map or (head == "Main" and ck.main_script):
        cur_sc = ck.resolve_class(head)
        cur_t = head
    elif re.match(r"^[A-Z]", head):
        if head in GODOT_SINGLETONS or head in GODOT_BUILTIN_TYPES:
            return ("builtin", head)
        return None
    else:
        if head in PROJECT_TYPE_MAP:
            cur_t = PROJECT_TYPE_MAP[head]
        elif head in local_types:
            cur_t = local_types[head]
        elif sc:
            mem = ck.find_member(sc, head)
            if mem:
                cur_t = mem[2] or ("Unknown" if mem[0] == "member" else None)
        cur_sc = ck.resolve_class(cur_t)
        if cur_sc is None:
            if cur_t is None:
                return None
            if cur_t in GODOT_BUILTIN_TYPES or cur_t in GODOT_SINGLETONS:
                return ("builtin", cur_t)
            if cur_t in ("int", "float", "bool", "String", "Array", "Dictionary",
                         "Variant", "StringName", "null"):
                return ("builtin", cur_t)
            return None
    for attr in parts[1:]:
        if cur_sc is None:
            return None
        mem = ck.find_member(cur_sc, attr)
        if mem is None:
            return None
        kind, _, mtype = mem
        if kind == "func":
            fn = cur_sc.funcs.get(attr)
            cur_t = fn.ret if fn else None
            cur_sc = ck.resolve_class(cur_t)
        elif kind == "member":
            if mtype and ck.resolve_class(mtype):
                cur_sc = ck.resolve_class(mtype)
                cur_t = mtype
            elif mtype and (mtype in GODOT_BUILTIN_TYPES or mtype in GODOT_SINGLETONS):
                return ("builtin", mtype)
            else:
                return None
        else:
            return None
    if cur_sc is not None:
        return ("project", cur_sc)
    if cur_t in GODOT_BUILTIN_TYPES or cur_t in GODOT_SINGLETONS:
        return ("builtin", cur_t)
    return None


# ----------------------------------------------------------------------------
# [E] 信号契约
# ----------------------------------------------------------------------------
def analyze_connect_target(ck, sc, target, local_types, shadowed, sig_n, sig_disp, ln, fname):
    """校验 connect 目标（可含 .bind(...)）。返回 (findings, 目标描述)。"""
    out = []
    desc = target if len(target) <= 48 else target[:45] + "..."
    t = target.strip()

    bind_n = 0
    base = t
    mb = None
    for mm in re.finditer(r"\.bind\s*\(", t):
        mb = mm
    if mb:
        open_pos = mb.end() - 1
        close = find_call_end_str(t, open_pos)
        if close is not None:
            bind_args = [a for a in split_top(t[open_pos + 1:close]) if a.strip()]
            bind_n = len(bind_args)
            base = t[:mb.start()].strip()

    known_sig = sig_n is not None
    n_eff = (sig_n if known_sig else 0) + bind_n

    def arity_check(fn, owner_file, who):
        if not known_sig:
            return
        if n_eff < fn.required:
            out.append(("ERROR", fname, ln,
                        "%s ← %s：回调将传 %d 参（信号 %d + bind %d），方法必填 %d 个（定义见 %s:%d）"
                        % (sig_disp, who, n_eff, sig_n, bind_n, fn.required, owner_file, fn.line)))
        elif n_eff > fn.total:
            out.append(("ERROR", fname, ln,
                        "%s ← %s：回调将传 %d 参（信号 %d + bind %d），方法最多收 %d 个（定义见 %s:%d）"
                        % (sig_disp, who, n_eff, sig_n, bind_n, fn.total, owner_file, fn.line)))

    if re.match(r"^func\s*\(", base):  # lambda
        m = re.match(r"^func\s*\(([^)]*)\)", base)
        lam = [p for p in split_top(m.group(1)) if p.strip()] if m else []
        if known_sig and len(lam) != n_eff:
            out.append(("WARN", fname, ln,
                        "%s ← lambda 形参 %d 个，但回调将传 %d 参（信号 %d + bind %d）"
                        % (sig_disp, len(lam), n_eff, sig_n, bind_n)))
        return out, desc

    if re.match(r"^\w+$", base):
        name = base
        if name in shadowed:
            return out, desc  # Callable 参数/局部变量，无法静态追踪
        fn = sc.funcs.get(name)
        if fn is None:
            if name in sc.members:
                return out, desc  # Callable 成员
            out.append(("ERROR", fname, ln,
                        "%s 的 connect 目标「%s」在本脚本中不存在" % (sig_disp, name)))
            return out, desc
        arity_check(fn, sc.file, "%s（本脚本）" % name)
        return out, desc

    if "." in base:
        parts = [p.strip() for p in base.split(".")]
        method = parts[-1]
        r = resolve_chain_type(ck, sc, parts[:-1], local_types, shadowed)
        if r is None or r[0] != "project":
            return out, desc
        owner = r[1]
        fn = owner.funcs.get(method)
        if fn is None:
            if method in owner.members:
                return out, desc  # Callable 成员
            out.append(("ERROR", fname, ln,
                        "%s 的 connect 目标方法「%s」在 %s 上不存在（定义见 %s）"
                        % (sig_disp, method, owner.disp, owner.file)))
            return out, desc
        arity_check(fn, owner.file, "%s.%s" % (owner.disp, method))
        return out, desc

    return out, desc


def check_signals(scripts, ck):
    """[E] 信号契约：signal 声明 / .emit / .connect 三方对账。"""
    findings = []
    infos = []
    emit_lines = []
    connect_lines = []
    # (脚本base, 信号名) -> [emit次数, connect次数]
    usage = {}
    for sc in scripts.values():
        for name in sc.signals:
            usage.setdefault((sc.base, name), [0, 0])

    for sc in scripts.values():
        local_types = ck.collect_local_types(sc)
        text = "\n".join(sc.lines)
        for ln, line in logical_lines(text):
            masked = Checker.STRING_MASK.sub('""', line)
            shadowed = shadowed_for_line(sc, ln, line)

            # ---- emit ----
            for m in Checker.EMIT_RE.finditer(masked):
                base = (m.group(1) or "").strip()
                sig = m.group(2)
                open_pos = m.end() - 1
                close = find_call_end_str(masked, open_pos)
                if close is None:
                    continue
                args = [a for a in split_top(masked[open_pos + 1:close]) if a.strip()]
                n = len(args)
                if not base:
                    meta = sc.signals.get(sig)
                    if meta is None:
                        if sig in sc.members:
                            continue  # Callable 成员变量的 emit
                        findings.append(("ERROR", sc.file, ln,
                                         "emit 了未声明的信号「%s」（%s 中无此 signal）" % (sig, sc.disp)))
                        continue
                    usage.setdefault((sc.base, sig), [0, 0])[0] += 1
                    if n != meta["n"]:
                        findings.append(("WARN", sc.file, ln,
                                         "%s.%s 声明 %d 参，emit 实传 %d 参（定义见 %s:%d）"
                                         % (sc.disp, sig, meta["n"], n, sc.file, meta["line"])))
                    else:
                        emit_lines.append("[OK] %s.%s.emit(%s) @ %s:%d —— %d 实参 vs 声明 %d 参"
                                          % (sc.disp, sig, ", ".join(args), sc.file, ln, n, meta["n"]))
                else:
                    parts = [p.strip() for p in re.sub(r"\s+", "", base).split(".")]
                    r = resolve_chain_type(ck, sc, parts, local_types, shadowed)
                    if r is None:
                        continue
                    kind, val = r
                    if kind == "project":
                        meta = val.signals.get(sig)
                        if meta is not None:
                            usage.setdefault((val.base, sig), [0, 0])[0] += 1
                            if n != meta["n"]:
                                findings.append(("WARN", sc.file, ln,
                                                 "%s.%s 声明 %d 参，emit 实传 %d 参（定义见 %s:%d）"
                                                 % (val.disp, sig, meta["n"], n, val.file, meta["line"])))
                            else:
                                emit_lines.append("[OK] %s.%s.emit(%s) @ %s:%d —— %d 实参 vs 声明 %d 参"
                                                  % (val.disp, sig, ", ".join(args), sc.file, ln,
                                                     n, meta["n"]))
                        elif sig in BUILTIN_SIGNALS:
                            if n != BUILTIN_SIGNALS[sig]:
                                findings.append(("WARN", sc.file, ln,
                                                 "内置信号 %s.emit 实传 %d 参（内置 %d 参）@ %s:%d"
                                                 % (sig, n, BUILTIN_SIGNALS[sig], sc.file, ln)))
                            else:
                                emit_lines.append("[OK] %s.emit()（内置信号）@ %s:%d"
                                                  % (sig, sc.file, ln))
                        else:
                            findings.append(("ERROR", sc.file, ln,
                                             "在 %s 上 emit 未声明的信号「%s」（定义见 %s）"
                                             % (val.disp, sig, val.file)))
                    else:
                        if sig in BUILTIN_SIGNALS:
                            if n != BUILTIN_SIGNALS[sig]:
                                findings.append(("WARN", sc.file, ln,
                                                 "内置信号 %s.emit 实传 %d 参（内置 %d 参）@ %s:%d"
                                                 % (sig, n, BUILTIN_SIGNALS[sig], sc.file, ln)))
                            else:
                                emit_lines.append("[OK] %s.emit()（内置信号）@ %s:%d"
                                                  % (sig, sc.file, ln))

            # ---- connect ----
            for m in Checker.CONNECT_RE.finditer(masked):
                base = (m.group(1) or "").strip()
                sig = m.group(2)
                open_pos = m.end() - 1
                close = find_call_end_str(masked, open_pos)
                if close is None:
                    continue
                args = [a for a in split_top(masked[open_pos + 1:close]) if a.strip()]
                if not args:
                    findings.append(("ERROR", sc.file, ln, "connect 缺少目标 Callable"))
                    continue
                target = args[0]
                sig_n = None
                owner_disp = None
                owner_base = None
                is_builtin = False

                if not base:
                    meta = sc.signals.get(sig)
                    if meta is None:
                        if sig in sc.members:
                            continue  # Callable 成员
                        findings.append(("ERROR", sc.file, ln,
                                         "connect 了未声明的信号「%s」（%s 中无此 signal）" % (sig, sc.disp)))
                        continue
                    sig_n = meta["n"]
                    owner_disp, owner_base = sc.disp, sc.base
                else:
                    parts = [p.strip() for p in re.sub(r"\s+", "", base).split(".")]
                    r = resolve_chain_type(ck, sc, parts, local_types, shadowed)
                    if r is None:
                        continue  # 无法解析（如 Callable 参数转发），保守跳过
                    kind, val = r
                    if kind == "project":
                        meta = val.signals.get(sig)
                        if meta is not None:
                            sig_n = meta["n"]
                            owner_disp, owner_base = val.disp, val.base
                        elif sig in BUILTIN_SIGNALS:
                            sig_n = BUILTIN_SIGNALS[sig]
                            owner_disp = parts[-1]
                            is_builtin = True
                        else:
                            findings.append(("ERROR", sc.file, ln,
                                             "在 %s 上 connect 不存在的信号「%s」（定义见 %s）"
                                             % (val.disp, sig, val.file)))
                            continue
                    else:
                        if sig in BUILTIN_SIGNALS:
                            sig_n = BUILTIN_SIGNALS[sig]
                            owner_disp = parts[-1]
                            is_builtin = True
                        else:
                            continue  # 白名单外内置信号，跳过参数校验

                if owner_base is not None:
                    usage.setdefault((owner_base, sig), [0, 0])[1] += 1
                sig_disp = "%s.%s%s" % (owner_disp or sig, sig, "（内置）" if is_builtin else "")
                tf, tdesc = analyze_connect_target(ck, sc, target, local_types, shadowed,
                                                   sig_n, sig_disp, ln, sc.file)
                findings.extend(tf)
                status = "OK" if not tf else "见上"
                connect_lines.append("[%s] %s ← %s @ %s:%d —— 信号 %s 参，目标「%s」"
                                     % (status, sig_disp, tdesc, sc.file, ln,
                                        sig_n if sig_n is not None else "?", tdesc))

    # ---- 三方对账汇总 ----
    n_decl = sum(len(sc.signals) for sc in scripts.values())
    infos.append("信号声明共 %d 个（%s）" % (
        n_decl,
        "；".join("%s.%s(%s)" % (sc.disp, name, meta["raw"])
                  for sc in scripts.values() for name, meta in sorted(sc.signals.items()))))
    unconnected = []
    for (sbase, sig), (ne, nc) in sorted(usage.items()):
        sc = scripts.get(sbase)
        if sc is None:
            continue
        meta = sc.signals.get(sig)
        if meta is None:
            continue
        line = "    %s.%s（%d 参，%s:%d）：emit %d 处，connect %d 处" % (
            sc.disp, sig, meta["n"], sc.file, meta["line"], ne, nc)
        if nc == 0:
            line += " —— 无任何 connect（若 UI 以轮询方式消费则为设计选择，非缺陷）"
            unconnected.append((sc.disp, sig))
        infos.append(line)
    return findings, infos, emit_lines, connect_lines, unconnected


def check_callable_indirection(scripts, ck):
    """main_menu._make_button(parent, text, action) 把方法引用当 Callable 传入，
    内部统一 pressed.connect(action)。按 0 参信号校验每个第 3 实参。"""
    out = []
    ok = 0
    sc = scripts.get("main_menu")
    if sc is None:
        return out, ok
    local_types = ck.collect_local_types(sc)
    for ln, line in logical_lines("\n".join(sc.lines)):
        masked = Checker.STRING_MASK.sub('""', line)
        for m in re.finditer(r"\b_make_button\s*\(", masked):
            open_pos = m.end() - 1
            close = find_call_end_str(masked, open_pos)
            if close is None:
                continue
            args = [a for a in split_top(masked[open_pos + 1:close]) if a.strip()]
            if len(args) < 3:
                continue
            shadowed = shadowed_for_line(sc, ln, line)
            tf, _desc = analyze_connect_target(ck, sc, args[2], local_types, shadowed, 0,
                                               "pressed（经 _make_button）", ln, sc.file)
            if tf:
                out.extend(tf)
            else:
                ok += 1
    return out, ok


# ----------------------------------------------------------------------------
# [F] GDScript 语法粗检
# ----------------------------------------------------------------------------
def check_syntax(scripts):
    findings = []
    infos = []
    for sc in scripts.values():
        issues = []  # (level, line, msg)
        lines = sc.lines

        # ---- 字符串/全角字符扫描（含三引号跨行块简单追踪） ----
        in_triple = None
        triple_lines = set()
        for idx, raw in enumerate(lines, 1):
            if in_triple:
                triple_lines.add(idx)
                pos = raw.find(in_triple)
                if pos >= 0:
                    in_triple = None
                continue
            i, n = 0, len(raw)
            line_open = None
            seen_fw = set()
            while i < n:
                c = raw[i]
                if line_open:
                    if c == "\\":
                        i += 2
                        continue
                    if c == line_open:
                        line_open = None
                    i += 1
                    continue
                if raw.startswith('"""', i):
                    in_triple = '"""'
                    break
                if raw.startswith("'''", i):
                    in_triple = "'''"
                    break
                if c in ('"', "'"):
                    line_open = c
                    i += 1
                    continue
                if c == "#":
                    break
                if c in FULLWIDTH_PUNCT and c not in seen_fw:
                    seen_fw.add(c)
                    issues.append(("ERROR", idx, "代码区出现全角字符「%s」（复制粘贴笔误？）" % c))
                i += 1
            if line_open:
                issues.append(("ERROR", idx, "字符串未闭合（行尾仍处于字符串内）"))

        # ---- 缩进风格 ----
        tab_cnt = space_cnt = 0
        for idx, raw in enumerate(lines, 1):
            if idx in triple_lines:
                continue
            stripped = raw.strip()
            if not stripped or stripped.startswith("#"):
                continue
            lead = raw[:len(raw) - len(raw.lstrip())]
            has_tab = "\t" in lead
            has_space = " " in lead
            if has_tab and has_space:
                issues.append(("ERROR", idx, "行内缩进 Tab 与空格混用"))
            elif has_tab:
                tab_cnt += 1
            elif has_space:
                space_cnt += 1
        if tab_cnt and space_cnt:
            issues.append(("ERROR", 0, "文件级缩进混用：Tab 缩进 %d 行 / 空格缩进 %d 行"
                           % (tab_cnt, space_cnt)))

        # ---- func 签名（逻辑块 = 括号续行 + 反斜杠续行均已合并，故可整体匹配） ----
        text = "\n".join(lines)
        blocks = logical_blocks(text)
        for ln, _end, block in blocks:
            if ln in triple_lines:
                continue
            stripped = block.strip()
            if re.match(r"^(static\s+)?func\s+\w+\s*\(", stripped):
                if not FUNC_FULL_RE.match(stripped):
                    issues.append(("ERROR", ln,
                                   "func 签名无法解析（括号不配平/缺冒号/多余尾缀）：%s"
                                   % (stripped[:72] + ("..." if len(stripped) > 72 else ""))))

        # ---- match 语句头/分支冒号 ----
        headers = []
        for idx, raw in enumerate(lines, 1):
            if idx in triple_lines:
                continue
            code = Checker.STRING_MASK.sub('""', strip_comment(raw))
            m = MATCH_HEADER_RE.match(code)
            if m:
                if not code.rstrip().endswith(":"):
                    issues.append(("ERROR", idx, "match 语句缺少结尾冒号"))
                else:
                    headers.append((idx, len(m.group(1))))
        for h_ln, h_indent in headers:
            branch_indent = None
            for idx in range(h_ln + 1, len(lines) + 1):
                if idx in triple_lines:
                    continue
                raw = lines[idx - 1]
                stripped = raw.strip()
                if not stripped or stripped.startswith("#"):
                    continue
                indent = len(raw) - len(raw.lstrip())
                if indent <= h_indent:
                    break
                if branch_indent is None:
                    branch_indent = indent
                    continue
                if indent != branch_indent:
                    continue  # 分支体（更深）或多行 pattern 续行
                code = Checker.STRING_MASK.sub('""', strip_comment(raw)).strip()
                if not has_top_level_colon(code):
                    issues.append(("ERROR", idx,
                                   "match 分支「%s」缺少冒号" % (code[:40])))

        # ---- 块语句冒号（括号续行与反斜杠续行均已合并为逻辑块） ----
        for ln, _end, block in blocks:
            if ln in triple_lines:
                continue
            stripped = block.strip()
            bm = BLOCK_KEYWORD_RE.match(stripped)
            if bm and not has_top_level_colon(stripped):
                issues.append(("ERROR", ln,
                               "块语句（%s …）缺少冒号" % bm.group(1)))

        # ---- 空块/缩进断裂（迭代4新增）：块头（以冒号结尾）的下一个非空逻辑行
        #      必须比块头更深一层；否则要么是空块，要么是同族缩进断裂 P0 ----
        for ln, end_ln, block in blocks:
            if ln in triple_lines or end_ln in triple_lines:
                continue
            stripped = block.strip()
            if not BLOCK_KEYWORD_RE.match(stripped):
                continue
            if not stripped.endswith(":"):
                continue  # 单行块（`if x: return`）或缺冒号（已另行报告）
            header_indent = len(block) - len(block.lstrip())
            body_indent = None
            for idx in range(end_ln + 1, len(lines) + 1):
                raw = lines[idx - 1]
                if not raw.strip() or raw.strip().startswith("#"):
                    continue
                if idx in triple_lines:
                    body_indent = None
                    break
                body_indent = len(raw) - len(raw.lstrip("\t"))
                break
            if body_indent is not None and body_indent <= header_indent:
                issues.append(("ERROR", ln,
                               "块语句（%s …）后缺少更深的缩进体（空块或缩进断裂）"
                               % stripped[:40]))

        # ---- 输出 ----
        if issues:
            for level, ln, msg in issues:
                loc = "%s:%d" % (sc.file, ln) if ln else sc.file
                findings.append((level, sc.file, ln, msg))
            infos.append("%s：%d 处语法粗检问题" % (sc.file, len(issues)))
        else:
            infos.append("%s：语法粗检通过（缩进/字符串/全角/match 冒号/func 签名/块冒号）" % sc.file)
    return findings, infos


# ----------------------------------------------------------------------------
# [A/B] 关键调用面逐点核验（迭代1新增 API 的映射覆盖证明）
# ----------------------------------------------------------------------------
KEY_SURFACES = [
    ("RaidManager.game → Main（main.gd）", r"\bgame\s*\.\s*\w+", None, None),
    ("game.hud → HUD", r"\bgame\s*\.\s*hud\b", "HUD", None),
    ("HUD.show_toast", r"\.show_toast\s*\(", "HUD", "show_toast"),
    ("HUD.show_coronation", r"\.show_coronation\s*\(", "HUD", "show_coronation"),
    ("HUD.invalidate_villager_list", r"\.invalidate_villager_list\s*\(",
     "HUD", "invalidate_villager_list"),
    ("RaidManager.raid_pending", r"\braid_pending\b", "RaidManager", "raid_pending"),
    ("RaidManager.raid_started_day", r"\braid_started_day\b", "RaidManager", "raid_started_day"),
    ("RaidManager.raid_mood_bonus / raid_mood_days_left",
     r"\braid_mood_(?:bonus|days_left)\b", "RaidManager", None),
    ("RaidManager.banner_text（横幅轮询）", r"\bbanner_text\b", "RaidManager", "banner_text"),
    ("RaidManager.retreat / on_new_day / tick / setup",
     r"\braid\s*\.\s*(?:retreat|on_new_day|tick|setup)\s*\(", "RaidManager", None),
]


def check_key_surfaces(scripts, ck):
    findings = []
    infos = []
    for label, pat, owner_cls, member in KEY_SURFACES:
        count = 0
        rx = re.compile(pat)
        for sc in scripts.values():
            for ln, line in logical_lines("\n".join(sc.lines)):
                masked = Checker.STRING_MASK.sub('""', line)
                count += len(rx.findall(masked))
        detail = ""
        if owner_cls:
            osc = ck.resolve_class(owner_cls)
            if osc is None:
                findings.append(("ERROR", "static_check", 0,
                                 "关键调用面 %s：类 %s 不存在" % (label, owner_cls)))
            elif member is not None and ck.find_member(osc, member) is None:
                findings.append(("ERROR", "static_check", 0,
                                 "关键调用面 %s：成员 %s.%s 不存在（定义见 %s）"
                                 % (label, owner_cls, member, osc.file)))
            else:
                detail = ("，成员 %s.%s 存在" % (owner_cls, member)) if member \
                    else ("，类 %s 存在" % owner_cls)
        infos.append("    %s：代码中出现 %d 处%s" % (label, count, detail))
    return findings, infos


# ----------------------------------------------------------------------------
# [C] 字典键一致性
# ----------------------------------------------------------------------------
def check_catalog_keys(scripts):
    infos = []
    with open(CATALOG_FILE, "r", encoding="utf-8") as f:
        text = f.read()
    catalog_keys = set()
    for ln, line in logical_lines(text):
        if re.match(r"^const\s+ALL\s*:\s*Array\[Dictionary\]", line.strip()):
            eq = line.index("=")
            s = line[line.index("[", eq):]
            depth, i = 0, 0
            while i < len(s):
                if s[i] == "[":
                    depth += 1
                elif s[i] == "]":
                    depth -= 1
                    if depth == 0:
                        block = s[:i + 1]
                        catalog_keys = {m.group(1) for m in re.finditer(r'"(\w+)"\s*:', block)}
                        break
                i += 1
            break

    # 查询点（仅限针对建筑目录字典的访问，避免混入存档 JSON 键）：
    #   1) 任意文件中  X.data.get("k") / X.data["k"]   —— X.data 是 Building.data
    #   2) building.gd / hud.gd 中裸 data.get("k")     —— 这两个文件里 data 即目录字典
    #   3) building_placer.gd 中 selected.get("k")    —— selected 即目录字典
    #   4) main.gd 中 catalog.get("k")               —— load_game 里的目录条目
    patterns = [
        re.compile(r'\w+\.data\s*\.\s*get\(\s*&?"(\w+)"'),
        re.compile(r'\w+\.data\s*\[\s*&?"(\w+)"\s*\]'),
    ]
    scoped = [
        ("building.gd", re.compile(r'(?<![\w.])data\s*\.\s*get\(\s*&?"(\w+)"')),
        ("building.gd", re.compile(r'(?<![\w.])data\s*\[\s*&?"(\w+)"\s*\]')),
        ("hud.gd", re.compile(r'(?<![\w.])data\s*\.\s*get\(\s*&?"(\w+)"')),
        ("hud.gd", re.compile(r'(?<![\w.])data\s*\[\s*&?"(\w+)"\s*\]')),
        ("building_placer.gd", re.compile(r'\bselected\s*\.\s*get\(\s*&?"(\w+)"')),
        ("building_placer.gd", re.compile(r'\bselected\s*\[\s*&?"(\w+)"\s*\]')),
        ("main.gd", re.compile(r'\bcatalog\s*\.\s*get\(\s*&?"(\w+)"')),
        # 迭代6 拆分：load_game 里的目录条目查询移至 save_manager.gd（main.gd 条目保留，兼容回退）
        ("save_manager.gd", re.compile(r'\bcatalog\s*\.\s*get\(\s*&?"(\w+)"')),
    ]
    used = {}
    for sc in scripts.values():
        for ln, line in logical_lines("\n".join(sc.lines)):
            for pat in patterns:
                for m in pat.finditer(line):
                    used.setdefault(m.group(1), []).append("%s:%d" % (sc.file, ln))
            for fname, pat in scoped:
                if sc.file == fname:
                    for m in pat.finditer(line):
                        used.setdefault(m.group(1), []).append("%s:%d" % (sc.file, ln))
    missing = {k: v for k, v in used.items() if k not in catalog_keys}
    unused = sorted(catalog_keys - set(used))
    return catalog_keys, used, missing, unused, infos


# ----------------------------------------------------------------------------
# [D] 存档对称性
# ----------------------------------------------------------------------------
def dict_literal_keys(s):
    """s 从 '{' 开始，返回顶层键集合（字符串安全、忽略嵌套）"""
    keys = set()
    depth = 0
    i = 0
    in_str = None
    seg_start = None
    while i < len(s):
        c = s[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == in_str:
                in_str = None
        elif c in ("\"", "'"):
            in_str = c
        elif c == "{":
            depth += 1
            if depth == 1:
                seg_start = i + 1
        elif c == "}":
            depth -= 1
            if depth == 0 and seg_start is not None:
                seg = s[seg_start:i]
                d = 0
                j = 0
                instr2 = None
                while j < len(seg):
                    ch = seg[j]
                    if instr2:
                        if ch == "\\":
                            j += 2
                            continue
                        if ch == instr2:
                            instr2 = None
                    elif ch in ("\"", "'"):
                        instr2 = ch
                    elif ch in "([{":
                        d += 1
                    elif ch in ")]}":
                        d -= 1
                    elif ch == ":" and d == 0:
                        m = re.search(r'"(\w+)"\s*$', seg[:j])
                        if m:
                            keys.add(m.group(1))
                    j += 1
                seg_start = None
        i += 1
    return keys


def extract_func_body(sc, func_name):
    lls = logical_lines("\n".join(sc.lines))
    body = []
    in_fn = False
    for ln, line in lls:
        stripped = line.strip()
        if not in_fn:
            if re.match(r"^func\s+%s\s*\(" % re.escape(func_name), stripped):
                in_fn = True
            continue
        if re.match(r"^func\s+\w+", stripped):
            return body
        body.append((ln, line))
    return body


def check_save_symmetry(scripts):
    infos = []
    issues = []
    # 防假绿守卫（迭代6 拆分预案）：提取不到函数体/三组键集全空时输出 [ERROR]。
    # 否则"空集 vs 空集"的对称会静默放行真正的回归（存档函数被移走/改名照样全绿）。
    errors = []
    sc = scripts.get("save_manager")
    if sc is None:
        sc = scripts.get("main")  # 兼容回退：未拆分版本仍直接读 main.gd
    if sc is None:
        errors.append("scripts/save_manager.gd（回退 scripts/main.gd）均不存在，存档对称性检查无目标文件")
        return errors, issues, infos, set(), set(), set(), set(), set(), set()
    infos.append("检查目标：%s（迭代6 拆分；save_manager.gd 缺失时回退 main.gd）" % sc.file)
    written, read = {}, {}

    save_body = extract_func_body(sc, "save_game")
    load_body = extract_func_body(sc, "load_game")
    list_body = extract_func_body(sc, "get_save_list")
    for fname, body in (("save_game", save_body), ("load_game", load_body),
                        ("get_save_list", list_body)):
        if not body:
            errors.append("%s 中未提取到 func %s 函数体（存档实现被移走/改名？防静默假绿守卫）"
                          % (sc.file, fname))

    for ln, line in save_body:
        if re.search(r"\bdata\s*:=\s*\{", line) or re.search(r"\bdata\s*=\s*\{", line):
            written["<顶层>"] = dict_literal_keys(line[line.index("{"):])
        m = re.search(r"building_list\.append\s*\(", line)
        if m and "{" in line:
            written["<buildings条目>"] = dict_literal_keys(line[line.index("{"):])
        m = re.search(r"villager_list\.append\s*\(", line)
        if m and "{" in line:
            written["<villagers条目>"] = dict_literal_keys(line[line.index("{"):])

    top_read, b_read, v_read = set(), set(), set()
    for ln, line in load_body + list_body:
        for m in re.finditer(r'\bbd\s*\.\s*get\(\s*"(\w+)"|\bbd\s*\[\s*"(\w+)"\s*\]', line):
            b_read.add(next(g for g in m.groups() if g))
        for m in re.finditer(r'\bvd\s*\.\s*get\(\s*"(\w+)"|\bvd\s*\[\s*"(\w+)"\s*\]', line):
            v_read.add(next(g for g in m.groups() if g))
        for m in re.finditer(r'(?<![\w.])data\s*\.\s*get\(\s*"(\w+)"|(?<![\w.])data\s*\[\s*"(\w+)"\s*\]', line):
            top_read.add(next(g for g in m.groups() if g))
        for m in re.finditer(r'\bparsed\s*\.\s*get\(\s*"(\w+)"', line):
            top_read.add(next(g for g in m.groups() if g))

    top_written = written.get("<顶层>", set())
    b_written = written.get("<buildings条目>", set())
    v_written = written.get("<villagers条目>", set())

    # 守卫：三组键集全空 = 源码里根本没提取到任何存档 JSON 键（函数体为空同义）→ 硬报错
    if not (top_written or b_written or v_written
            or top_read or b_read or v_read):
        errors.append("%s 中 save_game/load_game/get_save_list 三组键集全空（未提取到任何存档 JSON 键）"
                      % sc.file)

    def diff(name, w, r):
        only_w = sorted(w - r)
        only_r = sorted(r - w)
        if only_w:
            issues.append("%s 写入但从未读取：%s" % (name, ", ".join(only_w)))
        if only_r:
            issues.append("%s 读取但从未写入：%s" % (name, ", ".join(only_r)))
        if not only_w and not only_r:
            infos.append("%s：%d 个键两侧一致" % (name, len(w)))

    diff("顶层", top_written, top_read)
    diff("buildings 条目", b_written, b_read)
    diff("villagers 条目", v_written, v_read)
    infos.append("stock：写入 str(Type) / 读取 stock_data.get(str(t), 0)，动态键同构")
    return (errors, issues, infos, top_written, top_read, b_written, b_read, v_written, v_read)


# ----------------------------------------------------------------------------
# 主流程
# ----------------------------------------------------------------------------
ALL_SCRIPTS = {}


def main():
    scripts = {}
    for d in SCAN_DIRS:
        if not os.path.isdir(d):
            continue
        for fn in sorted(os.listdir(d)):
            if fn.endswith(".gd"):
                sc = parse_script(os.path.join(d, fn))
                scripts[sc.base] = sc

    out = []
    def w(s=""):
        out.append(s)

    w("=" * 78)
    w("KingdomBuilder 启发式静态检查报告")
    w("生成时间：%s" % datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"))
    w("运行时：Python %s" % sys.version.split()[0])
    w("工具版本：迭代2（新增 [E] 信号契约 / [F] 语法粗检；[A] 映射补全 game→Main；[D] 新字段复跑）")
    w("扫描目录：%s" % ", ".join(os.path.relpath(d, PROJECT) for d in SCAN_DIRS))
    w("脚本清单：%s" % ", ".join("%s(%s)" % (sc.file, sc.disp) for sc in scripts.values()))
    w("=" * 78)

    ck = Checker(scripts)

    w("")
    w("[A] 跨脚本调用契约 + [B] 幽灵属性（obj.method / obj.attr 扫描）")
    w("-" * 78)
    for sc in scripts.values():
        local_types = ck.collect_local_types(sc)
        full_text = "\n".join(sc.lines)
        for ln, line in logical_lines(full_text):
            shadowed = shadowed_for_line(sc, ln, line)
            before = len(ck.findings)
            ck.check_chains(sc, ln, line, local_types, shadowed)
            for f in ck.findings[before:]:
                w("  [%s] %s:%d  %s" % (f[0], f[1], f[2], f[3]))
    if not ck.findings:
        w("  （未发现可疑调用/成员访问）")
    w("  小计：ERROR=%d, WARN=%d" % (
        sum(1 for f in ck.findings if f[0] == "ERROR"),
        sum(1 for f in ck.findings if f[0] == "WARN")))

    w("  对象映射覆盖（迭代2）：PROJECT_TYPE_MAP 新增 game→Main（RaidManager 持有 main.gd），")
    w("  迭代1新增调用面全部纳入 [A] 扫描；逐点核验：")
    k_findings, k_infos = check_key_surfaces(scripts, ck)
    for msg in k_infos:
        w(msg)
    for f in k_findings:
        w("  [%s] %s" % (f[0], f[3]))

    w("")
    w("[C] 字典键一致性（building_catalog.gd vs 全代码目录字典查询）")
    w("-" * 78)
    catalog_keys, used, missing, unused, c_infos = check_catalog_keys(scripts)
    w("  catalog 定义键（%d 个）：%s" % (len(catalog_keys), ", ".join(sorted(catalog_keys))))
    w("  代码查询键（%d 个）：%s" % (len(used), ", ".join(sorted(used))))
    for f, msg in c_infos:
        w("  INFO %s %s" % (f, msg))
    if missing:
        for k, locs in sorted(missing.items()):
            w("  [ERROR] 代码查询了 catalog 未定义的键「%s」：%s" % (k, ", ".join(locs)))
    else:
        w("  未发现「代码查询了但 catalog 未定义」的键")
    if unused:
        w("  INFO catalog 定义但未见查询的键：%s" % ", ".join(unused))
    else:
        w("  INFO catalog 所有键在代码中均有查询")

    w("")
    w("[D] 存档对称性（save_manager.gd save_game 写入 vs load_game/get_save_list 读取；缺失时回退 main.gd）")
    w("-" * 78)
    d_errors, d_issues, d_infos, tw, tr, bw, br, vw, vr = check_save_symmetry(scripts)
    for msg in d_errors:
        w("  [ERROR] 防假绿守卫：" + msg)
    w("  顶层写入键（%d）：%s" % (len(tw), ", ".join(sorted(tw))))
    w("  顶层读取键（%d）：%s" % (len(tr), ", ".join(sorted(tr))))
    w("  buildings 条目 写入(%d)/读取(%d)：%s | %s" % (len(bw), len(br), ", ".join(sorted(bw)), ", ".join(sorted(br))))
    w("  villagers 条目 写入(%d)/读取(%d)：%s | %s" % (len(vw), len(vr), ", ".join(sorted(vw)), ", ".join(sorted(vr))))
    for msg in d_infos:
        w("  INFO " + msg)
    w("  迭代2复跑——迭代1新增字段两侧一致性断言：")
    for k in ("happiness", "raid_pending", "raid_started_day"):
        okc = (k in tw) and (k in tr)
        w("    %-18s 写入=%s 读取=%s %s" % (k, k in tw, k in tr, "一致" if okc else "不一致！"))
        if not okc:
            d_issues.append("迭代1新增字段「%s」未两侧同时出现" % k)
    if d_issues:
        for msg in d_issues:
            w("  [WARN] " + msg)
    else:
        w("  未发现写入/读取键差集")

    w("")
    w("[E] 信号契约（signal 声明 / .emit / .connect 三方对账）")
    w("-" * 78)
    s_findings, s_infos, emit_lines, connect_lines, unconnected = check_signals(scripts, ck)
    for msg in s_infos:
        w("  " + msg)
    if emit_lines:
        w("  emit 校验（%d 处）：" % len(emit_lines))
        for msg in emit_lines:
            w("    " + msg)
    if connect_lines:
        w("  connect 校验（%d 处）：" % len(connect_lines))
        for msg in connect_lines:
            w("    " + msg)
    ci_findings, ci_ok = check_callable_indirection(scripts, ck)
    if ci_ok or ci_findings:
        w("  Callable 间接连接（main_menu._make_button 模式，按 pressed 0 参校验）：")
        if ci_ok:
            w("    [OK] %d 处 _make_button 实参校验通过" % ci_ok)
        for f in ci_findings:
            w("    [%s] %s:%d  %s" % (f[0], f[1], f[2], f[3]))
    for f in s_findings:
        w("  [%s] %s:%d  %s" % (f[0], f[1], f[2], f[3]))
    w("  小计：ERROR=%d, WARN=%d" % (
        sum(1 for f in s_findings + ci_findings if f[0] == "ERROR"),
        sum(1 for f in s_findings + ci_findings if f[0] == "WARN")))

    w("")
    w("[F] GDScript 语法粗检（缩进混用 / 字符串未闭合 / 全角字符 / match 冒号 / func 签名 / 块冒号）")
    w("-" * 78)
    y_findings, y_infos = check_syntax(scripts)
    for msg in y_infos:
        w("  " + msg)
    for f in y_findings:
        w("  [%s] %s:%d  %s" % (f[0], f[1], f[2] if f[2] else 0, f[3]))
    w("  小计：ERROR=%d, WARN=%d" % (
        sum(1 for f in y_findings if f[0] == "ERROR"),
        sum(1 for f in y_findings if f[0] == "WARN")))

    w("")
    w("=" * 78)
    total_err = (sum(1 for f in ck.findings if f[0] == "ERROR")
                 + sum(1 for f in s_findings + ci_findings + y_findings + k_findings if f[0] == "ERROR"))
    total_warn = (sum(1 for f in ck.findings if f[0] == "WARN")
                  + sum(1 for f in s_findings + ci_findings + y_findings + k_findings if f[0] == "WARN"))
    w("总结：全部分节 ERROR=%d / WARN=%d（启发式，需人工逐条核对剔除误报）" % (total_err, total_warn))
    w("启发式检查结束。注意：以上为工具原始输出，需人工逐条核对源码剔除误报。")
    w("=" * 78)

    report = "\n".join(out)
    with open(REPORT_FILE, "w", encoding="utf-8") as f:
        f.write(report + "\n")
    print(report)
    print("\n报告已写入：%s" % REPORT_FILE)


if __name__ == "__main__":
    main()
