# SPDX-License-Identifier: GPL-3.0-or-later
extends GdUnitTestSuite
## The directories: the settings, the models, and the key's the config dir's, the caches' the
## cache dir's, `$HOME`'s beside; and the files the app kept in Godot's own directory come
## over, once, on the first boot after the move.

const WORK := "/tmp/cartouche-dirs-test"
var _old_home := ""


func before_test() -> void:
	_old_home = OS.get_environment("HOME")
	_wipe(WORK)
	DirAccess.make_dir_recursive_absolute(WORK + "/home")
	DirAccess.make_dir_recursive_absolute(WORK + "/roms/nes")
	_write_pattern_file(WORK + "/roms/nes/Alpha.nes", 16384, 1)
	OS.set_environment("HOME", WORK + "/home")
	LinuxPlugin.set_games_dir(WORK + "/roms")
	LinuxPlugin.set_scan_cache_path("")
	LinuxPlugin.set_ref_cache_path("")
	DesktopPlugin.set_settings_path("")


func after_test() -> void:
	DesktopPlugin.set_settings_path("")
	LinuxPlugin.set_scan_cache_path("")
	LinuxPlugin.set_ref_cache_path("")
	LinuxPlugin.set_games_dir("")
	OS.set_environment("HOME", _old_home)
	_wipe(WORK)


## A scan with no test's path: its caches' the cache dir's, `$HOME`'s beside.
func test_the_caches_stand_in_the_cache_directory() -> void:
	var p := LinuxPlugin.new()
	p.library(1)
	assert_bool(FileAccess.file_exists(WORK + "/home/.cache/cartouche/scan-cache.json")) \
		.override_failure_message("the scan cache stands in the cache dir").is_true()
	assert_bool(FileAccess.file_exists(WORK + "/home/.cache/cartouche/ref-cache.json")) \
		.override_failure_message("the reference cache stands in the cache dir").is_true()


## A choice the app makes stands in the config dir, `$HOME`'s beside.
func test_the_settings_stand_in_the_config_directory() -> void:
	var p := LinuxPlugin.new()
	p._store_settings()
	assert_bool(FileAccess.file_exists(WORK + "/home/.config/cartouche/settings.json")) \
		.override_failure_message("the settings stand in the config dir").is_true()


## The key, in the config dir: the source, on.
func test_the_key_stand_in_the_config_directory() -> void:
	DirAccess.make_dir_recursive_absolute(WORK + "/home/.config/cartouche")
	var key := FileAccess.open(WORK + "/home/.config/cartouche/sskey.json", FileAccess.WRITE)
	key.store_string(JSON.stringify({"devid": 1, "devpassword": "p", "softname": "s"}))
	key.close()
	var ss := ScreenScraper.new()
	assert_bool(ss.enabled()).override_failure_message("the key's the config dir's").is_true()


## A file the app kept in Godot's own directory comes over to its new place, once; the
## original's beside.
func test_the_files_the_app_kept_come_over() -> void:
	var old_dir := ProjectSettings.globalize_path("user://_").get_base_dir()
	var saved := {}
	for file_name: String in ["settings.json", "sskey.json", "ref-cache.json"]:
		var full := old_dir.path_join(file_name)
		if FileAccess.file_exists(full):
			saved[file_name] = FileAccess.get_file_as_string(full)
	DirAccess.make_dir_recursive_absolute(old_dir)
	_write_string(old_dir.path_join("settings.json"), "{\"a\": 1}")
	_write_string(old_dir.path_join("sskey.json"),
		JSON.stringify({"devid": 1, "devpassword": "p", "softname": "s"}))
	_write_string(old_dir.path_join("ref-cache.json"), "{\"version\": 1}")
	DesktopPlugin._migrated = false
	LinuxPlugin.new()
	assert_bool(FileAccess.file_exists(WORK + "/home/.config/cartouche/settings.json")) \
		.override_failure_message("the settings come over").is_true()
	assert_bool(FileAccess.file_exists(WORK + "/home/.config/cartouche/sskey.json")) \
		.override_failure_message("the key comes over").is_true()
	assert_bool(FileAccess.file_exists(WORK + "/home/.cache/cartouche/ref-cache.json")) \
		.override_failure_message("the reference cache comes over").is_true()
	assert_bool(FileAccess.file_exists(old_dir.path_join("settings.json"))) \
		.override_failure_message("the original's beside").is_true()
	for file_name: String in saved:
		var original: String = saved[file_name]
		_write_string(old_dir.path_join(file_name), original)
	for file_name: String in ["settings.json", "sskey.json", "ref-cache.json"]:
		if not saved.has(file_name):
			DirAccess.remove_absolute(old_dir.path_join(file_name))
	DesktopPlugin._migrated = true


## [param text] to [param path].
static func _write_string(path: String, text: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(text)
	file.close()


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
