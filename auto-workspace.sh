#!/bin/bash
set -uo pipefail

PLUGIN_ID="yesheytenzin.auto-workspace"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$PLUGIN_ID"
CONFIG_FILE="$CONFIG_DIR/config.json"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/auto-workspace"
STATE_FILE="$STATE_DIR/state.json"

mkdir -p "$CONFIG_DIR" "$STATE_DIR"

default_config() {
  cat <<'JSON'
{
  "version": 1,
  "settings": {
    "enabled": true,
    "launchDelayMs": 800,
    "staggerMs": 400,
    "silent": true,
    "onlyOnBoot": true
  },
  "assignments": []
}
JSON
}

ensure_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    default_config >"$CONFIG_FILE"
  fi
  # Validate json; if invalid, backup and reset
  if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
    cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%s)" 2>/dev/null || true
    default_config >"$CONFIG_FILE"
  fi
}

cmd_ensure_config() {
  ensure_config
  cat "$CONFIG_FILE"
}

cmd_list_apps() {
  # List .desktop apps: Name | Exec | Icon | File
  # Use jq-like output: name\texec\ticon
  local seen=""
  for dir in "$HOME/.local/share/applications" "/usr/share/applications" "/var/lib/flatpak/exports/share/applications" "$HOME/.local/share/flatpak/exports/share/applications"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r -d '' file; do
      local name="" exec_line="" icon="" hidden="" nodisplay=""
      name=$(grep -m1 "^Name=" "$file" 2>/dev/null | cut -d= -f2- | head -n1)
      exec_line=$(grep -m1 "^Exec=" "$file" 2>/dev/null | cut -d= -f2- | head -n1)
      icon=$(grep -m1 "^Icon=" "$file" 2>/dev/null | cut -d= -f2- | head -n1)
      hidden=$(grep -m1 "^Hidden=" "$file" 2>/dev/null | cut -d= -f2- | head -n1)
      nodisplay=$(grep -m1 "^NoDisplay=" "$file" 2>/dev/null | cut -d= -f2- | head -n1)
      [[ "$hidden" == "true" || "$nodisplay" == "true" ]] && continue
      [[ -z "$name" || -z "$exec_line" ]] && continue
      # strip field codes %U %F etc
      exec_line=$(echo "$exec_line" | sed -E 's/ \%[UuFfDdNnickvm]//g' | xargs)
      [[ -z "$exec_line" ]] && continue
      # dedup by exec
      if [[ "$seen" == *"|$exec_line|"* ]]; then continue; fi
      seen+="|$exec_line|"
      printf "%s\t%s\t%s\t%s\n" "$name" "$exec_line" "$icon" "$file"
    done < <(find "$dir" -maxdepth 1 -name "*.desktop" -print0 2>/dev/null)
  done | sort -u -t $'\t' -k1,1
}

cmd_status() {
  ensure_config
  local count enabled_count
  count=$(jq '.assignments | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
  enabled_count=$(jq '[.assignments[] | select(.enabled==true)] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
  local enabled
  enabled=$(jq -r '.settings.enabled // true' "$CONFIG_FILE" 2>/dev/null)
  cat <<EOF
{
  "configFile": "$CONFIG_FILE",
  "total": $count,
  "enabled": $enabled_count,
  "pluginEnabled": $enabled,
  "exists": true
}
EOF
}

cmd_launch() {
  local workspace="$1"
  local exec_cmd="$2"
  local silent="${3:-true}"
  if [[ -z "$workspace" || -z "$exec_cmd" ]]; then
    echo "usage: $0 --launch <workspace> <exec> [silent]" >&2
    exit 1
  fi
  # Validate workspace 1-10 or special
  if ! [[ "$workspace" =~ ^[0-9]+$ ]] && ! [[ "$workspace" =~ ^special: ]]; then
    echo "invalid workspace: $workspace" >&2
    exit 1
  fi
  local prefix="[workspace $workspace"
  if [[ "$silent" == "true" ]]; then
    prefix+=" silent]"
  else
    prefix+="]"
  fi
  # Use hyprctl dispatch exec with uwsm-app if needed
  # If exec already contains uwsm-app or omarchy-launch, use as-is
  local final_cmd="$exec_cmd"
  if [[ "$exec_cmd" != uwsm-app* && "$exec_cmd" != omarchy-launch* && "$exec_cmd" != "chromium"* && "$exec_cmd" != "google-chrome"* && "$exec_cmd" != "firefox"* ]]; then
    # heuristic: if it's a simple binary without path, wrap with uwsm-app for proper app launching
    if [[ "$exec_cmd" =~ ^[a-zA-Z0-9._-]+$ || "$exec_cmd" =~ ^[a-zA-Z0-9._-]+[[:space:]] ]]; then
      final_cmd="uwsm-app -- $exec_cmd"
    fi
  fi
  local dispatch_cmd="$prefix $final_cmd"
  # Hyprland 0.56+ uses hl.exec_cmd via hyprctl eval (dispatch legacy removed)
  # Escape for Lua string: backslash and double quotes
  local lua_escaped
  lua_escaped=$(printf '%s' "$dispatch_cmd" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  # Try hl.exec_cmd first (canonical in helpers.lua), then hl.dsp.exec_cmd
  if hyprctl eval "hl.exec_cmd(\"$lua_escaped\")" 2>&1; then
    # Chromium --app windows lose the workspace tag due to zygote fork; fix with delayed move
    if [[ "$final_cmd" == *"chromium"* || "$final_cmd" == *"chrome"* || "$final_cmd" == *"omarchy-launch-webapp"* ]]; then
      # async move checker: after Chrome spawns, move mis-placed window to target ws
      (
        sleep 2.5
        # find most recent chrome window not on target ws and move it
        local addrs
        addrs=$(hyprctl clients -j 2>/dev/null | jq -r --arg ws "$workspace" '
          [.[] | select(.class|test("chrome|chromium";"i")) | select(.workspace.name != $ws and .workspace.id != ($ws|tonumber)) | .address] | .[]' 2>/dev/null | tail -n 5)
        for addr in $addrs; do
          # only move the newest if multiple; check if title hints at our exec host
          hyprctl eval "hl.dsp.window.move({workspace=\"$workspace\", window=\"address:$addr\", follow=false})" >/dev/null 2>&1 || \
          hyprctl eval "hl.dsp.window.move({workspace=\"$workspace\", follow=false})" >/dev/null 2>&1 || true
        done
      ) & disown
    fi
    return 0
  elif hyprctl eval "hl.dsp.exec_cmd(\"$lua_escaped\")" 2>&1; then
    return 0
  else
    hyprctl dispatch exec "$dispatch_cmd" 2>&1 || hyprctl dispatch exec "[workspace $workspace] $final_cmd" 2>&1 || {
      hyprctl eval "hl.exec_cmd(\"[workspace $workspace] $final_cmd\")" 2>&1
    }
  fi
}

# Launch all enabled assignments from config
cmd_launch_all() {
  local force="${1:-false}"
  ensure_config
  local enabled
  enabled=$(jq -r '.settings.enabled // true' "$CONFIG_FILE")
  if [[ "$enabled" != "true" && "$force" != "true" ]]; then
    echo "plugin disabled, skipping (use --force to override)" >&2
    exit 0
  fi

  # onlyOnBoot check: compare boot id
  local only_on_boot
  only_on_boot=$(jq -r '.settings.onlyOnBoot // true' "$CONFIG_FILE")
  local boot_id
  boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")
  local last_boot_file="$STATE_DIR/last_boot_id"
  if [[ "$only_on_boot" == "true" && "$force" != "true" ]]; then
    if [[ -f "$last_boot_file" ]]; then
      local last_boot
      last_boot=$(cat "$last_boot_file" 2>/dev/null)
      if [[ "$last_boot" == "$boot_id" ]]; then
        # Also check if hyprctl clients already has windows for these workspaces? still skip to avoid duplicate
        echo "already launched this boot ($boot_id), skipping (use --force)"
        exit 0
      fi
    fi
  fi

  local stagger silent
  stagger=$(jq -r '.settings.staggerMs // 400' "$CONFIG_FILE")
  silent=$(jq -r '.settings.silent // true' "$CONFIG_FILE")

  local count
  count=$(jq '.assignments | length' "$CONFIG_FILE")
  if [[ "$count" -eq 0 ]]; then
    echo "no assignments configured"
    exit 0
  fi

  # Iterate enabled assignments
  local idx=0
  jq -c '.assignments[] | select(.enabled==true)' "$CONFIG_FILE" 2>/dev/null | while read -r item; do
    local ws exec_cmd name
    ws=$(echo "$item" | jq -r '.workspace')
    exec_cmd=$(echo "$item" | jq -r '.exec // .command // empty')
    name=$(echo "$item" | jq -r '.name // empty')
    if [[ -z "$ws" || -z "$exec_cmd" ]]; then
      echo "skip invalid item: $item" >&2
      continue
    fi

    # Dedup: check if window already exists matching class/title roughly
    # Use hyprctl clients -j and search for class/title containing name or exec basename
    local basename
    basename=$(echo "$exec_cmd" | awk '{print $1}' | xargs basename 2>/dev/null | cut -d' ' -f1)
    basename=$(basename "$basename" 2>/dev/null || echo "$basename")
    # simple check: if any client has workspace == ws and class/title contains basename/name, skip unless force
    if [[ "$force" != "true" ]]; then
      if hyprctl clients -j 2>/dev/null | jq -e --arg ws "$ws" --arg bn "$basename" --arg nm "$name" '
        any(.[]; (.workspace.id == ($ws|tonumber) or .workspace.name == $ws) and ((.class|test($bn;"i")) or (.title|test($nm;"i")) or (.initialClass|test($bn;"i"))))
      ' >/dev/null 2>&1; then
        echo "skip $name on ws $ws — already running"
        continue
      fi
    fi

    echo "launching [$ws] $name: $exec_cmd (silent=$silent)"
    # stagger except first
    if [[ "$idx" -gt 0 && "$stagger" -gt 0 ]]; then
      sleep "$(awk "BEGIN {print $stagger/1000}")"
    fi
    cmd_launch "$ws" "$exec_cmd" "$silent" || echo "failed to launch $name" >&2
    idx=$((idx+1))
  done

  # record boot id on success
  echo "$boot_id" > "$last_boot_file"
  echo "done"
}

case "${1:-}" in
  --ensure-config) cmd_ensure_config ;;
  --list-apps) cmd_list_apps ;;
  --status) cmd_status ;;
  --launch) shift; cmd_launch "$@" ;;
  --launch-all) shift; cmd_launch_all "$@" ;;
  --force-launch-all) cmd_launch_all "true" ;;
  --default-config) default_config ;;
  --help|-h|"") cat <<'HELP'
auto-workspace.sh — helper for yesheytenzin.auto-workspace

  --ensure-config         ensure config exists and print it
  --list-apps             list .desktop apps as TSV (name exec icon file)
  --status                json status
  --launch <ws> <exec> [silent]  launch single app on workspace
  --launch-all [--force]  launch all enabled assignments (respects onlyOnBoot)
  --force-launch-all      always launch regardless of settings
  --default-config        print default config
HELP
  ;;
  *) echo "unknown arg: $1" >&2; exit 1 ;;
esac
