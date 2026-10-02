import Foundation

/// Which video service a link belongs to, and whether that is the app the
/// recording was started for. Links are read for matching only and never
/// stored.
enum CalendarVideoLink {
    enum Service: Sendable, Equatable {
        case teams, zoom, meet, webex

        /// `MeetingApp` ids whose calls run inside a browser.
        private static let browserApps: Set<String> = ["browseros", "brave", "safari", "webkit"]

        /// Teams and Zoom have their own app rule; Meet and Webex are web
        /// calls, so any browser rule matches them.
        func matches(meetingApp: String?) -> Bool {
            guard let meetingApp else { return false }
            switch self {
            case .teams: return meetingApp == "teams"
            case .zoom: return meetingApp == "zoom"
            case .meet, .webex: return Self.browserApps.contains(meetingApp)
            }
        }
    }

    /// Host suffixes per service; a host matches when it IS the domain or a
    /// subdomain of it (`example.zoom.us`), never a lookalike (`notzoom.us`).
    private static let domains: [(Service, [String])] = [
        (.teams, ["teams.microsoft.com", "teams.live.com"]),
        (.zoom, ["zoom.us", "zoom.com"]),
        (.meet, ["meet.google.com"]),
        (.webex, ["webex.com"]),
    ]

    static func service(for url: URL) -> Service? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
            let host = url.host?.lowercased()
        else { return nil }
        for (service, suffixes) in domains
        where suffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return service
        }
        return nil
    }

    /// The http(s) links in some free texts (an event's URL and location),
    /// first-seen order, deduped. `NSDataDetector` handles bare links
    /// inside prose; the texts themselves are dropped by the caller.
    static func extract(from texts: [String?]) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<String>()
        var urls: [URL] = []
        for text in texts.compactMap({ $0 }) {
            let range = NSRange(text.startIndex..., in: text)
            for match in detector.matches(in: text, range: range) {
                guard let url = match.url, let scheme = url.scheme?.lowercased(),
                    scheme == "http" || scheme == "https", seen.insert(url.absoluteString).inserted
                else { continue }
                urls.append(url)
            }
        }
        return urls
    }
}
