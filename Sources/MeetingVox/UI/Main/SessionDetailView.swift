import SwiftUI

/// One session's detail: header, chips and toolbar, the pipeline stepper, and
/// the Resumen / Minuta / Transcripción tabs. It reloads the session's
/// off-main data whenever the entry or its memory facts change.
struct SessionDetailView: View {
    @Bindable var model: MainWindowModel
    let entry: MeetingEntry

    /// What makes the detail's data stale: the entry's markers or the list's
    /// memory facts for it.
    private struct LoadKey: Equatable {
        let entry: MeetingEntry
        let facts: HindsightFacts?
    }

    private func noticeBar(_ message: String) -> some View {
        HStack(spacing: 8) {
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(MainPalette.error)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(Textos.Principal.cerrarAviso) { model.session.dismissNotice() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(MainPalette.accent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
        .background(MainPalette.errorBackground)
    }

    @ViewBuilder private var tabContent: some View {
        let live = model.store.live(for: entry.dir.lastPathComponent)
        let data = model.session.data(for: entry.dir)
        switch model.tab {
        case .resumen:
            ResumenTab(state: ResumenTabState.derive(entry: entry, live: live, summaryApplies: model.session.inputs.summaryApplies))
        case .minuta:
            MinutaTab(
                state: MinutaTabState.derive(
                    entry: entry, live: live, unavailableReason: model.session.inputs.minutesUnavailableReason
                ),
                text: data?.minutesText, loaded: data != nil, templates: model.meetings.templates,
                initialTemplate: MinutaTabState.initialTemplate(
                    model.meetings.templates, sessionChoice: entry.metaTemplateID,
                    configured: model.session.inputs.defaultTemplateID
                ),
                onRetry: { model.session.retry(.minuta, dir: entry.dir) },
                onGenerate: { model.session.generateMinutes(templateID: $0, dir: entry.dir) }
            )
            .id(entry.dir)
        case .transcripcion:
            TranscriptTab(
                state: TranscriptTabState.derive(
                    hasTranscript: entry.hasTranscript, loaded: data != nil, lines: data?.transcriptLines
                ),
                target: model.transcriptLineTarget(for: entry.dir),
                targetNonce: model.transcriptTargetNonce(for: entry.dir),
                playback: model.playback
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            let actions = model.actions(for: entry)
            DetailHeaderView(
                header: model.header(for: entry), actions: actions, session: model.session, dir: entry.dir,
                classify: { model.classify(entry, as: $0) }
            )
            PipelineStepperView(
                steps: model.steps(for: entry), onRetry: { model.session.retry($0, dir: entry.dir) },
                onSend: actions.memory?.quickSend.map { quick in
                    { [status = actions.memory?.status] in
                        model.session.chooseMemory(quick.action, bank: quick.bank, shownAs: status, dir: entry.dir)
                    }
                },
                memoryLine: MemoryStatusLine.text(model.memoryStatus(for: entry), timeZone: model.timeZone)
            )
            if let message = model.session.notice(for: entry.dir) {
                noticeBar(message)
            }
            DetailTabBar(selection: $model.tab)
            tabContent
        }
        .background(MainPalette.window)
        .task(id: LoadKey(entry: entry, facts: model.meetings.facts[entry.dir])) {
            model.session.select(entry.dir)
        }
    }
}
