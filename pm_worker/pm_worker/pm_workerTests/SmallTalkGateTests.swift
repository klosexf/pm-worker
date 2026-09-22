//
//  SmallTalkGateTests.swift
//  pm_workerTests
//
//  寒暄预闸（2026-09-22）：`AppModel.isSmallTalk` 是「这条消息是不是纯寒暄/致谢」
//  的唯一判据，命中即绕开整条阶段流水线走轻量轮。实测一句「你好」在 ③ 阶段付了
//  22,463 token 输入 × 2 次串行调用 = 127 秒，全部花在被 prompt 强制的 radar/plan
//  自评审上（探针 usage.jsonl roundId 97894BE1）。
//
//  契约取向：**判不准就不短路**——不命中的唯一后果是维持今天的全量行为（慢但正确），
//  误命中的后果是吞掉真需求。所以词表只收明确问候与明确致谢，
//  「好的」「嗯」「ok」这类纯推进语**刻意排除**（它们在澄清语境里可能承载确认语义）。
//

import XCTest
@testable import pm_worker

final class SmallTalkGateTests: XCTestCase {

    private func gate(
        _ text: String, imageFiles: [String] = [], fileRefs: [String] = []
    ) -> Bool {
        AppModel.isSmallTalk(text, imageFiles: imageFiles, fileRefs: fileRefs)
    }

    // MARK: - 命中

    func testPureGreetingsAndThanksHit() {
        for utterance in [
            "你好", "您好", "你好呀", "你好啊", "哈喽", "嗨", "hi", "hello", "hey",
            "在吗", "在不在", "早上好", "上午好", "中午好", "下午好", "晚上好",
            "午安", "晚安", "早",
            "谢谢", "多谢", "感谢", "辛苦了", "再见", "拜拜", "回头见",
        ] {
            XCTAssertTrue(gate(utterance), "\(utterance) 应判为寒暄")
        }
    }

    func testLatinGreetingsAreCaseInsensitive() {
        XCTAssertTrue(gate("HI"))
        XCTAssertTrue(gate("Hello"))
    }

    /// 标点与空白不参与判定：「你好！」与「你好」同解。
    func testPunctuationAndWhitespaceAreStrippedBeforeMatch() {
        XCTAssertTrue(gate("你好！"))
        XCTAssertTrue(gate("  你好  "))
        XCTAssertTrue(gate("谢谢～"))
        XCTAssertTrue(gate("hello."))
    }

    // MARK: - 不命中：附件与引用改变语义

    /// 「你好」+ 一张截图 = 带诉求的开场，不是寒暄。
    func testAttachedImageDefeatsGate() {
        XCTAssertFalse(gate("你好", imageFiles: ["pasted-1.png"]))
    }

    func testReferencedFileDefeatsGate() {
        XCTAssertFalse(gate("你好", fileRefs: ["02-structure/页面清单.md"]))
    }

    // MARK: - 不命中：纯推进语刻意排除

    /// 本条是词表尺度的锚：这些词在 ① 澄清语境里可能承载确认语义，
    /// 短路成客套回答会吞掉真意图，故一律不判寒暄（宁可慢，不可错）。
    func testBareAcknowledgementsAndAdvanceWordsDoNotHit() {
        for word in ["好的", "好", "嗯", "嗯嗯", "行", "ok", "收到", "知道了", "继续", "开始吧"] {
            XCTAssertFalse(gate(word), "\(word) 是推进/确认语，不得判为寒暄")
        }
    }

    // MARK: - 不命中：整句必须纯粹

    /// 词表是「整句归一化后逐字相等」，不是「包含」——
    /// 尾巴上带了任何实义内容就不再是寒暄。
    func testGreetingWithAnySubstantiveTailDoesNotHit() {
        XCTAssertFalse(gate("你好，帮我看下原型"))
        XCTAssertFalse(gate("你好 456"))
        XCTAssertFalse(gate("你好吗"))      // 是真问题，不是问候
        XCTAssertFalse(gate("谢谢你的建议"))
        XCTAssertFalse(gate("你好，今天天气怎么样"))
    }

    func testEmptyAndWhitespaceOnlyDoNotHit() {
        XCTAssertFalse(gate(""))
        XCTAssertFalse(gate("   \n  "))
    }

    // MARK: - 判据纯度

    /// 预闸必须是纯函数：同一输入重复调用结果一致，且不碰任何实例状态
    /// （轻量轮分支要在 sendMessage 早期调用，那里不允许有副作用）。
    func testGateIsDeterminedSolelyByItsArguments() {
        let first = gate("你好")
        for _ in 0..<3 {
            XCTAssertEqual(gate("你好"), first)
        }
    }
}
