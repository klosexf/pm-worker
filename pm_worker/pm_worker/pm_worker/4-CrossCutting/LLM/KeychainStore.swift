//
//  KeychainStore.swift
//  pm_worker
//
//  API Key 存取（design.md §7.3 BYOK）：Key 走 Keychain，不落明文、不入 Git。
//

import Foundation
import Security

/// nonisolated：纯 Security.framework 调用，不持有可变状态。
nonisolated enum KeychainStore {
    private static let service = "com.xiaofengchen.pm-worker.byok"

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)

        var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status): "Keychain 操作失败（OSStatus \(status)）"
            }
        }
    }

    /// 写入（存在则更新）。
    static func set(_ value: String, forKey key: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unexpectedStatus(addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// 读取三态：「不存在」与「访问失败」必须区分——沙盒/并行构建重签等环境会把
    /// 读取整条拒绝（item 完好），若混为 nil，UI 会把失败显示成「未配置」，
    /// 且空值清理路径可能把真 Key 删掉（2026-09-13 Key「消失」事故根因）。
    nonisolated enum KeychainRead {
        case found(String)
        case notFound
        case accessFailed(OSStatus)
    }

    static func read(_ key: String) -> KeychainRead {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            return status == errSecItemNotFound ? .notFound : .accessFailed(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            return .notFound
        }
        return .found(value)
    }

    /// 便捷读取：notFound 与 accessFailed 都归 nil（调用方只需要「有没有值」时用）。
    static func get(_ key: String) -> String? {
        if case .found(let value) = read(key) { return value }
        return nil
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
