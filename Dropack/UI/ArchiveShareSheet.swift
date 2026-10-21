import SwiftUI
import UIKit
import UniformTypeIdentifiers
import OSLog

/// A new identity belongs to each invocation, including re-sharing the same file.
struct ArchiveShareRequest: Identifiable {
    let id = UUID()
    let url: URL
    let packageID: UUID
}

/// Keep system sharing outside the generic SwiftUI sheet and its child views.
/// This presenter belongs to this scene's view hierarchy; it never searches for
/// a global window or treats AirDrop covering it as the end of sharing.
struct ArchiveSharePresenter: UIViewControllerRepresentable {
    let request: ArchiveShareRequest?
    let onCompletion: (UUID, String) -> Void

    func makeUIViewController(context: Context) -> ArchiveSharePresentationController {
        ArchiveSharePresentationController()
    }

    func updateUIViewController(_ controller: ArchiveSharePresentationController, context: Context) {
        controller.update(request: request, onCompletion: onCompletion)
    }

    static func dismantleUIViewController(_ controller: ArchiveSharePresentationController, coordinator: ()) {
        controller.detach()
    }
}

@MainActor
final class ArchiveSharePresentationController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private let logger = Logger(subsystem: "app.dropack.ios", category: "ArchiveSharing")
    private var requested: ArchiveShareRequest?
    private var activeRequest: ArchiveShareRequest?
    private var activityController: UIActivityViewController?
    private var completion: ((UUID, String) -> Void)?
    private var terminalResult: String?
    private var finishedRequestID: UUID?
    private var presentationScheduled = false
    private var presenting = false
    private var detached = false

    override func loadView() {
        let anchor = UIView()
        anchor.backgroundColor = .clear
        anchor.isUserInteractionEnabled = false
        view = anchor
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        schedulePresentation()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updatePopoverAnchor()
    }

    func update(request: ArchiveShareRequest?, onCompletion: @escaping (UUID, String) -> Void) {
        requested = request?.id == finishedRequestID ? nil : request
        completion = onCompletion
        if let activeRequest, requested?.id != activeRequest.id {
            DispatchQueue.main.async { [weak self] in self?.withdrawIfRequested() }
        }
        schedulePresentation()
    }

    private func withdrawIfRequested() {
        guard let request = activeRequest, requested?.id != request.id,
              let controller = activityController else { return }
        terminalResult = terminalResult ?? "分享已取消。照片包已保留，随时可以重新发送。"
        // A deliberate request withdrawal is distinct from scene inactivity.
        if !presenting { finishAfterDismissal(controller, requestID: request.id) }
    }

    private func schedulePresentation() {
        guard !detached, !presentationScheduled, activeRequest == nil, requested != nil else { return }
        presentationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.presentationScheduled = false
            self.presentWhenAttached()
        }
    }

    private func presentWhenAttached() {
        guard !detached, let request = requested, activeRequest == nil,
              viewIfLoaded?.window != nil, !isBeingDismissed else { return }
        // A source picker or another scene-local modal must finish first. This
        // does not walk through presented controllers and steal their presenter.
        var ancestor: UIViewController? = self
        while let current = ancestor {
            if let transition = current.transitionCoordinator {
                let registered = transition.animate(alongsideTransition: nil) { [weak self] _ in
                    self?.schedulePresentation()
                }
                if registered { return }
            }
            guard current.presentedViewController == nil, !current.isBeingDismissed else { return }
            ancestor = current.parent
        }
        let controller = UIActivityViewController(activityItems: [ArchiveActivityItem(url: request.url)], applicationActivities: nil)
        activeRequest = request
        activityController = controller
        terminalResult = nil
        if traitCollection.userInterfaceIdiom == .pad {
            controller.modalPresentationStyle = .popover
            controller.popoverPresentationController?.sourceView = view
            controller.popoverPresentationController?.permittedArrowDirections = .up
            updatePopoverAnchor()
        }
        controller.completionWithItemsHandler = { [weak self, weak controller] activity, completed, _, error in
            let result: String
            if let error {
                result = "分享未完成：\(error.localizedDescription) 照片包已保留，可以重试。"
            } else if completed {
                result = activity == .airDrop
                    ? (request.url.pathExtension.lowercased() == PackageFileFormat.dropack.fileExtension
                        ? "系统已返回 AirDrop 分享完成。接收设备安装 Dropack 后，可打开照片包并确认保存到相册。"
                        : "系统已返回 AirDrop 分享完成。接收者可用 Dropack 或其他支持 ZIP 的应用打开。")
                    : "系统已返回分享完成。照片包仍保留在这里；接收后还需要导入相册。"
            } else {
                result = "分享已取消。照片包已保留，随时可以重新发送。"
            }
            let errorCode = (error as NSError?)?.code
            let activityName = activity?.rawValue ?? "none"
            DispatchQueue.main.async {
                guard let self, let controller,
                      self.activeRequest?.id == request.id, self.activityController === controller,
                      self.terminalResult == nil else { return }
                self.logger.info("Activity completion: type=\(activityName, privacy: .public), completed=\(completed), errorCode=\(errorCode ?? 0)")
                self.terminalResult = result
                self.finishAfterDismissal(controller, requestID: request.id)
            }
        }
        controller.presentationController?.delegate = self
        logger.info("Presenting native sharing: idiom=\(self.traitCollection.userInterfaceIdiom.rawValue)")
        presenting = true
        present(controller, animated: true) { [weak self, weak controller] in
            guard let self, let controller, self.activityController === controller else { return }
            self.presenting = false
            controller.presentationController?.delegate = self
            self.logger.info("Native sharing presentation finished")
            if self.terminalResult != nil { self.finishAfterDismissal(controller, requestID: request.id) }
        }
        // UIActivityViewController may prepare its remote UI asynchronously.
        // The presenting relationship can still be nil when present() returns;
        // only the presentation/completion callbacks may end this request.
    }

    private func updatePopoverAnchor() {
        guard let popover = activityController?.popoverPresentationController, isViewLoaded else { return }
        let bounds = view.bounds
        let leading = view.effectiveUserInterfaceLayoutDirection == .rightToLeft
        let x = leading ? min(32, bounds.width / 2) : max(0, bounds.width - 32)
        let y = min(max(view.safeAreaInsets.top + 24, 1), max(bounds.height - 1, 1))
        popover.sourceRect = CGRect(x: x, y: y, width: 1, height: 1)
    }

    /// Only a terminal activity callback or dismissal of this exact controller
    /// ends the request. AirDrop's own presented recipient UI is left alone.
    private func finishAfterDismissal(_ controller: UIActivityViewController, requestID: UUID) {
        guard activeRequest?.id == requestID, activityController === controller else { return }
        if controller.isBeingDismissed, let transition = controller.transitionCoordinator {
            let registered = transition.animate(alongsideTransition: nil) { [weak self, weak controller] context in
                guard let self, let controller else { return }
                if context.isCancelled {
                    self.finishAfterDismissal(controller, requestID: requestID)
                } else {
                    self.finish(requestID: requestID)
                }
            }
            if registered { return }
        }
        if controller.presentingViewController != nil {
            controller.dismiss(animated: true) { [weak self] in self?.finish(requestID: requestID) }
        } else {
            finish(requestID: requestID)
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        guard let controller = activityController,
              presentationController.presentedViewController === controller,
              let requestID = activeRequest?.id else { return }
        logger.info("Native sharing dismissed by user")
        finish(requestID: requestID)
    }

    private func finish(requestID: UUID) {
        guard activeRequest?.id == requestID else { return }
        let result = terminalResult ?? "分享已取消。照片包已保留，随时可以重新发送。"
        finishedRequestID = requestID
        activeRequest = nil
        activityController = nil
        terminalResult = nil
        presenting = false
        if requested?.id == requestID { requested = nil }
        logger.info("Native sharing request finished")
        // A matching request is acknowledged once, after the full modal closes.
        completion?(requestID, result)
        schedulePresentation()
    }

    func detach() {
        detached = true
        requested = nil
        guard let requestID = activeRequest?.id, let controller = activityController else { return }
        logger.info("Sharing presenter removed from its scene")
        controller.dismiss(animated: false) { [weak self] in self?.finish(requestID: requestID) }
    }
}

/// The file extension and the activity item both advertise the document type.
/// Only the URL is passed; no archive bytes are loaded into memory.
final class ArchiveActivityItem: NSObject, UIActivityItemSource {
    let url: URL
    init(url: URL) { self.url = url }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { url }
    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { url }
    func activityViewController(_ activityViewController: UIActivityViewController,
                                dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        (PackageFileFormat(rawValue: url.pathExtension.lowercased()) ?? .zip).contentTypeIdentifier
    }
}
