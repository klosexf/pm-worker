//  StreamProbe.swift
//  临时探针（2026-09-18）：流式吞吐定位——LLMClient 网络侧到达节奏 vs SessionStore
//  App 侧消费/发布节奏，分离测量以定位「裸测 ~74 tok/s vs 应用内 ~24 tok/s」的
//  差距归属。结论回收后本文件整体删除，不是产品功能。

import Foundation

nonisolated final class StreamProbe {
    static let shared = StreamProbe()

    private let lock = NSLock()
    private let storageURL: URL

    private init() {
        storageURL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
            .appendingPathComponent("pm-worker", isDirectory: true)
            .appendingPathComponent("probe_stream.jsonl")
    }

    /// 追加一行 JSONL（任何失败静默——探针绝不影响产品路径）。
    func append(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: storageURL.path) {
                FileManager.default.createFile(atPath: storageURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: storageURL)
            defer { try? handle.close() }
            try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.write(contentsOf: Data([0x0A]))
        } catch {}
    }
}
