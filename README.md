# SpaceMemory

A macOS window manager for wide screens. The window you're using stays in the center, and your other windows sit at the screen edges as small live previews.

Based on Scott Jenson's talk [Are we really going to use the same Desktop UX forever?](https://www.youtube.com/watch?v=V7AfAcQwLW0) from Akademy 2026.

![Focus mode, with one window in the center and cards on both edges](docs/images/focus-mode.svg)

This is a prototype. It's only been tested with simulated input, on one display, on macOS 26.

## Terms

| Term | Meaning |
| --- | --- |
| Focus mode | One window in the center, with all the others as cards |
| Focus area | The space between the edge columns |
| Main window | The window in the focus area |
| Card | A live, view-only preview of a window |
| Edge column | A stack of cards on the left or right edge |
| Deck | An edge column with overlapping cards, used when they don't all fit |
| Side zone | The part of the screen near each side where a dragged window shrinks |
| Docking | Turning a window into a card |
| Parking | Moving a docked window almost entirely off-screen |
| Promoting | Making a window the main window, which docks the previous one |
| Focused view | The main window sits between the edge columns |
| Full view | The main window fills the usable screen, and the edge columns hide |
| Reveal | Bringing back a hidden edge column by resting the cursor at that screen edge |

## Usage

### Dock a window

Drag a window into a side zone and release it near the edge. If you drag it back out first, it returns to full size.

![A window shrinking through the side zone and becoming a card](docs/images/drag-to-edge.svg)

### Start and end focus mode

| Action | Result |
| --- | --- |
| Shake a window by its title bar | Starts focus mode with that window as the main window |
| Shake the main window | Ends focus mode and restores every window's position and size |
| ⌃⌥⌘F | Starts focus mode, then switches between focused view and full view |
| Restore All Windows in the menu bar | Ends focus mode |

### Switch windows

| Action | Result |
| --- | --- |
| Click a card | Promotes that window |
| ⌘Tab or click in the Dock | Promotes that app's focused window |
| ⌘\` | Promotes another window of the same app |
| Open a window | Promotes the new window |
| ⌥Tab during focus mode | Returns to the last window. Hold ⌥ and keep pressing Tab to go further back. |

Hover over a deck to lift a card out of it.

### Use full view

Press ⌃⌥⌘F, or drag the window to go back to focused view.

![Focused view and full view side by side](docs/images/full-view.svg)

A column also hides when the front window covers more than half its width, including in native full screen. A card you just docked stays visible until the cursor leaves its column.

### Drag content between windows

During focus mode, drag a file, text or an image and do one of these:

- Hold it over a card for about half a second to promote that window, then drop it there.
- Press ⌘Tab or ⌥Tab to switch windows, then drop it.

Cards refuse drops.

## Install

You need macOS 14 or later, and Xcode or the Swift command line tools.

```bash
./scripts/build.sh
```

```bash
open build/SpaceMemory.app
```

The app runs in the menu bar. In **System Settings > Privacy & Security**, turn it on under:

- **Accessibility**, to move and resize windows
- **Screen & System Audio Recording**, to show previews. It doesn't capture audio.

To change the shortcut, choose **Change Shortcut…** in the menu bar. Quitting from the menu bar restores all windows.

## How it works

macOS doesn't let an app scale another app's window. A card is a floating panel showing a ScreenCaptureKit stream of the window, and the real window is parked at the bottom-right corner of the desktop.

| File in `Sources/` | Purpose |
| --- | --- |
| `SpaceMemory/main.swift` | Launcher that loads the library. Changing it means granting permissions again. |
| `SpaceMemoryCore/WindowManager.swift` | Docking, focus mode, switching, decks and hidden columns |
| `SpaceMemoryCore/WindowCapture.swift` | Preview streams and card panels |
| `SpaceMemoryCore/AXWindow.swift` | Moving windows with the Accessibility API |
| `SpaceMemoryCore/EventTap.swift` | System-wide mouse events |
| `SpaceMemoryCore/ShakeDetector.swift` | Shake detection |
| `SpaceMemoryCore/Shortcut.swift` | Global shortcuts and the Change Shortcut window |
| `SpaceMemoryCore/Support.swift` | Screen geometry, card size and logging |
| `SpaceMemoryCore/App.swift` | App startup and the menu bar |
| `SpaceMemoryCore/Checks.swift` | Automated checks |

## Automated checks

The checks take over the mouse and keyboard and move real windows, so don't use the computer while they run. Results go to `~/Library/Logs/SpaceMemory.log`, and images to `~/Library/Logs/SpaceMemory-checks/`.

```bash
open -n build/SpaceMemory.app --args --check-gestures TextEdit --check-switching TextEdit,Safari --quit-after-checks
```

| Flag | Covers |
| --- | --- |
| `--check-gestures Apps` | Docking, shake, decks and hover |
| `--check-switching App1,App2` | Switching windows and full view |
| `--check-fullview App` | Full view, hidden columns and native full screen |
| `--check-drag Chrome,TextEdit` | Dragging content. Needs `Resources/drag-test-page.html` open in Chrome and a TextEdit file named `drag-target`. |
| `--check-dropped-card` | Docking under a large window. Needs the same page in Chrome and a TextEdit file named `snap-test`. |
| `--check-shortcut set`, then `verify` | Changing the shortcut across a restart |

## Known limits

- You can't click into a card or drag content out of one.
- Outside focus mode, windows can overlap as usual.
- Cards don't update while you're in another Space, and windows on other Spaces aren't managed.
- In native full screen, clicking a card switches you to the desktop.
- Multiple displays are untested.
- macOS doesn't report shortcut clashes, so if another app uses the same shortcut, both respond. ⌥Tab can't be changed.
- In the checks, shaking a Chrome window failed after it left native full screen. This hasn't been tried by hand.
- A window covering less than half of a column doesn't hide it, so cards can overlap that window.
- The app is signed for local use only. Sharing it would need a Developer ID and notarization. It can't go on the App Store because of the sandbox and one private API.
