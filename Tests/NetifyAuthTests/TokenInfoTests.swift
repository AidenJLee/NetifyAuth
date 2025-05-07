// Tests/NetifyAuthTests/TokenInfoTests.swift
import XCTest
@testable import NetifyAuth // internal 요소 접근 위해 @testable 사용

final class TokenInfoTests: XCTestCase {
    
    // 의도: TokenInfo.create가 모든 속성을 사용하여 TokenInfo 객체를 올바르게 초기화하는지 확인합니다.
    // 주어진 상황: 접근 토큰, 갱신 토큰, 해당 토큰들의 만료 시간 및 생성 날짜.
    // 실행 시점: TokenInfo.create가 호출될 때.
    // 예상 결과: 생성된 TokenInfo 객체의 속성들이 입력 값에 따라 설정되어야 합니다.
    func testTokenCreation() {
        let now = Date()
        let accessToken = "test-access"
        let accessExpiresIn: TimeInterval = 3600 // 1 hour
        let refreshToken = "test-refresh"
        let refreshExpiresIn: TimeInterval = 86400 // 1 day
        
        let tokenInfo = TokenInfo.create(
            accessToken: accessToken,
            accessTokenExpiresIn: accessExpiresIn,
            refreshToken: refreshToken,
            refreshTokenExpiresIn: refreshExpiresIn,
            receivedAt: now
        )
        
        XCTAssertEqual(tokenInfo.accessToken, accessToken)
        XCTAssertEqual(tokenInfo.refreshToken, refreshToken)
        XCTAssertEqual(tokenInfo.accessTokenExpiresAt, now.addingTimeInterval(accessExpiresIn))
        XCTAssertEqual(tokenInfo.refreshTokenExpiresAt, now.addingTimeInterval(refreshExpiresIn))
    }
    
    // 의도: 갱신 토큰이 제공되지 않았을 때 TokenInfo.create가 TokenInfo 객체를 올바르게 초기화하는지 확인합니다.
    // 주어진 상황: 접근 토큰, 해당 토큰의 만료 시간, 갱신 토큰 없음 및 생성 날짜.
    // 실행 시점: TokenInfo.create가 호출될 때.
    // 예상 결과: 생성된 TokenInfo 객체의 접근 토큰 속성들은 설정되고, 갱신 토큰 속성들은 nil이어야 합니다.
    func testTokenCreationWithoutRefreshToken() {
        let now = Date()
        let accessToken = "test-access"
        let accessExpiresIn: TimeInterval = 3600
        
        let tokenInfo = TokenInfo.create(
            accessToken: accessToken,
            accessTokenExpiresIn: accessExpiresIn,
            refreshToken: nil,
            refreshTokenExpiresIn: nil,
            receivedAt: now
        )
        
        XCTAssertEqual(tokenInfo.accessToken, accessToken)
        XCTAssertNil(tokenInfo.refreshToken)
        XCTAssertEqual(tokenInfo.accessTokenExpiresAt, now.addingTimeInterval(accessExpiresIn))
        XCTAssertNil(tokenInfo.refreshTokenExpiresAt)
    }
    
    // 의도: 접근 토큰이 만료되지 않았고 버퍼 내에 있지 않을 때 checkValidity가 .valid를 반환하는지 확인합니다.
    // 주어진 상황: 1시간 후에 만료되는 접근 토큰을 가진 TokenInfo 객체.
    // 실행 시점: 60초 버퍼로 checkValidity가 호출될 때.
    // 예상 결과: 유효성 상태는 .valid여야 합니다.
    func testTokenValidity_Valid() {
        let now = Date()
        let tokenInfo = createTestTokenInfo(accessTokenExpiresIn: 3600, receivedAt: now) // 1 hour expiry
        let state = tokenInfo.checkValidity(accessTokenBuffer: 60, now: now)
        XCTAssertEqual(state, .valid)
    }
    
    // 의도: 접근 토큰이 만료되었지만 갱신 토큰이 여전히 유효할 때 checkValidity가 .needsRefresh를 반환하는지 확인합니다.
    // 주어진 상황: 접근 토큰이 100초 전에 만료되었지만 갱신 토큰은 여전히 유효하도록 생성된 TokenInfo 객체.
    // 실행 시점: 60초 접근 토큰 버퍼와 원래 생성 시간을 'now'로 사용하여 checkValidity가 호출될 때.
    // 예상 결과: 유효성 상태는 .needsRefresh여야 합니다.
    func testTokenValidity_NeedsRefresh_AccessTokenExpired() {
        let creationTime = Date().addingTimeInterval(-3700) // Token was "created" 3700s ago (1h + 100s)
        // Access token was set to expire 3600s (1h) after creationTime.
        // So, at 'creationTime + 3700s' (i.e., 'now'), the access token is 100s past its expiry.
        // Refresh token is still valid.
        let tokenInfo = createTestTokenInfo(accessTokenExpiresIn: 3600, refreshTokenExpiresIn: 86400, receivedAt: creationTime)
        let currentTime = creationTime.addingTimeInterval(3700) // This is effectively creationTime + 3700s
        let state = tokenInfo.checkValidity(accessTokenBuffer: 60, now: currentTime)
        XCTAssertEqual(state, .needsRefresh)
    }
    
    // 의도: 접근 토큰이 만료 버퍼 내에 있을 때 checkValidity가 .needsRefresh를 반환하는지 확인합니다.
    // 주어진 상황: 30초 후에 만료되는 접근 토큰을 가진 TokenInfo 객체.
    // 실행 시점: 60초 접근 토큰 버퍼로 checkValidity가 호출될 때 (즉, 60초 이내에 만료되면 "갱신 필요"로 간주됨).
    // 예상 결과: 유효성 상태는 .needsRefresh여야 합니다.
    func testTokenValidity_NeedsRefresh_AccessTokenWithinBuffer() {
        let now = Date()
        let tokenInfo = createTestTokenInfo(accessTokenExpiresIn: 30, receivedAt: now) // Expires in 30 seconds from now
        let state = tokenInfo.checkValidity(accessTokenBuffer: 60, now: now) // Buffer is 60 seconds
        XCTAssertEqual(state, .needsRefresh)
    }
    
    // 의도: 접근 토큰이 만료되었고 갱신 토큰이 없을 때 checkValidity가 .invalid를 반환하는지 확인합니다.
    // 주어진 상황: 만료된 접근 토큰과 갱신 토큰 없이 생성된 TokenInfo 객체.
    // 실행 시점: checkValidity가 호출될 때.
    // 예상 결과: 유효성 상태는 .invalid여야 합니다.
    func testTokenValidity_Invalid_NoRefreshToken() {
        let creationTime = Date().addingTimeInterval(-3700) // Token "created" 1h + 100s ago
        // Access token expired 100s ago relative to 'now'. No refresh token.
        let tokenInfo = createTestTokenInfo(accessTokenExpiresIn: 3600, refreshToken: nil, refreshTokenExpiresIn: nil, receivedAt: creationTime)
        let currentTime = creationTime.addingTimeInterval(3700)
        let state = tokenInfo.checkValidity(accessTokenBuffer: 60, now: currentTime)
        XCTAssertEqual(state, .invalid)
    }
    
    // 의도: 접근 토큰과 갱신 토큰 모두 만료되었을 때 checkValidity가 .invalid를 반환하는지 확인합니다.
    // 주어진 상황: 현재 시간 기준으로 접근 토큰과 갱신 토큰 모두 만료되도록 생성된 TokenInfo 객체.
    // 실행 시점: checkValidity가 호출될 때.
    // 예상 결과: 유효성 상태는 .invalid여야 합니다.
    func testTokenValidity_Invalid_RefreshTokenExpired() {
        // Creation time was 1 day + 100 seconds ago.
        // Access token was set to expire 1 hour after creation.
        // Refresh token was set to expire 1 day after creation.
        // So, at 'now', both are expired.
        let creationTime = Date().addingTimeInterval(-(86400 + 100)) // 1 day + 100 sec ago
        
        let tokenInfo = createTestTokenInfo(
            accessTokenExpiresIn: 3600,
            refreshTokenExpiresIn: 86400,
            receivedAt: creationTime
        )
        
        let currentTime = creationTime.addingTimeInterval(86400 + 100)
        let state = tokenInfo.checkValidity(accessTokenBuffer: 60, refreshTokenBuffer: 0, now: currentTime)
        XCTAssertEqual(state, .invalid)
    }
    
    // 의도: checkValidity가 refreshTokenBuffer를 올바르게 고려하는지 확인합니다.
    // 주어진 상황: 만료된 접근 토큰을 가진 TokenInfo. 갱신 토큰은 현재 유효하지만 45초 후에 만료됩니다.
    // 실행 시점: refreshTokenBuffer가 60초로 설정되어 checkValidity가 호출될 때 (즉, 갱신 토큰이 60초 이내에 만료되면 만료된 것으로 간주됨).
    // 예상 결과: 갱신 토큰이 버퍼 내에 있으므로 상태는 .invalid여야 합니다.
    // 실행 시점: refreshTokenBuffer가 0초로 설정되어 checkValidity가 호출될 때.
    // 예상 결과: 갱신 토큰이 여전히 유효하므로 (버퍼 내에 있지 않음) 상태는 .needsRefresh여야 합니다.
    func testTokenValidity_NeedsRefresh_RefreshTokenValid_RefreshTokenBuffer() {
        // Define a fixed time for consistent testing
        let testTime = Date()
        let accessTokenExpiresIn: TimeInterval = -100 // Access token expired 100s ago relative to testTime
        let refreshTokenExpiresIn: TimeInterval = 45   // Refresh token expires 45s after testTime
        
        // Create token relative to testTime
        let tokenInfo = createTestTokenInfo(
            accessTokenExpiresIn: accessTokenExpiresIn,
            refreshTokenExpiresIn: refreshTokenExpiresIn,
            receivedAt: testTime // Use fixed time for creation
        )
        
        // With buffer (60s), refresh token (valid for 45s) should be considered expired -> invalid
        let stateWithBuffer = tokenInfo.checkValidity(accessTokenBuffer: 60, refreshTokenBuffer: 60, now: testTime) // Pass fixed time
        XCTAssertEqual(stateWithBuffer, .invalid, "Should be invalid due to refresh token buffer")
        // Refresh token is valid without buffer
        let stateWithoutBuffer = tokenInfo.checkValidity(accessTokenBuffer: 60, refreshTokenBuffer: 0, now: testTime) // Pass fixed time
        XCTAssertEqual(stateWithoutBuffer, .needsRefresh, "Should need refresh without buffer")
    }
    
    // MARK: - Protocol Conformance Tests
    
    // 의도: TokenInfo가 Equatable 프로토콜을 올바르게 준수하는지 확인합니다.
    // 주어진 상황: 세 개의 TokenInfo 객체 (두 개는 동일하고 하나는 다름).
    // 실행 시점: 동등성 비교가 수행될 때.
    // 예상 결과: 동일한 토큰은 같아야 하고, 다른 토큰은 같지 않아야 합니다.
    func testEquatableConformance() {
        let date = Date()
        let token1 = TokenInfo.create(
            accessToken: "token", accessTokenExpiresIn: 3600,
            refreshToken: "refresh", refreshTokenExpiresIn: 86400,
            receivedAt: date
        )
        let token2 = TokenInfo.create(
            accessToken: "token", accessTokenExpiresIn: 3600,
            refreshToken: "refresh", refreshTokenExpiresIn: 86400,
            receivedAt: date
        )
        let token3 = TokenInfo.create(
            accessToken: "different-token", accessTokenExpiresIn: 3600,
            refreshToken: "refresh", refreshTokenExpiresIn: 86400,
            receivedAt: date
        )
        
        XCTAssertEqual(token1, token2, "Identical tokens should be equal")
        XCTAssertNotEqual(token1, token3, "Different tokens should not be equal")
    }
    
    // 의도: TokenInfo가 Codable 프로토콜을 올바르게 준수하는지 확인합니다.
    // 주어진 상황: 원본 TokenInfo 객체.
    // 실행 시점: 객체가 JSON으로 인코딩된 후 다시 디코딩될 때.
    // 예상 결과: 디코딩된 TokenInfo 객체는 원본과 같아야 합니다.
    func testCodableConformance() throws {
        let originalToken = createTestTokenInfo(
            accessToken: "codable-access",
            refreshToken: "codable-refresh"
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let encodedData = try encoder.encode(originalToken)
        let decodedToken = try decoder.decode(TokenInfo.self, from: encodedData)
        
        XCTAssertEqual(originalToken, decodedToken, "Decoded token should be equal to the original")
    }
}
