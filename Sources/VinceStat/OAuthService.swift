import AppKit
import CryptoKit
import Foundation
import Network

/// VinceStat 자체 OAuth 토큰 쌍.
struct OAuthTokens {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date?
}

enum OAuthError: LocalizedError {
    /// 루프백 콜백 서버를 띄우지 못함
    case listenerFailed(String)
    /// 제한 시간 내에 리다이렉트가 오지 않음 (브라우저에서 로그인을 마치지 않은 경우)
    case timedOut
    /// authorize 단계에서 오류/거부
    case denied(String)
    /// state 불일치 — 다른 로그인 시도의 응답
    case stateMismatch
    /// refresh token 이 무효 — 다시 로그인해야 한다
    case invalidGrant(String)
    case server(Int, String?)
    case badResponse
    /// 붙여넣기 로그인을 시작하지 않은 상태에서 코드를 넣음
    case noPendingLogin

    var errorDescription: String? {
        switch self {
        case .listenerFailed(let detail):
            return "로컬 콜백 서버를 열지 못했습니다 — \(detail)"
        case .timedOut:
            return "로그인이 완료되지 않았습니다 (제한 시간 초과)"
        case .denied(let detail):
            return "로그인이 거부되었습니다 — \(detail)"
        case .stateMismatch:
            return "로그인 응답의 state 가 일치하지 않습니다 — 다시 시도해 주세요"
        case .invalidGrant(let detail):
            return "저장된 로그인이 만료되었습니다 — 다시 로그인해 주세요 (\(detail))"
        case .server(let code, let detail):
            return "토큰 발급 실패 (HTTP \(code))" + (detail.map { " · \($0)" } ?? "")
        case .badResponse:
            return "토큰 응답을 해석하지 못했습니다"
        case .noPendingLogin:
            return "먼저 인증 페이지를 열어 주세요"
        }
    }
}

/// Claude Code 와 같은 public OAuth 클라이언트로 **VinceStat 전용** access/refresh 토큰 쌍을 받는다.
///
/// Claude Code 의 토큰을 빌려 쓰지 않기 때문에
/// - `Claude Code-credentials` Keychain 항목을 다시 읽을 일이 없고(= 허용 대화상자가 없고),
/// - refresh token 로테이션이 Claude Code 로그인 세션을 건드리지 않는다.
///
/// 엔드포인트·client_id·파라미터 구성은 Claude Code 2.1.226 의 로그인 플로우에서 확인한 값이다
/// (`CLAUDE_AI_AUTHORIZE_URL`, `TOKEN_URL`, `MANUAL_REDIRECT_URL`, `CLIENT_ID`).
final class OAuthService {
    /// Claude Code CLI 의 public client. client-id metadata document URL 은 이 엔드포인트가
    /// 받지 않는다 — UUID 만 유효하다.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    /// Claude 구독 계정 로그인용 authorize (콘솔/API 계정은 platform.claude.com/oauth/authorize)
    private static let authorizeEndpoint = URL(string: "https://claude.com/cai/oauth/authorize")!
    private static let tokenEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// 브라우저 리다이렉트를 못 받는 환경용 — 인증 후 화면에 `code#state` 가 표시된다.
    private static let pastedRedirectURI = "https://platform.claude.com/oauth/code/callback"
    /// Claude Code 가 로컬 콜백에 쓰는 기본 포트. 등록된 redirect 와 어긋나지 않도록 같은 값을
    /// 먼저 쓰고, 이미 점유돼 있으면 임의 포트로 물러난다.
    private static let preferredCallbackPort: UInt16 = 54545
    /// usage API 는 `user:profile` 이 있어야 응답한다.
    /// (`claude setup-token` 토큰은 `user:inference` 뿐이라 상시 429 로 거절된다.)
    /// Claude Code 자신은 여기에 `org:create_api_key` 등을 더 요청하지만, 상태 표시에 필요 없는
    /// 권한은 받지 않는다.
    private static let scopes = "user:profile user:inference"

    /// 붙여넣기 로그인 진행 상태 (verifier/state 는 코드 교환까지 들고 있어야 한다)
    private var pendingPaste: (verifier: String, state: String)?

    // MARK: - 루프백 로그인 (기본 경로)

    /// 브라우저를 열고 `http://127.0.0.1:<port>/callback` 으로 돌아오는 코드를 받아 토큰으로 교환한다.
    func login() async throws -> OAuthTokens {
        let server = LoopbackCallbackServer()
        let port: UInt16
        do {
            port = try await server.start(preferredPort: Self.preferredCallbackPort)
        } catch {
            throw OAuthError.listenerFailed(error.localizedDescription)
        }
        defer { server.stop() }

        let verifier = Self.randomURLSafeString()
        let state = Self.randomURLSafeString()
        // Claude Code 와 같은 형태(`localhost`)를 쓴다 — 등록된 redirect 와 어긋나지 않게.
        let redirectURI = "http://localhost:\(port)/callback"
        let url = Self.authorizeURL(redirectURI: redirectURI, verifier: verifier, state: state)
        await MainActor.run { _ = NSWorkspace.shared.open(url) }

        let items = try await server.awaitCallback(timeout: 300)
        if let error = items["error"] {
            throw OAuthError.denied(items["error_description"] ?? error)
        }
        guard let code = items["code"] else { throw OAuthError.badResponse }
        guard items["state"] == state else { throw OAuthError.stateMismatch }
        return try await exchange(
            code: code, verifier: verifier, state: state, redirectURI: redirectURI
        )
    }

    // MARK: - 붙여넣기 로그인 (폴백 경로)

    /// 인증 페이지 URL 을 만들고 verifier/state 를 기억한다. 인증 후 화면의 코드를
    /// `completePastedLogin(_:)` 에 넘기면 된다.
    func pastedLoginURL() -> URL {
        let verifier = Self.randomURLSafeString()
        let state = Self.randomURLSafeString()
        pendingPaste = (verifier, state)
        return Self.authorizeURL(
            redirectURI: Self.pastedRedirectURI, verifier: verifier, state: state
        )
    }

    /// 인증 페이지가 보여 준 코드(`code` 또는 `code#state` 형식)로 토큰을 교환한다.
    func completePastedLogin(_ pasted: String) async throws -> OAuthTokens {
        guard let pending = pendingPaste else { throw OAuthError.noPendingLogin }
        let trimmed = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "#", maxSplits: 1).map(String.init)
        guard let code = parts.first, !code.isEmpty else { throw OAuthError.badResponse }
        if parts.count > 1, parts[1] != pending.state { throw OAuthError.stateMismatch }
        let tokens = try await exchange(
            code: code,
            verifier: pending.verifier,
            state: pending.state,
            redirectURI: Self.pastedRedirectURI
        )
        pendingPaste = nil
        return tokens
    }

    // MARK: - 토큰 교환 / 갱신

    private func exchange(
        code: String, verifier: String, state: String, redirectURI: String
    ) async throws -> OAuthTokens {
        try await postToken([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": Self.clientID,
            "code_verifier": verifier,
            "state": state,
        ])
    }

    /// 만료 전에 조용히 호출된다. 응답에 새 refresh token 이 오면 그것으로 교체해야 한다.
    func refresh(refreshToken: String) async throws -> OAuthTokens {
        try await postToken([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
            "scope": Self.scopes,
        ])
    }

    private func postToken(_ body: [String: String]) async throws -> OAuthTokens {
        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OAuthError.badResponse }
        guard http.statusCode == 200 else { throw Self.tokenError(status: http.statusCode, data: data) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String
        else { throw OAuthError.badResponse }

        let expiresIn = (json["expires_in"] as? Double)
            ?? (json["expires_in"] as? Int).map(Double.init)
        return OAuthTokens(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) }
        )
    }

    /// OAuth 표준(`{"error":"invalid_grant",…}`)과 Anthropic 형식
    /// (`{"error":{"type":…,"message":…}}`) 둘 다 받아 준다.
    private static func tokenError(status: Int, data: Data) -> OAuthError {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .server(status, nil)
        }
        if let code = json["error"] as? String {
            let description = json["error_description"] as? String
            if code == "invalid_grant" { return .invalidGrant(description ?? code) }
            return .server(status, [code, description].compactMap { $0 }.joined(separator: ": "))
        }
        if let nested = json["error"] as? [String: Any] {
            let detail = [nested["type"] as? String, nested["message"] as? String]
                .compactMap { $0 }.joined(separator: ": ")
            return .server(status, detail.isEmpty ? nil : detail)
        }
        return .server(status, nil)
    }

    // MARK: - PKCE

    static func authorizeURL(redirectURI: String, verifier: String, state: String) -> URL {
        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)!
        // redirect_uri 의 `:` `/` 가 그대로 남지 않도록 직접 인코딩한다.
        components.percentEncodedQueryItems = [
            // Claude Code 도 항상 붙인다 — 없으면 인증 페이지가 코드를 넘겨주지 않는다.
            ("code", "true"),
            ("response_type", "code"),
            ("client_id", clientID),
            ("redirect_uri", redirectURI),
            ("scope", scopes),
            ("state", state),
            ("code_challenge", codeChallenge(for: verifier)),
            ("code_challenge_method", "S256"),
        ].map { URLQueryItem(name: $0.0, value: percentEncoded($0.1)) }
        return components.url!
    }

    /// 예약 문자를 전부 이스케이프한다 (RFC 3986 unreserved 만 남김).
    private static func percentEncoded(_ value: String) -> String {
        let unreserved = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
        )
        return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func randomURLSafeString() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - 루프백 콜백 서버

/// OAuth 리다이렉트 한 건만 받기 위해 루프백에 잠깐 띄우는 최소 HTTP 서버.
/// 콜백을 받거나 제한 시간이 지나면 스스로 닫힌다.
///
/// 가변 상태는 모두 `queue` 위에서만 만진다 (`start()` 의 리스너 세팅 포함) — 그래서
/// `@unchecked Sendable` 로 표시한다.
final class LoopbackCallbackServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.vince.vincestat.oauth-callback")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    /// awaitCallback 보다 콜백이 먼저 도착한 경우를 위한 보관함
    private var received: [String: String]?
    private var failure: Error?
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var startWaiter: CheckedContinuation<UInt16, Error>?
    private var isFinished = false

    /// 리스너를 열고 실제로 할당된 포트를 돌려준다.
    /// `preferredPort` 가 점유돼 있으면 임의 포트로 물러난다.
    func start(preferredPort: UInt16?) async throws -> UInt16 {
        if let preferredPort, let port = NWEndpoint.Port(rawValue: preferredPort) {
            do { return try await start(on: port) } catch { /* 아래에서 임의 포트로 재시도 */ }
        }
        return try await start(on: .any)
    }

    private func start(on port: NWEndpoint.Port) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            startWaiter = continuation
            // 상태 핸들러는 `queue` 위에서 돌기 때문에 startWaiter 를 여기서 만져도 안전하다.
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue {
                        self?.resumeStart(.success(port))
                    } else {
                        self?.resumeStart(.failure(OAuthError.listenerFailed("포트를 알 수 없습니다")))
                    }
                case .failed(let error):
                    self?.resumeStart(.failure(error))
                case .cancelled:
                    self?.resumeStart(.failure(OAuthError.listenerFailed("리스너가 취소되었습니다")))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    private func resumeStart(_ result: Result<UInt16, Error>) {
        guard let startWaiter else { return }
        self.startWaiter = nil
        startWaiter.resume(with: result)
    }

    /// 콜백의 쿼리 파라미터를 기다린다.
    func awaitCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                if let received = self.received {
                    continuation.resume(returning: received)
                    return
                }
                if let failure = self.failure {
                    continuation.resume(throwing: failure)
                    return
                }
                self.waiter = continuation
                self.queue.asyncAfter(deadline: .now() + timeout) {
                    self.finish(.failure(OAuthError.timedOut))
                }
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    // MARK: - 내부

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let items = Self.queryItems(inRequestLineOf: request)
            // 브라우저는 /favicon.ico 같은 것도 물어본다 — 콜백이 아니면 무시한다.
            guard items["code"] != nil || items["error"] != nil else {
                self.respond(on: connection, status: "404 Not Found", body: "Not found")
                return
            }
            let body = items["code"] != nil
                ? Self.page(title: "로그인 완료", message: "이 창을 닫고 VinceStat 으로 돌아가세요.")
                : Self.page(
                    title: "로그인 실패",
                    message: items["error_description"] ?? items["error"] ?? "알 수 없는 오류"
                )
            self.respond(on: connection, status: "200 OK", body: body)
            self.finish(.success(items))
        }
    }

    private func respond(on connection: NWConnection, status: String, body: String) {
        let response = """
            HTTP/1.1 \(status)\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r

            """ + body
        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    private func finish(_ result: Result<[String: String], Error>) {
        guard !isFinished else { return }
        isFinished = true
        switch result {
        case .success(let items): received = items
        case .failure(let error): failure = error
        }
        if let waiter {
            self.waiter = nil
            waiter.resume(with: result)
        }
        listener?.cancel()
        listener = nil
    }

    /// `GET /callback?code=…&state=… HTTP/1.1` 첫 줄에서 쿼리를 뽑는다.
    private static func queryItems(inRequestLineOf request: String) -> [String: String] {
        guard let requestLine = request.split(separator: "\r\n", maxSplits: 1).first,
              let target = requestLine.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: String(target)),
              let queryItems = components.queryItems
        else { return [:] }
        return Dictionary(
            queryItems.compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private static func page(title: String, message: String) -> String {
        """
        <!doctype html><meta charset="utf-8"><title>VinceStat</title>
        <body style="font:14px -apple-system,system-ui,sans-serif;padding:48px;color:#222">
        <h2 style="margin:0 0 8px">\(title)</h2><p style="color:#666">\(message)</p></body>
        """
    }
}
