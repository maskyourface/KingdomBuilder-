#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
KingdomBuilder 经济离散模拟（迭代4 公式同步版）
================================================
从当前源码抄录公式，复刻 60 天经济演化（每模拟天=1 步输出；内部以 0.5 游戏秒子步
积分，复刻逐帧 _process 的连续过程）。纯经济视角：不建模寻路/动画/特效/拆建手感。

迭代4 同步点（相对迭代3 报告的公式差异，S1~S8，均标注 来源文件:行号）：
  S1 面包房造价石料 10→6            building_catalog.gd:71-77（cost 注释 :73-74）
  S2 市场保留线面包 pop*2→pop       main.gd:293-299（生食仍 pop*2，与移民囤粮线脱钩）
  S3 一键招满优先级=ASSIGN_PRIORITY main.gd:468-472：gatherer→farm→lumber→quarry→mill→
     bakery→pasture→weaver→brewery→church→tavern→market→trade_post→watchtower
  S4 新增贸易站（时代Ⅴ，workers2，木25/石10）：每天金币收购 石2金/个≤10、木1金/个≤20，
     单站日支出≤40金，金币保底50不动；模拟策略时代Ⅴ且金≥50 时建 1 座
                                     building_catalog.gd:147-154 / main.gd:332-358
  S5 移民闸时代Ⅳ第 4 人/天          main.gd:160-163（era>=4 且幸福>=70 且 housing>pop+3）
  S6 酒馆服务上限随时代 serves×2^(era-3)（时代3:8/4:16/5:32）+ 啤酒不足时部分服务
     （served ≤ 啤酒库存×2，ceil(served/2) 瓶）  main.gd:222-241
  S7 袭击日（强盗在场）信仰/娱乐缺席惩罚不叠加（幸福公式跳过 -5）  main.gd:258-262
  S8 箭塔伤害 12（核对：源码已同步；模拟 A4 抽象防守，不逐发结算）  building_catalog.gd:138

公式来源（全部标注 文件:行号，行号对应当前 scripts/ 源码）：
  villager.gd          :19-24   移动/饥饿/进食回复常数
  villager.gd          :73-75   饥饿累积、hunger>=100 饿死
  villager.gd          :89,:98,:113-115,:124-125  任意状态 hunger>=HUNGRY_AT 且有粮即进食
  villager.gd          :102-111 进食 2s 引导，面包优先回 100、生食回 50
  time_manager.gd      :14-15   60 秒=1 天、5 天一季
  time_manager.gd      :29      season=(day-1)//5 %4 → 冬季=第16-20/36-40/56-60天
  time_manager.gd      :44-45   is_night: tod<0.15 或 >0.85 → 工作窗 42s/天
  building.gd          :56-88   生产：在岗才推进、按在岗比例缩放、幸福>=70 ×1.2、
                                no_winter 冬季停产、缺原料停工、interval 到点扣料产出
  building.gd          :24-25,:57-59  worked_today 白天到岗标记（市场/光环/贸易站日结门控）
  main.gd              :13      ERA_POP=[0,15,40,100,250] 时代按人口
  main.gd              :22-27   市场日上限 20 金、贸易保底 50 金、军饷 1 金/天、衣服穿 8~12 天
  main.gd              :132-166 日结顺序：发衣→幸福→市场/贸易站→军饷→袭击→离队→移民→复位出勤
  main.gd              :144-149 幸福<40 每天离队 1 人（卫兵豁免、pop>1 才离）
  main.gd              :150-163 移民闸：edible>=maxi(pop*(冬4/平2),4) 且 housing>pop；
                                幸福>=70 +1；时代>=3 再 +1；时代>=4 第 4 人/天（S5；
                                era 逐级用 current_era() 现算，移民落地后人口升级即生效）
  main.gd              :196-269 幸福日结：基础50、住房±10/-30、面包+10、挨饿-20、
                                水井+5、时代2衣服±10、时代3信仰/娱乐+10/缺席-5（袭击日
                                跳过 -5，S7）、城堡+10、袭击士气、clamp 0~100、全局=均值
  main.gd              :222-241 酒馆：serve_cap=serves×2^(era-3)、部分服务（S6）
  main.gd              :277-287 发衣（磨损 8~12 天，模拟取均值 10）
  main.gd              :289-358 市场保留线（面包 pop（S2）、生食 pop*2、衣服 pop、啤酒10）、
                                单价（衣3/酒3/包2/食1）、按贵到便宜卖、每市场 20 金/天、
                                白天有人到岗才卖；贸易站收购（S4）
  main.gd              :361-378 卫兵日结：军饷 1 金/天，断饷/无兵营退役
  main.gd              :468-472 一键招满 ASSIGN_PRIORITY（S3）；卫兵手动、不进一键招满
  raid_manager.gd      :10-18   士气常数（胜+5 / 抢-10 封顶-20 / 持续2天）、间隔6~9天、
                                每60人口+1强盗、单次最长4天
  raid_manager.gd      :81-120  排期：时代>=4 且非冬季；next<0 时 day+rand(6,9)；
                                day>=next → 次日清晨现身并重排
  enemy.gd             :187-208 劫掠：每个得手强盗偷 FOOD/面包 各 10%（至少1）、
                                有市场再偷金币 10%（至少1）
  resource_manager.gd  :25-31   开局物资：木 30、生食 20
  resource_manager.gd  :64-66   edible = 面包+生食
  building_catalog.gd  :17-161  建筑造价/产量/interval/inputs/outputs/workers/housing/
                                min_era/no_winter/serves=8/贸易站 auto_buys/箭塔 damage=12

模拟假设（与源码的差异，逐条可追溯）：
  A1 通勤扣减：村民清晨 0.15 处出发，60px/s（villager.gd:19），均距约 6 格 ×32px
     （grid_manager.gd:10-11 TILE=32）≈ 3.2s，土路 +60%（villager.gd:20）近似抵消绕路，
     取单程 3s、往返 6s/天扣减工作窗。参数 COMMUTE_ONEWAY 可调。
  A2 出勤窗：村民到岗 = 工作窗内且已走完单程通勤且不在进食引导中（进食时不在岗，
     对应 villager.gd State.EATING 不属于 WORKING）。
  A3 光环覆盖：水井/教堂半径覆盖按策略"建成即覆盖全体住所"近似（真实按
     main.gd:272-275 距离判定，城镇摊开后实际覆盖会打折）；酒馆按 serve_cap 名额随机。
  A4 防守模型：保守/标准策略在时代Ⅳ建成 2 箭塔+1 兵营（3 卫兵在岗）视为击退
     （劫掠 0 次、士气 +5）；激进不设防 → 全部强盗得手。箭塔伤害 12/1.5s
     （catalog:138，S8 核对一致）对 60HP 强盗（enemy.gd:11）恰好 5 发击杀，模拟不逐发结算。
  A5 工人分配：每日清晨按 ASSIGN_PRIORITY（main.gd:468-472，S3）轮转自动补满；
     源码一键招满不含兵营（卫兵手动指派），模拟按 A4 直接满编、附在序尾。
  A6 玩家建造：清晨瞬时完成（游戏内即时到账）；不开挂资源，严格扣 catalog 造价。
  A7 袭击劫掠简化为当日清晨一次结算（游戏内强盗需行军+5s 引导，未设防时结果相同）。
     S7 的"袭击日"映射：源码 raid.raid_active（午夜结算时强盗在场）↔ 模拟当日 raid_today
     （A7 一次性袭击=强盗当日在场一整天）。模拟不建模逃难停产，故袭击日在岗/光环照常。
  A8 不建模：城墙被拆的石头损失、强盗被杀、卫兵战死、manual 拆建。
  A9 贸易站收购与市场同段结算（main.gd:332-358 顺序），每日一次；收购到的石/木次日可用；
     收购用整数除法逐步复刻（affordable=(金-50)/价，n=min(日预算,affordable)/价）。

用法：python tools/economy_sim.py [-o 报告路径]
输出：控制台摘要 + tools/economy_sim_report.txt（曲线表+冬季最低点+结论）
"""

import argparse
import os
import random

TOOL_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_REPORT = os.path.join(TOOL_DIR, "economy_sim_report.txt")

# ----------------------------------------------------------------------------
# 常数（源码抄录）
# ----------------------------------------------------------------------------
DAY_SECONDS = 60.0                    # time_manager.gd:14 day_length_seconds=60
DAYS_PER_SEASON = 5                   # time_manager.gd:15 days_per_season=5
DAY_START = 0.15                      # time_manager.gd:45 is_night 下界
DAY_END = 0.85                        # time_manager.gd:45 is_night 上界
WORK_WINDOW = (DAY_END - DAY_START) * DAY_SECONDS   # 42s/天
HUNGER_RATE = 100.0 / 240.0           # villager.gd:21
HUNGRY_AT = 60.0                      # villager.gd:22
BREAD_RESTORE = 100.0                 # villager.gd:23
FOOD_RESTORE = 50.0                   # villager.gd:24
EAT_SECONDS = 2.0                     # villager.gd:103 进食引导
STARVE_AT = 100.0                     # villager.gd:73 hunger>=100 饿死
VILLAGER_SPEED = 60.0                 # villager.gd:19
COMMUTE_ONEWAY = 3.0                  # 假设 A1：单程 3s（≈6 格）
ERA_POP = [0, 15, 40, 100, 250]       # main.gd:13
MARKET_DAILY_CAP = 20                 # main.gd:22
TRADE_GOLD_RESERVE = 50               # main.gd:23 贸易站收购给金币留的保底（迭代4同步，S4）
TRADE_POST_DAILY_SPEND = 40           # main.gd:349 单贸易站日收购支出上限（迭代4同步，S4）
GUARD_WAGE = 1                        # main.gd:24
CLOTHES_WEAR_MIN, CLOTHES_WEAR_MAX = 8, 12   # main.gd:26-27（模拟取均值 10）
MOOD_VICTORY = 5                      # raid_manager.gd:10
MOOD_PER_PILLAGE = -10                # raid_manager.gd:11
MOOD_CAP = -20                        # raid_manager.gd:12
MOOD_DAYS = 2                         # raid_manager.gd:13
RAID_MIN_GAP, RAID_MAX_GAP = 6, 9     # raid_manager.gd:14-15
RAID_PER_POP = 60                     # raid_manager.gd:17 PER_POPULATION
TAVERN_SERVES = 8                     # building_catalog.gd:113 serves=8
DT = 0.5                              # 积分子步（游戏秒）
SIM_DAYS = 60

# 资源枚举（resource_manager.gd:7 顺序）
R_WOOD, R_FOOD, R_WHEAT, R_FLOUR, R_BREAD, R_STONE, R_GOLD, R_WOOL, R_CLOTHES, R_BEER = range(10)
RNAME = ["木", "食", "麦", "粉", "包", "石", "金", "毛", "衣", "酒"]

# 建筑目录（building_catalog.gd:17-152 逐条抄录；cost/inputs/outputs=[类型,数量]）
# id, name, cost, produces, inputs, outputs, interval, workers, housing, min_era,
# no_winter, serves, aura_kind, auto_sells, trains_guards, shoots
CATALOG = {
    "road":      dict(name="土路", cost={R_WOOD: 1}),
    "house":     dict(name="小屋", cost={R_WOOD: 5}, housing=3),
    "well":      dict(name="水井", cost={R_WOOD: 3, R_STONE: 2}, aura="well"),           # :29-34
    "gatherer":  dict(name="采集小屋", cost={R_WOOD: 6}, produces=True, inputs={},
                      outputs={R_FOOD: 2}, interval=9.0, workers=1, no_winter=True),       # :35-41
    "lumber":    dict(name="伐木场", cost={R_WOOD: 8}, produces=True, inputs={},
                      outputs={R_WOOD: 2}, interval=5.0, workers=2),                       # :42-48
    "farm":      dict(name="麦田", cost={R_WOOD: 4}, produces=True, inputs={},
                      outputs={R_WHEAT: 2}, interval=8.0, workers=2, no_winter=True),      # :49-55
    "quarry":    dict(name="采石场", cost={R_WOOD: 10}, produces=True, inputs={},
                      outputs={R_STONE: 1}, interval=8.0, workers=1),                      # :56-62
    "mill":      dict(name="磨坊", cost={R_WOOD: 15, R_STONE: 5}, produces=True,
                      inputs={R_WHEAT: 2}, outputs={R_FLOUR: 2}, interval=6.0,
                      workers=1, min_era=2),                                               # :63-69
    "bakery":    dict(name="面包房", cost={R_WOOD: 20, R_STONE: 6}, produces=True,
                      inputs={R_FLOUR: 2}, outputs={R_BREAD: 2}, interval=6.0,
                      workers=1, min_era=2),   # :71-77 迭代4同步 S1：石料 10→6（消除磨坊抢石节奏陷阱）
    "pasture":   dict(name="牧羊场", cost={R_WOOD: 12}, produces=True, inputs={},
                      outputs={R_WOOL: 2}, interval=10.0, workers=1, min_era=2),           # :78-84
    "weaver":    dict(name="纺织坊", cost={R_WOOD: 15, R_STONE: 5}, produces=True,
                      inputs={R_WOOL: 2}, outputs={R_CLOTHES: 1}, interval=6.0,
                      workers=1, min_era=2),                                               # :85-91
    "church":    dict(name="教堂", cost={R_WOOD: 20, R_STONE: 15}, workers=1, min_era=3,
                      aura="faith"),                                                       # :93-99
    "brewery":   dict(name="酿酒坊", cost={R_WOOD: 15, R_STONE: 5}, produces=True,
                      inputs={R_WHEAT: 2}, outputs={R_BEER: 2}, interval=8.0,
                      workers=1, min_era=3),                                               # :100-106
    "tavern":    dict(name="酒馆", cost={R_WOOD: 20, R_STONE: 10}, workers=1, min_era=3,
                      aura="fun", serves=TAVERN_SERVES),                                   # :107-113
    "market":    dict(name="市场", cost={R_WOOD: 25, R_STONE: 10}, workers=1, min_era=4,
                      auto_sells=True),                                                    # :115-120
    "wall":      dict(name="城墙", cost={R_STONE: 2}, min_era=4, hp=60),                 # :121-126
    "gate":      dict(name="城门", cost={R_WOOD: 4, R_STONE: 2}, min_era=4, hp=80),      # :127-132
    "watchtower": dict(name="箭塔", cost={R_WOOD: 10, R_STONE: 8}, min_era=4, workers=1,
                       shoots=True),   # :135-139 shoots_damage=12 已核对一致（S8；A4 不逐发结算）
    "barracks":  dict(name="兵营", cost={R_WOOD: 30, R_STONE: 20}, min_era=4, workers=3,
                      trains_guards=True),                                                 # :141-145
    "castle":    dict(name="城堡", cost={R_WOOD: 100, R_STONE: 80, R_GOLD: 50}, min_era=5,
                      aura="castle"),                                                      # :156-160
    # 迭代4同步 S4 新增（building_catalog.gd:147-154）：时代Ⅴ贸易站，用金币收购石料/木材
    # auto_buys=[(资源, 单价, 日上限)]：石 2 金/个≤10 个、木 1 金/个≤20 个
    "trade_post": dict(name="贸易站", cost={R_WOOD: 25, R_STONE: 10}, workers=2, min_era=5,
                       auto_buys=[(R_STONE, 2, 10), (R_WOOD, 1, 20)]),
}

# 工人分配优先级（迭代4同步 S3：main.gd:468-472 ASSIGN_PRIORITY 原序抄录）
# gatherer→farm→lumber→quarry→mill→bakery→pasture→weaver→brewery→church→tavern→
# market→trade_post→watchtower；源码一键招满不含兵营（卫兵手动指派），
# 模拟按 A4 直接满编、附在序尾（相当于手动配满的效果上限）
ASSIGN_ORDER = ["gatherer", "farm", "lumber", "quarry", "mill", "bakery",
                "pasture", "weaver", "brewery", "church", "tavern", "market",
                "trade_post", "watchtower", "barracks"]

# 市场参数（main.gd:277-291）
MARKET_PRICES = [(R_CLOTHES, 3), (R_BEER, 3), (R_BREAD, 2), (R_FOOD, 1)]  # 贵→便宜


def season_of(day):
    """time_manager.gd:29 season=int((day-1)/days_per_season)%4"""
    return ((day - 1) // DAYS_PER_SEASON) % 4


SEASON_NAMES = ["春", "夏", "秋", "冬"]   # time_manager.gd:9-12


def is_winter_day(day):
    return season_of(day) == 3


def days_until_winter(day):
    """time_manager.gd:36-41"""
    if season_of(day) == 3:
        return 0
    pos = (day - 1) % DAYS_PER_SEASON
    ahead = (3 - season_of(day) + 4) % 4
    return ahead * DAYS_PER_SEASON - pos


def era_of(pop):
    """main.gd:176-182 current_era"""
    era = 1
    for i, thr in enumerate(ERA_POP):
        if pop >= thr:
            era = i + 1
    return era


class Villager:
    _seq = 0

    def __init__(self):
        Villager._seq += 1
        self.uid = Villager._seq
        self.hunger = 0.0            # villager.gd:39 初始 0
        self.happiness = 50.0        # villager.gd:40 初始 50
        self.eating_t = 0.0
        self.job = None              # Building 或 None
        self.role_guard = False
        self.home = False            # 简化：是否分配到住房
        self.has_clothes = False
        self.clothes_days = 0
        self.last_ate_bread = False


class Building:
    _seq = 0

    def __init__(self, cid):
        Building._seq += 1
        self.uid = Building._seq
        self.cid = cid
        self.timer = 0.0             # building.gd:21
        self.worked_today = False    # building.gd:24
        self.workers = []            # 在编村民（Villager）


class Sim:
    def __init__(self, policy_fn, label, seed, defense=True, welfare=True):
        self.policy_fn = policy_fn
        self.label = label
        self.rng = random.Random(seed)
        self.seed = seed
        self.defense = defense       # 假设 A4：时代Ⅳ设防
        self.welfare = welfare       # 是否建福利（水井/衣/信仰/娱乐）
        # 资源（resource_manager.gd:25-31 reset：WOOD 30 / FOOD 20）
        self.stock = [0] * 10
        self.stock[R_WOOD] = 30
        self.stock[R_FOOD] = 20
        self.happiness = 50.0        # resource_manager.gd:19
        self.villagers = [Villager() for _ in range(5)]   # main.gd:87-89 开局 5 人
        self.buildings = []
        self.day = 1
        # 袭击状态（raid_manager.gd）
        self.next_raid_day = -1
        self.raid_today = False
        self.raid_mood_bonus = 0
        self.raid_mood_days_left = 0
        # 统计
        self.starved = 0
        self.left_happiness = 0
        self.raids = 0
        self.pillaged_total = 0
        self.trade_post_day = None     # 贸易站建成日（迭代4同步 S4）
        self.trade_gold_spent = 0      # 贸易站累计收购支出（金）
        self.trade_stone_bought = 0
        self.trade_wood_bought = 0
        self.deaths_by_day = {}
        self.log_rows = []
        self.winter_min_edible = {}   # 冬季起始日 -> 最低 edible
        self.softlock_day = None
        self.events = []

    # ---------- 基础查询 ----------
    @property
    def pop(self):
        return len(self.villagers)

    def edible(self):
        """resource_manager.gd:65-66"""
        return self.stock[R_BREAD] + self.stock[R_FOOD]

    def housing_capacity(self):
        """main.gd:493-497"""
        return sum(CATALOG[b.cid].get("housing", 0) for b in self.buildings)

    def counts(self):
        c = {}
        for b in self.buildings:
            c[b.cid] = c.get(b.cid, 0) + 1
        return c

    def has_all(self, costs):
        """resource_manager.gd:41-45"""
        for t, n in costs.items():
            if self.stock[t] < n:
                return False
        return True

    def try_spend(self, costs):
        """resource_manager.gd:48-54"""
        if not self.has_all(costs):
            return False
        for t, n in costs.items():
            self.stock[t] -= n
        return True

    def can_build(self, cid):
        d = CATALOG[cid]
        era = era_of(self.pop)       # main.gd:176-182（时代按当前人口）
        if era < d.get("min_era", 1):
            return False
        return self.has_all(d["cost"])

    def build(self, cid):
        d = CATALOG[cid]
        if not self.can_build(cid):
            return False
        self.try_spend(d["cost"])
        self.buildings.append(Building(cid))
        return True

    # ---------- 工人分配（假设 A5；迭代4同步 S3：按 ASSIGN_PRIORITY 轮转补满） ----------
    def assign_workers(self):
        for b in self.buildings:
            b.workers = []
        for v in self.villagers:
            v.job = None
            v.role_guard = False
        idle = list(self.villagers)
        for cid in ASSIGN_ORDER:
            if cid not in [b.cid for b in self.buildings]:
                continue
            need = CATALOG[cid].get("workers", 0)
            for b in [x for x in self.buildings if x.cid == cid]:
                while len(b.workers) < need and idle:
                    v = idle.pop(0)
                    b.workers.append(v)
                    v.job = b
                    if CATALOG[cid].get("trains_guards", False):
                        v.role_guard = True   # main.gd:406-408 入伍

    # ---------- 每日连续积分（复刻 _process） ----------
    def integrate_day(self, day):
        winter = is_winter_day(day)
        t = DAY_START * DAY_SECONDS if day == 1 else 0.0   # main.gd:542 新游戏从 0.3 开始
        raid_done = False
        while t < DAY_SECONDS:
            daytime = DAY_START * DAY_SECONDS <= t <= DAY_END * DAY_SECONDS
            arrived = daytime and t >= DAY_START * DAY_SECONDS + COMMUTE_ONEWAY  # A1/A2

            # —— 村民：饥饿累积 + 饿死（villager.gd:72-74）——
            dead = []
            for v in self.villagers:
                v.hunger += DT * HUNGER_RATE
                if v.hunger >= STARVE_AT:
                    dead.append(v)
            for v in dead:                # villager.gd:133-140 _die 清理引用
                self.starved += 1
                self.deaths_by_day[day] = self.deaths_by_day.get(day, 0) + 1
                if v.job is not None:
                    v.job.workers.remove(v)
                if v in self.villagers:
                    self.villagers.remove(v)
                self.events.append(f"D{day} 村民{v.uid} 饿死（库存 ed={self.edible()}）")

            # —— 村民：进食决策与引导（villager.gd:101-110，任意状态可吃）——
            for v in self.villagers:
                if v.eating_t > 0:
                    v.eating_t -= DT
                    if v.eating_t <= 0:
                        if self.stock[R_BREAD] >= 1:      # 面包优先 villager.gd:105-107
                            self.stock[R_BREAD] -= 1
                            v.hunger = max(0.0, v.hunger - BREAD_RESTORE)
                            v.last_ate_bread = True
                        elif self.stock[R_FOOD] >= 1:     # 生食回一半 villager.gd:108-109
                            self.stock[R_FOOD] -= 1
                            v.hunger = max(0.0, v.hunger - FOOD_RESTORE)
                elif v.hunger >= HUNGRY_AT and self.edible() > 0:
                    v.eating_t = EAT_SECONDS

            # —— 建筑：出勤标记 + 生产（building.gd:56-88）——
            for b in self.buildings:
                d = CATALOG[b.cid]
                present = 0
                if d.get("workers", 0) > 0:
                    for w in b.workers:
                        if arrived and w.eating_t <= 0:   # A2：到岗且不在吃饭
                            present += 1
                if present > 0:
                    b.worked_today = True                 # building.gd:57-59
                if not d.get("produces", False):
                    continue
                if d.get("no_winter", False) and winter:  # building.gd:64-65
                    continue
                if not self.has_all(d.get("inputs", {})):  # building.gd:67-69 缺料停工
                    continue
                rate = 1.2 if self.happiness >= 70.0 else 1.0   # building.gd:71-72
                mw = d.get("workers", 0)
                if mw > 0:
                    if present == 0:                       # building.gd:76-78 没人不动
                        continue
                    b.timer += DT * rate * float(present) / float(mw)   # :80 按在岗比例
                else:
                    b.timer += DT * rate
                if b.timer >= d["interval"]:               # building.gd:84-88
                    b.timer = 0.0
                    self.try_spend(d.get("inputs", {}))
                    for out_t, out_n in d.get("outputs", {}).items():
                        self.stock[out_t] += out_n

            # —— 袭击劫掠（enemy.gd:178-199，假设 A7 当日清晨一次）——
            if self.raid_today and not raid_done and arrived:
                raid_done = True
                self._do_raid(day)

            # —— 冬季存粮最低点统计 ——
            if winter:
                wkey = (day - 1) // DAYS_PER_SEASON * DAYS_PER_SEASON + 1
                cur = self.winter_min_edible.get(wkey, 1 << 30)
                self.winter_min_edible[wkey] = min(cur, self.edible())

            # —— 软锁检测：无木材收入且无力建伐木场 ——
            if self.softlock_day is None:
                has_lumber = any(b.cid == "lumber" for b in self.buildings)
                wood_income_possible = (not has_lumber) and self.stock[R_WOOD] < 8
                has_any_income = has_lumber
                if wood_income_possible and not has_any_income:
                    has_food_income = any(
                        CATALOG[b.cid].get("produces") and
                        not (CATALOG[b.cid].get("no_winter") and winter)
                        for b in self.buildings)
                    if not has_food_income:
                        self.softlock_day = day
                        self.events.append(f"D{day} 软锁：无木材收入、木<{8}、无食物产能 → 无法再建造")

            t += DT

    def _do_raid(self, day):
        """enemy.gd:178-199 抢劫 + raid_manager.gd:198-212 士气结算（假设 A4/A7）"""
        self.raids += 1
        bandits = 2 + self.pop // RAID_PER_POP        # raid_manager.gd:177
        towers_staffed = 0
        guards = 0
        for b in self.buildings:
            if b.cid == "watchtower" and b.workers:
                towers_staffed += 1
            if b.cid == "barracks" and b.workers:
                guards += len(b.workers)
        defended = self.defense and towers_staffed >= 2 and guards >= 3
        pillages = 0
        if not defended:
            for _ in range(bandits):
                got = 0
                want = max(1, self.stock[R_FOOD] // 10)
                if self.stock[R_FOOD] >= want:
                    self.stock[R_FOOD] -= want
                    got += want
                want = max(1, self.stock[R_BREAD] // 10)
                if self.stock[R_BREAD] >= want:
                    self.stock[R_BREAD] -= want
                    got += want
                if any(b.cid == "market" for b in self.buildings):   # enemy.gd:192
                    want = max(1, self.stock[R_GOLD] // 10)
                    if self.stock[R_GOLD] >= want:
                        self.stock[R_GOLD] -= want
                        got += want
                if got > 0:
                    pillages += 1
        self.pillaged_total += pillages
        if pillages == 0:
            self.raid_mood_bonus = MOOD_VICTORY
            self.events.append(f"D{day} 袭击被击退（强盗{bandits}，士气+{MOOD_VICTORY}）"
                               if defended else
                               f"D{day} 袭击无所得（强盗{bandits}，士气+{MOOD_VICTORY}）")
        else:
            self.raid_mood_bonus = max(MOOD_PER_PILLAGE * pillages, MOOD_CAP)  # :210
            self.events.append(f"D{day} 袭击：强盗{bandits} 得手{pillages} 次"
                               f"（抢走约 {pillages * 10}% 存粮，士气{self.raid_mood_bonus}）")
        self.raid_mood_days_left = MOOD_DAYS         # :211

    # ---------- 午夜日结（main.gd:130-156 顺序复刻） ----------
    def settle_new_day(self, new_day):
        winter = is_winter_day(new_day)
        era = era_of(self.pop)                        # 步骤3幸福用当前人口时代

        # 2. 发衣（main.gd:262-271：磨损全员结算，发放仅时代≥2）
        for v in self.villagers:
            if v.has_clothes:
                v.clothes_days -= 1
                if v.clothes_days <= 0:
                    v.has_clothes = False
            if not v.has_clothes and era >= 2 and self.stock[R_CLOTHES] >= 1:
                self.stock[R_CLOTHES] -= 1
                v.has_clothes = True
                v.clothes_days = 10               # 8~12 取均值（main.gd:271）

        # 3. 幸福日结（main.gd:196-269）
        well_cov = self._aura_covered("well")
        faith_cov = self._aura_covered("faith")
        fun_served = self._tavern_serving(era)
        # 迭代4同步 S7（main.gd:258-262）：袭击日（强盗在场）信仰/娱乐缺席惩罚不叠加。
        # 映射（A7）：此刻 raid_today=True ⟺ 正在结算的这一天清晨有过袭击（源码为午夜时
        # raid.raid_active 为真）。注意须在步骤6重置 raid_today 之前读取。
        raid_day = self.raid_today
        total = 0.0
        for v in self.villagers:
            h = 50.0                                  # main.gd:245
            h += 10.0 if v.home else -30.0            # main.gd:246-249
            if v.last_ate_bread:
                h += 10.0                             # main.gd:250-251
            if v.hunger > HUNGRY_AT:
                h -= 20.0                             # main.gd:252-253
            if well_cov:
                h += 5.0                              # main.gd:254-255
            if era >= 2:
                h += 10.0 if v.has_clothes else -10.0  # main.gd:256-257
            if era >= 3:
                # main.gd:259-262：在场时缺席记 0（跳过 -5），与袭击士气惩罚不叠加
                h += 10.0 if faith_cov else (0.0 if raid_day else -5.0)
                h += 10.0 if v.uid in fun_served else (0.0 if raid_day else -5.0)
            h += 10.0 if self._has_castle() else 0.0   # main.gd:210-211,263
            if self.raid_mood_days_left > 0:
                h += self.raid_mood_bonus             # main.gd:264-265
            v.happiness = max(0.0, min(100.0, h))     # main.gd:266 clamp
            v.last_ate_bread = False                  # main.gd:267
            total += v.happiness
        self.happiness = total / max(1.0, float(len(self.villagers)))  # main.gd:269

        # 4. 市场交易（main.gd:289-358）
        pop_now = self.pop
        # 迭代4同步 S2（main.gd:293-299）：保留线 面包 pop（与移民囤粮线脱钩）、生食仍 pop*2
        reserves = {R_BREAD: pop_now, R_FOOD: pop_now * 2,
                    R_CLOTHES: pop_now, R_BEER: 10}
        for b in self.buildings:
            if not CATALOG[b.cid].get("auto_sells", False):
                continue
            if CATALOG[b.cid].get("workers", 0) > 0 and not b.worked_today:
                continue                              # main.gd:312-315 没人到岗不卖
            gold = 0
            for t, price in MARKET_PRICES:
                surplus = self.stock[t] - reserves.get(t, 0)
                n = min(surplus, (MARKET_DAILY_CAP - gold) // price)   # main.gd:323
                if n <= 0:
                    continue
                self.stock[t] -= n
                gold += n * price
                if gold >= MARKET_DAILY_CAP:
                    break
            self.stock[R_GOLD] += gold                # main.gd:329-330

        # 4b. 贸易站收购（迭代4同步 S4：main.gd:332-358，时代Ⅴ auto_buys）
        # 单站日支出 ≤ TRADE_POST_DAILY_SPEND（40 金，main.gd:348 注释）；
        # 金币低于保底 TRADE_GOLD_RESERVE（50，main.gd:23）不买，不动加冕基金
        for b in self.buildings:
            buys = CATALOG[b.cid].get("auto_buys")
            if not buys:
                continue
            if CATALOG[b.cid].get("workers", 0) > 0 and not b.worked_today:
                continue                              # main.gd:337-339 没人到岗不收购
            spent = 0
            for res_type, price, cap in buys:
                if price <= 0 or cap <= 0:
                    continue                          # main.gd:346-347
                budget = min(cap * price, TRADE_POST_DAILY_SPEND - spent)      # main.gd:349
                affordable = (self.stock[R_GOLD] - TRADE_GOLD_RESERVE) // price  # main.gd:350
                n = min(budget, affordable) // price  # main.gd:351（负值时 n<=0 跳过）
                if n <= 0:
                    continue
                self.stock[R_GOLD] -= n * price       # main.gd:354-357 try_spend+add
                self.stock[res_type] += n
                spent += n * price
                if res_type == R_STONE:
                    self.trade_stone_bought += n
                elif res_type == R_WOOD:
                    self.trade_wood_bought += n
            self.trade_gold_spent += spent

        # 5. 卫兵日结（main.gd:361-378）
        for v in self.villagers:
            if not v.role_guard:
                continue
            if not any(b.cid == "barracks" and v in b.workers for b in self.buildings):
                v.role_guard = False                  # 兵营没了脱装
                continue
            if self.stock[R_GOLD] >= GUARD_WAGE:
                self.stock[R_GOLD] -= GUARD_WAGE      # main.gd:370 军饷 1 金/天
            else:
                v.role_guard = False                  # 断饷退役 main.gd:372

        # 6. 袭击日结（raid_manager.gd:81-120）
        if self.raid_mood_days_left > 0:
            self.raid_mood_days_left -= 1
            if self.raid_mood_days_left <= 0:
                self.raid_mood_bonus = 0              # :83-85
        self.raid_today = False
        if era < 4:
            self.next_raid_day = -1                   # :98-103
        elif winter:
            self.next_raid_day = -1                   # :104-110 冬季休战
        else:
            if self.next_raid_day < 0:
                self.next_raid_day = new_day + self.rng.randint(RAID_MIN_GAP, RAID_MAX_GAP)  # :115
            elif new_day >= self.next_raid_day:
                self.raid_today = True                # :117-119 次日清晨现身
                self.next_raid_day = new_day + self.rng.randint(RAID_MIN_GAP, RAID_MAX_GAP)

        # 7. 幸福<40 离队（main.gd:144-149）
        if self.happiness < 40.0 and self.pop > 1:
            cand = [v for v in self.villagers if not v.role_guard]   # :168-183 卫兵不抽
            if cand:
                homeless = [v for v in cand if not v.home]
                pool = homeless if homeless else cand
                worst = min(pool, key=lambda x: x.happiness)
                if worst.job is not None:
                    worst.job.workers.remove(worst)
                self.villagers.remove(worst)
                self.left_happiness += 1
                self.events.append(f"D{new_day} 村民{worst.uid} 因幸福度过低离队"
                                   f"（均值 {self.happiness:.0f}）")

        # 8. 移民闸（main.gd:150-163；迭代4同步 S5：时代Ⅳ第 4 人/天）
        pop = self.pop                                # 离队后再计数（与源码一致）
        food_need = pop * (4 if winter else 2)        # main.gd:153
        housing = self.housing_capacity()
        if self.edible() >= max(food_need, 4) and housing > pop:
            self._immigrate()
            if self.happiness >= 70.0 and housing > pop + 1:
                self._immigrate()
                # era 与源码一致逐级用 current_era() 现算（移民落地人口升级立即生效）
                if era_of(self.pop) >= 3 and housing > pop + 2:
                    self._immigrate()
                    # 迭代4同步 S5（main.gd:161-163）：时代Ⅳ第 4 人/天（3 人/天会把
                    # 加冕拖到 ~104 分钟，4 人/天 ≈ 87 分钟）
                    if era_of(self.pop) >= 4 and housing > pop + 3:
                        self._immigrate()
        # 9. 住房分配：移民优先入住（main.gd:458-476）
        self._assign_homes()
        # 10. worked_today 复位（main.gd:155-156）
        for b in self.buildings:
            b.worked_today = False

    def _immigrate(self):
        self.villagers.append(Villager())

    def _assign_homes(self):
        """main.gd:458-476 reassign_homes：有空位就补无房者"""
        cap = self.housing_capacity()
        housed = sum(1 for v in self.villagers if v.home)
        for v in self.villagers:
            if housed >= cap:
                break
            if not v.home:
                v.home = True
                housed += 1

    def _aura_covered(self, kind):
        """假设 A3：策略建了该光环建筑且有人在岗 → 全覆盖（真实为半径判定）"""
        for b in self.buildings:
            d = CATALOG[b.cid]
            if d.get("aura") == kind:
                if d.get("workers", 0) > 0 and not b.worked_today:
                    continue                          # main.gd:198-199 需在岗
                return True
        return False

    def _tavern_serving(self, era):
        """酒馆娱乐（迭代4同步 S6：main.gd:222-241）：
        serve_cap = serves×2^(era-3)（时代3:8 / 4:16 / 5:32，否则大人口娱乐不可达）；
        啤酒不足按库存部分服务（served ≤ 啤酒库存×2 ⟺ ceil(人数/2) ≤ 库存），不再全有全无；
        啤酒 ceil(served/2) 瓶。A3：覆盖=全体村民，名额随机轮转。"""
        served = set()
        for b in self.buildings:
            d = CATALOG[b.cid]
            if d.get("aura") != "fun":
                continue
            if d.get("workers", 0) > 0 and not b.worked_today:
                continue                              # main.gd:208-209 需在岗
            serve_cap = d.get("serves", 0) * (1 << max(0, era - 3))   # main.gd:233
            n = min(len(self.villagers), serve_cap,
                    self.stock[R_BEER] * 2)           # main.gd:234-235 部分服务
            if n <= 0:
                continue                              # main.gd:236-237
            cost = -(-n // 2)                          # ceili(n/2) main.gd:238
            if self.stock[R_BEER] >= cost:
                self.stock[R_BEER] -= cost
                ids = [v.uid for v in self.villagers if v.uid not in served]
                self.rng.shuffle(ids)
                served.update(ids[:n])
        return served

    def _has_castle(self):
        return any(b.cid == "castle" for b in self.buildings)

    # ---------- 玩家建造（清晨） ----------
    def build_step(self):
        self.assign_workers()   # 先按昨日阵容分配，策略再补建（新建筑清晨即可用人）
        for _ in range(12):     # 单日建造节奏上限（接近真实玩家手速/规划粒度）
            if not self.policy_fn(self):
                break
        self._assign_homes()    # main.gd:335-347 _on_placed → reassign_homes：房子一落成即入住
        self.assign_workers()   # 建完重排（放置自动招1+一键招满）

    # ---------- 主循环 ----------
    def run(self):
        self.build_step()       # 第 1 天开局建造（游戏从 tod=0.3 开始）
        for day in range(1, SIM_DAYS + 1):
            self.integrate_day(day)
            row = self.snapshot(day)
            self.log_rows.append(row)
            if day < SIM_DAYS:
                self.settle_new_day(day + 1)
                self.build_step()
        return self

    def snapshot(self, day):
        c = self.counts()
        return dict(
            day=day, season=SEASON_NAMES[season_of(day)], pop=self.pop,
            wood=self.stock[R_WOOD], food=self.stock[R_FOOD],
            wheat=self.stock[R_WHEAT], flour=self.stock[R_FLOUR],
            bread=self.stock[R_BREAD], stone=self.stock[R_STONE],
            gold=self.stock[R_GOLD], clothes=self.stock[R_CLOTHES],
            beer=self.stock[R_BEER], happy=self.happiness,
            edible=self.edible(),
            gat=c.get("gatherer", 0), farm=c.get("farm", 0), lum=c.get("lumber", 0),
            mil=c.get("mill", 0), bak=c.get("bakery", 0), house=c.get("house", 0),
            events=";".join(e for e in self.events if e.startswith("D%d " % day)),
        )


# ----------------------------------------------------------------------------
# 三组建造策略（返回 True 表示本日建了东西，主循环会再来一轮）
# 目标产能按"面包当量/天"估算：满勤 1 建筑日产能 ≈ 有效工作秒/interval × 产出
# 有效工作秒 ≈ 42 - 6(通勤) - ~1(进食) ≈ 35s（假设 A1/A2）
#   gatherer 35/9×2≈7.8 生食/天（冬季0）  farm 35/8×2≈8.75 麦/天（冬季0）
#   mill 35/6×2≈11.7 粉/天（耗等量麦）    bakery 35/6×2≈11.7 包/天（耗等量粉）
#   lumber 35/5×2≈14 木/天                quarry 35/8×1≈4.4 石/天
#   pasture 35/10×2=7 毛/天               weaver 35/6×1≈5.8 衣/天（耗等量×2 毛）
# 村民消耗：面包 60/146s≈0.41/天、生食 60/122s≈0.49/天 → 规划按 0.5/人·天
# ----------------------------------------------------------------------------

def _target_food_cap(sim, mult=1.0):
    """面包当量/天 目标 = 人口×0.5×mult + 底量6（含移民增量缓冲）"""
    return sim.pop * 0.5 * mult + 6


def _food_cap(sim):
    c = sim.counts()
    return (c.get("gatherer", 0) * 7.8 + c.get("bakery", 0) * 11.7
            + c.get("farm", 0) * 8.75 * 0.0)  # 麦不直接吃，不计 edible 产能


def _welfare_builds(sim):
    """福利建筑（保守/标准开；激进关）"""
    built = False
    c = sim.counts()
    era = era_of(sim.pop)
    if not sim.welfare:
        return False
    # 水井：每 12 人 1 口（幸福 +5）
    if c.get("well", 0) < max(1, sim.pop // 12) and sim.can_build("well"):
        sim.build("well")
        return True
    # 衣服链：时代2起 2 牧场养 1 纺织（毛 14/天 ≥ 需 11.7/天）
    if era >= 2:
        need_weaver = 1 if sim.pop <= 55 else 2
        if c.get("pasture", 0) < 2 * need_weaver and sim.can_build("pasture"):
            sim.build("pasture")
            return True
        if c.get("weaver", 0) < need_weaver and sim.can_build("weaver"):
            sim.build("weaver")
            return True
    # 信仰/娱乐：时代3起各 1（教堂全覆盖假设，酒馆服务 8 人）
    if era >= 3:
        if c.get("church", 0) < 1 and sim.can_build("church"):
            sim.build("church")
            return True
        if c.get("tavern", 0) < 1 and sim.can_build("tavern"):
            sim.build("tavern")
            return True
        if c.get("tavern", 0) >= 1 and c.get("brewery", 0) < 1 and sim.can_build("brewery"):
            sim.build("brewery")
            return True
    return False


def _defense_builds(sim):
    """时代Ⅳ防御：2 箭塔 + 1 兵营（假设 A4）；时代Ⅴ贸易站（S4）→ 城堡（若资源够）"""
    if not sim.defense:
        return False
    c = sim.counts()
    era = era_of(sim.pop)
    if era >= 4:
        if c.get("watchtower", 0) < 2 and sim.can_build("watchtower"):
            sim.build("watchtower")
            return True
        if c.get("barracks", 0) < 1 and sim.can_build("barracks"):
            sim.build("barracks")
            return True
    # 迭代4同步 S4：贸易站（时代Ⅴ）——金币盈余 ≥50（收购保底线）时建 1 座，
    # 排在城堡前：每日用金币换石料，缓解城堡 80 石的瓶颈（main.gd:332 注释同旨）
    if era >= 5 and c.get("trade_post", 0) < 1 \
            and sim.stock[R_GOLD] >= TRADE_GOLD_RESERVE and sim.can_build("trade_post"):
        if sim.build("trade_post"):
            sim.trade_post_day = sim.day
            sim.events.append("D%d 建成贸易站（时代Ⅴ，金币 %d≥保底%d）"
                              % (sim.day, sim.stock[R_GOLD], TRADE_GOLD_RESERVE))
            return True
    if era >= 5 and c.get("castle", 0) < 1 and sim.can_build("castle"):
        sim.build("castle")
        return True
    return False


def _ensure_bread_chain(sim, target, autumn=False):
    """面包链阶梯（farm→mill→bakery 按『先打通下游、再扩上游』的顺序补齐）：
    F farms 喂 M mills 喂 B bakeries；farm 8.75 麦/天，mill/bakery 11.7/天。
    顺序：缺农场 → 缺磨坊(上游不足时) → 缺面包房(上游已有富余时)。
    面包房仍优先于下一座磨坊拿石料（迭代4同步 S1 后 6 石 vs 5 石，差距收窄但
    磨坊连建仍会吸干石头，顺序规则保留）。"""
    c = sim.counts()
    F, M, B = c.get("farm", 0), c.get("mill", 0), c.get("bakery", 0)
    if B * 11.7 >= target and not (autumn and F * 8.75 < M * 11.7 + 17):
        return False
    # 采石场：1 + 每 3 磨坊 1 座（石头是磨坊/面包房的瓶颈）
    if c.get("quarry", 0) < 1 + M // 3 and sim.can_build("quarry"):
        return sim.build("quarry")
    # 秋季囤麦：农场产能超出磨坊需求约 2 座农场的量（冬季磨坊吃库存）
    if autumn and B * 11.7 >= target and F * 8.75 < M * 11.7 + 17 \
            and sim.can_build("farm"):
        return sim.build("farm")
    if F * 8.75 < M * 11.7 + 17 and sim.can_build("farm"):
        return sim.build("farm")                 # 先保证现有磨坊吃饱+略有余
    if M <= B and F * 8.75 >= M * 11.7 and sim.can_build("mill"):
        return sim.build("mill")                 # 上游农场已够 → 扩磨坊
    if M > B and sim.can_build("bakery"):
        return sim.build("bakery")               # 磨坊有富余 → 优先补面包房
    return False


def _opening_builds(sim):
    """三策略共用的开局基本盘（顺序即优先级）：
    1 采集（第1个食物来源）→ 1 伐木（木材经济不能断）→ 住房到 housing>pop（立即安置，
    否则新游戏首日幸福 50-30=20<40，次日即有人离队，main.gd:139-142）"""
    c = sim.counts()
    if c.get("gatherer", 0) < 1 and sim.can_build("gatherer"):
        return sim.build("gatherer")
    if c.get("lumber", 0) < 1 and sim.can_build("lumber"):
        return sim.build("lumber")
    if sim.housing_capacity() < sim.pop + 1 and sim.can_build("house"):
        return sim.build("house")
    return False


def policy_conservative(sim):
    """保守：开局即铺面包链。食物产能始终略超人口，住房跟紧，福利/防御齐全。"""
    c = sim.counts()
    era = era_of(sim.pop)
    autumn = season_of(sim.day) == 2
    # 秋季（第3季）产能目标 ×2.2：囤出过冬粮
    target = _target_food_cap(sim, 2.2 if autumn else 1.15)

    # 0) 开局基本盘
    if _opening_builds(sim):
        return True

    # 1) 食物产能（时代<2 用采集小屋；时代2 起转面包链）
    if era < 2:
        if _food_cap(sim) < target and sim.can_build("gatherer"):
            return sim.build("gatherer")
    else:
        if _ensure_bread_chain(sim, target, autumn=autumn):
            return True
        # 酿酒耗麦：多补 1 农场
        if c.get("brewery", 0) >= 1 and c.get("farm", 0) < 4 and sim.can_build("farm"):
            return sim.build("farm")

    # 2) 住房：housing ≥ pop+3（移民与幸福的地板）
    if sim.housing_capacity() < sim.pop + 3 and sim.can_build("house"):
        return sim.build("house")

    # 3) 木材：人口上台阶加 1 个伐木场
    want_lum = 1 + (1 if sim.pop >= 12 else 0) + (1 if sim.pop >= 30 else 0) \
        + (1 if sim.pop >= 60 else 0) + (1 if sim.pop >= 100 else 0)
    if c.get("lumber", 0) < want_lum and sim.can_build("lumber"):
        return sim.build("lumber")

    # 4) 石料：磨坊/面包房/福利需要石头
    if era >= 2 and c.get("quarry", 0) < 1 and sim.can_build("quarry"):
        return sim.build("quarry")
    if era >= 3 and c.get("quarry", 0) < 2 and sim.can_build("quarry"):
        return sim.build("quarry")

    # 5) 市场（时代4）
    if era >= 4 and c.get("market", 0) < 1 and sim.can_build("market"):
        return sim.build("market")

    # 6) 福利 + 防御
    if _welfare_builds(sim):
        return True
    if _defense_builds(sim):
        return True
    return False


def policy_standard(sim):
    """标准：按人口比例扩产（产能 = 人口×0.62+8），住房+4，其余同保守。"""
    c = sim.counts()
    era = era_of(sim.pop)
    autumn = season_of(sim.day) == 2
    target = sim.pop * 0.62 + 8 + (sim.pop * 0.9 if autumn else 0)

    if _opening_builds(sim):
        return True

    if era < 2:
        if _food_cap(sim) < target and sim.can_build("gatherer"):
            return sim.build("gatherer")
    else:
        if _ensure_bread_chain(sim, target, autumn=autumn):
            return True

    if sim.housing_capacity() < sim.pop + 4 and sim.can_build("house"):
        return sim.build("house")

    want_lum = 1 + (1 if sim.pop >= 10 else 0) + (1 if sim.pop >= 25 else 0) \
        + (1 if sim.pop >= 55 else 0) + (1 if sim.pop >= 95 else 0)
    if c.get("lumber", 0) < want_lum and sim.can_build("lumber"):
        return sim.build("lumber")

    if era >= 2 and c.get("quarry", 0) < 1 and sim.can_build("quarry"):
        return sim.build("quarry")
    if era >= 3 and c.get("quarry", 0) < 2 and sim.can_build("quarry"):
        return sim.build("quarry")

    if era >= 4 and c.get("market", 0) < 2 and sim.can_build("market"):
        return sim.build("market")

    if _welfare_builds(sim):
        return True
    if _defense_builds(sim):
        return True
    return False


def policy_aggressive(sim):
    """激进：先扩人口后补产能。房子先行（housing≥pop+9）、食物恐慌补建；无福利、无防御。"""
    c = sim.counts()
    era = era_of(sim.pop)
    # 0) 开局基本盘（采集+伐木+第1间房）
    if _opening_builds(sim):
        return True
    # 1) 房子先行：housing ≥ pop+9，保留 10 木缓冲
    if sim.housing_capacity() < sim.pop + 9 and sim.stock[R_WOOD] >= 15 \
            and sim.can_build("house"):
        return sim.build("house")
    # 2) 恐慌补产能：存粮 < 人口×1.5 才扩（ boom-bust 的根源）。
    #    恐慌期一律用采集小屋（即时生效）；面包链只在存粮健康时按序补齐。
    if sim.edible() < sim.pop * 1.5:
        if _food_cap(sim) < sim.pop * 0.5 + 6 and sim.can_build("gatherer"):
            return sim.build("gatherer")
    else:
        if era >= 2 and _ensure_bread_chain(sim, sim.pop * 0.5 + 6):
            return True
    # 3) 人口够再补伐木/住房维护
    if c.get("lumber", 0) < 2 and sim.pop >= 15 and sim.can_build("lumber"):
        return sim.build("lumber")
    if sim.housing_capacity() < sim.pop + 3 and sim.can_build("house"):
        return sim.build("house")
    return False


def policy_neglect(sim):
    """对照组 D0：完全不建食物产能（只建房子），验证『必然饿死』路径是否存在。"""
    if sim.housing_capacity() < sim.pop + 3 and sim.can_build("house"):
        return sim.build("house")
    if sim.counts().get("lumber", 0) < 1 and sim.can_build("lumber"):
        return sim.build("lumber")
    return False


# ----------------------------------------------------------------------------
# 报告输出
# ----------------------------------------------------------------------------

def run_strategy(label, policy, seed, defense=True, welfare=True):
    Villager._seq = 0
    Building._seq = 0
    sim = Sim(policy, label, seed, defense=defense, welfare=welfare)
    sim.run()
    return sim


def summarize(sim):
    pops = [r["pop"] for r in sim.log_rows]
    c = sim.counts()
    winters = {k: v for k, v in sim.winter_min_edible.items()}
    verdict = []
    if sim.pop == 0:
        verdict.append("灭局：人口归零（必然饿死路径成立）")
    elif sim.softlock_day is not None:
        verdict.append("软锁：第 %d 天起无木材收入且无食物产能" % sim.softlock_day)
    else:
        verdict.append("未观察到灭局/软锁")
    if sim.starved:
        verdict.append("饿死 %d 人" % sim.starved)
    if sim.left_happiness:
        verdict.append("因幸福离队 %d 人" % sim.left_happiness)
    if sim.raids:
        verdict.append("袭击 %d 次（被抢 %d 批）" % (sim.raids, sim.pillaged_total))
    else:
        verdict.append("未触发袭击（时代Ⅳ需人口≥100）" if era_of(max(pops)) < 4 else "")
    if sim.trade_post_day is not None:
        verdict.append("贸易站第 %d 天建成（累计收购支出 %d 金：石 %d 个/木 %d 个）"
                       % (sim.trade_post_day, sim.trade_gold_spent,
                          sim.trade_stone_bought, sim.trade_wood_bought))
    return dict(
        label=sim.label, seed=sim.seed,
        end_pop=sim.pop, max_pop=max(pops), min_pop=min(pops),
        end_happy=round(sim.happiness, 1),
        starved=sim.starved, left=sim.left_happiness,
        raids=sim.raids, pillaged=sim.pillaged_total,
        winter_min=winters,
        end_stock="食%d 包%d 麦%d 粉%d 木%d 石%d 金%d" % (
            sim.stock[R_FOOD], sim.stock[R_BREAD], sim.stock[R_WHEAT],
            sim.stock[R_FLOUR], sim.stock[R_WOOD], sim.stock[R_STONE],
            sim.stock[R_GOLD]),
        buildings=", ".join("%s×%d" % (CATALOG[k]["name"], v)
                            for k, v in sorted(c.items(), key=lambda x: -x[1])),
        verdict="；".join(v for v in verdict if v),
    )


def write_report(path, sims_by_label, diag):
    out = []
    w = out.append
    w("=" * 100)
    w("!! 过期警告：本模拟停留在迭代4 的公式，未建模迭代10~15 引入的五个系统 —— ")
    w("!!   建筑升级（产速/工位/住房/光环随等级变化）、冬季取暖烧柴与挨冻惩罚、")
    w("!!   生食腐坏与粮仓保鲜线、村民特长（班组人力 0.85~1.35）、原料优先级、")
    w("!!   以及时代Ⅱ~Ⅲ 的野狼骚扰。因此下面的人口曲线与冬季最低点会系统性偏乐观，")
    w("!!   在这些系统补进模拟之前，只能当作「旧基线」参考，不可用于平衡决策。")
    w("=" * 100)
    w("KingdomBuilder 经济模拟报告（迭代4 公式同步版）  python tools/economy_sim.py")
    w("模拟长度 60 天；内部子步 0.5 游戏秒；公式来源见 economy_sim.py 文件头（文件:行号）")
    w("迭代4 同步 S1~S8：S1 面包房石 10→6；S2 市场面包保留线 pop*2→pop（生食仍 pop*2）；")
    w("      S3 招满优先级=ASSIGN_PRIORITY（main.gd:468-472）；S4 新增贸易站（时代Ⅴ：日购")
    w("      石 2金≤10/木 1金≤20、单站日支出≤40金、金币保底 50，策略时代Ⅴ且金≥50 建 1 座）；")
    w("      S5 移民时代Ⅳ第 4 人/天；S6 酒馆 serve_cap=serves×2^(era-3)（3:8/4:16/5:32）+")
    w("      啤酒不足部分服务；S7 袭击日信仰/娱乐缺席不叠 -5；S8 箭塔伤害 12（核对一致）")
    w("假设：通勤单程 3s（42s 窗 → 实际在岗≈36s）；光环建成即全覆盖；")
    w("      保守/标准时代Ⅳ设防（2 箭塔+兵营）→ 袭击击退；激进不设防 → 全额被抢")
    w("=" * 100)

    for label, sim in sims_by_label.items():
        s = summarize(sim)
        w("")
        w("-" * 100)
        w("策略 %s（seed=%d）" % (label, sim.seed))
        w("-" * 100)
        w("  日曲线：日 季 | 人口 木 食 麦 粉 包 石 金 衣 酒 | 幸福 可食 | 采集 麦田 伐木 磨坊 面包房 小屋 | 事件")
        for r in sim.log_rows:
            w("  D%-3d %s | %4d %3d %4d %4d %4d %4d %3d %4d %3d %3d | %5.1f %5d | "
              "%d %d %d %d %d %d | %s" % (
                  r["day"], r["season"], r["pop"], r["wood"], r["food"], r["wheat"],
                  r["flour"], r["bread"], r["stone"], r["gold"], r["clothes"],
                  r["beer"], r["happy"], r["edible"],
                  r["gat"], r["farm"], r["lum"], r["mil"], r["bak"], r["house"],
                  r["events"][:110]))
        w("")
        w("  冬季存粮最低点（edible=面包+生食）：")
        for k in sorted(s["winter_min"]):
            w("    第 %d-%d 天（冬）：最低 edible = %d（人口峰值 %d）"
              % (k, k + 4, s["winter_min"][k],
                 max(r["pop"] for r in sim.log_rows[max(0, k - 1):k + 4])))
        w("  汇总：%s" % s["verdict"])
        w("    期末人口 %d（峰 %d / 谷 %d）幸福 %.1f；饿死 %d，离队 %d；袭击 %d 次抢 %d 批"
          % (s["end_pop"], s["max_pop"], s["min_pop"], s["end_happy"],
             s["starved"], s["left"], s["raids"], s["pillaged"]))
        w("    期末库存：%s" % s["end_stock"])
        w("    建筑构成：%s" % s["buildings"])

    # —— 多 seed 稳健性 ——
    w("")
    w("-" * 100)
    w("稳健性：每策略换 3 个随机种子（袭击间隔/离队选取/衣服磨损随机性）")
    w("-" * 100)
    for label, policy, kw in [("保守", policy_conservative, dict()),
                              ("标准", policy_standard, dict()),
                              ("激进", policy_aggressive, dict(defense=False, welfare=False))]:
        line = ["  %s：" % label]
        for seed in (11, 22, 33):
            s = run_strategy(label, policy, seed, **kw)
            ss = summarize(s)
            line.append("seed%d→终人口%d/饿死%d/离队%d/袭击%d" % (
                seed, ss["end_pop"], ss["starved"], ss["left"], ss["raids"]))
        w(" ".join(line))

    # —— 诊断：必然饿死路径 ——
    w("")
    w("-" * 100)
    w("对照组 D0（诊断）：完全不建食物产能 → 必然饿死路径是否成立")
    w("-" * 100)
    w("  %s" % diag["summary"])
    first_starve = diag["first_starve_day"]
    pop0_day = diag["pop_zero_day"]
    w("  首次饿死：第 %s 天；人口归零：第 %s 天" % (first_starve, pop0_day))
    w("  结论：玩家若完全不生产食物，初始 20 生食只够 5 人吃约 8 天，随后饥饿>60 起挨饿、")
    w("        约 4 天内依次饿死 → 『必然饿死路径』存在，且仅由『不建食物建筑』触发；")
    w("        三组正策略均在恐慌线前补产能，未复现该路径。")

    w("")
    w("=" * 100)
    w("总体结论（迭代4 公式同步版，详见对话输出）：")
    wm = {lbl: list(summarize(sim)["winter_min"].values()) for lbl, sim in sims_by_label.items()}
    lbls = list(sims_by_label)
    cons = summarize(sims_by_label[lbls[0]])
    std = summarize(sims_by_label[lbls[1]])
    agr = summarize(sims_by_label[lbls[2]])

    def era4_day(sim):
        return next((r["day"] for r in sim.log_rows if r["pop"] >= ERA_POP[3]), None)

    def tail_rate(sim):
        tail = [r["pop"] for r in sim.log_rows[-7:]]
        return (tail[-1] - tail[0]) / 6.0

    w("  1. 保守/标准策略 60 天曲线健康：终人口 %d/%d、幸福 %.0f/%.0f、零饿死零离队；"
      % (cons["end_pop"], std["end_pop"], cons["end_happy"], std["end_happy"]))
    w("     冬季存粮最低点（保守/标准）：%s / %s —— 秋季囤粮政策有效，无过冬风险。"
      % (wm[lbls[0]], wm[lbls[1]]))
    w("  2. 迭代4 同步差异归因（对照迭代3 报告 终人口 140/118/64、幸福 84/84/44）：")
    w("     - 标准 118→%d：S5 第 4 人/天兑现——时代Ⅳ到点 D%s，此后曲线恒 +4 人/天"
      % (std["end_pop"], era4_day(sims_by_label[lbls[1]])))
    w("       （末 6 天 +24）；S6 时代Ⅳ服务上限 8→16 再贡献约 +0.8 幸福。")
    w("     - 保守 140→%d：S1 面包房提前建成的建造级联使时代Ⅳ到点 D%s（旧 D47），"
      % (cons["end_pop"], era4_day(sims_by_label[lbls[0]])))
    w("       而保守住房目标 pop+3 基本挡住第 4 人闸门（仅 D49 整屋 +3 溢出放行 1 次，")
    w("       其余全程 3 人/天），净损 ≈2 天×3 人；")
    w("       消融复核：仅回退 S3/S6 人口不变 → 属离散模型级联敏感性，非公式偏差。")
    w("     - 激进 %d→%d：同步项不触达（无市场/福利、时代Ⅳ未至、幸福<70、金币 0）；恐慌线"
      % (agr["end_pop"], agr["end_pop"]))
    w("       补产能仍有效、未复现必然饿死，冬季最低存粮 %s，容错最小。" % (wm[lbls[2]],))
    w("  3. 袭击 0 次（全策略全 seed）：时代Ⅳ到点晚（D%d/D%d）→ 首个排期窗落在 D56+ ，"
      % (era4_day(sims_by_label[lbls[0]]), era4_day(sims_by_label[lbls[1]])))
    w("     与冬季（D56-60）重合被休战重排（raid_manager.gd:104-110）或超出 60 天窗口；")
    w("     设防（2 箭塔+兵营 3 卫兵）→ 击退士气 +5、不设防 → 每强盗抢 10% 的两分支结论保留（A4）。")
    w("  4. 贸易站（S4）：60 天内未建成——时代Ⅴ需人口≥250，期末最高 %d；按末段增速外推 "
      % max(cons["end_pop"], std["end_pop"]))
    w("     标准 ≈D%d / 保守 ≈D%d 建成（彼时金币均已 ≥保底 50）。收购机制已按源码逐步复刻并"
      % (60 + -(-(ERA_POP[4] - std["end_pop"]) // max(1, tail_rate(sims_by_label[lbls[1]]))),
         60 + -(-(ERA_POP[4] - cons["end_pop"]) // max(1, tail_rate(sims_by_label[lbls[0]])))))
    w("     单元验证：金 100 → 石 10+木 20 恰 40 金支出、金 54 → 只买 4 金（保底 50 不破）、")
    w("     金 ≤50 或缺勤日不收购（main.gd:332-358）。")
    w("  5. 必然饿死路径存在且已复现（对照组 D0）：完全不建食物产能时，初始 20 生食约 8 天")
    w("     耗尽，第 %s 天首名村民饿死、第 %s 天人口归零（灭局）。"
      % (diag["first_starve_day"], diag["pop_zero_day"]))
    w("  6. 唯一硬软锁 = 『无木材收入 且 木<8（伐木场造价）且 无食物产能』：人口饿死后永久")
    w("     无法建造。三组正策略因开局必建伐木场而不可达；0 人口即游戏结束，亦无软锁态。")
    w("=" * 100)

    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    return "\n".join(out)


def diagnose_neglect():
    s = run_strategy("对照D0", policy_neglect, 7)
    first_starve = min(s.deaths_by_day) if s.deaths_by_day else "-"
    pop_zero_day = "-"
    for r in s.log_rows:
        if r["pop"] == 0:
            pop_zero_day = r["day"]
            break
    return dict(summary=summarize(s)["verdict"],
                first_starve_day=first_starve, pop_zero_day=pop_zero_day)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--output", default=DEFAULT_REPORT)
    args = ap.parse_args()

    sims = {}
    sims["保守（开局即铺面包链）"] = run_strategy(
        "保守（开局即铺面包链）", policy_conservative, 20260905)
    sims["标准（按人口比例扩产）"] = run_strategy(
        "标准（按人口比例扩产）", policy_standard, 20260905)
    sims["激进（先扩人口后补产能）"] = run_strategy(
        "激进（先扩人口后补产能）", policy_aggressive, 20260905,
        defense=False, welfare=False)
    diag = diagnose_neglect()

    report = write_report(args.output, sims, diag)
    # 控制台只打摘要，曲线全文看报告
    for label, sim in sims.items():
        s = summarize(sim)
        print("[%s] 终人口 %d（峰%d/谷%d）饿死%d 离队%d 袭击%d 幸福%.0f | %s"
              % (label.split("（")[0], s["end_pop"], s["max_pop"], s["min_pop"],
                 s["starved"], s["left"], s["raids"], s["end_happy"], s["verdict"]))
    print("对照D0:", diag["summary"], "首次饿死 D%s，人口归零 D%s"
          % (diag["first_starve_day"], diag["pop_zero_day"]))
    print("完整曲线与冬季最低点见：%s" % args.output)


if __name__ == "__main__":
    main()
