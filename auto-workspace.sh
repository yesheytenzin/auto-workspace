#!/bin/bash
set -uo pipefail

PLUGIN_ID="tenzin.auto-workspace"
# Config lives OUTSIDE the plugin dir: the shell watches the plugin folder and
# reloads the whole plugin on any file change there, which would close the
# panel and restart the service on every settings save.
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/auto-workspace"
CONFIG_FILE="$STATE_DIR/config.json"
LEGACY_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins/$PLUGIN_ID/config.json"
STATE_FILE="$STATE_DIR/state.json"

mkdir -p "$STATE_DIR"

migrate_config() {
  # One-time migration from the old in-plugin-folder location.
  if [[ ! -f "$CONFIG_FILE" && -f "$LEGACY_CONFIG_FILE" ]]; then
    cp "$LEGACY_CONFIG_FILE" "$CONFIG_FILE" 2>/dev/null || true
  fi
}

default_config() {
  cat <<'JSON'
{
  "version": 1,
  "settings": {
    "enabled": true,
    "launchDelayMs": 800,
    "staggerMs": 400,
    "silent": true,
    "onlyOnBoot": true,
    "lastFormWorkspace": 1
  },
  "assignments": []
}
JSON
}

ensure_config() {
  migrate_config
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
  # List .desktop apps: Name | Exec | Icon | IconPath | File | Score
  # Score = rough frecency from shell histories + recently-used.xbel, so the
  # panel can show commonly used apps first. IconPath lets the UI render
  # real icons instead of glyphs.
  local seen=""
  # Icon index: basename (sans extension) -> first path found, pruned to the
  # common theme sizes so the find stays cheap.
  local -A icon_idx
  local ipath
  while IFS= read -r -d '' ipath; do
    local ibase="${ipath##*/}"
    ibase="${ibase%.*}"
    [[ -n "${icon_idx[$ibase]:-}" ]] || icon_idx["$ibase"]="$ipath"
  done < <(find "$HOME/.local/share/icons" "$HOME/.icons" "/usr/share/icons" "/var/lib/flatpak/exports/share/icons" "$HOME/.local/share/flatpak/exports/share/icons" -type f \( -name "*.png" -o -name "*.svg" \) \( -path "*/16x16/*" -o -path "*/22x22/*" -o -path "*/24x24/*" -o -path "*/32x32/*" -o -path "*/48x48/*" -o -path "*/64x64/*" -o -path "*/128x128/*" -o -path "*/256x256/*" -o -path "*/512x512/*" -o -path "*/scalable/*" -o -path "*/flatpak/*" \) -print0 2>/dev/null)
  # Collect shell history once, then count the leading command words.
  local hist_txt="" h
  for h in "$HOME/.bash_history" "$HOME/.zsh_history" "$HOME/.local/share/fish/fish_history"; do
    [[ -f "$h" ]] || continue
    hist_txt+="$(cat "$h" 2>/dev/null)"
    hist_txt+="\n"
  done
  local -A tok_count
  local token count
  while read -r token count; do
    [[ -n "$token" ]] && tok_count["$token"]="$count"
  done < <(awk '{ for (i=1; i<=NF && i<=2; i++) { if ($i ~ /^[a-zA-Z0-9_.+-]+$/ && $i !~ /^[0-9:-]+$/) print tolower($i) } }' < <(printf "%b" "$hist_txt") | sort | uniq -c | awk '{ print $2, $1 }')
  # recently-used.xbel: app .desktop path -> count
  local -A xbel_count
  while read -r count path; do
    [[ -n "$path" ]] && xbel_count["$path"]="$count"
  done < <(grep -oE 'file://[^"]+\.desktop' "$HOME/.local/share/recently-used.xbel" 2>/dev/null | sed 's#file://##' | sort | uniq -c | awk '{ print $2, $1 }')
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
      # resolve the icon to a real file path when possible
      local icon_path=""
      if [[ -n "$icon" ]]; then
        if [[ "$icon" == /* ]]; then
          [[ -f "$icon" ]] && icon_path="$icon"
        else
          icon_path="${icon_idx[$icon]:-}"
        fi
      fi
      # strip field codes %U %F etc
      exec_line=$(echo "$exec_line" | sed -E 's/ \%[UuFfDdNnickvm]//g' | xargs)
      [[ -z "$exec_line" ]] && continue
      # dedup by exec
      if [[ "$seen" == *"|$exec_line|"* ]]; then continue; fi
      seen+="|$exec_line|"
      local base="${exec_line%% *}"
      local appname="${base##*/}"
      local score=0
      local base_l="${base,,}" appname_l="${appname,,}" nfirst_l="${name%% *}" domain_l=""
      nfirst_l="${nfirst_l,,}"
      [[ -n "${tok_count[$base_l]:-}" ]] && score=$(( score + tok_count["$base_l"] ))
      [[ -n "${tok_count[$appname_l]:-}" ]] && score=$(( score + tok_count["$appname_l"] ))
      # users also type the app name itself (first word of Name=)
      [[ -n "${tok_count[$nfirst_l]:-}" ]] && score=$(( score + tok_count["$nfirst_l"] ))
      # webapps: score by the URL domain too (figma.com → "figma")
      if [[ "$exec_line" == omarchy-launch-webapp* ]]; then
        local url="${exec_line#*\'}"; url="${url%%\'*}"
        if [[ "$url" == http* ]]; then
          domain_l=$(echo "$url" | sed -E 's#^[a-z]+://([^/:]+).*#\1#' | sed -E 's/^www\.//')
          domain_l="${domain_l%%.*}"
          domain_l="${domain_l,,}"
          [[ -n "${tok_count[$domain_l]:-}" ]] && score=$(( score + tok_count["$domain_l"] ))
        fi
      fi
      [[ -n "${xbel_count[$file]:-}" ]] && score=$(( score + xbel_count["$file"] ))
      printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$name" "$exec_line" "$icon" "$icon_path" "$file" "$score"
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
  local is_browser_like="false"
  if [[ "$final_cmd" == *"chromium"* || "$final_cmd" == *"chrome"* || "$final_cmd" == *"omarchy-launch-webapp"* ]]; then
    is_browser_like="true"
  fi
  local browser_before=""
  if [[ "$is_browser_like" == "true" ]]; then
    browser_before=$(hyprctl clients -j 2>/dev/null | jq -r '.[] | select(.class|test("chrome|chromium";"i")) | .address' 2>/dev/null || true)
  fi

  # Try hl.exec_cmd first (canonical in helpers.lua), then hl.dsp.exec_cmd, then legacy dispatch.
  if ! hyprctl eval "hl.exec_cmd(\"$lua_escaped\")" >/dev/null 2>&1 \
    && ! hyprctl eval "hl.dsp.exec_cmd(\"$lua_escaped\")" >/dev/null 2>&1 \
    && ! hyprctl dispatch exec "$dispatch_cmd" >/dev/null 2>&1; then
    echo "failed to execute launch command on workspace $workspace: $final_cmd" >&2
    return 1
  fi

  # Chromium/webapps can spawn tagged + child windows; move only newly created, mis-placed
  # browser windows for this launch instead of moving every browser window.
  if [[ "$is_browser_like" == "true" ]]; then
    (
      sleep 2.5
      local addrs
      addrs=$(hyprctl clients -j 2>/dev/null | jq -r --arg ws "$workspace" --arg before "$browser_before" '
        def ws_ok($ws):
          if ($ws|test("^[0-9]+$")) then
            (.workspace.id == ($ws|tonumber) or .workspace.name == $ws)
          else
            .workspace.name == $ws
          end;
        ($before | split("\n") | map(select(length>0))) as $seen
        | [.[] | select(.class|test("chrome|chromium";"i"))
           | select((.address as $a | ($seen | index($a) | not)))
           | select((ws_ok($ws)) | not)
           | .address] | .[]' 2>/dev/null)
      for addr in $addrs; do
        hyprctl eval "hl.dsp.window.move({workspace=\"$workspace\", window=\"address:$addr\", follow=false})" >/dev/null 2>&1 \
          || hyprctl dispatch movetoworkspacesilent "$workspace,address:$addr" >/dev/null 2>&1 \
          || true
      done
    ) & disown
  fi
  return 0
}

default_only_on_boot_for_type() {
  local type="${1:-app}"
  if [[ "$type" == "app" ]]; then
    echo "false"
  else
    echo "true"
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

  # boot_id for per-item once-per-boot gating (type-based defaults handled in Model.js)
  local only_on_boot_global
  only_on_boot_global=$(jq -r '.settings.onlyOnBoot // true' "$CONFIG_FILE")
  local boot_id
  boot_id=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo "unknown")
  local last_boot_file="$STATE_DIR/last_boot_id"
  local last_boot=""
  [[ -f "$last_boot_file" ]] && last_boot=$(cat "$last_boot_file" 2>/dev/null || echo "")

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
    local ws exec_cmd name type
    ws=$(echo "$item" | jq -r '.workspace')
    exec_cmd=$(echo "$item" | jq -r '.exec // .command // empty')
    name=$(echo "$item" | jq -r '.name // empty')
    type=$(echo "$item" | jq -r '.type // "app"')
    if [[ -z "$ws" || -z "$exec_cmd" ]]; then
      echo "skip invalid item: $item" >&2
      continue
    fi

    # Per-item once-per-boot (type default: webapp true, app false, custom true via Model.js)
    local item_only
    item_only=$(echo "$item" | jq -r 'if has("onlyOnBoot") then .onlyOnBoot else empty end')
    if [[ -z "$item_only" || "$item_only" == "null" ]]; then
      item_only=$(default_only_on_boot_for_type "$type")
      [[ -z "$item_only" ]] && item_only="$only_on_boot_global"
    fi
    # Normalize to string "true"/"false"
    if [[ "$item_only" == "1" ]]; then item_only="true"; fi
    if [[ "$item_only" == "0" ]]; then item_only="false"; fi
    if [[ "$item_only" == "true" && "$force" != "true" && -n "$last_boot" && "$last_boot" == "$boot_id" ]]; then
      echo "skip $name on ws $ws — already launched this boot (once per boot)"
      continue
    fi

    # Dedup: only skip when we can match confidently. Broad title/class regex creates
    # false positives and causes valid assignments to be skipped.
    local basename
    basename=$(echo "$exec_cmd" | awk '{print $1}' | xargs basename 2>/dev/null | cut -d' ' -f1)
    basename=$(basename "$basename" 2>/dev/null || echo "$basename")
    local app_id=""
    if [[ "$exec_cmd" =~ --app-id=([^[:space:]]+) ]]; then
      app_id="${BASH_REMATCH[1]}"
    fi
    if [[ "$force" != "true" ]]; then
      if [[ "$exec_cmd" == omarchy-launch-webapp* || "$exec_cmd" == chromium* || "$exec_cmd" == google-chrome* || "$exec_cmd" == firefox* ]]; then
        :
      elif [[ -n "$app_id" ]]; then
        if hyprctl clients -j 2>/dev/null | jq -e --arg ws "$ws" --arg appid "$app_id" '
          def ws_ok($ws):
            if ($ws|test("^[0-9]+$")) then
              (.workspace.id == ($ws|tonumber) or .workspace.name == $ws)
            else
              .workspace.name == $ws
            end;
          any(.[]; ws_ok($ws) and ((.class|ascii_downcase)==($appid|ascii_downcase) or (.initialClass|ascii_downcase)==($appid|ascii_downcase)))
        ' >/dev/null 2>&1; then
          echo "skip $name on ws $ws — already running ($app_id)"
          continue
        fi
      elif [[ -n "$basename" && "$basename" != "." ]]; then
        if hyprctl clients -j 2>/dev/null | jq -e --arg ws "$ws" --arg bn "$basename" '
          def ws_ok($ws):
            if ($ws|test("^[0-9]+$")) then
              (.workspace.id == ($ws|tonumber) or .workspace.name == $ws)
            else
              .workspace.name == $ws
            end;
          any(.[]; ws_ok($ws) and ((.class|ascii_downcase)==($bn|ascii_downcase) or (.initialClass|ascii_downcase)==($bn|ascii_downcase)))
        ' >/dev/null 2>&1; then
          echo "skip $name on ws $ws — already running ($basename)"
          continue
        fi
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
auto-workspace.sh — helper for tenzin.auto-workspace

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
