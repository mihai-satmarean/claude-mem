#!/usr/bin/env bash
# zengram-sync.sh — incremental sync: claude-mem observations → Zengram
#
# Safe to run at any time during a live session. Tracks last sync
# via ~/.claude-mem/zengram-sync-state.json to avoid duplicates.
#
# Usage:
#   bash zengram-sync.sh              # sync new observations since last run
#   bash zengram-sync.sh --full       # resync everything (ignore state)
#   bash zengram-sync.sh --dry-run    # print what would be sent, don't post
#   bash zengram-sync.sh --summary    # also push latest session summary
#
# Required env vars:
#   ZENGRAM_URL      e.g. http://100.101.239.56:30084
#   ZENGRAM_API_KEY
#
# Optional:
#   CLAUDE_MEM_WORKER_PORT  (default: 37777)
#   CLAUDE_MEM_WORKER_HOST  (default: 127.0.0.1)

set -euo pipefail

WORKER_HOST="${CLAUDE_MEM_WORKER_HOST:-127.0.0.1}"
WORKER_PORT="${CLAUDE_MEM_WORKER_PORT:-37777}"
WORKER_BASE="http://${WORKER_HOST}:${WORKER_PORT}"
STATE_FILE="${HOME}/.claude-mem/zengram-sync-state.json"
DRY_RUN=false
FULL_SYNC=false
INCLUDE_SUMMARY=false

for arg in "$@"; do
  case "$arg" in
    --dry-run)   DRY_RUN=true ;;
    --full)      FULL_SYNC=true ;;
    --summary)   INCLUDE_SUMMARY=true ;;
  esac
done

ZENGRAM_URL="${ZENGRAM_URL:-}"
ZENGRAM_API_KEY="${ZENGRAM_API_KEY:-}"

if [[ -z "$ZENGRAM_URL" || -z "$ZENGRAM_API_KEY" ]]; then
  echo "ERROR: ZENGRAM_URL and ZENGRAM_API_KEY must be set" >&2
  exit 1
fi

if ! curl -sf "${WORKER_BASE}/health" >/dev/null 2>&1; then
  echo "ERROR: claude-mem worker not running at ${WORKER_BASE}" >&2
  exit 1
fi

# Read last sync state
LAST_SYNC_ID=0
LAST_SYNC_TS=""
if [[ -f "$STATE_FILE" ]] && [[ "$FULL_SYNC" == "false" ]]; then
  LAST_SYNC_ID=$(jq -r '.last_observation_id // 0' "$STATE_FILE" 2>/dev/null || echo 0)
  LAST_SYNC_TS=$(jq -r '.last_sync_at // ""' "$STATE_FILE" 2>/dev/null || echo "")
fi

echo "claude-mem → Zengram sync"
echo "  Last sync: ${LAST_SYNC_TS:-never} (observation id > ${LAST_SYNC_ID})"
echo "  Dry run: ${DRY_RUN}"
echo ""

# Fetch recent observations from claude-mem
# /api/search/observations supports query, limit; results sorted by id desc
OBSERVATIONS=$(curl -sf \
  "${WORKER_BASE}/api/search/observations?limit=200" \
  -H "Content-Type: application/json" \
  2>/dev/null || echo "[]")

if [[ -z "$OBSERVATIONS" ]] || [[ "$OBSERVATIONS" == "[]" ]]; then
  echo "No observations found in claude-mem."
  exit 0
fi

# Filter: only ids > LAST_SYNC_ID
TOTAL=$(echo "$OBSERVATIONS" | jq "length" 2>/dev/null || echo 0)
NEW_OBS=$(echo "$OBSERVATIONS" | jq "[.[] | select((.id // 0) > ${LAST_SYNC_ID})]" 2>/dev/null || echo "[]")
NEW_COUNT=$(echo "$NEW_OBS" | jq "length" 2>/dev/null || echo 0)

echo "Total observations: ${TOTAL} | New since last sync: ${NEW_COUNT}"

if [[ "$NEW_COUNT" -eq 0 ]]; then
  echo "Nothing new to sync."
  exit 0
fi

# Find max id for state update
MAX_ID=$(echo "$NEW_OBS" | jq '[.[].id // 0] | max' 2>/dev/null || echo 0)

# Batch observations by session into Zengram memories
# Group by sessionId, create one memory per session batch
SESSIONS=$(echo "$NEW_OBS" | jq -r '[.[].sessionId // "unknown"] | unique[]' 2>/dev/null || echo "unknown")

PUSHED=0
ERRORS=0

while IFS= read -r session_id; do
  SESSION_OBS=$(echo "$NEW_OBS" | jq --arg sid "$session_id" '[.[] | select(.sessionId == $sid)]' 2>/dev/null || echo "[]")
  OBS_COUNT=$(echo "$SESSION_OBS" | jq length 2>/dev/null || echo 0)

  # Build content: list of tool calls / observations for this session
  CONTENT=$(echo "$SESSION_OBS" | jq -r '
    "claude-mem observations (session: " + (.[0].sessionId // "unknown") + ")\n" +
    "Project: " + (.[0].project // "unknown") + "\n\n" +
    (map(
      "• [" + (.type // "obs") + "] " + (.tool_name // .toolName // "?") + ": " +
      ((.content // .summary // .tool_response // "") | tostring | .[0:200])
    ) | join("\n"))
  ' 2>/dev/null || echo "claude-mem session observations")

  PROJECT=$(echo "$SESSION_OBS" | jq -r '.[0].project // "unknown"' 2>/dev/null || echo "unknown")
  FIRST_TS=$(echo "$SESSION_OBS" | jq -r '.[0].createdAt // ""' 2>/dev/null || echo "")
  OBS_IDS=$(echo "$SESSION_OBS" | jq -r '[.[].id // 0 | tostring] | join(",")' 2>/dev/null || echo "")

  PAYLOAD=$(jq -n \
    --arg content "$CONTENT" \
    --arg project "$PROJECT" \
    --arg session_id "$session_id" \
    --arg obs_ids "$OBS_IDS" \
    --arg ts "$FIRST_TS" \
    --argjson count "$OBS_COUNT" \
    '{
      type: "fact",
      category: "session",
      source_agent: "cursor",
      importance: 0.5,
      content: $content,
      tags: ["claude-mem", "observations", "auto-sync"],
      metadata: {
        memory_subtype: "observation_batch",
        project: $project,
        claude_mem_session_id: $session_id,
        observation_ids: $obs_ids,
        observation_count: $count,
        captured_at: $ts
      }
    }')

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Would push ${OBS_COUNT} observations for session ${session_id} (project: ${PROJECT})"
  else
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
      -X POST "${ZENGRAM_URL}/api/memories" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer ${ZENGRAM_API_KEY}" \
      -d "$PAYLOAD" 2>/dev/null || echo "000")

    if [[ "$HTTP_STATUS" =~ ^2 ]]; then
      echo "  pushed: session ${session_id} (${OBS_COUNT} obs, project: ${PROJECT})"
      PUSHED=$((PUSHED + 1))
    else
      echo "  ERROR ${HTTP_STATUS}: session ${session_id}" >&2
      ERRORS=$((ERRORS + 1))
    fi
  fi
done <<< "$SESSIONS"

# Optionally push latest session summary
if [[ "$INCLUDE_SUMMARY" == "true" ]]; then
  SUMMARY=$(curl -sf "${WORKER_BASE}/api/sessions/summarize" 2>/dev/null || echo "")
  if [[ -n "$SUMMARY" ]] && [[ "$SUMMARY" != "null" ]]; then
    CONTENT=$(echo "$SUMMARY" | jq -r '.summary // .content // ""' 2>/dev/null || echo "")
    if [[ -n "$CONTENT" ]]; then
      PROJECT=$(echo "$SUMMARY" | jq -r '.project // "unknown"' 2>/dev/null || echo "unknown")
      PAYLOAD=$(jq -n \
        --arg content "Session summary (live)\nProject: ${PROJECT}\n\n${CONTENT}" \
        --arg project "$PROJECT" \
        '{
          type: "fact",
          category: "session",
          source_agent: "cursor",
          importance: 0.7,
          content: $content,
          tags: ["claude-mem", "cursor-session", "summary", "live-sync"],
          metadata: { memory_subtype: "session_summary", project: $project }
        }')
      if [[ "$DRY_RUN" != "true" ]]; then
        curl -sf -X POST "${ZENGRAM_URL}/api/memories" \
          -H "Content-Type: application/json" \
          -H "Authorization: Bearer ${ZENGRAM_API_KEY}" \
          -d "$PAYLOAD" >/dev/null 2>&1 && echo "  pushed: live session summary"
      else
        echo "[DRY-RUN] Would push live session summary"
      fi
    fi
  fi
fi

# Update state file
if [[ "$DRY_RUN" != "true" ]] && [[ "$PUSHED" -gt 0 ]]; then
  mkdir -p "$(dirname "$STATE_FILE")"
  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson max_id "$MAX_ID" \
    '{last_sync_at: $ts, last_observation_id: $max_id}' \
    > "$STATE_FILE"
fi

echo ""
echo "Done. Pushed: ${PUSHED} batches | Errors: ${ERRORS}"
