import SwiftUI

/// The Resumen tab (DT-1): the summary, its topics as chips and the
/// participants on the left, the meeting's tasks on the right (an empty
/// column says whether they were never extracted or there were none). Draws
/// `ResumenTabState`.
struct ResumenTab: View {
    let state: ResumenTabState

    var body: some View {
        switch state {
        case .summary(let summary):
            ScrollView {
                TwoColumns {
                    summaryColumn(summary)
                    tasksColumn(TasksColumnState.of(summary))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
            }
        case .generating:
            TabNote(text: Textos.Principal.resumenGenerando)
        case .failed:
            TabNote(text: Textos.Principal.resumenFallo)
        case .none(let applies):
            TabNote(text: applies ? Textos.Principal.resumenAun : Textos.Principal.resumenDesactivado)
        }
    }

    private func summaryColumn(_ summary: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TabLabel(text: Textos.Principal.etiquetaResumen)
            Text(summary.summary)
                .font(.system(size: 14))
                .lineSpacing(3)
                .frame(maxWidth: 520, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            TabLabel(text: Textos.Principal.etiquetaTemas)
            if summary.topics.isEmpty {
                muted(Textos.Principal.sinTemas)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(summary.topics, id: \.self) { TagChip(text: $0) }
                }
            }
            TabLabel(text: Textos.Principal.etiquetaParticipantes)
            if summary.participants.isEmpty {
                muted(Textos.Principal.sinParticipantes)
            } else {
                Text(summary.participants.joined(separator: ", "))
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// The session's tasks: who and what, with the deadline when there is one.
    private func tasksColumn(_ state: TasksColumnState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TabLabel(text: Textos.Principal.etiquetaTareas)
            switch state {
            case .notExtracted:
                emptyBox(Textos.Tareas.columnaSinExtraer)
            case .none:
                emptyBox(Textos.Tareas.columnaSinTareas)
            case .list(let tasks):
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tasks.enumerated()), id: \.offset) { index, task in
                        if index > 0 { Divider() }
                        TaskLine(task: task).padding(.vertical, 8)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func emptyBox(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(MainPalette.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(MainPalette.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
    }

    private func muted(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(MainPalette.muted)
    }
}

/// A topic chip: the sunken capsule the header's chips use.
struct TagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(MainPalette.sunken))
    }
}

/// One task as the Resumen column draws it: the action, then the owner and the
/// deadline underneath ("Sin responsable" when the model named nobody).
struct TaskLine: View {
    let task: MeetingTask

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.what)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 6) {
                if let who = task.who, !who.isEmpty {
                    Text(who).font(.system(size: 11, weight: .semibold))
                } else {
                    Text(Textos.Tareas.sinResponsable).font(.system(size: 11)).foregroundStyle(MainPalette.muted)
                }
                if let when = task.when, !when.isEmpty {
                    Text(Textos.Tareas.para(when)).font(.system(size: 11)).foregroundStyle(MainPalette.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
