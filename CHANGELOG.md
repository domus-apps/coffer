# Changelog

All notable changes to Coffer are documented here. The release workflow publishes each version's section as the GitHub release notes and embeds it in the Sparkle appcast, so the in-app update dialog shows the same notes. A release fails early if its version has no section here.

Keep each bullet on a single line: release notes render line breaks literally (both on GitHub and in the update dialog), so wrapped lines would break mid-sentence.

## 1.3.2

### Fixed

- The app icon's background looked flat in the Dock and Finder. It now shows its gradient.

## 1.3.1

### Fixed

- Closing Settings or the welcome window now returns you to the app you were using, so other apps' shortcuts keep working right away.

## 1.3.0

### Added

- Coffer can launch at login, from Settings.
- The menu bar icon can be hidden, from Settings. With it hidden, ⌥⌘C still opens the history, and launching Coffer again opens Settings.
- A trash button beside the search field clears the whole history, after asking once.

### Changed

- Settings is laid out in grouped sections, like System Settings.

### Fixed

- ⌘W closes and ⌘Q quits from the Settings window.
- Text on the highlighted row in the welcome window is readable with a yellow accent color.

## 1.2.6

### Fixed

- Fixed steady processor use that began once Settings had been opened and went on after the window was closed.

## 1.2.5

- Moving through a long list with the arrow keys keeps the highlighted entry clear of the top and bottom fades instead of tucking it underneath.

## 1.2.4

### Added

- Spotlight now finds the app by its Korean name and by what it does: 코퍼, 커퍼, 클립보드, and clipboard all match.

## 1.2.3

### Fixed

- The card behind the coffer's front showed through as a sharp transparent silhouette in the dark-mode icon. The front now declares a blur material, so the card diffuses through it as a frosted glow, matching the light appearance.

## 1.2.2

### Fixed

- The dark-mode icon lost its glass entirely. The previous fix dimmed the box image instead of declaring materials. The icon document now declares real Liquid Glass (specular highlights, and a translucent frosted box that blurs the card sinking behind it), so every appearance keeps the see-through story.

## 1.2.1

### Fixed

- The dark-mode app icon rendered the coffer's front as a near-opaque slab, hiding the card sinking into it. The front pane now carries the suite's translucent-glass alpha, so the dark variant keeps its see-through story.

## 1.2.0

### Added

- The clipboard history now survives restarts: it is saved to an owner-only file under ~/Library/Application Support/Coffer and restored at launch. Concealed (password manager) items were never recorded, so nothing secret lands on disk.
- A Settings window (menu bar icon → Settings…) where the history cap is configurable, from 10 to 1,000 items, 200 by default, with a reset button. Lowering the cap removes the oldest items immediately. The bounds exist because the whole history, images included, lives in memory.

### Changed

- The history panel's top fade now hugs the search field, like the System Settings sidebar, and scrolled items show through beneath the field with a frosted-glass blur.

### Fixed

- Rows at the bottom of the history panel no longer crop against an invisible boundary floating above the card's bottom edge. They dissolve into the edge itself.

## 1.1.1

- Fixed: installing by COPYING the app (instead of Finder-moving it) left it running from Gatekeeper's translocated read-only path, which blocked Sparkle updates. The app now detects this at launch, clears the quarantine flag, and relaunches itself from its real location.

## 1.1.0

### Added

- First-run onboarding that introduces the history palette and its ⌘⌥C shortcut.

## 1.0.0

- Initial release: everything you copy, kept in a searchable history. Press ⌘⌥C for a Liquid Glass palette, type to filter, and Return (or double-click) copies the selection back.
- Images and file copies are kept too, with thumbnails (QuickLook previews for files). Re-copying restores the original bytes or the files themselves, not a rendering.
- The palette is resizable from its edges, remembers its size, dissolves rows softly under its sticky search field, and supports right-click Copy / Delete per item.
- Password manager entries (concealed pasteboard items) are never recorded, and the history stays in memory only.
- Sparkle keeps the app up to date.
