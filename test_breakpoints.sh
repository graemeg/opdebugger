#!/bin/bash

# Test breakpoint functionality
# This script starts a test program and tests setting/removing breakpoints

set -e

echo "=== Breakpoint Testing ==="
echo

# Start test program in background
echo "Starting test program..."
( sleep 120; echo ) < /dev/null | ./tests/integration/test_01_loop > /tmp/test_loop.out 2>&1 &
TEST_PID=$!
echo "Test PID: $TEST_PID"
sleep 1  # Give it time to start

# Create test commands file
cat > /tmp/breakpoint_test.commands <<EOF
attach $TEST_PID
break MyGlobalInt
break 0x401000
delete 1
detach
quit
EOF

echo
echo "=== Running Debugger ==="
echo

# Run the debugger with the test commands
./pdr-cli/target/pdr tests/integration/test_01_loop < /tmp/breakpoint_test.commands

# Cleanup
kill $TEST_PID 2>/dev/null || true
rm -f /tmp/breakpoint_test.commands /tmp/test_loop.out

echo
echo "=== Test Complete ==="
