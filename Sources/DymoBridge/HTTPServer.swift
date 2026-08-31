import Foundation
import Network
import Security

// Minimal HTTP/1.1 server over Network.framework, loopback-only, optional TLS.
// The only client is the DYMO JS framework running in a local browser, so this
// handles exactly what that sends: GET/POST/OPTIONS with Content-Length bodies.

struct HTTPRequest {
    var method: String
    var path: String          // decoded, no query string
    var query: [String: String]
    var headers: [String: String]  // keys lowercased
    var body: Data

    // application/x-www-form-urlencoded body (what the DYMO framework POSTs)
    var formParams: [String: String] {
        guard let s = String(data: body, encoding: .utf8) else { return [:] }
        return HTTPRequest.parseURLEncoded(s)
    }

    static func parseURLEncoded(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in s.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let k = String(kv[0]).removingPercentEncodingPlus else { continue }
            let v = kv.count > 1 ? (String(kv[1]).removingPercentEncodingPlus ?? "") : ""
            out[k] = v
        }
        return out
    }
}

extension String {
    var removingPercentEncodingPlus: String? {
        replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}

struct HTTPResponse {
    var status = 200
    var statusText = "OK"
    var contentType = "text/plain; charset=utf-8"
    var headers: [String: String] = [:]
    var body = Data()

    init(status: Int = 200, contentType: String = "text/plain; charset=utf-8", body: String) {
        self.status = status
        self.statusText = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Error")
        self.contentType = contentType
        self.body = body.data(using: .utf8) ?? Data()
    }
    init(status: Int = 200, contentType: String, data: Data) {
        self.status = status
        self.statusText = status == 200 ? "OK" : "Error"
        self.contentType = contentType
        self.body = data
    }
}

enum TLSIdentity {

    // Loads an SSL-server identity already present in the keychain (e.g. the
    // one DYMO's installer imports into the System keychain as CN=localhost
    // with open access). Prefers an identity the system actually trusts for
    // SSL, since that is exactly what Chrome will evaluate.
    static func loadFromKeychain(commonName: String) throws -> SecIdentity {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnRef as String: true,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let items = result as? [AnyObject], !items.isEmpty else {
            throw NSError(domain: "DymoBridge", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "no keychain identities (status \(status))"])
        }
        var fallback: SecIdentity?
        for item in items {
            let identity = item as! SecIdentity
            var certOpt: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certOpt) == errSecSuccess,
                  let cert = certOpt,
                  let cn = SecCertificateCopySubjectSummary(cert) as String?,
                  cn == commonName else { continue }
            let policy = SecPolicyCreateSSL(true, commonName as CFString)
            var trustOpt: SecTrust?
            if SecTrustCreateWithCertificates(cert, policy, &trustOpt) == errSecSuccess,
               let trust = trustOpt, SecTrustEvaluateWithError(trust, nil) {
                Log.info("using system-trusted keychain identity CN=\(cn)")
                return identity
            }
            if fallback == nil { fallback = identity }
        }
        if let f = fallback {
            Log.info("using keychain identity CN=\(commonName) (not system-trusted — browser may warn)")
            return f
        }
        throw NSError(domain: "DymoBridge", code: -2,
                      userInfo: [NSLocalizedDescriptionKey: "no keychain identity with CN=\(commonName)"])
    }

    // Imports the p12 into a throwaway keychain created fresh at each launch.
    // Importing into the login keychain is a trap: the private key's ACL binds
    // to the exact binary that first imported it, so any rebuilt/upgraded
    // binary silently hangs in the TLS handshake waiting on a permission
    // dialog no background process can show. A fresh temp keychain gives the
    // current binary a fresh ACL every time.
    private static func makeScratchKeychain() -> SecKeychain? {
        let dir = ("~/Library/Application Support/DymoBridge" as NSString).expandingTildeInPath
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Sweep scratch keychains from previous runs.
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for entry in entries where entry.hasPrefix("scratch-") && entry.hasSuffix(".keychain") {
                try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(entry))
            }
        }
        let path = (dir as NSString).appendingPathComponent("scratch-\(getpid()).keychain")
        var password = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, password.count, &password) == errSecSuccess else { return nil }
        var keychain: SecKeychain?
        let status = path.withCString { cPath in
            SecKeychainCreate(cPath, UInt32(password.count), &password, false, nil, &keychain)
        }
        guard status == errSecSuccess else {
            Log.error("scratch keychain creation failed (status \(status)) — falling back to default keychain")
            return nil
        }
        return keychain
    }

    static func load(p12Path: String, passPath: String) throws -> SecIdentity {
        let p12 = try Data(contentsOf: URL(fileURLWithPath: p12Path))
        let pass = (try? String(contentsOf: URL(fileURLWithPath: passPath), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var items: CFArray?
        var options: [String: Any] = [kSecImportExportPassphrase as String: pass]
        if let scratch = makeScratchKeychain() {
            options[kSecImportExportKeychain as String] = scratch
        }
        let opts = options as CFDictionary
        let status = SecPKCS12Import(p12 as CFData, opts, &items)
        guard status == errSecSuccess,
              let arr = items as? [[String: Any]],
              let first = arr.first,
              let identityAny = first[kSecImportItemIdentity as String] else {
            throw NSError(domain: "DymoBridge", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "SecPKCS12Import failed (status \(status))"])
        }
        return (identityAny as! SecIdentity)
    }
}

final class HTTPServer {
    typealias Handler = (HTTPRequest) -> HTTPResponse
    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "dymo-bridge.server")

    init(port: UInt16, identity: SecIdentity?, handler: @escaping Handler) throws {
        self.handler = handler
        let params: NWParameters
        if let identity = identity {
            let tls = NWProtocolTLS.Options()
            guard let secIdentity = sec_identity_create(identity) else {
                throw NSError(domain: "DymoBridge", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "sec_identity_create failed"])
            }
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
            params = NWParameters(tls: tls)
        } else {
            params = NWParameters.tcp
        }
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: NWEndpoint.Port(rawValue: port)!)
        self.listener = try NWListener(using: params)
    }

    func start() throws {
        listener.stateUpdateHandler = { state in
            if case .failed(let err) = state {
                Log.error("listener failed: \(err)")
                exit(1)
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.serve(conn)
        }
        listener.start(queue: queue)
    }

    private func serve(_ conn: NWConnection) {
        conn.stateUpdateHandler = { state in
            if case .failed = state { conn.cancel() }
        }
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self = self else { conn.cancel(); return }
            var buf = buffer
            if let data = data { buf.append(data) }
            if error != nil { conn.cancel(); return }

            if let (request, remainder) = Self.parse(buf) {
                let response = self.handler(request)
                self.send(conn, response: response, keepAlive: !isComplete) {
                    if isComplete {
                        conn.cancel()
                    } else {
                        self.readRequest(conn, buffer: remainder)
                    }
                }
            } else if isComplete {
                conn.cancel()
            } else if buf.count > 8 << 20 {
                Log.error("request too large; dropping connection")
                conn.cancel()
            } else {
                self.readRequest(conn, buffer: buf)
            }
        }
    }

    // Returns (request, leftover bytes) once a full request is buffered.
    private static func parse(_ buf: Data) -> (HTTPRequest, Data)? {
        guard let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: buf[..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        let method = String(requestLine[0]).uppercased()
        let target = String(requestLine[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let k = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerEnd.upperBound
        guard buf.count - bodyStart >= contentLength else { return nil }
        let body = buf.subdata(in: bodyStart..<(bodyStart + contentLength))
        let remainder = buf.subdata(in: (bodyStart + contentLength)..<buf.count)

        var path = target
        var query: [String: String] = [:]
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            query = HTTPRequest.parseURLEncoded(String(target[target.index(after: q)...]))
        }
        path = path.removingPercentEncoding ?? path

        return (HTTPRequest(method: method, path: path, query: query, headers: headers, body: body), remainder)
    }

    private func send(_ conn: NWConnection, response: HTTPResponse, keepAlive: Bool, then: @escaping () -> Void) {
        var head = "HTTP/1.1 \(response.status) \(response.statusText)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n"
        head += "Access-Control-Allow-Headers: Content-Type, Accept, Cache-Control, Pragma\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
        for (k, v) in response.headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(response.body)
        conn.send(content: out, completion: .contentProcessed { error in
            if error != nil { conn.cancel() } else { then() }
        })
    }
}
