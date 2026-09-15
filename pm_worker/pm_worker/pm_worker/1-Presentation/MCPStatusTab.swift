//
//  MCPStatusTab.swift
//  pm_worker
//
//  MCP 状态页（M5 Task 5.2，design.md §7.1）：服务开关 / 已暴露 tool 列表 /
//  最近调用日志（mcp_tasks）/「复制 Claude Desktop 配置」按钮。
//
//  说明：MCP server 由外部客户端（Claude Desktop / Cursor）拉起独立无头实例，
//  不在 GUI 进程内常驻——「开关」控制的是无头实例是否允许启动（关闭则拉起即退），
//  调用日志从 ~/PMAgent/index.sqlite 跨进程读取（WAL，短连接）。
//  视觉还原 Wave 3-B：DSSwitch / dsCard 卡片分组 / 状态色令牌。
//

import SwiftUI
import GRDB
import MCP

// MARK: - 调用日志行模型

/// mcp_tasks 行的值投影（跨异步 / 视图层安全）。
struct MCPTaskRow: Identifiable, Equatable {
    var id: String
    var type: String
    var status: String
    var project: String
    var version: String
    var createdAt: String
    /// failed 时的错误摘要（result JSON 的 error 字段）。
    var error: String?

    /// 状态人话文案（DSTag 展示）：pending=排队 / running=执行中 / done=完成 / failed=失败。
    var statusText: String {
        switch status {
        case "pending": "排队中"
        case "running": "执行中"
        case "done": "完成"
        case "failed": "失败"
        default: status
        }
    }

    /// 状态徽章变体（DS 令牌）：done=success / failed=danger / pending=neutral / running=brand。
    var tagVariant: DSTag.Variant {
        switch status {
        case "pending": .neutral
        case "running": .brand
        case "done": .success
        case "failed": .danger
        default: .neutral
        }
    }
}

// MARK: - 状态页

struct MCPStatusTab: View {
    /// 服务开关（MCPServerRunner.enabledKey；未设置 = 允许）。
    @AppStorage(MCPServerRunner.enabledKey) private var serverEnabled = true

    @State private var tasks: [MCPTaskRow] = []
    @State private var logError: String?
    @State private var toast: DSNotifMessage?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.s24) {
                serviceSection
                configSection
                toolsSection
                logSection
            }
            .padding(DS.Spacing.s24)
        }
        .dsNotifCenter($toast)
        .task { reloadTasks() }
    }

    // MARK: - 服务开关

    private var serviceSection: some View {
        section(
            "MCP Server",
            footer: "关闭后 Claude Desktop / Cursor 拉起本 App（--mcp-server）会立即退出；已在运行的会话不受影响。服务名 \(MCPServerRunner.serverName) v\(MCPServerRunner.serverVersion)，stdio 传输。"
        ) {
            settingsRow("允许 MCP 客户端拉起服务") {
                DSSwitch(isOn: $serverEnabled)
            }
        }
    }

    // MARK: - 复制 Claude Desktop 配置

    private var configSection: some View {
        section(
            "接入配置",
            footer: "粘贴到 Claude Desktop → Settings → Developer → Edit Config（claude_desktop_config.json），或 Cursor 的 MCP 设置。"
        ) {
            settingsRow("可执行文件") {
                Text(executablePath)
                    .font(DS.Font.monoSM)
                    .foregroundStyle(Color.ink900)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 320, alignment: .trailing)
            }

            settingsDivider()

            HStack {
                Spacer()
                Button("复制 Claude Desktop 配置") {
                    copyConfig()
                }
                .buttonStyle(.ds(.brand))
                .disabled(executablePath.isEmpty)
            }
            .padding(.vertical, DS.Spacing.s10)

            settingsDivider()

            // 原型 .ds-code：overlay-l1 底 + neutral-l1 边 + mono
            Text(MCPServerRunner.claudeConfigJSON(executablePath: executablePath))
                .font(DS.Font.monoSM)
                .foregroundStyle(Color.ink500)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DS.Spacing.s10)
                .background(Color.overlayL1, in: RoundedRectangle(cornerRadius: DS.Radius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.lg)
                        .strokeBorder(Color.borderL1, lineWidth: 1)
                )
                .padding(.vertical, DS.Spacing.s10)
        }
    }

    private var executablePath: String {
        Bundle.main.executableURL?.path ?? ""
    }

    private func copyConfig() {
        let json = MCPServerRunner.claudeConfigJSON(executablePath: executablePath)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(json, forType: .string)
        toast = DSNotifMessage(variant: .success, title: "已复制到剪贴板")
    }

    // MARK: - 工具列表

    private var toolsSection: some View {
        section(
            "已暴露工具（\(MCPServerRunner.toolDefinitions.count) 个）",
            footer: "生成类工具为异步任务：提交即回 task_id，客户端用 get_task 轮询；确认闸口与 App 内一致（澄清要点表.md / confirmed.json）。"
        ) {
            ForEach(Array(MCPServerRunner.toolDefinitions.enumerated()), id: \.element.name) { index, tool in
                if index > 0 {
                    settingsDivider()
                }
                VStack(alignment: .leading, spacing: DS.Spacing.s3) {
                    Text(tool.name)
                        .font(DS.Font.monoSM.weight(.semibold))
                        .foregroundStyle(Color.ink900)
                    Text(tool.description ?? "")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, DS.Spacing.s8)
            }
        }
    }

    // MARK: - 调用日志

    private var logSection: some View {
        section(
            "最近调用（异步任务，\(tasks.count) 条）",
            footer: "读取 ~/PMAgent/index.sqlite 的 mcp_tasks 表（跨进程 WAL 读，重启后残留任务自动判 failed）。"
        ) {
            if let logError {
                Text(logError)
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.statusError)
                    .padding(.vertical, DS.Spacing.s10)
            } else if tasks.isEmpty {
                DSEmptyState(
                    icon: .barList,
                    title: "暂无调用记录",
                    description: "MCP 客户端发起调用后，这里会展示最近 50 条异步任务。"
                )
            } else {
                // 调用日志表（原型 .ds-table：表头大写 tertiary · 行底 L1 分隔 · 首列高亮）
                DSTable(columns: [
                    DSTableColumn("工具", width: 190),
                    DSTableColumn("状态", width: 96),
                    DSTableColumn("项目", width: 110),
                    DSTableColumn("版本", width: 110),
                    DSTableColumn("创建时间"),
                ]) {
                    ForEach(tasks) { task in
                        GridRow {
                            DSTableCell {
                                VStack(alignment: .leading, spacing: DS.Spacing.s2) {
                                    Text(task.type)
                                        .font(DS.Font.monoSM)
                                        .foregroundStyle(Color.ink900)
                                    if let error = task.error {
                                        Text(error)
                                            .font(DS.Font.bodyXS)
                                            .foregroundStyle(Color.statusError)
                                            .lineLimit(2)
                                    }
                                }
                            }
                            DSTableCell {
                                DSTag(title: task.statusText, variant: task.tagVariant)
                            }
                            DSTableText(task.project)
                            DSTableText(task.version)
                            DSTableText(task.createdAt, mono: true)
                        }
                    }
                }
                .padding(.vertical, DS.Spacing.s10)
            }

            settingsDivider()

            HStack {
                Spacer()
                Button("刷新") { reloadTasks() }
                    .buttonStyle(.ds(.secondary, size: .sm))
            }
            .padding(.vertical, DS.Spacing.s10)
        }
    }

    // MARK: - 区块与行（Xcode 偏好面板形制，与 SettingsDialog 同构）

    private func section<Content: View>(
        _ title: String,
        footer: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s6) {
            Text(title)
                .monospacedDigit()
                .font(DS.Font.bodySMStrong)
                .foregroundStyle(Color.ink500)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let footer {
                Text(footer)
                    .font(DS.Font.bodyXS)
                    .foregroundStyle(Color.ink500)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, DS.Spacing.s4)
            }
        }
    }

    /// 设置行：左标签 + 右控件（与 SettingsDialog.settingsRow 同范式）。
    private func settingsRow<Content: View>(
        _ label: String,
        @ViewBuilder trailing: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: DS.Spacing.s16) {
            Text(label)
                .font(DS.Font.bodyMD)
                .foregroundStyle(Color.ink900)
            Spacer(minLength: DS.Spacing.s16)
            trailing()
        }
        .padding(.vertical, DS.Spacing.s10)
    }

    private func settingsDivider() -> some View {
        DSDivider()
    }

    /// 短连接读取最近 50 条任务（不持有长连接，避免与无头 server 进程抢写锁）。
    private func reloadTasks() {
        guard let database = try? AppDatabase() else {
            logError = "索引库不可读（~/PMAgent/index.sqlite）"
            return
        }
        do {
            let rows = try database.dbQueue.read { db in
                try Row.fetchAll(
                    db,
                    sql: """
                    SELECT id, type, status, payload, result, created_at
                    FROM mcp_tasks ORDER BY created_at DESC, rowid DESC LIMIT 50
                    """
                )
            }
            tasks = rows.map { row in
                let payloadText: String = row["payload"] ?? "{}"
                let payload = (try? JSONSerialization.jsonObject(
                    with: Data(payloadText.utf8)
                )) as? [String: Any]
                let resultText: String? = row["result"]
                let error = resultText.flatMap { text -> String? in
                    guard let object = try? JSONSerialization.jsonObject(
                        with: Data(text.utf8)
                    ) as? [String: Any] else { return nil }
                    return object["error"] as? String
                }
                return MCPTaskRow(
                    id: row["id"] ?? "",
                    type: row["type"] ?? "",
                    status: row["status"] ?? "",
                    project: payload?["project"] as? String ?? "默认",
                    version: payload?["version"] as? String ?? "unversioned",
                    createdAt: row["created_at"] ?? "",
                    error: error
                )
            }
            logError = nil
        } catch {
            logError = "读取失败：\(error.localizedDescription)"
        }
    }
}
