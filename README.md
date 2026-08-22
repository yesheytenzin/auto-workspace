# Auto Workspace

Auto-launch apps on workspaces at boot/login for Omarchy Quattro + Hyprland.

Assign YouTube to workspace 1 so it always opens there, put Code + Terminal on workspace 2, etc. Supports multiple apps per workspace, silent launch, and per-boot dedup.

## Install

```sh
omarchy plugin add https://github.com/yesheytenzin/auto-workspace.git --enable
# or manual drop-in for dev:
mkdir -p ~/.config/omarchy/plugins/tenzin.auto-workspace
cp -r /path/to/auto_workspace/* ~/.config/omarchy/plugins/tenzin.auto-workspace/
omarchy-shell shell rescanPlugins
omarchy plugin enable tenzin.auto-workspace
# bar widget appears in left section; move if desired:
omarchy bar move tenzin.auto-workspace --section left
```

## Usage

1. Click the 󰨧 icon in the bar (left) → **Auto Workspace** panel.
2. Click **+ Add**, pick workspace 1-10, type name + command/URL, choose type:
   - **App** — `.desktop` Exec like `code`, `spotify`, `foot`, `chromium`
   - **Web App** — URL like `https://youtube.com` (uses `omarchy-launch-webapp`)
   - **Custom** — raw command as-is
3. **Add to WS** — saved to `~/.config/omarchy/plugins/tenzin.auto-workspace/config.json`.
4. Click **Launch all** to test now, or `↗` on a single rule. On next boot/login it launches automatically.

Tips:
- Multiple apps on same workspace → they tile/float per Hyprland layout.
- Use filter box to pick from installed `.desktop` apps quickly.
- Per-workspace launch is `hyprctl dispatch exec "[workspace N silent] <cmd>"` — doesn't steal focus from your current workspace.
- Toggle **Enabled** / **Once per boot** in panel header.

## Config

`~/.config/omarchy/plugins/tenzin.auto-workspace/config.json`:
```json
{
  "version": 1,
  "settings": {
    "enabled": true,
    "launchDelayMs": 800,
    "staggerMs": 400,
    "silent": true,
    "onlyOnBoot": true
  },
  "assignments": [
    { "id": "aw-...", "workspace": 1, "name": "YouTube", "command": "https://youtube.com", "exec": "omarchy-launch-webapp 'https://youtube.com'", "type": "webapp", "enabled": true }
  ]
}
```

## CLI

Helper script at `~/.config/omarchy/plugins/tenzin.auto-workspace/auto-workspace.sh`:

```sh
auto-workspace.sh --status
auto-workspace.sh --list-apps
auto-workspace.sh --launch 1 "chromium --app=https://youtube.com"
auto-workspace.sh --launch-all
auto-workspace.sh --force-launch-all
omarchy-shell -q tenzin.auto-workspace launchAll
omarchy-shell -q tenzin.auto-workspace forceLaunchAll
omarchy-shell -q tenzin.auto-workspace status
```

## How it works

- `Service.qml` (kind `service`) runs on shell start (`Component.onCompleted`). It ensures config exists, then after `launchDelayMs` spawns `auto-workspace.sh --launch-all` via `Process`. Respects `onlyOnBoot` by remembering `/proc/sys/kernel/random/boot_id` in `~/.local/state/omarchy/auto-workspace/last_boot_id` and dedups against `hyprctl clients -j`.
- `BarWidget.qml` + `Panel.qml` (kind `bar-widget`) provides the management UI. No sudo, no network.

## Remove

```sh
omarchy plugin remove tenzin.auto-workspace
rm -rf ~/.config/omarchy/plugins/tenzin.auto-workspace ~/.local/state/omarchy/auto-workspace
```

## License

MIT
