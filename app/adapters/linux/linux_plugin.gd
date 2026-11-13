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
## A file under a folder named for a platform is a game of that platform when the platform
## lists the file's extension; a file beside any folder (or under a folder no platform names,
## which holds bios and backups, not games) is a game of the first platform, in [constant
## _ORDER], that lists the extension and whose minimum size
## (`res://data/platforms/profiles.json`) the file reaches, a zip's as its member's. Below every
## candidate's minimum it is a `not_games` of the first candidate; with no candidate at all it
## is ignored (`unsupported`), as is a file under a platform folder the platform does not list
## (a media cache, a game folder's bindings, a bios).

## The launch was rehearsed: nothing was started; [param report] is what would have run.
signal launch_reported(report: Dictionary)

const _PROFILES := "res://data/platforms/profiles.json"
const _TITLES := "res://data/titles"
const _PRINTS := "res://data/prints"
## The order an ambiguous file beside the folder (several platforms list its extension)
## resolves to, most probable first: the disc images of the biggest consoles, then the
## cartridges, most specific last.
const _ORDER: Array[String] = ["ps2", "psx", "xbox360", "xbox", "wii", "gc", "n64", "snes", "nes",
	"gbc", "gb", "gba", "ps3", "dreamcast"]
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
	"ps3": ["iso"],
	"dreamcast": ["iso", "chd", "gd", "cdi", "cue", "img", "mdf", "bin"],
	"gc": ["gcm", "rvc", "d64", "gcz", "wia", "gcp", "dlo", "rvz"],
	"wii": ["wia", "wii", "wdb", "rvl", "rvz", "wbfs"],
	"xbox": ["iso", "chd", "ciso", "xiso", "xch", "xic", "xis", "nrg", "cvg", "xcd",
		"ziso", "dch", "wch", "gch"],
	"xbox360": ["iso", "chd", "ciso", "xch", "xic", "xis", "nrg", "cvg", "ziso", "dch",
		"wch", "gch", "zar"],
}
## What a launch would run, per platform, `{file.path}` being the file: the rehearsal where the
## conf lists no player for the platform; the honest answer where Linux has no common emulator.
const _COMMANDS: Dictionary = {
	"nes": "retroarch {file.path}",
	"snes": "retroarch {file.path}",
	"n64": "retroarch {file.path}",
	"gb": "retroarch {file.path}",
	"gbc": "retroarch {file.path}",
	"gba": "retroarch {file.path}",
	"psx": "retroarch {file.path}",
	"ps2": "pcsx2 {file.path}",
	"ps3": "rpcs3 {file.path}",
	"dreamcast": "kega_fusion {file.path}",
	"gc": "dolphin-qt {file.path}",
	"wii": "dolphin-qt {file.path}",
	"xbox": "{file.path}  # no common Linux emulator: the file is shown only",
	"xbox360": "{file.path}  # no common Linux emulator: the file is shown only",
}
## How deep the walk goes, and how many files it holds: past either, the folder is too much.
const _MAX_DEPTH := 12
const _MAX_FILES := 20000
## The largest file the parsers take in whole.
const _MAX_PARSE_BYTES := 64 * 1024 * 1024
## The parse cache's version: a change in the parse or the cache's shape is a bump, the old
## file's refused, the whole scan's the cache's off.
const _PARSE_CACHE_VERSION := 1
## The reference DB's cache's version: a change in the reference lists' data or the cache's
## shape is a bump, the old file's refused, the lists' parsed again.
const _REF_CACHE_VERSION := 1
## The `(Disc N)` and the trailing `Disc N` of a file name, numbered for [method _disc_number].
const _DISC_NUMBER_RE := "\\((?:disc|disk)\\s*(\\d+)\\)|(?:^|\\s)(?:disc|disk)\\s*[-:]?\\s*(\\d+)$"
## The `(disc N)` and the trailing `disc N` of a file name, for [method _group_key].
const _DISC_KEY_RE := "\\s*\\((?:disc|disk)\\s*\\d+\\)|(?:^|\\s)(?:disc|disk)\\s*[-:]?\\s*\\d+\\s*$"
## The ` (tag)` of a reference name, a region or a language, comma-separated.
const _TAG_RE := " \\(([A-Za-z][A-Za-z ,]{0,11})\\)"
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
var _parse_cache: Dictionary = {}
var _parse_cache_loaded := false
var _cache_bypass := false
static var _dir_override := ""
static var _title_lists: Dictionary = {}
static var _print_lists: Dictionary = {}
static var _serial_index: Dictionary = {}
static var _ref_cache_path := ""
static var _ref_loaded := false
static var _ref_parse_io := 0
static var _label_region := ""
static var _label_source := ""
static var _crc_table: PackedInt32Array = []
static var _config_override := ""
static var _config_path := ""
static var _config_resolved := false
static var _config_text := ""
static var _config_parsed := false
static var _players: Dictionary = {}
static var _aliases: Dictionary = {}
static var _extra_dirs: Array = []
static var _rehearsal := true


## `--option=value` among the launch arguments, whatever the build: the demo arguments go through
## [method Diagnostics.argument], which is silent in release builds, and this one is not.
static func argument(option: String) -> String:
	var prefix := "--%s=" % option
	var flag := "--" + option
	for given: String in OS.get_cmdline_user_args():
		if given.begins_with(prefix):
			return given.trim_prefix(prefix)
		if given == flag:
			return "1"
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


## The parse cache's file, for tests (the cache dir's `scan-cache.json` the default): the scan's
## per-file parse keyed on the file's path, size, and mtime; the second scan of an
## unchanged folder reads the parse, not the file.
static var _scan_cache_path := ""
## The walks this run did (one per [method _build_library]): the one scan is the startup's.
static var _walk_io := 0
## The parses this run did for real, a test's measure of the parse cache's work.
static var _parse_io := 0


static func set_scan_cache_path(path: String) -> void:
	_scan_cache_path = path


## The reference cache's file, for tests (the cache dir's `ref-cache.json` the default).
static func set_ref_cache_path(path: String) -> void:
	_ref_cache_path = path


## Where the launch config stands: `--config=PATH` among the arguments, the `CARTOUCHE_CONFIG`
## environment, `cartouche.conf` beside the executable, or `cartouche.conf` beside the working
## directory; empty when it stands nowhere (then the launch rehearses the fallback command).
## The conf, a `cartouche.conf`: the top-level keys `rehearsal` (true or false; the rehearsal
## until told otherwise), `path` (colon-separated dirs the player binaries are looked in, before
## the system `PATH`) and `alias.NAME = PATH` (the binary `NAME` stands at `PATH`); then, per
## platform section, the players in priority order, a player its command line, the `{file.path}`
## placeholder for the game file, and, for a player, its `accept` regular expression, matched
## against the file name (none, it accepts every file of the platform), and its `stop_first`,
## the lingering instances of the emulator stopped before the start (it would resume the
## previous game).
static func config_path() -> String:
	if _config_resolved:
		return _config_path
	_config_resolved = true
	var source := ""
	var given := argument("config")
	if not given.is_empty():
		source = given
	elif not _config_override.is_empty():
		source = _config_override
	else:
		var env := OS.get_environment("CARTOUCHE_CONFIG")
		if env:
			source = env
		else:
			var beside_executable := OS.get_executable_path().get_base_dir().path_join("cartouche.conf")
			if FileAccess.file_exists(beside_executable):
				source = beside_executable
			elif FileAccess.file_exists("cartouche.conf"):
				source = "cartouche.conf"
	_config_path = source
	if not source.is_empty():
		if FileAccess.file_exists(source):
			_config_text = FileAccess.get_file_as_string(source)
		else:
			print("Cartouche config: %s does not exist: no player is installed" % source)
	return _config_path


## Tests: the launch config stands at [param path] instead of the usual place.
static func set_config(path: String) -> void:
	_config_override = path
	_reset_config()


static func _reset_config() -> void:
	_config_path = ""
	_config_resolved = false
	_config_text = ""
	_config_parsed = false
	_players = {}
	_aliases = {}
	_extra_dirs = []
	_rehearsal = true


## The conf, parsed once: the rehearsal, the `path` dirs and the `alias`es on top, then, per
## platform section, the players, in order, each with its `accept` and `stop_first`.
static func _parse_config() -> void:
	if _config_parsed:
		return
	# The text is loaded by [method config_path]: resolve it here, or the parse would run on
	# the empty text and lock the empty players when the Emulator option asks before any launch.
	config_path()
	_config_parsed = true
	var section := ""
	for raw_line: String in _config_text.split("\n"):
		var line: String = raw_line.strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		if line.begins_with("[") and line.ends_with("]"):
			section = line.substr(1, line.length() - 2).strip_edges()
			continue
		var at := line.find("=")
		if at < 0:
			print("Cartouche config: a line without '=' is ignored: %s" % line)
			continue
		var key: String = line.substr(0, at).strip_edges()
		var value: String = line.substr(at + 1).strip_edges()
		if section.is_empty():
			_global_key(key, value)
		else:
			_player_key(section, key, value)


static func _global_key(key: String, value: String) -> void:
	if key == "rehearsal":
		var rehearsal_value: Variant = _bool_of(value)
		if rehearsal_value != null:
			_rehearsal = rehearsal_value == true
		else:
			print("Cartouche config: rehearsal must be true or false, got: %s" % value)
	elif key == "path":
		_extra_dirs = []
		for dir: String in value.split(":"):
			var trimmed: String = dir.strip_edges()
			if not trimmed.is_empty():
				_extra_dirs.append(trimmed)
	elif key.begins_with("alias."):
		_aliases[key.trim_prefix("alias.")] = value
	else:
		print("Cartouche config: an unknown key is ignored: %s" % key)


static func _player_key(platform_id: String, key: String, value: String) -> void:
	var players: Array = _players.get(platform_id, [])
	var dot := key.find(".")
	if dot < 0:
		var exists := false
		for player: Dictionary in players:
			if str(player["name"]) == key:
				exists = true
				break
		if exists:
			print("Cartouche config: the player %s of %s is listed twice; the first wins" % [key, platform_id])
			return
		players.append({"name": key, "command": value, "binary_token": _binary_token(value),
			"accept": null, "broken": false, "stop_first": false})
		_players[platform_id] = players
		return
	var player_name: String = key.substr(0, dot)
	var property: String = key.substr(dot + 1)
	var player := _find_player(players, player_name)
	if player.is_empty():
		print("Cartouche config: %s has no player %s (list the player first); ignored" % [platform_id, player_name])
		return
	if property == "accept":
		var pattern := RegEx.new()
		if pattern.compile(value) != OK:
			player["broken"] = true
			print("Cartouche config: the %s accept of %s is not a regular expression and the player is disabled" % [player_name, platform_id])
		else:
			player["accept"] = pattern
	elif property == "stop_first":
		var stop_value: Variant = _bool_of(value)
		if stop_value != null:
			player["stop_first"] = stop_value == true
		else:
			print("Cartouche config: %s.stop_first must be true or false, got: %s" % [player_name, value])
	else:
		print("Cartouche config: an unknown property of %s is ignored: %s" % [player_name, key])


static func _find_player(players: Array, name: String) -> Dictionary:
	for player: Dictionary in players:
		if str(player["name"]) == name:
			return player
	return {}


static func _bool_of(value: String) -> Variant:
	var lower: String = value.to_lower()
	if lower in ["true", "1", "yes"]:
		return true
	if lower in ["false", "0", "no"]:
		return false
	return null


## Where [param name] stands: its `alias` in the conf, else in the conf's `path` dirs, else in
## the system `PATH`; empty when it stands nowhere (the player is then not installed).
static func binary_at(name: String) -> String:
	var aliased: String = str(_aliases.get(name, ""))
	if not aliased.is_empty():
		return aliased if FileAccess.file_exists(aliased) else ""
	for dir: String in _extra_dirs:
		var in_dirs: String = dir.path_join(name)
		if FileAccess.file_exists(in_dirs):
			return in_dirs
	for dir: String in OS.get_environment("PATH").split(":"):
		if dir.is_empty():
			continue
		var in_path: String = dir.path_join(name)
		if FileAccess.file_exists(in_path):
			return in_path
	return ""


## The player of [param platform_id] that opens [param file_name]: the first of the conf's, in
## order, that is installed (its binary stands, [method binary_at]) and whose `accept` matches
## the file name; the first of the platform when it has no `accept`; none, the empty one.
static func select_player(platform_id: String, file_name: String) -> Dictionary:
	var players: Array = _players.get(platform_id, [])
	for player: Dictionary in players:
		if player.get("broken", false):
			continue
		if binary_at(str(player.get("binary_token", ""))).is_empty():
			continue
		var accept: RegEx = player.get("accept")
		if accept != null:
			var match := accept.search(file_name, 0, file_name.length())
			if match == null:
				continue
		return player
	return {}


## The rehearsal's command of [param platform_id] on [param file], `{file.path}` filled: the
## fallback where the conf lists no player for the platform.
static func command_for(platform_id: String, file: String) -> String:
	return _fill(str(_COMMANDS.get(platform_id, "{file.path}")), file)


## The template with `{file.path}` filled.
static func _fill(template: String, file: String) -> String:
	return template.replace("{file.path}", file)


## The binary the command line starts with, trimmed: the player's, looked in by [method binary_at].
static func _binary_token(command: String) -> String:
	var stripped: String = command.strip_edges()
	var end := 0
	while end < stripped.length() and not stripped[end] in [" ", "	"]:
		end += 1
	return stripped.substr(0, end)


## The platform of a file beside the folder, by [param ext] and [param size]: the first of
## [constant _ORDER] that lists the extension and whose minimum the file reaches; none when no
## platform lists it; the first candidate when the file is below every candidate's minimum
## (a `not_games` of it).
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
func _library_answer() -> Dictionary:
	_ensure_scanned()
	var games: Array = _current.get("games", [])
	if games.is_empty():
		return _demo_library()
	return {"ok": true, "library": _current}


func library(_id: int) -> String:
	return JSON.stringify(_library_answer())


## The carousel asks here on a desktop, and the desktop demo would answer made-up: the scanned
## library instead, or the demo's when the folder holds no games at all.
func useDemoLibrary(id: int, _games: int, _platform_id: String) -> String:
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
		return JSON.stringify({"marks": []})
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
			marks.append({"start": at, "length": needle.length()})
			from += needle_l.length()
	return JSON.stringify({"marks": marks})


## The launch: rehearsed when there is no conf, or the conf rehearses, run for real otherwise.
## The player is the conf's, per platform in order: the first installed one (its binary
## stands, [method binary_at]) whose `accept` matches the file name; none, the launch refuses
## as no player of the platform opens the game. Rehearsed, the report is printed and nothing
## is started; for real, a player with `stop_first` first stops its lingering instances (the
## emulator would resume the previous game), and its command, the conf's line with
## `{file.path}` filled, runs, the emulator left to the display server of the container.
func launchGame(_id: int, launch: Dictionary) -> String:
	var game_id: String = str(launch.get("game_id", ""))
	var game: Dictionary = _game_by_id(game_id)
	if game.is_empty():
		return JSON.stringify({"ok": false, "code": &"game_missing", "detail": "the library has no such game"})
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
	var platform_id: String = str(game["platform_id"])
	var report := {
		"game": game["title"],
		"platform": _platform_names.get(platform_id, platform_id),
		"platform_id": platform_id,
		"medium": game.get("medium", ""),
		"file": file,
		"size": disc_size,
		"crc32": meta.get("crc32", ""),
		"serials": meta.get("serials", []),
		"ref_code": meta.get("ref_code", ""),
		"chd": meta.get("chd"),
	}
	if not FileAccess.file_exists(file):
		report["command"] = command_for(platform_id, file)
		var missing_text := _report_text(report)
		report["text"] = missing_text
		print(missing_text)
		print("  the game file is missing or cannot be read")
		launch_reported.emit(report)
		return JSON.stringify({"ok": false, "code": &"file_missing",
			"detail": "the game file %s is missing or cannot be read" % file})
	var conf_path: String = config_path()
	if conf_path.is_empty():
		report["command"] = command_for(platform_id, file)
		var rehearsal_text := _report_text(report)
		report["text"] = rehearsal_text
		print(rehearsal_text)
		launch_reported.emit(report)
		return JSON.stringify({"ok": false, "code": &"linux_printed",
			"detail": "launch rehearsed and printed: no emulator is started on Linux"})
	_parse_config()
	var selected: Dictionary = select_player(platform_id, file.get_file())
	if selected.is_empty():
		report["player"] = ""
		report["binary"] = ""
		report["stop_first"] = false
		report["rehearsal"] = _rehearsal
		report["config"] = conf_path
		report["command"] = ""
		var no_player_text := _report_text(report)
		report["text"] = no_player_text
		print(no_player_text)
		launch_reported.emit(report)
		return JSON.stringify({"ok": false, "code": &"linux_no_player",
			"detail": "no installed emulator for %s opens this game" % str(_platform_names.get(platform_id, platform_id))})
	var player_name: String = str(selected["name"])
	var binary := binary_at(str(selected.get("binary_token", "")))
	var command := _fill(str(selected["command"]), file)
	var rehearsal := _rehearsal
	var stop_first: bool = selected.get("stop_first") == true
	report["player"] = player_name
	report["binary"] = binary
	report["stop_first"] = stop_first
	report["rehearsal"] = rehearsal
	report["config"] = conf_path
	report["command"] = command
	var text := _report_text(report)
	report["text"] = text
	print(text)
	launch_reported.emit(report)
	if rehearsal:
		return JSON.stringify({"ok": false, "code": &"linux_printed",
			"detail": "launch rehearsed and printed: no emulator is started on Linux"})
	if stop_first:
		var kill_rc: int = OS.execute("pkill", ["-f", binary])
		if kill_rc < 0:
			print("Cartouche launch: pkill could not run (is procps installed?)")
	# The first word of the command is the player's binary, stood where the conf says. The
	# engine re-tokenizes `OS.execute` arguments (a quoted path would split) and holds the
	# call open until every process with the child's output pipe is gone, so the command line
	# stands in a file `sh` runs, and the emulator's output goes to a log file, not the pipe:
	# the emulator is left to the container, and `sh` returns once it is started. The file
	# stands quoted (the report keeps it unquoted), and the binary where the conf says,
	# quoted too when it has a space.
	var quoted_file := "\"" + file.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
	var run_command: String = _fill(str(selected["command"]), quoted_file)
	var stripped_command: String = run_command.strip_edges()
	var rest: String = stripped_command.substr(_binary_token(stripped_command).length())
	var line_binary := binary
	if binary.find(" ") >= 0:
		line_binary = "\"" + binary.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
	var line: String = line_binary + rest + " >> /tmp/cartouche-%s.log 2>&1 &" % str(selected["name"])
	var script_path: String = "/tmp/cartouche-%s-%d.sh" % [str(selected["name"]), Time.get_ticks_msec()]
	var sfile := FileAccess.open(script_path, FileAccess.WRITE)
	if sfile == null:
		return JSON.stringify({"ok": false, "code": &"launch_failed",
			"detail": "the launch script %s cannot be written" % script_path})
	sfile.store_string(line + "\n")
	sfile.close()
	var start_rc: int = OS.execute("/bin/sh", [script_path])
	if start_rc != 0:
		return JSON.stringify({"ok": false, "code": &"launch_failed",
			"detail": "the launch failed (exit %d): %s" % [start_rc, command]})
	return JSON.stringify({"ok": true, "code": &"linux_launched", "detail": "launched: %s" % command})


## The forced rescan ([method scanPlatform], [method rescrape]): every game file read anew,
## the caches' reads standing for the rest; no label is looked for (there is no
## ScreenScraper here, by design).
func _rescan() -> Dictionary:
	_cache_bypass = true
	_scanned = false
	var answer: Dictionary = _library_answer()
	var games: Array = _current.get("games", [])
	answer["games"] = games.size()
	answer["labels"] = 0
	return answer


func rescrape(_id: int) -> String:
	return JSON.stringify(_rescan())


## The scan of [param platform_id]'s folder: the folder is one for every platform here, so the
## scan is the whole scan, and the report its own.
func scanPlatform(_id: int, platform_id: String) -> String:
	var answer: Dictionary = _rescan()
	answer["report"] = _scan_report(platform_id)
	return JSON.stringify(answer)


## How many games a scan of [param platform_id]'s folder would find, without saving anything.
func previewPlatform(_id: int, platform_id: String, _setup: Dictionary) -> String:
	_ensure_scanned()
	return JSON.stringify({"ok": true, "report": _scan_report(platform_id)})


## The desktop stand-in's name is the system's; the Linux one says it is Linux.
func deviceName() -> String:
	return "%s %s" % [OS.get_name(), OS.get_version()]


## The catalog as the stand-in sends it: the demo's, one source of the consoles' ring.
func loadCatalog(..._data: Array) -> String:
	return JSON.stringify(demo("catalog"))


## The installed players of [param platform_id], in the conf's order, for the form's list:
## the broken one (its binary does not stand) is not in it.
func installedPlayers(platform_id: String) -> String:
	_parse_config()
	var players: Array = []
	var conf_players: Array = _players.get(platform_id, [])
	for player: Dictionary in conf_players:
		if player.get("broken", false):
			continue
		if binary_at(str(player.get("binary_token", ""))).is_empty():
			continue
		players.append({"id": str(player["name"]), "name": str(player["name"]),
			"emulator_name": str(player.get("binary_token", ""))})
	return JSON.stringify({"players": players})


func battery() -> String:
	return JSON.stringify(demo("battery"))


## No curtain on a Linux desktop: the emulator shows in its own window.
func curtainAllowed() -> String:
	return "false"


func launchArguments() -> String:
	return JSON.stringify(OS.get_cmdline_user_args())


func releaseMemory() -> void:
	pass


func prepareTables(_platform_id: String) -> void:
	pass


func currentLibrary(_id: int) -> String:
	return JSON.stringify(_library_answer())


func selectGame(_id: int, _game_id: String) -> String:
	return JSON.stringify({"ok": true})


func enterConsole(_id: int, _platform_id: String) -> String:
	return JSON.stringify({"ok": true, "arrivals": {"unseen": [], "announced": {}}})


func leaveGame(_id: int, _game_id: String) -> String:
	return JSON.stringify({"ok": true, "arrivals": {"unseen": [], "announced": {}}})


## The refresh's answer: the library as it stands, no rescan here — the one scan is the
## startup's, a new game shows after a restart, by design — and no arrivals on a Linux
## scan (the demo's).
func refreshPlatform(_id: int, _platform_id: String) -> String:
	var answer: Dictionary = _library_answer()
	answer["arrivals"] = {"unseen": [], "announced": {}}
	return JSON.stringify(answer)


func removePlatform(_id: int, _platform_id: String) -> String:
	return JSON.stringify({"ok": false, "code": &"unexpected",
		"detail": "the Linux scan reads a folder and keeps no per-platform setup to remove"})


func orderConsoles(_id: int, _platform_ids: PackedStringArray) -> String:
	return JSON.stringify({"ok": false, "code": &"unexpected",
		"detail": "the Linux scan shows its consoles in the catalog's order"})


func placeConsole(_id: int, _platform_id: String, _gap: int) -> String:
	# The stand-in's no-story code: without a picked folder the scan keeps its own order.
	return JSON.stringify({"ok": false, "code": &"unavailable",
		"detail": "the Linux scan shows its consoles in the catalog's order"})


## The rehearsal's answer without running: the game, its disc's file, and the platform's
## player all stand, or the same refusal [method launchGame] would give.
func checkLaunch(_id: int, launch: Dictionary) -> String:
	var game_id: String = str(launch.get("game_id", ""))
	var game: Dictionary = _game_by_id(game_id)
	if game.is_empty():
		return JSON.stringify({"ok": false, "code": &"game_missing",
			"detail": "the library has no such game"})
	var files: PackedStringArray = _file_by_game.get(game_id, PackedStringArray())
	var disc: int = launch.get("disc", 0)
	if disc >= files.size():
		return JSON.stringify({"ok": false, "code": &"game_missing",
			"detail": "the game has no such disc"})
	var file: String = files[disc]
	if not FileAccess.file_exists(file):
		return JSON.stringify({"ok": false, "code": &"file_missing",
			"detail": "the game file %s is missing or cannot be read" % file})
	var platform_id: String = str(game["platform_id"])
	_parse_config()
	if select_player(platform_id, file.get_file()).is_empty():
		return JSON.stringify({"ok": false, "code": &"linux_no_player",
			"detail": "no installed emulator for %s opens this game" % str(_platform_names.get(platform_id, platform_id))})
	return JSON.stringify({"ok": true})


func persistedFolders(_id: int) -> String:
	return JSON.stringify({"ok": true, "folders": []})


func requestCurtainPermission(_id: int) -> String:
	return JSON.stringify({"ok": false, "code": &"activity_not_found",
		"detail": "Linux has no curtain permission to ask for"})


## The one-shot answers: the scan's pipeline does its own, and the stand-in's one-shot
## variants have no stand for them here.
func chooseLabel(_id: int, _game_id: String, _region: String, _source: String) -> String:
	return JSON.stringify({"ok": false, "code": &"unexpected",
		"detail": "the scan's art pipeline chooses the label on its own"})


func renameGame(_id: int, _game_id: String, _shown: String) -> String:
	return JSON.stringify({"ok": false, "code": &"unexpected",
		"detail": "the scan reads the title from the file and keeps no rename"})


func pickLabelPicture(_id: int) -> String:
	return JSON.stringify({"ok": false, "code": &"activity_not_found",
		"detail": "Linux has no system picture picker"})


func keepOwnLabel(_id: int, _game_id: String, _zoom: float, _centre_x: float, _centre_y: float, _proportion: float) -> String:
	return JSON.stringify({"ok": false, "code": &"unexpected",
		"detail": "the scan's art pipeline stores the label it finds"})


# ---------------------------------------------------------------- the scan


func _ensure_scanned() -> void:
	if _scanned:
		return
	_scanned = true
	_read_data()
	_load_parse_cache()
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
		_ss_system[platform_id] = str(profile.get("screenScraperSystem", 0)).to_int()
		var scans_raw: Variant = profile.get("scansBySerial", {})
		var scans: Dictionary = {}
		if scans_raw is Dictionary:
			scans = scans_raw
		_art_scans_url[platform_id] = str(scans.get("url", ""))
	if not _load_ref_cache():
		_ref_parse_io += 1
		_title_lists = _list(_TITLES, true)
		_print_lists = _list(_PRINTS, false)
		_serial_index = _serial_lists()
		_store_ref_cache()


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
	# The prefilter: walk only the catalog consoles' folders, so the parse cache stops
	# tracking the root's files and the folders no catalog console claims (their parse
	# entries would be throwaway).
	for console: String in _catalog_order():
		_walk(dir.path_join(console), console, 0, files)
	_walk_io += 1
	var games: Array = []
	var not_games: Dictionary = {}
	var unsupported: Array = []
	# one group per platform and name, the discs of a set sharing one
	var groups: Dictionary = {}
	for entry: Dictionary in files:
		var name: String = entry["name"]
		var size: int = entry["size"]
		var ext: String = name.get_extension().to_lower()
		# The folder is the platform: the library keeps one folder per console, and the files a
		# platform does not list under its folder (a bios, a backup, a media cache) are not
		# games. Beside the folder, the extension and the size decide, a zip's as its member's,
		# the archive's ROM, not the wrapper, being the game.
		var platform_id := ""
		var rel_path: String = str(entry["rel"])
		var slash: int = rel_path.find("/")
		if slash >= 0:
			var folder: String = rel_path.substr(0, slash).to_lower()
			if folder in _EXTENSIONS:
				if ext == "zip":
					var member: String = _zip_member_ext(str(entry["path"]))
					if not member.is_empty():
						ext = member
				if ext in _EXTENSIONS[folder]:
					platform_id = folder
		else:
			if ext == "zip":
				var member: String = _zip_member_ext(str(entry["path"]))
				if not member.is_empty():
					ext = member
			platform_id = platform_of(ext, size, _min_bytes)
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
			shelves.append({"platform_id": platform_id, "game_indexes": platform_games, "selected": 0})
	var library_data: Dictionary = {
		"revision": 0,
		"setups": {},
		"games": games,
		"not_games": not_games,
		"ignored_counts": {"*": [{"reason": "unsupported",
			"count": unsupported.size(),
			"examples": unsupported.slice(0, 3)}]},
		"skipped_folders": {},
		"console_variants": {},
		"shelves": shelves,
		"selected_shelf": 0,
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
	_store_parse_cache(files)
	_cache_bypass = false
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
			"size": _size_of(path), "mtime": _mtime_of(path)})


## The file's mtime, unix seconds: the parse cache's key beside its size.
static func _mtime_of(path: String) -> int:
	return FileAccess.get_modified_time(path)


## The parse of [param entry] — its print, its serials, its CHD header — the cache's when
## the file stands as the cache says (its size, its mtime, its platform), the file's reads
## otherwise, the cache's new line either way.
func _parse_entry(platform_id: String, entry: Dictionary) -> Dictionary:
	var path := str(entry["path"])
	var size: int = entry["size"]
	var mtime: int = _mtime_of(path)
	var cached: Dictionary = _parse_cache.get(path, {})
	if not _cache_bypass and cached.has("crc") and cached.has("serials") and cached.has("chd") \
		and cached.get("size") == size and cached.get("mtime") == mtime \
		and str(cached.get("platform", "")) == platform_id:
		var cached_serials: Array = cached["serials"]
		return {"crc": str(cached["crc"]), "serials": cached_serials.duplicate(),
			"chd": _dup_chd(cached["chd"])}
	_parse_io += 1
	var crc := _print_of(platform_id, entry)
	var serials := _serials_of(entry)
	var chd: Variant = _chd_header(platform_id, entry)
	_parse_cache[path] = {"platform": platform_id, "size": size, "mtime": mtime,
		"crc": crc, "serials": serials, "chd": chd}
	return {"crc": crc, "serials": serials.duplicate(), "chd": _dup_chd(chd)}


static func _dup_chd(chd: Variant) -> Variant:
	if chd is Dictionary:
		var stored: Dictionary = chd
		return stored.duplicate(true)
	return null


## The parse cache's file: the tests' [method set_scan_cache_path], the user's data's
## default.
static func _parse_cache_file() -> String:
	return _scan_cache_path if _scan_cache_path else cache_dir() + "/scan-cache.json"


## The parse cache, from its file: when it is this folder's, its version's, its files' lines.
func _load_parse_cache() -> void:
	if _parse_cache_loaded:
		return
	_parse_cache_loaded = true
	var path := _parse_cache_file()
	if not FileAccess.file_exists(path):
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return
	var payload: Dictionary = parsed
	var version: int = payload.get("version", 0)
	if version != _PARSE_CACHE_VERSION:
		return
	if str(payload.get("dir", "")) != games_dir():
		return
	var files: Variant = payload.get("files", {})
	if files is Dictionary:
		_parse_cache = files


## The parse cache, to its file: the lines the walk still shows, its folder, its version.
func _store_parse_cache(files: Array) -> void:
	var live := {}
	for entry: Dictionary in files:
		live[str(entry["path"])] = true
	for path: String in _parse_cache.keys():
		if not live.has(str(path)):
			_parse_cache.erase(path)
	var out := FileAccess.open(_parse_cache_file(), FileAccess.WRITE)
	if out == null:
		return
	out.store_string(JSON.stringify({"version": _PARSE_CACHE_VERSION,
		"dir": games_dir(), "files": _parse_cache}))
	out.close()


## The reference cache's file: the tests' [method set_ref_cache_path], the user's data's
## default.
static func _ref_cache_file() -> String:
	return _ref_cache_path if _ref_cache_path else cache_dir() + "/ref-cache.json"


## The reference lists' sizes, `{path: bytes}`: the cache's integrity check, a PCK file's
## standing beside its version (the packaged files' have no mtime).
static func _ref_sizes() -> Dictionary:
	var folders: Array[String] = [_TITLES, _PRINTS]
	var sizes: Dictionary = {}
	for folder: String in folders:
		for file_name: String in DirAccess.get_files_at(folder):
			if not file_name.ends_with(".tsv"):
				continue
			var path := folder.path_join(file_name)
			var file := FileAccess.open(path, FileAccess.READ)
			if file == null:
				continue
			sizes[path] = file.get_length()
			file.close()
	return sizes


## The cached sizes against the lists' own, in bytes: a JSON number's a float, the lists'
## [method _ref_sizes]' ints, and the lists' compare's the parser's types' off, so the bytes'
## the compare, the types' its aside.
static func _sizes_match(loaded: Variant) -> bool:
	if not (loaded is Dictionary):
		return false
	var live: Dictionary = _ref_sizes()
	var loaded_dict: Dictionary = loaded
	if loaded_dict.size() != live.size():
		return false
	for key: String in live:
		if not loaded_dict.has(key):
			return false
		var loaded_val: float = loaded_dict[key]
		var live_val: float = live[key]
		if loaded_val != live_val:
			return false
	return true


## The reference DB, from its file: when it is the version's and the lists' sizes' its parsed
## lines, the run's [constant _ref_loaded] knows it stood and the parse's off.
static func _load_ref_cache() -> bool:
	if _ref_loaded:
		return true
	var path := _ref_cache_file()
	if not FileAccess.file_exists(path):
		return false
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return false
	var payload: Dictionary = parsed
	var version: int = payload.get("version", 0)
	if version != _REF_CACHE_VERSION:
		return false
	var sizes: Variant = payload.get("sizes", {})
	if not _sizes_match(sizes):
		return false
	var titles: Variant = payload.get("titles", {})
	if not (titles is Dictionary):
		return false
	var print_data: Variant = payload.get("prints", {})
	if not (print_data is Dictionary):
		return false
	var serials: Variant = payload.get("serials", {})
	if not (serials is Dictionary):
		return false
	_title_lists = titles
	_print_lists = print_data
	_serial_index = serials
	_ref_loaded = true
	return true


## The reference DB, to its file: the parsed lines, its version, the lists' sizes.
static func _store_ref_cache() -> void:
	var out := FileAccess.open(_ref_cache_file(), FileAccess.WRITE)
	if out == null:
		return
	out.store_string(JSON.stringify({"version": _REF_CACHE_VERSION,
		"sizes": _ref_sizes(), "titles": _title_lists,
		"prints": _print_lists, "serials": _serial_index}))
	out.close()


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
	# The print and the parse of the first file, the serials of every one: the file's reads
	# the parse cache stands for (keyed on the file's path, size, and mtime), a rescan's the
	# bypass, the file read again.
	var first: Dictionary = entries[0]
	var first_name: String = first["name"]
	var first_parse: Dictionary = _parse_entry(platform_id, first)
	var crc: String = str(first_parse.get("crc", ""))
	var serials: Array = []
	for entry: Dictionary in entries:
		for serial: Variant in _parse_entry(platform_id, entry).get("serials", []):
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
		"ref_code": ref_code, "chd": first_parse.get("chd", null)}
	return game


# ------------------------------------------------------------- the cartridge print

## The print No-Intro lists for [param entry], as the core counts it: the ROM's CRC32, the
## iNES and copier headers not in it, a zip's as its archive records it; empty on a disc,
## where the serial, not a print, is what identifies it.
static func _print_of(platform_id: String, entry: Dictionary) -> String:
	if platform_id in ["ps2", "psx", "wii", "gc", "xbox", "xbox360", "ps3", "dreamcast"]:
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
	if platform_id not in ["ps2", "psx", "xbox", "xbox360", "dreamcast"]:
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
	# The subtitle's separators and its punctuation mean one thing in every listing: the
	# reference lists' ` - `, LaunchBox's `:`, the `!` one listing's `Punch-Out!` is another's
	# `Punch-Out!!`, and the `.` one listing's `L.A. Rush` is another's `LA Rush`; the keys
	# compare without them, and the spaces they leave behind are re-joined, so the collapse
	# follows the cut.
	var sep := RegEx.new()
	sep.compile("[-:!.]")
	var t := sep.sub(text.strip_edges(), "", true).to_lower()
	var re := RegEx.new()
	re.compile("\\s+")
	return re.sub(t, " ", true)


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


## The last region tag of [param name], its last ` (tag)` that is a region (not a disc
## number, not `Rev N`, not a language); empty when it has none.
static func _tag_of(name: String) -> String:
	var re := RegEx.new()
	re.compile(_TAG_RE)
	var disc_re := RegEx.new()
	disc_re.compile(_TAG_DISC_RE)
	var region := ""
	for match: RegExMatch in re.search_all(name):
		var tag := match.get_string(1)
		if disc_re.search(tag) == null and _label_region_key(tag) != "":
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

## The plugin's answers, as the services' signals carry them: the JSON text the app's bridge
## speaks, each the wire's own shape.
signal answered(text: String)
signal art_changed(text: String)
signal art_progress(text: String)
signal label_variant_downloaded(text: String)
signal battery_changed(text: String)

const _ART_INDEX_DIR := "res://data/art"
const _ART_IMAGES := "https://images.launchbox-app.com/"
const _ART_SOURCE_LAUNCHBOX := "launchbox"
const _ART_SOURCE_PSDATACENTER := "psxdatacenter"
const _ART_SOURCE_SCREENSCRAPER := "screenscraper"

var _art_index: Dictionary = {}
var _art_row_names: Dictionary = {}
var _art_scans_url: Dictionary = {}
var _art_jobs: Array = []
var _art_total := 0
var _art_done := 0
var _art_stall := ""
var _art_http: Variant = null
var _art_job: Dictionary = {}
var _art_pacing := false
var _art_source_by_game: Dictionary = {}
var _ss: ScreenScraper = null
var _ss_system: Dictionary = {}


## The art folder: `--art-dir=PATH`, the `CARTOUCHE_ART_DIR` environment, or the cache dir's.
static func art_dir() -> String:
	var given := argument("art-dir")
	if given:
		return given
	var env := OS.get_environment("CARTOUCHE_ART_DIR")
	if env:
		return env
	return cache_dir() + "/art"


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
	var rows: Dictionary = {}
	var text_path := _ART_INDEX_DIR.path_join(platform_id + ".tsv")
	if FileAccess.file_exists(text_path):
		var data := FileAccess.get_file_as_bytes(text_path)
		var text: String = data.get_string_from_utf8()
		for line: String in text.split("\n"):
			var clean: String = line.rstrip("\r")
			if clean.is_empty() or clean.begins_with("#"):
				continue
			var parts := clean.split("	")
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
			var names: Array = [parts[0]]
			for alt: String in parts[1].split("|"):
				if not alt.is_empty():
					names.append(alt)
					found[_normalize(alt)] = images
			found[_normalize(parts[0])] = images
			for raw: String in names:
				var key: String = _normalize(raw)
				if not rows.has(key):
					rows[key] = names
	_art_row_names[platform_id] = rows
	_art_index[platform_id] = found
	return found


## The test's `--label-region` value (the way `set_config` stands for the conf's).
static func set_label_region(value: String) -> void:
	_label_region = value

## Whether a label must be the game's own region: `--label-region=strict` (a bare
## `--label-region` counts) turns the any-region fallback off.
static func _label_region_strict() -> bool:
	var v: String = _label_region if _label_region != "" else argument("label-region")
	return v == "strict" or v == "1"


## The test's `--label-source` value (the way `set_label_region` stands for the flag's).
static func set_label_source(value: String) -> void:
	_label_source = value


## The label's source alone asked for: `--label-source=X` (`screenscraper`, `launchbox`, or
## `psxdatacenter`); the empty string, the order's all.
static func _label_source_only() -> String:
	return _label_source if _label_source != "" else argument("label-source")

## The art index's region name for a game's region tag: `usa` is the index's `North
## America`; a multi-region tag (`usa, asia`) stands for its first; the empty string when
## the tag names no indexed region (strict: no label).
static func _label_region_key(region: String) -> String:
	for entry: String in _normalize(region).split(","):
		match entry.strip_edges():
			"usa", "us", "north america", "na":
				return "North America"
			"europe", "eu":
				return "Europe"
			"japan", "jp", "jpn":
				return "Japan"
			"world", "worldwide":
				return "World"
			"australia", "au":
				return "Australia"
	return ""

## The candidates for [param game]'s label, in priority order: ScreenScraper's (the key's
## file the source on), LaunchBox's discs' scan, and, on the serial platforms, the serial
## source's — `--label-source=X` the one, only its: each `{"source", "source_name",
## "region", "url", "file"}`.
func _art_candidates(game: Dictionary) -> Array:
	var out: Array = []
	var platform_id := str(game["platform_id"])
	var index: Dictionary = _art_index_for(platform_id)
	var images: Dictionary = {}
	var hit := ""
	for k: String in _title_keys(str(game["title"])):
		if index.has(k):
			images = index[k]
			hit = k
			break
	var game_regions: Array = game.get("regions", [])
	var region := ""
	if not game_regions.is_empty():
		region = str(game_regions[0])
	var launchbox: Dictionary = {}
	if not images.is_empty():
		var file := ""
		if _label_region_strict():
			# Enforced: the label is the game's own region's, or there is none.
			if images.has(region):
				file = str(images[region])
			else:
				var mapped: String = _label_region_key(region)
				if mapped != "" and images.has(mapped):
					file = str(images[mapped])
		elif images.has(region):
			file = str(images[region])
		else:
			for r: String in images:
				file = str(images[r])
				break
		if not file.is_empty():
			launchbox = {"source": _ART_SOURCE_LAUNCHBOX, "source_name": "LaunchBox",
				"region": region, "url": _ART_IMAGES + file, "file": file}
	var screenscraper := _art_ss_candidate(platform_id, game, hit, region)
	var serial_url := _art_serial_url(platform_id, game)
	var psxdatacenter: Dictionary = {}
	if not serial_url.is_empty():
		psxdatacenter = {"source": _ART_SOURCE_PSDATACENTER, "source_name": "PlayStation DataCenter",
			"region": "", "url": serial_url, "file": serial_url.get_slice("/", -1)}
	# The order's, or the flag's one alone.
	var only := _label_source_only()
	for candidate: Dictionary in [screenscraper, launchbox, psxdatacenter]:
		if candidate.is_empty() or (only != "" and str(candidate["source"]) != only):
			continue
		out.append(candidate)
	return out


## The ScreenScraper candidate of [param game], when the key's file is, the source open, and
## its platform's table lists a release for it: the table's game and its texture of
## [param region]; [param hit], the art index's key the game took its row under, is the
## reference names' bridge to the table.
func _art_ss_candidate(platform_id: String, game: Dictionary, hit: String, region: String) -> Dictionary:
	if _ss == null:
		_ss = ScreenScraper.new()
	if not _ss.enabled() or not _ss.open():
		return {}
	var keys: Array = _title_keys(str(game["title"]))
	var rows_of: Dictionary = _art_row_names.get(platform_id, {})
	var names: Array = rows_of.get(hit, [])
	for raw: String in names:
		for key: String in ScreenScraper.row_keys(raw):
			if not keys.has(key):
				keys.append(key)
	var row: Dictionary = _ss.lookup(platform_id, keys)
	if row.is_empty():
		return {}
	var codes: Array = row["codes"]
	var game_id: int = str(row["game"]).to_int()
	var code := ScreenScraper.texture_code(codes, region, _label_region_strict())
	var key := "%d:%s" % [game_id, code]
	if _ss.is_no_media(key):
		# The server's absence the run's knows: the candidate's not, the request's not asked
		# again.
		return {}
	var system_id: int = str(_ss_system.get(platform_id, 0)).to_int()
	var url := _ss.request_url(system_id, game_id, code)
	if url.is_empty():
		return {}
	return {"source": _ART_SOURCE_SCREENSCRAPER, "source_name": "ScreenScraper",
		"region": region, "url": url, "file": "label", "no_media_key": key}


## The title's keys, the index's way: itself, then with its trailing `(Region)` and `(Disc N)`
## tags off, as the reference names carry them (`Final Fantasy VII (Europe) (Disc 1)`).
func _title_keys(title: String) -> Array:
	var keys: Array = [_normalize(title)]
	var stripped := _tags_stripped(title)
	if stripped != title:
		keys.append(_normalize(stripped))
	var core := _core_title(title)
	if core != title:
		keys.append(_normalize(core))
	return keys


static func _tags_stripped(title: String) -> String:
	var t := title
	while t.ends_with(")"):
		var cut := t.rfind(" (")
		if cut < 0:
			break
		t = t.substr(0, cut)
	return t.strip_edges()


## [param title] in the reference lists' plain form: its scene-release `[tag]` groups and its
## trailing `(tag)` groups off (`Halo 3 [RF][ENG]` is `Halo 3`), so a scene file name finds the
## plain row the reference lists carry.
static func _core_title(title: String) -> String:
	var re := RegEx.new()
	re.compile("\\[[^\\[\\]]*\\]")
	var no_brackets := re.sub(title, "", true)
	return _tags_stripped(no_brackets)


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
func labelVariants(_id: int, game_id: String) -> String:
	var game := _game_by_id(game_id)
	if game.is_empty():
		return JSON.stringify({"ok": false, "code": &"game_missing",
			"detail": "the library has no such game"})
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
	return JSON.stringify({"ok": true, "variants": variants})


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
## told at once, the rest downloaded one by one, ScreenScraper's (the key's file on) then
## LaunchBox's then the serial source's,
## [signal art_changed] the progress, a found, or the absences.
func artFocus(focus: PackedStringArray) -> void:
	if DisplayServer.get_name() == "headless" or _art_http != null or _art_pacing:
		return
	_ensure_scanned()
	DirAccess.make_dir_recursive_absolute(art_dir())
	var queue: Array = []
	var absent: PackedStringArray = PackedStringArray()
	var stored_done := 0
	for id_game: String in _art_game_order(focus):
		var game := _game_by_id(id_game)
		if game.is_empty():
			continue
		var stored := _art_stored(game)
		if not stored.is_empty():
			# The label is on disk from a run before: the carousel only shows a label it is
			# told of, so a restart with a full art folder would show none without this.
			stored_done += 1
			_art_changed({"done": stored_done, "total": 0,
				"found": {"game_id": id_game, "path": stored}})
			continue
		var candidates := _art_candidates(game)
		if candidates.is_empty():
			absent.append(id_game)
		else:
			queue.append({"game_id": id_game, "candidates": candidates, "attempt": 0})
	_art_done = stored_done
	_art_total = queue.size() + stored_done
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
	if str(candidate["source"]) == _ART_SOURCE_SCREENSCRAPER:
		if _ss == null or not _ss.admit():
			# ScreenScraper is not open (its quota spent, its key refused): the candidate is not
			# asked; the carousel's next focus pass will look for it again.
			job["attempt"] = attempt + 1
			_art_jobs.push_front(job)
			_art_next()
			return
		var wait_ms := _ss.pace_wait_ms()
		if wait_ms > 0:
			# The server's pace not kept yet: the candidate holds, and the pump waits for it.
			_art_jobs.push_front(job)
			_art_pacing = true
			_ss_pace_then_pump(wait_ms)
			return
		_ss.note_request()
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


## The pace's wait, then the pump: the scene tree's timer, the queue's hold over.
func _ss_pace_then_pump(wait_ms: int) -> void:
	var loop: Variant = Engine.get_main_loop()
	if not (loop is SceneTree):
		# No scene tree (a test, a headless run): the pace is not kept, the queue holds on.
		_art_pacing = false
		_art_next()
		return
	var tree: SceneTree = loop
	var timer: SceneTreeTimer = tree.create_timer(float(wait_ms) / 1000.0)
	await timer.timeout
	_art_pacing = false
	_art_next()


func _on_art_request(result: int, response_code: int, _headers: PackedStringArray,
		body: PackedByteArray, http: Node) -> void:
	_art_http = null
	var job := _art_job
	_art_job = {}
	var game_id := str(job["game_id"])
	var candidates: Array = job["candidates"]
	var attempt: int = job["attempt"]
	var candidate: Dictionary = candidates[attempt]
	if str(candidate["source"]) == _ART_SOURCE_SCREENSCRAPER and result == HTTPRequest.RESULT_SUCCESS:
		# ScreenScraper's absent and its refusals come as 200s of text; only its image bytes
		# go to the art folder, the rest to the next candidate.
		var kind := _ss.answer(response_code, body)
		print("Cartouche plugin: screenscraper: %s (http %d)" % [kind, response_code])
		if kind == "nomedia":
			_ss.note_no_media(str(candidate.get("no_media_key", "")))
		if kind != "image":
			http.queue_free()
			job["attempt"] = attempt + 1
			_art_jobs.push_front(job)
			_art_next()
			return
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
	label_variant_downloaded.emit(JSON.stringify(payload))


func _art_changed(payload: Dictionary) -> void:
	art_changed.emit(JSON.stringify(payload))


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
	var shelves: Array = _current.get("shelves", [])
	for shelf: Dictionary in shelves:
		if str(shelf["platform_id"]) != platform_id:
			continue
		var game_indexes: Array = shelf["game_indexes"]
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
	return {"ok": true, "library": made}


## The scan's report, as the terminal reads it.
func _scan_summary() -> String:
	var dir := games_dir()
	var lines := PackedStringArray()
	var games: Array = _current.get("games", [])
	lines.append("Cartouche (Linux): scanned %s" % dir)
	if games.is_empty():
		lines.append("  no games found: put game files in %s (or --games-dir=PATH)" % dir)
		return "\n".join(lines)
	var shelves: Array = _current.get("shelves", [])
	var identified := 0
	for game: Dictionary in games:
		if game["identified"]:
			identified += 1
	lines.append("  %d games on %d consoles, %d identified" % [games.size(), shelves.size(), identified])
	var not_games: Dictionary = _current.get("not_games", {})
	var ignored_count := _not_games_count(not_games)
	var ignored: Dictionary = _current.get("ignored_counts", {})
	if not ignored.is_empty():
		for entry: Dictionary in ignored.get("*", []):
			if str(entry.get("reason", "")) == "unsupported":
				ignored_count += entry.get("count", 0)
	if ignored_count > 0:
		lines.append("  %d file(s) set aside (too small or unsupported)" % ignored_count)
	for shelf: Dictionary in shelves:
		var platform_id: String = str(shelf["platform_id"])
		lines.append("  %s (%s):" % [_platform_names.get(platform_id, platform_id), platform_id])
		var shown := 0
		var game_indexes: Array = shelf["game_indexes"]
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
	if report.get("rehearsal", true):
		lines.append("Cartouche (Linux) — rehearsal: nothing was started")
	else:
		lines.append("Cartouche (Linux) — launch: %s" % str(report.get("command", "")))
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
	var player: String = str(report.get("player", ""))
	if player.is_empty() and report.has("player"):
		lines.append("  player:    none: no installed emulator opens the file")
	elif not player.is_empty():
		lines.append("  player:    %s — %s" % [player, str(report.get("binary", ""))])
		if report.get("stop_first", false):
			lines.append("  stop_first: its lingering instances are stopped first")
	var command: String = str(report.get("command", ""))
	if command.is_empty():
		lines.append("  would run: (no launch)")
	else:
		lines.append("  would run: %s" % command)
	return "\n".join(lines)
