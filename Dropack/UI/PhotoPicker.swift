import PhotosUI
import SwiftUI

struct PhotoPicker: UIViewControllerRepresentable {
    let onSelect: (PhotoPickerSelection, String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
        configuration.selectionLimit = 0
        // Ordered selection disables the system picker's swipe-to-select gesture.
        // Keep confirmation on Add; continuous modes instead deliver on every tap.
        configuration.selection = .default
        configuration.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onSelect: (PhotoPickerSelection, String?) -> Void
        init(onSelect: @escaping (PhotoPickerSelection, String?) -> Void) { self.onSelect = onSelect }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            // Keep the provider objects until the package has captured durable
            // resources; assetIdentifier may refer to an inaccessible library item.
            let selection = PhotoPickerSelection(items: results.map {
                .init(assetIdentifier: $0.assetIdentifier, provider: $0.itemProvider)
            })
            onSelect(selection, nil)
        }
    }
}
