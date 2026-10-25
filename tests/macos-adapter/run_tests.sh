#!/bin/bash
#
# macOS AArch64 process-control adapter tests.
#
# Builds the C debuggee with clang and the test driver with fpc, then runs
# the driver against the debuggee.  Needs no Pascal compiler for the
# debuggee and no OPDF, so it isolates TMacOSMachAdapter from the rest of
# the toolchain.
#
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
OUT="$SCRIPT_DIR/target"

if [ "$(uname -s)-$(uname -m)" != "Darwin-arm64" ]; then
    echo "SKIPPED: macOS arm64 only"
    exit 0
fi

mkdir -p "$OUT/units"
clang -O0 -o "$OUT/target" "$SCRIPT_DIR/target.c"
# task_for_pid needs the debuggee's consent, as Blaise --debug-opdf gives it
codesign -s - -f --entitlements "$SCRIPT_DIR/get-task-allow.plist" "$OUT/target" 2>/dev/null
fpc -Mobjfpc -Sh -FU"$OUT/units" \
    -Fu"$PROJECT_ROOT/opdf-lib/src/main/pascal" \
    -Fu"$PROJECT_ROOT/pdr-core/src/main/pascal" \
    -Fu"$PROJECT_ROOT/pdr-adapters/src/main/pascal" \
    -o"$OUT/test_macos_adapter" "$SCRIPT_DIR/test_macos_adapter.pas" > "$OUT/compile.log" 2>&1 \
    || { cat "$OUT/compile.log"; exit 1; }

"$OUT/test_macos_adapter" "$OUT/target"
