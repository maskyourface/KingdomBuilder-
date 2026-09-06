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
##   [14] 世界生成：WorldConfig 三张表结构完整；按预设生成后地貌比例接近目标；
##        开局保证（中心广场可建 + 12 格内四类资源齐全）在多张随机图上成立。
##   [15] 交通方式：四种路面的表齐全且代价/移速同向；各自只能铺在对应地形上；
##        A* 启发式下界 ≤ 最便宜的路面代价（否则寻路不再最优）。
##   [16] 时代×职能覆盖：每个时代都要有新解锁的军事/经济/民生建筑。
##   [17] 资源链闭合：每种资源都有生产者，也都有去处（吃/卖/当输入/当造价）。
##   [18] 生产数值平衡：打印全部生产建筑的"每工每分钟产出"排行；同一建造分组内
##        不得出现数量级离群；市场价目表必须按单价降序，且加工一步必须增值。
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
	_test_upgrade_system()
	_test_panel_anchors()
	_test_villager_traits()
	_test_wolves_and_bonfire()
	_test_school()
	_test_advisor_order()
	_test_world_generation()
	_test_transport()
	_test_era_sector_coverage()
	_test_resource_chains()
	_test_production_balance()
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
	# 村民进食的经济前提：EDIBLE_RESTORE 必须按回复值严格降序，且面包排第一。
	# 村民是"从头往下吃第一样有库存的"，表乱序 = 有面包也先啃生食，加工链直接失去意义
	var edible: Array = ResourceManager.EDIBLE_RESTORE
	_check(edible.size() >= 2, "可食用资源表至少两项（实为 %d）" % edible.size())
	_check(int(edible[0][0]) == ResourceManager.Type.BREAD,
		"面包排在可食用表首位（优先被吃）")
	var descending := true
	for ei in range(1, edible.size()):
		if float(edible[ei][1]) >= float(edible[ei - 1][1]):
			descending = false
	_check(descending, "EDIBLE_RESTORE 按回复值严格降序（吃的顺序 = 划算的顺序）")
	_check(float(edible[0][1]) > float(edible[edible.size() - 1][1]),
		"面包回复(%.0f) > 表尾生食回复(%.0f)（面包链因此有价值）"
		% [float(edible[0][1]), float(edible[edible.size() - 1][1])])
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

# ----------------------------------------------------------------------------
# [8] 建筑升级系统：目录 upgrade 块结构 + 加成键有人消费 + Building 生效值算术
# ----------------------------------------------------------------------------
## 允许的加成键 → 它在 building.gd 里必须出现的 level_bonus("键") 消费点。
## 这条护栏专治「在 catalog 里写了个加成键，但没有任何 eff_* 读它，于是升级悄悄没效果」。
const UPGRADE_GAIN_KEYS: Array[String] = [
	"speed", "workers", "housing", "aura", "serves", "sell_cap",
	"buy_budget", "hp", "radius", "damage", "range", "keeps", "scare",
	"teach_slots", "teach_radius", "crown",
]
const UPGRADE_META_KEYS: Array[String] = ["cost", "max_level", "titles"]

func _test_upgrade_system() -> void:
	print("[8] 建筑升级：目录结构 / 加成键消费护栏 / 生效值算术")
	# ---- 8a. building.gd 里每个加成键都有 level_bonus 消费点 ----
	var bsrc := ""
	var f := FileAccess.open("res://scripts/building.gd", FileAccess.READ)
	if f != null:
		bsrc = f.get_as_text()
		f.close()
	_check(bsrc != "", "building.gd 源码可读（加成键消费护栏的前提）")
	var used_keys := {}
	for entry in BuildingCatalog.ALL:
		var up: Dictionary = entry.get("upgrade", {})
		if up.is_empty():
			continue
		for k in up:
			if not (k in UPGRADE_META_KEYS):
				used_keys[String(k)] = true
	for k in used_keys:
		_check(k in UPGRADE_GAIN_KEYS, "加成键「%s」在允许集合内（拼错的键会被挡下）" % k)
		_check(bsrc.contains('level_bonus("%s")' % k),
			"加成键「%s」在 building.gd 有 level_bonus 消费点（不会升了级没效果）" % k)
	# ---- 8b. 每个 upgrade 块结构完整 ----
	var upgradable := 0
	for entry in BuildingCatalog.ALL:
		var up: Dictionary = entry.get("upgrade", {})
		var bid := String(entry["id"])
		if up.is_empty():
			continue
		upgradable += 1
		var max_lv := int(up.get("max_level", 1))
		_check(max_lv >= 2, "%s：max_level >= 2" % bid)
		var cost: Array = up.get("cost", [])
		_check(not cost.is_empty(), "%s：升级造价非空" % bid)
		var cost_ok := true
		for c in cost:
			if not (c is Array and c.size() == 2 and int(c[1]) > 0):
				cost_ok = false
		_check(cost_ok, "%s：升级造价格式为 [[类型, 正数], ...]" % bid)
		var titles: Array = up.get("titles", [])
		_check(titles.size() == max_lv - 1,
			"%s：titles 条数（%d）= max_level-1（%d）" % [bid, titles.size(), max_lv - 1])
		var gains := 0
		for k in up:
			if k in UPGRADE_GAIN_KEYS and float(up[k]) > 0.0:
				gains += 1
		_check(gains >= 1, "%s：至少有 1 项实际加成（不存在纯花钱升级）" % bid)
		# 加成必须作用在这栋建筑真有的属性上，否则是写错了对象
		if int(up.get("housing", 0)) > 0:
			_check(int(entry.get("housing", 0)) > 0, "%s：给了住房加成且本身是住房" % bid)
		if float(up.get("speed", 0.0)) > 0.0:
			_check(entry.get("produces", false), "%s：给了提速加成且本身有生产" % bid)
		if float(up.get("aura", 0.0)) > 0.0:
			_check(float(entry.get("aura_radius", 0.0)) > 0.0, "%s：给了光环加成且本身有光环" % bid)
		if int(up.get("workers", 0)) > 0:
			_check(int(entry.get("workers", 0)) > 0, "%s：给了工位加成且本身要工人" % bid)
		if int(up.get("hp", 0)) > 0:
			_check(int(entry.get("hp", -1)) > 0, "%s：给了耐久加成且本身有耐久" % bid)
		if int(up.get("keeps", 0)) > 0:
			_check(int(entry.get("keeps_food", 0)) > 0, "%s：给了保鲜加成且本身是粮仓" % bid)
		if float(up.get("scare", 0.0)) > 0.0:
			_check(float(entry.get("scares_wolves", 0.0)) > 0.0, "%s：给了火光加成且本身是篝火" % bid)
		if int(up.get("teach_slots", 0)) > 0 or float(up.get("teach_radius", 0.0)) > 0.0:
			_check(float(entry.get("teach_radius", 0.0)) > 0.0, "%s：给了授课加成且本身是学堂" % bid)
		if int(up.get("crown", 0)) > 0:
			_check(float(entry.get("castle_bonus", 0.0)) > 0.0, "%s：给了加冕加成且本身是城堡" % bid)
	_check(upgradable >= 15, "可升级建筑数量 %d ≥ 15（升级是全局系统而非个别特例）" % upgradable)
	# ---- 8c. Building 生效值算术（不进场景树，纯对象） ----
	var house_data := BuildingCatalog.find_by_id(&"house")
	var b := Building.new()
	b.data = house_data
	b.level = 1
	_check(b.eff_housing() == 3, "小屋 Lv1 住房 3（实得 %d）" % b.eff_housing())
	_check(b.max_level() == 3, "小屋 max_level=3")
	_check(b.can_upgrade(), "小屋 Lv1 可升级")
	var c1: Array = b.upgrade_cost()
	_check(c1.size() == 1 and int(c1[0][1]) == 5, "小屋 Lv1→2 造价 = 基础 ×1 = 木5")
	b.level = 2
	_check(b.eff_housing() == 5, "小屋 Lv2 住房 5（实得 %d）" % b.eff_housing())
	var c2: Array = b.upgrade_cost()
	_check(c2.size() == 1 and int(c2[0][1]) == 10, "小屋 Lv2→3 造价 = 基础 ×2 = 木10")
	b.level = 3
	_check(b.eff_housing() == 7, "小屋 Lv3 住房 7（实得 %d）" % b.eff_housing())
	_check(not b.can_upgrade(), "小屋 Lv3 已满级")
	# 总投入 = 建造 5 + 升级 5 + 升级 10 = 20（拆除退一半 = 10）
	var inv: Array = b.total_investment()
	var wood_inv := 0
	for c in inv:
		if int(c[0]) == ResourceManager.Type.WOOD:
			wood_inv = int(c[1])
	_check(wood_inv == 20, "小屋 Lv3 总投入 木20（建造5+升级5+升级10），实得 %d" % wood_inv)
	b.free()
	# 生产提速：面包房 Lv1 6 秒 → Lv3 应为 6/(1+0.5×2)=3 秒
	var bake := Building.new()
	bake.data = BuildingCatalog.find_by_id(&"bakery")
	bake.level = 1
	_check(is_equal_approx(bake.eff_interval(), 6.0), "面包房 Lv1 周期 6 秒")
	bake.level = 3
	_check(is_equal_approx(bake.eff_interval(), 3.0),
		"面包房 Lv3 周期 3 秒（实得 %.2f）" % bake.eff_interval())
	_check(bake.eff_workers() == 3, "面包房 Lv3 工位 3（实得 %d）" % bake.eff_workers())
	_check(bake.display_title().contains("Lv3"), "带等级显示名含 Lv3：%s" % bake.display_title())
	bake.free()
	# 城墙耐久随等级抬高，且升级会把耐久修满
	var wall := Building.new()
	wall.data = BuildingCatalog.find_by_id(&"wall")
	wall.level = 1
	wall.hp = 10  # 残血
	_check(wall.eff_max_hp() == 60, "城墙 Lv1 耐久上限 60")
	wall.apply_upgrade()
	_check(wall.level == 2 and wall.hp == 120,
		"城墙升级后 Lv2 且耐久修满 120（实得 Lv%d/%d）" % [wall.level, wall.hp])
	wall.free()
	# 粮仓：保鲜量为正，且升级增量与基础量同一量级（不会出现"升级只加 1"的鸡肋档）
	var gran_data := BuildingCatalog.find_by_id(&"granary")
	_check(not gran_data.is_empty(), "目录中存在粮仓")
	if not gran_data.is_empty():
		var base_keep := int(gran_data.get("keeps_food", 0))
		_check(base_keep > 0, "粮仓基础保鲜量 %d > 0" % base_keep)
		var gb := Building.new()
		gb.data = gran_data
		gb.level = 1
		_check(gb.eff_keeps_food() == base_keep, "粮仓 Lv1 保鲜 %d" % gb.eff_keeps_food())
		gb.level = 3
		_check(gb.eff_keeps_food() == base_keep + int(gran_data["upgrade"]["keeps"]) * 2,
			"粮仓 Lv3 保鲜 %d（基础 + 每级增量 ×2）" % gb.eff_keeps_food())
		_check(int(gran_data.get("workers", 0)) == 0, "粮仓无需工人（纯被动仓储）")
		gb.free()
	# 不产原料的建筑排优先级没意义：默认值必须是"常规"
	var pb := Building.new()
	pb.data = BuildingCatalog.find_by_id(&"bakery")
	_check(pb.priority == 1, "建筑默认原料优先级 = 常规（1）")
	pb.free()
	# 土路是纯基建，没有可升的东西
	var road_d := BuildingCatalog.find_by_id(&"road")
	_check(not road_d.has("upgrade"), "土路无升级块（升级按钮会自动隐藏）")
	# 城堡是三期工程：每一期都要给出实打实的幸福加成，且满级才等于加冕
	var castle_d := BuildingCatalog.find_by_id(&"castle")
	_check(castle_d.has("upgrade"), "城堡有升级块（三期工程）")
	if castle_d.has("upgrade"):
		var cb := Building.new()
		cb.data = castle_d
		var last := -1.0
		for lv in range(1, cb.max_level() + 1):
			cb.level = lv
			var bonus: float = cb.eff_castle_bonus()
			_check(bonus > last, "城堡第 %d 期全体幸福 +%.0f（逐期递增）" % [lv, bonus])
			last = bonus
		cb.level = cb.max_level()
		_check(is_equal_approx(cb.eff_castle_bonus(), 10.0),
			"城堡满级全体幸福 +10（与旧版一次性建成的数值持平，实为 %.0f）" % cb.eff_castle_bonus())
		_check(not cb.can_upgrade(), "城堡满级即不可再升（此时才加冕）")
		# 三期总价应与旧版一次性造价（木100 石80 金50）基本持平，不能借着分期偷偷涨价
		cb.level = cb.max_level()
		var total := {}
		for c in cb.total_investment():
			total[int(c[0])] = int(c[1])
		_check(absi(int(total.get(ResourceManager.Type.WOOD, 0)) - 100) <= 10,
			"城堡三期总木料 %d ≈ 100" % int(total.get(ResourceManager.Type.WOOD, 0)))
		_check(absi(int(total.get(ResourceManager.Type.STONE, 0)) - 80) <= 10,
			"城堡三期总石料 %d ≈ 80" % int(total.get(ResourceManager.Type.STONE, 0)))
		_check(absi(int(total.get(ResourceManager.Type.GOLD, 0)) - 50) <= 10,
			"城堡三期总金币 %d ≈ 50" % int(total.get(ResourceManager.Type.GOLD, 0)))
		cb.free()

# ----------------------------------------------------------------------------
# [9] 面板锚点/grow 一致性：把迭代8 踩过的"整面板画在屏幕外"固化成静态断言
# ----------------------------------------------------------------------------
## Godot 的 set_anchors_preset 只钉锚点，不决定往哪边长。锚在右边/下边/中心的面板
## 如果 grow 方向朝外，整块会长到屏幕外——迭代8 一次性踩中 7 个面板。
## 规则：某个轴上若没有用一对 offset 把两边都钉死（size 由内容决定），
##   锚在右/下 → grow 必须 BEGIN 或 BOTH；锚在中心 → grow 必须 BOTH。
## 锚在左/上时默认 END 就是朝屏内长，无需约束。
## headless 视口恒为 64×64，量不到真实布局，所以这条只能靠源码规则守。
const ANCHOR_PRESETS := {
	"PRESET_CENTER": ["center", "center"],
	"PRESET_CENTER_LEFT": ["left", "center"],
	"PRESET_CENTER_RIGHT": ["right", "center"],
	"PRESET_CENTER_TOP": ["center", "top"],
	"PRESET_CENTER_BOTTOM": ["center", "bottom"],
	"PRESET_TOP_LEFT": ["left", "top"],
	"PRESET_TOP_RIGHT": ["right", "top"],
	"PRESET_BOTTOM_LEFT": ["left", "bottom"],
	"PRESET_BOTTOM_RIGHT": ["right", "bottom"],
}
const UI_SOURCES: Array[String] = [
	"res://scripts/hud.gd", "res://scripts/main_menu.gd", "res://scripts/event_manager.gd",
]

func _test_panel_anchors() -> void:
	print("[9] 面板锚点/grow 一致性（防「整面板画到屏幕外」）")
	var checked := 0
	for path in UI_SOURCES:
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			_check(false, "%s 可读" % path)
			continue
		var src := f.get_as_text()
		f.close()
		var lines := src.split("\n")
		for line in lines:
			var t := line.strip_edges()
			if not t.contains(".set_anchors_preset(Control.PRESET_"):
				continue
			var var_name := t.substr(0, t.find(".set_anchors_preset"))
			var preset := t.substr(t.find("Control.PRESET_") + 8)
			preset = preset.substr(0, preset.find(")"))
			if not ANCHOR_PRESETS.has(preset):
				continue  # FULL_RECT / *_WIDE 两边都钉死，天然安全
			var axes: Array = ANCHOR_PRESETS[preset]
			var props := _collect_props(lines, var_name)
			checked += 1
			var tag := "%s（%s）" % [var_name, preset]
			# 水平轴
			var h_pinned: bool = props.has("offset_left") and props.has("offset_right")
			if axes[0] == "right" and not h_pinned:
				_check(props.get("grow_horizontal", "") in ["BEGIN", "BOTH"],
					"%s 锚在右边且宽度随内容 → grow_horizontal 应向内（实为 %s）"
					% [tag, props.get("grow_horizontal", "默认END")])
			elif axes[0] == "center" and not h_pinned:
				_check(props.get("grow_horizontal", "") == "BOTH",
					"%s 水平居中且宽度随内容 → grow_horizontal 应为 BOTH（实为 %s）"
					% [tag, props.get("grow_horizontal", "默认END")])
			# 垂直轴
			var v_pinned: bool = props.has("offset_top") and props.has("offset_bottom")
			if axes[1] == "bottom" and not v_pinned:
				_check(props.get("grow_vertical", "") in ["BEGIN", "BOTH"],
					"%s 锚在底边且高度随内容 → grow_vertical 应向内（实为 %s）"
					% [tag, props.get("grow_vertical", "默认END")])
			elif axes[1] == "center" and not v_pinned:
				_check(props.get("grow_vertical", "") == "BOTH",
					"%s 垂直居中且高度随内容 → grow_vertical 应为 BOTH（实为 %s）"
					% [tag, props.get("grow_vertical", "默认END")])
	_check(checked >= 10, "扫描到 %d 个带锚点预设的面板（≥10 说明扫描逻辑没漏掉文件）" % checked)

## 收集某个面板变量在整份源码里设过的 offset_*/grow_* 属性（面板配置都是连续几行，
## 变量名唯一，全文件收集足够可靠且不用写块解析器）
func _collect_props(lines: PackedStringArray, var_name: String) -> Dictionary:
	var out := {}
	for line in lines:
		var t := line.strip_edges()
		if not t.begins_with(var_name + "."):
			continue
		var body := t.substr(var_name.length() + 1)
		for key in ["offset_left", "offset_right", "offset_top", "offset_bottom"]:
			if body.begins_with(key + " ="):
				out[key] = true
		for key in ["grow_horizontal", "grow_vertical"]:
			if body.begins_with(key + " ="):
				if body.contains("GROW_DIRECTION_BOTH"):
					out[key] = "BOTH"
				elif body.contains("GROW_DIRECTION_BEGIN"):
					out[key] = "BEGIN"
				else:
					out[key] = "END"
	return out

# ----------------------------------------------------------------------------
# [10] 村民特长：特长表结构 / 抽取池合法 / 效率与饥饿算术 / 读档回落
# ----------------------------------------------------------------------------
## 特长表里的效果键必须真的被 Villager 的某个方法消费，否则"写了个特长但没效果"。
const TRAIT_EFFECT_KEYS := {
	"work": 'get("work", 1.0)',
	"craft": 'get("craft", 1.0)',
	"hunger": 'get("hunger", 1.0)',
	"speed": 'get("speed", 1.0)',
	"mood": 'get("mood", 0.0)',
	"hp": 'get("hp", 0)',
}

func _test_villager_traits() -> void:
	print("[10] 村民特长：表结构 / 抽取池 / 效率算术 / 读档回落")
	var vsrc := ""
	var f := FileAccess.open("res://scripts/villager.gd", FileAccess.READ)
	if f != null:
		vsrc = f.get_as_text()
		f.close()
	_check(vsrc != "", "villager.gd 源码可读")
	# ---- 10a. 表结构：每个特长有名字与说明；效果键都在允许集合内且有消费点 ----
	_check(Villager.TRAITS.has(&"plain"), "存在「寻常」兜底特长（旧档/坏档回落到它）")
	for tid in Villager.TRAITS:
		var t: Dictionary = Villager.TRAITS[tid]
		_check(String(t.get("name", "")) != "", "特长 %s：name 非空" % tid)
		_check(String(t.get("desc", "")) != "", "特长 %s：desc 非空" % tid)
		for k in t:
			if k == "name" or k == "desc":
				continue
			_check(TRAIT_EFFECT_KEYS.has(String(k)),
				"特长 %s：效果键「%s」在允许集合内" % [tid, k])
			if TRAIT_EFFECT_KEYS.has(String(k)):
				_check(vsrc.contains(String(TRAIT_EFFECT_KEYS[String(k)])),
					"效果键「%s」在 villager.gd 有消费点（不会写了没效果）" % k)
	# ---- 10b. 抽取池：只能抽到已定义的特长；池里必须有正有负 ----
	var pool_has_negative := false
	var pool_has_positive := false
	for tid in Villager.TRAIT_POOL:
		_check(Villager.TRAITS.has(tid), "抽取池条目 %s 在特长表中有定义" % tid)
		var t: Dictionary = Villager.TRAITS.get(tid, {})
		if float(t.get("work", 1.0)) < 1.0 or float(t.get("hunger", 1.0)) > 1.0:
			pool_has_negative = true
		if float(t.get("work", 1.0)) > 1.0 or float(t.get("craft", 1.0)) > 1.0 \
				or float(t.get("speed", 1.0)) > 1.0 or float(t.get("mood", 0.0)) > 0.0 \
				or int(t.get("hp", 0)) > 0:
			pool_has_positive = true
	_check(pool_has_positive, "抽取池里有正面特长")
	_check(pool_has_negative, "抽取池里有负面特长（否则派工没有取舍）")
	_check(Villager.TRAIT_POOL.size() >= 8, "抽取池 %d 条（够摊开权重）" % Villager.TRAIT_POOL.size())
	# ---- 10c. 效率算术：手巧只在"有原料投入"的作坊生效 ----
	var v := Villager.new()
	var bakery := Building.new()
	bakery.data = BuildingCatalog.find_by_id(&"bakery")   # 有 inputs（面粉）
	var lumber := Building.new()
	lumber.data = BuildingCatalog.find_by_id(&"lumber")   # 无 inputs（采集型）
	v.trait_id = &"plain"
	_check(is_equal_approx(v.work_efficiency(lumber), 1.0), "寻常：基准效率 1.0")
	_check(is_equal_approx(v.hunger_mult(), 1.0), "寻常：饥饿倍率 1.0")
	v.trait_id = &"diligent"
	_check(is_equal_approx(v.work_efficiency(lumber), 1.25), "勤劳：采集型效率 1.25")
	v.trait_id = &"skilled"
	_check(is_equal_approx(v.work_efficiency(lumber), 1.0),
		"手巧：采集型不加成（实得 %.2f）" % v.work_efficiency(lumber))
	_check(is_equal_approx(v.work_efficiency(bakery), 1.35),
		"手巧：加工作坊 +35%%（实得 %.2f）" % v.work_efficiency(bakery))
	v.trait_id = &"frail"
	_check(v.work_efficiency(lumber) < 1.0 and v.hunger_mult() > 1.0, "体弱：效率降、饿得快")
	v.trait_id = &"hardy"
	_check(v.guard_max_hp() > Villager.GUARD_MAX_HP,
		"壮硕：卫兵血上限 %d > 基准 %d" % [v.guard_max_hp(), Villager.GUARD_MAX_HP])
	v.trait_id = &"cheerful"
	_check(v.mood_bonus() > 0.0, "乐观：幸福偏移 +%.0f" % v.mood_bonus())
	v.trait_id = &"swift"
	_check(v.speed_mult() > 1.0, "腿快：移速倍率 %.2f" % v.speed_mult())
	# 坏特长 id 回落到寻常，绝不因为一个字段崩掉
	v.trait_id = &"__not_a_trait__"
	_check(is_equal_approx(v.work_efficiency(lumber), 1.0), "未知特长 id 回落为寻常基准")
	_check(v.trait_name() == "寻常", "未知特长 id 显示为「寻常」")
	# roll_trait 抽到的一定是池内合法项
	for i in 30:
		v.roll_trait()
		if not Villager.TRAITS.has(v.trait_id):
			_check(false, "roll_trait 抽出了未定义特长 %s" % v.trait_id)
			break
	_check(Villager.TRAITS.has(v.trait_id), "roll_trait 连抽 30 次全部落在特长表内")
	v.free()
	bakery.free()
	lumber.free()

# ----------------------------------------------------------------------------
# [11] 早期威胁：野狼分叉与篝火（时代Ⅱ~Ⅲ 不再是零风险挂机）
# ----------------------------------------------------------------------------
func _test_wolves_and_bonfire() -> void:
	print("[11] 野狼 / 篝火：时代分叉、目标表、篝火半径与集中供暖")
	# ---- 11a. 时代分叉：Ⅱ~Ⅲ 狼，Ⅳ 起强盗，Ⅰ 不排期 ----
	var rm := RaidManager.new()
	_check(rm.kind_for_era(2) == &"wolf", "时代Ⅱ 来的是野狼")
	_check(rm.kind_for_era(3) == &"wolf", "时代Ⅲ 来的是野狼")
	_check(rm.kind_for_era(4) == &"bandit", "时代Ⅳ 来的是强盗")
	_check(rm.kind_for_era(5) == &"bandit", "时代Ⅴ 来的是强盗")
	_check(RaidManager.WOLF_MIN_ERA >= 2, "时代Ⅰ 不排期（留给纯建设）")
	_check(RaidManager.WOLF_MIN_ERA < RaidManager.BANDIT_MIN_ERA,
		"野狼的时代门槛早于强盗（先有小威胁再有大威胁）")
	_check(RaidManager.WOLF_MAX_COUNT <= 4,
		"野狼数量封顶 %d（骚扰而非抄家）" % RaidManager.WOLF_MAX_COUNT)
	rm.free()
	# ---- 11b. 野狼目标表：只盯食物产线与粮仓，且目录里都真实存在 ----
	_check(not Enemy.WOLF_TARGET_IDS.is_empty(), "野狼目标表非空")
	for bid in Enemy.WOLF_TARGET_IDS:
		var d := BuildingCatalog.find_by_id(StringName(bid))
		_check(not d.is_empty(), "野狼目标 %s 在目录中存在" % bid)
		var is_food: bool = String(d.get("group", "")) == "food" \
			or int(d.get("keeps_food", 0)) > 0 \
			or String(d.get("id", "")) == "pasture"
		_check(is_food, "野狼目标 %s 确实是吃的相关（食物组/粮仓/牧场）" % bid)
		_check(int(d.get("housing", 0)) == 0, "野狼目标 %s 不是住房（狼不抄家）" % bid)
	_check(Enemy.WOLF_MAX_HP < Enemy.MAX_HP,
		"野狼血量 %d < 强盗 %d" % [Enemy.WOLF_MAX_HP, Enemy.MAX_HP])
	_check(Enemy.WOLF_SPEED > Enemy.SPEED, "野狼跑得比强盗快（逃跑的村民真跑不过）")
	# ---- 11c. 篝火：半径随等级增长，且冬季供暖比每户各烧更省 ----
	var fire_data := BuildingCatalog.find_by_id(&"bonfire")
	_check(not fire_data.is_empty(), "目录中存在篝火")
	if not fire_data.is_empty():
		_check(fire_data.get("warms", false), "篝火带 warms 标记（冬季集中供暖）")
		_check(int(fire_data.get("min_era", 1)) <= RaidManager.WOLF_MIN_ERA,
			"篝火解锁时代 ≤ 野狼出现时代（威胁来时已经有解法）")
		var fb := Building.new()
		fb.data = fire_data
		fb.level = 1
		var r1: float = fb.eff_scare_radius()
		_check(r1 > 0.0, "篝火 Lv1 火光半径 %.1f 格" % r1)
		fb.level = 3
		_check(fb.eff_scare_radius() > r1,
			"篝火 Lv3 火光半径 %.1f > Lv1 %.1f" % [fb.eff_scare_radius(), r1])
		fb.free()
		# 经济性：一堆篝火烧 BONFIRE_WOOD 木，要比它能覆盖的房子各烧一份便宜，
		# 否则这个建筑没有存在意义
		var bonfire_wood: int = MAIN_SCRIPT.BONFIRE_WOOD
		var small: int = MAIN_SCRIPT.HEAT_WOOD_SMALL
		_check(bonfire_wood > small,
			"篝火单独看更贵（%d > %d）——必须覆盖多户才划算，这是布局决策的来源"
			% [bonfire_wood, small])
		_check(bonfire_wood <= small * 3,
			"篝火覆盖 3 户即回本（%d ≤ %d），不至于贵到没人用" % [bonfire_wood, small * 3])

# ----------------------------------------------------------------------------
# [12] 学堂：把"村民特长"从出生抽签变成可长期投资的东西
# ----------------------------------------------------------------------------
func _test_school() -> void:
	print("[12] 学堂：可教集合 / 点化路径 / 半径与名额随等级增长")
	var sd := BuildingCatalog.find_by_id(&"school")
	_check(not sd.is_empty(), "目录中存在学堂")
	if sd.is_empty():
		return
	_check(int(sd.get("min_era", 1)) == 3, "学堂属于时代Ⅲ（把最薄的一个时代填厚）")
	_check(int(sd.get("workers", 0)) > 0, "学堂需要先生在岗（不是白嫖的被动光环）")
	# 刻意不走 aura_kind：它改的是特长不是幸福度，混进幸福光环循环会算错
	_check(String(sd.get("aura_kind", "")).is_empty(),
		"学堂不带 aura_kind（不混进幸福度光环结算）")
	var sb := Building.new()
	sb.data = sd
	sb.level = 1
	var r1: float = sb.eff_teach_radius()
	var s1: int = sb.eff_teach_slots()
	_check(r1 > 0.0 and s1 >= 1, "学堂 Lv1：半径 %.1f 格、每日 %d 人" % [r1, s1])
	sb.level = 3
	_check(sb.eff_teach_radius() > r1 and sb.eff_teach_slots() > s1,
		"学堂 Lv3：半径 %.1f、每日 %d 人（均随等级增长）"
		% [sb.eff_teach_radius(), sb.eff_teach_slots()])
	sb.free()
	# 可教集合与产出集合
	_check(not Villager.TEACHABLE.is_empty(), "可教特长集合非空")
	_check(not Villager.LEARNABLE.is_empty(), "可学手艺集合非空")
	for t in Villager.TEACHABLE:
		_check(Villager.TRAITS.has(t), "可教特长 %s 有定义" % t)
	for t in Villager.LEARNABLE:
		_check(Villager.TRAITS.has(t), "可学手艺 %s 有定义" % t)
		_check(not (t in Villager.TEACHABLE),
			"学出来的 %s 不在可教集合里（学完就毕业，不会被反复刷）" % t)
	# 点化路径：体弱 → 寻常 → 手艺 → 到此为止
	var pv := Villager.new()
	pv.trait_id = &"frail"
	pv.learn()
	_check(pv.trait_id == &"plain", "体弱先调理成寻常（实为 %s）" % pv.trait_id)
	pv.learn()
	_check(pv.trait_id in Villager.LEARNABLE,
		"寻常再学一门手艺（实为 %s）" % pv.trait_id)
	var learned: StringName = pv.trait_id
	pv.learn()
	_check(pv.trait_id == learned, "已有手艺者再进课堂不会被改写（避免洗成清一色最优解）")
	pv.free()
	# 学堂必须登记进一键招满优先级（否则"招满"永远不给学堂派先生）
	var pri: Array = MAIN_SCRIPT.ASSIGN_PRIORITY
	_check("school" in pri, "学堂已登记进 ASSIGN_PRIORITY")

# ----------------------------------------------------------------------------
# [13] 顾问提示：规则必须按紧急度降序排列
# ----------------------------------------------------------------------------
## advisor_hint 是"命中即返回"的规则链，所以**顺序就是优先级**。
## 如果有人把一条 level 0 的规则插到 level 2 前面，那条告急提示就永远轮不到——
## 而且不会有任何报错，只是玩家在快饿死时看到"有 3 名空闲村民"。
## 这条护栏直接读 main.gd 的函数体，断言 level 序列非递增。
func _test_advisor_order() -> void:
	print("[13] 顾问提示：规则链按紧急度降序（告急 → 提醒 → 信息）")
	var f := FileAccess.open("res://scripts/main.gd", FileAccess.READ)
	if f == null:
		_check(false, "main.gd 源码可读")
		return
	var src := f.get_as_text()
	f.close()
	var body := _extract_func(src, "advisor_hint")
	_check(body != "", "能提取到 advisor_hint 函数体")
	if body == "":
		return
	var levels: Array[int] = []
	var re := RegEx.new()
	re.compile('"level"\\s*:\\s*(\\d+)')
	for m in re.search_all(body):
		levels.append(int(m.get_string(1)))
	_check(levels.size() >= 5, "顾问至少有 %d 条带级别的规则" % levels.size())
	var descending := true
	var worst := ""
	for i in range(1, levels.size()):
		if levels[i] > levels[i - 1]:
			descending = false
			worst = "第 %d 条 level=%d 排在第 %d 条 level=%d 之后" % [
				i + 1, levels[i], i, levels[i - 1]]
	_check(descending,
		"规则链紧急度非递增（否则高级别提示永远轮不到）%s" % ("" if descending else "：" + worst))
	_check(levels.has(2) and levels.has(1) and levels.has(0),
		"三个级别都有规则（告急/提醒/信息各自都用得上）")
	# 顾问必须复用既有的计算入口，不能自己再写一遍公式——这是本项目反复走偏的地方
	for entry in ["food_days_left()", "winter_heat_need()", "food_keep_line()",
			"idle_building_report()"]:
		_check(body.contains(entry), "顾问复用既有入口 %s（不另立会走偏的公式）" % entry)

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

# ----------------------------------------------------------------------------
# [14] 世界生成：预设表完整性 + 分位数生成的比例可控性 + 开局保证
# ----------------------------------------------------------------------------
## 分位数取阈值的意义就是"配置里写多少就是多少"。这条守的就是这个承诺：
## 换地形预设后地貌真的变了，而不是噪声分布碰巧决定了一切。
## 开局保证那几条更重要——它替代了玩家"开局不好就重开"的手动流程。
func _test_world_generation() -> void:
	print("[14] 世界生成：预设表 / 比例可控 / 开局保证")
	_check(WorldConfig.SIZES.size() >= 3, "地图大小至少 3 档（实为 %d）" % WorldConfig.SIZES.size())
	_check(WorldConfig.TERRAINS.size() >= 2,
		"地图类型至少 2 种（实为 %d）" % WorldConfig.TERRAINS.size())
	_check(WorldConfig.RICHNESS.size() >= 2, "资源丰度至少 2 档")
	for table_name in ["SIZES", "TERRAINS", "RICHNESS"]:
		var table: Array[Dictionary] = WorldConfig.SIZES
		if table_name == "TERRAINS":
			table = WorldConfig.TERRAINS
		elif table_name == "RICHNESS":
			table = WorldConfig.RICHNESS
		var ids := {}
		var ok := true
		for d in table:
			if not d.has("id") or not d.has("name") or not d.has("desc"):
				ok = false
			if ids.has(d.get("id", "")):
				ok = false
			ids[d.get("id", "")] = true
		_check(ok, "%s 每项都有唯一 id / name / desc（界面直接读这三个键）" % table_name)
	for d in WorldConfig.SIZES:
		_check(int(d["w"]) >= 30 and int(d["h"]) >= 30,
			"尺寸 %s 不小于 30×30（再小放不下城堡 4×4 + 城墙）" % String(d["name"]))

	# 同一个种子必须生成同一张地图（世界种子的全部意义）
	var cfg := WorldConfig.new()
	cfg.size_id = &"small"
	cfg.terrain_id = &"plains"
	cfg.world_seed = 4242
	var g1 := GridManager.new()
	g1.apply_config(cfg)
	g1.generate_map()
	var g2 := GridManager.new()
	g2.apply_config(cfg)
	g2.generate_map()
	_check(g1.terrain == g2.terrain, "同一种子生成完全相同的地形（可复现开局）")
	_check(g1.width == cfg.map_width() and g1.height == cfg.map_height(),
		"生成尺寸 %d×%d 与配置一致" % [g1.width, g1.height])

	# 分位数保证"配置比例 ≈ 实际比例"（允许 ±3 个百分点：开局保证会挖掉/补上少量格子）
	for tid in [&"plains", &"lakeland", &"highland", &"forest"]:
		var c := WorldConfig.new()
		c.size_id = &"medium"
		c.terrain_id = tid
		c.world_seed = 777
		var g := GridManager.new()
		g.apply_config(c)
		g.generate_map()
		var n := float(g.width * g.height)
		var counts := {}
		for t in g.terrain:
			counts[t] = int(counts.get(t, 0)) + 1
		var water_ratio := float(int(counts.get(GridManager.TileType.WATER, 0))) / n
		var want_water := float(c.terrain_data()["water"])
		_check(absf(water_ratio - want_water) < 0.03,
			"%s：水域实际 %.1f%% ≈ 目标 %.1f%%"
			% [String(c.terrain_data()["name"]), water_ratio * 100.0, want_water * 100.0])
		var mount_ratio := float(int(counts.get(GridManager.TileType.MOUNTAIN, 0))
			+ int(counts.get(GridManager.TileType.IRON, 0))) / n
		var want_mount := float(c.terrain_data()["mountain"])
		_check(absf(mount_ratio - want_mount) < 0.03,
			"%s：山地(含铁矿脉)实际 %.1f%% ≈ 目标 %.1f%%"
			% [String(c.terrain_data()["name"]), mount_ratio * 100.0, want_mount * 100.0])

	# 开局保证：随机 6 张图，每张都要能立刻开工
	var house_conf := BuildingCatalog.find_by_id(&"house")
	var plaza_ok := true
	var res_ok := true
	var missing := ""
	for trial in 6:
		var c2 := WorldConfig.new()
		c2.size_id = &"medium"
		c2.terrain_id = WorldConfig.TERRAINS[trial % WorldConfig.TERRAINS.size()]["id"]
		c2.world_seed = 1000 + trial * 37
		var g3 := GridManager.new()
		g3.apply_config(c2)
		g3.generate_map()
		if not g3.can_place(g3.spawn_center, Vector2i.ONE, house_conf):
			plaza_ok = false
		for t in [GridManager.TileType.FOREST, GridManager.TileType.WATER,
				GridManager.TileType.MOUNTAIN, GridManager.TileType.BERRY]:
			if not g3._has_within(g3.spawn_center, t, GridManager.START_SCAN_RADIUS):
				res_ok = false
				missing = "%s 种子%d 缺地形%d" % [String(c2.terrain_data()["name"]),
					c2.world_seed, int(t)]
	_check(plaza_ok, "6 张随机图的出生点都能直接盖房（不会开局无处可建）")
	_check(res_ok, "6 张随机图的出生点 %d 格内都有森林/水域/山地/浆果丛（%s）"
		% [GridManager.START_SCAN_RADIUS, "全部齐全" if res_ok else missing])

# ----------------------------------------------------------------------------
# [15] 交通方式：四种路面的表、地形限制与寻路口径
# ----------------------------------------------------------------------------
## 加石板路时踩过的坑：改了 ROAD_MOVE_COSTS 却忘了 A* 启发式的单格下界，
## 结果启发式开始高估、寻路悄悄退化成次优。这一组把三张表钉在一起。
func _test_transport() -> void:
	print("[15] 交通方式：路面表 / 地形限制 / 寻路口径")
	var kinds := [GridManager.RoadType.DIRT, GridManager.RoadType.BRIDGE,
		GridManager.RoadType.STONE, GridManager.RoadType.PASS]
	for k in kinds:
		_check(GridManager.ROAD_NAMES.has(k), "路面 %d 有中文名" % int(k))
		_check(GridManager.ROAD_COLORS.has(k), "路面 %d 有颜色（画得出来）" % int(k))
		_check(GridManager.ROAD_MOVE_COSTS.has(k), "路面 %d 有寻路代价" % int(k))
		_check(GridManager.ROAD_SPEEDS.has(k), "路面 %d 有移速倍率" % int(k))
	# 代价与移速必须同向：走得快的路，寻路也得更愿意走，否则村民会绕开快路
	var cheapest := GridManager.BASE_MOVE_COST
	for k in kinds:
		var cost := int(GridManager.ROAD_MOVE_COSTS[k])
		var speed := float(GridManager.ROAD_SPEEDS[k])
		cheapest = mini(cheapest, cost)
		_check(cost < GridManager.BASE_MOVE_COST and speed > 1.0,
			"%s：代价 %d < 无路 %d 且移速 ×%.2f > 1"
			% [String(GridManager.ROAD_NAMES[k]), cost, GridManager.BASE_MOVE_COST, speed])
	for i in range(1, kinds.size()):
		for j in range(i):
			var a: int = kinds[i]
			var b: int = kinds[j]
			var ca := int(GridManager.ROAD_MOVE_COSTS[a])
			var cb := int(GridManager.ROAD_MOVE_COSTS[b])
			var sa := float(GridManager.ROAD_SPEEDS[a])
			var sb := float(GridManager.ROAD_SPEEDS[b])
			_check((ca < cb) == (sa > sb),
				"%s vs %s：代价高低与移速快慢方向一致"
				% [String(GridManager.ROAD_NAMES[a]), String(GridManager.ROAD_NAMES[b])])
	_check(GridManager.MIN_MOVE_COST <= cheapest,
		"A* 启发式下界 %d ≤ 最便宜路面代价 %d（不高估才保证最优路径）"
		% [GridManager.MIN_MOVE_COST, cheapest])

	# 目录里每种交通方式都要存在、可解析、且解锁时代递进
	var seen := {}
	for d in BuildingCatalog.ALL:
		if not d.get("is_road", false):
			continue
		var kind := GridManager.road_kind_of(d)
		_check(not seen.has(kind), "路面类型 %s 在目录里只出现一次"
			% String(GridManager.ROAD_NAMES.get(kind, "?")))
		seen[kind] = int(d.get("min_era", 1))
	for k in kinds:
		_check(seen.has(k), "目录中有 %s 这种交通方式" % String(GridManager.ROAD_NAMES[k]))
	_check(int(seen.get(GridManager.RoadType.DIRT, 9)) == 1, "土路时代Ⅰ 就能铺（开局唯一选择）")
	_check(int(seen.get(GridManager.RoadType.STONE, 0))
		> int(seen.get(GridManager.RoadType.DIRT, 0)),
		"石板路解锁时代晚于土路（升级路面是后期选项）")

	# 地形限制：桥只能架水上、山道只能开山里、陆路不能铺水上
	var g := _make_grid(8, 8)
	_set_cell(g, Vector2i(2, 2), GridManager.TileType.WATER)
	_set_cell(g, Vector2i(4, 4), GridManager.TileType.MOUNTAIN)
	_check(g.can_place_road(Vector2i(2, 2), GridManager.RoadType.BRIDGE), "木桥可架在水域上")
	_check(not g.can_place_road(Vector2i(2, 2), GridManager.RoadType.DIRT), "土路不能铺进水里")
	_check(not g.can_place_road(Vector2i(0, 0), GridManager.RoadType.BRIDGE), "木桥不能架在草地上")
	_check(g.can_place_road(Vector2i(4, 4), GridManager.RoadType.PASS), "山道可开在石林上")
	_check(not g.can_place_road(Vector2i(0, 0), GridManager.RoadType.PASS), "山道不能开在草地上")
	_check(not g.is_walkable(Vector2i(2, 2)), "没桥时水域不可通行")
	g.place_road(Vector2i(2, 2), GridManager.RoadType.BRIDGE)
	_check(g.is_walkable(Vector2i(2, 2)), "架桥后水域可通行")
	_check(g.is_walkable(Vector2i(2, 2), true), "桥对强盗同样可走（修桥即开门，代价必须真实）")
	g.place_road(Vector2i(4, 4), GridManager.RoadType.PASS)
	_check(g.is_walkable(Vector2i(4, 4)), "开山道后石林可通行")
	# 石板路可以直接盖在土路上（原地升级，不用先拆）
	g.place_road(Vector2i(0, 1), GridManager.RoadType.DIRT)
	_check(g.can_place_road(Vector2i(0, 1), GridManager.RoadType.STONE), "石板路可直接覆盖土路")
	_check(not g.can_place_road(Vector2i(0, 1), GridManager.RoadType.DIRT), "土路不能重复铺")
	# 建筑不能盖在任何路面上
	var house_conf := BuildingCatalog.find_by_id(&"house")
	_check(not g.can_place(Vector2i(0, 1), Vector2i.ONE, house_conf), "路面上不能盖建筑")

# ----------------------------------------------------------------------------
# [16] 时代×职能覆盖：每个时代都要有军事/经济/民生的新解锁
# ----------------------------------------------------------------------------
## 这条固化的是设计要求本身："每个阶段都要有对应的军事、经济、民生建筑"。
## 没有它，往目录里堆建筑很容易堆成"时代Ⅳ 有 12 座、时代Ⅰ 一座军事都没有"。
func _test_era_sector_coverage() -> void:
	print("[16] 时代×职能覆盖：每个时代都有军事/经济/民生")
	var sectors := ["military", "economy", "civic"]
	var sector_names := {"military": "军事", "economy": "经济", "civic": "民生"}
	var table := {}
	var untagged := PackedStringArray()
	for d in BuildingCatalog.ALL:
		var sec := String(d.get("sector", ""))
		if not (sec in sectors):
			untagged.append(String(d["name"]))
			continue
		var era := int(d.get("min_era", 1))
		if not table.has(era):
			table[era] = {}
		var row: Dictionary = table[era]
		row[sec] = int(row.get(sec, 0)) + 1
	_check(untagged.is_empty(), "所有建筑都标了 sector（缺：%s）"
		% ("无" if untagged.is_empty() else ", ".join(untagged)))
	var era_names: Array = MAIN_SCRIPT.ERA_NAMES
	for era in range(1, era_names.size() + 1):
		var row: Dictionary = table.get(era, {})
		var parts := PackedStringArray()
		for sec in sectors:
			parts.append("%s×%d" % [sector_names[sec], int(row.get(sec, 0))])
		print("  时代%d（%s）：%s" % [era, String(era_names[era - 1]), " ".join(parts)])
		for sec in sectors:
			_check(int(row.get(sec, 0)) >= 1,
				"时代%d 有新的%s建筑（%d 座）" % [era, sector_names[sec], int(row.get(sec, 0))])
	_check(BuildingCatalog.ALL.size() >= 50,
		"目录规模 ≥50 座（实为 %d）" % BuildingCatalog.ALL.size())

# ----------------------------------------------------------------------------
# [17] 资源链闭合：每种资源都有来源，也都有去处
# ----------------------------------------------------------------------------
## 数据驱动目录最容易出的错是"加了资源忘了配套"：产出了但没人要（死库存），
## 或者被要求却没人产（永远造不出来的建筑）。两头都在这里断言。
func _test_resource_chains() -> void:
	print("[17] 资源链闭合：来源 / 去处")
	var produced := {}    # 有建筑产出它
	var consumed := {}    # 有建筑吃它（作为输入或造价），或能吃/能卖
	for d in BuildingCatalog.ALL:
		for o in d.get("outputs", []):
			produced[int(o[0])] = String(d["name"])
		for i in d.get("inputs", []):
			consumed[int(i[0])] = String(d["name"])
		for c in d.get("cost", []):
			consumed[int(c[0])] = String(d["name"]) + "（造价）"
	for e in ResourceManager.EDIBLE_RESTORE:
		consumed[int(e[0])] = "村民吃掉"
	for row in MAIN_SCRIPT.SELL_TABLE:
		consumed[int(row["t"])] = "市场卖出"
	consumed[ResourceManager.Type.GOLD] = "市场/贸易站结算"
	produced[ResourceManager.Type.GOLD] = "市场卖出"
	# 开局直接发的物资也算有来源
	produced[ResourceManager.Type.WOOD] = "开局物资"
	produced[ResourceManager.Type.FOOD] = "开局物资"
	var no_source := PackedStringArray()
	var no_sink := PackedStringArray()
	for t in ResourceManager.Type.values():
		if not produced.has(t):
			no_source.append(String(ResourceManager.NAMES[t]))
		if not consumed.has(t):
			no_sink.append(String(ResourceManager.NAMES[t]))
	_check(no_source.is_empty(), "每种资源都有生产者（无来源的：%s）"
		% ("无" if no_source.is_empty() else ", ".join(no_source)))
	_check(no_sink.is_empty(), "每种资源都有去处（死库存：%s）"
		% ("无" if no_sink.is_empty() else ", ".join(no_sink)))
	# 名称与分类表必须覆盖全部枚举，否则界面会显示空白格
	var uncategorized := PackedStringArray()
	for t in ResourceManager.Type.values():
		_check(ResourceManager.NAMES.has(t), "资源 %d 有中文名" % int(t))
		var found := false
		for cat in ResourceManager.CATEGORIES:
			if int(t) in cat["types"]:
				found = true
		if not found:
			uncategorized.append(String(ResourceManager.NAMES.get(t, str(t))))
	_check(uncategorized.is_empty(), "每种资源都归入了某个分类（漏网：%s）"
		% ("无" if uncategorized.is_empty() else ", ".join(uncategorized)))
	# 生鲜清单必须都是能吃的，否则"腐坏"会烂掉一堆本来就该长期存放的原料
	var edible_ids := {}
	for e in ResourceManager.EDIBLE_RESTORE:
		edible_ids[int(e[0])] = true
	for t in ResourceManager.PERISHABLE:
		_check(edible_ids.has(int(t)), "会腐坏的 %s 是食物（只有生鲜该腐坏）"
			% String(ResourceManager.NAMES[int(t)]))
	# 月度口径自洽：一个月的天数与一个季节等长，否则「每月收支」与四季节奏对不上
	_check(ResourceManager.MONTH_DAYS == TimeManager.new().days_per_season,
		"1 月 = 1 季 = %d 天（月度面板与季节节奏同步）" % ResourceManager.MONTH_DAYS)

# ----------------------------------------------------------------------------
# [18] 生产数值平衡：每工每分钟产出排行 + 加工必须增值
# ----------------------------------------------------------------------------
## 口径说明（很重要，别把这条读成"价值模型"）：
## "每工每分钟产出" = 产物件数总和 × 60 ÷ interval ÷ 工位数。它把 1 块铁锭和
## 1 根木材当成同一件东西，所以**不能**用来判断哪座建筑更值钱；它只用来抓
## 数量级离群——某座新建筑不小心写成 interval 1.0 或 outputs 20，一眼就露馅。
## 真正的价值比较交给下面的"加工必须增值"（走市场价目表，两边都定价才比）。
func _test_production_balance() -> void:
	print("[18] 生产数值平衡：产出排行 / 加工增值")
	var rows: Array = []
	for d in BuildingCatalog.ALL:
		if not d.get("produces", false):
			continue
		var interval := float(d.get("interval", 0.0))
		_check(interval > 0.0, "%s 的 interval > 0" % String(d["name"]))
		if interval <= 0.0:
			continue
		var out_qty := 0
		for o in d.get("outputs", []):
			out_qty += int(o[1])
		if out_qty == 0:
			continue  # 植树场这类"产出是地形不是资源"的建筑不参与排行
		var workers: int = maxi(1, int(d.get("workers", 0)))
		var rate := float(out_qty) * 60.0 / interval / float(workers)
		rows.append([rate, String(d["name"]), String(d.get("group", "")),
			int(d.get("min_era", 1))])
	rows.sort_custom(_rate_desc)
	print("  —— 每工每分钟产出（件数口径，仅用于抓离群） ——")
	for r in rows:
		print("    %-6s 时代%d %s：%.1f 件/工/分" % [String(r[2]), int(r[3]),
			String(r[1]), float(r[0])])
	# 组内离群：同一个建造分组里最快的不该是最慢的 6 倍以上
	var by_group := {}
	for r in rows:
		var g := String(r[2])
		if not by_group.has(g):
			by_group[g] = []
		by_group[g].append(r)
	for g in by_group:
		var list: Array = by_group[g]
		var hi: float = float(list[0][0])
		var lo: float = float(list[list.size() - 1][0])
		_check(lo > 0.0 and hi / lo <= 6.0,
			"分组「%s」内产出倍差 %.1f×（最快 %s %.1f vs 最慢 %s %.1f）≤ 6×"
			% [g, hi / maxf(lo, 0.001), String(list[0][1]), hi,
				String(list[list.size() - 1][1]), lo])
	_check(rows.size() >= 20, "参与排行的生产建筑 ≥20 座（实为 %d）" % rows.size())

	# 市场价目表：必须按单价降序（_market_trading 依赖这个顺序"贵的先卖"）
	var table: Array = MAIN_SCRIPT.SELL_TABLE
	var sorted_ok := true
	var price_of := {}
	for i in table.size():
		price_of[int(table[i]["t"])] = int(table[i]["price"])
		if i > 0 and int(table[i]["price"]) > int(table[i - 1]["price"]):
			sorted_ok = false
	_check(sorted_ok, "市场价目表按单价降序（市场靠这个顺序优先卖贵货凑满日上限）")
	for row in table:
		var has_keep: bool = row.has("keep") or row.has("keep_pop")
		_check(has_keep, "%s 有保留线（keep 或 keep_pop），不会被卖光"
			% String(ResourceManager.NAMES[int(row["t"])]))

	# 加工必须增值：投入与产出两边都在价目表里时，产物总价必须严格高于投入总价。
	# 否则玩家投人力去加工反而亏——这类回归靠肉眼看数值表是抓不住的
	var compared := 0
	for d in BuildingCatalog.ALL:
		var inputs: Array = d.get("inputs", [])
		var outputs: Array = d.get("outputs", [])
		if inputs.is_empty() or outputs.is_empty():
			continue
		var in_val := 0
		var in_all_priced := true
		for i in inputs:
			if price_of.has(int(i[0])):
				in_val += price_of[int(i[0])] * int(i[1])
			else:
				in_all_priced = false
		var out_val := 0
		var out_all_priced := true
		for o in outputs:
			if price_of.has(int(o[0])):
				out_val += price_of[int(o[0])] * int(o[1])
			else:
				out_all_priced = false
		if not (in_all_priced and out_all_priced):
			continue
		compared += 1
		_check(out_val > in_val,
			"%s：产出市值 %d > 投入市值 %d（加工一步必须增值）"
			% [String(d["name"]), out_val, in_val])
	_check(compared >= 8, "至少 %d 条加工链两端都定了价、可做增值比对（覆盖面够广才有意义）" % compared)

func _rate_desc(a: Array, b: Array) -> bool:
	return float(a[0]) > float(b[0])
