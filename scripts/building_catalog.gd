class_name BuildingCatalog

## 建筑目录：所有建筑的静态配置，纯数据。
## 新增建筑 = 在这里加一条字典，不用改任何逻辑代码。
## cost / inputs / outputs 格式：[ [资源类型, 数量], ... ]
## workers = 需要的工人数（>0 时必须有村民在岗才生产/生效）
## housing = 提供住房容量；is_road = 按道路放置（不占建筑位）
## desc = 一句话作用说明（详情面板首行，让每个建筑的作用一目了然）
## aura_radius + aura_kind = 覆盖半径光环（"well"/"faith"/"fun"/"castle"，每日结算幸福）
## serves = 酒馆每天最多服务人数（耗啤酒）；auto_sells = 市场每天自动卖富余换金币
## auto_buys = [ [类型, 单价, 日上限], ... ] 贸易站用金币收购资源
## hp = 耐久（城墙/城门，可被强盗打坏）；is_wall = 城墙；is_gate = 城门（村民可走/敌人不可走）
## shoots_range / shoots_damage / shoots_interval = 箭塔射击（需在岗工人）
## trains_guards = 兵营：工人变卫兵；drag_place = 按住左键拖动连放
## needs_forest/mountain/berry = 选址需邻近对应资源地块
## work_radius = 工作区域半径（选中时画圈显示采集范围）
## depletes = "forest"：生产一轮消耗工作半径内一格森林（伐木场）
## plants = "forest"：生产一轮在周边种出一格森林（植树场）
## no_winter = 冬季停产
## min_era = 解锁时代（建造菜单按此置灰）
## group = 建造菜单分组（food食物/resource资源/life民生/produce生产/defense防御）
## 选址规则：建设用地只能是平原（草地）；森林/浆果丛是资源地块，不可建设

const R := ResourceManager.Type

const ALL: Array[Dictionary] = [
	{
		"id": &"road", "group": "resource", "name": "土路",
		"color": Color(0.72, 0.62, 0.45), "size": Vector2i(1, 1),
		"cost": [[R.WOOD, 1]], "is_road": true, "drag_place": true,
		"desc": "村民走土路速度 +60%，寻路也会优先沿路走；可铺进森林成为林间小径",
	},
	{
		"id": &"house", "group": "life", "name": "小屋",
		"color": Color(0.75, 0.55, 0.35), "size": Vector2i(1, 1),
		"cost": [[R.WOOD, 5]],
		"produces": false, "housing": 3, "drag_place": true,
		"desc": "住 3 名村民：有房 +10 幸福，无家 -30；住房有空位且存粮够才会来新移民",
	},
	{
		"id": &"well", "group": "life", "name": "水井",
		"color": Color(0.4, 0.55, 0.7), "size": Vector2i(1, 1),
		"cost": [[R.WOOD, 3], [R.STONE, 2]],
		"produces": false, "aura_radius": 4.0, "aura_kind": "well",
		"desc": "水井光环：半径 4 格内有住房的村民幸福 +5（无房者吃不到光环）",
	},
	{
		"id": &"gatherer", "group": "food", "name": "采集小屋",
		"color": Color(0.6, 0.45, 0.55), "size": Vector2i(1, 1),
		"cost": [[R.WOOD, 6]],
		"produces": true, "inputs": [], "outputs": [[R.FOOD, 2]],
		"interval": 9.0, "needs_berry": true, "no_winter": true, "workers": 1,
		"work_radius": 2.0,
		"desc": "从浆果丛采集生食（冬季停产）；选中可查看采集范围",
	},
	{
		"id": &"fisher", "group": "food", "name": "渔屋",
		"color": Color(0.3, 0.5, 0.65), "size": Vector2i(1, 1),
		"cost": [[R.WOOD, 7]],
		"produces": true, "inputs": [], "outputs": [[R.FOOD, 2]],
		"interval": 10.0, "needs_water": true, "workers": 1,
		"work_radius": 2.0,
		"desc": "在水边捕鱼产生食（全年不停产，冬天靠它续粮）；需邻近水域",
	},
	{
		"id": &"lumber", "group": "resource", "name": "伐木场",
		"color": Color(0.45, 0.3, 0.15), "size": Vector2i(1, 1),
		"cost": [[R.WOOD, 8]],
		"produces": true, "inputs": [], "outputs": [[R.WOOD, 2]],
		"interval": 5.0, "needs_forest": true, "workers": 2,
		"work_radius": 3.0, "depletes": "forest", "depletes_every": 10,
		"desc": "每产约 10 轮（约 20 木材）砍掉工作范围内一格森林；砍光停产，用植树场补种",
	},
	{
		"id": &"farm", "group": "food", "name": "麦田",
		"color": Color(0.85, 0.75, 0.3), "size": Vector2i(2, 2),
		"cost": [[R.WOOD, 4]],
		"produces": true, "inputs": [], "outputs": [[R.WHEAT, 2]],
		"interval": 8.0, "converts_to_farm": true, "no_winter": true, "workers": 2,
		"drag_place": true,
		"desc": "把草地犁成耕地产小麦（冬季停产）；只能建在平原上，拆除后复垦为草地",
	},
	{
		"id": &"quarry", "group": "resource", "name": "采石场",
		"color": Color(0.5, 0.5, 0.55), "size": Vector2i(1, 1),
		"cost": [[R.WOOD, 10]],
		"produces": true, "inputs": [], "outputs": [[R.STONE, 1]],
		"interval": 8.0, "needs_mountain": true, "workers": 1,
		"work_radius": 2.0,
		"desc": "开采石料（磨坊/面包房/水井/箭塔都要石头）；需邻近石林，选中可查看开采范围",
	},
	{
		"id": &"nursery", "group": "resource", "name": "植树场",
		"color": Color(0.3, 0.55, 0.25), "size": Vector2i(1, 1),
		"cost": [[R.WOOD, 10]],
		"produces": true, "inputs": [], "outputs": [],
		"interval": 12.0, "workers": 1,
		"work_radius": 3.0, "plants": "forest",
		"desc": "每隔一段时间在周边草地种出一格森林，让伐木可持续；建议建在伐木场旁",
	},
	{
		"id": &"mill", "group": "food", "name": "磨坊",
		"color": Color(0.7, 0.7, 0.65), "size": Vector2i(1, 1),
		"cost": [[R.WOOD, 15], [R.STONE, 5]],
		"produces": true, "inputs": [[R.WHEAT, 2]], "outputs": [[R.FLOUR, 2]],
		"interval": 6.0, "workers": 1, "min_era": 2,
		"desc": "把小麦磨成面粉（面包链中间环节）",
	},
	{
		"id": &"bakery", "group": "food", "name": "面包房",
		"color": Color(0.8, 0.5, 0.3), "size": Vector2i(1, 1),
		"cost": [[R.WOOD, 20], [R.STONE, 6]],
		"produces": true, "inputs": [[R.FLOUR, 2]], "outputs": [[R.BREAD, 2]],
		"interval": 6.0, "workers": 1, "min_era": 2,
		"desc": "把面粉烤成面包：面包回满饥饿度（生食只回一半），还 +10 幸福",
	},
	# ---- 时代Ⅱ：衣服链 ----
	{
		"id": &"pasture", "group": "produce", "name": "牧羊场",
		"color": Color(0.85, 0.82, 0.7), "size": Vector2i(2, 2),
		"cost": [[R.WOOD, 12]],
		"produces": true, "inputs": [], "outputs": [[R.WOOL, 2]],
		"interval": 10.0, "workers": 1, "min_era": 2,
		"desc": "放牧产羊毛（衣服链源头）",
	},
	{
		"id": &"weaver", "group": "produce", "name": "纺织坊",
		"color": Color(0.7, 0.5, 0.6), "size": Vector2i(1, 1),
		"cost": [[R.WOOD, 15], [R.STONE, 5]],
		"produces": true, "inputs": [[R.WOOL, 2]], "outputs": [[R.CLOTHES, 1]],
		"interval": 6.0, "workers": 1, "min_era": 2,
		"desc": "羊毛织成衣服；时代Ⅱ起每天清晨自动给没衣服的村民发一件（+10 幸福）",
	},
	{
		"id": &"stall", "group": "produce", "name": "货摊",
		"color": Color(0.8, 0.72, 0.45), "size": Vector2i(1, 1),
		"cost": [[R.WOOD, 10], [R.STONE, 2]],
		"produces": false, "workers": 1, "min_era": 2, "auto_sells": true,
		"sell_cap": 8,
		"desc": "小型集市：每天自动卖保留线以上的富余产物，上限 8 金（时代Ⅳ的市场是它的大号版）",
	},
	# ---- 时代Ⅲ：信仰与娱乐 ----
	{
		"id": &"church", "group": "life", "name": "教堂",
		"color": Color(0.9, 0.85, 0.6), "size": Vector2i(2, 2),
		"cost": [[R.WOOD, 20], [R.STONE, 15]],
		"produces": false, "workers": 1, "min_era": 3,
		"aura_radius": 6.0, "aura_kind": "faith",
		"desc": "信仰光环：半径 6 格内有住房的村民幸福 +10，覆盖不到 -5（需有人在岗）",
	},
	{
		"id": &"brewery", "group": "produce", "name": "酿酒坊",
		"color": Color(0.6, 0.4, 0.2), "size": Vector2i(1, 1),
		"cost": [[R.WOOD, 15], [R.STONE, 5]],
		"produces": true, "inputs": [[R.WHEAT, 2]], "outputs": [[R.BEER, 2]],
		"interval": 8.0, "workers": 1, "min_era": 3, "no_winter": true,
		"desc": "把小麦酿成啤酒供酒馆（冬季停产）；过剩的啤酒也能在市场卖钱",
	},
	{
		"id": &"tavern", "group": "life", "name": "酒馆",
		"color": Color(0.75, 0.45, 0.25), "size": Vector2i(1, 1),
		"cost": [[R.WOOD, 20], [R.STONE, 10]],
		"produces": false, "workers": 1, "min_era": 3,
		"aura_radius": 5.0, "aura_kind": "fun", "serves": 8,
		"desc": "娱乐光环：半径 5 格内村民幸福 +10（覆盖不到 -5）；服务消耗啤酒，上限随时代扩容",
	},
	# ---- 时代Ⅳ：市场与防御 ----
	{
		"id": &"market", "group": "produce", "name": "市场",
		"color": Color(0.9, 0.7, 0.3), "size": Vector2i(2, 2),
		"cost": [[R.WOOD, 25], [R.STONE, 10]],
		"produces": false, "workers": 1, "min_era": 4, "auto_sells": true,
		"desc": "每天自动卖出保留线以上的富余产物换金币（每市场每天上限 20 金）",
	},
	{
		"id": &"wall", "group": "defense", "name": "城墙",
		"color": Color(0.45, 0.45, 0.5), "size": Vector2i(1, 1),
		"cost": [[R.STONE, 2]], "min_era": 4,
		"hp": 60, "is_wall": true, "drag_place": true,
		"desc": "挡住强盗去路（耐久 60，被拆会坏）；敌人不能翻墙，只能拆墙或绕行",
	},
	{
		"id": &"gate", "group": "defense", "name": "城门",
		"color": Color(0.55, 0.4, 0.25), "size": Vector2i(1, 1),
		"cost": [[R.WOOD, 4], [R.STONE, 2]], "min_era": 4,
		"hp": 80, "is_gate": true, "drag_place": true,
		"desc": "村民可以穿行、强盗不能；和城墙围出城区（耐久 80）",
	},
	{
		"id": &"watchtower", "group": "defense", "name": "箭塔",
		"color": Color(0.5, 0.4, 0.3), "size": Vector2i(1, 1),
		"cost": [[R.WOOD, 10], [R.STONE, 8]], "min_era": 4, "workers": 1,
		"shoots_range": 6.0, "shoots_damage": 12, "shoots_interval": 1.5,
		"desc": "有弓箭手在岗时自动射击 6 格内的强盗（12 伤/1.5 秒），优先补刀残血",
	},
	{
		"id": &"barracks", "group": "defense", "name": "兵营",
		"color": Color(0.55, 0.3, 0.3), "size": Vector2i(2, 2),
		"cost": [[R.WOOD, 30], [R.STONE, 20]], "min_era": 4,
		"workers": 3, "trains_guards": true,
		"desc": "派进来的村民成为卫兵（120 血、主动迎击强盗，每天 1 金军饷）；撤出即退役",
	},
	# ---- 时代Ⅴ：贸易站与城堡 ----
	{
		"id": &"trade_post", "group": "produce", "name": "贸易站",
		"color": Color(0.6, 0.65, 0.5), "size": Vector2i(2, 1),
		"cost": [[R.WOOD, 25], [R.STONE, 10]], "min_era": 5,
		"workers": 2,
		# 每天用金币收购资源（[类型, 单价, 日上限]）：给金币持续出口、缓解城堡石料瓶颈
		"auto_buys": [[R.STONE, 2, 10], [R.WOOD, 1, 20]],
		"desc": "每天用金币收购石料（2 金/个，≤10）和木材（1 金/个，≤20）；金币低于 50 不收购",
	},
	{
		"id": &"castle", "group": "life", "name": "城堡",
		"color": Color(0.65, 0.6, 0.7), "size": Vector2i(4, 4),
		"cost": [[R.WOOD, 100], [R.STONE, 80], [R.GOLD, 50]],
		"produces": false, "min_era": 5, "aura_kind": "castle",
		"desc": "建成即加冕为王（全体 +10 幸福），此后进入自由建设",
	},
]

static func find_by_id(id: StringName) -> Dictionary:
	for d in ALL:
		if d["id"] == id:
			return d
	return {}
