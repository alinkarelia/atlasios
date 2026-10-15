import Foundation

/// Only exact trusted HTTPS application pages can hold the WebView session.
struct URLPolicy {
    enum Destination: Equatable { case application, external, blocked }
    func destination(for url: URL) -> Destination {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return .blocked }
        if host == "archiverf.ru" {
            if ["/aveli/connect", "/aveli/mail"].contains(url.path) || url.path.hasPrefix("/aveli/api/") { return .application }
            if url.path == "/aveli" || url.path.hasPrefix("/aveli/") { return .blocked }
        }
        if ["archiverf.ru", "mail.archiverf.ru"].contains(host) { return .external }
        return .blocked
    }
    func isApplicationURL(_ url: URL?) -> Bool { url.map { destination(for: $0) == .application } ?? false }
    func isApplicationBlobURL(_ url: URL, sourceURL: URL?) -> Bool {
        guard url.scheme == "blob", isApplicationURL(sourceURL), let inner = URL(string: String(url.absoluteString.dropFirst(5))) else { return false }
        return inner.scheme == "https" && inner.host == "archiverf.ru" && inner.user == nil && inner.password == nil && (inner.port == nil || inner.port == 443)
    }
    func permitsMediaOrigin(scheme: String, host: String, port: Int) -> Bool {
        scheme == "https" && host.lowercased() == "archiverf.ru" && (port == 0 || port == 443)
    }
}
