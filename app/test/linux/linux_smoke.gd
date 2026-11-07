# SPDX-License-Identifier: GPL-3.0-or-later
extends Node
## The headless smoke test of [LinuxPlugin]: it scans the fixture folder (the `--games-dir`
## argument), rehearses each launch, checks the scan and the rehearsal, and quits with the
## number of failures.
##
## Run:
##   godot --headless --path <app> res://test/linux/linux_smoke.tscn -- --games-dir=<roms>
##
## The fixtures, in `roms/` beside the app, each matched against the bundled reference lists:
## a Tetris NES ROM (its print in the NES prints), a Super Mario World SNES ROM (its 512-byte
## copier header not in its print), a zipped Super Mario Bros ROM (its print the CRC its archive
## records), a Final Fantasy X PS2 disc as a MAME v5 CHD (its serial in the PS2 titles), and a
## Final Fantasy VII PSX disc as a plain ISO (its serial in the PSX titles); beside them a file
## too small to be a game and one no platform lists, and, under folders named for platforms, a
## Dreamcast CHD and a GameCube RVZ (the folder, not the extension, is the platform) and a bios
## under a folder no platform names (not a game).

var _failures := 0


func _ready() -> void:
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
	_check(games.size() == 7, "7 games found, got %d" % games.size())
	var shelves_found: Dictionary = library.get("shelves", {})
	var shelves: Array = shelves_found.get("shelves", [])
	_check(shelves.size() == 6, "6 shelves, got %d" % shelves.size())
	var by_title := {}
	for game: Dictionary in games:
		var game_title: String = str(game["title"])
		by_title[game_title] = game
	_check("Tetris" in by_title, "Tetris in the library")
	_check("Super Mario World" in by_title, "Super Mario World in the library")
	_check("Super Mario Bros." in by_title, "Super Mario Bros (the zip) in the library")
	_check("Final Fantasy X" in by_title, "Final Fantasy X in the library")
	_check("Final Fantasy VII (Europe) (Disc 1)" in by_title, "Final Fantasy VII in the library")
	var tetris: Dictionary = by_title.get("Tetris", {})
	var tetris_platform: String = str(tetris.get("platform_id", ""))
	_check(tetris_platform == "nes", "Tetris is a nes game, got %s" % tetris_platform)
	var tetris_identified: bool = tetris.get("identified", false)
	_check(tetris_identified, "Tetris identified by its print")
	var smw: Dictionary = by_title.get("Super Mario World", {})
	var smw_platform: String = str(smw.get("platform_id", ""))
	_check(smw_platform == "snes", "Super Mario World is a snes game, got %s" % smw_platform)
	var smb: Dictionary = by_title.get("Super Mario Bros.", {})
	var smb_platform: String = str(smb.get("platform_id", ""))
	_check(smb_platform == "nes", "the zip's ROM makes it a nes game, got %s" % smb_platform)
	var ffx: Dictionary = by_title.get("Final Fantasy X", {})
	var ffx_platform: String = str(ffx.get("platform_id", ""))
	_check(ffx_platform == "ps2", "Final Fantasy X is a ps2 game, got %s" % ffx_platform)
	var ffx_serials: Array = ffx.get("serials", [])
	_check("SLPM_661.24" in ffx_serials, "FFX serial SLPM_661.24 read from its CHD, got %s" % str(ffx_serials))
	var ffx_identified: bool = ffx.get("identified", false)
	_check(ffx_identified, "FFX identified by its serial")
	var ffx7: Dictionary = by_title.get("Final Fantasy VII (Europe) (Disc 1)", {})
	var ffx7_platform: String = str(ffx7.get("platform_id", ""))
	_check(ffx7_platform == "psx", "Final Fantasy VII is a psx game, got %s" % ffx7_platform)
	var ffx7_serials: Array = ffx7.get("serials", [])
	_check("SCES_008.67" in ffx7_serials, "FFVII serial SCES_008.67 read from its ISO, got %s" % str(ffx7_serials))
	var ffx7_identified: bool = ffx7.get("identified", false)
	_check(ffx7_identified, "FFVII identified by its serial")
	var sa: Dictionary = by_title.get("Sonic Adventure (USA)", {})
	var sa_platform: String = str(sa.get("platform_id", ""))
	_check(sa_platform == "dreamcast", "the folder makes it a dreamcast game, got %s" % sa_platform)
	var fzero: Dictionary = by_title.get("F-Zero GX", {})
	var fzero_platform: String = str(fzero.get("platform_id", ""))
	_check(fzero_platform == "gc", "the folder makes it a gc game, got %s" % fzero_platform)

	# -- the set-aside files ----------------------------------------------------
	var not_games: Dictionary = library.get("not_games", {})
	var nes_not_games: Array = not_games.get("nes", [])
	_check("too_small.nes" in nes_not_games, "too_small.nes is a not_game of nes")
	var ignored: Dictionary = library.get("ignored_counts", {})
	var counts: Dictionary = ignored.get("*", {})
	var unsupported: Dictionary = counts.get("unsupported", {})
	var unsupported_count: int = unsupported.get("count", 0)
	_check(unsupported_count == 2, "readme.txt and the bios are the unsupported files, got %d" % unsupported_count)

	# -- the rehearsal: nothing starts, the report is printed -------------------
	var result: Dictionary = plugin.launchGame(2, {"game_id": str(tetris.get("id", "")), "disc": 0})
	var result_code: String = str(result.get("code", ""))
	_check(result_code == "linux_printed", "launch rehearsed (linux_printed), got %s" % result_code)
	plugin.launchGame(3, {"game_id": str(smw.get("id", "")), "disc": 0})
	plugin.launchGame(4, {"game_id": str(smb.get("id", "")), "disc": 0})
	plugin.launchGame(5, {"game_id": str(ffx.get("id", "")), "disc": 0})
	plugin.launchGame(6, {"game_id": str(ffx7.get("id", "")), "disc": 0})
	_check(reports.size() == 5, "five launch reports emitted, got %d" % reports.size())
	if reports.size() == 5:
		var r_tetris: Dictionary = reports[0]
		var tetris_crc: String = str(r_tetris.get("crc32", ""))
		_check(tetris_crc == "1394F57E", "Tetris rehearsal print 1394F57E, got %s" % tetris_crc)
		var tetris_file: String = str(r_tetris.get("file", ""))
		_check(tetris_file.ends_with("Tetris (USA).nes"), "Tetris rehearsal names its file")
		var r_smw: Dictionary = reports[1]
		var smw_crc: String = str(r_smw.get("crc32", ""))
		_check(smw_crc == "B19ED489", "S.M.World rehearsal print B19ED489, got %s" % smw_crc)
		var r_smb: Dictionary = reports[2]
		var smb_crc: String = str(r_smb.get("crc32", ""))
		_check(smb_crc == "393A432F", "the zip's rehearsal print is what its archive records, got %s" % smb_crc)
		var r_ffx: Dictionary = reports[3]
		var r_ffx_serials: Array = r_ffx.get("serials", [])
		_check("SLPM_661.24" in r_ffx_serials, "FFX rehearsal carries the serial")
		var chd: Variant = r_ffx.get("chd")
		if chd is Dictionary:
			var chd_data: Dictionary = chd
			var chd_version: int = chd_data.get("version", -1)
			var chd_hunks: int = chd_data.get("hunks", -1)
			var chd_hunk_size: int = chd_data.get("hunk_size", -1)
			var chd_logical: int = chd_data.get("logical", -1)
			var chd_first: int = chd_data.get("first_hunk", -1)
			_check(chd_version == 5, "FFX rehearsal carries the chd version")
			_check(chd_hunks == 16, "FFX rehearsal carries the chd hunks")
			_check(chd_hunk_size == 1048576, "FFX rehearsal carries the chd hunk size")
			_check(chd_logical == 16777216, "FFX rehearsal carries the chd logical size")
			_check(chd_first == 182, "FFX rehearsal carries the chd first hunk")
		else:
			_check(false, "FFX rehearsal carries a chd header")
		var r_ffx7: Dictionary = reports[4]
		var r_ffx7_serials: Array = r_ffx7.get("serials", [])
		_check("SCES_008.67" in r_ffx7_serials, "FFVII rehearsal carries the serial")

	print("== failures: %d ==" % _failures)
	get_tree().quit(_failures)


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   %s" % msg)
	else:
		print("  FAIL %s" % msg)
		_failures += 1
