//
//  DraftMergeCard.swift
//  pm_worker
//
//  草稿预演合并卡（B2）：变更池内的草稿提案处置行。
//  展示草稿推进位置与产物文件清单（覆盖警告），动作 = 合并入主线 / 放弃草稿。
//  合并是版本级结构写：要求当前选中即目标版本（按钮禁用态引导切换）。
//

import SwiftUI

struct DraftMergeCard: View {
    @EnvironmentObject private var model: AppModel
    let item: ChangeItem
    let project: String
    let version: String
    let onResolved: () -> Void

    private var proposal: ChangeProposalRecord { item.proposal }

    /// 草稿推进位置（提案登记的终点阶段）。
    private var draftStage: PipelineRun.Stage? {
        proposal.draftStage.flatMap { PipelineRun.Stage(rawValue: $0) }
    }

    private var stageLabel: String {
        switch draftStage {
        case .structure: "② 结构"
        case .prototype: "③ 原型"
        case .prd: "④ PRD"
        default: "① 澄清"
        }
    }

    /// 草稿产物文件清单（相对路径；提案目录按会话 id 分槽；两侧统一解析
    /// 符号链接防 /var → /private/var 前缀错位）。
    private var draftFiles: [String] {
        guard let sid = proposal.draftSessionId else { return [] }
        let root = PMAgentStore.artifactRoot(
            project: project, version: version, proposalSessionId: sid
        )
        let fm = FileManager.default
        let rootPath = URL(fileURLWithPath: root.path).resolvingSymlinksInPath().path
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        ) else { return [] }
        return enumerator.compactMap { url -> String? in
            guard let url = url as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { return nil }
            let resolved = url.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(rootPath + "/") else { return nil }
            return String(resolved.dropFirst(rootPath.count + 1))
        }
    }

    /// 合并入口要求当前选中即目标版本（合并读活引擎推进主线状态机）。
    private var canMergeHere: Bool {
        model.pipeline.project == project && model.pipeline.version == version
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s10) {
            HStack(spacing: DS.Spacing.s6) {
                DSTag(title: "草稿预演", variant: .neutral)
                DSTag(title: stageLabel, variant: .neutral)
                if let sid = proposal.draftSessionId,
                   SessionStore.isDraftSession(
                       project: project, version: version, sessionId: sid
                   ) {
                    Text("预演中")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                }
                Spacer(minLength: 0)
            }

            Text(proposal.idea)
                .font(DS.Font.headingXS)
                .foregroundStyle(Color.ink900)
                .dsBodyType(size: 14)
                .lineLimit(3)

            // 覆盖清单：合并会写入主线的文件（相对路径逐条列出，先看后合）
            if !draftFiles.isEmpty {
                VStack(alignment: .leading, spacing: DS.Spacing.s4) {
                    Text("合并将写入主线：")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                    ForEach(draftFiles, id: \.self) { rel in
                        HStack(alignment: .top, spacing: DS.Spacing.s6) {
                            DSIcon(.dot, size: 5)
                                .foregroundStyle(Color.ink300)
                                .padding(.top, 6)
                            Text(rel)
                                .font(DS.Font.bodySM)
                                .foregroundStyle(Color.ink700)
                                .dsBodyType(size: 13)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            HStack(spacing: DS.Spacing.s8) {
                if !canMergeHere {
                    Text("切换到「\(project) · \(version)」的会话后可合并")
                        .font(DS.Font.bodyXS)
                        .foregroundStyle(Color.ink500)
                }
                Spacer(minLength: 0)
                Button("放弃草稿") {
                    model.abandonDraftProposal(item, project: project, version: version)
                    onResolved()
                }
                .buttonStyle(.ds(.ghost))
                Button("合并入主线") {
                    if let error = model.mergeDraftProposal(item, project: project, version: version) {
                        model.notif = DSNotifMessage(
                            variant: .error, title: "合并失败", description: error
                        )
                    }
                    onResolved()
                }
                .buttonStyle(.ds(.primary, size: .sm))
                .disabled(!canMergeHere || draftFiles.isEmpty)
            }
        }
        .padding(DS.Spacing.s16)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .fill(Color.surfaceSecondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg)
                .strokeBorder(Color.borderL1, lineWidth: 1)
        )
    }
}
