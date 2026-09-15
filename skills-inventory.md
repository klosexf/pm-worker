# PM Copilot · 技能库初始内容清单

> 版本：v1.4 · 日期：2026-09-14 · 状态：V2 P1 已落地
>
> **v1.4 变更**：V2 P1 批次落地（2026-09-14 用户裁决启动）——追加 3 个 skill（S19 OST / S20-S21 调研链，见 §4.3 P1 标注），当前总量 **21**；`incoming-request-advisor` 裁决为**内建澄清 prompt**（确定性注入，不独立成卡，见 §5 已裁决）。
>
> 对应 [design.md](design.md) §15 开放问题 1「技能库初始内容边界」的裁决稿。
> 原则：首批 **14 个 skill**，覆盖五阶段流水线各环节；E11（未命中 skill 的正文不进上下文）的演示效果优先于数量。
>
> **v1.3 变更**：追加 1 个设计型 skill（S18，改写自 touchine-ojo/OJO-Design-Skills、Leonxlnx/taste-skill、oil-oil/draw-ui，均 MIT ✅）——高保真原型设计，配套原型阶段提示词升级（灰盒线框 → 彩色真实效果图），当前总量 **18**，见 §2.7（2026-09-13 用户确认）。
>
> **v1.2 变更**：追加 3 个流程型 skill（S15-S17，改写自 obra/superpowers，MIT ✅）——想法打磨对话 / 任务拆解与验收 / 证据先行门控，补齐「澄清对话收敛、里程碑任务拆解、完成判定口径」三类缺口，见 §2.6（2026-09-12 用户确认）。
>
> **v1.1 变更**：① front-matter 新增 `type`（component/interactive，决定命中后生效形态）与 `pitfalls`（结构化反模式，雷达规则确定性读取）两字段（2026-09-10 用户确认）；② §4.3 V2 候选池由平铺清单升级为**分级候选池**（基于 deanpeters 库 77 个 skill 全量内容审计：P1 补池 3 项 / P2 约 11 项 / 机制层 4 项 / 明确不进组）；③ §5 待确认 2（`best_for` 入 design.md §5.2）裁决通过，design.md v0.9.11 已同步（§5.2 schema + §5.3 skills 表 + §6.2 清单实例化）。

---

## 0. 决策摘要

| 决策项 | 结论 |
|---|---|
| 首批数量 | 14 个（11 个方法论 + 3 个流程型）；原 S15「PRD 质量清单」已裁决移入**规范路由**（见 §2.5） |
| 追加批（v1.4） | V2 P1 落地：+3 个（S19-S21，OST + 调研链），当前总量 21；`incoming-request-advisor` 内建澄清 prompt（见 §4.3 P1 / §5） |
| 追加批（v1.2） | +3 个流程型（S15-S17，改写自 obra/superpowers，MIT），见 §2.6 |
| 追加批（v1.3） | +1 个设计型（S18，改写自 OJO-Design-Skills / taste-skill / draw-ui，MIT），当前总量 18，见 §2.7 |
| 来源策略 | 公知方法论**自写**（KANO/RICE/JTBD 等不受版权保护）；流程型 skill 参照 anthropics（Apache-2.0）与 tarunccet/pm-skills（MIT）**改写**；deanpeters 库**只借鉴结构、不搬内容**（CC BY-NC-SA 4.0，与 MIT 不兼容） |
| front-matter 格式 | 六字段：`name / type / when_to_use / best_for / tags / pitfalls`——`best_for`（3-5 个典型场景短句，借鉴 deanpeters 检索友好设计）；`type` 与 `pitfalls` 为 v1.1 新增（机制见 §3.1） |
| 语言 | 中文正文 + 英文 tags（tags 同时编码进 embedding，双语提升中英 query 命中） |
| 单 skill 正文长度 | 软上限 1500 字（约 1k token）——渐进式披露下正文全量注入，超限会被 Context Builder 裁剪 |

---

## 1. 调研结论：GitHub 上的产品 Skill 库

| 仓库 | 许可 | 规模 | 结论 |
|---|---|---|---|
| [anthropics/knowledge-work-plugins](https://github.com/anthropics/knowledge-work-plugins) → `product-management` 插件 | Apache-2.0 ✅ | 8 skills：write-spec / competitive-brief / synthesize-research / product-brainstorming / roadmap-update / sprint-planning / metrics-review / stakeholder-update | **流程型 skill 的最佳参照**，工程化程度最高，可直接改写 |
| [tarunccet/pm-skills](https://github.com/tarunccet/pm-skills) | MIT ✅ | 100+ skills，9 个包（discovery / strategy / market-research / ai-product-management / gtm / analytics / execution / vibe-coding / guided-learning） | **方法论覆盖最全且许可干净**，strategy 包含 SWOT、五力、Lean Canvas、价值主张画布、Ansoff、定价策略、魔鬼代言人等 |
| [deanpeters/Product-Manager-Skills](https://github.com/deanpeters/Product-Manager-Skills) | ⚠️ CC BY-NC-SA 4.0 | 77 skills，三层结构（workflow 20 / interactive 29 / component 28） | **只学结构与写法**：front-matter 含 `best_for` / `scenarios`；SKILL.md 章节（Purpose / Input / Key Concepts / Application / Examples / Pitfalls / References）是自写时的模板；**77 个 skill 全量内容审计已完成（2026-09-10）**，内容缺口与机制借鉴项落 §4.3 分级候选池 |
| [mich3333/pm-claude-skills](https://github.com/mich3333/pm-claude-skills) | 见仓库 | 90 skills（PM 相关 33 个） | 备选，质量参差，仅补漏时查 |
| 方法论单体（JTBD / Hooked UX / CRO） | 各异 | — | Hooked（习惯回路）适合留存类产品，**V2 再入**；首批不加 |

---

## 2. 首批 14 个 Skill 清单（按五阶段映射）

### ① 澄清阶段（4 个）

| # | skill 名 | 类型 | 内容要点 | 来源 |
|---|---|---|---|---|
| S1 | `problem-statement` | 方法论 | 问题定义画布：用户是谁 / 痛点是什么 / 现有替代方案 / 为什么现在解决。防止「解决错误的问题」 | tarunccet（MIT），自写中文版 |
| S2 | `five-whys` | 方法论 | 5 Whys 根因追问法：从表面诉求挖到本质动机。苏格拉底式澄清的理论支撑 | 公知，自写 |
| S3 | `jtbd` | 方法论 | Jobs-to-be-Done：用户「雇佣」产品完成什么任务，功能诉求背后的动机拆解 | 公知，自写 |
| S4 | `mom-test-interview` | 方法论 | Mom Test 访谈原则：问过去的行为而非未来的意愿，防「礼貌性谎言」污染澄清结论 | 公知，自写 |

### ② 调研阶段（4 个）

| # | skill 名 | 类型 | 内容要点 | 来源 |
|---|---|---|---|---|
| S5 | `competitive-brief` | 流程 | 竞品简报结构：定位 / 核心功能 / 差异点 / 可借鉴 / 风险——与 ② 环输出 schema 直接对齐 | anthropics（Apache-2.0），改写 |
| S6 | `swot-analysis` | 方法论 | 优势/劣势/机会/威胁四象限，竞品与自身双向分析 | tarunccet（MIT），自写中文版 |
| S7 | `porters-five-forces` | 方法论 | 五力模型：供应商/买方/替代品/新进入者/行业竞争，判断赛道吸引力 | tarunccet（MIT），自写中文版 |
| S8 | `tam-sam-som` | 方法论 | 市场规模三层估算法：自上而下 / 自下而上 / 类比，标注每步假设的置信度 | 参照 deanpeters 思路自写 |

### ③ PRD 阶段（4 个）

| # | skill 名 | 类型 | 内容要点 | 来源 |
|---|---|---|---|---|
| S9 | `kano-model` | 方法论 | 基本型/期望型/兴奋型需求分类 + 问卷判定法。design.md 已点名的首发 skill | 公知，自写 |
| S10 | `rice-prioritization` | 方法论 | Reach × Impact × Confidence ÷ Effort 排序；design.md 中 ③ 环模板「命中 RICE 则按 RICE 排序」的执行依据 | 公知，自写 |
| S11 | `user-story` | 方法论 | Mike Cohn 格式（As a… I want… So that…）+ Gherkin 验收标准（Given-When-Then）+ 反模式清单 | 参照 anthropics write-spec 与公知，自写 |
| S12 | `working-backwards` | 方法论 | Amazon 工作法：先写新闻发布会再写 PRD，倒逼价值前置 | 公知，自写 |

### ④ 原型阶段（1 个）

| # | skill 名 | 类型 | 内容要点 | 来源 |
|---|---|---|---|---|
| S13 | `poc-probe-selection` | 流程 | 根据假设类型与风险等级选原型形态（灰盒线框 / 关键流程可点击 / 仿真界面）；对应 ④ 环「灰盒线框风即可」的度选择依据 | 参照 deanpeters pol-probe 思路自写 |

### ⑤ 评审阶段（1 个）

| # | skill 名 | 类型 | 内容要点 | 来源 |
|---|---|---|---|---|
| S14 | `devils-advocate` | 方法论 | 魔鬼代言人审查法：系统性列出最强反方论点。与自研毒舌评审人格互补——评审 Agent 的人格写死在 prompt，此 skill 提供审查框架供其调用 | tarunccet（MIT），自写中文版 |

### 2.5 移入规范路由的文档（非 skill，已裁决）

| 文档 | 落点 | 内容要点 | 裁决理由 |
|---|---|---|---|
| `prd-review-rubric` | `templates/prd-review-rubric.md`，规范路由确定性读取最新版 | PRD 六维评审清单（需求完整性 / 方案合理性 / 用户价值 / 技术可行性 / 文档质量 / 原型一致性），每维的典型扣分点与判定标准——⑤ 环打分的知识底座 | 本质是**评审模板**而非方法论：版本间会演进（打分维度、判定标准随产品成熟度调整），且⑤环**每次必读**、不能漏——语义检索「可能不命中」的机制与这两个特性天然冲突。「过期规范比没有规范更危险」「模板类文档走确定性路由」两条原则均适用（design.md §4 刻意设计 2） |

### 2.6 追加批（v1.2，2026-09-12：+3 个，改写自 obra/superpowers）

> 来源审计：[obra/superpowers](https://github.com/obra/superpowers)（Jesse Vincent，MIT ✅）共 14 个 agent 工程技能，其中 3 个与流水线环节直接对口，改写为 PM 语境流程型 component 落库；其余 11 个为纯工程执行向（git worktree / 分支收尾 / 子代理编排 / 元技能），不引入。与 §4.3「明确不进」的 Workflow 型排除不冲突：本批改写的是**方法论**（对话怎么收敛、任务怎么拆、完成怎么判定），不复刻四阶段主线流程本身。同首批落全局库（`~/PMAgent/skills/`）。

| # | skill 名 | 类型 | 落点阶段 | 内容要点 | 来源 |
|---|---|---|---|---|---|
| S15 | `idea-refinement` 想法打磨对话 | 流程 | ① 澄清 | 一次一问收敛 → 2-3 方案带权衡 → 设计分节确认 → 自审落盘才动手。补「澄清对话节奏」缺口，与 S1 问题定义画布互补（S1 管问什么，本卡管怎么收敛） | obra/superpowers#brainstorming（MIT），改写 |
| S16 | `task-decomposition` 任务拆解与验收 | 流程 | ③ PRD | 假设执行者零上下文：结构先行 → 依赖排序 → 单动作粒度 → 每任务自带验收与验证步骤。补「里程碑/实施计划章节写法」缺口 | obra/superpowers#writing-plans（MIT），改写 |
| S17 | `evidence-gated-completion` 证据先行门控 | 流程 | ⑤ 评审 | 没有新鲜验证证据不得宣称完成；验收标准须可判定；门控按证据不按叙述。与 prd-review-rubric（§2.5）互补：rubric 管审什么，本卡管完成的判定口径 | obra/superpowers#verification-before-completion（MIT），改写 |

### 2.7 追加批（v1.3，2026-09-13：+1 个设计型，原型阶段升级配套）

> 背景：用户裁决原型阶段输出从「灰盒线框风」升级为「高保真彩色 UI 效果图」（`AgentPrompts.prototype` 硬约束与 stageChecklist 已同步改）。本卡整合三个开源设计技能仓库的可执行规则（设计令牌先行、60/30/10 配色、中性色微染、AI 紫封禁、组件四态、真实数据感、「AI 味」五项自检），限定单文件 HTML 零外部依赖语境。落全局库（`~/PMAgent/skills/`）。

| # | skill 名 | 类型 | 落点阶段 | 内容要点 | 来源 |
|---|---|---|---|---|---|
| S18 | `hi-fi-prototype` 高保真原型设计 | 流程 | ④ 原型 | 设计令牌先行 → 60/30/10 配色与中性色微染 → 排印纪律与组件四态 → 真实感素材（内联 SVG 场景块/有机数据）→「AI 味」五项自检。与 S13 形态选择互补：S13 管画到什么精度，本卡管高保真档怎么画好 | touchine-ojo/OJO-Design-Skills、Leonxlnx/taste-skill、oil-oil/draw-ui（均 MIT），改写 |

---

## 3. 统一 front-matter 模板

```markdown
---
name: KANO 模型
type: component                  # component | interactive，机制见 §3.1
when_to_use: 需求优先级排序、区分基本型/期望型/兴奋型需求、判断功能是否「不做会死」时
best_for:
  - 新产品从 0 到 1 砍需求清单
  - 功能池超过 15 条需要分层
  - 用户明确说「没有 X 我就不用」
tags: [prioritization, methodology, kano, 优先级]
pitfalls:                        # 结构化反模式：命名失败模式（命名 + 成因/后果一句话）
  - 全标基本型：未过目标用户画像，把期望型误标为基本型
  - 兴奋型排最高优先：兴奋型缺失不致命，不应挤占基本型资源
---
（正文 ≤1500 字：是什么 / 何时用 / 步骤 / 反模式 / 一个例子）
```

**正文章节结构**（借鉴 deanpeters，自写时统一）：
1. **Purpose**——解决什么问题，一段话
2. **步骤**——Agent 可直接执行的编号流程
3. **反模式**——命名过的失败模式（「礼貌性谎言」「解决错误的问题」…），这是评审 skill 的扣分点来源；**每条须与 front-matter `pitfalls` 对应**（pitfalls 是其可路由摘要，详细版留正文）
4. **一个例子**——健身 App 场景贯穿（与 design.md 示例项目一致）

### 3.1 新增字段机制（v1.1）

**`type`（技能形态，决定命中后怎么生效）**：
- `component` → 命中后**注入正文**（现行机制不变；首批 14 个全部为 component）
- `interactive` → 命中后**触发问诊式流程**：问 3-5 个上下文问题 → 给带「何时用我」理由的编号建议 → 用户选路径 → 执行中持续解释 why（借鉴 deanpeters 的 Adaptive Decision Ladder，交互回路与澄清 Agent 同款）。**V2 预留，首批不启用**——但其问诊模式作为机制借鉴落 §4.3 机制层

**`pitfalls`（雷达信号源，为什么必须在 front-matter）**：
- 反模式若只存在于正文，读取依赖语义检索——**未命中 = 雷达漏检**，对哨兵机制是致命的（漏项雷达防的就是「没想到要检查这个」，而「没想到用这个 skill」和「没想到检查这个反模式」高度相关：越是不该漏的场景越容易漏）
- 读取路径 = **规则路由确定性读取**（与 §2.5 `prd-review-rubric` 走规范路由同一原则的延伸）：自评审时按「当前阶段」读取该阶段相关技能的**全部** pitfalls，实例化进本阶段自检清单（design.md §6.2 清单实例化机制），**不依赖语义命中**
- 与正文的关系：pitfalls 是正文「反模式」章节的可路由摘要；入库校验「pitfalls 每条在正文有对应展开」（§4 纪律 5）
- `type` / `pitfalls` 均**不编码进 embedding**（embedding 范围仍为 name + when_to_use + best_for + tags 四字段，§4 纪律 1）

---

## 4. 入库纪律与验收

1. **写完即建索引**：每补一个 skill 跑一次索引重建（skills/ 扫描 → name + when_to_use + best_for + tags 四字段 embedding → upsert；`type` / `pitfalls` 入库不编码，见 §3.1），E11 用 KANO skill 做演示样本
2. **首批 14 个全部落 `~/PMAgent/skills/`（全局库）**：均为跨项目方法论，无项目级 skill；`prd-review-rubric` 不在此，落 `templates/`（见 §2.5）
3. **V2 候选池（分级，v1.1）**：见下方分级表
4. **来源标注**：每个 skill 正文尾部一行 `> 来源：自写 / 改写自 anthropics#write-spec (Apache-2.0) / 改写自 tarunccet/pm-skills#swot-analysis (MIT)`——开源合规可追溯
5. **pitfalls 入库校验（v1.1 新增）**：每条 pitfall 须在正文「反模式」章节有对应展开；每 skill pitfalls 建议 2-5 条（少了护不住雷达，多了稀释清单——超 5 条说明该拆 skill 或合并同类项）

### 4.3 V2 分级候选池（基于 deanpeters 库 77 个 skill 全量内容审计，2026-09-10）

> 审计前提：仅**参照自写**（CC BY-NC-SA 4.0 不搬内容）；同类方法论有 MIT / Apache-2.0 来源（tarunccet / anthropics）优先参照那边，deanpeters 只作为结构与方法参照。原 v1.0 平铺候选池已并入下列分级。

**P1 · V2 第一批补池（真实缺口，3 项）——✅ 已落地（2026-09-14，v1.4）**

| skill | 补的缺口 | 落点 | 落地状态 |
|---|---|---|---|
| `opportunity-solution-tree`（S19） | 首批与候选池均无 OST（Teresa Torres）：「诉求 → 机会 → 方案 → 验证」树，澄清阶段最缺的主干框架，JTBD（S3）的自然下游 | 澄清阶段 | ✅ `Resources/skills/opportunity-solution-tree.md` |
| `competitive-research-snapshot`（S20）+ `battle-card-builder`（S21） | **调研链**：前者产物 schema 被后者消费，「调研变节奏而非一次性 deck」——FR3 从 competitive-brief 单点升级为链 | 调研分支（FR3） | ✅ `Resources/skills/competitive-research-snapshot.md` + `battle-card-builder.md` |
| `incoming-request-advisor` | 含混请求 → 「字面诉求 vs 真实 JTBD」结构化拆解——澄清 Agent 每轮行为的知识底座；**可内建进澄清 prompt 而非独立 skill**，V2 时二选一 | 澄清阶段（FR2） | ✅ 裁决内建：`AgentPrompts.clarify` 约束 7「含混请求拆解」，每轮确定性注入 |

**P2 · V2 第二批（按需补池，约 11 项）**

新增候选（参照 deanpeters 结构自写）：
- `epic-hypothesis`——epic 写成可验证假设（目标用户 / 预期结果 / 验证方法），与「假设态注入」机制同源
- `user-story-splitting`——Richard Lawrence 拆分模式，PRD stories 章节深化
- `proto-persona`——快速工作画像，澄清阶段 personas 输出前置
- `pestel-analysis`——宏观六力，补 SWOT / 五力之外的外部维度
- `positioning-statement`——Geoffrey Moore 模板，调研 → PRD 差异化章节的桥
- `derisk-measurement-advisor`——DUFV×PESTEL 降险测量（该测什么来降险）——**风险登记册终态沉淀「校准卡」的最合适知识底座候选**（与 FR6 闭环直接挂接）
- `recommendation-canvas`——AI 产品创意评估（目标用户扩展至 AI PM 时再加）

原 v1.0 候选池保留项（并入 P2，deanpeters 有参照形态）：
- `user-story-mapping`（component + workshop 两形态可参照）、`stakeholder-mapping`（三件套 identification → mapping → engagement 按套参考）、`lean-ux-canvas`（顶替原「Lean Canvas」——假设暴露与「假设态标注」呼应）、价值主张画布

**机制层（不作为 skill 入库——偷机制不偷内容）**

| 借鉴对象 | 机制 | 落点 |
|---|---|---|
| `prioritization-advisor` / `intel-discipline-advisor` | Adaptive Decision Ladder：问 3-5 个上下文问题 → 带理由编号建议 → 选路径执行 | 技能路由与澄清 Agent 的问诊模式（即 §3.1 interactive 型的呈现范本） |
| `autonomous-investigation` | Fact / Inference / Assumption 标签 + 置信度堆叠 | 调研产物 schema（FR3 输出格式） |
| `pm-skill-creator` | 引导用户造 skill 的对话流程 | FR8 完整形态（用户自定义技能）的功能范本 |
| `workshop-facilitation` | workshop 节奏控制（单步多轮、选项、进度追踪） | interactive 型技能呈现层的通用底座 |

**明确不进（防范围蔓延，替代原平铺排除语义）**

- **职业转型组**：director-readiness / vp-cpo-readiness / executive-onboarding / product-sense-interview / altitude-horizon（与四阶段无关）
- **EOL 组**（6 个）：产品下线流程，远超 MVP 语义
- **财务增长组**（约 8 个）：business-health / organic-growth / acquisition-channel / saas-* / ansoff / pricing——经营分析，超出「做产品」边界
- **Workflow 型全部**（约 20 个）：prd-development / roadmap-planning / discovery-process 等——与四阶段主线冲突或重复，**主线本身已产品化**
- **原候选池维持排除（V3+ 再议）**：Hooked 习惯回路、CRO、OKR、北极星指标、技能「学」模式联动

---

## 5. 待确认

1. **首批数量**：14 个是否合适？（多则稀释 E11 检索演示，少则 ② 调研阶段偏薄）

**已裁决**：
- ~~S15 评审清单归属~~ → **规范路由**（`templates/prd-review-rubric.md`，确定性读取；理由见 §2.5，2026-09-09 用户确认）
- ~~`best_for` 字段入 design.md §5.2~~ → **采纳**，与 `type` / `pitfalls` 一并写入（design.md v0.9.11：§5.2 技能 schema + §5.3 skills 表 embedding 扩为四字段 + §6.2 清单实例化扩展；2026-09-10 用户确认）
- ~~`incoming-request-advisor` 二选一~~ → **内建澄清 prompt**（`AgentPrompts.clarify` 约束 7；理由：每轮必读、不能漏——语义检索「可能不命中」与「每轮行为的知识底座」天然冲突，与 §2.5 prd-review-rubric 同一原则；2026-09-14 用户确认）
