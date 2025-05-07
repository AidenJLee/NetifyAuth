// Example usage of TokenAuthProvider

import Foundation
import Netify
import NetifyAuth
import OSLog

// MARK: - 0. 로거 설정 (필요시)
let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.netifyauth.example", category: "AuthExample")

// MARK: - 1. 토큰 저장소 구현 (NetifyAuth의 KeychainTokenStorage 사용)
// NetifyAuth 라이브러리에 이미 KeychainTokenStorage가 actor로 구현되어 있으므로,
// 별도의 클래스 정의 대신 해당 구현체를 사용합니다.
// let tokenStorage = KeychainTokenStorage() // AuthManager 내에서 생성

// MARK: - 2. 토큰 갱신 응답 구현
// TokenRefreshResponse 프로토콜은 이미 Sendable을 준수합니다.
// AuthTokenResponse가 Decodable 외에 Sendable도 준수하도록 명시하는 것이 좋습니다.
struct AuthTokenResponse: TokenRefreshResponse, Decodable, Sendable {
    let accessToken: String
    let accessTokenExpiresIn: TimeInterval
    let refreshToken: String?
    let refreshTokenExpiresIn: TimeInterval?
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accessTokenExpiresIn = "expires_in" // 실제 API 응답 필드명에 맞춰야 합니다.
        case refreshToken = "refresh_token"
        case refreshTokenExpiresIn = "refresh_expires_in" // 실제 API 응답 필드명에 맞춰야 합니다.
    }
}

// MARK: - 3. 토큰 갱신 요청 구현
struct RefreshTokenRequest: NetifyRequest {
    // ReturnType은 이미 Sendable을 준수하는 AuthTokenResponse로 설정됨
    typealias ReturnType = AuthTokenResponse
    
    let refreshTokenValue: String // 명확한 이름 사용 (refreshToken -> refreshTokenValue)
    
    let path = "/oauth/token"
    let method: HTTPMethod = .post
    let contentType: HTTPContentType = .json // Netify가 Encodable body를 처리하도록 contentType 명시
    
    // Encodable body를 사용하도록 변경
    struct RequestBody: Encodable, Sendable { // Sendable 추가
        let grant_type: String
        let refresh_token: String
        let client_id: String
        // let client_secret: String // Secret은 코드에 직접 포함하는 것보다 안전한 방법 고려
    }
    
    var body: Any? {
        return RequestBody(
            grant_type: "refresh_token",
            refresh_token: refreshTokenValue,
            client_id: "your_client_id"
            // client_secret: "your_client_secret" // 보안상 주의
        )
    }
    
    // headers는 필요시 추가 가능. Content-Type은 Netify가 contentType에 따라 자동 설정
    // var headers: HTTPHeaders? {
    //     return ["X-Custom-Header": "value"]
    // }
    
    var requiresAuthentication: Bool { false } // 토큰 갱신 요청 자체는 인증이 필요 없을 수 있음
}

// MARK: - 4. 토큰 폐기 요청 구현
struct RevokeTokenRequest: NetifyRequest {
    // Netify의 EmptyResponse는 Decodable 및 Sendable을 준수해야 합니다.
    // (Netify.swift 파일에 EmptyResponse가 Sendable을 준수하도록 수정되었다고 가정)
    typealias ReturnType = EmptyResponse
    
    let tokenToRevoke: String // 명확한 이름 사용
    
    let path = "/oauth/revoke"
    let method: HTTPMethod = .post
    let contentType: HTTPContentType = .json
    
    struct RequestBody: Encodable, Sendable { // Sendable 추가
        let token: String
        let token_type_hint: String
        let client_id: String
        // let client_secret: String
    }
    
    var body: Any? {
        return RequestBody(
            token: tokenToRevoke,
            token_type_hint: "refresh_token", // 또는 "access_token"
            client_id: "your_client_id"
            // client_secret: "your_client_secret" // 보안상 주의
        )
    }
    var requiresAuthentication: Bool { false } // 폐기 요청 시 토큰을 본문에 담아 보내므로, 헤더 인증은 불필요할 수 있음
}

// MARK: - 5. API 클라이언트 설정
@available(iOS 15, macOS 12, *)
// AuthManager는 여러 actor (TokenManager, NetifyClient 내부의 AuthenticationProvider 등)와 상호작용하고,
// UI 관련 콜백(logoutHandler)을 가질 수 있으므로, MainActor에서 관리하거나 Thread-Safe하게 설계해야 합니다.
// 여기서는 MainActor로 지정하여 UI 관련 작업의 안전성을 높입니다.
@MainActor
class AuthManager {
    // 기본 API 클라이언트 (인증 불필요한 일반 요청용)
    private let generalApiClient: NetifyClient // 이름 변경: apiClient -> generalApiClient
    
    // 토큰 관리자 (actor이므로 Sendable)
    private let tokenManager: TokenManager
    
    // 인증 API 클라이언트 (로그인, 토큰 갱신/폐기 등 인증 자체를 처리하는 요청용 - 인증 헤더 불필요)
    private let authApiClient: NetifyClient // 이름 변경: authClient -> authApiClient
    
    // 인증된 API 클라이언트 (자동으로 인증 헤더를 추가하는 요청용)
    private let authenticatedApiClient: NetifyClient // 이름 변경: authenticatedClient -> authenticatedApiClient
    
    // 로그아웃 콜백. MainActor에서 호출되도록 보장.
    private var logoutHandler: @MainActor @Sendable () -> Void = {}
    
    init(baseURL: URL, onLogout: @MainActor @Sendable @escaping () -> Void) {
        self.logoutHandler = onLogout
        
        // 1. Netify 기본 설정
        let baseConfiguration = NetifyConfiguration(
            baseURL: baseURL.absoluteString, // NetifyConfiguration은 String을 받음
            logLevel: .debug // 예시 로그 레벨
        )
        
        // 2. 인증 불필요 API 클라이언트 (로그인, 토큰 갱신/폐기 등)
        // 이 클라이언트는 자체적으로 인증 헤더를 추가하지 않아야 합니다.
        self.authApiClient = NetifyClient(configuration: baseConfiguration)
        
        // 3. 토큰 저장소 생성 (NetifyAuth의 KeychainTokenStorage 사용)
        let tokenStorage = KeychainTokenStorage() // actor
        
        // 4. 토큰 관리자 설정
        // TokenManager는 actor이므로 생성자 파라미터로 전달되는 클로저는 @Sendable이어야 함
        self.tokenManager = TokenManager(
            tokenStorage: tokenStorage,
            storageKey: "com.yourapp.authtoken", // 앱에 맞는 고유한 키 사용
            apiClient: authApiClient, // 토큰 갱신/폐기에 사용할 클라이언트 (인증 헤더 자동 추가 X)
            refreshRequestProvider: { refreshToken in // 이 클로저는 @Sendable을 준수해야 함
                logger.debug("TokenManager: Providing refresh token request for token: \(refreshToken)")
                return RefreshTokenRequest(refreshTokenValue: refreshToken)
            },
            revokeRequestProvider: { tokenToRevoke in // 이 클로저저는 @Sendable을 준수해야 함
                logger.debug("TokenManager: Providing revoke token request for token: \(tokenToRevoke)")
                return RevokeTokenRequest(tokenToRevoke: tokenToRevoke)
            },
            accessTokenRefreshBuffer: 60, // 1분
            refreshTokenBuffer: 3600 * 24 // 1일 (예시)
        )
        
        // 5. 인증 프로바이더 설정
        // TokenAuthProvider의 onAuthenticationFailed 클로저도 @Sendable을 준수해야 함
        let authProvider = TokenAuthProvider(
            tokenManager: tokenManager,
            onAuthenticationFailed: { [weak self] in // @Sendable 클로저
                logger.error("TokenAuthProvider: Authentication failed. Triggering logout.")
                // UI 업데이트는 MainActor에서 수행
                Task { @MainActor [weak self] in // 명시적으로 MainActor에서 실행
                    guard let self = self else { return }
                    // 이미 로그아웃 상태일 수 있으므로, logout 중복 호출 방지 로직 추가 가능
                    try? await self.logout() // TokenManager의 revokeTokens 호출
                    self.logoutHandler()     // 앱 레벨 로그아웃 처리
                }
            }
        )
        
        // 6. 인증된 API 클라이언트 설정 (실제 데이터 요청용)
        var authenticatedClientConfig = baseConfiguration // 기본 설정 복사
        authenticatedClientConfig = NetifyConfiguration( // authProvider를 추가하여 재구성
            baseURL: baseConfiguration.baseURL,
            sessionConfiguration: baseConfiguration.sessionConfiguration,
            defaultEncoder: baseConfiguration.defaultEncoder,
            defaultDecoder: baseConfiguration.defaultDecoder,
            defaultHeaders: baseConfiguration.defaultHeaders,
            logLevel: baseConfiguration.logLevel,
            cachePolicy: baseConfiguration.cachePolicy,
            maxRetryCount: baseConfiguration.maxRetryCount, // Netify 기본값 또는 앱 정책에 따름
            timeoutInterval: baseConfiguration.timeoutInterval,
            authenticationProvider: authProvider, // 인증 프로바이더 설정
            waitsForConnectivity: baseConfiguration.waitsForConnectivity
        )
        self.authenticatedApiClient = NetifyClient(configuration: authenticatedClientConfig)
        
        // 일반 요청용 클라이언트는 authProvider가 없어야 함
        self.generalApiClient = NetifyClient(configuration: baseConfiguration)
        
        // 7. 토큰 상태 모니터링
        Task { [weak self] in // Sendable 클로저
            guard let self = self else { return }
            // tokenManager는 actor이므로 tokenStream에 접근하는 것은 actor 외부에서 async하게 이루어짐
            for await tokenInfo in await self.tokenManager.tokenStream {
                // UI 업데이트는 MainActor에서 수행
                await MainActor.run { [weak self] in // 명시적으로 MainActor에서 실행
                    guard let self = self else { return }
                    if tokenInfo == nil {
                        logger.info("TokenManager stream: Token became nil. Executing logout handler.")
                        // 현재 로그인 상태인지 확인 후 로그아웃 핸들러 호출 (중복 방지)
                        // 예: if self.isUserLoggedIn { self.logoutHandler() }
                        self.logoutHandler()
                    } else {
                        logger.info("TokenManager stream: Token updated.")
                        // 필요한 경우 토큰 업데이트 시 추가 작업 수행
                    }
                }
            }
            logger.info("TokenManager stream finished.") // 스트림이 종료될 경우 (이론상 앱 생명주기 동안 유지)
        }
    }
    
    // 로그인 처리
    func login(username: String, password: String) async throws {
        struct LoginRequest: NetifyRequest {
            typealias ReturnType = AuthTokenResponse // Sendable 준수
            
            let path = "/oauth/token"
            let method: HTTPMethod = .post
            let contentType: HTTPContentType = .json
            
            struct RequestBody: Encodable, Sendable { // Sendable 추가
                let grant_type: String
                let username: String
                let password: String
                let client_id: String
                // let client_secret: String
            }
            
            let requestBody: RequestBody // 명확하게 분리
            
            init(username: String, password: String) {
                self.requestBody = RequestBody(
                    grant_type: "password",
                    username: username,
                    password: password,
                    client_id: "your_client_id"
                    // client_secret: "your_client_secret" // 보안상 주의
                )
            }
            
            var body: Any? {
                return requestBody
            }
            var requiresAuthentication: Bool { false } // 로그인 요청 자체는 인증 불필요
        }
        
        logger.info("Attempting login for user: \(username)")
        let request = LoginRequest(username: username, password: password)
        
        // 로그인 요청은 인증 헤더가 필요 없는 authApiClient 사용
        let response = try await authApiClient.send(request)
        logger.info("Login successful, received tokens.")
        
        // 토큰 저장 (TokenManager는 actor이므로 await 필요)
        try await tokenManager.updateTokens(
            accessToken: response.accessToken,
            accessTokenExpiresIn: response.accessTokenExpiresIn,
            refreshToken: response.refreshToken,
            refreshTokenExpiresIn: response.refreshTokenExpiresIn
        )
        logger.info("Tokens updated in TokenManager.")
    }
    
    // 로그아웃 처리
    func logout() async throws {
        logger.info("Attempting logout.")
        // TokenManager는 actor이므로 await 필요
        try await tokenManager.revokeTokens() // 내부적으로 clearTokens도 호출하여 스트림에 nil 전달
        logger.info("Logout process completed via TokenManager.")
        // logoutHandler는 tokenStream을 통해 호출되거나 onAuthenticationFailed에서 호출됨.
        // 여기서 직접 호출할 수도 있지만, TokenManager의 상태 변경에 따라 반응하는 것이 일관적일 수 있음.
        // 만약 즉시 UI 변경이 필요하다면 여기서도 logoutHandler() 호출 가능
        // self.logoutHandler()
    }
    
    // 인증된 API 요청 예시
    func fetchUserProfile() async throws -> UserProfile {
        struct UserProfileRequest: NetifyRequest {
            typealias ReturnType = UserProfile // Sendable 준수
            let path = "/api/user/profile"
            // method, contentType 등은 NetifyRequest의 기본값 사용 가능 (GET, JSON 등)
            // var requiresAuthentication: Bool { true } // NetifyRequest 기본값이 true이므로 생략 가능
        }
        
        logger.info("Fetching user profile.")
        // 인증된 API 클라이언트 사용 (TokenAuthProvider가 자동으로 토큰 관리)
        return try await authenticatedApiClient.send(UserProfileRequest())
    }
    
    // 인증이 필요 없는 일반 API 요청 예시
    func fetchPublicInfo() async throws -> PublicInfo {
        struct PublicInfoRequest: NetifyRequest {
            typealias ReturnType = PublicInfo // Sendable 준수
            let path = "/api/public/info"
            var requiresAuthentication: Bool { false } // 인증 불필요 명시
        }
        logger.info("Fetching public info.")
        return try await generalApiClient.send(PublicInfoRequest())
    }
}

// 샘플 사용자 프로필 모델
struct UserProfile: Decodable, Sendable { // Sendable 추가
    let id: String
    let name: String
    let email: String
}

// 샘플 공개 정보 모델
struct PublicInfo: Decodable, Sendable { // Sendable 추가
    let version: String
    let message: String
}

// Netify.swift에 정의된 EmptyResponse를 사용하거나,
// 만약 없다면 여기에 Sendable을 준수하도록 정의합니다.
// Netify 라이브러리 내부에 이미 `public struct EmptyResponse: Decodable, Sendable {}` (또는 유사 형태)로
// 정의되어 있다고 가정합니다. 만약 Decodable만 되어 있다면 Sendable 추가 필요.


// MARK: - 앱에서 사용 예시
@available(iOS 15, macOS 12, *)
@MainActor // AppCoordinator는 UI와 상호작용하므로 MainActor에서 실행
class AppCoordinator {
    private var authManager: AuthManager?
    
    func setupAuth() {
        logger.info("Setting up AuthManager.")
        let baseURL = URL(string: "https://api.example.com")!
        
        authManager = AuthManager(baseURL: baseURL) { [weak self] in
            // 이 클로저는 AuthManager에 의해 MainActor에서 호출됨
            logger.info("AppCoordinator: Logout handler triggered.")
            self?.showLoginScreen()
        }
    }
    
    func loginUser(username: String, password: String) async {
        guard let authManager = authManager else {
            logger.error("AuthManager not initialized.")
            showError(AppError.authManagerNotInitialized)
            return
        }
        logger.info("AppCoordinator: Attempting login for user \(username).")
        do {
            try await authManager.login(username: username, password: password)
            logger.info("AppCoordinator: Login successful, showing main screen.")
            showMainScreen()
        } catch {
            logger.error("AppCoordinator: Login failed: \(error.localizedDescription)")
            showError(error)
        }
    }
    
    func fetchProfile() async {
        guard let authManager = authManager else {
            logger.error("AuthManager not initialized.")
            showError(AppError.authManagerNotInitialized)
            return
        }
        logger.info("AppCoordinator: Attempting to fetch profile.")
        do {
            let profile = try await authManager.fetchUserProfile()
            logger.info("AppCoordinator: Profile fetched successfully: \(profile.name)")
            updateUI(with: profile)
        } catch {
            logger.error("AppCoordinator: Fetch profile failed: \(error.localizedDescription)")
            // 여기서 에러 타입에 따라 분기하여 로그아웃 처리 등을 할 수 있음
            // ex: if let tokenError = error as? TokenError, tokenError == .refreshTokenMissing { ... }
            showError(error)
        }
    }
    
    func logoutUser() async {
        guard let authManager = authManager else {
            logger.error("AuthManager not initialized.")
            showError(AppError.authManagerNotInitialized)
            return
        }
        logger.info("AppCoordinator: Attempting to logout user.")
        do {
            try await authManager.logout()
            logger.info("AppCoordinator: Logout successful (triggered via authManager.logout).")
            // showLoginScreen()은 logoutHandler에 의해 호출될 것임
        } catch {
            logger.error("AppCoordinator: Logout failed: \(error.localizedDescription)")
            showError(error)
        }
    }
    
    // UI 관련 메서드 (실제 구현 필요)
    private func showLoginScreen() { logger.debug("UI: Showing Login Screen") /* ... */ }
    private func showMainScreen() { logger.debug("UI: Showing Main Screen") /* ... */ }
    private func showError(_ error: Error) { logger.error("UI: Showing Error: \(error.localizedDescription)") /* ... */ }
    private func updateUI(with profile: UserProfile?) { logger.debug("UI: Updating with Profile: \(profile?.name ?? "nil")") /* ... */ }
}

enum AppError: LocalizedError {
    case authManagerNotInitialized
    
    var errorDescription: String? {
        switch self {
        case .authManagerNotInitialized:
            return "Authentication manager has not been initialized."
        }
    }
}
