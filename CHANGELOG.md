# Changelog

## Unreleased

## 0.1.0 - 2026-09-12

- Native macOS island with audio-driven orb and wave animation, speech bounce, and a shared fading close with a 20% swell.
- Local Piper speech with Jenny, Alan and Lessac voices, plus saved speed, sentence-pause and rhythm settings.
- Loopback HTTP speech and question APIs, bounded choices, required fallback answers and configurable 10 to 60 second deadlines.
- Compact answer buttons, hover glow and scrollable explanation bubbles that do not take keyboard focus.
- Automatic quiet delivery for active or unknown microphone input, plus manual Meeting mode for calls that release their input stream.
- Optional source titles and Herdr origin metadata, with a separate pi-orb connector.
- Recent messages submenu with the ten latest incoming messages, kept only in memory and replayed under current voice and quiet settings.
- Fixed repeated CoreAudio listener rebuilding on unchanged process lists and rejected callbacks from retired registrations.
- Native panel updates use committed state rather than stale queued snapshots. The Meeting mode checkbox keeps the menu open while toggling.
- Removed the island's top outline while preserving its side and bottom edges.
