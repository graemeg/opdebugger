#!/usr/bin/env python3
#
# pdr-dap end-to-end test: drives the real adapter over stdio against
# test_11_callstack (a Blaise program built with OPDF), checking the launch
# handshake, a breakpoint, the stack, locals, a step, evaluate and the exit.
#
# Usage: dap_session_test.py <pdr-dap> <program> <source-path>
# Exit code 0 when every check passes.
#
# Copyright (c) 2026 Graeme Geldenhuys
# SPDX-License-Identifier: BSD-3-Clause

import json
import subprocess
import sys
import threading
import queue

adapter, program, source = sys.argv[1], sys.argv[2], sys.argv[3]
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
    """The next response or event named NAME (others are skipped)."""
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
check(r.get("success"), "initialize")

send("launch", {"program": program})
r = expect("response", "launch")
check(r.get("success"), "launch: %s" % r.get("message"))
expect("event", "initialized")

send("setBreakpoints", {"source": {"path": source}, "breakpoints": [{"line": 13}]})
r = expect("response", "setBreakpoints")
bps = r.get("body", {}).get("breakpoints", [])
check(len(bps) == 1 and bps[0].get("verified"), "breakpoint at line 13 verified: %s" % bps)

send("configurationDone")
expect("response", "configurationDone")
e = expect("event", "stopped")
check(e.get("body", {}).get("reason") == "breakpoint", "stopped at the breakpoint: %s" % e)

send("stackTrace", {"threadId": 1})
r = expect("response", "stackTrace")
frames = r.get("body", {}).get("stackFrames", [])
names = [f.get("name", "").lower() for f in frames]
lines = [f.get("line") for f in frames]
check(names[:4] == ["level3", "level2", "level1", "main"], "frame names: %s" % names)
check(lines[:4] == [13, 19, 25, 37], "frame lines: %s" % lines)
check(frames and frames[0].get("source", {}).get("name") == "test_11_callstack.pas",
      "frame source: %s" % (frames[0] if frames else None))

send("scopes", {"frameId": 0})
r = expect("response", "scopes")
scopes = {s["name"]: s["variablesReference"] for s in r.get("body", {}).get("scopes", [])}
send("variables", {"variablesReference": scopes.get("Locals")})
r = expect("response", "variables")
vars_ = {v["name"].lower(): v for v in r.get("body", {}).get("variables", [])}
check("marker" in vars_ and vars_["marker"].get("type"), "Level3's locals: %s" % vars_)
send("variables", {"variablesReference": scopes.get("Globals")})
r = expect("response", "variables")
vars_ = {v["name"].lower(): v["value"] for v in r.get("body", {}).get("variables", [])}
check(vars_.get("x") == "10" and vars_.get("y") == "20", "globals: %s" % vars_)

send("evaluate", {"expression": "X + Y", "frameId": 3})
r = expect("response", "evaluate")
check(r.get("success") and r.get("body", {}).get("result") == "30",
      "evaluate X + Y: %s" % r)

send("next", {"threadId": 1})
expect("response", "next")
e = expect("event", "stopped")
check(e.get("body", {}).get("reason") == "step", "stopped after next: %s" % e)
send("stackTrace", {"threadId": 1})
r = expect("response", "stackTrace")
frames = r.get("body", {}).get("stackFrames", [])
check(frames and frames[0].get("name", "").lower() == "level2",
      "next over Level3's last line returns to Level2: %s" % (frames[:1],))

send("continue", {"threadId": 1})
expect("response", "continue")
e = expect("event", "exited")
check("exitCode" in e.get("body", {}), "exited")
expect("event", "terminated")

send("disconnect")
expect("response", "disconnect")
try:
    proc.wait(timeout=10)
except subprocess.TimeoutExpired:
    proc.kill()
    check(False, "adapter did not exit after disconnect")

check(any("Done" in l for l in stderr_lines), "the program's output went to stderr")

print("%d/%d checks passed" % (checks - failures, checks))
if failures:
    print("--- adapter stderr ---")
    print("\n".join(stderr_lines[-40:]))
sys.exit(1 if failures else 0)
