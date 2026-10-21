#!/usr/bin/env python3
"""Records the README demo: a few TextEdit windows, each captioned with the shortcut it shows
off, driven through reelctl while macOS records the screen. Then turns the recording into
docs/demo.gif.

Run it on an empty desktop (a fresh Space) with Reel running. The terminal needs the Screen
Recording permission. It takes about 40 seconds and moves real windows.

    python3 scripts/record-demo.py [path/to/reelctl]
"""
import os
import subprocess
import sys
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REELCTL = sys.argv[1] if len(sys.argv) > 1 else "/Applications/Reel.app/Contents/MacOS/reelctl"
OUT_MOV = os.path.join(tempfile.gettempdir(), "reel-demo.mov")
OUT_GIF = os.path.join(ROOT, "docs", "demo.gif")

# One window per caption, opened left to right.
CAPTIONS = [
    ("1-strip", "Reel", "Every window is a column on one long strip."),
    ("2-focus", "⌃⌥ ← →", "Move between columns. The strip scrolls to follow."),
    ("3-width", "⌃⌥ R", "Cycle through preset widths."),
    ("4-stack", "⌃⌥ [", "Stack a window into the column on its left."),
    ("5-tabs", "⌃⌥⇧ T", "Show a stack as tabs."),
    ("6-full", "⌃⌥ F", "Full width, and back."),
]

# (action, pause after). The pauses leave time to read the captions.
SCRIPT = [
    ("focus-1", 2.0),
    ("focus-right", 1.2), ("focus-right", 1.2), ("focus-right", 1.2),
    ("focus-left", 1.0), ("focus-left", 1.5),
    ("focus-3", 1.0), ("cycle-width", 1.2), ("cycle-width", 1.2), ("cycle-width", 1.5),
    ("focus-4", 1.0), ("stack-left", 2.0), ("focus-down", 1.0), ("focus-up", 1.5),
    ("toggle-tabbed", 2.0), ("toggle-tabbed", 1.5),
    ("focus-last", 1.0), ("full-width", 2.0), ("full-width", 1.5),
    ("focus-1", 2.5),
]


def ctl(*args):
    subprocess.run([REELCTL, *args], check=True, capture_output=True)


def rtf(title, key, body):
    # Big bold key, the explanation underneath, the way a slide would show it.
    def esc(s):
        return "".join(c if ord(c) < 128 else f"\\u{ord(c)}?" for c in s)
    return ("{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 Helvetica Neue;}}\\f0\\pard\\sa240"
            f"\\fs120\\b {esc(key)}\\b0\\par\\fs44 {esc(body)}\\par}}")


def main():
    if subprocess.run([REELCTL, "ping"], capture_output=True).returncode != 0:
        raise SystemExit("Reel isn't running")
    tmp = tempfile.mkdtemp(prefix="reel-demo-")
    subprocess.run(["pkill", "-x", "TextEdit"])
    time.sleep(1)
    for name, key, body in CAPTIONS:
        path = os.path.join(tmp, f"{name}.rtf")
        with open(path, "w") as f:
            f.write(rtf(name, key, body))
        subprocess.run(["open", "-F", "-a", "TextEdit", path])
        time.sleep(0.8)
    time.sleep(1.5)

    duration = int(sum(p for _, p in SCRIPT)) + 4
    print(f"recording {duration}s to {OUT_MOV}")
    rec = subprocess.Popen(["screencapture", "-v", "-V", str(duration), "-x", OUT_MOV])
    time.sleep(2)
    for action, pause in SCRIPT:
        ctl(action)
        time.sleep(pause)
    rec.wait()
    subprocess.run(["pkill", "-x", "TextEdit"])

    print(f"converting to {OUT_GIF}")
    subprocess.run(["swift", os.path.join(ROOT, "scripts", "mov-to-gif.swift"), OUT_MOV, OUT_GIF], check=True)
    print(f"done. The full-quality recording is {OUT_MOV}")


if __name__ == "__main__":
    main()
