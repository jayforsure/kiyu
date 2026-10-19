// Kiyu alerts server
// 1) API: phones tell us "send alerts for address 0x… to me" (saved in PostgreSQL)
// 2) Watcher: every block, look for Kiyu events and send a phone notification to the right person
import http from "node:http";
import { createHash } from "node:crypto";
import pg from "pg";
import webpush from "web-push";
import { createPublicClient, http as rpc, fallback, parseAbi, formatUnits, isAddress } from "viem";
import { sepolia, anvil } from "viem/chains";

// ---------- 1. Settings (from environment variables, never in code) ----------
try { process.loadEnvFile(); } catch { /* no .env file (e.g. on Railway): fine */ }

const LOCAL = process.env.CHAIN === "local";
const NET = LOCAL
  ? { chain: anvil,   rpc: "http://127.0.0.1:8545",                       kiyu: "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512" }
  : { chain: sepolia, rpc: "https://ethereum-sepolia-rpc.publicnode.com", kiyu: "0x6A65B7D654268d8A24803155411ebcE8b4bBf840" };
// Several free RPC providers: if one fails or is behind, the next one answers.
// (Later, a free key from Alchemy or Infura is more reliable: put it first via RPC_URL.)
const RPCS = [process.env.RPC_URL, NET.rpc, ...(LOCAL ? [] : ["https://sepolia.drpc.org", "https://1rpc.io/sepolia"])].filter(Boolean);
const KIYU = process.env.KIYU_ADDRESS || NET.kiyu;
const PORT = Number(process.env.PORT || 8080);                   // Railway sets PORT for us
const SITE = process.env.SITE_URL || "https://kiyu-production.up.railway.app/";
// only our own website may call the API
const ALLOWED = (process.env.ALLOWED_ORIGINS || "https://kiyu-production.up.railway.app,http://localhost:5173").split(",").map((s) => s.trim());
const EVERY = LOCAL ? 2000 : 12000;                              // check once per block
// Public RPCs are groups of servers; some are a block behind. Asking about the very newest block
// can reach one that hasn't seen it yet ("invalid parameters"). Staying 1 block behind avoids that.
const BEHIND = LOCAL ? 0n : 1n;
const RM_PER_USD = 4.08;

for (const k of ["DATABASE_URL", "VAPID_PUBLIC_KEY", "VAPID_PRIVATE_KEY"]) {
  if (!process.env[k]) { console.error(`Missing ${k}. Set it in .env (laptop) or Variables (Railway).`); process.exit(1); }
}
// VAPID keys prove to Google/Apple's push services that the alerts really come from Kiyu
webpush.setVapidDetails(process.env.VAPID_SUBJECT || "mailto:hello@kiyu.app", process.env.VAPID_PUBLIC_KEY, process.env.VAPID_PRIVATE_KEY);

// ---------- 2. Database ----------
const db = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.DATABASE_SSL === "true" ? { rejectUnauthorized: false } : undefined,
});
// create the tables the first time (safe to run every start)
await db.query(`
  CREATE TABLE IF NOT EXISTS subscriptions (
    endpoint   TEXT PRIMARY KEY,               -- the phone's unique push address
    address    TEXT NOT NULL,                  -- the Kiyu account it wants alerts for (lowercase)
    p256dh     TEXT NOT NULL,                  -- encryption keys from the phone, so only it can read the alert
    auth       TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  CREATE INDEX IF NOT EXISTS subscriptions_address ON subscriptions (address);
  CREATE TABLE IF NOT EXISTS profiles (
    address    TEXT PRIMARY KEY,               -- the Kiyu account (lowercase)
    username   TEXT NOT NULL UNIQUE,           -- "jay" (shown as @jay), lowercase, unique
    name       TEXT NOT NULL,                  -- "Jay Lee"
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
  );
  CREATE TABLE IF NOT EXISTS watcher (
    name       TEXT PRIMARY KEY,               -- which chain + contract
    last_block BIGINT NOT NULL                 -- last block we finished, so a restart doesn't miss or repeat alerts
  );
`);

// ---------- 3. Proof that you own the address ----------
// The website asks your account to sign this exact text. Only the owner of the address can
// produce a valid signature, so nobody can sign up for someone else's alerts.
// The server writes the text itself; it never trusts text sent by the browser.
const client = createPublicClient({
  chain: NET.chain,
  transport: fallback(RPCS.map((url) => rpc(url, { timeout: 10_000, retryCount: 1 }))),
});
const deviceId = (endpoint) => createHash("sha256").update(endpoint).digest("hex").slice(0, 16);
const alertsMessage = (address, endpoint, signedAt) =>
  `Turn on Kiyu payment alerts for this device.\n\nAccount: ${address}\nDevice: ${deviceId(endpoint)}\nTime: ${signedAt}`;
async function signedBy(address, message, signedAt, signature) {
  const t = Date.parse(signedAt);
  if (!t || Math.abs(Date.now() - t) > 10 * 60 * 1000) return false;          // older than 10 minutes: could be a replay
  if (typeof signature !== "string" || !/^0x[0-9a-fA-F]+$/.test(signature)) return false;
  // works for normal wallets and smart-contract wallets (it asks the chain when needed)
  return client.verifyMessage({ address, message, signature }).catch(() => false);
}
const provesOwner = (address, endpoint, signedAt, signature) => signedBy(address, alertsMessage(address, endpoint, signedAt), signedAt, signature);

// ---------- 3b. Kiyu IDs: @username + name, so people pay "@ali" instead of "0x7099…" ----------
const RESERVED = new Set(["kiyu", "admin", "support", "help", "official", "team", "root", "system", "security", "staff", "wallet", "pay", "payments", "bank"]);
// 3-20 characters: lowercase letters, numbers and _ ; starts with a letter
function usernameProblem(u) {
  if (typeof u !== "string" || !/^[a-z][a-z0-9_]{2,19}$/.test(u)) return "Use 3-20 letters, numbers or _, starting with a letter";
  if (RESERVED.has(u)) return "That username is reserved";
  return null;
}
// names are shown to other people, so only allow plain text: letters (any language), numbers, spaces and . ' -
const cleanName = (n) => (typeof n === "string" ? n.normalize("NFC").replace(/\s+/g, " ").trim() : "");
const nameOk = (n) => n.length >= 1 && n.length <= 40 && /^[\p{L}\p{M}\p{N} .'-]+$/u.test(n);
const profileMessage = (address, username, name, signedAt) =>
  `Set my Kiyu ID.\n\nAccount: ${address}\nUsername: @${username}\nName: ${name}\nTime: ${signedAt}`;
const publicProfile = (r) => r && { address: r.address, username: r.username, name: r.name };

// ---------- 4. Sending a notification ----------
async function notify(address, alert) {
  const { rows } = await db.query("SELECT endpoint, p256dh, auth FROM subscriptions WHERE address = $1", [address.toLowerCase()]);
  let delivered = 0;
  for (const s of rows) {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, JSON.stringify({ url: SITE, ...alert }), {
        TTL: 24 * 3600,                 // if the phone is off, keep trying for a day
        urgency: "high",                // money alerts must wake the phone; "normal" waits until you open the phone
      });
      delivered++;
    } catch (e) {
      if (e.statusCode === 404 || e.statusCode === 410) {
        await db.query("DELETE FROM subscriptions WHERE endpoint = $1", [s.endpoint]);   // phone turned alerts off: forget it
      } else console.error("Push failed:", e.statusCode ?? "", e.body ?? e.message);
    }
  }
  return delivered;
}

// ---------- 5. The API ----------
// Limits per person (per internet address), so nobody can hammer the server
// or check thousands of usernames: lookups 60 a minute, saving things 10 a minute.
const LIMITS = { lookup: 60, write: 10 };
const hits = new Map();                                          // "ip|kind" -> { count, start }
function tooMany(req, kind) {
  const ip = String(req.headers["x-forwarded-for"] ?? req.socket.remoteAddress ?? "?").split(",")[0].trim();   // Railway passes the real IP here
  const key = `${ip}|${kind}`, now = Date.now();
  const h = hits.get(key);
  if (!h || now - h.start > 60_000) { hits.set(key, { count: 1, start: now }); return false; }
  return ++h.count > LIMITS[kind];
}
setInterval(() => { const old = Date.now() - 60_000; for (const [k, h] of hits) if (h.start < old) hits.delete(k); }, 60_000).unref();   // forget old counts
function reply(req, res, status, body) {
  const origin = req.headers.origin;
  const headers = { "content-type": "application/json" };
  if (origin && ALLOWED.includes(origin)) {
    headers["access-control-allow-origin"] = origin;
    headers["access-control-allow-headers"] = "content-type";
    headers["access-control-allow-methods"] = "GET, POST, OPTIONS";
  }
  res.writeHead(status, headers);
  res.end(body === undefined ? "" : JSON.stringify(body));
}
function readJson(req) {
  return new Promise((resolve, reject) => {
    let data = "";
    req.on("data", (c) => { data += c; if (data.length > 10_000) { reject(new Error("too big")); req.destroy(); } });
    req.on("end", () => { try { resolve(JSON.parse(data || "{}")); } catch { reject(new Error("bad json")); } });
  });
}
const isText = (v) => typeof v === "string" && v.length > 0 && v.length < 1000;

http.createServer(async (req, res) => {
  try {
    if (req.method === "OPTIONS") return reply(req, res, 204);                         // browser asking "may I call you?"
    const url = new URL(req.url, "http://x");
    const parts = url.pathname.split("/").filter(Boolean);                             // "/profile/u/jay" -> ["profile","u","jay"]
    const isLookup = req.method === "GET" && ["username-available", "profile"].includes(parts[0]) || (req.method === "POST" && url.pathname === "/profiles");
    const isWrite = req.method === "POST" && ["/profile", "/subscribe"].includes(url.pathname);
    if ((isLookup && tooMany(req, "lookup")) || (isWrite && tooMany(req, "write")))
      return reply(req, res, 429, { error: "Too many requests. Try again in a minute" });

    // ---- Kiyu IDs ----
    if (req.method === "GET" && parts[0] === "username-available" && parts.length === 2) {
      const u = decodeURIComponent(parts[1]).toLowerCase();
      const problem = usernameProblem(u);
      if (problem) return reply(req, res, 200, { available: false, reason: problem });
      const { rows } = await db.query("SELECT address FROM profiles WHERE username = $1", [u]);
      const mine = url.searchParams.get("address")?.toLowerCase();                       // your own current username counts as available
      return reply(req, res, 200, rows.length && rows[0].address !== mine ? { available: false, reason: "That username is taken" } : { available: true });
    }
    if (req.method === "GET" && parts[0] === "profile" && parts.length === 3) {          // /profile/u/jay  or  /profile/a/0x…
      const key = decodeURIComponent(parts[2]).toLowerCase();
      const col = parts[1] === "u" ? "username" : parts[1] === "a" ? "address" : null;
      if (!col) return reply(req, res, 404, { error: "not found" });
      const { rows } = await db.query(`SELECT address, username, name FROM profiles WHERE ${col} = $1`, [key]);
      return rows.length ? reply(req, res, 200, publicProfile(rows[0])) : reply(req, res, 404, { error: "no such Kiyu ID" });
    }
    if (req.method === "POST" && url.pathname === "/profiles") {                         // names for many addresses at once
      const { addresses } = await readJson(req);
      if (!Array.isArray(addresses) || addresses.length > 100 || !addresses.every((a) => isAddress(a ?? "")))
        return reply(req, res, 400, { error: "bad addresses" });
      const { rows } = await db.query("SELECT address, username, name FROM profiles WHERE address = ANY($1)", [addresses.map((a) => a.toLowerCase())]);
      return reply(req, res, 200, { profiles: rows.map(publicProfile) });
    }
    if (req.method === "POST" && url.pathname === "/profile") {                          // create or change your own Kiyu ID
      const { address, username: rawU, name: rawN, signedAt, signature } = await readJson(req);
      if (!isAddress(address ?? "")) return reply(req, res, 400, { error: "bad address" });
      const username = typeof rawU === "string" ? rawU.trim().toLowerCase() : "", name = cleanName(rawN);
      const problem = usernameProblem(username);
      if (problem) return reply(req, res, 400, { error: problem });
      if (!nameOk(name)) return reply(req, res, 400, { error: "Use 1-40 letters for your name" });
      if (!(await signedBy(address, profileMessage(address, username, rawN, signedAt), signedAt, signature)))
        return reply(req, res, 401, { error: "signature doesn't prove you own this address" });
      try {
        await db.query(
          `INSERT INTO profiles (address, username, name) VALUES ($1, $2, $3)
           ON CONFLICT (address) DO UPDATE SET username = $2, name = $3, updated_at = now()`,
          [address.toLowerCase(), username, name]);
      } catch (e) {
        if (e.code === "23505") return reply(req, res, 409, { error: "That username is taken" });   // unique rule: someone else has it
        throw e;
      }
      return reply(req, res, 200, { address: address.toLowerCase(), username, name });
    }
    if (req.method === "GET" && url.pathname === "/health") return reply(req, res, 200, { ok: true });
    if (req.method === "GET" && url.pathname === "/vapid-key") return reply(req, res, 200, { key: process.env.VAPID_PUBLIC_KEY });

    if (req.method === "POST" && url.pathname === "/subscribe") {
      const { address, subscription: s, signedAt, signature } = await readJson(req);
      if (!isAddress(address ?? "")) return reply(req, res, 400, { error: "bad address" });
      if (!isText(s?.endpoint) || !s.endpoint.startsWith("https://") || !isText(s?.keys?.p256dh) || !isText(s?.keys?.auth))
        return reply(req, res, 400, { error: "bad subscription" });
      if (!(await provesOwner(address, s.endpoint, signedAt, signature)))
        return reply(req, res, 401, { error: "signature doesn't prove you own this address" });
      // same phone again (e.g. switched account): update it instead of adding a duplicate
      await db.query(
        `INSERT INTO subscriptions (endpoint, address, p256dh, auth) VALUES ($1, $2, $3, $4)
         ON CONFLICT (endpoint) DO UPDATE SET address = $2, p256dh = $3, auth = $4`,
        [s.endpoint, address.toLowerCase(), s.keys.p256dh, s.keys.auth]);
      return reply(req, res, 200, { ok: true });
    }
    if (req.method === "POST" && url.pathname === "/unsubscribe") {
      const { endpoint } = await readJson(req);
      if (isText(endpoint)) await db.query("DELETE FROM subscriptions WHERE endpoint = $1", [endpoint]);
      return reply(req, res, 200, { ok: true });
    }
    reply(req, res, 404, { error: "not found" });
  } catch (e) {
    reply(req, res, 400, { error: e.message });
  }
}).listen(PORT, () => console.log(`Alerts API on port ${PORT}`));

// ---------- 6. Watch the Kiyu contract ----------
const abi = parseAbi([
  "event Sent(uint256 indexed id, address indexed sender, address indexed recipient, uint256 amount)",
  "event Accepted(uint256 indexed id)",
  "event Rejected(uint256 indexed id)",
  "function payments(uint256) view returns (address sender, address recipient, uint256 amount, uint256 deadline, uint8 status)",
]);
const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;
async function who(address) {                                                    // "Ali Tan" if they have a Kiyu ID, else "0x7099…79C8"
  const { rows } = await db.query("SELECT name FROM profiles WHERE address = $1", [address.toLowerCase()]).catch(() => ({ rows: [] }));
  return rows[0]?.name ?? short(address);
}
const rm = (units) => `RM ${(Number(formatUnits(units, 6)) * RM_PER_USD).toFixed(2)}`;

const NAME = `${NET.chain.id}:${KIYU.toLowerCase()}`;
async function saveLast(n) {
  await db.query("INSERT INTO watcher (name, last_block) VALUES ($1, $2) ON CONFLICT (name) DO UPDATE SET last_block = $2", [NAME, n.toString()]);
}
let last;
{
  const { rows } = await db.query("SELECT last_block FROM watcher WHERE name = $1", [NAME]);
  last = rows.length ? BigInt(rows[0].last_block) : await client.getBlockNumber();   // first run: start from now, don't alert old payments
  if (!rows.length) await saveLast(last);
}
console.log(`Watching Kiyu ${KIYU} on ${NET.chain.name} from block ${last} (RPC: ${RPCS.map((u) => new URL(u).host).join(", ")})`);

async function handle(log) {
  const id = log.args.id;
  if (log.eventName === "Sent") {
    const { sender, recipient, amount } = log.args;
    const n = await notify(recipient, { title: "Money waiting for you", body: `${await who(sender)} sent you ${rm(amount)}. Open Kiyu to accept or decline.`, tag: `kiyu-${id}` });
    console.log(`#${id} sent -> alert delivered to ${n} device(s) of ${short(recipient)}`);
    return;
  }
  // Accepted / Rejected only carry the id, so look up who sent it
  const [sender, recipient, amount] = await client.readContract({ address: KIYU, abi, functionName: "payments", args: [id] });
  const accepted = log.eventName === "Accepted";
  const n = await notify(sender, accepted
    ? { title: "Payment accepted", body: `${await who(recipient)} accepted your ${rm(amount)}.`, tag: `kiyu-${id}` }
    : { title: "Payment declined", body: `${await who(recipient)} declined your ${rm(amount)}. It's back in your balance.`, tag: `kiyu-${id}` });
  console.log(`#${id} ${accepted ? "accepted" : "declined"} -> alert delivered to ${n} device(s) of ${short(sender)}`);
}

async function check() {
  const head = (await client.getBlockNumber()) - BEHIND;
  if (head + 20n < last) { last = head; await saveLast(last); }          // chain went far back: local test chain was restarted
  if (head <= last) return;                                              // nothing new yet
  const from = last + 1n;
  const to = head - from > 199n ? from + 199n : head;                    // public RPCs limit the range per request
  const logs = await client.getLogs({ address: KIYU, events: abi.filter((x) => x.type === "event"), fromBlock: from, toBlock: to });
  for (const log of logs) await handle(log);
  last = to; await saveLast(last);                                       // only after every alert went out
}
async function loop() {
  try { await check(); } catch (e) { console.error("Check failed, retrying:", (e.shortMessage ?? e.message).split("\n")[0], e.details ? `(${e.details})` : ""); }
  setTimeout(loop, EVERY);
}
loop();
