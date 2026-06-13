#!/bin/bash
#
# Blaise Integration Test Runner for PDR Debugger (Launch Mode)
#
# Companion to ../integration (the FPC suite).  Programs here are compiled
# with the Blaise compiler (--backend native --debug-opdf), so this suite
# exercises the toolchain Blaise actually ships and drives the OPDF format
# forward.  New OPDF features are tested HERE; the FPC suite is frozen as an
# interop conformance backstop for the legacy type zoo Blaise deliberately
# dropped (ShortString/AnsiString/WideString/UnicodeString, stack objects).
#
# Each test is a triple:
#   <name>.pas       — a Blaise program (0-based strings, single UTF-8 string
#                      type, no inline var, Self.Method for recursion)
#   <name>.commands  — pdr commands piped on stdin
#   <name>.expected  — filtered, lower-cased, address-normalised baseline
#
# The .expected baselines are written for Blaise semantics; they are NOT
# copies of the FPC suite's baselines (0-based indexing, one string type,
# etc. change the printed output even for an "equivalent" program).
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Blaise lives beside the debugger repo by default; override with BLAISE_ROOT.
BLAISE_ROOT="${BLAISE_ROOT:-/data/devel/new-pascal-compiler}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Counters
PASSED=0
FAILED=0

PDR_BIN="$PROJECT_ROOT/pdr-cli/target/pdr"
BLAISE="${BLAISE:-$BLAISE_ROOT/compiler/target/blaise}"
RUNTIME_UNITS="$BLAISE_ROOT/runtime/src/main/pascal"
STDLIB_UNITS="$BLAISE_ROOT/stdlib/src/main/pascal"

echo "=== PDR Blaise Integration Test Runner (Launch Mode) ==="
echo

if [ ! -f "$PDR_BIN" ]; then
    echo -e "${RED}ERROR: PDR binary not found: $PDR_BIN${NC}"
    exit 1
fi

if [ ! -x "$BLAISE" ]; then
    echo -e "${RED}ERROR: Blaise compiler not found: $BLAISE${NC}"
    echo "Set BLAISE or BLAISE_ROOT, or build it (pasbuild compile -m blaise-compiler)."
    exit 1
fi

# Filter non-deterministic output (shared with the FPC suite).
filter_output() {
    sed 's/^(pdr) //' | \
    sed -E 's/ \(0x[0-9A-Fa-f ]+\)//' | \
    sed -E 's/\(\$[0-9A-Fa-f]+\)/(<ptr>)/' | \
    grep -E '^(([A-Za-z(][A-Za-z0-9_.]+(\[[0-9]+\])? = |[-A-Za-z(][A-Za-z0-9_.]+[A-Za-z0-9_. +*/()<>-]*= (-?[0-9]|True|False|nil|'"'"'|\$))|(\[INFO\] )?[Ss]tepped to line:|(\[INFO\] )?[Rr]eturned to:|\[CALLSTACK\]|#[0-9]+ |Exception: [A-Za-z]+ —|(=>|  ) +[0-9]+($|  ))' | \
    grep -v '<unknown>' | \
    sed 's/^\[INFO\] //' || true
}

run_test() {
    local test_name=$1
    local test_base="${test_name%.pas}"

    echo -e "${YELLOW}Running: $test_base${NC}"

    # Compile with Blaise (native backend, OPDF debug info embedded).
    # Blaise links the executable directly — no separate QBE/gcc step.
    echo "  [1/3] Compiling (Blaise)..."
    if ! "$BLAISE" \
            --source "$test_name" \
            --output "$test_base" \
            --backend native --debug-opdf \
            --unit-path "$RUNTIME_UNITS" \
            --unit-path "$STDLIB_UNITS" \
            > "$test_base.compile.log" 2>&1; then
        echo -e "${RED}  FAILED: Compilation${NC}"
        cat "$test_base.compile.log"
        ((FAILED++))
        return 1
    fi

    # Run PDR with commands.
    echo "  [2/3] Running PDR..."
    if [ -f "$test_base.commands" ]; then
        cat "$test_base.commands" | "$PDR_BIN" --verbose "$test_base" 2>&1 | filter_output > "$test_base.actual"
    else
        echo -e "${YELLOW}  No commands file${NC}"
        return 0
    fi

    # Compare (case-insensitive for Pascal, address-normalized).
    echo "  [3/3] Comparing output..."
    if [ -f "$test_base.expected" ]; then
        if diff -u <(sed -E 's/@\$[0-9A-Fa-f]+/@$<addr>/g' "$test_base.expected" | tr '[:upper:]' '[:lower:]') \
                   <(sed -E 's/@\$[0-9A-Fa-f]+/@$<addr>/g' "$test_base.actual" | tr '[:upper:]' '[:lower:]') > "$test_base.diff"; then
            echo -e "${GREEN}  ✓ PASSED${NC}"
            ((PASSED++))
            return 0
        else
            echo -e "${RED}  ✗ FAILED${NC}"
            cat "$test_base.diff"
            ((FAILED++))
            return 1
        fi
    else
        echo -e "${YELLOW}  SKIPPED: No expected file${NC}"
        return 0
    fi
}

cd "$SCRIPT_DIR"

if [ $# -eq 1 ]; then
    TEST_NAME=$1
    [[ ! "$TEST_NAME" =~ \.pas$ ]] && TEST_NAME="${TEST_NAME}.pas"
    run_test "$TEST_NAME"
else
    for test_file in test_*_*.pas; do
        [ -f "$test_file" ] && run_test "$test_file" && echo
    done
fi

echo "==================================="
echo -e "Passed: ${GREEN}$PASSED${NC}"
echo -e "Failed: ${RED}$FAILED${NC}"
echo "==================================="

[ $FAILED -eq 0 ] && exit 0 || exit 1
