# Packaging MeetingVox.app

**English** · [Español](README.es.md)

`Scripts/build-app.sh` builds `.build/app/MeetingVox.app` from the release binary. **It only builds**: it never installs, never touches launchd and never opens the app.

## Quick path (first time on a Mac)

1. Create the **`MeetingVox Dev`** certificate (once, by hand): [steps](#create-the-meetingvox-dev-certificate).
2. Back it up as a `.p12` and keep the file and its password off the Mac: [steps](#back-up-the-certificate-p12).
3. `Scripts/build-app.sh`: the output must say `signing with identity "MeetingVox Dev"`.
4. Quit MeetingVox if it is running and install with `Scripts/install-app.sh` or with `ditto` ([install](#install-and-reinstall)).

If you skip steps 1 and 2 the app still builds, but with an **ad hoc** signature that changes on every build. See the next section.

## Why a stable signing identity matters

macOS ties the Microphone, System Audio Recording, Local Network and Calendars permissions, as well as the keychain's "Always Allow" answers, to the app's code signature. An **ad hoc** signature (the script's fallback when it does not find the certificate) is different on every build, so all those permissions are lost after each rebuild. A self-signed certificate that does not change produces a signature that survives rebuilds: the *designated requirement* is bound to the bundle id and the certificate, not to the file hash. Losing the certificate has the same effect as signing ad hoc.

## Files in this folder

| File | Role |
|---|---|
| `Info.plist` | Template for `Contents/Info.plist`: bundle id `com.pipostudio.meetingvox`, `LSUIElement` (no Dock icon), macOS 15+, permission texts in Spanish (`NSMicrophoneUsageDescription`, `NSAudioCaptureUsageDescription`, `NSLocalNetworkUsageDescription`, `NSCalendarsFullAccessUsageDescription`) and `NSAppTransportSecurity.NSAllowsLocalNetworking` for a Hindsight server on the LAN. `CFBundleVersion` is a placeholder: the script replaces it with the commit count. It is **not** embedded in the Mach-O binary, so the bare `.build/release/MeetingVox` has no `Info.plist` of its own. |
| `MeetingVox.entitlements` | `com.apple.security.device.audio-input` and `com.apple.security.personal-information.calendars` (read-only, for the optional calendar link). No sandbox. |
| `LaunchAgents/com.pipostudio.meetingvox.agent.plist` | Login agent, copied to `Contents/Library/LaunchAgents/` and registered with `SMAppService.agent(plistName:)`. `BundleProgram`, `KeepAlive { SuccessfulExit: false }` (a normal exit does not relaunch the app) and no `StandardErrorPath` (launchd does not expand `~`; the app redirects its own stderr to `~/Library/Logs/MeetingVox/meetingvox.log`). The file name and its `Label` must match `AppIdentity.agentLabel`. |
| `Icon/make-icon.swift` | Draws the feather on a gradient background into an `.iconset`; the script turns it into `AppIcon.icns` with `iconutil`. Generated on every build, not versioned. |

## Create the "MeetingVox Dev" certificate

The script never creates certificates or changes trust settings.

1. Open **Keychain Access** (*login* keychain) and choose **Keychain Access › Certificate Assistant › Create a Certificate…**. The exact menu and option names depend on the macOS language.
2. Name: `MeetingVox Dev`. Identity Type: **Self Signed Root**. Certificate Type: **Code Signing**. Leave *Let me override defaults* unchecked and create the certificate.
3. In **My Certificates**, double-click `MeetingVox Dev`, expand **Trust** and set **Code Signing** to **Always Trust** (authenticate when asked). Without this, `security find-identity -v` does not list it as valid and the script signs ad hoc.
4. Check that the script sees it:

   ```sh
   security find-identity -v -p codesigning | grep "MeetingVox Dev"
   ```

5. Rebuild with `Scripts/build-app.sh`. The output must say `signing with identity "MeetingVox Dev"` and the *designated requirement* must include the bundle id.

To use a certificate with another name:

```sh
MEETINGVOX_SIGN_IDENTITY="My certificate" Scripts/build-app.sh
```

If more than one valid certificate has the same name, the script refuses to guess and exits with an error. Remove the duplicates or use a unique name or hash.

The first launch of a build signed with a new certificate asks for the permissions again (once). From then on they persist across rebuilds as long as the same certificate signs.

## Back up the certificate (.p12)

If you lose the certificate (new Mac, reset keychain, reinstall), the next build has another identity and every permission is lost. Export a `.p12` and keep it somewhere safe off the Mac (password manager, encrypted volume).

1. In **Keychain Access › My Certificates**, select `MeetingVox Dev` (the row with the disclosure triangle, so the private key is included).
2. **File › Export Items…**, format **Personal Information Exchange (.p12)**, save it as `MeetingVoxDev.p12`.
3. Choose a strong export password and store it apart from the file. A `.p12` without its password is useless; with it, anyone can sign as you, so treat it like a private key.

To restore it on another Mac or after a reset:

```sh
security import MeetingVoxDev.p12 -k ~/Library/Keychains/login.keychain-db -T /usr/bin/codesign
```

Then repeat step 3 of the previous section ("Always Trust" for code signing) and step 4 to verify.

## What the build does

```sh
Scripts/build-app.sh
```

1. `swift build -c release`.
2. Assembles the bundle in a temporary directory inside `.build/app/`: `Contents/MacOS/MeetingVox`, `Contents/Info.plist` (from `Packaging/Info.plist`), the login agent, `Contents/Resources/AppIcon.icns` and the SwiftPM resource `*.bundle`s.
3. Sets `CFBundleVersion` = `git rev-list --count HEAD` (or `1` if git fails, with a warning).
4. Runs `plutil -lint`, checks that every required `Info.plist` key exists and validates the agent plist: `Label` equal to the file name, the right `BundleProgram` and no `StandardErrorPath`.
5. Signs with `MeetingVox Dev` (or `MEETINGVOX_SIGN_IDENTITY`), or ad hoc with a warning, using `Packaging/MeetingVox.entitlements`.
6. Verifies, and only then publishes to `.build/app/MeetingVox.app`. A failed run never leaves a half-built bundle and never deletes the previous one.

### Verify the signature and entitlements

```sh
codesign --verify --deep --strict --verbose=2 .build/app/MeetingVox.app
codesign -d -r- .build/app/MeetingVox.app             # designated requirement
codesign -dv .build/app/MeetingVox.app                # identifier and authority
codesign -d --entitlements - .build/app/MeetingVox.app
```

With an ad hoc signature, `codesign -dv` shows `Signature=adhoc`.

### No hardened runtime, no sandbox

The signature does **not** use the hardened runtime (`--options runtime`) and the app is **not** sandboxed:

- Without notarization the hardened runtime adds nothing, and its library validation could break loading FluidAudio/Core ML.
- The app reads `~/.config`, writes to the recordings folder and talks to a server on the LAN.

The microphone and calendar entitlements are declared anyway, so those permissions keep working if the hardened runtime is ever turned on.

## Install and reinstall

Before installing a new build, **quit MeetingVox** (menu "Salir de MeetingVox", or `SIGTERM`: a recording in progress is finalized before quitting).

```sh
Scripts/build-app.sh
Scripts/install-app.sh     # you run it in a terminal; it does not ask for confirmation
```

`Scripts/install-app.sh`, in order:

1. Requires `.build/app/MeetingVox.app` (otherwise it asks you to run `Scripts/build-app.sh`) and refuses to continue if MeetingVox is running from `/Applications`: quit the app first.
2. Verifies the signature of the built app and its agent plist.
3. Copies the app with `ditto` to a temporary path in `/Applications` and verifies the copy.
4. Moves a previous `/Applications/MeetingVox.app` to `~/MeetingVox-respaldos/app-previous-<date>/` and puts the new one in its place.
5. Registers the login item with `MeetingVox install --launch-at-login`. With exit code **3** it opens the Login Items pane so you can approve it.
6. Opens the app if it is not running.

It never sends SIGKILL and never deletes anything. If something fails, it tells you where the previous version is.

Without the script:

```sh
ditto .build/app/MeetingVox.app /Applications/MeetingVox.app
open /Applications/MeetingVox.app
```

In that case, register the login item from "Primeros pasos" ("Listo" step) or with the command in the next section.

## Login item

```sh
/Applications/MeetingVox.app/Contents/MacOS/MeetingVox install --launch-at-login   # register
/Applications/MeetingVox.app/Contents/MacOS/MeetingVox install --status            # show status (changes nothing)
/Applications/MeetingVox.app/Contents/MacOS/MeetingVox install --uninstall         # remove
```

- Pass **exactly one** of the three options; otherwise it exits with code **64**.
- `--launch-at-login` only registers from `/Applications/MeetingVox.app`. From anywhere else it refuses and exits with code **1**.
- Mechanism: `SMAppService.agent(plistName:)` over the embedded plist. If the system rejects it (for example with a self-signed bundle), it falls back to a LaunchAgent in `~/Library/LaunchAgents` with the same label, pointing at the installed executable.
- Exit codes of `--launch-at-login`:
  - **0**: registered.
  - **1**: failed or refused.
  - **3**: registered, but macOS still needs your approval. Nothing starts at login until you enable MeetingVox in System Settings › General › Login Items & Extensions.
- Repeating `--launch-at-login` is safe: with the service already registered nothing changes. If a leftover LaunchAgent file remains, it is deleted without stopping the running process.
- `--uninstall` removes both mechanisms. Since it also stops a running MeetingVox, a recording in progress is finalized first.
- The app's and the fallback agent's logs are in `~/Library/Logs/MeetingVox/` (`meetingvox.log`, `launchd.log`).

## Coming from quill

*Optional: only applies to Macs where the original `quill` was installed (`/usr/local/bin/quill` with the `com.digimata.quill` LaunchAgent).*

- MeetingVox **copies** `~/.config/quill` to `~/.config/meetingvox` once (marker `.migrated-from-quill`) and keeps reading the keychain items of the `com.digimata.quill` service until you save them again.
- It never modifies or deletes `/usr/local/bin/quill`, `~/.config/quill`, the legacy keychain items or the recordings. MeetingVox refuses to start while quill is running.
- `Scripts/install-app.sh` does not touch quill's agent. If it is still loaded, retire it by hand before installing (optional; `bootout` is a clean stop and ends a quill recording in progress, so do it when it is not recording):

```sh
launchctl bootout gui/$(id -u)/com.digimata.quill
mv ~/Library/LaunchAgents/com.digimata.quill.plist ~/Library/LaunchAgents/com.digimata.quill.plist.disabled
```

To go back to quill:

```sh
/Applications/MeetingVox.app/Contents/MacOS/MeetingVox install --uninstall
mv ~/Library/LaunchAgents/com.digimata.quill.plist.disabled ~/Library/LaunchAgents/com.digimata.quill.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.digimata.quill.plist
```

Configuration changes made in MeetingVox stay in `~/.config/meetingvox` and are not copied back to `~/.config/quill`. macOS may ask again for the microphone and system audio permissions for the quill binary.
