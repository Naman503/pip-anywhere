// test.html: streams an animated canvas to the app through the same encoder and
// connection as real captures. Checks the app ↔ extension pipeline without
// tab capture. Open chrome-extension://<id>/test.html (add ?autostart to begin at once).
import { AppConnection } from './connection';
import { Streamer } from './streamer';

const canvas = document.querySelector('canvas')!;
const status = document.getElementById('status')!;
const button = document.querySelector('button')!;
const ctx = canvas.getContext('2d')!;

// A mock code tutorial (editor with code being "typed"), so the stream looks like
// what the app is for and screenshots carry no third-party content.
const CODE: [string, string][][] = [
  [['#c678dd', 'async function '], ['#61afef', 'fetchUser'], ['#abb2bf', '(id) {']],
  [['#abb2bf', '  '], ['#c678dd', 'const '], ['#e5c07b', 'res'], ['#abb2bf', ' = '], ['#c678dd', 'await '], ['#61afef', 'fetch'], ['#abb2bf', '(`/api/users/${id}`);']],
  [['#abb2bf', '  '], ['#c678dd', 'if '], ['#abb2bf', '(!res.ok) '], ['#c678dd', 'throw new '], ['#e5c07b', 'Error'], ['#abb2bf', '('], ['#98c379', "'not found'"], ['#abb2bf', ');']],
  [['#abb2bf', '  '], ['#c678dd', 'return '], ['#abb2bf', 'res.'], ['#61afef', 'json'], ['#abb2bf', '();']],
  [['#abb2bf', '}']],
  [['#5c6370', '']],
  [['#5c6370', '// cache results for 60 seconds']],
  [['#c678dd', 'const '], ['#e5c07b', 'cache'], ['#abb2bf', ' = '], ['#c678dd', 'new '], ['#e5c07b', 'Map'], ['#abb2bf', '();']],
];

let frame = 0;
function draw() {
  frame++;
  const { width, height } = canvas;
  ctx.fillStyle = '#1e2127';
  ctx.fillRect(0, 0, width, height);
  // Title bar
  ctx.fillStyle = '#16181d';
  ctx.fillRect(0, 0, width, 64);
  for (const [i, c] of ['#ff5f57', '#febc2e', '#28c840'].entries()) {
    ctx.fillStyle = c;
    ctx.beginPath();
    ctx.arc(36 + i * 30, 32, 9, 0, Math.PI * 2);
    ctx.fill();
  }
  ctx.fillStyle = '#7f848e';
  ctx.font = '24px ui-monospace, Menlo, monospace';
  ctx.textAlign = 'left';
  ctx.fillText('users.ts — PiP Anywhere test stream', 140, 40);

  // Code, typed out one character per frame, looping
  ctx.font = '34px ui-monospace, Menlo, monospace';
  let budget = frame % 520;
  let caret = { x: 120, y: 150 };
  CODE.forEach((line, row) => {
    const y = 150 + row * 56;
    ctx.fillStyle = '#4b5263';
    ctx.textAlign = 'right';
    ctx.fillText(String(row + 1), 80, y);
    ctx.textAlign = 'left';
    let x = 120;
    for (const [color, text] of line) {
      const shown = text.slice(0, Math.max(0, budget));
      budget -= text.length;
      ctx.fillStyle = color;
      ctx.fillText(shown, x, y);
      x += ctx.measureText(shown).width;
      if (shown.length) caret = { x, y };
    }
  });
  if (Math.floor(frame / 30) % 2 === 0) {
    ctx.fillStyle = '#528bff';
    ctx.fillRect(caret.x + 2, caret.y - 30, 3, 38);
  }
  ctx.fillStyle = '#4b5263';
  ctx.font = '20px ui-monospace, Menlo, monospace';
  ctx.textAlign = 'right';
  ctx.fillText(`frame ${frame}`, width - 30, height - 24);
  requestAnimationFrame(draw);
}
draw();

let running: { app: AppConnection; streamer: Streamer; track: MediaStreamTrack } | null = null;

async function start() {
  const app = new AppConnection();
  try {
    const port = Number(new URLSearchParams(location.search).get('port')) || undefined;
    await app.open(port);
  } catch (err) {
    status.textContent = `Could not connect: ${(err as Error).message}`;
    return;
  }
  const [track] = canvas.captureStream(60).getVideoTracks();
  const streamer = new Streamer(app);
  let time = 0;
  setInterval(() => {
    time += 1;
    app.sendText({ type: 'state', title: 'Extension test stream', site: 'test', paused: false, currentTime: time, duration: 600, rate: 1, volume: 1, muted: false });
  }, 1000);
  app.onMessage = (msg) => {
    status.textContent = `App says: ${JSON.stringify(msg)}`;
    if (msg.type === 'keyframe') streamer.requestKeyframe();
  };
  app.onClose = () => (status.textContent = 'Disconnected');
  running = { app, streamer, track };
  status.textContent = 'Streaming to the app…';
  button.textContent = 'Stop';
  void streamer.run(track);
}

function stop() {
  if (!running) return;
  running.streamer.stop();
  running.track.stop();
  running.app.sendText({ type: 'stop', reason: 'test page stopped' });
  running.app.close();
  running = null;
  status.textContent = 'Stopped';
  button.textContent = 'Start';
}

button.addEventListener('click', () => (running ? stop() : void start()));
if (location.search.includes('autostart')) void start();
