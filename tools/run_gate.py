#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
KingdomBuilder 一键启动安全门禁（run_gate.py）
================================================
「修改前后必跑」的统一门禁入口：聚合 static_check 子进程与 7 项独立检查，
输出统一的 GO / NO-GO 结论（控制台 + tools/gate_report.txt 追加）。

用法：
    python tools/run_gate.py                       # 对主工程跑全套门禁
    python tools/run_gate.py --snapshot <目录>     # 对快照目录（建议 _releases/ 下）跑同一套检查
    python tools/run_gate.py --json                # stdout 输出机器可读 JSON（报告文件照常追加）

退出码：GO=0 / NO-GO=1（便于接 CI）；参数用法错误为 2。

门禁项与判定规则（任何一项出现 ERROR 级发现 → NO-GO；WARN 只列出、不阻塞）：
  [1]  调用 tools/static_check.py 子进程并解析输出：任何 ERROR 级发现 → NO-GO；
       WARN 全部列出但不作为失败。主工程模式在项目内原位运行（同时刷新其报告）；
       快照模式把 scripts/tests/工具复制到系统临时目录运行，绝不改动快照内容。
  [2a] 独立 .gd 块结构解析器（自写最小词法，与 static_check 互为冗余、防工具自身盲区）：
       三引号串/注释屏蔽 + 括号续行合并后，要求每个 func/if/elif/else/for/while/match/
       class 块头（行尾冒号）之后必须存在「更深」的缩进体——空块/缩进断裂/文件尾悬空
       块头 → ERROR；块语句缺冒号 → ERROR；行内 Tab+空格混用、文件级 Tab/空格风格
       混用 → ERROR；同级块头的块体首行缩进不一致 → WARN。
  [2b] 每个文件括号/引号配平：屏蔽字符串与注释后 (){}[] 必须配平，多余闭合/类型
       不匹配/未闭合 → ERROR；未闭合字符串（含三引号）→ ERROR。
  [2c] 关键文件存在性：scripts/ 14 个 .gd + scenes/main.tscn + project.godot + 字体文件。
       快照模式特例：project.godot 按 SNAPSHOT.md 设计不随快照分发（回滚时把快照内容
       复制回主工程根目录、由主工程提供），缺失记 WARN 并注明；其余缺失仍为 ERROR。
  [2d] project.godot 的 run/main_scene 必须指向存在的场景文件（无 project.godot 时
       快照模式记 WARN，主工程模式记 ERROR）。
  [2e] scenes/main.tscn 的全部 ext_resource path 必须存在；一个 ext_resource 都没有
       → ERROR（场景未挂载任何资源，无法启动游戏逻辑）。
  [2f] 存档对称性快速复核（独立实现，不依赖 static_check）：从 save_manager.gd 源码提取
       save_game 写入键 vs load_game/get_save_list 读取键（顶层 / buildings 条目 /
       villagers 条目 三组），要求每组键数>0 且两侧差集为空。
  [2g] 目录干净性：scripts/ 下不得有 *.bak / *.tmp / *~ / *.orig 临时备份文件。

结果追加写入 tools/gate_report.txt（每次运行追加一个 RUN 块，保留历史便于
「修改前后」对比）。
"""

import argparse
import datetime
import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
MAIN_PROJECT = os.path.dirname(TOOL_DIR)
REPORT_FILE = os.path.join(TOOL_DIR, "gate_report.txt")
STATIC_CHECK = "static_check.py"

# scripts/ 必须在位的 14 个 .gd（迭代4 基线清单 + 迭代6 拆分新增 save_manager.gd）
EXPECTED_SCRIPTS = [
    "building.gd", "building_catalog.gd", "building_placer.gd", "enemy.gd",
    "grid_manager.gd", "hud.gd", "main.gd", "main_menu.gd", "raid_manager.gd",
    "resource_manager.gd", "save_manager.gd", "time_manager.gd", "ui_font.gd",
    "villager.gd",
]
EXPECTED_SCENE = os.path.join("scenes", "main.tscn")
EXPECTED_FONT = os.path.join("fonts", "NotoSansCJKsc-Regular.otf")
FONT_EXTS = (".otf", ".ttf", ".woff", ".woff2")

TEMP_FILE_PATTERNS = ["*.bak", "*.tmp", "*~", "*.orig"]

BLOCK_KEYWORD_RE = re.compile(r"^(if|elif|else|for|while|match|func|class)\b")
PAIR = {")": "(", "]": "[", "}": "{"}
BRACKETS_OPEN = "([{"
BRACKETS_CLOSE = ")]}"


def err(file, line, message):
    return {"level": "ERROR", "file": file, "line": line, "message": message}


def warn(file, line, message):
    return {"level": "WARN", "file": file, "line": line, "message": message}


def loc(f):
    if f.get("file") and f.get("line"):
        return "%s:%d" % (f["file"], f["line"])
    return f.get("file") or "-"


# ----------------------------------------------------------------------------
# 最小词法：三引号串/行字符串/注释屏蔽 → 逐行"纯代码"文本
# ----------------------------------------------------------------------------
def mask_code_lines(text):
    """返回 (masked_lines, string_errors)。
    masked_lines[i] 与源文件第 i+1 行对应：字符串字面量替换为 "" 占位、注释移除，
    其余字符（含行首缩进）原样保留；三引号串的中间行变成空串。
    注意必须用 "" 占位而非整段删除：删除会让字符串后面紧跟的空格被误当行首缩进，
    造成「Tab 与空格混用」假阳性。
    string_errors：行内未闭合的字符串（含未终止的三引号串由后续行体现）。"""
    lines = text.splitlines()
    masked = []
    str_errors = []
    open_triple = None  # 未闭合三引号的引号字符
    for idx, raw in enumerate(lines, 1):
        buf = []
        i, n = 0, len(raw)
        if open_triple is not None:
            close = raw.find(open_triple * 3)
            if close == -1:
                masked.append("")  # 整行都在三引号串内
                continue
            buf.append('""')  # 三引号串收尾部分同样占位
            i = close + 3
            open_triple = None
        while i < n:
            if raw.startswith('"""', i):
                end = raw.find('"""', i + 3)
                buf.append('""')
                if end == -1:
                    open_triple = '"'
                    break
                i = end + 3
                continue
            if raw.startswith("'''", i):
                end = raw.find("'''", i + 3)
                buf.append('""')
                if end == -1:
                    open_triple = "'"
                    break
                i = end + 3
                continue
            c = raw[i]
            if c in ('"', "'"):
                q = c
                j = i + 1
                closed = False
                while j < n:
                    if raw[j] == "\\":
                        j += 2
                        continue
                    if raw[j] == q:
                        j += 1
                        closed = True
                        break
                    j += 1
                buf.append('""')
                if not closed:
                    str_errors.append((idx, "字符串未闭合（行尾仍处于字符串内）"))
                    break  # 该行剩余部分按字符串处理，不再产出代码
                i = j
                continue
            if c == "#":
                break  # 注释，整段丢弃
            buf.append(c)
            i += 1
        masked.append("".join(buf))
    return masked, str_errors


def merge_logical(masked):
    """把括号未闭合的续行 / 行尾反斜杠续行合并成逻辑行。
    返回列表元素：{"start", "end", "leading"(首行行首空白), "code"(去首尾空白的代码)}。"""
    logicals = []
    cur = None
    depth = 0
    for idx, code in enumerate(masked, 1):
        s = code.strip()
        if cur is None:
            if not s:
                continue
            leading = code[: len(code) - len(code.lstrip())]
            cur = {"start": idx, "end": idx, "leading": leading, "code": s}
        else:
            if s:
                cur["code"] += " " + s
            cur["end"] = idx
        depth += (code.count("(") - code.count(")")
                  + code.count("[") - code.count("]")
                  + code.count("{") - code.count("}"))
        cont = code.rstrip().endswith("\\")  # 反斜杠续行（字符串内的已被屏蔽）
        if depth <= 0 and not cont:
            logicals.append(cur)
            cur = None
            depth = 0
    if cur is not None:
        logicals.append(cur)  # 到文件尾仍未闭合：配平检查会另行报告
    return logicals


def has_top_colon(code):
    """屏蔽后的代码里，括号深度 0 处是否存在冒号"""
    depth = 0
    for c in code:
        if c in BRACKETS_OPEN:
            depth += 1
        elif c in BRACKETS_CLOSE:
            depth -= 1
        elif c == ":" and depth == 0:
            return True
    return False


def is_deeper(child_leading, parent_leading):
    """child 缩进是否严格深于 parent（风格无关：前缀包含且更长）"""
    return child_leading.startswith(parent_leading) and len(child_leading) > len(parent_leading)


# ----------------------------------------------------------------------------
# .gd 文件扫描（scripts/ 与 tests/，与 static_check 同范围）
# ----------------------------------------------------------------------------
def scan_gd_files(target):
    files = []
    for sub in ("scripts", "tests"):
        d = os.path.join(target, sub)
        if not os.path.isdir(d):
            continue
        for name in sorted(os.listdir(d)):
            if name.endswith(".gd"):
                files.append(os.path.join(d, name))
    scanned = []
    read_errors = []
    for p in files:
        rel = os.path.relpath(p, target).replace(os.sep, "/")
        try:
            with open(p, "r", encoding="utf-8-sig", errors="replace") as f:
                text = f.read()
        except OSError as e:
            read_errors.append(err(rel, None, "无法读取 .gd 文件：%s" % e))
            continue
        masked, str_errors = mask_code_lines(text)
        logicals = merge_logical(masked)
        scanned.append({
            "rel": rel,
            "masked": masked,
            "logicals": logicals,
            "str_errors": str_errors,
        })
    return {"files": scanned, "read_errors": read_errors}


# ----------------------------------------------------------------------------
# [2a] 块结构检查
# ----------------------------------------------------------------------------
def check_blocks_one(rel, masked, logicals):
    findings = []
    tab_lines = space_lines = 0
    for idx, code in enumerate(masked, 1):
        if not code.strip():
            continue
        lead = code[: len(code) - len(code.lstrip())]
        has_tab = "\t" in lead
        has_space = " " in lead
        if has_tab and has_space:
            findings.append(err(rel, idx, "行内缩进 Tab 与空格混用"))
        elif has_tab:
            tab_lines += 1
        elif has_space:
            space_lines += 1
    if tab_lines and space_lines:
        findings.append(err(rel, 0, "文件级缩进风格混用：Tab 缩进 %d 行 / 空格缩进 %d 行"
                           % (tab_lines, space_lines)))

    bodies = {}  # 块头缩进 -> {块体缩进 -> [块头行号]}
    for i, lg in enumerate(logicals):
        code = lg["code"]
        if not BLOCK_KEYWORD_RE.match(code):
            continue
        if not has_top_colon(code):
            findings.append(err(rel, lg["start"],
                                "块语句（%s …）缺少冒号" % code[:48]))
            continue
        if not code.endswith(":"):
            continue  # 单行块（`if x: return`）：冒号后有内联体，无需更深缩进
        if i + 1 >= len(logicals):
            findings.append(err(rel, lg["start"],
                                "块语句（%s …）后没有更深的缩进体（空块直至文件尾）"
                                % code[:48]))
            continue
        nxt = logicals[i + 1]
        if not is_deeper(nxt["leading"], lg["leading"]):
            findings.append(err(rel, lg["start"],
                                "块语句（%s …）后缺少更深的缩进体（空块或缩进断裂，下一代码行缩进=%r）"
                                % (code[:48], nxt["leading"])))
            continue
        bodies.setdefault(lg["leading"], {}).setdefault(nxt["leading"], []).append(lg["start"])

    for hl, m in sorted(bodies.items()):
        if len(m) > 1:
            det = "；".join("%r（%d 处，如行 %s）" % (bl, len(v), v[0])
                           for bl, v in sorted(m.items()))
            findings.append(warn(rel, None,
                                 "同级块头（缩进 %r）的块体缩进不一致：%s" % (hl, det)))
    return findings


def check_blocks(target, mode, ctx):
    errors, warnings, infos = [], [], []
    gd = ctx["gd"]
    for e in gd["read_errors"]:
        errors.append(e)
    n_headers = 0
    for f in gd["files"]:
        f_errs = check_blocks_one(f["rel"], f["masked"], f["logicals"])
        n_headers += sum(1 for lg in f["logicals"] if BLOCK_KEYWORD_RE.match(lg["code"]))
        for e in f_errs:
            (errors if e["level"] == "ERROR" else warnings).append(e)
    infos.append("块结构解析覆盖 %d 个 .gd 文件（scripts + tests），共识别 %d 个块头；"
                 "空块/缩进断裂/缺冒号 → ERROR，同级块体缩进不一致 → WARN"
                 % (len(gd["files"]), n_headers))
    return errors, warnings, infos


# ----------------------------------------------------------------------------
# [2b] 括号/引号配平
# ----------------------------------------------------------------------------
def check_balance(target, mode, ctx):
    errors, warnings, infos = [], [], []
    gd = ctx["gd"]
    for e in gd["read_errors"]:
        errors.append(e)
    for f in gd["files"]:
        rel = f["rel"]
        for ln, msg in f["str_errors"]:
            errors.append(err(rel, ln, msg))
        stack = []  # (char, line, col)
        for idx, code in enumerate(f["masked"], 1):
            for col, c in enumerate(code, 1):
                if c in BRACKETS_OPEN:
                    stack.append((c, idx, col))
                elif c in BRACKETS_CLOSE:
                    if not stack:
                        errors.append(err(rel, idx,
                                          "多余的闭合括号「%s」（前面没有可配对的开放括号）" % c))
                    else:
                        oc, ol, ocol = stack.pop()
                        if oc != PAIR[c]:
                            errors.append(err(rel, idx,
                                              "括号类型不匹配：「%s」(%d:%d) 被「%s」(%d:%d) 闭合"
                                              % (oc, ol, ocol, c, idx, col)))
        for oc, ol, ocol in stack:
            errors.append(err(rel, ol, "括号「%s」未闭合（打开于 %s:%d:%d，直至文件尾未配对）"
                              % (oc, rel, ol, ocol)))
    infos.append("括号/引号配平检查覆盖 %d 个 .gd 文件（屏蔽字符串与注释后统计 (){}[]）；"
                 "未闭合字符串含三引号串" % len(gd["files"]))
    return errors, warnings, infos


# ----------------------------------------------------------------------------
# [2c] 关键文件存在性
# ----------------------------------------------------------------------------
def check_files(target, mode, ctx):
    errors, warnings, infos = [], [], []
    scripts_dir = os.path.join(target, "scripts")
    actual = []
    if os.path.isdir(scripts_dir):
        actual = sorted(n for n in os.listdir(scripts_dir) if n.endswith(".gd"))
    else:
        errors.append(err("scripts/", None, "scripts/ 目录不存在"))
    for name in EXPECTED_SCRIPTS:
        if name not in actual:
            errors.append(err("scripts/" + name, None,
                              "缺少关键脚本文件：scripts/%s（基线要求 14 个 .gd 全部在位）" % name))
    extras = [n for n in actual if n not in EXPECTED_SCRIPTS]
    infos.append("scripts/ 实有 %d 个 .gd（基线要求 %d 个）；缺失 %d 个，额外 %d 个%s"
                 % (len(actual), len(EXPECTED_SCRIPTS),
                    len([n for n in EXPECTED_SCRIPTS if n not in actual]), len(extras),
                    ("（不阻塞）：" + ", ".join(extras)) if extras else ""))

    if not os.path.isfile(os.path.join(target, EXPECTED_SCENE)):
        errors.append(err(EXPECTED_SCENE, None, "缺少关键场景文件：%s" % EXPECTED_SCENE))
    else:
        infos.append("%s 存在" % EXPECTED_SCENE.replace(os.sep, "/"))

    pg = os.path.join(target, "project.godot")
    if os.path.isfile(pg):
        infos.append("project.godot 存在")
    elif mode == "snapshot":
        warnings.append(warn("project.godot", None,
                             "快照不含 project.godot——按 SNAPSHOT.md 设计，回滚时把快照内容"
                             "复制回主工程根目录、由主工程提供该文件；不作为 NO-GO 依据"))
    else:
        errors.append(err("project.godot", None, "缺少 project.godot（无它 Godot 无法识别工程）"))

    font_path = os.path.join(target, EXPECTED_FONT)
    if os.path.isfile(font_path):
        infos.append("字体文件存在：%s" % EXPECTED_FONT.replace(os.sep, "/"))
    else:
        found_font = None
        fonts_dir = os.path.join(target, "fonts")
        if os.path.isdir(fonts_dir):
            for n in sorted(os.listdir(fonts_dir)):
                if n.lower().endswith(FONT_EXTS):
                    found_font = "fonts/" + n
                    break
        if found_font:
            warnings.append(warn(found_font, None,
                                 "预期字体 %s 缺失，但存在其他字体文件 %s" % (EXPECTED_FONT, found_font)))
        else:
            errors.append(err(EXPECTED_FONT, None,
                              "缺少字体文件：%s（fonts/ 下也没有任何字体）" % EXPECTED_FONT))
    return errors, warnings, infos


# ----------------------------------------------------------------------------
# [2d] project.godot 主场景指向
# ----------------------------------------------------------------------------
def check_main_scene(target, mode, ctx):
    errors, warnings, infos = [], [], []
    pg = os.path.join(target, "project.godot")
    if not os.path.isfile(pg):
        if mode == "snapshot":
            warnings.append(warn("project.godot", None,
                                 "快照无 project.godot，[2d] 无法在快照内验证 run/main_scene"
                                 "（回滚到主工程后由主工程配置承担，主工程已单独通过本项）"))
            return errors, warnings, infos
        errors.append(err("project.godot", None,
                          "project.godot 不存在，无法验证 run/main_scene"))
        return errors, warnings, infos
    with open(pg, "r", encoding="utf-8-sig", errors="replace") as f:
        text = f.read()
    m = re.search(r'run/main_scene\s*=\s*"res://([^"]+)"', text)
    if not m:
        errors.append(err("project.godot", None,
                          "project.godot 未配置 run/main_scene（启动时无入口场景）"))
        return errors, warnings, infos
    scene_res = m.group(1)
    scene_path = os.path.join(target, scene_res.replace("/", os.sep))
    if not os.path.isfile(scene_path):
        errors.append(err("project.godot", None,
                          "run/main_scene 指向不存在的场景：res://%s" % scene_res))
    else:
        infos.append("run/main_scene = res://%s → 文件存在" % scene_res)
    return errors, warnings, infos


# ----------------------------------------------------------------------------
# [2e] main.tscn ext_resource 存在性
# ----------------------------------------------------------------------------
EXT_RES_RE = re.compile(r"\[ext_resource[^\]]*\]")
EXT_PATH_RE = re.compile(r'path="res://([^"]+)"')


def check_scene_resources(target, mode, ctx):
    errors, warnings, infos = [], [], []
    scene = os.path.join(target, EXPECTED_SCENE)
    if not os.path.isfile(scene):
        errors.append(err(EXPECTED_SCENE, None,
                          "main.tscn 不存在，无法校验 ext_resource"))
        return errors, warnings, infos
    with open(scene, "r", encoding="utf-8-sig", errors="replace") as f:
        text = f.read()
    paths = []
    for m in EXT_RES_RE.finditer(text):
        pm = EXT_PATH_RE.search(m.group(0))
        if pm:
            paths.append(pm.group(1))
    if not paths:
        errors.append(err(EXPECTED_SCENE, None,
                          "main.tscn 未引用任何 ext_resource（场景未挂载脚本/资源，无法启动游戏逻辑）"))
        return errors, warnings, infos
    missing = [p for p in paths
               if not os.path.isfile(os.path.join(target, p.replace("/", os.sep)))]
    for p in missing:
        errors.append(err(EXPECTED_SCENE, None,
                          "ext_resource 指向不存在的文件：res://%s" % p))
    if not missing:
        infos.append("ext_resource 共 %d 项，全部存在：%s" % (len(paths), ", ".join(paths)))
    return errors, warnings, infos


# ----------------------------------------------------------------------------
# [2f] 存档对称性快速复核（独立实现）
# ----------------------------------------------------------------------------
def strip_comments_keep_strings(text):
    """去掉注释（字符串内的 # 不是注释），保留字符串内容（存档键在其中）"""
    out = []
    for raw in text.splitlines():
        buf = []
        i, n = 0, len(raw)
        in_str = None
        while i < n:
            c = raw[i]
            if in_str:
                buf.append(c)
                if c == "\\" and i + 1 < n:
                    buf.append(raw[i + 1])
                    i += 2
                    continue
                if c == in_str:
                    in_str = None
                i += 1
            elif c in ('"', "'"):
                in_str = c
                buf.append(c)
                i += 1
            elif c == "#":
                break
            else:
                buf.append(c)
                i += 1
        out.append("".join(buf))
    return "\n".join(out)


def extract_func(text_lines, name):
    """提取顶层 func <name> 的整个函数体（含函数头），返回 [(行号, 行文本)]。
    以"列 0 的下一个 func"作为函数体终点（本项目函数均在顶层）。"""
    body = []
    in_fn = False
    head_re = re.compile(r"^func\s+%s\s*\(" % re.escape(name))
    any_func_re = re.compile(r"^func\s+\w")
    for no, raw in text_lines:
        stripped = raw.strip()
        if not in_fn:
            if head_re.match(stripped) and not raw[:1].isspace():
                in_fn = True
                body.append((no, raw))
            continue
        if any_func_re.match(stripped) and not raw[:1].isspace():
            break
        body.append((no, raw))
    return body


def find_matching_brace(text, open_idx):
    """text[open_idx] 必须是 '{'，返回配对 '}' 下标；找不到返回 -1（字符串安全）"""
    depth = 0
    in_str = None
    i, n = open_idx, len(text)
    while i < n:
        c = text[i]
        if in_str:
            if c == "\\":
                i += 2
                continue
            if c == in_str:
                in_str = None
        elif c in ('"', "'"):
            in_str = c
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return -1


def dict_literal_keys(text, open_idx):
    """提取 text[open_idx] 起（'{' 开始）字典字面量的顶层字符串键集合"""
    close = find_matching_brace(text, open_idx)
    if close < 0:
        return set()  # 括号不配平由 [2b] 报告
    seg = text[open_idx + 1: close]
    keys = set()
    depth = 0
    in_str = None
    j, n = 0, len(seg)
    while j < n:
        c = seg[j]
        if in_str:
            if c == "\\":
                j += 2
                continue
            if c == in_str:
                in_str = None
        elif c in ('"', "'"):
            in_str = c
        elif c in BRACKETS_OPEN:
            depth += 1
        elif c in BRACKETS_CLOSE:
            depth -= 1
        elif c == ":" and depth == 0:
            m = re.search(r'"(\w+)"\s*$', seg[:j])
            if m:
                keys.add(m.group(1))
        j += 1
    return keys


def check_save_symmetry(target, mode, ctx):
    errors, warnings, infos = [], [], []
    # 迭代6 拆分：存档读写实现移至 save_manager.gd（main.gd 仅保留 facade）
    p = os.path.join(target, "scripts", "save_manager.gd")
    if not os.path.isfile(p):
        errors.append(err("scripts/save_manager.gd", None,
                          "save_manager.gd 不存在，无法做存档对称性复核"))
        return errors, warnings, infos
    with open(p, "r", encoding="utf-8-sig", errors="replace") as f:
        text = strip_comments_keep_strings(f.read())
    lines = list(enumerate(text.splitlines(), 1))

    save_text = "\n".join(t for _, t in extract_func(lines, "save_game"))
    read_funcs = extract_func(lines, "load_game") + extract_func(lines, "get_save_list")
    read_text = "\n".join(t for _, t in read_funcs)
    if not save_text.strip():
        errors.append(err("scripts/save_manager.gd", None, "未找到 save_game 函数定义"))
    if not read_text.strip():
        errors.append(err("scripts/save_manager.gd", None, "未找到 load_game / get_save_list 函数定义"))
    if not save_text.strip() or not read_text.strip():
        return errors, warnings, infos

    # ---- 写入键 ----
    writes = {}
    m = re.search(r"(?<![\w.])data\s*:?=\s*\{", save_text)
    if m:
        writes["顶层"] = dict_literal_keys(save_text, m.end() - 1)
    else:
        writes["顶层"] = set()
    for m in re.finditer(r"\b(\w+_list)\s*\.\s*append\s*\(\s*\{", save_text):
        keys = dict_literal_keys(save_text, m.end() - 1)
        lname = m.group(1)
        grp = ("buildings" if "building" in lname
               else "villagers" if "villager" in lname else lname)
        writes.setdefault(grp, set()).update(keys)

    # ---- 读取键 ----
    reads = {"顶层": set()}
    top_pats = [
        r'(?<![\w.])data\s*\.\s*get\(\s*"(\w+)"',
        r'(?<![\w.])data\s*\[\s*"(\w+)"\s*\]',
        r'(?<![\w.])parsed\s*\.\s*get\(\s*"(\w+)"',
    ]
    for pat in top_pats:
        for m in re.finditer(pat, read_text):
            reads["顶层"].add(m.group(1))
    # 条目读取：load_game 中 "for <var> in <...>_entries:" 的循环变量
    for m in re.finditer(r"\bfor\s+(\w+)\s+in\s+(\w+)\s*:", read_text):
        var, entries = m.group(1), m.group(2)
        if not entries.endswith("_entries"):
            continue
        grp = ("buildings" if "building" in entries
               else "villagers" if "villager" in entries else None)
        if grp is None:
            continue
        reads.setdefault(grp, set())
        for pat in (r'\b%s\s*\.\s*get\(\s*"(\w+)"' % re.escape(var),
                    r'\b%s\s*\[\s*"(\w+)"\s*\]' % re.escape(var)):
            for mm in re.finditer(pat, read_text):
                reads[grp].add(mm.group(1))

    # ---- 对账：每组键数>0 且差集为空 ----
    groups = sorted(set(writes) | set(reads))
    for g in groups:
        w = writes.get(g, set())
        r = reads.get(g, set())
        if len(w) == 0 or len(r) == 0:
            errors.append(err("scripts/save_manager.gd", None,
                              "存档对称性：「%s」键数不足（写入 %d 个 / 读取 %d 个，要求两侧均 >0）"
                              % (g, len(w), len(r))))
            continue
        only_w = sorted(w - r)
        only_r = sorted(r - w)
        if only_w:
            errors.append(err("scripts/save_manager.gd", None,
                              "存档对称性：「%s」有写入但从未读取的键：%s" % (g, ", ".join(only_w))))
        if only_r:
            errors.append(err("scripts/save_manager.gd", None,
                              "存档对称性：「%s」有读取但从未写入的键：%s" % (g, ", ".join(only_r))))
        if not only_w and not only_r:
            infos.append("「%s」：%d 个键写入/读取两侧完全一致（%s）"
                         % (g, len(w), ", ".join(sorted(w))))
    infos.append("复核范围：save_game 写入 vs load_game + get_save_list 读取；"
                 "stock 以动态键 str(Type) 同构读写，不在静态键对账范围")
    return errors, warnings, infos


# ----------------------------------------------------------------------------
# [2g] 目录干净性
# ----------------------------------------------------------------------------
def check_cleanliness(target, mode, ctx):
    errors, warnings, infos = [], [], []
    d = os.path.join(target, "scripts")
    if not os.path.isdir(d):
        errors.append(err("scripts/", None, "scripts/ 目录不存在，无法检查干净性"))
        return errors, warnings, infos
    found = []
    for name in sorted(os.listdir(d)):
        low = name.lower()
        if any(fnmatch.fnmatch(low, pat) for pat in TEMP_FILE_PATTERNS):
            found.append(name)
    for name in found:
        errors.append(err("scripts/" + name, None,
                          "scripts/ 存在临时/备份文件：%s（提交前应删除）" % name))
    if not found:
        infos.append("scripts/ 无 %s 临时/备份文件（共 %d 项）"
                     % (" / ".join(TEMP_FILE_PATTERNS), len(os.listdir(d))))
    return errors, warnings, infos


# ----------------------------------------------------------------------------
# [1] static_check 子进程
# ----------------------------------------------------------------------------
def check_static(target, mode, ctx):
    errors, warnings, infos = [], [], []
    scripts_dir = os.path.join(target, "scripts")
    if not os.path.isdir(scripts_dir):
        return [err("scripts/", None, "scripts/ 目录不存在，static_check 无法运行")], [], []

    tmpdir = None
    try:
        own_tool = os.path.join(target, "tools", STATIC_CHECK)
        if mode == "project" and os.path.isfile(own_tool):
            workdir, script = target, own_tool
            run_kind = "主工程原位运行（同时刷新 tools/static_check_report.txt）"
        else:
            src = own_tool if os.path.isfile(own_tool) \
                else os.path.join(MAIN_PROJECT, "tools", STATIC_CHECK)
            if not os.path.isfile(src):
                return [err("tools/static_check.py", None,
                            "找不到 static_check.py（目标目录与主工程均无），门禁项 [1] 无法运行")], [], []
            tmpdir = tempfile.mkdtemp(prefix="kb_gate_")
            os.makedirs(os.path.join(tmpdir, "tools"))
            shutil.copy2(src, os.path.join(tmpdir, "tools", STATIC_CHECK))
            shutil.copytree(scripts_dir, os.path.join(tmpdir, "scripts"))
            tests_dir = os.path.join(target, "tests")
            if os.path.isdir(tests_dir):
                shutil.copytree(tests_dir, os.path.join(tmpdir, "tests"))
            workdir = tmpdir
            script = os.path.join(tmpdir, "tools", STATIC_CHECK)
            run_kind = "临时工程副本运行（目标 tools/static_check.py，不动快照内容）"

        env = dict(os.environ)
        env["PYTHONUTF8"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        try:
            proc = subprocess.run(
                [sys.executable, script],
                capture_output=True, text=True, encoding="utf-8",
                errors="replace", timeout=300, cwd=workdir, env=env)
        except subprocess.TimeoutExpired:
            return [err("tools/static_check.py", None,
                        "static_check 子进程超时（>300s），保守判 NO-GO")], [], []

        out = proc.stdout or ""
        if proc.returncode != 0:
            tail = ((proc.stderr or "")).strip()[-800:]
            errors.append(err("tools/static_check.py", None,
                              "static_check 子进程异常退出（returncode=%d）%s"
                              % (proc.returncode, ("：%s" % tail) if tail else "")))

        n_err = n_warn = None
        m = re.search(r"总结：全部分节\s*ERROR=(\d+)\s*/\s*WARN=(\d+)", out)
        if m:
            n_err, n_warn = int(m.group(1)), int(m.group(2))

        listed = {"ERROR": [], "WARN": []}
        for line in out.splitlines():
            lm = re.match(r"^\s*\[(ERROR|WARN)\]\s*(.*)$", line)
            if not lm:
                continue
            level, rest = lm.group(1), lm.group(2).strip()
            fm = re.match(r"^([\w.\\/-]+):(\d+)\s+(.*)$", rest)
            if fm:
                item = {"level": level, "file": fm.group(1),
                        "line": int(fm.group(2)), "message": fm.group(3)}
            else:
                item = {"level": level, "file": None, "line": None, "message": rest}
            listed[level].append(item)

        if n_err is None:
            n_err, n_warn = len(listed["ERROR"]), len(listed["WARN"])
            infos.append("输出中未找到「总结」行，按逐条明细统计：ERROR=%d / WARN=%d" % (n_err, n_warn))
        if len(listed["ERROR"]) < n_err:
            errors.append(err("tools/static_check.py", None,
                              "static_check 总结 ERROR=%d，但仅解析到 %d 条 [ERROR] 明细"
                              "（存在无法解析的输出格式），保守判 NO-GO"
                              % (n_err, len(listed["ERROR"]))))
        errors.extend(listed["ERROR"])
        warnings.extend(listed["WARN"])
        infos.append("运行方式：%s" % run_kind)
        infos.append("总结：ERROR=%d / WARN=%d；判定规则：任何 ERROR → NO-GO，WARN 仅列出"
                     % (n_err, n_warn))
    finally:
        if tmpdir:
            shutil.rmtree(tmpdir, ignore_errors=True)
    return errors, warnings, infos


# ----------------------------------------------------------------------------
# 门禁编排
# ----------------------------------------------------------------------------
# ----------------------------------------------------------------------------
# [3] Godot 实机测试套件（tools/godot_portable/ 存在时才跑）
# ----------------------------------------------------------------------------
GODOT_TEST_SCRIPTS = [
    ("smoke_test", "tests/smoke_test.gd"),
    ("menu_test", "tests/menu_test.gd"),
    ("play_test(真实开局模拟)", "tests/play_test.gd"),
    ("logic_test", "tests/logic_test.gd"),
]


def check_godot_tests(target, mode, ctx):
    errors, warnings, infos = [], [], []
    if mode != "project":
        warnings.append(warn("tools/godot_portable", None,
                             "快照模式跳过 Godot 实机测试（只对主工程运行）"))
        return errors, warnings, infos
    # 便携版 Godot 按平台探测：Windows 用 .exe，Linux 用 .x86_64（两者同版本，二选一即可）
    portable = os.path.join(MAIN_PROJECT, "tools", "godot_portable")
    candidates = [
        os.path.join(portable, "Godot_v4.4.1-stable_win64.exe"),
        os.path.join(portable, "Godot_v4.4.1-stable_linux.x86_64"),
    ]
    exe = next((c for c in candidates if os.path.isfile(c)), "")
    if not exe:
        warnings.append(warn("tools/godot_portable", None,
                             "未找到便携版 Godot（%s），跳过实机测试；"
                             "下载后本项自动启用"
                             % " 或 ".join(os.path.basename(c) for c in candidates)))
        return errors, warnings, infos

    def run_godot(args, timeout):
        env = dict(os.environ)
        env["PYTHONUTF8"] = "1"
        try:
            proc = subprocess.run([exe] + args, capture_output=True, text=True,
                                  encoding="utf-8", errors="replace",
                                  timeout=timeout, cwd=MAIN_PROJECT, env=env)
            return proc.returncode, proc.stdout or "", proc.stderr or ""
        except subprocess.TimeoutExpired:
            return -1, "", "超时（>%ds）" % timeout

    code, out, errout = run_godot(["--headless", "--path", MAIN_PROJECT, "--import"], 600)
    bad = [l for l in (out + errout).splitlines()
           if "SCRIPT ERROR" in l or "Parse Error" in l or "Failed to load script" in l]
    if code != 0 or bad:
        errors.append(err("godot --import", None,
                          "--import 退出码=%d，解析错误 %d 条：%s"
                          % (code, len(bad), "; ".join(bad[:5]))))
    else:
        infos.append("godot --import 通过（全部脚本解析零错误）")

    for name, script in GODOT_TEST_SCRIPTS:
        code, out, errout = run_godot(
            ["--headless", "--path", MAIN_PROJECT, "--script", script], 300)
        joined = out + errout
        fails = [l.strip() for l in out.splitlines()
                 if "[FAIL]" in l or "SCRIPT ERROR" in l]
        if code != 0 or fails or "SCRIPT ERROR" in errout:
            detail = "; ".join(fails[:5]) if fails else (errout.strip()[-300:] or "退出码=%d" % code)
            errors.append(err(script, None, "实机测试 %s 失败：%s" % (name, detail)))
        else:
            m = re.search(r"断言统计：PASS=(\d+)\s+FAIL=(\d+)", out)
            summary = ("PASS=%s/FAIL=%s" % (m.group(1), m.group(2))) if m else "全部步骤通过"
            infos.append("实机测试 %s 通过（%s）" % (name, summary))
    return errors, warnings, infos


CHECKS = [
    ("1", "static_check 子进程（ERROR→NO-GO；WARN 仅列出）", check_static),
    ("2a", ".gd 块结构：空块/缩进断裂/缺冒号", check_blocks),
    ("2b", ".gd 括号/引号配平", check_balance),
    ("2c", "关键文件存在性", check_files),
    ("2d", "project.godot 主场景指向", check_main_scene),
    ("2e", "main.tscn ext_resource 存在性", check_scene_resources),
    ("2f", "存档对称性复核（键数>0 且差集为空）", check_save_symmetry),
    ("2g", "scripts/ 目录干净性", check_cleanliness),
    ("3", "Godot 实机测试（--import + 4 套件）", check_godot_tests),
]

GATE_RULES = [
    "[1]  static_check 子进程 —— 任何 ERROR 级发现 → NO-GO；WARN 全部列出但不阻塞",
    "[2a] .gd 块结构（自写解析器）—— func/if/elif/else/for/while/match/class 块头必须有冒号且后随更深的体；空块/缩进断裂/缺冒号 → ERROR，同级块体缩进不一致 → WARN",
    "[2b] 括号/引号配平 —— 屏蔽字符串与注释后 (){}[] 必须配平；未闭合字符串（含三引号）→ ERROR",
    "[2c] 关键文件存在性 —— scripts 14 文件 + scenes/main.tscn + project.godot + 字体（快照缺 project.godot 按 SNAPSHOT.md 设计降级为 WARN）",
    "[2d] project.godot 的 run/main_scene 必须指向存在的场景文件",
    "[2e] main.tscn 全部 ext_resource path 必须存在；一个都没有 → ERROR",
    "[2f] 存档对称性 —— save_game 写入键 vs load_game/get_save_list 读取键（顶层/buildings/villagers 三组）：键数>0 且差集为空",
    "[2g] 目录干净性 —— scripts/ 下禁止 *.bak / *.tmp / *~ / *.orig",
]


def next_run_id():
    if not os.path.isfile(REPORT_FILE):
        return 1
    try:
        with open(REPORT_FILE, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
        ids = [int(x) for x in re.findall(r"^RUN #(\d+)\b", content, re.M)]
        return (max(ids) + 1) if ids else 1
    except OSError:
        return 1


def run_gate(target, mode):
    rep = {
        "tool": "tools/run_gate.py",
        "run_id": next_run_id(),
        "time": datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
        "python": sys.version.split()[0],
        "mode": mode,
        "target": target,
    }
    try:
        gd = scan_gd_files(target)
    except Exception as e:  # 门禁自身异常也必须 NO-GO，绝不静默放行
        gd = {"files": [], "read_errors": [
            err(None, None, "门禁 .gd 扫描器自身异常：%s: %s" % (type(e).__name__, e))]}
    checks = []
    for cid, name, fn in CHECKS:
        try:
            errors, warnings, infos = fn(target, mode, {"gd": gd, "target": target, "mode": mode})
        except Exception as e:
            errors, warnings, infos = [err(None, None,
                                           "门禁项 [%s] 自身异常（保守判 NO-GO）：%s: %s"
                                           % (cid, type(e).__name__, e))], [], []
        status = "FAIL" if errors else ("WARN" if warnings else "PASS")
        checks.append({
            "id": cid, "name": name, "status": status,
            "error_count": len(errors), "warn_count": len(warnings),
            "errors": errors, "warnings": warnings, "infos": infos,
        })
    rep["checks"] = checks
    rep["error_count"] = sum(c["error_count"] for c in checks)
    rep["warn_count"] = sum(c["warn_count"] for c in checks)
    rep["verdict"] = "GO" if rep["error_count"] == 0 else "NO-GO"
    rep["exit_code"] = 0 if rep["verdict"] == "GO" else 1
    return rep


def render_text(rep):
    bar = "=" * 78
    out = []
    out.append(bar)
    out.append("RUN #%d · KingdomBuilder 启动安全门禁（tools/run_gate.py）" % rep["run_id"])
    out.append("时间：%s | Python %s" % (rep["time"], rep["python"]))
    out.append("模式：%s | 目标：%s" % (rep["mode"], rep["target"]))
    out.append("-" * 78)
    out.append("门禁项与判定规则（任何 ERROR 级发现 → NO-GO；WARN 只列出、不阻塞）：")
    for line in GATE_RULES:
        out.append("  " + line)
    out.append("-" * 78)
    out.append("各项结果：")
    for c in rep["checks"]:
        mark = {"PASS": "PASS", "WARN": "PASS(有WARN)", "FAIL": "FAIL"}[c["status"]]
        out.append("  [%-3s] %-42s %s（ERROR=%d，WARN=%d）"
                   % (c["id"], c["name"], mark, c["error_count"], c["warn_count"]))
    out.append("-" * 78)
    out.append("详细发现：")
    had = False
    for c in rep["checks"]:
        block = []
        for m in c["errors"]:
            block.append("      [ERROR] %s  %s" % (loc(m), m["message"]))
        for m in c["warnings"]:
            block.append("      [WARN]  %s  %s" % (loc(m), m["message"]))
        for msg in c["infos"]:
            block.append("      INFO    %s" % msg)
        if block:
            had = True
            out.append("  [%s] %s" % (c["id"], c["name"]))
            out.extend(block)
    if not had:
        out.append("  （无）")
    out.append(bar)
    if rep["verdict"] == "GO":
        out.append("判定：GO（8 项门禁全部通过；WARN %d 条已列出，不阻塞）" % rep["warn_count"])
    else:
        failed = ", ".join(c["id"] for c in rep["checks"] if c["status"] == "FAIL")
        out.append("判定：NO-GO（未通过门禁项：[%s]；ERROR 共 %d 条，逐条见上）"
                   % (failed, rep["error_count"]))
    out.append(bar)
    return "\n".join(out)


def append_report(text):
    with open(REPORT_FILE, "a", encoding="utf-8") as f:
        f.write(text + "\n\n")


def main(argv=None):
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    ap = argparse.ArgumentParser(
        description="KingdomBuilder 一键启动安全门禁：聚合 static_check 与 7 项独立检查，输出 GO/NO-GO")
    ap.add_argument("--snapshot", metavar="目录",
                    help="对指定快照目录跑同一套检查（给目录名时自动在 _releases/ 下查找）")
    ap.add_argument("--json", action="store_true",
                    help="stdout 输出机器可读 JSON（tools/gate_report.txt 照常追加）")
    args = ap.parse_args(argv)

    if args.snapshot:
        cand = args.snapshot
        if not os.path.isdir(cand):
            alt = os.path.join(MAIN_PROJECT, "_releases", cand)
            if os.path.isdir(alt):
                cand = alt
        target = os.path.abspath(cand)
        if not os.path.isdir(target):
            print("错误：快照目录不存在：%s" % target, file=sys.stderr)
            return 2
        if not os.path.isdir(os.path.join(target, "scripts")):
            print("错误：快照目录缺少 scripts/ 子目录：%s" % target, file=sys.stderr)
            return 2
        mode = "snapshot"
    else:
        target = MAIN_PROJECT
        mode = "project"

    rep = run_gate(target, mode)
    text = render_text(rep)
    append_report(text)
    if args.json:
        print(json.dumps(rep, ensure_ascii=False, indent=2))
    else:
        print(text)
        print("报告已追加写入：%s" % REPORT_FILE)
    return rep["exit_code"]


if __name__ == "__main__":
    sys.exit(main())
