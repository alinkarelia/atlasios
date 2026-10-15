import Foundation

/// Семейный архив: Живая память — production staff application, remote only.
struct AppConfiguration {
    static let projectName = "Семейный архив: Живая память"
    static let clientID = "aveli"
    static let callback = "archiverf-aveli://oauth/callback"
    let origin = URL(string: "https://archiverf.ru")!
    let policy = URLPolicy()
    var startURL: URL { origin.appendingPathComponent("aveli/connect") }
    var helpURL: URL { URL(string: "https://archiverf.ru/#help")! }
}
