// End-to-end: runs the real app + the unpacked extension in Playwright Chromium.
//
//   node tests/e2e.mjs pipeline    test.html canvas → encoder → app (no tab capture)
//   node tests/e2e.mjs youtube     tab capture of a YouTube video, commands from the
//                                  app, then minimises the browser (spike S1)
//
// Needs: npm run build, and ../app/scripts/bundle.sh. Set CHROMIUM_PATH to reuse
// a downloaded Chromium. --allowlisted-extension-id lets the test start tab
// capture without a real click on the toolbar button.
import { chromium } from 'playwright';
import { spawn, execFileSync } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';

const mode = process.argv[2] ?? 'pipeline';
const EXT_ID = 'angpoecfkgeeclnkdmafakhldmadjdih';
const ext = resolve('dist');
const appBin = resolve('../app/build/PiP Anywhere.app/Contents/MacOS/PiPAnywhere');
// Override with VIDEO=... ; a 60 fps video checks that the window keeps up.
const VIDEO = process.env.VIDEO ?? 'https://www.youtube.com/watch?v=aircAruvnKk';

const results = [];
const check = (name, ok, detail = '') => {
  results.push(ok);
  console.log(`${ok ? '✅' : '❌'} ${name}${detail ? ` — ${detail}` : ''}`);
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// --- the app, with its log captured ---
const appLog = [];
// A spare port, so a copy of the app you're already running isn't disturbed.
const PORT = 47899;
const app = spawn(appBin, ['--port', String(PORT)], { stdio: ['ignore', 'ignore', 'pipe'] });
app.stderr.on('data', (d) => {
  for (const line of String(d).split('\n').filter(Boolean)) {
    appLog.push(line);
    if (process.env.VERBOSE) console.log('  app:', line);
  }
});
const lastStats = () => {
  const line = [...appLog].reverse().find((l) => l.includes('stats:'));
  const m = line && /stats: (\d+)×(\d+) · (\d+) fps(.*)/.exec(line);
  return m ? { width: +m[1], height: +m[2], fps: +m[3], rest: m[4].trim(), line } : null;
};
/** Waits for a stats line logged after `since` (app logs one every 5 s). */
async function freshStats(sinceIndex, minFps = 15, timeout = 15_000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const line = appLog.slice(sinceIndex).reverse().find((l) => l.includes('stats:'));
    // Encoder start-up makes the first report low; wait for a steady one.
    if (line && lastStats()?.fps >= minFps) return lastStats();
    await sleep(250);
  }
  return appLog.slice(sinceIndex).some((l) => l.includes('stats:')) ? lastStats() : null;
}
const sendCommand = (cmd) => execFileSync('swift', [resolve('../spikes/send-command.swift'), cmd, '--port', String(PORT)]);

const context = await chromium.launchPersistentContext(mkdtempSync(join(tmpdir(), 'pip-e2e-')), {
  ...(process.env.CHROMIUM_PATH ? { executablePath: process.env.CHROMIUM_PATH } : { channel: 'chromium' }),
  headless: mode === 'pipeline',
  viewport: { width: 1280, height: 800 },
  args: [
    `--disable-extensions-except=${ext}`,
    `--load-extension=${ext}`,
    `--allowlisted-extension-id=${EXT_ID}`,
    '--autoplay-policy=no-user-gesture-required',
  ],
});

try {
  await sleep(1000);
  check('app listening', appLog.some((l) => l.includes(`listening on ws://127.0.0.1:${PORT}`)));

  if (mode === 'pipeline') {
    const page = await context.newPage();
    await page.goto(`chrome-extension://${EXT_ID}/test.html?autostart&port=${PORT}`);
    const start = appLog.length;
    const stats = await freshStats(start);
    check('app receives the stream', !!stats && stats.fps >= 20, stats?.line ?? 'no stats');
    check('extension origin accepted', !appLog.some((l) => l.includes('rejected WebSocket')));
    check('playback state arrives', !!stats?.rest.includes('Extension test stream'), stats?.rest);
  }

  if (mode === 'youtube') {
    const page = await context.newPage();
    await page.goto(VIDEO, { waitUntil: 'domcontentloaded' });
    await page.waitForSelector('video', { timeout: 30_000 });
    await page.waitForFunction(() => document.querySelector('video')?.currentTime > 1, null, { timeout: 30_000 });
    // Small test windows get low-res 30 fps formats; ask for 1080p (60 fps where the video has it).
    await page.evaluate(() => document.getElementById('movie_player')?.setPlaybackQualityRange?.('hd1080', 'hd1080'));
    await sleep(3000);

    const sw = context.serviceWorkers()[0] ?? (await context.waitForEvent('serviceworker'));
    await sw.evaluate((port) => chrome.storage.local.set({ appPort: port }), PORT);
    const tabId = await sw.evaluate(async () => (await chrome.tabs.query({ url: '*://www.youtube.com/*' }))[0].id);
    let start = appLog.length;
    await sw.evaluate((id) => globalThis.pipToggleTab(id), tabId);
    const stats = await freshStats(start);
    check('tab capture streams to the app', !!stats && stats.fps >= 15, stats?.line ?? appLog.slice(-5).join(' | '));
    check('video is cropped (not the whole tab)', !!stats && stats.width / stats.height > 1.6 && stats.width / stats.height < 1.9, stats ? `${stats.width}×${stats.height}` : '');
    check('title + playing state reach the app', !!stats?.rest.includes('playing'), stats?.rest);

    // Frame rate: frames the page decodes per second vs frames the window receives.
    const pageFps = await page.evaluate(async () => {
      const v = document.querySelector('video');
      const frames = () => v.getVideoPlaybackQuality().totalVideoFrames - v.getVideoPlaybackQuality().droppedVideoFrames;
      const a = frames();
      await new Promise((r) => setTimeout(r, 4000));
      return (frames() - a) / 4;
    });
    const steady = await freshStats(appLog.length, 1);
    check('window frame rate keeps up with the video', !!steady && steady.fps >= pageFps * 0.85,
      `video ${pageFps.toFixed(0)} fps → window ${steady?.fps} fps (${steady?.width}×${steady?.height})`);

    const videoState = () => page.evaluate(() => ({ paused: document.querySelector('video').paused, t: document.querySelector('video').currentTime }));
    sendCommand('pause');
    await sleep(1200);
    check('app → tab: pause', (await videoState()).paused === true);
    const before = (await videoState()).t;
    sendCommand('seek:30');
    await sleep(1200);
    const after = (await videoState()).t;
    check('app → tab: seek +30 s', after - before > 25, `${before.toFixed(1)} → ${after.toFixed(1)}`);
    sendCommand('play');
    await sleep(1200);
    check('app → tab: play', (await videoState()).paused === false);

    const audio = () => page.evaluate(() => ({ volume: document.querySelector('video').volume, muted: document.querySelector('video').muted }));
    sendCommand('volume:0.3');
    await sleep(1200);
    check('app → tab: volume 30%', Math.abs((await audio()).volume - 0.3) < 0.01, JSON.stringify(await audio()));
    sendCommand('mute:1');
    await sleep(1200);
    check('app → tab: mute', (await audio()).muted === true);
    sendCommand('mute:0');
    await sleep(1200);
    check('app → tab: unmute', (await audio()).muted === false);

    // Spike S1: does capture keep producing frames when the browser window is hidden?
    const cdp = await context.newCDPSession(page);
    const { windowId } = await cdp.send('Browser.getWindowForTarget');
    await cdp.send('Browser.setWindowBounds', { windowId, bounds: { windowState: 'minimized' } });
    await sleep(6000);
    start = appLog.length;
    const hidden = await freshStats(start);
    check('S1: frames keep coming with the browser minimised', !!hidden && hidden.fps >= 15, hidden?.line ?? 'no stats');
    await cdp.send('Browser.setWindowBounds', { windowId, bounds: { windowState: 'normal' } });

    start = appLog.length;
    sendCommand('focusTab');
    await sleep(2000);
    check('back to tab ends the stream', appLog.slice(start).some((l) => l.includes('stream stopped')), appLog.slice(start).join(' | '));
  }
} finally {
  await context.close();
  app.kill();
}

const failed = results.filter((ok) => !ok).length;
console.log(`\n${results.length - failed}/${results.length} passed`);
process.exit(failed ? 1 : 0);
