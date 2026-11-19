#!/usr/bin/env bash
# The test suite, one godot process per test file.
#
# One process per file keeps every suite in the state its tests are written
# for: the ahead model's let-go stands THREAD_LOAD_INVALID_RESOURCE only for
# a scene the process has not threaded before, and a suite that loaded the
# media ahead in the same process leaves it COMPLETE. The engine runs with
# --fixed-fps 60: the screens' waits are written for sixteen millisecond
# frames, and a paced machine (this one runs at twenty-eight) makes a two
# frame wait longer than the form's sixty millisecond entry.
#
# Run all the files:
#   app/dev/run_tests.sh
# or a few:
#   app/dev/run_tests.sh test/screens/add_more_test.gd test/adapters/android_services_test.gd
#
# GODOT names the engine (default: the godot on the path, then /opt/data/bin/godot).
set -u
APP=$(cd "$(dirname "$0")/.." && pwd)
GODOT="${GODOT:-$(command -v godot || echo /opt/data/bin/godot)}"
OUT="$APP/.test-run"
rm -rf "$OUT"; mkdir -p "$OUT"
cd "$APP"

files=()
if [ $# -gt 0 ]; then
  for arg in "$@"; do
    files+=("$arg")
  done
else
  while IFS= read -r f; do
    files+=("$f")
  done < <(find test -name '*_test.gd' | sort)
fi

total=${#files[@]}
fails=0
i=0
: > "$OUT/summary.txt"
for f in "${files[@]}"; do
  i=$((i+1))
  name=$(echo "$f" | sed 's|[./]|_|g')
  log="$OUT/$name.log"
  timeout 600 "$GODOT" --headless --fixed-fps 60 \
    -s addons/gdUnit4/bin/GdUnitCmdTool.gd -a "res://$f" -c --ignoreHeadlessMode \
    > "$log" 2>&1
  rc=$?
  sum=$(sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -a 'Overall Summary' | tail -1)
  if [ $rc -eq 0 ]; then
    echo "[$i/$total] PASS  $f  $sum" | tee -a "$OUT/summary.txt"
  else
    echo "[$i/$total] FAIL(rc=$rc)  $f  $sum" | tee -a "$OUT/summary.txt"
    sed 's/\x1b\[[0-9;]*m//g' "$log" | grep -a ' FAILED ' | sed 's/^/    /' | head -8 | tee -a "$OUT/summary.txt"
    fails=$((fails+1))
  fi
done

echo "============================================" >> "$OUT/summary.txt"
if [ $fails -eq 0 ]; then
  echo "ALL FILES GREEN" >> "$OUT/summary.txt"
else
  echo "$fails file(s) failed" >> "$OUT/summary.txt"
fi
tail -40 "$OUT/summary.txt"
[ $fails -eq 0 ]
