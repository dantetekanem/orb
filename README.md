# Orb

A native Swift macOS prototype that speaks messages sent by any agent. A notch-style island expands around a luminous orb, with flowing wave ribbons driven by the speech audio. Pi can call it with curl; Orb has no Pi dependency.

SwiftUI and AppKit draw the island. Swift Network handles the local API. AVAudioPlayer plays the audio; energy and low/high animation bands follow its playback clock. The whole island subtly flexes with the voice. Motion respects Reduce Motion, and the shared frame loop pauses when closing begins.

Speech uses Piper, with `en_GB-jenny_dioco-medium` as the default voice. Piper is an external local TTS subprocess, not an assistant or server. No LLM, microphone recording or cloud inference. The last ten incoming messages stay in memory for manual replay.

## Installation

Requires macOS 15 or later, an Xcode 16-or-newer Swift toolchain with the macOS SDK, Git, [uv](https://docs.astral.sh/uv/getting-started/installation/), and Python 3.12. The voice runtime is not included in the repository. With Homebrew installed, you can get uv and Python with:

```sh
brew install uv python@3.12
```

Then clone the source, set up the voices, and build the app:

```sh
git clone https://github.com/dantetekanem/orb.git
cd orb
bash scripts/setup-voice.sh
bash scripts/build-app.sh
open dist/Orb.app
```

The setup script requires an existing Python 3.12; it does not download Python automatically. It installs pinned dependencies into `.runtime/venv`, downloads Jenny (63 MB), Alan (63 MB) and Lessac high-quality (114 MB), and verifies their checksums. It does not launch Orb or play sound. The build creates a locally signed app under `dist/`.

Launching the app starts `127.0.0.1:45821`. Use the waveform menu-bar icon for **Try Orb**, **Recent messages**, **Stop speaking**, **Meeting mode**, **Settings**, and **Quit Orb**. There is no automatic startup registration. The island uses a notched display when available; otherwise it appears below the primary display's menu bar. It does not take keyboard focus.

Keep `dist/Orb.app` in this checkout, rather than moving it into Applications: the prototype resolves `.runtime/` relative to the bundle. This is not a self-contained, notarized distribution. If you move the checkout, recreate `.runtime/venv` before running setup again because its executable paths are absolute. For development, run `swift run Orb` from the project root. `ORB_RUNTIME` can override the runtime path when launching the executable directly.

### Connect Pi

Install the separate [pi-orb connector](https://github.com/dantetekanem/pi-orb), then run `/reload` in Pi or start a new session:

```sh
pi install git:github.com/dantetekanem/pi-orb
```

It adds `orb_say` and `orb_ask`. Keep Orb running separately; the connector does not launch the app or install its voices. Other agents can use the HTTP API directly.

## Voice settings

Open **Settings** from Orb's waveform menu-bar icon. Choose Jenny (British, the factory default), Alan (British), or Lessac (American, high quality), then use **Preview voice** to hear it.

- Speaking speed: 0.65× to 1.45×, mapped to Piper's inverse length scale.
- Sentence pause: 0 to 0.8 seconds of extra silence between sentences.
- Rhythm variation: 0 to 1.2, mapped to Piper's phoneme timing variation (`noise-w-scale`), not a separate prosody model.

Settings are saved locally in macOS preferences for `local.orb.app`. Changes affect the next message or preview, not the current utterance. Reset restores Jenny, 1× speed, no extra sentence pause and 0.8 rhythm variation.

## Recent messages

Open **Recent messages** in the menu to replay one of the ten newest incoming messages. History lasts only until Orb quits; it is not written to disk or exposed through the API. Replay preserves the original text, title and source, uses your current voice settings and quiet policy, and does not duplicate or reorder history.

Replaying a question delivers only its question text, without reopening choices or answering the original request. Like a new message, replay replaces any current speech or waiting question.

## Quiet delivery during calls

Orb checks CoreAudio input activity automatically. Any active input stream—or an unavailable/incomplete check—uses a silent notice instead of speech. This also covers unrelated microphone use, such as recording or dictation; Orb does not record or request microphone access.

For **Meet, Tuple, Teams and Zoom**, turn on **Meeting mode** in the menu or Settings when joining a muted or listen-only call. Some calls release their input stream when muted, so microphone activity alone cannot identify every meeting. The Meeting mode checkbox can be toggled without closing the menu. It always stays silent, including previews and replays, and is saved separately from voice settings. Reset does not turn it off. Individual conferencing clients have not been live-tested.

The gate checks before synthesis and immediately before playback. If input becomes active or unknown, or Meeting mode is enabled, Orb stops its owned speech and shows the notice once. It never automatically resumes or repeats that message when the microphone becomes idle. Notifications are asynchronous; a transition can race playback, so this is not a zero-audible-sample guarantee.

A silent message shows its source and brief text for five seconds; hover for the full text. A silent question immediately shows its choices and question, without waiting for speech. The existing default/deadline applies. Both use the same nonactivating island, without notification sounds or focus changes.

## API

```sh
curl --fail-with-body http://127.0.0.1:45821/speak \
  -H 'Content-Type: application/json' \
  -d '{"text":"Your work is ready. Take a look when you have a moment.","source":"Pi"}'

curl http://127.0.0.1:45821/status
curl -X POST http://127.0.0.1:45821/stop -d ''
```

`text` is required (1 to 2000 characters). `source` is optional (1 to 32; defaults to `Agent`). Send plain spoken text: Orb does not summarize or rewrite it. The island shows the orb, waves, Stop control and an optional tiny source title. Full speech text and state remain available to VoiceOver.

Both `/speak` and `/ask` accept an optional `title` (1 to 24 characters, trimmed, no controls), such as `"Herdr 1:3"`. It appears below the orb and is not spoken. Omitting it leaves the speaking island without visible text. Silent notices use `source` when no title is supplied.

Optional `source_context` preserves origin data: `{"kind":"herdr","workspace_id":"w1","tab_id":"w1:t1","pane_id":"w1:p3"}`. Workspace IDs are limited to 32 characters and tab/pane IDs to 64, using letters, digits, `_`, `-` and `:`. Tab and pane IDs must belong to that workspace. This metadata does not execute commands or switch applications.

`POST /speak` returns HTTP 202 with an `id`, `state: "preparing"` and `delivery: "voice"`, or `state: "notifying"` and `delivery: "silent"`. This acknowledges acceptance, not completed playback. A valid new message or question replaces the current one. `/status` reports `idle`, `preparing`, `speaking`, `choosing`, `notifying`, `settling`, or `failed`, with the active ID when present; it never returns message text. It also returns string values for `meeting_mode` (`true`/`false`), `input_activity` (`active`/`inactive`/`unknown`) and `delivery` (`voice`/`silent`/`none`). Inactive input does not mean no meeting is in progress. Voice, speed, pause and rhythm reflect the current utterance's settings while active, otherwise the settings for the next message. `/stop` cancels speech or a waiting question and closes the island. Playback failures appear in the menu-bar status; `/status` includes error details.

Piper loads the model and generates a bounded WAV before playback, so startup is not instant. The API reports `preparing` during that interval. Temporary text/audio files use a private per-message directory and are removed during normal completion or cancellation. An abrupt crash can leave that directory in the system temporary folder.

### Ask and return a choice

```sh
curl --fail-with-body --max-time 65 http://127.0.0.1:45821/ask \
  -H 'Content-Type: application/json' \
  -d '{
    "question": "Which approach would you prefer?",
    "source": "Pi",
    "default_answer_id": "pause",
    "timeout_seconds": 30,
    "answers": [
      {"id":"prototype","label":"Build the prototype","summary":"Try the smallest working version.","detail":"Keep the scope local and test the interaction before adding integrations."},
      {"id":"pause","label":"Do nothing","summary":"Leave things as they are.","detail":"The caller should take no action for this choice."}
    ]
  }'
```

When voice is allowed, Orb speaks **only the question**, then shows narrow, label-only glass choices below the orb. Click to choose; hover an explained choice to open a glass bubble with an arrow on its right. Move into the bubble to read and scroll longer explanations. It falls back to the left near a screen edge, stays nonactivating, and closes when you leave or the question ends. Choices brighten with a soft mint glow on hover. Longer lists scroll inside the bounded deck. The island stays nonactivating; no keyboard input is required. Content is plain text, not commands or Markdown.

Two choices with labels up to 20 characters and a question up to 160 characters use a compact horizontal row, with the question underneath. Their explanations are available on hover. Longer questions, labels, or lists use the vertical deck.

`question` and `source` have the same limits as speech text and source. Supply 2 to 6 answers with unique `id` (1 to 64 characters) and `label` (1 to 80). `summary` (up to 200) and `detail` (up to 2000) are optional; plain yes/no choices need only IDs and labels. Strings are trimmed; NUL is rejected, and IDs, labels and source also reject control characters. The complete JSON body must fit within 16,384 UTF-8 bytes.

`default_answer_id` is required and must match one of the supplied answer IDs. A do-nothing fallback is an ordinary choice the caller supplies. `timeout_seconds` is an integer from 10 to 60, defaulting to 30. It starts when Orb accepts the complete valid request, including voice preparation and playback. This is an API deadline only, with no visible countdown.

The request waits on the **same connection**, without polling:

- HTTP 200: `{"id":"question UUID","state":"answered","answer_id":"prototype"}`.
- HTTP 409: `{"id":"question UUID","state":"cancelled","reason":"stopped"}`. A new valid `/ask` or `/speak` uses reason `replaced`. Invalid requests leave the current question alone.
- HTTP 503: `{"id":"question UUID","state":"failed","error":"reason"}` if speech cannot finish; no answer cards appear.
- HTTP 200 on timeout: `{"id":"question UUID","state":"answered","answer_id":"pause","reason":"timeout"}`. Orb stops any remaining speech and returns the required default ID. The reason distinguishes this fallback from a click.

Closing the client connection cancels its question. Keep both TCP directions open while waiting: half-closing or sending extra request data abandons the interaction. Quitting Orb closes waiting connections, which may end without an HTTP response. Only deadline expiry uses the default; stop, replacement, disconnect and voice failure do not choose an answer.

## Local access

This prototype trusts processes on your Mac: there is no API token or per-user authentication. Any local process able to reach the port can make it speak, ask, replace or stop. Do not send sensitive text where someone might hear or see it. Choosing an answer returns its ID to the requesting process; Orb does not execute an action on its behalf.

The listener binds only to `127.0.0.1`, requires the numeric Host, rejects browser Origin headers, and requires JSON for `/speak` and `/ask`. Requests use bounded HTTP/1.1 Content-Length framing, without chunking or pipelining. There are at most eight open connections. Ordinary and incomplete requests have a three-second lifetime; accepted questions use their 10–60 second deadline, with up to three seconds to send its fallback response. There is no persistent message log or remote endpoint. The menu's ten-message history remains in memory only.

## Focused checks

```sh
swift test --filter 'ExplanationHoverTests|MeetingModeTests|InputActivityTests|SourceContextTests|QuestionTests|ContractTests|AudioEnvelopeTests|PiperJobTests|VoiceSettingsTests'
```

These checks do not launch Orb, query live input activity, listen on a port, or produce sound. Fake input, synthesis and playback boundaries cover quiet gating, the post-synthesis check, interruption and no automatic replay. Focused regressions cover duplicate input-list notifications without listener rebuilding, retired callbacks, committed panel state, and bounded manual replay under current settings. They also cover hover handoff, stale explanation callbacks, screen-bounded bubble placement, request boundaries, question-only speech payloads, choice/default/deadline validation and exactly-once click or timeout replies, replacement/stop state, stale events, audio envelope behavior, preference validation/serialization and the actual parameters sent to the owned synthesis subprocess. Compilation and those tests do not establish animation smoothness or subjective voice quality; those need a live demo.

## Versioning

`package.json` tracks the project version; it does not make Orb a Node application or require a JavaScript install. For a new version, update it together with `CFBundleShortVersionString` in `Resources/Info.plist`, increment `CFBundleVersion`, and record the changes in [CHANGELOG.md](CHANGELOG.md).

## Sources and voice licensing

The original repository code is [MIT licensed](LICENSE). Piper and the downloaded voice models are separate dependencies with their own licenses; the MIT license does not replace those terms.

- [Piper CLI](https://github.com/OHF-Voice/piper1-gpl/blob/main/docs/CLI.md), an external GPL-3.0 speech engine.
- Voice model cards: [Jenny](https://huggingface.co/rhasspy/piper-voices/blob/v1.0.0/en/en_GB/jenny_dioco/medium/MODEL_CARD), [Alan](https://huggingface.co/rhasspy/piper-voices/blob/v1.0.0/en/en_GB/alan/medium/MODEL_CARD), [Lessac](https://huggingface.co/rhasspy/piper-voices/blob/v1.0.0/en/en_US/lessac/high/MODEL_CARD). Each links its dataset/license. Check voice and engine terms before redistributing a bundle.
- Apple's [CoreAudio input-running property](https://developer.apple.com/documentation/coreaudio/kaudioprocesspropertyisrunninginput) and [process list](https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertyprocessobjectlist): activity signals, not universal meeting detection.
- Apple's [NSScreen notch areas](https://developer.apple.com/documentation/appkit/nsscreen/auxiliarytopleftarea-swift.property) and [AVAudioPlayer](https://developer.apple.com/documentation/avfaudio/avaudioplayer).
