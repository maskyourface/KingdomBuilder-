class_name RaidManager
extends Node

## 袭击调度：节奏、警告横幅、生成/撤退、抢劫登记与战后士气结算。
## 两种来袭共用这一整套机制，只在生成时按时代分叉：
##   时代Ⅱ~Ⅲ = 野狼（血薄、不拆墙、只叼食物、怕篝火）——把时代Ⅰ~Ⅲ 的"零风险挂机"填掉；
##   时代Ⅳ 起 = 强盗（原有行为）。
## 注意：为避免 class_name 循环依赖，main 和其他脚本引用本对象时一律不加类型标注。

signal raid_started(count: int)
signal raid_ended

const MOOD_VICTORY := 5            # 无人被抢：全体 +5
const MOOD_PER_PILLAGE := -10      # 每次成功抢劫 -10
const MOOD_CAP := -20              # 惩罚封顶
const MOOD_DAYS := 2               # 士气影响持续天数
const RAID_MIN_GAP := 6            # 强盗间隔 6~9 天
const RAID_MAX_GAP := 9
const WOLF_MIN_ERA := 2            # 野狼从时代Ⅱ 开始（时代Ⅰ 留给纯建设）
const BANDIT_MIN_ERA := 4          # 时代Ⅳ 起换成强盗
const WOLF_MIN_GAP := 5            # 狼来得更勤但更轻
const WOLF_MAX_GAP := 8
const WOLF_PER_POPULATION := 50    # 每 50 人口 +1 只狼
const WOLF_MAX_COUNT := 4
const WARN_TIME := 0.7             # 前一天傍晚（time_of_day≥0.7）警告
const PER_POPULATION := 60         # 每 60 人口 +1 名强盗
const RAID_MAX_DAYS := 4           # 单次袭击最长持续天数（保险丝，防 raid_active 永真）

var game = null            # Main（add_child 用）
var grid = null            # GridManager
var placer = null          # BuildingPlacer（拆除被毁建筑）
var buildings_root = null  # Node2D：建筑容器（main.buildings_root）
var villagers_root = null  # Node2D：村民容器
var resources: ResourceManager = null
var time: TimeManager = null
var rng := RandomNumberGenerator.new()

var enemies: Array = []        # 在场强盗（Enemy，不加类型）
var raid_active := false
var raid_pending := false      # 已到袭击日，等天亮再现身（避免深夜全员熟睡时开打）
var raid_started_day := -1     # 本次袭击开始的天数（超时保险丝用）
var raid_warned := false       # 已挂出警告横幅，明日清晨来袭
var banner_text := ""
var next_raid_day := -1        # -1 = 未排期（时代<2 或冬季）
var raid_kind: StringName = &"bandit"  # 本次来袭的种类（生成时按时代定；不入档——存档即撤退）
var pillage_count := 0         # 本次袭击成功抢劫次数

var raid_mood_bonus := 0       # 供 main._update_happiness 读取
var raid_mood_days_left := 0


func setup(p_game, p_grid, p_placer, p_buildings_root, p_villagers_root,
		p_resources: ResourceManager, p_time: TimeManager) -> void:
	game = p_game
	grid = p_grid
	placer = p_placer
	buildings_root = p_buildings_root
	villagers_root = p_villagers_root
	resources = p_resources
	time = p_time
	rng.randomize()


func has_market() -> bool:
	for b in buildings_root.get_children():
		if b.data.get("auto_sells", false):
			return true
	return false


## 每帧调用：到点挂警告横幅（时代≥4、已排期、非冬季、明天是袭击日、傍晚之后）。
## 本时代该来什么：Ⅱ~Ⅲ 野狼，Ⅳ 起强盗
func kind_for_era(era: int) -> StringName:
	return &"bandit" if era >= BANDIT_MIN_ERA else &"wolf"

func _gap_for_era(era: int) -> int:
	if era >= BANDIT_MIN_ERA:
		return rng.randi_range(RAID_MIN_GAP, RAID_MAX_GAP)
	return rng.randi_range(WOLF_MIN_GAP, WOLF_MAX_GAP)

func tick(era: int) -> void:
	if raid_active or era < WOLF_MIN_ERA:
		return
	if time.is_winter():
		return
	# 到了袭击日：等天亮（村民/箭塔苏醒）再现身，不在深夜偷家
	if raid_pending:
		if not time.is_night():
			raid_pending = false
			_spawn_raid(era)
		return
	if raid_warned or next_raid_day < 0:
		return
	if time.day == next_raid_day - 1 and time.time_of_day >= WARN_TIME:
		raid_warned = true
		if kind_for_era(era) == &"wolf":
			banner_text = "山里传来狼嚎，明日恐有狼群下山——把食物产线用篝火照起来！"
		else:
			banner_text = "有探子来报：一伙强盗在附近出没，明日清晨可能来袭！"


## 每个新的一天调用（接 main._on_new_day）：士气衰减 + 排期 + 清晨生成。
func on_new_day(era: int) -> void:
	if raid_mood_days_left > 0:
		raid_mood_days_left -= 1
		if raid_mood_days_left <= 0:
			raid_mood_bonus = 0
	# 保险丝：袭击拖太久（强盗被意外卡死）就强制结算，防止 raid_active 永真。
	# 删除前先 set_process(false)：queue_free 到帧末才真正移除节点，
	# 延迟期间强盗还会跑 _process，可能同帧完成抢劫登记（幽灵结算）
	if raid_active and raid_started_day >= 0 and time.day - raid_started_day >= RAID_MAX_DAYS:
		for e in enemies.duplicate():
			if is_instance_valid(e):
				e.set_process(false)
				e.queue_free()
		enemies.clear()
		_settle_and_end()
	if raid_active:
		return
	if era < WOLF_MIN_ERA:
		# 时代跌回Ⅰ：取消待出动与预警，避免恢复后无预警突袭
		raid_pending = false
		raid_warned = false
		banner_text = ""
		return
	if time.is_winter():
		# 冬季休战：不排期，已排期/待出动的顺延到开春再重新随机
		next_raid_day = -1
		raid_pending = false
		raid_warned = false
		banner_text = ""  # 清掉过期预警，别让横幅挂一整个冬天
		return
	if raid_pending:
		return  # 等黎明 tick 现身
	var day: int = time.day
	if next_raid_day < 0:
		next_raid_day = day + _gap_for_era(era)
		return
	if day >= next_raid_day:
		raid_pending = true
		next_raid_day = day + _gap_for_era(era)
		raid_warned = false


func living_count() -> int:
	return enemies.size()


func find_nearest_wall(from: Vector2):
	var best = null
	var best_d := 1e30
	for b in buildings_root.get_children():
		if b.hp <= 0:  # 已被拆毁的墙不再作为目标（普通建筑 hp=-1 会被下一行过滤）
			continue
		if not (b.data.get("is_wall", false) or b.data.get("is_gate", false)):
			continue
		var d := from.distance_to(b.world_pos())
		if d < best_d:
			best_d = d
			best = b
	return best


func destroy_building(b) -> void:
	if placer != null:
		placer.destroy_building(b)


func register_pillage() -> void:
	pillage_count += 1


func on_enemy_died(e) -> void:
	enemies.erase(e)
	_check_end()


func on_enemy_left(e) -> void:
	enemies.erase(e)
	_check_end()


## 存档时若袭击进行中：强盗即刻撤退，不带士气结算（视为悬念留到下回）。
## 存档/读档/返回主菜单时调用；不走士气结算（悬念留到下回）。
func retreat() -> void:
	if not raid_active:
		return
	for e in enemies.duplicate():
		if is_instance_valid(e):
			e.set_process(false)  # 挡住 queue_free 延迟期内的最后一次抢劫/拆墙
			e.queue_free()
	enemies.clear()
	raid_active = false
	raid_warned = false
	banner_text = ""


func _spawn_raid(era: int) -> void:
	raid_kind = kind_for_era(era)
	var pop: int = villagers_root.get_child_count()
	var count: int
	if raid_kind == &"wolf":
		count = mini(1 + pop / WOLF_PER_POPULATION, WOLF_MAX_COUNT)
	else:
		count = 2 + pop / PER_POPULATION
	count = maxi(count, 1)
	for i in count:
		var e := Enemy.new()
		game.add_child(e)
		# 注意参数顺序：Enemy.setup(grid, resources, raid, start_cell, kind)
		e.setup(grid, resources, self, grid.random_edge_cell(true), raid_kind)
		enemies.append(e)
	raid_active = true
	raid_started_day = time.day
	pillage_count = 0
	if raid_kind == &"wolf":
		banner_text = "狼群下山了！它们盯上了村里的食物"
	else:
		banner_text = "强盗来袭！保护你的村民和物资！"
	raid_started.emit(count)


func _check_end() -> void:
	if not raid_active or not enemies.is_empty():
		return
	_settle_and_end()


## 结算士气并结束袭击（正常打完与超时保险丝共用）
func _settle_and_end() -> void:
	raid_active = false
	banner_text = ""
	if game != null and game.hud != null:
		var who := "狼群" if raid_kind == &"wolf" else "强盗"
		if pillage_count == 0:
			game.hud.show_toast("%s 无功而返！村民士气大振（幸福 +%d，持续 %d 天）"
				% [who, MOOD_VICTORY, MOOD_DAYS], 6.0)
		else:
			var mood := maxi(MOOD_PER_PILLAGE * pillage_count, MOOD_CAP)
			game.hud.show_toast("%s 叼走/抢走了 %d 批物资（幸福 %d，持续 %d 天）"
				% [who, pillage_count, mood, MOOD_DAYS], 6.0)
	if pillage_count == 0:
		raid_mood_bonus = MOOD_VICTORY
	else:
		raid_mood_bonus = maxi(MOOD_PER_PILLAGE * pillage_count, MOOD_CAP)
	raid_mood_days_left = MOOD_DAYS
	pillage_count = 0
	raid_ended.emit()
