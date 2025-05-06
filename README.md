# NetifyAuth 🚀🔑

[![Swift Version](https://img.shields.io/badge/Swift-5.7+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2015+%20%7C%20macOS%2012+-blue.svg)](https://developer.apple.com/swift/)
[![License](https://img.shields.io/badge/License-MIT-lightgrey.svg)](LICENSE)
<!-- Optional: Add build status, version badges later -->

**NetifyAuth는 [Netify](https://github.com/AidenJLee/Netify)를 위한 강력하고 유연한 인증 도우미입니다!** 🛡️

복잡한 토큰 관리(저장, 로드, 자동 갱신, 폐기)는 이제 NetifyAuth에게 맡기고, 여러분은 멋진 앱 기능 개발에만 집중하세요! `async/await` 기반으로 현대적인 Swift 동시성을 완벽하게 지원합니다.

## ✨ 주요 기능

*   🔐 **안전한 토큰 저장:** Keychain 또는 메모리(테스트용)에 토큰 정보를 안전하게 저장하고 관리합니다. (`TokenStorage` 프로토콜)
*   🔄 **자동 토큰 갱신:** Access Token 만료 시 자동으로 Refresh Token을 사용하여 새로운 토큰을 발급받습니다. (중복 갱신 방지 포함!)
*   🏗️ **유연한 API 통합:** 토큰 갱신/폐기 API 요청 생성을 클로저(`RequestProvider`)로 주입받아 어떤 서버 API 구조에도 쉽게 연동할 수 있습니다.
*   🔗 **간편한 Netify 연동:** `TokenAuthProvider`를 Netify 클라이언트에 설정하여 인증 헤더 추가 및 자동 갱신 기능을 쉽게 통합할 수 있습니다.
*   ⚡ **최신 Swift 지원:** `Actor` 기반으로 동시성 문제를 해결하고, `async/await` 및 `AsyncStream`을 적극 활용합니다.
*   📝 **상세한 로깅:** `OSLog`를 사용하여 토큰 관리 과정을 명확하게 추적할 수 있습니다.
*   🔧 **커스터마이징:** 토큰 저장 방식(`TokenStorage`), 갱신/폐기 요청 생성 방식(`RequestProvider`), 갱신 버퍼 시간 등 다양한 설정을 조절할 수 있습니다.
*   📢 **토큰 상태 관찰:** `AsyncStream`을 통해 토큰 정보의 변경(로그인, 로그아웃, 갱신)을 실시간으로 관찰하고 UI 등에 반영할 수 있습니다.

## 📋 요구 사항

*   Swift 5.7+
*   iOS 15.0+
*   macOS 12.0+
*   Netify (NetifyAuth는 Netify와 함께 사용하도록 설계되었습니다.)

## 📦 설치

Swift Package Manager를 사용하여 NetifyAuth를 프로젝트에 쉽게 추가할 수 있습니다.

1.  Xcode에서 프로젝트를 엽니다.
2.  `File` > `Add Packages...` 메뉴를 선택합니다.
3.  검색창에 다음 URL을 입력합니다:
    ```
    https://github.com/AidenJLee/NetifyAuth.git
    ```
4.  `Dependency Rule`을 설정하고 (예: `Up to Next Major Version`) `Add Package` 버튼을 클릭합니다.
5.  NetifyAuth 라이브러리를 사용할 타겟에 추가합니다.

또는 `Package.swift` 파일에 직접 의존성을 추가할 수도 있습니다:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/AidenJLee/Netify.git", from: "1.0.0"), // 사용하는 Netify 버전 명시
    .package(url: "https://github.com/AidenJLee/NetifyAuth.git", from: "1.0.0") // 사용하는 NetifyAuth 버전 명시
],
targets: [
    .target(
        name: "YourAppTarget",
        dependencies: [
            .product(name: "Netify", package: "Netify"),
            .product(name: "NetifyAuth", package: "NetifyAuth")
        ]
    )
]
```

💡 핵심 개념
NetifyAuth를 효과적으로 사용하기 위해 다음 구성 요소들을 이해하는 것이 중요합니다.

TokenManager (Actor): NetifyAuth의 핵심 두뇌입니다. 토큰 정보(TokenInfo)를 관리하며, 저장, 로드, 유효성 검사, 자동 갱신, 폐기 등의 모든 로직을 담당합니다. Actor로 구현되어 여러 스레드에서 동시에 접근해도 안전합니다.
TokenInfo (Struct): Access Token, Refresh Token 및 각각의 만료 시간을 포함하는 데이터 구조입니다. Codable을 준수하여 저장 및 로드가 용이합니다.
TokenStorage (Protocol): TokenInfo를 실제로 저장하고 로드하는 방법을 정의하는 인터페이스입니다.
KeychainTokenStorage: iOS/macOS의 안전한 키체인을 사용하여 토큰을 저장합니다. 실제 앱 환경에 권장됩니다.
InMemoryTokenStorage: 메모리에 토큰을 저장합니다. 테스트 또는 간단한 시나리오에 유용합니다. 필요하다면 TokenStorage 프로토콜을 직접 구현하여 다른 저장 방식(예: UserDefaults, CoreData)을 사용할 수도 있습니다.
TokenRefreshResponse (Protocol): 여러분의 서버가 토큰 갱신 API 호출 시 반환해야 하는 응답 데이터 형식을 정의합니다. 서버 응답 모델이 이 프로토콜을 준수하도록 구현해야 합니다. (accessToken, accessTokenExpiresIn 등 필수 필드 포함)
Request Providers (Closures): TokenManager를 초기화할 때 주입하는 클로저입니다. 이를 통해 NetifyAuth가 여러분의 특정 서버 API와 통신하는 방식을 정의합니다.
refreshRequestProvider: 현재 유효한 Refresh Token 문자열을 인자로 받아, 토큰 갱신 API를 호출하는 NetifyRequest 객체를 생성하여 반환합니다. 반환된 요청의 ReturnType은 TokenRefreshResponse 프로토콜을 준수해야 합니다.
revokeRequestProvider: 현재 유효한 Refresh Token 문자열을 인자로 받아, 토큰 폐기 API를 호출하는 NetifyRequest 객체를 생성하여 반환합니다. 서버 응답 본문이 없다면 Netify.EmptyResponse를 ReturnType으로 사용할 수 있습니다.
TokenAuthProvider (Class): Netify의 AuthenticationProvider 프로토콜을 구현한 클래스입니다. TokenManager를 사용하여 자동으로 API 요청 헤더에 유효한 Access Token을 추가하고, 토큰 만료 시(401 Unauthorized 등) TokenManager를 통해 토큰 갱신을 시도합니다.
TokenError (Enum): 토큰 관리 과정에서 발생할 수 있는 다양한 오류 상황(예: tokenNotFound, refreshTokenMissing, refreshFailed)을 정의합니다.

🚀 사용 방법
NetifyAuth를 사용하여 앱의 인증 시스템을 구축하는 단계별 가이드입니다.

1. API 요청/응답 모델 정의
먼저, 여러분의 서버 API 명세에 맞게 Netify의 NetifyRequest 프로토콜을 따르는 요청 모델과 Codable을 따르는 응답 모델을 정의합니다. 특히 토큰 갱신 응답 모델은 TokenRefreshResponse 프로토콜을 반드시 준수해야 합니다.

```swift
import Netify
import NetifyAuth // TokenRefreshResponse 프로토콜 사용

// --- 로그인 요청/응답 ---
struct LoginRequest: NetifyRequest {
    typealias ReturnType = LoginResponse // 실제 응답 타입 지정
    let method: HTTPMethod = .post
    let path = "/auth/login"
    let bodyParameters: BodyParameters?

    init(credentials: LoginCredentials) {
        self.bodyParameters = JSONBodyParameters(dictionary: ["username": credentials.username, "password": credentials.password])
    }
}

struct LoginResponse: Codable { // 서버 응답 구조에 맞게 정의
    let accessToken: String
    let expiresIn: TimeInterval
    let refreshToken: String
    let refreshTokenExpiresIn: TimeInterval? // 서버가 안 줄 수도 있음
}

// --- 토큰 갱신 요청/응답 ---
struct RefreshTokenRequest: NetifyRequest {
    typealias ReturnType = RefreshTokenApiResponse // 중요! 갱신 응답 타입 지정
    let method: HTTPMethod = .post
    let path = "/auth/refresh"
    let bodyParameters: BodyParameters?

    init(refreshToken: String) {
        self.bodyParameters = JSONBodyParameters(dictionary: ["refreshToken": refreshToken])
    }
}

// !!! 중요 !!!: 갱신 응답 모델은 RefreshTokenResponse 프로토콜을 준수해야 합니다.
struct RefreshTokenApiResponse: Codable, TokenRefreshResponse {
    let accessToken: String
    let accessTokenExpiresIn: TimeInterval // 서버 필드 이름과 프로토콜 필드 이름이 같아야 함
    let refreshToken: String? // 서버가 새 RT를 줄 수도, 안 줄 수도 있음 (Optional)
    let refreshTokenExpiresIn: TimeInterval? // 서버가 안 줄 수도 있음 (Optional)

    // 만약 서버 필드 이름이 프로토콜과 다르면 CodingKeys 사용
    // enum CodingKeys: String, CodingKey {
    //     case accessToken = "new_access_token"
    //     case accessTokenExpiresIn = "access_token_lifetime"
    //     case refreshToken = "new_refresh_token"
    //     case refreshTokenExpiresIn = "refresh_token_lifetime"
    // }
}

// --- 토큰 폐기 요청 ---
struct RevokeTokenRequest: NetifyRequest {
    typealias ReturnType = Netify.EmptyResponse // 서버 응답 본문 없으면 사용
    let method: HTTPMethod = .post
    let path = "/auth/logout"
    let bodyParameters: BodyParameters?

    init(refreshToken: String) {
        self.bodyParameters = JSONBodyParameters(dictionary: ["refreshToken": refreshToken])
    }
}

// --- 인증 필요한 API 요청 예시 ---
struct GetMyInfoRequest: NetifyRequest {
    typealias ReturnType = UserProfile
    let path = "/users/me"
    // method 기본값은 .get
    // requiresAuthentication 기본값은 true
}

struct UserProfile: Codable { // 서버 응답 구조에 맞게 정의
    let id: String
    let name: String
    let email: String
}
```

2. 설정 (Setup)
앱의 인증 흐름을 중앙에서 관리할 객체(예: ApiClientManager 싱글톤 또는 DI 컨테이너로 관리되는 객체)에서 NetifyAuth 관련 컴포넌트들을 설정하고 초기화합니다.

```swift
import Netify
import NetifyAuth
import OSLog
import Combine // ObservableObject 사용 예시

@MainActor // UI 관련 상태를 관리하므로 MainActor 사용
class ApiClientManager: ObservableObject {
    static let shared = ApiClientManager() // 싱글톤 예시

    /// 인증된 API 호출에 사용될 NetifyClient (로그인 상태일 때만 존재)
    @Published private(set) var apiClient: NetifyClient?

    /// NetifyAuth의 핵심 토큰 관리자
    private let tokenManager: TokenManager

    /// 토큰 갱신 및 폐기 API 호출 전용 NetifyClient (인증 Provider 없음!)
    private let netifyClientForAuth: NetifyClient

    private var cancellables = Set<AnyCancellable>()

    private init() {
        // 1. 토큰 갱신/폐기 API 호출 전용 NetifyClient 생성
        //    주의: 이 클라이언트에는 authenticationProvider를 설정하지 않습니다!
        //          순환 참조 또는 무한 루프를 방지하기 위함입니다.
        let authApiConfig = NetifyConfiguration(baseURL: "https://your-api.com")
        self.netifyClientForAuth = NetifyClient(configuration: authApiConfig)

        // 2. TokenStorage 구현체 선택 (실제 앱에서는 Keychain 권장)
        let tokenStorage = KeychainTokenStorage(
            serviceName: "com.yourapp.unique.service.name" // 앱 고유 ID 사용 권장
        )
        // 테스트 시: let tokenStorage = InMemoryTokenStorage()

        // 3. TokenManager 생성 및 의존성 주입
        self.tokenManager = TokenManager(
            tokenStorage: tokenStorage,
            storageKey: "userAuthToken", // 저장소 내에서 토큰을 식별하는 키
            apiClient: self.netifyClientForAuth, // 갱신/폐기용 클라이언트 주입
            refreshRequestProvider: { refreshToken in // 갱신 요청 생성 클로저
                // 위에서 정의한 RefreshTokenRequest 사용
                RefreshTokenRequest(refreshToken: refreshToken)
            },
            revokeRequestProvider: { refreshToken in // 폐기 요청 생성 클로저
                // 위에서 정의한 RevokeTokenRequest 사용
                RevokeTokenRequest(refreshToken: refreshToken)
            },
            accessTokenRefreshBuffer: 120.0, // Access Token 만료 120초(2분) 전에 갱신 시도
            refreshTokenBuffer: 0 // Refresh Token 만료 직전까지 사용 (필요시 조절)
        )

        // 4. 앱 시작 시 메인 API 클라이언트 설정 시도 (초기 토큰 로드 후)
        Task { await setupMainApiClient() }

        // 5. 토큰 상태 변화 구독 (로그아웃 시 UI 처리 등)
        subscribeToTokenChanges()
    }

    /// 메인 API 호출용 NetifyClient 설정 (인증 Provider 포함)
    private func setupMainApiClient() async {
        // TokenAuthProvider 생성 및 인증 실패 핸들러 설정
        let tokenProvider = TokenAuthProvider(
            tokenManager: tokenManager,
            onAuthenticationFailed: { [weak self] in
                // 인증 실패(토큰 갱신 실패 등) 시 호출됨
                // 주의: 백그라운드 스레드에서 호출될 수 있음
                Task { @MainActor [weak self] in // UI 관련 작업은 MainActor 보장
                    print("🚨 Authentication failed, forcing logout.")
                    await self?.handleLogoutUI()
                }
            }
        )

        // 메인 API 호출용 Netify 설정
        let mainApiConfig = NetifyConfiguration(
            baseURL: "https://your-api.com",
            authenticationProvider: tokenProvider // 생성된 Provider 설정!
        )
        self.apiClient = NetifyClient(configuration: mainApiConfig)
        print("✅ Main API Client is ready with authentication provider.")
    }

    /// 토큰 상태 변화 구독 설정
    private func subscribeToTokenChanges() {
        Task {
            for await tokenInfo in await tokenManager.tokenStream {
                // 토큰 상태 변화 감지 (로그인, 로그아웃, 갱신)
                if tokenInfo == nil { // 토큰 없음 (로그아웃 또는 초기 상태)
                    if self.apiClient != nil { // 이전에 로그인 상태였다면 로그아웃 처리
                        print("Token stream received nil, handling logout UI.")
                        await handleLogoutUI()
                    }
                } else { // 토큰 있음 (로그인 또는 갱신됨)
                    if self.apiClient == nil { // 이전에 로그아웃 상태였다면 메인 클라이언트 설정
                        print("Token stream received valid token, setting up main client.")
                        await setupMainApiClient()
                    }
                    // 필요시 로그인 상태 관련 UI 업데이트
                }
            }
        }
    }

    /// 로그아웃 관련 UI 처리 (MainActor에서 호출되어야 함)
    private func handleLogoutUI() {
        self.apiClient = nil
        // 예: 로그인 화면으로 전환, 사용자 정보 초기화 등
        print("UI updated for logged out state.")
    }

    // ... 로그인, 로그아웃 함수는 아래에 추가 ...
}
```

3. 로그인 처리
로그인 API 호출이 성공하면, 서버로부터 받은 토큰 정보를 TokenManager에 저장합니다. TokenManager는 내부적으로 토큰을 저장소에 저장하고, tokenStream을 통해 상태 변경을 알립니다. ApiClientManager의 구독 로직은 이 변경을 감지하여 apiClient를 설정할 것입니다.

```swift
// ApiClientManager 내부에 추가
extension ApiClientManager {
    func performLogin(credentials: LoginCredentials) async {
        do {
            // 1. 로그인 API 호출 (인증 Provider 없는 클라이언트 사용)
            let loginResponse: LoginResponse = try await netifyClientForAuth.send(
                LoginRequest(credentials: credentials)
            )

            // 2. TokenManager에 토큰 정보 업데이트
            //    이 호출은 내부적으로 토큰 저장 및 tokenStream 업데이트를 트리거합니다.
            try await tokenManager.updateTokens(
                accessToken: loginResponse.accessToken,
                accessTokenExpiresIn: loginResponse.expiresIn,
                refreshToken: loginResponse.refreshToken,
                refreshTokenExpiresIn: loginResponse.refreshTokenExpiresIn
            )

            // 3. 로그인 성공 후 처리 (예: 메인 화면 이동)
            //    setupMainApiClient()는 tokenStream 구독 로직에 의해 자동으로 호출될 것입니다.
            print("🎉 Login successful! Token updated.")

        } catch {
            print("❌ Login failed: \(error.localizedDescription)")
            // 로그인 실패 UI 처리
        }
    }
}
```

4. 인증된 API 요청하기
이제 ApiClientManager에 설정된 apiClient를 사용하여 인증이 필요한 API를 호출합니다. TokenAuthProvider가 자동으로 요청 헤더에 Authorization: Bearer <access_token>을 추가합니다. 만약 요청 중 401 Unauthorized 오류가 발생하면, TokenAuthProvider는 자동으로 TokenManager를 통해 토큰 갱신을 시도하고, 성공하면 원래 요청을 재시도합니다.

```swift
// SwiftUI View 예시
struct ProfileView: View {
    @State private var profile: UserProfile?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack {
            if isLoading {
                ProgressView()
            } else if let profile = profile {
                Text("Welcome, \(profile.name)!")
                Text("Email: \(profile.email)")
            } else if let errorMessage = errorMessage {
                Text("Error: \(errorMessage)")
                    .foregroundColor(.red)
            }
            Button("Fetch Profile") {
                fetchMyProfile()
            }
            .disabled(isLoading)
        }
        .onAppear {
            fetchMyProfile()
        }
    }

    func fetchMyProfile() {
        isLoading = true
        errorMessage = nil

        Task { @MainActor in // UI 업데이트는 MainActor에서
            // ApiClientManager의 apiClient 사용 (로그인 상태여야 함)
            guard let client = ApiClientManager.shared.apiClient else {
                errorMessage = "User not logged in."
                isLoading = false
                return
            }

            do {
                let fetchedProfile: UserProfile = try await client.send(GetMyInfoRequest())
                self.profile = fetchedProfile
                print("👤 User Profile fetched: \(fetchedProfile.name)")
            } catch {
                // NetworkRequestError.unauthorized (401) 발생 시
                // TokenAuthProvider가 자동으로 토큰 갱신 시도.
                // 갱신도 실패하면 (예: Refresh Token 만료) 에러가 그대로 전달됨.
                print("❌ Failed to fetch profile: \(error.localizedDescription)")
                self.errorMessage = error.localizedDescription

                // 갱신 실패로 인한 특정 오류 처리 (예: 강제 로그아웃)
                // TokenAuthProvider의 onAuthenticationFailed 핸들러에서 이미 처리될 수 있음
                // 필요하다면 여기서 추가 처리 가능
                // if let tokenError = error as? TokenError, tokenError == .refreshTokenMissing {
                //     // 추가적인 UI 처리
                // }
            }
            isLoading = false
        }
    }
}
```

5. 로그아웃 처리
로그아웃 시에는 TokenManager의 revokeTokens()를 호출하여 서버에 토큰 폐기를 요청하고 로컬 저장소에서도 토큰을 삭제하는 것이 가장 이상적입니다. revokeTokens()는 내부적으로 clearTokens()를 호출하여 로컬 토큰을 삭제하고 tokenStream에 nil을 방출합니다.

```swift
// ApiClientManager 내부에 추가
extension ApiClientManager {
    func performLogout() async {
        print("👋 Logging out...")
        do {
            // 서버 폐기 요청 및 로컬 토큰 삭제 시도
            try await tokenManager.revokeTokens()
            // 성공 시 tokenStream이 nil을 방출하여 구독 로직에서 handleLogoutUI()가 호출됨
            print("Logout process initiated (revoke successful or no token).")
        } catch {
            print("❌ Logout failed (revoke request failed): \(error.localizedDescription)")
            // 서버 폐기 요청이 실패하더라도 로컬에서는 로그아웃 처리 필요
            // revokeTokens 내부에서 clearTokens는 이미 호출되었으므로,
            // tokenStream 구독 로직이 handleLogoutUI()를 호출할 것임.
            // 추가적인 오류 로깅 또는 사용자 알림이 필요할 수 있음.
        }
    }

    // 만약 서버 폐기 API가 없다면 clearTokens() 직접 호출
    // func performLogoutWithoutRevoke() async {
    //     print("👋 Clearing local tokens...")
    //     try? await tokenManager.clearTokens() // 로컬 토큰만 삭제
    //     // tokenStream 구독 로직이 handleLogoutUI()를 호출할 것임.
    // }
}
6. 토큰 상태 관찰 (선택 사항)
TokenManager의 tokenStream (AsyncStream<TokenInfo?>)을 구독하여 토큰 상태 변화(로그인 성공, 로그아웃, 토큰 갱신 등)에 실시간으로 반응할 수 있습니다. 이는 앱의 전반적인 인증 상태를 관리하고 UI를 동기화하는 데 매우 유용합니다.

swift
// ApiClientManager.swift 내 subscribeToTokenChanges() 메서드 참고

// SwiftUI View에서 로그인 상태에 따라 UI 분기 예시
struct ContentView: View {
    @StateObject private var apiClientManager = ApiClientManager.shared

    var body: some View {
        // apiClientManager.apiClient의 존재 여부로 로그인 상태 확인
        if apiClientManager.apiClient != nil {
            MainTabView() // 로그인 후 보여줄 메인 화면
        } else {
            LoginView() // 로그인 화면
        }
    }
}
```

🔧 커스터마이징
토큰 저장소: TokenStorage 프로토콜을 직접 구현하여 UserDefaults, CoreData, Realm 등 원하는 방식으로 토큰을 저장할 수 있습니다.
Request Providers: TokenManager 초기화 시 제공하는 refreshRequestProvider 및 revokeRequestProvider 클로저를 통해 어떤 형태의 API 요청이든 생성 가능합니다.
버퍼 시간: accessTokenRefreshBuffer, refreshTokenBuffer 값을 조절하여 토큰 갱신 시점을 세밀하게 제어할 수 있습니다.
인증 헤더: TokenAuthProvider 초기화 시 headerName과 tokenPrefix를 변경하여 Authorization: Bearer <token> 외 다른 형식의 인증 헤더를 사용할 수 있습니다.
📚 예제 프로젝트
이 README의 코드 예시는 기본적인 사용법을 보여줍니다. 더 자세한 통합 예시는 프로젝트 내 Example/ 디렉토리(존재하는 경우) 또는 관련 테스트 코드를 참고하세요.

🙌 기여하기
NetifyAuth 개선을 위한 아이디어, 버그 리포트, Pull Request는 언제나 환영입니다! 😊 프로젝트 저장소의 이슈 트래커나 Pull Request 기능을 이용해 주세요.

📄 라이선스
NetifyAuth는 MIT 라이선스 하에 배포됩니다. 자세한 내용은 LICENSE 파일을 참고하세요.