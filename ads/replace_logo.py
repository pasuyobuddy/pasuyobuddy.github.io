"""Replace the wrong logo on the model photo (shirt + delivery bag) with the real PasuyoBuddy logo.

Usage: python3 replace_logo.py <photo> <logo.png> <out.png>
"""
import sys

import cv2
import numpy as np
from PIL import Image, ImageFilter

photo_path, logo_path, out_path = sys.argv[1:4]
img = cv2.cvtColor(np.array(Image.open(photo_path).convert("RGB")), cv2.COLOR_RGB2BGR)
H, W = img.shape[:2]

# ---------------------------------------------------------------- 1. erase old logos
def logo_mask(box):
    """Everything inside the box that is not plain red fabric (the old print and its soft halo)."""
    x0, y0, x1, y1 = box
    b, g, r = [img[y0:y1, x0:x1, i].astype(int) for i in range(3)]
    fabric = (r > 90) & (g < 62) & (b < 72) & (np.abs(g - b) < 22)
    shadow = (r < 120) & (g < 50) & (b < 50)                 # dark folds / bag trim
    m = np.zeros((H, W), np.uint8)
    m[y0:y1, x0:x1] = ((~fabric & ~shadow) * 255).astype(np.uint8)
    return m

SHIRT = (596, 806, 818, 910)
BAG = (812, 568, 1212, 758)
mask = logo_mask(SHIRT) | logo_mask(BAG)
mask = cv2.dilate(mask, np.ones((5, 5), np.uint8), iterations=2)
mask[832:862, 590:645] = 255                              # leftover haze just above the fingertip
# never touch the skin of the pointing finger
b, g, r = [img[:, :, i].astype(int) for i in range(3)]
skin = (r > 150) & (g > 95) & (b > 75) & (r - b > 25) & (r - g > 15)
finger = np.zeros_like(skin)
finger[860:940, 440:632] = True                          # only around the pointing finger
mask[skin & finger] = 0
clean = cv2.inpaint(img, mask, 15, cv2.INPAINT_NS)
# smooth only the repaired area a little so the fill matches the soft fabric
soft = cv2.GaussianBlur(clean, (0, 0), 2.2)
mm = cv2.GaussianBlur(mask.astype(np.float32) / 255, (0, 0), 3)[..., None]
clean = (clean * (1 - mm * 0.7) + soft * (mm * 0.7)).astype(np.uint8)
# above the fingertip: copy clean fabric from just above (inpainting there borrows skin colour)
Y0, Y1, X0, X1 = 808, 868, 586, 652
patch = img[Y0 - 78:Y1 - 78, X0:X1].astype(np.float32)       # plain chest fabric higher up (untouched original)
hh, ww = Y1 - Y0, X1 - X0
feather = np.ones((hh, ww), np.float32)
feather[:8] *= np.linspace(0, 1, 8)[:, None]
feather[:, :8] *= np.linspace(0, 1, 8)[None, :]
feather[:, -8:] *= np.linspace(1, 0, 8)[None, :]
o_ = img[Y0:Y1, X0:X1].astype(int)
finger_px = (o_[..., 2] > 150) & (o_[..., 1] > 95) & (o_[..., 0] > 70) & (o_[..., 2] < 245)  # BGR: skin of the fingertip
finger_px &= (np.arange(Y0, Y1)[:, None] >= 860)
keep = cv2.dilate(finger_px.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
fw = (feather * ~keep)[..., None]
dst = clean[Y0:Y1, X0:X1].astype(np.float32)
clean[Y0:Y1, X0:X1] = (dst * (1 - fw) + patch * fw).astype(np.uint8)

# the man's shoulder overlaps the bag: keep the original pixels there (incl. its natural rim light)
ys_, xs_ = np.mgrid[0:H, 0:W]
edge_y = np.interp(xs_, [780, 950, 1010, 1060], [652, 745, 838, 960])
shoulder = (ys_ > edge_y - 2) & (xs_ < 1060) & (ys_ > 560) & (ys_ < 800) & (xs_ > 780)
clean[shoulder] = img[shoulder]

# ---------------------------------------------------------------- 2. real logo with transparent background
logo = Image.open(logo_path).convert("RGB")
la = np.array(logo).astype(int)
bg = la[5, 5]
dist = np.sqrt(((la - bg) ** 2).sum(axis=2))
alpha = np.clip((dist - 14) / 36, 0, 1)
ys, xs = np.where(alpha > 0.05)
crop = (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1)
rgba = np.dstack([la, (alpha * 255).astype(int)]).astype(np.uint8)[crop[1]:crop[3], crop[0]:crop[2]]
logo_rgba = Image.fromarray(rgba, "RGBA")

def place(base_bgr, cx, cy, width, angle=0.0, blur=0.0, shade_strength=0.9, trim=0, flatten=0.0, grain=0.0, seed=1):
    """Print the logo onto fabric.
    angle: degrees (negative = clockwise; the logo itself is drawn rising ~11°, so -11 makes it level)
    trim: pixels to shave off the logo's outer border (looks less like a sticker)
    flatten: 0..1 lower contrast/saturation to match a soft, out-of-focus area
    grain: amount of fabric noise
    """
    lw = width
    lh = int(logo_rgba.height * lw / logo_rgba.width)
    lg = logo_rgba.resize((lw, lh), Image.LANCZOS)
    if trim:
        a_ = np.array(lg)[..., 3]
        a_ = cv2.erode(a_, np.ones((3, 3), np.uint8), iterations=trim)
        arr_ = np.array(lg); arr_[..., 3] = a_; lg = Image.fromarray(arr_, "RGBA")
    lg = lg.rotate(angle, resample=Image.BICUBIC, expand=True)
    if blur:
        lg = lg.filter(ImageFilter.GaussianBlur(blur))
    arr = np.array(lg).astype(np.float32) / 255
    h, w = arr.shape[:2]
    x0, y0 = int(cx - w / 2), int(cy - h / 2)
    region = base_bgr[y0:y0 + h, x0:x0 + w].astype(np.float32) / 255
    # fabric light/shadow under the print, so folds show through
    gray = cv2.cvtColor((region * 255).astype(np.uint8), cv2.COLOR_BGR2GRAY).astype(np.float32)
    local = cv2.GaussianBlur(gray, (0, 0), 25) + 1
    shade = np.clip((gray / local), 0.7, 1.25) ** shade_strength
    light = cv2.GaussianBlur(gray, (0, 0), 40) / max(1.0, gray.mean())   # broad lighting gradient
    shade = shade * np.clip(light, 0.75, 1.15) ** 0.8
    rgb = arr[..., :3][..., ::-1]                                       # to BGR
    if flatten:
        # pull the ink toward the fabric colour underneath: less contrast, less saturation, lifted blacks
        fabric = cv2.GaussianBlur(region, (0, 0), 12)
        lum = rgb.mean(axis=2, keepdims=True)
        rgb = rgb * (1 - flatten * 0.35) + lum * (flatten * 0.35)         # desaturate a bit
        rgb = rgb * (1 - flatten * 0.25) + fabric * (flatten * 0.25)      # tint with the fabric/ambient light
        rgb = 0.08 * flatten + rgb * (1 - 0.08 * flatten)                  # lift pure blacks (haze/defocus)
    rgb = rgb * shade[..., None] * 0.97
    if grain:
        rng = np.random.default_rng(seed)
        rgb = rgb + rng.normal(0, grain, rgb.shape[:2])[..., None]
    a = arr[..., 3:4] * 0.95
    out = region * (1 - a) + np.clip(rgb, 0, 1) * a
    base_bgr[y0:y0 + h, x0:x0 + w] = (np.clip(out, 0, 1) * 255).astype(np.uint8)

# chest print: level the text (logo is drawn slanted), slight follow of the chest angle
place(clean, cx=722, cy=852, width=168, angle=-8, blur=0.45, trim=1, flatten=0.15, grain=0.012)
# bag: level, out of focus like the rest of the bag, softer and tinted by the scene light
place(clean, cx=1050, cy=636, width=224, angle=-11, blur=2.4, shade_strength=0.8, trim=3, flatten=0.55, grain=0.01, seed=2)

Image.fromarray(cv2.cvtColor(clean, cv2.COLOR_BGR2RGB)).save(out_path)
Image.fromarray(mask).save(out_path.replace(".png", "_mask.png"))
print("saved", out_path)
