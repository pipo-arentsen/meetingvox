import Darwin
import Foundation

/// The private TCC answer for a service, as the SPI reports it.
enum TCCAccessStatus: Equatable, Sendable {
    case granted
    case denied
    /// Anything else the SPI returns (not yet decided).
    case unknown

    /// 0 = authorized, 1 = denied, anything else = not decided. This follows
    /// the return convention community references give for
    /// `TCCAccessPreflight` (0 granted, 1 denied, 2 unknown); it is **not
    /// documented by Apple and unverified on macOS 26**. Only 0 and 1 are
    /// trusted, so a different convention degrades to `unknown` (the row
    /// offers "Permitir" / reads "Solicitado"), never to a false "granted".
    init(raw: Int32) {
        switch raw {
        case 0: self = .granted
        case 1: self = .denied
        default: self = .unknown
        }
    }
}

/// The system-audio permission as far as the private TCC calls can tell.
protocol TCCAccessing: Sendable {
    /// Read-only. `nil` = the SPI is missing on this macOS.
    func preflightAudioCapture() -> TCCAccessStatus?
    /// Raises the prompt when undetermined. The callback's answer, or `nil`
    /// when the SPI is missing (no prompt was raised).
    func requestAudioCapture() async -> Bool?
}

/// `TCCAccessPreflight` / `TCCAccessRequest` from the private TCC framework,
/// resolved with `dlsym` so their absence on some macOS degrades to "no live
/// status" (the row then reads "Solicitado" once clicked) instead of a crash
/// or a link error. Unverified on macOS 26: the fallback is the tap trigger.
struct TCCBridge: TCCAccessing {
    static let audioCaptureService = "kTCCServiceAudioCapture"
    static let frameworkPath = "/System/Library/PrivateFrameworks/TCC.framework/TCC"

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int32
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    /// The prompt can wait as long as the user reads it, but a callback that
    /// never comes must not hang the row forever.
    static let defaultRequestTimeout: TimeInterval = 60

    private let preflight: PreflightFunction?
    private let request: RequestFunction?
    private let requestTimeout: TimeInterval
    private let sleep: @Sendable (TimeInterval) async -> Void

    /// `lookup` finds a symbol by name (`dlsym` on the TCC framework live, a
    /// fake in tests). One log line, at construction, when a symbol is missing.
    /// `sleep` is the deadline's clock, injected so tests never wait.
    init(
        lookup: (String) -> UnsafeMutableRawPointer?,
        log: @Sendable (String) -> Void,
        requestTimeout: TimeInterval = defaultRequestTimeout,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.requestTimeout = requestTimeout
        self.sleep = sleep
        preflight = lookup("TCCAccessPreflight").map { unsafeBitCast($0, to: PreflightFunction.self) }
        request = lookup("TCCAccessRequest").map { unsafeBitCast($0, to: RequestFunction.self) }
        var missing: [String] = []
        if preflight == nil { missing.append("TCCAccessPreflight") }
        if request == nil { missing.append("TCCAccessRequest") }
        if !missing.isEmpty {
            log("system audio: TCC symbol(s) not found (\(missing.joined(separator: ", "))); "
                + "status can't be read without prompting")
        }
    }

    var isAvailable: Bool { preflight != nil && request != nil }

    func preflightAudioCapture() -> TCCAccessStatus? {
        preflight.map { TCCAccessStatus(raw: $0(Self.audioCaptureService as CFString, nil)) }
    }

    /// The callback's answer, or `nil` if it did not come within the deadline
    /// (the caller then re-preflights and falls back to the tap).
    func requestAudioCapture() async -> Bool? {
        guard let request else { return nil }
        let timeout = requestTimeout
        let sleep = self.sleep
        return await withCheckedContinuation { continuation in
            let answer = Answer(continuation)
            request(Self.audioCaptureService as CFString, nil) { granted in answer.finish(granted) }
            answer.arm(Task {
                await sleep(timeout)
                if !Task.isCancelled { answer.finish(nil) }
            })
        }
    }

    /// Loads the framework once (loading it prompts nothing) and resolves
    /// the two symbols.
    static let live: TCCBridge = {
        let handle = dlopen(frameworkPath, RTLD_LAZY)
        return TCCBridge(
            lookup: { name in handle.flatMap { dlsym($0, name) } },
            log: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        )
    }()

    /// Resumes the continuation exactly once, from whichever of the callback
    /// and the deadline comes first, and stops the deadline's timer.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool?, Never>?
        private var timer: Task<Void, Never>?
        private var finished = false

        init(_ continuation: CheckedContinuation<Bool?, Never>) { self.continuation = continuation }

        func finish(_ value: Bool?) {
            let (pending, timer) = lock.withLock { () -> (CheckedContinuation<Bool?, Never>?, Task<Void, Never>?) in
                if finished { return (nil, nil) }
                finished = true
                defer { continuation = nil; self.timer = nil }
                return (continuation, self.timer)
            }
            timer?.cancel()
            pending?.resume(returning: value)
        }

        /// The callback may have answered before the timer existed.
        func arm(_ timer: Task<Void, Never>) {
            let alreadyDone = lock.withLock { () -> Bool in
                if !finished { self.timer = timer }
                return finished
            }
            if alreadyDone { timer.cancel() }
        }
    }
}
