// Sources/NetifyAuth/TokenModel.swift
import Foundation

/// 토큰 정보 저장을 위한 프로토콜
public protocol TokenStorage {
    /// 토큰 정보를 저장합니다
    /// - Parameters:
    ///   - tokenInfo: 저장할 토큰 정보
    ///   - key: 식별 키
    func save(tokenInfo: TokenInfo, forKey key: String) async throws
    
    /// 저장된 토큰 정보를 로드합니다
    /// - Parameter key: 식별 키
    /// - Returns: 토큰 정보
    /// - Throws: 토큰이 없으면 `TokenError.tokenNotFound` 발생
    func load(forKey key: String) async throws -> TokenInfo
    
    /// 저장된 토큰 정보를 삭제합니다
    /// - Parameter key: 식별 키
    func delete(forKey key: String) async throws
}

/// 토큰 갱신 API 응답 프로토콜
public protocol TokenRefreshResponse {
    /// 새로 발급된 접근 토큰
    var accessToken: String { get }
    
    /// 새로 발급된 접근 토큰의 유효 기간(초)
    var accessTokenExpiresIn: TimeInterval { get }
    
    /// 새로 발급된 갱신 토큰 (선택 사항)
    var refreshToken: String? { get }
    
    /// 새로 발급된 갱신 토큰의 유효 기간(초) (선택 사항)
    var refreshTokenExpiresIn: TimeInterval? { get }
}

/// 토큰 정보 구조체
public struct TokenInfo: Codable, Equatable {
    /// 접근 토큰
    public let accessToken: String
    
    /// 접근 토큰 만료 시간
    public let accessTokenExpiresAt: Date
    
    /// 갱신 토큰 (선택적)
    public let refreshToken: String?
    
    /// 갱신 토큰 만료 시간 (선택적)
    public let refreshTokenExpiresAt: Date?
    
    /// 토큰 정보 생성
    /// - Parameters:
    ///   - accessToken: 접근 토큰
    ///   - accessTokenExpiresIn: 접근 토큰 유효 기간(초)
    ///   - refreshToken: 갱신 토큰
    ///   - refreshTokenExpiresIn: 갱신 토큰 유효 기간(초)
    ///   - receivedAt: 수신 시간 (기본값: 현재 시간)
    public static func create(
        accessToken: String,
        accessTokenExpiresIn: TimeInterval,
        refreshToken: String?,
        refreshTokenExpiresIn: TimeInterval?,
        receivedAt: Date = Date()
    ) -> TokenInfo {
        let accessExpiresAt = receivedAt.addingTimeInterval(accessTokenExpiresIn)
        
        let refreshExpiresAt = refreshTokenExpiresIn.map { 
            receivedAt.addingTimeInterval($0) 
        }
        
        return TokenInfo(
            accessToken: accessToken,
            accessTokenExpiresAt: accessExpiresAt,
            refreshToken: refreshToken,
            refreshTokenExpiresAt: refreshExpiresAt
        )
    }
    
    /// 토큰 유효성 상태
    public enum ValidityState {
        /// 접근 토큰 유효
        case valid
        /// 접근 토큰 만료, 갱신 토큰 유효
        case needsRefresh
        /// 갱신 토큰 만료 또는 없음
        case invalid
    }
    
    /// 토큰 유효성 검사
    /// - Parameters:
    ///   - accessTokenBuffer: 접근 토큰 만료 전 버퍼 시간(초)
    ///   - refreshTokenBuffer: 갱신 토큰 만료 전 버퍼 시간(초)
    ///   - now: 기준 시간 (테스트 목적으로 사용 가능)
    /// - Returns: 토큰 유효성 상태
    public func checkValidity(
        accessTokenBuffer: TimeInterval = 60.0,
        refreshTokenBuffer: TimeInterval = 0,
        now: Date = Date() // 기준 시간 주입 가능하도록 변경
    ) -> ValidityState {
        // let now = Date() // BUG: 외부에서 주입된 now 값을 덮어쓰므로 제거
        
        // 접근 토큰 유효성 검사
        if accessTokenExpiresAt.addingTimeInterval(-accessTokenBuffer) > now {
            return .valid
        }
        
        // 갱신 토큰 유효성 검사
        guard refreshToken != nil else {
            return .invalid // 갱신 토큰 없음
        }
        
        if let refreshExpiresAt = refreshTokenExpiresAt,
           refreshExpiresAt.addingTimeInterval(-refreshTokenBuffer) < now {
            return .invalid // 갱신 토큰 만료
        }
        
        return .needsRefresh // 접근 토큰 만료, 갱신 토큰 유효
    }
}

/// 토큰 관련 오류
public enum TokenError: LocalizedError, Equatable {
    /// 저장소 오류
    case storageError(description: String)
    /// 토큰 없음
    case tokenNotFound
    /// 인코딩 오류
    case encodingError
    /// 디코딩 오류
    case decodingError
    /// 갱신 토큰 없음
    case refreshTokenMissing
    /// 토큰 갱신 실패
    case refreshFailed(description: String)
    /// 토큰 폐기 실패 (서버 통신 오류)
    case revocationFailed(underlyingError: Error)
    /// 잘못된 응답
    case invalidResponse(reason: String)
    /// 기타 오류
    case unknown(message: String)
    
    public var errorDescription: String? {
        switch self {
        case .storageError(let description):
            return "Storage operation failed: \(description)"
        case .tokenNotFound:
            return "Token not found in storage"
        case .encodingError:
            return "Failed to encode token information"
        case .decodingError:
            return "Failed to decode token information"
        case .refreshTokenMissing:
            return "Cannot refresh: Refresh token is missing"
        case .refreshFailed(let description):
            return "Token refresh failed: \(description)"
        case .revocationFailed(let underlyingError):
            return "Token revocation failed: \(underlyingError.localizedDescription)"
        case .invalidResponse(let reason):
            return "Invalid response: \(reason)"
        case .unknown(let message):
            return "Unknown error: \(message)"
        }
    }
    
    public static func == (lhs: TokenError, rhs: TokenError) -> Bool {
        // 연관 값 비교 없이 케이스 자체만 비교하도록 단순화
        switch (lhs, rhs) {
        case (.storageError, .storageError): return true
        case (.tokenNotFound, .tokenNotFound):
            return true
        case (.encodingError, .encodingError):
            return true
        case (.decodingError, .decodingError):
            return true
        case (.refreshTokenMissing, .refreshTokenMissing):
            return true
        case (.refreshFailed, .refreshFailed): return true
        // revocationFailed는 underlyingError 비교가 복잡하므로 케이스만 비교
        case (.revocationFailed, .revocationFailed): return true
        case (.invalidResponse, .invalidResponse): return true
        case (.unknown, .unknown): return true
        default:
            return false
        }
    }
}
