// sms2discord relay: receives Discord interactions (/otp, buttons) for a router
// that can only make outgoing requests. The router polls the queue, checks the
// user with Discord itself, computes the code and answers the interaction.
// Holds no OTP secrets: only account names and the app's public key.
import { DurableObject } from "cloudflare:workers";

const MAX_AGE = 14 * 60 * 1000; // interaction tokens are valid for 15 minutes
const OFFLINE_AFTER = 30 * 1000;
const EPHEMERAL = 64;

export class Relay extends DurableObject {
  async getState() {
    return {
      config: (await this.ctx.storage.get("config")) || {},
      lastPoll: (await this.ctx.storage.get("lastPoll")) || 0,
    };
  }

  async setConfig(config) {
    await this.ctx.storage.put("config", config);
  }

  async enqueue(item) {
    const queue = ((await this.ctx.storage.get("queue")) || []).slice(-99);
    queue.push(item);
    await this.ctx.storage.put("queue", queue);
  }

  async take() {
    const now = Date.now();
    const queue = ((await this.ctx.storage.get("queue")) || []).filter((i) => now - i.ts < MAX_AGE);
    await this.ctx.storage.put({ queue: [], lastPoll: now });
    return queue;
  }
}

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });

const reply = (content, extra = {}) =>
  json({ type: 4, data: { content, flags: EPHEMERAL, allowed_mentions: { parse: [] }, ...extra } });

function hexToBytes(hex) {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
  return out;
}

async function verifyDiscord(request, body, publicKey) {
  const sig = request.headers.get("x-signature-ed25519");
  const ts = request.headers.get("x-signature-timestamp");
  if (!sig || !ts || !/^[0-9a-f]{128}$/i.test(sig) || !/^[0-9a-f]{64}$/i.test(publicKey || "")) return false;
  const key = await crypto.subtle.importKey("raw", hexToBytes(publicKey), { name: "Ed25519" }, false, ["verify"]);
  return crypto.subtle.verify("Ed25519", key, hexToBytes(sig), new TextEncoder().encode(ts + body));
}

async function routerAuthorized(request, env) {
  const got = new TextEncoder().encode(request.headers.get("authorization") || "");
  const want = new TextEncoder().encode("Bearer " + (env.RELAY_KEY || ""));
  return env.RELAY_KEY && env.RELAY_KEY.length >= 32 && got.length === want.length
    && crypto.subtle.timingSafeEqual(got, want);
}

function pickMenu(names) {
  const rows = [];
  names.slice(0, 25).forEach((name, i) => {
    if (i % 5 === 0) rows.push({ type: 1, components: [] });
    rows[rows.length - 1].components.push({ type: 2, style: 1, label: name.slice(0, 80), custom_id: "otp:" + name });
  });
  return reply("\u{1F510} Pick an account:", { components: rows });
}

async function interaction(request, env, relay) {
  const body = await request.text();
  const { config, lastPoll } = await relay.getState();
  if (!(await verifyDiscord(request, body, config.public_key))) return new Response("bad signature", { status: 401 });
  const it = JSON.parse(body);
  if (it.type === 1) return json({ type: 1 }); // PING when the endpoint URL is saved

  const names = config.names || [];
  if (it.type === 4) { // autocomplete
    const focused = (it.data.options || []).find((o) => o.focused);
    const q = String(focused?.value || "").toLowerCase();
    return json({ type: 8, data: { choices: names.filter((n) => n.includes(q)).slice(0, 25).map((n) => ({ name: n, value: n })) } });
  }

  if (Date.now() - lastPoll > OFFLINE_AFTER) {
    const since = lastPoll ? `for ${Math.round((Date.now() - lastPoll) / 1000)} s` : "yet";
    return reply(`\u26A0\uFE0F The router hasn't checked in ${since}. Try again later, or use \`!otp\` in the channel.`);
  }

  let name;
  let type;
  if (it.type === 2) {
    name = String((it.data.options || []).find((o) => o.name === "account")?.value || "").toLowerCase();
    if (!name) return names.length ? pickMenu(names) : reply("No authenticator accounts set up on the router.");
    type = 5; // deferred, ephemeral: the router fills it in
  } else if (it.type === 3 && String(it.data.custom_id || "").startsWith("otp:")) {
    name = it.data.custom_id.slice(4);
    type = 6; // deferred update: the router turns the menu into the code
  } else {
    return new Response("unsupported", { status: 400 });
  }
  await relay.enqueue({ name, app: it.application_id, token: it.token, ts: Date.now() });
  return json(type === 5 ? { type, data: { flags: EPHEMERAL } } : { type });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const relay = env.RELAY.get(env.RELAY.idFromName("main"));

    if (url.pathname === "/interactions" && request.method === "POST") return interaction(request, env, relay);

    if (url.pathname.startsWith("/router/")) {
      if (!(await routerAuthorized(request, env))) return new Response("unauthorized", { status: 401 });
      if (url.pathname === "/router/queue" && request.method === "GET") return json(await relay.take());
      if (url.pathname === "/router/setup" && request.method === "POST") {
        const c = await request.json();
        const names = Array.isArray(c.names) ? c.names.filter((n) => typeof n === "string").slice(0, 100) : [];
        if (!/^[0-9a-f]{64}$/i.test(c.public_key || "") || !/^\d+$/.test(c.app_id || "")) return json({ error: "bad setup" }, 400);
        await relay.setConfig({ public_key: c.public_key, app_id: c.app_id, names });
        return json({ ok: true });
      }
    }

    if (url.pathname === "/") return new Response("sms2discord relay\n");
    return new Response("not found", { status: 404 });
  },
};
