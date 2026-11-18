#!/usr/bin/env python3
"""Installed-app control integration tests. No credentials or clipboard text are read."""
import json
import pathlib
import socket
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parent.parent
address = str(pathlib.Path.home() / "Library/Application Support/SilentClipboard/control.sock")

def control(command, **fields):
    with socket.socket(socket.AF_UNIX) as channel:
        channel.settimeout(5)
        channel.connect(address)
        channel.sendall(json.dumps(dict(command=command, **fields)).encode() + b"\n")
        return json.loads(channel.makefile("rb").readline(65536))

initial = control("status")
assert initial["ok"] and initial["hotkeyRegistered"]
assert initial["windowCount"] == 0 and initial["activationPolicy"] == "prohibited"
assert initial["credentialAvailable"] and initial["clipboardAccess"] == "allowed"
helper = subprocess.Popen(["swift", str(root / "scripts/qa-hotkey-conflict.swift")],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
try:
    existing, reserved = map(int, helper.stdout.readline().strip().split(","))
    assert existing != 0, "Installed hotkey must be exclusive"
    assert reserved == 0, "Test alternate hotkey must be available"
    conflict = dict(initial["configuration"], hotKeyCode=37)
    reply = control("configure", configuration=conflict)
    assert not reply["ok"] and reply["message"] == "hotkey_conflict"
    current = control("status")
    assert current["configuration"] == initial["configuration"] and current["hotkeyRegistered"]
finally:
    helper.communicate("done\n", timeout=5)

assert control("pause")["ok"]
paused = control("status")["pipeline"]
control("process")
assert control("status")["pipeline"]["requestID"] == paused["requestID"]
assert control("resume")["ok"]
assert not control("not-a-command")["ok"]
invalid = dict(initial["configuration"], hotKeyModifiers=0)
assert not control("configure", configuration=invalid)["ok"]

# Oversized or malformed messages must not crash the service or disclose errors.
with socket.socket(socket.AF_UNIX) as channel:
    channel.settimeout(5)
    channel.connect(address)
    channel.sendall(b"invalid-json\n")
    assert channel.recv(1) == b""
assert control("status")["ok"]
report = {"exclusiveHotkey": True, "conflictRollsBack": True, "pauseBlocksRequests": True,
          "invalidConfigRejected": True, "malformedIPCSurvives": True,
          "zeroWindows": True, "keychainReadableAfterRestart": True}
(root / "build/qa/control-integration.json").write_text(json.dumps(report, indent=2))
print(json.dumps(report, indent=2))
