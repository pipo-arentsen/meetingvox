import SwiftUI

/// Resumen / Minuta / Transcripción under the stepper: muted labels, the
/// selected one in the primary colour with a 2 pt accent underline, a hairline
/// under the whole row (the approved mockup's `.tabs`).
struct DetailTabBar: View {
    @Binding var selection: DetailTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DetailTab.allCases, id: \.self) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(selected ? Color.primary : MainPalette.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(selected ? MainPalette.accent : Color.clear).frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .background(alignment: .bottom) { Rectangle().fill(MainPalette.line).frame(height: 1) }
    }
}
