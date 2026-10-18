import Foundation

// Keep joiners used by emoji and writing systems such as Persian. Foundation's
// controlCharacters also includes these valid formatting scalars.
private let shareAlbumUnsafeControls = CharacterSet.controlCharacters
    .subtracting(CharacterSet(charactersIn: "\u{200C}\u{200D}"))

/// Portable identity for one mutable sharing album and one immutable export of it.
/// A PhotoKit local identifier is deliberately not part of this metadata.
public struct ShareAlbumMetadata: Codable, Equatable, Sendable {
    public static let maximumSenderNameUTF8Bytes = 128
    public var id: UUID
    public var snapshotID: UUID
    public var revision: Int
    public var title: String
    /// A sender-supplied device label, not a verified person or contact identity.
    /// Optional so albums created before this field existed remain readable.
    public var senderName: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), snapshotID: UUID = UUID(), revision: Int = 1,
                title: String, createdAt: Date = Date(), updatedAt: Date? = nil,
                senderName: String? = nil) {
        self.id = id
        self.snapshotID = snapshotID
        self.revision = revision
        self.title = title
        self.senderName = senderName
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    public func validate() throws {
        guard revision > 0,
              !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 768,
              !title.unicodeScalars.contains(where: { shareAlbumUnsafeControls.contains($0) }),
              createdAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt >= createdAt else { throw ShareAlbumError.invalidMetadata }
        if let senderName {
            guard !senderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  senderName.utf8.count <= Self.maximumSenderNameUTF8Bytes,
                  !senderName.unicodeScalars.contains(where: {
                      shareAlbumUnsafeControls.contains($0) || CharacterSet.newlines.contains($0)
                  }) else { throw ShareAlbumError.invalidMetadata }
        }
    }

    /// Membership changes never replace a user-assigned name with a date-derived name.
    /// Every revision gets a new snapshot identity; the logical album stays the same.
    public func revised(title: String? = nil, at date: Date = Date()) throws -> Self {
        try validate()
        guard revision < Int.max, date.timeIntervalSinceReferenceDate.isFinite else {
            throw ShareAlbumError.invalidMetadata
        }
        let result = Self(id: id, revision: revision + 1, title: title ?? self.title,
                          createdAt: createdAt, updatedAt: max(updatedAt, date), senderName: senderName)
        try result.validate()
        return result
    }

    public func renamed(to title: String, at date: Date = Date()) throws -> Self {
        try revised(title: title, at: date)
    }
}

public enum ShareAlbumError: Error, LocalizedError, Sendable {
    case invalidMetadata

    public var errorDescription: String? {
        "分享相册的信息不完整或不受支持。"
    }
}

public enum ShareAlbumNaming {
    /// Bound a system-provided device label without splitting emoji or writing
    /// system joiners. Do not invent a sender when the system returns no name.
    public static func senderName(deviceName: String) -> String? {
        let label = senderNameInput(deviceName).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return label.isEmpty ? nil : label
    }

    /// Safe editable text keeps spaces while typing multiword names. Portable
    /// metadata uses senderName(deviceName:) to remove surrounding whitespace.
    public static func senderNameInput(_ value: String) -> String {
        let cleaned = value.unicodeScalars.map {
            shareAlbumUnsafeControls.contains($0) || CharacterSet.newlines.contains($0) ? " " : String($0)
        }.joined()
        var bounded = ""
        for character in cleaned {
            let fragment = String(character)
            guard bounded.utf8.count + fragment.utf8.count <= ShareAlbumMetadata.maximumSenderNameUTF8Bytes else { break }
            bounded += fragment
        }
        return bounded
    }

    /// Match the sender's local Photos calendar when initially naming an album.
    /// Persist the result in ShareAlbumMetadata; receivers and later revisions do
    /// not recalculate it in a different time zone. Capture time zones are unknown.
    public static func title(dates: [Date], fallback: Date = Date(), timeZone: TimeZone = .current) -> String {
        let validDates = dates.filter { $0.timeIntervalSinceReferenceDate.isFinite }
        let safeFallback = fallback.timeIntervalSinceReferenceDate.isFinite ? fallback : Date(timeIntervalSince1970: 0)
        let first = validDates.min() ?? safeFallback
        let last = validDates.max() ?? first
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let start = formatter.string(from: first)
        let end = formatter.string(from: last)
        return start == end ? start : "\(start) – \(end)"
    }

    /// A friendly single path component suitable for Files and common external
    /// disks. Limits UTF-8 bytes without cutting a composed Unicode character.
    public static func safeFilename(title: String, extension fileExtension: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(shareAlbumUnsafeControls)
        let cleaned = title.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
        var stem = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if stem.isEmpty { stem = "分享相册" }
        var bounded = ""
        for character in stem {
            let fragment = String(character)
            guard bounded.utf8.count + fragment.utf8.count <= 180 else { break }
            bounded += fragment
        }
        bounded = bounded.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if bounded.isEmpty { bounded = "分享相册" }
        let reserved = Set(["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] })
        if reserved.contains(bounded.split(separator: ".").first.map(String.init)?.uppercased() ?? "") {
            bounded = "_" + bounded
        }
        let suffix = fileExtension.lowercased()
        let safeSuffix = !suffix.isEmpty && suffix.utf8.count <= 16 && suffix.utf8.allSatisfy {
            (97...122).contains($0) || (48...57).contains($0)
        } ? suffix : "dropack"
        return "\(bounded).\(safeSuffix)"
    }
}
