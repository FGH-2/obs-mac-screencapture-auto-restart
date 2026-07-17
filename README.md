# OBS macOS Screen Capture Auto-Restart

An OBS Lua script that automatically detects and recovers frozen **macOS Screen Capture** sources — the long-standing [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) bug where the capture silently freezes on the last frame (or goes black after the Mac sleeps).

No OBS fork, no process injection — just a standard script using the official OBS scripting API.

## The problem

On macOS, ScreenCaptureKit periodically stops delivering new frames to the capturing app. Discord, Google Meet, and OBS all hit it. In OBS this shows up as a frozen (or black) picture while recording keeps running. The usual fix is to restart the source by hand. This script does that for you.

## How it works

| Mechanism | What it does |
|---|---|
| **Freeze detection** | Every few seconds each capture source is rendered downscaled to a tiny off-screen texture; pixels are read back and checksummed. Unchanged for the timeout → frozen. |
| **Restart** | Briefly flips the source's "show cursor" setting and flips it back, forcing OBS to tear down and rebuild the ScreenCaptureKit stream (same rebuild path as the source's built-in Reactivate button). |
| **Sleep / wake** | System sleep suspends OBS. A large gap between timer ticks is treated as a wake event, and all capture sources are rebuilt immediately. |
| **Auto-detection** | All capture sources are discovered by type. Newly added ones are picked up without reconfiguration. |

## Requirements

- macOS with OBS Studio 28+ (tested on OBS 32)
- Uses OBS's bundled LuaJIT — no external dependencies

## Install

1. Download [`obs-auto-restart-source.lua`](./obs-auto-restart-source.lua) from this repo (or clone it).
2. In OBS: **Tools → Scripts → +** and select the file.
3. Confirm the Script Log shows `pixel-hash freeze detection active` and `watching '…'` for your capture sources.
4. (Optional) Click **Restart all capture sources now** to test — you should see a brief blip as the stream rebuilds.

To update later: replace the file and hit the reload (circular arrow) button in the Scripts window.

## Settings

| Setting | Default | Description |
|---|---|---|
| Watched source type ids | `screen_capture,display_capture,window_capture` | Source types to monitor |
| Check interval (seconds) | `2` | How often to sample sources |
| Freeze timeout (seconds) | `10` | Unchanged pixels for this long → restart |
| Settings flip gap (ms) | `400` | Delay between the two setting flips |
| Min seconds between restarts | `30` | Cooldown per source |
| Preventive restart every N sec | `0` (off) | Timer-based restart fallback |
| Restart after system wake | on | Rebuild sources after sleep |
| Verbose logging | on | Timestamped log lines |

## Caveats

- A completely idle screen (no cursor movement or animation) looks identical to a freeze, so it may trigger a harmless restart. Raise the freeze timeout if you often step away mid-recording.
- Restart briefly removes the cursor from the capture (a fraction of a second).
- The stream-rebuild trick relies on OBS's current macOS Screen Capture implementation; a future OBS change could require an update.
- After wake, if the Mac is still on the lock screen, capture may stay black until unlock — the freeze detector then restarts again.

## Troubleshooting

Open **Tools → Scripts → Script Log**.

| Log line | Meaning |
|---|---|
| `pixel-hash freeze detection active` | Detection is working |
| `WARNING: pixel detection unavailable` | Set a preventive restart interval as a fallback |
| `freeze detected on '…'` | Auto-recovery fired |
| `system wake detected` | Sleep/wake recovery fired |

## Contributing

Issues and PRs welcome — especially reports against new OBS / macOS versions.

## License

[MIT](./LICENSE)
