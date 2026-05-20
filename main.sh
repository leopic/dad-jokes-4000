#!/usr/bin/env bash
set -euo pipefail

# -------------------
# Fetches a dad joke from one of several sources, avoids repeats via seen.json,
# and sends it to a Telegram Bot.
# Relies on TELEGRAM_TOKEN and TELEGRAM_CHAT being set.

SEEN_FILE="seen.json"
MAX_RETRIES=5

[[ -f "$SEEN_FILE" ]] || echo "[]" > "$SEEN_FILE"

is_seen() {
  jq --arg id "$1" 'any(.[]; . == $id)' "$SEEN_FILE"
}

mark_seen() {
  local tmp
  tmp=$(mktemp)
  jq --arg id "$1" '. + [$id]' "$SEEN_FILE" > "$tmp" && mv "$tmp" "$SEEN_FILE"
}

fetch_joke() {
  local source=$(( RANDOM % 3 ))
  local json
  case $source in
    0)
      json=$(curl -sf -H "Accept: application/json" -H "User-Agent: dad-jokes-4000" https://icanhazdadjoke.com)
      JOKE_ID="icanhazdadjoke:$(jq -r '.id' <<< "$json")"
      JOKE_TEXT=$(jq -r '.joke' <<< "$json")
      ;;
    1)
      json=$(curl -sf "https://v2.jokeapi.dev/joke/Pun?type=single")
      JOKE_ID="jokeapi:$(jq -r '.id' <<< "$json")"
      JOKE_TEXT=$(jq -r '.joke' <<< "$json")
      ;;
    2)
      json=$(curl -sf "https://official-joke-api.appspot.com/jokes/random")
      JOKE_ID="official:$(jq -r '.id' <<< "$json")"
      JOKE_TEXT="$(jq -r '.setup' <<< "$json")"$'\n\n'"$(jq -r '.punchline' <<< "$json")"
      ;;
  esac
}

JOKE_ID=""
JOKE_TEXT=""

for i in $(seq 1 "$MAX_RETRIES"); do
  fetch_joke
  [[ "$(is_seen "$JOKE_ID")" == "false" ]] && break
  echo "Already seen $JOKE_ID, retrying ($i/$MAX_RETRIES)..."
done

./telegram "$JOKE_TEXT"
mark_seen "$JOKE_ID"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'JOKE_TEXT<<JOKE_EOF\n%s\nJOKE_EOF\n' "$JOKE_TEXT" >> "$GITHUB_ENV"
fi
