#!/usr/bin/env bash

# -------------------
# Fetches a joke from icanhazdadjoke.com and sends it into a Telegram Bot.
# Relies on TELEGRAM_TOKEN and TELEGRAM_CHAT being set
#

LE_JOKE="$(curl -H "Accept: text/plain" -H "User-Agent: dad-jokes-4000" https://icanhazdadjoke.com)"
./telegram "$LE_JOKE"

