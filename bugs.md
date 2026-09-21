# bugs.md — 高成本 Bug 经验库

记录本仓库**难解决、耗时很长、或反复出现的同一个 bug**。

AI 代理每次会话开始必读本文件；排查任何 bug 前先对照条目，症状命中直接采用已验证解法，禁止重复排查。

> 与 AGENTS.md 的分工：AGENTS.md 记「约定与铁律」（怎么写代码才不踩坑）；本文件记「具体 bug 的排查记录」（踩了坑之后怎么救回来）。

## 条目模板

每个条目严格按以下固定字段记录：

```markdown
### B00X：<一句话标题>

- **日期**：YYYY-MM-DD（首次记录）
- **状态**：未解决 / 已解决 / 反复出现
- **复发次数**：N（首次为 1）
- **症状**：<现象、报错、误导性表现>
- **排查要点**：<走过的弯路、有效的定位方法>
- **根因**：<真正的原因>
- **解法**：<已验证的修复，含关键代码 / 命令>
- **防复发**：<落地的约束（如已写入 AGENTS.md 的规则；无则写「暂无」）>
```

## 条目

<!-- 新条目追加在文件末尾，编号递增，勿插入中间；同一 bug 复发时更新原条目的「状态 / 复发次数 / 日期 / 解法」，不新开条目。-->

### B001：流式生成「思考 30 分钟」假象——95% 墙钟是 UI 渲染瓶颈，不是模型慢

- **日期**：2026-09-18（首次记录）
- **状态**：已解决
- **复发次数**：1（长期存在，首次被定责）
- **症状**：PRD 轮动辄 15–30 分钟，表现酷似「模型思考慢 / 端点限流 / 上下文太长」。误导性极强：StreamPublishThrottle 0.1s 节流看似在工作（实际自败——消费端比节流窗还慢时每个 delta 都过窗发布，节流形同虚设）。
- **排查要点**：
  1. **先裸 curl 对照排除服务端**（同 Key 同端点）：实测 74–87 tok/s 全况无差别——29k 大 prompt 不减速、12k 长输出零衰减、effort 档位不影响吞吐、代理 vs 直连无差。服务端无罪后才能锁死 App 侧。
  2. **双侧探针定责**：网络侧（LLMClient 逐 SSE 行到达时刻）+ 消费侧（streamReply 逐 delta 到达 + 每次发布的时刻/长度），JSONL 落盘后按 roundId 对齐。基线铁证：网络 45.5s 交付 3768 delta（80 行/s 平坦），App 消费 883s（4.3 delta/s 衰减 16→0.8）；正文 token 网络 t≈40s 已到齐、UI t=845s 才显示首字。
  3. **交叉验证公式**：发布次数 × 单次渲染耗时 ≈ 总耗时（3103 × ~0.3s ≈ 883s ✓）——对上即定案。
  4. **分阶段速率切分**定位残余瓶颈：修复后一轮正文阶段 4186 delta/s（满速）vs 思考阶段 17.8/s——两阶段渲染结构几乎相同，唯一差异变量 = 思考卡展开态，即锁定。
- **根因**：三层 UI 渲染瓶颈叠加（每 delta 一次的 MainActor 重活）：
  ① `SessionStore.streams` 是 @Published 字典 → 每个 delta 触发对话页整页重渲染；
  ② 流式 Text 全量逐次重排（PRD 轮 61k 字符 × 数千次）；
  ③ 思考卡展开态（liveReasoning）每次发布重排 4000 字符尾窗 + DSScroll 底部锚定滚动 ≈ 200ms × 1268 次 ≈ 254s。
- **解法**（三刀，全在「流式态 UI 只拿尾部、全量语义不动」一个思路下）：
  1. **StreamBox 拆盒**（SessionStore.swift）：`streams: [String: StreamState]` → `streamBoxes: [String: StreamBox]`（per-session ObservableObject 盒）+ `streams` 计算属性快照兼容层（既有测试零改动）。增量只触碰盒自身 objectWillChange，订阅者只有流式气泡子视图 StreamingBubbleView；成员增删（建键/剪枝）才触发字典发布。滚动跟随 onChange 从父视图下沉到子视图监听 `box.value.text`。
  2. **发布尾窗化 + 展示/识别解耦**（StreamPublishTail + StreamDisplayPayload）：发布到 @Published 的字符串裁尾——text 12000 / think 4000 字符。本地 full/reasoning 持续累积，落盘/续写/停止收尾/终值补发一律全量。**衍生回归两连（同日修复，教训在最后）**：
     - 第一版「拼回开栏」：裁头后把 `​```artifact:prd` 开栏行拼回尾窗——被用户实测打穿：①PRD 块是**四反引号**（````artifact:prd，内嵌 ``` 围栏属正文），拼回三反引号开栏后内嵌围栏被误判闭栏 → 进度卡判定翻转 → 刷屏；②prd 闭栏后接未闭合 radar 块，radar 本就不收进度卡 → prd 尾部 + radar 源文裸渲染。
     - 终版（结构化解耦）：识别事实在发布点用**全量 full** 计算（`StreamDisplayPayload.make` → 完整块列表 / 进行中块名+行数 / 剥离后的块间正文），StreamState 加结构化字段下发；视图 StreamingContentBody 只渲染不再解析。行数顺带从尾窗虚低修为全量准确。
  3. **展开态思考流尾窗**（liveThinkChars = 900）：280pt 限高 ≈ 十几行可视量，ThinkingCard.liveReasoning 只渲染尾部。效果：262s → 预期 ~75s（≈网络交付时长）；复测实证 27k delta 轮消费 92/s（≈网络 108/s），durS 294 vs 网络 252，差距从 837s 缩到 42s。
- **防复发**：性能问题纪律——「先两侧探针定责，再动手修 UI」；流式 UI 新增任何渲染路径时自问「这个视图每 delta 重排多少字符」，渲染量必须常数化（尾窗），禁止全量文本进流式 @Published 链。**裁剪展示文本时必须盘点下游识别链依赖的标记——但更深的纪律是：识别/解析事实永远不要建立在「可能被裁剪的展示文本」上，在发布点用全量算好、结构化下发（一次做对，胜过在展示层打补丁）**。围栏协议有变体（三/四反引号、内嵌围栏、多块）时，任何基于「找标记字符串」的补丁都可能被组合打穿。探针模式（StreamProbe JSONL 双侧记录 + roundId 对齐）值得在下次性能排查时复刻。

### B002：新增 @MainActor ObservableObject 漏写 nonisolated deinit → 启动即闪退（B001 修复引入）

- **日期**：2026-09-18（首次记录）；2026-09-21（复发，第二次）
- **状态**：已解决
- **复发次数**：2（同类坑此前已在 PipelineEngine / MemoryStore 踩过——AGENTS.md 铁律第 2 条就是为它写的；09-21 再次踩中，且这次**不是 ObservableObject**，见下）
- **症状**：启动/测试即闪退，19:33–19:36 密集产生 24 个 ips。签名：`EXC_CRASH SIGABRT — POINTER_BEING_FREED_WAS_NOT_ALLOCATED`（malloc 释放未分配指针）。堆栈：`StreamBox.__deallocating_deinit` → `swift_task_deinitOnExecutorImpl` → abort。触发点：`mutateStream` 空态剪枝 `streamBoxes[k] = nil` 或流收尾 defer 销毁盒实例。全量测试也救不了——测试进程自身崩（SessionStreamFanoutTests 里销毁盒即崩）。
  第二次（09-21）签名一字不差，但对象是**普通 @MainActor 类**（MermaidView.swift 新增的 `MermaidZoomBridge`：无 @Published、不是 ObservableObject、只装 weak webView 引用 + 两个闭包），由 SwiftUI `@State` 持有。崩在单元测试局部作用域结束、实例释放那一刻。
- **排查要点**： DiagnosticReports 的 ips 文件是 JSON Lines（首行 header、余下多行 body），python `json.loads` 要切掉首行解析余文；先看 `exception` + `faultingThread` 帧，Swift 符号（`__deallocating_deinit` / `swift_task_deinitOnExecutorImpl`）直接指认 isolated-deinit 路径。grep 多个 ips 同签名可确认单一根因。
  第二次的新教训：**xcodebuild 的崩溃报告极具误导性**——测试进程崩了以后它打的是 `Restarting after unexpected exit, crash, or test timeout`，随后汇总里 `Executed 2 tests, with 0 failures`（崩掉的那个用例根本不计数），末尾却仍给 `** TEST FAILED **`。只 grep "failed" 会看到「0 failures 但 FAILED」的矛盾态；必须 grep `malloc|Restarting after` 才看得见真凶。
- **根因**：Xcode 26 默认 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` 下，@MainActor 类的 deinit 是 isolated 的；实例在流收尾（Task defer 等非典型上下文）被销毁时走隔离销毁路径，触发 malloc 崩溃。B001 修复新增 StreamBox 时漏了这条铁律——**知识在 AGENTS.md 里，但写新类时没有回头对照**。第二次同因：**铁律第 2 条被理解成了「ObservableObject 才要管」，实际是「任何模块内隐式/显式 @MainActor 类，只要可能在非主线程上下文释放就要写」**。
- **解法**：类体内显式退出隔离销毁路径（一行）：

```swift
@MainActor
final class StreamBox: ObservableObject {
    @Published var value: StreamState
    init(_ value: StreamState = StreamState()) { self.value = value }
    nonisolated deinit {}
}
```

  第二次同解：`MermaidZoomBridge` 补 `nonisolated deinit {}`，单元测试即刻转绿。
- **防复发**：AGENTS.md「Swift 并发铁律」第 2 条已覆盖（新增 @MainActor ObservableObject 类 = 条件反射加 `nonisolated deinit {}`，无论当下是否看起来会在隔离上下文销毁），本条把适用范围明确到**任意 @MainActor 类（含不发布变化的桥/通道类）**。补充纪律：**新增 ObservableObject 类型后，冒烟启动 + 查 DiagnosticReports 必做**——单测/编译都兜不住这个坑，只有真实启动销毁路径能暴露；反之若给一个桥类写了局部实例的单元测试，崩溃会在测试期就暴露（本次即靠 `ScrollWheelForwardingTests` 的局部实例提前抓到，否则会是「关掉放大弹窗偶发闪退」这类难查线上崩）。跑测试见到 `0 failures` + `TEST FAILED` 矛盾态，一律按崩溃处理而非用例失败。

### B003：点击「采纳方案」等按钮无反应——三重独立原因叠加，单看任何一层都像「按钮坏了」

- **日期**：2026-09-17（首次记录）
- **状态**：已解决
- **复发次数**：1
- **症状**：点击「采纳方案」按钮无反应。强误导：直觉怀疑按钮 action / hit 区域 / 状态绑定坏了，实际是三个互相独立的原因，各自都能单独造成同症状。
- **排查要点**（逐层排除，勿先动按钮代码）：
  1. **悬浮窗遮挡**：置顶悬浮窗（如「iPhone 镜像」）盖住台账区域时，点击根本到不了按钮——先挪开悬浮窗对照。
  2. **macOS 后台窗口首击**：未激活窗口的第一次点击默认只激活窗口、不派发给控件——「前台窗口点正常、后台窗口第一次点必无反应」即此条铁证。
  3. **实例替换间隙**：并行会话重启 / 换实例瞬间点击会丢失，避开该时段操作。
  4. 附带排除：钥匙串授权失效（OSStatus -25293）重启应用即恢复，与本症状无关。
- **根因**：SwiftUI 窗口内容视图默认走 NSView 的 `acceptsFirstMouse = false`——后台（未激活）窗口第一击被「激活窗口」行为吞掉，不触发控件 action。
- **解法**：WindowControls.swift 新增「后台窗口第一击直达」机制：SwiftUI 宿主的 pane 视图不是 NSView 子类、无法直接 override，用 `class_addMethod` 动态补 `acceptsFirstMouse(for:) → true`；普通 NSView 子类（如 InspectorPanel.swift）直接 override。配合用户侧约定：悬浮窗不遮挡台账区域、避开实例替换间隙。
- **防复发**：新增窗口 / 浮层 / 台账类交互区时默认检查「后台窗口首击」是否已被 WindowControls 的 acceptsFirstMouse 机制覆盖；再遇「点击无反应」按 遮挡 → 首击 → 实例间隙 三连排除。暂未写入 AGENTS.md。

### B004：新增系统行前缀未登记渲染白名单 → 布局回退旧版 / 一条回答裂成两条（机制性坑）

- **日期**：2026-09-15（首次记录；同日第二次）
- **状态**：已解决（机制性坑，同类已复发 2 次，预计仍会复发）
- **复发次数**：2
- **症状**：两种表现同根。① 风险改版上线后 UI 布局意外回退旧版本：合并行中断，后续系统行及气泡产物块全部回退旧布局；② AI 一次消息分两次回答：回退操作后自动续第二轮生成时出现独立 Agent 头。共同点：都发生在「新增一种系统行前缀」之后。
- **排查要点**：症状与「刚新增某类系统行」强相关时，直接对照 ConversationView.swift 的两套前缀清单逐项核对：`turnNote(from:)` 可并入白名单（L2468 起）与 `isFastForwardChainedBefore` 链标记（L2649 起）。
- **根因**：会话流渲染依赖手工维护的前缀白名单，产生方（AppModel.swift 发新系统行）改了，消费方（ConversationView.swift 白名单）没同步——①「⚠️ 自评审新增 N 个风险」未进 turnNote 可并入白名单 → 合并行中断、布局回退；②「🔄 已回到 …」前缀行未纳入链标记 → 回退续段未被并入上一条回答、渲染成独立消息。
- **解法**：① turnNote 白名单加入「⚠️ 自评审新增」，配防回归测试 `testMergeableNotesAbsorbRiskRegistrationRow`；② 链标记纳入「🔄 已回到」前缀，配防回归测试 `testBacktrackContinuationChainedBefore`。
- **防复发**：**新增任何系统行前缀 = 必须同步登记 ConversationView.swift 全部前缀白名单 + 配防回归测试**（至少两处：turnNote 可并入白名单、isFastForwardChainedBefore 链标记；日后新增白名单同样适用）。与「UI 双份维护」同性质：产生方与消费方必须一起改。暂未写入 AGENTS.md。

### B005：非本阶段产物块静默丢弃——「AI 宣称原型已生成，用户一个文件都拿不到」（同类第二次）

- **日期**：2026-09-21（首次记录；同类事故 2026-09-17 已发生过一次，当时只修了 PRD）
- **状态**：已解决
- **复发次数**：2（① 2026-09-17 非 PRD 阶段携带 `artifact:prd` 块被丢弃；② 2026-09-21 ② 阶段携带 `artifact:prototype` 块被丢弃）
- **症状**：② 结构闸口待确认期间用户连说「继续」，AI 回复正文写「原型你上手玩一圈」「形态选高保真可交互单文件，共 4 页 + 1 设置弹层」，交付回执卡只有风险行、没有任何文件行，右栏产物台账和 `03-prototypes/` 全空。全程零报错、零 ⚠️、零异常——**最难查的一点：它不是失败，是「什么都没发生」**。
- **排查要点**（磁盘先行，五步定案，比读代码快一个数量级）：
  1. `ls ~/PMAgent/Projects/<项目>/<版本>/03-prototypes/` —— 空目录即证明从未落盘，不是「落了没显示」。
  2. `index.sqlite` 的 `pipeline_runs` 行看 `current_stage` / `structure_confirmed` / `updated_at`，与用户看到的消息时刻对齐 —— 实测 `structure` / `0` / `22:30:17`，即阶段根本没推进。
  3. `discussions.jsonl` 取最后一条 assistant 全文，逐行找 `^\s*\`\`\`artifact:` 列出块名与行号 —— 本轮真实含 `plan`(L2) / `prototype`(L16-311) / `radar`(L323)，原型块 24,259 字符 `<!DOCTYPE html>` 起 `</html>` 止、围栏闭合，**产物本身完好无损**。
  4. `events.jsonl` 同一时刻只有 `radarRecorded`、**无 `artifactGenerated`** —— 同轮 radar 被正常消费而 prototype 没有，一步锁定「是分派丢了，不是解析丢了」。
  5. 反查 `AppModel.handleAssistantReply` 的 `switch origin.stage`：`case .structure` 只有「三件齐全 → 落盘」和「出过结构块 → ⚠️」两条出口，本轮一个结构块都没有 → 两条都不满足 → fall through，**零留痕**。
- **根因**：落盘分派按发起阶段 `origin.stage` 路由，非本阶段的产物块在该分派里没有消费者；而唯一的 stray 兜底 `hasStrayPRDBlock` 只写了 PRD 一种。上一次的教训被落成「PRD 专属补丁」而不是「产物块通用纪律」，于是换一个产物类型原样复发。触发侧同因：`AgentPrompts` 有「PRD 产物块硬禁令」，对原型没有同等禁令，而 ② prompt 的快速通道目标菜单里就写着 `"prototype"：直接生成 ③ 交互原型` —— 模型被邀请跳步，却没人告诉它只能出 `fast-forward` 请求块。
- **解法**（顺收为主、留痕为底，两道安全前置）：
  1. **越界顺收**（`AppModel.handleAssistantReply`）：`origin.stage == .structure` 且 `hasWritablePrototypeBlock` 且盘上结构三件齐且 ③ 槽位为空 → `confirmStructure(outcome: "carried_by_prototype")` 收束 ② 闸口 + 落 ⚡ 说明行 + 按 ③ 协议落盘并过机器门。③ 段落提取为 `writePrototypeArtifacts(artifactOrigin:)` 供两条路径共用，顺收轮传 `origin.with(stage: .prototype)`，事件留痕的 `stage` 才记 `prototype` 而非发起时的 `structure`。
  2. **收窄版留痕兜底**：`hasStrayPrototypeBlock`（闭合块 / 未闭合围栏任一）+ 一条 ⚠️ 指向「直接出原型」，只在顺收不成立时发。与 `hasStrayPRDBlock` 同处同构。
  3. **两处刻意取舍**：① 顺收**不改判 switch** 而是「结构照常落 + 原型补落」——同一回复完全可能既改结构三件又出原型，改判会让结构更新静默丢失，等于新造一个同类 bug；② 顺收要求 ③ 槽位为空——顺收轮没有冲突快照（快照只在 ③ 阶段发送链采集），直接覆盖会无声吃掉用户已有的原型文件。两处各有测试锚定。
- **防复发**：`PrototypeCarryInTests` 5 个用例（顺收端到端 / 无结构三件 / ① 阶段 / 覆盖防护 / 谓词四象限）。**纪律升级：新增一种产物块 = 同时补齐三件事——本阶段落盘分支、非本阶段的 stray 兜底留痕、prompt 侧的越界禁令或顺收策略**，只做第一项必然复发（PRD 那次就是只补了 PRD 自己的一条）。排查此类「说了没做」一律按上面五步走磁盘先行，先看 `events.jsonl` 有没有 `artifactGenerated`，能一步区分「解析丢 / 分派丢 / 落盘失败」。UI 侧 `ConversationView.prototypeBlock` 在文件不存在时「不出占位」是有意设计（防双卡），但它把这类后端静默放大成前端完全无痕——新增产物类型时要一并想清楚「块在回复里、文件不在盘上」这个中间态谁负责说话。
