// Anonymous usage counted by the extension: fixed event names and enum values only
// (never URLs, titles, sites or anything on the page). Nothing is sent anywhere by the
// extension itself: counts wait in chrome.storage.local and are handed to the PiP Anywhere
// app over 127.0.0.1 the next time a video is popped out. The app records them only if
// its "Share anonymous usage" switch is on, and only events on its allow-list
// (PiPCore/UsageCatalog.swift).
import type { ExtMessage } from './protocol';

export type UsageProps = Record<string, string>;
export interface UsageItem {
  n: string;
  p?: UsageProps;
  c: number;
  d: string;
}

const KEY = 'usage';
const MAX_KEYS = 200;
const pad = (n: number) => String(n).padStart(2, '0');
export const today = (date = new Date()) => `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;

/** "day|name|k=v|…" (props sorted), like the app's UsageKeys. */
export function usageKey(day: string, name: string, props: UsageProps = {}) {
  return [day, name, ...Object.keys(props).sort().map((k) => `${k}=${props[k]}`)].join('|');
}

export function parseUsageKey(key: string, count: number): UsageItem | null {
  const [d, n, ...rest] = key.split('|');
  if (!d || !n) return null;
  const p: UsageProps = {};
  for (const part of rest) {
    const i = part.indexOf('=');
    if (i > 0) p[part.slice(0, i)] = part.slice(i + 1);
  }
  return { n, c: count, d, ...(Object.keys(p).length ? { p } : {}) };
}

type Counts = Record<string, number>;
const read = async () => ((await chrome.storage.local.get(KEY))[KEY] as Counts | undefined) ?? {};

// Service worker only (it owns storage writes; other contexts message it).
let queue: Promise<unknown> = Promise.resolve();
const serial = <T>(fn: () => Promise<T>) => (queue = queue.then(fn, fn)) as Promise<T>;

export function track(name: string, props: UsageProps = {}) {
  return serial(async () => {
    const counts = await read();
    const key = usageKey(today(), name, props);
    if (!(key in counts) && Object.keys(counts).length >= MAX_KEYS) return;
    counts[key] = Math.min((counts[key] ?? 0) + 1, 10_000);
    await chrome.storage.local.set({ [KEY]: counts });
  });
}

/** Everything counted so far, as items for the app (kept until acknowledged). */
export async function pendingUsage(): Promise<UsageItem[]> {
  const counts = await read();
  return Object.entries(counts)
    .map(([k, c]) => parseUsageKey(k, c))
    .filter((x): x is UsageItem => x !== null);
}

/** The app received `items`: subtract them (new counts since then stay). */
export function acknowledgeUsage(items: UsageItem[]) {
  return serial(async () => {
    const counts = await read();
    for (const item of items) {
      const key = usageKey(item.d, item.n, item.p);
      const left = (counts[key] ?? 0) - item.c;
      if (left > 0) counts[key] = left;
      else delete counts[key];
    }
    await chrome.storage.local.set({ [KEY]: counts });
  });
}

/** From the offscreen document: ask the service worker to count. */
export function trackRemote(name: string, props: UsageProps = {}) {
  chrome.runtime.sendMessage({ type: 'pip:usage', n: name, p: props } satisfies ExtMessage).catch(() => {});
}

/** Uncaught errors and unhandled rejections in this context, by kind only. */
export function captureErrors(where: 'background' | 'offscreen', report: (props: UsageProps) => void) {
  let last = 0;
  const once = (kind: string) => {
    // At most one per 30 s: a failing loop mustn't flood the counts.
    if (Date.now() - last < 30_000) return;
    last = Date.now();
    report({ where, kind });
  };
  self.addEventListener('error', () => once('uncaught'));
  self.addEventListener('unhandledrejection', () => once('rejection'));
}

/** The extension's stop reasons (fixed English strings) → enum, like UsageCatalog.stopReason. */
export function stopReason(reason: string) {
  const map: Record<string, string> = {
    'closed from the browser': 'closed_browser',
    'switched tabs': 'switched_tabs',
    'back to the tab': 'back_to_tab',
    'closed in the app': 'closed_in_app',
    'tab closed': 'tab_closed',
    'app disconnected': 'app_disconnected',
    'capture ended': 'capture_ended',
    'start failed': 'start_failed',
    replaced: 'replaced',
    error: 'error',
  };
  return map[reason] ?? 'other';
}

export function resolutionBucket(height: number) {
  if (height < 1) return 'unknown';
  if (height <= 480) return 'sd';
  if (height <= 720) return '720p';
  if (height <= 1080) return '1080p';
  if (height <= 1440) return '1440p';
  return '4k';
}
