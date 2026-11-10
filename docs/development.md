# Development

Build and unit test commands are in the [README](../README.md#build-from-source). This page covers the tooling
around them.

## Live test

```sh
python3 scripts/live-test.py
```

This drives the installed app with four TextEdit windows and runs each action through `reelctl`. After every step it
checks that each window sits where Reel placed it, that nothing overlaps, and that scrolled-away windows are off
screen. It takes about a minute and moves real windows, so run it when you're not using the Mac.

## Screenshots and demos

```sh
swift run -c release reel-demos docs         # the animated demos in docs/
REEL_SNAPSHOT=/tmp/shots .build/debug/Reel   # every settings page, plus hero-*.png on a wallpaper
python3 scripts/record-demo.py               # a real screen recording, into docs/demo.gif
```

`reel-demos` draws the demos rather than recording them: it runs each script of actions through the real strip
model and layout code, steps the windows with the app's spring, and paints every frame. They come out the same on
any Mac and need no permissions.

The recording script opens captioned TextEdit windows, drives them through `reelctl` while `screencapture`
records the screen, and converts the recording with `scripts/mov-to-gif.swift`. Run it on an empty Space; the terminal needs the
Screen Recording permission.
