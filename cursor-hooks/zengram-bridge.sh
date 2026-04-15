#!/usr/bin/env bash
# zengram-bridge.sh — push claude-mem session summary → Zengram collective memory
#
# Called from Cursor "stop" hook AFTER session-summary.sh has run.
# Reads the latest session summary from the claude-mem worker and posts
# it to Zengram as a type=fact memory so all agents can access it.
#
# Required env vars (set in shell profile or ~/.cursor/mcp.json):
#   ZENGRAM_URL      e.g. http://100.101.239.56:30084
#   ZENGRAM_API_KEY  the Zengram API key
#
# Optional:
#   CLAUDE_MEM_WORKER_PORT  (default: 37777)
#   CLAUDE_MEM_WORKER_HOST  (default: 127.0.0.1)

set -euo pipefail

WORKER_HOST="${CLAUDE_MEM_WORKER_HOST:-127.0.0.1}"
WORKER_PORT="${CLAUDE_MEM_WORKER_PORT:-37777}"
WORKER_BASE="http://${WORKER_HOST}:${WORKER_PORT}"

ZENGRAM_URL="${ZENGRAM_URL:-}"
ZENGRAM_API_KEY="${ZENGRAM_API_KEY:-}"

# Silent exit if Zengram not configured — bridge is opt-in
if [[ -z "$ZENGRAM_URL" || -z "$ZENGRAM_API_KEY" ]]; then
  echo '{"continue":true,"suppressOutput":true}'
  exit 0
fi

# Silent exit if worker not running
if ! curl -sf "${WORKER_BASE}/health" >/dev/null 2>&1; then
  echo '{"continue":true,"suppressOutput":true}'
  exit 0
fi

# Fetch latest session summary from claude-mem worker
SUMMARY=$(curl -sf "${WORKER_BASE}/api/sessions/latest-summary" 2>/dev/null || echo "")

if [[ -z "$SUMMARY" || "$SUMMARY" == "null" ]]; then
  echo '{"continue":true,"suppressOutput":true}'
  exit 0
fi

# Extract fields from the summary JSON
SESSION_ID=$(echo "$SUMMARY" | jq -r '.sessionId // .session_id // "unknown"' 2>/dev/null || echo "unknown")
PROJECT=$(echo "$SUMMARY" | jq -r '.project // .projectName // "unknown"' 2>/dev/null || echo "unknown")
CONTENT=$(echo "$SUMMARY" | jq -r '.summary // .content // ""' 2>/dev/null || echo "")
TIMESTAMP=$(echo "$SUMMARY" | jq -r '.createdAt // .timestamp // ""' 2>/dev/null || echo "")

if [[ -z "$CONTENT" ]]; then
  echo '{"continue":true,"suppressOutput":true}'
  exit 0
fi

# Build Zengram memory payload
PAYLOAD=$(jq -n \
  --arg content "Claude-mem session summary\nProject: ${PROJECT}\nSession: ${SESSION_ID}\n\n${CONTENT}" \
  --arg project "$PROJECT" \
  --arg session_id "$SESSION_ID" \
  --arg ts "$TIMESTAMP" \
  '{
    type: "fact",
    category: "session",
    source_agent: "cursor",
    importance: 0.6,
    content: $content,
    tags: ["claude-mem", "cursor-session", "auto-capture"],
    metadata: {
      memory_subtype: "session_summary",
      project: $project,
      claude_mem_session_id: $session_id,
      captured_at: $ts
    }
  }')

# Fire-and-forget POST to Zengram (don't block Cursor)
curl -sf -X POST "${ZENGRAM_URL}/api/memories" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${ZENGRAM_API_KEY}" \
  -d "$PAYLOAD" \
  >/dev/null 2>&1 &

echo '{"continue":true,"suppressOutput":true}'
