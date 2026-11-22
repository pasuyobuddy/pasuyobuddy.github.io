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
patch = clean[796:828, 586:650].astype(np.float32)
feather = np.ones((32, 64), np.float32)
feather[:6] = np.linspace(0, 1, 6)[:, None]
feather[:, :6] *= np.linspace(0, 1, 6)[None, :]
feather[:, -6:] *= np.linspace(1, 0, 6)[None, :]
dst = clean[830:862, 586:650].astype(np.float32)
keep = skin[830:862, 586:650] & (np.arange(830, 862)[:, None] >= 858)   # don't paint over the finger
fw = (feather * ~keep)[..., None]
clean[830:862, 586:650] = (dst * (1 - fw) + patch * fw).astype(np.uint8)

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

def place(base_bgr, cx, cy, width, angle=0.0, blur=0.0, shade_strength=0.9):
    lw = width
    lh = int(logo_rgba.height * lw / logo_rgba.width)
    lg = logo_rgba.resize((lw, lh), Image.LANCZOS).rotate(angle, resample=Image.BICUBIC, expand=True)
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
    shade = shade * np.clip(light, 0.75, 1.15) ** 0.6
    rgb = arr[..., :3][..., ::-1] * shade[..., None] * 0.97              # to BGR, slight ink darkening
    a = arr[..., 3:4] * 0.97
    out = region * (1 - a) + np.clip(rgb, 0, 1) * a
    base_bgr[y0:y0 + h, x0:x0 + w] = (out * 255).astype(np.uint8)

place(clean, cx=724, cy=856, width=172, angle=3, blur=0.35)          # chest print, right of the fingertip
place(clean, cx=1048, cy=628, width=218, angle=0, blur=1.8, shade_strength=0.7)  # on the bag, clear of the shoulder (bag is out of focus)

Image.fromarray(cv2.cvtColor(clean, cv2.COLOR_BGR2RGB)).save(out_path)
Image.fromarray(mask).save(out_path.replace(".png", "_mask.png"))
print("saved", out_path)
