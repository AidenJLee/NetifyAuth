// Sources/NetifyAuth/TokenAuthProvider.swift
import Foundation
import Netify
import OSLog

/// NetifyAuth의 토큰 관리 기능을 Netify의 AuthenticationProvider와 통합하는 클래스입니다.
/// 외부에서 주입된 `TokenManager`를 사용하여 인증 헤더 추가 및 자동 토큰 갱신을 처리합니다.
/// 이 Provider를 `NetifyClient` 설정 시 사용하면 인증 관련 로직을 간편하게 적용할 수 있습니다.
@available(iOS 15, macOS 12, *)
public final class TokenAuthProvider: AuthenticationProvider {

    // MARK: - 타입 정의
    
    /// 인증 실패 시 동작을 위한 클로저 타입
    public typealias AuthenticationFailedHandler = () -> Void
    
    // MARK: - 속성
    
    /// 토큰 관리자
    private let tokenManager: TokenManager
    
    /// 인증 헤더 이름 (기본값: "Authorization")
    private let headerName: String
    
    /// 토큰 접두사 (기본값: "Bearer ")
    private let tokenPrefix: String
    
    /// 인증 실패 시 호출되는 클로저
    private let onAuthenticationFailed: AuthenticationFailedHandler?
    
    /// 로거
    private let logger: Logger
    
    // MARK: - 초기화
    
    /// TokenAuthProvider 초기화
    /// - Parameters:
    ///   - tokenManager: 토큰 관리자
    ///   - headerName: 인증 헤더 이름 (기본값: "Authorization")
    ///   - tokenPrefix: 토큰 접두사 (기본값: "Bearer ")
    ///   - onAuthenticationFailed: 인증 실패(토큰 갱신 실패 등) 시 호출되는 클로저.
    ///                             **주의:** 이 클로저는 백그라운드 스레드에서 호출될 수 있으므로, UI 업데이트 시 메인 스레드로 디스패치해야 합니다.
    ///   - subsystem: 로깅 서브시스템
    ///   - category: 로깅 카테고리
    public init(
        tokenManager: TokenManager,
        headerName: String = "Authorization",
        tokenPrefix: String = "Bearer ",
        onAuthenticationFailed: AuthenticationFailedHandler? = nil,
        subsystem: String = Bundle.main.bundleIdentifier ?? "com.app.auth",
        category: String = "TokenAuthProvider"
    ) {
        self.tokenManager = tokenManager
        self.headerName = headerName
        self.tokenPrefix = tokenPrefix
        self.onAuthenticationFailed = onAuthenticationFailed
        self.logger = Logger(subsystem: subsystem, category: category)
    }
    
    // MARK: - AuthenticationProvider 구현
    
    /// 요청에 인증 헤더를 추가합니다.
    /// - Parameter request: 원본 URLRequest
    /// - Returns: 인증 헤더가 추가된 URLRequest
    /// - Throws: 토큰을 가져오는 중 오류가 발생하면 TokenError 등을 던집니다.
    public func authenticate(request: URLRequest) async throws -> URLRequest {
        do {
            // 토큰 관리자에서 유효한 접근 토큰 가져오기
            let accessToken = try await tokenManager.getValidAccessToken()
            var mutableRequest = request // URLRequest는 값 타입이므로 복사됨
            
            // 인증 헤더 추가 (headers 프로퍼티 사용 가정)
            let headerValue = "\(tokenPrefix)\(accessToken)" // NetifyRequest는 headers 프로퍼티를 가짐
            mutableRequest.setValue(headerValue, forHTTPHeaderField: headerName) // 수정: URLRequest의 헤더 설정 메서드 사용

            logger.debug("Added authentication header to request")
            return mutableRequest
        } catch {
            logger.error("Failed to add authentication: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// 인증 토큰 만료 시 호출되어 비동기적으로 갱신을 시도합니다.
    /// - Returns: 갱신 성공 여부.
    /// - Throws: 갱신 중 발생한 오류 (예: 네트워크 오류, 서버 오류).
    ///           TokenManager 내부 오류는 Bool 값으로 변환됩니다.
    public func refreshAuthentication() async throws -> Bool {
        logger.info("Attempting to refresh authentication via provider.")
        do {
            // 토큰 강제 갱신 시도
            _ = try await tokenManager.getValidAccessToken(forceRefresh: true)
            logger.info("Authentication refresh successful.")
            return true
        } catch let error as TokenError where error == .refreshTokenMissing || error == .tokenNotFound {
            // 갱신 토큰이 없거나 찾을 수 없는 명확한 실패 케이스
            logger.warning("Authentication refresh failed: Refresh token missing or token info not found.")
            if let onAuthenticationFailed = onAuthenticationFailed {
                logger.info("Invoking authentication failed handler due to missing refresh token.")
                onAuthenticationFailed()
            }
            return false // 갱신 불가능 상태이므로 false 반환
        } catch {
            // 그 외 TokenManager 내부 오류 또는 네트워크 오류 등
            // 오류 타입과 설명을 함께 로깅하여 디버깅 용이성 향상
            logger.error("Authentication refresh failed with error type \(type(of: error)): \(error.localizedDescription)")
            if let onAuthenticationFailed = onAuthenticationFailed {
                logger.info("Invoking authentication failed handler due to refresh error.")
                // 주의: 이 핸들러는 현재 스레드(백그라운드일 수 있음)에서 실행됩니다.
                onAuthenticationFailed()
            }
            return false // 갱신 실패 시 false 반환
        }
    }
    
    /// NetifyClient가 오류 발생 시 호출하여 해당 오류가 인증 만료(HTTP 401 Unauthorized 등)를 나타내는지 확인합니다.
    /// AuthenticationProvider 프로토콜 요구사항입니다.
    public nonisolated func isAuthenticationExpired(from error: Error) -> Bool {
        guard let networkError = error as? NetworkRequestError else { return false }

        // Netify의 NetworkRequestError 케이스 확인
        switch networkError {
        case .unauthorized:
            return true
        case .forbidden:
            // 403 Forbidden은 일반적으로 토큰 만료보다는 권한 부족을 의미하므로,
            // 기본적으로는 인증 만료로 간주하지 않아 갱신을 트리거하지 않음.
            return false
        // .unauthorized 케이스가 401을 처리하므로 .clientError에서 401을 중복 확인할 필요는 없음
        default:
            return false
        }
    }
}
