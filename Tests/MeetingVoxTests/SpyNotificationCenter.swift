import Foundation

/// A `NotificationCenter` for tests: block observers are recorded and a post
/// runs the matching blocks **synchronously, on the caller's thread**, so a
/// test can post and assert on the next line with no run-loop turn, no
/// `OperationQueue` hop and no sleeping. It also keeps count of what was added
/// and removed, so "the window removed all three observers on close" is an
/// assertion instead of a wait-and-see.
///
/// Only the block-based API the windows use is supported.
final class SpyNotificationCenter: NotificationCenter, @unchecked Sendable {
    private final class Token: NSObject {
        let name: Notification.Name?
        let block: @Sendable (Notification) -> Void
        init(name: Notification.Name?, block: @escaping @Sendable (Notification) -> Void) {
            self.name = name
            self.block = block
        }
    }

    private let lock = NSLock()
    private var tokens: [Token] = []
    private var _added = 0
    private var _removed = 0

    /// Observers currently registered.
    var activeCount: Int { lock.withLock { tokens.count } }
    /// Observers ever added / removed.
    var addedCount: Int { lock.withLock { _added } }
    var removedCount: Int { lock.withLock { _removed } }
    /// Names of the observers currently registered.
    var activeNames: [Notification.Name] { lock.withLock { tokens.compactMap(\.name) } }

    override func addObserver(
        forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?,
        using block: @escaping @Sendable (Notification) -> Void
    ) -> NSObjectProtocol {
        let token = Token(name: name, block: block)
        lock.withLock {
            tokens.append(token)
            _added += 1
        }
        return token
    }

    override func removeObserver(_ observer: Any) {
        lock.withLock {
            let before = tokens.count
            tokens.removeAll { $0 === (observer as AnyObject) }
            _removed += before - tokens.count
        }
    }

    override func post(_ notification: Notification) {
        let matching = lock.withLock { tokens.filter { $0.name == nil || $0.name == notification.name } }
        for token in matching { token.block(notification) }
    }

    override func post(name aName: NSNotification.Name, object anObject: Any?) {
        post(Notification(name: aName, object: anObject))
    }

    override func post(name aName: NSNotification.Name, object anObject: Any?, userInfo aUserInfo: [AnyHashable: Any]? = nil) {
        post(Notification(name: aName, object: anObject, userInfo: aUserInfo))
    }
}
