import SwiftUI

/// One track's meter: the label, a bar for `.level` and "—" for `.unavailable`
/// (a track that is off is not the same as a silent one, which is an empty bar).
struct LevelMeterView: View {
    let label: String
    let display: MeterReading.Display

    static let barHeight: CGFloat = 6

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            switch display {
            case .level(let fraction):
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.quaternary)
                        Capsule()
                            .fill(.green)
                            .frame(width: max(0, geometry.size.width * min(1, max(0, fraction))))
                    }
                }
                .frame(height: Self.barHeight)
            case .unavailable:
                Text(Textos.Pildora.sinSenal)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 14)
    }
}
