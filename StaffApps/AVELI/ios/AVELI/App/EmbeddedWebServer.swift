import Foundation
import Network

/// Serves signed, public application assets on the device only. User data stays in
/// WebKit's origin storage; this server exposes no documents, cookies or credentials.
final class EmbeddedWebServer {
    static let port: NWEndpoint.Port = 19473
    static let origin = URL(string: "http://127.0.0.1:19473/")!
    private static let hostHeader = "127.0.0.1:19473"
    private static let maximumHeaderBytes = 16_384
    private static let maximumAssetBytes = 8 * 1_024 * 1_024
    private static let maximumConnections = 32
    private static let startupTimeout: TimeInterval = 8
    private let queue = DispatchQueue(label: "ru.archiverf.aveli.bundled-web")
    private let root: URL?
    private var listener: NWListener?
    private var generation = UUID()
    private var ready = false
    private var completions: [(Result<URL, Error>) -> Void] = []
    private var connections: [UUID: NWConnection] = [:]
    #if DEBUG
    private var networkEvents: [[String: Any]] = []
    private var networkCounts: [String: Int] = [:]
    #endif

    enum StartupError: LocalizedError {
        case missingAssets
        case timedOut
        case stopped
        case unexpectedPort
        var errorDescription: String? {
            switch self {
            case .missingAssets:
                return "В сборке отсутствуют файлы AVELI. Установите обновлённую версию приложения."
            case .timedOut:
                return "Локальное пространство AVELI не запустилось вовремя. Нажмите «Открыть снова». Интернет для открытия не нужен."
            case .stopped:
                return "Запуск AVELI был остановлен. Нажмите «Открыть снова»."
            case .unexpectedPort:
                return "Не удалось подготовить локальный адрес AVELI. Нажмите «Открыть снова»."
            }
        }
        var diagnosticCode: String {
            switch self {
            case .missingAssets: return "BOOT-ASSETS"
            case .timedOut: return "BOOT-TIMEOUT"
            case .stopped: return "BOOT-STOPPED"
            case .unexpectedPort: return "BOOT-PORT"
            }
        }
    }

    init(bundle: Bundle = .main) {
        root = bundle.url(forResource: "WebApp", withExtension: nil)?.resolvingSymlinksInPath()
    }

    deinit {
        listener?.cancel()
        connections.values.forEach { $0.cancel() }
    }

    func start(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.ready { completion(.success(Self.origin)); return }
            guard let root = self.root,
                  FileManager.default.fileExists(atPath: root.appendingPathComponent("index.html").path) else {
                completion(.failure(StartupError.missingAssets)); return
            }
            self.completions.append(completion)
            guard self.listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                // An exact loopback bind, not a wildcard listener on Wi-Fi/mobile interfaces.
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: Self.port)
                // Do not copy interface/accept restrictions into accepted
                // NWConnections; the concrete requiredLocalEndpoint binds us.
                parameters.allowLocalEndpointReuse = false
                // requiredLocalEndpoint already supplies the port. Passing on:
                // as well can make Network.framework reject the listener (EINVAL).
                let listener = try NWListener(using: parameters)
                let generation = UUID()
                self.generation = generation
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    guard self.generation == generation, self.ready else {
                        #if DEBUG
                        self.recordNetworkEvent("accept-rejected-state")
                        #endif
                        connection.cancel()
                        return
                    }
                    self.accept(connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self, self.generation == generation else { return }
                    switch state {
                    case .ready:
                        guard self.listener?.port == Self.port else {
                            self.failStartup(StartupError.unexpectedPort, generation: generation)
                            return
                        }
                        self.ready = true
                        #if DEBUG
                        self.recordNetworkEvent("listener-ready")
                        #endif
                        self.completeStartup(.success(Self.origin))
                    case .waiting(let error), .failed(let error):
                        self.failStartup(error, generation: generation)
                    case .cancelled:
                        self.failStartup(StartupError.stopped, generation: generation)
                    default: break
                    }
                }
                listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + Self.startupTimeout) { [weak self] in
                    guard let self, self.generation == generation, !self.ready else { return }
                    self.failStartup(StartupError.timedOut, generation: generation)
                }
            } catch {
                self.listener = nil
                self.completeStartup(.failure(error))
            }
        }
    }

    /// Runs only on `queue`. Invalidate the generation before cancellation so
    /// late cancelled/ready callbacks cannot affect a retry or complete twice.
    private func failStartup(_ error: Error, generation expectedGeneration: UUID) {
        guard generation == expectedGeneration else { return }
        let failedListener = listener
        generation = UUID()
        ready = false
        listener = nil
        failedListener?.cancel()
        completeStartup(.failure(error))
    }

    private func completeStartup(_ result: Result<URL, Error>) {
        let pending = completions
        completions.removeAll()
        pending.forEach { $0(result) }
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < Self.maximumConnections else {
            #if DEBUG
            recordNetworkEvent("accept-rejected-capacity")
            #endif
            connection.cancel()
            return
        }
        let id = UUID()
        connections[id] = connection
        #if DEBUG
        recordNetworkEvent("accept", id: id)
        #endif
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                #if DEBUG
                self.recordNetworkEvent("connection-ready", id: id)
                #endif
            case .waiting(let error):
                #if DEBUG
                self.recordNetworkEvent("connection-waiting", id: id, error: error)
                #endif
            case .failed(let error):
                #if DEBUG
                self.recordNetworkEvent("connection-failed", id: id, error: error)
                #endif
                self.connections.removeValue(forKey: id)
            case .cancelled:
                #if DEBUG
                self.recordNetworkEvent("connection-closed", id: id)
                #endif
                self.connections.removeValue(forKey: id)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, let expired = self.connections.removeValue(forKey: id) else { return }
            #if DEBUG
            self.recordNetworkEvent("connection-timeout", id: id)
            #endif
            expired.cancel()
        }
        receive(connection, id: id, buffered: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            #if DEBUG
            self.recordNetworkEvent(error == nil ? "receive" : "receive-error", id: id, bytes: data?.count ?? 0, error: error)
            #endif
            var bytes = buffered
            if let data { bytes.append(data) }
            guard bytes.count <= Self.maximumHeaderBytes else {
                self.respond(connection, id: id, status: 431, body: Data("Request headers too large".utf8)); return
            }
            if let delimiter = bytes.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(Data(bytes[..<delimiter.lowerBound]), connection: connection, id: id)
            } else if complete || error != nil {
                self.connections.removeValue(forKey: id)?.cancel()
            } else {
                self.receive(connection, id: id, buffered: bytes)
            }
        }
    }

    private func handle(_ data: Data, connection: NWConnection, id: UUID) {
        guard let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else {
            respond(connection, id: id, status: 400); return
        }
        let lines = text.components(separatedBy: "\r\n")
        let request = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[2] == "HTTP/1.1" || request[2] == "HTTP/1.0" else {
            respond(connection, id: id, status: 400); return
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("\t") else {
                respond(connection, id: id, status: 400); return
            }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, headers[name] == nil else { respond(connection, id: id, status: 400); return }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // This also prevents a foreign web page from DNS rebinding to our local server.
        guard headers["host"] == Self.hostHeader,
              headers["transfer-encoding"] == nil,
              headers["origin"] == nil || headers["origin"] == "http://" + Self.hostHeader else {
            respond(connection, id: id, status: 403); return
        }
        let method = String(request[0])
        let target = String(request[1]).components(separatedBy: "?")[0]
        guard target.hasPrefix("/"), !target.hasPrefix("//"),
              let path = target.removingPercentEncoding,
              !path.contains("\\"), !path.contains("%"), !path.contains("#"),
              !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }) else {
            respond(connection, id: id, status: 400); return
        }
        let declaredLength = headers["content-length"].flatMap(Int.init) ?? 0
        guard declaredLength >= 0, declaredLength <= 65_536,
              headers["content-length"] == nil || Int(headers["content-length"]!) != nil else {
            respond(connection, id: id, status: 413); return
        }
        let head = method == "HEAD"
        if path.hasPrefix("/api/") {
            if (method == "GET" || head) && path == "/api/session" {
                respondJSON(connection, id: id, status: 200, head: head,
                    value: ["mode": "local-demo", "user": NSNull(), "csrf": NSNull(), "remoteConfigured": false])
            } else if (method == "GET" || head) && path == "/api/calls/config" {
                respondJSON(connection, id: id, status: 200, head: head,
                    value: ["mode": "local-demo", "signaling": "same-browser", "iceServers": [],
                            "remoteCallingConfigured": false, "transcriptionConfigured": false])
            } else {
                respondJSON(connection, id: id, status: 503, head: head,
                    value: ["error": "backend_not_connected", "message": "Сервер AVELI пока не подключён. Это локальный прототип."])
            }
            return
        }
        guard method == "GET" || head else { respond(connection, id: id, status: 405); return }
        guard declaredLength == 0 else { respond(connection, id: id, status: 400); return }
        guard let root else { respond(connection, id: id, status: 503); return }
        let relative = path == "/" ? "index.html" : String(path.dropFirst())
        let asset = root.appendingPathComponent(relative).resolvingSymlinksInPath()
        guard asset.path.hasPrefix(root.path + "/"), let mime = Self.mimeTypes[asset.pathExtension.lowercased()],
              let values = try? asset.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= Self.maximumAssetBytes,
              let body = try? Data(contentsOf: asset, options: .mappedIfSafe) else {
            respond(connection, id: id, status: 404, head: head); return
        }
        respond(connection, id: id, status: 200, contentType: mime, body: body, head: head)
    }

    private func respondJSON(_ connection: NWConnection, id: UUID, status: Int, head: Bool, value: [String: Any]) {
        let body = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{}".utf8)
        respond(connection, id: id, status: status, contentType: "application/json; charset=utf-8", body: body, head: head)
    }

    private func respond(_ connection: NWConnection, id: UUID, status: Int,
                         contentType: String = "text/plain; charset=utf-8", body: Data = Data(), head: Bool = false) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed",
                      413: "Content Too Large", 431: "Request Header Fields Too Large", 503: "Service Unavailable"][status] ?? "Error"
        let policy = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' data: blob:; connect-src 'self'; font-src 'self'; worker-src 'none'; object-src 'none'; base-uri 'self'; frame-src 'self'; frame-ancestors 'self'; form-action 'self'"
        let headers = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: \(policy)\r\nPermissions-Policy: camera=(self), microphone=(self)\r\n\r\n"
        var response = Data(headers.utf8)
        if !head { response.append(body) }
        #if DEBUG
        recordNetworkEvent("send", id: id, bytes: response.count, status: status)
        #endif
        // contentProcessed means queued, not acknowledged by the browser.
        // A final message sends a graceful TCP FIN after the response bytes.
        // Retain the connection until the peer closes rather than cancelling
        // immediately and resetting an HTTP response still in flight.
        connection.send(content: response, contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { [weak self] error in
            guard let self, self.connections[id] != nil else { return }
            #if DEBUG
            self.recordNetworkEvent(error == nil ? "send-finished" : "send-error", id: id, error: error)
            #endif
            if error != nil {
                self.connections.removeValue(forKey: id)?.cancel()
            } else {
                self.waitForPeerClose(connection, id: id)
            }
        })
    }

    private func waitForPeerClose(_ connection: NWConnection, id: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] _, _, complete, error in
            guard let self, self.connections[id] != nil else { return }
            if complete || error != nil {
                #if DEBUG
                self.recordNetworkEvent(error == nil ? "peer-closed" : "peer-close-error", id: id, error: error)
                #endif
                self.connections.removeValue(forKey: id)?.cancel()
            } else {
                // A request body can remain unread after its headers. It is
                // discarded, never parsed or logged; the 8-second cap remains.
                self.waitForPeerClose(connection, id: id)
            }
        }
    }

    #if DEBUG
    /// Bounded native transport evidence, usable even when no HTML loads.
    /// Fixed event labels, byte counts and NW codes only: no paths or payloads.
    private func recordNetworkEvent(_ kind: String, id: UUID? = nil, bytes: Int? = nil,
                                    status: Int? = nil, error: NWError? = nil) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        var event: [String: Any] = ["kind": kind, "at": timestamp]
        if let id { event["connectionID"] = id.uuidString }
        if let bytes { event["bytes"] = bytes }
        if let status { event["statusCode"] = status }
        if let error {
            switch error {
            case .posix(let code): event["errorCode"] = "NW-POSIX-\(code.rawValue)"
            case .dns(let code): event["errorCode"] = "NW-DNS-\(code)"
            case .tls(let code): event["errorCode"] = "NW-TLS-\(code)"
            @unknown default: event["errorCode"] = "NW-UNKNOWN"
            }
        }
        networkEvents.append(event)
        if networkEvents.count > 32 { networkEvents.removeFirst(networkEvents.count - 32) }
        networkCounts[kind, default: 0] += 1
        var requestID: Any = NSNull()
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--aveli-preview-request"), arguments.indices.contains(index + 1),
           UUID(uuidString: arguments[index + 1]) != nil { requestID = arguments[index + 1] }
        let snapshot: [String: Any] = [
            "schema": "aveli.network.v1", "requestID": requestID,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "buildNumber": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "updatedAt": timestamp, "listenerReady": ready, "listenerGeneration": generation.uuidString,
            "activeConnections": connections.count, "counts": networkCounts, "events": networkEvents
        ]
        guard let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("aveli-network.json"), options: [.atomic])
    }
    #endif

    private static let mimeTypes = [
        "html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8", "json": "application/json; charset=utf-8",
        "webmanifest": "application/manifest+json; charset=utf-8", "png": "image/png",
        "svg": "image/svg+xml", "jpg": "image/jpeg", "jpeg": "image/jpeg",
        "webp": "image/webp", "ico": "image/x-icon", "woff2": "font/woff2"
    ]
}
