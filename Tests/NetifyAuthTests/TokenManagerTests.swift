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
    // TokenManager를 표준 InMemoryTokenStorage로 설정하는 헬퍼 함수
    func setupTokenManager(initialToken: TokenInfo? = nil) async {
        mockApiClient = MockNetifyClient()
        mockTokenStorage = InMemoryTokenStorage() // 표준 모의 스토리지 사용
        
        if let token = initialToken {
            // 테스트 시나리오에 따라 초기 토큰을 스토리지에 미리 저장
            try? await mockTokenStorage.save(tokenInfo: token, forKey: storageKey)
        }
        
        refreshRequestProvider = { MockRefreshRequest(refreshToken: $0) }
        revokeRequestProvider = { MockRevokeRequest(refreshToken: $0) }
        
        tokenManager = TokenManager(
            tokenStorage: mockTokenStorage, // 표준 모의 스토리지 사용
            storageKey: storageKey,
            apiClient: mockApiClient,
            refreshRequestProvider: refreshRequestProvider,
            revokeRequestProvider: revokeRequestProvider,
            accessTokenRefreshBuffer: 60, // 1분 버퍼
            refreshTokenBuffer: 0
        )
        // TokenManager가 초기 로드를 완료할 때까지 대기 (첫 번째 스트림 방출 소비)
        // 이는 초기 상태가 설정되는 데 중요한 테스트에 필수적입니다.
        let initialLoadExpectation = expectation(description: "TokenManager initial load for setup: \(String(describing: initialToken?.accessToken))")
        let streamTask = Task {
            // tokenStream의 첫 번째 값을 기다려 초기화 완료를 확인합니다.
            // 이 값은 테스트 메서드 내에서 다시 확인하지 않을 수 있습니다.
            for await _ in await tokenManager.tokenStream {
                initialLoadExpectation.fulfill()
                break // 첫 번째 방출만 필요
            }
        }
        await fulfillment(of: [initialLoadExpectation], timeout: 1.0) // 필요에 따라 타임아웃 조정
        streamTask.cancel() // 스트림 소비 후 태스크 취소
    }
    
    // MARK: - Initialization Tests
    
    // 의도: TokenManager가 초기화 시 스토리지에서 기존 토큰을 올바르게 로드하는지 확인합니다.
    // 주어진 상황: TokenStorage에 저장된 TokenInfo 객체.
    // 실행 시점: 해당 스토리지와 키로 TokenManager가 초기화될 때.
    // 예상 결과: TokenManager는 로드된 토큰을 currentToken으로 가져야 하며, tokenStream은 이 토큰을 (버퍼링된 최신 값으로) 가지고 있어야 합니다.
    func testInitialTokenLoad_Success() async throws {
        let initialToken = createTestTokenInfo() // 테스트용 토큰 생성
        await setupTokenManager(initialToken: initialToken)
        
        // setupTokenManager에서 초기 로드를 이미 기다렸습니다.
        
        let currentRefreshToken = await tokenManager.getRefreshToken()
        XCTAssertEqual(currentRefreshToken, initialToken.refreshToken)
        
        // setupTokenManager에서 초기 로드가 완료되었으므로,
        // TokenManager의 currentToken은 initialToken으로 설정되어 있어야 합니다.
        // getValidAccessToken()은 String을 반환하므로, initialToken.accessToken과 비교합니다.
        let accessToken = try await tokenManager.getValidAccessToken()
        XCTAssertEqual(accessToken, initialToken.accessToken)
    }
    
    // 의도: TokenManager가 초기화 시 스토리지에서 토큰을 찾을 수 없는 경우를 올바르게 처리하는지 확인합니다.
    // 주어진 상황: 비어 있는 TokenStorage.
    // 실행 시점: TokenManager가 초기화될 때.
    // 예상 결과: TokenManager의 currentToken은 nil이어야 하며, tokenStream은 nil을 (버퍼링된 최신 값으로) 가지고 있어야 합니다.
    func testInitialTokenLoad_NotFound() async throws {
        await setupTokenManager(initialToken: nil) // 초기 토큰 없음
        
        // setupTokenManager에서 초기 로드를 이미 기다렸습니다.
        
        let currentRefreshToken = await tokenManager.getRefreshToken()
        XCTAssertNil(currentRefreshToken)
        
        // setupTokenManager에서 초기 로드가 완료되었고, initialToken이 nil이므로
        // TokenManager의 currentToken은 nil이어야 합니다.
        // getValidAccessToken() 호출 시 TokenError.tokenNotFound가 발생하는지 확인합니다.
        await XCTAssertThrowsErrorAsync(try await tokenManager.getValidAccessToken()) { error in
            XCTAssertEqual(error as? TokenError, .tokenNotFound)
        }
    }
    
    // 의도: TokenManager가 스토리지에서 초기 토큰 로드 중 실패를 처리하는지 확인합니다.
    // 주어진 상황: 로드 시 오류를 발생시키도록 구성된 TokenStorage.
    // 실행 시점: 이 실패 가능한 스토리지로 TokenManager가 초기화될 때.
    // 예상 결과: TokenManager의 currentToken은 nil이어야 하며, 충돌하지 않아야 합니다.
    func testInitialTokenLoad_StorageFailure() async throws {
        // 이 테스트에는 MockFailableTokenStorage 사용
        let failableStorage = MockFailableTokenStorage()
        mockApiClient = MockNetifyClient()
        refreshRequestProvider = { MockRefreshRequest(refreshToken: $0) }
        revokeRequestProvider = { MockRevokeRequest(refreshToken: $0) }
        
        // 스토리지 로드 실패 설정
        let expectedError = TokenError.storageError(description: "Load failed!")
        await failableStorage.failNextLoad(error: expectedError)
        
        // 실패 가능한 스토리지로 직접 매니저 생성
        // setupTokenManager를 사용하지 않으므로, 초기 스트림 대기를 여기서 직접 처리
        tokenManager = TokenManager(
            tokenStorage: failableStorage,
            storageKey: storageKey,
            apiClient: mockApiClient,
            refreshRequestProvider: refreshRequestProvider,
            revokeRequestProvider: revokeRequestProvider
        )
        // TokenManager 초기 로드 완료 대기
        let initialLoadExpectation = expectation(description: "TokenManager initial load for storage failure test")
        let streamTask = Task {
            for await _ in await tokenManager.tokenStream { initialLoadExpectation.fulfill(); break }
        }
        await fulfillment(of: [initialLoadExpectation], timeout: 2.0) // CI 환경 등을 고려하여 타임아웃 약간 증가
        streamTask.cancel()
        // 로드 실패 후 내부 상태가 nil인지 확인
        let refreshToken = await tokenManager.getRefreshToken() // 단언문 밖에서 await 호출
        XCTAssertNil(refreshToken, "Token should be nil after initial load failure")
    }
    
    // MARK: - Get Valid Access Token Tests
    
    // 의도: getValidAccessToken이 현재 접근 토큰이 유효하고 버퍼 내에 있지 않은 경우 해당 토큰을 반환하는지 확인합니다.
    // 주어진 상황: 유효하고, 만료되지 않았으며, 버퍼링되지 않은 접근 토큰을 가진 TokenManager.
    // 실행 시점: getValidAccessToken이 호출될 때.
    // 예상 결과: 현재 접근 토큰이 갱신 시도 없이 반환되어야 합니다.
    func testGetValidAccessToken_ValidToken() async throws {
        let validToken = createTestTokenInfo(accessTokenExpiresIn: 3600) // 1시간 동안 유효
        await setupTokenManager(initialToken: validToken)
        
        let accessToken = try await tokenManager.getValidAccessToken()
        XCTAssertEqual(accessToken, validToken.accessToken)
    }
    
    // 의도: 사용 가능한 토큰이 없는 경우 getValidAccessToken이 TokenError.tokenNotFound를 발생시키는지 확인합니다.
    // 주어진 상황: 현재 토큰이 없는 TokenManager.
    // 실행 시점: getValidAccessToken이 호출될 때.
    // 예상 결과: TokenError.tokenNotFound 오류가 발생해야 합니다.
    func testGetValidAccessToken_NoToken() async throws {
        await setupTokenManager(initialToken: nil) // 초기 토큰 없음
        
        do {
            _ = try await tokenManager.getValidAccessToken()
            XCTFail("Expected TokenError.tokenNotFound but getValidAccessToken succeeded.")
        } catch let error as TokenError {
            XCTAssertEqual(error, .tokenNotFound)
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
    }
    
    // 의도: 유효한 갱신 토큰이 있는 경우 만료된 접근 토큰을 getValidAccessToken이 성공적으로 갱신하는지 확인합니다.
    // 주어진 상황: 만료된 접근 토큰과 유효한 갱신 토큰을 가진 TokenManager. API 클라이언트는 성공적인 갱신 응답을 반환하도록 모의 설정됩니다.
    // 실행 시점: getValidAccessToken이 호출될 때.
    // 예상 결과: 토큰이 갱신되고, 새 접근 토큰이 반환되며, 새 토큰이 스토리지에 저장되고, tokenStream이 새 토큰을 방출해야 합니다.
    func testGetValidAccessToken_NeedsRefresh_Success() async throws {
        let now = Date()
        // 접근 토큰이 이미 만료되도록 생성 (예: 'now'보다 100초 전에 만료)
        let initialToken = createTestTokenInfo(
            accessTokenExpiresIn: -100, // 'now' 기준으로 100초 전에 만료됨
            refreshTokenExpiresIn: 3600, // 갱신 토큰은 유효
            receivedAt: now
        )
        await setupTokenManager(initialToken: initialToken)
        
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
        var finalStreamValueAfterRefresh: TokenInfo?
        
        // getValidAccessToken 호출 전에 스트림 구독 시작
        let streamTask = Task {
            for await tokenInfo in await tokenManager.tokenStream {
                // 이 루프는 스트림의 현재 값과 그 이후의 모든 변화를 받습니다.
                // 우리는 갱신 후의 값을 확인하고 싶습니다.
                if tokenInfo?.accessToken == newAccessToken {
                    finalStreamValueAfterRefresh = tokenInfo
                    streamExpectation.fulfill()
                    break // 원하는 값을 받았으므로 루프 종료
                }
            }
        }
        
        let accessToken = try await tokenManager.getValidAccessToken() // 이 호출이 스트림 변화를 유발
        
        await fulfillment(of: [streamExpectation], timeout: 2.0)
        streamTask.cancel()
        
        XCTAssertEqual(accessToken, newAccessToken)
        let storedToken = try await mockTokenStorage.load(forKey: storageKey)
        XCTAssertEqual(storedToken.accessToken, newAccessToken)
        XCTAssertEqual(storedToken.refreshToken, refreshResponse.refreshToken)
        XCTAssertEqual(finalStreamValueAfterRefresh?.accessToken, newAccessToken)
    }
    
    // 의도: 접근 토큰이 완전히 만료되지 않았더라도 갱신 버퍼 기간 내에 있는 경우 getValidAccessToken이 토큰을 갱신하는지 확인합니다.
    // 주어진 상황: 30초 후에 만료될 접근 토큰과 60초의 accessTokenRefreshBuffer를 가진 TokenManager. 유효한 갱신 토큰이 존재합니다.
    // 실행 시점: getValidAccessToken이 호출될 때.
    // 예상 결과: 토큰이 갱신되고, 새 접근 토큰이 반환되며, 새 토큰이 스토리지에 저장되고, tokenStream이 새 토큰을 방출해야 합니다.
    func testGetValidAccessToken_NeedsRefresh_WithinBuffer_Success() async throws {
        let now = Date()
        let soonToExpireToken = createTestTokenInfo(
            accessTokenExpiresIn: 30, // 'now'로부터 30초 후에 만료
            refreshTokenExpiresIn: 3600, // 'now'로부터 1시간 동안 유효한 갱신 토큰
            receivedAt: now
        )
        await setupTokenManager(initialToken: soonToExpireToken)
        
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
        var finalStreamValueAfterRefresh: TokenInfo?
        
        let streamTask = Task {
            for await tokenInfo in await tokenManager.tokenStream {
                if tokenInfo?.accessToken == newAccessToken {
                    finalStreamValueAfterRefresh = tokenInfo
                    streamExpectation.fulfill()
                    break
                }
            }
        }
        
        let accessToken = try await tokenManager.getValidAccessToken()
        
        await fulfillment(of: [streamExpectation], timeout: 2.0)
        streamTask.cancel()
        
        XCTAssertTrue(refreshApiCalled, "Refresh API should have been called due to buffer")
        XCTAssertEqual(accessToken, newAccessToken)
        let storedToken = try await mockTokenStorage.load(forKey: storageKey)
        XCTAssertEqual(storedToken.accessToken, newAccessToken)
        XCTAssertEqual(storedToken.refreshToken, refreshResponse.refreshToken)
        XCTAssertEqual(finalStreamValueAfterRefresh?.accessToken, newAccessToken)
    }
    
    // 의도: 접근 토큰 갱신이 필요하지만 사용 가능한 갱신 토큰이 없는 경우 getValidAccessToken이 TokenError.refreshTokenMissing을 발생시키는지 확인합니다.
    // 주어진 상황: 만료된 접근 토큰과 갱신 토큰이 없는 TokenManager.
    // 실행 시점: getValidAccessToken이 호출될 때.
    // 예상 결과: TokenError.refreshTokenMissing 오류가 발생해야 합니다.
    func testGetValidAccessToken_NeedsRefresh_RefreshTokenMissing() async throws {
        let now = Date()
        let initialToken = createTestTokenInfo(
            accessTokenExpiresIn: -100, // 만료됨
            refreshToken: nil,
            refreshTokenExpiresIn: nil,
            receivedAt: now
        )
        await setupTokenManager(initialToken: initialToken)
        
        do {
            _ = try await tokenManager.getValidAccessToken()
            XCTFail("Expected TokenError.refreshTokenMissing but getValidAccessToken succeeded.")
        } catch let error as TokenError {
            XCTAssertEqual(error, .refreshTokenMissing)
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
    }
    
    // 의도: 접근 토큰 갱신이 필요하지만 갱신 토큰 자체가 만료된 경우 getValidAccessToken이 TokenError.refreshTokenMissing을 발생시키는지 확인합니다.
    // 주어진 상황: 만료된 접근 토큰과 만료된 갱신 토큰을 가진 TokenManager.
    // 실행 시점: getValidAccessToken이 호출될 때.
    // 예상 결과: TokenError.refreshTokenMissing 오류가 발생해야 합니다.
    func testGetValidAccessToken_NeedsRefresh_RefreshTokenExpired() async throws {
        let now = Date()
        // 'now' 기준으로 접근 토큰과 갱신 토큰 모두 이미 만료되도록 생성
        let initialToken = createTestTokenInfo(
            accessTokenExpiresIn: -100,     // 접근 토큰 만료됨
            refreshTokenExpiresIn: -86400, // 갱신 토큰 만료됨 (1일 전)
            receivedAt: now
        )
        await setupTokenManager(initialToken: initialToken)
        
        do {
            _ = try await tokenManager.getValidAccessToken()
            XCTFail("Expected TokenError.refreshTokenMissing but getValidAccessToken succeeded.")
        } catch let error as TokenError {
            XCTAssertEqual(error, .refreshTokenMissing)
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
    }
    
    // 의도: 토큰 갱신 API 호출이 일반적인 네트워크 오류로 실패하는 경우 getValidAccessToken이 TokenError.refreshFailed를 발생시키는지 확인합니다.
    // 주어진 상황: 만료된 접근 토큰과 유효한 갱신 토큰을 가진 TokenManager. API 클라이언트는 갱신 중 서버 오류를 발생시키도록 모의 설정됩니다.
    // 실행 시점: getValidAccessToken이 호출될 때.
    // 예상 결과: 원래 API 오류의 설명을 포함하는 TokenError.refreshFailed 오류가 발생해야 합니다.
    func testGetValidAccessToken_NeedsRefresh_ApiFailure() async throws {
        let now = Date()
        let initialToken = createTestTokenInfo(
            accessTokenExpiresIn: -100, // 만료됨
            refreshTokenExpiresIn: 3600,
            receivedAt: now
        )
        await setupTokenManager(initialToken: initialToken)
        
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
    
    // 의도: 토큰 갱신 API가 무단(401) 오류를 반환하는 경우, 로컬 토큰이 지워지고, TokenError.refreshTokenMissing이 발생하며, tokenStream이 nil을 방출하는지 확인합니다.
    // 주어진 상황: 만료된 접근 토큰과 유효한 갱신 토큰을 가진 TokenManager. API 클라이언트는 갱신 중 401 오류를 반환하도록 모의 설정됩니다.
    // 실행 시점: getValidAccessToken이 호출될 때.
    // 예상 결과: 로컬 토큰이 지워지고, TokenError.refreshTokenMissing이 발생하며, tokenStream이 nil을 방출해야 합니다.
    func testGetValidAccessToken_NeedsRefresh_ApiUnauthorized() async throws {
        let now = Date()
        let initialToken = createTestTokenInfo(
            accessTokenExpiresIn: -100, // 만료됨
            refreshTokenExpiresIn: 3600,
            receivedAt: now
        )
        await setupTokenManager(initialToken: initialToken)
        
        let apiError = NetworkRequestError.unauthorized(data: nil) // 401
        mockApiClient.sendHandler = { _ in throw apiError }
        
        let streamExpectation = expectation(description: "Token stream emits nil after unauthorized refresh")
        var finalStreamValueAfterFailure: TokenInfo? = initialToken // 초기값을 예상과 다르게 설정
        
        let streamTask = Task {
            // 스트림은 여러 값을 방출할 수 있습니다 (예: 초기값, 갱신 시도 중 값, 최종 nil).
            // 우리는 최종적으로 nil이 되는 것을 기다립니다.
            var lastSeenToken: TokenInfo? = initialToken
            for await tokenInfo in await tokenManager.tokenStream {
                lastSeenToken = tokenInfo
                if lastSeenToken == nil { // 최종적으로 nil이 되면 성공
                    finalStreamValueAfterFailure = nil
                    streamExpectation.fulfill()
                    break
                }
            }
            // 타임아웃 시 XCTFail을 유도하기 위해, 루프가 끝나도 expectation이 fulfill되지 않으면 실패합니다.
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
        streamTask.cancel()
        
        do {
            _ = try await mockTokenStorage.load(forKey: storageKey)
            XCTFail("Expected TokenError.tokenNotFound but load succeeded.")
        } catch let error as TokenError {
            XCTAssertEqual(error, .tokenNotFound)
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
        XCTAssertNil(finalStreamValueAfterFailure, "Stream should have emitted nil")
    }
    
    // 의도: 토큰 갱신 API 응답을 디코딩할 수 없는 경우 TokenError.refreshFailed가 발생하는지 확인합니다.
    // 주어진 상황: 만료된 접근 토큰과 유효한 갱신 토큰을 가진 TokenManager. API 클라이언트는 디코딩 오류를 발생시키도록 모의 설정됩니다.
    // 실행 시점: getValidAccessToken이 호출될 때.
    // 예상 결과: 디코딩 오류의 설명을 포함하는 TokenError.refreshFailed 오류가 발생해야 합니다.
    func testGetValidAccessToken_NeedsRefresh_ApiDecodingError() async throws {
        let now = Date()
        let initialToken = createTestTokenInfo(
            accessTokenExpiresIn: -100, // 만료됨
            refreshTokenExpiresIn: 3600,
            receivedAt: now
        )
        await setupTokenManager(initialToken: initialToken)
        
        let underlyingDecodeError = NSError(domain: "TestDecode", code: 1)
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
    
    // 의도: 현재 토큰이 유효하더라도 forceRefresh가 true인 경우 getValidAccessToken이 강제로 갱신을 수행하는지 확인합니다.
    // 주어진 상황: 유효한 접근 토큰을 가진 TokenManager. API 클라이언트는 성공적인 갱신을 위해 모의 설정됩니다.
    // 실행 시점: forceRefresh: true로 getValidAccessToken이 호출될 때.
    // 예상 결과: 토큰이 갱신되고, 새 접근 토큰이 반환되며, 새 토큰이 스토리지에 저장되고, tokenStream이 새 토큰을 방출해야 합니다.
    func testGetValidAccessToken_ForceRefresh_Success() async throws {
        let validToken = createTestTokenInfo(accessTokenExpiresIn: 3600) // 1시간 동안 유효
        await setupTokenManager(initialToken: validToken)
        
        let newAccessToken = "forced-refresh-token"
        let refreshResponse = MockTokenRefreshResponse.validResponse(newAccessToken: newAccessToken)
        mockApiClient.sendHandler = { _ in return refreshResponse }
        
        let accessToken = try await tokenManager.getValidAccessToken(forceRefresh: true)
        
        XCTAssertEqual(accessToken, newAccessToken)
        let storedToken = try await mockTokenStorage.load(forKey: storageKey)
        XCTAssertEqual(storedToken.accessToken, newAccessToken)
    }
    
    // 의도: 갱신이 필요할 때 getValidAccessToken에 대한 여러 동시 호출이 이루어지면 갱신 API가 한 번만 호출되는지 확인합니다.
    // 주어진 상황: 만료된 접근 토큰과 유효한 갱신 토큰을 가진 TokenManager. API 클라이언트는 약간의 지연과 함께 성공적인 갱신을 위해 모의 설정됩니다.
    // 실행 시점: getValidAccessToken에 대한 두 번의 호출이 동시에 이루어질 때.
    // 예상 결과: 두 호출 모두 동일한 새 접근 토큰을 받아야 하며, 갱신 API는 한 번만 호출되어야 합니다. 새 토큰은 스토리지에 저장되고 tokenStream을 통해 방출됩니다.
    func testGetValidAccessToken_ConcurrentRefresh() async throws {
        let now = Date()
        let initialToken = createTestTokenInfo(
            accessTokenExpiresIn: -100, // 만료됨
            refreshTokenExpiresIn: 3600,
            receivedAt: now
        )
        await setupTokenManager(initialToken: initialToken)
        
        let newAccessToken = "concurrent-refresh-token"
        let refreshResponse = MockTokenRefreshResponse.validResponse(newAccessToken: newAccessToken)
        let apiCallCount = ActorIsolated(0)
        
        mockApiClient.sendHandler = { [apiCallCount] _ in
            try await Task.sleep(nanoseconds: 200_000_000) // API 호출 지연 시뮬레이션
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
    
    // 의도: updateTokens가 현재 토큰을 올바르게 업데이트하고, 스토리지에 저장하며, tokenStream에 새 토큰을 방출하는지 확인합니다.
    // 주어진 상황: TokenManager (초기 토큰 유무와 관계없음). 새 접근 및 갱신 토큰 상세 정보.
    // 실행 시점: 새 토큰 상세 정보로 updateTokens가 호출될 때.
    // 예상 결과: TokenManager의 현재 토큰은 새 토큰이어야 하며, 스토리지에 저장되고, tokenStream은 새 TokenInfo를 방출해야 합니다.
    func testUpdateTokens() async throws {
        await setupTokenManager(initialToken: nil) // 초기 토큰 없음
        
        let newAccessToken = "updated-access"
        let newRefreshToken = "updated-refresh"
        let accessExpiresIn: TimeInterval = 1800
        let refreshExpiresIn: TimeInterval = 7200
        
        let streamExpectation = expectation(description: "Token stream emits updated token")
        var finalStreamValueAfterUpdate: TokenInfo?
        
        let streamTask = Task {
            for await tokenInfo in await tokenManager.tokenStream {
                if tokenInfo?.accessToken == newAccessToken && tokenInfo?.refreshToken == newRefreshToken {
                    finalStreamValueAfterUpdate = tokenInfo
                    streamExpectation.fulfill()
                    break
                }
            }
        }
        
        try await tokenManager.updateTokens(
            accessToken: newAccessToken,
            accessTokenExpiresIn: accessExpiresIn,
            refreshToken: newRefreshToken,
            refreshTokenExpiresIn: refreshExpiresIn
        )
        
        await fulfillment(of: [streamExpectation], timeout: 1.0)
        streamTask.cancel()
        
        let currentRefreshToken = await tokenManager.getRefreshToken()
        XCTAssertEqual(currentRefreshToken, newRefreshToken)
        
        let storedToken = try await mockTokenStorage.load(forKey: storageKey)
        XCTAssertEqual(storedToken.accessToken, newAccessToken)
        XCTAssertEqual(storedToken.refreshToken, newRefreshToken)
        XCTAssertNotNil(storedToken.accessTokenExpiresAt)
        XCTAssertNotNil(storedToken.refreshTokenExpiresAt)
        
        XCTAssertEqual(finalStreamValueAfterUpdate?.accessToken, newAccessToken)
        XCTAssertEqual(finalStreamValueAfterUpdate?.refreshToken, newRefreshToken)
    }
    
    // 의도: 새 접근 토큰만 제공될 때 (갱신 토큰은 nil이 됨) updateTokens가 토큰을 올바르게 업데이트하는지 확인합니다.
    // 주어진 상황: TokenManager (갱신 토큰을 포함한 기존 토큰이 있을 수 있음). 새 접근 토큰 상세 정보, 그러나 갱신 토큰은 없음.
    // 실행 시점: 새 접근 토큰 상세 정보만으로 updateTokens가 호출될 때.
    // 예상 결과: TokenManager의 현재 토큰은 새 접근 토큰을 반영해야 하며, 갱신 토큰 부분은 nil이어야 하고, 이것이 스토리지에 저장되며, tokenStream은 새 (접근 전용) TokenInfo를 방출해야 합니다.
    func testUpdateTokens_AccessTokenOnly() async throws {
        let initialToken = createTestTokenInfo(refreshToken: "initial-refresh") // 초기 갱신 토큰 있음
        await setupTokenManager(initialToken: initialToken)
        
        let newAccessToken = "updated-access-only"
        let accessExpiresIn: TimeInterval = 1800
        
        let streamExpectation = expectation(description: "Token stream emits updated token (access only)")
        var finalStreamValueAfterUpdate: TokenInfo?
        
        let streamTask = Task {
            for await tokenInfo in await tokenManager.tokenStream {
                if tokenInfo?.accessToken == newAccessToken && tokenInfo?.refreshToken == nil {
                    finalStreamValueAfterUpdate = tokenInfo
                    streamExpectation.fulfill()
                    break
                }
            }
        }
        
        try await tokenManager.updateTokens(
            accessToken: newAccessToken,
            accessTokenExpiresIn: accessExpiresIn,
            refreshToken: nil,
            refreshTokenExpiresIn: nil
        )
        
        await fulfillment(of: [streamExpectation], timeout: 1.0)
        streamTask.cancel()
        
        let currentRefreshToken = await tokenManager.getRefreshToken()
        XCTAssertNil(currentRefreshToken, "Refresh token should be nil after access-only update")
        
        let storedToken = try await mockTokenStorage.load(forKey: storageKey)
        XCTAssertEqual(storedToken.accessToken, newAccessToken)
        XCTAssertNil(storedToken.refreshToken, "Stored refresh token should be nil")
        XCTAssertNil(storedToken.refreshTokenExpiresAt, "Stored refresh token expiry should be nil")
        
        XCTAssertEqual(finalStreamValueAfterUpdate?.accessToken, newAccessToken)
        XCTAssertNil(finalStreamValueAfterUpdate?.refreshToken, "Streamed refresh token should be nil")
    }
    
    // 의도: TokenStorage에 저장하는 데 실패하면 updateTokens가 오류를 올바르게 처리하고 발생시키는지 확인합니다.
    // 주어진 상황: 저장 시 실패할 TokenStorage로 구성된 TokenManager. 새 토큰 상세 정보.
    // 실행 시점: updateTokens가 호출될 때.
    // 예상 결과: 메서드는 TokenStorage에서 발생한 오류를 발생시켜야 합니다. 그러나 이 오류가 발생하기 전에 `TokenManager`의 내부 `currentToken`은 새 토큰으로 업데이트되고, `tokenStream`은 이 새 토큰 정보를 방출합니다 (낙관적 업데이트).
    func testUpdateTokens_StorageFailure() async throws {
        // 이 테스트에는 MockFailableTokenStorage 사용
        let failableStorage = MockFailableTokenStorage()
        mockApiClient = MockNetifyClient()
        refreshRequestProvider = { MockRefreshRequest(refreshToken: $0) }
        revokeRequestProvider = { MockRevokeRequest(refreshToken: $0) }
        
        // 실패 가능한 스토리지로 직접 매니저 생성
        tokenManager = TokenManager(
            tokenStorage: failableStorage,
            storageKey: storageKey,
            apiClient: mockApiClient,
            refreshRequestProvider: refreshRequestProvider,
            revokeRequestProvider: revokeRequestProvider
        )
        // 초기 로드 대기
        let initialLoadExpectation = expectation(description: "TokenManager initial load for update storage failure test")
        let streamTask = Task {
            for await _ in await tokenManager.tokenStream { initialLoadExpectation.fulfill(); break }
        }
        await fulfillment(of: [initialLoadExpectation], timeout: 1.0)
        streamTask.cancel()
        
        let expectedError = TokenError.storageError(description: "Save failed!")
        await failableStorage.failNextSave(error: expectedError)
        
        do {
            try await tokenManager.updateTokens(
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
    
    // 의도: clearTokens가 현재 토큰을 제거하고, 스토리지에서 삭제하며, 진행 중인 갱신 작업을 취소하고, tokenStream에 nil을 방출하는지 확인합니다.
    // 주어진 상황: 기존 토큰을 가진 TokenManager.
    // 실행 시점: clearTokens가 호출될 때.
    // 예상 결과: 현재 토큰은 nil이어야 하며, 토큰은 스토리지에서 삭제되고, tokenStream은 (초기 방출 후) nil을 방출해야 합니다.
    func testClearTokens() async throws {
        let initialToken = createTestTokenInfo() // 테스트용 토큰 생성
        await setupTokenManager(initialToken: initialToken)
        
        let streamExpectation = expectation(description: "Token stream emits nil after clear")
        var finalStreamValueAfterClear: TokenInfo? = initialToken // 초기값을 예상과 다르게 설정하여 변경 확인
        
        let streamTask = Task {
            // 스트림은 초기값(initialToken)을 가지고 있다가 clearTokens 후 nil로 변경됩니다.
            // 우리는 nil 상태를 기다립니다.
            var lastSeenToken: TokenInfo? = initialToken
            for await tokenInfo in await tokenManager.tokenStream {
                lastSeenToken = tokenInfo
                if lastSeenToken == nil {
                    finalStreamValueAfterClear = nil
                    streamExpectation.fulfill()
                    break
                }
            }
        }
        
        try await tokenManager.clearTokens()
        
        await fulfillment(of: [streamExpectation], timeout: 2.0) // 약간의 여유 시간
        streamTask.cancel()
        
        let currentRefreshToken = await tokenManager.getRefreshToken()
        XCTAssertNil(currentRefreshToken)
        
        XCTAssertNil(finalStreamValueAfterClear, "Stream should be nil after clearTokens")
        
        do {
            _ = try await mockTokenStorage.load(forKey: storageKey)
            XCTFail("Expected TokenError.tokenNotFound but load succeeded.")
        } catch let error as TokenError {
            XCTAssertEqual(error, .tokenNotFound)
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
    }
    
    // 의도: 현재 토큰이 없을 때 clearTokens가 올바르게 (오류 없이) 동작하는지 확인합니다.
    // 주어진 상황: 현재 토큰이 없는 TokenManager.
    // 실행 시점: clearTokens가 호출될 때.
    // 예상 결과: 메서드는 오류 없이 완료되어야 하며, 스토리지는 비어 있어야 합니다.
    func testClearTokens_WhenNoTokenExists() async throws {
        await setupTokenManager(initialToken: nil) // 초기 토큰 없음
        
        // 1. setupTokenManager 후 TokenManager의 내부 상태 확인
        // getRefreshToken()은 currentToken이 nil이면 nil을 반환해야 합니다.
        var currentRefreshTokenBeforeClear = await tokenManager.getRefreshToken()
        XCTAssertNil(currentRefreshTokenBeforeClear, "Refresh token should be nil after setup with no initial token.")
        
        // getValidAccessToken()은 TokenError.tokenNotFound를 발생시켜야 합니다.
        await XCTAssertThrowsErrorAsync(try await tokenManager.getValidAccessToken(), "getValidAccessToken should throw when no token exists.") { error in
            XCTAssertEqual(error as? TokenError, .tokenNotFound, "Error should be tokenNotFound.")
        }
        
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
        
        // clearTokens 호출 후에도 TokenManager의 내부 상태는 여전히 nil이어야 합니다.
        currentRefreshTokenBeforeClear = await tokenManager.getRefreshToken() // 변수 재사용
        XCTAssertNil(currentRefreshTokenBeforeClear, "Refresh token should still be nil after clearing an already empty manager.")
        
        await XCTAssertThrowsErrorAsync(try await tokenManager.getValidAccessToken(), "getValidAccessToken should still throw after clearing an empty manager.") { error in
            XCTAssertEqual(error as? TokenError, .tokenNotFound, "Error should still be tokenNotFound.")
        }
    }
    
    
    // MARK: - Revoke Tokens Tests
    
    // 의도: revokeTokens가 성공적으로 폐기 API를 호출하고, 로컬 토큰을 지우며, tokenStream에 nil을 방출하는지 확인합니다.
    // 주어진 상황: 유효한 갱신 토큰을 가진 TokenManager. API 클라이언트는 성공적인 폐기를 위해 모의 설정됩니다.
    // 실행 시점: revokeTokens가 호출될 때.
    // 예상 결과: 폐기 API가 호출되고, 로컬 토큰이 지워지며, tokenStream이 nil을 방출해야 합니다.
    func testRevokeTokens_Success() async throws {
        let initialToken = createTestTokenInfo() // 테스트용 토큰 생성
        await setupTokenManager(initialToken: initialToken)
        
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
        var finalStreamValueAfterRevoke: TokenInfo? = initialToken
        
        let streamTask = Task {
            // 초기값 -> revoke 후 nil
            var lastSeenToken: TokenInfo? = initialToken
            for await tokenInfo in await tokenManager.tokenStream {
                lastSeenToken = tokenInfo
                if lastSeenToken == nil {
                    finalStreamValueAfterRevoke = nil
                    streamExpectation.fulfill()
                    break
                }
            }
        }
        
        try await tokenManager.revokeTokens()
        
        await fulfillment(of: [streamExpectation], timeout: 1.0)
        streamTask.cancel()
        
        XCTAssertTrue(revokeApiCalled, "Revoke API should have been called")
        XCTAssertNil(finalStreamValueAfterRevoke, "Stream should have emitted nil")
        
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
    
    // 의도: 폐기 API 호출이 실패하면 revokeTokens가 TokenError.revocationFailed를 발생시키지만, 여전히 로컬 토큰을 지우고 tokenStream에 nil을 방출하는지 확인합니다.
    // 주어진 상황: 유효한 갱신 토큰을 가진 TokenManager. API 클라이언트는 폐기 중 오류를 반환하도록 모의 설정됩니다.
    // 실행 시점: revokeTokens가 호출될 때.
    // 예상 결과: TokenError.revocationFailed 오류 (원래 API 오류 정보 포함)가 발생하고, 로컬 토큰이 지워지며, tokenStream이 nil을 방출해야 합니다.
    func testRevokeTokens_ApiFailure() async throws {
        let initialToken = createTestTokenInfo() // 테스트용 토큰 생성
        await setupTokenManager(initialToken: initialToken)
        
        let apiError = NetworkRequestError.serverError(statusCode: 500, data: nil)
        var revokeApiCalled = false
        mockApiClient.sendHandler = { request in
            revokeApiCalled = true
            throw apiError
        }
        
        let streamExpectation = expectation(description: "Token stream emits nil even after failed revoke")
        var finalStreamValueAfterFailure: TokenInfo? = initialToken
        
        let streamTask = Task {
            // 초기값 -> revoke 시도 -> clearTokens로 인해 nil
            var lastSeenToken: TokenInfo? = initialToken
            for await tokenInfo in await tokenManager.tokenStream {
                lastSeenToken = tokenInfo
                if lastSeenToken == nil {
                    finalStreamValueAfterFailure = nil
                    streamExpectation.fulfill()
                    break
                }
            }
        }
        
        do {
            try await tokenManager.revokeTokens()
            XCTFail("Expected TokenError.revocationFailed but revokeTokens succeeded.")
        } catch let error as TokenError {
            guard case .revocationFailed(let description) = error else {
                XCTFail("Expected TokenError.revocationFailed but got \(error)")
                return
            }
            XCTAssertTrue(description.contains(apiError.localizedDescription), "Error description should contain API error info")
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
        
        await fulfillment(of: [streamExpectation], timeout: 1.0)
        streamTask.cancel()
        
        XCTAssertTrue(revokeApiCalled, "Revoke API should have been called")
        XCTAssertNil(finalStreamValueAfterFailure, "Stream should have emitted nil")
        
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
    
    // 의도: 성공적인 API 호출 후 TokenStorage에서 삭제하는 데 실패하면 revokeTokens가 오류를 올바르게 처리하고 발생시키는지 확인합니다.
    // 주어진 상황: 유효한 갱신 토큰을 가진 TokenManager. API 클라이언트는 성공을 위해 모의 설정됩니다. TokenStorage는 삭제 시 실패하도록 모의 설정됩니다.
    // 실행 시점: revokeTokens가 호출될 때.
    // 예상 결과: 폐기 API가 호출된 다음 메서드는 스토리지 오류를 발생시켜야 합니다. 그러나 이 스토리지 오류가 발생하기 전에 `TokenManager`의 내부 `currentToken`은 `nil`로 설정되고 `tokenStream`은 `nil`을 방출합니다 (낙관적 업데이트). 최종적으로 토큰은 (삭제 실패로 인해) 스토리지에 여전히 존재할 수 있습니다.
    func testRevokeTokens_StorageFailure() async throws {
        // 이 테스트에는 MockFailableTokenStorage 사용
        let failableStorage = MockFailableTokenStorage()
        mockApiClient = MockNetifyClient()
        refreshRequestProvider = { MockRefreshRequest(refreshToken: $0) }
        revokeRequestProvider = { MockRevokeRequest(refreshToken: $0) }
        
        let initialToken = createTestTokenInfo()
        try await failableStorage.save(tokenInfo: initialToken, forKey: storageKey) // 사전 채우기
        
        // 실패 가능한 스토리지로 직접 매니저 생성
        tokenManager = TokenManager(
            tokenStorage: failableStorage,
            storageKey: storageKey,
            apiClient: mockApiClient,
            refreshRequestProvider: refreshRequestProvider,
            revokeRequestProvider: revokeRequestProvider
        )
        // 초기 로드 대기
        let initialLoadExpectation = expectation(description: "TokenManager initial load for revoke storage failure test")
        let streamTask = Task {
            for await _ in await tokenManager.tokenStream { initialLoadExpectation.fulfill(); break }
        }
        await fulfillment(of: [initialLoadExpectation], timeout: 1.0)
        streamTask.cancel()
        
        var revokeApiCalled = false
        mockApiClient.sendHandler = { _ in
            revokeApiCalled = true
            return EmptyResponse() // API 성공
        }
        
        let expectedError = TokenError.storageError(description: "Delete failed!")
        await failableStorage.failNextDelete(error: expectedError)
        
        // 스트림은 clearTokens의 낙관적 업데이트로 인해 nil을 방출할 것으로 예상합니다.
        let streamExpectation = expectation(description: "Token stream emits nil even on revoke storage failure")
        var finalStreamValueAfterFailure: TokenInfo? = initialToken // nil이 아닌 값으로 초기화
        
        let streamObservationTask = Task {
            for await tokenInfo in await tokenManager.tokenStream {
                if tokenInfo == nil {
                    finalStreamValueAfterFailure = nil
                    streamExpectation.fulfill()
                    break
                }
            }
        }
        
        do {
            try await tokenManager.revokeTokens()
            XCTFail("Expected revokeTokens to throw a storage error, but it succeeded.")
        } catch let error as TokenError {
            XCTAssertEqual(error, expectedError, "Expected storage error was not thrown")
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
        
        XCTAssertTrue(revokeApiCalled, "Revoke API should have been called before storage failure")
        
        // 스트림 업데이트 대기
        await fulfillment(of: [streamExpectation], timeout: 1.0)
        streamObservationTask.cancel()
        
        XCTAssertNil(finalStreamValueAfterFailure, "Stream should have emitted nil due to optimistic clearTokens")
        
        // TokenManager의 내부 상태 확인 (clearTokens 시도로 인해 nil이어야 함)
        let currentRefreshToken = await tokenManager.getRefreshToken()
        XCTAssertNil(currentRefreshToken, "TokenManager's currentToken should be nil even if storage delete failed.")
        
        // 스토리지 직접 확인
        let storedToken = try? await failableStorage.load(forKey: storageKey)
        XCTAssertNotNil(storedToken, "Token should still exist in storage after delete failure")
        XCTAssertEqual(storedToken, initialToken)
    }
    
    // 의도: 사용 가능한 갱신 토큰이 없는 경우 revokeTokens가 API를 호출하지 않고 로컬 토큰을 지우는지 확인합니다.
    // 주어진 상황: 갱신 토큰 부분이 없는 토큰을 가진 TokenManager.
    // 실행 시점: revokeTokens가 호출될 때.
    // 예상 결과: 폐기 API가 호출되지 않고, 로컬 토큰이 지워지며, tokenStream이 nil을 방출해야 합니다.
    func testRevokeTokens_NoRefreshToken() async throws {
        let initialToken = createTestTokenInfo(refreshToken: nil, refreshTokenExpiresIn: nil) // 갱신 토큰 없음
        await setupTokenManager(initialToken: initialToken)
        
        var revokeApiCalled = false
        mockApiClient.sendHandler = { _ in
            revokeApiCalled = true
            return EmptyResponse()
        }
        
        let streamExpectation = expectation(description: "Token stream emits nil after revoke without refresh token")
        var finalStreamValueAfterRevoke: TokenInfo? = initialToken
        
        let streamTask = Task {
            // 초기값 (refreshToken: nil) -> revoke 시도 (API 호출 안 함) -> clearTokens로 인해 nil
            var lastSeenToken: TokenInfo? = initialToken
            for await tokenInfo in await tokenManager.tokenStream {
                lastSeenToken = tokenInfo
                if lastSeenToken == nil {
                    finalStreamValueAfterRevoke = nil
                    streamExpectation.fulfill()
                    break
                }
            }
        }
        
        try await tokenManager.revokeTokens()
        
        await fulfillment(of: [streamExpectation], timeout: 1.0)
        streamTask.cancel()
        
        XCTAssertFalse(revokeApiCalled, "Revoke API should not be called when no refresh token exists")
        XCTAssertNil(finalStreamValueAfterRevoke, "Stream should have emitted nil")
        
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
// 스레드 안전 카운터를 위한 헬퍼 액터
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
// 실패를 시뮬레이션할 수 있는 모의 스토리지
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
            shouldFailOnSave = false // 다음 호출을 위해 재설정
            throw saveError
        }
        storage[key] = tokenInfo
    }
    
    func load(forKey key: String) async throws -> TokenInfo {
        if shouldFailOnLoad {
            shouldFailOnLoad = false // 다음 호출을 위해 재설정
            throw loadError
        }
        guard let token = storage[key] else {
            throw TokenError.tokenNotFound
        }
        return token
    }
    
    func delete(forKey key: String) async throws {
        if shouldFailOnDelete {
            shouldFailOnDelete = false // 다음 호출을 위해 재설정
            throw deleteError
        }
        // 키가 존재하지 않아도 오류를 발생시키지 않는 표준 delete 동작 모방
        storage.removeValue(forKey: key)
    }
    
    // Helper to clear storage for tests
    // 테스트용 스토리지 비우기 헬퍼
    func clearAll() {
        storage.removeAll()
    }
    
    // Helper to configure failure
    // 실패 설정 헬퍼
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

// Helper to assert throwing async functions
func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: @autoclosure () -> String = "",
    file: StaticString = #filePath,
    line: UInt = #line,
    _ errorHandler: (_ error: Error) -> Void = { _ in }
) async {
    do {
        _ = try await expression()
        XCTFail(message(), file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
