# 前期体验扩展 + UI/交互改善（迭代 7）

## A. 随机事件系统（前期核心扩展，暂停等待选择）
**新文件 `scripts/event_manager.gd`**（照 raid_manager 注入模式，PROCESS_MODE_ALWAYS）：
- 事件池（时代Ⅰ起，每 2~4 天 roll 一次，同事件冷却 ≥8 天；袭击/覆灭面板/冬季暴雨除外互斥）：
  1. 流浪工匠（Ⅰ+）：收留（+1 村民）/ 送盘缠（-3 食）
  2. 行商队（Ⅰ+）：卖 10 食物 → +12 金 / 拒绝
  3. 丰收祭（Ⅰ+）：花 6 食办宴 → 全体幸福 +10 一天 / 取消
  4. 暴雨（Ⅰ+，自动无选择）：明天农田与渔屋停产一天（前一天预警）
  5. 走失的羊群（Ⅱ+）：+4 羊毛 / +4 食物
  6. 猎户来投（Ⅱ+）：+1 村民
- 事件卡 UI：弹出即暂停（保存原 paused 状态），标题+描述+最多 2 按钮，选完恢复；复用 ui_font 主题；main.gd 的 event 分支与 raid/覆灭互斥。
- 暴雨停产：Building 加 `no_prod_today` 标记，main 日结时按 rainy_day 置位（农田/渔屋），building._process 在出勤记录后检查，hud 状态行「暴雨停产」。

## B. UI / 交互改善
1. **建造菜单红警式分组**：catalog 每条加 `group` 字段（食物/资源/民生/生产/防御 5 组）；建造面板顶部加分类 Tab 按钮排，点击切换该组建筑（era 置灰逻辑保留，默认 tab=食物）。
2. 修死代码：`_terrain_hint` 的 needs_water 分支（当前在 return 后永不执行）。
3. 分配反馈：assign_worker 失败原因 toast（无空闲村民/岗位满/四周被堵；一键招满走静默参数）；一键招满完成 toast「已补 N 人」。
4. **通知日志**：toast 容量 3→5；顶栏加「日志」按钮 → 右侧面板列最近 20 条历史消息（toast 不再丢消息）。
5. **暂停视觉**：time_scale==0 时横幅通道常驻「⏸ 已暂停」。
6. **昼夜感**：main 加 CanvasModulate，按 time_of_day 插值（白天亮→黄昏橙→夜晚蓝暗），解决"夜晚空转无感知"。
7. **快捷键**：B=建造菜单、L=村民列表；顶栏「人口/空闲」标签改为可点击按钮 → 循环定位空闲村民。
8. 土路/渔屋等放置失败文案与 needs_water 提示保持一致（placer._warn_place_failed 已支持水域）。

## C. 测试与验证
- logic_test 增补：事件池结构断言（每事件有 title/options/era 过滤/冷却）、tutorial 6 步、catalog group 全覆盖且组名合法、ASSIGN_PRIORITY 含 fisher/stall。
- play_test 增补：事件效果 apply 断言（工匠 +1 人、行商扣食加金）。
- 全部落地后 `python tools/run_gate.py` 必须 GO（9 项含 Godot 实机 4 套件），GO 才归档日志与刷新 `_releases` 快照。

## 实施顺序
1. catalog group 字段 + 建造菜单分组 Tab → 2. 修 needs_water 死代码 → 3. event_manager + 事件卡（最大件）→ 4. 分配反馈 + 通知日志 → 5. 暂停视觉 + CanvasModulate → 6. 快捷键/空闲定位 → 7. 测试增补 → 8. run_gate → 9. README/ITERATION_LOG/快照归档。

不做（按你的选择）：村民愿望系统。已确认事件卡=暂停等待选择。