extends Node

## One-off: the scanned games' ids and titles, in order (the art cache is keyed by id).
func _ready() -> void:
	var plugin := LinuxPlugin.new()
	var lib: Dictionary = plugin.library(0)
	var parsed: Variant = JSON.parse_string(str(lib["library"]))
	var current: Dictionary = {}
	if parsed is Dictionary:
		current = parsed
	var games: Array = current.get("games", [])
	var i := 0
	for game_raw: Variant in games:
		var game: Dictionary = game_raw
		print("%d\t%s\t%s" % [i, str(game["platform_id"]), str(game["title"])])
		i += 1
	get_tree().quit()
