import ActivityKit
import Foundation

/// Compile this file into both the app and its WidgetKit extension. The payload
/// contains task counts, resource progress and language only; no filenames, URLs,
/// bookmarks or photos.
public struct TransferActivityAttributes: ActivityAttributes, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case packaging
        case importing

        public var title: String { title(language: L10n.resolvedLanguageCode) }
        public func title(language: String) -> String {
            switch self {
            case .packaging: return L10n.translate("照片打包", language: language)
            case .importing: return L10n.translate("存入相册", language: language)
            }
        }
    }

    public enum Stage: String, Codable, Hashable, Sendable {
        case running
        case paused
        case finished
        case failed
    }

    public struct ContentState: Codable, Hashable, Sendable {
        public var completed: Int
        public var total: Int
        public var stage: Stage
        public var languageCode: String?
        /// Fraction of the current resource's processing stage. Optional for
        /// compatibility with existing activities and import tasks without one.
        public var currentFraction: Double?
        /// Actual bytes read when the source has not supplied a total size.
        /// This never implies a percentage or a resumable byte checkpoint.
        public var currentReadBytes: UInt64?

        public init(completed: Int, total: Int, stage: Stage, languageCode: String? = nil,
                    currentFraction: Double? = nil, currentReadBytes: UInt64? = nil) {
            self.total = max(0, total)
            self.completed = min(max(0, completed), self.total)
            self.stage = stage
            self.languageCode = languageCode ?? L10n.resolvedLanguageCode
            self.currentFraction = currentFraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
            self.currentReadBytes = currentReadBytes
        }

        // Clamp again when rendering: synthesized Decodable does not use init.
        public var displayedTotal: Int { max(0, total) }
        public var displayedCompleted: Int { min(max(0, completed), displayedTotal) }
        public var progress: Double {
            guard displayedTotal > 0 else { return 0 }
            // Item progress plus the current resource stage; this is not a
            // byte-weighted total. Never retain provisional work after pausing.
            let fraction = stage == .running && displayedCompleted < displayedTotal
                ? displayedCurrentFraction ?? 0 : 0
            return (Double(displayedCompleted) + fraction) / Double(displayedTotal)
        }

        public var displayedCurrentFraction: Double? {
            guard currentReadBytes == nil else { return nil }
            return currentFraction.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        }

        public var displayedReadBytes: UInt64? { stage == .running ? currentReadBytes : nil }
        public var readBytesText: String? { displayedReadBytes.map(TransferByteCountText.string) }
        public var isReadingUnknownTotal: Bool { displayedReadBytes != nil }

        public func statusLabel(for kind: Kind) -> String {
            let language = languageCode ?? L10n.resolvedLanguageCode
            switch stage {
            case .running:
                if isReadingUnknownTotal { return L10n.translate("读取当前文件", language: language) }
                guard displayedTotal > 0 else { return L10n.translate("准备中", language: language) }
                return L10n.translate(kind == .packaging ? "打包中" : "存入中", language: language)
            case .paused: return L10n.translate("已暂停", language: language)
            case .finished: return L10n.translate(kind == .packaging ? "已就绪" : "已存入", language: language)
            case .failed: return L10n.translate("需处理", language: language)
            }
        }
    }

    public let jobID: UUID
    public let kind: Kind

    public init(jobID: UUID, kind: Kind) {
        self.jobID = jobID
        self.kind = kind
    }

    public var deepLink: URL {
        // All components are generated from a closed enum and UUID.
        URL(string: "dropack://activity/\(kind.rawValue)/\(jobID.uuidString)")!
    }
}

/// Shared by the app and widget so a genuine byte counter has one compact format.
public enum TransferByteCountText {
    public static func string(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }
}
