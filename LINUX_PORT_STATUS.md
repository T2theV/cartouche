# Cartouche → x86 Linux port — STATUS (checkpoint)

Goal: functional Linux port of [cartouche](https://github.com/Hakimba/cartouche) (Godot 4.7.2):
scan a user-specified directory for ROMs/disc images, parse them, identify against the bundled
reference lists, and instead of launching emulators **print a report to the terminal and show a
dialog**. No ScreenScraper. Must produce a **buildable/exportable** project.

Working dir: `/opt/data/cartouche-linux/` (modified copy of the repo; git repo — latest commit
`70ac773` is the checkpoint). Godot binary: `/opt/data/bin/godot` (4.7.2-stable x86_64).
Export templates installed at `~/.local/share/godot/export_templates/4.7.2-stable/`.
Original read-only reference clone: `/opt/data/cache/scratch/cartouche-src/`.

## Current state

- `git import` (headless) PASSES (no parse errors in repo files).
- **BLOCKED:** `app/adapters/linux/linux_plugin.gd` (833 lines) and `app/test/linux/linux_smoke.gd`
  fail to parse under the project's strict GDScript mode. `project.godot` treats as **errors**:
  untyped declarations, unsafe Variant accesses (method call / index / `in` / `==` on a Variant),
  passing a Variant where a typed value is expected, `int(...)`/`bool(...)` constructors on Variants.
- Repo-own code pattern to follow: **assign Variant results into pre-declared typed variables
  first** (e.g. `var ok: bool = payload.get("ok", false)`), then use the typed value. Untyped
  `Array`/`Dictionary` locals are fine; the moment you *call a method* or *pass/index* a Variant,
  it is an error. `var x: Variant` explicit is allowed (repo does `var parsed: Variant = ...`).
  Typed `for x: T in variant_array:` is allowed (repo pattern).

### Known parse errors in linux_plugin.gd (last run, line numbers may shift)
- 516 `_report(platform_id: String)` — parent `DesktopPlugin._report()` takes no args → rename to
  `_scan_report(platform_id)`.
- 329 `String(PackedByteArray)` — no such constructor in 4.7.2 → use
  `FileAccess.get_file_as_string(path)` (repo pattern) or `bytes.get_string_from_utf8()`.
- 406-410 `_reports[platform_id]` written **outside** the platform loop (also a logic bug) → move
  inside the loop with typed locals.
- 431 `DirAccess.FILE_TYPE_DIR` — **removed in Godot 4.7.2** (no FILE_TYPE_* constants at all).
  Use static `DirAccess.file_exists(full_path)` / `DirAccess.dir_exists(full_path)` instead.
- 648/665 `PackedByteArray.get_string()` — removed; use `get_string_from_utf8()` /
  `get_string_from_ascii()` (repo uses these in `dev/bridge`).
- `_game_by_id` has no return type → give `-> Dictionary`, return `{}` (not null) when missing;
  caller checks `.is_empty()`.
- ~15 more: `int(x.get(...))` constructors, `.size()`/`.is_empty()`/`.to_lower()`/`in` on Variants,
  `.append()` on `dict[key]` Variants (read `var arr: Array = d["k"]` first), `for key in dict`
  loops where the loop var is used after the loop.

### Known API facts (Godot 4.7.2, verified in binary)
- `PackedByteArray`: `get_string_from_utf8/utf16/utf32/ascii/multibyte_char/wchar` exist; plain
  `get_string()` does NOT.
- `DirAccess`: `FILE_TYPE_*` constants gone; static `file_exists`, `dir_exists` exist.
- `String(PackedByteArray)` constructor does NOT exist.
- GDScript `Zlib` class (de)compresses — usable for raw-deflate (`Zlib.decompress_raw`).
- `String` has `norm_nfd()` (NFKD unaccent path for TitleKey).

## Decisions

- Extend `DesktopPlugin` (the documented desktop stand-in); keep the Godot side as UI only.
- `_initial_plugin()` static factory in `android_services.gd`: `OS.get_name() == "Linux"` →
  `LinuxPlugin.new()`, else `DesktopPlugin.new()`. (Don't touch `project.godot` autoloads.)
- Linux `launchGame()` prints a rehearsal report and returns `code = "linux_printed"`;
  `carousel.gd::_on_game_launch_failed` silently passes on `rehearsed`/`too_late`/`linux_printed`.
- Games dir: `--games-dir=PATH` cmdline arg → `CARTOUCHE_GAMES_DIR` env → `roms/` next to cwd.
- **Faithful-format port (agreed direction, not yet implemented):** parse the project's *real*
  file formats (below) instead of the earlier simplified dialect the current fixtures use.

## THE DOMAIN SPEC (decoded from `kotlin/core/.../files` + `library` — ground truth)

### Platforms & readers (`FileReading.kt`)
Readers exist ONLY for: ps2, psx (chd/iso/bin), gc, wii (iso/gcm/rvz/wia), nes (nes/zip),
snes (sfc,smc/zip), n64 (z64,v64,n64/zip), gb (gb/zip), gbc (gbc,gb/zip), gba (gba/zip).
Platform for a file = daijishou extension candidates (see below); try candidate platforms in
catalog order; first whose reader yields facts + whose TitleIndex matches wins.

### Cartridge prints (`Cartridges.kt::cartridgePrint`)
- `head` = first 16 bytes. Skip: NES: 16 if head BE32 == 0x4E45531A ("iNES") else 0. SNES: 512
  if `size % 1024 == 512` else 0. N64/GB/GBA: 0.
- N64 reorder: if head BE32 == 0x37804012 → byte-swap; == 0x40123780 → word-swap. Swap:
  `other = at xor mask` (mask 1 or 3); swap when `other > at and (at or mask) < size`.
- Print = CRC32 (zlib) of bytes[skip..end], 8 upper-case hex. GB shell = byte 0x143: 0xC0 →
  exclusive, 0x80 → compatible, else unknown (label only).
- zip (`zipEntryPrint`): single-entry zip. Tail = last min(size, 22+65535) bytes; find END record
  sig 0x504B0506; `end+10..12` LE16 entry count must be 1; entry = 46 bytes at `end+16..20` LE32
  offset; sig 0x504B0102; **print = LE32 at entry+16** (the CRC the archive *records* — trusted).

### PlayStation disc serial (`Iso9660.kt::bootSerial`)
- `volume` = sector 16 (2048). Must have bytes 1..5 == "CD001".
- Root record at volume[156]: `sector` = LE32 at [158..162], `size` = LE32 at [166..170].
- Directory: walk from 0; `length = dir[at]`; length 0 → jump to `(at/2048+1)*2048` (end of
  sector); record: `nameLength = dir[at+32]`, name = `dir[at+33 .. at+33+nameLength]` with part
  before ';' uppercased; record extent: `sector` LE32 at at+2, `size` LE32 at at+10.
- Find "SYSTEM.CNF"; read `size` bytes from its `sector` (2048-byte sectors, last cut to size).
- Regex (case-insensitive) on that text: `BOOT2?\s*=\s*cdrom0?:\\?\\?([A-Z]{4}[_-]\d{3}\.\d{2})`
  → group 1 = serial as the disc writes it (e.g. `SLES_524.95`).
- Raw ISO: sector n = `data[n*2048 .. +2048]`. `.bin`: raw 2352-byte sectors; sector data =
  `raw[at]` with header skip: `raw[at+15]==1 → 16 else 24`.

### MAME v5 CHD (`ChdImage.kt`) — magic "MComprHD", NOT the old dialect
Header (124 bytes): [0..7] "MComprHD"; [12..15] BE version must be 5; [16..31] four 4-byte codec
tags ("cdlz"/"cdzl"/"lzma"/"zlib"/else OTHER; 0 if unused); [32..39] BE64 image size;
[40..47] BE64 hunk-map offset; [48..55] BE64 metadata offset (0 → DVD layout); [56..59] BE32
hunk size (1..1MB).
Map at map-offset: [0..3] BE32 = size of bits region; [4..10] BE48 = **absolute** file offset of
first hunk data; [10..12] = 0,0; [12] = lengthBits; [13] = selfBits; [14] = parentBits; [15] = 0.
Bits region = Huffman tree, then per-hunk kind codes, then per-hunk entries.
- Huffman: 16 symbols, codes ≤ 8 bits. Tree RLE: read 4-bit `length`; if ≠ 1 → literal; else
  `repeated = read(4)`: if repeated == 1 → count = 1, else count = read(4)+3; repeat length
  `repeated` `count` times. Canonical build: `starts[33]` counts by length; `for length in
  32 downTo 1: next = (start + starts[length]) shr 1; starts[length] = start; start = next`;
  then `symbols[(1 << length) or starts[length]++] = symbol` for length 1..8 (table of 256, -1).
  Decode: `code = 1; repeat 8: code = (code shl 1) or bit; if symbols[code] >= 0 → symbol`.
- Kinds (RLE): codes 7 (RLE_SMALL), 8 (RLE_LARGE): `kinds[hunk] = last`; then `count = decode`;
  repeat = 2 + (count if SMALL else 16 + (count shl 4) + decode); else kind = code, last = code.
  Kind meaning: 0..3 = codec index (compressed), 4 = NONE (stored), 5 = SELF, 6 = PARENT,
  9 = SELF_0, 10 = SELF_1.
- Entry walk for hunk n (bit reader over bits region from tree end): CODEC: `length = read(lengthBits)`,
  read 16-bit crc, `offset += length`; NONE: read 16-bit crc, `offset += hunkBytes`;
  SELF: `lastSelf = read(selfBits)`; SELF_1: `lastSelf++` (SELF_0: nothing); PARENT: read(parentBits).
  Result for n: kind 0..3 → Compressed(kind, start, length); 4 → Stored(start); 5/9/10 →
  Self(lastSelf); 6 → unsupported.
- Sector read: `perHunk = hunkBytes / stride`; `sector(n) = layout.data(hunk(n/perHunk),
  (n % perHunk) * stride)`; data = `units[at + headerLen .. at + headerLen + 2048]`; headerLen:
  DVD/COOKED → 0, MODE2 → 8, RAW → units[at+15]==1 ? 16 : 24.
- Layout from metadata walk (offset at header 48): follow entries: [0..3] tag, [5..7] 3-byte
  length, [8..15] BE64 next-entry offset, text at +16; if tag "CHT2"/"CHTR" → track type from
  text regex `TYPE:(\S+)` → `_RAW` → RAW (stride 2448), "MODE2"/"MODE2_FORM_MIX" → MODE2, else
  COOKED (stride 2448); no track (offset 0) → DVD (stride 2048). Max 32 entries.
- Decoders to implement: stored (kind 4, tag 0) and zlib (`Zlib.decompress_raw`); cdzl/cdlz/lzma
  = not implemented (return none) — document.
- **Assembly recipe** (from repo testFixtures Generators.kt): file = 124-byte header + 16-byte
  map head + bits region + hunk data at `firstHunk = 124 + 16 + body.size`; metadata at
  firstHunk+hunkBytes if present else header[48]=0 (DVD). Test-map example: tree = 16 literals of
  length 4 (bits `[0][4]`×16), kind codes 4-bit each, entries 16-bit crc each; mapHead =
  BE32(body.size) + BE48(firstHunk) + [0,0,31,16,16,0].

### GC/Wii (`discGameCode` / `compressedGameCode`)
- `.iso`/`.gcm`: 6 chars at offset 0, must match `[A-Z0-9]{6}` (e.g. `GKYP01`); serial = first 4.
- `.rvz`/`.wia`: magic `RVZ\1`/`WIA\1` at 0; code at 0x58.

### Identification (`TitleIndex.kt`, `GameName.kt`, `Game.kt`)
- Per-platform `TitleIndex`: titles from `data/titles/<id>.tsv` (`name<TAB>serials`, comma-sep),
  prints from `data/prints/<id>.tsv` (`name<TAB>CRC32hex`, line valid only if name is in titles).
- Indices: byText (exact title text), byTitle (filing key), byMainTitle, bySerial
  (key = alnum-uppercase of serial), byDiscId (TSV serial `^(DL-DOL|RVL)-([^-]+)` → key of group),
  byPrint (crc32 UInt).
- `identifyByName(text)`: exact byText → Disc; else `judge()` (full GameName matching).
- `identifyByContent(facts, file)`: Serial → bySerial[key] else byDiscId[key.take(4)]; Print →
  byPrint[crc]. Then prefer candidates whose written name == file's, then region; exactly one →
  Disc; else Release if all share displayTitle, with shared serials; none if empty.
- `judge(file)`: sameTitle = byTitle[key] else (byMainTitle[key] if one title); filter `canBe`
  (same otherTags set lowercased; region overlap or file none; languages ok; versions
  containsAll either way; disc equal if file names one); prefer with-versions, then
  with-languages; exact = same regions+languages+versions+disc; exactly one exact → Disc; else
  Release with shared serials (empty → not identified).
- `Game.identified = redumpName.isSome() || serials.isNotEmpty()`; redumpName = exact reference
  disc text (Disc identifications). TitleKey: NFKD-unaccent (ASCII fast path), lowercase,
  non-alnum → single space, trim. GameName tags: `\s*[(\[((?:[^()\[\]]|\([^()]*\))*)[)\]]`;
  regions map (Asia..World + eu/eur/us/jp/jpn); languages tag `[A-Z][a-z](?:-[A-Z][a-z]+)?...`;
  version `(?i)v\s?\d[\w.]*|rev\s+[\w.]+`; disc `(?i)(?:disc|disk|cd)\s*(\d+)...`; article
  inversion `^(.*), (The|A|An)$`; displayTitle splits on " - ".

### Extension → platform map (from `data/platforms/daijishou/*.json`)
Parse each platform JSON: `platform.shortname` = platform id; each `playerList[].acceptedFilenameRegex`
has the extensions in `\(\?:([a-z0-9|]*)\)`. Extract per platform, union → extension → platforms[].
Verified examples: `nes`→[nes], `sfc`→[snes], `chd`→10 consoles incl ps2/psx, `iso`→10 incl
ps2/psx, `bin`→16, `txt`→none (→ unsupported). Ambiguous extensions are resolved by trying
candidate platforms' readers + TitleIndex (content), so e.g. a PS2 CHD resolves to ps2.

## Fixture plan (v2, NOT yet generated — current roms/ are old dialect)
Deterministic, all content-based identifications:
- `Final Fantasy X (Japan).chd`: MAME v5, 1 stored hunk (hunkBytes = image size ≤ 1MB), DVD
  layout (metadata offset 0), image = ISO9660 disc (CD001 PVD @ sector 16, root record @156 →
  root dir sector, SYSTEM.CNF with `BOOT2 = cdrom0:\SLPM_661.24;1`) → key SLPM66124 → matches
  `Final Fantasy X (Japan)` (SLPM-66124,SLPS-25050,SLPS-72501) in titles/ps2.tsv.
- `Final Fantasy VII (Europe) (Disc 1).iso`: ISO9660, `BOOT = cdrom:\SCES_008.67;1` → SCES00867 →
  `Final Fantasy VII (Europe) (Disc 1)` (SCES-00867) in titles/psx.tsv.
- A `.zip` NES fixture: single-entry zip, central-directory CRC set to a real print from
  data/prints/nes.tsv (e.g. `1394F57E` for `Tetris (USA)` or `Super Mario Bros. (USA)`'s) →
  identified by content (the zip records the CRC; data can be small).
- `Tetris (USA).nes` (iNES 16382B synthetic) + `Super Mario World (USA).sfc` (69632B synthetic):
  content CRCs are NOT in the prints lists → identified by exact name (`judge`/byText) → still
  identified (redumpName via name match), report should say "by name".
- `too_small.nes` (100B) → ignored not_a_game (profiles.json minimumGameBytes);
  `readme.txt` → ignored unsupported.
- Expected: 4 shelves (nes, snes, ps2, psx), 5 games.

## Resume steps
1. `cd /opt/data/cartouche-linux` — repo is clean at `70ac773`.
2. Write `app/adapters/linux/game_name.gd` (GameName port), `file_reading.gd` (FileReading port:
   crc32, cartridge, zip, ISO9660, MAME v5 CHD, game codes), `title_index.gd` (TitleIndex port).
   Strict-mode rules above. GDScript `Zlib.decompress_raw` for zlib hunks; `norm_nfd()` for
   TitleKey unaccent; RegEx without flags param (use inline `(?i)`).
3. Rewrite `linux_plugin.gd`: load daijishou extension map + per-platform TitleIndex; scan
   `roms/` (or `--games-dir`); per file: candidates → readers → facts → identify_by_content →
   else identify_by_name; build Game dicts (redumpName/serials/identified/shell), group discs by
   base name (disc number from GameName.disc), shelves with groups/keys; `launchGame` rehearsal
   prints report (file, size, crc32/serial/chd details, ref name+code, "linux_printed").
   `res://` data paths: `res://data/platforms/profiles.json`, `res://data/platforms/daijishou/`,
   `res://data/titles/*.tsv`, `res://data/prints/*.tsv`.
4. Rewrite `make_fixtures.py` (ISO9660 builder + MAME v5 CHD writer + zip writer per plan above).
5. Update `app/test/linux/linux_smoke.gd`: 4 shelves / 5 games; content identifications for
   chd/iso/zip (serials + redump names); name-based for nes/sfc fixtures; ignored counts.
6. Run: `/opt/data/bin/godot --headless --path /opt/data/cartouche-linux/app --import` then
   `-s res://test/linux/linux_smoke.gd -- --games-dir=/opt/data/cartouche-linux/roms`
   (script extends SceneTree; quits with failure count). Iterate until 0 failures.
7. Export: `--headless --export ... Linux ../build/cartouche-linux.x86_64` using
   `export_presets.cfg` preset "Linux" (path already set to `../build/cartouche-linux.x86_64`).
   Verify the binary runs: at minimum it must start, print the scan report before UI, and
   rehearsal must not need a display. (No X server in this environment; `--headless` only.)
8. Commit each green step.

## Environment
- No sudo, no Xvfb, no `xxd` (use `od`/python), no `docker-compose` CLI (use `docker compose`).
- Terminal cwd persists between calls (watch stale `cd`s).
