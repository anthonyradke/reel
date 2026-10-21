# Reel

Reel is a scrolling window manager for macOS. Every window becomes a column on one long horizontal strip, one strip
per display and Space. Opening a window adds a column next to the one you're in without squeezing the others, and
when the strip is wider than the screen you scroll it with the keyboard or a trackpad swipe.

I wrote it because I like how niri and PaperWM work on Linux and wanted the same thing on my Mac, as a small native
app with no scripting layer to set up.

## What it does

- Tiles normal windows into columns. Dialogs, sheets, Quick Look, fixed-size windows and anything you add a rule for
  stay floating.
- Columns have preset widths (a third, a half, two thirds by default) that you cycle through, plus full width and
  free resizing with the keyboard or by dragging a window edge.
- Several windows can share a column, either stacked with adjustable heights or as tabs with a small tab bar.
- You can pin a column to the left or right edge so it stays put while the rest of the strip scrolls.
- Scrolling uses a spring animation, and the strip follows a three or four finger swipe with momentum.
- Each display gets its own strip, and windows that reach the edge of a neighbouring display hide instead of
  spilling onto it.
- Native macOS tabs, minimised windows, hidden apps and full-screen windows come back to where they were.
- The strip survives a restart of Reel, a sleep or a display change.
- An optional focus border, dimming of unfocused windows, and a strip indicator at the top of the screen that you can
  click or drag to reorder.
- Every shortcut can be changed in the settings, and the settings file is plain JSON that reloads as you save it.

## Keys

All the defaults use ⌃⌥ (Control-Option).

| Keys | What it does |
|---|---|
| ⌃⌥ ← → or H L | Focus the column to the left or right |
| ⌃⌥ ↑ ↓ or K J | Focus up or down inside a stacked column |
| ⌃⌥⇧ with any of the above | Move the window instead of the focus |
| ⌃⌥ 1 to 9 | Jump to a column, ⌃⌥⇧ to move the window there |
| ⌃⌥ R | Cycle preset widths (⇧ goes backwards) |
| ⌃⌥ F | Full width and back |
| ⌃⌥ C | Centre the column |
| ⌃⌥ = and - | Wider and narrower (⇧ for taller and shorter) |
| ⌃⌥ ] and [ | Stack the window into the column on its left or right |
| ⌃⌥⇧ ] and [ | Take it back out |
| ⌃⌥⇧ T | Show the column as tabs |
| ⌃⌥ T | Float or tile the window |
| ⌃⌥ P | Pin the column to the left edge (⇧ for the right) |
| ⌃⌥ N | Send the window to the next display |
| ⌃⌥ , | Settings |
| ⌃⌥ Q | Stop Reel and put the windows back on screen |

## Installing

Reel needs macOS 13 or later. Download `Reel.dmg` from the releases page, drag Reel to Applications and open it. The
first run walks through the one permission it needs: Accessibility, which is how macOS lets an app move other
apps' windows. The Mac Setup page in the settings checks the trackpad and Spaces options that make it work best,
and warns if another window manager is running.

## Building

```sh
swift test                      # layout and strip logic
./scripts/build-app.sh          # build/Reel.app
./scripts/build-app.sh --dmg    # also build/Reel.dmg
./scripts/build-app.sh --install
python3 scripts/live-test.py    # drives the installed app with TextEdit windows
```

The live test opens four TextEdit windows and runs the actions through `reelctl`. After each step it checks that
every window really sits where Reel meant to put it, that nothing overlaps, and that scrolled-away windows are off
screen. It moves real windows around for about a minute.

The build script signs with the first Apple Development or Developer ID identity it finds, or ad hoc if there isn't
one. Signing with the same identity every time keeps the Accessibility permission across rebuilds.

The code is in three parts. `ReelCore` holds the strip model, the layout maths and the spring, with no AppKit in it,
so it's what the tests cover. `Reel` is the app: the Accessibility and SkyLight calls, the animation loop, hot keys,
gestures, overlays and the SwiftUI settings. `reelctl` is a small command line client.

## Scripting

Every action has a name, and there are three ways to trigger one from outside:

```sh
open -g reel://focus-right
reelctl move-to-3
reelctl status            # strips and windows as JSON
reelctl set gap 12        # change a setting
```

The Automation page in the settings links `reelctl` into `~/.local/bin` and can export Raycast script commands.

## Files

- Settings: `~/Library/Application Support/Reel/config.json`
- Saved strips: `~/Library/Application Support/Reel/session.json`
- Log: `~/Library/Logs/Reel/engine.log`
