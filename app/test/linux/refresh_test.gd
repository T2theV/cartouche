# SPDX-License-Identifier: GPL-3.0-or-later
extends GdUnitTestSuite
## The refresh (a re-read the user did not ask for, a console folder's): a walk the last scan's
## walk left and the caches hold the reads reads nothing and stands the library as it stood; a
## file the folder brought is the only one read; a file the folder lost is gone, and no read.

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


func after_test() -> void:
	LinuxPlugin.set_games_dir("")
	LinuxPlugin.set_scan_cache_path("")
	LinuxPlugin.set_ref_cache_path("")
	DesktopPlugin.set_settings_path("")
	LinuxPlugin._parse_io = 0
	_wipe(WORK)


## A folder that did not change: its walk the last scan's walk left, its caches hold its reads,
## so the refresh reads nothing, and the library stands as it stood.
func test_the_refresh_reads_nothing_the_folder_does_not_change() -> void:
	var p := LinuxPlugin.new()
	var lib: Dictionary = JSON.parse_string(p.library(1))
	var library: Dictionary = lib.get("library", {})
	var games: Array = library.get("games", [])
	assert_int(games.size()).is_equal(2)
	assert_int(LinuxPlugin._parse_io).is_equal(2)

	LinuxPlugin._parse_io = 0
	var answer: Dictionary = JSON.parse_string(p.refreshPlatform(1, "psx"))
	assert_bool(answer.get("ok", false)).override_failure_message("the refresh stands").is_true()
	assert_int(LinuxPlugin._parse_io).is_zero() \
		.override_failure_message("the unchanged folder's refresh reads no file, got %d" % LinuxPlugin._parse_io)
	var games_in_answer: int = answer.get("games", -1)
	assert_int(games_in_answer).is_equal(2) \
		.override_failure_message("the library stands as it stood, got %d" % games_in_answer)
	var lib2: Dictionary = JSON.parse_string(p.library(1))
	assert_bool(lib2 == lib).override_failure_message("the library stands as it stood").is_true()


## A file the folder brought: the only one the refresh reads, its game's in the library.
func test_the_refresh_brings_the_files_the_folder_brought() -> void:
	var p := LinuxPlugin.new()
	p.library(1)
	assert_int(LinuxPlugin._parse_io).is_equal(2)

	_write_pattern_file(ROMS.path_join("psx/Delta.iso"), 65536, 3)
	LinuxPlugin._parse_io = 0
	var answer: Dictionary = JSON.parse_string(p.refreshPlatform(1, "psx"))
	var games_in_answer: int = answer.get("games", -1)
	assert_int(games_in_answer).is_equal(3) \
		.override_failure_message("the new game's in the library, got %d" % games_in_answer)
	assert_int(LinuxPlugin._parse_io).is_equal(1) \
		.override_failure_message("only the new file is read, got %d" % LinuxPlugin._parse_io)


## A file the folder lost: gone from the walk, gone from the library, and no read.
func test_the_refresh_leaves_the_files_the_folder_lost() -> void:
	var p := LinuxPlugin.new()
	p.library(1)
	assert_int(LinuxPlugin._parse_io).is_equal(2)

	DirAccess.remove_absolute(ROMS.path_join("psx/Gamma.iso"))
	LinuxPlugin._parse_io = 0
	var answer: Dictionary = JSON.parse_string(p.refreshPlatform(1, "psx"))
	var games_in_answer: int = answer.get("games", -1)
	assert_int(games_in_answer).is_equal(1) \
		.override_failure_message("the lost game's gone, got %d" % games_in_answer)
	assert_int(LinuxPlugin._parse_io).is_zero() \
		.override_failure_message("the lost file's no read, got %d" % LinuxPlugin._parse_io)


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
