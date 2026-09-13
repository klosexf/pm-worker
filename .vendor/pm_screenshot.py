#!/usr/bin/env python3
"""Screenshot the PM Copilot prototype at multiple views."""
import os
from playwright.sync_api import sync_playwright

URL = "file:///Users/chenxiaofeng/Documents/Tare%20code%20file/pm%20worker/PM%20Copilot%20%E4%BA%A4%E4%BA%92%E5%8E%9F%E5%9E%8B%20v4%20%C2%B7%20TraeWork.html"
OUT = "/tmp/pm_shots"
os.makedirs(OUT, exist_ok=True)

with sync_playwright() as p:
    browser = p.chromium.launch()
    ctx = browser.new_context(viewport={"width": 1512, "height": 982}, device_scale_factor=2)
    page = ctx.new_page()
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.goto(URL)
    page.wait_for_timeout(4000)

    page.screenshot(path=f"{OUT}/01_home.png")
    print("home done")
    print("TITLE:", page.title())

    links = page.eval_on_selector_all("button, [role=button], a", "els => els.slice(0,80).map(e => e.innerText.replace(/\\n/g,' | ').slice(0,50)).filter(Boolean)")
    print("BUTTONS:", links[:60])

    browser.close()
    if errors:
        print("PAGE ERRORS:", errors[:5])
