#!/usr/bin/lua
-- sms2discord: forward incoming SMS from the smstools3 spool to a Discord
-- webhook, and optionally send SMS from "!sms" commands in Discord and
-- answer "!otp NAME" (or "!auth") with an authenticator (TOTP) code; "!otp"
-- alone posts a menu where a reaction picks the account. With the optional
-- relay (Cloudflare Worker), /otp shows real buttons and private replies.
-- Works on OpenWrt with smstools3, including GL.iNet firmware 4.x.
-- https://github.com/koraysels/sms2discord
--
-- Usage: sms2discord run|setup|set-bot|detect|migrate|status [--json]|test|otp NAME|selftest
--
-- Config: UCI /etc/config/sms2discord (older versions: /etc/sms2discord/config).
--
-- Never logs SMS text, phone numbers, OTP codes or secrets.

local cjson = require "cjson"

local VERSION = "0.6.2"
local CONF_DIR = "/etc/sms2discord"
local CONF_FILE = "/etc/config/sms2discord"
local LEGACY_CONF = CONF_DIR .. "/config"
local UCI_PKG = "sms2discord"
local SEEN_FILE = CONF_DIR .. "/seen"
local LASTID_FILE = CONF_DIR .. "/last_id"
local RUN_DIR = "/tmp/sms2discord"
local LOCK_DIR = RUN_DIR .. "/lock"
local OTP_PENDING = RUN_DIR .. "/otp_pending" -- code replies still to delete
local RELAY_STATE = RUN_DIR .. "/relay_state"
-- GL.iNet generates its live config in /tmp; stock OpenWrt uses /etc/smsd.conf
local SMSD_CFGS = { "/tmp/smstools.cfg", "/etc/smsd.conf" }
local API = "https://discord.com/api/v10"

local MAX_DISCORD_CHARS = 1990
local MAX_SMS_CHARS = 459 -- 3 concatenated GSM-7 parts (smsd autosplit = 3)
local TRACK_SECONDS = 900
local OTP_GRACE = 15 -- keep a code visible this long after it expires
local MENU_SECONDS = 60 -- an !otp menu stays open this long
local CLOCK_MIN = 1700000000 -- before this the router clock is not synced

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

-- ---------------------------------------------------------------- totp

-- Pure Lua 5.1 (no bit library on stock OpenWrt): 32-bit unsigned ops by
-- arithmetic. Only used for a few HMAC blocks per !otp, so speed is fine.
local TWO32 = 4294967296

local function bitop(a, b, keep)
  local r, p = 0, 1
  while a > 0 or b > 0 do
    local x, y = a % 2, b % 2
    if keep(x + y) then r = r + p end
    a, b, p = (a - x) / 2, (b - y) / 2, p * 2
  end
  return r
end

local function band(a, b) return bitop(a, b, function(n) return n == 2 end) end
local function bor(a, b) return bitop(a, b, function(n) return n > 0 end) end
local function bxor(a, b) return bitop(a, b, function(n) return n == 1 end) end
local function bnot(a) return TWO32 - 1 - a end
local function rol(a, n) return (a * 2 ^ n) % TWO32 + math.floor(a / 2 ^ (32 - n)) end

local function be_bytes(n, len)
  local t = {}
  for i = len - 1, 0, -1 do t[#t + 1] = string.char(math.floor(n / 2 ^ (8 * i)) % 256) end
  return table.concat(t)
end

local function sha1(msg)
  local h = { 1732584193, 4023233417, 2562383102, 271733878, 3285377520 }
  local ml = #msg * 8
  msg = msg .. "\128" .. string.rep("\0", (55 - #msg) % 64) .. be_bytes(ml, 8)
  for blk = 1, #msg, 64 do
    local w = {}
    for i = 0, 15 do
      local a, b, c, d = msg:byte(blk + i * 4, blk + i * 4 + 3)
      w[i] = ((a * 256 + b) * 256 + c) * 256 + d
    end
    for i = 16, 79 do w[i] = rol(bxor(bxor(w[i - 3], w[i - 8]), bxor(w[i - 14], w[i - 16])), 1) end
    local a, b, c, d, e = h[1], h[2], h[3], h[4], h[5]
    for i = 0, 79 do
      local f, k
      if i < 20 then f, k = bor(band(b, c), band(bnot(b), d)), 1518500249
      elseif i < 40 then f, k = bxor(bxor(b, c), d), 1859775393
      elseif i < 60 then f, k = bor(bor(band(b, c), band(b, d)), band(c, d)), 2400959708
      else f, k = bxor(bxor(b, c), d), 3395469782 end
      a, b, c, d, e = (rol(a, 5) + f + e + k + w[i]) % TWO32, a, rol(b, 30), c, d
    end
    for i, v in ipairs({ a, b, c, d, e }) do h[i] = (h[i] + v) % TWO32 end
  end
  local out = {}
  for i = 1, 5 do out[i] = be_bytes(h[i], 4) end
  return table.concat(out)
end

local function hmac_sha1(key, msg)
  if #key > 64 then key = sha1(key) end
  key = key .. string.rep("\0", 64 - #key)
  local ipad, opad = {}, {}
  for i = 1, 64 do
    local k = key:byte(i)
    ipad[i] = string.char(bxor(k, 54))
    opad[i] = string.char(bxor(k, 92))
  end
  return sha1(table.concat(opad) .. sha1(table.concat(ipad) .. msg))
end

-- RFC 6238 with SHA1 (what nearly every service uses)
local function totp(key, t, digits, period)
  local h = hmac_sha1(key, be_bytes(math.floor(t / period), 8))
  local off = h:byte(20) % 16
  local a, b, c, d = h:byte(off + 1, off + 4)
  local bin = (((a % 128) * 256 + b) * 256 + c) * 256 + d
  return string.format("%0" .. digits .. "d", bin % 10 ^ digits)
end

local B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"

local function base32_decode(s)
  s = s:upper():gsub("[%s%-]", ""):gsub("=+$", "")
  if s == "" or s:find("[^A-Z2-7]") then return nil end
  local bits, nbits, out = 0, 0, {}
  for i = 1, #s do
    bits = bits * 32 + B32:find(s:sub(i, i), 1, true) - 1
    nbits = nbits + 5
    if nbits >= 8 then
      nbits = nbits - 8
      out[#out + 1] = string.char(math.floor(bits / 2 ^ nbits))
      bits = bits % 2 ^ nbits
    end
  end
  return table.concat(out)
end

local function urldec(s)
  return (s:gsub("+", " "):gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- accepts a bare base32 secret or an otpauth://totp/... link from a QR code
local function parse_otp_secret(s)
  s = (s or ""):match("^%s*(.-)%s*$")
  local e = { digits = 6, period = 30 }
  local secret = s
  if s:lower():match("^otpauth://") then
    if (s:match("^%a+://(%a+)/") or ""):lower() ~= "totp" then return nil, "only otpauth://totp links are supported" end
    local q = {}
    for k, v in (s:match("%?(.*)$") or ""):gmatch("([^&=]+)=([^&]*)") do q[k:lower()] = urldec(v) end
    if q.algorithm and q.algorithm:upper() ~= "SHA1" then return nil, "only SHA1 is supported, not " .. q.algorithm end
    e.digits = tonumber(q.digits or 6)
    e.period = tonumber(q.period or 30)
    secret = q.secret or ""
  end
  if not (e.digits and e.digits >= 6 and e.digits <= 8 and e.digits % 1 == 0) then return nil, "digits must be 6, 7 or 8" end
  if not (e.period and e.period >= 10 and e.period <= 300 and e.period % 1 == 0) then return nil, "period must be 10-300 s" end
  e.key = base32_decode(secret)
  if not e.key or #e.key < 5 then return nil, "secret is not valid base32" end
  return e
end

-- ---------------------------------------------------------------- config

-- internal key -> UCI option in sms2discord.main
local UCI_MAP = {
  WEBHOOK_URL = "webhook_url", BOT_TOKEN = "bot_token", CHANNEL_ID = "channel_id",
  ALLOWED_USER_IDS = "allowed_user", POLL_SMS = "poll_sms", POLL_DISCORD = "poll_discord",
  OUT_MAX_PER_HOUR = "out_max_per_hour", RELAY_URL = "relay_url", RELAY_KEY = "relay_key",
}

local function uci_cursor()
  local ok, uci = pcall(require, "uci")
  return ok and uci.cursor() or nil
end

local function read_legacy()
  local raw = {}
  for line in (read_file(LEGACY_CONF) or ""):gmatch("[^\n]+") do
    local k, v = line:match("^%s*([%u_]+)%s*=%s*(.-)%s*$")
    if k then raw[k] = v:match('^"(.*)"$') or v:match("^'(.*)'$") or v end
  end
  return raw
end

local function read_raw_config()
  local cur = uci_cursor()
  local sec = cur and cur:get_all(UCI_PKG, "main")
  if not sec then return read_legacy() end
  local raw = { ENABLED = sec.enabled }
  for k, opt in pairs(UCI_MAP) do
    local v = sec[opt]
    if type(v) == "table" then v = table.concat(v, " ") end
    raw[k] = v
  end
  return raw
end

-- "config otp" sections: name + secret. A bad entry is skipped, never fatal.
local function load_otp(c)
  c.otp, c.otp_names, c.otp_errs = {}, {}, {}
  local cur = uci_cursor()
  if not cur then return end
  cur:foreach(UCI_PKG, "otp", function(sec)
    if sec.enabled == "0" then return end
    local name = (sec.name or ""):lower()
    if not name:match("^[%w][%w_%.%-]*$") or #name > 32 then
      c.otp_errs[#c.otp_errs + 1] = "otp entry with invalid name skipped"
      return
    end
    local e, err = parse_otp_secret(sec.secret)
    if not e then
      c.otp_errs[#c.otp_errs + 1] = "otp '" .. name .. "': " .. err
    elseif not c.otp[name] then
      c.otp[name] = e
      c.otp_names[#c.otp_names + 1] = name
    end
  end)
  table.sort(c.otp_names)
end

local function load_config()
  local c = { POLL_SMS = "2", POLL_DISCORD = "4", OUT_MAX_PER_HOUR = "10" }
  for k, v in pairs(read_raw_config()) do
    if v ~= "" then c[k] = v end
  end
  local errs = {}
  if not (c.WEBHOOK_URL or ""):match("^https://[%w%.]*discord%.com/api/webhooks/%d+/[%w_%-]+$")
    and not (c.WEBHOOK_URL or ""):match("^https://[%w%.]*discordapp%.com/api/webhooks/%d+/[%w_%-]+$") then
    errs[#errs + 1] = "webhook_url missing or not a Discord webhook URL"
  end
  c.enabled = c.ENABLED ~= "0"
  c.allowed = {}
  for id in (c.ALLOWED_USER_IDS or ""):gmatch("%d+") do c.allowed[id] = true end
  c.outbound = (c.BOT_TOKEN or "") ~= "" and (c.CHANNEL_ID or "") ~= "" and next(c.allowed) ~= nil
  if c.outbound then
    if not c.BOT_TOKEN:match("^[%w%._%-]+$") then errs[#errs + 1] = "bot_token has unexpected characters" end
    if not c.CHANNEL_ID:match("^%d+$") then errs[#errs + 1] = "channel_id must be numeric" end
  end
  c.poll_sms = math.max(1, tonumber(c.POLL_SMS) or 2)
  c.poll_discord = math.max(2, tonumber(c.POLL_DISCORD) or 4)
  c.out_max = tonumber(c.OUT_MAX_PER_HOUR) or 10
  -- a bad relay setting only disables the relay, never SMS forwarding
  c.relay_url = (c.RELAY_URL or ""):gsub("/+$", "")
  c.relay_err = nil
  if c.relay_url ~= "" then
    if not c.relay_url:match("^https://[%w%.%-]+[%w%./%-_]*$") then c.relay_err = "relay_url must be an https:// URL"
    elseif not (c.RELAY_KEY or ""):match("^[%w_%-]+$") or #c.RELAY_KEY < 32 then c.relay_err = "relay_key must be 32+ letters/digits"
    elseif not c.outbound then c.relay_err = "the relay needs the bot (bot token, channel, allowed users)" end
  end
  c.relay = c.relay_url ~= "" and not c.relay_err
  load_otp(c)
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

local function http(method, url, body, token, bearer)
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
  if bearer then lines[#lines + 1] = 'header = "Authorization: Bearer ' .. bearer .. '"' end
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

local Outbound = { last_id = nil, next_try = 0, sent_times = {}, tracking = {}, warned = false, expiring = nil, menus = {} }

-- reactions that act as menu buttons: 1-9, 10, then A-J
local MENU_EMOJI = {}
for i = 1, 9 do MENU_EMOJI[i] = tostring(i) .. "\239\184\143\226\131\163" end
MENU_EMOJI[10] = "\240\159\148\159"
for i = 0, 9 do MENU_EMOJI[11 + i] = "\240\159\135" .. string.char(166 + i) end

-- Discord may or may not keep the U+FE0F variation selector in emoji names
local function emoji_key(e)
  return (e or ""):gsub("\239\184\143", "")
end

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

-- ---------------------------------------------------------------- !otp

function Outbound.save_expiring()
  local t = {}
  for _, x in ipairs(Outbound.expiring) do t[#t + 1] = x.id .. " " .. x.at end
  write_atomic(OTP_PENDING, table.concat(t, "\n") .. "\n", "600")
end

local CLOCK_MSG = E_FAIL .. " The router clock is not set yet (NTP), so codes would be wrong."

-- code text and how long it stays useful (both codes when the first is nearly done)
local function otp_text(e, name, now)
  local left = e.period - now % e.period
  local text = "\240\159\148\144 **" .. name .. "**  `" .. totp(e.key, now, e.digits, e.period) .. "`  valid " .. left .. " s"
  local life = left
  if left < 10 then
    text = text .. "\nnext  `" .. totp(e.key, now + e.period, e.digits, e.period) .. "`  from " .. left .. " s"
    life = life + e.period
  end
  return text, life
end

function Outbound.otp_code(c, mid, name, now)
  local e = c.otp[name]
  if now < CLOCK_MIN then
    bot_reply(c, mid, CLOCK_MSG)
    log("warning", "otp refused: router clock not synced")
    return
  end
  local text, life = otp_text(e, name, now)
  life = life + OTP_GRACE
  local code, resp = bot_reply(c, mid, text .. "\n-# deletes itself in " .. life .. " s")
  local ok, j = pcall(cjson.decode, resp)
  if code >= 200 and code < 300 and ok and type(j) == "table" and j.id then
    Outbound.expiring[#Outbound.expiring + 1] = { id = tostring(j.id), at = now + life }
    Outbound.save_expiring()
  end
  log("info", "otp code sent for '" .. name .. "'")
end

local function react_retry(c, id, emoji)
  local code, resp = bot_react(c, id, emoji)
  if code == 429 then
    sleep(retry_after(resp))
    code = bot_react(c, id, emoji)
  end
  return code
end

function Outbound.otp_menu(c, mid, now)
  local names, lines = {}, { "\240\159\148\144 Pick an account:" }
  for i, name in ipairs(c.otp_names) do
    if i > #MENU_EMOJI then break end
    names[i] = name
    lines[#lines + 1] = MENU_EMOJI[i] .. " " .. name
  end
  if #c.otp_names > #MENU_EMOJI then
    lines[#lines + 1] = "\226\128\166 and " .. (#c.otp_names - #MENU_EMOJI) .. " more: use `!otp NAME`"
  end
  lines[#lines + 1] = "-# closes in " .. MENU_SECONDS .. " s"
  local code, resp = bot_reply(c, mid, table.concat(lines, "\n"))
  local ok, j = pcall(cjson.decode, resp)
  if not (code >= 200 and code < 300 and ok and type(j) == "table" and j.id) then
    log("warning", "could not post otp menu (HTTP " .. code .. ")")
    return
  end
  local menu = { id = tostring(j.id), mid = mid, at = now + MENU_SECONDS, opts = {}, gone = { id = tostring(j.id), at = now + MENU_SECONDS } }
  -- deleted on time even if the service restarts before anyone picks
  Outbound.expiring[#Outbound.expiring + 1] = menu.gone
  Outbound.save_expiring()
  Outbound.menus[#Outbound.menus + 1] = menu
  for i, name in ipairs(names) do
    menu.opts[emoji_key(MENU_EMOJI[i])] = name
    if react_retry(c, menu.id, MENU_EMOJI[i]) >= 300 then break end
  end
end

-- a pick is a reaction from an allow-listed user on an open menu
function Outbound.poll_menus(c, now)
  local keep = {}
  for _, menu in ipairs(Outbound.menus) do
    local done = now >= menu.at
    if not done then
      local base = API .. "/channels/" .. c.CHANNEL_ID .. "/messages/" .. menu.id
      local code, resp = http("GET", base, nil, c.BOT_TOKEN)
      local ok, m = pcall(cjson.decode, resp)
      if code == 404 then
        done = true
      elseif code == 200 and ok and type(m) == "table" then
        for _, r in ipairs(type(m.reactions) == "table" and m.reactions or {}) do
          local name = type(r.emoji) == "table" and menu.opts[emoji_key(r.emoji.name)]
          -- skip reactions that are only the bot's own
          if name and (tonumber(r.count) or 0) > (r.me and 1 or 0) then
            local ucode, uresp = http("GET", base .. "/reactions/" .. urlenc(r.emoji.name) .. "?limit=25", nil, c.BOT_TOKEN)
            local uok, users = pcall(cjson.decode, uresp)
            if ucode == 200 and uok and type(users) == "table" then
              for _, u in ipairs(users) do
                if type(u) == "table" and c.allowed[tostring(u.id)] then done = name break end
              end
            end
          end
          if done then break end
        end
      end
    end
    if done then
      menu.gone.at = 0 -- delete the menu now
      if type(done) == "string" and c.otp[done] then Outbound.otp_code(c, menu.mid, done, now) end
    else
      keep[#keep + 1] = menu
    end
  end
  Outbound.menus = keep
end

function Outbound.otp(c, mid, content, now)
  local name = (content:match("^!%a+%s+(%S+)") or ""):lower()
  if #c.otp_names == 0 then
    bot_reply(c, mid, "No authenticator accounts set up. Add them in LuCI: Services \226\134\146 SMS to Discord \226\134\146 Authenticator.")
    return
  end
  if name == "" and #c.otp_names == 1 then name = c.otp_names[1] end -- nothing to pick
  if name == "" then return Outbound.otp_menu(c, mid, now) end
  if not c.otp[name] then
    bot_reply(c, mid, "Unknown name. Available: `" .. table.concat(c.otp_names, "`, `") .. "`")
    return
  end
  Outbound.otp_code(c, mid, name, now)
end

function Outbound.expire(c, now)
  local keep, changed = {}, false
  for _, x in ipairs(Outbound.expiring) do
    local code = 0
    if now >= x.at then
      code = http("DELETE", API .. "/channels/" .. c.CHANNEL_ID .. "/messages/" .. x.id, nil, c.BOT_TOKEN)
    end
    -- 404: already deleted by hand; retry later on rate limit or network trouble
    if code == 204 or code == 404 or code == 403 or (now > x.at + 3600) then
      changed = true
      if code == 403 then log("warning", "cannot delete otp reply (HTTP 403)") end
    else
      keep[#keep + 1] = x
    end
  end
  Outbound.expiring = keep
  if changed then Outbound.save_expiring() end
end

function Outbound.handle(c, paths, m, now)
  if m.webhook_id or (m.author and m.author.bot) then return end
  local content = (m.content or ""):gsub("\r", "")
  local cmd = content:match("^!(%a+)")
  if cmd == "auth" then cmd = "otp" end
  if cmd ~= "sms" and cmd ~= "otp" then return end
  local mid = tostring(m.id)
  local uid = m.author and tostring(m.author.id) or ""
  if not c.allowed[uid] then
    bot_react(c, mid, E_BLOCK)
    log("warning", "ignored !" .. cmd .. " from a user not in ALLOWED_USER_IDS")
    return
  end
  if cmd == "otp" then return Outbound.otp(c, mid, content, now) end
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
  if not Outbound.expiring then
    -- survives a service restart (not a reboot), so old codes still get deleted
    Outbound.expiring = {}
    for id, at in (read_file(OTP_PENDING) or ""):gmatch("(%d+) (%d+)") do
      Outbound.expiring[#Outbound.expiring + 1] = { id = id, at = tonumber(at) }
    end
  end
  if #Outbound.menus > 0 then Outbound.poll_menus(c, now) end
  if #Outbound.expiring > 0 then Outbound.expire(c, now) end
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

-- ---------------------------------------------------------------- relay

-- Optional Cloudflare Worker (relay/ in the repo) that receives /otp and button
-- clicks from Discord. The router polls it, asks Discord who really clicked,
-- and answers the interaction with an ephemeral code. Secrets stay here.
local Relay = { ready = false, next_try = 0, warned = false, expiring = {} }

local function relay_state(s)
  write_file(RELAY_STATE, s .. "\n", "600")
end

local function json_list(t)
  if #t == 0 then return "[]" end
  return cjson.encode(t)
end

function Relay.setup(c)
  local code, resp = http("GET", API .. "/applications/@me", nil, c.BOT_TOKEN)
  local ok, app = pcall(cjson.decode, resp)
  if code ~= 200 or not ok or type(app) ~= "table" then return nil, "reading the bot application", code end
  code, resp = http("GET", API .. "/channels/" .. c.CHANNEL_ID, nil, c.BOT_TOKEN)
  local ok2, ch = pcall(cjson.decode, resp)
  if code ~= 200 or not ok2 or type(ch) ~= "table" or not ch.guild_id then return nil, "reading the channel", code end
  local setup = '{"public_key":' .. cjson.encode(app.verify_key) .. ',"app_id":' .. cjson.encode(tostring(app.id))
    .. ',"names":' .. json_list(c.otp_names) .. "}"
  code = http("POST", c.relay_url .. "/router/setup", setup, nil, c.RELAY_KEY)
  if code ~= 200 then return nil, "contacting the relay", code end
  -- no options: the command answers with a row of buttons, one per account
  local cmds = "["
  for i, n in ipairs({ "otp", "auth" }) do
    cmds = cmds .. (i > 1 and "," or "") .. '{"name":"' .. n .. '","type":1,"description":"Pick an account and get its authenticator code"}'
  end
  code = http("PUT", API .. "/applications/" .. app.id .. "/guilds/" .. ch.guild_id .. "/commands", cmds .. "]", c.BOT_TOKEN)
  if code ~= 200 then return nil, "registering /otp", code end
  local want = c.relay_url .. "/interactions"
  if app.interactions_endpoint_url ~= want then
    -- Discord pings the relay before it accepts the URL
    code = http("PATCH", API .. "/applications/@me", '{"interactions_endpoint_url":' .. cjson.encode(want) .. "}", c.BOT_TOKEN)
    if code ~= 200 then return nil, "setting the interactions endpoint", code end
  end
  return true
end

function Relay.answer(c, it, now)
  local name = tostring(it.name or ""):lower()
  local app, token = tostring(it.app or ""), tostring(it.token or "")
  if not app:match("^%d+$") or not token:match("^[%w%._%-]+$") then return end
  local url = API .. "/webhooks/" .. app .. "/" .. token .. "/messages/@original"
  -- trust Discord, not the relay, for who asked
  local code, resp = http("GET", url)
  local ok, m = pcall(cjson.decode, resp)
  local meta = ok and type(m) == "table" and (type(m.interaction_metadata) == "table" and m.interaction_metadata
    or type(m.interaction) == "table" and m.interaction)
  local uid = meta and type(meta.user) == "table" and tostring(meta.user.id)
  if code ~= 200 or not uid then
    log("warning", "could not verify an /otp request (HTTP " .. code .. ")")
    return
  end
  local text, life = nil, 0
  if not c.allowed[uid] then
    text = E_BLOCK .. " You are not allowed to get codes."
    log("warning", "ignored /otp from a user not in ALLOWED_USER_IDS")
  elseif not c.otp[name] then
    text = "Unknown account. Available: `" .. table.concat(c.otp_names, "`, `") .. "`"
  elseif now < CLOCK_MIN then
    text = CLOCK_MSG
  else
    text, life = otp_text(c.otp[name], name, now)
  end
  code = http("PATCH", url, '{"content":' .. cjson.encode(text) .. ',"components":[],' .. NO_MENTIONS .. "}")
  if code ~= 200 then log("warning", "answering /otp failed (HTTP " .. code .. ")") return end
  if life > 0 then
    log("info", "otp code sent for '" .. name .. "' (button)")
    Relay.expiring[#Relay.expiring + 1] = { url = url, name = name, at = now + life }
  end
end

function Relay.tick(c, now)
  -- replace a used code by a short note once it has expired (only the asker sees it)
  local keep = {}
  for _, x in ipairs(Relay.expiring) do
    if now >= x.at then
      http("PATCH", x.url, '{"content":' .. cjson.encode("\240\159\148\144 **" .. x.name .. "** code expired. Use `/otp` again.") .. "}")
    else
      keep[#keep + 1] = x
    end
  end
  Relay.expiring = keep
  if now < Relay.next_try then return end
  if not Relay.ready then
    local ok, step, code = Relay.setup(c)
    if not ok then
      relay_state("error: " .. step .. " failed (HTTP " .. tostring(code) .. ")")
      log("warning", "relay setup: " .. step .. " failed (HTTP " .. tostring(code) .. ")")
      Relay.next_try = now + 60
      return
    end
    Relay.ready = true
    relay_state("ok")
    log("info", "relay ready: /otp with buttons enabled")
  end
  local code, resp = http("GET", c.relay_url .. "/router/queue", nil, nil, c.RELAY_KEY)
  local ok, items = pcall(cjson.decode, resp)
  if code ~= 200 or not ok or type(items) ~= "table" then
    if not Relay.warned then log("warning", "relay poll failed (HTTP " .. code .. ")") end
    Relay.warned = true
    relay_state("error: relay poll failed (HTTP " .. code .. ")")
    Relay.next_try = now + 10
    return
  end
  if Relay.warned then relay_state("ok") end
  Relay.warned = false
  for _, it in ipairs(items) do
    if type(it) == "table" then Relay.answer(c, it, now) end
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
  if not c.enabled then
    log("info", "disabled in " .. CONF_FILE)
    os.exit(0)
  end
  local paths
  while true do
    paths = smsd_paths()
    if paths then break end
    sleep(10) -- smstools3 writes its config at start-up
  end
  Inbound.init(paths)
  log("info", "started v" .. VERSION .. (c.outbound and " (inbound + outbound)" or " (inbound only)")
    .. (#c.otp_names > 0 and (", " .. #c.otp_names .. " authenticator account(s)") or ""))
  for _, e in ipairs(c.otp_errs) do log("warning", "config: " .. e) end

  local next_sms, next_discord, next_relay = 0, 0, 0
  if not c.relay then os.remove(RELAY_STATE) end
  if c.relay_err then log("warning", "config: " .. c.relay_err .. " (relay off)") end
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
    if c.relay and now >= next_relay then
      Relay.tick(c, now)
      next_relay = now + 2
    end
    sleep(1)
  end
end

local function save_config(c)
  local cur = uci_cursor()
  if not cur then return nil, "libuci-lua is not installed" end
  if not exists(CONF_FILE) then write_file(CONF_FILE, "", "600") end
  cur:set(UCI_PKG, "main", "sms2discord")
  if not cur:get(UCI_PKG, "main", "enabled") then cur:set(UCI_PKG, "main", "enabled", "1") end
  for k, opt in pairs(UCI_MAP) do
    local v = c[k] or ""
    if opt == "allowed_user" then
      local ids = {}
      for id in v:gmatch("%d+") do ids[#ids + 1] = id end
      if #ids > 0 then cur:set(UCI_PKG, "main", opt, ids) else cur:delete(UCI_PKG, "main", opt) end
    elseif v ~= "" then
      cur:set(UCI_PKG, "main", opt, v)
    else
      cur:delete(UCI_PKG, "main", opt)
    end
  end
  return cur:commit(UCI_PKG)
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
    write_file(CONF_FILE, before, "600") -- keep the old, working config
    print("Not saved; previous config kept.")
  end
  os.exit(ok and 0 or 1)
end

-- fill in missing IDs from Discord and save (used by LuCI's "Detect" button)
local function cmd_detect()
  os.execute("mkdir -p " .. shq(RUN_DIR) .. " && chmod 700 " .. shq(RUN_DIR))
  local c = load_config()
  autodetect_ids(c)
  save_config(c)
  c = load_config()
  local code = 0
  if c.outbound then
    code = http("GET", API .. "/channels/" .. c.CHANNEL_ID .. "/messages?limit=1", nil, c.BOT_TOKEN)
  end
  print(cjson.encode({ channel_id = c.CHANNEL_ID or "", allowed_user = c.ALLOWED_USER_IDS or "",
    outbound = c.outbound, bot_read_http = code }))
end

-- move /etc/sms2discord/config (v0.1/v0.2) into UCI
local function cmd_migrate()
  if not exists(LEGACY_CONF) then return end
  local c = load_config()
  if (c.WEBHOOK_URL or "") == "" then
    for k, v in pairs(read_legacy()) do if v ~= "" then c[k] = v end end
    local ok, err = save_config(c)
    if not ok then io.stderr:write("sms2discord: migration failed: " .. tostring(err) .. "\n") os.exit(1) end
  end
  os.remove(LEGACY_CONF)
  log("info", "migrated " .. LEGACY_CONF .. " to " .. CONF_FILE)
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

local function cmd_status(as_json)
  local c, errs = load_config()
  local pid = (read_file(LOCK_DIR .. "/pid") or ""):match("%d+")
  local n = 0
  for _ in (read_file(SEEN_FILE) or ""):gmatch("[^\n]+") do n = n + 1 end
  local p = smsd_paths()
  local st = {
    version = VERSION,
    running = pid ~= nil and exists("/proc/" .. pid .. "/cmdline"),
    enabled = c.enabled,
    configured = #errs == 0,
    errors = table.concat(errs, "; "),
    webhook_set = (c.WEBHOOK_URL or "") ~= "",
    bot_set = (c.BOT_TOKEN or "") ~= "",
    outbound = c.outbound,
    channel_id = c.CHANNEL_ID or "",
    allowed_users = c.ALLOWED_USER_IDS or "",
    seen = n,
    initialised = exists(SEEN_FILE),
    watching = p and table.concat(p.watch, " ") or "",
    otp_names = table.concat(c.otp_names, " "),
    otp_errors = table.concat(c.otp_errs, "; "),
    clock_ok = os.time() >= CLOCK_MIN,
    relay_set = c.relay_url ~= "",
    relay_state = c.relay_err or (c.relay and (read_file(RELAY_STATE) or "starting"):gsub("%s+$", "")) or "",
  }
  if as_json then print(cjson.encode(st)) return end
  print("version:   " .. st.version)
  print("service:   " .. (st.running and "running" or "not running") .. (st.enabled and "" or " (disabled in config)"))
  print("config:    " .. CONF_FILE .. (st.configured and "" or (" (" .. st.errors .. ")")))
  print("webhook:   " .. (st.webhook_set and "set (hidden)" or "not set"))
  print("outbound:  " .. (st.outbound and ("enabled, channel " .. st.channel_id) or "disabled"))
  print("otp:       " .. (#c.otp_names > 0 and table.concat(c.otp_names, ", ") or "none")
    .. (st.otp_errors ~= "" and (" (" .. st.otp_errors .. ")") or ""))
  if st.relay_set then print("relay:     " .. st.relay_state) end
  print("seen sms:  " .. n .. (st.initialised and "" or " (not initialised yet)"))
  print("watching:  " .. (st.watching ~= "" and st.watching or "smstools config not found"))
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

local function cmd_otp(name)
  local c = load_config()
  local e = c.otp[(name or ""):lower()]
  if not e then
    print("Unknown name. Available: " .. (#c.otp_names > 0 and table.concat(c.otp_names, ", ") or "none"))
    os.exit(1)
  end
  local now = os.time()
  if now < CLOCK_MIN then print("Router clock is not set (NTP).") os.exit(1) end
  print(totp(e.key, now, e.digits, e.period) .. "  (valid " .. (e.period - now % e.period) .. " s)")
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
  local h, b = parse_sms("From: 15555550100\nFrom_TOA: 91 international\nAlphabet: ISO\n\nCode 1234\n")
  eq("parse from", h and h.From, "15555550100")
  eq("parse body", b, "Code 1234\n")
  eq("decode iso", decode_body(h, b), "Code 1234")
  eq("sender intl", display_sender(h), "+15555550100")
  eq("sender alpha", display_sender({ From = "itsme", From_TOA = "D0 alphanumeric" }), "itsme")
  local hu, bu = parse_sms("From: x\nAlphabet: UCS2\n\n\0H\0i")
  eq("decode ucs2", decode_body(hu, bu), "Hi")
  eq("no header sep", parse_sms("garbage"), nil)
  local json = '{"content":' .. cjson.encode('a "q" \\ \n </x>') .. "," .. NO_MENTIONS .. "}"
  local ok, back = pcall(cjson.decode, json)
  eq("json roundtrip", ok and back.content, 'a "q" \\ \n </x>')
  eq("json parse array", ok and type(back.allowed_mentions.parse), "table")
  local function hex(s) return (s:gsub(".", function(ch) return string.format("%02x", ch:byte()) end)) end
  eq("sha1 empty", hex(sha1("")), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
  eq("sha1 abc", hex(sha1("abc")), "a9993e364706816aba3e25717850c26c9cd0d89d")
  eq("sha1 2 blocks", hex(sha1("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
    "84983e441c3bd26ebaae4aa1f95129e5e54670f1")
  eq("hmac rfc2202", hex(hmac_sha1(string.rep("\11", 20), "Hi There")), "b617318655057264e28bc0b6fb378c8ef146be00")
  eq("hmac long key", hex(hmac_sha1(string.rep("\170", 80), "Test Using Larger Than Block-Size Key - Hash Key First")),
    "aa4ae5e15272d00e95705637ce8a3b55ed402112")
  local rk = "12345678901234567890"
  eq("base32", base32_decode("GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"), rk)
  eq("base32 spaced lower", base32_decode("gezd gnbv gy3t qojq gezd gnbv gy3t qojq"), rk)
  eq("base32 invalid", base32_decode("ABC1"), nil)
  -- RFC 6238 appendix B (SHA1) and RFC 4226 appendix D
  for _, v in ipairs({ { 59, "94287082" }, { 1111111109, "07081804" }, { 1111111111, "14050471" },
    { 1234567890, "89005924" }, { 2000000000, "69279037" }, { 20000000000, "65353130" } }) do
    eq("totp " .. v[1], totp(rk, v[1], 8, 30), v[2])
  end
  eq("hotp 0", totp(rk, 0, 6, 30), "755224")
  eq("hotp 9", totp(rk, 9 * 30, 6, 30), "520489")
  local e = parse_otp_secret("otpauth://totp/Acme:me%40x.org?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ&issuer=Acme&digits=8&period=60")
  eq("otpauth key", e and e.key, rk)
  eq("otpauth digits", e and e.digits, 8)
  eq("otpauth period", e and e.period, 60)
  eq("bare secret", (parse_otp_secret(" JBSWY3DPEHPK3PXP ") or {}).digits, 6)
  eq("reject sha256", select(2, parse_otp_secret("otpauth://totp/x?secret=JBSWY3DPEHPK3PXP&algorithm=SHA256")),
    "only SHA1 is supported, not SHA256")
  eq("reject hotp", select(2, parse_otp_secret("otpauth://hotp/x?secret=JBSWY3DPEHPK3PXP&counter=1")),
    "only otpauth://totp links are supported")
  local keys = {}
  for i, em in ipairs(MENU_EMOJI) do keys[emoji_key(em)] = i end
  local nkeys = 0
  for _ in pairs(keys) do nkeys = nkeys + 1 end
  eq("menu emoji unique", nkeys, 20)
  eq("menu emoji fe0f", keys[emoji_key("1\226\131\163")], 1)
  eq("menu emoji J", MENU_EMOJI[20], "\240\159\135\175")
  eq("reject junk", select(2, parse_otp_secret("not a secret!")), "secret is not valid base32")
  print(fails == 0 and "selftest OK" or ("selftest: " .. fails .. " failure(s)"))
  os.exit(fails == 0 and 0 or 1)
end

local cmd = arg[1]
if cmd == "run" then cmd_run()
elseif cmd == "setup" then cmd_setup()
elseif cmd == "set-bot" then cmd_set_bot()
elseif cmd == "status" then cmd_status(arg[2] == "--json")
elseif cmd == "detect" then cmd_detect()
elseif cmd == "migrate" then cmd_migrate()
elseif cmd == "test" then cmd_test()
elseif cmd == "otp" then cmd_otp(arg[2])
elseif cmd == "selftest" then cmd_selftest()
else
  print("Usage: sms2discord run|setup|set-bot|detect|migrate|status [--json]|test|otp NAME|selftest")
  os.exit(cmd and 1 or 0)
end
