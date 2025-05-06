// Sources/NetifyAuth/KeychainTokenStorage.swift
import Foundation
import Security

/// 키체인을 사용한 토큰 저장소 구현
public class KeychainTokenStorage: TokenStorage {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let serviceName: String
    private let accessibility: CFString
    
    /// 키체인 토큰 저장소 초기화
    /// - Parameters:
    ///   - serviceName: 키체인 서비스 이름 (기본값: 앱 번들 ID)
    ///   - accessibility: 키체인 접근성 설정
    public init(
        serviceName: String = Bundle.main.bundleIdentifier ?? "com.app.tokenstore",
        accessibility: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ) {
        self.serviceName = serviceName
        self.accessibility = accessibility
    }
    
    /// 키체인 쿼리 생성
    private func makeQuery(forKey key: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: key
        ]
    }
    
    public func save(tokenInfo: TokenInfo, forKey key: String) async throws {
        do {
            let data = try encoder.encode(tokenInfo)
            
            var query = makeQuery(forKey: key)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = accessibility
            
            // 먼저 삭제 시도 (기존 항목이 있을 경우)
            SecItemDelete(query as CFDictionary)
            
            // 새로운 항목 추가
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else {
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "Status: \(status)"
                throw TokenError.storageError(description: message)
            }
        } catch let error as TokenError {
            throw error
        } catch {
            throw TokenError.encodingError
        }
    }
    
    public func load(forKey key: String) async throws -> TokenInfo {
        var query = makeQuery(forKey: key)
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw TokenError.tokenNotFound
            }
            
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Status: \(status)"
            throw TokenError.storageError(description: message)
        }
        
        guard let data = item as? Data else {
            throw TokenError.unknown(message: "Keychain returned invalid data type")
        }
        
        do {
            return try decoder.decode(TokenInfo.self, from: data)
        } catch {
            throw TokenError.decodingError
        }
    }
    
    public func delete(forKey key: String) async throws {
        let query = makeQuery(forKey: key)
        let status = SecItemDelete(query as CFDictionary)
        
        // 성공 또는 항목 없음은 성공으로 간주
        guard status == errSecSuccess || status == errSecItemNotFound else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "Status: \(status)"
            throw TokenError.storageError(description: message)
        }
    }
}

/// 메모리 내 토큰 저장소 (테스트용)
public actor InMemoryTokenStorage: TokenStorage {
    private var storage: [String: Data] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    
    public init() {}
    
    public func save(tokenInfo: TokenInfo, forKey key: String) async throws {
        do {
            let data = try encoder.encode(tokenInfo)
            storage[key] = data
        } catch {
            throw TokenError.encodingError
        }
    }
    
    public func load(forKey key: String) async throws -> TokenInfo {
        guard let data = storage[key] else {
            throw TokenError.tokenNotFound
        }
        
        do {
            return try decoder.decode(TokenInfo.self, from: data)
        } catch {
            throw TokenError.decodingError
        }
    }
    
    public func delete(forKey key: String) async throws {
        storage.removeValue(forKey: key)
    }
    
    /// 모든 데이터 삭제 (테스트용)
    public func clearAll() async { // Add async keyword
        storage.removeAll()
    }
}
