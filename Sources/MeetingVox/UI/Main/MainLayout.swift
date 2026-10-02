import CoreGraphics

/// Every measure of the main window that more than one place needs, in one
/// spot: the window controller, `MainView`, the title strip and the
/// snapshots all read these instead of repeating numbers.
enum MainLayout {
    static let defaultSize = CGSize(width: 1280, height: 820)
    static let minimumSize = CGSize(width: 960, height: 600)

    static let sidebarWidth: CGFloat = 220
    static let sidebarRange: ClosedRange<CGFloat> = 180...280
    static let listWidth: CGFloat = 330
    static let listRange: ClosedRange<CGFloat> = 280...420
    /// The detail column never gets narrower than this.
    static let detailMinimumWidth: CGFloat = 420

    static let titleStripHeight: CGFloat = 52
    /// Width the traffic lights need before the title.
    static let trafficLightsInset: CGFloat = 78
}
