import SafariServices
import SwiftUI

/// A web page shown inside the app (Carter, #55006: a box's console in the app, not in the browser). Only https pages.
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// A page to show in a sheet.
struct InAppPage: Identifiable, Equatable {
    let url: URL
    var id: String { url.absoluteString }

    /// Only an https page opens in the app.
    init?(url: URL) {
        guard url.scheme?.lowercased() == "https" else { return nil }
        self.url = url
    }
}
