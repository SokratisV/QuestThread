// Test helper (not loaded by the game): decodes the installed QuestieDB's baked data into JSON
// for tests/run.py. Usage: node tests/dump-questiedb.js <AddOns folder> <out.json>
const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const addons = process.argv[2];
const out = process.argv[3];
const toc = path.join(addons, "QuestieDB", "QuestieDB_Forever.toc");
const xpFile = path.join(addons, "QuestieDB", "support", "Forever", "QuestXP", "xpDB-classic.lua");

function cbor(buf) {
  let p = 0;
  const len = (i) => {
    if (i < 24) return i;
    if (i === 24) return buf[p++];
    if (i === 25) { const v = buf.readUInt16BE(p); p += 2; return v; }
    if (i === 26) { const v = buf.readUInt32BE(p); p += 4; return v; }
    if (i === 27) { const v = Number(buf.readBigUInt64BE(p)); p += 8; return v; }
    throw new Error("len");
  };
  const item = () => {
    const b = buf[p++], m = b >> 5, i = b & 31;
    if (m === 0) return len(i);
    if (m === 1) return -1 - len(i);
    if (m === 2) { const n = len(i); const v = buf.toString("utf8", p, p + n); p += n; return v; }
    if (m === 3) { const n = len(i); const v = buf.toString("utf8", p, p + n); p += n; return v; }
    if (m === 4) { const n = len(i); const a = []; for (let k = 0; k < n; k++) a.push(item()); return a; }
    if (m === 5) { const n = len(i); const o = {}; for (let k = 0; k < n; k++) { const key = item(); o[key] = item(); } return o; }
    if (m === 7) { if (i === 20) return false; if (i === 21) return true; return null; }
    throw new Error("cbor major " + m);
  };
  return item();
}
const inflate = (b) => { for (const f of [zlib.inflateSync, zlib.inflateRawSync, zlib.gunzipSync]) { try { return f(b); } catch (e) { /* next */ } } throw new Error("inflate"); };

const meta = new Map();
for (const line of fs.readFileSync(toc, "utf8").split(/\r?\n/)) {
  const m = /^## (X-(?:Quest|Item)-[^:]+): (.*)$/.exec(line);
  if (m) meta.set(m[1], m[2]);
}
const stored = (k) => {
  const v = meta.get(k);
  if (v === undefined) return null;
  const c = /^~(\d+)~$/.exec(v);
  if (!c) return v;
  let s = "";
  for (let i = 1; i <= Number(c[1]); i++) s += meta.get(k + "-" + i) || "";
  return s;
};

const quests = {};
const qids = cbor(inflate(Buffer.from(stored("X-Quest-IDS"), "base64")));
const F = { 12: "pre", 13: "preS", 14: "child", 28: "bcs", 26: "rep" };
for (const id of qids) {
  const row = stored(`X-Quest-${id}-S`);
  const s = row ? cbor(Buffer.from(row, "base64")) : {};
  const q = {};
  const nm = s[1]; if (nm) q.name = nm;
  if (s[22]) q.next = s[22];
  if (s[27]) q.bcFor = s[27];
  const present = s.p || 0;
  for (const f of Object.keys(F).map(Number)) {
    if (Math.floor(present / 2 ** (f - 1)) % 2 !== 1) continue;
    const raw = stored(`X-Quest-${id}-${f}`);
    if (raw) q[F[f]] = cbor(Buffer.from(raw, "base64"));
  }
  quests[id] = q;
}
const itemQuests = {};
for (const [k, v] of meta) {
  const m = /^X-Item-(\d+)-6$/.exec(k);
  if (m) itemQuests[m[1]] = cbor(Buffer.from(stored(k), "base64"));
}
const xp = {};
for (const line of fs.readFileSync(xpFile, "utf8").split(/\r?\n/)) {
  const m = /^\s*\[(\d+)\]\s*=\s*\{(-?\d+),\s*(-?\d+)\}/.exec(line);
  if (m) xp[m[1]] = [Number(m[2]), Number(m[3])];
}
fs.writeFileSync(out, JSON.stringify({ quests, itemQuests, xp }));
console.log(`quests ${qids.length}, items with rewards ${Object.keys(itemQuests).length}, xp rows ${Object.keys(xp).length}`);
