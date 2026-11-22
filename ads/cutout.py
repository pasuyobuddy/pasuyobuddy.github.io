"""Cut a vehicle picture out of its white background (keeps white parts inside the vehicle).
Usage: python3 cutout.py in.png out.png"""
import sys
import numpy as np, cv2
from PIL import Image
im = np.array(Image.open(sys.argv[1]).convert("RGB")); h, w = im.shape[:2]
near_white = (im.min(axis=2) > 228).astype(np.uint8)
bg = np.zeros((h, w), np.uint8)
seeds = [(x, 0) for x in range(0, w, 6)] + [(x, h - 1) for x in range(0, w, 6)] + [(0, y) for y in range(0, h, 6)] + [(w - 1, y) for y in range(0, h, 6)]
for (x, y) in seeds:
    if near_white[y, x] and not bg[y, x]:
        m = np.zeros((h + 2, w + 2), np.uint8)
        cv2.floodFill(near_white.copy(), m, (x, y), 2, flags=4 | (255 << 8) | cv2.FLOODFILL_MASK_ONLY)
        bg |= m[1:-1, 1:-1]
alpha = np.where(bg > 0, 0, 255).astype(np.uint8)
# drop pale floor shadow under the vehicle (unsaturated light gray touching the background)
rgb = im.astype(int); pale = ((rgb.min(2) > 150) & ((rgb.max(2) - rgb.min(2)) < 22)).astype(np.uint8)
pale[: int(h * 0.55)] = 0
n, lab = cv2.connectedComponents(pale, connectivity=8)
trans = cv2.dilate((alpha == 0).astype(np.uint8), np.ones((3, 3), np.uint8))
for i in range(1, n):
    comp = lab == i
    if (comp & (trans > 0)).any(): alpha[comp] = 0
alpha = cv2.GaussianBlur(cv2.erode(alpha, np.ones((2, 2), np.uint8)), (0, 0), 0.8)
out = Image.fromarray(np.dstack([im, alpha]), "RGBA").resize((w * 2, h * 2), Image.LANCZOS)
ys, xs = np.where(np.array(out)[..., 3] > 10); out = out.crop((xs.min(), ys.min(), xs.max() + 1, ys.max() + 1))
out.save(sys.argv[2]); print(sys.argv[2], out.size)
