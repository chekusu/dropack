import Foundation
import Photos
import PhotosUI
import UniformTypeIdentifiers

/// Retains the private PHPicker grant. Its identifier alone is not a PhotoKit
/// authorization grant, especially when the library permission is limited.
struct PhotoPickerSelection: @unchecked Sendable {
    struct Item: @unchecked Sendable {
        let id = UUID()
        let assetIdentifier: String?
        let provider: NSItemProvider
        var kind: MediaKind {
            if provider.canLoadObject(ofClass: PHLivePhoto.self) { return .photo }
            return provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) ? .video : .photo
        }
    }
    let items: [Item]
    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }
    /// An original in-memory item token is safe even when PHPicker supplied no
    /// local ID. New selections must match exact persisted Photos IDs; position,
    /// filename and count are never enough to rebind an interrupted source.
    func resources(for job: PackageJob) throws -> [String: Item] {
        let knownLocalIDs = Set(job.assets.compactMap(\.pickerAssetIdentifier))
        let knownTokens = Set(job.assets.compactMap(\.pickerSelectionItemID))
        var byLocalID: [String: Item] = [:]
        var byToken: [UUID: Item] = [:]
        for selected in items {
            guard knownTokens.contains(selected.id) || selected.assetIdentifier.map({ knownLocalIDs.contains($0) }) == true else {
                if job.assets.contains(where: { $0.pickerResourcePending == true && $0.pickerAssetIdentifier == nil }) {
                    throw PhotoPackageError.pickerReselectionUnavailable
                }
                throw PhotoPackageError.pickerReselectionMismatch
            }
            guard byToken.updateValue(selected, forKey: selected.id) == nil else {
                throw PhotoPackageError.pickerReselectionMismatch
            }
            if let identifier = selected.assetIdentifier, !identifier.isEmpty {
                guard byLocalID.updateValue(selected, forKey: identifier) == nil else {
                    throw PhotoPackageError.pickerReselectionMismatch
                }
            }
        }
        var mapped: [String: Item] = [:]
        var claimedTokens = Set<UUID>()
        for asset in job.assets where asset.pickerResourcePending == true {
            let retained = asset.pickerSelectionItemID.flatMap { byToken[$0] }
            let fresh = asset.pickerAssetIdentifier.flatMap { byLocalID[$0] }
            guard let selected = retained ?? fresh else {
                if asset.pickerAssetIdentifier == nil { throw PhotoPackageError.pickerReselectionUnavailable }
                throw PhotoPackageError.pickerReselectionMismatch
            }
            guard selected.kind == asset.kind, claimedTokens.insert(selected.id).inserted,
                  retained != nil || selected.assetIdentifier == asset.pickerAssetIdentifier else {
                throw PhotoPackageError.pickerReselectionMismatch
            }
            mapped[asset.id] = selected
        }
        return mapped
    }

    var readablePhotoIdentifiers: [String]? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return nil }
        let identifiers = items.compactMap(\.assetIdentifier)
        guard identifiers.count == items.count, Set(identifiers).count == items.count else { return nil }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        return fetched.count == identifiers.count ? identifiers : nil
    }
}
