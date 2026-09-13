#!/usr/bin/env python3
"""Screenshot multiple views of the PM Copilot prototype (v2 - generic selectors)."""
import os
from playwright.sync_api import sync_playwright

URL = "file:///Users/chenxiaofeng/Documents/Tare%20code%20file/pm%20worker/PM%20Copilot%20%E4%BA%A4%E4%BA%92%E5%8E%9F%E5%9E%8B%20v4%20%C2%B7%20TraeWork.html"
OUT = "/tmp/pm_shots"
os.makedirs(OUT, exist_ok=True)

def click_text(page, text, nth=0):
    try:
        loc = page.locator(f"text={text}").nth(nth)
        loc.click(timeout=2500)
        return True
    except Exception as e:
        print(f"  click fail [{text}]: {str(e)[:60]}")
        return False

with sync_playwright() as p:
    browser = p.chromium.launch()
    ctx = browser.new_context(viewport={"width": 1512, "height": 982}, device_scale_factor=2)
    page = ctx.new_page()
    page.goto(URL)
    page.wait_for_timeout(3500)

    # View 2: chat view — click session item
    if click_text(page, "四阶段流水线 · 全程"):
        page.wait_for_timeout(1500)
        page.screenshot(path=f"{OUT}/02_chat.png")
        print("chat done")

        # View 3: 按阶段视图 in right panel
        if click_text(page, "按阶段"):
            page.wait_for_timeout(1200)
            page.screenshot(path=f"{OUT}/03_phase_view.png")
            print("phase view done")

        # back to 文件 tab? try clicking 文件 first
        click_text(page, "文件")
        page.wait_for_timeout(800)

        # View 4: decision log tab in right panel (right side tabs)
        # find tab elements - they may repeat with left nav, use last ones
        locs = page.locator("text=决策日志")
        try:
            print("决策日志 count:", locs.count())
            locs.last.click(timeout=2000)
            page.wait_for_timeout(1200)
            page.screenshot(path=f"{OUT}/04_decision_tab.png")
            print("decision tab done")
        except Exception as e:
            print("  decision tab fail:", str(e)[:60])

        # View 5: radar tab
        try:
            locs = page.locator("text=漏项雷达")
            print("漏项雷达 count:", locs.count())
            locs.last.click(timeout=2000)
            page.wait_for_timeout(1200)
            page.screenshot(path=f"{OUT}/05_radar_tab.png")
            print("radar tab done")
        except Exception as e:
            print("  radar tab fail:", str(e)[:60])

    # View 6: decision log full page (left nav) - go home first
    page.goto(URL)
    page.wait_for_timeout(3000)
    try:
        locs = page.locator("text=决策日志")
        print("home 决策日志 count:", locs.count())
        locs.first.click(timeout=2000)  # left nav entry is first
        page.wait_for_timeout(1500)
        page.screenshot(path=f"{OUT}/06_decision_page.png")
        print("decision page done")
    except Exception as e:
        print("  decision page fail:", str(e)[:60])

    browser.close()
print("ALL DONE")
