import Foundation
import Testing

@testable import MeetingVox

/// The Local Network probe is an unauthenticated GET: any HTTP answer proves
/// the permission is granted; -1009 is how a denied (or unanswered) prompt
/// looks. Only the pure mapping and the request shape are tested; the live
/// probe would raise the system prompt and is never run by an agent.
@Suite("LocalNetworkProbe")
struct LocalNetworkProbeTests {
    // MARK: - classify

    @Test func anyHTTPStatusIsReachable() {
        for status in [200, 204, 301, 401, 403, 404, 500, 503] {
            #expect(LocalNetworkProbe.classify(status: status, urlError: nil) == .reachable)
        }
    }

    @Test func notConnectedToInternetIsProhibited() {
        #expect(LocalNetworkProbe.classify(status: nil, urlError: URLError.notConnectedToInternet.rawValue) == .prohibited)
        #expect(LocalNetworkProbe.classify(status: nil, urlError: -1009) == .prohibited)
    }

    @Test func otherErrorsAreUnreachable() {
        for code in [URLError.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .badServerResponse] {
            #expect(LocalNetworkProbe.classify(status: nil, urlError: code.rawValue) == .unreachable)
        }
    }

    /// The probe only runs after a click. A timeout then most likely means the
    /// Local Network prompt is still waiting for an answer, so it must not be
    /// reported as a server problem.
    @Test func timedOutMeansThePermissionIsStillPending() {
        #expect(LocalNetworkProbe.classify(status: nil, urlError: URLError.timedOut.rawValue) == .pending)
    }

    @Test func noStatusAndNoErrorIsUnreachable() {
        #expect(LocalNetworkProbe.classify(status: nil, urlError: nil) == .unreachable)
    }

    @Test func aStatusWinsOverAnError() {
        #expect(LocalNetworkProbe.classify(status: 200, urlError: -1009) == .reachable)
    }

    // MARK: - request

    @Test func theRequestIsAnUnauthenticatedHEADWithAFiveSecondTimeout() throws {
        let url = try #require(URL(string: "http://localhost:8888"))
        let request = LocalNetworkProbe.request(baseURL: url)
        #expect(request.url == url)
        // HEAD: the answer is all the probe needs, never a response body.
        #expect(request.httpMethod == "HEAD")
        #expect(request.timeoutInterval == 5)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.allHTTPHeaderFields?.isEmpty ?? true)
    }

    // MARK: - probe over a fake transport

    private func http(_ status: Int, url: URL) -> (Data, URLResponse) {
        (Data(), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }

    @Test func probeMapsAnHTTPAnswerToReachable() async throws {
        let url = try #require(URL(string: "http://hindsight.local:8888"))
        let result = await LocalNetworkProbe.probe(baseURL: url) { _ in self.http(401, url: url) }
        #expect(result == .reachable)
    }

    @Test func probeMapsATransportErrorThroughClassify() async throws {
        let url = try #require(URL(string: "http://hindsight.local:8888"))
        let prohibited = await LocalNetworkProbe.probe(baseURL: url) { _ in throw URLError(.notConnectedToInternet) }
        let unreachable = await LocalNetworkProbe.probe(baseURL: url) { _ in throw URLError(.cannotConnectToHost) }
        let pending = await LocalNetworkProbe.probe(baseURL: url) { _ in throw URLError(.timedOut) }
        #expect(prohibited == .prohibited)
        #expect(unreachable == .unreachable)
        #expect(pending == .pending)
    }

    @Test func probeMapsANonHTTPErrorToUnreachable() async throws {
        struct Boom: Error {}
        let url = try #require(URL(string: "http://hindsight.local:8888"))
        let result = await LocalNetworkProbe.probe(baseURL: url) { _ in throw Boom() }
        #expect(result == .unreachable)
    }

    @Test func probeSendsTheRequestItBuilt() async throws {
        let url = try #require(URL(string: "http://hindsight.local:8888"))
        let seen = Recorder()
        _ = await LocalNetworkProbe.probe(baseURL: url) { request in
            seen.add(request)
            return self.http(200, url: url)
        }
        #expect(seen.requests.count == 1)
        #expect(seen.requests.first == LocalNetworkProbe.request(baseURL: url))
    }

    // MARK: - Redirects

    /// A redirect could send the probe to a different host, on or off the
    /// local network: the 3xx itself is the answer.
    @Test func redirectsAreRefused() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "http://hindsight.local:8888"))
        let task = session.dataTask(with: url)  // never resumed: no network
        let response = try #require(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil))
        final class Answer: @unchecked Sendable {
            var called = false
            var followed: URLRequest? = URLRequest(url: URL(string: "http://placeholder")!)
        }
        let answer = Answer()
        LocalNetworkProbe.RedirectRefuser().urlSession(
            session, task: task, willPerformHTTPRedirection: response, newRequest: URLRequest(url: url)
        ) { next in
            answer.called = true
            answer.followed = next
        }
        #expect(answer.called)
        #expect(answer.followed == nil)
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []
        func add(_ r: URLRequest) { lock.lock(); stored.append(r); lock.unlock() }
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return stored }
    }
}
