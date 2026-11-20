// Renders og.html to public/og.jpg and favicon.svg to public/favicon-32.png and favicon.ico.
// Start `bunx wrangler dev --port 8788` in Site/, then `node og/render.mjs` (Playwright).
// og.html is copied into public/ for the shot and removed after; its inline style needs bypassCSP.
import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';
const here = path.dirname(new URL(import.meta.url).pathname);
const pub = path.join(here, '..', 'public');
const base = process.env.SITE || 'http://localhost:8788';
fs.copyFileSync(path.join(here, 'og.html'), path.join(pub, 'og-render.html'));
const browser = await chromium.launch();
try {
  const og = await (await browser.newContext({ viewport: { width: 1200, height: 630 }, bypassCSP: true })).newPage();
  await og.goto(`${base}/og-render`, { waitUntil: 'networkidle' });
  await og.screenshot({ path: path.join(pub, 'og.jpg'), type: 'jpeg', quality: 86 });

  const ic = await (await browser.newContext({ viewport: { width: 32, height: 32 } })).newPage();
  await ic.setContent(`<style>html,body{margin:0;background:transparent}</style><img src="${base}/favicon.svg" width="32" height="32">`);
  await ic.waitForLoadState('networkidle');
  const png = await ic.screenshot({ omitBackground: true });
  fs.writeFileSync(path.join(pub, 'favicon-32.png'), png);
  // An .ico holding that PNG (one 32×32 entry): header, directory entry, image.
  const head = Buffer.alloc(22);
  head.writeUInt16LE(0, 0); head.writeUInt16LE(1, 2); head.writeUInt16LE(1, 4);
  head.writeUInt8(32, 6); head.writeUInt8(32, 7); head.writeUInt8(0, 8); head.writeUInt8(0, 9);
  head.writeUInt16LE(1, 10); head.writeUInt16LE(32, 12); head.writeUInt32LE(png.length, 14); head.writeUInt32LE(22, 18);
  fs.writeFileSync(path.join(pub, 'favicon.ico'), Buffer.concat([head, png]));
} finally {
  await browser.close();
  fs.rmSync(path.join(pub, 'og-render.html'));
}
