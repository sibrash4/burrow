# Product

<!-- impeccable:product-schema 1 -->

## Platform

ios

Note: the real target is native macOS (SwiftUI, macOS 14+, Apple Silicon). The schema has no `macos` value; `ios` is the nearest Apple-native value so Apple HIG guidance applies. Follow macOS HIG (window, sidebar, toolbar, pointer), not iPhone conventions.

## Stack

Native SwiftUI app, Swift Package / Xcode project, no third-party dependencies. Shells out to the Homebrew-installed Mole CLI (`mo`, currently 1.59.1). User chose this over Rust (Tauri/egui).

## Users

One person (the owner) on their own Mac. Comfortable with a terminal but wants a GUI for routine cleanup: open it, see what is taking space, pick what goes, clean, quit. Used occasionally (weekly or when disk is tight), not all day.

## Product Purpose

Burrow is a small, native GUI over Mole. It exists because Mole's own GUI (Mole for Mac) is paid and closed source, and the CLI is fine but not pleasant for reviewing and picking items. Success: a scan-pick-clean cycle takes under a minute, nothing is deleted that the user did not see first, and the app stays tiny and fast.

## Positioning

Every delete goes through Mole's own audited safety layer (protected paths, symlink checks, live-cache guard, Trash-first uninstall). Burrow adds review and selection, never its own deletion logic. Unlike PureMac or MacSai, it has no cleaning engine of its own to trust.

## Operating Context

- Mole installed via Homebrew at `/opt/homebrew/bin/mo`.
- Some Mole cleanup needs `sudo`; v1 skips sudo-only items and says so.
- Mole output is human terminal text, not JSON, except `mo uninstall --list` and `mo history --json`. Purge and installer selection is an interactive terminal menu.

## Capabilities and Constraints

v1 jobs, all via `mo`:
- **Clean**: caches, logs, browser, developer and app junk (`mo clean`). Preview first.
- **Purge**: project build artifacts like `node_modules`, `.next`, `dist`, `.venv` (`mo purge`).
- **Installers**: leftover `.dmg`, `.pkg`, `.zip` installers (`mo installer`).
- **Uninstall**: remove apps and their leftovers (`mo uninstall`), to Trash by default.

Interaction: always preview, then let the user untick individual items, then confirm. Window app with a sidebar. No menu bar item, no scheduling, no auto-clean in v1.

Constraints: no telemetry, no network calls. Never use `--permanent`. Do not use the Mole name or logo as Burrow's identity (Mole TRADEMARK.md); "a GUI for Mole" in descriptions is fine.

## Brand Commitments

Name: Burrow. User wants it "clean, modern, does what it needs to, nothing fancy".

## Evidence on Hand

Real dry-run captures of this Mac in `_research/` (clean, purge, installer, history JSON). No users, testimonials, or metrics exist; do not invent any.

## Product Principles

1. Mole decides what is safe; Burrow only shows and asks.
2. Nothing goes without being seen: preview, pick, confirm.
3. Small and fast beats feature-rich.
4. Plain words and real numbers (GB freed), no fear badges or fake urgency.

## Accessibility & Inclusion

Standard macOS: VoiceOver labels on all controls, keyboard navigation, Dark Mode and Increase Contrast respected.
