# Renders Squint's worn-photocopy artwork: the app icon layers and the DMG window background.
#   python3 tools/print-art.py icon   -> App/AppIcon.icon/Assets/{ink,shape,dots}.png
#   python3 tools/print-art.py dmg    -> tools/dmg/background.png and background@2x.png
# Needs numpy and Pillow (tools/make-icon.sh and release.sh set up a venv with them under build/).
# The DMG icon positions here must match tools/dmg/settings.py.
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INK = 20


class Print:
    """Noise and print-damage helpers for one canvas of h x w pixels."""

    def __init__(self, h, w, seed):
        self.h, self.w = h, w
        self.rng = np.random.default_rng(seed)
        self.y, self.x = np.mgrid[0:h, 0:w].astype(float)

    def rand(self):
        return self.rng.random((self.h, self.w))

    def fbm(self, octaves=(4, 8, 16, 32, 64, 128, 256), falloff=0.55):
        out, amp, total = np.zeros((self.h, self.w)), 1.0, 0.0
        for o in octaves:
            small = self.rng.random((max(2, o * self.h // max(self.h, self.w)), max(2, o * self.w // max(self.h, self.w))))
            out += np.asarray(Image.fromarray(small.astype(np.float32), mode="F").resize((self.w, self.h), Image.BICUBIC)) * amp
            total += amp
            amp *= falloff
        out /= total
        return (out - out.min()) / (out.max() - out.min())

    @staticmethod
    def blur(a, r):
        lo, hi = float(a.min()), float(a.max())
        if hi == lo:
            return a.astype(float)
        img = Image.fromarray(((a - lo) / (hi - lo) * 255).astype(np.uint8), mode="L").filter(ImageFilter.GaussianBlur(r))
        return np.asarray(img).astype(float) / 255 * (hi - lo) + lo

    def screen(self, cell, angle=8):
        """A coarse AM halftone screen in 0..1."""
        a = np.deg2rad(angle)
        sx = np.cos(a) * self.x + np.sin(a) * self.y
        sy = -np.sin(a) * self.x + np.cos(a) * self.y
        return (np.cos(sx * 2 * np.pi / cell) + np.cos(sy * 2 * np.pi / cell)) / 4 + 0.5

    def halftone(self, dark, cell, toner):
        """Darkness (0..1) to ink through a screen, with dot gain, a second copy generation and dropouts."""
        dark = self.blur(dark, 2.5 * cell / 17)
        dark = dark * (0.85 + 0.4 * toner) + (self.fbm((16, 32, 64, 128)) - 0.5) * 0.35
        ink = (dark + (self.screen(cell) - 0.5) * 0.9) > 0.5
        ink = self.blur(ink.astype(float), 2.2 * cell / 17) + (self.rand() - 0.5) * 0.25 + (toner - 0.5) * 0.3 > 0.5
        ink = self.blur(ink.astype(float), 1.3 * cell / 17) + (self.rand() - 0.5) * 0.2 > 0.5
        return ink & ~self.dropouts()

    def solid(self, mask, r=1.2):
        """A shape printed as solid ink with ragged edges and dropouts."""
        ink = self.blur(mask.astype(float), r) + (self.rand() - 0.5) * 0.3 + (self.fbm((16, 32, 64)) - 0.5) * 0.25 > 0.5
        return ink & ~self.dropouts()

    def outline(self, mask, width):
        inner = self.blur(mask.astype(float), width) > 0.92
        g = self.blur(self.rand(), 1.0)
        return mask & ~inner & (g < np.percentile(g, 80))

    def dropouts(self):
        g = self.blur(self.rand(), 1.2)
        return (g > np.percentile(g, 96)) | (self.fbm((64, 128, 256)) > 0.88)

    def dirt(self, edge=90):
        """Toner specks, clumps, a dragged streak and grime along the edges."""
        g = self.blur(self.rand(), 1.5)
        speck = g < np.percentile(g, 0.6)
        clump = (self.fbm((32, 64, 128, 256)) > 0.85) & (self.rand() < 0.08)
        sx = self.rng.integers(int(self.w * 0.15), int(self.w * 0.85))
        streak = (np.abs(self.x - sx - self.y * 0.02) < 3) & (self.rand() < 0.05 + 0.2 * self.fbm((4, 8)))
        border = np.minimum.reduce([self.x, self.y, self.w - self.x, self.h - self.y])
        grime = (border < 20 + self.fbm((4, 8, 16)) * edge) & (self.rand() < 0.07)
        return self.blur((speck | clump | streak | grime).astype(float), 0.8) > 0.4

    def spill(self, cell, keep_clear, threshold=0.62, weight=None):
        """Patches of halftone printing where they shouldn't, fading out, away from `keep_clear`.
        `weight` (0..1) places the patches instead of random clouds."""
        w = np.clip((self.fbm((3, 6, 12, 24)) - threshold) * 3.0, 0, 1) if weight is None else weight
        w = w * ~keep_clear
        s = ((w * 0.42 + (self.screen(cell) - 0.5) * 0.9 + (self.rand() - 0.5) * 0.15) > 0.5) & (w > 0.04)
        return self.blur(s.astype(float), 1.0) + (self.rand() - 0.5) * 0.25 > 0.55

    def grid(self, pitch, dot):
        """Faint square dot grid, worn away in places."""
        return ((self.x % pitch) < dot) & ((self.y % pitch) < dot) & (self.fbm((4, 8, 16, 64)) > 0.35) & (self.rand() > 0.15)

    def paper(self):
        return 255 - self.fbm((2, 4, 8)) * 26

    def tone(self):
        return INK + self.rand() * 30


def pen_mask(x, y, n):
    """The pen silhouette (rounded end top-right, point bottom-left) on an n x n canvas, plus its shading."""
    k = n / 1024
    c = np.sqrt(0.5)
    u = c * (x - n / 2) + c * (y - n / 2)
    v = -c * (x - n / 2) + c * (y - n / 2)
    w, top, shoulder, tip = 92 * k, -330 * k, 200 * k, 370 * k
    taper = w * (1 - (v - shoulder) / (tip - shoulder))
    cone = (v > shoulder) & (v <= tip) & (np.abs(u) <= np.maximum(taper, 0))
    pen = ((np.abs(u) <= w) & (v >= top) & (v <= shoulder)) | ((u ** 2 + (v - top) ** 2 <= w ** 2) & (v < top)) | cone
    light = 0.15 + 0.85 * np.clip(np.cos((u / w + 0.35) * 1.6), 0, 1) ** 1.5
    light -= 0.25 * np.clip((v - top) / (tip - top), 0, 1)
    light = np.where(cone, light * 0.65, light)
    light = np.where(cone & (v > tip - 60 * k), 0.0, light)
    return pen, np.where(pen, 0.28 + 0.72 * (1 - light), 0.0)


def icon():
    n = 1024
    p = Print(n, n, seed=3)
    # Wobble the geometry so no edge of the printed pen is a clean line.
    wx = p.x + (p.fbm((8, 16, 32, 64)) - 0.5) * 13
    wy = p.y + (p.fbm((8, 16, 32, 64)) - 0.5) * 13
    pen, dark = pen_mask(wx, wy, n)
    toner = p.fbm()
    ink = p.halftone(dark, 17, toner) | p.outline(pen, 6)
    ink &= p.blur(pen.astype(float), 3) > 0.02

    # Only big halftone clouds, gathered in the bottom-left corner.
    corner = np.clip(1.25 - np.hypot(p.x, n - p.y) / (n * 0.5), 0, 1)
    cloud = np.clip(corner * (0.5 + p.fbm((3, 6, 12, 24))) * 1.4, 0, 1)
    dots = p.spill(19, p.blur(pen.astype(float), 18) > 0.05, weight=cloud).astype(float)

    clean, _ = pen_mask(p.x, p.y, n)
    out = os.path.join(ROOT, "App/AppIcon.icon/Assets")

    def rgba(gray, alpha):
        g = np.full((n, n), gray, np.uint8)
        return Image.fromarray(np.dstack([g, g, g, (np.clip(alpha, 0, 1) * 255).astype(np.uint8)]), "RGBA")

    rgba(INK, ink).save(f"{out}/ink.png")
    rgba(0, dots).save(f"{out}/dots.png")
    rgba(255, p.blur(clean.astype(float), 1.0)).save(f"{out}/shape.png")


def dmg():
    s = 2                                   # draw at 2x, downsample for 1x
    w, h = 640 * s, 400 * s
    app, apps = (170 * s, 200 * s), (470 * s, 200 * s)
    p = Print(h, w, seed=11)

    def text_mask(text, size, center_y, font_index):
        img = Image.new("L", (w, h), 0)
        d = ImageDraw.Draw(img)
        font = ImageFont.truetype("/System/Library/Fonts/HelveticaNeue.ttc", size * s, index=font_index)
        box = d.textbbox((0, 0), text, font=font)
        d.text(((w - (box[2] - box[0])) / 2 - box[0], center_y * s - (box[3] - box[1]) / 2 - box[1]), text, font=font, fill=255)
        return np.asarray(img) > 127

    title = text_mask("SQUINT", 54, 58, 1)
    tagline = text_mask("CODE PREVIEWS FOR QUICK LOOK", 13, 102, 1)
    hint = text_mask("DRAG SQUINT INTO APPLICATIONS", 11, 262, 1)

    # A chunky arrow between the two icons, shaded like the pen.
    ax0, ax1, ay = 252 * s, 388 * s, 200 * s
    shaft = (p.x >= ax0) & (p.x <= ax1 - 34 * s) & (np.abs(p.y - ay) <= 11 * s)
    head = (p.x > ax1 - 40 * s) & (p.x <= ax1) & (np.abs(p.y - ay) <= (ax1 - p.x) * 0.8)
    arrow = shaft | head
    shade = np.where(arrow, 0.45 + 0.55 * np.clip((p.x - ax0) / (ax1 - ax0), 0, 1), 0.0)
    toner = p.fbm()
    ink = p.solid(title, 1.6) | p.solid(tagline, 0.9) | p.solid(hint, 0.8)
    ink |= p.halftone(shade, 13, toner) & (p.blur(arrow.astype(float), 3) > 0.02)
    ink |= p.outline(arrow, 4)

    # Keep the icons and their labels readable: no spill or heavy dirt around them.
    around = np.zeros((h, w), bool)
    for cx, cy in (app, apps):
        around |= ((p.x - cx) ** 2 / (95 * s) ** 2 + (p.y - cy - 12 * s) ** 2 / (95 * s) ** 2) < 1
    clear = around | (p.blur((title | tagline | hint | arrow).astype(float), 14) > 0.02)
    background = p.spill(13, clear, 0.6) | (p.dirt(70) & ~around)

    paper = p.paper()
    paper = np.where(p.grid(22, 5) & ~around, paper - 30, paper)
    img = np.where(ink | background, p.tone(), paper)
    out = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).convert("RGB")
    out.save(os.path.join(ROOT, "tools/dmg/background@2x.png"), dpi=(144, 144))
    out.resize((640, 400), Image.LANCZOS).save(os.path.join(ROOT, "tools/dmg/background.png"), dpi=(72, 72))


if __name__ == "__main__":
    {"icon": icon, "dmg": dmg}[sys.argv[1]]()
