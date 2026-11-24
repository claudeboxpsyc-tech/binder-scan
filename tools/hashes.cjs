// Builds a 256-bit picture fingerprint (difference hash) for every card image on TCGdex,
// so the scanner can recognise a card by how it looks. Output: hashes/<lang>.json (ids) + hashes/<lang>.bin (32 bytes each).
// Incremental: only cards without a fingerprint are downloaded.
const fs = require("fs");
const sharp = require("sharp");
const HEAD = { "User-Agent": "BinderScan/1.0 (+https://github.com/claudeboxpsyc-tech/binder-scan)" };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const W = 68, H = 64;

function hashFromGrey(g) {            // g: W*H grey bytes → 32-byte hash
  const v = new Float32Array(17 * 16);
  for (let y = 0; y < 16; y++) for (let x = 0; x < 17; x++) {
    let s = 0;
    for (let j = 0; j < 4; j++) for (let i = 0; i < 4; i++) s += g[(y * 4 + j) * W + x * 4 + i];
    v[y * 17 + x] = s;
  }
  const out = Buffer.alloc(32);
  for (let y = 0; y < 16; y++) for (let x = 0; x < 16; x++)
    if (v[y * 17 + x] > v[y * 17 + x + 1]) out[(y * 16 + x) >> 3] |= 0x80 >> ((y * 16 + x) & 7);
  return out;
}
async function hashImage(buf) {
  const g = await sharp(buf).flatten({ background: "#ffffff" }).resize(W, H, { fit: "fill" }).greyscale().raw().toBuffer();
  return hashFromGrey(g);
}
async function getJSON(url) {
  for (let i = 0; i < 5; i++) {
    try { const r = await fetch(url, { headers: HEAD }); const t = await r.text(); return JSON.parse(t); } catch {}
    await sleep(1500 * (i + 1));
  }
  throw new Error("failed " + url);
}
async function getBuf(url) {
  for (let i = 0; i < 3; i++) {
    try { const r = await fetch(url, { headers: HEAD }); if (r.ok) return Buffer.from(await r.arrayBuffer()); if (r.status === 404) return null; } catch {}
    await sleep(800 * (i + 1));
  }
  return null;
}
const norm = s => String(s || "").normalize("NFKD").replace(/[\u0300-\u036f]/g, "").normalize("NFC").toLowerCase()
  .replace(/[’'`]/g, "").replace(/[^\p{L}\p{N} ]+/gu, " ").replace(/\s+/g, " ").trim();
const stripPre = s => norm(String(s).replace(/^[A-Za-z]{1,6}\d*(\.\d+)?[a-z]?\s*:\s*/, ""));
const local = s => String(s || "").toUpperCase().replace(/^([A-Z]*)0*(\d)/, "$1$2");
// same matching as the app (tcProducts in index.html)
function tcPhotoFinder(lang) {
  const dir = lang === "ja" ? "prices/jp/" : "prices/";
  let groups = [];
  try { groups = JSON.parse(fs.readFileSync(dir + "index.json", "utf8")).groups || []; } catch {}
  const files = new Map();
  return (setId, setNm, localId, name) => {
    let g;
    if (lang === "ja") g = groups.find(x => (x.a || "").toLowerCase() === String(setId).toLowerCase());
    else if (setNm) { const want = norm(setNm);
      g = groups.find(x => stripPre(x.n) === want) || groups.find(x => norm(x.n) === want) || groups.find(x => stripPre(x.n).endsWith(" " + want)); }
    if (!g) return null;
    if (!files.has(g.g)) { let d = null; try { d = JSON.parse(fs.readFileSync(dir + g.g + ".json", "utf8")); } catch {} files.set(g.g, d); }
    const d = files.get(g.g); if (!d) return null;
    let list = [];
    for (const [num, arr] of Object.entries(d)) if (local(num.split("/")[0]) === local(localId)) list.push(...arr);
    const named = list.filter(p => norm(p.n).startsWith(norm(name)));
    if (named.length) list = named;
    if (!list.length) return null;
    return (list.find(p => !/\(/.test(p.n)) || list[0]).i;
  };
}
async function run(lang) {
  const idsFile = `hashes/${lang}.json`, binFile = `hashes/${lang}.bin`;
  const have = new Map();
  if (fs.existsSync(idsFile) && fs.existsSync(binFile)) {
    const ids = JSON.parse(fs.readFileSync(idsFile, "utf8")), bin = fs.readFileSync(binFile);
    if (bin.length === ids.length * 32) ids.forEach((id, i) => have.set(id, bin.subarray(i * 32, i * 32 + 32)));
  }
  const all = (await getJSON(`https://api.tcgdex.net/v2/${lang}/cards`)).filter(c => c && c.id);
  // cards TCGdex has no picture for: use TCGplayer's product photo, found through the price files in prices/
  const sets = await getJSON(`https://api.tcgdex.net/v2/${lang}/sets`).catch(() => []);
  const setName = new Map(sets.map(s => [s.id, s.name]));
  const photo = tcPhotoFinder(lang);
  const cards = [];
  for (const c of all) {
    if (c.image) { cards.push({ id: c.id, url: c.image + "/low.webp" }); continue; }
    if (have.has(c.id)) { cards.push({ id: c.id }); continue; }
    const sid = c.id.slice(0, c.id.lastIndexOf("-"));
    const pid = photo(sid, setName.get(sid), c.localId, c.name);
    if (pid) cards.push({ id: c.id, url: `https://tcgplayer-cdn.tcgplayer.com/product/${pid}_200w.jpg` });
  }
  const todo = cards.filter(c => !have.has(c.id));
  console.log(lang, "cards:", all.length, "with a picture source:", cards.length, "new:", todo.length);
  let done = 0, failed = 0;
  async function worker() {
    for (;;) {
      const c = todo.pop(); if (!c) return;
      try { const b = await getBuf(c.url); if (b) have.set(c.id, await hashImage(b)); else failed++; } catch { failed++; }
      if (++done % 2000 === 0) console.log(lang, done);
    }
  }
  await Promise.all(Array.from({ length: 12 }, worker));
  const ids = cards.map(c => c.id).filter(id => have.has(id));
  fs.mkdirSync("hashes", { recursive: true });
  fs.writeFileSync(idsFile, JSON.stringify(ids));
  fs.writeFileSync(binFile, Buffer.concat(ids.map(id => have.get(id))));
  console.log(lang, "fingerprints:", ids.length, "failed:", failed);
}
module.exports = { hashFromGrey, hashImage };
if (require.main === module) (async () => { for (const l of ["en", "ja"]) await run(l); })();
