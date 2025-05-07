// Tests/NetifyAuthTests/TokenAuthProviderTests.swift
import XCTest
import Netify
@testable import NetifyAuth

// Mock TokenManager for provider tests
// MockTokenManager 제거 - 실제 TokenManager와 Mock Dependencies 사용


@available(iOS 15, macOS 12, *)
final class TokenAuthProviderTests: XCTestCase {
    
    // var mockTokenManager: MockTokenManager! // 제거: MockTokenManager 사용 안 함
    // 실제 TokenManager 사용
    // var tokenManager: TokenManager! // 각 테스트에서 생성하도록 변경
    var mockApiClient: MockNetifyClient!
    var mockTokenStorage: InMemoryTokenStorage!
    // var authProvider: TokenAuthProvider! // 각 테스트에서 생성하도록 변경
    let storageKey = "test.authprovider.token"
    // Replace Bool flag and optional expectation with a state actor
    var failureState: FailureHandlerState!
    
    // @MainActor // 핸들러 디스패치가 명시적이므로 제거 가능
    override func setUp() {
        super.setUp()
        // mockTokenManager = MockTokenManager() // 제거: MockTokenManager 사용 안 함
        mockApiClient = MockNetifyClient()
        mockTokenStorage = InMemoryTokenStorage()
        failureState = FailureHandlerState() // Initialize the state actor
        // TokenManager 및 AuthProvider 생성은 각 테스트 메서드로 이동
    }
    
    override func tearDown() {
        // tokenManager = nil // 각 테스트에서 생성되므로 여기서 정리할 필요 없음
        mockApiClient = nil
        mockTokenStorage = nil
        // authProvider = nil // 각 테스트에서 생성되므로 여기서 정리할 필요 없음
        failureState = nil // Clean up the state actor
        super.tearDown()
    }
    
    // MARK: - Authenticate Tests
    
    // 의도: authenticate가 TokenManager의 유효한 토큰으로 인증 헤더를 성공적으로 추가하는지 확인합니다.
    // 주어진 상황: 유효하고 만료되지 않은 토큰을 가진 TokenManager. AuthProvider를 위한 사용자 정의 헤더 이름 및 접두사.
    // 실행 시점: AuthProvider에서 authenticate가 호출될 때.
    // 예상 결과: 반환된 URLRequest는 토큰 및 접두사가 포함된 올바른 인증 헤더를 가져야 합니다.
    func testAuthenticate_Success() async throws {
        let originalRequest = URLRequest(url: URL(string: "https://example.com/data")!)
        let expectedToken = "auth-success-token"
        
        // TokenManager가 사용할 토큰을 Storage에 저장
        let initialToken = createTestTokenInfo(accessToken: expectedToken, accessTokenExpiresIn: 3600)
        try await mockTokenStorage.save(tokenInfo: initialToken, forKey: storageKey)
        
        // Create TokenManager AFTER storage is populated
        let tokenManager = TokenManager(
            tokenStorage: mockTokenStorage,
            storageKey: storageKey,
            apiClient: mockApiClient,
            refreshRequestProvider: { MockRefreshRequest(refreshToken: $0) },
            revokeRequestProvider: { MockRevokeRequest(refreshToken: $0) }
        )
        
        // Create AuthProvider
        let authProvider = TokenAuthProvider(
            tokenManager: tokenManager,
            headerName: "X-Auth-Test",
            tokenPrefix: "TestBearer ",
            onAuthenticationFailed: { /* Handler setup as needed */ }
        )
        
        // Wait for TokenManager to finish its initial load
        let initialLoadExpectation = expectation(description: "Wait for TokenManager initial load")
        let streamTask = Task {
            for await _ in await tokenManager.tokenStream {
                initialLoadExpectation.fulfill()
                break // Only need the very first emission
            }
        }
        // If tokenManager.tokenStream is guaranteed to emit immediately upon subscription
        // even if loadInitialToken is still running, this is fine.
        // If loadInitialToken completes *before* the stream is fully set up to emit,
        // a slight delay or a more direct signal from TokenManager might be needed.
        // For now, this pattern is generally good.
        await fulfillment(of: [initialLoadExpectation], timeout: 1.0)
        streamTask.cancel() // Cancel the task after getting the first emission
        
        let authenticatedRequest = try await authProvider.authenticate(request: originalRequest)
        
        let authHeader = authenticatedRequest.value(forHTTPHeaderField: "X-Auth-Test")
        XCTAssertEqual(authHeader, "TestBearer \(expectedToken)")
        // API 호출 여부 확인 (이 경우 API 호출 없음)
        XCTAssertNil(mockApiClient.sendHandler, "API client should not have been called")
    }
    
    // 의도: authenticate가 TokenManager의 오류(예: TokenError.tokenNotFound)를 전파하는지 확인합니다.
    // 주어진 상황: 토큰을 가져오려고 할 때 TokenError.tokenNotFound를 발생시키는 TokenManager (예: 스토리지가 비어 있음).
    // 실행 시점: AuthProvider에서 authenticate가 호출될 때.
    // 예상 결과: authenticate 메서드에서 동일한 TokenError.tokenNotFound가 발생해야 합니다.
    func testAuthenticate_TokenManagerError() async throws {
        let originalRequest = URLRequest(url: URL(string: "https://example.com/data")!)
        let expectedError = TokenError.tokenNotFound
        // Storage를 비워 TokenNotFound 유도
        // await mockTokenStorage.clearAll() // setUp에서 이미 비어 있음
        
        // Create TokenManager AFTER storage is confirmed empty
        let tokenManager = TokenManager(
            tokenStorage: mockTokenStorage,
            storageKey: storageKey,
            apiClient: mockApiClient,
            refreshRequestProvider: { MockRefreshRequest(refreshToken: $0) },
            revokeRequestProvider: { MockRevokeRequest(refreshToken: $0) }
        )
        
        // Create AuthProvider
        let authProvider = TokenAuthProvider(
            tokenManager: tokenManager,
            headerName: "X-Auth-Test",
            tokenPrefix: "TestBearer "
        )
        
        // Use do-catch instead of XCTAssertThrowsError
        do {
            _ = try await authProvider.authenticate(request: originalRequest)
            XCTFail("Expected authenticate to throw \(expectedError), but it succeeded.")
        } catch let error as TokenError { // Remove unnecessary cast
            XCTAssertEqual(error, expectedError)
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
        // let callCount = await mockTokenManager.getValidAccessTokenCallCount // 제거: MockTokenManager 사용 안 함
        // XCTAssertEqual(callCount, 1) // 제거: MockTokenManager 사용 안 함
    }
    
    // 의도: 현재 토큰이 만료된 경우 authenticate가 TokenManager를 통해 토큰 갱신을 트리거한 다음 새 토큰을 사용하는지 확인합니다.
    // 주어진 상황: 초기에 만료된 접근 토큰과 유효한 갱신 토큰을 가진 TokenManager. API 클라이언트는 성공적인 갱신을 위해 모의 설정됩니다.
    // 실행 시점: AuthProvider에서 authenticate가 호출될 때.
    // 예상 결과: TokenManager는 토큰을 갱신해야 하며, AuthProvider는 인증 헤더에 *새* 접근 토큰을 사용해야 합니다.
    func testAuthenticate_RefreshesToken_Success() async throws {
        let originalRequest = URLRequest(url: URL(string: "https://example.com/data")!)
        let newAccessToken = "refreshed-during-auth"
        let now = Date()
        let initialExpiredToken = createTestTokenInfo(accessTokenExpiresIn: -100, refreshTokenExpiresIn: 3600, receivedAt: now)
        
        // Save initial expired token
        try await mockTokenStorage.save(tokenInfo: initialExpiredToken, forKey: storageKey)
        
        // Create TokenManager
        let tokenManager = TokenManager(
            tokenStorage: mockTokenStorage,
            storageKey: storageKey,
            apiClient: mockApiClient,
            refreshRequestProvider: { MockRefreshRequest(refreshToken: $0) },
            revokeRequestProvider: { MockRevokeRequest(refreshToken: $0) }
        )
        
        // Create AuthProvider
        let authProvider = TokenAuthProvider(
            tokenManager: tokenManager,
            headerName: "Authorization",
            tokenPrefix: "Bearer "
        )
        
        // Wait for initial load
        let initialLoadExpectation = expectation(description: "Wait for TokenManager initial load")
        let streamTask = Task {
            for await _ in await tokenManager.tokenStream { initialLoadExpectation.fulfill(); break }
        }
        await fulfillment(of: [initialLoadExpectation], timeout: 1.0)
        streamTask.cancel()
        
        // Mock API to return refreshed token
        let refreshResponse = MockTokenRefreshResponse.validResponse(newAccessToken: newAccessToken)
        var refreshApiCalled = false
        mockApiClient.sendHandler = { request in
            XCTAssertTrue(request is MockRefreshRequest)
            refreshApiCalled = true
            return refreshResponse
        }
        
        // Call authenticate - should trigger refresh
        let authenticatedRequest = try await authProvider.authenticate(request: originalRequest)
        
        // Verify
        XCTAssertTrue(refreshApiCalled, "Refresh API should have been called")
        let authHeader = authenticatedRequest.value(forHTTPHeaderField: "Authorization")
        XCTAssertEqual(authHeader, "Bearer \(newAccessToken)", "Header should contain the NEW access token")
    }
    
    // 의도: 제공된 경우 authenticate가 사용자 정의 헤더 이름과 토큰 접두사를 올바르게 사용하는지 확인합니다.
    // 주어진 상황: 유효한 토큰을 가진 TokenManager. 사용자 정의 헤더 이름("X-My-Auth")과 접두사("Custom ")로 초기화된 AuthProvider.
    // 실행 시점: authenticate가 호출될 때.
    // 예상 결과: 반환된 URLRequest는 인증 헤더에 사용자 정의 헤더 이름과 접두사를 사용해야 합니다.
    func testAuthenticate_CustomHeaderAndPrefix() async throws {
        let originalRequest = URLRequest(url: URL(string: "https://example.com/data")!)
        let expectedToken = "custom-header-token"
        let now = Date()
        let initialToken = createTestTokenInfo(accessToken: expectedToken, accessTokenExpiresIn: 3600, receivedAt: now)
        try await mockTokenStorage.save(tokenInfo: initialToken, forKey: storageKey)
        
        // Create components similar to testAuthenticate_Success, but with custom provider settings
        let tokenManager = TokenManager(tokenStorage: mockTokenStorage, storageKey: storageKey, apiClient: mockApiClient, refreshRequestProvider: { MockRefreshRequest(refreshToken: $0) }, revokeRequestProvider: { MockRevokeRequest(refreshToken: $0) })
        let authProvider = TokenAuthProvider(tokenManager: tokenManager, headerName: "X-My-Auth", tokenPrefix: "Custom ")
        let initialLoadExpectation = expectation(description: "Wait for initial load"); let streamTask = Task { for await _ in await tokenManager.tokenStream { initialLoadExpectation.fulfill(); break } }; await fulfillment(of: [initialLoadExpectation], timeout: 1.0); streamTask.cancel()
        
        let authenticatedRequest = try await authProvider.authenticate(request: originalRequest)
        let authHeader = authenticatedRequest.value(forHTTPHeaderField: "X-My-Auth")
        XCTAssertEqual(authHeader, "Custom \(expectedToken)")
    }
    
    // MARK: - Refresh Authentication Tests
    
    // 의도: refreshAuthentication이 TokenManager를 통해 토큰 갱신을 성공적으로 트리거하고 true를 반환하는지 확인합니다.
    // 주어진 상황: 만료된 접근 토큰과 유효한 갱신 토큰을 가진 TokenManager. 성공적인 갱신을 위해 API 클라이언트가 모의 설정됩니다.
    // 실행 시점: AuthProvider에서 refreshAuthentication이 호출될 때.
    // 예상 결과: 메서드는 true를 반환해야 하며, onAuthenticationFailed 핸들러(제공된 경우)는 호출되지 않아야 합니다.
    func testRefreshAuthentication_Success() async throws {
        // 초기 만료된 토큰 설정
        let initialToken = createTestTokenInfo(accessTokenExpiresIn: -100, refreshTokenExpiresIn: 3600, receivedAt: Date())
        // let initialRefreshToken = initialToken.refreshToken! // 필요시 검증용
        try await mockTokenStorage.save(tokenInfo: initialToken, forKey: storageKey)
        
        // Create TokenManager AFTER storage is populated
        let tokenManager = TokenManager(
            tokenStorage: mockTokenStorage,
            storageKey: storageKey,
            apiClient: mockApiClient,
            refreshRequestProvider: { MockRefreshRequest(refreshToken: $0) },
            revokeRequestProvider: { MockRevokeRequest(refreshToken: $0) }
        )
        
        // Create AuthProvider with failure handler
        let authProvider = TokenAuthProvider(
            tokenManager: tokenManager, // Capture the actor state instead of self
            onAuthenticationFailed: { [failureState] in Task { await failureState?.markCalledAndFulfill() }
            }
        )
        // Wait for TokenManager to finish its initial load
        let initialLoadExpectation = expectation(description: "Wait for TokenManager initial load for refresh success")
        let streamTask = Task {
            for await _ in await tokenManager.tokenStream { initialLoadExpectation.fulfill(); break }
        }
        await fulfillment(of: [initialLoadExpectation], timeout: 1.0)
        streamTask.cancel()
        
        // API Mock 설정 (성공 응답)
        let newAccessToken = "refreshed-token"
        let refreshResponse = MockTokenRefreshResponse.validResponse(newAccessToken: newAccessToken)
        mockApiClient.sendHandler = { request in
            XCTAssertTrue(request is MockRefreshRequest)
            return refreshResponse
        }
        
        let success = try await authProvider.refreshAuthentication()
        
        XCTAssertTrue(success)
        let wasCalled = await failureState.wasCalled // Check state via actor
        XCTAssertFalse(wasCalled, "Handler should not be called on success")
    }
    
    // 의도: TokenManager가 누락된 갱신 토큰으로 인해 갱신할 수 없는 경우 refreshAuthentication이 false를 반환하고 onAuthenticationFailed를 호출하는지 확인합니다.
    // 주어진 상황: 만료된 접근 토큰과 갱신 토큰이 없는 TokenManager.
    // 실행 시점: AuthProvider에서 refreshAuthentication이 호출될 때.
    // 예상 결과: 메서드는 false를 반환해야 하며, onAuthenticationFailed 핸들러가 호출되어야 합니다.
    func testRefreshAuthentication_Failure_RefreshTokenMissing() async throws {
        // Refresh Token이 없는 초기 토큰 설정
        let now = Date()
        let initialToken = createTestTokenInfo(accessTokenExpiresIn: -100, refreshToken: nil, refreshTokenExpiresIn: nil, receivedAt: now)
        
        try await mockTokenStorage.save(tokenInfo: initialToken, forKey: storageKey)
        
        // Create TokenManager AFTER storage is populated
        let tokenManager = TokenManager(
            tokenStorage: mockTokenStorage,
            storageKey: storageKey,
            apiClient: mockApiClient,
            refreshRequestProvider: { MockRefreshRequest(refreshToken: $0) },
            revokeRequestProvider: { MockRevokeRequest(refreshToken: $0) }
        )
        
        // Create AuthProvider with failure handler and expectation
        let authProvider = TokenAuthProvider(
            tokenManager: tokenManager, // Capture the actor state
            onAuthenticationFailed: { [failureState] in Task { await failureState?.markCalledAndFulfill() }
            }
        )
        // Wait for TokenManager to finish its initial load
        let initialLoadExpectation = expectation(description: "Wait for TokenManager initial load for refresh failure (missing RT)")
        let streamTask = Task {
            for await _ in await tokenManager.tokenStream { initialLoadExpectation.fulfill(); break }
        }
        await fulfillment(of: [initialLoadExpectation], timeout: 1.0)
        streamTask.cancel()
        
        let expectation = expectation(description: "onAuthenticationFailed called for missing refresh token")
        await failureState.setExpectation(expectation) // Set expectation on the actor
        
        let success = try await authProvider.refreshAuthentication()
        
        await fulfillment(of: [expectation], timeout: 1.0) // Await the local expectation
        
        XCTAssertFalse(success)
        let wasCalled = await failureState.wasCalled // Check state via actor
        XCTAssertTrue(wasCalled, "Handler should have been called")
    }
    
    // 의도: TokenManager가 토큰 정보(TokenNotFound)를 찾을 수 없는 경우 refreshAuthentication이 false를 반환하고 onAuthenticationFailed를 호출하는지 확인합니다.
    // 주어진 상황: 비어 있는 스토리지(토큰 없음)를 가진 TokenManager.
    // 실행 시점: AuthProvider에서 refreshAuthentication이 호출될 때.
    // 예상 결과: 메서드는 false를 반환해야 하며, onAuthenticationFailed 핸들러가 호출되어야 합니다.
    func testRefreshAuthentication_Failure_TokenNotFound() async throws {
        // This scenario is similar to RefreshTokenMissing in terms of outcome for the provider
        // Storage를 비워서 TokenNotFound 유도
        // await mockTokenStorage.clearAll() // 이미 비어 있음
        
        // Create TokenManager AFTER storage is confirmed empty
        let tokenManager = TokenManager(
            tokenStorage: mockTokenStorage,
            storageKey: storageKey,
            apiClient: mockApiClient,
            refreshRequestProvider: { MockRefreshRequest(refreshToken: $0) },
            revokeRequestProvider: { MockRevokeRequest(refreshToken: $0) }
        )
        
        // Create AuthProvider with failure handler and expectation
        let authProvider = TokenAuthProvider(
            tokenManager: tokenManager, // Capture the actor state
            onAuthenticationFailed: { [failureState] in Task { await failureState?.markCalledAndFulfill() }
            }
        )
        // Wait for TokenManager to finish its initial load
        let initialLoadExpectation = expectation(description: "Wait for TokenManager initial load for refresh failure (missing RT)")
        let streamTask = Task { // Renamed from previous test, ensure unique description if needed or combine tests
            for await _ in await tokenManager.tokenStream { initialLoadExpectation.fulfill(); break }
        }
        await fulfillment(of: [initialLoadExpectation], timeout: 1.0)
        streamTask.cancel()
        
        let expectation = expectation(description: "onAuthenticationFailed called for token not found during refresh")
        await failureState.setExpectation(expectation) // Set expectation on the actor
        
        let success = try await authProvider.refreshAuthentication()
        
        await fulfillment(of: [expectation], timeout: 1.0) // Await the local expectation
        
        XCTAssertFalse(success)
        let wasCalled = await failureState.wasCalled // Check state via actor
        XCTAssertTrue(wasCalled, "Handler should have been called")
    }
    
    // 의도: TokenManager의 갱신 시도가 일반적인 API 오류로 인해 실패하는 경우 refreshAuthentication이 false를 반환하고 onAuthenticationFailed를 호출하는지 확인합니다.
    // 주어진 상황: 만료된 접근 토큰과 유효한 갱신 토큰을 가진 TokenManager. API 클라이언트는 갱신 중 일반적인 오류를 발생시키도록 모의 설정됩니다.
    // 실행 시점: AuthProvider에서 refreshAuthentication이 호출될 때.
    // 예상 결과: 메서드는 false를 반환해야 하며, onAuthenticationFailed 핸들러가 호출되어야 합니다.
    func testRefreshAuthentication_Failure_GeneralError() async throws {
        let underlyingError = NSError(domain: "TestError", code: 123, userInfo: nil)
        // 초기 만료된 토큰 설정
        let now = Date()
        let initialToken = createTestTokenInfo(accessTokenExpiresIn: -100, refreshTokenExpiresIn: 3600, receivedAt: now)
        
        try await mockTokenStorage.save(tokenInfo: initialToken, forKey: storageKey)
        
        // Create TokenManager AFTER storage is populated
        let tokenManager = TokenManager(
            tokenStorage: mockTokenStorage,
            storageKey: storageKey,
            apiClient: mockApiClient,
            refreshRequestProvider: { MockRefreshRequest(refreshToken: $0) },
            revokeRequestProvider: { MockRevokeRequest(refreshToken: $0) }
        )
        
        // Create AuthProvider with failure handler and expectation
        let authProvider = TokenAuthProvider(
            tokenManager: tokenManager, // Capture the actor state
            onAuthenticationFailed: { [failureState] in Task { await failureState?.markCalledAndFulfill() }
            }
        )
        // Wait for TokenManager to finish its initial load
        let initialLoadExpectation = expectation(description: "Wait for TokenManager initial load for refresh failure (general error)")
        let streamTask = Task {
            for await _ in await tokenManager.tokenStream { initialLoadExpectation.fulfill(); break }
        }
        await fulfillment(of: [initialLoadExpectation], timeout: 1.0)
        streamTask.cancel()
        
        // API Mock 설정 (에러 발생)
        mockApiClient.sendHandler = { _ in throw underlyingError }
        
        let expectation = expectation(description: "onAuthenticationFailed called for general refresh error")
        await failureState.setExpectation(expectation) // Set expectation on the actor
        
        let success = try await authProvider.refreshAuthentication()
        
        await fulfillment(of: [expectation], timeout: 1.0) // Await the local expectation
        
        XCTAssertFalse(success)
        let wasCalled = await failureState.wasCalled // Check state via actor
        XCTAssertTrue(wasCalled, "Handler should have been called")
    }
    
    // 의도: onAuthenticationFailed 핸들러가 nil이고 갱신 실패가 발생하는 경우 refreshAuthentication이 false를 반환하지만 충돌하지 않는지 확인합니다.
    // 주어진 상황: 갱신에 실패하도록 구성된 TokenManager (예: 누락된 갱신 토큰). onAuthenticationFailed 핸들러 없이 초기화된 AuthProvider.
    // 실행 시점: refreshAuthentication이 호출될 때.
    // 예상 결과: 메서드는 false를 반환해야 하며, nil 핸들러로 인해 충돌이 발생하지 않아야 합니다.
    func testRefreshAuthentication_NoFailureHandler() async throws {
        // Refresh Token이 없는 초기 토큰 설정
        let now = Date()
        let initialToken = createTestTokenInfo(accessTokenExpiresIn: -100, refreshToken: nil, refreshTokenExpiresIn: nil, receivedAt: now)
        
        try await mockTokenStorage.save(tokenInfo: initialToken, forKey: storageKey)
        
        // Create TokenManager AFTER storage is populated
        let tokenManager = TokenManager(
            tokenStorage: mockTokenStorage,
            storageKey: storageKey,
            apiClient: mockApiClient,
            refreshRequestProvider: { MockRefreshRequest(refreshToken: $0) },
            revokeRequestProvider: { MockRevokeRequest(refreshToken: $0) }
        )
        
        // Create AuthProvider without the handler
        let authProvider = TokenAuthProvider(
            tokenManager: tokenManager,
            onAuthenticationFailed: nil // No handler
        )
        // Wait for TokenManager to finish its initial load
        let initialLoadExpectation = expectation(description: "Wait for TokenManager initial load for no failure handler test")
        let streamTask = Task {
            for await _ in await tokenManager.tokenStream { initialLoadExpectation.fulfill(); break }
        }
        await fulfillment(of: [initialLoadExpectation], timeout: 1.0)
        streamTask.cancel()
        
        let success = try await authProvider.refreshAuthentication()
        
        // Wait a short moment to ensure handler *would* have been called if present
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let wasCalled = await failureState.wasCalled // Check state via actor
        XCTAssertFalse(success)
        XCTAssertFalse(wasCalled, "Handler should not have been called")
    }
    
    
    // MARK: - Is Authentication Expired Tests
    
    // Helper to create a dummy provider for these tests
    private func createDummyAuthProvider() -> TokenAuthProvider {
        // These tests don't rely on TokenManager state, so a dummy one is fine
        let dummyManager = TokenManager(
            tokenStorage: InMemoryTokenStorage(), // Use a fresh dummy storage
            storageKey: "dummy",
            apiClient: MockNetifyClient(),
            refreshRequestProvider: { MockRefreshRequest(refreshToken: $0) },
            revokeRequestProvider: { MockRevokeRequest(refreshToken: $0) }
        )
        return TokenAuthProvider(tokenManager: dummyManager)
    }
    
    // 의도: isAuthenticationExpired가 NetworkRequestError.unauthorized에 대해 true를 반환하는지 확인합니다.
    // 주어진 상황: NetworkRequestError.unauthorized 오류.
    // 실행 시점: 이 오류로 isAuthenticationExpired가 호출될 때.
    // 예상 결과: 메서드는 true를 반환해야 합니다.
    func testIsAuthenticationExpired_UnauthorizedError() async throws {
        let authProvider = createDummyAuthProvider()
        let error = NetworkRequestError.unauthorized(data: nil)
        XCTAssertTrue(authProvider.isAuthenticationExpired(from: error))
    }
    
    // 의도: isAuthenticationExpired가 NetworkRequestError.forbidden에 대해 false를 반환하는지 확인합니다.
    // 주어진 상황: NetworkRequestError.forbidden 오류.
    // 실행 시점: 이 오류로 isAuthenticationExpired가 호출될 때.
    // 예상 결과: 메서드는 false를 반환해야 합니다.
    func testIsAuthenticationExpired_ForbiddenError() async throws {
        let authProvider = createDummyAuthProvider()
        let error = NetworkRequestError.forbidden(data: nil)
        XCTAssertFalse(authProvider.isAuthenticationExpired(from: error), "Forbidden should not be treated as expired by default")
    }
    
    // 의도: isAuthenticationExpired가 401이 아닌 상태 코드를 가진 NetworkRequestError.clientError에 대해 false를 반환하는지 확인합니다.
    // 주어진 상황: 상태 코드 400을 가진 NetworkRequestError.clientError.
    // 실행 시점: 이 오류로 isAuthenticationExpired가 호출될 때.
    // 예상 결과: 메서드는 false를 반환해야 합니다.
    func testIsAuthenticationExpired_ClientError_Not401() async throws {
        let authProvider = createDummyAuthProvider()
        // Assuming Netify defines clientError like this
        let error = NetworkRequestError.clientError(statusCode: 400, data: nil)
        XCTAssertFalse(authProvider.isAuthenticationExpired(from: error))
    }
    
    // 의도: 현재 구현이 .unauthorized 케이스만 명시적으로 확인하므로, 상태 코드가 401이더라도 isAuthenticationExpired가 NetworkRequestError.clientError에 대해 false를 반환하는지 확인합니다.
    // 주어진 상황: 상태 코드 401을 가진 NetworkRequestError.clientError.
    // 실행 시점: 이 오류로 isAuthenticationExpired가 호출될 때.
    // 예상 결과: 메서드는 false를 반환해야 합니다. 401에 대해서는 .unauthorized 열거형 케이스만 명시적으로 처리하기 때문입니다.
    func testIsAuthenticationExpired_ClientError_Is401() async throws {
        let authProvider = createDummyAuthProvider()
        // NOTE: The current implementation relies ONLY on the `.unauthorized` case.
        // If Netify's `.clientError` could also represent 401, this test would fail,
        // indicating a potential need to update `isAuthenticationExpired`.
        let error = NetworkRequestError.clientError(statusCode: 401, data: nil)
        XCTAssertFalse(authProvider.isAuthenticationExpired(from: error), "ClientError(401) is not currently handled as expired")
    }
    
    // 의도: isAuthenticationExpired가 NetworkRequestError.serverError에 대해 false를 반환하는지 확인합니다.
    // 주어진 상황: NetworkRequestError.serverError.
    // 실행 시점: 이 오류로 isAuthenticationExpired가 호출될 때.
    // 예상 결과: 메서드는 false를 반환해야 합니다.
    func testIsAuthenticationExpired_ServerError() async throws {
        let authProvider = createDummyAuthProvider()
        let error = NetworkRequestError.serverError(statusCode: 500, data: nil)
        XCTAssertFalse(authProvider.isAuthenticationExpired(from: error))
    }
    
    // 의도: isAuthenticationExpired가 NetworkRequestError가 아닌 일반적인 Error 타입에 대해 false를 반환하는지 확인합니다.
    // 주어진 상황: 표준 NSError.
    // 실행 시점: 이 오류로 isAuthenticationExpired가 호출될 때.
    // 예상 결과: 메서드는 false를 반환해야 합니다.
    func testIsAuthenticationExpired_OtherError() async throws {
        let authProvider = createDummyAuthProvider()
        let error = NSError(domain: "TestDomain", code: 1, userInfo: nil)
        XCTAssertFalse(authProvider.isAuthenticationExpired(from: error))
    }
}

// Actor to manage failure handler state safely across concurrency domains
actor FailureHandlerState {
    var wasCalled = false
    private var expectation: XCTestExpectation? // Keep expectation private
    
    // Set the expectation from the test method
    func setExpectation(_ expectation: XCTestExpectation) {
        self.expectation = expectation
    }
    
    // Called from the nonisolated closure passed to TokenAuthProvider
    func markCalledAndFulfill() {
        wasCalled = true
        // Fulfill the expectation if it's set
        expectation?.fulfill()
    }
}
