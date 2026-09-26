#!/usr/bin/env python3
"""Captures a board's serial output for a fixed time through arduino-cli monitor.

Usage: serial-capture.py <port> <seconds> [baud]
Prints what arrived and exits; never leaves the monitor running.
"""
import subprocess
import sys
import time

port, seconds = sys.argv[1], float(sys.argv[2])
baud = sys.argv[3] if len(sys.argv) > 3 else "115200"
proc = subprocess.Popen(
    ["arduino-cli", "monitor", "-p", port, "--config", "baudrate=" + baud, "--quiet"],
    # stdin stays an open pipe: arduino-cli monitor exits as soon as its input
    # reaches EOF, which an inherited closed or /dev/null stdin does at once.
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
deadline = time.monotonic() + seconds
try:
    while time.monotonic() < deadline:
        time.sleep(0.2)
finally:
    proc.terminate()
    try:
        out, _ = proc.communicate(timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, _ = proc.communicate()
sys.stdout.write(out.decode("utf-8", "replace"))
