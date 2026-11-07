# Cartouche → x86 Linux port — STATUS: DONE (all verified)

Goal: functional Linux port of [cartouche](https://github.com/Hakimba/cartouche) (Godot 4.7.2):
scan a user-specified directory for ROMs/disc images, parse them, identify against the bundled
reference lists, and instead of launching emulators **print a report to the terminal and show a
dialog** in the Godot UI. No ScreenScraper. Must produce a **buildable/exportable** project.

Working dir: `/opt/data/cartouche-linux/` (modified copy of the repo). Godot binary:
`/opt/data/bin/godot` (4.7.2-stable x86_64).

## Final state (everything green)

- `app/adapters/linux/linux_plugin.gd` — the complete faithful parse layer (single file,
  ~1360 lines): CRC32 table, iNES/copier-header cartridge prints, zip central-directory CRC
  (+ zip-member-extension platform resolution), MAME v5 CHD huffman decode (stored hunks),
  ISO9660 PVD → root directory → `SYSTEM.CNF` `BOOT2` serial, alnum-key serial matching,
  recursive directory walk (DirAccess is top-level-only statics in 4.7.2), per-platform and
  whole-scan reports, rehearsal launch (`linux_printed`, nothing spawned), `launch_reported`
  signal → dialog. Compiles clean under the project's strict GDScript mode.
- `app/test/linux/linux_smoke.tscn` + `.gd` — headless smoke test, **33/33 checks pass**
  (5 games identified, prints/serials verified against the bundled reference lists, both
  negative fixtures, 5 rehearsal reports with correct CRCs/serials/CHD fields).
- `make_fixtures.py` (repo root) — generates the verified fixtures in `roms/`:
  Tetris (USA).nes → print `1394F57E` (in data/prints/nes.tsv),
  Super Mario World (USA).sfc (512-byte copier header) → `B19ED489` (snes.tsv),
  Super Mario Bros. (World).zip → `393A432F` (nes.tsv, the CRC the archive records),
  Final Fantasy X (Japan).chd (MAME v5, 16 stored 1 MiB hunks) → serial `SLPM_661.24`
  (matches `Final Fantasy X (Japan)` in data/titles/ps2.tsv),
  Final Fantasy VII (Europe) (Disc 1).iso → `SCES_008.67` (matches psx.tsv),
  too_small.nes (not_a_game) and readme.txt (unsupported).
- Exports in `build/` (preset "Linux" in `app/export_presets.cfg`):
  - `cartouche-linux.x86_64` + `.pck` — **release** (73.5 MB), verified headless: boots,
    scans, prints the report.
  - `cartouche-linux-debug.x86_64` + `.pck` — debug, verified headless: boots, scans, the UI
    carousel then shows "5 games on 4 shelves".
- Dev app (`godot --headless --path app`) boots headless with no errors; a missing games
  folder is skipped silently (the demo library stands in).

## How to run

```sh
cd /opt/data/cartouche-linux/app
# smoke test (headless; -- before user args):
/opt/data/bin/godot --headless --path . res://test/linux/linux_smoke.tscn \
  -- --games-dir=/opt/data/cartouche-linux/roms
# the app itself (any display; --headless also works):
/opt/data/bin/godot --headless --path . -- --games-dir=/opt/data/cartouche-linux/roms
# regenerate fixtures:
python3 /opt/data/cartouche-linux/make_fixtures.py
# exports:
/opt/data/bin/godot --headless --path . --export-release Linux /opt/data/cartouche-linux/build/cartouche-linux.x86_64
/opt/data/bin/godot --headless --path . --export-debug   Linux /opt/data/cartouche-linux/build/cartouche-linux-debug.x86_64
# exported binaries (user args after --; cwd must not matter, use an absolute dir):
/opt/data/cartouche-linux/build/cartouche-linux.x86_64 -- --games-dir=/opt/data/cartouche-linux/roms
```

Games dir, in order: `--games-dir=PATH` (after `--`) → `CARTOUCHE_GAMES_DIR` env → `roms/`.

## Godot 4.7.2 API facts (verified against the binary — several 4.x habits do not exist)

- **`//` is not a GDScript operator.** Int/int `/` under this project's
  `gdscript/warnings/integer_division=2` is an **error**; the legal form is
  `int(float(a) / b)`. (`int(a / b)`, `floori(a / b)` also trip it.)
- `String(PackedByteArray)` constructor does not exist; `PackedByteArray.get_string_from_utf8()`
  and `get_string_from_ascii()` take **no arguments** (whole buffer). Sub-ranges:
  `data.slice(from, to).get_string_from_ascii()` (slice is `[from, to)`).
- `RegEx.global_regex_search()` → `search_all()`; `RegExMatch.start(n)` → `get_start()`.
- `DirAccess`: no `list_dir()`/`get_next()`/`FILE_TYPE_*`/`DirAccess.dir_exists(path)` statics.
  Statics: `get_files_at(dir)`, `get_directories_at(dir)`, `open(dir)` + instance `dir_exists` /
  `file_exists`. Quiet "does this folder exist" (no C++ ERROR spam):
  `DirAccess.open(".").dir_exists(dir)` — relative paths resolve as the scan's do.
- `OS.get_cwd()` is gone.
- **Autoload identifiers (`Diagnostics`, …) are NOT resolvable in a `-s` main-script context**
  (and `-s` does not even host the autoloads). Test harnesses must be **scenes**
  (`.tscn` + `extends Node` + `_ready`): scene scripts compile after the autoloads exist, and
  the `Diagnostics` identifier in `desktop_plugin.gd` then resolves. This was the root cause
  of the "Nonexistent function 'demo' in base 'GDScript'" cascade: a failed base-class compile
  demotes `LinuxPlugin`'s base to `GDScript`.
- A function without return type is a parse error here (`_initial_plugin() -> Object` fix in
  `adapters/android/android_services.gd`).
- Export templates must sit at `~/.local/share/godot/export_templates/4.7.2.stable/`
  (**dot**, not dash) as `linux_debug.x86_64` / `linux_release.x86_64`; the official
  templates zip extracts into a `templates/` subdir. (Symlinked from the 4.7.2-stable download.)
- Exported games **chdir to the executable's directory** at start, so a bare `roms/` resolves
  beside the binary; pass `--games-dir` (absolute). User args need the `--` separator. Release
  builds block-buffer stdout to files (fine on a TTY); `--quit-after N` for bounded headless
  runs. `Diagnostics` traces are gated on `OS.is_debug_build()` (silent in release by design);
  the plugin's own `print`s (scan summary, rehearsal report) are unconditional.

## Artwork (implemented, verified in the webtop container)

- `linux_plugin.gd` — the art pipeline: `artFocus` (the carousel's on-screen games first)
  downloads one candidate at a time and stores each label in the art folder
  (`--art-dir` → `CARTOUCHE_ART_DIR` → `user://art`) **with the image's own extension**
  (`Image.load_from_file` refuses unknown extensions; same bytes load as `.png`, not `.img`).
  Candidates per game, in priority order: LaunchBox (the index ships in `res://data/art/<id>.tsv`,
  images at `images.launchbox-app.com`, region preferred, name + alternates), then, where
  `profiles.json` gives `scansBySerial` (PS2), psxdatacenter by the first serial
  (`SLPM_661.24` → `SLPM-66124`). `art_changed` carries found/absent/stall;
  `labelVariants` answers the sources per game; headless stays art-less.
- Godot 4.7.2: `HTTPRequest` is a **Node** (it must live in the tree — the `Android` autoload
  owns it), `RESULT_SUCCESS` (no `RESULT_OK`), `request_completed` still `(result, code,
  headers, body)`.
- `AndroidServices.is_available()` now treats the Linux plugin as the bridge it stands in for
  (the carousel's art signals connect; `_demo` falls off).
- Verified end-to-end in webtop (`/ROMs` mounted, internet works): fixture run 4/5 labels
  downloaded (FFX JP's LaunchBox disc label scan **rendered on the disc face** in the UI —
  confirmed by screenshot; FF7 correctly absent, no image in the index for that name);
  an earlier `/ROMs` run downloaded 4 real-library covers.

## Outstanding (in queue order)

1. **Folder-matching**: the classifier keys on extension+size, so `/ROMs/bios/ps2/*.bin`
   misreads as N64. Fix: the top-level folder under the games dir is the platform;
   extension+size only for root-level files. Add `ps3`/`dreamcast` to `_EXTENSIONS`/
   `profiles.json`/catalog and `rvz` (GC/Wii discs) where the library has them.
2. **Launch configuration**: `cartouche.conf`, a 1:1 mirror of the Android `playerList`
   (per-platform players: `command` template with `{file.path}`, `accept` pattern,
   optional `stop_first`; global `rehearsal = true`; availability = `command -v` in the
   image; first matching player wins). No `where`/docker axis: one container, cartouche +
   emulators + display server.
3. **Compressed CHD serials**: `cdlz` (zlib) hunks decode to nothing (no Zlib in Godot 4.7.2);
   stored hunks only. Identification then falls to serial/name for those discs.
4. **Full `/ROMs` scan**: 410 GB, ~744 zips (730 in `amiibo/`) — headless scan of the
   ps2+psx subset (~2 GB) took a few minutes; the whole tree needs `amiibo/` excluded or a
   long patience.

## Design notes

- Matching, per game, in order: cartridge **print CRC32** (iNES 16-byte / 512-byte copier
  header skipped; zip = the CRC its central directory records) → disc **serial** (alnum key,
  case/separator-insensitive: `SLES_524.95` ≡ `SLES-52495`) → **name** (normalized title in
  `data/titles/<id>.tsv`).
- Platform = first platform in `_ORDER` (discs first) that lists the file's extension
  (`data/platforms/daijishou/`) and whose `minimumGameBytes` (`profiles.json`) the file
  reaches; below every candidate's minimum → `not_games`; no candidate → `unsupported`.
  `.zip` resolves to the member ROM's extension (local file header), not "zip".
- CHD: MAME v5 ("MComprHD"), huffman length RLE + canonical 16-symbol tree, kind codes
  (0..3 codec, 4 stored, 5/9/10 self, 6 parent); compressed hunks decode to nothing
  (no codecs) — stored hunks carry the data; the ISO 9660 PVD at sector 16 → root dir record
  at PVD[156] → `SYSTEM.CNF` → `BOOT2 = cdromN:\SERIAL;1`.
- The CHD/ISO sector read returns `PackedByteArray()` (empty) for compressed/missing hunks;
  `_iso9660_boot_serial` tolerates that and yields no serial.
- The rehearsal: `launchGame` returns `{"ok": true, "code": "linux_printed", ...}`, prints
  `Cartouche (Linux) — rehearsal: nothing was started` + the report, emits `launch_reported`
  (the dialog). No process is spawned anywhere.
