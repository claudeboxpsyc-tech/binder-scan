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
async function run(lang) {
  const idsFile = `hashes/${lang}.json`, binFile = `hashes/${lang}.bin`;
  const have = new Map();
  if (fs.existsSync(idsFile) && fs.existsSync(binFile)) {
    const ids = JSON.parse(fs.readFileSync(idsFile, "utf8")), bin = fs.readFileSync(binFile);
    if (bin.length === ids.length * 32) ids.forEach((id, i) => have.set(id, bin.subarray(i * 32, i * 32 + 32)));
  }
  const cards = (await getJSON(`https://api.tcgdex.net/v2/${lang}/cards`)).filter(c => c && c.id && c.image);
  const todo = cards.filter(c => !have.has(c.id));
  console.log(lang, "cards with image:", cards.length, "new:", todo.length);
  let done = 0, failed = 0;
  async function worker() {
    for (;;) {
      const c = todo.pop(); if (!c) return;
      try { const b = await getBuf(c.image + "/low.webp"); if (b) have.set(c.id, await hashImage(b)); else failed++; } catch { failed++; }
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
