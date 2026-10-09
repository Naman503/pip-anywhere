// WebSocket to the PiP Anywhere app.
import { appUrl, type AppMessage } from './protocol';
import type { Sink } from './streamer';

export class AppConnection implements Sink {
  private ws: WebSocket | null = null;

  onMessage: (msg: AppMessage) => void = () => {};
  onClose: () => void = () => {};

  /** Resolves when connected; rejects if the app isn't running. */
  open(port?: number, timeoutMs = 3000): Promise<void> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(appUrl(port));
      ws.binaryType = 'arraybuffer';
      const timer = setTimeout(() => {
        ws.close();
        reject(new Error('timeout'));
      }, timeoutMs);
      ws.onopen = () => {
        clearTimeout(timer);
        this.ws = ws;
        this.sendText({ type: 'hello', version: '1', userAgent: navigator.userAgent });
        resolve();
      };
      ws.onerror = () => {
        clearTimeout(timer);
        reject(new Error('PiP Anywhere app is not running'));
      };
      ws.onclose = () => {
        if (this.ws === ws) {
          this.ws = null;
          this.onClose();
        }
      };
      ws.onmessage = (e) => {
        if (typeof e.data !== 'string') return;
        try {
          this.onMessage(JSON.parse(e.data) as AppMessage);
        } catch {
          // ignore malformed
        }
      };
    });
  }

  get isOpen() {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  close() {
    const ws = this.ws;
    this.ws = null;
    ws?.close();
  }

  sendText(message: object) {
    if (this.isOpen) this.ws!.send(JSON.stringify(message));
  }

  sendBinary(data: ArrayBuffer) {
    if (this.isOpen) this.ws!.send(data);
  }

  bufferedAmount() {
    return this.ws?.bufferedAmount ?? 0;
  }
}
