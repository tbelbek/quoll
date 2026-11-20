import Foundation
import Network

public struct WebRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data

    public init(
        method: String,
        path: String,
        query: [String: String],
        headers: [String: String],
        body: Data
    ) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

public struct WebReply: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> WebReply {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return WebReply(
            status: status,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: data
        )
    }

    public static func text(_ value: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> WebReply {
        WebReply(status: status, headers: ["Content-Type": contentType], body: Data(value.utf8))
    }

    public func serialize() -> Data {
        var headers = self.headers
        headers["Content-Length"] = String(body.count)
        headers["Connection"] = "close"

        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 500: reason = "Internal Server Error"
        default: reason = "Status"
        }

        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        data.append(body)
        return data
    }
}

public final class WebServer {
    private let port: UInt16
    private let username: String
    private let password: String
    private let handler: (WebRequest) -> WebReply
    private let queue = DispatchQueue(label: "quoll.http")
    private var listener: NWListener?

    public init(
        port: Int,
        username: String = "",
        password: String = "",
        handler: @escaping (WebRequest) -> WebReply
    ) {
        self.port = UInt16(clamping: port)
        self.username = username
        self.password = password
        self.handler = handler
    }

    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "Quoll.HTTP", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "invalid port \(port)"
            ])
        }
        let listener = try NWListener(using: parameters, on: endpointPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            guard let data, let text = String(data: data, encoding: .utf8),
                  let request = Self.parse(text) else {
                let response = WebReply.text("bad request", status: 400)
                connection.send(content: response.serialize(), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }

            if !self.username.isEmpty {
                let expected = Data("\(self.username):\(self.password)".utf8).base64EncodedString()
                let actual = request.headers["authorization"] ?? ""
                if actual != "Basic \(expected)" {
                    var response = WebReply.text("unauthorized", status: 401)
                    response.headers["WWW-Authenticate"] = "Basic realm=\"Quoll\""
                    connection.send(content: response.serialize(), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }
            }

            let response = self.handler(request)
            connection.send(content: response.serialize(), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    private static func parse(_ text: String) -> WebRequest? {
        let parts = text.components(separatedBy: "\r\n\r\n")
        guard let head = parts.first else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let fields = requestLine.split(separator: " ")
        guard fields.count >= 2 else { return nil }

        let method = String(fields[0])
        let target = String(fields[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let components = URLComponents(string: "http://localhost" + target)
        let path = components?.path ?? "/"
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }

        let body = parts.count > 1 ? Data(parts[1].utf8) : Data()
        return WebRequest(method: method, path: path, query: query, headers: headers, body: body)
    }
}
