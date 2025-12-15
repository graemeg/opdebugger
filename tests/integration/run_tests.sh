#!/bin/bash
#
# Integration Test Runner for PDR Debugger
#
# Usage: ./run_tests.sh [test_name]
#   If test_name provided, runs only that test
#   Otherwise, runs all test_*.pas files
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Counters
PASSED=0
FAILED=0

# Check if PDR binary exists
PDR_BIN="$PROJECT_ROOT/pdr-cli/target/pdr"
OPDF_GEN="$PROJECT_ROOT/tools/target/opdf_generator"

echo "=== PDR Integration Test Runner ==="
echo

if [ ! -f "$PDR_BIN" ]; then
    echo -e "${RED}ERROR: PDR binary not found at $PDR_BIN${NC}"
    echo "Run 'pasbuild compile' first"
    exit 1
fi

if [ ! -f "$OPDF_GEN" ]; then
    echo -e "${YELLOW}WARNING: OPDF generator not found at $OPDF_GEN${NC}"
    echo "OPDF generation will be skipped"
fi

# Run a single test
run_test() {
    local test_name=$1
    local test_base="${test_name%.pas}"

    echo -e "${YELLOW}Running test: $test_base${NC}"

    # Compile test program
    echo "  [1/5] Compiling test program..."
    if ! fpc -g "$test_name" -o"$test_base" > "$test_base.compile.log" 2>&1; then
        echo -e "${RED}  FAILED: Compilation error${NC}"
        cat "$test_base.compile.log"
        ((FAILED++))
        return 1
    fi

    # Get symbol addresses using nm
    echo "  [2/5] Extracting symbol addresses..."
    nm "$test_base" | grep -E ' (B|D) ' > "$test_base.symbols" || true

    # Generate OPDF (if generator exists)
    if [ -f "$OPDF_GEN" ]; then
        echo "  [3/5] Generating OPDF..."
        if ! "$OPDF_GEN" "$test_base" > "$test_base.opdf.log" 2>&1; then
            echo -e "${RED}  FAILED: OPDF generation error${NC}"
            cat "$test_base.opdf.log"
            ((FAILED++))
            return 1
        fi
    else
        echo "  [3/5] Skipping OPDF generation (generator not built)"
    fi

    # Run test program in background
    echo "  [4/5] Running test program..."
    ./"$test_base" > "$test_base.output.log" 2>&1 &
    TEST_PID=$!

    # Give it a moment to start
    sleep 0.5

    # Check if process is still running
    if ! kill -0 $TEST_PID 2>/dev/null; then
        echo -e "${RED}  FAILED: Test program exited immediately${NC}"
        cat "$test_base.output.log"
        ((FAILED++))
        return 1
    fi

    # Run PDR debugger
    echo "  [5/5] Running PDR debugger..."
    if [ -f "$test_base.commands" ]; then
        # Feed PID to debugger, then commands
        {
            echo "$TEST_PID"
            cat "$test_base.commands"
        } | "$PDR_BIN" "$test_base" > "$test_base.actual" 2>&1 || true
    else
        echo -e "${YELLOW}  WARNING: No commands file found${NC}"
    fi

    # Kill test program
    kill $TEST_PID 2>/dev/null || true
    wait $TEST_PID 2>/dev/null || true

    # Compare output
    if [ -f "$test_base.expected" ] && [ -f "$test_base.actual" ]; then
        if diff -u "$test_base.expected" "$test_base.actual" > "$test_base.diff"; then
            echo -e "${GREEN}  ✓ PASSED${NC}"
            ((PASSED++))
            return 0
        else
            echo -e "${RED}  ✗ FAILED: Output mismatch${NC}"
            echo "  Expected vs Actual:"
            cat "$test_base.diff"
            ((FAILED++))
            return 1
        fi
    else
        echo -e "${YELLOW}  SKIPPED: No expected output file${NC}"
        return 0
    fi
}

# Main execution
cd "$SCRIPT_DIR"

if [ $# -eq 1 ]; then
    # Run specific test
    TEST_NAME=$1
    if [ ! -f "$TEST_NAME.pas" ]; then
        TEST_NAME="test_${TEST_NAME}"
    fi

    if [ ! -f "$TEST_NAME.pas" ]; then
        echo -e "${RED}ERROR: Test file not found: $TEST_NAME.pas${NC}"
        exit 1
    fi

    run_test "$TEST_NAME.pas"
else
    # Run all tests
    for test_file in test_*.pas; do
        if [ -f "$test_file" ]; then
            run_test "$test_file"
            echo
        fi
    done
fi

# Summary
echo "==================================="
echo -e "Tests passed: ${GREEN}$PASSED${NC}"
echo -e "Tests failed: ${RED}$FAILED${NC}"
echo "==================================="

if [ $FAILED -gt 0 ]; then
    exit 1
fi

exit 0
