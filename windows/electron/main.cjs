const { app, BrowserWindow, ipcMain, dialog, shell, screen, powerSaveBlocker, protocol } = require("electron");
const path = require("path");
const fs = require("fs");
const crypto = require("crypto");
const { spawn } = require("child_process");
const { Document, Packer, Paragraph, TextRun } = require("docx");
const mammoth = require("mammoth");
const { SecureWiFiManager, getLocalIPv4 } = require("./wifiShare.cjs");

const VIDEO_EXTS = new Set(["mp4", "m4v", "mov", "mkv", "avi", "webm", "ts", "mts", "mpg", "mpeg"]);
const AUDIO_EXTS = new Set(["mp3", "wav", "aac", "m4a", "flac", "alac", "aiff", "ogg", "opus"]);
const IMAGE_EXTS = new Set(["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "webp", "bmp"]);
const PDF_EXTS = new Set(["pdf"]);

let mainWindow = null;
let cinemaWindow = null;
let powerBlockerId = null;
let keepAwakeEnabled = true;

const dataDir = () => {
  const dir = path.join(app.getPath("userData"), "ChronoStreamData");
  fs.mkdirSync(dir, { recursive: true });
  return dir;
};

const docsDir = () => {
  const dir = path.join(app.getPath("documents"), "ChronoStream Docs");
  fs.mkdirSync(dir, { recursive: true });
  return dir;
};

const inboxDir = () => {
  const dir = path.join(app.getPath("downloads"), "ChronoStream Inbox");
  fs.mkdirSync(dir, { recursive: true });
  return dir;
};

const remuxDir = () => {
  const dir = path.join(app.getPath("temp"), "ChronoStreamRemux");
  fs.mkdirSync(dir, { recursive: true });
  return dir;
};

let wifiManager = null;

function classifyExt(filePath) {
  const ext = path.extname(filePath).toLowerCase().replace(".", "");
  if (VIDEO_EXTS.has(ext)) return "video";
  if (AUDIO_EXTS.has(ext)) return "audio";
  if (IMAGE_EXTS.has(ext)) return "image";
  if (PDF_EXTS.has(ext)) return "pdf";
  return null;
}

function fastPartialHash(filePath, size) {
  try {
    const fd = fs.openSync(filePath, "r");
    const len = Math.min(131072, size);
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, 0);
    fs.closeSync(fd);
    return crypto.createHash("sha256").update(buf).update(String(size)).digest("hex").slice(0, 16);
  } catch {
    return null;
  }
}

function scanDirectoryRecursive(dirPath, maxDepth = 4, depth = 0) {
  if (depth > maxDepth) return [];
  let out = [];
  let entries = [];
  try {
    entries = fs.readdirSync(dirPath, { withFileTypes: true });
  } catch {
    return [];
  }
  for (const entry of entries) {
    if (entry.name.startsWith(".")) continue;
    const full = path.join(dirPath, entry.name);
    if (entry.isDirectory()) {
      out = out.concat(scanDirectoryRecursive(full, maxDepth, depth + 1));
    } else if (entry.isFile()) {
      const kind = classifyExt(full);
      if (!kind) continue;
      try {
        const st = fs.statSync(full);
        out.push({
          id: full,
          path: full,
          name: entry.name,
          kind,
          ext: path.extname(entry.name).toUpperCase().replace(".", ""),
          fileSize: st.size,
          modifiedAt: st.mtimeMs,
          partialHash: fastPartialHash(full, st.size),
          isFavorite: false,
          lastPosition: 0,
          duration: 0
        });
      } catch {}
    }
  }
  return out;
}

function needsFFmpegRemux(filePath) {
  const ext = path.extname(filePath).toLowerCase().replace(".", "");
  if (["mkv", "avi", "ts", "mts", "mpg", "mpeg"].includes(ext)) return true;
  if (ext === "mp4") {
    try {
      const fd = fs.openSync(filePath, "r");
      const buf = Buffer.alloc(12);
      fs.readSync(fd, buf, 0, 12, 0);
      fs.closeSync(fd);
      // Hikvision MPEG-PS disguised as .mp4 starts with 00 00 01 BA
      if (buf[0] === 0x00 && buf[1] === 0x00 && buf[2] === 0x01 && buf[3] === 0xba) return true;
    } catch {}
  }
  return false;
}

function runFFmpeg(args) {
  return new Promise((resolve) => {
    const proc = spawn("ffmpeg", args, { windowsHide: true });
    let err = "";
    proc.stderr.on("data", (d) => { err += d.toString(); });
    proc.on("error", (e) => resolve({ ok: false, error: e.message }));
    proc.on("close", (code) => resolve({ ok: code === 0, error: code === 0 ? null : err.slice(-300) }));
  });
}

function updatePowerAssertion() {
  const displays = screen.getAllDisplays();
  const hasExternal = displays.length > 1;
  const shouldBlock = keepAwakeEnabled && (hasExternal || cinemaWindow !== null);
  if (shouldBlock && powerBlockerId === null) {
    powerBlockerId = powerSaveBlocker.start("prevent-display-sleep");
  } else if (!shouldBlock && powerBlockerId !== null) {
    powerSaveBlocker.stop(powerBlockerId);
    powerBlockerId = null;
  }
}

function getDisplayPayload() {
  const primaryId = screen.getPrimaryDisplay().id;
  return screen.getAllDisplays().map((d, idx) => ({
    id: d.id,
    name: d.label || (d.id === primaryId ? "Primary Display" : `External Display ${idx + 1}`),
    width: Math.round(d.size.width * d.scaleFactor),
    height: Math.round(d.size.height * d.scaleFactor),
    refreshRateHz: Math.round(d.displayFrequency || 60),
    scaleFactor: d.scaleFactor,
    isBuiltIn: d.id === primaryId && screen.getAllDisplays().length === 1 ? true : d.id === primaryId,
    isMain: d.id === primaryId
  }));
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1240,
    height: 780,
    minWidth: 960,
    minHeight: 620,
    backgroundColor: "#F5F7FA",
    title: "ChronoStream",
    webPreferences: {
      preload: path.join(__dirname, "preload.cjs"),
      contextIsolation: true,
      nodeIntegration: false,
      webSecurity: true
    }
  });

  if (process.env.VITE_DEV_SERVER_URL) {
    mainWindow.loadURL(process.env.VITE_DEV_SERVER_URL);
  } else {
    mainWindow.loadFile(path.join(__dirname, "../dist/index.html"));
  }

  mainWindow.on("closed", () => {
    if (cinemaWindow) cinemaWindow.close();
    mainWindow = null;
  });
}

// Register streaming media protocol supporting HTTP 206 Byte-Range requests (instant scrubbing for multi-GB videos)
protocol.registerSchemesAsPrivileged([
  { scheme: "chronostream-media", privileges: { standard: true, secure: true, supportFetchAPI: true, stream: true } }
]);

app.whenReady().then(() => {
  protocol.handle("chronostream-media", (request) => {
    const url = new URL(request.url);
    const filePath = decodeURIComponent(url.searchParams.get("path") || "");
    if (!filePath || !fs.existsSync(filePath)) {
      return new Response("Not Found", { status: 404 });
    }

    const stat = fs.statSync(filePath);
    const total = stat.size;
    const ext = path.extname(filePath).toLowerCase();
    const mimeMap = {
      ".mp4": "video/mp4", ".m4v": "video/mp4", ".mov": "video/quicktime", ".webm": "video/webm",
      ".mp3": "audio/mpeg", ".wav": "audio/wav", ".m4a": "audio/mp4", ".flac": "audio/flac", ".ogg": "audio/ogg",
      ".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp", ".gif": "image/gif",
      ".pdf": "application/pdf"
    };
    const contentType = mimeMap[ext] || "application/octet-stream";
    const range = request.headers.get("range");

    if (range) {
      const match = /bytes=(\d+)-(\d*)/.exec(range);
      const start = match ? parseInt(match[1], 10) : 0;
      const end = match && match[2] ? parseInt(match[2], 10) : Math.min(start + 2 * 1024 * 1024 - 1, total - 1);
      const chunkSize = end - start + 1;
      const stream = fs.createReadStream(filePath, { start, end });
      return new Response(stream, {
        status: 206,
        headers: {
          "Content-Range": `bytes ${start}-${end}/${total}`,
          "Accept-Ranges": "bytes",
          "Content-Length": String(chunkSize),
          "Content-Type": contentType
        }
      });
    }

    const stream = fs.createReadStream(filePath);
    return new Response(stream, {
      status: 200,
      headers: {
        "Content-Length": String(total),
        "Accept-Ranges": "bytes",
        "Content-Type": contentType
      }
    });
  });

  wifiManager = new SecureWiFiManager(inboxDir(), (fileRecord) => {
    if (mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.webContents.send("wifi:received-file", fileRecord);
    }
  });

  createWindow();
  updatePowerAssertion();

  screen.on("display-added", () => {
    updatePowerAssertion();
    mainWindow?.webContents.send("displays:changed", getDisplayPayload());
  });
  screen.on("display-removed", () => {
    updatePowerAssertion();
    mainWindow?.webContents.send("displays:changed", getDisplayPayload());
  });
});

app.on("window-all-closed", () => {
  wifiManager?.stopSend();
  wifiManager?.stopReceive();
  if (powerBlockerId !== null) powerSaveBlocker.stop(powerBlockerId);
  if (process.platform !== "darwin") app.quit();
});

// --- IPC Handlers ---

ipcMain.handle("fs:pick-folders", async () => {
  const res = await dialog.showOpenDialog(mainWindow, { properties: ["openDirectory", "multiSelections"] });
  return res.canceled ? [] : res.filePaths;
});

ipcMain.handle("fs:pick-files", async () => {
  const res = await dialog.showOpenDialog(mainWindow, { properties: ["openFile", "multiSelections"] });
  return res.canceled ? [] : res.filePaths;
});

ipcMain.handle("fs:scan-folder", async (_e, folderPath) => scanDirectoryRecursive(folderPath));
ipcMain.handle("fs:reveal", async (_e, filePath) => shell.showItemInFolder(filePath));
ipcMain.handle("fs:open-inbox", async () => shell.openPath(inboxDir()));
ipcMain.handle("fs:read-text", async (_e, filePath) => {
  try { return fs.readFileSync(filePath, "utf8"); } catch { return null; }
});

ipcMain.handle("state:load", async (_e, key) => {
  const file = path.join(dataDir(), `${key}.json`);
  try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; }
});

ipcMain.handle("state:save", async (_e, key, value) => {
  const file = path.join(dataDir(), `${key}.json`);
  fs.writeFileSync(file, JSON.stringify(value, null, 2), "utf8");
  return true;
});

ipcMain.handle("video:prepare-playback", async (_e, filePath) => {
  if (!needsFFmpegRemux(filePath)) return { path: filePath, remuxed: false };
  const hash = crypto.createHash("sha1").update(filePath).digest("hex").slice(0, 12);
  const outPath = path.join(remuxDir(), `${hash}.mp4`);
  if (fs.existsSync(outPath)) return { path: outPath, remuxed: true };
  const res = await runFFmpeg(["-y", "-i", filePath, "-c", "copy", "-movflags", "+faststart", outPath]);
  if (res.ok && fs.existsSync(outPath)) return { path: outPath, remuxed: true };
  return { path: filePath, remuxed: false, error: res.error || "Install FFmpeg to play non-standard containers." };
});

ipcMain.handle("video:studio-op", async (_e, payload) => {
  const { op, inputPath, secondInputPath, startSec, durationSec, speed, mute } = payload;
  const parsed = path.parse(inputPath);
  const saveRes = await dialog.showSaveDialog(mainWindow, {
    defaultPath: path.join(parsed.dir, `${parsed.name}-${op}${op === "extractAudio" ? ".m4a" : ".mp4"}`)
  });
  if (saveRes.canceled || !saveRes.filePath) return { ok: false, canceled: true };
  const out = saveRes.filePath;

  let args = [];
  if (op === "trim") {
    args = ["-y", "-ss", String(startSec || 0), "-i", inputPath, "-t", String(durationSec || 10), "-c", "copy", out];
  } else if (op === "extractAudio") {
    args = ["-y", "-i", inputPath, "-vn", "-c:a", "aac", out];
  } else if (op === "transform") {
    const vf = `setpts=${(1 / (speed || 1)).toFixed(3)}*PTS`;
    args = ["-y", "-i", inputPath, "-vf", vf, ...(mute ? ["-an"] : []), out];
  } else if (op === "merge" && secondInputPath) {
    args = ["-y", "-i", inputPath, "-i", secondInputPath, "-filter_complex", "[0:v][0:a][1:v][1:a]concat=n=2:v=1:a=1[v][a]", "-map", "[v]", "-map", "[a]", out];
  }
  const r = await runFFmpeg(args);
  return { ...r, outputPath: out };
});

// Displays & HDMI Cinema
ipcMain.handle("displays:list", async () => ({
  displays: getDisplayPayload(),
  keepAwake: keepAwakeEnabled,
  cinemaActive: cinemaWindow !== null,
  localIP: getLocalIPv4()
}));

ipcMain.handle("displays:keep-awake", async (_e, enabled) => {
  keepAwakeEnabled = Boolean(enabled);
  updatePowerAssertion();
  return keepAwakeEnabled;
});

ipcMain.handle("displays:move-window", async (_e, displayId) => {
  const target = screen.getAllDisplays().find((d) => d.id === displayId);
  if (!target || !mainWindow) return false;
  const b = target.workArea;
  const [w, h] = mainWindow.getSize();
  const nw = Math.min(w, b.width);
  const nh = Math.min(h, b.height);
  mainWindow.setBounds({ x: Math.round(b.x + (b.width - nw) / 2), y: Math.round(b.y + (b.height - nh) / 2), width: nw, height: nh }, true);
  mainWindow.focus();
  return true;
});

ipcMain.handle("displays:start-cinema", async (_e, mediaUrl, displayId) => {
  const displays = screen.getAllDisplays();
  const target = displays.find((d) => d.id === displayId) || displays.find((d) => d.id !== screen.getPrimaryDisplay().id);
  if (!target) return false;
  if (cinemaWindow) cinemaWindow.close();
  cinemaWindow = new BrowserWindow({
    x: target.bounds.x,
    y: target.bounds.y,
    width: target.bounds.width,
    height: target.bounds.height,
    frame: false,
    backgroundColor: "#000000",
    alwaysOnTop: true
  });
  const html = `<!doctype html><html><body style="margin:0;background:#000;overflow:hidden"><video src="${mediaUrl}" autoplay controls style="width:100vw;height:100vh;object-fit:contain"></video></body></html>`;
  cinemaWindow.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(html)}`);
  cinemaWindow.on("closed", () => { cinemaWindow = null; updatePowerAssertion(); });
  updatePowerAssertion();
  return true;
});

ipcMain.handle("displays:stop-cinema", async () => {
  if (cinemaWindow) { cinemaWindow.close(); cinemaWindow = null; }
  updatePowerAssertion();
  return true;
});

// Wi-Fi Share (Two-way Token + PIN)
ipcMain.handle("wifi:start-send", async (_e, paths, requirePin) => wifiManager.startSend(paths, requirePin));
ipcMain.handle("wifi:stop-send", async () => { wifiManager.stopSend(); return true; });
ipcMain.handle("wifi:start-receive", async () => wifiManager.startReceive());
ipcMain.handle("wifi:rotate-pin", async () => wifiManager.rotateReceivePIN());
ipcMain.handle("wifi:stop-receive", async () => { wifiManager.stopReceive(); return true; });
ipcMain.handle("wifi:list-inbox", async () => {
  const dir = inboxDir();
  try {
    return fs.readdirSync(dir)
      .filter((f) => !f.startsWith("."))
      .map((name) => {
        const p = path.join(dir, name);
        const st = fs.statSync(p);
        return { path: p, name, size: st.size, receivedAt: st.mtimeMs };
      })
      .sort((a, b) => b.receivedAt - a.receivedAt);
  } catch { return []; }
});

// Doc Writer (.docx & PDF)
ipcMain.handle("docs:list", async () => {
  const dir = docsDir();
  try {
    return fs.readdirSync(dir)
      .filter((f) => /\.(docx|html|txt)$/i.test(f))
      .map((name) => {
        const p = path.join(dir, name);
        const st = fs.statSync(p);
        return { path: p, title: path.basename(name, path.extname(name)), ext: path.extname(name).toUpperCase().replace(".", ""), size: st.size, modifiedAt: st.mtimeMs };
      })
      .sort((a, b) => b.modifiedAt - a.modifiedAt);
  } catch { return []; }
});

ipcMain.handle("docs:save-docx", async (_e, { title, plainText, existingPath }) => {
  const safe = (title || "Untitled Document").replace(/[/:\\?%*|"<>\r\n]/g, "-");
  const dest = existingPath || path.join(docsDir(), `${safe}.docx`);
  const lines = (plainText || "").split(/\r?\n/);
  const doc = new Document({
    sections: [{
      children: lines.map((line) => new Paragraph({ children: [new TextRun({ text: line, font: "Calibri", size: 24 })] }))
    }]
  });
  const buf = await Packer.toBuffer(doc);
  fs.writeFileSync(dest, buf);
  return { ok: true, path: dest, name: path.basename(dest) };
});

ipcMain.handle("docs:open-docx", async (_e, filePath) => {
  let target = filePath;
  if (!target) {
    const res = await dialog.showOpenDialog(mainWindow, {
      defaultPath: docsDir(),
      filters: [{ name: "Documents", extensions: ["docx", "txt", "html"] }]
    });
    if (res.canceled || !res.filePaths[0]) return null;
    target = res.filePaths[0];
  }
  const ext = path.extname(target).toLowerCase();
  if (ext === ".docx") {
    const result = await mammoth.convertToHtml({ path: target });
    return { path: target, title: path.basename(target, ext), html: result.value };
  }
  const raw = fs.readFileSync(target, "utf8");
  return { path: target, title: path.basename(target, ext), html: ext === ".html" ? raw : `<p>${raw.replace(/\n/g, "<br/>")}</p>` };
});

ipcMain.handle("docs:export-pdf", async (_e, { title, html }) => {
  const safe = (title || "Untitled Document").replace(/[/:\\?%*|"<>\r\n]/g, "-");
  const res = await dialog.showSaveDialog(mainWindow, { defaultPath: path.join(docsDir(), `${safe}.pdf`) });
  if (res.canceled || !res.filePath) return { ok: false };
  const printWin = new BrowserWindow({ show: false, width: 794, height: 1123 });
  const docHtml = `<!doctype html><html><body style="font-family:'Segoe UI',Arial,sans-serif;padding:48px;color:#0F172A;line-height:1.6">${html}</body></html>`;
  await printWin.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(docHtml)}`);
  const pdf = await printWin.webContents.printToPDF({ pageSize: "A4", printBackground: true });
  fs.writeFileSync(res.filePath, pdf);
  printWin.close();
  return { ok: true, path: res.filePath };
});

ipcMain.handle("docs:delete", async (_e, filePath) => {
  try { await shell.trashItem(filePath); return true; } catch { return false; }
});
ipcMain.handle("docs:open-folder", async () => shell.openPath(docsDir()));
