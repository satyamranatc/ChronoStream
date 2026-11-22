const http = require("http");
const fs = require("fs");
const path = require("path");
const os = require("os");
const crypto = require("crypto");
const QRCode = require("qrcode");

function getLocalIPv4() {
  const ifaces = os.networkInterfaces();
  let fallback = null;
  for (const name of Object.keys(ifaces)) {
    for (const info of ifaces[name] || []) {
      if (info.family === "IPv4" && !info.internal) {
        if (/wi-?fi|wlan|en0/i.test(name)) return info.address;
        if (!fallback) fallback = info.address;
      }
    }
  }
  return fallback;
}

function randomToken(len = 24) {
  return crypto.randomBytes(Math.ceil((len * 3) / 4)).toString("base64url").slice(0, len);
}

function randomPIN() {
  return String(Math.floor(1000 + Math.random() * 9000));
}

function sanitizeName(raw) {
  const base = path.basename(raw || "PhoneFile");
  return base.replace(/[/:\\?%*|"<>\r\n]/g, "_") || `PhoneFile-${Date.now()}`;
}

function uniqueDestPath(dir, filename) {
  fs.mkdirSync(dir, { recursive: true });
  const ext = path.extname(filename);
  const stem = path.basename(filename, ext);
  let candidate = path.join(dir, filename);
  let n = 2;
  while (fs.existsSync(candidate)) {
    candidate = path.join(dir, `${stem}-${n}${ext}`);
    n += 1;
  }
  return candidate;
}

class SecureWiFiManager {
  constructor(inboxDir, onReceivedFile) {
    this.inboxDir = inboxDir;
    this.onReceivedFile = onReceivedFile;

    this.sendServer = null;
    this.sendTimer = null;
    this.sendState = null;

    this.receiveServer = null;
    this.receiveTimer = null;
    this.receiveState = null;
  }

  async startSend(filePaths, requirePin = true) {
    this.stopSend();
    const ip = getLocalIPv4();
    if (!ip) throw new Error("Connect to Wi-Fi first.");

    const validFiles = filePaths
      .filter((p) => fs.existsSync(p))
      .map((p, idx) => {
        const st = fs.statSync(p);
        return { id: String(idx), path: p, name: path.basename(p), size: st.size };
      });
    if (!validFiles.length) throw new Error("No valid files selected.");

    const token = randomToken(24);
    const pin = randomPIN();
    const state = {
      token,
      pin,
      requirePin,
      files: validFiles,
      failedAttempts: 0,
      lockedUntil: 0,
      expiresAt: Date.now() + 10 * 60 * 1000
    };
    this.sendState = state;

    const server = http.createServer((req, res) => {
      const urlObj = new URL(req.url || "/", `http://${ip}`);
      const pathname = urlObj.pathname;
      if (!pathname.startsWith(`/s/${state.token}`)) {
        res.writeHead(403, { "Content-Type": "text/plain" });
        return res.end("Invalid or expired session.");
      }

      const pinParam = urlObj.searchParams.get("pin") || req.headers["x-chrono-pin"];
      const sub = pathname.slice(`/s/${state.token}`.length);

      if (req.method === "GET" && (sub === "" || sub === "/")) {
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        return res.end(this.renderSendHTML(state));
      }

      if (req.method === "GET" && sub === "/verify") {
        if (!state.requirePin) {
          res.writeHead(200, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ ok: true }));
        }
        if (Date.now() < state.lockedUntil) {
          const secs = Math.ceil((state.lockedUntil - Date.now()) / 1000);
          res.writeHead(429, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ ok: false, error: `Locked for ${secs}s.` }));
        }
        if (pinParam === state.pin) {
          state.failedAttempts = 0;
          res.writeHead(200, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ ok: true }));
        }
        state.failedAttempts += 1;
        if (state.failedAttempts >= 5) {
          state.lockedUntil = Date.now() + 60 * 1000;
          res.writeHead(429, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ ok: false, error: "Too many attempts. Locked for 60s." }));
        }
        res.writeHead(403, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ ok: false, error: `Wrong PIN (${5 - state.failedAttempts} tries left)` }));
      }

      if (req.method === "GET" && sub.startsWith("/file/")) {
        if (state.requirePin && pinParam !== state.pin) {
          res.writeHead(403, { "Content-Type": "text/plain" });
          return res.end("PIN required.");
        }
        const id = sub.slice("/file/".length);
        const item = state.files.find((f) => f.id === id);
        if (!item) {
          res.writeHead(404);
          return res.end("Not found");
        }
        res.writeHead(200, {
          "Content-Type": "application/octet-stream",
          "Content-Length": item.size,
          "Content-Disposition": `attachment; filename="${encodeURIComponent(item.name)}"`
        });
        fs.createReadStream(item.path).pipe(res);
        return;
      }

      res.writeHead(404);
      res.end("Not Found");
    });

    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "0.0.0.0", resolve);
    });

    const port = server.address().port;
    const shareURL = `http://${ip}:${port}/s/${token}`;
    const qrDataUrl = await QRCode.toDataURL(shareURL, { width: 240, margin: 1 });
    this.sendServer = server;
    this.sendTimer = setTimeout(() => this.stopSend(), 10 * 60 * 1000);

    return { shareURL, qrDataUrl, pin, requirePin, expiresAt: state.expiresAt };
  }

  stopSend() {
    if (this.sendTimer) clearTimeout(this.sendTimer);
    this.sendTimer = null;
    if (this.sendServer) {
      try { this.sendServer.close(); } catch {}
    }
    this.sendServer = null;
    this.sendState = null;
  }

  async startReceive() {
    this.stopReceive();
    const ip = getLocalIPv4();
    if (!ip) throw new Error("Connect to Wi-Fi first.");

    const token = randomToken(24);
    const pin = randomPIN();
    const state = {
      token,
      pin,
      failedAttempts: 0,
      lockedUntil: 0,
      expiresAt: Date.now() + 10 * 60 * 1000
    };
    this.receiveState = state;

    const server = http.createServer((req, res) => {
      const urlObj = new URL(req.url || "/", `http://${ip}`);
      const pathname = urlObj.pathname;
      if (!pathname.startsWith(`/r/${state.token}`)) {
        res.writeHead(403, { "Content-Type": "text/plain" });
        return res.end("Invalid or expired session.");
      }
      const sub = pathname.slice(`/r/${state.token}`.length);
      const pinParam = urlObj.searchParams.get("pin") || req.headers["x-chrono-pin"];

      if (req.method === "GET" && (sub === "" || sub === "/")) {
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        return res.end(this.renderReceiveHTML(`/r/${state.token}`));
      }

      if (req.method === "GET" && sub === "/verify") {
        if (Date.now() < state.lockedUntil) {
          const secs = Math.ceil((state.lockedUntil - Date.now()) / 1000);
          res.writeHead(429, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ ok: false, error: `Locked for ${secs}s.` }));
        }
        if (pinParam === state.pin) {
          state.failedAttempts = 0;
          res.writeHead(200, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ ok: true }));
        }
        state.failedAttempts += 1;
        if (state.failedAttempts >= 5) {
          state.lockedUntil = Date.now() + 60 * 1000;
          res.writeHead(429, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ ok: false, error: "Too many attempts. Locked for 60s." }));
        }
        res.writeHead(403, { "Content-Type": "application/json" });
        return res.end(JSON.stringify({ ok: false, error: `Wrong PIN (${5 - state.failedAttempts} tries left)` }));
      }

      if (req.method === "POST" && sub === "/upload") {
        if (Date.now() < state.lockedUntil || pinParam !== state.pin) {
          res.writeHead(403, { "Content-Type": "application/json" });
          return res.end(JSON.stringify({ ok: false, error: "PIN required" }));
        }
        const safeName = sanitizeName(urlObj.searchParams.get("name"));
        const dest = uniqueDestPath(this.inboxDir, safeName);
        const ws = fs.createWriteStream(dest);
        req.pipe(ws);
        ws.on("finish", () => {
          const st = fs.statSync(dest);
          if (this.onReceivedFile) {
            this.onReceivedFile({
              path: dest,
              name: path.basename(dest),
              size: st.size,
              receivedAt: Date.now()
            });
          }
          res.writeHead(200, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ ok: true }));
        });
        ws.on("error", () => {
          res.writeHead(500, { "Content-Type": "application/json" });
          res.end(JSON.stringify({ ok: false }));
        });
        return;
      }

      res.writeHead(404);
      res.end("Not Found");
    });

    await new Promise((resolve, reject) => {
      server.once("error", reject);
      server.listen(0, "0.0.0.0", resolve);
    });

    const port = server.address().port;
    const receiverURL = `http://${ip}:${port}/r/${token}`;
    const qrDataUrl = await QRCode.toDataURL(receiverURL, { width: 240, margin: 1 });
    this.receiveServer = server;
    this.receiveTimer = setTimeout(() => this.stopReceive(), 10 * 60 * 1000);

    return { receiverURL, qrDataUrl, pin, expiresAt: state.expiresAt };
  }

  rotateReceivePIN() {
    if (!this.receiveState) return null;
    const pin = randomPIN();
    this.receiveState.pin = pin;
    this.receiveState.failedAttempts = 0;
    this.receiveState.lockedUntil = 0;
    return pin;
  }

  stopReceive() {
    if (this.receiveTimer) clearTimeout(this.receiveTimer);
    this.receiveTimer = null;
    if (this.receiveServer) {
      try { this.receiveServer.close(); } catch {}
    }
    this.receiveServer = null;
    this.receiveState = null;
  }

  renderSendHTML(state) {
    const base = `/s/${state.token}`;
    const itemsJSON = JSON.stringify(state.files.map((f) => ({ id: f.id, name: f.name, size: f.size })));
    return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ChronoStream · Download</title>
<style>*{box-sizing:border-box;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}body{margin:0;background:#F5F7FA;color:#0F172A;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}.card{width:100%;max-width:440px;background:#fff;border:1px solid #E2E8F0;border-radius:20px;padding:24px;box-shadow:0 12px 30px rgba(15,23,42,.06)}.badge{display:inline-block;font-size:11px;font-weight:700;color:#008080;background:#E6F4F4;padding:4px 10px;border-radius:999px;margin-bottom:10px}h1{margin:0 0 6px;font-size:21px}p{margin:0 0 16px;color:#475569;font-size:14px}.pin-box{display:flex;gap:8px;margin-bottom:10px}input{flex:1;font-size:22px;letter-spacing:6px;text-align:center;padding:10px;border:1.5px solid #CBD5E1;border-radius:12px}button{background:#008080;color:#fff;border:0;border-radius:12px;padding:0 18px;font-weight:600;cursor:pointer}.row{display:flex;justify-content:space-between;align-items:center;padding:12px;background:#F8FAFC;border:1px solid #E2E8F0;border-radius:12px;margin-bottom:8px;gap:10px}.dl{background:#008080;color:#fff;text-decoration:none;padding:7px 14px;border-radius:10px;font-size:13px;font-weight:600}.hidden{display:none}</style></head>
<body><div class="card"><div class="badge">Same Wi-Fi · Direct LAN</div><h1>ChronoStream Share</h1>
<div id="lock" class="${state.requirePin ? "" : "hidden"}"><p>Enter the 4-digit PIN shown on your PC.</p><div class="pin-box"><input id="pin" type="tel" maxlength="4" placeholder="••••"><button id="go">Unlock</button></div><div id="err" style="color:#DC2626;font-size:13px"></div></div>
<div id="files" class="${state.requirePin ? "hidden" : ""}"></div></div>
<script>const BASE=${JSON.stringify(base)},ITEMS=${itemsJSON};let PIN="";
function render(){const box=document.getElementById("files");box.innerHTML=ITEMS.map(f=>\`<div class="row"><div style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap"><strong>\${f.name}</strong><div style="font-size:12px;color:#64748B">\${(f.size/1048576).toFixed(2)} MB</div></div><a class="dl" href="\${BASE}/file/\${f.id}?pin=\${encodeURIComponent(PIN)}">Save</a></div>\`).join("")}
if(!${state.requirePin})render();
document.getElementById("go").onclick=async()=>{const v=document.getElementById("pin").value.trim();const r=await fetch(BASE+"/verify?pin="+encodeURIComponent(v));const d=await r.json().catch(()=>({}));if(r.ok&&d.ok){PIN=v;document.getElementById("lock").classList.add("hidden");document.getElementById("files").classList.remove("hidden");render()}else{document.getElementById("err").textContent=d.error||"Wrong PIN"}};</script></body></html>`;
  }

  renderReceiveHTML(base) {
    return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ChronoStream · Send to PC</title>
<style>*{box-sizing:border-box;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}body{margin:0;background:#F5F7FA;color:#0F172A;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}.card{width:100%;max-width:440px;background:#fff;border:1px solid #E2E8F0;border-radius:20px;padding:24px;box-shadow:0 12px 30px rgba(15,23,42,.06)}.badge{display:inline-block;font-size:11px;font-weight:700;color:#008080;background:#E6F4F4;padding:4px 10px;border-radius:999px;margin-bottom:10px}h1{margin:0 0 6px;font-size:21px}p{margin:0 0 16px;color:#475569;font-size:14px}.pin-box{display:flex;gap:8px;margin-bottom:10px}input[type=tel]{flex:1;font-size:22px;letter-spacing:6px;text-align:center;padding:10px;border:1.5px solid #CBD5E1;border-radius:12px}button{background:#008080;color:#fff;border:0;border-radius:12px;padding:0 18px;font-weight:600;cursor:pointer}.drop{display:block;border:2px dashed #99D5D5;background:#F3FAFA;border-radius:16px;padding:28px 16px;text-align:center;cursor:pointer}.hidden{display:none}.row{background:#F8FAFC;border:1px solid #E2E8F0;border-radius:12px;padding:10px;margin-top:8px;font-size:13px}.bar-bg{height:6px;background:#E2E8F0;border-radius:999px;overflow:hidden;margin-top:6px}.bar{height:100%;width:0%;background:#008080}</style></head>
<body><div class="card"><div class="badge">Same Wi-Fi · PIN Protected</div><h1>Send to PC</h1>
<div id="lock"><p>Enter the 4-digit PIN shown in ChronoStream.</p><div class="pin-box"><input id="pin" type="tel" maxlength="4" placeholder="••••"><button id="go">Unlock</button></div><div id="err" style="color:#DC2626;font-size:13px"></div></div>
<div id="up" class="hidden"><p>Choose photos, videos, audio, or PDFs to send directly over Wi-Fi.</p><label class="drop"><input id="picker" type="file" multiple style="display:none"><strong style="color:#006666">Tap to Choose Files</strong></label><div id="list"></div></div></div>
<script>const BASE=${JSON.stringify(base)};let PIN="";
document.getElementById("go").onclick=async()=>{const v=document.getElementById("pin").value.trim();const r=await fetch(BASE+"/verify?pin="+encodeURIComponent(v));const d=await r.json().catch(()=>({}));if(r.ok&&d.ok){PIN=v;document.getElementById("lock").classList.add("hidden");document.getElementById("up").classList.remove("hidden")}else{document.getElementById("err").textContent=d.error||"Wrong PIN"}};
document.getElementById("picker").onchange=async(e)=>{for(const f of e.target.files){const row=document.createElement("div");row.className="row";row.innerHTML=\`<div style="display:flex;justify-content:space-between"><span>\${f.name}</span><span class="pct">0%</span></div><div class="bar-bg"><div class="bar"></div></div>\`;document.getElementById("list").prepend(row);await new Promise(res=>{const x=new XMLHttpRequest();x.open("POST",BASE+"/upload?name="+encodeURIComponent(f.name)+"&pin="+encodeURIComponent(PIN));x.setRequestHeader("X-Chrono-PIN",PIN);x.upload.onprogress=ev=>{if(ev.lengthComputable){const p=Math.round(ev.loaded/ev.total*100);row.querySelector(".pct").textContent=p+"%";row.querySelector(".bar").style.width=p+"%"}};x.onload=()=>{row.querySelector(".pct").textContent=x.status===200?"Sent":"Failed";res()};x.onerror=()=>{row.querySelector(".pct").textContent="Error";res()};x.send(f)})}e.target.value=""};</script></body></html>`;
  }
}

module.exports = { SecureWiFiManager, getLocalIPv4 };
