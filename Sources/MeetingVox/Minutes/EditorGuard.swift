import Foundation

/// The rule behind "you have unsaved changes": moving from the open document
/// to another one while the open one is dirty needs a confirmation, because
/// the move drops the edit. Anything else goes straight through. Pure, so the
/// Biblioteca editors (and any future one) share one answer.
enum EditorGuard {
    enum Decision: Equatable, Sendable {
        case proceed
        case confirmDiscard
    }

    /// - Parameters:
    ///   - current: the document open now (nil = none).
    ///   - target: the document being asked for (nil = leaving to none).
    static func decide(isDirty: Bool, current: String?, target: String?) -> Decision {
        guard isDirty, current != target else { return .proceed }
        return .confirmDiscard
    }
}
