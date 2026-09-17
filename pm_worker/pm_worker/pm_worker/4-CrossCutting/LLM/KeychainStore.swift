//
//  KeychainStore.swift
//  pm_worker
//
//  API Key 存取（design.md §7.3 BYOK）：Key 走 Keychain，不落明文、不入 Git。
//

import Foundation
import Security

/// nonisolated：纯 Security.framework 调用 + NSLock 保护的进程内 Key 缓存。
nonisolated enum KeychainStore {
    private static let service = "com.xiaofengchen.pm-worker.byok"

    /// 进程内缓存：read 成功后驻留内存，set/delete 时失效。
    /// 动机：重建把磁盘上的 .app 换掉后，仍在运行的旧进程会被 securityd
    /// 整体拒绝读钥匙串（OSStatus -25293，且授权弹窗被压制，进程内无法
    /// 自愈，官方出路只有退出重开）。此前 streamChat 每次发送都重读
    /// 钥匙串，导致并行构建后旧进程一发言就撞死。缓存后仅进程内首次
    /// 读取走钥匙串，旧进程可照常工作到退出；安全性无新增暴露——Key
    /// 本就随每次请求进入内存。
    /// 代价：外部工具（钥匙串访问/CLI）绕过本进程改值时读不到新值；
    /// 本进程的 set/delete 均同步失效缓存，正常路径不受影响。
    private static let cacheLock = NSLock()
    private nonisolated(unsafe) static var cache: [String: String] = [:]

    private static func cachedValue(forKey key: String) -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cache[key]
    }

    private static func storeCached(_ value: String?, forKey key: String) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let value {
            cache[key] = value
        } else {
            cache.removeValue(forKey: key)
        }
    }

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
        storeCached(value, forKey: key)
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
        if let cached = cachedValue(forKey: key) { return .found(cached) }
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
        storeCached(value, forKey: key)
        return .found(value)
    }

    /// 便捷读取：notFound 与 accessFailed 都归 nil（调用方只需要「有没有值」时用）。
    static func get(_ key: String) -> String? {
        if case .found(let value) = read(key) { return value }
        return nil
    }

    static func delete(_ key: String) {
        storeCached(nil, forKey: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
