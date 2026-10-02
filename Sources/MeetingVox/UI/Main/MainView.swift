import SwiftUI

/// The main window's content: the title strip, then sidebar | list | detail.
/// Selecting Tareas swaps the list and detail for the tasks page (filters |
/// tasks); the Biblioteca entries swap them for their editors (Plantillas:
/// files | editor; Glosario: note and add form | entries).
///
/// `flatColumns` lays the three columns out with plain stacks instead of a
/// `NavigationSplitView`: the headless snapshots cannot draw a split view's
/// sidebar column (it renders as a hole offscreen), everything else is the
/// same views at the same widths.
struct MainView: View {
    @Bindable var model: MainWindowModel
    let onToggleRecording: () -> Void
    var flatColumns = false

    var body: some View {
        VStack(spacing: 0) {
            TitleStrip(state: model.recordButton, onToggle: onToggleRecording)
            Divider()
            if flatColumns {
                flat
            } else {
                split
            }
        }
        .frame(minWidth: MainLayout.minimumSize.width, minHeight: MainLayout.minimumSize.height)
        .background(MainPalette.window)
        .sheet(isPresented: Binding(
            get: { model.trashRequest != nil },
            set: { if !$0 { model.cancelTrash() } }
        )) {
            if let request = model.trashRequest {
                TrashConfirmationView(
                    plan: request.plan, label: { model.trashLabel(for: $0) },
                    cancel: { model.cancelTrash() },
                    confirm: { model.confirmTrash(deleteFromMemory: $0) }
                )
            }
        }
        .alert(
            Textos.Papelera.problemaTitulo,
            isPresented: Binding(get: { model.trashProblem != nil }, set: { if !$0 { model.dismissTrashProblem() } })
        ) {
            Button(Textos.Papelera.entendido) { model.dismissTrashProblem() }
        } message: {
            Text(model.trashProblem ?? "")
        }
    }

    /// The columns are measured at their minimum width by the split view: a
    /// column's content must never need more than the window's height there
    /// (no `.fixedSize(vertical:)` text outside a `ScrollView`), or the title
    /// strip is pushed off screen. `MainWindowSplitLayoutTests` measures it.
    private var split: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(
                    min: MainLayout.sidebarRange.lowerBound, ideal: MainLayout.sidebarWidth, max: MainLayout.sidebarRange.upperBound
                )
        } content: {
            listColumn
                .frame(minHeight: 0, maxHeight: .infinity)
                .navigationSplitViewColumnWidth(
                    min: MainLayout.listRange.lowerBound, ideal: MainLayout.listWidth, max: MainLayout.listRange.upperBound
                )
        } detail: {
            detailColumn
                .frame(minHeight: 0, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var flat: some View {
        HStack(spacing: 0) {
            SidebarView(model: model).frame(width: MainLayout.sidebarWidth)
            Divider()
            listColumn.frame(width: MainLayout.listWidth)
            Divider()
            detailColumn.frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder private var listColumn: some View {
        switch model.sidebar {
        case .plantillas:
            TemplateListView(model: model.library.templates)
        case .glosario:
            GlossaryAddPanel(model: model.library.glossary)
        case .tareas:
            TasksFilterPanel(model: model.tasks)
        default:
            MeetingListView(model: model)
        }
    }

    @ViewBuilder private var detailColumn: some View {
        switch model.sidebar {
        case .plantillas:
            TemplatesEditorView(model: model.library.templates)
        case .glosario:
            GlossaryEntriesView(model: model.library.glossary)
        case .tareas:
            TasksListView(model: model.tasks, timeZone: model.timeZone)
        default:
            DetailAreaView(model: model)
        }
    }
}
