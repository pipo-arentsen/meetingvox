@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// Records the default input device to a fixed-format AAC mono CAF (48 kHz)
/// through `AVCaptureSession` + `AVCaptureAudioDataOutput` — the way
/// QuickTime does it. This is the production raw-mic path.
///
/// Why not AVAudioEngine: its input node binds to `CADefaultDeviceAggregate`
/// (default input + default output). With a Bluetooth headset as both, that
/// claims the headset's output too, and every A2DP <-> HFP switch posts
/// `AVAudioEngineConfigurationChange`; rebuilding the engine on it drives an
/// A2DP <-> HFP oscillation (mic buffers missing or all zeros for seconds up
/// to the whole session, and the user's playback cutting out). A capture
/// session binds to the input device only: `quill diag --mode capture` gave
/// voice from the first second with playback uninterrupted.
///
/// Threading: `start()` / `stop()` are called from the main thread and never
/// wait for `startRunning()` / `stopRunning()` (which block for seconds while
/// a Bluetooth headset switches profile). Those run on `sessionQueue`, which
/// `stop()` only ever dispatches to asynchronously. Cross-queue state lives
/// under `stateLock`; the file lives in `MicTrackWriter` (own lock).
///
/// Robustness:
/// - Permission `.notDetermined` asks asynchronously and starts the track
///   when granted (`firstBufferAt` keeps it aligned); a refusal reports
///   through `onUnavailable`. `.denied` makes `start` throw.
/// - Gaps (restart, device switch, stalled delivery) are padded with silence
///   (`MicTrackWriter`), never more than the wall-clock gap.
/// - The default input is tracked (Core Audio listener + capture device
///   connect / disconnect); the session switches to the new default.
/// - Watchdog: no audio written for 2.5 s restarts the session, with
///   exponential backoff (`RestartBackoff`) — never while interrupted or
///   while no input device exists (device events bring it back).
/// - Dead mic (`DeadMicDetector` via `MicHealthMonitor`): silence, no
///   buffers or unconvertible buffers for > 10 s after a 3 s grace. The
///   user is notified once per recording; later episodes only log.
final class CaptureMicRecorder: NSObject, MicRecording, AVCaptureAudioDataOutputSampleBufferDelegate,
    @unchecked Sendable {
    enum RecorderError: Error, CustomStringConvertible {
        case noInputDevice
        case permissionDenied
        case sessionSetupFailed(Error)
        case fileCreationFailed(Error)

        var description: String {
            switch self {
            case .noInputDevice: return Textos.Errores.sinMicrofono
            case .permissionDenied: return Textos.Errores.microfonoSinPermiso
            case .sessionSetupFailed(let e): return Textos.Errores.microfonoNoInicia(e)
            case .fileCreationFailed(let e): return Textos.Errores.archivoMicrofono(e)
            }
        }
    }

    /// English detail wrapped by `RecorderError.sessionSetupFailed` (logs).
    enum SetupFailure: Error, CustomStringConvertible {
        case cannotAddInput(String)
        case cannotAddOutput

        var description: String {
            switch self {
            case .cannotAddInput(let name): return "AVCaptureSession refused the audio input \"\(name)\""
            case .cannotAddOutput: return "AVCaptureSession refused the audio data output"
            }
        }
    }

    /// What `quill diag` observes. Emitted on the session or sample queue.
    enum DiagEvent {
        case log(String)
        /// The session (re)started on `device`.
        case attached(device: String)
    }

    // Set before `start`, never after.
    /// Diagnostics only: when set, log lines go here instead of stderr.
    var diagEvent: ((DiagEvent) -> Void)?
    var diagBuffer: ((AVAudioPCMBuffer) -> Void)?
    var onUnavailable: (@Sendable (Error) -> Void)?
    /// Live peak for the recording pill (`MeteredTrack`), published on the sample queue.
    let level = LevelTap()
    /// Dead-mic transitions for the pill (`MicSignalReporting`). Set before `start`.
    var onSignalChange: (@Sendable (MicSignal) -> Void)?
    /// User notification (title, body); `quill diag` routes it to its log.
    var notify: @Sendable (String, String) -> Void = { notifyUser(title: $0, body: $1) }

    private static let watchdogTimeout: TimeInterval = 2.5
    private static let deviceSettleDelay: TimeInterval = 1.0

    private let sessionQueue = DispatchQueue(label: AppIdentity.queueLabel("mic.capture.session"))
    private let sampleQueue = DispatchQueue(label: AppIdentity.queueLabel("mic.capture.samples"))
    private let listenerQueue = DispatchQueue(label: AppIdentity.queueLabel("mic.capture.listener"))

    // Only touched on `sessionQueue`.
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private var input: AVCaptureDeviceInput?
    private var observers: [NSObjectProtocol] = []
    private var watchdog: DispatchSourceTimer?
    private var interrupted = false
    private var waitingForInput = false
    private var switchLimiter = RestartLimiter(minimumInterval: 5)
    /// Invalidates scheduled device checks superseded by newer events.
    private var deviceCheckGeneration = 0

    // Only touched on `sampleQueue`.
    private var nativeFormat: AVAudioFormat?
    private var pcmCopyErrors = 0

    // Shared across queues — guarded by `stateLock`.
    private let stateLock = NSLock()
    private var recording = false
    /// Bumped by every start / stop, so work queued for an older run aborts.
    private var generation = 0
    /// Open while the track is live; kept after `stop` for `firstBufferAt`.
    private var writer: MicTrackWriter?
    private var trackOpen = false
    private var startUptime: TimeInterval = 0
    private var health = MicHealthMonitor()
    private var backoff = RestartBackoff()
    private var defaultInputListener: AudioObjectPropertyListenerBlock?

    var isRecording: Bool { withState { recording } }

    var firstBufferAt: Date? { withState { writer }?.firstBufferAt }

    // MARK: - Start / stop

    /// Returns quickly: session start runs on `sessionQueue`. Throws for a
    /// denied mic, no input device, or a file / session setup failure; with
    /// permission not decided yet it asks and starts the track later.
    func start(writingTo url: URL) throws {
        let permission = AVCaptureDevice.authorizationStatus(for: .audio)
        switch permission {
        case .authorized, .notDetermined: break
        default: throw RecorderError.permissionDenied
        }
        guard Self.defaultCaptureDevice() != nil else { throw RecorderError.noInputDevice }

        let token: Int? = withState {
            guard !recording else { return nil }
            recording = true
            generation += 1
            startUptime = ProcessInfo.processInfo.systemUptime
            health = MicHealthMonitor()
            backoff = RestartBackoff()
            return generation
        }
        guard let token else { return }

        if permission == .authorized {
            do {
                // `sessionQueue` is idle here: this recorder hasn't run yet.
                try sessionQueue.sync { try openTrack(url, token: token) }
            } catch {
                withState { recording = false; generation += 1 }
                throw error
            }
            sessionQueue.async { self.run(token: token) }
        } else {
            log("mic: asking for microphone permission; the mic track starts once it is granted")
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                self.sessionQueue.async {
                    guard self.isCurrent(token, requireTrack: false) else { return }
                    guard granted else {
                        self.log("mic: microphone permission denied — recording without mic")
                        self.onUnavailable?(RecorderError.permissionDenied)
                        return
                    }
                    do {
                        try self.openTrack(url, token: token)
                    } catch {
                        self.log("mic: cannot start after permission was granted: \(error)")
                        self.onUnavailable?(error)
                        return
                    }
                    self.run(token: token)
                }
            }
        }
        listenForDefaultInputChanges()
    }

    /// Returns quickly: closes the file (complete when this returns — the
    /// transcription reads it right away) and stops the session
    /// asynchronously. Pending restarts / device switches abort.
    func stop() {
        let writer: MicTrackWriter?? = withState {
            guard recording else { return .none }
            recording = false
            trackOpen = false
            generation += 1
            return .some(self.writer)
        }
        guard case .some(let writer) = writer else { return }
        stopListeningForDefaultInputChanges()
        writer?.close()
        sessionQueue.async { self.teardownSession() }
    }

    // MARK: - Session (session queue)

    /// Creates the file and configures the session; on failure leaves no
    /// `mic.caf` behind (so `meta.json` omits the track).
    private func openTrack(_ url: URL, token: Int) throws {
        let newWriter: MicTrackWriter
        do {
            newWriter = try MicTrackWriter(
                url: url,
                clockSource: { [weak self] in self?.session.synchronizationClock },
                log: { [weak self] in self?.log($0) }
            )
        } catch {
            throw RecorderError.fileCreationFailed(error)
        }
        do {
            try configureSession()
        } catch {
            teardownSession()
            newWriter.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        let current = withState { () -> Bool in
            guard recording, generation == token else { return false }
            writer = newWriter
            trackOpen = true
            return true
        }
        if !current { newWriter.close() }
    }

    private func run(token: Int) {
        guard isCurrent(token) else { return }
        observeSession()
        session.startRunning()
        guard isCurrent(token) else { return }
        log("mic: capture session started on \"\(input?.device.localizedName ?? "?")\" "
            + "(isRunning=\(session.isRunning))")
        if let input { diagEvent?(.attached(device: input.device.localizedName)) }
        startWatchdog(token: token)
    }

    private func configureSession() throws {
        guard let device = Self.defaultCaptureDevice() else { throw RecorderError.noInputDevice }
        let newInput: AVCaptureDeviceInput
        do {
            newInput = try AVCaptureDeviceInput(device: device)
        } catch {
            throw RecorderError.sessionSetupFailed(error)
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(newInput) else {
            throw RecorderError.sessionSetupFailed(SetupFailure.cannotAddInput(device.localizedName))
        }
        session.addInput(newInput)
        input = newInput
        // audioSettings = nil: device-native samples; conversion happens in the writer.
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(output) else {
            throw RecorderError.sessionSetupFailed(SetupFailure.cannotAddOutput)
        }
        session.addOutput(output)
    }

    private func teardownSession() {
        watchdog?.cancel()
        watchdog = nil
        deviceCheckGeneration += 1
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if session.isRunning { session.stopRunning() }
        output.setSampleBufferDelegate(nil, queue: nil)
        session.beginConfiguration()
        for existing in session.inputs { session.removeInput(existing) }
        for existing in session.outputs { session.removeOutput(existing) }
        session.commitConfiguration()
        input = nil
    }

    /// The system default input as a capture device (Core Audio UID ==
    /// `AVCaptureDevice.uniqueID` for audio devices), falling back to
    /// AVFoundation's own default.
    private static func defaultCaptureDevice() -> AVCaptureDevice? {
        let id = CoreAudioDevice.defaultDevice(input: true)
        if id != kAudioObjectUnknown, let uid = CoreAudioDevice.uid(id),
           let device = AVCaptureDevice(uniqueID: uid), device.hasMediaType(.audio) {
            return device
        }
        return AVCaptureDevice.default(for: .audio)
    }

    /// Makes the session's input the current default input. Keeps the old
    /// input if the new one can't be added.
    private func bindDefaultInput() {
        guard let device = Self.defaultCaptureDevice() else {
            log("mic: no default input device available")
            return
        }
        if let input, input.device.uniqueID == device.uniqueID, input.device.isConnected { return }
        let newInput: AVCaptureDeviceInput
        do {
            newInput = try AVCaptureDeviceInput(device: device)
        } catch {
            log("mic: cannot open \"\(device.localizedName)\": \(error)")
            return
        }
        let oldName = input?.device.localizedName ?? "none"
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let input { session.removeInput(input) }
        guard session.canAddInput(newInput) else {
            log("mic: capture session refused \"\(device.localizedName)\" — keeping \"\(oldName)\"")
            if let input, session.canAddInput(input) { session.addInput(input) }
            return
        }
        session.addInput(newInput)
        input = newInput
        log("mic: input switched \"\(oldName)\" -> \"\(device.localizedName)\" uid=\(device.uniqueID)")
    }

    /// Recovery restart (watchdog, runtime error, unexpected stop), subject
    /// to `RestartBackoff`. Skipped while interrupted (the interruption-ended
    /// event resumes) or with no input device (connect / default-change
    /// events resume).
    private func restartIfAllowed(reason: String, quietIfDeferred: Bool = false) {
        guard isLive(), !interrupted else { return }
        guard Self.defaultCaptureDevice() != nil else {
            if !waitingForInput { log("mic: \(reason) — no input device; waiting for one to connect") }
            waitingForInput = true
            return
        }
        waitingForInput = false
        let (allowed, delay, attempt) = withState { () -> (Bool, TimeInterval, Int) in
            let allowed = backoff.allow(at: elapsed())
            return (allowed, backoff.currentDelay, backoff.restarts)
        }
        guard allowed else {
            if !quietIfDeferred { log("mic: \(reason) — restart deferred (backoff)") }
            return
        }
        log(String(format: "mic: %@ — restarting capture (attempt %d; next one no sooner than %.0f s)",
                   reason, attempt, delay))
        reattach(fullRestart: true)
    }

    /// Re-binds the default input and makes sure the session runs; the
    /// next buffer pads the gap. `fullRestart` stops the session first.
    private func reattach(fullRestart: Bool) {
        let writer = withState { () -> MicTrackWriter? in
            health.resync(at: elapsed())
            return self.writer
        }
        writer?.markResync()
        if fullRestart, session.isRunning { session.stopRunning() }
        guard isLive() else { return }
        bindDefaultInput()
        if !session.isRunning { session.startRunning() }
        guard isLive() else { return }
        log("mic: capture running on \"\(input?.device.localizedName ?? "?")\" (isRunning=\(session.isRunning))")
        if let input { diagEvent?(.attached(device: input.device.localizedName)) }
    }

    // MARK: - Device tracking (session queue)

    /// Coalesces default-input / connect / disconnect events: after `delay`,
    /// if the default input differs from the bound one (or it disconnected),
    /// switch. Not subject to the restart backoff (a real change must win),
    /// but at most one switch per 5 s so a flapping default can't loop.
    private func scheduleDeviceCheck(after delay: TimeInterval) {
        deviceCheckGeneration += 1
        let token = deviceCheckGeneration
        sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isLive(), self.deviceCheckGeneration == token else { return }
            guard let device = Self.defaultCaptureDevice() else { return }
            self.waitingForInput = false
            let bound = self.input?.device
            if let bound, bound.uniqueID == device.uniqueID, bound.isConnected, self.session.isRunning { return }
            guard self.switchLimiter.allow(at: ProcessInfo.processInfo.systemUptime) else {
                self.scheduleDeviceCheck(after: 1)
                return
            }
            self.log("mic: default input is now \"\(device.localizedName)\" "
                + "(bound: \"\(bound?.localizedName ?? "none")\") — switching")
            self.reattach(fullRestart: false)
        }
    }

    /// The part of a notification the handlers need, extracted on the
    /// posting thread (`Notification` isn't `Sendable`).
    private struct NoteInfo: Sendable {
        var detail = ""
        var audioDevice: (name: String, uid: String)?
    }

    private func observeSession() {
        let center = NotificationCenter.default
        func add(_ name: Notification.Name, object: AnyObject?,
                 _ handle: @escaping @Sendable (CaptureMicRecorder, NoteInfo) -> Void) {
            observers.append(center.addObserver(forName: name, object: object, queue: nil) { [weak self] note in
                guard let self else { return }
                var info = NoteInfo()
                if let error = note.userInfo?[AVCaptureSessionErrorKey] { info.detail = "\(error)" }
                else if let userInfo = note.userInfo { info.detail = "\(userInfo)" }
                if let device = note.object as? AVCaptureDevice, device.hasMediaType(.audio) {
                    info.audioDevice = (device.localizedName, device.uniqueID)
                }
                let captured = info
                self.sessionQueue.async {
                    guard self.isLive() else { return }
                    handle(self, captured)
                }
            })
        }
        add(AVCaptureSession.runtimeErrorNotification, object: session) { me, info in
            me.restartIfAllowed(reason: "capture session runtime error (\(info.detail.isEmpty ? "unknown" : info.detail))")
        }
        add(AVCaptureSession.didStopRunningNotification, object: session) { me, _ in
            // Our own restart stops and restarts synchronously on this queue,
            // so by now the session runs again; only an unexpected stop (or
            // a restart whose start failed) gets here.
            guard !me.session.isRunning else { return }
            me.restartIfAllowed(reason: "capture session stopped", quietIfDeferred: true)
        }
        add(AVCaptureSession.wasInterruptedNotification, object: session) { me, info in
            me.log("mic: capture session interrupted \(info.detail) — waiting for it to end")
            me.interrupted = true
        }
        add(AVCaptureSession.interruptionEndedNotification, object: session) { me, _ in
            me.log("mic: capture session interruption ended")
            me.interrupted = false
            let writer = me.withState { () -> MicTrackWriter? in
                me.health.resync(at: me.elapsed())
                return me.writer
            }
            writer?.markResync()
        }
        add(AVCaptureDevice.wasDisconnectedNotification, object: nil) { me, info in
            guard let device = info.audioDevice else { return }
            me.log("mic: audio device disconnected: \"\(device.name)\" uid=\(device.uid)")
            if device.uid == me.input?.device.uniqueID { me.scheduleDeviceCheck(after: 0.5) }
        }
        add(AVCaptureDevice.wasConnectedNotification, object: nil) { me, info in
            guard let device = info.audioDevice else { return }
            me.log("mic: audio device connected: \"\(device.name)\" uid=\(device.uid)")
            me.scheduleDeviceCheck(after: Self.deviceSettleDelay)
        }
    }

    private func listenForDefaultInputChanges() {
        var address = Self.defaultInputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.sessionQueue.async {
                guard self.isLive() else { return }
                let id = CoreAudioDevice.defaultDevice(input: true)
                self.log("mic: default input changed -> \(CoreAudioDevice.name(id) ?? "none") (id \(id))")
                self.scheduleDeviceCheck(after: Self.deviceSettleDelay)
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
        if status == noErr {
            withState { defaultInputListener = block }
        } else {
            log("mic: cannot listen to default input changes (\(status))")
        }
    }

    /// Removal may wait for an in-flight callback on `listenerQueue`, which
    /// only ever hops *async* to the session queue — no deadlock.
    private func stopListeningForDefaultInputChanges() {
        let block = withState { () -> AudioObjectPropertyListenerBlock? in
            defer { defaultInputListener = nil }
            return defaultInputListener
        }
        guard let block else { return }
        var address = Self.defaultInputAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, listenerQueue, block)
    }

    private static var defaultInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    // MARK: - Watchdog (session queue)

    private func startWatchdog(token: Int) {
        let timer = DispatchSource.makeTimerSource(queue: sessionQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self, self.isCurrent(token) else { return }
            let (silentFor, event, notify) = self.withState {
                () -> (TimeInterval, DeadMicDetector.Event?, Bool) in
                let (silentFor, event) = health.tick(at: elapsed())
                return (silentFor, event, event.map { health.shouldNotify($0) } ?? false)
            }
            if let event { self.report(event, notify: notify) }
            if silentFor > Self.watchdogTimeout {
                self.restartIfAllowed(reason: String(format: "no mic audio for %.1f s", silentFor),
                                      quietIfDeferred: true)
            }
        }
        timer.resume()
        watchdog = timer
    }

    private func report(_ event: DeadMicDetector.Event, notify shouldNotify: Bool) {
        onSignalChange?(MicSignal(event))
        switch event {
        case .dead(let silentFor):
            let threshold = withState { health.detector.threshold }
            log(String(format: "mic: no signal for %.0f s (peak <= %g) — the mic looks dead", silentFor, threshold)
                + (shouldNotify ? "; notifying" : " (already notified this recording)"))
            if shouldNotify { notify(Textos.Notificacion.microfonoMudo, Textos.Notificacion.revisaMicrofono) }
        case .recovered:
            log("mic: signal is back")
        }
    }

    // MARK: - Samples (sample queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pcm = pcmBuffer(from: sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        let state = withState { () -> (MicTrackWriter, Bool)? in
            guard trackOpen, let writer else { return nil }
            return (writer, health.isStalled(at: elapsed()))
        }
        guard let (writer, stalled) = state else { return }
        if stalled { writer.markResync() }
        let result = writer.append(pcm, presentationTime: pts)

        let (event, notify) = withState { () -> (DeadMicDetector.Event?, Bool) in
            let now = elapsed()
            let event: DeadMicDetector.Event?
            switch result {
            case .written(_, let peak):
                event = health.written(peak: peak, at: now)
                backoff.noteAudio(at: now)
            case .failed:
                // Buffers arrive but nothing is written: silence to the
                // detector, and the watchdog keeps counting.
                event = health.conversionFailed(at: now)
            case .buffered, .closed:
                event = nil
            }
            return (event, event.map { health.shouldNotify($0) } ?? false)
        }
        if case .written(let out, let peak) = result { level.publish(peak); diagBuffer?(out) }
        if let event { report(event, notify: notify) }
    }

    /// CMSampleBuffer -> AVAudioPCMBuffer in the sample buffer's own format.
    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0 else { return nil }

        let format: AVAudioFormat
        if let nativeFormat,
           CMFormatDescriptionEqual(nativeFormat.formatDescription, otherFormatDescription: description) {
            format = nativeFormat
        } else {
            format = AVAudioFormat(cmAudioFormatDescription: description)
            nativeFormat = format
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        guard status == noErr else {
            pcmCopyErrors += 1
            if pcmCopyErrors <= 5 { log("mic: PCM copy failed (\(status))") }
            return nil
        }
        return buffer
    }

    // MARK: - Helpers

    private func withState<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock(); defer { stateLock.unlock() }
        return try body()
    }

    /// Seconds since `start`. Caller holds `stateLock`.
    private func elapsed() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime - startUptime
    }

    /// Still the run started with `token` (not stopped since), with its
    /// track open unless `requireTrack` is false.
    private func isCurrent(_ token: Int, requireTrack: Bool = true) -> Bool {
        withState { recording && generation == token && (trackOpen || !requireTrack) }
    }

    /// Recording with an open track (events and restarts only act then).
    private func isLive() -> Bool {
        withState { recording && trackOpen }
    }

    private func log(_ message: String) {
        if let diagEvent {
            diagEvent(.log(message))
        } else {
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }
    }
}
