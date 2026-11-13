# SPDX-License-Identifier: GPL-3.0-or-later
extends GdUnitTestSuite
## The one scan is the startup's: the folder's one walk, the files the caches do not hold read
## once. A refresh (a re-read the user did not ask for, one console a request) walks nothing
## and reads nothing, the library as it stands; a file the folder brought, or lost, shows
## only in a new run — the restart, its one scan.

const WORK := "/tmp/cartouche-refresh-test"
const ROMS := WORK + "/roms"


func before_test() -> void:
	_wipe(WORK)
	DirAccess.make_dir_recursive_absolute(ROMS.path_join("nes"))
	DirAccess.make_dir_recursive_absolute(ROMS.path_join("psx"))
	_write_pattern_file(ROMS.path_join("nes/Alpha.nes"), 16384, 1)
	_write_pattern_file(ROMS.path_join("psx/Gamma.iso"), 65536, 2)
	LinuxPlugin.set_games_dir(ROMS)
	LinuxPlugin.set_scan_cache_path(WORK + "/scan-cache.json")
	LinuxPlugin.set_ref_cache_path(WORK + "/ref-cache.json")
	DesktopPlugin.set_settings_path(WORK + "/settings.json")
	LinuxPlugin._parse_io = 0
	LinuxPlugin._walk_io = 0


func after_test() -> void:
	LinuxPlugin.set_games_dir("")
	LinuxPlugin.set_scan_cache_path("")
	LinuxPlugin.set_ref_cache_path("")
	DesktopPlugin.set_settings_path("")
	LinuxPlugin._parse_io = 0
	LinuxPlugin._walk_io = 0
	_wipe(WORK)


## The startup's scan: the folder's one walk, every game file the cold caches' read. A refresh
## (a re-read the user did not ask for, one console a request) walks nothing, reads nothing,
## and stands the library as it stood.
func test_the_startup_scan_is_the_one_scan() -> void:
	var p := LinuxPlugin.new()
	var lib: Dictionary = JSON.parse_string(p.library(1))
	var library: Dictionary = lib.get("library", {})
	var games: Array = library.get("games", [])
	assert_int(games.size()).is_equal(2)
	assert_int(LinuxPlugin._walk_io).is_equal(1) \
		.override_failure_message("the startup's scan is the one walk, got %d" % LinuxPlugin._walk_io)
	assert_int(LinuxPlugin._parse_io).is_equal(2)

	LinuxPlugin._parse_io = 0
	LinuxPlugin._walk_io = 0
	var platform_ids := PackedStringArray(["psx", "nes"])
	for platform_id: String in platform_ids:
		var answer: Dictionary = JSON.parse_string(p.refreshPlatform(1, platform_id))
		assert_bool(answer.get("ok", false)).override_failure_message("the refresh stands").is_true()
		var answer_library: Dictionary = answer.get("library", {})
		var answer_games: Array = answer_library.get("games", [])
		assert_int(answer_games.size()).is_equal(2) \
			.override_failure_message("the library stands as it stood, got %d" % answer_games.size())
		assert_int(LinuxPlugin._walk_io).is_zero() \
			.override_failure_message("the refresh's no walk, got %d" % LinuxPlugin._walk_io)
		assert_int(LinuxPlugin._parse_io).is_zero() \
			.override_failure_message("the refresh's no read, got %d" % LinuxPlugin._parse_io)
	var lib2: Dictionary = JSON.parse_string(p.library(1))
	assert_bool(lib2 == lib).override_failure_message("the library stands as it stood").is_true()


## A file the folder brought: the running run's refresh shows it not (no walk, no read, the
## library as it stood); a new run's one scan does, its file the only one read.
func test_the_new_game_shows_only_after_a_restart() -> void:
	var p := LinuxPlugin.new()
	p.library(1)
	assert_int(LinuxPlugin._parse_io).is_equal(2)
	assert_int(LinuxPlugin._walk_io).is_equal(1)

	_write_pattern_file(ROMS.path_join("psx/Delta.iso"), 65536, 3)
	LinuxPlugin._parse_io = 0
	LinuxPlugin._walk_io = 0
	var answer: Dictionary = JSON.parse_string(p.refreshPlatform(1, "psx"))
	assert_int(LinuxPlugin._walk_io).is_zero() \
		.override_failure_message("the new game's no walk, the restart's, got %d" % LinuxPlugin._walk_io)
	assert_int(LinuxPlugin._parse_io).is_zero() \
		.override_failure_message("the new game's no read, the restart's, got %d" % LinuxPlugin._parse_io)
	var answer_library: Dictionary = answer.get("library", {})
	var answer_games: Array = answer_library.get("games", [])
	assert_int(answer_games.size()).is_equal(2) \
		.override_failure_message("the new game's not shown until a restart, got %d" % answer_games.size())

	LinuxPlugin._parse_io = 0
	LinuxPlugin._walk_io = 0
	var q := LinuxPlugin.new()
	var restart: Dictionary = JSON.parse_string(q.library(1))
	var restart_library: Dictionary = restart.get("library", {})
	var restart_games: Array = restart_library.get("games", [])
	assert_int(restart_games.size()).is_equal(3) \
		.override_failure_message("the restart's one scan brings the new game, got %d" % restart_games.size())
	assert_int(LinuxPlugin._walk_io).is_equal(1) \
		.override_failure_message("the restart's one scan is the one walk, got %d" % LinuxPlugin._walk_io)
	assert_int(LinuxPlugin._parse_io).is_equal(1) \
		.override_failure_message("the restart's one scan reads the new file only, got %d" % LinuxPlugin._parse_io)


## A file the folder lost: the running run's refresh shows it still (no walk, no read, the
## library as it stood); a new run's one scan has it gone.
func test_the_lost_game_is_gone_after_a_restart() -> void:
	var p := LinuxPlugin.new()
	p.library(1)
	assert_int(LinuxPlugin._parse_io).is_equal(2)
	assert_int(LinuxPlugin._walk_io).is_equal(1)

	DirAccess.remove_absolute(ROMS.path_join("psx/Gamma.iso"))
	LinuxPlugin._parse_io = 0
	LinuxPlugin._walk_io = 0
	var answer: Dictionary = JSON.parse_string(p.refreshPlatform(1, "psx"))
	assert_int(LinuxPlugin._walk_io).is_zero() \
		.override_failure_message("the lost game's no walk, the restart's, got %d" % LinuxPlugin._walk_io)
	assert_int(LinuxPlugin._parse_io).is_zero() \
		.override_failure_message("the lost game's no read, the restart's, got %d" % LinuxPlugin._parse_io)
	var answer_library: Dictionary = answer.get("library", {})
	var answer_games: Array = answer_library.get("games", [])
	assert_int(answer_games.size()).is_equal(2) \
		.override_failure_message("the lost game stands until a restart, got %d" % answer_games.size())

	LinuxPlugin._parse_io = 0
	LinuxPlugin._walk_io = 0
	var q := LinuxPlugin.new()
	var restart: Dictionary = JSON.parse_string(q.library(1))
	var restart_library: Dictionary = restart.get("library", {})
	var restart_games: Array = restart_library.get("games", [])
	assert_int(restart_games.size()).is_equal(1) \
		.override_failure_message("the restart's one scan leaves the lost game, got %d" % restart_games.size())
	assert_int(LinuxPlugin._parse_io).is_zero() \
		.override_failure_message("the kept file's cached, no read, got %d" % LinuxPlugin._parse_io)


## [param size] bytes of a deterministic pattern (tagged), to [param path].
static func _write_pattern_file(path: String, size: int, tag: int) -> void:
	var data := PackedByteArray()
	data.resize(size)
	for i in size:
		data[i] = (tag * 131 + i * 17 + (i * 31) % 251) & 0xFF
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_buffer(data)
	file.close()


## [param path] and what is in it, away.
static func _wipe(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := path.path_join(entry)
		if dir.current_is_dir():
			_wipe(full)
		else:
			DirAccess.remove_absolute(full)
		entry = dir.get_next()
	DirAccess.remove_absolute(path)
