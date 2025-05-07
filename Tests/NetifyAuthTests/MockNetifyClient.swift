// Tests/NetifyAuthTests/Mocks/MockNetifyClient.swift
import Foundation
import Netify
@testable import NetifyAuth // @testable을 사용하여 internal 요소 접근
import OSLog // Logger 사용을 위해 추가 (NetifyConfiguration 필요)

// NetifyClient Mock (상속 대신 자체 구현)
// 참고: NetifyClient가 final이므로 상속할 수 없습니다.
// TokenManager가 NetifyClient 구체 타입 대신 프로토콜에 의존하도록 리팩토링하는 것이 좋습니다.
// 여기서는 Mock 객체가 컴파일되도록 수정합니다.
@available(iOS 15, macOS 12, *) // NetifyClient 및 관련 타입의 가용성 레벨에 맞춤
class MockNetifyClient: NetifyClientProtocol { // 프로토콜 준수 추가
    var sendHandler: ((any NetifyRequest) async throws -> Any)?
    let configuration: NetifyConfiguration // NetifyClient와 유사한 구조를 갖도록 configuration 추가
    
    init() {
        // 테스트에 필요한 최소한의 NetifyConfiguration 생성
        self.configuration = NetifyConfiguration(
            baseURL: "https://mock.api.com",
            logLevel: .off // 테스트 중에는 로깅 최소화 또는 off
        )
        // 상속 제거로 super.init 호출 불필요
    }
    
    // override 제거
    func send<Request: NetifyRequest>(_ request: Request) async throws -> Request.ReturnType {
        guard let handler = sendHandler else {
            fatalError("MockNetifyClient.sendHandler is not set.")
        }
        // 핸들러가 Any를 반환하므로, 예상 타입으로 캐스팅 시도
        let result = try await handler(request)
        guard let typedResult = result as? Request.ReturnType else { // ResponseType -> ReturnType
            // 실제 테스트 시나리오에 따라 적절한 오류 처리 또는 기본값 반환
            fatalError("MockNetifyClient.sendHandler returned unexpected type. Expected \(Request.ReturnType.self), got \(type(of: result))") // ResponseType -> ReturnType
        }
        return typedResult
    }
}

// Mock Token Refresh Response
struct MockTokenRefreshResponse: TokenRefreshResponse, Decodable, Sendable {
    var accessToken: String
    var accessTokenExpiresIn: TimeInterval
    var refreshToken: String?
    var refreshTokenExpiresIn: TimeInterval?
    
    static func validResponse(
        newAccessToken: String = "new-access-token",
        newRefreshToken: String? = "new-refresh-token"
    ) -> MockTokenRefreshResponse {
        MockTokenRefreshResponse(
            accessToken: newAccessToken,
            accessTokenExpiresIn: 3600, // 1 hour
            refreshToken: newRefreshToken,
            refreshTokenExpiresIn: 86400 // 1 day
        )
    }
}

// Mock Refresh Request
struct MockRefreshRequest: NetifyRequest, Sendable {
    typealias ReturnType = MockTokenRefreshResponse // ResponseType -> ReturnType
    let refreshToken: String
    var path: String = "/mock/refresh"
    var method: HTTPMethod = .post
}

// Mock Revoke Request
struct MockRevokeRequest: NetifyRequest, Sendable {
    typealias ReturnType = EmptyResponse // ResponseType -> ReturnType
    let refreshToken: String
    var path: String = "/mock/revoke"
    var method: HTTPMethod = .post
}

// 빈 응답 타입 (예제 코드에 있는 것 활용)
struct EmptyResponse: Decodable, Sendable {}

// Helper for creating TokenInfo
func createTestTokenInfo(
    accessToken: String = "access-token",
    accessTokenExpiresIn: TimeInterval = 3600, // 1 hour
    refreshToken: String? = "refresh-token",
    refreshTokenExpiresIn: TimeInterval? = 86400, // 1 day
    receivedAt: Date = Date()
) -> TokenInfo {
    TokenInfo.create(
        accessToken: accessToken,
        accessTokenExpiresIn: accessTokenExpiresIn,
        refreshToken: refreshToken,
        refreshTokenExpiresIn: refreshTokenExpiresIn,
        receivedAt: receivedAt
    )
}
