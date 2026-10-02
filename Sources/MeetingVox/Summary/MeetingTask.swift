import Foundation

/// One action item extracted from a meeting, as stored in `resumen.json`'s
/// `tasks`. `who` stays exactly as the model wrote it ("Yo" included): the
/// speaker ids of the transcript are not resolved here. A nil `who` means the
/// owner is unknown — the Tareas page still lists it.
struct MeetingTask: Codable, Sendable, Equatable, Hashable {
    let who: String?
    let what: String
    let when: String?

    init(who: String?, what: String, when: String?) {
        self.who = who
        self.what = what
        self.when = when
    }

    private enum CodingKeys: String, CodingKey { case who, what, when }

    /// `what` is required; a wrong-typed `who`/`when` reads as nil rather than
    /// failing, so one odd field never costs the whole list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        what = try container.decode(String.self, forKey: .what)
        who = (try? container.decodeIfPresent(String.self, forKey: .who)) ?? nil
        when = (try? container.decodeIfPresent(String.self, forKey: .when)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(who, forKey: .who)
        try container.encode(what, forKey: .what)
        try container.encodeIfPresent(when, forKey: .when)
    }
}
