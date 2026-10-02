import Foundation

/// Peak amplitude -> meter fraction. dBFS mapped linearly from -60...0 onto
/// 0...1: a Bluetooth HFP mic sits near -37 dBFS and must read about 0.38, not
/// as empty (a linear amplitude scale would).
enum LevelMeterScale {
    static let floorDB: Double = -60

    static func fraction(_ peak: Float) -> Double {
        guard peak.isFinite, peak > 1e-6 else { return 0 }  // below ~-120 dBFS: silence
        let db = 20 * log10(Double(peak))
        return min(1, max(0, (db - floorDB) / -floorDB))
    }
}
