# sms2discord

Two-way SMS ↔ Discord bridge that runs **on the router itself**. Every SMS your router's SIM receives appears in a Discord channel within seconds, and `!sms +15555550100 hello` in that channel sends one back.

Built for OpenWrt routers with a cellular modem and `smstools3`, tested on a **GL.iNet GL-X2000 (Spitz Plus)** with firmware 4.7. Handy for OTP codes on a SIM that lives in a router.

- Pure Lua + curl (~30 KB), no server, no Docker, no e-mail relay
- Only **new** SMS are forwarded, never the existing inbox
- No duplicates, also after a reboot; retries while the internet is down
- Mentions disabled, markdown escaped, link previews off
- Secrets stay in `/etc/sms2discord/config` (`chmod 600`) and never appear in logs or on a command line. Logs never contain SMS text or phone numbers.
- Sending is limited to allow-listed Discord users, with a rate limit and ⏳ → ✅/❌ status reactions

```
modem ─▶ smsd ─▶ /etc/spool/sms/incoming/…   sms2discord polls every 2 s ─▶ Discord webhook ─▶ #sms
                                                                                                │ !sms +1555… text
modem ◀─ smsd ◀─ /etc/spool/sms/outgoing/…   sms2discord polls every 4 s ◀─ Discord bot (REST) ◀┘
```

The router never needs inbound access: it only makes outgoing HTTPS requests to Discord.

---

## Requirements

- OpenWrt (19.07 or newer) or GL.iNet firmware 4.x with a modem and **smstools3** receiving SMS
- Packages `lua`, `lua-cjson`, `curl` (pre-installed on GL.iNet 4.x; `opkg` installs them otherwise)
- A Discord server where you can create a webhook (and optionally a bot)

## Install

### Option A: opkg package (recommended)

Download the `.ipk` from [Releases](https://github.com/koraysels/sms2discord/releases) and install it on the router:

```bash
cd /tmp
wget https://github.com/koraysels/sms2discord/releases/download/v0.2.0/sms2discord_0.2.0-1_all.ipk
opkg update && opkg install ./sms2discord_0.2.0-1_all.ipk
```

On GL.iNet it then also shows up under **Applications → Plug-ins**, where you can uninstall it. One `.ipk` fits every architecture.

### Option B: copy over SSH from your computer

```bash
git clone https://github.com/koraysels/sms2discord.git && cd sms2discord
HOST=root@192.168.8.1 ./install.sh                     # add --keep-on-upgrade to survive firmware upgrades
```

### Option C: build into your own firmware

`package/sms2discord` is a regular OpenWrt feed package:

```bash
echo "src-git sms2discord https://github.com/koraysels/sms2discord.git" >> feeds.conf
./scripts/feeds update sms2discord && ./scripts/feeds install sms2discord
make package/sms2discord/compile
```

## Configure

### 1. Webhook (receiving)

In Discord: your private channel → **Edit Channel → Integrations → Webhooks → New Webhook → Copy Webhook URL**. Then on the router (input is hidden and stays on the router):

```bash
ssh -t root@192.168.8.1 sms2discord setup
ssh root@192.168.8.1 /etc/init.d/sms2discord restart
```

Leave the bot token empty (`-`) if you only want to receive. `setup` posts a test message to the channel. Send an SMS to the router to test it.

### 2. Bot (sending, optional)

Use a dedicated bot for this, not one that does other things.

1. [Developer Portal](https://discord.com/developers/applications) → **New Application**
2. **Bot** → turn on **Message Content Intent**, then **Reset Token** and keep the token at hand
3. **Installation** → Install Link: **None**, then **Bot** → turn off **Public Bot**
4. Invite it: `https://discord.com/oauth2/authorize?client_id=<APPLICATION_ID>&scope=bot&permissions=68672` (View Channels, Send Messages, Read Message History, Add Reactions)
5. Private channel → **Edit Channel → Permissions** → add the bot
6. Connect it from your computer (needs Node 22+):
   ```bash
   HOST=root@192.168.8.1 tools/setup-bot.sh
   ```
   The token is typed hidden. The script does Discord's one-time Gateway login (required before a bot may post over REST), sends the token to the router over SSH stdin, takes the channel ID from the webhook and allows the bot's owner as sender, checks everything and restarts the service. A failed check leaves the old config untouched.

## Use

```
!sms +15555550100 your message
```

| Reaction | Meaning |
|----------|---------|
| ⏳ | queued on the router |
| ✅ | sent by the modem |
| ❌ | sending failed |
| ⚠️ | no result after 15 minutes |
| 🚫 | you are not in `ALLOWED_USER_IDS` |

Numbers with country code (`+15555550100`) or national format, no spaces. Max 459 characters (3 SMS parts), max 10 SMS per hour by default.

Everyone who can read the channel can read your OTP codes. Keep it private.

## Manage (on the router)

| What | Command |
|------|---------|
| Status and recent log | `sms2discord status` |
| Send a test message | `sms2discord test` |
| Follow the log | `logread -f -e sms2discord` |
| Restart / stop / disable | `/etc/init.d/sms2discord restart` / `stop` / `disable` |
| Change settings | `sms2discord setup` |
| Built-in tests | `sms2discord selftest` |

`/etc/sms2discord/config`:

| Key | Default | Meaning |
|-----|---------|---------|
| `WEBHOOK_URL` | | Discord webhook for incoming SMS |
| `BOT_TOKEN` | empty | Bot token; empty disables `!sms` |
| `CHANNEL_ID` | webhook's channel | Channel the bot reads |
| `ALLOWED_USER_IDS` | bot owner | Discord user IDs allowed to send (space separated) |
| `POLL_SMS` | `2` | Seconds between inbox checks |
| `POLL_DISCORD` | `4` | Seconds between Discord checks |
| `OUT_MAX_PER_HOUR` | `10` | Outgoing SMS limit |

State: `/etc/sms2discord/seen` (forwarded files) and `last_id` (last Discord message handled).

## Uninstall

```bash
opkg remove sms2discord          # if installed as a package
./uninstall.sh                   # if installed with install.sh (add --purge to delete config and secrets)
```

The SMS inbox is never touched. Delete the webhook and bot in Discord afterwards. `/etc/sms2discord/` stays after `opkg remove`; delete it with `rm -rf /etc/sms2discord` to remove the secrets.

## How it works

- smstools3 writes each received SMS as a file. sms2discord reads the spool directories from the live smstools config (`/tmp/smstools.cfg` on GL.iNet, `/etc/smsd.conf` on stock OpenWrt) and polls them. It does not use smstools' `eventhandler`, because GL.iNet regenerates that config at every start and its own forward script would be overwritten on updates.
- GL.iNet's `modem_AT` also stores received SMS in `storage/<bus>`; that directory is watched too when it exists.
- `Alphabet: ISO` bodies are ISO-8859-15, `UCS2` bodies are raw UTF-16BE. Both are converted to UTF-8.
- On first start every existing file counts as seen. A file is forwarded once its size is stable across two polls, and only marked seen after Discord confirms it.
- Outgoing SMS use the same spool format as smstools' `sendsms`, written atomically. smstools moves them to `sent/` or `failed/`, which drives the status reactions.
- Discord is polled over REST, so there is no long-lived Gateway connection. Snowflake IDs are compared as strings because Lua 5.1 numbers can't hold them.

## Development

```
package/sms2discord/files/sms2discord.lua   daemon + setup/set-bot/status/test/selftest → /usr/bin/sms2discord
package/sms2discord/files/sms2discord.init  procd service (START=99, after smstools3)   → /etc/init.d/sms2discord
package/sms2discord/Makefile                OpenWrt feed package
tools/build-ipk.sh                          build dist/*.ipk without the SDK
tools/setup-bot.sh                          connect the bot (token stays local)
tools/gateway-identify.mjs                  one-time Gateway login
install.sh / uninstall.sh                   copy-based install over SSH
```

Run the tests on a router: `ssh root@192.168.8.1 'lua - selftest' < package/sms2discord/files/sms2discord.lua`

Releases: push a tag `v<version>` matching `PKG_VERSION` and GitHub Actions attaches the `.ipk`.

## License

MIT
