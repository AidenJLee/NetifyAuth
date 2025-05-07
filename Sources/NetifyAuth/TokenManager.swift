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
    public typealias RefreshRequestProvider = @Sendable (String) -> any NetifyRequest
    
    /// 갱신 토큰으로 토큰 폐기 요청 생성 클로저
    public typealias RevokeRequestProvider = @Sendable (String) -> any NetifyRequest
    
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
        subsystem: String = Bundle.main.bundleIdentifier ?? "com.netifyauth.token",
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
        Task { [weak self] in // 순환 참조 방지를 위해 [weak self] 추가
            // self가 해제된 경우를 대비한 가드 추가
            guard let self = self else { return }
            await self.loadInitialToken()
        }
    }
    
    /// 초기 토큰 로드
    private func loadInitialToken() async {
        do {
            let loadedToken = try await tokenStorage.load(forKey: storageKey)
            // 로드 성공 시, 현재 토큰 상태와 관계없이 로드된 토큰으로 상태를 업데이트하고 방출합니다.
            // 이것이 스트림의 명확한 초기 상태를 설정합니다.
            self.currentToken = loadedToken
            logger.info("저장소에서 토큰 로드 완료: \(self.storageKey)")
            tokenContinuation.yield(loadedToken)
        } catch TokenError.tokenNotFound {
            logger.info("저장소에 토큰 없음: \(self.storageKey)")
            // 토큰이 없을 경우, 현재 토큰을 nil로 설정하고 nil을 방출합니다.
            self.currentToken = nil
            tokenContinuation.yield(nil)
        } catch {
            logger.error("토큰 로드 실패: \(error.localizedDescription)")
            // 기타 오류 발생 시에도 현재 토큰을 nil로 설정하고 nil을 방출합니다.
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
            logger.debug("진행 중인 갱신 작업 대기 중")
            return try await task.value
        }
        
        // 2. 현재 토큰 확인
        guard let token = currentToken else {
            logger.warning("사용 가능한 토큰 없음")
            throw TokenError.tokenNotFound
        }
        
        // 3. 강제 갱신 요청
        if forceRefresh {
            logger.info("토큰 강제 갱신 시도")
            return try await refreshToken()
        }
        
        // 4. 토큰 상태 확인
        let state = token.checkValidity(
            accessTokenBuffer: accessTokenRefreshBuffer,
            refreshTokenBuffer: refreshTokenBuffer
        )
        
        switch state {
        case .valid:
            logger.debug("유효한 접근 토큰 사용")
            return token.accessToken
            
        case .needsRefresh:
            logger.info("접근 토큰 갱신 필요")
            return try await refreshToken()
            
        case .invalid:
            logger.warning("토큰 만료, 재인증 필요")
            throw TokenError.refreshTokenMissing // 갱신 토큰이 없거나 만료된 경우이므로 이 오류를 발생시킴
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
        // 스트림에 변경 알림 (내부 상태가 업데이트되었으므로)
        // 저장소 작업 실패 여부와 관계없이 currentToken은 newToken이 됨
        tokenContinuation.yield(newToken)
        // 저장소에 저장
        try await tokenStorage.save(tokenInfo: newToken, forKey: storageKey)
    }
    
    /// 토큰 초기화 (로그아웃)
    public func clearTokens() async throws {
        let tokenExistedPreviously = currentToken != nil
        
        // 내부 상태 초기화
        currentToken = nil
        
        // 스트림에 변경 알림 (내부 상태가 nil로 변경되었으므로)
        // 저장소 작업 실패 여부와 관계없이 currentToken은 nil이 됨
        if tokenExistedPreviously { // Only yield nil if there was a token to clear
            tokenContinuation.yield(nil)
        }
        
        // 진행 중인 갱신 태스크 취소
        refreshTask?.cancel()
        refreshTask = nil
        
        // 저장소에서 삭제
        try await tokenStorage.delete(forKey: storageKey)
        logger.info("토큰 초기화 및 저장소에서 삭제 완료")
    }
    
    /// 토큰 폐기 (서버에 알림)
    public func revokeTokens() async throws {
        guard let refreshTokenToRevoke = getRefreshToken() else { // 변수명 명확화
            logger.warning("폐기할 갱신 토큰 없음")
            try? await clearTokens() // 로컬 토큰만이라도 정리 시도
            return
        }
        
        var revocationError: Error?
        
        // 서버에 폐기 요청
        do {
            let request = revokeRequestProvider(refreshTokenToRevoke)
            _ = try await apiClient.send(request)
            logger.info("서버에 토큰 폐기 요청 성공")
        } catch {
            logger.error("토큰 폐기 실패: \(error.localizedDescription)")
            revocationError = error
        }
        
        // 로컬 토큰 삭제
        do {
            try await clearTokens()
        } catch {
            // 로컬 토큰 삭제 실패는 크리티컬한 상황일 수 있으므로 로깅 레벨 조정
            logger.critical("로컬 토큰 삭제 실패: \(error.localizedDescription)")
            // 서버 폐기 성공 여부와 관계없이 로컬 삭제 실패 시 오류를 우선적으로 던짐
            throw error
        }
        
        // 서버 폐기 실패 시 오류 전달 (로컬 삭제가 성공했을 경우)
        if let error = revocationError {
            throw TokenError.revocationFailed(description: error.localizedDescription)
        }
        
        logger.info("토큰 폐기 절차 완료")
    }
    
    // MARK: - 내부 메서드
    
    /// 토큰 갱신 수행
    private func refreshToken() async throws -> String {
        // 진행 중인 태스크 확인
        if let existingTask = refreshTask { // 변수명 명확화
            logger.debug("기존 갱신 작업 대기 중")
            return try await existingTask.value
        }
        
        // 현재 토큰 확인
        guard let currentTokenInfo = currentToken else { // 변수명 명확화
            logger.warning("갱신할 현재 토큰 정보 없음")
            throw TokenError.tokenNotFound
        }
        
        // 갱신 토큰 확인
        guard let refreshTokenValue = currentTokenInfo.refreshToken else { // 변수명 명확화
            logger.warning("갱신 토큰 없음")
            throw TokenError.refreshTokenMissing
        }
        
        // 갱신 토큰 만료 확인
        if let expiresAt = currentTokenInfo.refreshTokenExpiresAt,
           expiresAt.addingTimeInterval(-refreshTokenBuffer) < Date() {
            logger.warning("갱신 토큰 만료됨")
            throw TokenError.refreshTokenMissing
        }
        
        // 새 갱신 태스크 생성
        logger.info("새로운 갱신 작업 생성")
        let newTask = Task<String, Error> { [weak self] in // 변수명 명확화, 순환 참조 방지
            guard let self = self else {
                throw TokenError.unknown(message: "TokenManager deallocated during refresh")
            }
            return try await self.executeRefresh(with: refreshTokenValue)
        }
        
        self.refreshTask = newTask
        
        // 태스크 완료 후 정리 (새로운 Task에서 비동기적으로 처리)
        Task { [weak self] in
            _ = await newTask.result // 작업 완료 대기 (성공/실패 무관)
            await self?.clearRefreshTask() // 완료 후 refreshTask 참조 정리
        }
        
        // 결과 반환
        do {
            return try await newTask.value
        } catch {
            // TokenError나 CancellationError는 그대로 전달
            if error is TokenError || error is CancellationError {
                throw error
            } else {
                // 그 외 오류는 TokenError.refreshFailed로 래핑
                logger.error("갱신 작업 중 알 수 없는 오류 발생: \(error.localizedDescription)")
                throw TokenError.refreshFailed(description: error.localizedDescription)
            }
        }
    }
    
    /// 실제 토큰 갱신 요청 수행
    private func executeRefresh(with refreshToken: String) async throws -> String {
        logger.info("토큰 갱신 요청 실행")
        
        do {
            // 갱신 요청 생성
            let request = refreshRequestProvider(refreshToken)
            
            // API 호출
            let response = try await apiClient.send(request)
            
            // 응답 검증
            guard let tokenResponse = response as? TokenRefreshResponse else {
                logger.error("잘못된 응답 타입: \(type(of: response))")
                throw TokenError.invalidResponse(reason: "응답이 TokenRefreshResponse를 준수하지 않음")
            }
            
            // 토큰 업데이트
            // 새 갱신 토큰이 응답에 없으면 기존 갱신 토큰을 유지
            try await updateTokens(
                accessToken: tokenResponse.accessToken,
                accessTokenExpiresIn: tokenResponse.accessTokenExpiresIn,
                refreshToken: tokenResponse.refreshToken ?? refreshToken,
                refreshTokenExpiresIn: tokenResponse.refreshTokenExpiresIn
            )
            
            logger.info("토큰 갱신 성공")
            return tokenResponse.accessToken
            
        } catch let error as NetworkRequestError where
                    error.isUnauthorized || error.isForbidden {
            // 401 또는 403 오류 발생 시: 갱신 토큰이 거부된 것으로 간주
            logger.error("갱신 토큰 거부됨 (401/403): \(error.localizedDescription)")
            try? await clearTokens() // 로컬 토큰 정리 시도
            throw TokenError.refreshTokenMissing // 인증 실패와 유사하게 처리
            
        } catch {
            // 그 외 네트워크 오류 또는 기타 오류
            logger.error("토큰 갱신 실패: \(error.localizedDescription)")
            throw TokenError.refreshFailed(description: error.localizedDescription)
        }
    }
    
    /// 갱신 태스크 정리
    private func clearRefreshTask() {
        if refreshTask != nil { // 이미 nil이 아닌 경우에만 로깅
            refreshTask = nil
            logger.debug("갱신 작업 참조 해제됨")
        }
    }
}

// MARK: - 네트워크 오류 확장
// Netify 라이브러리의 NetworkRequestError 정의에 의존적인 확장입니다.
// Netify의 해당 타입 변경 시 이 확장 기능도 영향을 받을 수 있습니다.
private extension NetworkRequestError {
    /// 오류가 인증 만료(Unauthorized)를 나타내는지 여부
    var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }
    
    /// 오류가 접근 금지(Forbidden)를 나타내는지 여부
    var isForbidden: Bool {
        if case .forbidden = self { return true }
        return false
    }
}
