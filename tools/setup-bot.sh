#!/usr/bin/env bash
# Connect the !sms bot in one go. The token is typed hidden, stays on this
# machine and the router, and never appears on a command line.
#
#   tools/setup-bot.sh
#   HOST=root@10.0.0.1 tools/setup-bot.sh
set -euo pipefail
cd "$(dirname "$0")/.."

HOST="${HOST:-root@192.168.8.1}"
# one password prompt per run: the first connection becomes a shared master
SSH=(ssh -o LogLevel=ERROR -o ControlMaster=auto -o ControlPersist=60
	-o "ControlPath=${SSH_CONTROL:-$HOME/.ssh/cm-%r@%h:%p}")

read -rsp "Bot token (hidden): " DISCORD_BOT_TOKEN
echo
export DISCORD_BOT_TOKEN
trap 'unset DISCORD_BOT_TOKEN' EXIT

echo "==> one-time gateway login"
node tools/gateway-identify.mjs

echo "==> saving on router"
printf '%s\n' "$DISCORD_BOT_TOKEN" | "${SSH[@]}" "$HOST" 'sms2discord set-bot && /etc/init.d/sms2discord restart'
sleep 3
"${SSH[@]}" "$HOST" 'logread -e sms2discord | tail -n 2'
echo
echo "Test in Discord: !sms +15555550100 test"
