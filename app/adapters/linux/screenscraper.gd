# SPDX-License-Identifier: GPL-3.0-or-later
class_name ScreenScraper
extends RefCounted
##
## The labels the bundled indexes have no image of, from ScreenScraper (its `api2`): the
## per-platform tables under `res://data/screenscraper` list, by the reference lists' release
## names, each release's game and the textures the server has of it, and this class, with the
## app's developer key (a key file), asks for one image at a time. No key file, no requests:
## the source is off, and its candidates are not made.
##
## The key file, `--ss-key=PATH`, the `CARTOUCHE_SS_KEY` environment, or the config dir's
## `sskey.json`:
## `{"devid": ..., "devpassword": ..., "softname": ...}`; `ssid` and `sspassword`, when both
## are there, name the member the requests go as. The credentials go into the request at
## request time only: nothing but this file holds them.
##
## The pace the server asked of its clients (a 1.0 of theirs) is kept at a 1.2 of ours: no
## request goes sooner from the last, `pace_wait_ms` the wait, `note_request` the ask.
##
## Answers, as the server gives them: the image's bytes, or a 200 of text, `NOMEDIA` the
## game's absence of the texture and a wrong key its refusal; a 429 spends the back-off, a
## 430 or 431 the day (the quota's), a 401, 403, or 426 the key for the run.

const _TABLES := "res://data/screenscraper"
const _API := "https://api.screenscraper.fr/api2/mediaJeu.php"
const _SIZE := 1024
const _BACK_OFF_MS := 10_000
const _PACE_MS := 1200
const _NO_MEDIA := "NOMEDIA"
const _BAD_KEY := "identifiants développeur"
const _LONGEST_TEXT := 1024

const _REGION_CODES: Dictionary = {
	"North America": ["us", "ame"],
	"Europe": ["eu"],
	"Japan": ["jp"],
	"World": ["wor"],
}
const _FALLBACK_CODES: Array[String] = ["us", "eu", "jp", "wor"]

var _key_path_override := ""
var _creds: Dictionary = {}
var _creds_path := "\n"
var _tables: Dictionary = {}
var _backoff_until := 0
var _closed_day := ""
var _refused := false
var _last_request := 0
var _no_media: Dictionary = {}


## Where the key is read: `set_key_path`'s, `--ss-key=`'s, the environment's, or the config
## dir's `sskey.json`.
func key_path() -> String:
	if not _key_path_override.is_empty():
		return _key_path_override
	var env := OS.get_environment("CARTOUCHE_SS_KEY")
	if env != "":
		return env
	return DesktopPlugin.config_dir() + "/sskey.json"


func set_key_path(path: String) -> void:
	_key_path_override = path


## The credentials, read from the key file on first need; none when the file is not there,
## not a JSON object, or names no full key.
func _credentials() -> Dictionary:
	var path := key_path()
	if path != _creds_path:
		_creds_path = path
		_creds = _load_key(path)
	return _creds


func _load_key(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return {}
	var c: Dictionary = parsed
	for name: String in ["devid", "devpassword", "softname"]:
		if str(c.get(name, "")).strip_edges().is_empty():
			return {}
	return c


## Whether the key's file is a key: the source, on or off.
func enabled() -> bool:
	return not _credentials().is_empty()


## Whether a request may go: the key there, the run's refusals and the day's quota over.
func open() -> bool:
	if _refused:
		return false
	if _closed_day != "" and _closed_day >= _today():
		return false
	return enabled()


## Whether a request may go now: [open] and the 429's back-off over.
func admit() -> bool:
	return open() and Time.get_ticks_msec() >= _backoff_until


## The server's pace kept: [param _PACE_MS] from the last request the app asked, like the
## front-ends that asked the server for it (a 1.0 of theirs, a 1.2 of ours).
func pace_wait_ms() -> int:
	var gap: int = Time.get_ticks_msec() - _last_request
	return _PACE_MS - gap if _last_request != 0 and gap < _PACE_MS else 0


## The request's ask told, the pace's start.
func note_request() -> void:
	_last_request = Time.get_ticks_msec()


## The absence's note, the run's kept: the request's key the server answered `NOMEDIA`.
func note_no_media(key: String) -> void:
	_no_media[key] = true

## The absence's known: the request's not asked again in the run.
func is_no_media(key: String) -> bool:
	return _no_media.has(key)


## The texture's code of [param codes] for [param region]: the region's, then, without
## [param strict], the known codes' and then the table's first; none when strict has no own.
static func texture_code(codes: Array, region: String, strict: bool) -> String:
	var wanted: Array = _REGION_CODES.get(region, [])
	for code: String in wanted:
		if codes.has(code):
			return code
	if strict:
		return ""
	for code: String in _FALLBACK_CODES:
		if codes.has(code):
			return code
	return codes[0] if not codes.is_empty() else ""


## The request of [param game_id]'s texture [param code] on [param system_id], the key and,
## when both are named, the member in it; none when the key is not, or no texture is asked.
func request_url(system_id: int, game_id: int, code: String) -> String:
	var c := _credentials()
	if c.is_empty() or system_id <= 0 or code.is_empty():
		return ""
	var params: Array = [
		"devid=" + str(c["devid"]).uri_encode(),
		"devpassword=" + str(c["devpassword"]).uri_encode(),
		"softname=" + str(c["softname"]).uri_encode(),
	]
	var ssid := str(c.get("ssid", "")).strip_edges()
	var sspassword := str(c.get("sspassword", "")).strip_edges()
	if ssid != "" and sspassword != "":
		params.append("ssid=" + ssid.uri_encode())
		params.append("sspassword=" + sspassword.uri_encode())
	params.append("systemeid=" + str(system_id))
	params.append("jeuid=" + str(game_id))
	params.append("media=support-texture(" + code + ")")
	params.append("maxwidth=" + str(_SIZE))
	params.append("maxheight=" + str(_SIZE))
	return _API + "?" + "&".join(params)


## The table's row of [param platform_id] under one of [param keys] (the reference names',
## normalized): its `{game, codes}`; none for a release the table lacks.
func lookup(platform_id: String, keys: Array) -> Dictionary:
	var table := _table(platform_id)
	for key: String in keys:
		if table.has(key):
			return table[key]
	return {}


## A release's table keys: its name, its name without its trailing tags, and its core, each
## normalized, as the keys the lookups come in.
static func row_keys(name: String) -> Array:
	var keys: Array = []
	var names: Array = [name, LinuxPlugin._tags_stripped(name), LinuxPlugin._core_title(name)]
	for raw: String in names:
		var key: String = LinuxPlugin._normalize(raw)
		if not key.is_empty() and not keys.has(key):
			keys.append(key)
	return keys


func _table(platform_id: String) -> Dictionary:
	if _tables.has(platform_id):
		return _tables[platform_id]
	var found: Dictionary = {}
	var text_path := _TABLES.path_join(platform_id + ".tsv")
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
			var game_id: int = parts[1].to_int()
			var codes: Array = []
			for c: String in parts[2].split(" "):
				var trimmed: String = c.strip_edges()
				if not trimmed.is_empty():
					codes.append(trimmed)
			if game_id <= 0 or codes.is_empty():
				continue
			var row := {"game": game_id, "codes": codes}
			for key: String in row_keys(parts[0]):
				if not found.has(key):
					found[key] = row
	_tables[platform_id] = found
	return found


## The answer's kind, the state's kept: `image` the image's bytes, `nomedia` the absence,
## `refused` the key's (and the run's off), `throttled` the 429's, `closed` the quota's day,
## `status` another code, `unreadable` a 200 that is none of these.
func answer(response_code: int, body: PackedByteArray) -> String:
	var now := Time.get_ticks_msec()
	match response_code:
		429:
			_backoff_until = now + _BACK_OFF_MS
			return "throttled"
		430, 431:
			_closed_day = _today()
			return "closed"
		401, 403, 426:
			_refused = true
			return "refused"
	if response_code != 200:
		return "status"
	if _is_image(body):
		return "image"
	if body.size() <= _LONGEST_TEXT:
		var text: String = body.get_string_from_utf8()
		if text.strip_edges() == _NO_MEDIA:
			return "nomedia"
		if _BAD_KEY in text:
			_refused = true
			return "refused"
	return "unreadable"


static func _is_image(body: PackedByteArray) -> bool:
	if body.size() >= 4 and body[0] == 0x89 and body[1] == 0x50 and body[2] == 0x4E and body[3] == 0x47:
		return true
	return body.size() >= 3 and body[0] == 0xFF and body[1] == 0xD8 and body[2] == 0xFF


static func _today() -> String:
	var d := Time.get_datetime_dict_from_system()
	var y: int = d["year"]
	var m: int = d["month"]
	var day: int = d["day"]
	return "%04d-%02d-%02d" % [y, m, day]


## The tests': the key's, the tables', and the run's state, gone.
func reset() -> void:
	_key_path_override = ""
	_creds = {}
	_creds_path = "\n"
	_tables.clear()
	_no_media.clear()
	_backoff_until = 0
	_closed_day = ""
	_refused = false
	_last_request = 0
