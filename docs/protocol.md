# Extension ↔ app protocol (v1)

The browser extension's offscreen document connects to the app with a WebSocket:

```
ws://127.0.0.1:47823/
```

The app listens on loopback only. It accepts the upgrade only when the `Origin` header is the pinned extension:

```
chrome-extension://angpoecfkgeeclnkdmafakhldmadjdih
```

The ID is fixed by the `key` field in `extension/static/manifest.json`. Web pages can't forge `Origin`, so a random site can't push video into the app or receive its commands.

Only one stream is active at a time. A new connection replaces the old one.

## Text frames (JSON)

### Extension → app

| type | fields | when |
|---|---|---|
| `hello` | `version`, `userAgent` | right after connecting |
| `config` | `codec` (e.g. `avc1.64002A`), `width`, `height`, `description` (base64 avcC) | before the first frame, and whenever the encoder is reconfigured (crop size changed) |
| `state` | `title`, `site`, `paused`, `currentTime`, `duration`, `rate` | on play/pause/seek/rate change, and every ~1 s while playing |
| `stop` | `reason` | capture ended: user stopped it, the tab closed, or navigation |

### App → extension

| type | fields | meaning |
|---|---|---|
| `hello` | `version` | reply to `hello` |
| `command` | `action`, `value?` | `play`, `pause`, `toggle`, `seek` (value = ±seconds), `seekTo` (value = seconds), `rate` (value = playback rate), `focusTab`, `close` |
| `keyframe` | – | the decoder lost sync; the encoder should send a key frame next |

## Binary frames (video)

```
byte 0       1 = key frame, 2 = delta frame
bytes 1..8   float64 little-endian, presentation timestamp in microseconds
bytes 9..    one H.264 access unit in AVCC format (4-byte big-endian NALU lengths),
             exactly as WebCodecs VideoEncoder emits with avc.format = "avc"
```

The app wraps each access unit in a `CMSampleBuffer` using the format description built from the latest `config.description` (avcC). It enqueues the buffer on an `AVSampleBufferDisplayLayer` marked *display immediately*. There is no jitter buffer: lowest latency wins, because the tab plays the audio.
