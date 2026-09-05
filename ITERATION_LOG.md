# KingdomBuilder 迭代日志

目标：5 轮迭代。每轮并发 5 个 subagent 同时执行「debug 代码 / 逻辑性 / 游戏性 / 持续性 / 静态验证」分析，
随后由主控汇总修复并验证。本文件记录每轮的发现、修复与验证结论。

## 项目概况（基线 v0）

- Godot 4.7 GDScript 2.0，2D 王国建设原型：村民 AI、生产链、时代 1~5、幸福度日结、四季、
  袭击（强盗/城墙/箭塔/卫兵）、市场金币、存档 v4（JSON）。
- 本机无 Godot 可执行文件 → 验证手段 = 静态检查（tools/static_check.py）+ 人工核对。
- 代码规模：scripts/ 13 个文件。

## 迭代 0（主控预读）已知可疑点（待 subagent 核实）

| # | 位置 | 问题 | 预判 |
|---|------|------|------|
| K1 | main.gd:80 vs hud.gd:45 | `hud.setup(...)` 传 6 参，HUD.setup 只收 5 参 → 启动即运行时错误，_ready 中断（无镜头/村民/菜单） | P0 |
| K2 | raid_manager.gd:64,82 | `time.total_days` 属性不存在（TimeManager 只有 `day`）→ 每日结算报错，袭击永不排期 | P0 |
| K3 | raid_manager.gd:147 | `e.setup(grid, resources, cell, self)` 与 `Enemy.setup(grid, resources, raid, start_cell)` 参数错位 → 生成强盗即报错 | P0 |
| K4 | raid_manager.gd:53 | `b.placed` 属性不存在（Building 无 placed 字段）→ has_market() 报错 | P1 |
| K5 | raid_manager.gd | `banner_text` 从未在 HUD 显示 → 袭击预警对玩家不可见 | P1 |
| K6 | main.gd / main_menu.gd | 菜单打开时 get_tree().paused=true，main 被暂停 → ESC 关闭菜单的分支永不执行 | P2 |
| K7 | building.gd:81 | 生产完成时忽略 `try_spend` 返回值（理论上有重复产出风险） | P2 |
| K8 | main.gd load_game | 坏档字段 `bd["origin"]`/`vd["cell"]` 直接下标访问，损坏存档会报错 | P2 |
| K9 | README.md | 文档停留在 v2 时代（实际已 v4：袭击/衣服/啤酒/市场/城堡） | P2 |
| K10 | saves/autosave.json | 旧版无 version 存档会被正确拒载（行为正确，但列表中显示为可读档） | P2 |

---

## 迭代 1（已完成）

### 5 个并发 subagent 分析结论
> 平台并发限制实际排队执行，但 5 个 agent 均按同一批次任务分发并全部交付。

1. **debug 崩溃分析**：确认 5 处 P0 编译/启动错误——①main.gd:80 `hud.setup` 6参vs5参；②main.gd:287 调用不存在的 `hud.show_coronation()`；③④raid_manager.gd:64/:82 `time.total_days` 幽灵属性；⑤raid_manager.gd:147 `Enemy.setup` 参数错位。另确认 P1：raid_manager.gd:53/:100 访问不存在的 `b.placed`（抢劫/攻城必崩）；P2：load_game 坏档直下标、暂停时 ESC 失效。核实 building.gd 忽略 try_spend 返回值为良性（同帧无插队）。
2. **逻辑性分析**：村民状态机闭合；但 ①FLEEING/FIGHTING 无进食出口→袭击期间"满仓饿死"；②`_try_siege` 设 ATTACK 却不走路→隔空拆墙；③袭击在深夜(≈0.0)生成→村民熟睡、箭塔无人、防御真空；④raid_active 永真后果链（无超时保险丝）；⑤经济数值测算：面包链一条喂 49 人，产能过剩、饥饿压力装饰化，冬季压力不足为惧；⑥存档缺 `resources.happiness`；⑦open_load_menu 不先 autosave；⑧读档同人数时村民列表按钮悬空。
3. **游戏性分析**：①顶栏单行在 1280×720 需约 1900px→保存/读取/建造按钮出屏；②建造菜单 20 条目 2 列无滚动→兵营/城堡被裁掉；③`banner_text` 无任何 UI 渲染、raid 信号无人连接→袭击玩法对玩家 100% 不可见；④时代升级/村民离开/饿死/停工原因/市场战报全部无反馈；⑤幸福度<40 无预警；开局死亡螺旋数值克制但零提示；⑥无"距冬季 N 天"提示；⑦右键秒拆无确认。
4. **持续性分析**：确认项目当前不可运行；唯一硬死局=全员饿死+0木+无伐木场（待后续迭代加兜底）；市场保留线锁死金币经济、酒馆 serves=8 在大人口下娱乐不可达标（后续迭代）；读档非原子+写档无 tmp+rename、autosave 单槽（后续迭代）；find_path O(V²)+全图闲逛寻路是 250 人口首要瓶颈（后续迭代）；README 与 v4 实现大面积脱节（后续迭代）；setup 位置参数网（Villager raid 末位 vs Enemy 第3位）是 K3 根因。
5. **静态验证**：交付 `tools/static_check.py`（调用契约/幽灵属性/目录键/存档对称性四类检查），确认上述 P0/P1，并证实 catalog 键与存档键对称、无其他幽灵属性；记录 6 类误报修正如实写档。

### 修复清单（全部已实施）
| # | 修复 | 文件 |
|---|------|------|
| 1 | HUD.setup 增加第 6 参 `p_raid` 并保存（与调用方一致） | hud.gd |
| 2 | 实现 `show_coronation()`（加冕 toast） | hud.gd |
| 3 | `time.total_days`→`time.day`（2 处） | raid_manager.gd |
| 4 | `e.setup(grid, resources, self, cell)` 参数顺序修正+注释 | raid_manager.gd |
| 5 | 删除两处 `b.placed` 幽灵访问（has_market/find_nearest_wall） | raid_manager.gd |
| 6 | 袭击改为"白天现身"：on_new_day 只置 `raid_pending`，tick 等非夜间 `_spawn_raid`，消除防御真空 | raid_manager.gd |
| 7 | 超时保险丝：`RAID_MAX_DAYS=4`，超时强制结算士气，防 raid_active 永真 | raid_manager.gd |
| 8 | `_settle_and_end` 统一结算并通过 `game.hud.show_toast` 播报战果 | raid_manager.gd |
| 9 | `_try_siege` 保持 SEEK 行军到位再拆 + `_attack_building` 增加近战距离校验（杜绝隔空拆墙） | enemy.gd |
| 10 | FLEEING/FIGHTING 饥饿进食出口；RESTING 夜袭唤醒（平民逃/卫兵战）；MOVING 途中威胁感知；卫兵迎战决策提到昼夜判断之前 | villager.gd |
| 11 | `died(villager, reason)` 信号 + `_die(reason)`：饿死/战死/离开区分，main 连接后 toast 播报（读档恢复的村民同样接线） | villager.gd / main.gd |
| 12 | 顶栏改两行（状态+按钮 / 资源），修复 720p 按钮出屏 | hud.gd |
| 13 | 建造菜单包 ScrollContainer（272×400），20 条目全部可达 | hud.gd |
| 14 | 袭击横幅常驻渲染（读 raid.banner_text）+ toast 系统（时代升级/袭击战果/村民离开） | hud.gd |
| 15 | 幸福度<40 顶栏红色预警；时间栏"距冬季N天/冬季中"提示（新增 `days_until_winter()`） | hud.gd / time_manager.gd |
| 16 | 详情面板新增停工原因行（缺原料/缺工人/冬季）与市场昨日成交行 | hud.gd |
| 17 | 菜单打开时（暂停态）ESC 由 MainMenu 处理：子面板退回/返回游戏 | main_menu.gd |
| 18 | 读档结构预校验（buildings/villagers 非数组即拒）+ origin/cell 防御式解析，销毁世界前剔除坏条目 | main.gd |
| 19 | 存档补 `happiness`/`raid_pending`/`raid_started_day`，读档恢复（.get 默认值，兼容旧 v4 档） | main.gd |
| 20 | `open_load_menu` 读取前先 autosave，防误触回滚 | main.gd |
| 21 | `hud.invalidate_villager_list()`：新游戏/读档后强制重建村民列表按钮 | hud.gd / main.gd |
| 22 | 市场卖出循环防御式 `prices.get/reserves.get`（价格≤0 跳过，杜绝除零） | main.gd |
| 23 | hud.gd/main_menu.gd 的 `main` 由 `Node2D` 改无类型引用（消除对脚本方法调用 `current_era()` 等的静态分析编译风险，与 raid 注入同一模式） | hud.gd / main_menu.gd |

### 验证结论
- `python tools/static_check.py`：ERROR=0 / WARN=0；调用契约、幽灵属性、catalog 键（30/30 一致）、存档对称性（顶层 21 键、buildings 5 键、villagers 12 键两侧一致，含本轮新增 3 键）全部通过。
- 人工复查：villager.gd 状态机闭环（FLEEING/FIGHTING 有进食与退出出口）；raid 流程 pending→黎明 spawn→结算/超时保险丝闭合；hud 新增 UI 引用均有初始化；menu_test/smoke_test 调用面兼容。
- 遗留（转入后续迭代）：读档原子性(tmp+rename+.bak)、v3 旧档迁移与列表标注、find_path O(V²) 与全图闲逛、开局死亡螺旋引导、右键误拆确认、市场保留线锁金币、酒馆 serves 大人口不可达、README 与 v4 脱节、整数除法告警（良性）。

---

## 迭代 2（已完成）

### 分析（5 个 subagent：debug 回归 / 逻辑 / 游戏性 / 持续性(重发) / 静态验证升级）
> 持续性 agent 两次被平台取消，其要点（性能排序、存档原子性、死局兜底）已并入修复与迭代3任务。

1. **debug 回归**：迭代1的23项修复全部核对通过；但发现修复#9 引入 P1 回归——`_leave_tick` 的 `state != State.ATTACK` 判断失效，"拆墙突围"成死代码（得手强盗被围时原地凭空消失）；`get_save_list` 对"合法 JSON 但非对象"的坏档不设防（启动即砖）；raid_warned 在 new_game/load_game 泄漏；冬季/时代回退不清 banner；ESC 未滤 echo；袭击中打开读取面板=白嫖撤退。
2. **逻辑**：核心发现——村民只在白天 WORKING、建筑无在岗者停产 → 全局有效产能≈名义值 50%（目录 interval 按 24h 连续开工口径写，纺织坊平衡点实为 34 人而非 100 人）；教堂/酒馆/市场的 workers 是装饰（光环与 auto_sells 不检查在岗）；单箭塔 5 发×10=50<60HP 杀不死路过强盗；移民闸无天数模型且冬季不停；入伍即满血=免费医疗；酒馆名额树序垄断；reassign_homes 不迁移但补位跨图。
3. **游戏性**：0→250 人口约 730 次点按；推荐"空闲计数+放置自动招1+一键招满"三件套（已实施）；右键秒拆无确认+详情面板关闭/拆除相邻（已实施两段确认）；开局 42 秒假幸福度 50（已实施立即结算）；toast 单槽互相覆盖（已实施 3 条队列）；建议倍速/夜间加速（部分通过 is_night 窗口 0.22~0.78→0.15~0.85 实现，工作窗 56%→70%）。
4. **静态验证**：工具升级——[E] 信号契约（8 信号/16 emit/22 connect 全过）、[F] 语法粗检、对象映射补全 game→Main、注入式自测证明检测器有效；当前代码 ERROR=0。人工确认 enemy.gd 回归（P1）与两个 P2（死信号 raid_started/ended、v3 幽灵档展示——后者本轮已修）。

### 修复清单（4 个文件分区并行的实施 agent + 主控补刀，全部已实施）
| # | 修复 | 文件 |
|---|------|------|
| 1 | `_leave_tick` 条件 `!= ATTACK`→`== LEAVE`，恢复拆墙突围（P1 回归） | enemy.gd |
| 2 | 冬季/时代<4 早退分支清理 `raid_pending/raid_warned/banner_text` | raid_manager.gd |
| 3 | 超时保险丝 queue_free 前 `set_process(false)`（防幽灵抢劫结算） | raid_manager.gd |
| 4 | `get_save_list` 非 Dictionary 坏档跳过 + 列表带 version 字段；`autosave.bak.json` 不入列表 | main.gd |
| 5 | `open_load_menu` 袭击中不触发自动存档（堵"读档面板=无敌开关"） | main.gd |
| 6 | 存档原子写（.tmp→rename）+ autosave 覆盖前留 `autosave.bak.json` | main.gd |
| 7 | new_game/load_game 重置 `raid_warned`；new_game 后立即 `_update_happiness()`（消灭开局假 50） | main.gd |
| 8 | load_game：条目非 Dictionary 跳过；建筑 footprint 越界校验（防 occupy_area 越界写） | main.gd |
| 9 | 移民闸：冬季需求×2 + `maxi(need,4)` 下限（消灭 0 人口移民循环饿死） | main.gd |
| 10 | 幸福<40 离队者优先级：无房者→幸福最低者，卫兵最后（`_pick_leaving_villager`） | main.gd |
| 11 | 移民落点改为随机住房门口（不再全图随机） | main.gd |
| 12 | 断饷退役 toast 播报；教堂/酒馆/市场工人在岗门控（workers 不再是装饰）；酒馆名额 shuffle 轮转；入伍不再免费满血；空闲分配就近挑选 | main.gd |
| 13 | `assign_all_workers()` 一键招满（跳过兵营）+ 放置建筑自动招 1 人 | main.gd / hud.gd |
| 14 | 顶栏「人口/空闲/无房」计数 + 无房时目标行覆盖"⚠ 先建小屋安置村民" + 一键招满按钮 | hud.gd |
| 15 | toast 3 条堆叠队列（逐条倒计时，超限挤掉最旧） | hud.gd |
| 16 | `invalidate_villager_list` 同时重置 `_last_era`（防读档后假时代 toast） | hud.gd |
| 17 | 存档列表：版本不兼容档灰显禁读；ESC 长按 echo 防抖（main+menu 两处） | main_menu.gd / main.gd |
| 18 | is_night 窗口 0.22~0.78→0.15~0.85（工作窗 56%→70%，夜间等待缩短） | time_manager.gd |
| 19 | 箭塔伤害 10→12（5发×12=60 恰杀 60HP 强盗，单塔可击杀） | building_catalog.gd |
| 20 | 拆兵营工人当场退役；右键拆除改两段确认（首按红框高亮、再按同格真拆）；右键拖动连续拆路 | building_placer.gd |
| 21 | `random_walkable_cell_near()`：闲逛限身边 10 格（砍跨图 O(V²) 寻路） | grid_manager.gd / villager.gd |

### 测试结论
- `python tools/static_check.py`：ERROR=0；6 条 WARN 经人工核对全为类型推断误报（`mouse_cell := Vector2i.ZERO` 初始化、枚举循环变量）。
- 主控复核：酒馆块缩进归位正确、assign_all_workers 依赖闭环（hud 按钮↔main 方法均已落地）、toast 队列/倒计时正确、raid 清理链完整、enemy 撤退分支闭合；发现并修复实施遗漏 1 处（.bak 混入存档列表）。
- 遗留（转入迭代3）：金币经济与保留线深度（市场保留线 pop*2 与移民囤粮线同值→高价商品卖不出）、酒馆 serves=8 大人口娱乐不可达、村民列表筛选/排序、倍速控制、失败覆灭面板、A* 数据结构升级、每帧重绘节流、README 与 v4 脱节、dead signals raid_started/ended。

---

## 迭代 3（已完成）

### 分析（4 个方向 agent + 2 个补位 + 1 个经济模拟测试；中途多次平台限流/验证失败，按"结束即补位"规则补齐）
1. **debug 回归**：再抓 2 个 P0——①实施 agent 在 `_remove_building` 留下多一档缩进（解析失败无法启动）；②`reassign_homes` 结构错位（`for b` 嵌进 `for v` + 分房四行落在 while 体外→死循环或"全员住进伐木场"）。P1：午夜结算时 `_count_present_workers()==0` 恒真→教堂/酒馆/市场瘫痪、金币断流（我方设计缺陷）。P2×8：pending_demolish 陈旧态/单格高亮、拆路逐格全量重分配、存档写盘错误未校验、retreat 幽灵抢劫、读档 day/time_of_day 数值域、横幅/toast 吞点击、离队者计数偏移（良性备案）。
2. **持续性/性能**：定稿 A* 方案=二叉堆+懒惰删除（单条长路径 60~300ms→5~15ms；AStarGrid2D 列二阶段、失败缓存不做）； villager/enemy 无条件 queue_redraw ≈3~5ms/帧→条件化；grid 全图重绘触发点清单与烘焙方案；reassign_homes 读档最坏 100~300ms 一次性尖峰（P3 缓存方案）；autosave.bak 只写不读；README 修订提纲；10 条回归检查点。
3. **游戏性**：0→250 剩余 ~300 次点按；「建造菜单保持打开」+「小屋 drag_place」为最大收益（→~180 次）；倍速推荐手动 Space 1×/2×/4×（无 Timer/音效风险，夜间自动加速否决）；村民列表筛选排序；市场补可见性不做开关；覆灭面板触发条件（pop=0 且木<5 且 [无房或存粮<4]，连续 2 天+非袭击中）；时代目标行进度数字；新手 4 步引导队列。
4. **逻辑（补位）**：产能表重算（有效工作窗 42s）——工位占人口 28~34%，瓶颈=操作量与 3人/天移民上限（82 分钟下限）而非产能；**一键招满树序错配**（磨坊满员麦田缺编→面包链归零）；worked_today 不入档→读档后首次日结福利建筑必失效；**面包保留线=移民囤粮线→卖货压移民**；**石料节奏陷阱**（磨坊5石先抢完→面包房10石永远攒不齐，模拟复现）；多市场共享保留线≈无效；1酿酒最多养2酒馆（第3家必缺酒）；serves 缩放公式（×2^(era-3)）；时代Ⅴ金币真空（建议贸易站）。
5. **经济模拟测试（交付工具）**：tools/economy_sim.py（源码公式复刻、0.5s 子步）+ tools/economy_sim_report.txt（3 策略×60 天）+ tests/logic_test.gd（30+ 断言，待有 Godot 机器执行）。结论：正常玩法无必然饿死；D0 对照组（不建食物）第 11 天灭局复现；唯一硬软锁=无木收入且木<8；石料争抢陷阱实锤。

### 修复清单（主控实施，全部已落地）
| # | 修复 | 文件 |
|---|------|------|
| 1 | P0：`_remove_building` 缩进归位 | building_placer.gd |
| 2 | P0：`reassign_homes` 结构重写（for b 出嵌套、分房四行入 while） | main.gd |
| 3 | P0：`handle_input` 按下处理死代码缩进修复（放置/拆除/查看全部恢复） | building_placer.gd |
| 4 | P1：`worked_today` 出勤门控（白天记出勤→午夜日结消费→日结末复位），替代"结算时点在岗数" | building.gd / main.gd |
| 5 | P2：拆除确认改为按建筑 origin（多格 footprint 高亮）、点空地/目标消失清 pending | building_placer.gd |
| 6 | P2：拆路统一不发 demolished；铺路(土路)不再触发全量重分配 | building_placer.gd / main.gd |
| 7 | P2：存档写盘错误校验（截断档不顶替旧档）；retreat 前 set_process(false)；读档 day/time_of_day 钳制 | main.gd / raid_manager.gd |
| 8 | P2：横幅/toast mouse_filter=IGNORE（不再吞地图点击） | hud.gd |
| 9 | 性能：A* 二叉堆+懒惰删除（语义不变） | grid_manager.gd |
| 10 | 性能：villager/enemy 重绘签名节流（状态/饥饿档/血条档变化+8Hz 脉冲） | villager.gd / enemy.gd |
| 11 | 性能：HUD 每帧只做横幅+toast；人口统计/目标行/幸福度/时间字符串下沉 0.5s 低频块并缓存 | hud.gd |
| 12 | 逻辑：一键招满按产业链优先级轮转补人（食物链→下游→福利→塔） | main.gd |
| 13 | 逻辑：worked_today 入档/恢复；面包保留线 pop×2→pop（与移民囤粮线脱钩）；面包房石料 10→6 | main.gd / building_catalog.gd |
| 14 | 玩法：Space 1×/2×/4× 倍速（toast 提示，菜单/读档/新游戏复位 1×，时间栏显示倍速徽标）；建造菜单保持打开；小屋 drag_place 拖动连放 | main.gd / hud.gd / building_catalog.gd |

### 测试结论
- static_check：ERROR=0；WARN=7 全为已知误报族（成员初始化字面量/局部类型收集无作用域）。
- 主控复核：reassign_homes 字节级缩进验证 ✓；handle_input 死代码复活 ✓；A* 堆语义与 [to]/懒惰删除边界 ✓；worked_today 生命周期（记→用→复位→入档）闭环 ✓。
- 遗留（转入迭代4）：时代目标进度数字、新手引导队列、覆灭面板、村民列表筛选/排序、市场可见性行、贸易站（金币×石料双解）、serves 缩放、v3 迁移/autosave.bak 恢复入口、README 重写、save_manager 拆分、reassign_homes 无房者缓存、grid 地形烘焙。

---

## 迭代 4（已完成）

### 分析（debug 回归 / 逻辑 / 持续性·文档 / 游戏性补位 + 模拟同步 + README 重写 + 单测增补；期间按"结束即补位"维持 4 并发）
1. **debug 回归**：A* 堆/重绘签名/HUD 低频重构/一键招满/worked_today 生命周期逐项 ✔；抓到 **P1×2**：①×N 倍速徽标不随 Space 刷新且降档残留；②HUD 按钮（FOCUS_ALL）吃掉 Space=ui_accept——焦点在「保存」上按空格会连发时间戳存档。P2×4：resources.changed 风暴、市场停工日 last_sale 残留、toast 计时随倍速加速、时代降级误弹 toast。另：7 条 WARN 复核仍全为误报。
2. **逻辑**：用补丁副本量化迭代3改动（标准策略人口 118→127、D25 石料 ×3，中性偏正）；**建议采纳**：时代Ⅳ第4移民/天（加冕 ~104→~87 分钟）、serves ×2^(era-3) 且捆绑部分服务（省 24 工位）、贸易站 auto_buys（金币×石料双解，务必不给 auto_sells 以免扩大袭击打击面）；economy_sim 三处公式未同步（已由同步 agent 修复重跑：无新失败模式，D0 灭局仍仅由"完全不建食物"触发）。
3. **持续性/文档**：README 重写提纲（已交付落地）；save_manager 拆分定稿（facade 模式 + [D]/logic_test 重定向护栏，暂存迭代5）；v3 迁移决策=**不做**（保持拒绝+灰显）；autosave.bak 恢复入口方案（迭代5）；grid 烘焙=**不做**（收益窗口仅拖路，RoadLayer 备查）；测试补强清单；11 条回归检查点（核心：[D]/logic_test 对 main.gd 的硬编码指向在拆分时会假绿）。
4. **游戏性（补位）**：抓到 **P0**——我方改 `_refresh_villager_list` 时引入的缩进断裂（连续第三轮同族缩进事故）；贸易站石料购买量被单价二次整除（实际购买减半）；读档冬季档误弹"冬季来临"；点按量复评 ~200-240 次、下一步杠杆=麦田/水井拖放；720p 顶栏最坏 1330px 溢出→方案 A（间距 10 + 招满按钮短文案 + 造价单字缩写）；进度数字/引导队列/覆灭面板/列表筛选的实现步骤。
5. **模拟同步 agent**：economy_sim.py 同步 8 项公式（S1~S8）重跑——3 策略终人口 135/127/64，贸易站 60 天内未建成（时代Ⅴ到点 ≈D91+，属移民闸决定非金币问题）；无新灭局/软锁。
6. **README agent**：全文重写 230 行、9 章、21 建筑表；全部数值对照源码核实；已按代码事实删除旧取舍（金币未启用/A*线性）。
7. **单测 agent**：logic_test.gd 337→514 行，新增 [5] A* 等价性 17 断言（修正任务书 size 16→19 的数学错误并给出推导）、[6] 招满优先级 8 断言（静态护栏+场景装配未降级）；预期 PASS=83/FAIL=0（待实机 Godot）。

### 修复清单（主控实施，全部已落地）
| # | 修复 | 文件 |
|---|------|------|
| 1 | P0：hud.gd `_refresh_villager_list` 缩进归位（本轮唯一 P0，引入于本轮编辑、当轮即被补位 agent 抓住） | hud.gd |
| 2 | P1：HUD 全部按钮 focus_mode=FOCUS_NONE（Space 不再被焦点按钮吞掉/误发存档）；列表按钮同步 | hud.gd |
| 3 | P1：×N 徽标纳入时间行重建条件（Space 即时刷新/降档消除） | hud.gd |
| 4 | P2：resources.changed→脏标记，每帧最多重建一次资源栏 | hud.gd |
| 5 | P2：市场/贸易站停工日 last_sale 清零（详情面板不挂旧战报） | main.gd |
| 6 | P2：toast 倒计时改真实时间（×4 下提示不闪没） | hud.gd |
| 7 | P3：时代降级不再弹升级 toast；"时代村庄解锁"文案修正；ESC 清 pending 红框 | hud.gd / main.gd |
| 8 | P2：贸易站石料购买量 `mini(budget/price, affordable)`（修正减半 bug）；金币保底 50 常量化 | main.gd |
| 9 | 设计：时代Ⅳ第 4 移民/天；酒馆 serve_cap=8/16/32+部分服务（served≤啤酒×2）；袭击日福利缺席不叠罚；箭塔补刀优先（射程内血量最低）；入冬 toast+读档/新游戏 `_last_season` 复位 | main.gd / building.gd |
| 10 | 新系统：贸易站（时代Ⅴ，workers2，收石2金≤10/天、木1金≤20/天、单站≤40金/天）+ ASSIGN_PRIORITY 纳入 + 详情面板"昨日收购"行 | building_catalog.gd / main.gd / hud.gd |
| 11 | 玩法：时代目标行进度数字（人口 x/N、有衣、教堂/酒馆、卫兵/箭塔、木/石/金、已加冕）+ 顶栏方案 A（间距10/「招满」/造价单字） | main.gd / hud.gd |
| 12 | 工具：static_check [F] 新增"块语句后缺少更深缩进体（空块/缩进断裂）"规则，注入自证命中（终结连续三轮的缩进 P0 盲区） | tools/static_check.py |
| 13 | 文档：README.md 全文重写（v4 口径）；删除过期"无法启动"警告（P0 已修） | README.md |
| 14 | 测试：logic_test.gd +25 断言（A* 等价性/招满优先级/静态护栏），预期 83 PASS | tests/logic_test.gd |

### 测试结论
- static_check：ERROR=0（含新空块规则）；WARN=7 已知误报族。
- 主控复核：hud 缩进修复字节级验证；贸易站金额口径（budget=金、affordable=件数）核验；进度数字在 720p 的宽度按方案 A 收敛；README 关键数值抽查与源码一致。
- 遗留（转入迭代5）：新手引导队列、覆灭面板、村民列表筛选/排序、市场保留线说明行、麦田/水井 drag_place、拖放资源不足提示、save_manager 拆分（含 [D]/logic_test 重定向）、autosave.bak 恢复入口、袭击期 4× 寻路尖峰观察。
---

## 基线固化：可正常使用的实例（迭代 4 后、迭代 5 前）

用户指令：**优先保证一个可正常使用的实例，之后在该实例上修改**。已完成：

1. **获取 Godot 4.4.1 便携版**（tools/godot_portable/，GitHub Releases 下载）——项目首次具备实机验证能力。
2. **实机验证结果（全部通过，零 stderr 错误）**：
   - `--import` 全量脚本解析：零错误零警告；**并当场抓到并修复 1 个静态工具盲区 P0**
     （main.gd `var before := b.workers.size()` 无类型推断解析错误→main.gd 加载失败；改为显式 `: int`）。
   - tests/smoke_test.gd：启动→建造→派工→存档→读档→180 帧全过（v3 旧档被正确拒载并提示）。
   - tests/menu_test.gd：菜单/暂停状态机全过。
   - **tests/play_test.gd（新增，真实开局模拟）**：new_game 后 720 帧真实运转——开局真实幸福度 20（假 50 修复生效）、
     放置自动招 1 人生效、村民 AI 真实运转、跨午夜日结触发"幸福度过低离开"（软失败机制实机复现）、存读档回环成功。
   - tests/logic_test.gd：PASS=83/FAIL=0（修复测试自身 2 处：类型推断解析错误、存档键提取正则误把
     `hb.data.get` 当存档键——加负向后顾）。
3. **一键门禁 tools/run_gate.py（9 项）**：static_check + 自写块结构解析器 + 括号配平 + 关键文件 +
   主场景指向 + ext_resource + 存档对称性 + 目录干净性 + **Godot 实机 4 套件**。当前判定 **GO**。
   用法：`python tools/run_gate.py`（每轮修改前后必跑）。
4. **稳定基线快照 `_releases/stable-iter4-verified/`**（含 .gdignore 不影响主工程）：
   实机验证通过的完整代码副本 + SNAPSHOT.md（用途/回滚方法/验证记录）。主工程后续若坏，
   把快照内容复制回根目录即可回滚。



---

## 迭代 5（已完成 · 用户定向需求：前期循环 / 地形分区画质 / 采集机制 / 工作区域 / 建筑作用 / 土路 / 就近居住）

### 分析（4 agent：debug 回归 / 逻辑 / 游戏性 / 持续性，全部交付）
1. **debug**：类型推断专项——全项目 `:=` 面核对干净（与实机 import 零错误互证）；抓 4 个 P2：
   ①袭击日豁免在午夜结算时 raid_active 已为 false→基本不生效；②无存档开局路径绕过假幸福度修复；
   ③坏档 id 非字符串时 StringName 直转报错且世界已销毁；④时代跌破Ⅲ酒馆继续白扣啤酒。
2. **逻辑**：纠正豁免判定式时序错误（day 在日结前已自增，`==day` 永假，必须 `==day-1`）；
   时代Ⅴ全覆盖啤酒链冬季吃麦≈面包链 116%（模拟实锤冬季麦子第 3 天耗尽）→ 酿酒坊加 no_winter；
   贸易站闭环成立、不构成瓶颈；招满顺序 market→trade_post 正确。
3. **游戏性**：给出引导队列/覆灭面板/列表筛选/拖放扩展的全部实现步骤；
   抓到「覆灭面板读取存档会先用死档覆盖 autosave」的隐藏陷阱→open_load_menu(autosave_first) 参数化；
   布局复核（引导面板与菜单互斥让位）。
4. **持续性**：save_manager 拆分预案定稿（facade + 三处工具重定向 + 键数>0 防假绿，迭代6 落地）；
   bak 恢复入口 14 行方案；性能终审（拖路重绘 2-5ms 不值得拆层，A*堆后无帧率风险源）；
   「run_gate GO 才归档+刷快照」流程固化。

### 实施清单（主控实施，run_gate 9 项 GO + logic_test 85/85 实机验证）
| # | 实施 | 文件 |
|---|------|------|
| 1 | **地形分区**：can_place 只允许平原草地（森林/浆果丛/水域/石林均不可建设，农场规则统一满足） | grid_manager.gd |
| 2 | **画质区分**：森林画树（树干+双层树冠）、石林画 3 根石笋、水域画双弧波纹、浆果丛画灌木红果、平原加草簇（确定性抖动） | grid_manager.gd |
| 3 | **森林动态消耗**：伐木场 depletes=forest，每产一轮砍工作半径 3 格内一格森林；周边砍光停产并显示「周边森林已耗尽」 | building.gd / grid_manager.gd |
| 4 | **新增植树场**（时代Ⅰ，木10，1 工人，12 秒/轮）：每轮在周边 3 格草地种出一格森林（避开道路与建筑占格）——木材循环闭合，前期不会因森林枯竭卡死 | building_catalog.gd / building.gd |
| 5 | **工作区域可视化**：Building.show_work_area + work_radius；选中伐木场（绿圈+高亮范围内每格森林）/植树场/采集小屋/采石场画工作圈；main._set_inspected_building 管理，详情关闭联动清除 | building.gd / main.gd / hud.gd |
| 6 | **建筑作用明确**：catalog 22 条目全部加 desc 一句话作用（水井=光环+5 等），详情面板首行「作用：…」 | building_catalog.gd / hud.gd |
| 7 | **土路穿林+寻路加权**：can_place_road 允许森林（林间小径）；A* 代价 65:100 路面加权（启发式 ×65 保持可采纳），村民主动绕走土路 | grid_manager.gd |
| 8 | **小屋就近居住**：reassign_homes 新增通勤调剂——住所距工作点 >8 格的村民，每天最多 2 人自动搬进离工作点更近的空房（home_cell 出发时仍会重算，搬家即刻生效） | main.gd |
| 9 | **覆灭面板**：_check_collapse（人口0+木<5+[无房或存粮<4] 连续2天+非袭击）→ 全屏遮罩面板（读取存档/新游戏/继续观望）；open_load_menu(autosave_first) 参数化——死档绝不顶进 autosave | main.gd / hud.gd |
| 10 | **新手引导队列**：main.tutorial_step() 纯派生四步（采集小屋→伐木场→3小屋→植树场/麦田）+ hud 引导面板（与前两个面板互斥）+ 建造按钮「需森林/需浆果/需石林」提示 | main.gd / hud.gd |
| 11 | **放置失败原因提示**：place_failed 信号 + _drag_warned（每次按下最多一条）——资源不足/需贴某地形/只能建在平原 三分 | building_placer.gd / main.gd |
| 12 | 农田/水井 drag_place；酿酒坊 no_winter；P2×4（袭击日豁免 day-1 判定、无存档开局立即结算幸福度、StringName(String(id)) 坏档防御、era<3 酒馆停收啤酒） | building_catalog.gd / main.gd |
| 13 | **bak 恢复入口**：读取面板「恢复上次自动存档备份」按钮（直调 load_and_play，不回列表） | main_menu.gd |
| 14 | README：地形/采集/作用/覆灭/通勤小节 + 测试节改为 run_gate+便携版 Godot 四件套 + 表格更新 | README.md |

### 测试结论
- `python tools/run_gate.py`：**GO**（9 项；godot --import 零解析错误；smoke/menu/play 全过；logic_test PASS=85/FAIL=0）。
- 期间实机门禁抓到 2 个静态盲区解析错误（grid_manager 变量遮蔽、logic_test 类型推断）并即时修复——实机门禁价值实证。
- 遗留（迭代6）：save_manager 拆分（预案已定稿）、村民列表筛选/排序、麦田 2×2 拖放跳格提示、袭击次日读档袭击顺延的提示。


---

## 迭代 6（进行中 → 分析完毕、修复已落地）

### 分析（4 agent：save_manager 拆分实施 / 列表筛选实施 / debug 回归 / 逻辑平衡待补）
1. **save_manager.gd 拆分（P1 已落地）**：新建 save_manager.gd（302 行，RaidManager 注入模式）；main.gd 留 4 个 facade 转发 + save_dir getter（外部调用面零改动）；工具重定向三处（run_gate [2f] 目标文件与 EXPECTED_SCRIPTS 14、static_check [D] 优先 save_manager + 函数体/键数双守卫防假绿 + [C] 补查询面、logic_test MAIN_GD 重定向 + 键数下限）。**run_gate 一次 GO；logic_test PASS=89/FAIL=0；键数 21/6/12 全对称。**
2. **村民列表筛选/排序（已落地）**：只看空闲/无房 CheckButton + 排序轮换按钮 + uid 签名重建判据 + 空结果提示 + 面板 BOTTOM_LEFT 收口；agent 自修一个 PackedStringArray.join 解析错误（实机门禁抓到）。
3. **debug 回归**：抓到 **P1——reassign_homes 的提前 return 把通勤调剂掐死**（稳态永远走不到调剂，迭代5 头号特性失效）→ return 改 break；P2×3：坏档村民 name 非字符串崩在销毁后、find_random_terrain_near 40 次采样在资源将尽时 ~44% 漏检（假停产闪烁/漏种，加线性兜底）、土路失败文案与事实矛盾；P3×4（grid 注释漂移、菜单 version 缺省 0 等）。**全部已修复。**
4. **逻辑平衡（待交付）**：森林循环配比验证等。
5. 事实更正：debug agent 称「terrain 是迭代5 才入档」不成立——terrain 自 v2 起就在存档中，其 v4-无-terrain 假想场景不存在，对应修复不需要。

### 门禁
- 最终 run_gate：**GO**（9 项；logic_test 89/89；--import 零解析错误）。


---

## 迭代 6（已完成）

### 分析（4 agent 全部交付：save_manager 拆分实施 / 列表筛选实施 / debug 回归 / 逻辑平衡 / 游戏性复评）
1. **逻辑平衡（演算实证）**：实测森林格均值 ≈954（43 个斑块可覆盖水/山，"346"是名义比率非实际值）；砍伐池中位 13 格（P5=5）→ 无植树场时单场约 18 天砍空，D15~D25 的首次「周边森林已耗尽」是常规事件；**1 植树场养 4.17 伐木场（12s:50s）**，推荐 1:3~2:5；**土路加权对强盗同样生效且无移速补偿**（1 木/格可把袭击者引进箭塔走廊，行程最多 +54%，与 enemy 自述「不吃道路加速」矛盾）→ 应排除；**通勤调剂被双重卡死**（2 人/天上限 → 250 人口收敛中位 84 天；pop==容量时 0 空位完全失效），单调性验证成立无振荡 → 上限应与空位挂钩；economy_sim 通勤假设「单程 3s」=收敛后最优态，前期系统性高估产出（激进策略冬季需敏感性复跑）。
2. **游戏性**：**覆灭判定 wood<5 漏掉最常见死局**（人口0+木≥5+粮<4 数学上不可恢复却永不弹面板）→ 改为 pop==0 且粮<4；覆灭空窗 2 天无反馈 → 第 1 天加倒计时 toast；**覆灭态 ESC/关窗仍会把死档写进 autosave**（与面板保护不一致）→ 存活才存；引导第 4 步 39 木>30 木必吃「资源不足」且 ×4 会烧掉引导窗口 → 文案+退场条件修正；引导与建造菜单互斥导致"照着做看不到要做啥" → 共存；工作圈(圆)与实际窗口(方)不一致 → 方形化；**选中建造时三层视觉叠加** → 清工作圈；README 路线图 4 项已实现仍标未实现；新 UI 零自动化断言（留待补测）。
3. **持续/实施**：村民列表筛选/排序落地（agent 自修 PackedStringArray.join 解析错误——实机门禁再立功）；save_manager 拆分一次 GO。

### 修复清单（全部落地，run_gate GO + logic_test 89/89）
| # | 修复 | 文件 |
|---|------|------|
| 1 | [P2] 强盗寻路排除路面加权：`_move_cost(cell, for_enemy)`，敌人恒走平价最短路 | grid_manager.gd |
| 2 | [P2] 通勤调剂上限 `maxi(2, 空位数)`（0 空位失效/84 天收敛两个问题同解） | main.gd |
| 3 | [P1] 覆灭判定补洞：pop==0 且存粮<4（删 wood<5）；第 1 天加「明日将覆灭」倒计时 toast | main.gd |
| 4 | [P2] 覆灭态自动存档保护：return_to_menu/quit/关窗改走 `_autosave_if_alive()`（死档不顶 autosave） | main.gd |
| 5 | [P2] 打开读取面板时收起覆灭遮罩（两面板同锚点叠放） | main.gd |
| 6 | [P2] 引导第 4 步：文案改「攒够木 10 建植树场（另外开麦田）+ 空格等伐木场出货」；退场 day>3→day>4；植树场为确定项 | main.gd / hud.gd |
| 7 | [P2] 引导面板与建造菜单共存（只与村民列表互斥）；时代Ⅱ toast 追加「先建采石场贴石林备石料」 | hud.gd |
| 8 | [P2] 选中建造时清工作区域圈（`_on_build_button` → clear_building_inspect） | hud.gd |
| 9 | [P3] 伐木场详情「周边森林 N 格（≤5 提示将耗尽）」、植树场「周边可种草地 N 格」；未停产资源复查 0.5s 节流（原每帧 40 采样+49 格扫描） | building.gd / hud.gd |
| 10 | [P3] 工作区域圆→方形（与实际 7×7 窗口和森林高亮一致） | building.gd |
| 11 | [P3] 土路失败文案与事实一致、grid 注释漂移、菜单 version 缺省 0 | placer / grid / main_menu |
| 12 | README 路线图同步（移除已实现 4 项） | README.md |

### 测试结论
- run_gate：**GO**（9 项；--import 零解析错误；smoke/menu/play 全过；logic_test 89/89）。
- 遗留（迭代7）：economy_sim 补森林维度与通勤敏感性（模拟 agent 预案已给）、倍速细化（P 暂停）、设置面板实体化、新 UI 自动化断言（collapse/tutorial）、正式美术。
