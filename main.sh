#!/usr/bin/env bash
set -euo pipefail

# -------------------
# Fetches a dad joke from one of several sources, avoids repeats via seen.json,
# and sends it to a Telegram Bot.
# Relies on TELEGRAM_TOKEN and TELEGRAM_CHAT being set.

SEEN_FILE="seen.json"
MAX_RETRIES=${MAX_RETRIES:-5}

[[ -f "$SEEN_FILE" ]] || echo "[]" > "$SEEN_FILE"

# seen.json holds two kinds of entries per sent joke: "<source>:<id>" and
# "text:<key>". The text key catches the same joke coming from another source
# under a different ID.

# Lowercase letters and digits only, so punctuation, spacing and curly vs
# straight quotes don't matter. Prints "text:" alone if nothing is left.
text_key() {
  jq -rn --arg t "$1" '"text:" + ($t | ascii_downcase | gsub("[^a-z0-9]"; ""))'
}

# Args: joke ID, text key.
is_seen() {
  jq --arg id "$1" --arg tk "$2" 'any(.[]; . == $id or ($tk != "text:" and . == $tk))' "$SEEN_FILE"
}

# Args: joke ID, text key.
mark_seen() {
  local tmp
  tmp=$(mktemp)
  jq --arg id "$1" --arg tk "$2" '. + [$id] + (if $tk == "text:" then [] else [$tk] end)' "$SEEN_FILE" > "$tmp" && mv "$tmp" "$SEEN_FILE"
}

# Sets JOKE_ID and JOKE_TEXT. On a failed request or an unexpected body it
# returns 1 and leaves both unchanged, so one source being down costs a retry
# instead of failing the run.
fetch_joke() {
  local source=$(( RANDOM % 3 ))
  local prefix json id text count
  case $source in
    0)
      prefix="icanhazdadjoke"
      json=$(curl -sSf -H "Accept: application/json" -H "User-Agent: dad-jokes-4000" https://icanhazdadjoke.com) || return 1
      id=$(jq -r '.id // empty' <<< "$json") || return 1
      text=$(jq -r '.joke // empty' <<< "$json") || return 1
      ;;
    1)
      # The official-joke-api server is gone, but its archived data file is
      # still on GitHub. Its IDs were the 1-based position in this file, so
      # "official:<n>" entries already in seen.json still match.
      prefix="official"
      json=$(curl -sSf https://raw.githubusercontent.com/15Dkatz/official_joke_api/master/jokes/index.json) || return 1
      count=$(jq 'length' <<< "$json") || return 1
      [[ "$count" =~ ^[1-9][0-9]*$ ]] || return 1
      id=$(( RANDOM % count + 1 ))
      text=$(jq -r --argjson i "$id" '.[$i - 1] | [.setup, .punchline] | map(select(. != null and . != "")) | join("\n\n")' <<< "$json") || return 1
      ;;
    2)
      prefix="groandeck"
      json=$(curl -sSf -H "User-Agent: dad-jokes-4000" https://groandeck.com/api/v1/random) || return 1
      id=$(jq -r '.id // empty' <<< "$json") || return 1
      text=$(jq -r '[.setup, .punchline] | map(select(. != null and . != "")) | join("\n\n")' <<< "$json") || return 1
      ;;
  esac
  if [[ -z "$id" || -z "$text" ]]; then
    echo "Unexpected response from $prefix" >&2
    return 1
  fi
  JOKE_ID="$prefix:$id"
  JOKE_TEXT="$text"
}

JOKE_ID=""
JOKE_TEXT=""
JOKE_KEY=""

FOUND=false

for i in $(seq 1 "$MAX_RETRIES"); do
  if ! fetch_joke; then
    echo "Fetch failed, retrying ($i/$MAX_RETRIES)..."
    continue
  fi
  JOKE_KEY=$(text_key "$JOKE_TEXT")
  if [[ "$(is_seen "$JOKE_ID" "$JOKE_KEY")" == "false" ]]; then
    FOUND=true
    break
  fi
  echo "Already seen $JOKE_ID, retrying ($i/$MAX_RETRIES)..."
done

# Never send a repeat: fail the run instead, so it shows up in CI.
if [[ "$FOUND" != "true" ]]; then
  echo "No new joke after $MAX_RETRIES attempts" >&2
  exit 1
fi

./telegram "$JOKE_TEXT"
mark_seen "$JOKE_ID" "$JOKE_KEY"

if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'JOKE_TEXT<<JOKE_EOF\n%s\nJOKE_EOF\n' "$JOKE_TEXT" >> "$GITHUB_ENV"
fi
