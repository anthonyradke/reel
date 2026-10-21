#!/usr/bin/env python3
"""Drives a running Reel through reelctl with a few TextEdit windows and checks that every
window really ends up where Reel says it should. It moves real windows, so run it when you
don't mind the screen jumping around for half a minute.

    python3 scripts/live-test.py [path/to/reelctl]
"""
import json
import os
import subprocess
import sys
import tempfile
import time

REELCTL = sys.argv[1] if len(sys.argv) > 1 else "/Applications/Reel.app/Contents/MacOS/reelctl"
SETTLE = 0.9
failures = []


def ctl(*args):
    out = subprocess.run([REELCTL, *args], capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f"reelctl {' '.join(args)} failed: {out.stdout}{out.stderr}")
    return json.loads(out.stdout) if out.stdout.strip().startswith("{") else out.stdout


def act(name, wait=SETTLE):
    ctl(name)
    time.sleep(wait)


def strip():
    s = ctl("status")
    for d in s["displays"]:
        if d["focusedStrip"]:
            return d
    return s["displays"][0]


TEST_TITLES = {f"{n}.txt" for n in "abcd"}


def ours(d):
    """Columns as lists of window ids, only the test's own windows."""
    cols = []
    for c in d["columns"]:
        ids = [w["id"] for w in c["windows"] if w["app"] == "TextEdit" and w["title"] in TEST_TITLES]
        if ids:
            cols.append(ids)
    return cols


def focused_window(d):
    for c in d["columns"]:
        if c["focused"]:
            return c
    return None


def check(cond, what):
    print(("  ok   " if cond else "  FAIL ") + what)
    if not cond:
        failures.append(what)


def all_windows(d):
    for c in d["columns"]:
        yield from c["windows"]
    yield from d["pinnedLeft"]
    yield from d["pinnedRight"]


def check_frames(label):
    """Every on-screen window sits at its target; every parked one is off the display."""
    d = strip()
    fx, fy, fw, fh = d["frame"]
    bad = []
    for w in all_windows(d):
        if "frame" not in w or "target" not in w:
            continue
        x, y, wd, ht = w["frame"]
        tx, ty, tw, th = w["target"]
        if w["onScreen"]:
            width_ok = abs(wd - tw) <= 2 or ("minWidth" in w and wd >= tw)
            if abs(x - tx) > 2 or abs(y - ty) > 2 or not width_ok or abs(ht - th) > 2:
                bad.append(f"{w['app']} {w['id']} at {w['frame']} wants {w['target']}")
        else:
            shown = max(0, min(x + wd, fx + fw) - max(x, fx))
            if shown > 2:
                bad.append(f"{w['app']} {w['id']} should be parked but shows {shown}px at {w['frame']}")
    shown = [w for w in all_windows(d) if w.get("onScreen") and "frame" in w]
    for i, a in enumerate(shown):
        for b in shown[i + 1:]:
            ax, ay, aw, ah = a["frame"]
            bx, by, bw, bh = b["frame"]
            ix = min(ax + aw, bx + bw) - max(ax, bx)
            iy = min(ay + ah, by + bh) - max(ay, by)
            if ix > 2 and iy > 2:
                bad.append(f"{a['app']} {a['id']} overlaps {b['app']} {b['id']} by {ix}x{iy}")
    check(not bad, f"{label}: frames match" + ("" if not bad else "\n         " + "\n         ".join(bad)))
    return d


HELPER = os.path.join(tempfile.gettempdir(), "reel-test-helper")
HELPER_SRC = """
import AppKit
let args = CommandLine.arguments
guard args.count == 3, let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[2]).first else { exit(1) }
_ = args[1] == "hide" ? app.hide() : app.unhide()
"""


def build_helper():
    src = HELPER + ".swift"
    with open(src, "w") as f:
        f.write(HELPER_SRC)
    subprocess.run(["swiftc", "-O", "-o", HELPER, src], check=True, capture_output=True)


def main():
    build_helper()
    status = ctl("status")
    if not status.get("running"):
        raise SystemExit("Reel isn't running (or has no Accessibility permission)")
    subprocess.run(["pkill", "-x", "TextEdit"])
    time.sleep(1)

    tmp = tempfile.mkdtemp(prefix="reel-test-")
    files = []
    for name in "abcd":
        p = os.path.join(tmp, f"{name}.txt")
        with open(p, "w") as f:
            f.write(f"Reel test window {name}\n")
        files.append(p)

    print("open four windows")
    for p in files:
        # -F: don't bring back windows from an earlier run.
        subprocess.run(["open", "-F", "-a", "TextEdit", p])
        time.sleep(1.2)
    time.sleep(1)
    d = check_frames("after opening")
    cols = ours(d)
    check(len(cols) == 4 and all(len(c) == 1 for c in cols), f"four TextEdit columns ({cols})")
    order = [c[0] for c in cols]

    print("focus")
    act("focus-left")
    d = check_frames("focus-left")
    f = focused_window(d)
    check(f and f["windows"][0]["id"] == order[2], "focus moved one column left")
    act("focus-right")
    d = check_frames("focus-right")
    f = focused_window(d)
    check(f and f["windows"][0]["id"] == order[3], "focus moved back right")

    print("widths")
    before = focused_window(strip())["windows"][0]["target"][2]
    act("cycle-width")
    after = focused_window(check_frames("cycle-width"))["windows"][0]["target"][2]
    check(after != before, f"cycle-width changed the width ({before} -> {after})")
    act("full-width")
    d = check_frames("full-width")
    full = focused_window(d)["windows"][0]["target"][2]
    ax, ay, aw, ah = d["area"]
    check(full >= aw - 2 * 48, f"full width fills the screen ({full} of {aw})")
    act("full-width")
    back = focused_window(check_frames("full-width off"))["windows"][0]["target"][2]
    check(back == after, f"full width toggles back ({back})")

    print("move")
    act("move-left")
    d = check_frames("move-left")
    cols = ours(d)
    check([c[0] for c in cols] == [order[0], order[1], order[3], order[2]], "window moved one place left")
    act("move-right")
    check([c[0] for c in ours(check_frames("move-right"))] == order, "and back")

    print("stacks")
    act("stack-left")
    d = check_frames("stack-left")
    cols = ours(d)
    check(len(cols) == 3 and cols[2] == [order[2], order[3]], f"stacked into the left column ({cols})")
    col = focused_window(d)
    if col and len(col["windows"]) == 2:
        a, b = col["windows"]
        check(a["target"][1] + a["target"][3] <= b["target"][1], "stacked windows don't overlap")
    act("toggle-tabbed")
    d = check_frames("tabbed")
    col = focused_window(d)
    check(col and col["tabbed"], "column is tabbed")
    if col:
        shown = [w for w in col["windows"] if w["onScreen"]]
        check(len(shown) == 1, f"one tab on screen ({len(shown)})")
    act("toggle-tabbed")
    act("pop-out")
    d = check_frames("pop-out")
    check([c[0] for c in ours(d)] == order and all(len(c) == 1 for c in ours(d)), f"popped back out ({ours(d)})")

    print("pins")
    act("pin-left")
    d = check_frames("pin-left")
    pinned = [w["id"] for w in d["pinnedLeft"]]
    check(pinned == [order[3]], f"pinned to the left ({pinned})")
    if d["pinnedLeft"]:
        check(d["pinnedLeft"][0]["target"][0] <= d["area"][0] + 48, "pinned column sits at the left edge")
    act("pin-left")
    d = check_frames("unpin")
    check(not d["pinnedLeft"], "unpinned")
    act("move-last")

    print("scrolling")
    act("scroll:-100000")
    d = check_frames("scroll to start")
    check(d["viewOffset"] >= -1, f"scrolling stops at the start ({d['viewOffset']})")
    act("scroll:100000")
    d = check_frames("scroll to end")
    act("focus-last")
    check_frames("focus-last")

    print("float")
    act("toggle-float")
    d = strip()
    s = ctl("status")
    floating = [w["id"] for w in s["floating"]]
    check(order[3] in floating and all(order[3] not in c for c in ours(d)), "floated off the strip")
    act("toggle-float")
    d = check_frames("tiled again")
    check(any(order[3] in c for c in ours(d)), "back on the strip")

    print("jump and resize")
    act("focus-1")
    d = check_frames("focus-1")
    check(d["columns"][0]["focused"], "focus-1 goes to the first column")
    act("focus-last")
    act("move-to-1")
    d = check_frames("move-to-1")
    check(d["columns"][0]["windows"][0]["id"] == order[3], "move-to-1 puts the window first")
    act("move-last")
    w0 = focused_window(strip())["windows"][0]["target"][2]
    act("narrower")
    w1 = focused_window(check_frames("narrower"))["windows"][0]["target"][2]
    act("wider")
    w2 = focused_window(check_frames("wider"))["windows"][0]["target"][2]
    check(w1 < w0 and abs(w2 - w0) <= 2, f"narrower then wider ({w0} -> {w1} -> {w2})")
    # Narrower than TextEdit allows: the strip has to make room instead of overlapping.
    for _ in range(6):
        act("narrower", 0.3)
    time.sleep(0.8)
    d = check_frames("narrower than the app allows")
    act("cycle-width")

    print("stack heights")
    act("stack-left")
    act("taller")
    d = check_frames("taller")
    col = focused_window(d)
    if col and len(col["windows"]) == 2:
        a, b = col["windows"]
        check(b["target"][3] > a["target"][3], f"focused window got taller ({a['target'][3]} / {b['target'][3]})")
    act("equalize-heights")
    d = check_frames("equal heights")
    col = focused_window(d)
    if col and len(col["windows"]) == 2:
        a, b = col["windows"]
        check(abs(a["target"][3] - b["target"][3]) <= 2, "heights equal again")
    act("pop-out")

    print("hide and show the app")
    before = ours(strip())
    subprocess.run([HELPER, "hide", "com.apple.TextEdit"])
    time.sleep(1.2)
    d = check_frames("app hidden")
    check(not ours(d), f"hidden windows left the strip ({ours(d)})")
    subprocess.run([HELPER, "unhide", "com.apple.TextEdit"])
    time.sleep(1.5)
    d = check_frames("app shown")
    check(ours(d) == before, f"they came back in the same places ({before} -> {ours(d)})")

    print("restart keeps the strip")
    before = [c for c in ours(strip())]
    act("stop", 0.5)
    act("start", 2.0)
    after = ours(check_frames("after restart"))
    check(after == before, f"same order after restart ({before} -> {after})")

    print("quit TextEdit")
    subprocess.run(["pkill", "-x", "TextEdit"])
    time.sleep(1.5)
    d = check_frames("after quitting")
    check(not ours(d), "TextEdit windows left the strip")

    print()
    if failures:
        print(f"{len(failures)} failed")
        sys.exit(1)
    print("all passed")


if __name__ == "__main__":
    main()
