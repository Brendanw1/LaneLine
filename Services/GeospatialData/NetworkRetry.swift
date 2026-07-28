import Foundation

/// Fetches `request`, retrying once on either a connection-level failure
/// (dropped WiFi/cellular, DNS hiccup — the raw request throws, e.g.
/// "could not connect to the server") or a transient HTTP status
/// (429/500/502/503/504). Both are common here: the servers this app talks
/// to are free public instances that occasionally 5xx under load, and a
/// rider's connection can drop and recover mid-ride. A second consecutive
/// failure throws `GeospatialDataError` with `source` attributed, so the
/// rider sees which service failed instead of a generic system message.
func fetchWithTransientRetry(
    _ request: URLRequest,
    session: URLSession,
    source: String,
    attempt: Int = 1
) async throws -> Data {
    do {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeospatialDataError.badResponse(source: source)
        }
        if (200..<300).contains(http.statusCode) {
            return data
        }
        if [429, 500, 502, 503, 504].contains(http.statusCode), attempt < 2 {
            try await Task.sleep(for: .seconds(2))
            return try await fetchWithTransientRetry(
                request, session: session, source: source, attempt: attempt + 1
            )
        }
        throw GeospatialDataError.badResponse(source: source)
    } catch let error as GeospatialDataError {
        throw error
    } catch is CancellationError {
        throw CancellationError()
    } catch {
        guard attempt < 2 else { throw GeospatialDataError.connectionFailed(source: source) }
        try await Task.sleep(for: .seconds(2))
        return try await fetchWithTransientRetry(
            request, session: session, source: source, attempt: attempt + 1
        )
    }
}
