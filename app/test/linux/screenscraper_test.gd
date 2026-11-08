# SPDX-License-Identifier: GPL-3.0-or-later
extends GdUnitTestSuite
##
## The ScreenScraper source's tests: its tables, read from the app's `res://data/screenscraper`,
## its lookups by the reference names, its requests, and its answers' states. No request of
## these is ever sent: the source is keyed, not asked.

const FOLDER := "user://ss-test"

var _ss: ScreenScraper
var _key := ""


func before_test() -> void:
	DirAccess.make_dir_recursive_absolute(FOLDER)
	_key = FOLDER.path_join("key.json")
	var file := FileAccess.open(_key, FileAccess.WRITE)
	file.store_string("{\"devid\": \"test\", \"devpassword\": \"test-pass\", \"softname\": \"CartoucheTest\"}")
	file.close()
	_ss = ScreenScraper.new()
	_ss.set_key_path(ProjectSettings.globalize_path(_key))


func after_test() -> void:
	for file in DirAccess.get_files_at(FOLDER):
		DirAccess.remove_absolute(FOLDER.path_join(file))


## The title's keys, as the index compares them: itself, its tags off, and its core, normalized.
func _title_keys(title: String) -> Array:
	var keys: Array = [LinuxPlugin._normalize(title)]
	var stripped: String = LinuxPlugin._tags_stripped(title)
	if stripped != title:
		keys.append(LinuxPlugin._normalize(stripped))
	var core: String = LinuxPlugin._core_title(title)
	if core != title:
		keys.append(LinuxPlugin._normalize(core))
	return keys


func test_without_a_key_the_source_is_off() -> void:
	var off := ScreenScraper.new()
	off.set_key_path(ProjectSettings.globalize_path("user://ss-test/none.json"))
	assert_bool(off.enabled()).is_false()
	assert_bool(off.open()).is_false()
	assert_bool(off.admit()).is_false()


func test_the_key_file_enables_the_source() -> void:
	assert_bool(_ss.enabled()).is_true()
	assert_bool(_ss.open()).is_true()
	assert_bool(_ss.admit()).is_true()


func test_rush_2049_is_found_by_the_rom_s_title_keys() -> void:
	var keys: Array = _title_keys("San Francisco Rush 2049 (USA)")
	var row: Dictionary = _ss.lookup("gbc", keys)
	assert_int(str(row["game"]).to_int()).is_equal(36995)
	assert_array(row["codes"]).has_size(1)
	assert_array(row["codes"]).contains("us")


func test_barbie_is_found_by_the_art_row_s_name_as_the_bridge() -> void:
	var keys: Array = ScreenScraper.row_keys("Barbie Software - Groovy Games (U)")
	var row: Dictionary = _ss.lookup("gba", keys)
	assert_int(str(row["game"]).to_int()).is_equal(4204)


func test_an_unlisted_release_is_no_found() -> void:
	var row: Dictionary = _ss.lookup("gbc", [LinuxPlugin._normalize("No Such Game (USA)")])
	assert_bool(row.is_empty()).is_true()


func test_the_texture_is_the_region_s_code_then_the_knowns() -> void:
	var codes: Array = ["br", "ca", "eu", "jp", "us"]
	assert_that(ScreenScraper.texture_code(codes, "North America", false)).is_equal("us")
	assert_that(ScreenScraper.texture_code(codes, "Europe", false)).is_equal("eu")
	assert_that(ScreenScraper.texture_code(codes, "Japan", false)).is_equal("jp")
	assert_that(ScreenScraper.texture_code(codes, "Australia", false)).is_equal("us")
	assert_that(ScreenScraper.texture_code(codes, "Australia", true)).is_equal("")
	assert_that(ScreenScraper.texture_code([], "Europe", false)).is_equal("")


func test_the_request_carries_the_key_the_system_the_game_and_the_texture() -> void:
	var url := _ss.request_url(10, 36995, "us")
	assert_bool(url.begins_with("https://api.screenscraper.fr/api2/mediaJeu.php?")).is_true()
	assert_bool("devid=test" in url).is_true()
	assert_bool("devpassword=test-pass" in url).is_true()
	assert_bool("systemeid=10" in url).is_true()
	assert_bool("jeuid=36995" in url).is_true()
	assert_bool("media=support-texture(us)" in url).is_true()
	# The parameters are ampersand-separated: the server reads each one on its own.
	assert_bool("devid=test&devpassword=test-pass" in url).is_true()
	assert_bool("systemeid=10&jeuid=36995" in url).is_true()
	assert_bool("media=support-texture(us)&maxwidth=1024" in url).is_true()
	assert_bool("," not in url).is_true()
	assert_that(_ss.request_url(10, 36995, "")).is_equal("")
	assert_that(_ss.request_url(0, 36995, "us")).is_equal("")


func test_a_429_waits_its_back_off() -> void:
	assert_that(_ss.answer(429, PackedByteArray())).is_equal("throttled")
	assert_bool(_ss.admit()).is_false()
	assert_bool(_ss.open()).is_true()


func test_the_spent_quota_closes_the_day() -> void:
	assert_that(_ss.answer(430, PackedByteArray())).is_equal("closed")
	assert_bool(_ss.open()).is_false()


func test_the_refused_key_is_off_for_the_run() -> void:
	_ss.answer(403, PackedByteArray())
	assert_bool(_ss.open()).is_false()
	_ss = ScreenScraper.new()
	_ss.set_key_path(ProjectSettings.globalize_path(_key))
	assert_that(_ss.answer(200, "Erreur de login : Vérifier vos identifiants développeur !".to_utf8_buffer())).is_equal("refused")
	assert_bool(_ss.open()).is_false()


func test_no_media_is_the_absence_and_not_the_key_s_refusal() -> void:
	assert_that(_ss.answer(200, "NOMEDIA".to_utf8_buffer())).is_equal("nomedia")
	assert_bool(_ss.open()).is_true()


func test_the_image_bytes_are_the_image() -> void:
	var png := PackedByteArray([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0])
	assert_that(_ss.answer(200, png)).is_equal("image")
	assert_bool(_ss.open()).is_true()
	assert_that(_ss.answer(200, PackedByteArray([0xFF, 0xD8, 0xFF, 0xE0, 0]))).is_equal("image")


func test_the_absence_is_kept_per_run() -> void:
	var ss := ScreenScraper.new()
	assert_bool(ss.is_no_media("1291:us")).is_false()
	ss.note_no_media("1291:us")
	assert_bool(ss.is_no_media("1291:us")).is_true()
	assert_bool(ss.is_no_media("1291:eu")).is_false()
	ss.reset()
	assert_bool(ss.is_no_media("1291:us")).is_false()


func test_the_period_is_the_separator_too() -> void:
	assert_that(LinuxPlugin._normalize("L.A. Rush")).is_equal("la rush")
	# The row's way: the tags off, then the keys' without the period.
	assert_that(LinuxPlugin._normalize(LinuxPlugin._tags_stripped("L.A. Rush (USA, Europe)"))).is_equal("la rush")
