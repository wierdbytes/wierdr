// node og/uncarrier.mjs ../docs/screenshots/iphone-live-activity.jpg shots/iphone-lock.png
// Paints over the Simulator's "Carrier" on the lock screen shot: each pixel of the box is
// interpolated from the box's four edges (the wallpaper there is a smooth gradient).
import { chromium } from 'playwright';
import fs from 'node:fs';
const [src, dst] = process.argv.slice(2);
const b = await chromium.launch();
const p = await b.newPage();
const data = 'data:image/jpeg;base64,' + fs.readFileSync(src).toString('base64');
const out = await p.evaluate(async (data) => {
  const img = new Image(); img.src = data; await img.decode();
  const c = document.createElement('canvas'); c.width = img.width; c.height = img.height;
  const g = c.getContext('2d'); g.drawImage(img, 0, 0);
  const x0 = 120, y0 = 28, x1 = 325, y1 = 126; // "Carrier", in 1284×2778
  const d = g.getImageData(0, 0, c.width, c.height); const a = d.data; const W = c.width;
  const px = (x, y) => { const i = (y * W + x) * 4; return [a[i], a[i + 1], a[i + 2]]; };
  for (let y = y0; y <= y1; y++) for (let x = x0; x <= x1; x++) {
    const L = px(x0 - 1, y), R = px(x1 + 1, y), T = px(x, y0 - 1), B = px(x, y1 + 1);
    const wl = 1 / (x - x0 + 1), wr = 1 / (x1 - x + 1), wt = 1 / (y - y0 + 1), wb = 1 / (y1 - y + 1);
    const s = wl + wr + wt + wb; const i = (y * W + x) * 4;
    for (let k = 0; k < 3; k++) a[i + k] = (L[k] * wl + R[k] * wr + T[k] * wt + B[k] * wb) / s;
  }
  g.putImageData(d, 0, 0);
  return c.toDataURL('image/png');
}, data);
fs.writeFileSync(dst, Buffer.from(out.split(',')[1], 'base64'));
await b.close();
