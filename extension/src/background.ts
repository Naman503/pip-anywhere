// Service worker: starts/stops PiP for a tab and routes commands between the
// app (via the offscreen document) and the tab's content script.
import { DEFAULT_APP_PORT, type ExtMessage, type ProbeResult } from './protocol';

interface Active {
  tabId: number;
  windowId: number;
}

// Service workers are restarted often; keep the active session in session storage.
const getActive = async () => (await chrome.storage.session.get('active')).active as Active | undefined;
const setActive = (active: Active | null) =>
  active ? chrome.storage.session.set({ active }) : chrome.storage.session.remove('active');

async function badge(tabId: number | undefined, text: string, title: string, color = '#d93025') {
  await chrome.action.setBadgeBackgroundColor({ color });
  await chrome.action.setBadgeText({ text, ...(tabId !== undefined ? { tabId } : {}) });
  await chrome.action.setTitle({ title, ...(tabId !== undefined ? { tabId } : {}) });
}

async function ensureOffscreen() {
  const contexts = await chrome.runtime.getContexts({ contextTypes: [chrome.runtime.ContextType.OFFSCREEN_DOCUMENT] });
  if (contexts.length) return;
  await chrome.offscreen.createDocument({
    url: 'offscreen.html',
    reasons: [chrome.offscreen.Reason.USER_MEDIA],
    justification: 'Capture the tab video and stream it to the PiP Anywhere floating window',
  });
}

/** Asks the tab's content script for its video, injecting the script if needed. */
async function probe(tabId: number): Promise<ProbeResult | null> {
  const ask = () => chrome.tabs.sendMessage(tabId, { type: 'pip:probe' } satisfies ExtMessage) as Promise<ProbeResult>;
  try {
    return await ask();
  } catch {
    // Tabs opened before the extension was installed have no content script yet.
    try {
      await chrome.scripting.executeScript({ target: { tabId }, files: ['content.js'] });
      return await ask();
    } catch {
      return null;
    }
  }
}

async function start(tab: chrome.tabs.Tab) {
  if (tab.id === undefined) return;
  const tabId = tab.id;
  const result = await probe(tabId);
  if (!result?.found || !result.rect) {
    await badge(tabId, '–', 'No video found on this page');
    setTimeout(() => void badge(tabId, '', 'Pop out video'), 2500);
    return;
  }
  // Allowed because the user invoked the extension on this tab (click, shortcut or menu).
  const streamId = await chrome.tabCapture.getMediaStreamId({ targetTabId: tabId });
  await ensureOffscreen();
  await setActive({ tabId, windowId: tab.windowId });
  // `appPort` in local storage is a development override (e.g. a second app instance).
  const port = ((await chrome.storage.local.get('appPort')).appPort as number | undefined) ?? DEFAULT_APP_PORT;
  await chrome.runtime.sendMessage({ type: 'pip:start', target: 'offscreen', streamId, tabId, rect: result.rect, port } satisfies ExtMessage);
  await chrome.tabs.sendMessage(tabId, { type: 'pip:track', on: true } satisfies ExtMessage).catch(() => {});
  await badge(tabId, 'PiP', 'Popped out: click to bring it back', '#1a73e8');
}

/** Ends the session on the extension side; `notifyOffscreen` = also stop capture. */
async function stop(reason: string, notifyOffscreen = true) {
  const active = await getActive();
  if (!active) return;
  await setActive(null);
  if (notifyOffscreen) {
    await chrome.runtime.sendMessage({ type: 'pip:stop', target: 'offscreen', reason } satisfies ExtMessage).catch(() => {});
  }
  await chrome.tabs.sendMessage(active.tabId, { type: 'pip:track', on: false } satisfies ExtMessage).catch(() => {});
  await badge(active.tabId, '', 'Pop out video').catch(() => {});
}

async function toggle(tab: chrome.tabs.Tab | undefined) {
  if (!tab?.id) return;
  const active = await getActive();
  if (active?.tabId === tab.id) return stop('closed from the browser');
  if (active) await stop('switched tabs');
  try {
    await start(tab);
  } catch (err) {
    console.error('[PiP] start failed', err);
    await badge(tab.id, '!', `Could not start: ${(err as Error).message}`);
  }
}

chrome.action.onClicked.addListener((tab) => void toggle(tab));
chrome.commands.onCommand.addListener((command, tab) => {
  if (command === 'toggle-pip') void toggle(tab);
});

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({ id: 'pip-video', title: 'Pop out with PiP Anywhere', contexts: ['video', 'page'] });
});
chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId === 'pip-video') void toggle(tab);
});

chrome.runtime.onMessage.addListener((msg: ExtMessage) => {
  void (async () => {
    switch (msg.type) {
      case 'pip:app-command': {
        const active = await getActive();
        if (!active) return;
        if (msg.action === 'focusTab') {
          await chrome.tabs.update(active.tabId, { active: true });
          await chrome.windows.update(active.windowId, { focused: true });
          await stop('back to the tab');
        } else if (msg.action === 'close') {
          await stop('closed in the app');
        } else {
          await chrome.tabs.sendMessage(active.tabId, { type: 'pip:command', action: msg.action, value: msg.value } satisfies ExtMessage);
        }
        break;
      }
      case 'pip:ended':
        await stop(msg.reason, false);
        break;
      case 'pip:error': {
        const active = await getActive();
        await stop('error', false);
        const app = /not running|timeout/.test(msg.message);
        await badge(active?.tabId, '!', app ? 'Open the PiP Anywhere app first (menu bar)' : msg.message);
        break;
      }
    }
  })();
});

chrome.tabs.onRemoved.addListener(async (tabId) => {
  if ((await getActive())?.tabId === tabId) await stop('tab closed');
});

// A full page load replaces the content script; re-attach it to the new page.
chrome.tabs.onUpdated.addListener(async (tabId, change) => {
  if (change.status !== 'complete' || (await getActive())?.tabId !== tabId) return;
  await chrome.tabs.sendMessage(tabId, { type: 'pip:track', on: true } satisfies ExtMessage).catch(() => {});
});

// For automated tests (Playwright evaluates this in the service worker).
(globalThis as unknown as { pipToggleTab: (tabId: number) => Promise<void> }).pipToggleTab = async (tabId) =>
  toggle(await chrome.tabs.get(tabId));
