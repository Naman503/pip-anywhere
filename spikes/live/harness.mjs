// Launches Chromium (Chrome for Testing) on testpage.html and reports, every 2 s, the
// page's own frame rate, visibility and the input it received. Used to measure Live Apps.
// Usage: CHROMIUM_PATH=… node spikes/live/harness.mjs [seconds]   (run from repo root)
import { createRequire } from 'node:module';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execSync } from 'node:child_process';

const require = createRequire(resolve('extension/package.json'));
const { chromium } = require('playwright');
const seconds = Number(process.argv[2] ?? 120);

const context = await chromium.launchPersistentContext(mkdtempSync(join(tmpdir(), 'live-')), {
  ...(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : { channel: 'chromium' }),
  headless: false,
  viewport: null,
  args: ['--window-size=1100,760', '--window-position=120,120'],
});
const page = context.pages()[0] ?? (await context.newPage());
await page.goto('file://' + resolve('spikes/live/testpage.html'));
// WINDOW_STATE=maximized|fullscreen puts the window in that state (to test moving it).
if (process.env.WINDOW_STATE) {
  const cdp = await context.newCDPSession(page);
  const { windowId } = await cdp.send('Browser.getWindowForTarget');
  await cdp.send('Browser.setWindowBounds', { windowId, bounds: { windowState: process.env.WINDOW_STATE } });
  await new Promise((r) => setTimeout(r, 1500));
}
const pid = execSync('pgrep -n -x "Google Chrome for Testing"').toString().trim();
console.log(JSON.stringify({ ready: true, pid: Number(pid) }));

// CONTENT_FULLSCREEN_AT=s1,s2: click the page's "Video full screen" button (like a video's
// full-screen control) after s1 seconds, leave content full screen after s2.
if (process.env.CONTENT_FULLSCREEN_AT) {
  const [enter, leave] = process.env.CONTENT_FULLSCREEN_AT.split(',').map(Number);
  setTimeout(() => page.click('#fs').catch(() => {}), enter * 1000);
  if (leave) setTimeout(() => page.evaluate(() => document.exitFullscreen()).catch(() => {}), leave * 1000);
}
// FULLSCREEN_AT=s1,s2: enter native full screen after s1 seconds, leave it after s2.
if (process.env.FULLSCREEN_AT) {
  const [enter, leave] = process.env.FULLSCREEN_AT.split(',').map(Number);
  const cdp = await context.newCDPSession(page);
  const { windowId } = await cdp.send('Browser.getWindowForTarget');
  setTimeout(() => cdp.send('Browser.setWindowBounds', { windowId, bounds: { windowState: 'fullscreen' } }).catch(() => {}), enter * 1000);
  if (leave) setTimeout(() => cdp.send('Browser.setWindowBounds', { windowId, bounds: { windowState: 'normal' } }).catch(() => {}), leave * 1000);
}
const end = Date.now() + seconds * 1000;
while (Date.now() < end) {
  await new Promise((r) => setTimeout(r, 2000));
  try {
    const s = await page.evaluate(() => ({
      fps: window.__fps,
      visibility: document.visibilityState,
      focused: document.hasFocus(),
      field: document.getElementById('field').value,
      scrollTop: document.getElementById('list').scrollTop,
      size: `${innerWidth}x${innerHeight}`,
      contentFullscreen: !!document.fullscreenElement,
      events: window.__log.slice(-6),
    }));
    console.log(JSON.stringify({ t: Math.round((end - Date.now()) / 1000), ...s }));
  } catch (e) {
    console.log(JSON.stringify({ error: String(e).slice(0, 120) }));
  }
}
await context.close();
