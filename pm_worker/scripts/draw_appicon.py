#!/usr/bin/env python3
"""PM Copilot AppIcon 绘制：品牌紫渐变 + 白色文档(折角) + 四角星光斑。
2048 超采样 → 1024 LANCZOS 缩减。全出血设计（系统自动应用 squircle 遮罩）。"""
import math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 2048          # 采样尺寸
OUT = 1024        # 输出尺寸

# 品牌色（DS.swift 令牌）
C_TOP = (0x5B, 0x4D, 0xEA)     # 亮紫
C_BOT = (0x36, 0x28, 0xA8)     # 深紫
C_DOC = (255, 255, 255)
C_LINE = (0xC9, 0xC2, 0xF2)    # 淡紫灰内容行
C_BRAND_LINE = (0x4B, 0x3F, 0xE3)  # 品牌紫高亮行

# ---------- 1. 对角渐变背景（135°：左上→右下，带轻微径向提亮） ----------
yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
t = (xx + yy) / (2 * S)
cx, cy = S * 0.38, S * 0.32
r = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2) / (S * 0.85)
glow = np.clip(0.22 * (1 - r), 0, 1)
arr = np.zeros((S, S, 3), dtype=np.float32)
for i in range(3):
    base = C_TOP[i] + (C_BOT[i] - C_TOP[i]) * t
    arr[:, :, i] = base + glow * ((C_TOP[i] - base) * 0.55 + 18)
img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB").convert("RGBA")

# ---------- 2. 文档软阴影 ----------
doc_l, doc_t, doc_r, doc_b = int(S*0.30), int(S*0.24), int(S*0.70), int(S*0.76)
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ds = ImageDraw.Draw(shadow)
ds.rounded_rectangle(
    [doc_l + 30, doc_t + 55, doc_r + 30, doc_b + 55],
    radius=int(S * 0.045), fill=(0x14, 0x0A, 0x50, 150)
)
shadow = shadow.filter(ImageFilter.GaussianBlur(S * 0.035))
img = Image.alpha_composite(img, shadow)

# ---------- 3. 白色文档（圆角 + 右上折角） ----------
fold = int(S * 0.11)
rad = int(S * 0.045)

doc_layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
dd = ImageDraw.Draw(doc_layer)
dd.rounded_rectangle([doc_l, doc_t, doc_r, doc_b], radius=rad, fill=C_DOC + (255,))

# 擦掉右上折角三角（透明）
eraser = Image.new("L", (S, S), 0)
de = ImageDraw.Draw(eraser)
de.polygon([(doc_r - fold, doc_t), (doc_r, doc_t), (doc_r, doc_t + fold)], fill=255)
doc_layer = Image.composite(Image.new("RGBA", (S, S), (0, 0, 0, 0)), doc_layer, eraser)

# 折角小三角（浅紫，模拟纸背翻折）
fold_tri = Image.new("RGBA", (S, S), (0, 0, 0, 0))
df = ImageDraw.Draw(fold_tri)
df.polygon(
    [(doc_r - fold + 4, doc_t + 4), (doc_r - fold + 4, doc_t + fold - 4),
     (doc_r - 4, doc_t + fold - 4)],
    fill=(0xDE, 0xD8, 0xF6, 255)
)
doc_layer = Image.alpha_composite(doc_layer, fold_tri)
img = Image.alpha_composite(img, doc_layer)

# ---------- 4. 文档内容行（PRD 质感） ----------
d3 = ImageDraw.Draw(img)
line_l = doc_l + int(S * 0.055)
line_r = doc_r - int(S * 0.055)
lh = int(S * 0.020)
gap = int(S * 0.030)
y = doc_t + int(S * 0.09)
rows = [
    (line_r, C_BRAND_LINE),                                  # 品牌紫标题行
    (int((line_r - line_l) * 0.72) + line_l, C_LINE),
    (int((line_r - line_l) * 0.86) + line_l, C_LINE),
    (int((line_r - line_l) * 0.60) + line_l, C_LINE),
]
for w, col in rows:
    d3.rounded_rectangle([line_l, y, w, y + lh], radius=lh // 2, fill=col + (255,))
    y += lh + gap

# ---------- 5. 四角星光斑（TraeWork aiStars 语言） ----------
def star4(draw, cx, cy, r, color):
    inner = r * 0.30
    pts = []
    for i in range(8):
        ang = math.radians(i * 45 - 90)
        rr = r if i % 2 == 0 else inner
        pts.append((cx + rr * math.cos(ang), cy + rr * math.sin(ang)))
    draw.polygon(pts, fill=color + (255,))

scx, scy = doc_r - int(S * 0.015), doc_t + int(S * 0.02)
star4(d3, scx, scy, int(S * 0.075), (255, 255, 255))
star4(d3, scx - int(S*0.115), scy - int(S*0.075), int(S * 0.032), (255, 255, 255))

# ---------- 6. 缩减输出 ----------
final = img.convert("RGB").resize((OUT, OUT), Image.LANCZOS)
final.save(
    "/Users/chenxiaofeng/Documents/Tare code file/pm worker/pm_worker/pm_worker/"
    "pm_worker/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
)
print("saved AppIcon.png", final.size)
