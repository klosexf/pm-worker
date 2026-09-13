//
//  GitSnapshot.swift
//  pm_worker
//
//  Git 后台快照（Task 3.7）：actor 天然串行互斥，绝不并发跑 git。
//  快照在每次闸口确认后由主 agent（AppModel）调用——本文件只提供 API。
//  commit 身份固定为 PM Copilot（GIT_AUTHOR/COMMITTER 环境变量，不依赖全局 git config）；
//  无变更（nothing to commit）静默返回 nil。
//

import Foundation

/// Git 快照队列：actor 保证全局串行（同一时刻至多一个 git 进程在跑）。
actor GitSnapshotQueue {
    /// 共享队列（AppModel 可直接持有或用此单例）；测试可另行独立实例化。
    static let shared = GitSnapshotQueue()

    init() {}

    /// 对项目目录做一次快照：git init（若缺 .git）→ git add -A → git commit -m。
    ///
    /// - Returns: 新 commit 的 hash；nil 表示无变更（nothing to commit，静默幂等）。
    /// - Throws: git 不可用 / init·add·commit 非预期失败（附 git 输出）。
    func snapshot(projectDir: URL, message: String) throws -> String? {
        let fm = FileManager.default

        if !fm.fileExists(atPath: projectDir.appendingPathComponent(".git").path) {
            let initResult = try runGit(["init"], in: projectDir)
            guard initResult.code == 0 else {
                throw Self.failure("git init 失败：\n\(initResult.output)", projectDir)
            }
        }

        let addResult = try runGit(["add", "-A"], in: projectDir)
        guard addResult.code == 0 else {
            throw Self.failure("git add 失败：\n\(addResult.output)", projectDir)
        }

        let commitResult = try runGit(["commit", "-m", message], in: projectDir)
        if commitResult.code != 0 {
            // 无变更 → 静默 nil（幂等重试不算失败）
            if commitResult.output.localizedCaseInsensitiveContains("nothing to commit") {
                return nil
            }
            throw Self.failure("git commit 失败：\n\(commitResult.output)", projectDir)
        }

        let hashResult = try runGit(["rev-parse", "HEAD"], in: projectDir)
        guard hashResult.code == 0 else {
            throw Self.failure("git rev-parse 失败：\n\(hashResult.output)", projectDir)
        }
        let hash = hashResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return hash.isEmpty ? nil : hash
    }

    // MARK: - Private

    private nonisolated static let gitName = "PM Copilot"
    private nonisolated static let gitEmail = "pm-copilot@pmworker.local"

    private nonisolated static func failure(_ message: String, _ dir: URL) -> NSError {
        NSError(
            domain: "GitSnapshotQueue", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(message)\n目录：\(dir.path)"]
        )
    }

    /// 同步跑一条 git 命令（stdout+stderr 合并；actor 内串行，无并发）。
    private func runGit(_ arguments: [String], in directory: URL) throws -> (code: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        // 固定提交身份：不读用户全局 git config
        environment["GIT_AUTHOR_NAME"] = Self.gitName
        environment["GIT_AUTHOR_EMAIL"] = Self.gitEmail
        environment["GIT_COMMITTER_NAME"] = Self.gitName
        environment["GIT_COMMITTER_EMAIL"] = Self.gitEmail
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
