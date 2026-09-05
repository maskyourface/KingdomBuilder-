extends Node
class_name ResourceManager

## 全局资源池（MVP 采用共享库存，后期可升级为搬运物流）。
## 建造扣费、生产产出、村民吃饭都走这里。

enum Type { WOOD, FOOD, WHEAT, FLOUR, BREAD, STONE, GOLD, WOOL, CLOTHES, BEER }

const NAMES := {
	Type.WOOD: "木材", Type.FOOD: "食物", Type.WHEAT: "小麦",
	Type.FLOUR: "面粉", Type.BREAD: "面包", Type.STONE: "石料", Type.GOLD: "金币",
	Type.WOOL: "羊毛", Type.CLOTHES: "衣服", Type.BEER: "啤酒",
}

signal changed

var stock: Dictionary = {}
## 全局平均幸福度（main 每天计算一次写入），建筑产量加成读它
var happiness := 50.0

func _ready() -> void:
	reset()

## 清空库存并给开局物资（新游戏时调用）
func reset() -> void:
	for t in Type.values():
		stock[t] = 0
	stock[Type.WOOD] = 40
	stock[Type.FOOD] = 30
	happiness = 50.0
	changed.emit()

func get_amount(t: int) -> int:
	return stock.get(t, 0)

func add(t: int, amount: int) -> void:
	stock[t] = get_amount(t) + amount
	changed.emit()

## costs 格式：[ [类型, 数量], ... ]
func has_all(costs: Array) -> bool:
	for c in costs:
		if get_amount(c[0]) < c[1]:
			return false
	return true

## 尝试扣一组资源，不足则不动并返回 false
func try_spend(costs: Array) -> bool:
	if not has_all(costs):
		return false
	for c in costs:
		stock[c[0]] = get_amount(c[0]) - c[1]
	changed.emit()
	return true

## 尝试消耗单个资源（村民吃饭用）
func try_consume(t: int, amount: int = 1) -> bool:
	if get_amount(t) < amount:
		return false
	stock[t] -= amount
	changed.emit()
	return true

## 可吃的东西总量（面包优先被吃，这里只统计）
func edible_amount() -> int:
	return get_amount(Type.BREAD) + get_amount(Type.FOOD)
