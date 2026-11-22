import React, { useRef, useState } from "react";
import {
  ChevronLeft, ZoomIn, ZoomOut, RotateCw, Share2, Download, Scissors, Wand2, Film
} from "lucide-react";
import { MediaItem, formatBytes } from "../types";

export function PhotoViewerView({ item, onShare, onClose }: { item: MediaItem; onShare: (i: MediaItem) => void; onClose: () => void }) {
  const [zoom, setZoom] = useState(1);
  const [rot, setRot] = useState(0);
  const src = window.chronoAPI ? window.chronoAPI.mediaUrl(item.path) : item.path;

  return (
    <div className="flex h-full flex-col bg-zinc-950 text-white">
      <div className="flex items-center justify-between border-b border-white/10 px-4 py-2.5">
        <div className="flex items-center gap-3 min-w-0">
          <button onClick={onClose} className="inline-flex items-center gap-1 rounded-lg bg-white/10 px-2.5 py-1 text-xs cursor-pointer"><ChevronLeft size={14} /> Library</button>
          <span className="truncate text-sm font-medium">{item.name}</span>
        </div>
        <div className="flex items-center gap-2">
          <button onClick={() => setZoom((z) => Math.max(0.25, z - 0.25))} className="rounded bg-white/10 p-1.5 cursor-pointer"><ZoomOut size={14} /></button>
          <span className="font-mono text-xs">{Math.round(zoom * 100)}%</span>
          <button onClick={() => setZoom((z) => Math.min(4, z + 0.25))} className="rounded bg-white/10 p-1.5 cursor-pointer"><ZoomIn size={14} /></button>
          <button onClick={() => setRot((r) => (r + 90) % 360)} className="rounded bg-white/10 p-1.5 cursor-pointer"><RotateCw size={14} /></button>
          <button onClick={() => onShare(item)} className="rounded bg-white/10 px-2.5 py-1 text-xs inline-flex items-center gap-1 cursor-pointer"><Share2 size={13} /> Share</button>
        </div>
      </div>
      <div className="flex flex-1 items-center justify-center overflow-auto p-6">
        <img src={src} alt={item.name} style={{ transform: `scale(${zoom}) rotate(${rot}deg)` }} className="max-h-full max-w-full rounded-lg transition-transform" />
      </div>
    </div>
  );
}

export function PDFReaderView({ item, onShare, onClose }: { item: MediaItem; onShare: (i: MediaItem) => void; onClose: () => void }) {
  const src = window.chronoAPI ? window.chronoAPI.mediaUrl(item.path) : item.path;
  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center justify-between border-b px-4 py-2.5" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
        <div className="flex items-center gap-3 min-w-0">
          <button onClick={onClose} className="inline-flex items-center gap-1 rounded-lg border px-2.5 py-1 text-xs cursor-pointer" style={{ borderColor: "var(--cs-border)" }}><ChevronLeft size={14} /> Library</button>
          <span className="truncate text-sm font-semibold">{item.name}</span>
        </div>
        <button onClick={() => onShare(item)} className="inline-flex items-center gap-1 rounded-lg border px-2.5 py-1 text-xs cursor-pointer" style={{ borderColor: "var(--cs-border)" }}><Share2 size={13} /> Share</button>
      </div>
      <iframe src={src} title={item.name} className="h-full w-full flex-1 border-0 bg-white" />
    </div>
  );
}

export function PhotoStudioView({ photos }: { photos: MediaItem[] }) {
  const [selected, setSelected] = useState<MediaItem | null>(photos[0] || null);
  const [brightness, setBrightness] = useState(100);
  const [contrast, setContrast] = useState(100);
  const [saturate, setSaturate] = useState(100);
  const [overlayText, setOverlayText] = useState("");
  const imgRef = useRef<HTMLImageElement>(null);

  const exportPNG = () => {
    const img = imgRef.current;
    if (!img) return;
    const canvas = document.createElement("canvas");
    canvas.width = img.naturalWidth || 1200;
    canvas.height = img.naturalHeight || 800;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.filter = `brightness(${brightness}%) contrast(${contrast}%) saturate(${saturate}%)`;
    ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
    if (overlayText.trim()) {
      ctx.filter = "none";
      ctx.font = `bold ${Math.max(32, canvas.width / 18)}px sans-serif`;
      ctx.fillStyle = "#FFFFFF";
      ctx.textAlign = "center";
      ctx.shadowColor = "rgba(0,0,0,0.6)";
      ctx.shadowBlur = 10;
      ctx.fillText(overlayText, canvas.width / 2, canvas.height - 60);
    }
    const a = document.createElement("a");
    a.href = canvas.toDataURL("image/png");
    a.download = `${selected?.name.replace(/\.[^.]+$/, "") || "edited"}-studio.png`;
    a.click();
  };

  return (
    <div className="flex h-full overflow-hidden">
      <div className="w-64 border-r p-3 overflow-y-auto space-y-2" style={{ borderColor: "var(--cs-border)", background: "var(--cs-sidebar)" }}>
        <div className="flex items-center gap-1.5 text-xs font-semibold"><Wand2 size={14} style={{ color: "var(--cs-accent)" }} /> Photo Studio ({photos.length})</div>
        {photos.length === 0 ? (
          <p className="text-xs pt-4" style={{ color: "var(--cs-text-tertiary)" }}>Add a folder with photos to edit them here.</p>
        ) : (
          photos.map((p) => (
            <button key={p.id} onClick={() => setSelected(p)} className="w-full rounded-lg px-2.5 py-2 text-left text-xs truncate cursor-pointer" style={{ background: selected?.id === p.id ? "var(--cs-accent-soft)" : "var(--cs-surface)" }}>
              {p.name}
            </button>
          ))
        )}
      </div>

      <div className="flex flex-1 flex-col">
        <div className="flex flex-1 items-center justify-center overflow-hidden p-6" style={{ background: "var(--cs-canvas)" }}>
          {selected ? (
            <div className="relative">
              <img
                ref={imgRef}
                crossOrigin="anonymous"
                src={window.chronoAPI ? window.chronoAPI.mediaUrl(selected.path) : selected.path}
                alt={selected.name}
                style={{ filter: `brightness(${brightness}%) contrast(${contrast}%) saturate(${saturate}%)` }}
                className="max-h-[60vh] max-w-full rounded-xl shadow-lg"
              />
              {overlayText && (
                <div className="pointer-events-none absolute inset-x-0 bottom-6 text-center text-2xl font-bold text-white drop-shadow-lg">
                  {overlayText}
                </div>
              )}
            </div>
          ) : (
            <p className="text-sm" style={{ color: "var(--cs-text-secondary)" }}>Select a photo to begin editing</p>
          )}
        </div>

        <div className="flex flex-wrap items-center justify-between gap-4 border-t px-5 py-3 text-xs" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
          <div className="flex flex-wrap items-center gap-4">
            <label className="flex items-center gap-2">Brightness <input type="range" min={50} max={150} value={brightness} onChange={(e) => setBrightness(Number(e.target.value))} className="w-24 accent-teal-600" /></label>
            <label className="flex items-center gap-2">Contrast <input type="range" min={50} max={150} value={contrast} onChange={(e) => setContrast(Number(e.target.value))} className="w-24 accent-teal-600" /></label>
            <label className="flex items-center gap-2">Saturation <input type="range" min={0} max={200} value={saturate} onChange={(e) => setSaturate(Number(e.target.value))} className="w-24 accent-teal-600" /></label>
            <input value={overlayText} onChange={(e) => setOverlayText(e.target.value)} placeholder="Add text layer…" className="rounded-lg border px-2.5 py-1 outline-none" style={{ borderColor: "var(--cs-border)" }} />
          </div>
          <button disabled={!selected} onClick={exportPNG} className="inline-flex items-center gap-1.5 rounded-lg px-3.5 py-1.5 font-medium text-white disabled:opacity-40 cursor-pointer" style={{ background: "var(--cs-accent)" }}>
            <Download size={13} /> Export PNG
          </button>
        </div>
      </div>
    </div>
  );
}

export function VideoStudioView({ videos }: { videos: MediaItem[] }) {
  const [selected, setSelected] = useState<MediaItem | null>(videos[0] || null);
  const [second, setSecond] = useState<MediaItem | null>(videos[1] || null);
  const [op, setOp] = useState<"trim" | "transform" | "merge" | "extractAudio">("trim");
  const [startSec, setStartSec] = useState(0);
  const [durationSec, setDurationSec] = useState(30);
  const [speed, setSpeed] = useState(1);
  const [mute, setMute] = useState(false);
  const [busy, setBusy] = useState(false);
  const [resultMsg, setResultMsg] = useState<string | null>(null);

  const run = async () => {
    if (!selected || !window.chronoAPI) return;
    setBusy(true);
    setResultMsg(null);
    const res = await window.chronoAPI.runVideoStudioOp({
      op,
      inputPath: selected.path,
      secondInputPath: second?.path,
      startSec,
      durationSec,
      speed,
      mute
    });
    setBusy(false);
    if (res.canceled) return;
    setResultMsg(res.ok ? `Exported cleanly to ${res.outputPath}` : `FFmpeg error: ${res.error || "Ensure FFmpeg is in PATH."}`);
  };

  return (
    <div className="h-full overflow-y-auto p-6 space-y-5">
      <div className="flex items-center gap-2.5">
        <div className="flex h-8 w-8 items-center justify-center rounded-lg" style={{ background: "var(--cs-accent-soft)", color: "var(--cs-accent)" }}>
          <Scissors size={16} />
        </div>
        <div>
          <h2 className="text-base font-bold">Video Studio</h2>
          <p className="text-xs" style={{ color: "var(--cs-text-secondary)" }}>FFmpeg-powered local Trim, Speed/Mute, Merge &amp; Audio Extraction</p>
        </div>
      </div>

      <div className="cs-card rounded-2xl p-5 space-y-4 max-w-2xl">
        <div className="space-y-1.5">
          <label className="text-xs font-semibold">Source Video</label>
          <select value={selected?.id || ""} onChange={(e) => setSelected(videos.find((v) => v.id === e.target.value) || null)} className="w-full rounded-lg border px-3 py-2 text-sm" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
            <option value="">Choose a video from your library…</option>
            {videos.map((v) => <option key={v.id} value={v.id}>{v.name} ({formatBytes(v.fileSize)})</option>)}
          </select>
        </div>

        <div className="inline-flex rounded-lg p-1 text-xs" style={{ background: "var(--cs-surface-subtle)" }}>
          {([["trim", "Trim"], ["transform", "Speed / Mute"], ["merge", "Merge Two"], ["extractAudio", "Extract Audio"]] as const).map(([k, label]) => (
            <button key={k} onClick={() => setOp(k)} className="rounded-md px-3 py-1.5 font-medium cursor-pointer" style={{ background: op === k ? "var(--cs-surface)" : "transparent" }}>
              {label}
            </button>
          ))}
        </div>

        {op === "trim" && (
          <div className="grid grid-cols-2 gap-3 text-xs">
            <label className="space-y-1">Start (seconds)<input type="number" min={0} value={startSec} onChange={(e) => setStartSec(Number(e.target.value))} className="w-full rounded-lg border px-2.5 py-1.5" style={{ borderColor: "var(--cs-border)" }} /></label>
            <label className="space-y-1">Duration (seconds)<input type="number" min={1} value={durationSec} onChange={(e) => setDurationSec(Number(e.target.value))} className="w-full rounded-lg border px-2.5 py-1.5" style={{ borderColor: "var(--cs-border)" }} /></label>
          </div>
        )}

        {op === "transform" && (
          <div className="flex items-center gap-6 text-xs">
            <label className="flex items-center gap-2">Speed
              <select value={speed} onChange={(e) => setSpeed(Number(e.target.value))} className="rounded border px-2 py-1" style={{ borderColor: "var(--cs-border)" }}>
                {[0.5, 1, 1.5, 2].map((s) => <option key={s} value={s}>{s}×</option>)}
              </select>
            </label>
            <label className="flex items-center gap-2"><input type="checkbox" checked={mute} onChange={(e) => setMute(e.target.checked)} /> Mute Audio</label>
          </div>
        )}

        {op === "merge" && (
          <div className="space-y-1.5">
            <label className="text-xs font-semibold">Second Video</label>
            <select value={second?.id || ""} onChange={(e) => setSecond(videos.find((v) => v.id === e.target.value) || null)} className="w-full rounded-lg border px-3 py-2 text-sm" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
              <option value="">Choose second video…</option>
              {videos.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}
            </select>
          </div>
        )}

        <button disabled={!selected || busy} onClick={run} className="inline-flex items-center gap-2 rounded-lg px-4 py-2 text-sm font-medium text-white disabled:opacity-40 cursor-pointer" style={{ background: "var(--cs-accent)" }}>
          <Film size={15} /> {busy ? "Processing with FFmpeg…" : "Export Video"}
        </button>

        {resultMsg && <div className="rounded-lg p-3 text-xs" style={{ background: "var(--cs-surface-subtle)" }}>{resultMsg}</div>}
      </div>
    </div>
  );
}
