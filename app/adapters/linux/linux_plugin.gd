# SPDX-License-Identifier: GPL-3.0-or-later
class_name LinuxPlugin
extends DesktopPlugin
## Stands in for the Kotlin plugin on a Linux desktop: where [DesktopPlugin] answers from the demo,
## this one scans a real folder of game files, parses each one (its size, its CRC32, the CHD
## header when there is one, the disc's serial), and identifies the games against the reference
## lists shipped in `res://data/titles` and `res://data/prints`. It starts no emulator: a launch
## prints what it would run to the terminal, and [signal launch_reported] carries the report to
## the dialog the carousel shows.
##
## The folder is the `--games-dir=PATH` argument, the `CARTOUCHE_GAMES_DIR` environment variable,
## or `roms/` beside the working directory.
##
## Identification, per game, in order:
## 1. on a cartridge, the first file's CRC32 against the platform's prints
##    (`res://data/prints/<id>.tsv`, a `name<TAB>crc32` list);
## 2. the first file's name against the platform's titles (`res://data/titles/<id>.tsv`);
## 3. on a disc, nothing more: the serial read from the files is kept and reported, and the game
##    stays unidentified.
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
## (`res://data/platforms/daijishou/`).
const _EXTENSIONS: Dictionary = {
	"nes": ["nes", "fds", "unf", "unif", "rom", "nsf", "qd"],
	"snes": ["sfc", "smc", "fig", "swc"],
	"n64": ["n64", "z64", "v64", "ndd", "ndz"],
	"gb": ["gb"],
	"gbc": ["gbc"],
	"gba": ["gba", "srd"],
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
## How far into a disc image the serial is looked for.
const _SERIAL_SCAN_BYTES := 8 * 1024 * 1024
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
		if size >= int(min_bytes.get(platform_id, 0)):
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
	if _current.get("games", []).is_empty():
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
		var text: String = shelf[i].title if order == "title" else shelf[i].region
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
		var hay: String = shelf[position].title.to_lower()
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
	var game := _game_by_id(game_id)
	if game == null:
		return {"ok": false, "code": &"game_missing", "detail": "the library has no such game"}
	var files: PackedStringArray = _file_by_game.get(game_id, PackedStringArray())
	var disc: int = int(launch.get("disc", 0))
	var file: String = files[disc] if disc < files.size() else \
		(str(game["discs"][disc]["name"]) if disc < game["discs"].size() else "")
	var meta: Dictionary = _meta_by_game.get(game_id, {})
	var sizes: Array = meta.get("sizes", [])
	var report := {
		"game": game["title"],
		"platform": _platform_names.get(game["platform_id"], game["platform_id"]),
		"platform_id": game["platform_id"],
		"medium": game.get("medium", ""),
		"file": file,
		"size": int(sizes[disc]) if disc < sizes.size() else 0,
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
	answer["games"] = _current.get("games", []).size()
	answer["labels"] = 0
	return answer


## The scan of [param platform_id]'s folder: the folder is one for every platform here, so the
## scan is the whole scan, and the report its own.
func scanPlatform(id: int, platform_id: String) -> Dictionary:
	var answer: Dictionary = rescrape(id)
	answer["report"] = _report(platform_id)
	return answer


## How many games a scan of [param platform_id]'s folder would find, without saving anything.
func previewPlatform(_id: int, platform_id: String, _setup: Dictionary) -> Dictionary:
	_ensure_scanned()
	return {"ok": true, "report": _report(platform_id)}


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
		_medium_of[platform_id] = profile.get("medium", {}).get("default", "")
		_min_bytes[platform_id] = profile.get("minimumGameBytes", 0)
	_title_lists = _list(_TITLES, true)
	_print_lists = _list(_PRINTS, false)


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
		var text := String(FileAccess.get_file_as_bytes(folder.path_join(file_name)))
		for line: String in text.split("\n"):
			var parts := line.rstrip("\r").split("	")
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
		var platform_id: String = platform_of(ext, size, _min_bytes)
		if platform_id.is_empty():
			unsupported.append(name)
			continue
		if int(_min_bytes.get(platform_id, 0)) > size:
			var too_small: Array = not_games.get(platform_id, [])
			too_small.append(name)
			not_games[platform_id] = too_small
			continue
		var base: String = name.get_basename()
		var key := platform_id + " " + _group_key(base)
		var group: Dictionary = groups.get(key, {})
		if group.is_empty():
			group = {"base": base, "platform": platform_id, "entries": [], "numbers": []}
		group["entries"].append(entry)
		group["numbers"].append(_disc_number(base))
		groups[key] = group
	# one game per group, in the catalog's order, the shelves behind them
	var shelves: Array = []
	var by_platform: Dictionary = {}
	for platform_id: String in _catalog_order():
		var platform_games: Array = []
		for key: String in groups:
			if groups[key]["platform"] != platform_id:
				continue
			var game: Dictionary = _game_of(groups[key], games.size())
			games.append(game)
			platform_games.append(games.size() - 1)
		if not platform_games.is_empty():
			by_platform[platform_id] = platform_games
			shelves.append({"platform": platform_id, "games": platform_games, "selected": 0})
	var library: Dictionary = {
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
		library["setups"][platform_id] = {"folder_uri": dir, "folder_depth": "top_level",
			"disc_grouping": "grouped"}
	_reports[platform_id] = {
		"files": files.size(),
		"games": by_platform[platform_id].size(),
		"identified": _identified_count(platform_id, games),
		"ignored": int(not_games.get(platform_id, []).size()) + unsupported.size(),
		"skipped_folders": _skipped_dirs.size()}
	_reports["*"] = {
		"files": files.size(),
		"games": games.size(),
		"identified": _identified_count("", games),
		"ignored": _not_games_count(not_games) + unsupported.size(),
		"skipped_folders": _skipped_dirs.size()}
	return library


func _walk(dir: String, rel: String, depth: int, files: Array) -> void:
	if depth > _MAX_DEPTH or files.size() >= _MAX_FILES:
		return
	var access := DirAccess.open(dir)
	if access == null:
		return
	for entry: Dictionary in access.list_dir():
		if files.size() >= _MAX_FILES:
			break
		var name: String = entry["name"]
		if entry["type"] == DirAccess.FILE_TYPE_DIR:
			if not name.begins_with("."):
				_walk(dir.path_join(name), name if rel.is_empty() else rel.path_join(name),
					depth + 1, files)
			else:
				_skipped_dirs.append(name if rel.is_empty() else rel.path_join(name))
			continue
		if name.begins_with(".") or name.ends_with(".import") or name.ends_with(".uid"):
			continue
		var path := dir.path_join(name)
		files.append({"path": path, "name": name,
			"rel": name if rel.is_empty() else rel.path_join(name),
			"size": _size_of(path)})


## The game of [param group] at [param index]: its discs, its parse, its identification.
func _game_of(group: Dictionary, index: int) -> Dictionary:
	var platform_id: String = group["platform"]
	var base: String = group["base"]
	var entries: Array = group["entries"].duplicate()
	for i: int in entries.size():
		entries[i]["num"] = group["numbers"][i]
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["num"] != b["num"]:
			return a["num"] < b["num"]
		return a["name"] < b["name"])
	# The identification and the parse of the first file, the serials of every one.
	var first: Dictionary = entries[0]
	var crc := crc32(_first_file_bytes(platform_id, first))
	var serials: Array = []
	for entry: Dictionary in entries:
		for serial: String in _serials_of(platform_id, entry):
			if serial not in serials:
				serials.append(serial)
	var name_key := _normalize(str(first["name"].get_basename()))
	var identified := false
	var redump := ""
	var ref_code := ""
	var prints: Dictionary = _print_lists.get(platform_id, {})
	var titles: Dictionary = _title_lists.get(platform_id, {})
	if not crc.is_empty() and prints.has(crc):
		identified = true
		redump = prints[crc]
	elif titles.has(name_key):
		identified = true
		var title: Dictionary = titles[name_key]
		redump = str(title.get("name", ""))
		ref_code = str(title.get("code", ""))
	var shown: String = redump if identified else str(first["name"].get_basename())
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
		paths.append(entry["path"])
		sizes.append(entry["size"])
	_file_by_game[game_id] = paths
	_meta_by_game[game_id] = {"crc32": crc, "serials": serials, "sizes": sizes,
		"ref_code": ref_code, "chd": _chd_header(platform_id, first)}
	return game


## The walk's report, for [param platform_id] or the whole scan (``*).
func _report(platform_id: String) -> Dictionary:
	var report: Dictionary = _reports.get(platform_id, _reports.get("*", {})).duplicate(true)
	report["milliseconds"] = _scan_ms
	return report


## The shelf of [param platform_id], as `[{title, region}]` in shelf order.
func _shelf_games(platform_id: String) -> Array:
	if _current.is_empty():
		return []
	var out: Array = []
	var games: Array = _current.get("games", [])
	var shelves: Array = _current.get("shelves", {}).get("shelves", [])
	for shelf: Dictionary in shelves:
		if str(shelf["platform"]) != platform_id:
			continue
		for index: int in shelf["games"]:
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
		var text: String = shelf[i].title if order == "title" else shelf[i].region
		var letter := _letter_of(text)
		if groups.is_empty() or groups.back()["letter"] != letter:
			groups.append({"letter": letter, "label": letter, "start": i})
	return groups


static func _keys(shelf: Array, order: String) -> Dictionary:
	var keys := {}
	for i: int in shelf.size():
		var text: String = shelf[i].title if order == "title" else shelf[i].region
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


func _game_by_id(game_id: String):
	if not _by_id.has(game_id):
		return null
	var games: Array = _current.get("games", [])
	var index: int = _by_id[game_id]
	if index >= games.size():
		return null
	return games[index]


static func _identified_count(platform_id: String, games: Array) -> int:
	var count := 0
	for game: Dictionary in games:
		if (platform_id.is_empty() or game["platform_id"] == platform_id) and game["identified"]:
			count += 1
	return count


static func _not_games_count(not_games: Dictionary) -> int:
	var count := 0
	for platform_id: String in not_games:
		count += not_games[platform_id].size()
	return count


func _size_of(path: String) -> int:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return 0
	var size: int = file.get_length()
	file.close()
	return size


## The first file of a cartridge game, whole (the CRC32's); none on a disc, where the serial, not
## the CRC, is what identifies it.
func _first_file_bytes(platform_id: String, entry: Dictionary) -> PackedByteArray:
	if not _is_cartridge(platform_id):
		return PackedByteArray()
	var file := FileAccess.open(entry["path"], FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var data := file.get_buffer(mini(file.get_length(), 32 * 1024 * 1024))
	file.close()
	return data


static func _is_cartridge(platform_id: String) -> bool:
	return platform_id in ["nes", "snes", "n64", "gb", "gbc", "gba"]


## The disc's serial, in the first megabytes of [param entry], as the reference lists spell it
## (`[A-Z]{4}-NNNNN`); none when it is not there.
func _serials_of(platform_id: String, entry: Dictionary) -> Array:
	if _is_cartridge(platform_id):
		return []
	var file := FileAccess.open(entry["path"], FileAccess.READ)
	if file == null:
		return []
	var data := file.get_buffer(mini(file.get_length(), _SERIAL_SCAN_BYTES))
	file.close()
	var found: Array = []
	var re := RegEx.new()
	re.compile("[A-Z]{4}-\\d{5}")
	for match: RegExMatch in re.global_regex_search(data.get_string()):
		var serial: String = match.get_string(0)
		if serial not in found:
			found.append(serial)
	return found


## The CHD header of [param entry], when it is a CHD: its type, its sectors, their size.
func _chd_header(platform_id: String, entry: Dictionary) -> Variant:
	if entry["size"] <= 0xC0 or platform_id not in ["ps2", "psx", "xbox", "xbox360"]:
		return null
	var file := FileAccess.open(entry["path"], FileAccess.READ)
	if file == null:
		return null
	file.seek(0x80)
	var head := file.get_buffer(0x20)
	file.close()
	if head.size() < 0x20 or head.slice(0, 3).get_string() != "CHD":
		return null
	var type: int = head[0x08] | (head[0x09] << 8) | (head[0x0A] << 16) | (head[0x0B] << 24)
	var sectors: int = head[0x10] | (head[0x11] << 8) | (head[0x12] << 16) | (head[0x13] << 24)
	var sector_size: int = head[0x14] | (head[0x15] << 8) | (head[0x16] << 16) | (head[0x17] << 24)
	return {"type": type, "sectors": sectors, "sector_size": sector_size}


## The last region tag of [param name], its last ` (tag)` that is not a disc number; empty when
## it has none.
static func _tag_of(name: String) -> String:
	var re := RegEx.new()
	re.compile(_TAG_RE)
	var disc_re := RegEx.new()
	disc_re.compile(_TAG_DISC_RE)
	var region := ""
	for match: RegExMatch in re.global_regex_search(name):
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
		out = out.substr(0, match.start(0))
	return out.strip_edges()


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
	var shelves: Array = _current.get("shelves", {}).get("shelves", [])
	var identified := 0
	for game: Dictionary in games:
		if game["identified"]:
			identified += 1
	lines.append("  %d games on %d consoles, %d identified" % [games.size(), shelves.size(), identified])
	var not_games: Dictionary = _current.get("not_games", {})
	var ignored_count := _not_games_count(not_games)
	var ignored: Dictionary = _current.get("ignored_counts", {})
	if not ignored.is_empty():
		ignored_count += ignored.get("*", {}).get("unsupported", {}).get("count", 0)
	if ignored_count > 0:
		lines.append("  %d file(s) set aside (too small or unsupported)" % ignored_count)
	for shelf: Dictionary in shelves:
		var platform_id: String = str(shelf["platform"])
		lines.append("  %s (%s):" % [_platform_names.get(platform_id, platform_id), platform_id])
		var shown := 0
		for index: int in shelf["games"]:
			if shown >= 8:
				lines.append("    …")
				break
			shown += 1
			lines.append("    %s" % _one_line(games[index]))
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
	var discs: int = game["discs"].size()
	if discs > 1:
		detail += ", %d discs" % discs
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
	var chd: Variant = report.get("chd")
	if chd is Dictionary and not chd.is_empty():
		lines.append("  chd:       type=%d sectors=%d sector_size=%d" % [chd["type"], chd["sectors"],
			chd["sector_size"]])
	lines.append("  would run: %s" % report.get("command", ""))
	return "\n".join(lines)
