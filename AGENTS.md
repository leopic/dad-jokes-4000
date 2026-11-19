# AGENTS.md

Telegram bot that sends a dad joke a few times a day. It runs entirely on GitHub Actions.

## Layout

- `main.sh`: fetches a joke from icanhazdadjoke, GroanDeck or the archived official-joke-api data file on GitHub, skips repeats, and sends it with `telegram` ([fabianonline/telegram.sh](https://github.com/fabianonline/telegram.sh), checked out in CI).
- `poll.sh`: reads `/joke` requests from Telegram and runs `main.sh`.
- `seen.json`: every sent joke as `<source>:<id>` plus `text:<key>` (lowercase a-z0-9 only). A joke is a repeat if either one is already there.
- `offset.json`: last Telegram update handled by `poll.sh`.
- `tests/main_test.sh`: fake `curl` and `telegram`, no network.

## Gotchas

- Any push to `main` runs `main.yml` and sends a real joke.
- The bot commits `seen.json` and `offset.json` to `main` several times a day. Rebase before merging. On a conflict, take main's file and re-add your entries.
- `official:<n>` is the 1-based position in the archived data file. Don't reorder or filter the file before indexing it.
- A run that finds no new joke exits 1 on purpose. Never resend a joke.
- GitHub skips many scheduled runs. Scheduled `main.yml` runs fell from 25 to ~10 a week after a 5-minute poll cron was added, so that cron is paused (see `poll.yml`). Avoid frequent crons.
- GitHub's terms limit Actions to build, test and deploy work. Don't turn this into an always-on job.

## Before pushing

- Run `tests/main_test.sh`. CI runs it in `test.yml`.
