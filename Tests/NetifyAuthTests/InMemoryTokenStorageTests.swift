// Tests/NetifyAuthTests/InMemoryTokenStorageTests.swift
import XCTest
@testable import NetifyAuth

final class InMemoryTokenStorageTests: XCTestCase {
    
    var storage: InMemoryTokenStorage!
    let testKey = "testTokenKey"
    let testTokenInfo = createTestTokenInfo()
    
    override func setUp() {
        super.setUp()
        storage = InMemoryTokenStorage()
    }
    
    override func tearDown() {
        storage = nil
        super.tearDown()
    }
    
    // 의도: InMemoryTokenStorage에 토큰을 저장하고 로드할 수 있는지 확인합니다.
    // 주어진 상황: TokenInfo 객체와 키.
    // 실행 시점: 키를 사용하여 토큰을 저장한 다음 동일한 키를 사용하여 로드할 때.
    // 예상 결과: 로드된 토큰은 원래 저장된 토큰과 같아야 합니다.
    func testSaveAndLoadToken() async throws {
        // Save
        try await storage.save(tokenInfo: testTokenInfo, forKey: testKey)
        
        // Load
        let loadedToken = try await storage.load(forKey: testKey)
        XCTAssertEqual(loadedToken, testTokenInfo)
    }
    
    // 의도: 존재하지 않는 키로 토큰을 로드하려고 할 때 TokenError.tokenNotFound가 발생하는지 확인합니다.
    // 주어진 상황: 토큰 저장에 사용되지 않은 키.
    // 실행 시점: 존재하지 않는 키로 load가 호출될 때.
    // 예상 결과: TokenError.tokenNotFound 오류가 발생해야 합니다.
    func testLoadTokenNotFound() async {
        do {
            _ = try await storage.load(forKey: "nonExistentKey")
            XCTFail("Expected TokenError.tokenNotFound but no error was thrown.")
        } catch let error as TokenError {
            XCTAssertEqual(error, .tokenNotFound)
        } catch {
            XCTFail("Expected TokenError.tokenNotFound but got \(error)")
        }
    }
    
    // 의도: 저장된 토큰을 스토리지에서 삭제할 수 있는지 확인합니다.
    // 주어진 상황: 스토리지에 저장된 토큰.
    // 실행 시점: 토큰의 키로 delete가 호출될 때.
    // 예상 결과: 동일한 키로 토큰을 다시 로드하려고 하면 TokenError.tokenNotFound가 발생해야 합니다.
    func testDeleteToken() async throws {
        // Save first
        try await storage.save(tokenInfo: testTokenInfo, forKey: testKey)
        
        // Delete
        try await storage.delete(forKey: testKey)
        
        // Try to load again, should fail
        do {
            _ = try await storage.load(forKey: testKey)
            XCTFail("Expected TokenError.tokenNotFound but load succeeded.")
        } catch let error as TokenError {
            XCTAssertEqual(error, .tokenNotFound)
        } catch {
            XCTFail("Caught unexpected error type: \(error)")
        }
    }
    
    // 의도: 존재하지 않는 키로 토큰을 삭제하려고 할 때 오류가 발생하지 않는지 확인합니다.
    // 주어진 상황: 토큰 저장에 사용되지 않은 키.
    // 실행 시점: 존재하지 않는 키로 delete가 호출될 때.
    // 예상 결과: 오류가 발생하지 않아야 합니다.
    func testDeleteNonExistentToken() async throws {
        // Deleting a non-existent key should not throw an error
        try await storage.delete(forKey: "nonExistentKey")
    }
    
    // 의도: clearAll이 스토리지에서 모든 토큰을 제거하는지 확인합니다.
    // 주어진 상황: 스토리지에 여러 토큰이 저장된 경우.
    // 실행 시점: clearAll이 호출될 때.
    // 예상 결과: 이전에 저장된 토큰을 로드하려고 하면 TokenError.tokenNotFound가 발생해야 합니다.
    func testClearAll() async throws {
        try await storage.save(tokenInfo: testTokenInfo, forKey: "key1")
        try await storage.save(tokenInfo: createTestTokenInfo(accessToken: "token2"), forKey: "key2")
        
        await storage.clearAll() // clearAll is now async
        
        // Verify key1 is cleared using do-catch
        do {
            _ = try await storage.load(forKey: "key1")
            XCTFail("Expected TokenError.tokenNotFound for key1 but load succeeded.")
        } catch TokenError.tokenNotFound {
            // Expected error, pass
        } catch {
            XCTFail("Caught unexpected error type for key1: \(error)")
        }
        // Verify key2 is cleared using do-catch
        do {
            _ = try await storage.load(forKey: "key2")
            XCTFail("Expected TokenError.tokenNotFound for key2 but load succeeded.")
        } catch TokenError.tokenNotFound {
            // Expected error, pass
        } catch {
            XCTFail("Caught unexpected error type for key2: \(error)")
        }
    }
    
    // 의도: 기존 키로 토큰을 저장하면 이전 토큰을 덮어쓰는지 확인합니다.
    // 주어진 상황: 특정 키로 저장된 초기 토큰.
    // 실행 시점: 동일한 키로 새 토큰이 저장될 때.
    // 예상 결과: 해당 키로 토큰을 로드하면 새롭고 업데이트된 토큰이 반환되어야 합니다.
    func testOverwriteToken() async throws {
        let initialToken = createTestTokenInfo(accessToken: "initial")
        let updatedToken = createTestTokenInfo(accessToken: "updated")
        
        try await storage.save(tokenInfo: initialToken, forKey: testKey)
        var loaded = try await storage.load(forKey: testKey)
        XCTAssertEqual(loaded.accessToken, "initial")
        
        try await storage.save(tokenInfo: updatedToken, forKey: testKey)
        loaded = try await storage.load(forKey: testKey)
        XCTAssertEqual(loaded.accessToken, "updated")
    }
}
