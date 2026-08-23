#!/usr/bin/env bash
set -euo pipefail

# Polls Telegram for new messages since the last processed update. If the
# tracked chat asked for a joke, triggers main.sh to fetch and send one
# right away instead of waiting for the next scheduled slot.
# Relies on TELEGRAM_TOKEN and TELEGRAM_CHAT being set.

OFFSET_FILE="offset.json"
COMMAND_RE='^/joke(@[a-z0-9_]+)?[[:space:]]*$'

[[ -f "$OFFSET_FILE" ]] || echo '{"offset": 0}' > "$OFFSET_FILE"

offset=$(jq -r '.offset' "$OFFSET_FILE")

updates=$(curl -sf "https://api.telegram.org/bot${TELEGRAM_TOKEN}/getUpdates?offset=$((offset + 1))&timeout=0")

requested=false

while IFS= read -r update; do
  [[ -z "$update" ]] && continue

  update_id=$(jq -r '.update_id' <<< "$update")
  chat_id=$(jq -r '.message.chat.id // empty' <<< "$update")
  text=$(jq -r '.message.text // empty' <<< "$update" | tr '[:upper:]' '[:lower:]')

  if [[ "$chat_id" == "$TELEGRAM_CHAT" && "$text" =~ $COMMAND_RE ]]; then
    requested=true
  fi

  offset="$update_id"
done < <(jq -c '.result[]' <<< "$updates")

jq -n --argjson offset "$offset" '{offset: $offset}' > "$OFFSET_FILE"

if [[ "$requested" == "true" ]]; then
  echo "Joke requested, fetching now..."
  ./main.sh
fi
