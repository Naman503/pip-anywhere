// Runs in every page: finds the main <video>, reports where it is and its
// playback state while it's popped out, and applies commands from the app.
import type { CommandAction, ExtMessage, PlaybackState, ProbeResult, VideoRect } from './protocol';

// The script can be injected twice (manifest + executeScript fallback).
const w = window as unknown as { __pipAnywhere?: boolean };
if (!w.__pipAnywhere) {
  w.__pipAnywhere = true;
  setUp();
}

function setUp() {
  let video: HTMLVideoElement | null = null;
  let tracking = false;
  let pending: ReturnType<typeof setTimeout> | undefined;
  let interval: ReturnType<typeof setInterval> | undefined;
  const resizeObserver = new ResizeObserver(() => scheduleReport());

  const send = (msg: ExtMessage) => chrome.runtime.sendMessage(msg).catch(() => {});

  /** Largest visible video, preferring ones that are playing. */
  function findVideo(): HTMLVideoElement | null {
    let best: HTMLVideoElement | null = null;
    let bestScore = 0;
    for (const v of document.querySelectorAll('video')) {
      const r = v.getBoundingClientRect();
      const visible =
        Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0)) *
        Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));
      const score = (r.width * r.height + visible) * (v.paused ? 1 : 2) * (v.readyState > 0 ? 1 : 0.1);
      if (score > bestScore) {
        best = v;
        bestScore = score;
      }
    }
    return best;
  }

  /** The picture inside the element (object-fit: contain letterboxes it). */
  function rectOf(v: HTMLVideoElement): VideoRect {
    const r = v.getBoundingClientRect();
    let { left: x, top: y, width, height } = r;
    const fit = getComputedStyle(v).objectFit;
    if (v.videoWidth && v.videoHeight && fit !== 'fill' && fit !== 'cover') {
      const scale = Math.min(width / v.videoWidth, height / v.videoHeight);
      const w2 = v.videoWidth * scale;
      const h2 = v.videoHeight * scale;
      x += (width - w2) / 2;
      y += (height - h2) / 2;
      width = w2;
      height = h2;
    }
    return { x, y, width, height, viewportWidth: innerWidth, viewportHeight: innerHeight, devicePixelRatio };
  }

  function state(v: HTMLVideoElement): PlaybackState {
    return {
      title: document.title,
      site: location.hostname.replace(/^www\./, ''),
      paused: v.paused,
      currentTime: v.currentTime,
      duration: Number.isFinite(v.duration) ? v.duration : 0,
      rate: v.playbackRate,
      volume: v.volume,
      muted: v.muted,
    };
  }

  function report() {
    pending = undefined;
    if (!tracking) return;
    // Sites like YouTube swap the element on navigation.
    if (!video || !video.isConnected) attach(findVideo());
    if (!video) return;
    send({ type: 'pip:rect', rect: rectOf(video) });
  }

  // setTimeout rather than requestAnimationFrame: rAF stops in background tabs.
  function scheduleReport() {
    if (tracking && !pending) pending = setTimeout(report, 50);
  }

  function sendState() {
    if (tracking && video) send({ type: 'pip:state', state: state(video) });
  }

  const mediaEvents = ['play', 'pause', 'ratechange', 'seeked', 'durationchange', 'loadedmetadata', 'emptied', 'volumechange'];
  function attach(v: HTMLVideoElement | null) {
    if (video === v) return;
    if (video) {
      resizeObserver.unobserve(video);
      for (const e of mediaEvents) video.removeEventListener(e, onMediaEvent);
    }
    video = v;
    if (!video) return;
    resizeObserver.observe(video);
    for (const e of mediaEvents) video.addEventListener(e, onMediaEvent);
    sendState();
  }

  function onMediaEvent() {
    sendState();
    scheduleReport(); // loadedmetadata changes the letterboxing
  }

  function setTracking(on: boolean) {
    tracking = on;
    clearInterval(interval);
    if (on) {
      attach(video ?? findVideo());
      if (video) {
        const r = video.getBoundingClientRect();
        if (r.bottom < 0 || r.top > innerHeight) video.scrollIntoView({ block: 'center' });
      }
      report();
      // Catches layout shifts that fire no event, and keeps the time in sync.
      interval = setInterval(() => {
        report();
        sendState();
      }, 1000);
    } else {
      attach(null);
    }
  }

  function command(action: CommandAction, value = 0) {
    const v = video ?? findVideo();
    if (!v) return;
    switch (action) {
      case 'play':
        void v.play();
        break;
      case 'pause':
        v.pause();
        break;
      case 'toggle':
        if (v.paused) void v.play();
        else v.pause();
        break;
      case 'seek':
        v.currentTime = Math.max(0, Math.min(v.currentTime + value, v.duration || Infinity));
        break;
      case 'seekTo':
        v.currentTime = value;
        break;
      case 'rate':
        v.playbackRate = value;
        break;
      case 'volume':
        v.volume = Math.min(1, Math.max(0, value));
        if (v.volume > 0) v.muted = false;
        break;
      case 'mute':
        v.muted = value !== 0;
        break;
    }
    sendState();
  }

  for (const target of [window, document]) {
    target.addEventListener('scroll', scheduleReport, { passive: true, capture: true });
  }
  window.addEventListener('resize', scheduleReport);
  document.addEventListener('fullscreenchange', scheduleReport);

  chrome.runtime.onMessage.addListener((msg: ExtMessage, _sender, respond) => {
    switch (msg.type) {
      case 'pip:probe': {
        const v = findVideo();
        if (v) attach(v);
        const result: ProbeResult = v ? { found: true, rect: rectOf(v), title: document.title } : { found: false };
        respond(result);
        break;
      }
      case 'pip:track':
        setTracking(msg.on);
        break;
      case 'pip:command':
        command(msg.action, msg.value);
        break;
    }
  });
}
