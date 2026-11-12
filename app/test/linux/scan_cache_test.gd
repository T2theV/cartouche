# SPDX-License-Identifier: GPL-3.0-or-later
extends GdUnitTestSuite
## The scan's parse cache: the first scan of a folder parses its game files (its prints, its
## serials, its CHD headers), and writes the parse keyed on each file's path, size, and mtime;
## a fresh boot of an unchanged folder reads the parse, not the file; a changed file is the
## only one read again. The games the cache serves stand for the files' reads, so the library
## is the same as without the cache.
##
## Hermetic: its own temp folder of made-up game files and its own cache file (the fixtures'
## and the user's data's, neither).

const WORK := "/tmp/cartouche-scan-cache-test"
const ROMS := WORK + "/roms"
const CACHE := WORK + "/scan-cache.json"


func before_test() -> void:
	_wipe(WORK)
	DirAccess.make_dir_recursive_absolute(ROMS.path_join("nes"))
	DirAccess.make_dir_recursive_absolute(ROMS.path_join("psx"))
	_write_pattern_file(ROMS.path_join("nes/Alpha.nes"), 16384, 1)
	_write_pattern_file(ROMS.path_join("psx/Gamma.iso"), 65536, 2)
	LinuxPlugin.set_games_dir(ROMS)
	LinuxPlugin.set_scan_cache_path(CACHE)
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


## The one folder, two games: a cartridge (its print the CRC of its bytes) and a disc (its
## serial, none in made-up bytes), the cache's work measured by [LinuxPlugin._parse_io].
func test_scan_cache_round_trip() -> void:
	# The first scan of the folder: every game file parsed, the cache written.
	var p1 := LinuxPlugin.new()
	var lib1: Dictionary = JSON.parse_string(p1.library(1))
	var library1: Dictionary = lib1.get("library", {})
	var games1: Array = library1.get("games", [])
	assert_int(games1.size()).is_equal(2).override_failure_message("two games found")
	assert_int(LinuxPlugin._parse_io).is_equal(games1.size()) \
		.override_failure_message("the first scan parses every game file, got %d" % LinuxPlugin._parse_io)
	var json1 := p1.library(1)
	assert_bool(FileAccess.file_exists(CACHE)).override_failure_message("the cache is written").is_true()

	# A fresh boot of the unchanged folder: the parse cache's, no file read, the library the same.
	LinuxPlugin._parse_io = 0
	var p2 := LinuxPlugin.new()
	var lib2: Dictionary = JSON.parse_string(p2.library(1))
	var library2: Dictionary = lib2.get("library", {})
	var games2: Array = library2.get("games", [])
	assert_int(LinuxPlugin._parse_io).is_zero().override_failure_message(
		"the unchanged folder's second scan reads no file, got %d" % LinuxPlugin._parse_io)
	assert_int(games2.size()).is_equal(2)
	assert_str(p2.library(1)).is_equal(json1).override_failure_message(
		"the cache's library stands for the files' reads")

	# One file changed (its size and its mtime): only it read again, the rest the cache's.
	LinuxPlugin._parse_io = 0
	var alpha := ROMS.path_join("nes/Alpha.nes")
	var changed := FileAccess.open(alpha, FileAccess.READ_WRITE)
	changed.seek_end(0)
	changed.store_buffer(PackedByteArray([9, 8, 7, 6, 5, 4, 3, 2]))
	changed.close()
	var p3 := LinuxPlugin.new()
	var lib3: Dictionary = JSON.parse_string(p3.library(1))
	var library3: Dictionary = lib3.get("library", {})
	var games3: Array = library3.get("games", [])
	assert_int(LinuxPlugin._parse_io).is_equal(1) \
		.override_failure_message("only the changed file is read again, got %d" % LinuxPlugin._parse_io)
	assert_int(games3.size()).is_equal(2).override_failure_message("still two games")
	# The changed file's game still stands (its name, its platform), the parse the new one's.
	var alpha_game := _by_title(games3, "Alpha")
	assert_str(str(alpha_game.get("platform_id", ""))).is_equal("nes")


## [param games] by title: the one named [param title], or nothing.
func _by_title(games: Array, title: String) -> Dictionary:
	for game: Dictionary in games:
		if str(game.get("title", "")) == title:
			return game
	return {}


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
