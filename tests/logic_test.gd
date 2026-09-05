extends SceneTree

## 逻辑单测（[1]-[4] 纯静态断言；迭代4追加 [5] A* 直跑与 [6] 一键招满，[6b] 需装配主场景）
## 运行方式（本机装好 Godot 后执行；当前环境无 Godot，先用 tools/static_check.py 做 [F] 语法粗检）：
##   godot --headless --path <项目根> --script tests/logic_test.gd
## 依赖说明：[1]-[5] 只用 class_name 全局类；[6a] 经 preload 读 main.gd 的 const；
##   [6b] 仿 tests/smoke_test.gd 实例化 scenes/main.tscn（只 new_game 取干净状态，
##   不读不写任何存档），场景装配失败时该组按 FAIL 记账、不影响其余各组结果。
## 覆盖点：
##   [1] building_catalog：全部 produces 建筑净产出为正（有产出、interval>0、
##       同资源"入<出"，转换链不得凭空销毁资源）。
##   [2] 原料链上游产能≥下游需求：每个被消耗的资源在目录中必须有上游生产者（硬断言），
##       并用一组参照配队（农场/磨坊/面包房/牧羊场/纺织坊/酿酒坊）逐资源断言净速率≥0；
##       打印"1 个下游需要几个上游"配比表（含 2 农场不够喂磨坊+酿酒坊的反例）。
##   [3] 存档对称性（正则静态提取 save_manager.gd 源码；迭代6 拆分前在 main.gd）：
##       save_game 写入键 vs load_game/get_save_list 读取键，
##       顶层/buildings条目/villagers条目 三组双向断言。
##   [4] 幸福度档位期望范围推演（main.gd:260-337 公式复刻）：打印典型场景期望值并断言，
##       推导生产加速阈（幸福≥70）在各时代的可达条件。
##   [5] A* 路径等价性（GridManager 纯函数无头直跑、不进场景树；只断言代价与不变量，
##       不断言具体格子序列）：开阔最短路 size/端点；x=3 整列 WATER 仅 (3,6) 可走的
##       绕障代价 + 逐格相邻（曼哈顿距离1）+ 全部 is_walkable；目标四面临水 → []；
##       from==to → [to]；城门 is_walkable 双语义（村民可走/敌军不可走），
##       且村民 find_path 可穿城门、for_enemy 不可穿。
##   [6] 一键招满优先级：6a 静态护栏 —— BuildingCatalog.ALL 中 workers>0 且非
##       trains_guards 的建筑 id 必须全部登记在 main.ASSIGN_PRIORITY（preload 读 const）；
##       6b 场景断言 —— 裁到 2 名空闲村民 + gatherer/mill/bakery 各 1 座（开阔草地、
##       四周可走），assign_all_workers() 后断言 gatherer=1、mill=1、bakery=0
##       （2 名空闲村民按优先级先喂饱 gatherer/mill，bakery 轮空）；兵营跳过不断言。

const MAIN_GD := "res://scripts/save_manager.gd"  # 迭代6 拆分：存档读写实现移至 save_manager.gd
const MAIN_SCRIPT := preload("res://scripts/main.gd")  # main.gd 无 class_name：const 经 preload 直接读

var _pass := 0
var _fail := 0


func _initialize() -> void:
	print("=== LOGIC TEST START ===")
	_test_catalog_net_output()
	_test_chain_capacity()
	_test_save_key_symmetry()
	_test_happiness_ladder()
	_test_astar_paths()
	await _test_assign_priority()  # 6b 内部要 await 场景帧，必须 await 完再统计/退出
	_test_events_and_groups()
	print("=== 断言统计：PASS=%d FAIL=%d ===" % [_pass, _fail])
	if _fail == 0:
		print("=== LOGIC TEST END (ALL PASS) ===")
	else:
		print("=== LOGIC TEST END (FAILED) ===")
	quit(1 if _fail > 0 else 0)


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  [PASS] ", msg)
	else:
		_fail += 1
		print("  [FAIL] ", msg)


# ----------------------------------------------------------------------------
# [1] 目录净产出
# ----------------------------------------------------------------------------
func _test_catalog_net_output() -> void:
	print("[1] building_catalog：produces 建筑净产出为正")
	var producers := 0
	for entry in BuildingCatalog.ALL:
		if not bool(entry.get("produces", false)):
			continue
		producers += 1
		var bid := String(entry["id"])
		var outputs: Array = entry.get("outputs", [])
		# 植树场这类"地块改造"建筑产出的是地形而非资源，允许 outputs 为空
		var terrain_worker: bool = entry.has("plants") or entry.has("depletes")
		_check(outputs.size() > 0 or terrain_worker, "%s：outputs 非空（或为地块改造建筑）" % bid)
		_check(float(entry.get("interval", 0.0)) > 0.0, "%s：interval > 0" % bid)
		var inputs: Array = entry.get("inputs", [])
		for out in outputs:
			var out_t: int = out[0]
			var out_n: int = out[1]
			_check(out_n > 0, "%s：产出数量 > 0" % bid)
			for inp in inputs:
				var in_t: int = inp[0]
				var in_n: int = inp[1]
				if in_t == out_t:
					# 同资源转换必须"出多于入"才算净产出为正（磨坊 2麦→2粉 资源不同，放行）
					_check(out_n > in_n, "%s：同资源 %d 净增（入 %d → 出 %d）" % [bid, out_t, in_n, out_n])
	print("  小计：produces 建筑共 %d 个" % producers)
	# 村民进食的经济前提（villager.gd:21-24）：面包回 100 > 生食回 50，面包链因此有价值
	_check(Villager.BREAD_RESTORE > Villager.FOOD_RESTORE,
		"面包回复(%.0f) > 生食回复(%.0f)（villager.gd:23-24）"
		% [Villager.BREAD_RESTORE, Villager.FOOD_RESTORE])
	# 饥饿模型自洽：100/240 每秒 × 240s = 100（约 4 分钟饿满，villager.gd:21）
	_check(absf(Villager.HUNGER_RATE * 240.0 - 100.0) < 0.001,
		"HUNGER_RATE×240 = 100（约 4 分钟饿满）")
	# 工作窗自洽（time_manager.gd:14-15,44-45）：60s/天 × (0.85-0.15) = 42s
	_check(absf((0.85 - 0.15) * 60.0 - 42.0) < 0.001,
		"is_night 0.15~0.85 → 每天工作窗 42s")


# ----------------------------------------------------------------------------
# [2] 原料链上游产能 ≥ 下游需求
# ----------------------------------------------------------------------------
func _prod_rate(bid: String, res: int) -> float:
	var entry := BuildingCatalog.find_by_id(StringName(bid))
	var total := 0.0
	for out in entry.get("outputs", []):
		if int(out[0]) == res:
			total += float(out[1])
	return total / float(entry.get("interval", 1.0))


func _cons_rate(bid: String, res: int) -> float:
	var entry := BuildingCatalog.find_by_id(StringName(bid))
	var total := 0.0
	for inp in entry.get("inputs", []):
		if int(inp[0]) == res:
			total += float(inp[1])
	return total / float(entry.get("interval", 1.0))


func _fleet_net(fleet: Dictionary, res: int) -> float:
	var net := 0.0
	for bid in fleet:
		var n := float(fleet[bid])
		net += n * _prod_rate(bid, res) - n * _cons_rate(bid, res)
	return net


func _test_chain_capacity() -> void:
	print("[2] 原料链：上游产能 ≥ 下游需求（满员在岗口径，building.gd:80）")
	# ---- 2a. 每个被消耗的资源都必须存在上游生产者（防止孤儿原料 = 设计性软锁）----
	var consumed := {}
	var produced := {}
	for entry in BuildingCatalog.ALL:
		var bid := String(entry["id"])
		for inp in entry.get("inputs", []):
			consumed[int(inp[0])] = true
		for out in entry.get("outputs", []):
			produced[int(out[0])] = true
	for res in consumed:
		_check(produced.has(res), "资源 %d 有目录内上游生产者" % res)
	# ---- 2b. 配比表：1 个下游建筑需要几个最优上游（含食物链与衣服链）----
	print("  配比表（下游需求速率 / 最优上游生产速率，向上取整）：")
	for entry in BuildingCatalog.ALL:
		if not bool(entry.get("produces", false)):
			continue
		var did := String(entry["id"])
		for inp in entry.get("inputs", []):
			var res: int = inp[0]
			var need := _cons_rate(did, res)
			var best_bid := ""
			var best_rate := 0.0
			for entry2 in BuildingCatalog.ALL:
				if not bool(entry2.get("produces", false)):
					continue
				var r := _prod_rate(String(entry2["id"]), res)
				if r > best_rate:
					best_rate = r
					best_bid = String(entry2["id"])
			if best_rate <= 0.0:
				continue
			var need_cnt := int(ceil(need / best_rate))
			print("    %s ← %s ×%d（需 %.3f/s，单 %s 供 %.3f/s）"
				% [did, best_bid, need_cnt, need, best_bid, best_rate])
			_check(need_cnt <= 10, "%s 的上游配比可行（×%d）" % [did, need_cnt])
	# ---- 2c. 参照配队净速率 ≥ 0（上游产能≥下游需求的整体断言）----
	# 3 农场 + 1 磨坊 + 1 面包房 + 1 酿酒坊 + 2 牧羊场 + 1 纺织坊
	var fleet := {"farm": 3, "mill": 1, "bakery": 1, "brewery": 1,
		"pasture": 2, "weaver": 1}
	_check(_fleet_net(fleet, ResourceManager.Type.WHEAT) >= -0.0001,
		"参照配队小麦净速率 ≥ 0（%.3f/s）" % _fleet_net(fleet, ResourceManager.Type.WHEAT))
	_check(_fleet_net(fleet, ResourceManager.Type.FLOUR) >= -0.0001,
		"参照配队面粉净速率 ≥ 0（%.3f/s）" % _fleet_net(fleet, ResourceManager.Type.FLOUR))
	_check(_fleet_net(fleet, ResourceManager.Type.WOOL) >= -0.0001,
		"参照配队羊毛净速率 ≥ 0（%.3f/s）" % _fleet_net(fleet, ResourceManager.Type.WOOL))
	_check(_fleet_net(fleet, ResourceManager.Type.BREAD) > 0.0,
		"参照配队面包净产出 > 0（%.3f/s）" % _fleet_net(fleet, ResourceManager.Type.BREAD))
	_check(_fleet_net(fleet, ResourceManager.Type.CLOTHES) > 0.0,
		"参照配队衣服净产出 > 0（%.3f/s）" % _fleet_net(fleet, ResourceManager.Type.CLOTHES))
	# 反例（只打印不判失败）：2 农场喂 1 磨坊 + 1 酿酒坊是亏空，需 3 农场
	var fleet2 := {"farm": 2, "mill": 1, "brewery": 1}
	print("  反例：2 农场+1 磨坊+1 酿酒坊 小麦净速率 %.3f/s（<0 → 至少 3 农场）"
		% _fleet_net(fleet2, ResourceManager.Type.WHEAT))
	# 冬季注意：农场/采集 no_winter（catalog:40,54），面包链冬季靠小麦/面粉/面包库存
	print("  INFO：farm/gatherer no_winter=true（catalog:40,54）→ 冬季面包链靠库存小麦/面粉续命")


# ----------------------------------------------------------------------------
# [3] 存档键对称性（正则静态提取，与 tools/static_check.py [D] 同思路独立复刻）
# ----------------------------------------------------------------------------
func _extract_func(text: String, fname: String) -> String:
	var lines := text.split("\n")
	var body := ""
	var in_fn := false
	for line in lines:
		if not in_fn:
			if line.begins_with("func %s(" % fname):
				in_fn = true
			continue
		if line.begins_with("func "):
			break
		body += line + "\n"
	return body


func _slice_between(body: String, start_marker: String, end_marker: String) -> String:
	var i := body.find(start_marker)
	if i < 0:
		return ""
	var j := body.find(end_marker, i)
	if j < 0:
		j = body.length()
	return body.substr(i, j - i)


func _regex_keys(src: String, pattern: String) -> Array:
	var re := RegEx.create_from_string(pattern)
	var keys := {}
	var m := re.search(src)
	while m != null:
		keys[m.get_string(1)] = true
		m = re.search(src, m.get_end())
	var arr := []
	for k in keys:
		arr.append(k)
	arr.sort()
	return arr


func _diff_desc(written: Array, read: Array) -> String:
	var only_w := []
	var only_r := []
	for k in written:
		if not read.has(k):
			only_w.append(k)
	for k in read:
		if not written.has(k):
			only_r.append(k)
	return "写入未读:%s 读取未写:%s" % [str(only_w), str(only_r)]


func _sets_equal(w: Array, r: Array) -> bool:
	if w.size() != r.size():
		return false
	for k in w:
		if not r.has(k):
			return false
	return true


func _test_save_key_symmetry() -> void:
	print("[3] 存档对称性：save_manager.gd save_game 写入 vs load_game/get_save_list 读取")
	var text := FileAccess.get_file_as_string(MAIN_GD)
	_check(text.length() > 0, "能读取 save_manager.gd 源码（%d 字符）" % text.length())
	var save_body := _extract_func(text, "save_game")
	var load_body := _extract_func(text, "load_game")
	var list_body := _extract_func(text, "get_save_list")
	# ---- 防静默假绿守卫：函数体提取不到内容时，下方键集对比会"空对空"假绿，先硬断言 ----
	_check(not save_body.is_empty() and not load_body.is_empty() and not list_body.is_empty(),
		"save_game/load_game/get_save_list 三个函数体均提取到内容（防静默假绿）")
	# ---- 写入侧：三个字典字面量（save_manager.gd:33-83；building_list 33-40 / villager_list 44-57 / data 61-83）----
	var w_top := _regex_keys(_slice_between(save_body, "var data := {", "var path :="),
		"\"(\\w+)\"\\s*:")
	var w_b := _regex_keys(_slice_between(save_body, "building_list.append({", "})"),
		"\"(\\w+)\"\\s*:")
	var w_v := _regex_keys(_slice_between(save_body, "villager_list.append({", "})"),
		"\"(\\w+)\"\\s*:")
	# ---- 读取侧：data.get / parsed.get（顶层）、bd.get（建筑条目）、vd.get（村民条目）----
	# 负向后顾排除 wb.data/hb.data 这类"建筑配置读取"（它们不是存档键）
	var r_top := _regex_keys(load_body + list_body, "(?<![\\w.])data\\.get\\(\"(\\w+)\"")
	var r_top2 := _regex_keys(list_body, "\\bparsed\\.get\\(\"(\\w+)\"")
	for k in r_top2:
		if not r_top.has(k):
			r_top.append(k)
	r_top.sort()
	var r_b := _regex_keys(load_body, "\\bbd\\.get\\(\"(\\w+)\"")
	var r_v := _regex_keys(load_body, "\\bvd\\.get\\(\"(\\w+)\"")
	print("  顶层 写%d/读%d  buildings条目 写%d/读%d  villagers条目 写%d/读%d"
		% [w_top.size(), r_top.size(), w_b.size(), r_b.size(), w_v.size(), r_v.size()])
	# ---- 键数下限断言：防止两侧键集同次静默缩水（对称但为空/残缺仍会假绿） ----
	_check(w_top.size() >= 20 and r_top.size() >= 20,
		"顶层键数下限 ≥20（写 %d / 读 %d）" % [w_top.size(), r_top.size()])
	_check(w_b.size() >= 5 and r_b.size() >= 5,
		"buildings 条目键数下限 ≥5（写 %d / 读 %d）" % [w_b.size(), r_b.size()])
	_check(w_v.size() >= 10 and r_v.size() >= 10,
		"villagers 条目键数下限 ≥10（写 %d / 读 %d）" % [w_v.size(), r_v.size()])
	_check(_sets_equal(w_top, r_top), "顶层键两侧一致（%s）" % _diff_desc(w_top, r_top))
	_check(_sets_equal(w_b, r_b), "buildings 条目键两侧一致（%s）" % _diff_desc(w_b, r_b))
	_check(_sets_equal(w_v, r_v), "villagers 条目键两侧一致（%s）" % _diff_desc(w_v, r_v))
	print("  INFO stock：写入 str(Type) / 读取 stock_data.get(str(t),0)，动态键同构")


# ----------------------------------------------------------------------------
# [4] 幸福度档位期望范围推演（main.gd:260-337 公式复刻）
# ----------------------------------------------------------------------------
func _h(era: int, homed: bool, bread: bool, hungry: bool, well: bool, clothed: bool,
		faith: bool, fun: bool, castle: bool, mood: int) -> float:
	var h := 50.0                        # main.gd:311 基础 50
	h += 10.0 if homed else -30.0        # main.gd:312-315 住房 +10 / 无房 -30
	if bread:
		h += 10.0                        # main.gd:316-317 昨日吃面包 +10
	if hungry:
		h -= 20.0                        # main.gd:318-319 挨饿(hunger>60) -20
	if well:
		h += 5.0                         # main.gd:320-321 水井光环 +5
	if era >= 2:
		h += 10.0 if clothed else -10.0  # main.gd:322-323 时代Ⅱ 衣服 ±10
	if era >= 3:
		h += 10.0 if faith else -5.0     # main.gd:329 信仰 +10/-5
		h += 10.0 if fun else -5.0       # main.gd:330 娱乐 +10/-5
	if castle:
		h += 10.0                        # main.gd:274-275,331 城堡全局 +10
	h += mood                            # main.gd:332-333 袭击士气（胜+5/被抢-10封顶-20）
	return clampf(h, 0.0, 100.0)         # main.gd:334 clamp 0~100


func _test_happiness_ladder() -> void:
	print("[4] 幸福度档位推演（公式 main.gd:260-337；括号内为求值过程）")
	var s1 := _h(1, true, true, false, false, false, false, false, false, 0)
	var s2 := _h(1, true, false, false, false, false, false, false, false, 0)
	var s3 := _h(1, false, false, false, false, false, false, false, false, 0)
	var s4 := _h(1, true, false, true, false, false, false, false, false, 0)
	var s4b := _h(1, true, true, true, false, false, false, false, false, 0)
	var s5 := _h(2, true, true, false, false, true, false, false, false, 0)
	var s6 := _h(2, true, true, false, false, false, false, false, false, 0)
	var s7 := _h(3, true, true, false, true, true, true, true, false, 0)
	var s8 := _h(3, true, true, false, false, true, false, false, false, 0)
	var s9 := _h(3, false, true, true, false, false, false, false, false, 0)
	var s10 := _h(2, true, true, false, false, true, false, false, false, -20)
	var s11 := _h(2, true, true, false, false, true, false, false, false, 5)
	print("  时代Ⅰ 有房+面包          = %5.1f（50+10+10）" % s1)
	print("  时代Ⅰ 有房 无面包        = %5.1f（50+10）开局建房保底档" % s2)
	print("  时代Ⅰ 无房               = %5.1f（50-30）首日不建房 → <40 次日离队" % s3)
	print("  时代Ⅰ 有房 挨饿          = %5.1f（50+10-20）离队线上方一档" % s4)
	print("  时代Ⅰ 有房+面包 挨饿     = %5.1f（50+10+10-20）" % s4b)
	print("  时代Ⅱ 有房+面包+衣       = %5.1f（50+10+10+10）生产×1.2 达标档" % s5)
	print("  时代Ⅱ 有房+面包 无衣     = %5.1f（50+10+10-10）" % s6)
	print("  时代Ⅲ 全覆盖（井衣信仰娱乐）= %5.1f（50+10+10+5+10+10+10=105→clamp 100）" % s7)
	print("  时代Ⅲ 有衣 缺信仰娱乐    = %5.1f（50+10+10+10-5-5）恰达生产加速阈" % s8)
	print("  时代Ⅲ 无房+挨饿+全缺     = %5.1f（50-30+10-20-10-5-5=-10→clamp 0）最惨档" % s9)
	print("  时代Ⅱ 达标档 被抢(士气-20) = %5.1f（80-20）" % s10)
	print("  时代Ⅱ 达标档 击退(+5)    = %5.1f（80+5）" % s11)
	_check(s1 == 70.0, "时代Ⅰ 有房+面包 = 70")
	_check(s2 == 60.0, "时代Ⅰ 有房 无面包 = 60")
	_check(s3 == 20.0, "时代Ⅰ 无房 = 20（<40 触发每日离队）")
	_check(s4 == 40.0, "时代Ⅰ 有房+挨饿(无面包) = 40（离队线上方一档）")
	_check(s4b == 50.0, "时代Ⅰ 有房+面包+挨饿 = 50")
	_check(s5 == 80.0, "时代Ⅱ 衣服达标 = 80（≥70 生产×1.2）")
	_check(s6 == 60.0, "时代Ⅱ 无衣 = 60（加速阈以下）")
	_check(s7 == 100.0, "时代Ⅲ 全覆盖 = clamp(105)=100")
	_check(s8 == 70.0, "时代Ⅲ 缺信仰娱乐 = 70（恰好保住×1.2）")
	_check(s9 == 0.0, "时代Ⅲ 最惨 = clamp(-10)=0")
	_check(s10 == 60.0 and s11 == 85.0, "袭击士气 -20/+5 正确叠加")
	var ladder := [s9, s3, s10, s2, s6, s4, s4b, s1, s5, s11, s8, s7]
	var in_range := true
	for val in ladder:
		if val < 0.0 or val > 100.0:
			in_range = false
	_check(in_range, "全部档位落在 clamp [0,100] 内")
	print("  推演：生产加速阈（幸福≥70，building.gd:72）各时代可达条件 ——")
	print("    时代Ⅰ：有房+吃面包=70 恰达标；无面包时即使有水井也只有 65")
	print("    时代Ⅱ：必须穿衣服（无衣上限 65）；有衣 80 稳达标")
	print("    时代Ⅲ：有衣+缺信仰娱乐 = 70 恰达标；有井全覆盖 = clamp(105)=100")
	print("    被抢封顶 -20：80→60，会丢失×1.2 加成 2 天 → 袭击的间接经济伤害大于直接抢掠")


# ----------------------------------------------------------------------------
# [5] A* 路径等价性（GridManager 纯函数，无头直跑、不进场景树）
# ----------------------------------------------------------------------------
## 造一块 w×h 的确定性网格：GridManager.new() 不 add_child → _ready 不会随机
## generate_map；手工设好宽高后调一次 generate_map() 拿到正确尺寸的
## terrain/occupancy/roads，再整表覆盖成 GRASS，各用例再雕刻自己的地形。
func _make_grid(w: int, h: int) -> GridManager:
	var g := GridManager.new()
	g.width = w
	g.height = h
	g.generate_map()
	for i in w * h:
		g.terrain[i] = GridManager.TileType.GRASS
	return g


## 写单格地形（下标公式同 grid_manager.gd 的 _idx：x * height + y）
func _set_cell(g: GridManager, c: Vector2i, t: int) -> void:
	g.terrain[g._idx(c.x, c.y)] = t


func _test_astar_paths() -> void:
	print("[5] A* 路径等价性：只断言代价与不变量，不断言具体格子序列")
	# ---- 5a. 开阔地 (0,0)→(6,0)：全草 8×8，最短 6 步 7 格 ----
	var g1 := _make_grid(8, 8)
	var p1 := g1.find_path(Vector2i(0, 0), Vector2i(6, 0))
	_check(p1.size() == 7, "开阔 (0,0)→(6,0)：size()==7（曼哈顿最优代价）")
	_check(p1.size() > 0 and p1[0] == Vector2i(0, 0), "开阔：首格 = 起点")
	_check(p1.size() > 0 and p1[p1.size() - 1] == Vector2i(6, 0), "开阔：尾格 = 终点")
	# ---- 5b. from == to：立即返回 [to]（find_path 入口短路，grid_manager.gd:212）----
	var p4 := g1.find_path(Vector2i(2, 2), Vector2i(2, 2))
	_check(p4.size() == 1 and p4[0] == Vector2i(2, 2), "from==to：返回单格路径 [to]")
	# ---- 5c. 绕障：x=3 整列 WATER、仅 (3,6) 可走，(0,0)→(6,0) 必经缺口 ----
	var g2 := _make_grid(8, 8)
	for y in 8:
		_set_cell(g2, Vector2i(3, y), GridManager.TileType.WATER)
	_set_cell(g2, Vector2i(3, 6), GridManager.TileType.GRASS)
	_check(g2.is_walkable(Vector2i(3, 6)) and not g2.is_walkable(Vector2i(3, 3)),
		"绕障前置：水墙上仅 (3,6) 可走")
	var p2 := g2.find_path(Vector2i(0, 0), Vector2i(6, 0))
	# 代价下界：任何路径必踩 (3,6)，长 = dist((0,0),(3,6)) + dist((3,6),(6,0))
	#          = (3+6) + (3+6) = 18 步 = 19 格（A* 最优可达；注意格子数恒为奇数 7+2k）
	_check(p2.size() == 19, "绕障 (0,0)→(6,0)：size()==19（必经 (3,6)：2×(3+6)+1）")
	var adj_ok := true
	for i in maxi(p2.size() - 1, 0):  # maxi 兜底：路径为空时不产生负数迭代
		var d: Vector2i = p2[i + 1] - p2[i]
		if absi(d.x) + absi(d.y) != 1:
			adj_ok = false
	_check(adj_ok, "绕障路径逐格相邻（%d 段全部曼哈顿距离 1）" % (p2.size() - 1))
	var walk_ok := true
	for c in p2:
		if not g2.is_walkable(c):
			walk_ok = false
	_check(walk_ok, "绕障路径全部 is_walkable（%d 格）" % p2.size())
	_check(p2.has(Vector2i(3, 6)), "绕障路径经过唯一缺口 (3,6)")
	# ---- 5d. 不可达：目标四面临水 → 空路径 ----
	var g3 := _make_grid(8, 8)
	for c in [Vector2i(5, 6), Vector2i(7, 6), Vector2i(6, 5), Vector2i(6, 7)]:
		_set_cell(g3, c, GridManager.TileType.WATER)
	_check(g3.is_walkable(Vector2i(6, 6)), "不可达前置：目标 (6,6) 本身可走，仅四邻被围")
	var p3 := g3.find_path(Vector2i(0, 0), Vector2i(6, 6))
	_check(p3.is_empty(), "四面临水的目标返回 []")
	# ---- 5e. 城门双语义：村民可穿、敌军不可穿（is_gate，grid_manager.gd:104-113）----
	var g4 := _make_grid(8, 8)
	var res := ResourceManager.new()
	var tm := TimeManager.new()
	var wall := Building.new()
	wall.setup(BuildingCatalog.find_by_id(&"wall"), Vector2i(3, 0), res, tm)
	var gate := Building.new()
	gate.setup(BuildingCatalog.find_by_id(&"gate"), Vector2i(3, 4), res, tm)
	g4.occupy_area(Vector2i(3, 0), Vector2i(1, 4), wall)  # 城墙占 (3,0)~(3,3)
	g4.occupy_area(Vector2i(3, 5), Vector2i(1, 3), wall)  # 城墙占 (3,5)~(3,7)
	g4.occupy_area(Vector2i(3, 4), Vector2i.ONE, gate)    # 城门占 (3,4)
	_check(g4.is_walkable(Vector2i(3, 4), false), "城门格 is_walkable(c,false)==true（村民语义）")
	_check(not g4.is_walkable(Vector2i(3, 4), true), "城门格 is_walkable(c,true)==false（敌军语义）")
	_check(not g4.is_walkable(Vector2i(3, 0), false), "对照组：城墙格对村民同样不可走")
	var pv := g4.find_path(Vector2i(0, 4), Vector2i(6, 4))
	_check(pv.size() == 7, "村民 (0,4)→(6,4) 可穿城门（直线 7 格）")
	_check(pv.has(Vector2i(3, 4)), "村民路径经过城门格 (3,4)")
	var pe := g4.find_path(Vector2i(0, 4), Vector2i(6, 4), true)
	_check(pe.is_empty(), "敌军 (0,4)→(6,4) 不可穿（城墙+城门全封锁 → []）")
	# 孤儿 Node 手工 free（从未进树，quit() 兜不住，否则退出时报 ObjectDB 泄漏）
	g1.free()
	g2.free()
	g3.free()
	g4.free()
	wall.free()
	gate.free()
	res.free()
	tm.free()


# ----------------------------------------------------------------------------
# [6] 一键招满：ASSIGN_PRIORITY 静态护栏（6a） + 场景分配行为（6b，仿 smoke_test 装配）
# ----------------------------------------------------------------------------
func _test_events_and_groups() -> void:
	print("[7] 事件系统结构 + 建造菜单分组")
	# 事件池结构：id/title/desc/options/era 齐全，options 均带 label 与 effects 字典
	var ids := {}
	for e in EventManager.EVENTS:
		var eid := String(e["id"])
		_check(eid != "" and not ids.has(eid), "事件 %s：id 非空且唯一" % eid)
		ids[eid] = true
		_check(String(e.get("title", "")) != "", "事件 %s：title 非空" % eid)
		_check(String(e.get("desc", "")) != "", "事件 %s：desc 非空" % eid)
		_check(int(e.get("era", 0)) >= 1, "事件 %s：era >= 1" % eid)
		var opts: Array = e.get("options", [])
		_check(opts.size() >= 1, "事件 %s：至少一个选项" % eid)
		for o in opts:
			_check(String(o.get("label", "")) != "", "事件 %s：选项 label 非空" % eid)
			_check(o.get("effects", null) is Dictionary, "事件 %s：选项 effects 为字典" % eid)
	# 分组：catalog 全部条目有合法 group；每组至少一座建筑
	var names := {
		"food": true, "resource": true, "life": true, "produce": true, "defense": true,
	}
	var per_group := {}
	for entry in BuildingCatalog.ALL:
		var g := String(entry.get("group", ""))
		_check(names.has(g), "%s：group 合法（%s）" % [String(entry["id"]), g])
		per_group[g] = per_group.get(g, 0) + 1
	for g in names:
		_check(per_group.get(g, 0) > 0, "分组「%s」至少有 1 座建筑" % g)

func _test_assign_priority() -> void:
	print("[6] 一键招满优先级：目录护栏（6a） + 场景断言（6b）")
	# ---- 6a. 静态护栏：目录中 workers>0 且非 trains_guards 的 id ⊆ main.ASSIGN_PRIORITY ----
	var priority: Array = MAIN_SCRIPT.ASSIGN_PRIORITY
	var missing: Array[String] = []
	var required := 0
	for entry in BuildingCatalog.ALL:
		if int(entry.get("workers", 0)) <= 0:
			continue
		if bool(entry.get("trains_guards", false)):
			continue  # 兵营被刻意排除在一键招满外（防一键征兵，main.gd:574）
		required += 1
		var bid := String(entry["id"])
		if not priority.has(bid):
			missing.append(bid)
	_check(missing.is_empty(),
		"目录中 %d 个需工人建筑（非 trains_guards）全部登记在 ASSIGN_PRIORITY（缺：%s）"
		% [required, str(missing)])
	_check(priority.has("gatherer") and priority.has("mill") and priority.has("bakery"),
		"ASSIGN_PRIORITY 含场景断言三主角 gatherer/mill/bakery")
	# ---- 6b. 场景断言：2 空闲村民 + gatherer/mill/bakery 各 1 → 一键招满 ----
	var main = load("res://scenes/main.tscn").instantiate()
	if main == null:
		_check(false, "6b 场景断言：无法实例化 res://scenes/main.tscn（装配失败，按 FAIL 记账）")
		return
	root.add_child(main)
	await process_frame
	await process_frame
	main.new_game()  # 干净开局：5 名村民、0 建筑、地图重生成；不读不写任何存档
	var kids: Array = main.villagers_root.get_children()
	if kids.size() >= 3:
		for i in 3:
			kids[i].free()  # 裁到 2 名空闲村民（开局默认 5 名；不足 3 时保命不裁，让下方计数断言报 FAIL）
	_check(main.villagers_root.get_child_count() == 2, "6b 装配：裁员后恰余 2 名空闲村民")
	# 东南角手工铺一块开阔草地（盖掉随机地形），三座 1×1 建筑互隔 2 格、四周皆可走
	for x in range(39, 47):
		for y in range(39, 47):
			main.grid.terrain[main.grid._idx(x, y)] = GridManager.TileType.GRASS
	var cells := {"gatherer": Vector2i(40, 40), "mill": Vector2i(42, 40),
		"bakery": Vector2i(42, 42)}
	var placed := 0
	for bid in cells:
		var cat := BuildingCatalog.find_by_id(StringName(bid))
		var b := Building.new()
		# 绕过 placer 手工落格：免扣费/免 min_era 校验（mill/bakery 是时代Ⅱ建筑），装配法同 load_game
		b.setup(cat, cells[bid], main.resources, main.time_mgr, main.raid)
		main.buildings_root.add_child(b)
		main.grid.occupy_area(cells[bid], cat.get("size", Vector2i.ONE), b)
		placed += 1
	_check(placed == 3 and main.buildings_root.get_child_count() == 3,
		"6b 装配：gatherer/mill/bakery 各 1 座并已占格")
	main.assign_all_workers()
	var got := {}
	for b in main.buildings_root.get_children():
		got[String(b.data.get("id", ""))] = b.workers.size()
	_check(int(got.get("gatherer", -1)) == 1, "一键招满：gatherer=1（优先级 0，拿第 1 名空闲村民）")
	_check(int(got.get("mill", -1)) == 1, "一键招满：mill=1（优先级 4，拿第 2 名空闲村民）")
	_check(int(got.get("bakery", -1)) == 0, "一键招满：bakery=0（优先级 5，空闲村民已耗尽）")
	var employed := 0
	for v in main.villagers_root.get_children():
		if v.workplace != null:
			employed += 1
	_check(employed == 2, "2 名空闲村民全部上岗（workplace 均已绑定）")
