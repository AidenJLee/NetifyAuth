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
    
    func testSaveAndLoadToken() async throws {
        // Save
        try await storage.save(tokenInfo: testTokenInfo, forKey: testKey)
        
        // Load
        let loadedToken = try await storage.load(forKey: testKey)
        XCTAssertEqual(loadedToken, testTokenInfo)
    }
    
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
    
    func testDeleteNonExistentToken() async throws {
        // Deleting a non-existent key should not throw an error
        try await storage.delete(forKey: "nonExistentKey")
    }
    
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
