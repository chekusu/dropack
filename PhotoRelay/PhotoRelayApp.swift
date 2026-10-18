import SwiftUI

@main
@MainActor
struct PhotoRelayApp: App {
    @StateObject private var controller: ImportController
    @StateObject private var packageController: PackageController
    @StateObject private var inbox = IncomingArchiveInbox()
    @StateObject private var liveActivities: TransferLiveActivityCoordinator
    @StateObject private var activityBridge: TransferLiveActivityBridge
    @StateObject private var preferences = AppPreferences.shared

    init() {
        let importer = ImportController()
        let package = PackageController()
        let activities = TransferLiveActivityCoordinator()
        _controller = StateObject(wrappedValue: importer)
        _packageController = StateObject(wrappedValue: package)
        _liveActivities = StateObject(wrappedValue: activities)
        _activityBridge = StateObject(wrappedValue: TransferLiveActivityBridge(
            package: package, importer: importer, coordinator: activities))
    }

    var body: some Scene {
        WindowGroup {
            ContentView(controller: controller, package: packageController, inbox: inbox,
                        liveActivities: liveActivities, activityBridge: activityBridge)
                .tint(RelayTheme.accent)
                .environment(\.locale, preferences.locale)
                .environment(\.layoutDirection, preferences.layoutDirection)
                .preferredColorScheme(preferences.preferredColorScheme)
                .onOpenURL { inbox.receive($0) }
                .task {
#if DEBUG
                    // Explicit, visible QA entry. It only opens the real import flow;
                    // it never grants permission or starts saving automatically.
                    let arguments = ProcessInfo.processInfo.arguments
                    if let index = arguments.firstIndex(of: "-dropack-import"),
                       arguments.indices.contains(index + 1), !inbox.didOpenTestSource {
                        inbox.didOpenTestSource = true
                        inbox.isTestMode = true
                        inbox.receive(URL(fileURLWithPath: arguments[index + 1]))
                    }
                    if let index = arguments.firstIndex(of: "-dropack-url"),
                       arguments.indices.contains(index + 1), !inbox.didOpenTestURL,
                       let url = URL(string: arguments[index + 1]) {
                        inbox.didOpenTestURL = true
                        inbox.isTestMode = true
                        inbox.receive(url)
                    }
#endif
                }
        }
    }
}

/// Keep the security scope alive while the user finishes another task or reviews
/// replacement. A file-open event must never silently discard the active job.
@MainActor
final class IncomingArchiveInbox: ObservableObject {
    @Published private(set) var sources: [PendingSource] = []
    @Published var isTestMode = false
    var didOpenTestSource = false
    var didOpenTestURL = false
    @Published var activityRequest: ActivityNavigationRequest?
    @Published var albumNavigationRequest: AlbumNavigationRequest?

    func receive(_ url: URL) {
        if let destination = ActivityTaskDestination(url: url) {
            activityRequest = ActivityNavigationRequest(destination: destination)
            return
        }
        if let destination = AlbumDestination(url: url) {
            albumNavigationRequest = AlbumNavigationRequest(destination: destination)
            return
        }
        guard url.isFileURL else { return }
        guard !sources.contains(where: { $0.url == url }) else { return }
        sources.append(PendingSource(url: url))
    }

    func remove(_ source: PendingSource) {
        sources.removeAll { $0.id == source.id }
    }
}

struct ActivityNavigationRequest: Identifiable {
    let id = UUID()
    let destination: ActivityTaskDestination
}

final class PendingSource: Identifiable {
    let id = UUID()
    let url: URL
    let relink: Bool
    private var scoped: Bool

    init(url: URL, relink: Bool = false) {
        self.url = url
        self.relink = relink
        scoped = url.startAccessingSecurityScopedResource()
    }

    func releaseScope() {
        guard scoped else { return }
        url.stopAccessingSecurityScopedResource()
        scoped = false
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
}
