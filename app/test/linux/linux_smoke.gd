# SPDX-License-Identifier: GPL-3.0-or-later
extends SceneTree
## The headless smoke test of [LinuxPlugin]: it scans the fixture folder (the `--games-dir`
## argument), rehearses each launch, checks the scan and the rehearsal, and quits with the
## number of failures.
##
## Run:
##   godot --headless --path <app> -s res://test/linux/linux_smoke.gd -- --games-dir=<roms>

var _failures := 0
var _done := false


func _initialize() -> void:
	print("== Cartouche (Linux) smoke test ==")
	var roms := LinuxPlugin.games_dir()
	print("games dir: %s" % roms)
	var plugin := LinuxPlugin.new()
	var reports: Array = []
	plugin.launch_reported.connect(func(r: Dictionary) -> void: reports.append(r))

	# -- the library -----------------------------------------------------------
	var answer: Dictionary = plugin.library(1)
	var ok: bool = answer.get("ok", false)
	_check(ok, "library answers ok")
	var library: Dictionary = JSON.parse_string(str(answer.get("library", "{}")))
	var library_holds_games: bool = library is Dictionary and not library.is_empty()
	_check(library_holds_games, "library is JSON")
	var games: Array = library.get("games", [])
	_check(games.size() == 4, "4 games found, got %d" % games.size())
	var shelves_found: Dictionary = library.get("shelves", {})
	var shelves: Array = shelves_found.get("shelves", [])
	_check(shelves.size() == 4, "4 shelves, got %d" % shelves.size())
	var by_title := {}
	for game: Dictionary in games:
		var game_title: String = str(game["title"])
		by_title[game_title] = game
	_check("Tetris" in by_title, "Tetris identified by title")
	_check("Super Mario World" in by_title, "Super Mario World identified by title")
	_check("Final Fantasy X" in by_title, "Final Fantasy X identified by title")
	_check("Final Fantasy VII" in by_title, "Final Fantasy VII identified by title")

	var tetris: Dictionary = by_title.get("Tetris", {})
	var tetris_platform: String = str(tetris.get("platform_id", ""))
	_check(tetris_platform == "nes", "Tetris is a nes game")
	var tetris_identified: bool = tetris.get("identified", false)
	_check(tetris_identified, "Tetris identified")
	var smw: Dictionary = by_title.get("Super Mario World", {})
	var smw_platform: String = str(smw.get("platform_id", ""))
	_check(smw_platform == "snes", "Super Mario World is a snes game")
	var ffx: Dictionary = by_title.get("Final Fantasy X", {})
	var ffx_platform: String = str(ffx.get("platform_id", ""))
	_check(ffx_platform == "ps2", "Final Fantasy X is a ps2 game")
	var ffx_serials: Array = ffx.get("serials", [])
	_check("SLPM-66124" in ffx_serials, "FFX serial SLPM-66124 parsed, got %s" % str(ffx_serials))
	var ffx7: Dictionary = by_title.get("Final Fantasy VII", {})
	var ffx7_platform: String = str(ffx7.get("platform_id", ""))
	_check(ffx7_platform == "psx", "Final Fantasy VII is a psx game")
	var ffx7_serials: Array = ffx7.get("serials", [])
	_check("SCES-00867" in ffx7_serials, "FFVII serial SCES-00867 parsed, got %s" % str(ffx7_serials))

	# -- the set-aside files ----------------------------------------------------
	var not_games: Dictionary = library.get("not_games", {})
	var nes_not_games: Array = not_games.get("nes", [])
	_check("too_small.nes" in nes_not_games, "too_small.nes is a not_game of nes")
	var ignored: Dictionary = library.get("ignored_counts", {})
	var counts: Dictionary = ignored.get("*", {})
	var unsupported: Dictionary = counts.get("unsupported", {})
	var unsupported_count: int = unsupported.get("count", 0)
	_check(unsupported_count == 1, "readme.txt is unsupported")

	# -- the rehearsal: nothing starts, the report is printed -------------------
	var result: Dictionary = plugin.launchGame(2, {"game_id": str(tetris.get("id", "")), "disc": 0})
	var result_code: String = str(result.get("code", ""))
	_check(result_code == "linux_printed", "launch rehearsed (linux_printed), got %s" % result_code)
	plugin.launchGame(3, {"game_id": str(smw.get("id", "")), "disc": 0})
	plugin.launchGame(4, {"game_id": str(ffx.get("id", "")), "disc": 0})
	plugin.launchGame(5, {"game_id": str(ffx7.get("id", "")), "disc": 0})
	_check(reports.size() == 4, "four launch reports emitted, got %d" % reports.size())
	if reports.size() == 4:
		var r_tetris: Dictionary = reports[0]
		var tetris_crc: String = str(r_tetris.get("crc32", ""))
		_check(tetris_crc == "E9DC16B5", "Tetris rehearsal crc32 E9DC16B5, got %s" % tetris_crc)
		var tetris_file: String = str(r_tetris.get("file", ""))
		_check(tetris_file.ends_with("Tetris (USA).nes"), "Tetris rehearsal names its file")
		var r_smw: Dictionary = reports[1]
		var smw_crc: String = str(r_smw.get("crc32", ""))
		_check(smw_crc == "82D1063F", "S.M.World rehearsal crc32 82D1063F, got %s" % smw_crc)
		var r_ffx: Dictionary = reports[2]
		var r_ffx_serials: Array = r_ffx.get("serials", [])
		_check("SLPM-66124" in r_ffx_serials, "FFX rehearsal carries the serial")
		var chd: Variant = r_ffx.get("chd")
		if chd is Dictionary:
			var chd_data: Dictionary = chd
			var chd_type: int = chd_data.get("type", -1)
			_check(chd_type == 4, "FFX rehearsal carries the chd type")
			var chd_sectors: int = chd_data.get("sectors", -1)
			_check(chd_sectors == 16384, "FFX rehearsal carries the chd sectors")
			var chd_sector_size: int = chd_data.get("sector_size", -1)
			_check(chd_sector_size == 2048, "FFX rehearsal carries the chd sector size")
		else:
			_check(false, "FFX rehearsal carries a chd header")
		var r_ffx7: Dictionary = reports[3]
		var r_ffx7_serials: Array = r_ffx7.get("serials", [])
		_check("SCES-00867" in r_ffx7_serials, "FFVII rehearsal carries the serial")

	print("== failures: %d ==" % _failures)
	_done = true
	quit(_failures)


func _process(_delta: float) -> bool:
	return _done


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   %s" % msg)
	else:
		print("  FAIL %s" % msg)
		_failures += 1
