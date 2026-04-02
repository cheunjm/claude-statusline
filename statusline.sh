#!/bin/bash
# claude-statusline — A lightweight, single-line statusline for Claude Code
# https://github.com/cheunjm/claude-statusline
#
# Format: [agent|task] · dir · ⎥ [ISSUE-ID] branch · [CI #N] · model · tokens · $cost · 5h:X% 7d:Y% · ⚡cache% · Nm

# Ensure tools like jq, git are available (Claude runs with minimal PATH)
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.asdf/shims:$PATH"

# Load config (KEY=value format, all optional)
STATUSLINE_CONF="${STATUSLINE_CONF:-$HOME/.claude/statusline.conf}"
# Defaults
SHOW_GIT=true
SHOW_RATE_LIMITS=true
SHOW_CACHE=true
SHOW_DURATION=true
SHOW_ISSUE_ID=true
SHOW_TMUX_TASK=true
CONTEXT_WARN_PCT=70
CONTEXT_CRIT_PCT=90
COST_WARN_CENTS=50
COST_CRIT_CENTS=200
RATE_WARN_PCT=60
RATE_CRIT_PCT=85
GIT_CACHE_TTL=5
# shellcheck disable=SC1090
[ -f "$STATUSLINE_CONF" ] && . "$STATUSLINE_CONF"

input=$(cat)

# Batch extract all JSON fields in a single jq call
eval "$(echo "$input" | jq -r '
  "cwd='"'"'\(.workspace.current_dir // .cwd // "")'"'"'",
  "model_full='"'"'\(.model.display_name // "")'"'"'",
  "used_pct='"'"'\(.context_window.used_percentage // "")'"'"'",
  "used_tokens='"'"'\(.context_window.current_usage.input_tokens // "")'"'"'",
  "cache_tokens='"'"'\(.context_window.current_usage.cache_read_input_tokens // "")'"'"'",
  "cache_create_tokens='"'"'\(.context_window.current_usage.cache_creation_input_tokens // "")'"'"'",
  "ctx_size='"'"'\(.context_window.context_window_size // "")'"'"'",
  "cost='"'"'\(.cost.total_cost_usd // "")'"'"'",
  "duration_ms='"'"'\(.cost.total_duration_ms // "")'"'"'",
  "worktree='"'"'\(.worktree.name // "")'"'"'",
  "agent_name='"'"'\(.agent.name // "")'"'"'",
  "rate_5h='"'"'\(.rate_limits.five_hour.used_percentage // "")'"'"'",
  "rate_7d='"'"'\(.rate_limits.seven_day.used_percentage // "")'"'"'"
' 2>/dev/null)"

# Shorten cwd: replace $HOME with ~
home_dir="$HOME"
short_dir="${cwd/#$home_dir/\~}"

# Compact model name: "Claude Opus 4.6 (1M context)" → "opus"
# shellcheck disable=SC2154
model=$(echo "$model_full" | sed 's/^Claude //' | sed 's/ [0-9].*//' | tr '[:upper:]' '[:lower:]')

# Git branch — cached to avoid repeated subprocess overhead
# Cache key includes cwd hash to avoid stale data on directory changes
cache_key=$(printf '%s' "$cwd" | cksum | cut -d' ' -f1)
CACHE_FILE="/tmp/.claude-statusline-git-${cache_key}"
git_branch=""
is_worktree=""

if [ "$SHOW_GIT" = "true" ] && [ -n "$cwd" ]; then
  cache_valid=""
  if [ -f "${CACHE_FILE}" ]; then
    # macOS uses stat -f %m, Linux uses stat -c %Y
    cache_mtime=$(stat -f %m "${CACHE_FILE}" 2>/dev/null || stat -c %Y "${CACHE_FILE}" 2>/dev/null || echo 0)
    cache_age=$(( $(date +%s) - cache_mtime ))
    if [ "$cache_age" -lt "$GIT_CACHE_TTL" ] 2>/dev/null; then
      cache_valid=1
    fi
  fi

  if [ -n "$cache_valid" ]; then
    git_branch=$(sed -n '1p' "${CACHE_FILE}" 2>/dev/null)
    is_worktree=$(sed -n '2p' "${CACHE_FILE}" 2>/dev/null)
    git_common=$(sed -n '3p' "${CACHE_FILE}" 2>/dev/null)
    [ "$is_worktree" = "$git_branch" ] && is_worktree=""
  else
    git_info=$(git -C "$cwd" --no-optional-locks rev-parse --abbrev-ref HEAD --git-dir --git-common-dir 2>/dev/null)
    if [ -n "$git_info" ]; then
      git_branch=$(echo "$git_info" | sed -n '1p')
      git_dir=$(echo "$git_info" | sed -n '2p')
      git_common=$(echo "$git_info" | sed -n '3p')
      if [ -z "$worktree" ] && [ -n "$git_dir" ] && [ -n "$git_common" ] && [ "$git_dir" != "$git_common" ]; then
        is_worktree=$(basename "$cwd")
      fi
    fi
    printf "%s\n%s\n%s\n" "$git_branch" "$is_worktree" "$git_common" > "${CACHE_FILE}" 2>/dev/null
  fi
fi

# Detect applied worktree patch (from scripts/worktree.sh apply)
applied_patch_id=""
if [ -n "$git_common" ]; then
  # Resolve relative git_common against cwd
  case "$git_common" in
    /*) applied_dir="$git_common/applied-patch" ;;
    *)  applied_dir="$cwd/$git_common/applied-patch" ;;
  esac
  if [ -d "$applied_dir" ]; then
    patch_file=$(find "$applied_dir" -maxdepth 1 -name '*.patch' 2>/dev/null | head -1)
    if [ -n "$patch_file" ]; then
      applied_patch_id=$(basename "$patch_file" .patch)
    fi
  fi
fi

# Extract issue ID from branch (e.g. feat/INF-60-title → INF-60, fix/PROJ-123-bug → PROJ-123)
# shellcheck disable=SC2034
issue_id=""
if [ "$SHOW_ISSUE_ID" = "true" ] && [ -n "$git_branch" ]; then
  # shellcheck disable=SC2034
  issue_id=$(echo "$git_branch" | grep -oE '[A-Z]{2,}-[0-9]+' | head -1)
fi

# Load task summary from tmux pane title
task_summary=""
if [ "$SHOW_TMUX_TASK" = "true" ] && [ -n "$TMUX_PANE" ]; then
  pane_title=$(tmux display-message -p -t "$TMUX_PANE" '#{pane_title}' 2>/dev/null)
  if [ -n "$pane_title" ]; then
    task_summary=$(echo "$pane_title" | sed 's/^[^ ]* //' | sed 's/: .*$//')
  fi
fi

# --- Helpers ---

fmt_k() {
  v="$1"
  if [ -z "$v" ] || [ "$v" = "0" ]; then echo "0"; return; fi
  if [ "$v" -ge 1000 ] 2>/dev/null; then
    echo "$((v / 1000))k"
  else
    echo "$v"
  fi
}

color_by_pct() {
  val=$(printf "%.0f" "$1" 2>/dev/null || echo "0")
  warn="$2"; crit="$3"
  if [ "$val" -lt "$warn" ] 2>/dev/null; then echo "32"
  elif [ "$val" -lt "$crit" ] 2>/dev/null; then echo "33"
  else echo "31"; fi
}

SEP=" \xc2\xb7 "  # middle dot ·

# --- Output ---

# PREFIX: subagent name OR task summary
if [ -n "$agent_name" ]; then
  printf "\033[2;36m\xe2\x86\xb3 %s\033[0m" "$agent_name"
  printf "%b" "$SEP"
elif [ -n "$task_summary" ]; then
  printf "\033[2;3;37m%s\033[0m" "$task_summary"
  printf "%b" "$SEP"
fi

# DIR (yellow)
printf "\033[33m%s\033[0m" "$short_dir"

# BRANCH with issue ID and worktree badge
if [ -n "$git_branch" ]; then
  printf "%b" "$SEP"
  printf "\033[35m\xef\x9c\xa5 \033[0m"
  wt_label="${worktree:-$is_worktree}"
  if [ -n "$wt_label" ]; then
    printf "\033[36m[%s] \033[0m" "$wt_label"
  fi
  printf "\033[35m%s\033[0m" "$git_branch"
fi

# APPLIED PATCH badge (yellow — shows when a worktree patch is applied to main)
if [ -n "$applied_patch_id" ]; then
  printf "%b\033[33m\xe2\x8e\x87 %s\xe2\x86\x92main\033[0m" "$SEP" "$applied_patch_id"
fi

# CI WATCH (animated spinner when gh pr checks is running)
ci_pid=$(pgrep -f "gh pr checks" 2>/dev/null | head -1)
if [ -n "$ci_pid" ]; then
  ci_args=$(ps -p "$ci_pid" -o args= 2>/dev/null)
  ci_pr=$(echo "$ci_args" | grep -oE 'checks[[:space:]]+([0-9]+)' | grep -oE '[0-9]+')
  spin_chars=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  spin_idx=$(( $(date +%s) % 10 ))
  spin_char="${spin_chars[$spin_idx]}"
  ci_label="CI"
  [ -n "$ci_pr" ] && ci_label="CI #${ci_pr}"
  printf "%b\033[33m%s %s\033[0m" "$SEP" "$spin_char" "$ci_label"
fi

# MODEL (blue)
if [ -n "$model" ]; then
  printf "%b\033[34m%s\033[0m" "$SEP" "$model"
fi

# CONTEXT — "Xk/Yk" with color
if [ -n "$used_tokens" ] && [ -n "$ctx_size" ] && [ "$ctx_size" -gt 0 ] 2>/dev/null; then
  total_used="$used_tokens"
  if [ -n "$cache_tokens" ] && [ "$cache_tokens" -gt 0 ] 2>/dev/null; then
    total_used=$((used_tokens + cache_tokens))
  fi
  if [ -n "$cache_create_tokens" ] && [ "$cache_create_tokens" -gt 0 ] 2>/dev/null; then
    total_used=$((total_used + cache_create_tokens))
  fi
  used_k=$(fmt_k "$total_used")
  ctx_k=$(fmt_k "$ctx_size")
  c=$(color_by_pct "${used_pct:-0}" "$CONTEXT_WARN_PCT" "$CONTEXT_CRIT_PCT")
  printf "%b\033[%sm%s/%s\033[0m" "$SEP" "$c" "$used_k" "$ctx_k"
elif [ -n "$used_pct" ]; then
  used_int=$(printf "%.0f" "$used_pct" 2>/dev/null || echo "0")
  c=$(color_by_pct "$used_int" "$CONTEXT_WARN_PCT" "$CONTEXT_CRIT_PCT")
  printf "%b\033[%sm%s%% ctx\033[0m" "$SEP" "$c" "$used_int"
fi

# COST (color thresholds in cents via config)
if [ -n "$cost" ]; then
  cost_whole="${cost%%.*}"
  cost_frac="${cost#*.}"
  [ "$cost_whole" = "$cost" ] && cost_frac="00"
  cost_frac3=$(printf "%.3s" "${cost_frac}000")
  cost_millis=$((cost_whole * 1000 + cost_frac3))

  if [ "$cost_millis" -lt 10 ] 2>/dev/null; then
    cost_fmt=$(printf "\$0.%s" "$cost_frac3")
  else
    cost_frac2=$(printf "%.2s" "${cost_frac}00")
    cost_fmt=$(printf "\$%s.%s" "$cost_whole" "$cost_frac2")
  fi
  c=$(color_by_pct "$((cost_millis / 10))" "$COST_WARN_CENTS" "$COST_CRIT_CENTS")
  printf "%b\033[%sm%s\033[0m" "$SEP" "$c" "$cost_fmt"
fi

# RATE LIMITS (5h:X% 7d:Y%)
if [ "$SHOW_RATE_LIMITS" = "true" ]; then
  if [ -n "$rate_5h" ] || [ -n "$rate_7d" ]; then
    printf "%b" "$SEP"
    if [ -n "$rate_5h" ]; then
      r5=$(printf "%.0f" "$rate_5h" 2>/dev/null || echo "0")
      c=$(color_by_pct "$r5" "$RATE_WARN_PCT" "$RATE_CRIT_PCT")
      printf "\033[%sm5h:%s%%\033[0m" "$c" "$r5"
    fi
    if [ -n "$rate_5h" ] && [ -n "$rate_7d" ]; then
      printf " "
    fi
    if [ -n "$rate_7d" ]; then
      r7=$(printf "%.0f" "$rate_7d" 2>/dev/null || echo "0")
      c=$(color_by_pct "$r7" "$RATE_WARN_PCT" "$RATE_CRIT_PCT")
      printf "\033[%sm7d:%s%%\033[0m" "$c" "$r7"
    fi
  fi
fi

# CACHE HIT %
if [ "$SHOW_CACHE" = "true" ] && [ -n "$used_tokens" ] && [ -n "$cache_tokens" ] && [ "$used_tokens" -gt 0 ] 2>/dev/null; then
  total_input=$((used_tokens + cache_tokens))
  if [ -n "$cache_create_tokens" ] && [ "$cache_create_tokens" -gt 0 ] 2>/dev/null; then
    total_input=$((total_input + cache_create_tokens))
  fi
  if [ "$total_input" -gt 0 ] 2>/dev/null; then
    cache_pct=$((cache_tokens * 100 / total_input))
    if [ "$cache_pct" -ge 50 ] 2>/dev/null; then c="32"
    elif [ "$cache_pct" -ge 20 ] 2>/dev/null; then c="33"
    else c="31"; fi
    printf "%b\033[%sm\xe2\x9a\xa1%s%%\033[0m" "$SEP" "$c" "$cache_pct"
  fi
fi

# SESSION DURATION
if [ "$SHOW_DURATION" = "true" ] && [ -n "$duration_ms" ] && [ "$duration_ms" -gt 0 ] 2>/dev/null; then
  total_sec=$((duration_ms / 1000))
  if [ "$total_sec" -ge 3600 ] 2>/dev/null; then
    hrs=$((total_sec / 3600))
    mins=$(( (total_sec % 3600) / 60 ))
    printf "%b\033[2m%dh%02dm\033[0m" "$SEP" "$hrs" "$mins"
  elif [ "$total_sec" -ge 60 ] 2>/dev/null; then
    mins=$((total_sec / 60))
    printf "%b\033[2m%dm\033[0m" "$SEP" "$mins"
  else
    printf "%b\033[2m%ds\033[0m" "$SEP" "$total_sec"
  fi
fi

printf "\n"
