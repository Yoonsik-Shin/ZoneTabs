"""앱 아이콘 원본(Resources/AppIcon.png, 1024x1024)을 그린다. Pillow 필요.

두 개로 나뉜 화면과, 그 오른쪽에 떠 있는 전환 바를 표현한다.
"""
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 4  # 계단 현상을 줄이려고 4배로 그린 뒤 줄인다.
SIZE = 1024 * S


def px(v):
    return int(round(v * S))


def rounded(draw, box, radius, fill):
    draw.rounded_rectangle([px(box[0]), px(box[1]), px(box[2]), px(box[3])], radius=px(radius), fill=fill)


# 배경: macOS 아이콘 규격(1024 캔버스 안의 824 둥근 사각형)에 세로 그라데이션.
gradient = Image.new("RGB", (1, SIZE))
top, bottom = (112, 132, 255), (66, 72, 214)
for y in range(SIZE):
    t = y / (SIZE - 1)
    gradient.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
gradient = gradient.resize((SIZE, SIZE))

mask = Image.new("L", (SIZE, SIZE), 0)
rounded(ImageDraw.Draw(mask), (100, 100, 924, 924), 185, 255)

icon = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
icon.paste(gradient, (0, 0), mask)

# 위아래로 나뉜 두 창.
panes = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(panes)
rounded(draw, (214, 232, 660, 492), 44, (255, 255, 255, 235))
rounded(draw, (214, 532, 660, 792), 44, (255, 255, 255, 120))
icon = Image.alpha_composite(icon, panes)

# 오른쪽에 떠 있는 전환 바: 그림자, 본체, 아이콘 자리 세 칸(맨 위가 선택된 칸).
shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
rounded(ImageDraw.Draw(shadow), (700, 322, 820, 722), 60, (20, 20, 80, 110))
shadow = shadow.filter(ImageFilter.GaussianBlur(px(14)))
icon = Image.alpha_composite(icon, shadow)

bar = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(bar)
rounded(draw, (696, 306, 816, 706), 60, (30, 32, 78, 245))
rounded(draw, (716, 328, 796, 408), 24, (255, 255, 255, 255))
rounded(draw, (716, 430, 796, 510), 24, (255, 255, 255, 110))
rounded(draw, (716, 532, 796, 612), 24, (255, 255, 255, 110))
draw.ellipse([px(741), px(644), px(771), px(674)], fill=(255, 255, 255, 150))
icon = Image.alpha_composite(icon, bar)

out = sys.argv[1] if len(sys.argv) > 1 else "Resources/AppIcon.png"
icon.resize((1024, 1024), Image.LANCZOS).save(out)
print("wrote", out)
