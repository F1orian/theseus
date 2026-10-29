import SwiftUI
import UIKit

/// The Share extension's entry point (PLAT-04): hosts `ShareView` and talks to the share sheet.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    private let model = ShareModel.live()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        model.cancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        model.openApp = { [weak self] url in await self?.openTheseus(url) ?? false }

        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        let items = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
        Task { await model.load(items) }
    }

    /// Opens Theseus on the stored share. Share extensions have no API of their own for this, so
    /// it asks the host application found up the responder chain. When that isn't possible the
    /// share stays in the inbox and opens the next time Theseus becomes active (ADR 0100).
    private func openTheseus(_ url: URL) async -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                return await application.open(url)
            }
            responder = current.next
        }
        return false
    }
}
