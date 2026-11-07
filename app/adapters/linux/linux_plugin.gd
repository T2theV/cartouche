# SPDX-License-Identifier: GPL-3.0-or-later
class_name LinuxPlugin
extends DesktopPlugin
## Stands in for the Kotlin plugin on a Linux desktop: where [DesktopPlugin] answers from the demo,
## this one scans a real folder of game files, parses each one the way the core does — a cartridge's
## CRC32 print (the iNES and copier headers not in it, a zip's as its archive records it), a disc's
## serial (the MAME CHD's huffman map read down to the ISO 9660 `SYSTEM.CNF` it boots) — and
## identifies the games against the reference lists shipped in `res://data/titles` and
## `res://data/prints`. It starts no emulator: a launch prints what it would run to the terminal,
## and [signal launch_reported] carries the report to the dialog the carousel shows.
##
## The folder is the `--games-dir=PATH` argument, the `CARTOUCHE_GAMES_DIR` environment variable,
## or `roms/` (beside the executable in an exported game, beside the working directory otherwise).
##
## Identification, per game, in order:
## 1. on a cartridge, the ROM's CRC32 against the platform's prints
##    (`res://data/prints/<id>.tsv`, a `name<TAB>CRC32` list);
## 2. on a disc, the serial read from it against the platform's titles
##    (`res://data/titles/<id>.tsv`), the way the lists compare them (`SLES_524.95` as the disc
##    writes it and `SLES-52495` as they do are one);
## 3. by the file's name against the platform's titles.
##
## A file is a game of the first platform, in [constant _ORDER], that lists its extension and
## whose minimum size (`res://data/platforms/profiles.json`) the file reaches; below every
## candidate's minimum it is a `not_games` of the first candidate; with no candidate at all it is
## ignored (`unsupported`).

## The launch was rehearsed: nothing was started; [param report] is what would have run.
signal launch_reported(report: Dictionary)

const _PROFILES := "res://data/platforms/profiles.json"
const _TITLES := "res://data/titles"
const _PRINTS := "res://data/prints"
## The order an ambiguous file (several platforms list its extension) resolves to, most probable
## first: the disc images of the biggest consoles, then the cartridges, most specific last.
const _ORDER: Array[String] = ["ps2", "psx", "xbox360", "xbox", "wii", "gc", "n64", "snes", "nes",
	"gbc", "gb", "gba"]
## The extensions of each platform's players, as the Daijishō definitions list them
## (`res://data/platforms/daijishou/`); a cartridge may arrive zipped, in which case its print is
## the CRC the archive records.
const _EXTENSIONS: Dictionary = {
	"nes": ["nes", "fds", "unf", "unif", "rom", "nsf", "qd", "zip"],
	"snes": ["sfc", "smc", "fig", "swc", "zip"],
	"n64": ["n64", "z64", "v64", "ndd", "ndz", "zip"],
	"gb": ["gb", "zip"],
	"gbc": ["gbc", "zip"],
	"gba": ["gba", "srd", "zip"],
	"psx": ["cue", "ccd", "chd", "iso", "img", "mdf", "nrg", "cvg", "bin", "pbp"],
	"ps2": ["chd", "iso", "img", "mdf", "nrg", "bin", "cso", "elf", "isz", "gz"],
	"gc": ["gcm", "rvc", "d64", "gcz", "wia", "gcp", "dlo"],
	"wii": ["wia", "wii", "wdb", "rvl"],
	"xbox": ["iso", "chd", "ciso", "xiso", "xch", "xic", "xis", "nrg", "cvg", "xcd",
		"ziso", "dch", "wch", "gch"],
	"xbox360": ["iso", "chd", "ciso", "xch", "xic", "xis", "nrg", "cvg", "ziso", "dch",
		"wch", "gch"],
}
## What a launch would run, per platform, %s being the file; the honest answer where Linux has
## no common emulator.
const _COMMANDS: Dictionary = {
	"nes": "retroarch %s",
	"snes": "retroarch %s",
	"n64": "retroarch %s",
	"gb": "retroarch %s",
	"gbc": "retroarch %s",
	"gba": "retroarch %s",
	"psx": "retroarch %s",
	"ps2": "pcsx2 %s",
	"gc": "dolphin-qt %s",
	"wii": "dolphin-qt %s",
	"xbox": "%s  # no common Linux emulator: the file is shown only",
	"xbox360": "%s  # no common Linux emulator: the file is shown only",
}
## How deep the walk goes, and how many files it holds: past either, the folder is too much.
const _MAX_DEPTH := 12
const _MAX_FILES := 20000
## The largest file the parsers take in whole.
const _MAX_PARSE_BYTES := 64 * 1024 * 1024
## The `(Disc N)` and the trailing `Disc N` of a file name, numbered for [method _disc_number].
const _DISC_NUMBER_RE := "\\((?:disc|disk)\\s*(\\d+)\\)|(?:^|\\s)(?:disc|disk)\\s*[-:]?\\s*(\\d+)$"
## The `(disc N)` and the trailing `disc N` of a file name, for [method _group_key].
const _DISC_KEY_RE := "\\s*\\((?:disc|disk)\\s*\\d+\\)|(?:^|\\s)(?:disc|disk)\\s*[-:]?\\s*\\d+\\s*$"
## The last ` (tag)` of a reference name.
const _TAG_RE := " \\(([A-Za-z][A-Za-z ]{0,11})\\)"
## The trailing tags of a name, as [method _display_name] cuts them.
const _DISPLAY_RE := "\\s+\\((?:disc|disk)\\s*\\d+\\)$|\\s+\\([A-Za-z][A-Za-z ]{0,11}\\)$"
## A disc number, not a region.
const _TAG_DISC_RE := "(?i)^(?:disc|disk)\\s*\\d+$"
## The serial as a disc writes it in `SYSTEM.CNF`: four letters, the number, the revision.
const _BOOT_SERIAL_RE := "[A-Z]{4}[_-]\\d{3}\\.\\d{2}"

var _by_id: Dictionary = {}
var _file_by_game: Dictionary = {}
var _meta_by_game: Dictionary = {}
var _platform_names := {}
var _medium_of := {}
var _min_bytes := {}
var _reports := {}
var _skipped_dirs: Array = []
var _scan_ms := 0
var _scanned := false
static var _dir_override := ""
static var _title_lists: Dictionary = {}
static var _print_lists: Dictionary = {}
static var _serial_index: Dictionary = {}
static var _crc_table: PackedInt32Array = []


## `--option=value` among the launch arguments, whatever the build: the demo arguments go through
## [method Diagnostics.argument], which is silent in release builds, and this one is not.
static func argument(option: String) -> String:
	var prefix := "--%s=" % option
	for given: String in OS.get_cmdline_user_args():
		if given.begins_with(prefix):
			return given.trim_prefix(prefix)
	return ""


## Where the games live: `--games-dir=PATH`, the `CARTOUCHE_GAMES_DIR` environment, or `roms/`
## beside the working directory.
static func games_dir() -> String:
	var given := argument("games-dir")
	if given:
		return given
	if not _dir_override.is_empty():
		return _dir_override
	var env := OS.get_environment("CARTOUCHE_GAMES_DIR")
	if env:
		return env
	return "roms"


## Tests: scan [param dir] instead of the usual place.
static func set_games_dir(dir: String) -> void:
	_dir_override = dir


## The launch would have run this command on the file, %s filled.
static func command_for(platform_id: String, file: String) -> String:
	var template: String = _COMMANDS.get(platform_id, "%s")
	return template % file


## The platform of [param ext] and [param size]: the first of [constant _ORDER] that lists the
## extension and whose minimum the file reaches; none when no platform lists it; the first
## candidate when the file is below every candidate's minimum (a `not_games` of it).
static func platform_of(ext: String, size: int, min_bytes: Dictionary) -> String:
	var candidates: Array = []
	for platform_id: String in _EXTENSIONS:
		if ext in _EXTENSIONS[platform_id]:
			candidates.append(platform_id)
	if candidates.is_empty():
		return ""
	var viable: Array = []
	for platform_id: String in candidates:
		var min_size: int = min_bytes.get(platform_id, 0)
		if size >= min_size:
			viable.append(platform_id)
	if viable.is_empty():
		return str(candidates[0])
	if viable.size() > 1:
		# A `.bin` under a megabyte is a cartridge, not a disc image: the cartridge platforms
		# list the extension for their raw image, and the disc platforms' minimums do not
		# keep a small file out.
		if ext == "bin" and size < 1024 * 1024 and "nes" in viable:
			return "nes"
		for platform_id: String in _ORDER:
			if platform_id in viable:
				return platform_id
	return str(viable[0])


## The library, scanned from disk on first use; the same answer until [method rescrape]; the
## demo's when the folder holds no games at all.
func library(_id: int) -> Dictionary:
	_ensure_scanned()
	var games: Array = _current.get("games", [])
	if games.is_empty():
		return _demo_library()
	return {"ok": true, "library": JSON.stringify(_current)}


## The carousel asks here on a desktop, and the desktop demo would answer made-up: the scanned
## library instead, or the demo's when the folder holds no games at all.
func useDemoLibrary(id: int, _games: int, _platform_id: String) -> Dictionary:
	return library(id)


## The shelf of [param platform_id] as the carousel shows it: the games matching [param typed]
## by title (order `title`) or by region (order `region`), with the ribbon's groups and keys.
func browse(platform_id: String, order: String, typed: String) -> String:
	_ensure_scanned()
	var shelf := _shelf_games(platform_id)
	if shelf.is_empty():
		return "{}"
	var needle := typed.strip_edges().to_lower()
	var shown: Array = []
	for i: int in shelf.size():
		var entry: Dictionary = shelf[i]
		var text: String = str(entry["title"]) if order == "title" else str(entry["region"])
		if needle.is_empty() or text.to_lower().find(needle) >= 0:
			shown.append(i)
	var view := {"count": shelf.size(), "games": shown}
	if needle.is_empty():
		view["groups"] = _groups(shelf, order)
		view["keys"] = _keys(shelf, order)
	return JSON.stringify(view)


## [method AndroidServices.title_marks]'s answer as the plugin gives it: the (start, length) of
## [param typed] in the title at [param position], every occurrence.
func titleMarks(platform_id: String, position: int, typed: String) -> String:
	_ensure_scanned()
	var shelf := _shelf_games(platform_id)
	if position < 0 or position >= shelf.size():
		return "[]"
	var marks: Array = []
	var needle := typed.strip_edges()
	if not needle.is_empty():
		var entry: Dictionary = shelf[position]
		var hay: String = str(entry["title"]).to_lower()
		var needle_l: String = needle.to_lower()
		var from := 0
		while from <= hay.length():
			var at := hay.find(needle_l, from)
			if at < 0:
				break
			marks.append([at, needle.length()])
			from += needle_l.length()
	return JSON.stringify(marks)


## The launch rehearsed: the report printed to the terminal, [signal launch_reported] to the
## dialog; nothing is started, and the answer is the rehearsal's refusal so the carousel shows
## again.
func launchGame(_id: int, launch: Dictionary) -> Dictionary:
	var game_id: String = str(launch.get("game_id", ""))
	var game: Dictionary = _game_by_id(game_id)
	if game.is_empty():
		return {"ok": false, "code": &"game_missing", "detail": "the library has no such game"}
	var files: PackedStringArray = _file_by_game.get(game_id, PackedStringArray())
	var disc: int = launch.get("disc", 0)
	var file: String = ""
	if disc < files.size():
		file = files[disc]
	else:
		var discs: Array = game["discs"]
		if disc < discs.size():
			var d: Dictionary = discs[disc]
			file = str(d.get("name", ""))
	var meta: Dictionary = _meta_by_game.get(game_id, {})
	var sizes: Array = meta.get("sizes", [])
	var disc_size: int = 0
	if disc < sizes.size():
		disc_size = sizes[disc]
	var report := {
		"game": game["title"],
		"platform": _platform_names.get(game["platform_id"], game["platform_id"]),
		"platform_id": game["platform_id"],
		"medium": game.get("medium", ""),
		"file": file,
		"size": disc_size,
		"crc32": meta.get("crc32", ""),
		"serials": meta.get("serials", []),
		"ref_code": meta.get("ref_code", ""),
		"chd": meta.get("chd"),
		"command": command_for(str(game["platform_id"]), file),
	}
	var text := _report_text(report)
	report["text"] = text
	print(text)
	launch_reported.emit(report)
	return {"ok": false, "code": &"linux_printed",
		"detail": "launch rehearsed and printed: no emulator is started on Linux"}


## Scans the folder again, reading every game file anew; no label is looked for (there is no
## ScreenScraper here, by design).
func rescrape(id: int) -> Dictionary:
	_scanned = false
	_current = {}
	var answer: Dictionary = library(id)
	var games: Array = _current.get("games", [])
	answer["games"] = games.size()
	answer["labels"] = 0
	return answer


## The scan of [param platform_id]'s folder: the folder is one for every platform here, so the
## scan is the whole scan, and the report its own.
func scanPlatform(id: int, platform_id: String) -> Dictionary:
	var answer: Dictionary = rescrape(id)
	answer["report"] = _scan_report(platform_id)
	return answer


## How many games a scan of [param platform_id]'s folder would find, without saving anything.
func previewPlatform(_id: int, platform_id: String, _setup: Dictionary) -> Dictionary:
	_ensure_scanned()
	return {"ok": true, "report": _scan_report(platform_id)}


## The desktop stand-in's name is the system's; the Linux one says it is Linux.
func deviceName() -> String:
	return "%s %s" % [OS.get_name(), OS.get_version()]


# ---------------------------------------------------------------- the scan


func _ensure_scanned() -> void:
	if _scanned:
		return
	_scanned = true
	_read_data()
	var started := Time.get_ticks_msec()
	_current = _build_library()
	_scan_ms = Time.get_ticks_msec() - started
	print(_scan_summary())


func _read_data() -> void:
	if not _platform_names.is_empty():
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(_PROFILES))
	var profiles: Dictionary = {}
	if parsed is Dictionary:
		profiles = parsed
	var catalog: Dictionary = demo("catalog")
	for platform: Dictionary in catalog.get("platforms", []):
		var platform_id: String = str(platform["id"])
		_platform_names[platform_id] = platform["name"]
		var profile: Dictionary = profiles.get(platform_id, {})
		var medium: Dictionary = profile.get("medium", {})
		_medium_of[platform_id] = medium.get("default", "")
		_min_bytes[platform_id] = profile.get("minimumGameBytes", 0)
		var scans_raw: Variant = profile.get("scansBySerial", {})
		var scans: Dictionary = {}
		if scans_raw is Dictionary:
			scans = scans_raw
		_art_scans_url[platform_id] = str(scans.get("url", ""))
	_title_lists = _list(_TITLES, true)
	_print_lists = _list(_PRINTS, false)
	_serial_index = _serial_lists()


## `{platform: {…}}` for a reference list of `name<TAB>code` lines: the titles' [param by_name]
## maps the normalized name to its code (a serial on the disc platforms), the prints' the CRC32
## to the name.
static func _list(folder: String, by_name: bool) -> Dictionary:
	var found := {}
	for file_name: String in DirAccess.get_files_at(folder):
		if not file_name.ends_with(".tsv"):
			continue
		var platform_id: String = file_name.get_basename()
		var map: Dictionary = {}
		var data := FileAccess.get_file_as_bytes(folder.path_join(file_name))
		var text: String = data.get_string_from_utf8()
		for line: String in text.split("\n"):
			var clean: String = line.rstrip("\r")
			var parts := clean.split("\t")
			if parts.is_empty() or parts[0].is_empty():
				continue
			# A line may carry no code (cartridge titles): the name still stands.
			var code := parts[1] if parts.size() > 1 else ""
			if by_name:
				map[_normalize(parts[0])] = {"name": parts[0], "code": code}
			elif not code.is_empty():
				map[code.to_upper()] = parts[0]
		found[platform_id] = map
	return found


## The disc serials of every titles list, as the lists compare them: `{platform: {serial_key:
## name}}`, a line's comma-listed serials each filed once, the key the alphanumerics of a serial,
## `SLPM-66124` and the disc's `SLPM_661.24` alike.
static func _serial_lists() -> Dictionary:
	var found := {}
	for file_name: String in DirAccess.get_files_at(_TITLES):
		if not file_name.ends_with(".tsv"):
			continue
		var platform_id: String = file_name.get_basename()
		var index: Dictionary = {}
		var data := FileAccess.get_file_as_bytes(_TITLES.path_join(file_name))
		var text: String = data.get_string_from_utf8()
		for line: String in text.split("\n"):
			var clean: String = line.rstrip("\r")
			var parts := clean.split("\t")
			if parts.size() < 2 or parts[0].is_empty() or parts[1].is_empty():
				continue
			for serial: String in parts[1].split(","):
				var key: String = _alnum(serial)
				if not key.is_empty() and not index.has(key):
					index[key] = parts[0]
		found[platform_id] = index
	return found


func _build_library() -> Dictionary:
	var dir := games_dir()
	_by_id.clear()
	_file_by_game.clear()
	_meta_by_game.clear()
	_reports.clear()
	_skipped_dirs.clear()
	var files: Array = []
	_walk(dir, "", 0, files)
	var games: Array = []
	var not_games: Dictionary = {}
	var unsupported: Array = []
	# one group per platform and name, the discs of a set sharing one
	var groups: Dictionary = {}
	for entry: Dictionary in files:
		var name: String = entry["name"]
		var size: int = entry["size"]
		var ext: String = name.get_extension().to_lower()
		# A zip's platform is its member's: the archive's ROM, not the wrapper, is the game.
		if ext == "zip":
			var member: String = _zip_member_ext(str(entry["path"]))
			if not member.is_empty():
				ext = member
		var platform_id: String = platform_of(ext, size, _min_bytes)
		if platform_id.is_empty():
			unsupported.append(name)
			continue
		var min_size: int = _min_bytes.get(platform_id, 0)
		if min_size > size:
			var too_small: Array = not_games.get(platform_id, [])
			too_small.append(name)
			not_games[platform_id] = too_small
			continue
		var base: String = name.get_basename()
		var key := platform_id + " " + _group_key(base)
		var group: Dictionary = groups.get(key, {})
		if group.is_empty():
			group = {"base": base, "platform": platform_id, "entries": [], "numbers": []}
		var group_entries: Array = group["entries"]
		group_entries.append(entry)
		var group_numbers: Array = group["numbers"]
		group_numbers.append(_disc_number(base))
		groups[key] = group
	# one game per group, in the catalog's order, the shelves behind them
	var shelves: Array = []
	var by_platform: Dictionary = {}
	for platform_id: String in _catalog_order():
		var platform_games: Array = []
		for key: String in groups:
			var group: Dictionary = groups[key]
			if str(group["platform"]) != platform_id:
				continue
			var game: Dictionary = _game_of(group, games.size())
			games.append(game)
			platform_games.append(games.size() - 1)
		if not platform_games.is_empty():
			by_platform[platform_id] = platform_games
			shelves.append({"platform": platform_id, "games": platform_games, "selected": 0})
	var library_data: Dictionary = {
		"setups": {},
		"games": games,
		"not_games": not_games,
		"ignored_counts": {"*": {"unsupported": {"count": unsupported.size(),
			"examples": unsupported.slice(0, 3)}}},
		"skipped_folders": {},
		"console_variants": {},
		"shelves": {"shelves": shelves, "selected": 0},
	}
	for platform_id: String in by_platform:
		library_data["setups"][platform_id] = {"folder_uri": dir, "folder_depth": "top_level",
			"disc_grouping": "grouped"}
		var platform_games: Array = by_platform[platform_id]
		var not_game_files: Array = not_games.get(platform_id, [])
		_reports[platform_id] = {
			"files": files.size(),
			"games": platform_games.size(),
			"identified": _identified_count(platform_id, games),
			"ignored": not_game_files.size() + unsupported.size(),
			"skipped_folders": _skipped_dirs.size()}
	_reports["*"] = {
		"files": files.size(),
		"games": games.size(),
		"identified": _identified_count("", games),
		"ignored": _not_games_count(not_games) + unsupported.size(),
		"skipped_folders": _skipped_dirs.size()}
	return library_data


## Whether [param dir] exists, as the walk's [method DirAccess.get_directories_at] would read it:
## the folder is opened from the working directory, and the missing-folder error never prints.
static func _dir_exists(dir: String) -> bool:
	var current := DirAccess.open(".")
	if current == null:
		return false
	return current.dir_exists(dir)


func _walk(dir: String, rel: String, depth: int, files: Array) -> void:
	if depth > _MAX_DEPTH or files.size() >= _MAX_FILES:
		return
	if not _dir_exists(dir):
		return
	for name: String in DirAccess.get_directories_at(dir):
		if files.size() >= _MAX_FILES:
			break
		if not name.begins_with("."):
			_walk(dir.path_join(name), name if rel.is_empty() else rel.path_join(name),
				depth + 1, files)
		else:
			_skipped_dirs.append(name if rel.is_empty() else rel.path_join(name))
	for name: String in DirAccess.get_files_at(dir):
		if files.size() >= _MAX_FILES:
			break
		if name.begins_with(".") or name.ends_with(".import") or name.ends_with(".uid"):
			continue
		var path := dir.path_join(name)
		files.append({"path": path, "name": name,
			"rel": name if rel.is_empty() else rel.path_join(name),
			"size": _size_of(path)})


## The game of [param group] at [param index]: its discs, its parse, its identification.
func _game_of(group: Dictionary, index: int) -> Dictionary:
	var platform_id: String = group["platform"]
	var entries_source: Array = group["entries"]
	var entries: Array = entries_source.duplicate()
	for i: int in entries.size():
		entries[i]["num"] = group["numbers"][i]
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["num"] != b["num"]:
			return a["num"] < b["num"]
		return a["name"] < b["name"])
	# The print and the parse of the first file, the serials of every one.
	var first: Dictionary = entries[0]
	var first_name: String = first["name"]
	var crc := _print_of(platform_id, first)
	var serials: Array = []
	for entry: Dictionary in entries:
		for serial: String in _serials_of(entry):
			if serial not in serials:
				serials.append(serial)
	# Identification: the print, then the serial, then the name.
	var identified := false
	var redump := ""
	var ref_code := ""
	var print_index: Dictionary = _print_lists.get(platform_id, {})
	var titles: Dictionary = _title_lists.get(platform_id, {})
	var serial_index: Dictionary = _serial_index.get(platform_id, {})
	if not crc.is_empty() and print_index.has(crc):
		identified = true
		redump = str(print_index[crc])
	else:
		var matched := ""
		for serial: String in serials:
			var key: String = _alnum(serial)
			if serial_index.has(key):
				matched = serial
				redump = str(serial_index[key])
				break
		if not redump.is_empty():
			identified = true
			ref_code = matched
		else:
			var name_key := _normalize(first_name.get_basename())
			if titles.has(name_key):
				identified = true
				var title: Dictionary = titles[name_key]
				redump = str(title.get("name", ""))
				ref_code = str(title.get("code", ""))
	var shown: String = redump if identified else first_name.get_basename()
	if identified:
		shown = _display_name(redump)
	var region := _tag_of(redump if identified else shown)
	var game_id := "linux/%d" % index
	var discs: Array = []
	for entry: Dictionary in entries:
		var disc: Dictionary = {"name": entry["name"]}
		if entry["num"] > 0:
			disc["number"] = entry["num"]
			discs.append(disc)
	var game := {
		"id": game_id,
		"platform_id": platform_id,
		"title": shown,
		"regions": [region] if region else [],
		"medium": _medium_of.get(platform_id, ""),
		"languages": [],
		"serials": serials,
		"discs": discs,
		"last_disc": 0,
		"identified": identified}
	if identified:
		game["redump_name"] = redump
	_by_id[game_id] = index
	var paths := PackedStringArray()
	var sizes: Array = []
	for entry: Dictionary in entries:
		paths.append(str(entry["path"]))
		sizes.append(entry["size"])
	_file_by_game[game_id] = paths
	_meta_by_game[game_id] = {"crc32": crc, "serials": serials, "sizes": sizes,
		"ref_code": ref_code, "chd": _chd_header(platform_id, first)}
	return game


# ------------------------------------------------------------- the cartridge print

## The print No-Intro lists for [param entry], as the core counts it: the ROM's CRC32, the
## iNES and copier headers not in it, a zip's as its archive records it; empty on a disc,
## where the serial, not a print, is what identifies it.
static func _print_of(platform_id: String, entry: Dictionary) -> String:
	if platform_id in ["ps2", "psx", "wii", "gc", "xbox", "xbox360"]:
		return ""
	var ext: String = str(entry["name"]).get_extension().to_lower()
	var file := FileAccess.open(str(entry["path"]), FileAccess.READ)
	if file == null:
		return ""
	var size: int = file.get_length()
	var data := file.get_buffer(mini(size, 32 * 1024 * 1024))
	file.close()
	if ext == "zip":
		return _zip_print(data, size)
	if platform_id == "nes":
		return _nes_print(data, size)
	if platform_id == "snes":
		var skip: int = 512 if size % 1024 == 512 else 0
		return crc32(data.slice(skip, size))
	return crc32(data)


## [data] without its 16-byte iNES header, when it starts with one; the print the headered
## NES ROM's ROM has.
static func _nes_print(data: PackedByteArray, size: int) -> String:
	if size >= 16 and data[0] == 0x4E and data[1] == 0x45 and data[2] == 0x53 and data[3] == 0x1A:
		return crc32(data.slice(16, size))
	return crc32(data)


## The print a zip archive records for its only entry, in its central directory (found from
## the end record, which a comment may follow); none for an archive of several entries.
static func _zip_print(data: PackedByteArray, size: int) -> String:
	var tail_len: int = mini(size, 22 + 65535)
	var tail: PackedByteArray = data.slice(size - tail_len, size)
	var end := -1
	for i: int in range(tail.size() - 22, -1, -1):
		if _be32(tail, i) == 0x504B0506:
			end = i
			break
	if end < 0:
		return ""
	var count: int = tail[end + 10] | (tail[end + 11] << 8)
	if count != 1:
		return ""
	var cd_offset: int = _le32(tail, end + 16)
	if cd_offset < 0 or cd_offset + 46 > size:
		return ""
	var entry: PackedByteArray = data.slice(cd_offset, cd_offset + 46)
	if entry.size() < 46 or _be32(entry, 0) != 0x504B0102:
		return ""
	return _to_hex(_le32(entry, 16) & 0xFFFFFFFF)


## The extension of a zip's first member, read from the local file header that always opens the
## archive; empty when the archive does not open with one, which leaves the wrapper's own
## extension to the caller.
static func _zip_member_ext(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var data := file.get_buffer(mini(file.get_length(), 2 * 1024 * 1024))
	file.close()
	if data.size() < 30 or _le32(data, 0) != 0x504B0304:
		return ""
	var name_len: int = _le16(data, 26)
	if 30 + name_len > data.size():
		return ""
	return _ascii(data, 30, 30 + name_len).get_extension().to_lower()


# ------------------------------------------------------------- the disc serial

## The serials of [param entry], read the way the core reads them: the PlayStation CHD and
## ISO down to the `SYSTEM.CNF` they boot; none on a cartridge or an undecoded format.
static func _serials_of(entry: Dictionary) -> Array:
	var ext: String = str(entry["name"]).get_extension().to_lower()
	var path: String = str(entry["path"])
	if ext == "chd":
		return _chd_serials(path)
	if ext == "iso" or ext == "img":
		return _iso_serials(path)
	return []


static func _iso_serials(path: String) -> Array:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return []
	var data := file.get_buffer(mini(file.get_length(), _MAX_PARSE_BYTES))
	file.close()
	var sector := func(n: int) -> PackedByteArray:
		var at: int = n * 2048
		if at + 2048 > data.size():
			return PackedByteArray()
		return data.slice(at, at + 2048)
	var serial: String = _iso9660_boot_serial(sector)
	return [serial] if serial != "" else []


static func _chd_serials(path: String) -> Array:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return []
	var data := file.get_buffer(mini(file.get_length(), _MAX_PARSE_BYTES))
	file.close()
	var parsed: Dictionary = _chd_parse(data)
	if parsed.is_empty():
		return []
	var sector := func(n: int) -> PackedByteArray:
		return _chd_sector(data, parsed, n)
	var serial: String = _iso9660_boot_serial(sector)
	return [serial] if serial != "" else []


## The CHD header of [param entry], when it is a MAME v5 CHD: its version, its hunks, their
## size, the image's logical size; none otherwise.
static func _chd_header(platform_id: String, entry: Dictionary) -> Variant:
	if platform_id not in ["ps2", "psx", "xbox", "xbox360"]:
		return null
	var ext: String = str(entry["name"]).get_extension().to_lower()
	var file_size: int = entry["size"]
	if ext != "chd" or file_size <= 140:
		return null
	var file := FileAccess.open(str(entry["path"]), FileAccess.READ)
	if file == null:
		return null
	var data := file.get_buffer(mini(file.get_length(), _MAX_PARSE_BYTES))
	file.close()
	var parsed: Dictionary = _chd_parse(data)
	if parsed.is_empty():
		return null
	var hunks: int = parsed["hunks"]
	var hunk_size: int = parsed["hunk_size"]
	var logical: int = parsed["logical"]
	var first_hunk: int = parsed["first_hunk"]
	return {
		"version": 5,
		"hunks": hunks,
		"hunk_size": hunk_size,
		"logical": logical,
		"first_hunk": first_hunk,
	}


# ------------------------------------------------------------- the CHD reading

## The MAME v5 CHD map of [param file]: `MComprHD`, its huffman tree, the kinds run-length
## coded, and where each hunk's bytes sit; empty when it is not one.
static func _chd_parse(file: PackedByteArray) -> Dictionary:
	if file.size() < 140 or _ascii(file, 0, 8) != "MComprHD":
		return {}
	if _be32(file, 12) != 5:
		return {}
	var logical: int = _be64(file, 32)
	var hunk_size: int = _be32(file, 56)
	if hunk_size <= 0 or logical < hunk_size:
		return {}
	var hunks: int = int(float(logical) / hunk_size)
	var head := file.slice(124, 140)
	var body_len: int = _be32(head, 0)
	var first_hunk: int = _be48(head, 4)
	var length_bits: int = head[12]
	var self_bits: int = head[13]
	var parent_bits: int = head[14]
	if 140 + body_len > file.size():
		return {}
	var body := file.slice(140, 140 + body_len)
	var pos := 0

	# -- the huffman tree: sixteen codes, four bits each, run-length coded ----
	var lengths := PackedByteArray()
	lengths.resize(16)
	var node := 0
	while node < 16:
		var r0: Array = _read_bits(body, pos, 4)
		var length: int = r0[0]
		pos = r0[1]
		if length != 1:
			lengths[node] = length
			node += 1
			continue
		var r1: Array = _read_bits(body, pos, 4)
		var repeated: int = r1[0]
		pos = r1[1]
		var count: int = 1
		if repeated != 1:
			var r2: Array = _read_bits(body, pos, 4)
			count = r2[0] + 3
			pos = r2[1]
		for _k: int in count:
			lengths[node] = repeated
			node += 1
	# The canonical start: a code of n bits is filed with a leading 1, so that codes of
	# every length share one table.
	var starts := PackedInt32Array()
	starts.resize(33)
	for i: int in 16:
		starts[lengths[i]] += 1
	var start := 0
	for length: int in range(32, 0, -1):
		var nxt: int = (start + starts[length]) >> 1
		starts[length] = start
		start = nxt
	var symbols := PackedInt32Array()
	symbols.resize(512)
	for i: int in 512:
		symbols[i] = -1
	for symbol: int in 16:
		var code_len: int = lengths[symbol]
		if code_len >= 1 and code_len <= 8 and starts[code_len] < (1 << code_len):
			symbols[(1 << code_len) | starts[code_len]] = symbol
			starts[code_len] += 1

	# -- the kinds, one code per hunk, run-length coded ------------------------
	var kinds := PackedByteArray()
	kinds.resize(hunks)
	var last := 0
	var repeat := 0
	for hunk: int in hunks:
		if repeat > 0:
			kinds[hunk] = last
			repeat -= 1
			continue
		var c0: Array = _huff_symbol(symbols, body, pos)
		var code: int = c0[0]
		pos = c0[1]
		if code in [7, 8]:
			kinds[hunk] = last
			var c1: Array = _huff_symbol(symbols, body, pos)
			var count2: int = c1[0]
			pos = c1[1]
			if code == 7:
				repeat = 2 + count2
			else:
				var c2: Array = _huff_symbol(symbols, body, pos)
				var count3: int = c2[0]
				pos = c2[1]
				repeat = 2 + 16 + (count2 << 4) + count3
		else:
			kinds[hunk] = code
			last = code

	# -- the walk: where each hunk's bytes sit, the last self along ------------
	var hunk_start := PackedInt32Array()
	hunk_start.resize(hunks)
	var hunk_kind := PackedByteArray()
	hunk_kind.resize(hunks)
	var self_of := PackedInt32Array()
	self_of.resize(hunks)
	var offset := first_hunk
	var last_self := 0
	for hunk: int in hunks:
		var kind: int = kinds[hunk]
		hunk_start[hunk] = offset
		hunk_kind[hunk] = kind
		if kind in [0, 1, 2, 3]:
			var e0: Array = _read_bits(body, pos, length_bits)
			var vlen: int = e0[0]
			pos = e0[1]
			var skip0: Array = _read_bits(body, pos, 16)
			pos = skip0[1]
			offset += vlen
		elif kind == 4:
			var skip4: Array = _read_bits(body, pos, 16)
			pos = skip4[1]
			offset += hunk_size
		elif kind == 5:
			var e1: Array = _read_bits(body, pos, self_bits)
			last_self = e1[0]
			pos = e1[1]
		elif kind == 10:
			last_self += 1
		elif kind == 6:
			var e2: Array = _read_bits(body, pos, parent_bits)
			pos = e2[1]
		# kind 9 (SELF_0) reads nothing
		self_of[hunk] = last_self
	return {
		"first_hunk": first_hunk,
		"hunk_size": hunk_size,
		"hunks": hunks,
		"logical": logical,
		"kinds": kinds,
		"hunk_start": hunk_start,
		"hunk_kind": hunk_kind,
		"self_of": self_of,
	}


## The sector [param n] of the CHD [param file] parsed as [param parsed]: its hunk's bytes,
## the compressed hunks as none (this port decodes no codec).
static func _chd_sector(file: PackedByteArray, parsed: Dictionary, n: int) -> PackedByteArray:
	var hunk_size: int = parsed["hunk_size"]
	var per_hunk: int = int(float(hunk_size) / 2048)
	var hunk: int = int(float(n) / per_hunk)
	var offset_in: int = (n % per_hunk) * 2048
	var hunk_start: PackedInt32Array = parsed["hunk_start"]
	var hunk_kind: PackedByteArray = parsed["hunk_kind"]
	var self_of: PackedInt32Array = parsed["self_of"]
	var kind: int = hunk_kind[hunk]
	var start: int = hunk_start[hunk]
	if kind in [5, 9, 10]:
		var target: int = self_of[hunk]
		if target >= 0 and target < hunk_kind.size():
			kind = hunk_kind[target]
			start = hunk_start[target]
	if kind in [0, 1, 2, 3]:
		return PackedByteArray()
	if start + hunk_size > file.size():
		return PackedByteArray()
	var data := file.slice(start, start + hunk_size)
	return data.slice(offset_in, offset_in + 2048)


# ------------------------------------------------------------- ISO 9660

## The boot serial of an ISO 9660 image: the primary volume descriptor's root directory's
## `SYSTEM.CNF`, the serial its `BOOT` line names; none when it is not there. [param sector]
## is called with a sector number and returns its 2048 bytes.
static func _iso9660_boot_serial(sector: Callable) -> String:
	var pvd: PackedByteArray = sector.call(16)
	if pvd.size() < 2048 or _ascii(pvd, 1, 6) != "CD001":
		return ""
	var root_sector: int = _le32(pvd, 156 + 2)
	var root_size: int = _le32(pvd, 156 + 10)
	var directory: PackedByteArray = _sectors(sector, root_sector, root_size)
	var at := 0
	while at < directory.size():
		var length: int = directory[at]
		if length == 0:
			at = int(float(at) / 2048) * 2048 + 2048
			continue
		if at + 33 >= directory.size():
			break
		var name_len: int = directory[at + 32]
		if at + 33 + name_len > directory.size():
			break
		var name: String = _ascii(directory, at + 33, at + 33 + name_len).to_upper()
		var sep: int = name.find(";")
		if sep >= 0:
			name = name.substr(0, sep)
		var extent: int = _le32(directory, at + 2)
		var size: int = _le32(directory, at + 10)
		if name == "SYSTEM.CNF":
			var cnf: PackedByteArray = _sectors(sector, extent, size)
			return _boot_serial(_ascii(cnf, 0, cnf.size()))
		at += length
	return ""


## [param size] bytes from sector [param start], 2048 at a time, as [param sector] gives them.
static func _sectors(sector: Callable, start: int, size: int) -> PackedByteArray:
	var out := PackedByteArray()
	var i := 0
	var left := size
	while left > 0:
		var s: PackedByteArray = sector.call(start + i)
		var take: int = mini(2048, left)
		for j: int in take:
			out.append(s[j])
		left -= take
		i += 1
	return out


## The serial [param text]'s `BOOT` line names (`SLPM_661.24`); none when it has none.
static func _boot_serial(text: String) -> String:
	var re := RegEx.new()
	re.compile(_BOOT_SERIAL_RE)
	var m := re.search(text)
	if m == null:
		return ""
	return m.get_string(0)


# ------------------------------------------------------------- the bit reading

## The bit of [param data] at [param position], most significant first, zero past the end.
static func _bit(data: PackedByteArray, position: int) -> int:
	var index: int = position >> 3
	if index >= data.size():
		return 0
	return (data[index] >> (7 - (position & 7))) & 1


## [param count] bits of [param data] from [param position], most significant first: the value
## and the position after.
static func _read_bits(data: PackedByteArray, position: int, count: int) -> Array:
	var value := 0
	for i: int in count:
		value = (value << 1) | _bit(data, position + i)
	return [value, position + count]


## The next huffman symbol of [param symbols] in [param bits] at [param position], and the
## position after; -1 when no code of at most eight bits matches.
static func _huff_symbol(symbols: PackedInt32Array, bits: PackedByteArray, position: int) -> Array:
	var code := 1
	var pos := position
	for _i: int in 8:
		code = (code << 1) | _bit(bits, pos)
		pos += 1
		if code < symbols.size() and symbols[code] >= 0:
			return [symbols[code], pos]
	return [-1, pos]


# ------------------------------------------------------------- the bytes

## [param data] as an ASCII string, from [param from] to [param to].
static func _ascii(data: PackedByteArray, from: int, to: int) -> String:
	if to > data.size():
		to = data.size()
	if from >= to:
		return ""
	return data.slice(from, to).get_string_from_ascii()


## The little-endian 16 bits of [param data] at [param at].
static func _le16(data: PackedByteArray, at: int) -> int:
	return data[at] | (data[at + 1] << 8)


## The little-endian 32 bits of [param data] at [param at].
static func _le32(data: PackedByteArray, at: int) -> int:
	return data[at] | (data[at + 1] << 8) | (data[at + 2] << 16) | (data[at + 3] << 24)


## The big-endian 32 bits of [param data] at [param at].
static func _be32(data: PackedByteArray, at: int) -> int:
	return (data[at] << 24) | (data[at + 1] << 16) | (data[at + 2] << 8) | data[at + 3]


## The big-endian 48 bits of [param data] at [param at].
static func _be48(data: PackedByteArray, at: int) -> int:
	var v := 0
	for i: int in 6:
		v = (v << 8) | data[at + i]
	return v


## The big-endian 64 bits of [param data] at [param at].
static func _be64(data: PackedByteArray, at: int) -> int:
	var v := 0
	for i: int in 8:
		v = (v << 8) | data[at + i]
	return v


# ------------------------------------------------------------- the names

## [param text]'s alphanumerics, upper-cased: how the lists compare a serial, `SLPM-66124` and
## the disc's `SLPM_661.24` alike.
static func _alnum(text: String) -> String:
	var out := ""
	for c: String in text:
		if (c >= "0" and c <= "9") or (c >= "A" and c <= "Z") or (c >= "a" and c <= "z"):
			out += c
	return out.to_upper()


static func _normalize(text: String) -> String:
	var re := RegEx.new()
	re.compile("\\s+")
	return re.sub(text.strip_edges(), " ", true).to_lower()


## [param name] without its trailing ` (region)` and ` (disc N)` tags, as the user reads it.
static func _display_name(name: String) -> String:
	var out := name
	var re := RegEx.new()
	re.compile(_DISPLAY_RE)
	while true:
		var match := re.search(out)
		if match == null:
			break
		out = out.substr(0, match.get_start())
	return out.strip_edges()


## The last region tag of [param name], its last ` (tag)` that is not a disc number; empty when
## it has none.
static func _tag_of(name: String) -> String:
	var re := RegEx.new()
	re.compile(_TAG_RE)
	var disc_re := RegEx.new()
	disc_re.compile(_TAG_DISC_RE)
	var region := ""
	for match: RegExMatch in re.search_all(name):
		var tag := match.get_string(1)
		if disc_re.search(tag) == null:
			region = tag
	return region


## [param base] without its `(Disc N)` or its trailing `Disc N`, as the discs of a set share one.
static func _group_key(base: String) -> String:
	var re := RegEx.new()
	re.compile(_DISC_KEY_RE)
	return re.sub(base, " ", true).strip_edges()


## The disc number of [param base], 0 when it names none.
static func _disc_number(base: String) -> int:
	var re := RegEx.new()
	re.compile(_DISC_NUMBER_RE)
	var match := re.search(base.to_lower())
	if match == null:
		return 0
	return match.get_string(1).to_int() if not match.get_string(1).is_empty() else match.get_string(2).to_int()


# ------------------------------------------------------------- the CRC32

## The CRC32 of [param data], zlib's; empty for none.
static func crc32(data: PackedByteArray) -> String:
	if data.is_empty():
		return ""
	if _crc_table.is_empty():
		_build_crc_table()
	var c := 0xFFFFFFFF
	for byte: int in data:
		var t: int = _crc_table[(c ^ byte) & 0xFF]
		c = ((t & 0xFFFFFFFF) ^ (c >> 8)) & 0xFFFFFFFF
	return _to_hex((c ^ 0xFFFFFFFF) & 0xFFFFFFFF)


static func _build_crc_table() -> void:
	var table := PackedInt32Array()
	for i: int in 256:
		var c := i
		for _j: int in 8:
			c = ((c >> 1) ^ (0xEDB88320 if (c & 1) else 0)) & 0xFFFFFFFF
		table.append(c)
	_crc_table = table


static func _to_hex(value: int) -> String:
	var digits := "0123456789ABCDEF"
	var out := ""
	for _i: int in 8:
		out = digits[value & 0xF] + out
		value >>= 4
	return out


# ------------------------------------------------------------- the art

## The plugin's answers, as the services' signals carry them; the desktop stand-in's are the
## demo's, the Android bridge's the device's.
signal answered(payload: Dictionary)
signal art_changed(payload: Dictionary)
signal art_progress(payload: Dictionary)
signal label_variant_downloaded(payload: Dictionary)
signal battery_changed(payload: Dictionary)

const _ART_INDEX_DIR := "res://data/art"
const _ART_IMAGES := "https://images.launchbox-app.com/"
const _ART_SOURCE_LAUNCHBOX := "launchbox"
const _ART_SOURCE_PSDATACENTER := "psxdatacenter"

var _art_index: Dictionary = {}
var _art_scans_url: Dictionary = {}
var _art_jobs: Array = []
var _art_total := 0
var _art_done := 0
var _art_stall := ""
var _art_http: Variant = null
var _art_job: Dictionary = {}
var _art_source_by_game: Dictionary = {}


## The art folder: `--art-dir=PATH`, the `CARTOUCHE_ART_DIR` environment, or the user's
## share dir.
static func art_dir() -> String:
	var given := argument("art-dir")
	if given:
		return given
	var env := OS.get_environment("CARTOUCHE_ART_DIR")
	if env:
		return env
	return ProjectSettings.globalize_path("user://art")


static func _art_file_name(game_id: String, file: String) -> String:
	# The reader's `Image.load_from_file` wants the image's own extension, its bytes do not care.
	var ext := file.get_slice(".", -1).to_lower()
	if ext.is_empty():
		ext = "png"
	return game_id.replace("/", "_") + "." + ext


## The stored label of [param game], when one is in the art folder, in the candidates' order;
## none yet.
func _art_stored(game: Dictionary) -> String:
	for candidate: Dictionary in _art_candidates(game):
		var path := art_dir().path_join(_art_file_name(str(game["id"]), str(candidate["file"])))
		if FileAccess.file_exists(path):
			return path
	return ""


## The art index of [param platform_id], read from `res://data/art/<id>.tsv` on first need:
## the normalized names, the game's and its alternates, to `{region: file}`.
func _art_index_for(platform_id: String) -> Dictionary:
	if _art_index.has(platform_id):
		return _art_index[platform_id]
	var found: Dictionary = {}
	var text_path := _ART_INDEX_DIR.path_join(platform_id + ".tsv")
	if FileAccess.file_exists(text_path):
		var data := FileAccess.get_file_as_bytes(text_path)
		var text: String = data.get_string_from_utf8()
		for line: String in text.split("\n"):
			var clean: String = line.rstrip("\r")
			if clean.is_empty() or clean.begins_with("#"):
				continue
			var parts := clean.split("\t")
			if parts.size() < 3:
				continue
			var images: Dictionary = {}
			for pair: String in parts[2].split(";"):
				var eq := pair.find("=")
				if eq < 0:
					continue
				images[pair.substr(0, eq)] = pair.substr(eq + 1)
			if images.is_empty():
				continue
			found[_normalize(parts[0])] = images
			for alt: String in parts[1].split("|"):
				if not alt.is_empty():
					found[_normalize(alt)] = images
	_art_index[platform_id] = found
	return found


## The candidates for [param game]'s label, in priority order, discs' LaunchBox's scan first
## and, on the serial platforms, the serial source's: each `{"source", "source_name",
## "region", "url", "file"}`.
func _art_candidates(game: Dictionary) -> Array:
	var out: Array = []
	var platform_id := str(game["platform_id"])
	var index: Dictionary = _art_index_for(platform_id)
	var images: Dictionary = {}
	var key := _normalize(str(game["title"]))
	if index.has(key):
		images = index[key]
	if not images.is_empty():
		var region := ""
		var game_regions: Array = game.get("regions", [])
		if not game_regions.is_empty():
			region = str(game_regions[0])
		var file := ""
		if images.has(region):
			file = str(images[region])
		else:
			for r: String in images:
				file = str(images[r])
				break
		if not file.is_empty():
			out.append({"source": _ART_SOURCE_LAUNCHBOX, "source_name": "LaunchBox",
				"region": region, "url": _ART_IMAGES + file, "file": file})
	var serial_url := _art_serial_url(platform_id, game)
	if not serial_url.is_empty():
		out.append({"source": _ART_SOURCE_PSDATACENTER, "source_name": "PlayStation DataCenter",
			"region": "", "url": serial_url, "file": serial_url.get_slice("/", -1)})
	return out


## The serial source's URL of [param game]'s first serial, by [param platform_id]'s
## `scansBySerial` template, its serial as the template's regex writes it (`SLPM-66124`);
## none otherwise.
func _art_serial_url(platform_id: String, game: Dictionary) -> String:
	var template := str(_art_scans_url.get(platform_id, ""))
	if template.is_empty():
		return ""
	var serials: Array = game.get("serials", [])
	if serials.is_empty():
		return ""
	var alnum: String = str(_alnum(str(serials[0])))
	if alnum.length() < 10:
		return ""
	var prefix := alnum.substr(0, 4)
	var rest := alnum.substr(4, 5)
	if rest.length() != 5:
		return ""
	var all_digits := true
	for c: String in rest:
		if c < "0" or c > "9":
			all_digits = false
			break
	if not all_digits or prefix != prefix.to_upper():
		return ""
	return template.replace("{serial}", prefix + "-" + rest)


## The label variants of [param game_id], as `labelVariants` answers.
func labelVariants(_id: int, game_id: String) -> Dictionary:
	var game := _game_by_id(game_id)
	if game.is_empty():
		return {"ok": false}
	var variants: Array = []
	var stored := _art_stored(game)
	var stored_source := str(_art_source_by_game.get(game_id, ""))
	for candidate: Dictionary in _art_candidates(game):
		var variant: Dictionary = {
			"game_id": game_id,
			"region": candidate["region"],
			"source": candidate["source"],
			"source_name": candidate["source_name"]}
		if not stored.is_empty() and candidate["source"] == stored_source:
			variant["path"] = stored
		variants.append(variant)
	return {"ok": true, "variants": variants}


## The games' order for the art: [param focus] first, in order, the library's after.
func _art_game_order(focus: PackedStringArray) -> PackedStringArray:
	var order := PackedStringArray()
	for id_focus: String in focus:
		if _by_id.has(id_focus):
			order.append(id_focus)
	for game_raw: Variant in _current.get("games", []):
		var game: Dictionary = game_raw
		var id_game := str(game["id"])
		if not order.has(id_game):
			order.append(id_game)
	return order


## The games' art, looked for as the carousel gives the on-screen games: the stored labels are
## told at once, the rest downloaded one by one, LaunchBox's then the serial source's,
## [signal art_changed] the progress, a found, or the absences.
func artFocus(focus: PackedStringArray) -> void:
	if DisplayServer.get_name() == "headless" or _art_http != null:
		return
	_ensure_scanned()
	DirAccess.make_dir_recursive_absolute(art_dir())
	var queue: Array = []
	var absent: PackedStringArray = PackedStringArray()
	for id_game: String in _art_game_order(focus):
		var game := _game_by_id(id_game)
		if game.is_empty():
			continue
		if not _art_stored(game).is_empty():
			continue
		var candidates := _art_candidates(game)
		if candidates.is_empty():
			absent.append(id_game)
		else:
			queue.append({"game_id": id_game, "candidates": candidates, "attempt": 0})
	_art_done = 0
	_art_total = queue.size()
	_art_jobs = queue
	_art_stall = ""
	if not absent.is_empty():
		_art_changed({"done": _art_done, "total": _art_total, "absent": absent})
	_art_next()


func _art_next() -> void:
	if _art_jobs.is_empty():
		return
	var job: Dictionary = {}
	job = _art_jobs.pop_front()
	_art_job = job
	var candidates: Array = job["candidates"]
	var attempt: int = job["attempt"]
	if attempt >= candidates.size():
		# Every candidate failed: no source had an image.
		_art_done += 1
		_art_changed({"done": _art_done, "total": _art_total,
			"absent": PackedStringArray([str(job["game_id"])])})
		_art_next()
		return
	var candidate: Dictionary = candidates[attempt]
	var http := HTTPRequest.new()
	# Godot 4.7's HTTPRequest is a Node: the AndroidServices autoload keeps it in the tree.
	var loop: Variant = Engine.get_main_loop()
	if not (loop is SceneTree) or http == null:
		job["attempt"] = attempt + 1
		_art_jobs.push_front(job)
		_art_next()
		return
	var tree: SceneTree = loop
	var owner: Node = tree.root.get_node_or_null("Android")
	if owner == null:
		http.queue_free()
		_art_stall = "offline"
		_art_jobs.push_front(job)
		_art_changed({"done": _art_done, "total": _art_total, "stall": _art_stall})
		return
	owner.add_child(http)
	http.request_completed.connect(_on_art_request.bind(http))
	_art_http = http
	http.request(str(candidate["url"]))


func _on_art_request(result: int, response_code: int, _headers: PackedStringArray,
		body: PackedByteArray, http: Node) -> void:
	_art_http = null
	var job := _art_job
	_art_job = {}
	var game_id := str(job["game_id"])
	var candidates: Array = job["candidates"]
	var attempt: int = job["attempt"]
	var candidate: Dictionary = candidates[attempt]
	if result == HTTPRequest.RESULT_SUCCESS and response_code == 200 and not body.is_empty():
		var path := art_dir().path_join(_art_file_name(game_id, str(candidate["file"])))
		var file := FileAccess.open(path, FileAccess.WRITE)
		if file == null:
			_art_stall = "storage"
			_art_changed({"done": _art_done, "total": _art_total, "stall": _art_stall})
			http.queue_free()
			return
		file.store_buffer(body)
		file.close()
		_art_source_by_game[game_id] = str(candidate["source"])
		_art_done += 1
		_art_changed({"done": _art_done, "total": _art_total,
			"found": {"game_id": game_id, "path": path}})
		_label_variant_downloaded(game_id, candidate, path)
		http.queue_free()
		_art_next()
		return
	http.queue_free()
	if response_code >= 400 or body.is_empty():
		# No image here: the next candidate, or, none left, the absence.
		job["attempt"] = attempt + 1
		_art_jobs.push_front(job)
		_art_next()
		return
	# The network will not: wait, then look again from this game.
	_art_stall = "offline"
	_art_jobs.push_front(job)
	_art_changed({"done": _art_done, "total": _art_total, "stall": _art_stall})


func _label_variant_downloaded(game_id: String, candidate: Dictionary, path: String) -> void:
	var payload: Dictionary = {
		"game_id": game_id,
		"region": candidate["region"],
		"source": candidate["source"],
		"source_name": candidate["source_name"],
		"path": path}
	label_variant_downloaded.emit(payload)


func _art_changed(payload: Dictionary) -> void:
	art_changed.emit(payload)


# ------------------------------------------------------------- the reporting

## The walk's report, for [param platform_id] or the whole scan (``*``).
func _scan_report(platform_id: String) -> Dictionary:
	var fallback: Dictionary = _reports.get("*", {})
	var report_source: Dictionary = _reports.get(platform_id, fallback)
	var report: Dictionary = report_source.duplicate(true)
	report["milliseconds"] = _scan_ms
	return report


## The shelf of [param platform_id], as `[{title, region}]` in shelf order.
func _shelf_games(platform_id: String) -> Array:
	if _current.is_empty():
		return []
	var out: Array = []
	var games: Array = _current.get("games", [])
	var shelves_root: Dictionary = _current.get("shelves", {})
	var shelves: Array = shelves_root.get("shelves", [])
	for shelf: Dictionary in shelves:
		if str(shelf["platform"]) != platform_id:
			continue
		var game_indexes: Array = shelf["games"]
		for index: int in game_indexes:
			var game: Dictionary = games[index]
			var regions: Array = game.get("regions", [])
			out.append({"title": game["title"], "region": str(regions[0]) if not regions.is_empty() else ""})
	return out


## The catalog's order, of the platforms with a console model.
func _catalog_order() -> PackedStringArray:
	var order := PackedStringArray()
	for platform_id: String in _ORDER:
		if _medium_of.has(platform_id):
			order.append(platform_id)
	return order


static func _groups(shelf: Array, order: String) -> Array:
	var groups: Array = []
	for i: int in shelf.size():
		var entry: Dictionary = shelf[i]
		var text: String = str(entry["title"]) if order == "title" else str(entry["region"])
		var letter := _letter_of(text)
		var starts_new := true
		if not groups.is_empty():
			var last: Dictionary = groups.back()
			starts_new = last["letter"] != letter
		if starts_new:
			groups.append({"letter": letter, "label": letter, "start": i})
	return groups


static func _keys(shelf: Array, order: String) -> Dictionary:
	var keys := {}
	for i: int in shelf.size():
		var entry: Dictionary = shelf[i]
		var text: String = str(entry["title"]) if order == "title" else str(entry["region"])
		if text.is_empty():
			continue
		var c := text[0]
		var is_letter := (c >= "a" and c <= "z") or (c >= "A" and c <= "Z")
		var is_digit := c >= "0" and c <= "9"
		if not (is_letter or is_digit or c == " "):
			continue
		var letter := c.to_lower()
		if not keys.has(letter):
			keys[letter] = i
	return keys


static func _letter_of(text: String) -> String:
	if text.is_empty():
		return "#"
	var c := text[0]
	if (c >= "A" and c <= "Z") or (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
		return c.to_upper()
	return "#"


func _game_by_id(game_id: String) -> Dictionary:
	if not _by_id.has(game_id):
		return {}
	var games: Array = _current.get("games", [])
	var index: int = _by_id[game_id]
	if index >= games.size():
		return {}
	var game: Dictionary = games[index]
	return game


static func _identified_count(platform_id: String, games: Array) -> int:
	var count := 0
	for game: Dictionary in games:
		if (platform_id.is_empty() or game["platform_id"] == platform_id) and game["identified"]:
			count += 1
	return count


static func _not_games_count(not_games: Dictionary) -> int:
	var count := 0
	for platform_id: String in not_games:
		var list: Array = not_games[platform_id]
		count += list.size()
	return count


func _size_of(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size: int = file.get_length()
	file.close()
	return size


## The demo's library, the desktop demo's, when the folder holds no games.
func _demo_library() -> Dictionary:
	var made := demo("library")
	made["console_variants"] = _variants()
	_current = made
	return {"ok": true, "library": JSON.stringify(made)}


## The scan's report, as the terminal reads it.
func _scan_summary() -> String:
	var dir := games_dir()
	var lines := PackedStringArray()
	var games: Array = _current.get("games", [])
	lines.append("Cartouche (Linux): scanned %s" % dir)
	if games.is_empty():
		lines.append("  no games found: put game files in %s (or --games-dir=PATH)" % dir)
		return "\n".join(lines)
	var shelves_root: Dictionary = _current.get("shelves", {})
	var shelves: Array = shelves_root.get("shelves", [])
	var identified := 0
	for game: Dictionary in games:
		if game["identified"]:
			identified += 1
	lines.append("  %d games on %d consoles, %d identified" % [games.size(), shelves.size(), identified])
	var not_games: Dictionary = _current.get("not_games", {})
	var ignored_count := _not_games_count(not_games)
	var ignored: Dictionary = _current.get("ignored_counts", {})
	if not ignored.is_empty():
		var star: Dictionary = ignored.get("*", {})
		var unsupported: Dictionary = star.get("unsupported", {})
		ignored_count += unsupported.get("count", 0)
	if ignored_count > 0:
		lines.append("  %d file(s) set aside (too small or unsupported)" % ignored_count)
	for shelf: Dictionary in shelves:
		var platform_id: String = str(shelf["platform"])
		lines.append("  %s (%s):" % [_platform_names.get(platform_id, platform_id), platform_id])
		var shown := 0
		var game_indexes: Array = shelf["games"]
		for index: int in game_indexes:
			if shown >= 8:
				lines.append("    …")
				break
			shown += 1
			var game: Dictionary = games[index]
			lines.append("    %s" % _one_line(game))
	return "\n".join(lines)


func _one_line(game: Dictionary) -> String:
	var meta: Dictionary = _meta_by_game.get(game["id"], {})
	var sizes: Array = meta.get("sizes", [0])
	var total := 0
	for size: int in sizes:
		total += size
	var detail := "%d bytes" % total
	var crc: String = meta.get("crc32", "")
	if not crc.is_empty():
		detail += ", crc32 %s" % crc
	var serials: Array = meta.get("serials", [])
	if not serials.is_empty():
		detail += ", serial %s" % ", ".join(PackedStringArray(serials))
	var discs: Array = game["discs"]
	if discs.size() > 1:
		detail += ", %d discs" % discs.size()
	return "%s — %s" % [game["title"], detail]


## The launch's report, as the terminal and the dialog read it.
static func _report_text(report: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append("Cartouche (Linux) — rehearsal: nothing was started")
	lines.append("  game:      %s" % report.get("game", ""))
	lines.append("  platform:  %s (%s)" % [report.get("platform", ""), report.get("platform_id", "")])
	lines.append("  medium:    %s" % report.get("medium", ""))
	lines.append("  file:      %s" % report.get("file", ""))
	lines.append("  size:      %d bytes" % report.get("size", 0))
	var crc: String = report.get("crc32", "")
	if not crc.is_empty():
		lines.append("  crc32:     %s" % crc)
	var serials: Array = report.get("serials", [])
	if not serials.is_empty():
		lines.append("  serial:    %s" % ", ".join(PackedStringArray(serials)))
	var ref_code: String = report.get("ref_code", "")
	if not ref_code.is_empty():
		lines.append("  code:      %s" % ref_code)
	var chd_raw: Variant = report.get("chd")
	if chd_raw is Dictionary:
		var chd_d: Dictionary = chd_raw
		if not chd_d.is_empty():
			lines.append("  chd:       v%d hunks=%d hunk_size=%d logical=%d" % [chd_d["version"], chd_d["hunks"],
				chd_d["hunk_size"], chd_d["logical"]])
	lines.append("  would run: %s" % report.get("command", ""))
	return "\n".join(lines)
