# MeetingVox

**English** · [Español](README.es.md)

MeetingVox is a macOS menu-bar app that records meetings and transcribes them **on the Mac itself**. One click records two separate tracks: your microphone (`mic.caf`, "Yo") and everything the Mac plays (`system.caf`, "Otros", captured with a Core Audio *process tap*, with no virtual devices or kernel extensions). When you stop, it transcribes both tracks locally and produces a transcript with one speaker per turn. Optionally it writes minutes, summaries and tasks with a language model through OpenRouter, and it can send transcripts to a Hindsight memory server of your own.

The app's user interface is in Spanish.

It is a fork of [`digimata/quill`](https://github.com/digimata/quill), renamed MeetingVox (the feather icon comes from there).

## Contents

1. [What leaves the Mac and what does not](#what-leaves-the-mac-and-what-does-not)
2. [Requirements](#requirements)
3. [Getting the code](#getting-the-code)
4. [Build, install and run](#build-install-and-run)
5. [First run](#first-run)
6. [Basic use](#basic-use)
7. [Transcription](#transcription)
8. [External components](#external-components)
9. [Configuration](#configuration)
10. [Files of each session](#files-of-each-session)
11. [Modifying the project](#modifying-the-project)
12. [Technical notes: Bluetooth headsets](#technical-notes-bluetooth-headsets)
13. [Distributing your own build](#distributing-your-own-build)
14. [License and credits](#license-and-credits)

## What leaves the Mac and what does not

- **Audio never leaves the Mac.** The `.caf` files are only read and written locally.
- **Transcription is local** (Parakeet Ultra on Core ML). The only download is the speech model, once.
- **OpenRouter** (optional, needs a key and a model): receives **text only**, and only to write minutes, summaries and tasks:
  - Minutes: the transcript text (automatically when `minutes.enabled` is on, or when you ask for one meeting).
  - Summaries: the minutes text if there are minutes; otherwise the transcript.
  - Tasks and the meeting's country: the same text as the summary (together with the summary, or through "Reconstruir índice").
  - With `openrouter.deny_data_collection` (on by default), OpenRouter only uses providers that neither store nor train on the data.
- **Hindsight** (optional, off by default): receives the transcript and its metadata (title, date, times, duration, template, attendees, engine and models), plus the meeting's client and country as tags. It **never** receives the audio or the minutes text (attendee names are extracted locally from the minutes, but the minutes are not sent). Only the meetings you choose are sent, or every eligible one if you turn on automatic sending.
- **Calendar** (optional, off by default): MeetingVox only **reads** your calendar; it never modifies it and never reads event notes. When a meeting is linked to an event (until you use "Quitar evento del calendario"), the event title and the invitees' **names** are sent to OpenRouter with the transcript and to Hindsight as `titulo` and `asistentes`. Invitee emails, notes, the event URL and its location never leave the Mac.
- Secrets (OpenRouter key, Hindsight token) live in the macOS keychain, never in configuration files, logs or sessions.

These statements match the app's own notices (`Textos.Ajustes.privacidadNota`, `Textos.Memoria.nota` and `NSLocalNetworkUsageDescription` in `Packaging/Info.plist`); if you change what is sent, update those notices too.

## Requirements

- **macOS 15 or later** (the package declares `.macOS(.v15)`; system audio capture uses Core Audio *process taps*).
- **Apple Silicon recommended** for fast transcription.
- **Swift 6 toolchain** (`swift-tools-version:6.0`): Xcode, or just the Command Line Tools (`xcode-select --install`). With only the Command Line Tools the build works the same, but the tests need extra flags (see [Tests](#tests)).
- **git** (`Scripts/build-app.sh` also uses `git rev-list --count HEAD` for the build number).
- **Disk space for the speech model**: `MeetingVox doctor` estimates ~750 MB; once downloaded it takes about 600 MB in `~/Library/Application Support/FluidAudio/Models/parakeet-ultra`.
- An internet connection to resolve the SwiftPM dependencies and download the model the first time.

## Getting the code

```sh
git clone https://github.com/pipo-arentsen/meetingvox.git
cd meetingvox
```

## Build, install and run

Run everything from the repository root.

### Before the first build: signing certificate

Create the self-signed **`MeetingVox Dev`** certificate once and back up its `.p12` (steps in [Packaging/README.md](Packaging/README.md)). macOS ties the privacy permissions (microphone, system audio, local network, calendar) and the keychain's "Always Allow" answers to the app's signature:

- With `MeetingVox Dev` the signature is stable and the permissions survive every rebuild.
- Without it the script signs **ad hoc** (with a visible warning). That signature changes on every build, so macOS asks for the permissions again and the keychain asks again after each rebuild.
- To use another certificate: `MEETINGVOX_SIGN_IDENTITY="My certificate" Scripts/build-app.sh`.

### Build

```sh
swift build -c release   # .build/release/MeetingVox: the bare binary (development, tests, doctor, diag)
Scripts/build-app.sh     # .build/app/MeetingVox.app: bundle + icon + signature (installs nothing)
```

`Scripts/build-app.sh` builds in release mode, assembles the bundle (`Info.plist` from `Packaging/Info.plist`, icon, login agent), signs it and verifies it with `codesign --verify --deep --strict`. When it signs with the certificate, the output says `signing with identity "MeetingVox Dev"`.

The bare binary has no `Info.plist` of its own: permissions are attributed to the terminal, and there are no native notifications or onboarding. Use it for `doctor`, `diag` and tests; to use the app, install the `.app`.

### Install

Quit MeetingVox if it is running (menu "Salir de MeetingVox", or `SIGTERM`: a recording in progress is finalized before quitting). Then pick one:

```sh
# Option A: install script (copies to /Applications, registers the login item and opens the app)
Scripts/install-app.sh

# Option B: manual copy
ditto .build/app/MeetingVox.app /Applications/MeetingVox.app
open /Applications/MeetingVox.app
```

- `Scripts/install-app.sh` requires `.build/app/MeetingVox.app` (otherwise it asks you to run `Scripts/build-app.sh`), refuses to continue while MeetingVox is running, moves a previous install to `~/MeetingVox-respaldos/app-previous-<date>/` (it deletes nothing), installs with `ditto`, registers the login item and opens the app. It does not ask for confirmation.
- With option B, launch at login is enabled from the "Primeros pasos" window ("Listo" step) or with `MeetingVox install --launch-at-login` (see [Packaging/README.md](Packaging/README.md#login-item)).

### Logs and diagnostics

- The installed app logs to `~/Library/Logs/MeetingVox/meetingvox.log` (rotated to `.1` past 10 MB): `tail -f ~/Library/Logs/MeetingVox/meetingvox.log`.
- `MeetingVox doctor` checks the microphone, system audio, recordings folder, speech model, OpenRouter, Hindsight and calendar. Non-critical problems show up as warnings.

```sh
/Applications/MeetingVox.app/Contents/MacOS/MeetingVox doctor
```

### Experiments without touching your real configuration

Any invocation of the binary (even `--help`) first runs the configuration migration against the real `~/.config`. **`HOME=<tmp>` does not isolate the app on macOS** (it uses `homeDirectoryForCurrentUser`, which ignores `HOME`). To experiment, use `CFFIXED_USER_HOME`:

```sh
CFFIXED_USER_HOME="$(mktemp -d)" .build/release/MeetingVox doctor
```

The only exception is `diag --mode snapshot`, which neither reads the configuration nor runs the migration. Careful: `diag` without `--mode` (or with `mic`, `capture`, `tap-then-mic`, etc.) opens the microphone and records; do not run it unattended.

## First run

The first time the installed app opens, the **"Primeros pasos"** window appears with four steps: **Permisos**, **Modelo**, **Minutas** and **Listo**. You can move freely between them; the window only stops appearing once you press **"Empezar"** (saved in `~/.config/meetingvox/onboarding.json`). It can be reopened from the menu ("Primeros pasos…") or from Settings.

- **Permisos** (permissions): each one is requested only when you click "Permitir":
  - Microphone (your voice).
  - System audio (the other people's voices).
  - Notifications (a notice when a meeting is ready).
  - Local network (only if you use a Hindsight server on your network).
  You can change them later in System Settings › Privacy & Security. If you deny the microphone, only the system track is recorded and `doctor` reports a warning.
- **Modelo** (model): "Descargar modelo" downloads Parakeet Ultra once. If you skip it here, it is downloaded on the first transcription (better to do it before an important meeting).
- **Minutas** (minutes): OpenRouter key and model, optional ("Omitir" changes nothing).
- **Listo** (ready): recordings folder (the change applies after restarting the app), launch at login, meeting detection, automatic minutes and the calendar, which is *opt-in*. macOS asks for the Calendars permission only when you turn that switch on, never at launch.

While the window is open, MeetingVox does not start automatic work that could trigger system prompts (keychain, network); it resumes when the window closes.

## Basic use

- **Record**: click the feather in the menu bar → "Iniciar grabación" (⌘R). While recording, the menu bar shows the elapsed time and a floating pill shows the "Yo" and "Otros" levels and a "Detener" button. If one track fails, the other keeps recording and you get a notice.
- **Meeting detection**: when Teams, Zoom, WhatsApp or a supported browser (BrowserOS, Brave, Safari) starts using the microphone, the pill asks "… detectada" with "Grabar" / "Ignorar". MeetingVox **never starts recording by itself**. When the call ends it asks whether to stop ("Seguir grabando" / "Detener"). Stopping automatically is optional (`meeting_detection.auto_stop`).
- **After stopping**: automatic transcription and, if configured, minutes, summary, tasks and sending to memory. You get **one** "reunión lista" notification per session.
- **Main window** ("Abrir MeetingVox", ⌘J): meeting list with full-text search, classification by scope (Trabajo, Profesional, Personal), a detail view with Resumen / Minuta / Transcripción tabs (with a player), a Tareas page and the Biblioteca (templates and glossary). From the detail you can also regenerate the minutes, apply the glossary, send to memory or move the meeting to the Trash.
- **Ajustes…** (⌘,): OpenRouter, Reuniones and Memoria tabs.

## Transcription

- Engine: **Parakeet Ultra** (`parakeet-ultra-coreml`) through [FluidAudio](https://github.com/FluidInference/FluidAudio) **0.17.4**, on Core ML, 100 % on the Mac, multilingual. There is no other engine: `transcription.engine` only accepts `parakeet` (any other value is ignored with a warning).
- **Why Ultra**: the previous model (Parakeet v3) invented English words in real Spanish meetings; Ultra removed that problem in testing, at the same speed. **FluidAudio 0.17.4 and Ultra go together**: 0.17.4 with v3 gives worse results than the previous FluidAudio version with v3, so do not go back to v3 without testing again.
- Each track is transcribed separately, aligned with its start offset and merged by time: "Yo" (`me`) and "Otros" (`them`), without a diarization model.
- Very quiet tracks (for example Bluetooth microphones in hands-free mode) are normalized on a temporary copy; the original `.caf` is never modified.
- Serial, crash-tolerant queue: a session with `meta.json` but no `transcript.json` is pending and resumes at the next launch. Errors go to the session's `transcribe.log` and do not block the others.
- **Glossary**: once a transcript is done, the misheard variants of the flagged terms are corrected in the text (the original stays in `text_raw`).

## External components

MeetingVox works fully (record, transcribe, search, play back) **without any external service**. The three below are optional.

### Memory (Hindsight)

- **Hindsight is an external memory server. It is not included in this repository and is not distributed with the app.** To use this feature you need your own Hindsight server (or access to one) and a token.
- Off by default (`hindsight.enabled: false`). Without it, nothing memory-related is shown and nothing is sent.
- **What is sent**: one document per session (`document_id` `mv-<folder>`, so a resend updates the same document) with:
  - The transcript as timed turns (your turns under `owner_name`, the others as "Otros").
  - Metadata: title, date, start and end times, duration, time zone, template, attendees, transcription engine and model, summary model.
  - Tags: `fuente:meetingvox`, `tipo:transcripcion`, `plantilla:<id>`, `cliente:<…>` and `pais:<…>` (these two when the summary found them).
  - **Never** the audio or the minutes text.
- **When**:
  - Manually: "Enviar a memoria" in the main window or in the meeting-ready notification.
  - Automatically: with `hindsight.auto_send`, for meetings from the date `hindsight.since` on (`yyyy-MM-dd`; without a valid date nothing is sent automatically). Short meetings are skipped, that is, fewer than `min_words` words (150) **or** fewer than `min_minutes` minutes (2). Manual sends ignore the date and the threshold.
  - A meeting can be marked "No enviar a memoria".
- **Banks**: `hindsight.bank` is the default bank. When the server answers, Ajustes › Memoria lists the available banks. A meeting already sent stays in the bank it was sent to.
- **Token**: stored in the keychain (service `com.pipostudio.meetingvox`, account `hindsight_token`) from Ajustes › Memoria. A 401/403 pauses sending until you save a new token or change the configuration.
- **API used**: `GET {base_url}/v1/default/banks`, `POST …/banks/{bank}/memories` and `DELETE …/banks/{bank}/documents/{id}` (the latter only if, when moving a meeting to the Trash, you explicitly tick "Borrar también de la memoria"), with `Authorization: Bearer <token>`.
- **Local network**: if the server is on your LAN, macOS asks for the Local Network permission. The first request after installing a build may fail as "offline" until you answer that prompt; the next automatic attempt sends it again.
- Keys: `hindsight.enabled`, `auto_send`, `base_url`, `bank`, `owner_name` (default "Yo"), `owner_description`, `since`, `min_words`, `min_minutes`.

### OpenRouter

- External LLM service ([openrouter.ai](https://openrouter.ai)) for **minutes**, **summaries** and **tasks**. Optional: without a key and a model, MeetingVox only transcribes.
- The API key is stored in the keychain (service `com.pipostudio.meetingvox`, account `openrouter_api_key`) from Ajustes › OpenRouter or the "Minutas" step; the model goes in `openrouter.model` (for example `openai/gpt-4o-mini`).
- `minutes.enabled` is **off** by default. Minutes can also be requested for one session from the Minuta tab ("Generar minuta") or with "Generar minuta con…".
- `summary.enabled` is **on** by default: as soon as there is a model and a key, every transcribed meeting gets a `resumen.json` (title, summary, topics, participants, client, tasks, country). To send nothing this way, set `summary.enabled: false`.
- Retries for transient errors (no network, 429, 5xx) are automatic (30 s, 2 min, 10 min). Permanent ones leave a `*.error` marker and can be retried from the window or the notification.

### Calendar (macOS, EventKit)

- Optional and *opt-in* (`calendar.enabled: false` by default). Turn it on in Ajustes › Reuniones or in the "Listo" step. macOS asks for the Calendars permission once, when you turn the switch on.
- **Read-only**: when a recording stops, it looks for the matching event (one you take part in) and stores the title and the invitees' names in `meta.json` (`calendar_event`). It uses them to name the meeting and as context for the minutes and the summary.
- It never writes to your calendars and never reads notes. "Quitar evento del calendario" (the detail's ⋯ menu) removes a session's link.

## Configuration

Optional file `~/.config/meetingvox/config.json`. Almost everything is edited from the settings window, which rewrites the file with sorted keys and keeps the keys it does not know. Invalid JSON is never overwritten.

| Key | Default | Purpose |
|---|---|---|
| `recordings_dir` | `~/Recordings` | Session folder (`--out` > config > default; read at launch). |
| `transcription.enabled` | `true` | `false` = record only. |
| `transcription.engine` | `parakeet` | The only engine available. |
| `mic_voice_processing` | `false` | Apple's echo cancellation (useful with speakers; with headphones, better off). See the [Bluetooth notes](#technical-notes-bluetooth-headsets). |
| `on_stop` | — | Shell command that receives the session folder when processing ends (once per session). |
| `minutes.enabled` | `false` | Automatic minutes after each transcription. |
| `minutes.template` | `general` | Default template. |
| `minutes.language` | `español` | Language of the minutes. |
| `summary.enabled` | `true` | Summary and tasks (needs a key and a model). |
| `openrouter.model` | — | Model ID on OpenRouter. |
| `openrouter.deny_data_collection` | `true` | Only providers that neither store nor train on the data. |
| `glossary` | `[]` | Terms and variants (see below). |
| `meeting_detection.enabled` | `true` | Ask when a meeting is detected. |
| `meeting_detection.ignored_apps` | `[]` | Rule IDs (`teams`, `zoom`, `whatsapp`, `browseros`, `brave`, `safari`, `webkit`) or bundle ids to ignore. |
| `meeting_detection.prompt_on_end` | `true` | Ask whether to stop when the meeting ends. |
| `meeting_detection.auto_stop` | `false` | Stop by itself 45 s after that question if nobody answers. |
| `recording_pill.enabled` | `true` | Floating pill while recording. |
| `calendar.enabled` | `false` | Link sessions to calendar events. |
| `hindsight.*` | `enabled: false`, `auto_send: false` | See [Memory (Hindsight)](#memory-hindsight). |

- **Minutes templates**: Markdown files in `~/.config/meetingvox/plantillas/<id>.md` (with `nombre` and `descripcion` *frontmatter*). Seven factory templates are installed (`general`, `comercial`, `daily`, `uno-a-uno`, `levantamiento`, `entrevista`, `familiar`); edit and restore them from Biblioteca › Plantillas. They are generic: "Yo" is the person who recorded the meeting and "Otros" everyone else, so adapt them to your context (your company, your recurring terms) as you need.
- **Glossary**: each element is a term (`"Kubernetes"`) or an object `{"term": "MeetingVox", "variants": ["miting vox"], "transcript": true}`. The variants of terms with `transcript: true` are corrected in the transcript; every term is suggested to the model for minutes and summaries. Edit it in Biblioteca › Glosario, and reapply it to an older meeting with "Aplicar glosario".

**Coming from quill**: on first launch MeetingVox **copies** `~/.config/quill` to `~/.config/meetingvox` once, and keeps reading the keychain items saved by quill until you save them again. quill's configuration, keychain items and binary are never modified or deleted, and MeetingVox does not start while quill is running. `Scripts/install-app.sh` does not touch quill's agent: retire it by hand before installing (see [Packaging/README.md](Packaging/README.md#coming-from-quill)).

## Files of each session

Each recording creates `<recordings_dir>/yyyy.MM.dd-HHmm[-N]/`. `indice.md`, a Markdown index of every session, is regenerated at the root.

| File | Contents |
|---|---|
| `mic.caf`, `system.caf` | Your audio tracks (AAC in CAF: readable even if the process dies mid-recording). |
| `meta.json` | Start, end, duration, per-track offsets and, optionally, `minutes_template`, `meeting_app`, `ambito`, `calendar_event`. |
| `transcript.json` / `transcript.md` | Canonical transcript (segments with `speaker` `me`/`them`, `text`, `text_raw`) and its readable version. |
| `minuta.md`, `minuta.<id>.md`, `minuta-anterior.md` | Automatic minutes, manual minutes with another template, and the version replaced by the last regeneration. |
| `resumen.json` | Summary, topics, participants, client, tasks and country. |
| `*.log` | `transcribe.log`, `minuta.log`, `resumen.log`, `hindsight.log` (they never contain secrets). |

Markers (empty files or small JSON; the filesystem is the queue):

| Marker | Meaning |
|---|---|
| `minuta.pendiente` / `minuta.error` | Minutes requested and pending (resumed at launch) / failed for good. |
| `resumen.pendiente` / `resumen.error` | The same for the summary. |
| `tareas.pendiente` / `tareas.error` | Task extraction for an older summary pending / failed (only "Reconstruir índice" starts it). |
| `hook.ejecutado` | `on_stop` already ran (never twice). |
| `hindsight.json` / `hindsight.error` | Last content Hindsight accepted / rejected. |
| `hindsight.solicitado` / `hindsight.omitir` | Send requested by the user / never send this session. |
| `listo.notificado` | The "reunión lista" notification was already posted. |

The keys of `meta.json`, `transcript.json` and `resumen.json` and the `me`/`them` ids are stable: an external `on_stop` can parse them.

## Modifying the project

### Layout

```
Sources/MeetingVox/
  App/            bootstrap (Entry.swift is the @main), single instance, logging, quitting, login item
  Audio/          microphone and system recording, meeting detection (MeetingDetection/)
  Transcription/  Parakeet, transcription queue, glossary, model download
  Minutes/        minutes, templates, prompts (MinutesPrompts), chunking of long transcripts
  Summary/        summaries and tasks (SummaryPrompts)
  OpenRouter/     OpenRouter HTTP client
  Hindsight/      export to Hindsight
  Calendar/       EventKit link (only EventKitCalendarSource touches EventKit)
  MeetingIndex/   index, list, filters, full-text search, pure logic of the window
  Notifications/  native notices and their routing
  Onboarding/, Permissions/  "Primeros pasos" and permission status
  Pill/, Playback/, Pipeline/, Markdown/  pill, player, stage status, minutes viewer
  Config/, Secrets/, Migration/  configuration, keychain, migration from quill
  UI/             AppKit/SwiftUI views; every visible string lives in UI/Textos.swift
  Diag/           diag and view snapshots
Tests/MeetingVoxTests/  swift-testing tests (@testable import MeetingVox)
Packaging/      Info.plist, entitlements, login agent, icon (see Packaging/README.md)
Scripts/        build-app.sh (builds and signs) and install-app.sh (installs; you run it)
```

### Architecture essentials

- **Bootstrap**: `App/Entry.swift` is the only `@main`. Order: argument cleanup → log redirect → single instance → log rotation → configuration migration → command. Nothing reads `Config` before the migration.
- **The filesystem is the queue**: every stage (transcription, minutes, summary, memory) reads and writes markers in the session folder (see [Files of each session](#files-of-each-session)), so a crash or a relaunch picks up pending work. Errors are logged and never block the queue.
- **Audio**: the microphone is captured with `AVCaptureSession` (`Audio/CaptureMicRecorder.swift`); `AVAudioEngine` (`Audio/MicRecorder.swift`) is only used with `mic_voice_processing`. System audio uses a process tap that excludes the app itself. Read the [Bluetooth notes](#technical-notes-bluetooth-headsets) before touching capture.
- **Quitting**: the only exit path is `NSApp.terminate` → `AppDelegate`, so ⌘Q, `SIGTERM`, logout and `launchctl bootout` finalize a recording in progress (they write `meta.json`) before exiting.
- **Privacy**: the app's notices (`Textos.Ajustes.privacidadNota`, `Textos.Memoria.nota`, `NSLocalNetworkUsageDescription`) must match what actually leaves the Mac; `PrivacyCopyTests` pins them.
- **Calendar**: EventKit is only used inside `Calendar/EventKitCalendarSource.swift`, and only in the bundled app; tests and the bare binary never create an `EKEventStore`.
- **Pure logic, thin views**: decisions (pill state, menu, filters, stages, notifications) are pure functions with tests; views only draw models and never read `Config` or the keychain (`SnapshotHomeGuardTests` checks this).

### Tests

With Xcode:

```sh
swift test
```

With only the Command Line Tools, `Testing.framework` is not on the default search path:

```sh
D=/Library/Developer/CommandLineTools/Library/Developer
swift test -Xswiftc -F -Xswiftc $D/Frameworks -Xlinker -F -Xlinker $D/Frameworks \
  -Xlinker -rpath -Xlinker $D/Frameworks -Xlinker -rpath -Xlinker $D/usr/lib
```

A change is done when `swift build -c release` builds with no errors and no new warnings, and the tests pass.

### View snapshots

```sh
.build/release/MeetingVox diag --mode snapshot --out /tmp/meetingvox-snapshots
```

Renders interface states to PNG (`<state>.png`) from sample data in a temporary directory, without reading your configuration, your keychain or your recordings, and without network. New states are added to `SnapshotStates.all`.

### Conventions

- Swift 6 with strict concurrency: the UI is `@MainActor`, the processing queues are `actor`s, and the recorders are lock-guarded `@unchecked Sendable`.
- Every visible string is in `UI/Textos.swift` (in Spanish). The LLM prompts are in `Minutes/MinutesPrompts.swift` and `Summary/SummaryPrompts.swift`.
- snake_case JSON; `///` comments that explain the *why*; *conventional commits*.
- What persists (bundle id, paths, keychain service, labels) is named only in `AppIdentity.swift`.

## Technical notes: Bluetooth headsets

Findings measured with a Bluetooth headset; they explain why microphone capture works the way it does.

- Opening the microphone switches the headset from A2DP (stereo) to hands-free (HFP).
- **`AVAudioEngine` is the wrong tool for raw capture on Bluetooth.** Its input node binds to `CADefaultDeviceAggregate` (default input plus default output), so it claims the headset's output too. Each A2DP↔HFP switch posts `AVAudioEngineConfigurationChange`; destroying and recreating the engine on it drove an A2DP↔HFP oscillation: microphone buffers missing or pure zeros (from 5 s up to the whole session) and the user's playback cutting out. An engine bound directly to the input device still cut playback.
- **`AVCaptureSession` works** (`MeetingVox diag --mode capture`): voice from the first second and uninterrupted playback, also with the system tap started after the microphone. That is why `CaptureMicRecorder` is the production path and a session starts the microphone first, then the tap (the reverse order was never tested with the capture session). `AVAudioEngine` is kept only for voice processing.
- Every full capture restart reopens the microphone (an A2DP↔HFP cycle, with playback cuts); hence the backoff between restarts.
- In HFP the microphone delivers 16 kHz at a very low level (≈ −37 dBFS); hence the loudness normalization before transcription.
- A short burst of digital zeros can arrive at start (about 7 s with the engine); hence the 3 s grace period of the dead-microphone detector.
- **`mic_voice_processing` is off by default.** Apple's voice processing is not an input effect: it replaces the engine's I/O with a duplex `VoiceProcessingIO` unit. With an incomplete graph (accepting the format the input inherits, for example 9 channels at 48 kHz on a multichannel route, and no connected output path), the microphone track came out as digital silence (≈ −91 dB) even though the file had the right duration. It needs an explicit mono format on both sides of the unit and a connected output path, and some input/output combinations may still fail. If you turn it on, test it with your hardware first.
- Do not touch the microphone graph casually.

## Distributing your own build

If you publish your own build, change the identity so it does not clash with the author's (permissions, keychain, configuration and the login item depend on it):

- `Sources/MeetingVox/AppIdentity.swift`: `bundleID` (it also defines the keychain service, the queue labels and the notification names), `agentLabel`, `configDirName`, and `displayName`/`executableName` if you rename the app.
- `Packaging/Info.plist`: `CFBundleIdentifier` (and the name or version if needed).
- `Packaging/LaunchAgents/com.pipostudio.meetingvox.agent.plist`: the file name and its `Label` must equal `AppIdentity.agentLabel`, and `AssociatedBundleIdentifiers` must be the new bundle id.
- `Scripts/build-app.sh` and `Scripts/install-app.sh`: the variable holding the agent plist name (`AGENT_PLIST` / `AGENT_PLIST_NAME`).
- Tests that pin these values: `AppIdentityTests`, `LaunchAgentPlistTests`, `NotifierFactoryTests` and `HindsightConfigTests` (keychain service).
- Optional: the `HTTP-Referer` header that `OpenRouter/OpenRouterClient.swift` sends to OpenRouter (currently `github.com/pipo-arentsen/meetingvox`).
- Sign with your own certificate (`MEETINGVOX_SIGN_IDENTITY`). With a new bundle id, macOS asks for the permissions from scratch.

## License and credits

- MIT License (see [LICENSE](LICENSE), Copyright (c) 2026 Andrew Jones and Copyright (c) 2026 Felipe Arentsen).
- Based on [digimata/quill](https://github.com/digimata/quill).
- Transcription with [FluidAudio](https://github.com/FluidInference/FluidAudio) (Parakeet on Core ML).
- CLI with [swift-argument-parser](https://github.com/apple/swift-argument-parser).
