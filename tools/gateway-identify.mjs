// One-time Discord Gateway login for the sms2discord bot.
//
// Discord requires a bot to connect to the Gateway at least once before it may
// post messages over REST. The router only uses REST, so run this once:
//
//   read -rs DISCORD_BOT_TOKEN && export DISCORD_BOT_TOKEN && node tools/gateway-identify.mjs
//
// Needs Node 22+ (built-in WebSocket). The token is read from the environment.

const token = process.env.DISCORD_BOT_TOKEN;
if (!token) {
  console.error('Set DISCORD_BOT_TOKEN first.');
  process.exit(1);
}

const ws = new WebSocket('wss://gateway.discord.gg/?v=10&encoding=json');
const timer = setTimeout(() => {
  console.error('Timed out waiting for READY.');
  process.exit(1);
}, 20000);

ws.addEventListener('message', (event) => {
  const msg = JSON.parse(event.data);
  if (msg.op === 10) {
    ws.send(JSON.stringify({
      op: 2,
      d: { token, intents: 0, properties: { os: 'linux', browser: 'sms2discord', device: 'sms2discord' } },
    }));
  } else if (msg.t === 'READY') {
    console.log(`Gateway login OK as ${msg.d.user.username} (${msg.d.user.id}).`);
    clearTimeout(timer);
    ws.close();
  } else if (msg.op === 9) {
    console.error('Invalid session: token wrong?');
    process.exit(1);
  }
});

ws.addEventListener('close', (event) => {
  if (event.code === 4004) {
    console.error('Authentication failed: token is wrong.');
    process.exit(1);
  }
  process.exit(0);
});
