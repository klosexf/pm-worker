#!/usr/bin/env python3
"""Verify v4.16 model config page + interactions of the PM Copilot prototype."""
import os
from playwright.sync_api import sync_playwright

URL = "file:///Users/chenxiaofeng/Documents/Tare%20code%20file/pm%20worker/PM%20Copilot%20%E4%BA%A4%E4%BA%92%E5%8E%9F%E5%9E%8B%20v4%20%C2%B7%20TraeWork.html"
OUT = "/tmp/pm_shots"
os.makedirs(OUT, exist_ok=True)
errors, console_errors = [], []

with sync_playwright() as p:
    browser = p.chromium.launch()
    ctx = browser.new_context(viewport={"width": 1512, "height": 982}, device_scale_factor=2)
    page = ctx.new_page()
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.on("console", lambda m: console_errors.append(m.text) if m.type == "error" else None)
    page.goto(URL)
    page.wait_for_timeout(3500)
    page.screenshot(path=f"{OUT}/m1_home.png")
    print("TITLE:", page.title())

    # 1) home model dropdown: click the model pill near send button
    model_btn = page.locator('[title^="对话模型"]').first
    print("model btn found:", model_btn.count() > 0)
    model_btn.click()
    page.wait_for_timeout(400)
    page.screenshot(path=f"{OUT}/m2_home_model_dropdown.png")
    print("dropdown open, options:", page.locator('[role="option"]').count())

    # 2) pick deepseek-chat, verify pill label sync
    page.locator('[role="option"]').filter(has_text="deepseek-chat").first.click()
    page.wait_for_timeout(300)
    pill = model_btn.inner_text()
    print("pill after pick:", pill.strip())

    # 3) open 模型配置 via dropdown footer entry
    model_btn.click(); page.wait_for_timeout(300)
    page.locator('[role="button"]').filter(has_text="模型配置 · 分阶段模型与供应商").first.click()
    page.wait_for_timeout(500)
    page.screenshot(path=f"{OUT}/m3_models_page.png")
    body = page.locator("body").inner_text()
    for t in ["模型配置", "槽位模型分配", "用量与成本", "智谱 AI", "Ollama", "Keychain", "本月 ¥4.2", "意图分类"]:
        print(f"page contains {t!r}:", t in body)

    # 4) clarify slot should be deepseek-chat (synced from home pick)
    selects = page.locator("select")
    print("select count:", selects.count())
    clarify = page.locator('select[aria-label="① 需求澄清 · 对话 模型"]')
    print("clarify slot value:", clarify.input_value() if clarify.count() else "NOT FOUND")

    # 5) switch clarify provider back to zhipu (auto-picks glm-4.6), then check home pill
    clarify_prov = page.locator('select[aria-label="① 需求澄清 · 对话 供应商"]')
    clarify_prov.select_option("zhipu")
    page.wait_for_timeout(300)
    print("clarify after provider switch:", clarify.input_value())

    # 6) test 更换密钥 modal
    page.locator('[title^="更换密钥"]').first.click()
    page.wait_for_timeout(300)
    page.screenshot(path=f"{OUT}/m4_key_modal.png")
    dlg = page.locator('[role="dialog"]')
    print("key modal open:", dlg.count() > 0)
    dlg.locator("input").fill("sk-new-secret-AB12")
    page.locator("button").filter(has_text="保存").last.click()
    page.wait_for_timeout(300)
    print("key updated:", "AB12" in page.locator("body").inner_text())

    # 7) test 测试连接 (state flips to 连接中 then 已连通)
    page.locator("button").filter(has_text="测试连接").first.click()
    page.wait_for_timeout(300)
    print("testing tag:", "连接中" in page.locator("body").inner_text())
    page.wait_for_timeout(1200)

    # 8) 添加供应商 modal
    page.locator("button").filter(has_text="添加供应商").click()
    page.wait_for_timeout(300)
    page.screenshot(path=f"{OUT}/m5_add_modal.png")
    inputs = page.locator('[role="dialog"] input')
    inputs.nth(0).fill("月之暗面")
    inputs.nth(1).fill("https://api.moonshot.cn/v1")
    inputs.nth(2).fill("sk-moonshot-998X")
    page.locator("button").filter(has_text="添加并测试").click()
    page.wait_for_timeout(400)
    page.screenshot(path=f"{OUT}/m6_provider_added.png")
    print("new provider card:", "月之暗面" in page.locator("body").inner_text())
    print("new key tail:", "998X" in page.locator("body").inner_text())

    # 9) token limit stepper
    plus = page.locator("button").filter(has_text="+")
    plus.last.click(); page.wait_for_timeout(200)
    print("limit now 25:", "25 万 tok" in page.locator("body").inner_text())

    # 10) back home: pill should read GLM-4.6 (slot changed in step 5)
    page.locator("text=新建任务").first.click()
    page.wait_for_timeout(500)
    page.screenshot(path=f"{OUT}/m7_home_after.png")
    print("home pill after slot change:", model_btn.inner_text().strip())

    # 11) chat page: 本月 ¥4.2 entry goes to models
    page.locator("text=四阶段流水线 · 全程").first.click()
    page.wait_for_timeout(600)
    page.screenshot(path=f"{OUT}/m8_chat_cost.png")
    page.locator('[title^="本月模型费用"]').click()
    page.wait_for_timeout(500)
    print("chat->models ok:", "槽位模型分配" in page.locator("body").inner_text())

    browser.close()

print("PAGE ERRORS:", errors[:5] if errors else "none")
print("CONSOLE ERRORS:", console_errors[:5] if console_errors else "none")
