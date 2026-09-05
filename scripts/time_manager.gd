extends Node
class_name TimeManager

## 游戏内时间：昼夜循环 + 四季。
## 默认现实 60 秒 = 游戏 1 天，每 5 天换季。
## 其他系统连 new_day 信号做"每天一次"的事（人口增长等）。

enum Season { SPRING, SUMMER, AUTUMN, WINTER }
const SEASON_NAMES := {
	Season.SPRING: "春", Season.SUMMER: "夏",
	Season.AUTUMN: "秋", Season.WINTER: "冬",
}

@export var day_length_seconds := 60.0
@export var days_per_season := 5

var day := 1
## 0~1，0.25=清晨，0.5=正午，0.8 以后=夜晚
var time_of_day := 0.3
var season: int = Season.SPRING

signal new_day

func _process(delta: float) -> void:
	time_of_day += delta / day_length_seconds
	if time_of_day >= 1.0:
		time_of_day -= 1.0
		day += 1
		season = int((day - 1) / days_per_season) % 4
		new_day.emit()

func is_winter() -> bool:
	return season == Season.WINTER

## 距入冬还有几天（冬季中返回 0），顶栏存粮预警用
func days_until_winter() -> int:
	if season == Season.WINTER:
		return 0
	var pos := (day - 1) % days_per_season
	var ahead := (Season.WINTER - season + 4) % 4
	return ahead * days_per_season - pos

## 0.15~0.85 为白天（工作窗 70%），缩短夜间空转等待
func is_night() -> bool:
	return time_of_day > 0.85 or time_of_day < 0.15

func day_text() -> String:
	return "第%d天 %s季" % [day, SEASON_NAMES[season]]
