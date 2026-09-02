#!/usr/bin/env python3
"""Generate 5 radically different app icon concepts for Kjol.

Each icon: 512×512, system-color palette (Apple Silicon aesthetic),
abstract chill/flow split via a diagonal stroke through a stylized ø form.
"""

from PIL import Image, ImageDraw, ImageFilter
import math, os

OUTDIR = "/Users/lappier/Desktop/kjol-icon-exploration/renders"
SIZE = 512
os.makedirs(OUTDIR, exist_ok=True)

# Palette (Apple system colors, adapted subtly)
ACCENT_BLUE   = (10, 132, 255, 255)      # system blue accent
ACCENT_VIOLET = (94, 92, 230, 255)       # purple-violet accent shift
COOL_GRAY     = (200, 203, 208, 255)     # light cool gray
MID_GRAY      = (142, 147, 158, 255)
DARK          = (28, 28, 30, 255)        # near-black
BACKGROUND    = (250, 251, 252, 255)     # near-white card
BACKGROUND2   = (237, 238, 242, 255)     # slightly warm gray
WHITE         = (255, 255, 255, 255)
WHITE_DIM     = (255, 255, 255, 230)

def save(path, img):
    img.save(path)
    print(f"→ {path}  ({img.size[0]}×{img.size[1]})")

def rounded_rect(draw, xy, r, fill=None, outline=None, width=1):
    draw.rounded_rectangle(xy, r, fill=fill, outline=outline, width=width)

def circle_filled(draw, cx, cy, r, fill):
    draw.ellipse([cx-r, cy-r, cx+r, cy+r], fill=fill)

def line(draw, x1, y1, x2, y2, fill, width=2, joint="curve"):
    draw.line([(x1,y1),(x2,y2)], fill=fill, width=width, joint=joint)

def radial_line(draw, cx, cy, radius, start_deg, end_deg, fill, width=3, step=2):
    pts = []
    for a in range(int(start_deg), int(end_deg) + 1, step):
        ra = math.radians(a)
        pts.append((cx + radius * math.cos(ra), cy + radius * math.sin(ra)))
    if len(pts) >= 2:
        draw.line(pts, fill=fill, width=width, joint="curve")

def ø_stroke(draw, cx, cy, r, stroke_w, color, angle=135):
    """Draw the diagonal stroke of the ø from upper-left to lower-right."""
    ang = math.radians(angle)
    dx, dy = math.cos(ang), math.sin(ang)
    t = r + 10
    p1 = (cx + t*dx, cy + t*dy)
    p2 = (cx - t*dx, cy - t*dy)
    draw.line([p1, p2], fill=color, width=stroke_w, joint="curve")

def diagonal_half_polygon(draw, cx, cy, r, fill, side, angle=135, inset=0):
    """Fill one half of a circle along the diagonal by angle-side polygon."""
    a1 = math.radians(angle)          # ~135 = upper-left
    a2 = math.radians(angle - 180)    # ~315 = lower-right
    # Clip inset
    r_in = r - inset
    if side == "right":
        # right side: from a2 (-45) up to a1 (135) the long way through 45/90
        pts = [(cx, cy), (cx + r_in*math.cos(a2), cy + r_in*math.sin(a2))]
        for a in range(int(angle - 180), int(angle) + 1, 4):
            ra = math.radians(a)
            pts.append((cx + r_in*math.cos(ra), cy + r_in*math.sin(ra)))
        pts.append((cx + r_in*math.cos(a1), cy + r_in*math.sin(a1)))
    else:
        pts = [(cx, cy), (cx + r_in*math.cos(a1), cy + r_in*math.sin(a1))]
        for a in range(int(angle), int(angle + 180) + 1, 4):
            ra = math.radians(a)
            pts.append((cx + r_in*math.cos(ra), cy + r_in*math.sin(ra)))
        pts.append((cx + r_in*math.cos(a2), cy + r_in*math.sin(a2)))
    draw.polygon(pts, fill=fill)


# ======================================================================
# ICON 1 — Split-diagonal Ø
#           Left half = chill (cool gray), right half = flow (accent blue);
#           clean diagonal stroke; abstract glyphs (descending ticks / chevron).
# ======================================================================
def icon1():
    img = Image.new("RGBA", (SIZE, SIZE), BACKGROUND)
    draw = ImageDraw.Draw(img)
    cx, cy = SIZE//2, SIZE//2
    r = 200
    stroke_w = 14

    # Base bowl (cool gray)
    circle_filled(draw, cx, cy, r, COOL_GRAY)
    # Right half overlay (accent blue)
    diagonal_half_polygon(draw, cx, cy, r, ACCENT_BLUE, "right", angle=135, inset=0)

    # Diagonal stroke (dark)
    ø_stroke(draw, cx, cy, r, stroke_w, DARK, angle=135)
    # Inner accent line for depth
    radial_line(draw, cx, cy, r - 12, 130, 140, ACCENT_VIOLET, width=5, step=1)
    radial_line(draw, cx, cy, r - 12, 310, 320, ACCENT_VIOLET, width=5, step=1)

    # Left chill glyph: descending ticks
    line(draw, cx - 40, cy + 20, cx - 60, cy + 45, WHITE, width=6)
    line(draw, cx - 20, cy + 40, cx - 40, cy + 65, WHITE, width=6)
    # Right flow glyph: chevron
    line(draw, cx + 40, cy - 38, cx + 82, cy, ACCENT_VIOLET, width=8)
    line(draw, cx + 82, cy, cx + 40, cy + 38, ACCENT_VIOLET, width=8)

    # Keel anchor dot
    circle_filled(draw, cx, cy, 6, DARK)

    # Subtle outer ring
    draw.ellipse([cx-r-14, cy-r-14, cx+r+14, cy+r+14],
                 outline=(210, 212, 218, 255), width=3)
    save(f"{OUTDIR}/kjol-icon-01-split-diagonal.png", img)


# ======================================================================
# ICON 2 — Macro-aperture Ø
#           Concentric ring segments, split-tone; more abstract/`aperture'
#           feel. Fluid core with keel line through center.
# ======================================================================
def icon2():
    img = Image.new("RGBA", (SIZE, SIZE), BACKGROUND)
    draw = ImageDraw.Draw(img)
    cx, cy = SIZE//2, SIZE//2
    outer_r, mid_r, inner_r = 200, 130, 72

    # Outer ring: two halves (left cool, right accent)
    # Left outer arc (135°→315° the left way through 180°)
    radial_line(draw, cx, cy, outer_r, 135, 315, COOL_GRAY, width=20, step=2)
    # Right outer arc (315°→495° the right way through 45/90)
    radial_line(draw, cx, cy, outer_r, 315, 495, ACCENT_BLUE, width=20, step=2)

    # Middle ring: accent violet, full thin ring
    for a in range(0, 360, 3):
        ra = math.radians(a)
        x1, y1 = cx + mid_r*math.cos(ra), cy + mid_r*math.sin(ra)
        x2, y2 = cx + (mid_r-8)*math.cos(ra), cy + (mid_r-8)*math.sin(ra)
        draw.line([(x1, y1), (x2, y2)], fill=ACCENT_VIOLET, width=2)

    # Inner core: split diagonal halves
    # Right half (accent)
    diagonal_half_polygon(draw, cx, cy, inner_r, ACCENT_BLUE, "right", angle=135, inset=0)
    # Left half (cool)
    diagonal_half_polygon(draw, cx, cy, inner_r, COOL_GRAY, "left", angle=135, inset=0)

    # Diagonal keel line through outer
    ø_stroke(draw, cx, cy, outer_r + 8, 8, DARK, angle=135)

    # Right flow chevron
    line(draw, cx + 88, cy - 20, cx + 130, cy, ACCENT_VIOLET, width=7)
    line(draw, cx + 130, cy, cx + 88, cy + 20, ACCENT_VIOLET, width=7)
    # Left chill descending ticks
    line(draw, cx - 68, cy + 8, cx - 98, cy + 32, WHITE, width=6)
    line(draw, cx - 48, cy + 28, cx - 78, cy + 52, WHITE, width=6)

    # Keel center dot
    circle_filled(draw, cx, cy, 7, DARK)
    save(f"{OUTDIR}/kjol-icon-02-aperture-rings.png", img)


# ======================================================================
# ICON 3 — Geometric split (abstract shapes, letter-less)
#           Left = calm cooling column (rounded rect), right = flow wedge;
#           diagonal separator; keel accent at bottom.
# ======================================================================
def icon3():
    img = Image.new("RGBA", (SIZE, SIZE), BACKGROUND2)
    draw = ImageDraw.Draw(img)
    cx, cy = SIZE//2, SIZE//2

    # Soft vignette background
    for i in range(0, 20):
        r = 30 + i*12
        col = tuple(int(250 - i*1.1) for _ in range(3)) + (255,)
        draw.ellipse([cx-r, cy-r, cx+r, cy+r], outline=col, width=1)

    # Left field: cool gray settling column
    lw, lh = 96, 210
    lx0, ly0 = cx - lw - 30, cy - lh//2
    rounded_rect(draw, [lx0, ly0, lx0+lw, ly0+lh], 28, COOL_GRAY)

    # Right field: flow wedge (pointing right)
    wx0, wy0, wx1 = cx + 40, cy - 95, cx + 170
    draw.polygon([(wx0, wy0), (wx1, cy), (wx0, cy + 95)], fill=ACCENT_BLUE)

    # Diagonal separator
    line(draw, cx - 80, cy - 80, cx + 80, cy + 80, DARK, width=7)

    # Left chill ticks (descending inside column)
    line(draw, lx0 + 40, ly0 + 40, lx0 + 25, ly0 + 60, WHITE, width=6)
    line(draw, lx0 + 40, ly0 + 70, lx0 + 25, ly0 + 90, WHITE, width=6)
    line(draw, lx0 + 40, ly0 + 100, lx0 + 25, ly0 + 120, WHITE, width=6)

    # Right flow chevron (inside wedge)
    line(draw, cx + 80, cy - 22, cx + 115, cy, ACCENT_VIOLET, width=7)
    line(draw, cx + 115, cy, cx + 80, cy + 22, ACCENT_VIOLET, width=7)

    # Keel accent line (bottom)
    line(draw, cx - 70, cy + 105, cx + 70, cy + 105, DARK, width=5)

    save(f"{OUTDIR}/kjol-icon-03-geometric-split.png", img)


# ======================================================================
# ICON 4 — Typographic-ø hero
#           Stylized ø as the hero; slightly abstract, clean bowl,
#           diagonal stroke with inner glow line; crisp glyphs.
# ======================================================================
def icon4():
    img = Image.new("RGBA", (SIZE, SIZE), BACKGROUND2)
    draw = ImageDraw.Draw(img)
    cx, cy = SIZE//2, SIZE//2
    r = 185
    stroke_w = 16

    # Bowl: two-tone via two arcs
    # Left arc (cool)
    radial_line(draw, cx, cy, r, 135, 315, COOL_GRAY, width=20, step=2)
    # Right arc (accent)
    radial_line(draw, cx, cy, r, 315, 135, ACCENT_BLUE, width=20, step=2)
    # note: 315→135 wraps through 360/0; we want right side from 315° → 495°
    radial_line(draw, cx, cy, r, 315, 495, ACCENT_BLUE, width=20, step=2)

    # Interior fills
    diagonal_half_polygon(draw, cx, cy, r - 16, ACCENT_BLUE, "right", angle=135, inset=0)
    diagonal_half_polygon(draw, cx, cy, r - 16, COOL_GRAY, "left", angle=135, inset=0)

    # Diagonal stroke (thick, dark)
    ø_stroke(draw, cx, cy, r + 8, stroke_w, DARK, angle=135)
    # Inner secondary stroke (glow line)
    radial_line(draw, cx, cy, r - 8, 130, 140, ACCENT_VIOLET, width=5, step=1)
    radial_line(draw, cx, cy, r - 8, 310, 320, ACCENT_VIOLET, width=5, step=1)

    # Flow glyph right
    line(draw, cx + 45, cy - 45, cx + 90, cy, ACCENT_VIOLET, width=9)
    line(draw, cx + 90, cy, cx + 45, cy + 45, ACCENT_VIOLET, width=9)
    # Chill glyph left
    line(draw, cx - 35, cy + 30, cx - 55, cy + 55, WHITE, width=6)
    line(draw, cx - 18, cy + 55, cx - 38, cy + 80, WHITE, width=6)

    # Keel dot
    circle_filled(draw, cx, cy, 8, DARK)

    # Outer frame ring
    draw.ellipse([cx-r-16, cy-r-16, cx+r+16, cy+r+16],
                 outline=(210, 212, 218, 255), width=3)
    save(f"{OUTDIR}/kjol-icon-04-typographic-ø.png", img)


# ======================================================================
# ICON 5 — Minimal-ink Ø
#           Close to a single stroke; two-tone halves implied by thin
#           accent vs cool; diagonal stroke as the only strong line;
#           restrained, almost typographic.
# ======================================================================
def icon5():
    img = Image.new("RGBA", (SIZE, SIZE), BACKGROUND)
    draw = ImageDraw.Draw(img)
    cx, cy = SIZE//2, SIZE//2
    r = 178
    stroke_w = 22

    # Bowl as two separate open arcs (gaps at diagonal)
    radial_line(draw, cx, cy, r, 315, 135, COOL_GRAY, width=stroke_w, step=2)
    radial_line(draw, cx, cy, r, 135, 315, COOL_GRAY, width=stroke_w, step=2)
    # (draws full bowl in cool) then overlay right half accent

    # Right-half accent overlay — just draw the right arc again on top
    for a in range(315, 496, 2):
        ra = math.radians(a)
        x = cx + r*math.cos(ra)
        y = cy + r*math.sin(ra)
        x_next = cx + r*math.cos(math.radians(a+2))
        y_next = cy + r*math.sin(math.radians(a+2))
        draw.line([(x, y), (x_next, y_next)], fill=ACCENT_BLUE, width=stroke_w, joint="curve")

    # Diagonal stroke (the only strong separator)
    ø_stroke(draw, cx, cy, r + 6, 14, DARK, angle=135)

    # Minimal: accent chevron (right) + tiny tick (left)
    line(draw, cx + 36, cy - 36, cx + 66, cy, ACCENT_VIOLET, width=6)
    line(draw, cx - 36, cy + 36, cx - 55, cy + 55, WHITE, width=5)

    # Keel dot
    circle_filled(draw, cx, cy, 6, ACCENT_VIOLET)

    save(f"{OUTDIR}/kjol-icon-05-minimal-ink-ø.png", img)


# ======================================================================
# Run all
# ======================================================================
print("\n=== Kjol icon exploration renders ===")
for func in (icon1, icon2, icon3, icon4, icon5):
    func()
print(f"\nAll renders saved to: {OUTDIR}/")
print("Files:")
for f in sorted(os.listdir(OUTDIR)):
    print(f"  {f}")
