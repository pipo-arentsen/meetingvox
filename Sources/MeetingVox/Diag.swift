@preconcurrency import AVFoundation
import ArgumentParser
import CoreAudio
import Foundation

/// `quill diag`: records with the production mic recorder (the one config
/// selects: `CaptureMicRecorder`, or `MicRecorder` when
/// `mic_voice_processing` is on) and `SystemAudioRecorder`, and prints
/// per-second mic/system levels plus every device event, to pin down
/// Bluetooth headset problems. Diagnostic output only — nothing here changes
/// how normal recording behaves. `--mode capture` forces the capture-session
/// recorder; `--mode engine-direct` runs an EXPERIMENTAL strategy
/// (`Audio/ExperimentalMicCapture.swift`). `--mode processes` opens no mic
/// at all: it prints, once a second, which processes run audio input and
/// what the meeting detector would make of them.
struct Diag: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record a short diagnostic session and print mic/system levels and device events."
    )

    enum Mode: String, ExpressibleByArgument, CaseIterable {
        /// Mic only (config-selected recorder), no process tap.
        case mic
        /// System tap, then mic (the pre-capture-session production order).
        case tapThenMic = "tap-then-mic"
        /// Mic first; the tap starts once the mic delivers non-zero audio (or after 10 s).
        /// Close to `RecordingSession.start` (mic, then tap right away).
        case micThenTap = "mic-then-tap"
        /// `CaptureMicRecorder` regardless of `mic_voice_processing`.
        case capture
        /// EXPERIMENTAL: AVAudioEngine bound directly to the input device, reconfigured in place.
        case engineDirect = "engine-direct"
        /// No recording: list processes with audio input running, once a
        /// second, as the meeting detector sees them.
        case processes
        /// No recording, no post, no permission request: print which
        /// notification backend this process would use (bundled: also the
        /// authorization status and the categories read back).
        case notifications
        /// No recording, no prompt, no tap, no probe: print every permission
        /// status this process can read, the marker and the gate decision.
        case permissions
        /// No recording, no config, no Keychain: render the main-window views
        /// to PNG from synthetic fixtures in a temp dir (`--out` is where the
        /// PNGs go). See `SnapshotHarness`.
        case snapshot

        var isExperimental: Bool { self == .engineDirect }
        var acceptsWithTap: Bool { self == .capture || self == .engineDirect }
    }

    @Option(name: .long, help: "Which recorders to start, and in what order.")
    var mode: Mode = .tapThenMic

    @Flag(name: .long, help: ArgumentHelp(
        "capture / engine-direct only: start the system tap after the mic (once it delivers audio, or after 10 s)."))
    var withTap = false

    @Flag(name: .long, help: ArgumentHelp(
        "processes only: act as if MeetingVox started recording at launch and run the meeting-end check (no audio is opened)."))
    var simulateRecording = false

    @Option(name: .long, help: "Recording length in seconds.")
    var seconds: Int = 25

    @Option(name: .long, help: "Output directory (default: a new temp directory).")
    var out: String?

    func validate() throws {
        guard seconds > 0 else { throw ValidationError("--seconds must be positive") }
        if withTap, !mode.acceptsWithTap {
            throw ValidationError("--with-tap only applies to --mode capture or engine-direct")
        }
        if simulateRecording, mode != .processes {
            throw ValidationError("--simulate-recording only applies to --mode processes")
        }
    }

    func run() throws {
        // Before anything reads `Config`: the snapshot route builds every
        // dependency itself from a temp dir and never sees the real home.
        if mode == .snapshot {
            try runSnapshot()
            return
        }
        if mode == .processes {
            runProcesses()
            return
        }
        if mode == .notifications {
            runNotifications()
            return
        }
        if mode == .permissions {
            runPermissions()
            return
        }
        let dir = try outputDirectory()
        let probe = DiagProbe()
        probe.say("MeetingVox diag · mode=\(mode.rawValue)\(withTap ? " +tap" : "") · seconds=\(seconds)"
            + (mode.isExperimental ? " · EXPERIMENTAL mic strategy (not the production recorder)" : ""))
        probe.say("output dir: \(dir.path)")
        probe.say("config mic_voice_processing=\(Config.micVoiceProcessing())")
        probe.say("mic permission (as seen by this process): \(Self.micPermission())")
        if let terminal = Self.hostTerminal() {
            probe.say("note: launched from \(terminal) — macOS may attribute microphone / system-audio "
                + "permission (TCC) to the terminal app, not to MeetingVox")
        }
        probe.say("default input:  \(CoreAudioDevice.describe(CoreAudioDevice.defaultDevice(input: true)))")
        probe.say("default output: \(CoreAudioDevice.describe(CoreAudioDevice.defaultDevice(input: false)))")
        probe.startListening()
        defer { probe.stopListening() }

        let backend: MicBackend = mode == .capture ? .capture : .current()
        let mic = backend.makeRecorder()
        let system = SystemAudioRecorder()
        mic.diagBuffer = { [probe] buffer in probe.addMic(buffer) }
        if let engineMic = mic as? MicRecorder {
            engineMic.diagEvent = { [probe] event in probe.micEvent(event) }
        } else if let captureMic = mic as? CaptureMicRecorder {
            captureMic.diagEvent = { [probe] event in probe.captureEvent(event) }
            // Diag must not pop real notifications.
            captureMic.notify = { [probe] title, body in probe.event("notification (not sent): \(title) — \(body)") }
            probe.attachLabel = "capture session restarts / input switches"
        }
        if !mode.isExperimental {
            probe.say("mic recorder: \(backend == .capture ? "CaptureMicRecorder (AVCaptureSession)" : "MicRecorder (AVAudioEngine, voice processing)")")
        }
        mic.onUnavailable = { [probe] error in probe.event("mic unavailable: \(error)") }
        system.diagBuffer = { [probe] buffer in probe.addSystem(buffer) }

        let micURL = dir.appendingPathComponent("mic.caf")
        let systemURL = dir.appendingPathComponent("system.caf")

        let directMic = ExperimentalDirectEngineMic()
        directMic.onBuffer = { [probe] buffer in probe.addMic(buffer) }
        directMic.onLog = { [probe] line in probe.event(line) }
        directMic.onAttached = { [probe] bound, format in probe.directAttached(bound: bound, format: format) }
        directMic.defaultInputDevice = { CoreAudioDevice.defaultDevice(input: true) }
        if mode == .engineDirect { probe.attachLabel = "same-engine (re)starts" }

        probe.markStart()
        switch mode {
        case .mic:
            probe.event("starting mic")
            try mic.start(writingTo: micURL)
        case .tapThenMic:
            probe.event("starting system tap")
            try system.start(writingTo: systemURL)
            Self.reportExclusion(of: system, to: probe)
            probe.event("system tap started; starting mic")
            do {
                try mic.start(writingTo: micURL)
            } catch {
                system.stop()
                throw error
            }
        case .micThenTap:
            probe.event("starting mic (tap deferred until mic peak > 1e-4 or 10 s)")
            try mic.start(writingTo: micURL)
        case .capture:
            probe.event("starting AVCaptureSession mic (CaptureMicRecorder)")
            try mic.start(writingTo: micURL)
        case .engineDirect:
            probe.event("starting EXPERIMENTAL direct-bound AVAudioEngine mic")
            try directMic.start(writingTo: micURL)
        case .processes, .notifications, .permissions, .snapshot:
            return // handled before any recorder exists
        }
        probe.event("mic started")

        let deferTap = mode == .micThenTap || withTap
        var tapStarted = mode == .tapThenMic
        let deadline = Date().addingTimeInterval(TimeInterval(seconds))
        var nextTick = Date().addingTimeInterval(1)
        while Date() < deadline {
            RunLoop.current.run(until: min(Date().addingTimeInterval(0.1), deadline))
            if deferTap, !tapStarted {
                let elapsed = probe.elapsed
                if probe.micEverAbove(1e-4) || elapsed >= 10 {
                    probe.event(elapsed >= 10 && !probe.micEverAbove(1e-4)
                        ? "mic still silent after 10 s; starting system tap anyway"
                        : "mic delivering audio; starting system tap")
                    do {
                        try system.start(writingTo: systemURL)
                        Self.reportExclusion(of: system, to: probe)
                        probe.event("system tap started")
                    } catch {
                        probe.event("system tap failed: \(error)")
                    }
                    tapStarted = true
                }
            }
            if Date() >= nextTick {
                probe.flushSecond(tapActive: tapStarted && system.isRecording)
                nextTick = nextTick.addingTimeInterval(1)
            }
        }

        probe.event("stopping")
        switch mode {
        case .engineDirect: directMic.stop()
        default: mic.stop()
        }
        system.stop()
        probe.summary()
        probe.say("files: \(dir.path)")
    }

    /// The two lines printed at the one point where a diag run starts the tap
    /// (every mode that has one): whether Core Audio knows this process, and
    /// whether the running tap excludes it (what lets playback run mid-recording).
    private static func reportExclusion(of system: SystemAudioRecorder, to probe: DiagProbe) {
        probe.say(ownObjectLine(system.ownObject))
        probe.say(excludesSelfLine(system.excludesSelf))
    }

    static func ownObjectLine(_ object: AudioObjectID?) -> String {
        "own process object: \(object.map { "found (\($0))" } ?? "absent")"
    }

    static func excludesSelfLine(_ excludes: Bool) -> String { "excludesSelf: \(excludes)" }

    /// `--mode snapshot`: renders the registered view states to
    /// `<out>/<state>.png` from synthetic fixtures. Reads no config, opens no
    /// keychain item, audio device, socket or real recording; the fixture
    /// environment lives in a fresh temp dir (refused if it were inside the
    /// real home) that is removed at the end. The process stays
    /// `.prohibited`: no Dock icon, no window ever shown.
    private func runSnapshot() throws {
        let say: @Sendable (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) }
        let outDir = try outputDirectory()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(AppIdentity.tempPrefix)snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let env = try SnapshotEnvironment.make(tempRoot: tempRoot, home: FileManager.default.homeDirectoryForCurrentUser)
        let installed = try SnapshotFixtures.install(in: env)
        say("MeetingVox diag · mode=snapshot · fixtures in \(tempRoot.path) · PNGs in \(outDir.path)")
        let results = try MainActor.assumeIsolated {
            try SnapshotHarness.run(
                states: SnapshotStates.all, context: SnapshotContext(env: env, installed: installed),
                outDir: outDir, say: say)
        }
        let failed = results.filter { $0.file == nil }
        say("\(results.count - failed.count)/\(results.count) snapshots written")
        if !failed.isEmpty { throw ExitCode.failure }
    }

    /// `--mode notifications`: reports the backend this process would post
    /// through and the notification cutoff file's path. Posts nothing, opens
    /// no audio, and does not read or write the cutoff file. Unbundled, the
    /// notification center is never touched. From the bundled .app it also
    /// reads the authorization status and reads the registered categories
    /// back — read-only: it never asks for permission and never posts.
    private func runNotifications() {
        let bundled = LogRedirect.isBundled(bundleURL: Bundle.main.bundleURL)
        let backend = NotifierFactory.currentKind
        let home = FileManager.default.homeDirectoryForCurrentUser
        let say: (String) -> Void = { FileHandle.standardOutput.write(Data(($0 + "\n").utf8)) }
        say("MeetingVox diag · mode=notifications · nothing is posted, no permission is requested")
        say("bundled: \(bundled)")
        say("notification backend: \(backend)")
        say("notification cutoff file: \(AppIdentity.notificationCutoffFile(home: home).path)")
        guard backend == .userNotifications else {
            say("notification center: not touched (unbundled process)")
            return
        }
        guard let readBack = UserNotificationsSetup.readBack() else {
            say("notification center: no answer within 10 s")
            return
        }
        say("authorizationStatus: \(NotificationAuthorizationPolicy.name(readBack.authorization))")
        say("alertSetting: \(readBack.alertSetting.rawValue)")
        for id in readBack.categories.keys.sorted() {
            say("category \(id): [\((readBack.categories[id] ?? []).joined(separator: ", "))]")
        }
        let problems = NotificationCategories.problems(readBack: readBack.categories)
        say(problems.isEmpty
            ? "categories: \(readBack.categories.count) registered, read back as registered"
            : "categories: MISMATCH — " + problems.joined(separator: "; "))
        if readBack.categories.isEmpty, readBack.authorization == .notDetermined {
            say("note: the center returned no categories while authorization is notDetermined (measured with an"
                + " ad-hoc signed bundle); re-run once notices are allowed to confirm the buttons are retained")
        }
    }

    /// `--mode processes`: meeting-detection dry run. Reads process identity
    /// only (Core Audio process objects + `proc_pidpath`), never audio, and
    /// shows no panel. Runs the same state machine as the app, with
    /// "not recording" and "no panel on screen", so "PROMPT" marks the
    /// second the app would have asked. With `--simulate-recording` it runs
    /// as if a recording started at launch: no start prompt, and the
    /// meeting-end machine prints what it watches, the grace countdown and
    /// "END PROMPT" (the panel never shows, so "Seguir grabando" is assumed
    /// after each one).
    ///
    /// The per-second lines poll, so they cannot show what the app misses
    /// between Core Audio events. Alongside, the app's own `MeetingDetector`
    /// runs on the real event source; its decisions print as "[app] …" (plus
    /// its "meeting end: …" logs on stderr). A polled "END PROMPT" with no
    /// "[app] END PROMPT" within the rescan interval is an event-delivery bug.
    private func runProcesses() {
        let say: @Sendable (String) -> Void = { line in FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
        // Same snapshot the app's detector uses (malformed section → defaults).
        let config = MeetingDetectionConfig(Config.values())
        say("MeetingVox diag · mode=processes\(simulateRecording ? " --simulate-recording" : "")"
            + " · seconds=\(seconds) · no audio is opened")
        say("config meeting_detection.enabled=\(config.enabled) prompt_on_end=\(config.promptOnEnd)"
            + " ignored_apps=\(config.ignored.sorted())"
            + (config.formatError.map { " · \($0) malformed, using defaults" } ?? ""))
        say("responsibility lookup (\(AppResolver.responsibilitySymbol)): "
            + (AppResolver.responsibilityAvailable
                ? "available"
                : "MISSING — WebKit capture processes fall back to the generic browser rule"))
        say("own pid: \(getpid())")
        say("note: the app is event-driven (rescans every \(Int(MeetingDetector.recordingRescanInterval)) s only while"
            + " recording a meeting app); this dry run samples once a second, \"[app]\" lines are the app's own detector")
        let appDetector = MainActor.assumeIsolated { () -> MeetingDetector in
            let detector = MeetingDetector()
            detector.onPrompt = { prompt in
                say("   [app] → PROMPT: \(prompt.app.id) (pid \(prompt.pid))")
            }
            detector.onEndPrompt = { [weak detector] prompt in
                say("   [app] → END PROMPT: \(prompt.app.id)")
                detector?.endPromptDismissed() // as if "Seguir grabando" were clicked
            }
            detector.start()
            detector.setRecording(simulateRecording)
            return detector
        }
        defer { MainActor.assumeIsolated { appDetector.stop() } }
        var machine = MeetingDetectionMachine()
        var endMachine = MeetingEndMachine()
        let start = Date()
        for second in 1...seconds {
            RunLoop.current.run(until: start.addingTimeInterval(TimeInterval(second)))
            let now = Date()
            let device = CoreAudioDevice.defaultDevice(input: true)
            let processes = AudioProcesses.inputProcesses()
            let context = MeetingDetectionMachine.Context(
                now: now, recording: simulateRecording, enabled: config.enabled, ignored: config.ignored)
            let observations = MeetingDetector.observations(processes)
            let prompt = machine.step(observations, context)
            let endContext = MeetingEndMachine.Context(
                now: now, enabled: config.enabled && config.promptOnEnd, ignored: config.ignored)
            let endPrompt = simulateRecording ? endMachine.step(observations, endContext) : nil
            let running = AudioProcesses.isRunningSomewhere(device)
            say(String(format: "[%3ds] default input \"%@\" running somewhere: %@ · %d process(es) with input",
                       second, CoreAudioDevice.name(device) ?? "none", running ? "yes" : "no", processes.count))
            for process in processes {
                let app = MeetingApp.resolve(process)
                let own = process.pid == context.ownPID
                let state: String
                if own {
                    state = "excluded (MeetingVox)"
                } else if let app {
                    state = Self.describe(machine.status(of: app, context))
                } else {
                    state = "not a meeting app"
                }
                say("   pid=\(process.pid) bundle=\(process.bundleID ?? "?") app=\(process.appBundleID ?? "=")"
                    + " rule=\(app.map { "\($0.id) \"\($0.label)\"" } ?? "-") · \(state)")
            }
            if let prompt {
                say("   → PROMPT: \(Textos.Reuniones.detectada(prompt.app.label)) (pid \(prompt.pid))")
            }
            if simulateRecording {
                say("   end: " + Self.describe(endMachine.status(endContext)))
            }
            if let endPrompt {
                say("   → END PROMPT: \(endPrompt.app.endedTitle) — \(Textos.Reuniones.preguntaDetener)")
                endMachine.dismissed() // as if "Seguir grabando" were clicked
            }
        }
    }

    private static func describe(_ status: MeetingEndMachine.Status) -> String {
        switch status {
        case .disabled: "disabled in config (meeting_detection.enabled / prompt_on_end)"
        case .notWatching: "no meeting app has captured input during this recording"
        case .capturing(let ids): "watching end · capturing: \(ids.joined(separator: ", "))"
        case .grace(let elapsed, let grace):
            String(format: "watching end · all meeting apps idle · grace %.0f/%.0f s", elapsed, grace)
        case .disarmed: "idle · already asked; re-arms on a new capture"
        }
    }

    private static func describe(_ status: MeetingDetectionMachine.AppStatus) -> String {
        switch status {
        case .disabled: "detection disabled in config"
        case .ignored: "ignored (ignored_apps)"
        case .recording: "recording"
        case .waiting(let elapsed, let threshold): String(format: "waiting %.0f/%.0f s", elapsed, threshold)
        case .handled: "already prompted; re-arms after \(Int(MeetingDetectionMachine.rearmAfter)) s idle"
        case .idle: "idle"
        }
    }

    private func outputDirectory() throws -> URL {
        let dir: URL
        if let out {
            dir = URL(fileURLWithPath: (out as NSString).expandingTildeInPath, isDirectory: true)
        } else {
            let stamp = Int(Date().timeIntervalSince1970)
            dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(AppIdentity.tempPrefix)diag-\(stamp)", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func micPermission() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "authorized"
        case .notDetermined: return "not determined (macOS will prompt)"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    /// Best-effort: terminals export `TERM_PROGRAM`; the LaunchAgent does not.
    static func hostTerminal() -> String? {
        let env = ProcessInfo.processInfo.environment
        if let program = env["TERM_PROGRAM"], !program.isEmpty { return program }
        if let bundle = env["__CFBundleIdentifier"], !bundle.isEmpty { return bundle }
        return isatty(STDIN_FILENO) != 0 ? "a terminal" : nil
    }
}

// MARK: - Probe

/// Collects levels from the recorder hooks (tap/IO threads) and device events
/// (Core Audio listener queue), and prints them relative to the start time.
private final class DiagProbe: @unchecked Sendable {
    private struct Levels {
        var sumSquares: Double = 0
        var samples = 0
        var peak: Float = 0
        var buffers = 0

        var rms: Double { samples > 0 ? (sumSquares / Double(samples)).squareRoot() : 0 }

        mutating func add(_ buffer: AVAudioPCMBuffer) {
            buffers += 1
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            guard buffer.format.commonFormat == .pcmFormatFloat32 else { return }
            for audioBuffer in list {
                guard let data = audioBuffer.mData else { continue }
                let count = Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size
                let floats = data.assumingMemoryBound(to: Float.self)
                for i in 0..<count {
                    let v = floats[i]
                    sumSquares += Double(v * v)
                    peak = max(peak, abs(v))
                }
                samples += count
            }
        }
    }

    private let lock = NSLock()
    private let listenerQueue = DispatchQueue(label: AppIdentity.queueLabel("diag.listeners"))
    private var start = Date()
    private var mic = Levels()
    private var sys = Levels()
    private var micMaxPeak: Float = 0

    private var second = 0
    private var firstLoudSecond: Int?
    private var zeroSeconds = 0
    private var noBufferSeconds = 0
    private var attachCount = 0
    private var configChanges = 0
    /// How the summary names `attachCount - 1`.
    var attachLabel = "engine rebuilds"

    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var rateListeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    var elapsed: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(start)
    }

    func markStart() {
        lock.lock()
        start = Date()
        lock.unlock()
    }

    func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    func event(_ message: String) {
        say(String(format: "[+%6.2fs] ", elapsed) + message)
    }

    // MARK: Levels

    func addMic(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        mic.add(buffer)
        micMaxPeak = max(micMaxPeak, mic.peak)
        lock.unlock()
    }

    func addSystem(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        sys.add(buffer)
        lock.unlock()
    }

    func micEverAbove(_ threshold: Float) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return micMaxPeak > threshold
    }

    func flushSecond(tapActive: Bool) {
        lock.lock()
        let m = mic, s = sys
        mic = Levels()
        sys = Levels()
        second += 1
        let t = second
        if m.peak > 1e-3, firstLoudSecond == nil { firstLoudSecond = t }
        if m.peak <= 1e-4 { zeroSeconds += 1 }
        if m.buffers == 0 { noBufferSeconds += 1 }
        lock.unlock()

        var line = String(format: "t=%3ds mic_rms=%.5f mic_peak=%.5f (%@) buffers=%d",
                          t, m.rms, m.peak, Self.dbfs(m.peak), m.buffers)
        if tapActive {
            line += String(format: " sys_rms=%.5f sys_peak=%.5f sys_buffers=%d", s.rms, s.peak, s.buffers)
        }
        say(line)
    }

    func summary() {
        lock.lock()
        let first = firstLoudSecond, zeros = zeroSeconds, empty = noBufferSeconds
        let total = second, attaches = attachCount, changes = configChanges
        lock.unlock()
        say("── summary ──")
        say("first second with mic peak > 1e-3: \(first.map { "t=\($0)s" } ?? "never")")
        say("zero seconds (mic peak <= 1e-4): \(zeros) of \(total) (of which \(empty) with no buffers)")
        say("\(attachLabel): \(max(0, attaches - 1)) (AVAudioEngine configuration changes seen by MicRecorder: \(changes))")
    }

    private static func dbfs(_ peak: Float) -> String {
        peak > 0 ? String(format: "%.1f dBFS", 20 * log10(Double(peak))) : "-inf dBFS"
    }

    // MARK: Mic events

    func micEvent(_ event: MicRecorder.DiagEvent) {
        switch event {
        case .configurationChanged(let current):
            lock.lock(); configChanges += 1; lock.unlock()
            self.event("AVAudioEngineConfigurationChange" + (current ? "" : " (stale engine, ignored)"))
        case .restarting(let reason):
            self.event("mic restarting: \(reason)")
        case .attached(let input, let inputFormat, let tapFormat):
            lock.lock(); attachCount += 1; let n = attachCount; lock.unlock()
            let bound = Self.boundDevice(of: input)
            self.event("engine \(n == 1 ? "built" : "rebuilt (#\(n - 1))"): input=\(inputFormat) tap=\(tapFormat)")
            self.event("  input AudioUnit bound to: \(bound.map { CoreAudioDevice.describe($0) } ?? "unknown")")
            self.event("  default input now: \(CoreAudioDevice.describe(CoreAudioDevice.defaultDevice(input: true)))")
        }
    }

    /// `CaptureMicRecorder` log lines and (re)starts.
    func captureEvent(_ event: CaptureMicRecorder.DiagEvent) {
        switch event {
        case .log(let line):
            self.event(line)
        case .attached(let device):
            lock.lock(); attachCount += 1; let n = attachCount; lock.unlock()
            self.event("capture session \(n == 1 ? "started" : "restarted (#\(n - 1))") on \"\(device)\"")
            self.event("  default input now: \(CoreAudioDevice.describe(CoreAudioDevice.defaultDevice(input: true)))")
        }
    }

    /// EXPERIMENTAL engine-direct: the same engine (re)started.
    func directAttached(bound: AudioObjectID?, format: AVAudioFormat) {
        lock.lock(); attachCount += 1; let n = attachCount; lock.unlock()
        let bound = bound.map { CoreAudioDevice.describe($0) } ?? "unknown"
        event("engine-direct \(n == 1 ? "started" : "restarted (#\(n - 1))"): input=\(format)")
        event("  input AudioUnit bound to: \(bound)")
        event("  default input now: \(CoreAudioDevice.describe(CoreAudioDevice.defaultDevice(input: true)))")
    }

    /// The device the engine's input AudioUnit actually uses — may differ
    /// from the system default if the engine latched onto a stale device.
    private static func boundDevice(of input: AVAudioInputNode) -> AudioObjectID? {
        guard let unit = input.audioUnit else { return nil }
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &device, &size)
        return status == noErr ? device : nil
    }

    // MARK: Core Audio listeners

    func startListening() {
        for input in [true, false] {
            var address = AudioObjectPropertyAddress(
                mSelector: input ? kAudioHardwarePropertyDefaultInputDevice
                                 : kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                guard let self else { return }
                let device = CoreAudioDevice.defaultDevice(input: input)
                self.event("default \(input ? "input" : "output") changed → \(CoreAudioDevice.describe(device))")
                self.watchSampleRates()
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
            if status == noErr {
                listeners.append((AudioObjectID(kAudioObjectSystemObject), address, block))
            } else {
                say("warning: could not listen to default \(input ? "input" : "output") changes (\(status))")
            }
        }
        watchSampleRates()
    }

    func stopListening() {
        lock.lock()
        let all = listeners + rateListeners
        listeners = []
        rateListeners = []
        lock.unlock()
        for (object, address, block) in all {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, listenerQueue, block)
        }
    }

    /// (Re)attach nominal-sample-rate listeners to the current default
    /// output and input devices; called again whenever a default changes.
    private func watchSampleRates() {
        lock.lock()
        let old = rateListeners
        rateListeners = []
        lock.unlock()
        for (object, address, block) in old {
            var address = address
            AudioObjectRemovePropertyListenerBlock(object, &address, listenerQueue, block)
        }

        var added: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        var seen = Set<AudioObjectID>()
        for input in [false, true] {
            let device = CoreAudioDevice.defaultDevice(input: input)
            guard device != kAudioObjectUnknown, seen.insert(device).inserted else { continue }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                let rate = CoreAudioDevice.nominalSampleRate(device).map { String(format: "%.0f Hz", $0) } ?? "?"
                self?.event("nominal sample rate of \(device) \"\(CoreAudioDevice.name(device) ?? "?")\" → \(rate)")
            }
            if AudioObjectAddPropertyListenerBlock(device, &address, listenerQueue, block) == noErr {
                added.append((device, address, block))
            }
        }
        lock.lock()
        rateListeners = added
        lock.unlock()
    }
}
