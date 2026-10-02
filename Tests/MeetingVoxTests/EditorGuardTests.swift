import Testing

@testable import MeetingVox

/// The pure rule behind "you have unsaved changes": moving to another
/// document while the current one is dirty needs a confirmation; anything
/// else goes straight through.
@Suite("EditorGuard")
struct EditorGuardTests {
    @Test func aDirtyDocumentAskedToMoveElsewhereNeedsConfirmation() {
        #expect(EditorGuard.decide(isDirty: true, current: "general", target: "daily") == .confirmDiscard)
        #expect(EditorGuard.decide(isDirty: true, current: "general", target: nil) == .confirmDiscard)
        #expect(EditorGuard.decide(isDirty: true, current: nil, target: "daily") == .confirmDiscard)
    }

    @Test func aCleanDocumentMovesFreely() {
        #expect(EditorGuard.decide(isDirty: false, current: "general", target: "daily") == .proceed)
        #expect(EditorGuard.decide(isDirty: false, current: "general", target: nil) == .proceed)
    }

    @Test func choosingTheDocumentAlreadyOpenNeverAsks() {
        #expect(EditorGuard.decide(isDirty: true, current: "general", target: "general") == .proceed)
        #expect(EditorGuard.decide(isDirty: true, current: nil, target: nil) == .proceed)
    }
}
