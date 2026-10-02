import SwiftUI

/// The Transcripción tab (DT-3): timestamp · Yo/Otros · text, read-only, in a
/// lazy stack so a two-hour meeting scrolls without laying everything out.
/// Words the glossary corrected are underlined with a dotted accent line and
/// the line's hover names what the recognizer wrote. A search hit's
/// `target` line is scrolled into view and drawn as the current line, also
/// when the lines only arrive after the tab (the detail reads them off the
/// main thread). With a `playback` the player bar sits on top, the current
/// line is marked and followed, and the stamp and speaker columns seek (R-B.5,
/// R-B.6). Draws `TranscriptTabState`.
struct TranscriptTab: View {
    let state: TranscriptTabState
    /// `TranscriptViewLine.id` to scroll to and mark; nil = none.
    var target: Int? = nil
    /// Changes on every tap of a snippet, so the same line scrolls again.
    var targetNonce = 0
    /// The session's player; nil = none (snapshots of the plain tab, tests).
    var playback: PlaybackController? = nil

    /// The grid of one line: 52 pt stamp, 48 pt speaker, the rest for the text.
    static let stampWidth: CGFloat = 52
    static let speakerWidth: CGFloat = 48

    var body: some View {
        VStack(spacing: 0) {
            if let playback, PlayerBarText.showsBar(for: playback.gate) {
                PlayerBar(playback: playback)
                Divider()
            }
            content
        }
    }

    @ViewBuilder private var content: some View {
        switch state {
        case .loading: TabNote(text: Textos.Principal.cargandoDetalle)
        case .missing: TabNote(text: Textos.Principal.transcripcionSinArchivo)
        case .unreadable: TabNote(text: Textos.Principal.transcripcionSinLeer)
        case .empty: TabNote(text: Textos.Principal.transcripcionVacia)
        case .lines(let lines): TranscriptLinesView(lines: lines, target: target, targetNonce: targetNonce, playback: playback)
        }
    }
}

/// The scrolling lines. Following the current line is suspended only when the
/// user scrolls (`interacting`, `tracking`, `decelerating`; not `animating`,
/// which is our own `scrollTo`) and resumes at the next seek or Play.
private struct TranscriptLinesView: View {
    let lines: [TranscriptViewLine]
    let target: Int?
    let targetNonce: Int
    let playback: PlaybackController?
    @State private var following = true

    /// The current line is marked once the player has been used in this session.
    private var current: Int? {
        guard let playback, playback.hasMoved || playback.isPlaying else { return nil }
        return playback.currentLine
    }

    private var canSeek: Bool { playback.map { $0.canPlay && $0.timeline.isPlayable } ?? false }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        LineView(
                            line: line, isTarget: line.id == target || line.id == current,
                            onSeek: canSeek ? { playback?.seekToLine(startMs: $0) } : nil
                        )
                    }
                }
                .padding(.vertical, 8)
            }
            .onScrollPhaseChange { _, phase in
                switch phase {
                case .interacting, .tracking, .decelerating: following = false
                default: break
                }
            }
            // On appear (the lines just arrived) and whenever the target
            // changes; a yield lets the lazy stack register its rows first.
            .task(id: [target ?? -1, targetNonce]) {
                guard let target, lines.contains(where: { $0.id == target }) else { return }
                await Task.yield()
                proxy.scrollTo(target, anchor: .center)
            }
            .onChange(of: current) { _, line in
                guard following, playback?.isPlaying == true, let line else { return }
                withAnimation { proxy.scrollTo(line, anchor: .center) }
            }
            .onChange(of: playback?.followEpoch) {
                following = true
                guard let line = current else { return }
                withAnimation { proxy.scrollTo(line, anchor: .center) }
            }
        }
    }
}

/// A line's text as styled text: the glossary's changes dotted-underlined.
enum TranscriptLineText {
    static func attributed(_ line: TranscriptViewLine) -> AttributedString {
        var text = AttributedString(line.text)
        for mark in line.marks {
            guard let range = Range(NSRange(location: mark.location, length: mark.length), in: text) else { continue }
            text[range].underlineStyle = Text.LineStyle(pattern: .dot, color: MainPalette.accent)
            text[range].foregroundColor = MainPalette.accent
        }
        return text
    }
}

private struct LineView: View {
    let line: TranscriptViewLine
    /// A search hit's jump target or the line being played.
    let isTarget: Bool
    /// Seeks to a line's start; nil = the columns are plain text.
    let onSeek: ((Int) -> Void)?

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(line.timestamp)
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(MainPalette.muted)
                .frame(width: TranscriptTab.stampWidth, alignment: .leading)
            Text(line.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(line.speaker == "me" ? MainPalette.accent : MainPalette.ok)
                .frame(width: TranscriptTab.speakerWidth, alignment: .leading)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let onSeek {
                // Only the stamp and speaker are the button: a click on the
                // text must keep selecting it.
                Button { onSeek(line.startMs) } label: { header }
                    .buttonStyle(.plain)
                    .help(Textos.Reproductor.clickEnLinea)
            } else {
                header
            }
            Text(TranscriptLineText.attributed(line))
                .font(.system(size: 13))
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 7)
        .background(isTarget ? MainPalette.accentBackground : Color.clear)
        .help(line.glossaryTooltip.map { "\(Textos.Principal.glosarioCorregido): \($0)" } ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line.rendered)
    }
}
