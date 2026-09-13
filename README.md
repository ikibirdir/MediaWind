# MediaWind

A fast, native photo and video viewer for macOS. It's meant to replace Preview for photos:
double-click a photo in Finder, it's on screen in a fraction of a second, and ← → flip
through every photo and video in that folder. No library, no file browser, no editing.

- Native Swift (AppKit, ImageIO, AVKit), no third-party code, no network access.
- One window. Opening another file while it's running reuses the window.
- Targets macOS 26 (built and tested on macOS 26.6.2, Apple silicon, Command Line Tools only).

## Install

MediaWind is built from source. It takes about a minute and needs no Apple developer account.

1. **Requirements:** macOS 26 or later and Apple's Command Line Tools (or Xcode). If you don't
   have them, run `xcode-select --install` in Terminal and follow the prompt.
2. **Build and install:**

   ```sh
   git clone https://github.com/ikibirdir/MediaWind.git
   cd MediaWind
   ./build.sh --install
   ```

   This puts `MediaWind.app` in /Applications. Because you built it yourself, macOS opens it
   without a Gatekeeper warning.
3. **Use it:** right-click a photo in Finder ▸ Open With ▸ MediaWind, or make it the default
   viewer (see below).

To update later: `git pull && ./build.sh --install`.

## Build details

```sh
./build.sh --install     # build, copy to /Applications, register with LaunchServices
./build.sh               # build only: .build/app.noindex/MediaWind.app (never used by Finder)
./test.sh                # unit tests for the folder/sort/navigation logic (MediaWindCore)
```

`build.sh` runs `swift build -c release`, wraps the binary in `MediaWind.app` (Info.plist,
bundle ID `com.ikibirdir.MediaWind`, ad-hoc code signature), and with `--install` quits a
running copy, replaces `/Applications/MediaWind.app`, registers it with `lsregister`, and
unregisters every other copy. The build copy lives in a `.noindex` folder and is unregistered,
so Finder always opens the installed app.

Rebuilding and reinstalling is the same command. To uninstall, delete
`/Applications/MediaWind.app` (and restore your defaults first, see below).

The first time MediaWind browses a folder in Desktop, Documents, Downloads or on an external
drive, macOS asks for permission. Click **Allow**. If you denied it, MediaWind still shows the
file you opened and offers a button to the right Privacy & Security page.

## Making it the default (and undoing that)

MediaWind never changes your defaults on its own. It only registers as an *alternate* viewer,
so it shows up in Finder's **Open With** menu.

- **Make it the default:** MediaWind ▸ Default Viewer ▸ *Make MediaWind the Default for
  Photos…* (and/or *…for Videos…*). The welcome window, shown when you launch MediaWind without a
  file, has the same buttons. It covers JPEG, HEIC/HEIF, PNG, GIF, TIFF, BMP, WebP, AVIF,
  JPEG 2000, ICO and common camera RAW formats. For videos it covers MP4, MOV, M4V and 3GP.
- **Undo:** MediaWind ▸ Default Viewer ▸ *Restore Preview and QuickTime Player…*

macOS asks you to confirm each change: it shows a small system panel per file type, and the
change only takes effect once you click it. The panels can end up stacked behind other windows,
so look for them if nothing seems to happen. A command-line script can't do this instead — the
request is dropped when the script exits, even though the API reports success.
- **By hand, per file type:** in Finder, select a file ▸ Get Info ▸ *Open with* ▸ pick an app ▸
  *Change All…*

PDFs are never claimed. Preview keeps those.

## Keyboard shortcuts

| Keys | Action |
|---|---|
| ← / → | Previous / next photo or video (stops at the first/last) |
| fn← / fn→ (Home / End) | First / last |
| Hold → or ← | Fly through quickly (fast previews), full quality when you let go |
| Hold → or ← on a video | Fast-forward / rewind at 3× until you let go (a tap still moves on) |
| ⌘+ (or ⌘=) / ⌘− | Zoom in / out |
| Pinch | Zoom |
| ⌘0 | Zoom to fit |
| ⌘1 | Actual size (1 image pixel = 1 point, like Preview) |
| Double-click (or two-finger double-tap) | Toggle fit / actual size |
| Drag | Pan when zoomed in |
| F or ⌃⌘F | Toggle full screen |
| Esc | Leave full screen, or close the window (which quits) |
| Space | Play / pause video |
| M | Mute / unmute videos |
| ⌘O | Open… (files or a folder) |
| ⇧⌘O | Open in Preview (to crop, mark up or print) |
| ⇧⌘R | Show in Finder |
| ⌘C | Copy the file |
| ⌘W | Close |
| ⌘/ | Show this list |

Every command is also in the menu bar.

### Browsing order

By default (View ▸ Sort By ▸ **Follow Finder**) MediaWind browses in the order Finder shows the
folder in, so ← → match what you see in the Finder window. It reads the folder's view settings
from the `.DS_Store` file Finder keeps (in the folder itself, or in its parent under the folder's
name), falling back to Finder's global view preferences, and finally to name order.

Finder's orders are all supported: Name, Kind, Date Created, Date Modified, Date Added, Date Last
Opened and Size, in the same direction Finder uses (names and kinds A→Z, dates newest first,
biggest files first), with the name as tie-break. Picking any of them from the Sort By menu stops
following Finder and is remembered; **Reverse Order** flips the direction. Name order is natural
like Finder's: IMG_2 before IMG_10.

Arrangements with no equivalent here (manual/grid, tags, labels) fall back to name order.

## Features

- Finder ▸ Open With ▸ MediaWind opens straight into the photo, with no welcome window flash.
  Launching without a file shows a small welcome window with Open… and the default-app buttons.
- The opened file shows first. The folder is listed in the background, then the title fills in
  the position ("IMG_1234.HEIC — 12 of 348"). Measured on this machine: from a cold start, the
  photo is on screen about 0.1 s after Finder's open request (about 0.3 s after the process
  starts); when MediaWind is already running, 20–100 ms. A 5,000-file folder is listed and
  sorted in 0.25–0.35 s in the background.
- Opening files while the app runs shows them in the same window. Opening several files at once
  browses just those.
- Photos are decoded off the main thread at the window's pixel size, and at full resolution only
  when you zoom past that. EXIF orientation is honored. Neighbors are preloaded in the direction
  you're going, and only a few decoded images are cached (with a memory budget and memory-pressure
  purge).
- Holding an arrow key shows embedded thumbnails while flying and full quality once you let go.
- Videos (AVKit) autoplay muted with standard controls. Space plays/pauses. Moving away stops
  them, sound included. Unmuting carries over to the next video until you quit.
- On a video, holding → or ← for a moment fast-forwards or rewinds at 3× with a "3×" badge, and
  goes back to normal speed (or stays paused) when you let go. A quick tap still moves to the
  next/previous item, on release. Videos AVFoundation can't play that fast backwards are scanned
  by seeking instead.
- Animated GIF/PNG/WebP animate.
- Dark window. Media is scaled down to fit and small images aren't enlarged past 100%. Hover
  arrows appear at the edges. In full screen, a name/position overlay fades when the mouse is
  idle, and so does the cursor.
- Hidden files and `._*` AppleDouble files are skipped. Files deleted or renamed while you browse
  are skipped quietly.
- Anything that can't be shown (e.g. `.mkv`, `.webm`, damaged files) gets a message with
  **Show in Finder** and **Open With ▸** (other apps only, never MediaWind itself).
- If macOS denies folder access, MediaWind shows the opened file and a banner with a button to
  Privacy & Security ▸ Files and Folders.
- ← → / Space / Esc / F are handled at the window level, so they work immediately after opening
  and while a video has the player's controls.

## Not included

- Editing, rotating, deleting, printing: use File ▸ Open in Preview.
- Sorting by EXIF capture date (date modified only), slideshow, looping videos.
- Live folder watching: files added after you opened the folder appear the next time you open a
  file there. Deleted ones are skipped when you reach them.
- HDR rendering: HDR photos and videos are shown in standard dynamic range.

## Known limitations

- **Privacy prompts after rebuilding:** the app is ad-hoc signed, and macOS ties folder
  permissions to the exact signature, so a rebuilt/reinstalled MediaWind may ask for
  Desktop/Documents/Downloads access again.
- **Video formats** are whatever AVFoundation plays: MP4/MOV/M4V (H.264, HEVC, ProRes) and some
  AVI. WebM, MKV, WMV and FLV show the "can't play" message.
- **Actual size** is 1 image pixel per point (like Preview and Quick Look). On a Retina display
  that's 2×2 screen pixels per image pixel.
- Multi-page TIFFs and HEIC image sequences show their first image.
- Camera RAW support is whatever macOS supports. Unsupported cameras get the message.
- The window is not restored between launches (by design: each launch shows what Finder asked for).

## Troubleshooting

**"Apple could not verify “photo.jpg” is free of malware…", and afterwards the photo won't open
in any app.** This is macOS behavior, not specific to MediaWind (it also happens with TextEdit,
browsers and office apps). It hits *flagged* files that you open through Open With ▸ Other…,
especially with **Always Open With** checked, which writes a per-file app binding (so does Get Info
▸ Open with without *Change All*).

- *Flagged* means the file carries macOS's quarantine flag. Browsers set it on downloads, e.g.
  photos from a Google Takeout zip.
- Sandboxed apps like Preview and QuickTime Player also set it on files they open, so a photo you
  once viewed in Preview counts as flagged.

macOS treats a flagged file that insists on a particular app the way it treats a downloaded
program: Gatekeeper vets it, finds no signature and blocks it. Dismissing the dialog records a
rejection, so every app refuses the file afterwards. The file itself is fine. The file's execute
bit plays no role.

To check and fix a folder (file contents aren't changed):

```sh
find "FOLDER" -xattrname com.apple.LaunchServices.OpenWith   # files with a per-file binding
find "FOLDER" -xattrname com.apple.LaunchServices.OpenWith \
     -exec xattr -d com.apple.LaunchServices.OpenWith {} +  # remove the bindings
find "FOLDER" -xattrname com.apple.quarantine \
     -exec xattr -d com.apple.quarantine {} +             # clear the downloaded flag (trusted files only)
```

To avoid it, don't use *Always Open With* on downloaded files. MediaWind ▸ Default Viewer and
Get Info ▸ Open with ▸ *Change All…* set a default per file type instead of binding single files.

## Two-minute manual test

Generate test media first (it goes into `TestMedia/`, which git ignores):

```sh
scripts/make-testdata.sh           # ~300 files: many sizes and formats, EXIF-rotated, GIF, videos, junk
scripts/make-testdata.sh --large   # 5,000 files (APFS clones, almost no disk space) in TestMedia-Large/
```

1. In Finder, right-click `TestMedia/IMG_3.jpg` ▸ Open With ▸ MediaWind. It appears almost
   instantly, with no welcome window, and the title says "IMG_3.jpg — 3 of 300". (Allow folder
   access if asked.)
2. Press → a few times without clicking anything. IMG_4 is small and shown at its real size, not
   enlarged. IMG_5 and IMG_6 are videos that autoplay muted. Press → while a video plays: it moves
   on and the sound stops.
3. On a video, press Space to pause/resume and M to unmute. Hold → for a second: it plays at 3×
   with a "3×" badge, then normal speed when released. Hold ← to rewind. A quick tap moves on.
4. IMG_7 animates. IMG_8 and IMG_9 show an upright ✓ (EXIF rotation). IMG_11 shows "Can't
   display" with Show in Finder / Open With.
5. Hold → for two seconds: pictures fly by, and are sharp once you release. Press fn→ (End) and
   fn← (Home).
6. On a big photo (IMG_15): pinch or ⌘+, drag to pan, double-click, ⌘0. Moving to the next photo
   resets to fit.
7. Press F: full screen. Move the mouse and the name/position overlay shows, then fades with the
   cursor. Press Esc to leave full screen.
8. With MediaWind open, open a photo from another folder in Finder: same window, new folder.
   Select three photos in Finder and Open With ▸ MediaWind: "1 of 3".
9. View ▸ Sort By ▸ Date Modified: the position changes. Quit and reopen: still by date.
10. Open `IMG_101_h264.mkv`: the "Can't play" message, and Open With lists other apps but never
    MediaWind.
11. File ▸ Open in Preview opens the current photo in Preview.
12. Press Esc (not in full screen): the window closes and the app quits. Launch MediaWind from
    /Applications: the welcome window.

## Project layout

```
Package.swift                      Swift package (Swift 5 language mode), macOS 26
Sources/MediaWindCore/             plain Swift, no UI: classify, scan, natural sort, prev/next
Sources/MediaWind/                 AppKit app
  AppDelegate.swift                launch/open handling, welcome window, Open…
  ViewerWindowController*.swift    the viewer window: navigation, keys, display, video, menus
  ImageLoader.swift                ImageIO decoding (preview / fit / full), cache, preloading
  ImageScrollView.swift            zoom, pan, fit/actual size
  OverlayViews.swift               hover arrows, full-screen overlay, messages, banner
  MainMenu.swift, DefaultApps.swift, WelcomeView.swift (SwiftUI), Perf.swift, DebugHook.swift
Tests/MediaWindCoreTests/          Swift Testing unit tests (./test.sh)
Resources/Info.plist               document types (Viewer, Alternate), privacy usage strings
build.sh, test.sh, scripts/        build/install, tests, test media, test driver
```

### Automated UI checks

Timing logs: `log stream --predicate 'subsystem == "com.ikibirdir.MediaWind"'`.

For scripted checks without Accessibility or Screen Recording permission, launch with
`open --env MEDIAWIND_DEBUG=1 -a /Applications/MediaWind.app <file>`. The app then accepts
commands from `scripts/mwdebug.swift` (build it with `swiftc -O scripts/mwdebug.swift -o
.build/mwdebug`): inject keys, send menu commands (e.g. `"action changeSortOrder: 1"`), dump
window state as JSON, and render a snapshot. The hook is off in normal launches.

## License

MIT. See [LICENSE](LICENSE).
