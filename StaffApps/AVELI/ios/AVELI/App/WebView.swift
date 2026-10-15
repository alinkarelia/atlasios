import SwiftUI
import WebKit

@MainActor
struct AVELIWebView: UIViewRepresentable {
    @ObservedObject var session: WebSession

    func makeUIView(context: Context) -> WKWebView {
        session.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct DownloadedFile: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
