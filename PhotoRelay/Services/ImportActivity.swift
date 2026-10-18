import Combine
import Foundation

/// Byte/preview changes redraw only the small task presentation, not the album
/// grid or root navigation. Durable item transitions remain on ImportController.
@MainActor
final class ImportActivity: ObservableObject {
    @Published var currentFile = ""
    @Published var currentFraction: Double = 0
    @Published var currentStage = ""
    @Published var currentReadBytes: UInt64 = 0
    @Published var currentTotalBytes: UInt64 = 0
    @Published var isSavingToPhotos = false
    @Published var activePreview: ImportPreview?
    @Published var recentSavedPreviews: [ImportPreview] = []
    @Published var savedPreviewSequence: UInt64 = 0
    var lastSavedPreview: ImportPreview? { recentSavedPreviews.first }
}
