## NetifyAuth 테스트 계획서

### 1. 개요

이 문서는 `NetifyAuth` 라이브러리의 각 구성 요소(`Sources` 폴더 기준)에 대한 테스트 계획을 기술합니다. 목표는 라이브러리의 정확성, 안정성 및 예상된 동작을 검증하는 것입니다. 테스트는 주로 단위 테스트 방식으로 진행되며, 각 컴포넌트의 기능과 상호작용을 중점적으로 다룹니다.

### 2. 테스트 대상 컴포넌트 및 항목

#### 2.1. `TokenInfo` (in `TokenModels.swift`)

* **목표:** 토큰 데이터 구조의 생성, 유효성 검사, 직렬화/역직렬화 로직 검증.
* **테스트 항목:**
    * `TokenInfo.create`:
        * Access Token 및 Refresh Token 포함 시 만료 시간(`accessTokenExpiresAt`, `refreshTokenExpiresAt`) 정확성 검증.
        * Refresh Token 미포함 시 만료 시간 정확성 검증.
    * `checkValidity`:
        * **Valid:** 유효한 Access Token 상태 반환 검증.
        * **NeedsRefresh (Buffer):** Access Token 만료 버퍼 내에 있을 때 `.needsRefresh` 상태 반환 검증.
        * **NeedsRefresh (Expired):** Access Token 만료되었으나 유효한 Refresh Token 존재 시 `.needsRefresh` 상태 반환 검증.
        * **Invalid (No Refresh Token):** Access Token 만료 및 Refresh Token 부재 시 `.invalid` 상태 반환 검증.
        * **Invalid (Refresh Token Expired):** Access Token 및 Refresh Token 모두 만료 시 `.invalid` 상태 반환 검증.
        * `accessTokenRefreshBuffer`, `refreshTokenBuffer` 파라미터 영향 검증.
    * `Equatable` 프로토콜 준수 검증 (동등성 비교).
    * `Codable` 프로토콜 준수 검증 (JSON 인코딩/디코딩).

#### 2.2. `TokenStorage` 구현체 (in `KeychainTokenStorage.swift`)

* **목표:** 토큰 저장 및 로드 로직 검증. `InMemoryTokenStorage`를 중점적으로 테스트합니다. (`KeychainTokenStorage`는 시스템 의존성 및 자동화 어려움으로 인해 수동 테스트 또는 별도 환경 필요).
* **테스트 항목 (`InMemoryTokenStorageTests`):**
    * `save` 및 `load`: 정상적인 저장 및 로드 동작 검증.
    * `load` (실패): 존재하지 않는 키 로드 시 `TokenError.tokenNotFound` 오류 발생 검증.
    * `delete`: 정상적인 삭제 동작 검증 (삭제 후 `load` 시 실패).
    * `delete` (실패): 존재하지 않는 키 삭제 시 오류 미발생 검증.
    * `save` (덮어쓰기): 동일 키에 대해 `save` 호출 시 데이터 덮어쓰기 검증.
    * `clearAll`: 모든 데이터 삭제 기능 검증.

#### 2.3. `TokenManager` (in `TokenManager.swift`)

* **목표:** 토큰 관리 로직(로드, 유효성 검사, 자동 갱신, 업데이트, 삭제, 폐기, 상태 스트림)의 정확성 및 동시성 처리 검증.
* **테스트 항목:**
    * **초기화:**
        * 저장소에 유효한 토큰 존재 시 초기 로드 성공 검증 (내부 상태 `currentToken`, `tokenStream` 초기 방출 값).
        * 저장소에 토큰 부재 시 초기 로드 검증 (내부 상태 `currentToken`, `tokenStream` 초기 방출 값).
        * 초기 로드 중 저장소 오류 발생 시 처리 검증.
    * **`getValidAccessToken`:**
        * **Valid:** 유효 토큰 존재 시 Access Token 반환 및 API 미호출 검증.
        * **No Token:** 토큰 부재 시 `TokenError.tokenNotFound` 오류 발생 검증.
        * **Needs Refresh (Success):** Access Token 만료 및 유효 Refresh Token 존재 시, 자동 갱신 실행, 새 Access Token 반환, 저장소 업데이트, `tokenStream` 방출 검증.
        * **Needs Refresh (Buffer):** Access Token 버퍼 내 존재 시 자동 갱신 실행 검증.
        * **Force Refresh:** `forceRefresh: true` 파라미터 사용 시 토큰 유효 상태와 무관하게 강제 갱신 실행 검증.
        * **Refresh Fail (Missing RT):** 갱신 필요하나 Refresh Token 부재 시 `TokenError.refreshTokenMissing` 오류 발생 검증.
        * **Refresh Fail (Expired RT):** 갱신 필요하나 Refresh Token 만료 시 `TokenError.refreshTokenMissing` 오류 발생 검증.
        * **Refresh Fail (API Error):** 갱신 API 호출 실패(일반 네트워크 오류) 시 `TokenError.refreshFailed` 오류 발생 검증.
        * **Refresh Fail (API 401/403):** 갱신 API 호출 시 401/403 응답 수신 시, 토큰 자동 삭제, `TokenError.refreshTokenMissing` 오류 발생, `tokenStream`에 `nil` 방출 검증.
        * **Refresh Fail (Invalid Response):** 갱신 API 응답 형식이 `TokenRefreshResponse`와 불일치 시 `TokenError.invalidResponse` 오류 발생 검증.
        * **Concurrent Refresh:** 여러 스레드/Task에서 동시에 `getValidAccessToken` 호출(갱신 필요 상황) 시, 갱신 API 호출은 1회만 발생하고 모든 호출자가 동일한 새 토큰을 받는지 검증.
    * **`getRefreshToken`:**
        * Refresh Token 존재 시 올바른 값 반환 검증.
        * 토큰 또는 Refresh Token 부재 시 `nil` 반환 검증.
    * **`updateTokens`:**
        * 새 토큰 정보(Access + Refresh)로 업데이트 시, 내부 상태 변경, 저장소 저장, `tokenStream` 방출 검증.
        * Refresh Token 없이 업데이트 시 검증.
        * 업데이트 중 저장소 저장 실패 시 오류 처리 검증.
    * **`clearTokens`:**
        * 기존 토큰 삭제 시, 내부 상태 `nil`, 저장소 삭제, 진행 중인 갱신 작업(`refreshTask`) 취소, `tokenStream`에 `nil` 방출 검증.
        * 토큰 부재 시 `clearTokens` 호출해도 오류 미발생 및 `tokenStream` 미방출(이미 nil일 경우) 검증.
    * **`revokeTokens`:**
        * **Success:** 유효 Refresh Token 존재 시, 폐기 API 호출, 로컬 토큰 삭제, `tokenStream`에 `nil` 방출 검증.
        * **API Fail:** 폐기 API 호출 실패 시, `TokenError.revocationFailed` 오류 발생, *하지만* 로컬 토큰은 삭제되고 `tokenStream`에 `nil` 방출 검증.
        * **No Refresh Token:** Refresh Token 부재 시, API 미호출, 로컬 토큰만 삭제, `tokenStream`에 `nil` 방출 검증.
        * 폐기 중 저장소 삭제 실패 시 오류 처리 검증.
    * **`tokenStream`:**
        * 초기화 시 토큰 로드 성공/실패에 따른 정확한 값 방출 검증.
        * `updateTokens` 호출 후 새 `TokenInfo` 방출 검증.
        * `clearTokens` 호출 후 `nil` 방출 검증.
        * `revokeTokens` 호출 후 `nil` 방출 검증.
        * 토큰 갱신 성공 후 새 `TokenInfo` 방출 검증.
        * 토큰 갱신 실패(401/403) 후 `nil` 방출 검증.

#### 2.4. `TokenAuthProvider` (in `TokenAuthProvider.swift`)

* **목표:** `TokenManager`와 `NetifyClient` 간의 통합 로직, 헤더 추가 및 자동 갱신 트리거 로직 검증.
* **테스트 항목:**
    * **`authenticate(request:)`:**
        * **Success (Valid Token):** `TokenManager`가 유효 토큰 제공 시, 요청 헤더에 올바른 인증 정보(`Authorization: Bearer <token>`) 추가 검증.
        * **Success (Refreshed Token):** `TokenManager`가 토큰 갱신 성공 시, *새* 토큰으로 헤더 추가 검증.
        * **Failure:** `TokenManager`가 오류(`tokenNotFound`, `refreshFailed` 등) 발생 시, 해당 오류 전파 검증.
        * 사용자 정의 `headerName`, `tokenPrefix` 설정 시 정상 동작 검증.
    * **`refreshAuthentication()`:**
        * **Success:** `TokenManager` 갱신 성공 시 `true` 반환 검증.
        * **Failure (API Error):** `TokenManager` 갱신 실패(네트워크 오류 등) 시 `false` 반환 및 `onAuthenticationFailed` 핸들러 호출 검증.
        * **Failure (No/Expired RT):** `TokenManager` 갱신 실패(`refreshTokenMissing`, `tokenNotFound`) 시 `false` 반환 및 `onAuthenticationFailed` 핸들러 호출 검증.
        * `onAuthenticationFailed` 핸들러가 `nil`일 때의 동작 검증 (오류 미발생).
    * **`isAuthenticationExpired(from:)`:**
        * 입력 오류가 `NetworkRequestError.unauthorized`일 때 `true` 반환 검증.
        * 입력 오류가 `NetworkRequestError.forbidden`일 때 `false` 반환 검증.
        * 다른 `NetworkRequestError` 케이스 및 일반 `Error` 타입일 때 `false` 반환 검증.

### 3. 테스트 환경 및 도구

* **프레임워크:** XCTest
* **Mocking:**
    * `MockNetifyClient`: `NetifyClientProtocol`을 준수하여 API 요청 및 응답(성공/실패) 시뮬레이션.
    * `InMemoryTokenStorage`: `TokenStorage` 프로토콜 구현체로, 실제 저장소 대신 메모리 사용.
    * Mock `NetifyRequest` 구현체 (갱신/폐기 요청용).
    * Mock `TokenRefreshResponse` 구현체.
* **Helper:** 테스트 데이터(`TokenInfo`) 생성을 위한 유틸리티 함수.

---
