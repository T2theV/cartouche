# SPDX-License-Identifier: GPL-3.0-or-later
extends Node
## The headless launch test of [LinuxPlugin]: it writes stub emulators and `cartouche.conf`
## files in a temp dir, and through the conf's players rehearses and, for real, launches a
## fixture game, checking the selection (the first installed player whose `accept` matches,
## the uninstalled and the non-accepting skipped), the rehearsal, the real start (the stub's
## log), `stop_first` (the lingering instance the second launch stops), and the no-player
## refusal (a platform the conf does not list).
##
## Run:
##   godot --headless --path <app> res://test/linux/launch_test.tscn -- --games-dir=<roms>

const WORK := "/tmp/cartouche-launch-test"

var _failures := 0


func _ready() -> void:
	print("== Cartouche (Linux) launch test ==")
	var roms := LinuxPlugin.games_dir()
	print("games dir: %s" % roms)
	_prepare()
	var plugin := LinuxPlugin.new()
	var reports: Array = []
	plugin.launch_reported.connect(func(r: Dictionary) -> void: reports.append(r))

	# -- the library: the fixture ps2 game (a CHD) and a snes game (no conf for snes) ----
	var answer: Dictionary = plugin.library(1)
	var library_ok: bool = answer.get("ok", false)
	_check(library_ok, "library answers ok")
	var library: Dictionary = JSON.parse_string(str(answer.get("library", "{}")))
	var games: Array = library.get("games", [])
	var by_title := {}
	for game: Dictionary in games:
		by_title[str(game["title"])] = game
	var ffx: Dictionary = by_title.get("Final Fantasy X", {})
	var smw: Dictionary = by_title.get("Super Mario World", {})
	_check(not ffx.is_empty(), "the fixture has a ps2 game")
	_check(not smw.is_empty(), "the fixture has a snes game")

	# -- rehearsal: the conf's player stands, nothing is started ---------------------------
	LinuxPlugin.set_config(WORK + "/conf-rehearsal.conf")
	var rehearsal_result: Dictionary = plugin.launchGame(1, {"game_id": str(ffx.get("id", "")), "disc": 0})
	_check(str(rehearsal_result.get("code", "")) == "linux_printed",
		"the conf rehearsal answers linux_printed, got %s" % str(rehearsal_result.get("code", "")))
	_check(reports.size() == 1, "the rehearsal emitted a report, got %d" % reports.size())
	if reports.size() == 1:
		var r: Dictionary = reports[0]
		_check(str(r.get("player", "")) == "pcsx2",
			"the rehearsal names its player (skipping the alias miss, the uninstalled, the non-accepting), got %s" % str(r.get("player", "")))
		_check(str(r.get("binary", "")) == WORK + "/stubs/pcsx2",
			"the rehearsal names the player's binary, got %s" % str(r.get("binary", "")))
		_check(str(r.get("command", "")).contains("Final Fantasy X"),
			"the rehearsal renders the file path, got %s" % str(r.get("command", "")))

	# -- for real: the stub runs with the file ---------------------------------------------
	LinuxPlugin.set_config(WORK + "/conf-real.conf")
	var real_result: Dictionary = plugin.launchGame(2, {"game_id": str(ffx.get("id", "")), "disc": 0})
	_check(str(real_result.get("code", "")) == "linux_launched",
		"the launch answers linux_launched, got %s" % str(real_result.get("code", "")))
	var real_ok: bool = real_result.get("ok", false)
	_check(real_ok, "the launch answers ok")
	var logged: bool = await _wait_for_file(WORK + "/pcsx2.log", 5.0)
	_check(logged, "the stub ran (its log appeared)")
	if logged:
		var log_text := _read_text(WORK + "/pcsx2.log")
		_check(log_text.contains("Final Fantasy X"), "the stub got the file path, got %s" % log_text)

	# -- stop_first: the lingering instance the second launch stops -----------------------
	LinuxPlugin.set_config(WORK + "/conf-sleeper.conf")
	plugin.launchGame(3, {"game_id": str(ffx.get("id", "")), "disc": 0})
	var sleeper_started: bool = await _wait_for_file(WORK + "/sleeper.log", 5.0)
	_check(sleeper_started, "the sleeper started (its log appeared)")
	var first_pids: Array = _alive_pids(WORK + "/stubs/sleeper")
	_check(not first_pids.is_empty(), "the sleeper is running before the second launch")
	plugin.launchGame(4, {"game_id": str(ffx.get("id", "")), "disc": 0})
	await _seconds(1.0)
	var after_pids: Array = _alive_pids(WORK + "/stubs/sleeper")
	var old_gone := true
	for pid: String in first_pids:
		if pid in after_pids:
			old_gone = false
	_check(old_gone and not after_pids.is_empty(),
		"stop_first stopped the lingering sleeper and the second launch started a new one")

	# -- no player: the conf lists no snes --------------------------------------------------
	LinuxPlugin.set_config(WORK + "/conf-real.conf")
	var no_player: Dictionary = plugin.launchGame(5, {"game_id": str(smw.get("id", "")), "disc": 0})
	_check(str(no_player.get("code", "")) == "linux_no_player",
		"no snes player: linux_no_player, got %s" % str(no_player.get("code", "")))

	print("== failures: %d ==" % _failures)
	get_tree().quit(_failures)


func _prepare() -> void:
	OS.execute("rm", ["-rf", WORK])
	var killscript := "/tmp/cartouche-launch-kill.sh"
	var kf := FileAccess.open(killscript, FileAccess.WRITE)
	if kf != null:
		kf.store_string("pkill -f '%s/stubs/sleeper'\n" % WORK)
		kf.close()
	OS.execute("/bin/sh", [killscript])
	var made: int = DirAccess.make_dir_recursive_absolute(WORK + "/stubs")
	_check(made == OK, "the work dir is made, error %d" % made)
	_write(WORK + "/stubs/pcsx2", "#!/bin/sh\nprintf '%%s\\n' \"$@\" >> %s/pcsx2.log\n" % WORK)
	_write(WORK + "/stubs/sleeper", "#!/bin/sh\nprintf '%%s\\n' \"$@\" >> %s/sleeper.log\nsleep 30\n" % WORK)
	OS.execute("chmod", ["+x", WORK + "/stubs/pcsx2", WORK + "/stubs/sleeper"])
	_write(WORK + "/conf-rehearsal.conf", _conf_body("true"))
	_write(WORK + "/conf-real.conf", _conf_body("false"))
	var sleeper := "rehearsal = false\n"
	sleeper += "path = %s/stubs\n" % WORK
	sleeper += "\n[ps2]\n"
	sleeper += "sleeper = sleeper \"{file.path}\"\n"
	sleeper += "sleeper.stop_first = true\n"
	_write(WORK + "/conf-sleeper.conf", sleeper)


func _conf_body(rehearsal: String) -> String:
	var s := "rehearsal = %s\n" % rehearsal
	s += "path = %s/stubs\n" % WORK
	s += "alias.retroarch = /nowhere/retroarch\n"
	s += "\n[ps2]\n"
	s += "retroarch = retroarch \"{file.path}\"\n"
	s += "uninstalled = uninstalled {file.path}\n"
	s += "onlyiso = pcsx2 \"{file.path}\"\n"
	s += "onlyiso.accept = ^.*\\.iso$\n"
	s += "pcsx2 = pcsx2 \"{file.path}\"\n"
	s += "pcsx2.stop_first = true\n"
	return s


func _write(path: String, text: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("  FAIL cannot write %s" % path)
		_failures += 1
		return
	f.store_string(text)
	f.close()


func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


func _wait_for_file(path: String, seconds: float) -> bool:
	var waited := 0.0
	while not FileAccess.file_exists(path):
		if waited >= seconds:
			return false
		await get_tree().create_timer(0.1).timeout
		waited += 0.1
	return true


func _alive_pids(what: String) -> Array:
	# The engine re-tokenizes `OS.execute` arguments, so the pgrep stands in a file.
	var script := WORK + "/alive.sh"
	var sfile := FileAccess.open(script, FileAccess.WRITE)
	if sfile != null:
		sfile.store_string("pgrep -f '%s' > '%s' 2>/dev/null\n" % [what, WORK + "/pid"])
		sfile.close()
	OS.execute("/bin/sh", [script])
	var pids: Array = []
	var text := _read_text(WORK + "/pid").strip_edges()
	if not text.is_empty():
		for line: String in text.split("\n"):
			var pid: String = line.strip_edges()
			if pid.is_valid_int() and OS.execute("kill", ["-0", pid]) == 0:
				pids.append(pid)
	return pids


func _seconds(n: float) -> void:
	await get_tree().create_timer(n).timeout


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   %s" % msg)
	else:
		print("  FAIL %s" % msg)
		_failures += 1
