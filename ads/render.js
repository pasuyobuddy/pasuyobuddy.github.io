// Render an ad page to MP4: node render.js <page.html> <w> <h> <lang> <music.wav> <out.mp4>
// Needs a local web server serving the repo root on http://127.0.0.1:8766 and ffmpeg on PATH.
const { chromium } = require("playwright");
const { execFileSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const [, , page, w, h, lang, music, out] = process.argv;
const FPS = 30;

(async () => {
  const dir = fs.mkdtempSync(path.join(process.env.FRAMES_DIR || os.tmpdir(), "frames-"));
  const browser = await chromium.launch();
  const p = await browser.newPage({ viewport: { width: +w, height: +h } });
  const errors = [];
  p.on("pageerror", (e) => errors.push(e.message));
  await p.goto(`http://127.0.0.1:8766/ads/${page}?w=${w}&h=${h}&lang=${lang}`);
  await p.waitForLoadState("networkidle");
  await p.evaluate(() => document.fonts.ready);
  const dur = await p.evaluate(() => window.DURATION);
  const frames = Math.round(dur * FPS);
  for (let i = 0; i < frames; i++) {
    await p.evaluate((t) => window.renderAt(t), i / FPS);
    await p.screenshot({ path: path.join(dir, String(i).padStart(5, "0") + ".jpg"), type: "jpeg", quality: 92 });
  }
  await browser.close();
  if (errors.length) console.error("page errors:", errors);
  execFileSync("ffmpeg", ["-y", "-loglevel", "error", "-framerate", String(FPS), "-i", path.join(dir, "%05d.jpg"), "-i", music,
    "-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p", "-r", String(FPS),
    "-c:a", "aac", "-b:a", "192k", "-shortest", "-movflags", "+faststart", out]);
  fs.rmSync(dir, { recursive: true, force: true });
  console.log("done", out, frames, "frames");
})().catch((e) => { console.error(e); process.exit(1); });
