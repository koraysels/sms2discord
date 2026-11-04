#!/usr/bin/lua
-- sms2discord: forward incoming SMS from the smstools3 spool to a Discord
-- webhook, and optionally send SMS from "!sms" commands in Discord.
-- Works on OpenWrt with smstools3, including GL.iNet firmware 4.x.
-- https://github.com/koraysels/sms2discord
--
-- Usage: sms2discord run|setup|set-bot|status|test|selftest
--
-- Never logs SMS text, phone numbers or secrets.

local cjson = require "cjson"

local VERSION = "0.2.0"
local CONF_DIR = "/etc/sms2discord"
local CONF_FILE = CONF_DIR .. "/config"
local SEEN_FILE = CONF_DIR .. "/seen"
local LASTID_FILE = CONF_DIR .. "/last_id"
local RUN_DIR = "/tmp/sms2discord"
local LOCK_DIR = RUN_DIR .. "/lock"
-- GL.iNet generates its live config in /tmp; stock OpenWrt uses /etc/smsd.conf
local SMSD_CFGS = { "/tmp/smstools.cfg", "/etc/smsd.conf" }
local API = "https://discord.com/api/v10"

local MAX_DISCORD_CHARS = 1990
local MAX_SMS_CHARS = 459 -- 3 concatenated GSM-7 parts (smsd autosplit = 3)
local TRACK_SECONDS = 900

-- ---------------------------------------------------------------- helpers

local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function log(level, msg)
  os.execute("logger -t sms2discord -p daemon." .. level .. " " .. shq(msg))
end

local function read_file(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

local function exists(p)
  local f = io.open(p, "rb")
  if f then f:close() return true end
  return false
end

local function write_file(p, data, mode)
  local f, err = io.open(p, "wb")
  if not f then return nil, err end
  f:write(data)
  f:close()
  if mode then os.execute("chmod " .. mode .. " " .. shq(p)) end
  return true
end

-- write to a temp file in the same directory, then rename (atomic on ubifs)
local function write_atomic(p, data, mode)
  local tmp = p .. ".tmp"
  local ok, err = write_file(tmp, data, mode)
  if not ok then return nil, err end
  return os.rename(tmp, p)
end

local function sleep(sec)
  os.execute("sleep " .. tonumber(sec))
end

local function list_dir(dir)
  local t = {}
  local h = io.popen("ls -1tr " .. shq(dir) .. " 2>/dev/null")
  if not h then return t end
  for n in h:lines() do
    if n ~= "" and not n:match("^%.") then t[#t + 1] = n end
  end
  h:close()
  return t
end

local function random_name(len)
  local alnum = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  local f = io.open("/dev/urandom", "rb")
  local raw = f and f:read(len) or tostring(os.time())
  if f then f:close() end
  local out = {}
  for i = 1, len do
    local b = raw:byte((i - 1) % #raw + 1)
    local k = b % #alnum + 1
    out[i] = alnum:sub(k, k)
  end
  return table.concat(out)
end

local function urlenc(s)
  return (s:gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

-- Discord snowflakes exceed double precision: compare as decimal strings
local function sf_gt(a, b)
  if #a ~= #b then return #a > #b end
  return a > b
end

-- ---------------------------------------------------------------- text

local function utf8_char(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
  else
    return string.char(0xF0 + math.floor(cp / 262144), 0x80 + math.floor(cp / 4096) % 64,
      0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
  end
end

-- smstools "ISO" alphabet is ISO-8859-15
local LATIN9 = {
  [0xA4] = 0x20AC, [0xA6] = 0x160, [0xA8] = 0x161, [0xB4] = 0x17D,
  [0xB8] = 0x17E, [0xBC] = 0x152, [0xBD] = 0x153, [0xBE] = 0x178,
}

local function latin9_to_utf8(s)
  return (s:gsub("[\128-\255]", function(c)
    local b = c:byte()
    return utf8_char(LATIN9[b] or b)
  end))
end

-- smstools "UCS2" alphabet: raw UTF-16BE bytes
local function utf16be_to_utf8(s)
  local out, i = {}, 1
  while i + 1 <= #s do
    local cp = s:byte(i) * 256 + s:byte(i + 1)
    i = i + 2
    if cp >= 0xD800 and cp <= 0xDBFF and i + 1 <= #s then
      local lo = s:byte(i) * 256 + s:byte(i + 1)
      if lo >= 0xDC00 and lo <= 0xDFFF then
        cp = 0x10000 + (cp - 0xD800) * 1024 + (lo - 0xDC00)
        i = i + 2
      end
    end
    if cp >= 0xD800 and cp <= 0xDFFF then cp = 0xFFFD end
    out[#out + 1] = utf8_char(cp)
  end
  return table.concat(out)
end

-- replace invalid UTF-8 and stray control chars so Discord accepts the JSON
local function utf8_clean(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local c = s:byte(i)
    local len
    if c < 0x80 then len = 1
    elseif c >= 0xC2 and c <= 0xDF then len = 2
    elseif c >= 0xE0 and c <= 0xEF then len = 3
    elseif c >= 0xF0 and c <= 0xF4 then len = 4
    else len = 0 end
    local ok = len > 0 and i + len - 1 <= n
    if ok then
      for j = i + 1, i + len - 1 do
        local b = s:byte(j)
        if b < 0x80 or b > 0xBF then ok = false break end
      end
    end
    if ok and len == 1 and c < 0x20 and c ~= 0x0A and c ~= 0x09 then
      out[#out + 1] = (c == 0x0D) and "" or " "
      i = i + 1
    elseif ok then
      out[#out + 1] = s:sub(i, i + len - 1)
      i = i + len
    else
      out[#out + 1] = "\239\191\189"
      i = i + 1
    end
  end
  return table.concat(out)
end

local function utf8_len(s)
  local _, n = s:gsub("[^\128-\191]", "")
  return n
end

local function utf8_trunc(s, max)
  local count = 0
  for i = 1, #s do
    local c = s:byte(i)
    if c < 0x80 or c >= 0xC0 then
      count = count + 1
      if count > max then return s:sub(1, i - 1), true end
    end
  end
  return s, false
end

local function md_escape(s)
  return (s:gsub("([\\%*_~`|>#%[%]%-])", "\\%1"))
end

-- ---------------------------------------------------------------- sms files

local function parse_sms(raw)
  local sep = raw:find("\n\n", 1, true)
  if not sep then return nil end
  local h = {}
  for line in raw:sub(1, sep):gmatch("[^\n]+") do
    local k, v = line:match("^([%w_]+):%s?(.-)%s*$")
    if k then h[k] = v end
  end
  return h, raw:sub(sep + 2)
end

local function decode_body(h, body)
  local alpha = (h.Alphabet or ""):upper()
  local text
  if alpha:find("UCS") then
    text = utf16be_to_utf8(body)
  elseif alpha:find("UTF") then
    text = body
  else
    text = latin9_to_utf8(body)
  end
  return (utf8_clean(text):gsub("%s+$", ""))
end

local function display_sender(h)
  local from = h.From or "?"
  if from:match("^%d+$") and (h.From_TOA or ""):match("^91") then from = "+" .. from end
  return from
end

local function format_inbound(h, text)
  local when = h.Received or h.Sent or ""
  local head = "\240\159\147\169 **" .. md_escape(utf8_clean(display_sender(h))) .. "**"
  if when ~= "" then head = head .. "  \194\183  " .. md_escape(when) end
  if text == "" then text = "(empty message)" else text = md_escape(text) end
  local msg, cut = utf8_trunc(head .. "\n" .. text, MAX_DISCORD_CHARS)
  if cut then msg = msg .. " \226\128\166" end
  return msg
end

-- ---------------------------------------------------------------- config

local function load_config()
  local c = { POLL_SMS = "2", POLL_DISCORD = "4", OUT_MAX_PER_HOUR = "10" }
  for line in (read_file(CONF_FILE) or ""):gmatch("[^\n]+") do
    local k, v = line:match("^%s*([%u_]+)%s*=%s*(.-)%s*$")
    if k then c[k] = v:match('^"(.*)"$') or v:match("^'(.*)'$") or v end
  end
  local errs = {}
  if not (c.WEBHOOK_URL or ""):match("^https://[%w%.]*discord%.com/api/webhooks/%d+/[%w_%-]+$")
    and not (c.WEBHOOK_URL or ""):match("^https://[%w%.]*discordapp%.com/api/webhooks/%d+/[%w_%-]+$") then
    errs[#errs + 1] = "WEBHOOK_URL missing or not a Discord webhook URL"
  end
  c.allowed = {}
  for id in (c.ALLOWED_USER_IDS or ""):gmatch("%d+") do c.allowed[id] = true end
  c.outbound = (c.BOT_TOKEN or "") ~= "" and (c.CHANNEL_ID or "") ~= "" and next(c.allowed) ~= nil
  if c.outbound then
    if not c.BOT_TOKEN:match("^[%w%._%-]+$") then errs[#errs + 1] = "BOT_TOKEN has unexpected characters" end
    if not c.CHANNEL_ID:match("^%d+$") then errs[#errs + 1] = "CHANNEL_ID must be numeric" end
  end
  c.poll_sms = math.max(1, tonumber(c.POLL_SMS) or 2)
  c.poll_discord = math.max(2, tonumber(c.POLL_DISCORD) or 4)
  c.out_max = tonumber(c.OUT_MAX_PER_HOUR) or 10
  return c, errs
end

local function smsd_paths()
  local d
  for _, f in ipairs(SMSD_CFGS) do
    d = read_file(f)
    if d then break end
  end
  if not d then return nil end
  local p = {}
  for line in d:gmatch("[^\n]+") do
    if line:match("^%s*%[") then break end -- device sections follow the globals
    local k, v = line:match("^%s*(%w+)%s*=%s*(/%S+)")
    if k then p[k] = v end
  end
  if not (p.incoming and p.outgoing) then return nil end
  -- GL.iNet's modem_AT also writes received SMS to storage/<bus>
  p.watch = { p.incoming }
  local root, bus = p.incoming:match("^(.*)/incoming/([^/]+)$")
  if root and os.execute("test -d " .. shq(root .. "/storage/" .. bus)) == 0 then
    p.storage = root .. "/storage/" .. bus
    p.watch[2] = p.storage
  end
  return p
end

-- ---------------------------------------------------------------- http

local function http(method, url, body, token)
  -- URL and token go into a curl config file so they never appear in argv
  local cfg = RUN_DIR .. "/curl.cfg"
  local resp = RUN_DIR .. "/resp"
  local req = RUN_DIR .. "/req.json"
  local lines = {
    "silent", "show-error", "max-time = 20", "connect-timeout = 10",
    'request = "' .. method .. '"',
    'url = "' .. url .. '"',
    'header = "User-Agent: sms2discord/' .. VERSION .. '"',
    'output = "' .. resp .. '"',
    'write-out = "%{http_code}"',
  }
  if token then lines[#lines + 1] = 'header = "Authorization: Bot ' .. token .. '"' end
  if body then
    write_file(req, body, "600")
    lines[#lines + 1] = 'header = "Content-Type: application/json"'
    lines[#lines + 1] = 'data-binary = "@' .. req .. '"'
  end
  write_file(cfg, table.concat(lines, "\n") .. "\n", "600")
  local h = io.popen("curl -K " .. shq(cfg) .. " 2>/dev/null")
  local code = tonumber(h and h:read("*a") or "") or 0
  if h then h:close() end
  local out = read_file(resp) or ""
  -- don't leave SMS text or secrets lying around in /tmp
  os.remove(resp)
  os.remove(req)
  os.remove(cfg)
  return code, out
end

local function retry_after(resp)
  local ok, j = pcall(cjson.decode, resp)
  local s = ok and type(j) == "table" and tonumber(j.retry_after) or 5
  return math.ceil(s) + 1
end

local NO_MENTIONS = '"allowed_mentions":{"parse":[]}'

local function post_webhook(c, content)
  -- flags 4 = SUPPRESS_EMBEDS (no link previews for SMS links)
  local body = '{"content":' .. cjson.encode(content) .. "," .. NO_MENTIONS .. ',"flags":4}'
  return http("POST", c.WEBHOOK_URL .. "?wait=true", body)
end

local function bot_reply(c, mid, text)
  local body = '{"content":' .. cjson.encode(text) .. "," .. NO_MENTIONS
    .. ',"message_reference":{"message_id":"' .. mid .. '","fail_if_not_exists":false}}'
  return http("POST", API .. "/channels/" .. c.CHANNEL_ID .. "/messages", body, c.BOT_TOKEN)
end

local function bot_react(c, mid, emoji, remove)
  local url = API .. "/channels/" .. c.CHANNEL_ID .. "/messages/" .. mid .. "/reactions/" .. urlenc(emoji) .. "/@me"
  if remove then return http("DELETE", url, nil, c.BOT_TOKEN) end
  return http("PUT", url, "", c.BOT_TOKEN)
end

-- ---------------------------------------------------------------- inbound

local E_WAIT, E_OK, E_FAIL, E_WARN, E_BLOCK =
  "\226\143\179", "\226\156\133", "\226\157\140", "\226\154\160\239\184\143", "\240\159\154\171"

local Inbound = { seen = {}, missing = {}, settle = {}, next_try = 0, backoff = 0, warned = false }

function Inbound.save()
  local t = {}
  for n in pairs(Inbound.seen) do t[#t + 1] = n end
  table.sort(t)
  write_atomic(SEEN_FILE, table.concat(t, "\n") .. "\n", "600")
end

function Inbound.scan(paths)
  local list, present = {}, {}
  for _, dir in ipairs(paths.watch) do
    for _, n in ipairs(list_dir(dir)) do
      if not present[n] then
        present[n] = true
        list[#list + 1] = { name = n, path = dir .. "/" .. n }
      end
    end
  end
  return list, present
end

function Inbound.init(paths)
  local d = read_file(SEEN_FILE)
  if d then
    for n in d:gmatch("[^\n]+") do Inbound.seen[n] = true end
    return
  end
  -- first start: everything already in the inbox counts as seen
  local list = Inbound.scan(paths)
  for _, e in ipairs(list) do Inbound.seen[e.name] = true end
  Inbound.save()
  log("info", "first start: marked " .. #list .. " existing SMS as already seen")
end

function Inbound.tick(c, paths, now)
  local list, present = Inbound.scan(paths)
  -- forget files deleted from the inbox so the seen list stays small; wait a
  -- few scans so a file moving between incoming/ and storage/ isn't re-sent
  local pruned = false
  for n in pairs(Inbound.seen) do
    if present[n] then
      Inbound.missing[n] = nil
    else
      Inbound.missing[n] = (Inbound.missing[n] or 0) + 1
      if Inbound.missing[n] >= 5 then
        Inbound.seen[n], Inbound.missing[n] = nil, nil
        pruned = true
      end
    end
  end
  if pruned then Inbound.save() end
  if now < Inbound.next_try then return end

  for _, e in ipairs(list) do
    if not Inbound.seen[e.name] then
      local raw = read_file(e.path)
      if not raw then return end
      -- wait until the file size is stable across two polls
      if Inbound.settle[e.name] ~= #raw then
        Inbound.settle[e.name] = #raw
        return
      end
      local h, body = parse_sms(raw)
      local content
      if h then
        content = format_inbound(h, decode_body(h, body))
      else
        content = E_WARN .. " New SMS in an unexpected format. Check the router inbox."
      end
      local code, resp = post_webhook(c, content)
      if code >= 200 and code < 300 then
        Inbound.seen[e.name] = true
        Inbound.settle[e.name] = nil
        Inbound.save()
        Inbound.backoff, Inbound.warned = 0, false
        log("info", "forwarded sms " .. e.name)
      elseif code == 429 then
        Inbound.next_try = now + retry_after(resp)
        return
      elseif code == 400 or code == 413 then
        -- Discord rejects this message's content: notify without content, don't loop
        post_webhook(c, E_WARN .. " New SMS could not be forwarded (Discord HTTP " .. code .. "). Check the router inbox.")
        Inbound.seen[e.name] = true
        Inbound.save()
        log("err", "discord rejected sms " .. e.name .. " (HTTP " .. code .. "), marked seen")
      else
        -- network down, Discord down, or webhook invalid: keep it pending and retry
        local cap = (code >= 400 and code < 500) and 300 or 60
        Inbound.backoff = math.min(math.max(Inbound.backoff * 2, c.poll_sms * 2), cap)
        Inbound.next_try = now + Inbound.backoff
        if not Inbound.warned then
          log("warning", "forward failed (HTTP " .. code .. "), retrying every <=" .. cap .. "s")
          Inbound.warned = true
        end
        return
      end
    end
  end
end

-- ---------------------------------------------------------------- outbound

local Outbound = { last_id = nil, next_try = 0, sent_times = {}, tracking = {}, warned = false }

local function queue_sms(paths, num, text)
  local toa = num:sub(1, 1) == "+" and "international" or "National"
  -- same layout as smstools3's sendsms script (UTF-8, no iconv needed)
  local data = "To: " .. num .. "\nAlphabet: UTF-8\nTo_TOA: " .. toa .. "\n\n" .. text
  local parent = paths.outgoing:match("^(.*)/[^/]+$")
  local name = "send_" .. random_name(6)
  local tmp = parent .. "/.sms2discord_" .. name -- same filesystem: rename is atomic
  local ok, err = write_file(tmp, data, "0660")
  if not ok then return nil, err end
  ok, err = os.rename(tmp, paths.outgoing .. "/" .. name)
  if not ok then os.remove(tmp) return nil, err end
  return name
end

function Outbound.save()
  write_atomic(LASTID_FILE, Outbound.last_id .. "\n", "600")
end

function Outbound.handle(c, paths, m, now)
  if m.webhook_id or (m.author and m.author.bot) then return end
  local content = (m.content or ""):gsub("\r", "")
  if not content:match("^!sms") then return end
  local mid = tostring(m.id)
  local uid = m.author and tostring(m.author.id) or ""
  if not c.allowed[uid] then
    bot_react(c, mid, E_BLOCK)
    log("warning", "ignored !sms from a user not in ALLOWED_USER_IDS")
    return
  end
  local num, text = content:match("^!sms%s+(%+?%d+)%s+(.+)$")
  if not num or #num < 3 or #num > 16 then
    bot_reply(c, mid, "Usage: `!sms +15555550100 your message`")
    return
  end
  text = text:gsub("%s+$", "")
  if utf8_len(text) > MAX_SMS_CHARS then
    bot_reply(c, mid, E_FAIL .. " Too long (" .. utf8_len(text) .. " chars, max " .. MAX_SMS_CHARS .. ").")
    return
  end
  local recent = {}
  for _, t in ipairs(Outbound.sent_times) do
    if now - t < 3600 then recent[#recent + 1] = t end
  end
  Outbound.sent_times = recent
  if #recent >= c.out_max then
    bot_reply(c, mid, E_FAIL .. " Rate limit: max " .. c.out_max .. " SMS per hour.")
    log("warning", "outgoing sms rate limit reached")
    return
  end
  local name, err = queue_sms(paths, num, text)
  if not name then
    bot_reply(c, mid, E_FAIL .. " Could not queue SMS on the router.")
    log("err", "queue failed: " .. tostring(err))
    return
  end
  recent[#recent + 1] = now
  bot_react(c, mid, E_WAIT)
  Outbound.tracking[#Outbound.tracking + 1] = { name = name, mid = mid, deadline = now + TRACK_SECONDS }
  log("info", "queued outgoing sms " .. name)
end

function Outbound.track(c, paths, now)
  local keep = {}
  for _, t in ipairs(Outbound.tracking) do
    local result
    if paths.sent and exists(paths.sent .. "/" .. t.name) then result = E_OK
    elseif paths.failed and exists(paths.failed .. "/" .. t.name) then result = E_FAIL
    elseif now > t.deadline then result = E_WARN end
    if result then
      bot_react(c, t.mid, E_WAIT, true)
      bot_react(c, t.mid, result)
      log("info", "outgoing sms " .. t.name .. (result == E_OK and " sent" or result == E_FAIL and " failed" or " status unknown"))
    else
      keep[#keep + 1] = t
    end
  end
  Outbound.tracking = keep
end

function Outbound.tick(c, paths, now)
  if #Outbound.tracking > 0 then Outbound.track(c, paths, now) end
  if now < Outbound.next_try then return end
  local base = API .. "/channels/" .. c.CHANNEL_ID .. "/messages"

  if not Outbound.last_id then
    local d = read_file(LASTID_FILE)
    Outbound.last_id = d and d:match("%d+")
    if not Outbound.last_id then
      -- first start: only react to messages posted from now on
      local code, resp = http("GET", base .. "?limit=1", nil, c.BOT_TOKEN)
      if code ~= 200 then
        Outbound.next_try = now + (code == 429 and retry_after(resp) or 30)
        log("warning", "bot cannot read channel (HTTP " .. code .. ")")
        return
      end
      local ok, list = pcall(cjson.decode, resp)
      Outbound.last_id = ok and type(list) == "table" and list[1] and tostring(list[1].id) or "0"
      Outbound.save()
    end
  end

  local code, resp = http("GET", base .. "?limit=50&after=" .. Outbound.last_id, nil, c.BOT_TOKEN)
  if code == 429 then
    Outbound.next_try = now + retry_after(resp)
    return
  elseif code ~= 200 then
    Outbound.next_try = now + ((code >= 400 and code < 500) and 300 or 30)
    if not Outbound.warned then
      log("warning", "reading Discord channel failed (HTTP " .. code .. ")")
      Outbound.warned = true
    end
    return
  end
  Outbound.warned = false
  local ok, list = pcall(cjson.decode, resp)
  if not ok or type(list) ~= "table" or #list == 0 then return end
  table.sort(list, function(a, b) return sf_gt(tostring(b.id), tostring(a.id)) end)
  for _, m in ipairs(list) do
    local id = tostring(m.id)
    if sf_gt(id, Outbound.last_id) then
      -- advance first so a crash can't make us send the same SMS twice
      Outbound.last_id = id
      Outbound.save()
      Outbound.handle(c, paths, m, now)
    end
  end
end

-- ---------------------------------------------------------------- commands

local function my_pid()
  local h = io.popen("echo $PPID") -- PPID of the popen shell is this process
  local pid = h and h:read("*l")
  if h then h:close() end
  return pid
end

local function acquire_lock()
  os.execute("mkdir -p " .. shq(RUN_DIR) .. " && chmod 700 " .. shq(RUN_DIR))
  for _ = 1, 2 do
    if os.execute("mkdir " .. shq(LOCK_DIR) .. " 2>/dev/null") == 0 then
      write_file(LOCK_DIR .. "/pid", (my_pid() or "") .. "\n")
      return true
    end
    local pid = (read_file(LOCK_DIR .. "/pid") or ""):match("%d+")
    if pid and exists("/proc/" .. pid .. "/cmdline") then return false end
    os.execute("rm -rf " .. shq(LOCK_DIR)) -- stale lock left by a crash
  end
  return false
end

local function cmd_run()
  if not acquire_lock() then
    io.stderr:write("sms2discord: already running\n")
    os.exit(1)
  end
  local c, errs = load_config()
  if #errs > 0 then
    for _, e in ipairs(errs) do log("err", "config: " .. e) end
    os.exit(1)
  end
  local paths
  while true do
    paths = smsd_paths()
    if paths then break end
    sleep(10) -- smstools3 writes its config at start-up
  end
  Inbound.init(paths)
  log("info", "started v" .. VERSION .. (c.outbound and " (inbound + outbound)" or " (inbound only)"))

  local next_sms, next_discord = 0, 0
  while true do
    local now = os.time()
    if now >= next_sms then
      Inbound.tick(c, paths, now)
      next_sms = now + c.poll_sms
    end
    if c.outbound and now >= next_discord then
      Outbound.tick(c, paths, now)
      next_discord = now + c.poll_discord
    end
    sleep(1)
  end
end

local CONF_KEYS = { "WEBHOOK_URL", "BOT_TOKEN", "CHANNEL_ID", "ALLOWED_USER_IDS", "POLL_SMS", "POLL_DISCORD", "OUT_MAX_PER_HOUR" }

local function save_config(c)
  os.execute("mkdir -p " .. shq(CONF_DIR) .. " && chmod 700 " .. shq(CONF_DIR))
  local lines = {}
  for _, k in ipairs(CONF_KEYS) do lines[#lines + 1] = k .. "=" .. (c[k] or "") end
  return write_atomic(CONF_FILE, table.concat(lines, "\n") .. "\n", "600")
end

-- fill CHANNEL_ID from the webhook and ALLOWED_USER_IDS from the bot's owner
local function autodetect_ids(c)
  if (c.CHANNEL_ID or "") == "" and (c.WEBHOOK_URL or "") ~= "" then
    local code, resp = http("GET", c.WEBHOOK_URL)
    local ok, j = pcall(cjson.decode, resp)
    if code == 200 and ok and type(j) == "table" and j.channel_id then
      c.CHANNEL_ID = tostring(j.channel_id)
      print("Channel ID from webhook: " .. c.CHANNEL_ID)
    end
  end
  if (c.ALLOWED_USER_IDS or "") == "" and (c.BOT_TOKEN or "") ~= "" then
    local code, resp = http("GET", API .. "/oauth2/applications/@me", nil, c.BOT_TOKEN)
    local ok, j = pcall(cjson.decode, resp)
    if code == 200 and ok and type(j) == "table" then
      local owner = (type(j.team) == "table" and j.team.owner_user_id) or (type(j.owner) == "table" and j.owner.id)
      if owner then
        c.ALLOWED_USER_IDS = tostring(owner)
        print("Allowed user = bot owner: " .. c.ALLOWED_USER_IDS)
      end
    else
      print("Could not read bot application (HTTP " .. code .. "): token wrong?")
    end
  end
end

local function check_bot(c)
  if not c.outbound then
    print("Outbound (!sms) disabled: needs BOT_TOKEN, CHANNEL_ID and ALLOWED_USER_IDS.")
    return false
  end
  local bc = http("GET", API .. "/channels/" .. c.CHANNEL_ID .. "/messages?limit=1", nil, c.BOT_TOKEN)
  print("Bot channel read: HTTP " .. bc .. (bc == 200 and " OK" or
    " FAILED (403: bot not in channel or missing View Channel/Read Message History; 401: token wrong)"))
  return bc == 200
end

-- read a bot token on stdin (never argv), fill in the IDs, save
local function cmd_set_bot()
  os.execute("mkdir -p " .. shq(RUN_DIR) .. " && chmod 700 " .. shq(RUN_DIR))
  local token = (io.read("*l") or ""):gsub("%s", "")
  if not token:match("^[%w%._%-]+$") then print("ERROR: no valid token on stdin") os.exit(1) end
  local before = read_file(CONF_FILE)
  local c = load_config()
  c.BOT_TOKEN = token
  autodetect_ids(c)
  save_config(c)
  local ok = check_bot((load_config()))
  if ok then
    print("Saved. Restart with: /etc/init.d/sms2discord restart")
  elseif before then
    write_atomic(CONF_FILE, before, "600") -- keep the old, working config
    print("Not saved; previous config kept.")
  end
  os.exit(ok and 0 or 1)
end

local function prompt(label, secret)
  io.write(label)
  io.flush()
  local h = io.popen(secret and "sh -c 'read -s v; printf %s \"$v\"'" or "sh -c 'read v; printf %s \"$v\"'")
  local v = h:read("*a") or ""
  h:close()
  if secret then io.write("\n") end
  return (v:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function cmd_setup()
  os.execute("mkdir -p " .. shq(CONF_DIR) .. " && chmod 700 " .. shq(CONF_DIR))
  os.execute("mkdir -p " .. shq(RUN_DIR) .. " && chmod 700 " .. shq(RUN_DIR))
  local old = load_config()
  print("sms2discord setup. Input marked (hidden) is not echoed. Leave empty to keep the current value.")
  local webhook = prompt("Discord webhook URL (hidden): ", true)
  local token = prompt("Bot token for !sms sending, or '-' to disable (hidden): ", true)
  local channel = prompt("Channel ID the bot reads, empty = webhook's channel" .. (old.CHANNEL_ID and (" [" .. old.CHANNEL_ID .. "]") or "") .. ": ")
  local users = prompt("Allowed Discord user IDs, space separated, empty = bot owner" ..
    (old.ALLOWED_USER_IDS and (" [" .. old.ALLOWED_USER_IDS .. "]") or "") .. ": ")
  if webhook == "" then webhook = old.WEBHOOK_URL or "" end
  if token == "" then token = old.BOT_TOKEN or "" elseif token == "-" then token = "" end
  if channel == "" then channel = old.CHANNEL_ID or "" end
  if users == "" then users = old.ALLOWED_USER_IDS or "" end
  old.WEBHOOK_URL, old.BOT_TOKEN, old.CHANNEL_ID, old.ALLOWED_USER_IDS = webhook, token, channel, users
  autodetect_ids(old)
  save_config(old)
  local c, errs = load_config()
  for _, e in ipairs(errs) do print("ERROR: " .. e) end
  if #errs > 0 then os.exit(1) end
  local code = post_webhook(c, E_OK .. " sms2discord connected. New SMS will appear here.")
  print("Webhook test: HTTP " .. code .. (code >= 200 and code < 300 and " OK" or " FAILED"))
  check_bot(c)
  print("Saved " .. CONF_FILE .. ". Restart with: /etc/init.d/sms2discord restart")
end

local function cmd_status()
  local c, errs = load_config()
  local pid = (read_file(LOCK_DIR .. "/pid") or ""):match("%d+")
  local running = pid ~= nil and exists("/proc/" .. pid .. "/cmdline")
  print("version:   " .. VERSION)
  print("service:   " .. (running and "running" or "not running"))
  print("config:    " .. (exists(CONF_FILE) and "present" or "missing") .. (#errs > 0 and (" (" .. table.concat(errs, "; ") .. ")") or ""))
  print("webhook:   " .. ((c.WEBHOOK_URL or "") ~= "" and "set (hidden)" or "not set"))
  print("outbound:  " .. (c.outbound and ("enabled, channel " .. c.CHANNEL_ID) or "disabled"))
  local n = 0
  for _ in (read_file(SEEN_FILE) or ""):gmatch("[^\n]+") do n = n + 1 end
  print("seen sms:  " .. n .. (exists(SEEN_FILE) and "" or " (not initialised yet)"))
  local p = smsd_paths()
  print("watching:  " .. (p and table.concat(p.watch, ", ") or "smstools config not found"))
  print("recent log:")
  io.stdout:flush()
  os.execute("logread -e sms2discord 2>/dev/null | tail -n 10")
end

local function cmd_test()
  local c, errs = load_config()
  if #errs > 0 then print("ERROR: " .. table.concat(errs, "; ")) os.exit(1) end
  os.execute("mkdir -p " .. shq(RUN_DIR) .. " && chmod 700 " .. shq(RUN_DIR))
  local code = post_webhook(c, "\240\159\167\170 sms2discord test message (" .. os.date("%Y-%m-%d %H:%M:%S") .. ")")
  print("Webhook: HTTP " .. code)
  os.exit((code >= 200 and code < 300) and 0 or 1)
end

local function cmd_selftest()
  local fails = 0
  local function eq(name, got, want)
    if got ~= want then
      fails = fails + 1
      print("FAIL " .. name .. ": got " .. string.format("%q", tostring(got)) .. " want " .. string.format("%q", tostring(want)))
    end
  end
  eq("latin9 euro", latin9_to_utf8("\164 5"), "\226\130\172 5")
  eq("latin9 e-acute", latin9_to_utf8("caf\233"), "caf\195\169")
  eq("utf16 ascii", utf16be_to_utf8("\0A\0B"), "AB")
  eq("utf16 e-acute", utf16be_to_utf8("\0\233"), "\195\169")
  eq("utf16 emoji", utf16be_to_utf8("\216\61\222\0"), "\240\159\152\128")
  eq("utf16 lone surrogate", utf16be_to_utf8("\216\61"), "\239\191\189")
  eq("clean invalid", utf8_clean("a\255b"), "a\239\191\189b")
  eq("clean control", utf8_clean("a\rb\0c\n"), "ab c\n")
  eq("utf8 len", utf8_len("caf\195\169\240\159\152\128"), 5)
  eq("trunc", (utf8_trunc("\195\169\195\169\195\169", 2)), "\195\169\195\169")
  eq("md escape", md_escape("*a_b* `c` @everyone"), "\\*a\\_b\\* \\`c\\` @everyone")
  eq("sf_gt longer", sf_gt("1000000000000000000", "999999999999999999"), true)
  eq("sf_gt same len", sf_gt("1300000000000000001", "1300000000000000000"), true)
  eq("sf_gt equal", sf_gt("5", "5"), false)
  eq("urlenc", urlenc("\226\143\179"), "%E2%8F%B3")
  local h, b = parse_sms("From: 32470\nFrom_TOA: 91 international\nAlphabet: ISO\n\nCode 1234\n")
  eq("parse from", h and h.From, "32470")
  eq("parse body", b, "Code 1234\n")
  eq("decode iso", decode_body(h, b), "Code 1234")
  eq("sender intl", display_sender(h), "+32470")
  eq("sender alpha", display_sender({ From = "itsme", From_TOA = "D0 alphanumeric" }), "itsme")
  local hu, bu = parse_sms("From: x\nAlphabet: UCS2\n\n\0H\0i")
  eq("decode ucs2", decode_body(hu, bu), "Hi")
  eq("no header sep", parse_sms("garbage"), nil)
  local json = '{"content":' .. cjson.encode('a "q" \\ \n </x>') .. "," .. NO_MENTIONS .. "}"
  local ok, back = pcall(cjson.decode, json)
  eq("json roundtrip", ok and back.content, 'a "q" \\ \n </x>')
  eq("json parse array", ok and type(back.allowed_mentions.parse), "table")
  print(fails == 0 and "selftest OK" or ("selftest: " .. fails .. " failure(s)"))
  os.exit(fails == 0 and 0 or 1)
end

local cmd = arg[1]
if cmd == "run" then cmd_run()
elseif cmd == "setup" then cmd_setup()
elseif cmd == "set-bot" then cmd_set_bot()
elseif cmd == "status" then cmd_status()
elseif cmd == "test" then cmd_test()
elseif cmd == "selftest" then cmd_selftest()
else
  print("Usage: sms2discord run|setup|set-bot|status|test|selftest")
  os.exit(cmd and 1 or 0)
end
