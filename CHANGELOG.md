# Changelog

All notable changes to Coffer are documented here. The release workflow publishes each version's section as the GitHub release notes and embeds it in the Sparkle appcast, so the in-app update dialog shows the same notes. A release fails early if its version has no section here.

Keep each bullet on a single line: release notes render line breaks literally (both on GitHub and in the update dialog), so wrapped lines would break mid-sentence.

## 1.1.1

- Fixed: installing by COPYING the app (instead of Finder-moving it) left it running from Gatekeeper's translocated read-only path, which blocked Sparkle updates — the app now detects this at launch, clears the quarantine flag, and relaunches itself from its real location.

## 1.1.0

### Added

- First-run onboarding that introduces the history palette and its ⌘⌥C shortcut.

## 1.0.0

- Initial release: everything you copy, kept in a searchable history — press ⌘⌥C for a Liquid Glass palette, type to filter, and Return (or double-click) copies the selection back.
- Images and file copies are kept too, with thumbnails (QuickLook previews for files) — re-copying restores the original bytes or the files themselves, not a rendering.
- The palette is resizable from its edges, remembers its size, dissolves rows softly under its sticky search field, and supports right-click Copy / Delete per item.
- Password manager entries (concealed pasteboard items) are never recorded, and the history stays in memory only.
- Sparkle keeps the app up to date.
