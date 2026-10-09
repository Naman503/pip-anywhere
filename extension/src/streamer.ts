// Crops a captured video track to the video's rectangle, encodes it to H.264
// with WebCodecs, and hands packets to `send` in the app's wire format.
import { FRAME_DELTA, FRAME_KEY, type VideoRect } from './protocol';

declare class MediaStreamTrackProcessor<T = VideoFrame> {
  constructor(init: { track: MediaStreamTrack });
  readonly readable: ReadableStream<T>;
}

/** Longest output edge; larger crops are scaled down. */
const MAX_EDGE = 2560;
/** Matches the capture limit, so 60 fps videos stay 60 fps. */
export const MAX_FPS = 60;
const KEYFRAME_INTERVAL = 120; // frames (2 s at 60 fps)
/** Drop frames instead of queueing when the encoder or socket falls behind. */
const MAX_ENCODE_QUEUE = 2;
const MAX_SOCKET_BUFFER = 4 * 1024 * 1024;

// Highest profile/level first; hardware encoders reject some combinations.
const CODECS = ['avc1.640033', 'avc1.64002A', 'avc1.640028', 'avc1.4D401F', 'avc1.42E01F'];

export interface Sink {
  sendText(message: object): void;
  sendBinary(data: ArrayBuffer): void;
  bufferedAmount(): number;
}

const even = (n: number) => Math.max(2, Math.round(n / 2) * 2);

function toBase64(buffer: AllowSharedBufferSource): string {
  const bytes = ArrayBuffer.isView(buffer)
    ? new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength)
    : new Uint8Array(buffer);
  let s = '';
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

export class Streamer {
  /** Crop in CSS px of the viewport; null = use the whole frame. */
  crop: VideoRect | null = null;

  private encoder: VideoEncoder | null = null;
  private codec = '';
  private canvas: OffscreenCanvas | null = null;
  private ctx: OffscreenCanvasRenderingContext2D | null = null;
  private size = { width: 0, height: 0 };
  private source = { width: 0, height: 0 };
  private configuring: Promise<void> | null = null;
  private frameIndex = 0;
  private needKeyframe = true;
  private running = false;
  private reader: ReadableStreamDefaultReader<VideoFrame> | null = null;

  constructor(private readonly sink: Sink) {}

  requestKeyframe() {
    this.needKeyframe = true;
  }

  /** Reads frames until the track ends or stop() is called. */
  async run(track: MediaStreamTrack) {
    this.running = true;
    this.reader = new MediaStreamTrackProcessor({ track }).readable.getReader();
    while (this.running) {
      const { value: frame, done } = await this.reader.read();
      if (done || !frame) break;
      try {
        this.handle(frame);
      } catch (err) {
        console.error('[PiP] frame failed', err);
      } finally {
        frame.close();
      }
    }
    this.stop();
  }

  stop() {
    this.running = false;
    void this.reader?.cancel().catch(() => {});
    this.reader = null;
    if (this.encoder && this.encoder.state !== 'closed') this.encoder.close();
    this.encoder = null;
  }

  private handle(frame: VideoFrame) {
    if (this.configuring) return;
    const src = this.sourceRect(frame);
    if (!src) return;
    this.source = { width: frame.displayWidth, height: frame.displayHeight };

    const scale = Math.min(1, MAX_EDGE / Math.max(src.width, src.height));
    const width = even(src.width * scale);
    const height = even(src.height * scale);
    if (width !== this.size.width || height !== this.size.height || !this.encoder) {
      this.configuring = this.configure(width, height).finally(() => (this.configuring = null));
      return;
    }
    const encoder = this.encoder;
    // Skipping a frame before it's encoded doesn't break the decoder's references,
    // so no key frame is needed (forcing one here made drops snowball).
    if (encoder.encodeQueueSize > MAX_ENCODE_QUEUE || this.sink.bufferedAmount() > MAX_SOCKET_BUFFER) return;

    this.ctx!.drawImage(frame, src.x, src.y, src.width, src.height, 0, 0, width, height);
    const out = new VideoFrame(this.canvas!, { timestamp: frame.timestamp });
    const keyFrame = this.needKeyframe || this.frameIndex % KEYFRAME_INTERVAL === 0;
    this.needKeyframe = false;
    this.frameIndex++;
    encoder.encode(out, { keyFrame });
    out.close();
  }

  /** Maps the CSS-pixel crop onto the captured frame (which may be scaled or letterboxed). */
  private sourceRect(frame: VideoFrame) {
    const fw = frame.displayWidth;
    const fh = frame.displayHeight;
    const c = this.crop;
    if (!c || c.viewportWidth <= 0 || c.viewportHeight <= 0) return { x: 0, y: 0, width: fw, height: fh };
    const scale = Math.min(fw / c.viewportWidth, fh / c.viewportHeight);
    const offsetX = (fw - c.viewportWidth * scale) / 2;
    const offsetY = (fh - c.viewportHeight * scale) / 2;
    const x0 = Math.max(0, offsetX + c.x * scale);
    const y0 = Math.max(0, offsetY + c.y * scale);
    const x1 = Math.min(fw, offsetX + (c.x + c.width) * scale);
    const y1 = Math.min(fh, offsetY + (c.y + c.height) * scale);
    if (x1 - x0 < 16 || y1 - y0 < 16) return null; // video scrolled out of view
    return { x: x0, y: y0, width: x1 - x0, height: y1 - y0 };
  }

  private async configure(width: number, height: number) {
    const base: VideoEncoderConfig = {
      codec: '',
      width,
      height,
      bitrate: Math.round(Math.min(20e6, Math.max(2e6, width * height * MAX_FPS * 0.07))),
      framerate: MAX_FPS,
      latencyMode: 'realtime',
      hardwareAcceleration: 'prefer-hardware',
      avc: { format: 'avc' },
    };
    let config: VideoEncoderConfig | null = null;
    for (const codec of this.codec ? [this.codec, ...CODECS] : CODECS) {
      const { supported } = await VideoEncoder.isConfigSupported({ ...base, codec });
      if (supported) {
        config = { ...base, codec };
        break;
      }
    }
    if (!config) throw new Error(`No H.264 encoder for ${width}×${height}`);

    if (!this.encoder || this.encoder.state === 'closed') {
      this.encoder = new VideoEncoder({
        output: (chunk, meta) => this.output(chunk, meta),
        error: (err) => {
          console.error('[PiP] encoder error', err);
          this.encoder = null; // reconfigured on the next frame
        },
      });
    }
    this.encoder.configure(config);
    this.codec = config.codec;
    this.size = { width, height };
    this.canvas = new OffscreenCanvas(width, height);
    this.ctx = this.canvas.getContext('2d', { alpha: false, desynchronized: true });
    this.needKeyframe = true;
    console.info(`[PiP] encoding ${width}×${height} ${config.codec}`);
  }

  private output(chunk: EncodedVideoChunk, meta?: EncodedVideoChunkMetadata) {
    const description = meta?.decoderConfig?.description;
    if (description) {
      this.sink.sendText({
        type: 'config',
        codec: this.codec,
        width: this.size.width,
        height: this.size.height,
        sourceWidth: this.source.width,
        sourceHeight: this.source.height,
        description: toBase64(description),
      });
    }
    const packet = new Uint8Array(9 + chunk.byteLength);
    packet[0] = chunk.type === 'key' ? FRAME_KEY : FRAME_DELTA;
    new DataView(packet.buffer).setFloat64(1, chunk.timestamp, true);
    chunk.copyTo(packet.subarray(9));
    this.sink.sendBinary(packet.buffer);
  }
}
