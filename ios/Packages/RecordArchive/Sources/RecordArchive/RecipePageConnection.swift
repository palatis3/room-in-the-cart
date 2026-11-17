import Darwin
import Foundation
import Network
import Security

/// Each hop resolves once, rejects mixed private/public answers and connects only to a vetted numeric address.
final class RecipePageConnection: @unchecked Sendable {
    private let queue = DispatchQueue(label: "RoomInTheCart.RecipePage")
    private var continuation: CheckedContinuation<RecipePageResponse, Error>?
    private var connection: NWConnection?
    private var cancelled = false
    private var received = Data()

    func load(_ page: URLComponents, deadline: DispatchTime) async throws -> RecipePageResponse {
        guard let host = page.host, DispatchTime.now() < deadline else { throw ArchiveError.unavailable }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { reply in
                queue.async {
                    guard !self.cancelled else { reply.resume(throwing: CancellationError()); return }
                    self.continuation = reply
                    self.queue.asyncAfter(deadline: deadline) { self.finish(.failure(ArchiveError.unavailable)) }
                    DispatchQueue.global(qos: .utility).async {
                        let result = Result { try Self.addresses(for: host) }
                        self.queue.async {
                            guard self.continuation != nil else { return }
                            do { self.connect(try result.get()[...], host: host, page: page) }
                            catch { self.finish(.failure(error)) }
                        }
                    }
                }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                self.finish(.failure(CancellationError()))
            }
        }
    }

    private static func addresses(for host: String) throws -> [NWEndpoint.Host] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var first: UnsafeMutablePointer<addrinfo>?
        // Absolute name prevents a device search domain from replacing the selected host.
        guard getaddrinfo(host + ".", nil, &hints, &first) == 0, let first else { throw ArchiveError.unavailable }
        defer { freeaddrinfo(first) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        var addresses: [NWEndpoint.Host] = []
        while let info = cursor {
            cursor = info.pointee.ai_next
            guard let address = info.pointee.ai_addr else { throw ArchiveError.unavailable }
            let endpoint: NWEndpoint.Host
            if address.pointee.sa_family == AF_INET {
                var v4 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                let bytes = withUnsafeBytes(of: &v4) { Data($0) }
                guard publicIPv4(bytes), let numeric = IPv4Address(bytes) else { throw ArchiveError.invalidRecipe }
                endpoint = .ipv4(numeric)
            } else if address.pointee.sa_family == AF_INET6 {
                var v6 = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in6.self).pointee
                let bytes = withUnsafeBytes(of: &v6.sin6_addr) { Data($0) }
                guard v6.sin6_scope_id == 0, publicIPv6(bytes), let numeric = IPv6Address(bytes) else { throw ArchiveError.invalidRecipe }
                endpoint = .ipv6(numeric)
            } else { throw ArchiveError.invalidRecipe }
            if !addresses.contains(endpoint) { addresses.append(endpoint) }
            guard addresses.count <= 32 else { throw ArchiveError.tooLarge }
        }
        guard !addresses.isEmpty else { throw ArchiveError.unavailable }
        return addresses
    }

    static func publicIPv4(_ bytes: Data) -> Bool {
        let b = Array(bytes)
        guard b.count == 4 else { return false }
        switch (b[0], b[1], b[2]) {
        case (0, _, _), (10, _, _), (127, _, _), (224...255, _, _), (100, 64...127, _),
             (169, 254, _), (172, 16...31, _), (192, 0, 0), (192, 0, 2), (192, 88, 99),
             (192, 168, _), (198, 18...19, _), (198, 51, 100), (203, 0, 113): return false
        default: return true
        }
    }

    static func publicIPv6(_ bytes: Data) -> Bool {
        let b = Array(bytes)
        guard b.count == 16, b[0] & 0xe0 == 0x20 else { return false }
        // Global unicast only. Exclude IETF assignments, documentation and IPv4 transition prefixes.
        return !(b[0] == 0x20 && (b[1] == 0x02 || (b[1] == 0x01 && (b[2] < 2 || (b[2] == 0x0d && b[3] == 0xb8))))) &&
               !(b[0] == 0x3f && b[1] == 0xff && b[2] < 0x10)
    }

    private func connect(_ addresses: ArraySlice<NWEndpoint.Host>, host: String, page: URLComponents) {
        guard let address = addresses.first else { finish(.failure(ArchiveError.unavailable)); return }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
        let socket = NWConnection(host: address, port: .https, using: NWParameters(tls: tls, tcp: .init()))
        connection = socket
        socket.stateUpdateHandler = { [weak self, weak socket] state in
            guard let self, let socket, self.connection === socket else { return }
            switch state {
            case .ready:
                let path = page.percentEncodedPath.isEmpty ? "/" : page.percentEncodedPath
                let target = path + (page.percentEncodedQuery.map { "?" + $0 } ?? "")
                let request = "GET \(target) HTTP/1.1\r\nHost: \(host)\r\nAccept: text/html, application/ld+json, application/json, application/xhtml+xml\r\nAccept-Encoding: identity\r\nConnection: close\r\nUser-Agent: RoomInTheCart-RecipeReader/1\r\n\r\n"
                socket.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    guard self.connection === socket else { return }
                    if error != nil { self.finish(.failure(ArchiveError.unavailable)) } else { self.read(socket) }
                })
            case .failed, .waiting:
                self.connection = nil
                socket.cancel()
                if self.received.isEmpty { self.connect(addresses.dropFirst(), host: host, page: page) }
                else { self.finish(.failure(ArchiveError.unavailable)) }
            default: break
            }
        }
        socket.start(queue: queue)
    }

    private func read(_ socket: NWConnection) {
        socket.receive(minimumIncompleteLength: 1, maximumLength: 32768) { data, _, done, error in
            guard self.connection === socket else { return }
            if let data { self.received.append(data) }
            guard self.received.count <= RecipePageReader.maximumBody + RecipePageReader.maximumHeader else {
                self.finish(.failure(ArchiveError.tooLarge)); return
            }
            if error != nil { self.finish(.failure(ArchiveError.unavailable)) }
            else if done { self.finish(Result { try RecipePageResponse(self.received) }) }
            else { self.read(socket) }
        }
    }

    private func finish(_ result: Result<RecipePageResponse, Error>) {
        guard let reply = continuation else { return }
        continuation = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        received = Data()
        reply.resume(with: result)
    }
}

struct RecipePageResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    init(_ bytes: Data) throws {
        let end = Data("\r\n\r\n".utf8)
        guard let split = bytes.prefix(RecipePageReader.maximumHeader).range(of: end),
              let header = String(data: bytes[..<split.lowerBound], encoding: .isoLatin1) else { throw ArchiveError.invalidRecipe }
        let lines = header.components(separatedBy: "\r\n")
        let statusLine = lines[0].split(separator: " ")
        guard statusLine.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(statusLine[0])),
              let code = Int(statusLine[1]), (200...599).contains(code) else { throw ArchiveError.invalidRecipe }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw ArchiveError.invalidRecipe }
            let name = line[..<colon].lowercased()
            guard ["content-type", "content-length", "transfer-encoding", "content-encoding", "location"].contains(name) else { continue }
            guard fields[name] == nil else { throw ArchiveError.invalidRecipe }
            fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        status = code
        headers = fields
        guard code == 200 else { body = Data(); return }
        let payload = bytes[split.upperBound...]
        guard fields["content-encoding"]?.lowercased() ?? "identity" == "identity" else { throw ArchiveError.invalidRecipe }
        if let transfer = fields["transfer-encoding"] {
            guard fields["content-length"] == nil, transfer.lowercased() == "chunked" else { throw ArchiveError.invalidRecipe }
            body = try Self.chunks(payload)
        } else {
            if let length = fields["content-length"], Int(length) != payload.count { throw ArchiveError.invalidRecipe }
            guard payload.count <= RecipePageReader.maximumBody else { throw ArchiveError.tooLarge }
            body = Data(payload)
        }
    }

    private static func chunks(_ payload: Data.SubSequence) throws -> Data {
        let newline = Data("\r\n".utf8)
        var rest = payload, output = Data()
        while let header = rest.prefix(1024).range(of: newline) {
            let size = rest[..<header.lowerBound].prefix { $0 != 59 }
            guard !size.isEmpty, size.count <= 8, size.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                  let count = Int(String(decoding: size, as: UTF8.self), radix: 16) else { throw ArchiveError.invalidRecipe }
            rest = rest[header.upperBound...]
            if count == 0 {
                guard rest == newline else { throw ArchiveError.invalidRecipe }
                return output
            }
            guard count <= RecipePageReader.maximumBody - output.count else { throw ArchiveError.tooLarge }
            guard rest.count >= count + 2, rest.dropFirst(count).starts(with: newline) else { throw ArchiveError.invalidRecipe }
            output.append(contentsOf: rest.prefix(count))
            rest = rest.dropFirst(count + 2)
        }
        throw ArchiveError.invalidRecipe
    }
}
