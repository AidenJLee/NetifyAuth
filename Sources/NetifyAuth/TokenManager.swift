// Sources/NetifyAuth/TokenManager.swift
import Foundation
import OSLog
import Netify

/// 토큰 관리자
/// 토큰 저장, 로드, 유효성 검사, 자동 갱신, 폐기 및 상태 변경 관찰 기능 제공
@available(iOS 15, macOS 12, *)
public actor TokenManager {
    // MARK: - 타입 정의
    
    /// 갱신 토큰으로 토큰 갱신 요청 생성 클로저
    public typealias RefreshRequestProvider = (String) -> any NetifyRequest
    
    /// 갱신 토큰으로 토큰 폐기 요청 생성 클로저
    public typealias RevokeRequestProvider = (String) -> any NetifyRequest
    
    // MARK: - 속성
    
    /// 토큰 정보 변경 스트림
    public let tokenStream: AsyncStream<TokenInfo?>
    
    /// 토큰 저장소
    private let tokenStorage: TokenStorage
    
    /// 저장소 키
    private let storageKey: String
    
    /// API 요청용 클라이언트
    private let apiClient: NetifyClientProtocol // 타입 변경: NetifyClient -> NetifyClientProtocol
    
    /// 토큰 갱신 요청 제공자
    private let refreshRequestProvider: RefreshRequestProvider
    
    /// 토큰 폐기 요청 제공자
    private let revokeRequestProvider: RevokeRequestProvider
    
    /// 로거
    private let logger: Logger
    
    /// 현재 토큰 정보
    private var currentToken: TokenInfo?
    
    /// 토큰 갱신 중복 방지 태스크
    private var refreshTask: Task<String, Error>?
    
    /// 토큰 스트림 컨티뉴에이션
    private let tokenContinuation: AsyncStream<TokenInfo?>.Continuation
    
    /// 접근 토큰 만료 전 버퍼 시간(초)
    private let accessTokenRefreshBuffer: TimeInterval
    
    /// 갱신 토큰 만료 전 버퍼 시간(초)
    private let refreshTokenBuffer: TimeInterval
    
    // MARK: - 초기화
    
    /// 토큰 매니저 초기화
    /// - Parameters:
    ///   - tokenStorage: 토큰 저장소
    ///   - storageKey: 저장소 키
    ///   - apiClient: API 요청용 클라이언트
    ///   - refreshRequestProvider: 토큰 갱신 요청 제공자
    ///   - revokeRequestProvider: 토큰 폐기 요청 제공자
    ///   - accessTokenRefreshBuffer: 접근 토큰 만료 전 버퍼 시간(초)
    ///   - refreshTokenBuffer: 갱신 토큰 만료 전 버퍼 시간(초)
    ///   - subsystem: 로깅 서브시스템
    ///   - category: 로깅 카테고리
    public init(
        tokenStorage: TokenStorage,
        storageKey: String = "auth.token",
        apiClient: NetifyClientProtocol, // 타입 변경
        refreshRequestProvider: @escaping RefreshRequestProvider,
        revokeRequestProvider: @escaping RevokeRequestProvider,
        accessTokenRefreshBuffer: TimeInterval = 60.0,
        refreshTokenBuffer: TimeInterval = 0,
        subsystem: String = Bundle.main.bundleIdentifier ?? "com.app.auth",
        category: String = "TokenManager"
    ) {
        self.tokenStorage = tokenStorage
        self.storageKey = storageKey
        self.apiClient = apiClient
        self.refreshRequestProvider = refreshRequestProvider
        self.revokeRequestProvider = revokeRequestProvider
        self.accessTokenRefreshBuffer = max(0, accessTokenRefreshBuffer)
        self.refreshTokenBuffer = max(0, refreshTokenBuffer)
        self.logger = Logger(subsystem: subsystem, category: category)
        
        // 토큰 스트림 초기화
        var continuation: AsyncStream<TokenInfo?>.Continuation!
        self.tokenStream = AsyncStream(TokenInfo?.self, bufferingPolicy: .bufferingNewest(1)) {
            continuation = $0
        }
        self.tokenContinuation = continuation
        
        // 초기 토큰 로드
        Task {
            await loadInitialToken()
        }
    }
    
    /// 초기 토큰 로드
    private func loadInitialToken() async {
        do {
            let token = try await tokenStorage.load(forKey: storageKey)
            self.currentToken = token
            logger.info("Token loaded from storage: \(self.storageKey)")
            
            // 토큰 스트림에 초기값 전달
            tokenContinuation.yield(token)
        } catch TokenError.tokenNotFound {
            logger.info("No token found in storage: \(self.storageKey)")
            // currentToken은 이미 nil일 수 있지만 명시적으로 설정
            self.currentToken = nil 
            tokenContinuation.yield(nil)
        } catch {
            logger.error("Failed to load token: \(error.localizedDescription)")
            self.currentToken = nil
            tokenContinuation.yield(nil)
        }
    }
    
    // MARK: - 공개 메서드
    
    /// 유효한 접근 토큰 가져오기
    /// - Parameter forceRefresh: 강제 갱신 여부
    /// - Returns: 유효한 접근 토큰
    public func getValidAccessToken(forceRefresh: Bool = false) async throws -> String {
        // 1. 진행 중인 갱신 태스크가 있으면 대기
        if let task = refreshTask {
            logger.debug("Waiting for ongoing refresh task")
            return try await task.value
        }
        
        // 2. 현재 토큰 확인
        guard let token = currentToken else {
            logger.warning("No token available")
            throw TokenError.tokenNotFound
        }
        
        // 3. 강제 갱신 요청
        if forceRefresh {
            logger.info("Forcing token refresh")
            return try await refreshToken()
        }
        
        // 4. 토큰 상태 확인
        let state = token.checkValidity(
            accessTokenBuffer: accessTokenRefreshBuffer,
            refreshTokenBuffer: refreshTokenBuffer
        )
        
        switch state {
        case .valid:
            logger.debug("Using valid access token")
            return token.accessToken
            
        case .needsRefresh:
            logger.info("Access token needs refresh")
            return try await refreshToken()
            
        case .invalid:
            logger.warning("Token invalid, re-authentication required")
            throw TokenError.refreshTokenMissing
        }
    }
    
    /// 갱신 토큰 가져오기
    /// - Returns: 갱신 토큰 (없으면 nil)
    public func getRefreshToken() -> String? {
        return currentToken?.refreshToken
    }
    
    /// 토큰 업데이트
    /// - Parameters:
    ///   - accessToken: 접근 토큰
    ///   - accessTokenExpiresIn: 접근 토큰 유효 기간(초)
    ///   - refreshToken: 갱신 토큰
    ///   - refreshTokenExpiresIn: 갱신 토큰 유효 기간(초)
    public func updateTokens(
        accessToken: String,
        accessTokenExpiresIn: TimeInterval,
        refreshToken: String?,
        refreshTokenExpiresIn: TimeInterval?
    ) async throws {
        // 새 토큰 정보 생성
        let newToken = TokenInfo.create(
            accessToken: accessToken,
            accessTokenExpiresIn: accessTokenExpiresIn,
            refreshToken: refreshToken,
            refreshTokenExpiresIn: refreshTokenExpiresIn
        )
        
        // 내부 상태 업데이트
        self.currentToken = newToken
        
        // 저장소에 저장
        try await tokenStorage.save(tokenInfo: newToken, forKey: storageKey)
        logger.info("Token updated and saved")
        
        // 스트림에 변경 알림
        tokenContinuation.yield(newToken)
    }
    
    /// 토큰 초기화 (로그아웃)
    public func clearTokens() async throws {
        let hadToken = currentToken != nil
        
        // 내부 상태 초기화
        currentToken = nil
        
        // 진행 중인 갱신 태스크 취소
        refreshTask?.cancel()
        refreshTask = nil
        
        // 저장소에서 삭제
        try await tokenStorage.delete(forKey: storageKey)
        logger.info("Tokens cleared")
        
        // 이전에 토큰이 있었다면 스트림에 변경 알림
        if hadToken {
            tokenContinuation.yield(nil)
        }
    }
    
    /// 토큰 폐기 (서버에 알림)
    public func revokeTokens() async throws {
        guard let refreshToken = getRefreshToken() else {
            logger.warning("No refresh token to revoke")
            try? await clearTokens()
            return
        }
        
        var revocationError: Error?
        
        // 서버에 폐기 요청
        do {
            let request = revokeRequestProvider(refreshToken)
            _ = try await apiClient.send(request)
            logger.info("Token revoked on server")
        } catch {
            logger.error("Failed to revoke token: \(error.localizedDescription)")
            revocationError = error
        }
        
        // 로컬 토큰 삭제
        do {
            try await clearTokens()
        } catch {
            logger.critical("Failed to clear local tokens: \(error.localizedDescription)")
            throw error
        }
        
        // 서버 폐기 실패 시 오류 전달
        if let error = revocationError {
            // 서버 폐기 실패 오류를 명확한 타입으로 전달
            throw TokenError.revocationFailed(underlyingError: error)
        }
        
        logger.info("Token revocation completed")
    }
    
    // MARK: - 내부 메서드
    
    /// 토큰 갱신 수행
    private func refreshToken() async throws -> String {
        // 진행 중인 태스크 확인
        if let task = refreshTask {
            return try await task.value
        }
        
        // 현재 토큰 확인
        guard let token = currentToken else {
            throw TokenError.tokenNotFound
        }
        
        // 갱신 토큰 확인
        guard let refreshToken = token.refreshToken else {
            throw TokenError.refreshTokenMissing
        }
        
        // 갱신 토큰 만료 확인
        if let expiresAt = token.refreshTokenExpiresAt, expiresAt.addingTimeInterval(-refreshTokenBuffer) < Date() {
            throw TokenError.refreshTokenMissing
        }
        
        // 새 갱신 태스크 생성
        logger.info("Creating new refresh task")
        let task = Task<String, Error> { [weak self] in
            guard let self = self else {
                throw TokenError.unknown(message: "TokenManager deallocated")
            }
            return try await self.executeRefresh(with: refreshToken)
        }
        
        self.refreshTask = task
        
        // 태스크 완료 후 정리
        Task { [weak self] in
            _ = await task.result
            await self?.clearRefreshTask()
        }
        
        // 결과 반환
        do {
            return try await task.value
        } catch {
            if error is TokenError || error is CancellationError {
                throw error
            } else {
                throw TokenError.refreshFailed(description: error.localizedDescription)
            }
        }
    }
    
    /// 실제 토큰 갱신 요청 수행
    private func executeRefresh(with refreshToken: String) async throws -> String {
        logger.info("Executing token refresh request")
        
        do {
            // 갱신 요청 생성
            let request = refreshRequestProvider(refreshToken)
            
            // API 호출
            let response = try await apiClient.send(request)
            
            // 응답 검증
            // NetifyRequest의 ResponseType 제약으로 인해 이론적으로 항상 성공해야 하지만,
            // 런타임 안전성을 위해 명시적으로 타입을 확인합니다.
            guard let tokenResponse = response as? TokenRefreshResponse else {
                logger.error("Invalid response type: \(type(of: response))")
                throw TokenError.invalidResponse(reason: "Response doesn't conform to TokenRefreshResponse")
            }
            
            // 토큰 업데이트
            try await updateTokens(
                accessToken: tokenResponse.accessToken,
                accessTokenExpiresIn: tokenResponse.accessTokenExpiresIn,
                refreshToken: tokenResponse.refreshToken ?? refreshToken,
                refreshTokenExpiresIn: tokenResponse.refreshTokenExpiresIn
            )
            
            logger.info("Token refresh successful")
            return tokenResponse.accessToken
            
        } catch let error as NetworkRequestError where
                    error.isUnauthorized || error.isForbidden {
            logger.error("Refresh token rejected: \(error.localizedDescription)")
            try? await clearTokens()
            throw TokenError.refreshTokenMissing
            
        } catch {
            logger.error("Token refresh failed: \(error.localizedDescription)")
            throw TokenError.refreshFailed(description: error.localizedDescription)
        }
    }
    
    /// 갱신 태스크 정리
    private func clearRefreshTask() {
        refreshTask = nil
        logger.debug("Refresh task reference cleared")
    }
}

// MARK: - 네트워크 오류 확장
// Netify 라이브러리의 NetworkRequestError 정의에 의존적인 확장입니다.
// Netify의 해당 타입 변경 시 이 확장 기능도 영향을 받을 수 있습니다.
private extension NetworkRequestError {
    var isUnauthorized: Bool {
        // 실제 Netify의 NetworkRequestError 정의에 맞게 수정
        if case .unauthorized = self { return true }
        // .clientError 케이스는 401 외 다른 클라이언트 오류를 포함하므로 여기서는 확인하지 않음
        return false
    }
    
    var isForbidden: Bool {
        // 실제 Netify의 NetworkRequestError 정의에 맞게 수정
        if case .forbidden = self { return true }
        // .clientError 케이스는 403 외 다른 클라이언트 오류를 포함하므로 여기서는 확인하지 않음
        return false
    }
}
