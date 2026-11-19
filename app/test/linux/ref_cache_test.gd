# SPDX-License-Identifier: GPL-3.0-or-later
extends GdUnitTestSuite
## The reference DB's parse cache: the first boot of the run parses the reference lists (the
## titles, the prints, the disc serials) and writes them to the cache, keyed on their version
## and their sizes; a fresh boot of the same data reads the parse, not the lists, and the data
## the cache serves is the parse's, so the identification stands.
##
## Hermetic: its own temp cache file and its own (empty) games folder (the user's data's and the
## fixtures', neither). The reference lists themselves stand in res://, packaged, so the parse
## is the real one, its cost the run's own.

const WORK := "/tmp/cartouche-ref-cache-test"
const CACHE := WORK + "/ref-cache.json"


func before_test() -> void:
	_wipe(WORK)
	DirAccess.make_dir_recursive_absolute(WORK)
	LinuxPlugin.set_ref_cache_path(CACHE)
	LinuxPlugin.set_scan_cache_path(WORK + "/scan-cache.json")
	LinuxPlugin.set_games_dir(WORK + "/roms")
	DesktopPlugin.set_settings_path(WORK + "/settings.json")
	_reset_ref()


func after_test() -> void:
	LinuxPlugin.set_ref_cache_path("")
	LinuxPlugin.set_scan_cache_path("")
	LinuxPlugin.set_games_dir("")
	DesktopPlugin.set_settings_path("")
	_reset_ref()
	_wipe(WORK)


## The round trip: the cold boot parses the lists and writes the cache; the warm boot reads the
## cache, not the lists, and the reference data is the parse's.
func test_ref_cache_round_trip() -> void:
	# The cold boot: no cache, the lists' parsed, the cache written.
	var p1 := LinuxPlugin.new()
	p1.library(1)
	assert_int(LinuxPlugin._ref_parse_io).is_equal(1) \
		.override_failure_message("the cold boot parses the reference lists, got %d" % LinuxPlugin._ref_parse_io)
	assert_bool(FileAccess.file_exists(CACHE)).override_failure_message("the cache is written").is_true()
	var cold_titles := LinuxPlugin._title_lists.duplicate(true)
	var cold_prints := LinuxPlugin._print_lists.duplicate(true)
	var cold_serials := LinuxPlugin._serial_index.duplicate(true)
	assert_bool(cold_titles.size() > 0).override_failure_message("the titles' parsed").is_true()
	assert_bool(cold_serials.size() > 0).override_failure_message("the serials' parsed").is_true()
	# The warm boot: a fresh one (the process's state reset), the cache's, no parse, the data
	# the parse's.
	_reset_ref()
	var p2 := LinuxPlugin.new()
	p2.library(1)
	assert_int(LinuxPlugin._ref_parse_io).is_zero() \
		.override_failure_message("the warm boot parses no reference list, got %d" % LinuxPlugin._ref_parse_io)
	assert_bool(LinuxPlugin._title_lists == cold_titles) \
		.override_failure_message("the cache's titles are the parse's").is_true()
	assert_bool(LinuxPlugin._print_lists == cold_prints) \
		.override_failure_message("the cache's prints are the parse's").is_true()
	assert_bool(LinuxPlugin._serial_index == cold_serials) \
		.override_failure_message("the cache's serials are the parse's").is_true()


## The cache of the wrong version is refused, the lists' parsed again.
func test_ref_cache_stale_version() -> void:
	_write_cache(LinuxPlugin._REF_CACHE_VERSION + 1, {})
	_reset_ref()
	var p1 := LinuxPlugin.new()
	p1.library(1)
	assert_int(LinuxPlugin._ref_parse_io).is_equal(1) \
		.override_failure_message("the stale cache's refused, the lists' parsed, got %d" % LinuxPlugin._ref_parse_io)


## The cache whose sizes do not stand for the lists' is refused, the lists' parsed again.
func test_ref_cache_size_mismatch() -> void:
	_write_cache(LinuxPlugin._REF_CACHE_VERSION, {"res://data/titles/absent.tsv": 1})
	_reset_ref()
	var p1 := LinuxPlugin.new()
	p1.library(1)
	assert_int(LinuxPlugin._ref_parse_io).is_equal(1) \
		.override_failure_message("the mismatched cache's refused, the lists' parsed, got %d" % LinuxPlugin._ref_parse_io)


## Two instances in one process: the first parses, the second's the run's, no second parse.
func test_ref_cache_two_instances_one_parse() -> void:
	var p1 := LinuxPlugin.new()
	p1.library(1)
	assert_int(LinuxPlugin._ref_parse_io).is_equal(1)
	var p2 := LinuxPlugin.new()
	p2.library(1)
	assert_int(LinuxPlugin._ref_parse_io).is_equal(1) \
		.override_failure_message("the second instance parses no reference list, got %d" % LinuxPlugin._ref_parse_io)


## The cache file, stood: its version, its sizes, its (empty) lists.
static func _write_cache(version: int, sizes: Dictionary) -> void:
	var f := FileAccess.open(CACHE, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"version": version, "sizes": sizes,
		"titles": {}, "prints": {}, "serials": {}}))
	f.close()


## The reference DB's process state, away: its statics' the run's.
static func _reset_ref() -> void:
	LinuxPlugin._ref_loaded = false
	LinuxPlugin._ref_parse_io = 0
	LinuxPlugin._title_lists = {}
	LinuxPlugin._print_lists = {}
	LinuxPlugin._serial_index = {}


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
