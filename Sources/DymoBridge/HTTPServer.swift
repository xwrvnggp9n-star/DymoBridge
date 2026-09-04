import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

// HTTP/1.1 server on SwiftNIO, loopback-only, TLS from in-memory PEM files.
// No Security.framework/keychain anywhere in the TLS path: on modern macOS,
// keychain-based server identities produce permission dialogs a background
// daemon can never answer (three distinct variants of that trap were hit
// during development — imported-key ACLs pinned to a prior binary, Apple-only
// partition lists on CLI-imported keys, and password prompts for programmatic
// scratch keychains).

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

    init(head: HTTPRequestHead, body: Data) {
        self.method = head.method.rawValue.uppercased()
        self.body = body
        var headers: [String: String] = [:]
        for (name, value) in head.headers { headers[name.lowercased()] = value }
        self.headers = headers

        var path = head.uri
        var query: [String: String] = [:]
        if let q = head.uri.firstIndex(of: "?") {
            path = String(head.uri[..<q])
            query = HTTPRequest.parseURLEncoded(String(head.uri[head.uri.index(after: q)...]))
        }
        self.path = path.removingPercentEncoding ?? path
        self.query = query
    }
}

extension String {
    var removingPercentEncodingPlus: String? {
        replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}

struct HTTPResponse {
    var status = 200
    var reason: String? = nil   // custom reason phrase (the DYMO framework shows xhr.statusText in its errors)
    var contentType = "text/plain; charset=utf-8"
    var headers: [String: String] = [:]
    var body = Data()

    init(status: Int = 200, reason: String? = nil, contentType: String = "text/plain; charset=utf-8", body: String) {
        self.status = status
        self.reason = reason
        self.contentType = contentType
        self.body = body.data(using: .utf8) ?? Data()
    }
    init(status: Int = 200, contentType: String, data: Data) {
        self.status = status
        self.contentType = contentType
        self.body = data
    }
}

private final class HTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let handler: (HTTPRequest) -> HTTPResponse
    private var head: HTTPRequestHead?
    private var body = Data()

    init(handler: @escaping (HTTPRequest) -> HTTPResponse) {
        self.handler = handler
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
            body = Data()
            if body.count < 8 << 20 { body.reserveCapacity(min(Int(h.headers["content-length"].first.flatMap { Int($0) } ?? 0), 8 << 20)) }
        case .body(var buf):
            if body.count < 8 << 20, let bytes = buf.readBytes(length: buf.readableBytes) {
                body.append(contentsOf: bytes)
            }
        case .end:
            guard let h = head else { return }
            let request = HTTPRequest(head: h, body: body)
            head = nil
            body = Data()

            // Handlers can block for seconds (PrintLabel waits for CUPS to finish
            // the job), so run them off the event loop and hop back to write.
            let handler = self.handler
            let loop = context.eventLoop
            DispatchQueue.global(qos: .userInitiated).async {
                let response = handler(request)
                loop.execute { self.write(response, for: h, context: context) }
            }
        }
    }

    private func write(_ response: HTTPResponse, for h: HTTPRequestHead, context: ChannelHandlerContext) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: response.contentType)
        headers.add(name: "Content-Length", value: "\(response.body.count)")
        headers.add(name: "Access-Control-Allow-Origin", value: "*")
        headers.add(name: "Access-Control-Allow-Methods", value: "GET, POST, OPTIONS")
        headers.add(name: "Access-Control-Allow-Headers", value: "Content-Type, Accept, Cache-Control, Pragma")
        for (k, v) in response.headers { headers.add(name: k, value: v) }

        let status: HTTPResponseStatus = response.reason.map { .custom(code: UInt(response.status), reasonPhrase: $0) }
            ?? HTTPResponseStatus(statusCode: response.status)
        let respHead = HTTPResponseHead(version: h.version, status: status, headers: headers)
        let keepAlive = h.isKeepAlive
        context.write(wrapOutboundOut(.head(respHead)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: response.body.count)
        buffer.writeBytes(response.body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        let endPromise: EventLoopPromise<Void>? = keepAlive ? nil : context.eventLoop.makePromise()
        if let p = endPromise {
            p.futureResult.whenComplete { _ in context.close(promise: nil) }
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: endPromise)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Browsers abort keep-alive sockets constantly; only log real oddities.
        if !(error is NIOSSLError) && !(error is IOError) {
            Log.error("http error: \(error)")
        }
        context.close(promise: nil)
    }
}

final class HTTPServer {
    typealias Handler = (HTTPRequest) -> HTTPResponse
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    private let port: UInt16
    private let sslContext: NIOSSLContext?
    private let handler: Handler

    init(port: UInt16, certPath: String?, keyPath: String?, handler: @escaping Handler) throws {
        self.port = port
        self.handler = handler
        if let certPath = certPath, let keyPath = keyPath {
            let certs = try NIOSSLCertificate.fromPEMFile(certPath)
            let key = try NIOSSLPrivateKey(file: keyPath, format: .pem)
            let config = TLSConfiguration.makeServerConfiguration(
                certificateChain: certs.map { .certificate($0) },
                privateKey: .privateKey(key))
            self.sslContext = try NIOSSLContext(configuration: config)
        } else {
            self.sslContext = nil
        }
    }

    func start() throws {
        let sslContext = self.sslContext
        let handler = self.handler
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 64)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let first: EventLoopFuture<Void>
                if let ctx = sslContext {
                    first = channel.pipeline.addHandler(NIOSSLServerHandler(context: ctx))
                } else {
                    first = channel.eventLoop.makeSucceededFuture(())
                }
                return first.flatMap {
                    channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true)
                }.flatMap {
                    channel.pipeline.addHandler(HTTPHandler(handler: handler))
                }
            }
        _ = try bootstrap.bind(host: "127.0.0.1", port: Int(port)).wait()
    }
}
