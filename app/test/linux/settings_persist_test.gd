# SPDX-License-Identifier: GPL-3.0-or-later
extends GdUnitTestSuite
## The settings' persistence: a saved setting stands in its file beside the user's other
## data, a fresh boot reads it back, and the start's answer (`--backdrop`, `--pixel-veil`)
## still stands ahead of the stored ones, for the keys it names alone.
##
## Hermetic: its own temp settings file (the user's data's, not).

const WORK := "/tmp/cartouche-settings-test"
const SETTINGS := WORK + "/settings.json"


func before_test() -> void:
	_wipe(WORK)
	DirAccess.make_dir_recursive_absolute(WORK)
	if FileAccess.file_exists(SETTINGS):
		DirAccess.remove_absolute(SETTINGS)
	DesktopPlugin.set_settings_path(SETTINGS)


func after_test() -> void:
	DesktopPlugin.set_settings_path("")
	_wipe(WORK)


## Save two settings (a choice's name, a level's int); a fresh boot reads both back; the
## start's answer overrides its own key only, the rest standing from the file.
func test_saved_settings_stand_for_the_next_boot() -> void:
	# The saves, to their file.
	var p1 := LinuxPlugin.new()
	var saved: Dictionary = JSON.parse_string(p1.saveSetting(1, "backdrop", "dark"))
	assert_bool(saved.get("ok", false)).override_failure_message("the backdrop save answers ok").is_true()
	var saved2: Dictionary = JSON.parse_string(p1.saveSetting(2, "sound_level", "7"))
	assert_bool(saved2.get("ok", false)).override_failure_message("the level save answers ok").is_true()
	assert_bool(FileAccess.file_exists(SETTINGS)).override_failure_message("the settings' file stands").is_true()
	var on_disk: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SETTINGS))
	assert_str(str(on_disk.get("backdrop", ""))).is_equal("dark")
	assert_float(float(str(on_disk.get("sound_level", -1)))).is_equal(7.0)

	# A fresh boot reads both back (the demo's behind them).
	var p2 := LinuxPlugin.new()
	var s2: Dictionary = JSON.parse_string(p2.settings(1))
	assert_str(str(s2.get("backdrop", ""))).is_equal("dark") \
		.override_failure_message("the saved backdrop stands, got %s" % str(s2.get("backdrop")))
	assert_float(float(str(s2.get("sound_level", -1)))).is_equal(7.0) \
		.override_failure_message("the saved level stands, got %s" % str(s2.get("sound_level")))

	# The start's answer ahead: its key overridden, the rest from the file.
	var p3 := LinuxPlugin.new()
	p3.start_with_backdrop("anthracite", "")
	var s3: Dictionary = JSON.parse_string(p3.settings(1))
	assert_str(str(s3.get("backdrop", ""))).is_equal("anthracite") \
		.override_failure_message("the start's backdrop stands ahead, got %s" % str(s3.get("backdrop")))
	assert_float(float(str(s3.get("sound_level", -1)))).is_equal(7.0) \
		.override_failure_message("the key the start does not name stands from the file")


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
