#!/bin/bash
#
# pdr-dap end-to-end tests: build Blaise programs with OPDF debug
# information and drive pdr-dap over the Debug Adapter Protocol.
#
#   BLAISE=<blaise> tests/dap-integration/run_tests.sh
#
# Needs python3 (the DAP client) and a built pdr-dap (pasbuild compile).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BLAISE_ROOT="${BLAISE_ROOT:-/nas/data/devel/new-pascal-compiler}"
BLAISE="${BLAISE:-$BLAISE_ROOT/compiler/target/blaise}"
STDLIB_UNITS="$BLAISE_ROOT/stdlib/src/main/pascal"
ADAPTER="$PROJECT_ROOT/pdr-dap/target/pdr-dap"
SOURCE="$PROJECT_ROOT/tests/integration-blaise/test_11_callstack.pas"
WORK="$SCRIPT_DIR/target"

[ -x "$ADAPTER" ] || { echo "pdr-dap not built: $ADAPTER"; exit 1; }
[ -x "$BLAISE" ] || { echo "Blaise compiler not found: $BLAISE"; exit 1; }
mkdir -p "$WORK"
"$BLAISE" --source "$SOURCE" --output "$WORK/test_11_callstack" \
    --backend native --debug-opdf --unit-path "$STDLIB_UNITS" > "$WORK/compile.log" 2>&1 \
    || { cat "$WORK/compile.log"; exit 1; }
python3 -I "$SCRIPT_DIR/dap_session_test.py" "$ADAPTER" "$WORK/test_11_callstack" "$SOURCE"

# Pause while continue is blocked, then disconnect while paused.
LOOP_SOURCE="$SCRIPT_DIR/programs/dap_loop.pas"
"$BLAISE" --source "$LOOP_SOURCE" --output "$WORK/dap_loop" \
    --backend native --debug-opdf --unit-path "$STDLIB_UNITS" > "$WORK/compile-loop.log" 2>&1 \
    || { cat "$WORK/compile-loop.log"; exit 1; }
python3 -I "$SCRIPT_DIR/dap_pause_test.py" "$ADAPTER" "$WORK/dap_loop"
