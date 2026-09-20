import Foundation
import Network

/// Minimal local HTTP API: `GET http://127.0.0.1:<port>/<command>?key=value…` returns JSON.
/// Bound to the loopback interface only and not running unless enabled in settings.
final class HTTPServer {
    static let shared = HTTPServer()

    private var listener: NWListener?
    private var port: UInt16?
    private var retries = 0
    private let queue = DispatchQueue(label: "app.ekran.http")

    var isRunning: Bool { listener != nil }

    /// Starts, stops or moves the listener to match the settings. The token is read per request,
    /// so changing it never restarts the server.
    func reload() {
        let settings = SettingsStore.shared.value
        let wantedPort = settings.httpEnabled ? UInt16(clamping: settings.httpPort) : nil
        guard wantedPort != port || (wantedPort != nil && listener == nil) else { return }
        retries = 0
        if let listener {
            // Wait until the old socket is released before binding again.
            listener.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state { DispatchQueue.main.async { self?.start(wantedPort) } }
            }
            listener.cancel()
            self.listener = nil
            port = nil
        } else {
            start(wantedPort)
        }
    }

    private func start(_ wantedPort: UInt16?) {
        guard let wantedPort, let endpointPort = NWEndpoint.Port(rawValue: wantedPort), listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpointPort)
            parameters.acceptLocalOnly = true
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard case let .failed(error) = state else { return }
                Log.automation.error("HTTP server failed: \(error.localizedDescription)")
                listener?.cancel()
                DispatchQueue.main.async { self?.retryAfterFailure(port: wantedPort) }
            }
            listener.start(queue: queue)
            self.listener = listener
            port = wantedPort
            Log.automation.info("HTTP API on 127.0.0.1:\(wantedPort)")
        } catch {
            Log.automation.error("HTTP server could not start: \(error.localizedDescription)")
            retryAfterFailure(port: wantedPort)
        }
    }

    private func retryAfterFailure(port failedPort: UInt16) {
        guard port == failedPort || port == nil else { return }
        listener = nil
        port = nil
        guard retries < 5 else { return }
        retries += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, SettingsStore.shared.value.httpEnabled,
                  UInt16(clamping: SettingsStore.shared.value.httpPort) == failedPort else { return }
            self.start(failedPort)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
                self.respond(to: header, on: connection)
            } else if isComplete || buffer.count > 65_536 {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to header: String, on connection: NWConnection) {
        let lines = header.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "POST",
              var components = URLComponents(string: "http://localhost" + parts[1])
        else {
            send(status: "400 Bad Request", body: ["ok": false, "error": "bad request"], on: connection)
            return
        }

        DispatchQueue.main.async {
            let token = SettingsStore.shared.value.httpToken
            if !token.isEmpty {
                let authorization = lines.first { $0.lowercased().hasPrefix("authorization:") }
                let bearer = authorization.map { $0.dropFirst("authorization:".count).trimmingCharacters(in: .whitespaces) }
                    .map { $0.hasPrefix("Bearer ") ? String($0.dropFirst(7)) : $0 }
                let queryToken = components.queryItems?.first { $0.name == "token" }?.value
                guard bearer == token || queryToken == token else {
                    self.queue.async { self.send(status: "401 Unauthorized", body: ["ok": false, "error": "invalid token"], on: connection) }
                    return
                }
            }
            components.queryItems = components.queryItems?.filter { $0.name != "token" }
            let command = components.path.split(separator: "/").first.map(String.init) ?? "help"
            var params: [String: String] = [:]
            for item in components.queryItems ?? [] { params[item.name.lowercased()] = item.value ?? "" }

            let response = CommandRouter.execute(command: command, params: params)
            let json = (try? JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
            let ok = response["ok"] as? Bool ?? false
            self.queue.async { self.send(status: ok ? "200 OK" : "422 Unprocessable Entity", json: json, on: connection) }
        }
    }

    private func send(status: String, body: [String: Any], on connection: NWConnection) {
        let json = (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        send(status: status, json: json, on: connection)
    }

    private func send(status: String, json: Data, on connection: NWConnection) {
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(json)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
