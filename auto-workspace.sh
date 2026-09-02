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

# Reject symlink destinations before writing fixed config paths (Panel.qml:94-109,259-282).
_refuse_symlink_dest() {
  local dest="$1"
  local dir
  dir=$(dirname "$dest")
  if [[ -L "$dest" || -L "$dir" ]]; then
    echo "refusing symlink dest: $dest or $dir" >&2
    return 1
  fi
}
_safe_write() {
  local dest="$1"
  _refuse_symlink_dest "$dest" || return 1
  local tmp
  tmp=$(mktemp "$dest.tmp.XXXXXX") || return 1
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  if [[ -L "$dest" ]]; then rm -f "$tmp"; echo "refusing symlink (race): $dest" >&2; return 1; fi
  mv -f "$tmp" "$dest"
}

migrate_config() {
  # One-time migration from the old in-plugin-folder location.
  if [[ ! -f "$CONFIG_FILE" && -f "$LEGACY_CONFIG_FILE" ]]; then
    if _refuse_symlink_dest "$CONFIG_FILE"; then
      local tmp
      tmp=$(mktemp "$CONFIG_FILE.tmp.XXXXXX") && cp -- "$LEGACY_CONFIG_FILE" "$tmp" 2>/dev/null && { if [[ -L "$CONFIG_FILE" ]]; then rm -f "$tmp"; else mv -f "$tmp" "$CONFIG_FILE"; fi; } || rm -f "$tmp"
    fi
  fi
}

default_config() {
  cat <<'JSON'
{
  "version": 1,
  "settings": {
    "enabled": true,
    "launchDelayMs": 1500,
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
    _refuse_symlink_dest "$CONFIG_FILE" && default_config | _safe_write "$CONFIG_FILE" || true
  fi
  # Validate json; if invalid, backup and reset
  if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
    cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%s)" 2>/dev/null || true
    _refuse_symlink_dest "$CONFIG_FILE" && default_config | _safe_write "$CONFIG_FILE" || true
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

wait_for_hyprland() {
  local timeout=20 tries=0
  while ! hyprctl -j version >/dev/null 2>&1; do
    tries=$((tries+1))
    if [[ $tries -ge $timeout ]]; then
      echo "hyprctl not ready after ${timeout}s, aborting launch" >&2
      return 1
    fi
    sleep 1
  done
  return 0
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
  # TUI editors need a terminal — use omarchy-launch-tui so they get a window
  local base_for_tui
  base_for_tui=$(printf '%s' "$exec_cmd" | awk '{print $1}' | xargs basename 2>/dev/null)
  case "$base_for_tui" in
    nvim|vim|vi|nano|helix|hx|emacs|micro|btop|htop|yazi|ranger|lf)
      if [[ "$exec_cmd" != omarchy-launch-tui* ]]; then
        # preserve args after binary (e.g. "nvim file.txt")
        local tui_args="${exec_cmd#"$base_for_tui"}"
        # trim leading space
        tui_args=$(printf '%s' "$tui_args" | sed 's/^ *//')
        if [[ -n "$tui_args" ]]; then
          final_cmd="omarchy-launch-tui --app-id=org.omarchy.$base_for_tui $base_for_tui $tui_args"
        else
          final_cmd="omarchy-launch-tui --app-id=org.omarchy.$base_for_tui $base_for_tui"
        fi
      fi
      ;;
    *)
      if [[ "$exec_cmd" != uwsm-app* && "$exec_cmd" != omarchy-launch* && "$exec_cmd" != "chromium"* && "$exec_cmd" != "google-chrome"* && "$exec_cmd" != "firefox"* ]]; then
        # heuristic: if it's a simple binary without path, wrap with uwsm-app for proper app launching
        if [[ "$exec_cmd" =~ ^[a-zA-Z0-9._-]+$ || "$exec_cmd" =~ ^[a-zA-Z0-9._-]+[[:space:]] ]]; then
          final_cmd="uwsm-app -- $exec_cmd"
        fi
      fi
      ;;
  esac
  local dispatch_cmd="$prefix $final_cmd"
  # Hyprland 0.56+ uses hl.exec_cmd via hyprctl eval (dispatch legacy removed)
  # Escape for Lua string: backslash and double quotes
  local lua_escaped
  lua_escaped=$(printf '%s' "$dispatch_cmd" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
  local is_browser_like="false"
  local is_tui_like="false"
  if [[ "$final_cmd" == *"chromium"* || "$final_cmd" == *"chrome"* || "$final_cmd" == *"omarchy-launch-webapp"* ]]; then
    is_browser_like="true"
  fi
  case "$base_for_tui" in
    nvim|vim|vi|nano|helix|hx|emacs|micro|btop|htop|yazi|ranger|lf) is_tui_like="true" ;;
  esac

  # Snapshot ALL client addresses BEFORE launching — so we can detect windows created by THIS exec
  local before
  before=$(hyprctl clients -j 2>/dev/null | jq -r '.[].address' 2>/dev/null | sort -u | tr '\n' ' ')

  # Try hl.exec_cmd first (canonical in helpers.lua), then hl.dsp.exec_cmd, then legacy dispatch.
  if ! hyprctl eval "hl.exec_cmd(\"$lua_escaped\")" >/dev/null 2>&1 \
    && ! hyprctl eval "hl.dsp.exec_cmd(\"$lua_escaped\")" >/dev/null 2>&1 \
    && ! hyprctl dispatch exec "$dispatch_cmd" >/dev/null 2>&1; then
    echo "failed to execute launch command on workspace $workspace: $final_cmd" >&2
    return 1
  fi

  # For every launch, verify the new window(s) land on the target workspace.
  # Chromium shares a profile — new windows often appear on the focused ws (ws1),
  # so we explicitly move any newly-created window to the assigned workspace.
  local target_ws="$workspace"
  local ok=false
  local tries=40
  for _try in $(seq 1 $tries); do
    local now_addrs new_addrs moved=0
    now_addrs=$(hyprctl clients -j 2>/dev/null | jq -r '.[].address' 2>/dev/null | sort -u)
    # comm needs sorted inputs: compute new addresses = now - before
    new_addrs=$(comm -13 <(printf '%s' "$before" | tr ' ' '\n' | sort -u) <(printf '%s' "$now_addrs" | tr ' ' '\n' | sort -u) 2>/dev/null)
    if [[ -n "$new_addrs" ]]; then
      while IFS= read -r addr; do
        [[ -z "$addr" ]] && continue
        # Filter by expected class — only move windows belonging to this launch
        local cls
        cls=$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$addr" '.[] | select(.address==$a) | .class' 2>/dev/null)
        if [[ "$is_browser_like" == "true" ]]; then
          # browser launches should only move chromium/chrome app windows
          if ! [[ "$cls" =~ chrome|chromium ]] && ! [[ "${cls,,}" =~ chrome|chromium ]]; then
            continue
          fi
        elif [[ "$is_tui_like" == "true" ]]; then
          # tui launches via omarchy-launch-tui create foot/org.omarchy.* windows
          if ! [[ "$cls" =~ foot|org\.omarchy ]] && ! [[ "${cls,,}" =~ foot|nvim ]]; then
            continue
          fi
        fi
        # Skip if already on the right workspace
        local on_ws
        on_ws=$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$addr" --arg ws "$target_ws" '
          def ws_ok($ws):
            if ($ws|test("^[0-9]+$")) then
              (.workspace.id == ($ws|tonumber) or .workspace.name == $ws)
            else
              .workspace.name == $ws
            end;
          .[] | select(.address == $a) | ws_ok($ws)
        ' 2>/dev/null)
        if [[ "$on_ws" != "true" ]]; then
          hyprctl eval "hl.dispatch(hl.dsp.window.move({workspace=\"$target_ws\", window=\"address:$addr\", follow=false}))" >/dev/null 2>&1 \
            || true
        fi
        moved=$((moved+1))
      done <<< "$new_addrs"
      if [[ "$moved" -gt 0 ]]; then
        ok=true
        break
      fi
    fi
    sleep 0.3
  done

  # Browser/webapps can spawn additional child windows shortly after the first;
  # sweep again in background so every new window from this launch ends up on target.
  if [[ "$is_browser_like" == "true" ]]; then
    (
      sleep 2.5
      for _bg in $(seq 1 20); do
        local now2 new2 m2=0
        now2=$(hyprctl clients -j 2>/dev/null | jq -r '.[].address' 2>/dev/null | sort -u)
        new2=$(comm -13 <(printf '%s' "$before" | tr ' ' '\n' | sort -u) <(printf '%s' "$now2" | tr ' ' '\n' | sort -u) 2>/dev/null)
        if [[ -n "$new2" ]]; then
          while IFS= read -r addr; do
            [[ -z "$addr" ]] && continue
            local cls2
            cls2=$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$addr" '.[] | select(.address==$a) | .class' 2>/dev/null)
            if [[ "$is_browser_like" == "true" ]]; then
              if ! [[ "$cls2" =~ chrome|chromium ]] && ! [[ "${cls2,,}" =~ chrome|chromium ]]; then
                continue
              fi
            elif [[ "$is_tui_like" == "true" ]]; then
              if ! [[ "$cls2" =~ foot|org\.omarchy ]] && ! [[ "${cls2,,}" =~ foot|nvim ]]; then
                continue
              fi
            fi
            local on_ws2
            on_ws2=$(hyprctl clients -j 2>/dev/null | jq -r --arg a "$addr" --arg ws "$target_ws" '
              def ws_ok($ws):
                if ($ws|test("^[0-9]+$")) then
                  (.workspace.id == ($ws|tonumber) or .workspace.name == $ws)
                else
                  .workspace.name == $ws
                end;
              .[] | select(.address == $a) | ws_ok($ws)
            ' 2>/dev/null)
            if [[ "$on_ws2" != "true" ]]; then
              hyprctl eval "hl.dispatch(hl.dsp.window.move({workspace=\"$target_ws\", window=\"address:$addr\", follow=false}))" >/dev/null 2>&1 \
                || true
              m2=$((m2+1))
            fi
          done <<< "$new2"
        fi
        # if nothing needed moving, stop early
        [[ "$m2" -eq 0 ]] && break
        sleep 0.3
      done
    ) & disown
  fi

  if [[ "$ok" != "true" ]]; then
    echo "warn: no new window detected for workspace $workspace: $final_cmd (may have reused existing window)" >&2
    # not fatal — caller still counts it; don't return error for reused-window case
    # return 0 so launch_all continues; boot log will show OK with warning
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

  # Wait for Hyprland to be ready — boot is the only time this matters
  wait_for_hyprland || exit 1

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

  # Boot log for diagnostics
  local boot_log="$STATE_DIR/launch-$boot_id.log"
  if _refuse_symlink_dest "$boot_log"; then
    : > "$boot_log" 2>/dev/null || true
    echo "$(date -u) boot_id=$boot_id assignments=$count force=$force" >> "$boot_log" 2>/dev/null || true
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
    echo "$(date -u) START ws=$ws name=$name exec=$exec_cmd" >> "$boot_log" 2>/dev/null || true
    # stagger except first
    if [[ "$idx" -gt 0 && "$stagger" -gt 0 ]]; then
      sleep "$(awk "BEGIN {print $stagger/1000}")"
    fi
    if cmd_launch "$ws" "$exec_cmd" "$silent"; then
      echo "$(date -u) OK ws=$ws name=$name" >> "$boot_log" 2>/dev/null || true
    else
      echo "$(date -u) FAIL ws=$ws name=$name" >> "$boot_log" 2>/dev/null || true
      echo "failed to launch $name" >&2
    fi
    idx=$((idx+1))
  done

  # record boot id on success
  if _refuse_symlink_dest "$last_boot_file"; then
    tmp=$(mktemp "$last_boot_file.tmp.XXXXXX") && printf '%s' "$boot_id" > "$tmp" && { if [[ -L "$last_boot_file" ]]; then rm -f "$tmp"; else mv -f "$tmp" "$last_boot_file"; fi; } || rm -f "$tmp"
  fi
  echo "done"
}

# Hyprland facts for the panel preview. Last field is per-workspace layouts
# (id:layout,...), matching Super+L / omarchy-hyprland-workspace-layout-toggle.
cmd_hypr_facts() {
  local L C GI GO B R MF S MW MH
  L=$(hyprctl getoption general:layout -j 2>/dev/null | jq -r '.str // empty')
  C=$(hyprctl getoption scrolling:column_width -j 2>/dev/null | jq -r '.float // 0.49')
  GI=$(hyprctl getoption general:gaps_in -j 2>/dev/null | jq -r '(.css // "5") | split(" ")[0] | (tonumber? // 5)')
  GO=$(hyprctl getoption general:gaps_out -j 2>/dev/null | jq -r '(.css // "10") | split(" ")[0] | (tonumber? // 10)')
  B=$(hyprctl getoption general:border_size -j 2>/dev/null | jq -r '.int // 2')
  R=$(hyprctl getoption decoration:rounding -j 2>/dev/null | jq -r '.int // 0')
  MF=$(hyprctl getoption master:mfact -j 2>/dev/null | jq -r '.float // 0.55')
  S=$(hyprctl monitors -j 2>/dev/null | jq -r '([.[] | select(.focused == true)][0] // .[0] // {}).scale // 1')
  MW=$(hyprctl monitors -j 2>/dev/null | jq -r '([.[] | select(.focused == true)][0] // .[0] // {}).width // 1920')
  MH=$(hyprctl monitors -j 2>/dev/null | jq -r '([.[] | select(.focused == true)][0] // .[0] // {}).height // 1080')

  local -A layouts=()
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/workspace-layouts"
  local f id lay
  if [[ -d $dir ]]; then
    for f in "$dir"/*.lua; do
      [[ -f $f ]] || continue
      id=$(basename "$f" .lua)
      [[ $id =~ ^[0-9]+$ ]] || continue
      lay=$(sed -n 's/.*layout = "\([^"]*\)".*/\1/p' "$f" | head -n1)
      [[ -n $lay ]] && layouts[$id]=$lay
    done
  fi
  while IFS=: read -r id lay; do
    [[ -n $id && -n $lay && $lay != "null" ]] && layouts[$id]=$lay
  done < <(hyprctl workspaces -j 2>/dev/null | jq -r '.[] | select(.id > 0) | "\(.id):\(.tiledLayout // empty)"')

  local ws_pairs=""
  for id in "${!layouts[@]}"; do
    ws_pairs+="${ws_pairs:+,}${id}:${layouts[$id]}"
  done

  printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "${L:-dwindle}" "${C:-0.49}" "${GI:-5}" "${GO:-10}" "${B:-2}" "${R:-0}" \
    "${MF:-0.55}" "${S:-1}" "${MW:-1920}" "${MH:-1080}" "$ws_pairs"
}

# Persist and apply layout for one workspace — same files Super+L writes.
cmd_set_workspace_layout() {
  local ws="$1"
  local layout="$2"
  if ! [[ $ws =~ ^[0-9]+$ ]]; then
    echo "invalid workspace: $ws" >&2
    exit 1
  fi
  case "$layout" in
    dwindle|scrolling|master) ;;
    *) echo "invalid layout: $layout" >&2; exit 1 ;;
  esac
  local dir="${XDG_STATE_HOME:-$HOME/.local/state}/omarchy/workspace-layouts"
  mkdir -p "$dir"
  local dest="$dir/$ws.lua"
  if _refuse_symlink_dest "$dest"; then
    local tmp
    tmp=$(mktemp "$dest.tmp.XXXXXX") && printf 'hl.workspace_rule({ workspace = "%s", layout = "%s" })\n' "$ws" "$layout" > "$tmp" && { if [[ -L "$dest" ]]; then rm -f "$tmp"; echo "refusing symlink (race): $dest" >&2; else mv -f "$tmp" "$dest"; fi; } || rm -f "$tmp"
  else
    echo "refusing symlink dest: $dest" >&2; return 1
  fi
  hyprctl eval "hl.workspace_rule({ workspace = \"$ws\", layout = \"$layout\" })" >/dev/null 2>&1 || \
    hyprctl keyword workspace "$ws, layout:$layout"
}

case "${1:-}" in
  --ensure-config) cmd_ensure_config ;;
  --list-apps) cmd_list_apps ;;
  --status) cmd_status ;;
  --launch) shift; cmd_launch "$@" ;;
  --launch-all) shift; cmd_launch_all "$@" ;;
  --force-launch-all) cmd_launch_all "true" ;;
  --default-config) default_config ;;
  --hypr-facts) cmd_hypr_facts ;;
  --set-workspace-layout) shift; cmd_set_workspace_layout "$@" ;;
  --help|-h|"") cat <<'HELP'
auto-workspace.sh — helper for tenzin.auto-workspace

  --ensure-config         ensure config exists and print it
  --list-apps             list .desktop apps as TSV (name exec icon file)
  --status                json status
  --launch <ws> <exec> [silent]  launch single app on workspace
  --launch-all [--force]  launch all enabled assignments (respects onlyOnBoot)
  --force-launch-all      always launch regardless of settings
  --default-config        print default config
  --hypr-facts            print layout/gaps/monitor facts plus per-workspace layouts
  --set-workspace-layout <ws> <dwindle|scrolling|master>
                          set one workspace's layout (same persist path as Super+L)
HELP
  ;;
  *) echo "unknown arg: $1" >&2; exit 1 ;;
esac
