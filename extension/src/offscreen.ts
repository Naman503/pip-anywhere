// Offscreen document: owns the tab-capture stream, the encoder, and the
// connection to the app. Offscreen documents only get chrome.runtime, so tab
// actions go back through the service worker.
import { AppConnection } from './connection';
import type { ExtMessage, VideoRect } from './protocol';
import { MAX_FPS, Streamer } from './streamer';

let session: { tabId: number; stream: MediaStream; streamer: Streamer; app: AppConnection } | null = null;

const notify = (msg: ExtMessage) => chrome.runtime.sendMessage(msg).catch(() => {});

async function start(streamId: string, tabId: number, rect: VideoRect, port: number) {
  stop('replaced');

  const app = new AppConnection();
  try {
    await app.open(port);
  } catch (err) {
    notify({ type: 'pip:error', message: (err as Error).message });
    return;
  }

  // Video only: capturing audio would mute the tab; the tab keeps playing sound.
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: false,
    video: {
      mandatory: {
        chromeMediaSource: 'tab',
        chromeMediaSourceId: streamId,
        // The tab's real pixel size; larger maxima make Chrome upscale every frame.
        maxWidth: Math.round(rect.viewportWidth * rect.devicePixelRatio),
        maxHeight: Math.round(rect.viewportHeight * rect.devicePixelRatio),
        maxFrameRate: MAX_FPS,
      },
    } as MediaTrackConstraints,
  });
  const [track] = stream.getVideoTracks();
  const streamer = new Streamer(app);
  streamer.crop = rect;
  session = { tabId, stream, streamer, app };

  app.onMessage = (msg) => {
    if (msg.type === 'command') notify({ type: 'pip:app-command', action: msg.action, value: msg.value });
    else if (msg.type === 'keyframe') streamer.requestKeyframe();
  };
  app.onClose = () => end('app disconnected');
  track.addEventListener('ended', () => end('capture ended'));

  void streamer.run(track);
}

/** Stops streaming; the app is told why. */
function stop(reason: string) {
  if (!session) return;
  const { stream, streamer, app } = session;
  session = null;
  streamer.stop();
  for (const t of stream.getTracks()) t.stop();
  app.sendText({ type: 'stop', reason });
  app.close();
}

/** Stops because of something on this side, and tells the service worker. */
function end(reason: string) {
  if (!session) return;
  stop(reason);
  notify({ type: 'pip:ended', reason });
}

chrome.runtime.onMessage.addListener((msg: ExtMessage, sender) => {
  switch (msg.type) {
    case 'pip:start':
      void start(msg.streamId, msg.tabId, msg.rect, msg.port).catch((err) => {
        console.error('[PiP] start failed', err);
        end('start failed');
        notify({ type: 'pip:error', message: String(err) });
      });
      break;
    case 'pip:stop':
      stop(msg.reason);
      break;
    case 'pip:rect':
      if (session && sender.tab?.id === session.tabId) session.streamer.crop = msg.rect;
      break;
    case 'pip:state':
      if (session && sender.tab?.id === session.tabId) session.app.sendText({ type: 'state', ...msg.state });
      break;
  }
});
