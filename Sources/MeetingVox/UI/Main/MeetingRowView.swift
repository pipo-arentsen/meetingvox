import SwiftUI

/// One row of the meeting list: title, then `time · duration · app`
/// with at most one status pill and the ámbito dot.
struct MeetingRowView: View {
    let entry: MeetingEntry
    let pill: StatusPill?
    let timeZone: TimeZone
    /// Why the row matched through its transcript or minutes text (nil for a
    /// summary match or no search): a line of text under the meta, highlighted.
    var hit: SearchHit? = nil
    /// Tapping the snippet opens the session at that text.
    var onOpenHit: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(MeetingRowMeta.title(summaryTitle: entry.summary?.title, calendarTitle: entry.calendarEvent?.title))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            HStack(spacing: 6) {
                Text(MeetingRowMeta.text(
                    started: entry.started, ended: entry.ended, durationSeconds: entry.durationSeconds,
                    app: entry.app, timeZone: timeZone
                ))
                .font(.system(size: 12))
                .foregroundStyle(MainPalette.muted)
                .lineLimit(1)
                .truncationMode(.tail)
                // The app name outranks the pill: the pill's label gives way.
                .layoutPriority(1)
                if let pill {
                    StatusPillView(pill: pill, truncates: true)
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(MainPalette.dot(for: entry.ambito))
                    .frame(width: 8, height: 8)
                    .help(entry.ambito?.label ?? Textos.Indice.sinClasificar)
                    .accessibilityLabel(MeetingRowMeta.ambitoAccessibilityLabel(entry.ambito))
            }
            if let hit {
                SnippetButton(hit: hit, onOpen: onOpenHit)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The snippet under a row: the matched text with every query token marked,
/// up to two lines. A plain button so it does not steal the row's selection.
private struct SnippetButton: View {
    let hit: SearchHit
    let onOpen: (() -> Void)?

    var body: some View {
        Button { onOpen?() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Image(systemName: hit.source == .transcript ? "text.quote" : "doc.text")
                    .font(.system(size: 10))
                Text(SnippetText.attributed(hit.snippet))
                    .font(.system(size: 11.5))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(MainPalette.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(hit.source == .transcript ? Textos.Principal.coincidenciaEnTranscripcion : Textos.Principal.coincidenciaEnMinuta)
    }
}

enum SnippetText {
    /// The snippet as styled text: each highlight bold, in the accent colour,
    /// on a soft background. A range that does not map (never expected) is skipped.
    static func attributed(_ snippet: SearchSnippet) -> AttributedString {
        var text = AttributedString(snippet.text)
        for range in snippet.highlights {
            guard let r = Range(range, in: text) else { continue }
            text[r].font = .system(size: 11.5, weight: .bold)
            text[r].foregroundColor = MainPalette.accent
            text[r].backgroundColor = MainPalette.accentBackground
        }
        return text
    }
}
