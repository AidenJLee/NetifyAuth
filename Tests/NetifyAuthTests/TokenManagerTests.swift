// Tests/NetifyAuthTests/TokenManagerTests.swift
import XCTest
import Netify // For NetworkRequestError
@testable import NetifyAuth

@available(iOS 15, macOS 12, *)
final class TokenManagerTests: XCTestCase {
    
    var tokenManager: TokenManager!
    var mockApiClient: MockNetifyClient!
    var mockTokenStorage: InMemoryTokenStorage! // Use InMemory for most tests
    let storageKey = "test.token"
    var refreshRequestProvider: TokenManager.RefreshRequestProvider!
    var revokeRequestProvider: TokenManager.RevokeRequestProvider!
    
    // Helper to setup TokenManager with standard InMemoryTokenStorage
    func setupTokenManager(initialToken: TokenInfo? = nil) async {
        mockApiClient = MockNetifyClient()
        mockTokenStorage = InMemoryTokenStorage() // Standard mock storage
        
        if let token = initialToken {
            try? await mockTokenStorage.save(tokenInfo: token, forKey: storageKey)
        }
        
        refreshRequestProvider = { MockRefreshRequest(refreshToken: $0) }
        revokeRequestProvider = { MockRevokeRequest(refreshToken: $0) }
        
        tokenManager = TokenManager(
            tokenStorage: mockTokenStorage, // Use standard mock storage
            storageKey: storageKey,
            apiClient: mockApiClient,
            refreshRequestProvider: refreshRequestProvider,
            revokeRequestProvider: revokeRequestProvider,
            accessTokenRefreshBuffer: 60, // 1 minute buffer
            refreshTokenBuffer: 0
        )
        // Allow time for initial token loading if needed
        await Task.yield()
    }
    
    // MARK: - Initialization Tests
    
    func testInitialTokenLoad_Success() async throws {
        let initialToken = createTestTokenInfo()
        await setupTokenManager(initialToken: initialToken)
        
        // Wait for potential async load
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        let token = await tokenManager.getRefreshToken()
        XCTAssertEqual(token, initialToken.refreshToken)
        
        // Check stream
        let streamExpectation = expectation(description: "Token stream emits initial token")
        var receivedToken: TokenInfo?
        let task = Task {
            for await tokenInfo in await tokenManager.tokenStream {
                receivedToken = tokenInfo
                streamExpectation.fulfill()
                break // Only need the first emission
            }
        }
        await fulfillment(of: [streamExpectation], timeout: 1.0)
        task.cancel()
        XCTAssertEqual(receivedToken, initialToken)
    }
    
    func testInitialTokenLoad_NotFound() async throws {
        await setupTokenManager(initialToken: nil) // No initial token
        
        // Wait for potential async load
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        let token = await tokenManager.getRefreshToken()
        XCTAssertNil(token)
        
        // Check stream
        let streamExpectation = expectation(description: "Token stream emits nil")
        var receivedTokenValue: TokenInfo? = createTestTokenInfo() // Non-nil initial value
        let task = Task {
            for await tokenInfo in await tokenManager.tokenStream {
                receivedTokenValue = tokenInfo
                streamExpectation.fulfill()
                break // Only need the first emission
            }
        }
        await fulfillment(of: [streamExpectation], timeout: 1.0)
        task.cancel()
        XCTAssertNil(receivedTokenValue)
    }
    
    func testInitialTokenLoad_StorageFailure() async throws {
        // Use MockFailableTokenStorage for this test
        let failableStorage = MockFailableTokenStorage()
        mockApiClient = MockNetifyClient()
        refreshRequestProvider = { MockRefreshRequest(refreshToken: $0) }
        revokeRequestProvider = { MockRevokeRequest(refreshToken: $0) }

        // Configure storage to fail on load
        let expectedError = TokenError.storageError(description: "Load failed!")
        await failableStorage.failNextLoad(error: expectedError)

        // Create manager directly with failable storage
        let manager = TokenManager(
            tokenStorage: failableStorage,
            storageKey: storageKey,
            apiClient: mockApiClient,
            refreshRequestProvider: refreshRequestProvider,
            revokeRequestProvider: revokeRequestProvider
        )
        // Wait for the async load attempt in init to complete
        try await Task.sleep(nanoseconds: 100_000_000)
        // Verify internal state is nil after load failure
        let refreshToken = await manager.getRefreshToken() // Await outside the assertion
        XCTAssertNil(refreshToken, "Token should be nil after initial load failure")
    }
    
    // MARK: - Get Valid Access Token Tests
    
    func testGetValidAccessToken_ValidToken() async throws {
        let validToken = createTestTokenInfo(accessTokenExpiresIn: 3600) // Valid for 1 hour
        await setupTokenManager(initialToken: validToken)
        try await Task.sleep(nanoseconds: 100_000_000) // Ensure load
        
        let accessToken = try await tokenManager.getValidAccessToken()
        XCTAssertEqual(accessToken, validToken.accessToken)
    }
    
    func testGetValidAccessToken_NoToken() async throws {
        await setupTokenManager(initialToken: nil)
        try await Task.sleep(nanoseconds: 100_000_000) // Ensure load attempt
        
        do {
            _ = try await tokenManager.getValidAccessToken()
            XCTFail("Expected TokenError.tokenNotFound but getValidAccessToken succeeded.")
        } catch let error as TokenError {
            XCTAssertEqual(error, .tokenNotFound)
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
    }
    
    func testGetValidAccessToken_NeedsRefresh_Success() async throws {
        let expiredAccessToken = Date().addingTimeInterval(-100) // Expired
        let initialToken = createTestTokenInfo(
            accessTokenExpiresIn: 0,
            refreshTokenExpiresIn: 3600,
            receivedAt: expiredAccessToken
        )
        await setupTokenManager(initialToken: initialToken)
        try await Task.sleep(nanoseconds: 100_000_000) // Ensure load
        
        let newAccessToken = "new-access-token-123"
        let refreshResponse = MockTokenRefreshResponse.validResponse(newAccessToken: newAccessToken)
        
        mockApiClient.sendHandler = { request in
            XCTAssertTrue(request is MockRefreshRequest)
            guard let mockRequest = request as? MockRefreshRequest else {
                XCTFail("Expected MockRefreshRequest")
                throw TokenError.unknown(message: "Test setup error: Unexpected request type")
            }
            XCTAssertEqual(mockRequest.refreshToken, initialToken.refreshToken)
            return refreshResponse
        }
        
        let streamExpectation = expectation(description: "Token stream emits refreshed token")
        var receivedRefreshedToken: TokenInfo?
        let task = Task {
            var initialEmissionSkipped = false
            for await tokenInfo in await tokenManager.tokenStream {
                if !initialEmissionSkipped {
                    initialEmissionSkipped = true
                    continue
                }
                receivedRefreshedToken = tokenInfo
                streamExpectation.fulfill()
                break
            }
        }
        
        let accessToken = try await tokenManager.getValidAccessToken()
        
        await fulfillment(of: [streamExpectation], timeout: 2.0)
        task.cancel()
        
        XCTAssertEqual(accessToken, newAccessToken)
        let storedToken = try await mockTokenStorage.load(forKey: storageKey)
        XCTAssertEqual(storedToken.accessToken, newAccessToken)
        XCTAssertEqual(storedToken.refreshToken, refreshResponse.refreshToken)
        XCTAssertEqual(receivedRefreshedToken?.accessToken, newAccessToken)
    }
    
    func testGetValidAccessToken_NeedsRefresh_WithinBuffer_Success() async throws {
        let soonToExpireToken = createTestTokenInfo(
            accessTokenExpiresIn: 30,
            refreshTokenExpiresIn: 3600
        )
        await setupTokenManager(initialToken: soonToExpireToken)
        try await Task.sleep(nanoseconds: 100_000_000) // Ensure load
        
        let newAccessToken = "refreshed-within-buffer-token"
        let refreshResponse = MockTokenRefreshResponse.validResponse(newAccessToken: newAccessToken)
        var refreshApiCalled = false
        
        mockApiClient.sendHandler = { request in
            XCTAssertTrue(request is MockRefreshRequest)
            guard let mockRequest = request as? MockRefreshRequest else {
                XCTFail("Expected MockRefreshRequest")
                throw TokenError.unknown(message: "Test setup error: Unexpected request type")
            }
            XCTAssertEqual(mockRequest.refreshToken, soonToExpireToken.refreshToken)
            refreshApiCalled = true
            return refreshResponse
        }
        
        let streamExpectation = expectation(description: "Token stream emits refreshed token (buffer)")
        var receivedRefreshedToken: TokenInfo?
        let task = Task {
            var initialEmissionSkipped = false
            for await tokenInfo in await tokenManager.tokenStream {
                if !initialEmissionSkipped {
                    initialEmissionSkipped = true
                    continue
                }
                receivedRefreshedToken = tokenInfo
                streamExpectation.fulfill()
                break
            }
        }
        
        let accessToken = try await tokenManager.getValidAccessToken()
        
        await fulfillment(of: [streamExpectation], timeout: 2.0)
        task.cancel()
        
        XCTAssertTrue(refreshApiCalled, "Refresh API should have been called due to buffer")
        XCTAssertEqual(accessToken, newAccessToken)
        let storedToken = try await mockTokenStorage.load(forKey: storageKey)
        XCTAssertEqual(storedToken.accessToken, newAccessToken)
        XCTAssertEqual(storedToken.refreshToken, refreshResponse.refreshToken)
        XCTAssertEqual(receivedRefreshedToken?.accessToken, newAccessToken)
    }
    
    func testGetValidAccessToken_NeedsRefresh_RefreshTokenMissing() async throws {
        let expiredAccessToken = Date().addingTimeInterval(-100)
        let initialToken = createTestTokenInfo(
            accessTokenExpiresIn: 0,
            refreshToken: nil,
            refreshTokenExpiresIn: nil,
            receivedAt: expiredAccessToken
        )
        await setupTokenManager(initialToken: initialToken)
        try await Task.sleep(nanoseconds: 100_000_000) // Ensure load
        
        do {
            _ = try await tokenManager.getValidAccessToken()
            XCTFail("Expected TokenError.refreshTokenMissing but getValidAccessToken succeeded.")
        } catch let error as TokenError {
            XCTAssertEqual(error, .refreshTokenMissing)
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
    }
    
    func testGetValidAccessToken_NeedsRefresh_RefreshTokenExpired() async throws {
        let expiredDate = Date().addingTimeInterval(-86500)
        let initialToken = createTestTokenInfo(
            accessTokenExpiresIn: 0,
            refreshTokenExpiresIn: 86400,
            receivedAt: expiredDate
        )
        await setupTokenManager(initialToken: initialToken)
        try await Task.sleep(nanoseconds: 100_000_000) // Ensure load
        
        do {
            _ = try await tokenManager.getValidAccessToken()
            XCTFail("Expected TokenError.refreshTokenMissing but getValidAccessToken succeeded.")
        } catch let error as TokenError {
            XCTAssertEqual(error, .refreshTokenMissing)
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
    }
    
    func testGetValidAccessToken_NeedsRefresh_ApiFailure() async throws {
        let expiredAccessToken = Date().addingTimeInterval(-100)
        let initialToken = createTestTokenInfo(
            accessTokenExpiresIn: 0,
            refreshTokenExpiresIn: 3600,
            receivedAt: expiredAccessToken
        )
        await setupTokenManager(initialToken: initialToken)
        try await Task.sleep(nanoseconds: 100_000_000) // Ensure load
        
        let apiError = NetworkRequestError.serverError(statusCode: 500, data: nil)
        mockApiClient.sendHandler = { _ in throw apiError }
        
        do {
            _ = try await tokenManager.getValidAccessToken()
            XCTFail("Expected TokenError.refreshFailed but getValidAccessToken succeeded.")
        } catch let error as TokenError {
            guard case .refreshFailed(let description) = error else {
                XCTFail("Expected TokenError.refreshFailed but got \(error)")
                return
            }
            XCTAssertTrue(description.contains(apiError.localizedDescription))
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
    }
    
    func testGetValidAccessToken_NeedsRefresh_ApiUnauthorized() async throws {
        let expiredAccessToken = Date().addingTimeInterval(-100)
        let initialToken = createTestTokenInfo(
            accessTokenExpiresIn: 0,
            refreshTokenExpiresIn: 3600,
            receivedAt: expiredAccessToken
        )
        await setupTokenManager(initialToken: initialToken)
        try await Task.sleep(nanoseconds: 100_000_000) // Ensure load
        
        let apiError = NetworkRequestError.unauthorized(data: nil) // 401
        mockApiClient.sendHandler = { _ in throw apiError }
        
        let streamExpectation = expectation(description: "Token stream emits nil after unauthorized refresh")
        var receivedNilToken = false
        let task = Task {
            var initialEmissionSkipped = false
            for await tokenInfo in await tokenManager.tokenStream {
                if !initialEmissionSkipped {
                    initialEmissionSkipped = true
                    continue
                }
                if tokenInfo == nil {
                    receivedNilToken = true
                    streamExpectation.fulfill()
                }
                break
            }
        }
        
        do {
            _ = try await tokenManager.getValidAccessToken()
            XCTFail("Expected TokenError.refreshTokenMissing but getValidAccessToken succeeded.")
        } catch let error as TokenError {
            XCTAssertEqual(error, .refreshTokenMissing, "Unauthorized refresh should result in refreshTokenMissing")
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
        
        await fulfillment(of: [streamExpectation], timeout: 2.0)
        task.cancel()
        
        do {
            _ = try await mockTokenStorage.load(forKey: storageKey)
            XCTFail("Expected TokenError.tokenNotFound but load succeeded.")
        } catch let error as TokenError {
            XCTAssertEqual(error, .tokenNotFound)
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
        XCTAssertTrue(receivedNilToken, "Stream should have emitted nil")
    }
    
    func testGetValidAccessToken_NeedsRefresh_ApiDecodingError() async throws {
        let expiredAccessToken = Date().addingTimeInterval(-100)
        let initialToken = createTestTokenInfo(
            accessTokenExpiresIn: 0,
            refreshTokenExpiresIn: 3600,
            receivedAt: expiredAccessToken
        )
        await setupTokenManager(initialToken: initialToken)
        try await Task.sleep(nanoseconds: 100_000_000) // Ensure load
        
        let underlyingDecodeError = NSError(domain: "TestDecode", code: 1)
        // Use the correct associated value label 'underlyingError' and add 'data' if needed
        // Assuming the case is defined as decodingError(underlyingError: Error, data: Data?)
        let apiError = NetworkRequestError.decodingError(underlyingError: underlyingDecodeError, data: nil)
        mockApiClient.sendHandler = { _ in throw apiError }
        
        do {
            _ = try await tokenManager.getValidAccessToken()
            XCTFail("Expected TokenError.refreshFailed due to decoding error but getValidAccessToken succeeded.")
        } catch let error as TokenError {
            guard case .refreshFailed(let description) = error else {
                XCTFail("Expected TokenError.refreshFailed but got \(error)")
                return
            }
            XCTAssertTrue(description.contains(apiError.localizedDescription), "Error description should contain underlying decoding error info")
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
    }
    
    func testGetValidAccessToken_ForceRefresh_Success() async throws {
        let validToken = createTestTokenInfo(accessTokenExpiresIn: 3600)
        await setupTokenManager(initialToken: validToken)
        try await Task.sleep(nanoseconds: 100_000_000) // Ensure load
        
        let newAccessToken = "forced-refresh-token"
        let refreshResponse = MockTokenRefreshResponse.validResponse(newAccessToken: newAccessToken)
        mockApiClient.sendHandler = { _ in return refreshResponse }
        
        let accessToken = try await tokenManager.getValidAccessToken(forceRefresh: true)
        
        XCTAssertEqual(accessToken, newAccessToken)
        let storedToken = try await mockTokenStorage.load(forKey: storageKey)
        XCTAssertEqual(storedToken.accessToken, newAccessToken)
    }
    
    func testGetValidAccessToken_ConcurrentRefresh() async throws {
        let expiredAccessToken = Date().addingTimeInterval(-100)
        let initialToken = createTestTokenInfo(
            accessTokenExpiresIn: 0,
            refreshTokenExpiresIn: 3600,
            receivedAt: expiredAccessToken
        )
        await setupTokenManager(initialToken: initialToken)
        try await Task.sleep(nanoseconds: 100_000_000) // Ensure load
        
        let newAccessToken = "concurrent-refresh-token"
        let refreshResponse = MockTokenRefreshResponse.validResponse(newAccessToken: newAccessToken)
        let apiCallCount = ActorIsolated(0)
        
        mockApiClient.sendHandler = { [apiCallCount] _ in
            try await Task.sleep(nanoseconds: 200_000_000)
            await apiCallCount.increment()
            return refreshResponse
        }
        
        async let firstCall = tokenManager.getValidAccessToken()
        async let secondCall = tokenManager.getValidAccessToken()
        
        let (firstResult, secondResult) = try await (firstCall, secondCall)
        
        XCTAssertEqual(firstResult, newAccessToken)
        XCTAssertEqual(secondResult, newAccessToken)
        
        let finalCount = await apiCallCount.value
        XCTAssertEqual(finalCount, 1, "API should only be called once for concurrent refreshes")
        
        let storedToken = try await mockTokenStorage.load(forKey: storageKey)
        XCTAssertEqual(storedToken.accessToken, newAccessToken)
    }
    
    
    // MARK: - Update Tokens Tests
    
    func testUpdateTokens() async throws {
        await setupTokenManager(initialToken: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        let newAccessToken = "updated-access"
        let newRefreshToken = "updated-refresh"
        let accessExpiresIn: TimeInterval = 1800
        let refreshExpiresIn: TimeInterval = 7200
        
        let streamExpectation = expectation(description: "Token stream emits updated token")
        var receivedUpdatedToken: TokenInfo?
        let task = Task {
            var initialEmissionSkipped = false
            for await tokenInfo in await tokenManager.tokenStream {
                if !initialEmissionSkipped {
                    initialEmissionSkipped = true
                    continue
                }
                receivedUpdatedToken = tokenInfo
                streamExpectation.fulfill()
                break
            }
        }
        
        try await tokenManager.updateTokens(
            accessToken: newAccessToken,
            accessTokenExpiresIn: accessExpiresIn,
            refreshToken: newRefreshToken,
            refreshTokenExpiresIn: refreshExpiresIn
        )
        
        await fulfillment(of: [streamExpectation], timeout: 1.0)
        task.cancel()
        
        let currentRefreshToken = await tokenManager.getRefreshToken()
        XCTAssertEqual(currentRefreshToken, newRefreshToken)
        
        let storedToken = try await mockTokenStorage.load(forKey: storageKey)
        XCTAssertEqual(storedToken.accessToken, newAccessToken)
        XCTAssertEqual(storedToken.refreshToken, newRefreshToken)
        XCTAssertNotNil(storedToken.accessTokenExpiresAt)
        XCTAssertNotNil(storedToken.refreshTokenExpiresAt)
        
        XCTAssertEqual(receivedUpdatedToken?.accessToken, newAccessToken)
        XCTAssertEqual(receivedUpdatedToken?.refreshToken, newRefreshToken)
    }
    
    func testUpdateTokens_AccessTokenOnly() async throws {
        let initialToken = createTestTokenInfo(refreshToken: "initial-refresh")
        await setupTokenManager(initialToken: initialToken)
        try await Task.sleep(nanoseconds: 100_000_000) // Ensure initial load
        
        let newAccessToken = "updated-access-only"
        let accessExpiresIn: TimeInterval = 1800
        
        let streamExpectation = expectation(description: "Token stream emits updated token (access only)")
        var receivedUpdatedToken: TokenInfo?
        let task = Task {
            var initialEmissionSkipped = false
            for await tokenInfo in await tokenManager.tokenStream {
                if !initialEmissionSkipped {
                    initialEmissionSkipped = true
                    continue
                }
                receivedUpdatedToken = tokenInfo
                streamExpectation.fulfill()
                break
            }
        }
        
        try await tokenManager.updateTokens(
            accessToken: newAccessToken,
            accessTokenExpiresIn: accessExpiresIn,
            refreshToken: nil,
            refreshTokenExpiresIn: nil
        )
        
        await fulfillment(of: [streamExpectation], timeout: 1.0)
        task.cancel()
        
        let currentRefreshToken = await tokenManager.getRefreshToken()
        XCTAssertNil(currentRefreshToken, "Refresh token should be nil after access-only update")
        
        let storedToken = try await mockTokenStorage.load(forKey: storageKey)
        XCTAssertEqual(storedToken.accessToken, newAccessToken)
        XCTAssertNil(storedToken.refreshToken, "Stored refresh token should be nil")
        XCTAssertNil(storedToken.refreshTokenExpiresAt, "Stored refresh token expiry should be nil")
        
        XCTAssertEqual(receivedUpdatedToken?.accessToken, newAccessToken)
        XCTAssertNil(receivedUpdatedToken?.refreshToken, "Streamed refresh token should be nil")
    }
    
    func testUpdateTokens_StorageFailure() async throws {
        // Use MockFailableTokenStorage for this test
        let failableStorage = MockFailableTokenStorage()
        mockApiClient = MockNetifyClient()
        refreshRequestProvider = { MockRefreshRequest(refreshToken: $0) }
        revokeRequestProvider = { MockRevokeRequest(refreshToken: $0) }
        
        // Create manager directly with failable storage
        let manager = TokenManager(
            tokenStorage: failableStorage,
            storageKey: storageKey,
            apiClient: mockApiClient,
            refreshRequestProvider: refreshRequestProvider,
            revokeRequestProvider: revokeRequestProvider
        )
        try await Task.sleep(nanoseconds: 100_000_000) // Allow init load attempt
        
        let expectedError = TokenError.storageError(description: "Save failed!")
        await failableStorage.failNextSave(error: expectedError)
        
        do {
            try await manager.updateTokens(
                accessToken: "access", accessTokenExpiresIn: 3600,
                refreshToken: "refresh", refreshTokenExpiresIn: 86400
            )
            XCTFail("Expected updateTokens to throw a storage error, but it succeeded.")
        } catch let error as TokenError {
            XCTAssertEqual(error, expectedError, "Expected storage error was not thrown")
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
    }
    
    // MARK: - Clear Tokens Tests
    
    func testClearTokens() async throws {
        let initialToken = createTestTokenInfo()
        await setupTokenManager(initialToken: initialToken)
        try await Task.sleep(nanoseconds: 100_000_000) // Ensure load
        
        let streamExpectation = expectation(description: "Token stream emits nil after clear")
        var emissions: [TokenInfo?] = []
        let task = Task {
            for await tokenInfo in await tokenManager.tokenStream {
                emissions.append(tokenInfo)
                if emissions.count == 2 {
                    streamExpectation.fulfill()
                    break
                }
            }
        }
        
        try await Task.sleep(nanoseconds: 50_000_000) // Give stream time to emit initial
        
        try await tokenManager.clearTokens()
        
        await fulfillment(of: [streamExpectation], timeout: 1.0)
        task.cancel()
        
        let currentRefreshToken = await tokenManager.getRefreshToken()
        XCTAssertNil(currentRefreshToken)
        
        XCTAssertEqual(emissions.count, 2, "Should have received two emissions")
        XCTAssertEqual(emissions.first ?? nil, initialToken, "First emission should be the initial token")
        XCTAssertNil(emissions.last ?? initialToken, "Second emission should be nil")
        
        do {
            _ = try await mockTokenStorage.load(forKey: storageKey)
            XCTFail("Expected TokenError.tokenNotFound but load succeeded.")
        } catch let error as TokenError {
            XCTAssertEqual(error, .tokenNotFound)
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
    }
    
    func testClearTokens_WhenNoTokenExists() async throws {
        await setupTokenManager(initialToken: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        
        try await tokenManager.clearTokens()
        
        let currentRefreshToken = await tokenManager.getRefreshToken()
        XCTAssertNil(currentRefreshToken)
        do {
            _ = try await mockTokenStorage.load(forKey: storageKey)
            XCTFail("Expected TokenError.tokenNotFound but load succeeded.")
        } catch TokenError.tokenNotFound {
            // Expected
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
    }
    
    
    // MARK: - Revoke Tokens Tests
    
    func testRevokeTokens_Success() async throws {
        let initialToken = createTestTokenInfo()
        await setupTokenManager(initialToken: initialToken)
        try await Task.sleep(nanoseconds: 100_000_000) // Ensure load
        
        var revokeApiCalled = false
        mockApiClient.sendHandler = { request in
            XCTAssertTrue(request is MockRevokeRequest)
            guard let mockRequest = request as? MockRevokeRequest else {
                XCTFail("Expected MockRevokeRequest")
                throw TokenError.unknown(message: "Test setup error: Unexpected request type")
            }
            XCTAssertEqual(mockRequest.refreshToken, initialToken.refreshToken)
            revokeApiCalled = true
            return EmptyResponse()
        }
        
        let streamExpectation = expectation(description: "Token stream emits nil after revoke")
        var receivedNilToken = false
        let task = Task {
            var initialEmissionSkipped = false
            for await tokenInfo in await tokenManager.tokenStream {
                if !initialEmissionSkipped {
                    initialEmissionSkipped = true
                    continue
                }
                if tokenInfo == nil {
                    receivedNilToken = true
                    streamExpectation.fulfill()
                }
                break
            }
        }
        
        try await tokenManager.revokeTokens()
        
        await fulfillment(of: [streamExpectation], timeout: 1.0)
        task.cancel()
        
        XCTAssertTrue(revokeApiCalled, "Revoke API should have been called")
        XCTAssertTrue(receivedNilToken, "Stream should have emitted nil")
        
        let currentRefreshToken = await tokenManager.getRefreshToken()
        XCTAssertNil(currentRefreshToken)
        do {
            _ = try await mockTokenStorage.load(forKey: storageKey)
            XCTFail("Expected TokenError.tokenNotFound but load succeeded.")
        } catch TokenError.tokenNotFound {
            // Expected
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
    }
    
    func testRevokeTokens_ApiFailure() async throws {
        let initialToken = createTestTokenInfo()
        await setupTokenManager(initialToken: initialToken)
        try await Task.sleep(nanoseconds: 100_000_000) // Ensure load
        
        let apiError = NetworkRequestError.serverError(statusCode: 500, data: nil)
        var revokeApiCalled = false
        mockApiClient.sendHandler = { request in
            revokeApiCalled = true
            throw apiError
        }
        
        let streamExpectation = expectation(description: "Token stream emits nil even after failed revoke")
        var receivedNilToken = false
        let task = Task {
            var initialEmissionSkipped = false
            for await tokenInfo in await tokenManager.tokenStream {
                if !initialEmissionSkipped {
                    initialEmissionSkipped = true
                    continue
                }
                if tokenInfo == nil {
                    receivedNilToken = true
                    streamExpectation.fulfill()
                }
                break
            }
        }
        
        do {
            try await tokenManager.revokeTokens()
            XCTFail("Expected TokenError.revocationFailed but revokeTokens succeeded.")
        } catch let error as TokenError {
            guard case .revocationFailed(let underlyingError) = error else {
                XCTFail("Expected TokenError.revocationFailed but got \(error)")
                return
            }
            XCTAssertEqual(underlyingError as? NetworkRequestError, apiError)
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
        
        await fulfillment(of: [streamExpectation], timeout: 1.0)
        task.cancel()
        
        XCTAssertTrue(revokeApiCalled, "Revoke API should have been called")
        XCTAssertTrue(receivedNilToken, "Stream should have emitted nil")
        
        let currentRefreshToken = await tokenManager.getRefreshToken()
        XCTAssertNil(currentRefreshToken)
        do {
            _ = try await mockTokenStorage.load(forKey: storageKey)
            XCTFail("Expected TokenError.tokenNotFound but load succeeded.")
        } catch TokenError.tokenNotFound {
            // Expected
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
    }
    
    func testRevokeTokens_StorageFailure() async throws {
        // Use MockFailableTokenStorage for this test
        let failableStorage = MockFailableTokenStorage()
        mockApiClient = MockNetifyClient()
        refreshRequestProvider = { MockRefreshRequest(refreshToken: $0) }
        revokeRequestProvider = { MockRevokeRequest(refreshToken: $0) }
        
        let initialToken = createTestTokenInfo()
        try await failableStorage.save(tokenInfo: initialToken, forKey: storageKey) // Pre-populate
        
        // Create manager directly with failable storage
        let manager = TokenManager(
            tokenStorage: failableStorage,
            storageKey: storageKey,
            apiClient: mockApiClient,
            refreshRequestProvider: refreshRequestProvider,
            revokeRequestProvider: revokeRequestProvider
        )
        try await Task.sleep(nanoseconds: 100_000_000) // Allow init load
        
        var revokeApiCalled = false
        mockApiClient.sendHandler = { _ in
            revokeApiCalled = true
            return EmptyResponse() // API succeeds
        }
        
        let expectedError = TokenError.storageError(description: "Delete failed!")
        await failableStorage.failNextDelete(error: expectedError)
        
        do {
            try await manager.revokeTokens()
            XCTFail("Expected revokeTokens to throw a storage error, but it succeeded.")
        } catch let error as TokenError {
            // Note: The current implementation prioritizes throwing storage errors over API errors.
            // If API fails AND storage fails, storage error is thrown.
            XCTAssertEqual(error, expectedError, "Expected storage error was not thrown")
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
        
        XCTAssertTrue(revokeApiCalled, "Revoke API should have been called before storage failure")
        // Internal state might be nil due to clearTokens attempt, but storage still contains the token
        // Let's check storage directly
        let storedToken = try? await failableStorage.load(forKey: storageKey)
        XCTAssertNotNil(storedToken, "Token should still exist in storage after delete failure")
        XCTAssertEqual(storedToken, initialToken)
    }
    
    func testRevokeTokens_NoRefreshToken() async throws {
        let initialToken = createTestTokenInfo(refreshToken: nil, refreshTokenExpiresIn: nil)
        await setupTokenManager(initialToken: initialToken)
        try await Task.sleep(nanoseconds: 100_000_000) // Ensure load
        
        var revokeApiCalled = false
        mockApiClient.sendHandler = { _ in
            revokeApiCalled = true
            return EmptyResponse()
        }
        
        let streamExpectation = expectation(description: "Token stream emits nil after revoke without refresh token")
        var receivedNilToken = false
        let task = Task {
            var initialEmissionSkipped = false
            for await tokenInfo in await tokenManager.tokenStream {
                if !initialEmissionSkipped {
                    initialEmissionSkipped = true
                    continue
                }
                if tokenInfo == nil {
                    receivedNilToken = true
                    streamExpectation.fulfill()
                }
                break
            }
        }
        
        try await tokenManager.revokeTokens()
        
        await fulfillment(of: [streamExpectation], timeout: 1.0)
        task.cancel()
        
        XCTAssertFalse(revokeApiCalled, "Revoke API should not be called when no refresh token exists")
        XCTAssertTrue(receivedNilToken, "Stream should have emitted nil")
        
        let currentRefreshToken = await tokenManager.getRefreshToken()
        XCTAssertNil(currentRefreshToken)
        do {
            _ = try await mockTokenStorage.load(forKey: storageKey)
            XCTFail("Expected TokenError.tokenNotFound but load succeeded.")
        } catch TokenError.tokenNotFound {
            // Expected
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
    }
}

// Helper Actor for thread-safe counter
actor ActorIsolated<T> {
    var value: T
    init(_ value: T) {
        self.value = value
    }
    
    func increment() where T == Int {
        value += 1
    }
}

// Mock Storage that can simulate failures
actor MockFailableTokenStorage: TokenStorage {
    private var storage: [String: TokenInfo] = [:]
    var shouldFailOnSave = false
    var shouldFailOnLoad = false
    var shouldFailOnDelete = false
    var saveError: Error = TokenError.storageError(description: "Simulated save failure")
    var loadError: Error = TokenError.storageError(description: "Simulated load failure")
    var deleteError: Error = TokenError.storageError(description: "Simulated delete failure")
    
    func save(tokenInfo: TokenInfo, forKey key: String) async throws {
        if shouldFailOnSave {
            throw saveError
        }
        storage[key] = tokenInfo
    }
    
    func load(forKey key: String) async throws -> TokenInfo {
        if shouldFailOnLoad {
            throw loadError
        }
        guard let token = storage[key] else {
            throw TokenError.tokenNotFound
        }
        return token
    }
    
    func delete(forKey key: String) async throws {
        if shouldFailOnDelete {
            throw deleteError
        }
        // Simulate potential partial failure: remove only if key exists
        if storage[key] != nil {
            storage.removeValue(forKey: key)
        } else {
            // If key doesn't exist, don't throw, mimic standard delete behavior
        }
    }
    
    // Helper to clear storage for tests
    func clearAll() {
        storage.removeAll()
    }
    
    // Helper to configure failure
    func failNextSave(error: Error? = nil) {
        shouldFailOnSave = true
        if let error = error { saveError = error }
    }
    func failNextLoad(error: Error? = nil) {
        shouldFailOnLoad = true
        if let error = error { loadError = error }
    }
    func failNextDelete(error: Error? = nil) {
        shouldFailOnDelete = true
        if let error = error { deleteError = error }
    }
    func resetFailures() {
        shouldFailOnSave = false
        shouldFailOnLoad = false
        shouldFailOnDelete = false
    }
}
