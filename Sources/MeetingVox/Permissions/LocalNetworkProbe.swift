import Foundation

/// Finds out whether the app may reach the Hindsight server on the local
/// network. **The probe itself raises the Local Network prompt**, so it only
/// ever runs from a user click. It is an unauthenticated HEAD to `base_url`
/// (no body is ever downloaded), redirects are not followed, and there is no
/// Keychain read (hence no Keychain prompt). Any HTTP answer, even a 401 or a
/// 3xx, proves the network path is open.
enum LocalNetworkProbe {
    enum Result: Equatable, Sendable {
        /// The server answered over HTTP: permission granted.
        case reachable
        /// -1009: how a denied (or still unanswered) Local Network prompt looks.
        case prohibited
        /// The probe timed out. It only runs after a click, so the prompt is
        /// most likely still waiting for an answer.
        case pending
        /// A completed failure that is not the permission (refused, DNS, ...).
        case unreachable
    }

    static let timeout: TimeInterval = 5

    /// `status`: the HTTP status when there was a response. `urlError`: the
    /// `URLError` code when the transfer failed.
    static func classify(status: Int?, urlError: Int?) -> Result {
        if status != nil { return .reachable }
        if urlError == URLError.notConnectedToInternet.rawValue { return .prohibited }
        if urlError == URLError.timedOut.rawValue { return .pending }
        return .unreachable
    }

    static func request(baseURL: URL) -> URLRequest {
        var request = URLRequest(url: baseURL, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        return request
    }

    /// `fetch` is the transport (faked in tests).
    static func probe(
        baseURL: URL,
        fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    ) async -> Result {
        do {
            let (_, response) = try await fetch(request(baseURL: baseURL))
            return classify(status: (response as? HTTPURLResponse)?.statusCode, urlError: nil)
        } catch {
            return classify(status: nil, urlError: (error as? URLError)?.code.rawValue)
        }
    }

    /// The live transport: an ephemeral session so nothing is cached or
    /// stored, and no redirects. Raises the system prompt; never run by an agent.
    static func probe(baseURL: URL) async -> Result {
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        return await probe(baseURL: baseURL) { try await session.data(for: $0, delegate: RedirectRefuser()) }
    }

    /// Answers every redirect with "don't follow": the 3xx is the answer, and
    /// following it could reach another host.
    final class RedirectRefuser: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
