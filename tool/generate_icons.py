"""Generates the Windows icons used by the app.

    python3 tool/generate_icons.py

Writes:
  windows/runner/resources/app_icon.ico    app / taskbar icon
  windows/runner/resources/vault_icon.ico  icon of .flk vault files in Explorer
  assets/icons/app_icon.png                512 px previews (README)
  assets/icons/vault_icon.png

Shapes are drawn at 1024 px and scaled down, so every size is smooth.
Requires Pillow (pip install pillow).
"""

from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
CANVAS = 1024
SIZES = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]

INDIGO = (99, 102, 241)
VIOLET = (139, 92, 246)
DEEP = (67, 56, 202)
WHITE = (255, 255, 255, 255)


def gradient(size, start, end):
    """Diagonal gradient from the top-left to the bottom-right corner."""
    image = Image.new("RGBA", (size, size))
    pixels = image.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            pixels[x, y] = tuple(
                round(start[i] + (end[i] - start[i]) * t) for i in range(3)
            ) + (255,)
    return image


def draw_padlock(draw, center_x, top, width, color, hole_color):
    """A rounded padlock: shackle (arc) on top of a rounded body."""
    body_h = width * 0.78
    shackle_w = width * 0.62
    thickness = width * 0.13
    shackle_top = top
    body_top = top + width * 0.42
    # Shackle.
    draw.rounded_rectangle(
        (
            center_x - shackle_w / 2,
            shackle_top,
            center_x + shackle_w / 2,
            body_top + thickness * 2,
        ),
        radius=shackle_w / 2,
        outline=color,
        width=round(thickness),
    )
    # Body.
    draw.rounded_rectangle(
        (center_x - width / 2, body_top, center_x + width / 2, body_top + body_h),
        radius=width * 0.16,
        fill=color,
    )
    # Keyhole.
    hole = width * 0.12
    cy = body_top + body_h * 0.45
    draw.ellipse(
        (center_x - hole, cy - hole, center_x + hole, cy + hole), fill=hole_color
    )
    draw.rounded_rectangle(
        (center_x - hole * 0.45, cy, center_x + hole * 0.45, cy + hole * 2.3),
        radius=hole * 0.3,
        fill=hole_color,
    )


def app_icon():
    size = CANVAS
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (40, 40, size - 40, size - 40), radius=230, fill=255
    )
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.paste(gradient(size, INDIGO, VIOLET), (0, 0), mask)
    draw_padlock(ImageDraw.Draw(icon), size / 2, 250, 420, WHITE, DEEP + (255,))
    return icon


def vault_icon():
    size = CANVAS
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    folder = gradient(size, INDIGO, VIOLET)
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    # Folder tab and body.
    draw.rounded_rectangle((70, 170, 470, 360), radius=70, fill=255)
    draw.rounded_rectangle((70, 250, size - 70, size - 150), radius=90, fill=255)
    icon.paste(folder, (0, 0), mask)
    # Lighter front panel for depth.
    front = Image.new("RGBA", (size, size), (255, 255, 255, 38))
    front_mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(front_mask).rounded_rectangle(
        (70, 330, size - 70, size - 150), radius=90, fill=255
    )
    icon.alpha_composite(Image.composite(front, Image.new("RGBA", (size, size)), front_mask))
    # Padlock badge.
    badge = ImageDraw.Draw(icon)
    cx, cy, r = size - 250, size - 250, 210
    badge.ellipse((cx - r - 24, cy - r - 24, cx + r + 24, cy + r + 24), fill=WHITE)
    badge.ellipse((cx - r, cy - r, cx + r, cy + r), fill=DEEP + (255,))
    draw_padlock(badge, cx, cy - 150, 200, WHITE, DEEP + (255,))
    return icon


def save_ico(image, path):
    path.parent.mkdir(parents=True, exist_ok=True)
    frames = [image.resize((s, s), Image.LANCZOS) for s in SIZES]
    frames[-1].save(path, format="ICO", sizes=[(s, s) for s in SIZES], append_images=frames[:-1])


def main():
    resources = ROOT / "windows" / "runner" / "resources"
    app = app_icon()
    save_ico(app, resources / "app_icon.ico")
    save_ico(vault_icon(), resources / "vault_icon.ico")
    preview = ROOT / "assets" / "icons" / "app_icon.png"
    preview.parent.mkdir(parents=True, exist_ok=True)
    app.resize((512, 512), Image.LANCZOS).save(preview)
    vault_icon().resize((512, 512), Image.LANCZOS).save(preview.with_name("vault_icon.png"))
    print("Icons written to", resources)


if __name__ == "__main__":
    main()
