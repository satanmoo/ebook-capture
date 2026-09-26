# ebook-capture

**English** | [한국어](README.ko.md)

A macOS command-line tool that turns the pages of an ebook in **교보도서관** (Kyobo Library) or a **Chrome web viewer**, captures each page, and saves them all as one PDF — handy for reading and annotating on an iPad.

> **Personal study use only.** Sharing or distributing captured books violates copyright.

## Requirements

- macOS 14 (Sonoma) or later
- 교보도서관 from the App Store (Apple Silicon Macs), or a Chrome web viewer that turns pages with the → key
- Permissions for your terminal app, in System Settings › Privacy & Security:
  - **Accessibility** (to press → for page turns)
  - **Screen Recording** (to capture pages)

## Install

```bash
brew install satanmoo/tap/ebook-capture
```

Update with `brew upgrade ebook-capture`.

## Usage

Open the book in the reader, then run:

```bash
ebook-capture -o linear-algebra --app 1
```

Run `ebook-capture` with no options to be asked for each value instead.

| Option | Meaning |
|---|---|
| `-o, --output FILE` | PDF to write. A bare name is saved in the current folder; paths work too (`~/Documents/la`). `.pdf` is added if missing, and you are told when it is. |
| `--pages N` | Stop after N captures. Omit it to keep going until the end of the book. In two-page view one capture holds two pages, so N is half the page count. |
| `--app APP` | `1` / `library` for 교보도서관, `2` / `chrome` for Chrome |
| `--region "x y w h"` | Capture area. Omit it to capture the whole window minus `--margin` (default 10). |
| `-f, --force` | Overwrite an existing FILE without asking |
| `--resume` | Continue an unfinished capture of FILE (see below) |

Before capturing, the tool prints `Saving to: <path>`. If the file already exists, it asks `Overwrite? [y/N]` (or stops, when not run from a terminal, unless you pass `-f`).

While it runs, the reader is brought to the front and → is pressed for every page, so **don't touch the keyboard or mouse, and don't switch to another app**. Each page is captured once it has changed and stopped moving. If a page is slow, it waits another 5 seconds; if the page still hasn't changed, that's the end of the book and it stops there without saving a duplicate.

When it's done, you hear a sound and the terminal you started it from comes back to the front with the result.

Whatever ends the run — the page count, the end of the book, Ctrl-C, or an error — the pages captured so far are saved to the PDF. If capturing fails, the message says why when it can tell (for example "You switched to WezTerm while capturing" or "The Chrome window is no longer on screen").

### Continuing an unfinished capture

After Ctrl-C or an error, the captured pages are also kept so you can pick up where it stopped:

```bash
ebook-capture -o linear-algebra --resume
```

It reuses the app, capture area and page limit from the first run and rebuilds the PDF with all the pages. **Leave the reader on its current page until you resume**: the next page is worked out from how many times → was pressed, so turning pages yourself (or reloading the tab) in between makes it skip or repeat pages. Running again without `--resume` asks whether to continue (in a terminal) or starts over.

The kept pages wait in a temporary folder that macOS may clear after a few days. Starting over moves them to the Trash rather than deleting them.

### Choosing a capture area

When asked, pick **1) Custom** to type `x`, `y`, width and height, or **2) Whole window**.

To measure, press **Cmd+Shift+4**: the crosshair shows the cursor position. Hover over the top-left corner of the page for `x` and `y`, then drag to the bottom-right corner to see the width and height. Press Esc to cancel without taking a screenshot. The numbers are measured from the top-left corner of the screen the reader is on, which is what `--region` expects too.

### Chrome

- Make the viewer the active tab of your most recently used Chrome window, and click once on the page before starting. If the address bar has focus, → won't turn pages.
- Whole-window capture includes the tab bar and address bar. Use a custom area, or full screen, to capture just the page.

## Image quality: why Retina matters

ebook-capture doesn't read the book file. It takes a picture of the reader window, exactly as the app draws it on screen, one page at a time. So a captured page can never be sharper than the page on your screen.

macOS sizes everything in *points* and draws each point with more or fewer pixels depending on the screen:

| Screen | Pixels per point | The same 900 × 1000 pt page is captured as |
|---|---|---|
| Regular monitor (e.g. 1920 × 1080) | 1 × 1 | 900 × 1000 px |
| Retina (e.g. a MacBook's built-in display) | 2 × 2 | 1800 × 2000 px |

An iPad screen is over 2000 px on its long side, so a 1× capture gets stretched and looks soft, while a 2× capture doesn't. Making the image bigger in software can't fix this: it would only stretch what the app drew at 1×.

To capture at 2×:

- **Capture on a Retina display.** If you use your MacBook in clamshell mode, open the lid and move the reader window to the built-in display just for capturing.
- **Use a HiDPI mode on an external monitor.** Tools such as BetterDisplay can make a 1080p monitor render at 2× (the desktop looks the same size, but apps draw with twice the pixels).
- **4K monitors** at a scaled resolution already render at 2×.

Also put the reader in **full screen** (Ctrl+Cmd+F): the title bar drops out of the capture and the page itself gets bigger.

## Design

See [docs/DESIGN.md](docs/DESIGN.md) (Korean) for the design decisions and what was tested.

## Development

A Swift package with no dependencies. Needs Xcode or the Command Line Tools (`xcode-select --install`).

```bash
swift build
swift test
swift run ebook-capture --help
```

End-to-end checks drive real apps, so run them from a terminal with the permissions above:

```bash
scripts/e2e.sh preview      # automatic, using a generated book in Preview
scripts/e2e.sh app 1        # your open book in 교보도서관 (2 for Chrome)
```

Releases: [docs/RELEASING.md](docs/RELEASING.md) (Korean).

## License

[MIT](LICENSE)
