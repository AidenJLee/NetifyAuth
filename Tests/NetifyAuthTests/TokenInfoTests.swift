// Tests/NetifyAuthTests/TokenInfoTests.swift
import XCTest
@testable import NetifyAuth // internal 요소 접근 위해 @testable 사용

final class TokenInfoTests: XCTestCase {
    
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
    
    func testTokenValidity_Valid() {
        let tokenInfo = createTestTokenInfo(accessTokenExpiresIn: 3600) // 1 hour expiry
        let state = tokenInfo.checkValidity(accessTokenBuffer: 60)
        XCTAssertEqual(state, .valid)
    }
    
    func testTokenValidity_NeedsRefresh_AccessTokenExpired() {
        let pastDate = Date().addingTimeInterval(-3700) // Expired 100 seconds ago
        let tokenInfo = createTestTokenInfo(accessTokenExpiresIn: 3600, receivedAt: pastDate)
        let state = tokenInfo.checkValidity(accessTokenBuffer: 60)
        XCTAssertEqual(state, .needsRefresh)
    }
    
    func testTokenValidity_NeedsRefresh_AccessTokenWithinBuffer() {
        let tokenInfo = createTestTokenInfo(accessTokenExpiresIn: 30) // Expires in 30 seconds
        let state = tokenInfo.checkValidity(accessTokenBuffer: 60) // Buffer is 60 seconds
        XCTAssertEqual(state, .needsRefresh)
    }
    
    func testTokenValidity_Invalid_NoRefreshToken() {
        let pastDate = Date().addingTimeInterval(-3700)
        let tokenInfo = createTestTokenInfo(accessTokenExpiresIn: 3600, refreshToken: nil, refreshTokenExpiresIn: nil, receivedAt: pastDate)
        let state = tokenInfo.checkValidity(accessTokenBuffer: 60)
        XCTAssertEqual(state, .invalid)
    }
    
    func testTokenValidity_Invalid_RefreshTokenExpired() {
        let refreshExpiredDate = Date().addingTimeInterval(-86500) // Refresh token expired (1 day + 100 sec ago)
        let tokenInfo = createTestTokenInfo(
            accessTokenExpiresIn: 3600,
            refreshTokenExpiresIn: 86400,
            receivedAt: refreshExpiredDate // Use the earlier date for creation
        )
        
        // Manually adjust access token expiry based on its own lifetime relative to creation
        let adjustedTokenInfo = TokenInfo(
            accessToken: tokenInfo.accessToken,
            accessTokenExpiresAt: refreshExpiredDate.addingTimeInterval(3600), // Access token expired relative to creation
            refreshToken: tokenInfo.refreshToken,
            refreshTokenExpiresAt: tokenInfo.refreshTokenExpiresAt // Refresh token expired
        )
        
        
        let state = adjustedTokenInfo.checkValidity(accessTokenBuffer: 60, refreshTokenBuffer: 0)
        XCTAssertEqual(state, .invalid)
    }
    
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
