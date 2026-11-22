import React, { useEffect, useRef, useState } from "react";
import {
  ChevronLeft, Play, Pause, RotateCcw, RotateCw, Volume2, VolumeX,
  Maximize, Tv, Keyboard, Share2, Subtitles
} from "lucide-react";
import { MediaItem, formatTime } from "../types";

interface Props {
  item: MediaItem;
  hasExternalDisplay: boolean;
  onClose: () => void;
  onShare: (item: MediaItem) => void;
  onProgress: (id: string, pos: number, dur: number, isPlaying: boolean) => void;
}

const SPEEDS = [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4];
const ZOOMS = [0, 3600, 900, 120];

export default function VideoStageView({ item, hasExternalDisplay, onClose, onShare, onProgress }: Props) {
  const videoRef = useRef<HTMLVideoElement>(null);
  const previewVideoRef = useRef<HTMLVideoElement>(null);
  const previewCanvasRef = useRef<HTMLCanvasElement>(null);
  const containerRef = useRef<HTMLDivElement>(null);

  const [playbackUrl, setPlaybackUrl] = useState<string>("");
  const [statusMsg, setStatusMsg] = useState<string | null>("Loading video…");
  const [errorMsg, setErrorMsg] = useState<string | null>(null);
  const [isPlaying, setIsPlaying] = useState(false);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);
  const [volume, setVolume] = useState(1);
  const [muted, setMuted] = useState(false);
  const [speed, setSpeed] = useState(1);
  const [zoomWindow, setZoomWindow] = useState(0);
  const [cinemaActive, setCinemaActive] = useState(false);
  const [showShortcuts, setShowShortcuts] = useState(false);
  const [osd, setOsd] = useState<string | null>(null);
  const [hoverInfo, setHoverInfo] = useState<{ x: number; time: number } | null>(null);

  const osdTimer = useRef<number | null>(null);
  const flashOSD = (text: string) => {
    setOsd(text);
    if (osdTimer.current) window.clearTimeout(osdTimer.current);
    osdTimer.current = window.setTimeout(() => setOsd(null), 900);
  };

  useEffect(() => {
    let active = true;
    setErrorMsg(null);
    setStatusMsg("Preparing playback…");
    (async () => {
      if (window.chronoAPI) {
        const prep = await window.chronoAPI.prepareVideoPlayback(item.path);
        if (!active) return;
        if (prep.error) setErrorMsg(prep.error);
        setPlaybackUrl(window.chronoAPI.mediaUrl(prep.path));
        setStatusMsg(null);
      } else {
        setPlaybackUrl(item.path);
        setStatusMsg(null);
      }
    })();
    return () => {
      active = false;
      window.chronoAPI?.stopCinema();
    };
  }, [item.path]);

  const togglePlay = () => {
    const v = videoRef.current;
    if (!v) return;
    if (v.paused) { v.play(); flashOSD("Play"); } else { v.pause(); flashOSD("Paused"); }
  };

  const seekBy = (delta: number) => {
    const v = videoRef.current;
    if (!v) return;
    v.currentTime = Math.max(0, Math.min(v.duration || 0, v.currentTime + delta));
    flashOSD(delta > 0 ? `+${delta}s` : `${delta}s`);
  };

  // Full Video Keyboard Shortcuts (exact parity with macOS)
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.target as HTMLElement)?.tagName === "INPUT" || (e.target as HTMLElement)?.tagName === "TEXTAREA") return;
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      const v = videoRef.current;
      if (!v) return;

      switch (e.key) {
        case " ":
        case "k":
        case "K":
          e.preventDefault(); togglePlay(); break;
        case "ArrowLeft":
          e.preventDefault(); seekBy(e.shiftKey ? -30 : -5); break;
        case "ArrowRight":
          e.preventDefault(); seekBy(e.shiftKey ? 30 : 5); break;
        case "j":
        case "J":
          seekBy(-10); break;
        case "l":
        case "L":
          seekBy(10); break;
        case ",":
          v.pause(); v.currentTime = Math.max(0, v.currentTime - 1 / 30); flashOSD("Frame -1"); break;
        case ".":
          v.pause(); v.currentTime = Math.min(v.duration || 0, v.currentTime + 1 / 30); flashOSD("Frame +1"); break;
        case "[":
        case "<": {
          const idx = Math.max(0, SPEEDS.indexOf(speed) - 1);
          const next = SPEEDS[idx]; setSpeed(next); v.playbackRate = next; flashOSD(`Speed ${next}×`); break;
        }
        case "]":
        case ">": {
          const idx = Math.min(SPEEDS.length - 1, SPEEDS.indexOf(speed) + 1);
          const next = SPEEDS[idx]; setSpeed(next); v.playbackRate = next; flashOSD(`Speed ${next}×`); break;
        }
        case "\\":
        case "Backspace":
          setSpeed(1); v.playbackRate = 1; flashOSD("Speed 1×"); break;
        case "ArrowUp": {
          e.preventDefault();
          const nv = Math.min(1, volume + 0.1); setVolume(nv); setMuted(false); v.volume = nv; v.muted = false;
          flashOSD(`Volume ${Math.round(nv * 100)}%`); break;
        }
        case "ArrowDown": {
          e.preventDefault();
          const nv = Math.max(0, volume - 0.1); setVolume(nv); setMuted(nv === 0); v.volume = nv; v.muted = nv === 0;
          flashOSD(nv === 0 ? "Muted" : `Volume ${Math.round(nv * 100)}%`); break;
        }
        case "m":
        case "M":
          v.muted = !v.muted; setMuted(v.muted); flashOSD(v.muted ? "Muted" : "Unmuted"); break;
        case "f":
        case "F":
          if (document.fullscreenElement) document.exitFullscreen(); else containerRef.current?.requestFullscreen();
          break;
        case "z":
        case "Z": {
          const nextZ = ZOOMS[(ZOOMS.indexOf(zoomWindow) + 1) % ZOOMS.length];
          setZoomWindow(nextZ);
          flashOSD(nextZ === 0 ? "Full Timeline" : nextZ >= 3600 ? "1 hr Window" : `${nextZ / 60}m Window`);
          break;
        }
        case "?":
          setShowShortcuts((s) => !s); break;
        case "Escape":
          if (showShortcuts) setShowShortcuts(false);
          else if (document.fullscreenElement) document.exitFullscreen();
          else onClose();
          break;
        default:
          if (/^[0-9]$/.test(e.key) && v.duration) {
            const pct = Number(e.key) / 10;
            v.currentTime = v.duration * pct;
            flashOSD(`${Number(e.key) * 10}%`);
          }
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [speed, volume, zoomWindow, showShortcuts]);

  // Real-time hover frame preview via hidden warm video element
  const updateHoverPreview = (e: React.MouseEvent<HTMLDivElement>) => {
    const rect = e.currentTarget.getBoundingClientRect();
    const ratio = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
    const t = ratio * (duration || 0);
    setHoverInfo({ x: e.clientX - rect.left, time: t });
    const pv = previewVideoRef.current;
    if (pv && pv.readyState >= 1) {
      pv.currentTime = t;
    }
  };

  const drawPreviewFrame = () => {
    const pv = previewVideoRef.current;
    const cv = previewCanvasRef.current;
    if (!pv || !cv) return;
    const ctx = cv.getContext("2d");
    if (ctx) ctx.drawImage(pv, 0, 0, cv.width, cv.height);
  };

  const toggleCinema = async () => {
    if (!window.chronoAPI) return;
    if (cinemaActive) {
      await window.chronoAPI.stopCinema();
      setCinemaActive(false);
      flashOSD("HDMI Cinema Off");
    } else {
      const ok = await window.chronoAPI.startCinema(playbackUrl);
      if (ok) { setCinemaActive(true); flashOSD("Playing on External HDMI"); }
    }
  };

  return (
    <div ref={containerRef} className="relative flex h-full w-full flex-col bg-black text-white">
      {/* Hidden warm preview decoder */}
      {playbackUrl && (
        <video
          ref={previewVideoRef}
          src={playbackUrl}
          muted
          preload="metadata"
          onSeeked={drawPreviewFrame}
          className="hidden"
        />
      )}

      {/* Top HUD */}
      <div className="absolute inset-x-0 top-0 z-20 flex items-center justify-between bg-gradient-to-b from-black/80 to-transparent px-4 py-3">
        <div className="flex items-center gap-3 min-w-0">
          <button onClick={onClose} className="inline-flex items-center gap-1 rounded-lg bg-white/15 px-2.5 py-1 text-xs font-medium hover:bg-white/25 cursor-pointer">
            <ChevronLeft size={14} /> Library
          </button>
          <span className="truncate text-sm font-semibold">{item.name}</span>
        </div>

        <div className="flex items-center gap-2">
          <button onClick={() => onShare(item)} className="inline-flex items-center gap-1 rounded-lg bg-white/15 px-2.5 py-1 text-xs font-medium hover:bg-white/25 cursor-pointer">
            <Share2 size={13} /> Share
          </button>
          {hasExternalDisplay && (
            <button onClick={toggleCinema} className={`inline-flex items-center gap-1 rounded-lg px-2.5 py-1 text-xs font-medium cursor-pointer ${cinemaActive ? "bg-teal-600" : "bg-white/15 hover:bg-white/25"}`}>
              <Tv size={13} /> {cinemaActive ? "HDMI On" : "HDMI Cinema"}
            </button>
          )}
          <button onClick={() => setShowShortcuts((s) => !s)} className="rounded-lg bg-white/15 p-1.5 hover:bg-white/25 cursor-pointer" title="Keyboard Shortcuts (?)">
            <Keyboard size={14} />
          </button>
          <button onClick={() => document.fullscreenElement ? document.exitFullscreen() : containerRef.current?.requestFullscreen()} className="rounded-lg bg-white/15 p-1.5 hover:bg-white/25 cursor-pointer" title="Full Screen (F)">
            <Maximize size={14} />
          </button>
        </div>
      </div>

      {/* Main Video Surface */}
      <div className="relative flex flex-1 items-center justify-center overflow-hidden" onClick={togglePlay}>
        {playbackUrl && (
          <video
            ref={videoRef}
            src={playbackUrl}
            autoPlay
            className="h-full w-full object-contain"
            onLoadedMetadata={(e) => {
              const v = e.currentTarget;
              setDuration(v.duration || 0);
              if (item.lastPosition && item.lastPosition > 5 && item.lastPosition < (v.duration || 0) - 5) {
                v.currentTime = item.lastPosition;
              }
            }}
            onPlay={() => { setIsPlaying(true); onProgress(item.id, currentTime, duration, true); }}
            onPause={() => { setIsPlaying(false); onProgress(item.id, currentTime, duration, false); }}
            onTimeUpdate={(e) => {
              const v = e.currentTarget;
              setCurrentTime(v.currentTime);
              onProgress(item.id, v.currentTime, v.duration || duration, !v.paused);
            }}
          />
        )}

        {statusMsg && <div className="rounded-xl bg-black/75 px-5 py-3 text-sm">{statusMsg}</div>}
        {errorMsg && <div className="rounded-xl bg-red-950/90 border border-red-500/40 px-5 py-3 text-sm max-w-md text-center">{errorMsg}</div>}

        {osd && (
          <div className="pointer-events-none absolute rounded-full border border-white/15 bg-black/80 px-4 py-2 text-sm font-semibold">
            {osd}
          </div>
        )}

        {showShortcuts && (
          <div onClick={(e) => e.stopPropagation()} className="absolute right-4 top-14 z-30 w-72 rounded-2xl border border-white/15 bg-zinc-900/95 p-4 text-xs shadow-2xl">
            <div className="mb-2 font-semibold text-sm">Video Keyboard Shortcuts</div>
            <div className="grid grid-cols-2 gap-y-1.5 text-white/80">
              <span className="font-mono text-teal-400">Space / K</span><span>Play / Pause</span>
              <span className="font-mono text-teal-400">← / →</span><span>Seek -5s / +5s</span>
              <span className="font-mono text-teal-400">⇧← / ⇧→</span><span>Seek -30s / +30s</span>
              <span className="font-mono text-teal-400">J / L</span><span>Seek -10s / +10s</span>
              <span className="font-mono text-teal-400">, / .</span><span>Prev / Next Frame</span>
              <span className="font-mono text-teal-400">0 – 9</span><span>Jump 0% – 90%</span>
              <span className="font-mono text-teal-400">[ / ]</span><span>Speed - / +</span>
              <span className="font-mono text-teal-400">↑ / ↓ / M</span><span>Volume / Mute</span>
              <span className="font-mono text-teal-400">F / Z / Esc</span><span>Full / Zoom / Back</span>
            </div>
          </div>
        )}
      </div>

      {/* Bottom Controls Card */}
      <div className="z-20 mx-4 mb-4 rounded-2xl border border-white/15 bg-zinc-900/85 px-4 py-3 backdrop-blur-md space-y-2">
        {/* Precision Zoom Bar */}
        {zoomWindow > 0 && duration > zoomWindow && (
          <div className="space-y-1">
            <div className="flex justify-between text-[11px] text-white/60">
              <span>Precision Window ({zoomWindow >= 3600 ? "1 hr" : `${zoomWindow / 60}m`})</span>
              <span className="font-mono">
                {formatTime(Math.max(0, currentTime - zoomWindow / 2))} – {formatTime(Math.min(duration, currentTime + zoomWindow / 2))}
              </span>
            </div>
            <div
              className="relative h-2 cursor-pointer rounded-full bg-white/15"
              onClick={(e) => {
                const start = Math.max(0, Math.min(duration - zoomWindow, currentTime - zoomWindow / 2));
                const rect = e.currentTarget.getBoundingClientRect();
                const r = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
                if (videoRef.current) videoRef.current.currentTime = start + r * zoomWindow;
              }}
            >
              <div className="h-full rounded-full bg-teal-400" style={{ width: "50%" }} />
            </div>
          </div>
        )}

        {/* Main Scrubber with Hover Frame Preview */}
        <div
          className="relative flex h-4 cursor-pointer items-center"
          onMouseMove={updateHoverPreview}
          onMouseLeave={() => setHoverInfo(null)}
          onClick={(e) => {
            const rect = e.currentTarget.getBoundingClientRect();
            const r = Math.max(0, Math.min(1, (e.clientX - rect.left) / rect.width));
            if (videoRef.current) videoRef.current.currentTime = r * (duration || 0);
          }}
        >
          {hoverInfo && (
            <div
              className="pointer-events-none absolute -top-32 flex flex-col items-center rounded-lg bg-black/90 p-1.5 shadow-xl border border-white/15"
              style={{ left: Math.max(88, Math.min(hoverInfo.x, 760)), transform: "translateX(-50%)" }}
            >
              <canvas ref={previewCanvasRef} width={160} height={90} className="rounded bg-zinc-900" />
              <span className="mt-1 font-mono text-[11px] font-semibold">{formatTime(hoverInfo.time)}</span>
            </div>
          )}
          <div className="h-1.5 w-full rounded-full bg-white/20">
            <div className="h-full rounded-full bg-teal-400" style={{ width: `${duration ? (currentTime / duration) * 100 : 0}%` }} />
          </div>
        </div>

        {/* Transport Row */}
        <div className="flex items-center justify-between text-xs">
          <div className="flex items-center gap-3">
            <button onClick={togglePlay} className="cursor-pointer hover:text-teal-400">
              {isPlaying ? <Pause size={18} /> : <Play size={18} />}
            </button>
            <button onClick={() => seekBy(-10)} className="cursor-pointer hover:text-teal-400" title="-10s (J)"><RotateCcw size={15} /></button>
            <button onClick={() => seekBy(10)} className="cursor-pointer hover:text-teal-400" title="+10s (L)"><RotateCw size={15} /></button>
            <span className="font-mono text-white/75">{formatTime(currentTime)} / {formatTime(duration)}</span>
          </div>

          <div className="flex items-center gap-3">
            <select
              value={zoomWindow}
              onChange={(e) => setZoomWindow(Number(e.target.value))}
              className="rounded bg-white/10 px-2 py-1 text-xs outline-none"
            >
              <option value={0} className="text-black">Full</option>
              <option value={3600} className="text-black">1 hr</option>
              <option value={900} className="text-black">15m</option>
              <option value={120} className="text-black">2m</option>
            </select>

            <select
              value={speed}
              onChange={(e) => {
                const s = Number(e.target.value);
                setSpeed(s);
                if (videoRef.current) videoRef.current.playbackRate = s;
              }}
              className="rounded bg-white/10 px-2 py-1 text-xs outline-none"
            >
              {SPEEDS.map((s) => <option key={s} value={s} className="text-black">{s}×</option>)}
            </select>

            <div className="flex items-center gap-1.5">
              <button onClick={() => { if (videoRef.current) { videoRef.current.muted = !muted; setMuted(!muted); } }} className="cursor-pointer">
                {muted || volume === 0 ? <VolumeX size={15} /> : <Volume2 size={15} />}
              </button>
              <input
                type="range" min={0} max={1} step={0.05}
                value={muted ? 0 : volume}
                onChange={(e) => {
                  const v = Number(e.target.value);
                  setVolume(v); setMuted(v === 0);
                  if (videoRef.current) { videoRef.current.volume = v; videoRef.current.muted = v === 0; }
                }}
                className="w-20 accent-teal-400"
              />
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
