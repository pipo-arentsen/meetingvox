import Testing
@testable import MeetingVox

@Suite("SidebarItem")
struct SidebarItemTests {
    @Test func reunionesAndTheAmbitoEntriesMapToTheListFilter() {
        #expect(SidebarItem.reuniones.ambitoFilter == .all)
        #expect(SidebarItem.ambito(.trabajo).ambitoFilter == .only(.trabajo))
        #expect(SidebarItem.ambito(.profesional).ambitoFilter == .only(.profesional))
        #expect(SidebarItem.ambito(.personal).ambitoFilter == .only(.personal))
        #expect(SidebarItem.sinClasificar.ambitoFilter == .unclassified)
    }

    @Test func tareasHasItsOwnPageAndTheLibraryEntriesAreEditorPages() {
        #expect(SidebarItem.tareas.ambitoFilter == nil)
        #expect(!SidebarItem.tareas.isLibrary)
        for item in [SidebarItem.plantillas, .glosario] {
            #expect(item.ambitoFilter == nil, "\(item) must not touch the list filter")
            #expect(item.isLibrary, "\(item)")
        }
        for item in [SidebarItem.reuniones, .ambito(.personal), .sinClasificar] {
            #expect(!item.isLibrary, "\(item)")
        }
    }

    @Test func theSidebarListsEveryEntryInTheMockupOrder() {
        #expect(SidebarItem.ambitoItems == [.ambito(.trabajo), .ambito(.profesional), .ambito(.personal), .sinClasificar])
        #expect(SidebarItem.bibliotecaItems == [.plantillas, .glosario])
    }

    @Test func eachEntryHasItsSpanishLabel() {
        #expect(SidebarItem.reuniones.label == "Reuniones")
        #expect(SidebarItem.tareas.label == "Tareas")
        #expect(SidebarItem.ambito(.trabajo).label == "Trabajo")
        #expect(SidebarItem.sinClasificar.label == "Sin clasificar")
        #expect(SidebarItem.plantillas.label == "Plantillas")
        #expect(SidebarItem.glosario.label == "Glosario")
    }

    @Test func everyEntryHasOneIcon() {
        #expect(SidebarItem.reuniones.icon == "list.bullet")
        #expect(SidebarItem.tareas.icon == "checkmark.square")
        #expect(SidebarItem.plantillas.icon == "doc.text")
        #expect(SidebarItem.glosario.icon == "textformat")
        let all: [SidebarItem] = [.reuniones, .tareas] + SidebarItem.ambitoItems + SidebarItem.bibliotecaItems
        #expect(all.count == 8)
        for item in all {
            #expect(!item.icon.isEmpty, "\(item)")
        }
    }
}
