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

        // Wait for TokenManager's initial load to complete
        // This ensures the load attempt uses the already saved token
        // Wait for TokenManager to finish its initial load by consuming the first stream emission
        let initialLoadExpectation = expectation(description: "Wait for TokenManager initial load")
        let streamTask = Task {
            for await _ in await tokenManager.tokenStream {
                initialLoadExpectation.fulfill()
                break // Only need the very first emission
            }
        }
        await fulfillment(of: [initialLoadExpectation], timeout: 1.0)
        streamTask.cancel() // Cancel the task after getting the first emission
        
        let authenticatedRequest = try await authProvider.authenticate(request: originalRequest)
        
        let authHeader = authenticatedRequest.value(forHTTPHeaderField: "X-Auth-Test")
        XCTAssertEqual(authHeader, "TestBearer \(expectedToken)")
        // API 호출 여부 확인 (이 경우 API 호출 없음)
        XCTAssertNil(mockApiClient.sendHandler, "API client should not have been called")
    }
    
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
    
    func testAuthenticate_RefreshesToken_Success() async throws {
        let originalRequest = URLRequest(url: URL(string: "https://example.com/data")!)
        let initialExpiredToken = createTestTokenInfo(accessTokenExpiresIn: -100, refreshTokenExpiresIn: 3600)
        let newAccessToken = "refreshed-during-auth"

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

    func testAuthenticate_CustomHeaderAndPrefix() async throws {
        let originalRequest = URLRequest(url: URL(string: "https://example.com/data")!)
        let expectedToken = "custom-header-token"
        let initialToken = createTestTokenInfo(accessToken: expectedToken, accessTokenExpiresIn: 3600)
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
    
    func testRefreshAuthentication_Success() async throws {
        // 초기 만료된 토큰 설정
        let initialToken = createTestTokenInfo(accessTokenExpiresIn: -100, refreshTokenExpiresIn: 3600)
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
        try await Task.sleep(nanoseconds: 50_000_000) // 초기 로드 시작 대기
        
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
    
    func testRefreshAuthentication_Failure_RefreshTokenMissing() async throws {
        // Refresh Token이 없는 초기 토큰 설정
        let initialToken = createTestTokenInfo(accessTokenExpiresIn: -100, refreshToken: nil, refreshTokenExpiresIn: nil)
        
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
        try await Task.sleep(nanoseconds: 50_000_000) // 초기 로드 시작 대기
        
        let expectation = expectation(description: "onAuthenticationFailed called for missing refresh token")
        await failureState.setExpectation(expectation) // Set expectation on the actor
        
        let success = try await authProvider.refreshAuthentication()
        
        await fulfillment(of: [expectation], timeout: 1.0) // Await the local expectation
        
        XCTAssertFalse(success)
        let wasCalled = await failureState.wasCalled // Check state via actor
        XCTAssertTrue(wasCalled, "Handler should have been called")
    }
    
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
        try await Task.sleep(nanoseconds: 50_000_000) // 초기 로드 시작 대기
        
        let expectation = expectation(description: "onAuthenticationFailed called for token not found during refresh")
        await failureState.setExpectation(expectation) // Set expectation on the actor
        
        let success = try await authProvider.refreshAuthentication()
        
        await fulfillment(of: [expectation], timeout: 1.0) // Await the local expectation
        
        XCTAssertFalse(success)
        let wasCalled = await failureState.wasCalled // Check state via actor
        XCTAssertTrue(wasCalled, "Handler should have been called")
    }
    
    func testRefreshAuthentication_Failure_GeneralError() async throws {
        let underlyingError = NSError(domain: "TestError", code: 123, userInfo: nil)
        // 초기 만료된 토큰 설정
        let initialToken = createTestTokenInfo(accessTokenExpiresIn: -100, refreshTokenExpiresIn: 3600)
        
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
        try await Task.sleep(nanoseconds: 50_000_000) // 초기 로드 시작 대기
        
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
    
    func testRefreshAuthentication_NoFailureHandler() async throws {
        // Refresh Token이 없는 초기 토큰 설정
        let initialToken = createTestTokenInfo(accessTokenExpiresIn: -100, refreshToken: nil, refreshTokenExpiresIn: nil)
        
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
        try await Task.sleep(nanoseconds: 50_000_000) // 초기 로드 시작 대기
        
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
    
    func testIsAuthenticationExpired_UnauthorizedError() async throws {
        let authProvider = createDummyAuthProvider()
        let error = NetworkRequestError.unauthorized(data: nil)
        XCTAssertTrue(authProvider.isAuthenticationExpired(from: error))
    }
    
    func testIsAuthenticationExpired_ForbiddenError() async throws {
        let authProvider = createDummyAuthProvider()
        let error = NetworkRequestError.forbidden(data: nil)
        XCTAssertFalse(authProvider.isAuthenticationExpired(from: error), "Forbidden should not be treated as expired by default")
    }
    
    func testIsAuthenticationExpired_ClientError_Not401() async throws {
        let authProvider = createDummyAuthProvider()
        // Assuming Netify defines clientError like this
        let error = NetworkRequestError.clientError(statusCode: 400, data: nil)
        XCTAssertFalse(authProvider.isAuthenticationExpired(from: error))
    }
    
    func testIsAuthenticationExpired_ClientError_Is401() async throws {
        let authProvider = createDummyAuthProvider()
        // NOTE: The current implementation relies ONLY on the `.unauthorized` case.
        // If Netify's `.clientError` could also represent 401, this test would fail,
        // indicating a potential need to update `isAuthenticationExpired`.
        let error = NetworkRequestError.clientError(statusCode: 401, data: nil)
        // The current isAuthenticationExpired logic only checks for the specific .unauthorized case.
        // It does NOT check the status code within .clientError.
        // Therefore, this test correctly expects false based on the current implementation.
        XCTAssertFalse(authProvider.isAuthenticationExpired(from: error), "ClientError(401) is not currently handled as expired")
    }
    
    
    func testIsAuthenticationExpired_ServerError() async throws {
        let authProvider = createDummyAuthProvider()
        let error = NetworkRequestError.serverError(statusCode: 500, data: nil)
        XCTAssertFalse(authProvider.isAuthenticationExpired(from: error))
    }
    
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
