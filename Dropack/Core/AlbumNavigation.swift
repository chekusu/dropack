import Foundation

public enum AlbumLibrarySection: String, CaseIterable, Hashable, Sendable {
    case sent, received
}

/// Album routes carry the logical album ID, never an export snapshot ID.
/// `importing` is reserved for a standalone import's job ID. Resolving any route
/// is navigation only: it does not select a source or start a Photos write.
public enum AlbumDestination: Hashable, Sendable {
    case library(AlbumLibrarySection)
    case sent(UUID)
    case received(UUID)
    case importing(UUID)

    public init?(url: URL) {
        guard url.scheme?.lowercased() == "dropack",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }

        // Paths contain only fixed ASCII names and UUIDs. Reject encoded or
        // ambiguous separators instead of silently normalizing another route.
        let path = components.percentEncodedPath
        guard !path.contains("%") else { return nil }

        switch url.host?.lowercased() {
        case "albums":
            if path.isEmpty || path == "/" {
                self = .library(.sent)
                return
            }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.first == "", (2...3).contains(parts.count),
                  let section = AlbumLibrarySection(rawValue: String(parts[1])) else { return nil }
            if parts.count == 2 {
                self = .library(section)
            } else {
                guard let id = UUID(uuidString: String(parts[2])) else { return nil }
                self = section == .sent ? .sent(id) : .received(id)
            }
        case "imports":
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts.first == "",
                  let id = UUID(uuidString: String(parts[1])) else { return nil }
            self = .importing(id)
        default:
            return nil
        }
    }

    public var url: URL {
        let path: String
        switch self {
        case .library(let section): path = "albums/\(section.rawValue)"
        case .sent(let id): path = "albums/sent/\(id.uuidString.lowercased())"
        case .received(let id): path = "albums/received/\(id.uuidString.lowercased())"
        case .importing(let id): path = "imports/\(id.uuidString.lowercased())"
        }
        // Every component is a fixed literal, enum raw value, or formatted UUID.
        return URL(string: "dropack://\(path)")!
    }
}

/// Separate deliveries of the same URL remain distinct navigation events.
public struct AlbumNavigationRequest: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let destination: AlbumDestination

    public init(destination: AlbumDestination) {
        id = UUID()
        self.destination = destination
    }
}
