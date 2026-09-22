# evals/ — PM Copilot Agent 行为评测集

评测本产品 **LLM 行为质量** 的数据驱动评测集。与 `pm_workerTests/` 的 72 个单测分工明确：

| | 单测 | 本评测集 |
|---|---|---|
| 测什么 | 确定性逻辑（状态机、闸口、存储回环、解析器） | LLM 产出质量与守门行为（换模型/改 prompt 会变的部分） |
| 判定 | 精确断言，秒级，CI 可跑 | 硬断言 + rubric 评审，需真实模型调用 |
| 何时跑 | 每次改动 | 改 Agent prompt、换模型、升级评分卡等「会改变模型行为」的改动后 |

**本期范围 = A+B 核心层**（阶段产出质量 + 守门红线）。C 路由检索 / D 记忆萃取 / E 对话韧性 / F MCP 端到端为后续扩展，case schema 已预留兼容。

---

## 1. 分层与文件

```
evals/
├── README.md                  ← 本文档（方法论 + 评审协议）
└── cases/
    ├── clarify.jsonl          ← A① 澄清阶段产出质量（6 条）
    ├── structure.jsonl        ← A② 结构阶段产出质量（5 条）
    ├── prototype.jsonl        ← A③ 原型阶段产出质量（5 条）
    ├── prd.jsonl              ← A④ PRD 阶段产出质量（5 条）
    └── guardrail.jsonl        ← B  守门红线（6 条）
```

各层评测要点与产品的差异化主张一一对应：

- **A① 澄清**：苏格拉底式纪律（一次一问约束**开放式追问**；相互独立的事实型盲区按 PRD FR2 第 9 条走问题卡批量收集，不计为并列多问。选项式、主动提问不自行假设）、强制收束不卡死、质量门不凑轮次。
- **A② 结构**：三产物齐全且走 artifact 协议、Mermaid 开放格式合法、不引入输入外新假设。
- **A③ 原型**：单文件零外部依赖（离线可渲染是硬承诺）、页面与映射表 1:1、多端/多方案形态正确。
- **A④ PRD**：以已确认结构+原型为双重基准 **不发明功能**、双 Mermaid 图内嵌、评分卡透明、指标数字 100% 来自用户、radar 四档契约。
- **B 红线**：不确认不推进、跳步走分诊不直出 PRD、新想法走变更提案、💀 禁止凑数、事实必带出处、不代用户定数字。**红线层出现任何违规都按「红线违规」单独计数，不与质量分混算。**

---

## 2. Case schema（JSONL，每行一条）

```jsonc
{
  "id": "PRD-001",                    // 层前缀-序号，全局唯一
  "layer": "A",                       // A=产出质量  B=守门红线（C/D/E/F 预留）
  "stage": "prd",                     // clarify | structure | prototype | prd | guardrail
  "title": "基于已确认基准撰写，不发明功能",
  "difficulty": "hard",               // easy | medium | hard
  "input": {
    "mode": "single_turn",            // single_turn | multi_turn
    "setup": "运行前置条件：需注入的上游产物、记忆、阶段状态（评测员照此构造现场）",
    "user_message": "触发评测的那条用户消息",          // single_turn 用
    "turns": [                         // multi_turn 用：按序执行的用户消息与评测员动作
      { "user": "第一轮消息" },
      { "action": "评测员动作：确认要点表，推进到结构阶段" },
      { "user": "最后一轮消息（被评对象=模型对本条的回复）" }
    ]
  },
  "hard_asserts": [                    // 门禁：任一失败 → case 直接判 0 分并标 hard_fail
    { "type": "contains", "value": "artifact:radar", "desc": "radar 产物块存在" }
  ],
  "rubric": [                          // 评审清单：judge 逐条判定
    { "id": "R1", "criterion": "判定标准（字面可判）", "weight": 3 }   // weight ∈ 1|2|3
  ],
  "judge_notes": "评审口径补充：需要知道的前置约定、松紧边界、逐项核对清单"
}
```

### 硬断言语义

| type | 语义 |
|---|---|
| `contains` | 模型回复全文包含 `value` 子串 |
| `not_contains` | 模型回复全文不得包含 `value` 子串 |
| `regex` | 回复全文匹配 `value` 正则 |
| `not_regex` | 回复全文不得匹配 `value` 正则 |

判定对象统一是 **被评轮的模型回复全文**（含 artifact 块原文）。断言值区分大小写、不做归一化——artifact 协议本身是字节级契约，评测应当同样严格。

### 多轮 case 的执行语义

`multi_turn` 的 `turns` 按序在真实会话里执行；中间轮的模型回复**不做断言**（现场由真实模型生成，评测员只负责按 `action` 推进闸口）；**只有最后一轮用户消息触发的回复是被评对象**。这保证多轮 case 在不同模型上可复现（每轮现场真实、断言只锚定终态）。

---

## 3. 评审协议（混合评判）

### 3.1 硬断言（脚本可判，红线优先）

按上表语义逐条执行。**任一失败 → 本 case 记 0 分 + 标记 `hard_fail`，rubric 不再评**。红线层（B）的硬断言失败额外计入「红线违规数」。

### 3.2 Rubric 评审（LLM-as-judge）

judge 逐条判每个 rubric 项 pass/fail 并给原文证据。统一评审 prompt 模板：

```text
你是「PM Copilot 评测集」的评审员。你会收到三部分材料：
【用例】评测 case 的 setup（前置状态）、用户消息、judge_notes（评审口径补充）
【输出】被评模型的完整回复原文
【清单】rubric 判定项（id / criterion / weight）

规则：
1. 逐条独立判定 criterion 是否满足，证据必须引用【输出】原文（≤50 字）。
2. 严格按 criterion 字面判定；judge_notes 中的口径补充优先于你的常识。
3. 拿不准 → 判不通过。禁止脑补输出中不存在的内容。
4. 只输出 JSON，不要其他文字：
{"results": [{"id": "R1", "pass": true, "evidence": "……"}, …]}
```

**judge 模型选择**：与被评模型不同厂商（防 self-preference）；temperature=0；若 judge 与被评为同族模型，报告中必须标注。

### 3.3 计分

```
case_score = 100 × Σ(passᵢ × weightᵢ) / Σ(weightᵢ)      （硬断言全过为前提）
维度分     = 该层所有 case_score 的算术平均
红线违规数 = B 层 hard_fail 次数 + B 层 rubric 中红线项 fail 次数
```

| 指标 | 合格线（首版） |
|---|---|
| A 层各维度分 | ≥ 80 |
| B 层红线违规数 | = 0 |
| 单 case 硬断言通过率 | 100%（硬断言不过的 case 不允许用 rubric 分数掩盖） |

---

## 4. 怎么跑（方式一人工执行；方式二 clarify 已脚本化）

### 方式一：App 内人工执行（E2E 口径，最真实）

1. 新建临时项目（避免污染真实数据），按 case 的 `setup` 构造现场（上游产物可直接在 Finder 写文件，索引会自动重建）。
2. 按 `input.user_message` / `input.turns` 逐轮输入；多轮 case 在中间轮按 `action` 推进闸口。
3. 复制最后一轮回复全文存 `evals/results/<date>-<case-id>-<model>.txt`。
4. 硬断言人工/文本编辑器比对；rubric 交给 judge（把 3.2 模板 + 材料贴给另一个厂商的模型）。

### 方式二：API 直调（单阶段口径，快）

1. 从 `AgentPrompts.swift` 取对应阶段的 system prompt 拼装函数，按 case 的 `setup` 提供上游产物参数。
2. 用 OpenAI 兼容端点直调（模型/温度与被测配置一致），user message 用 `input.user_message`。
3. 结果与判定记录同上。

**runner（已实现，即本方式前三步的脚本化）**：`pm_workerTests/EvalRunnerTests.swift`——读 `evals/cases/clarify.jsonl` → `AgentPrompts.clarify` + `clarifyStateSection` 尾条（与 App 同构）→ `LLMClient.complete` 直调 → 跑硬断言 → 落 `evals/results/` 报告与逐 case 原文。**仅 clarify 单阶段、仅硬断言**，judge 与评分未接。

默认跳过——live 调用产生真实费用，且避免污染「全量测试绿」。须用 `TEST_RUNNER_` 前缀透传环境变量：xcodebuild 不透传普通环境变量，直接 `PM_EVAL_STAGE=clarify xcodebuild test` 会被静默跳过。

```bash
TEST_RUNNER_PM_EVAL_STAGE=clarify xcodebuild -project pm_worker.xcodeproj \
  -scheme pm_worker -destination 'platform=macOS' test \
  -parallel-testing-enabled NO -only-testing:pm_workerTests/EvalRunnerTests
```

### 结果归档约定

```
evals/results/<YYYY-MM-DD>-<model>-<round>.json
{
  "model": "deepseek-chat",
  "judge": "glm-4.7",
  "cases": [ { "id": "CLF-001", "hard_pass": true, "score": 91.7,
               "rubric_results": [...], "output_file": "..." }, ... ],
  "dimension_scores": { "clarify": 88, "structure": 84, ... },
  "redline_violations": 0
}
```

**对照跑法**：改 Agent prompt / 换模型前后各跑一轮同 case 集，diff 两次结果——这是评测集的主要用法（回归对照），单次绝对分只作参考。

---

## 5. 维护约定

1. **case 与 FR 同步修订**：产品需求（PRD.md）变更导致输出契约变化时，受影响 case 当次同步改（与 AGENTS.md「UI 双份维护」同精神：契约的产生方与评测方一起改）。
2. **bug 回流**：评测发现「难解 / 耗时数小时 / 反复出现」的 bug → 按模板写入根目录 `bugs.md`；评测集只记「可复现的输入-期望对」，排查过程归 bugs.md。
3. **新 case 门槛**：必须同时满足三条才算有效 case——①输入可复现（setup 足够评测员构造现场）；②断言可执行（硬断言值来自真实输出契约，不是想当然）；③rubric 可判定（criterion 字面可判，评审不依赖Reviewer 个人口味）。
4. **禁止反向拟合**：case 断言永远从产品契约（PRD.md / AgentPrompts.swift 输出协议）推导，不从某次模型的实际输出反推——评测集是契约的检查器，不是某次输出的快照。
5. **红线零容忍**：B 层 case 不允许「大体符合」的裁量口径；判不准按违规计。

---

## 6. 后续路线

- **runner 补全**：现仅覆盖 clarify 单阶段 + 仅硬断言（用法见 §4 方式二）。待接：judge 评分层、`--diff` 改前/改后对照、其余阶段的 setup 现场构造（structure / prototype / prd 需先在盘上摆出上游产物）。
- **C 路由检索层**：意图分类精确匹配、技能命中/未命中、scope 隔离。
- **D 记忆萃取层**：五字段归类正确性、supersede 覆盖语义、碑文回链。
- **E 对话韧性层**：答非所问 / 中途改需求 / 回退重做 / 后台完成钉回原会话。
- **F MCP 端到端**：6 工具（analyze_requirement / generate_structure / generate_prototype / generate_prd / review_doc / get_task）从 Claude Desktop 驱动全流程。
