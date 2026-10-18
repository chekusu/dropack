import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Opens the original Files item. The importer owns its security-scoped lifetime.
struct SourcePicker: UIViewControllerRepresentable {
    let kind: SourceKind
    let onSelect: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType]
        switch kind {
        case .zip: types = [UTType(exportedAs: PackageFileFormat.typeIdentifier), .zip]
        case .folder: types = [.folder]
        case .mediaFile: types = [.folder, .image, .movie, UTType(exportedAs: PackageFileFormat.typeIdentifier), .zip]
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSelect: (URL) -> Void
        let onCancel: () -> Void

        init(onSelect: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onSelect = onSelect
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onCancel(); return }
            onSelect(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

/// Sending may select several original media files or a folder. No Photos write
/// occurs here; the packaging service takes durable bookmarks before returning.
struct SendSourcePicker: UIViewControllerRepresentable {
    let onSelect: ([URL]) -> Void
    let onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect, onCancel: onCancel) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder, .image, .movie], asCopy: false)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSelect: ([URL]) -> Void
        let onCancel: () -> Void
        init(onSelect: @escaping ([URL]) -> Void, onCancel: @escaping () -> Void) {
            self.onSelect = onSelect; self.onCancel = onCancel
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if urls.isEmpty { onCancel() } else { onSelect(urls) }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onCancel() }
    }
}
