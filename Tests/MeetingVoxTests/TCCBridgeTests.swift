import Foundation
import Testing

@testable import MeetingVox

// C stand-ins for the private TCC symbols. The real ones are never called by
// a test: `TCCAccessRequest` can raise the system-audio prompt.
private let fakePreflightDenied: @convention(c) (CFString, CFDictionary?) -> Int32 = { _, _ in 1 }
private let fakePreflightGranted: @convention(c) (CFString, CFDictionary?) -> Int32 = { _, _ in 0 }
private let fakePreflightOther: @convention(c) (CFString, CFDictionary?) -> Int32 = { _, _ in 2 }
private let fakeRequestGrants: @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void = { _, _, done in
    done(true)
}
private let fakeRequestDenies: @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void = { _, _, done in
    done(false)
}

private let fakeRequestNeverAnswers: @convention(c) (CFString, CFDictionary?, @convention(block) (Bool) -> Void) -> Void = { _, _, _ in }

/// Keeps the callback of the request that timed out, to fire it late.
private final class StoredCallback: @unchecked Sendable {
    static let shared = StoredCallback()
    private let lock = NSLock()
    private var block: (@convention(block) (Bool) -> Void)?
    func store(_ b: @escaping @convention(block) (Bool) -> Void) { lock.withLock { block = b } }
    func fire(_ value: Bool) { lock.withLock { block }?(value) }
}
private let fakeRequestStoresCallback: @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void = { _, _, done in
    StoredCallback.shared.store(done)
}

private func pointer<T>(_ function: T) -> UnsafeMutableRawPointer {
    unsafeBitCast(function, to: UnsafeMutableRawPointer.self)
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
}

@Suite("TCCBridge")
struct TCCBridgeTests {
    // MARK: - raw value mapping

    @Test func rawValuesMapToTheStatus() {
        #expect(TCCAccessStatus(raw: 0) == .granted)
        #expect(TCCAccessStatus(raw: 1) == .denied)
    }

    @Test func anyOtherRawValueIsUnknown() {
        for raw: Int32 in [2, 3, -1, 255, Int32.max] {
            #expect(TCCAccessStatus(raw: raw) == .unknown)
        }
    }

    // MARK: - absence

    @Test func absentSymbolsGiveNilAndOneLogLine() async {
        let lines = Lines()
        let bridge = TCCBridge(lookup: { _ in nil }, log: { lines.add($0) })
        #expect(bridge.preflightAudioCapture() == nil)
        #expect(bridge.preflightAudioCapture() == nil)
        let requested = await bridge.requestAudioCapture()
        #expect(requested == nil)
        #expect(lines.all.count == 1)
        #expect(lines.all.first?.contains("TCCAccessPreflight") == true)
        #expect(bridge.isAvailable == false)
    }

    @Test func onlyThePreflightSymbolStillReadsTheStatus() async {
        let lines = Lines()
        let bridge = TCCBridge(
            lookup: { $0 == "TCCAccessPreflight" ? pointer(fakePreflightDenied) : nil },
            log: { lines.add($0) }
        )
        #expect(bridge.preflightAudioCapture() == .denied)
        let requested = await bridge.requestAudioCapture()
        #expect(requested == nil)
        #expect(lines.all.count == 1)
        #expect(lines.all.first?.contains("TCCAccessRequest") == true)
    }

    // MARK: - present

    @Test func presentSymbolsReadAndMapThePreflight() {
        let lines = Lines()
        func bridge(_ preflight: UnsafeMutableRawPointer) -> TCCBridge {
            TCCBridge(
                lookup: { $0 == "TCCAccessPreflight" ? preflight : pointer(fakeRequestGrants) },
                log: { lines.add($0) }
            )
        }
        #expect(bridge(pointer(fakePreflightGranted)).preflightAudioCapture() == .granted)
        #expect(bridge(pointer(fakePreflightDenied)).preflightAudioCapture() == .denied)
        #expect(bridge(pointer(fakePreflightOther)).preflightAudioCapture() == .unknown)
        #expect(bridge(pointer(fakePreflightGranted)).isAvailable)
        #expect(lines.all.isEmpty)
    }

    @Test func theRequestReturnsWhatTheCallbackSaid() async {
        func bridge(_ request: UnsafeMutableRawPointer) -> TCCBridge {
            TCCBridge(
                lookup: { $0 == "TCCAccessRequest" ? request : pointer(fakePreflightGranted) },
                log: { _ in }
            )
        }
        let granted = await bridge(pointer(fakeRequestGrants)).requestAudioCapture()
        let denied = await bridge(pointer(fakeRequestDenies)).requestAudioCapture()
        #expect(granted == true)
        #expect(denied == false)
    }

    @Test func theLookupAsksForTheAudioCaptureServiceSymbolsByName() {
        let names = Lines()
        _ = TCCBridge(lookup: { names.add($0); return nil }, log: { _ in })
        #expect(Set(names.all) == ["TCCAccessPreflight", "TCCAccessRequest"])
        #expect(TCCBridge.audioCaptureService == "kTCCServiceAudioCapture")
    }

    // MARK: - Request deadline

    private func bridge(
        request: UnsafeMutableRawPointer, timeout: TimeInterval = TCCBridge.defaultRequestTimeout,
        sleep: @escaping @Sendable (TimeInterval) async -> Void
    ) -> TCCBridge {
        TCCBridge(
            lookup: { $0 == "TCCAccessRequest" ? request : pointer(fakePreflightGranted) },
            log: { _ in }, requestTimeout: timeout, sleep: sleep
        )
    }

    @Test func theDefaultDeadlineIsSixtySeconds() {
        #expect(TCCBridge.defaultRequestTimeout == 60)
    }

    @Test func aCallbackThatNeverComesTimesOutToNil() async {
        let waited = Lines()
        let result = await bridge(request: pointer(fakeRequestNeverAnswers), timeout: 42) { seconds in
            waited.add("\(seconds)")  // returns at once: the deadline passes
        }.requestAudioCapture()
        #expect(result == nil)
        #expect(waited.all == ["42.0"])
    }

    @Test func aCallbackBeforeTheDeadlineWinsAndStopsTheTimer() async {
        // A sleeper that only ends when cancelled: the answer must not wait for it.
        let granted = await bridge(request: pointer(fakeRequestGrants)) { _ in
            try? await Task.sleep(for: .seconds(3600))
        }.requestAudioCapture()
        let denied = await bridge(request: pointer(fakeRequestDenies)) { _ in
            try? await Task.sleep(for: .seconds(3600))
        }.requestAudioCapture()
        #expect(granted == true)
        #expect(denied == false)
    }

    @Test func aCallbackAfterTheTimeoutIsIgnored() async {
        let result = await bridge(request: pointer(fakeRequestStoresCallback)) { _ in }.requestAudioCapture()
        #expect(result == nil)
        // Must neither crash nor resume the continuation a second time.
        StoredCallback.shared.fire(true)
        StoredCallback.shared.fire(false)
    }
}
