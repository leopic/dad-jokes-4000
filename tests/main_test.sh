#!/usr/bin/env bash
# Tests for main.sh. No network: curl and ./telegram are replaced by fakes.
# Run from the repo root: tests/main_test.sh
set -uo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
FAILED=0

# Fake bodies, one per source. Each test can override them.
ICANHAZ_OK='{"id":"ican1","joke":"Why did the chicken? Fowl play!"}'
OFFICIAL_OK='[{"type":"general","setup":"What do you call a fake noodle?","punchline":"An impasta."}]'
GROANDECK_OK='{"id":"groan1","setup":"I am reading a book on glue.","punchline":"I cannot put it down."}'

# Runs main.sh in a temp dir. Env in: SEEN, FAIL_RE, ICANHAZ, OFFICIAL, GROANDECK.
# Sets: RC, SENT (text given to ./telegram, or empty), SEEN_OUT (seen.json after).
run_main() {
  local work
  work=$(mktemp -d)
  mkdir -p "$work/bin"
  cp "$REPO/main.sh" "$work/main.sh"
  printf '%s' "${SEEN:-[]}" > "$work/seen.json"

  cat > "$work/telegram" <<'EOF'
#!/usr/bin/env bash
printf '%s' "$1" > sent.txt
EOF

  cat > "$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${@: -1}"
if [[ -n "${FAIL_RE:-}" && "$url" =~ $FAIL_RE ]]; then
  echo "curl: (22) The requested URL returned error: 503" >&2
  exit 22
fi
case "$url" in
  *icanhazdadjoke.com*) printf '%s' "$ICANHAZ" ;;
  *raw.githubusercontent.com*) printf '%s' "$OFFICIAL" ;;
  *groandeck.com*) printf '%s' "$GROANDECK" ;;
  *) echo "unexpected URL in test: $url" >&2; exit 99 ;;
esac
EOF
  chmod +x "$work/telegram" "$work/bin/curl"

  # Many retries so the random source pick reaches every working source.
  # GITHUB_ENV points at a temp file so a CI run of these tests doesn't write
  # JOKE_TEXT into the job env. "${VAR-default}" lets a test pass an empty body.
  ( cd "$work" && PATH="$work/bin:$PATH" MAX_RETRIES=50 GITHUB_ENV="$work/github_env" \
      ICANHAZ="${ICANHAZ-$ICANHAZ_OK}" OFFICIAL="${OFFICIAL-$OFFICIAL_OK}" GROANDECK="${GROANDECK-$GROANDECK_OK}" \
      FAIL_RE="${FAIL_RE:-}" ./main.sh ) > "$work/out.txt" 2>&1
  RC=$?
  SENT=$(cat "$work/sent.txt" 2>/dev/null || true)
  SEEN_OUT=$(jq -c . "$work/seen.json")
  OUT=$(cat "$work/out.txt")
  GH_ENV_OUT=$(cat "$work/github_env" 2>/dev/null || true)
  rm -rf "$work"
}

check() {
  local name=$1 cond=$2
  if eval "$cond"; then
    echo "ok   - $name"
  else
    echo "FAIL - $name"
    echo "       rc=$RC sent=$(printf '%q' "$SENT") seen=$SEEN_OUT"
    printf '%s\n' "$OUT" | sed 's/^/       | /'
    FAILED=1
  fi
}

seen_has() { jq -e --arg x "$1" 'index($x) != null' <<< "$SEEN_OUT" > /dev/null; }

# --- one source down: the run still sends a joke from another source
SEEN='[]' FAIL_RE='icanhazdadjoke' run_main
check "one source down still sends" '[[ $RC == 0 && -n "$SENT" ]]'
check "no joke from the down source" '! seen_has "icanhazdadjoke:ican1"'

# --- all sources down: nothing sent, run fails
SEEN='[]' FAIL_RE='.' run_main
check "all sources down fails the run" '[[ $RC != 0 && -z "$SENT" ]]'
check "all sources down leaves seen.json alone" '[[ $SEEN_OUT == "[]" ]]'

# --- bad bodies (HTML, wrong shape) count as a failed fetch
SEEN='[]' ICANHAZ='<html>oops</html>' OFFICIAL='{}' GROANDECK='[]' run_main
check "bad bodies fail the run without sending" '[[ $RC != 0 && -z "$SENT" ]]'

# --- empty or null bodies count as a failed fetch
SEEN='[]' ICANHAZ='' OFFICIAL='null' GROANDECK='null' run_main
check "empty/null bodies fail the run without sending" '[[ $RC != 0 && -z "$SENT" ]]'

# --- every joke already seen by ID: nothing sent (no repeats)
SEEN='["icanhazdadjoke:ican1","official:1","groandeck:groan1"]' run_main
check "all seen by ID fails the run without sending" '[[ $RC != 0 && -z "$SENT" ]]'

# --- same text under a new ID (other source) is a repeat too
SEEN='["text:whydidthechickenfowlplay","text:whatdoyoucallafakenoodleanimpasta","text:iamreadingabookonglueicannotputitdown"]' run_main
check "all seen by text fails the run without sending" '[[ $RC != 0 && -z "$SENT" ]]'

# --- new joke: sent, and both ID and text key stored
SEEN='[]' FAIL_RE='icanhazdadjoke|githubusercontent' run_main
check "new joke is sent" '[[ $RC == 0 && $SENT == $'"'"'I am reading a book on glue.\n\nI cannot put it down.'"'"' ]]'
check "new joke stores its ID" 'seen_has "groandeck:groan1"'
check "new joke stores its text key" 'seen_has "text:iamreadingabookonglueicannotputitdown"'

# --- official source: ID is the 1-based position in the data file
SEEN='[]' FAIL_RE='icanhazdadjoke|groandeck' run_main
check "official joke stored as official:1" '[[ $RC == 0 ]] && seen_has "official:1"'

# --- official IDs map to positions: with official:2 seen, only entries 1 or 3 go out, with matching text
OFFICIAL3='[{"setup":"one","punchline":"a"},{"setup":"two","punchline":"b"},{"setup":"three","punchline":"c"}]'
SEEN='["official:2"]' FAIL_RE='icanhazdadjoke|groandeck' OFFICIAL="$OFFICIAL3" run_main
check "official ID matches its position in the file" \
  '[[ $RC == 0 ]] && { { seen_has "official:1" && [[ $SENT == $'"'"'one\n\na'"'"' ]]; } || { seen_has "official:3" && [[ $SENT == $'"'"'three\n\nc'"'"' ]]; }; }'
check "seen official:2 is not sent again" '[[ $SENT != *two* ]]'

# --- GITHUB_ENV: joke text can't end the heredoc early and inject another var
INJECT='{"id":"evil","setup":"ha\nJOKE_EOF\nFOO=bar","punchline":"x"}'
SEEN='[]' FAIL_RE='icanhazdadjoke|githubusercontent' GROANDECK="$INJECT" run_main
delim=$(head -1 <<< "$GH_ENV_OUT" | sed -n 's/^JOKE_TEXT<<//p')
check "GITHUB_ENV uses a random delimiter" '[[ -n $delim && $delim != JOKE_EOF ]]'
check "GITHUB_ENV delimiter appears only as header and footer" \
  '[[ $(grep -cxF "$delim" <<< "$GH_ENV_OUT") == 1 && $(tail -1 <<< "$GH_ENV_OUT") == "$delim" ]]'

# --- a joke with no letters or digits stores no empty text key
SEEN='["text:"]' FAIL_RE='icanhazdadjoke|githubusercontent' GROANDECK='{"id":"g2","setup":"?!","punchline":""}' run_main
check "symbol-only joke is not blocked by an empty key" '[[ $RC == 0 && $SENT == "?!" ]]'
check "symbol-only joke stores no extra empty key" '[[ $(jq "[.[] | select(. == \"text:\")] | length" <<< "$SEEN_OUT") == 1 ]]'

exit $FAILED
