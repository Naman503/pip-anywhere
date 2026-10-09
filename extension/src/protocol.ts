// Shared types: messages between the extension's contexts, and the app wire
// protocol (docs/protocol.md).

export const DEFAULT_APP_PORT = 47823;
export const appUrl = (port = DEFAULT_APP_PORT) => `ws://127.0.0.1:${port}/`;

/** Where the video sits in the tab, in CSS pixels relative to the viewport. */
export interface VideoRect {
  x: number;
  y: number;
  width: number;
  height: number;
  viewportWidth: number;
  viewportHeight: number;
  devicePixelRatio: number;
}

export interface PlaybackState {
  title: string;
  site: string;
  paused: boolean;
  currentTime: number;
  duration: number;
  rate: number;
  volume: number;
  muted: boolean;
}

export type CommandAction = 'play' | 'pause' | 'toggle' | 'seek' | 'seekTo' | 'rate' | 'volume' | 'mute' | 'focusTab' | 'close';

export interface ProbeResult {
  found: boolean;
  rect?: VideoRect;
  title?: string;
}

/** Messages on chrome.runtime / chrome.tabs messaging. */
export type ExtMessage =
  // service worker → content script
  | { type: 'pip:probe' }
  | { type: 'pip:track'; on: boolean }
  | { type: 'pip:command'; action: CommandAction; value?: number }
  // content script → offscreen (broadcast)
  | { type: 'pip:rect'; rect: VideoRect }
  | { type: 'pip:state'; state: PlaybackState }
  // service worker → offscreen
  | { type: 'pip:start'; target: 'offscreen'; streamId: string; tabId: number; rect: VideoRect; port: number }
  | { type: 'pip:stop'; target: 'offscreen'; reason: string }
  // offscreen → service worker
  | { type: 'pip:app-command'; action: CommandAction; value?: number }
  | { type: 'pip:ended'; reason: string }
  | { type: 'pip:error'; message: string };

/** App → extension (JSON text frames). */
export type AppMessage =
  | { type: 'hello'; version: string }
  | { type: 'command'; action: CommandAction; value?: number }
  | { type: 'keyframe' };

export const FRAME_KEY = 1;
export const FRAME_DELTA = 2;
