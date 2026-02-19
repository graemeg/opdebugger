#!/bin/bash
#
# Integration Test Runner for PDR Debugger (Launch Mode)
#
# Tests that launch programs directly (for break/next/step commands)
# Compiles using the FPC OPDF-capable compiler (ppcx64 -gO).
# Debug information is embedded directly in the binary (.opdf ELF section).
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Counters
PASSED=0
FAILED=0

PDR_BIN="$PROJECT_ROOT/pdr-cli/target/pdr"
PPCX64="/data/devel/fpc-3.3.1/x86_64-linux/lib/fpc/3.3.1/ppcx64"
FPC_CFG="/data/devel/fpc-3.3.1/x86_64-linux/lib/fpc/3.3.1/fpc.cfg"

echo "=== PDR Integration Test Runner (Launch Mode) ==="
echo

if [ ! -f "$PDR_BIN" ]; then
    echo -e "${RED}ERROR: PDR binary not found${NC}"
    exit 1
fi

if [ ! -f "$PPCX64" ]; then
    echo -e "${RED}ERROR: OPDF-capable FPC compiler not found: $PPCX64${NC}"
    exit 1
fi

# Filter non-deterministic output
filter_output() {
    # Remove the debugger prompt (pdr) from each line, then filter.
    # Only capture debugger output from print commands, callstack, and step messages.
    # Matches: variable names with 2+ chars (optionally followed by [index]) and " = " value
    #           e.g. Sum = 15, COUNTER = 42, BigArray[2] = 30
    # Matches: [INFO] Stepped to line: ..., stepped to line: ...
    # Matches: [CALLSTACK], #0 ..., #1 ..., etc.
    # Excludes: single-char names (A, B), program WriteLn output (multi-word lines)
    sed 's/^(pdr) //' | \
    sed -E 's/ \(0x[0-9A-Fa-f ]+\)//' | \
    grep -E "^(([A-Z][A-Za-z0-9_]+(\[[0-9]+\])? = )|(\[INFO\] )?[Ss]tepped to line:|\\[CALLSTACK\\]|#[0-9]+ )" | \
    sed 's/^\[INFO\] //' || true
}

run_test() {
    local test_name=$1
    local test_base="${test_name%.pas}"

    echo -e "${YELLOW}Running: $test_base${NC}"

    # Compile with FPC OPDF support (embeds debug info in .opdf ELF section)
    echo "  [1/3] Compiling..."
    if ! "$PPCX64" "@$FPC_CFG" -gO "$test_name" -o"$test_base" > "$test_base.compile.log" 2>&1; then
        echo -e "${RED}  FAILED: Compilation${NC}"
        cat "$test_base.compile.log"
        ((FAILED++))
        return 1
    fi

    # Run PDR with commands
    echo "  [2/3] Running PDR..."
    if [ -f "$test_base.commands" ]; then
        cat "$test_base.commands" | "$PDR_BIN" --verbose "$test_base" 2>&1 | filter_output > "$test_base.actual"
    else
        echo -e "${YELLOW}  No commands file${NC}"
        return 0
    fi

    # Compare (case-insensitive for Pascal, address-normalized)
    echo "  [3/3] Comparing output..."
    if [ -f "$test_base.expected" ]; then
        # Normalize addresses in both files (replace hex addresses with placeholder)
        # Then convert to lowercase for case-insensitive comparison
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
