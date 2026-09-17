# LidAwake

Keep your MacBook running with the lid closed — no kernel extensions, no hacks beyond what Apple's own `pmset` supports.

**[中文文档](README.zh-CN.md)**

## Why

Closing the lid normally puts a MacBook to sleep. That's a problem when you want to:

- run long tasks with the lid closed (downloads, builds, AI agents, backups)
- use an external display in clamshell mode without the machine sleeping
- keep a headless Mac reachable over SSH / screen sharing

Apple gives you `pmset`, but its behavior is full of traps:

1. **`pmset -c sleep 0` does NOT prevent lid-close sleep.** It only controls the idle timer. The switch that actually suppresses lid sleep is `pmset -a disablesleep 1`.
2. **`disablesleep` is global** — it doesn't distinguish AC power from battery. Forget to turn it off and your Mac keeps running (and heating up) inside a closed bag on battery.
3. **`0` means "never"**, which is the opposite of intuition (`displaysleep 0` = the display never sleeps).

LidAwake wraps all of this into safe, named modes with automatic snapshots and rollback.

## What's inside

| Component | What it does |
|---|---|
| [`lidawake.sh`](lidawake.sh) | One-shot script: apply / restore / show. The minimal "lid closed = stay awake" setup. |
| [`batteryctl/`](batteryctl/README.md) | The main tool. Named power modes (`default` / `charging` / `background` / `awake`), automatic pre-change snapshots, one-command rollback, read-only diagnostics including USB-C PD adapter analysis. Python CLI + native SwiftUI app. |
| [`batteryctl/app/`](batteryctl/app/README.md) | `BatteryCtl.app` — native SwiftUI GUI on top of the same CLI core. Built with `swiftc` only, no full Xcode needed. |
| [`charge-watch.sh`](charge-watch.sh) | Sampling monitor that catches the exact moment charging degrades: PD renegotiation drops, "plugged in but not charging", not-charging/inhibit reason codes. |
| [`charger-info.c`](charger-info.c) | ~40-line demo of the two charger-detection APIs (`IOPSCopyExternalPowerAdapterDetails` + IORegistry `AppleSmartBattery`). The core of a "what can this USB-C port actually deliver" check. |

## Quick start

### 1. Download the release (recommended)

Grab the latest app from [**Releases**](https://github.com/XavierProduct/LidAwake/releases/latest):

1. Download `BatteryCtl-macOS-arm64.zip` and unzip
2. First launch: right-click the app → **Open** (it is ad-hoc signed only, so a plain double-click gets blocked by Gatekeeper), or run `xattr -cr BatteryCtl.app` in Terminal
3. Applying a mode prompts once for your admin password — `pmset` requires root

### 2. batteryctl CLI (from source)

```bash
cd batteryctl

# read-only, no sudo
python3 batteryctl.py status
python3 batteryctl.py list

# switch modes (needs sudo; auto-snapshots first)
sudo python3 batteryctl.py apply background   # lid closed, long tasks keep running
sudo python3 batteryctl.py apply awake        # clamshell + external display
sudo python3 batteryctl.py apply default      # back to normal

# roll back to the last snapshot
sudo python3 batteryctl.py restore
```

### 3. One-shot script (simplest, no Python needed)

```bash
sudo bash lidawake.sh apply    # lid closed = stays awake (AC: no idle sleep either)
bash lidawake.sh show          # read-only status, no sudo needed
sudo bash lidawake.sh restore  # back to Apple factory defaults
```

### 4. Build the GUI yourself

```bash
cd batteryctl/app
bash build.sh
open ../BatteryCtl.app
```

## The modes

| Mode | Purpose | `disablesleep` |
|---|---|---|
| `default` | Everyday use; sleeps normally (even on AC) | 0 |
| `charging` | Fastest charging; power handed to the battery | 0 |
| `background` | **Lid closed, long tasks keep running** | 1 |
| `awake` | **Clamshell + external display** (also checks display + screen-recording permission before applying) | 1 |

## ⚠️ Safety notes

- `background` / `awake` enable `disablesleep`, which is **global**. On battery with the lid closed, the Mac keeps running, generating heat and draining. When you're done, run `restore` or `apply default`.
- Every `apply` writes a snapshot first; any failed `pmset` call triggers an automatic rollback.
- Read-only commands (`status`, `list`) never require privileges.
- Clamshell *display output* (as opposed to just staying awake) requires an external display or HDMI dummy plug — Apple Silicon cuts the internal display pipeline when the lid closes. No software can bypass this; `awake` mode verifies the preconditions before applying.

## Requirements

- macOS 13+ (developed and tested on Apple Silicon; Intel needs a `build.sh` tweak for the GUI)
- Python 3 for `batteryctl`
- Xcode Command Line Tools for the GUI
- `sudo` only for mode changes

## Tests

```bash
cd batteryctl
python3 -m unittest discover -s tests -v
```

36 unit tests over the pure logic (parsing, profile loading, command construction). Tests never touch system power settings.

## Design docs

- [CLI design](docs/2026-09-13-batteryctl-design.md)
- [App design](docs/2026-09-13-batteryctl-app-design.md)
- [Implementation plan](docs/2026-09-13-batteryctl.md)

## License

MIT — see [LICENSE](LICENSE).
