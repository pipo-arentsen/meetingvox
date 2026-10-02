import AppKit
import CoreAudio
import Darwin
import Foundation

// MARK: - Core Audio process list

/// Thin Core Audio glue: which processes run audio input right now, and who
/// they are. Reads process metadata only (never audio), needs no permission.
/// Blocking HAL IPC: call it off the main thread (`CoreAudioProcessSource`),
/// except in the `quill diag` CLI.
enum AudioProcesses {
    /// Every process with input running, own PID included (the machine
    /// filters it so diag can show it).
    static func inputProcesses() -> [ProcessIdentity] {
        processObjects().compactMap { object in
            guard isRunningInput(object), let pid = pid(object) else { return nil }
            return identity(object: object, pid: pid)
        }
    }

    static func identity(object: AudioObjectID, pid: pid_t) -> ProcessIdentity {
        let bundleID = string(object, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
        let app = AppResolver.appBundleID(for: pid)
        return ProcessIdentity(pid: pid, bundleID: bundleID, appBundleID: app == bundleID ? nil : app)
    }

    /// `kAudioDevicePropertyDeviceIsRunningSomewhere`: any process (quill
    /// included) doing IO on `device`.
    static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        return uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
    }

    static func isRunningInput(_ object: AudioObjectID) -> Bool {
        uint32(object, kAudioProcessPropertyIsRunningInput) == 1
    }

    static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func pid(_ object: AudioObjectID) -> pid_t? {
        var address = address(kAudioProcessPropertyPID)
        var value = pid_t(0)
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = address(selector)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else {
            return nil
        }
        return value.takeRetainedValue() as String
    }
}

// MARK: - PID → app

/// Maps a (helper) process to the app it belongs to, without AppleScript or
/// any permission:
/// 1. the outermost `*.app` in the executable path (`proc_pidpath`) — a
///    Chromium/Electron helper lives inside its app's bundle;
/// 2. the process macOS holds "responsible" for it (XPC services such as
///    `com.apple.WebKit.GPU` run from a system framework, but their
///    responsible process is Safari) — private libsystem symbol, looked up
///    with `dlsym` and skipped if absent (logged once);
/// 3. the parent process (unless it is launchd).
enum AppResolver {
    static func appBundleID(for pid: pid_t) -> String? {
        if let id = bundleIDFromPath(of: pid) { return id }
        for candidate in [responsiblePID(for: pid), parentPID(of: pid)].compactMap({ $0 })
        where candidate != pid && candidate > 1 {
            if let id = NSRunningApplication(processIdentifier: candidate)?.bundleIdentifier { return id }
            if let id = bundleIDFromPath(of: candidate) { return id }
        }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// Pure: `/Applications/Brave Browser.app/Contents/Frameworks/…/Brave
    /// Browser Helper.app/Contents/MacOS/…` → `/Applications/Brave Browser.app`.
    static func outermostAppBundle(inExecutablePath path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The private responsibility lookup exists on this macOS. When it
    /// doesn't, WebKit capture processes fall back to the generic rule.
    static var responsibilityAvailable: Bool { responsibleFn != nil }

    static let responsibilitySymbol = "responsibility_get_pid_responsible_for_pid"

    private static func bundleIDFromPath(of pid: pid_t) -> String? {
        guard let path = executablePath(of: pid), let app = outermostAppBundle(inExecutablePath: path) else {
            return nil
        }
        return Bundle(url: URL(fileURLWithPath: app, isDirectory: true))?.bundleIdentifier
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        let parent = pid_t(info.pbi_ppid)
        return parent > 1 ? parent : nil
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    /// Lazy and thread-safe (static let), so the "missing" line is logged
    /// once per process.
    private static let responsibleFn: ResponsibleFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), responsibilitySymbol) else {
            FileHandle.standardError.write(Data(
                "meeting detection: \(responsibilitySymbol) not found — WebKit calls resolve to the generic browser rule\n"
                    .utf8))
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    private static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let fn = responsibleFn else { return nil }
        let responsible = fn(pid)
        return responsible > 0 ? responsible : nil
    }
}

// MARK: - Event source

/// Where the detector's observations come from: Core Audio in the app, a
/// fake in tests.
@MainActor
protocol MeetingProcessSource: AnyObject {
    /// Start watching. `onUpdate` gets the processes with input running,
    /// on the main actor: once right away, then after every change. While
    /// started again, only triggers a fresh scan.
    func start(onUpdate: @escaping @MainActor ([ProcessIdentity]) -> Void)
    /// Stop watching: no listeners, no scans, pending updates dropped.
    func stop()
}

/// Event-driven, no polling. Listens to:
/// - the process object list (apps opening/closing audio clients);
/// - each process's `IsRunning` (any I/O) and `IsRunningInput` — catches
///   apps capturing from any device, not only the default input. Measured
///   on macOS 26: Core Audio notifies `IsRunning` but not the per-direction
///   `IsRunningOutput` (and presumably `IsRunningInput`), so input changes
///   of an app that keeps playing audio are missed; `MeetingDetector`
///   rescans while recording to cover that;
/// - the default input's `DeviceIsRunningSomewhere` (re-attached when the
///   default input changes), as a backstop.
/// Every event schedules one coalesced scan on a background serial queue,
/// where all HAL, `proc_pidpath`, `Bundle` and responsibility lookups run;
/// only the resulting list hops to the main actor.
@MainActor
final class CoreAudioProcessSource: MeetingProcessSource {
    private let watcher = Watcher()
    /// Bumped by every start/stop so an update scanned before a stop is dropped.
    private var generation = 0
    private var onUpdate: (@MainActor ([ProcessIdentity]) -> Void)?

    func start(onUpdate: @escaping @MainActor ([ProcessIdentity]) -> Void) {
        let isRunning = self.onUpdate != nil
        self.onUpdate = onUpdate
        if isRunning {
            watcher.rescan()
            return
        }
        generation += 1
        let generation = self.generation
        watcher.start { [weak self] processes in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == generation else { return }
                    self.onUpdate?(processes)
                }
            }
        }
    }

    func stop() {
        guard onUpdate != nil else { return }
        onUpdate = nil
        generation += 1
        watcher.stop()
    }
}

/// All state is confined to `queue` (listener blocks are delivered there too).
private final class Watcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: AppIdentity.queueLabel("meeting-detection"), qos: .utility)

    private var deliver: (@Sendable ([ProcessIdentity]) -> Void)?
    private var systemListeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListener: AudioObjectPropertyListenerBlock?
    /// Process object → its PID (fixed per object) and property listeners.
    private var processes: [AudioObjectID: (pid: pid_t?, listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)])] = [:]
    private static let processSelectors = [kAudioProcessPropertyIsRunning, kAudioProcessPropertyIsRunningInput]
    /// Resolved identity per PID; dropped when the PID leaves the process list.
    private var identities: [pid_t: ProcessIdentity] = [:]
    private var scanScheduled = false

    func start(deliver: @escaping @Sendable ([ProcessIdentity]) -> Void) {
        queue.async { [self] in
            self.deliver = deliver
            addSystemListeners()
            attachDefaultInput()
            scheduleScan()
        }
    }

    func rescan() {
        queue.async { [self] in scheduleScan() }
    }

    func stop() {
        queue.async { [self] in
            deliver = nil
            let system = AudioObjectID(kAudioObjectSystemObject)
            for (selector, block) in systemListeners {
                var address = AudioProcesses.address(selector)
                AudioObjectRemovePropertyListenerBlock(system, &address, queue, block)
            }
            systemListeners = []
            detachDevice()
            for object in Array(processes.keys) { removeProcess(object) }
            identities = [:]
        }
    }

    // MARK: Listeners (on queue)

    private func addSystemListeners() {
        guard systemListeners.isEmpty else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        let handlers: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = [
            (kAudioHardwarePropertyProcessObjectList, { [weak self] _, _ in self?.scheduleScan() }),
            (kAudioHardwarePropertyDefaultInputDevice, { [weak self] _, _ in
                self?.attachDefaultInput()
                self?.scheduleScan()
            }),
        ]
        for (selector, block) in handlers {
            var address = AudioProcesses.address(selector)
            if AudioObjectAddPropertyListenerBlock(system, &address, queue, block) == noErr {
                systemListeners.append((selector, block))
            } else {
                Self.log("meeting detection: cannot listen to system property \(selector)")
            }
        }
    }

    private func attachDefaultInput() {
        let newDevice = CoreAudioDevice.defaultDevice(input: true)
        guard newDevice != device || deviceListener == nil else { return }
        detachDevice()
        device = newDevice
        guard device != kAudioObjectUnknown else { return }
        var address = AudioProcesses.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleScan() }
        if AudioObjectAddPropertyListenerBlock(device, &address, queue, block) == noErr {
            deviceListener = block
        } else {
            Self.log("meeting detection: cannot listen to input device \(device)")
        }
    }

    private func detachDevice() {
        if let block = deviceListener {
            var address = AudioProcesses.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(device, &address, queue, block)
        }
        deviceListener = nil
        device = AudioObjectID(kAudioObjectUnknown)
    }

    /// Match per-process listeners to the current process object list.
    private func reconcile(_ objects: [AudioObjectID]) {
        let current = Set(objects)
        for object in processes.keys where !current.contains(object) { removeProcess(object) }
        for object in objects where processes[object] == nil {
            var listeners: [(AudioObjectPropertySelector, AudioObjectPropertyListenerBlock)] = []
            for selector in Self.processSelectors {
                var address = AudioProcesses.address(selector)
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleScan() }
                if AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr {
                    listeners.append((selector, block))
                }
            }
            processes[object] = (AudioProcesses.pid(object), listeners)
        }
        let livePIDs = Set(processes.values.compactMap(\.pid))
        identities = identities.filter { livePIDs.contains($0.key) }
    }

    private func removeProcess(_ object: AudioObjectID) {
        for (selector, block) in processes[object]?.listeners ?? [] {
            var address = AudioProcesses.address(selector)
            AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
        }
        processes[object] = nil
    }

    // MARK: Scanning (on queue)

    /// Coalesces bursts of events (a call start fires several) into one scan.
    private func scheduleScan() {
        guard deliver != nil, !scanScheduled else { return }
        scanScheduled = true
        queue.async { [self] in
            scanScheduled = false
            scan()
        }
    }

    private func scan() {
        guard let deliver else { return }
        let objects = AudioProcesses.processObjects()
        reconcile(objects)
        let running = objects.compactMap { object -> ProcessIdentity? in
            guard AudioProcesses.isRunningInput(object), let pid = processes[object]?.pid else { return nil }
            if let cached = identities[pid] { return cached }
            let identity = AudioProcesses.identity(object: object, pid: pid)
            identities[pid] = identity
            return identity
        }
        deliver(running)
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
