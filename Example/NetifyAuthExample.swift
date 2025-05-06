// Example usage of TokenAuthProvider

import Foundation
import Netify
import NetifyAuth

// MARK: - 1. 토큰 저장소 구현
class KeychainTokenStorage: TokenStorage {
    func save(tokenInfo: TokenInfo, forKey key: String) async throws {
        // 키체인에 토큰 정보 저장 구현
    }
    
    func load(forKey key: String) async throws -> TokenInfo {
        // 키체인에서 토큰 정보 로드 구현
        // 토큰 없으면 TokenError.tokenNotFound 발생
        throw TokenError.tokenNotFound
    }
    
    func delete(forKey key: String) async throws {
        // 키체인에서 토큰 정보 삭제 구현
    }
}

// MARK: - 2. 토큰 갱신 응답 구현
struct AuthTokenResponse: TokenRefreshResponse, Decodable {
    let accessToken: String
    let accessTokenExpiresIn: TimeInterval
    let refreshToken: String?
    let refreshTokenExpiresIn: TimeInterval?
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accessTokenExpiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case refreshTokenExpiresIn = "refresh_expires_in"
    }
}

// MARK: - 3. 토큰 갱신 요청 구현
struct RefreshTokenRequest: NetifyRequest {
    typealias ResponseType = AuthTokenResponse
    
    let refreshToken: String
    let path = "/oauth/token"
    let method: HTTPMethod = .post
    
    var body: Data? {
        let parameters = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": "your_client_id",
            "client_secret": "your_client_secret"
        ]
        
        return try? JSONSerialization.data(withJSONObject: parameters)
    }
    
    var headers: [String: String] {
        return ["Content-Type": "application/json"]
    }
}

// MARK: - 4. 토큰 폐기 요청 구현
struct RevokeTokenRequest: NetifyRequest {
    typealias ResponseType = EmptyResponse
    
    let refreshToken: String
    let path = "/oauth/revoke"
    let method: HTTPMethod = .post
    
    var body: Data? {
        let parameters = [
            "token": refreshToken,
            "token_type_hint": "refresh_token",
            "client_id": "your_client_id",
            "client_secret": "your_client_secret"
        ]
        
        return try? JSONSerialization.data(withJSONObject: parameters)
    }
    
    var headers: [String: String] {
        return ["Content-Type": "application/json"]
    }
}

// MARK: - 5. API 클라이언트 설정
@available(iOS 15, macOS 12, *)
class AuthManager {
    // 기본 API 클라이언트
    private let apiClient: NetifyClient
    
    // 토큰 관리자
    private let tokenManager: TokenManager
    
    // 인증 API 클라이언트 (인증 불필요)
    private let authClient: NetifyClient
    
    // 인증된 API 클라이언트 (인증 필요)
    private let authenticatedClient: NetifyClient
    
    // 로그아웃 콜백
    private var logoutHandler: () -> Void = {}
    
    init(baseURL: URL, onLogout: @escaping () -> Void) {
        self.logoutHandler = onLogout
        
        // 1. 기본 API 클라이언트 설정
        self.apiClient = NetifyClient(baseURL: baseURL)
        
        // 2. 토큰 저장소 생성
        let tokenStorage = KeychainTokenStorage()
        
        // 3. 인증 API 클라이언트 설정 (토큰 갱신/폐기용)
        self.authClient = NetifyClient(baseURL: baseURL)
        
        // 4. 토큰 관리자 설정
        self.tokenManager = TokenManager(
            tokenStorage: tokenStorage,
            apiClient: authClient,
            refreshRequestProvider: { refreshToken in
                return RefreshTokenRequest(refreshToken: refreshToken)
            },
            revokeRequestProvider: { refreshToken in
                return RevokeTokenRequest(refreshToken: refreshToken)
            }
        )
        
        // 5. 인증 프로바이더 설정
        let authProvider = TokenAuthProvider(
            tokenManager: tokenManager,
            onAuthenticationFailed: { [weak self] in
                // 인증 실패 시 로그아웃 처리
                Task {
                    try? await self?.logout()
                    self?.logoutHandler()
                }
            }
        )
        
        // 6. 인증된 API 클라이언트 설정
        self.authenticatedClient = NetifyClient(
            baseURL: baseURL,
            configuration: NetifyClientConfiguration(
                authenticationProvider: authProvider
            )
        )
        
        // 7. 토큰 상태 모니터링
        Task {
            for await tokenInfo in tokenManager.tokenStream {
                if tokenInfo == nil {
                    // 토큰 제거됨 (로그아웃 등)
                    logoutHandler()
                }
            }
        }
    }
    
    // 로그인 처리
    func login(username: String, password: String) async throws {
        struct LoginRequest: NetifyRequest {
            typealias ResponseType = AuthTokenResponse
            
            let username: String
            let password: String
            let path = "/oauth/token"
            let method: HTTPMethod = .post
            
            var body: Data? {
                let parameters = [
                    "grant_type": "password",
                    "username": username,
                    "password": password,
                    "client_id": "your_client_id",
                    "client_secret": "your_client_secret"
                ]
                
                return try? JSONSerialization.data(withJSONObject: parameters)
            }
            
            var headers: [String: String] {
                return ["Content-Type": "application/json"]
            }
        }
        
        // 로그인 요청 생성
        let request = LoginRequest(username: username, password: password)
        
        // 인증 API 클라이언트로 요청 전송
        let response = try await authClient.send(request)
        
        // 토큰 저장
        try await tokenManager.updateTokens(
            accessToken: response.accessToken,
            accessTokenExpiresIn: response.accessTokenExpiresIn,
            refreshToken: response.refreshToken,
            refreshTokenExpiresIn: response.refreshTokenExpiresIn
        )
    }
    
    // 로그아웃 처리
    func logout() async throws {
        try await tokenManager.revokeTokens()
    }
    
    // 인증된 API 요청 예시
    func fetchUserProfile() async throws -> UserProfile {
        struct UserProfileRequest: NetifyRequest {
            typealias ResponseType = UserProfile
            let path = "/api/user/profile"
            let method: HTTPMethod = .get
        }
        
        // 인증된 클라이언트로 요청 전송 (토큰 자동 처리)
        return try await authenticatedClient.send(UserProfileRequest())
    }
}

// 샘플 사용자 프로필 모델
struct UserProfile: Decodable {
    let id: String
    let name: String
    let email: String
}

// 빈 응답 타입
struct EmptyResponse: Decodable {}

// MARK: - 앱에서 사용 예시
@available(iOS 15, macOS 12, *)
class AppCoordinator {
    private var authManager: AuthManager?
    
    func setupAuth() {
        let baseURL = URL(string: "https://api.example.com")!
        
        authManager = AuthManager(baseURL: baseURL) { [weak self] in
            // 로그아웃 시 처리
            self?.showLoginScreen()
        }
    }
    
    func loginUser(username: String, password: String) async {
        do {
            try await authManager?.login(username: username, password: password)
            showMainScreen()
        } catch {
            showError(error)
        }
    }
    
    func fetchProfile() async {
        do {
            let profile = try await authManager?.fetchUserProfile()
            updateUI(with: profile)
        } catch {
            showError(error)
        }
    }
    
    func logoutUser() async {
        do {
            try await authManager?.logout()
        } catch {
            showError(error)
        }
    }
    
    // UI 관련 메서드
    private func showLoginScreen() { /* ... */ }
    private func showMainScreen() { /* ... */ }
    private func showError(_ error: Error) { /* ... */ }
    private func updateUI(with profile: UserProfile?) { /* ... */ }
}
