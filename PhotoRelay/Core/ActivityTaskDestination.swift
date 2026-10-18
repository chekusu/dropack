import Foundation

/// A Live Activity link can only navigate to a known kind of task. It cannot
/// select a source, resume work, delete a package, or start a Photos write.
public struct ActivityTaskDestination: Equatable, Sendable {
    public enum Kind: String, Sendable { case packaging, importing }
    public let kind: Kind
    public let jobID: UUID

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "dropack", url.host == "activity",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, let kind = Kind(rawValue: parts[0]),
              let id = UUID(uuidString: parts[1]) else { return nil }
        self.kind = kind
        jobID = id
    }
}
