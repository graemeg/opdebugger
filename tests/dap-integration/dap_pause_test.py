#!/usr/bin/env python3
#
# pdr-dap pause test: runs dap_loop (a Blaise program that never ends),
# pauses it while continue is blocked, reads the stack, resumes, pauses
# again and disconnects.
#
# Usage: dap_pause_test.py <pdr-dap> <program>
# Exit code 0 when every check passes.
#
# Copyright (c) 2026 Graeme Geldenhuys
# SPDX-License-Identifier: BSD-3-Clause

import json
import subprocess
import sys
import threading
import queue
import time

adapter, program = sys.argv[1], sys.argv[2]
proc = subprocess.Popen([adapter], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE)
messages = queue.Queue()
stderr_lines = []


def reader():
    out = proc.stdout
    while True:
        length = None
        while True:
            line = out.readline()
            if not line:
                messages.put(None)
                return
            line = line.strip()
            if not line:
                break
            if line.lower().startswith(b"content-length:"):
                length = int(line.split(b":")[1])
        messages.put(json.loads(out.read(length)))


def drain_stderr():
    for line in proc.stderr:
        stderr_lines.append(line.decode(errors="replace").rstrip())


threading.Thread(target=reader, daemon=True).start()
threading.Thread(target=drain_stderr, daemon=True).start()

seq = 0
failures = 0
checks = 0


def check(cond, what):
    global failures, checks
    checks += 1
    if not cond:
        failures += 1
        print("FAIL:", what)


def send(command, arguments=None):
    global seq
    seq += 1
    msg = {"seq": seq, "type": "request", "command": command}
    if arguments is not None:
        msg["arguments"] = arguments
    body = json.dumps(msg).encode()
    proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
    proc.stdin.flush()
    return seq


def expect(kind, name, timeout=20):
    key = "command" if kind == "response" else "event"
    while True:
        try:
            m = messages.get(timeout=timeout)
        except queue.Empty:
            check(False, "timed out waiting for %s %s" % (kind, name))
            return {}
        if m is None:
            check(False, "adapter closed before %s %s" % (kind, name))
            return {}
        if m.get("type") == kind and m.get(key) == name:
            return m


send("initialize", {"adapterID": "pdr", "linesStartAt1": True})
r = expect("response", "initialize")
filters = r.get("body", {}).get("exceptionBreakpointFilters", [])
check([f.get("filter") for f in filters] == ["raised"], "exception filters: %s" % filters)
send("launch", {"program": program})
check(expect("response", "launch").get("success"), "launch")
expect("event", "initialized")
send("setExceptionBreakpoints", {"filters": []})
check(expect("response", "setExceptionBreakpoints").get("success"), "setExceptionBreakpoints")
send("configurationDone")
expect("response", "configurationDone")

for round_ in (1, 2):
    time.sleep(0.5)
    send("pause", {"threadId": 1})
    check(expect("response", "pause", timeout=5).get("success"), "pause %d answered" % round_)
    e = expect("event", "stopped", timeout=10)
    check(e.get("body", {}).get("reason") == "pause", "pause %d stops: %s" % (round_, e))
    send("stackTrace", {"threadId": 1})
    frames = expect("response", "stackTrace").get("body", {}).get("stackFrames", [])
    names = [f.get("name", "").lower() for f in frames]
    check("main" in names or "spin" in names, "pause %d stack: %s" % (round_, names))
    if round_ == 1:
        send("continue", {"threadId": 1})
        expect("response", "continue")

send("disconnect", {"terminateDebuggee": True})
expect("response", "disconnect")
try:
    proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()
    check(False, "adapter did not exit after disconnect")

print("%d/%d checks passed" % (checks - failures, checks))
if failures:
    print("--- adapter stderr ---")
    print("\n".join(stderr_lines[-40:]))
sys.exit(1 if failures else 0)
