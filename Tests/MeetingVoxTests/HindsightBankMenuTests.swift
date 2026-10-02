import Foundation
import Testing
@testable import MeetingVox

@Suite struct HindsightBankMenuTests {
    @Test func singleDefaultBankStillBuildsAOneEntryMenu() throws {
        let menu = try #require(HindsightBankMenu.build(defaultBank: "meetingvox", otherBanks: []))
        #expect(menu.entries.map(\.title) == [Textos.Memoria.bancoPredeterminado("meetingvox")])
        #expect(menu.entries.map(\.bank) == [nil])
        #expect(menu.entries.map(\.isDefault) == [true])
    }

    @Test func defaultFirstThenOthersInServerOrder() throws {
        let menu = try #require(HindsightBankMenu.build(defaultBank: "meetingvox", otherBanks: ["archivo", "clientes"]))
        #expect(menu.entries.map(\.title) == [Textos.Memoria.bancoPredeterminado("meetingvox"), "archivo", "clientes"])
        #expect(menu.entries.map(\.bank) == [nil, "archivo", "clientes"])
        #expect(menu.entries.map(\.isDefault) == [true, false, false])
    }

    @Test func noDefaultStillListsTheOthers() throws {
        let menu = try #require(HindsightBankMenu.build(defaultBank: nil, otherBanks: ["archivo"]))
        #expect(menu.entries.map(\.title) == ["archivo"])
        #expect(menu.entries.map(\.isDefault) == [false])
    }

    @Test func noBankAtAllBuildsNothing() {
        #expect(HindsightBankMenu.build(defaultBank: nil, otherBanks: []) == nil)
    }
}
