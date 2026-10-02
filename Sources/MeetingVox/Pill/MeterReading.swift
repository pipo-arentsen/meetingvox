import Foundation

/// Smooths one track's readings for display and decides when the meter shows
/// "—". Pure: `now` is injected.
///
/// "—" comes ONLY from `.unavailable` (the track never started, failed, is the
/// VPIO mic, or was lost) or from `.sample(nil)` persisting for `dashAfter`
/// (no write for that long). A reading of 0 is a real silent track: an empty
/// bar, never a dash.
struct MeterReading: Equatable, Sendable {
    enum Display: Equatable, Sendable {
        case level(Double)
        case unavailable
    }

    /// Fraction lost per second after a peak (rises are instant).
    static let decayPerSecond = 1.5
    /// How long without a single write before the bar turns into "—".
    static let dashAfter: TimeInterval = 1

    private var value = 0.0
    private var lastUpdate: TimeInterval?
    /// Last time a write was seen (or the first update, so a track that never
    /// writes also reaches "—").
    private var lastWrite: TimeInterval?

    mutating func update(_ level: TrackLevel, now: TimeInterval) -> Display {
        let dt = max(0, now - (lastUpdate ?? now))
        lastUpdate = now
        switch level {
        case .unavailable:
            value = 0
            lastWrite = nil
            return .unavailable
        case .sample(let peak?):
            lastWrite = now
            value = max(LevelMeterScale.fraction(peak), value - Self.decayPerSecond * dt)
            return .level(value)
        case .sample(nil):
            let since = lastWrite ?? now
            lastWrite = since
            value = max(0, value - Self.decayPerSecond * dt)
            if now - since >= Self.dashAfter { return .unavailable }
            return .level(value)
        }
    }
}
