import React, { useEffect, useRef, useState } from "react";
import {
  ChevronLeft, Play, Pause, SkipBack, SkipForward, Repeat, Repeat1,
  Shuffle, Volume2, VolumeX, Moon, Share2, Search, Music
} from "lucide-react";
import { MediaItem, formatBytes, formatTime } from "../types";

interface Props {
  item: MediaItem;
  queue: MediaItem[];
  onSelectTrack: (item: MediaItem) => void;
  onShare: (item: MediaItem) => void;
  onClose: () => void;
  onPlaybackState: (isPlaying: boolean) => void;
}

export default function AudioStageView({ item, queue, onSelectTrack, onShare, onClose, onPlaybackState }: Props) {
  const audioRef = useRef<HTMLAudioElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);

  const [isPlaying, setIsPlaying] = useState(false);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);
  const [volume, setVolume] = useState(1);
  const [muted, setMuted] = useState(false);
  const [speed, setSpeed] = useState(1);
  const [repeatMode, setRepeatMode] = useState<"off" | "all" | "one">("off");
  const [shuffled, setShuffled] = useState(false);
  const [sleepSec, setSleepSec] = useState<number | null>(null);
  const [queueFilter, setQueueFilter] = useState("");

  const src = window.chronoAPI ? window.chronoAPI.mediaUrl(item.path) : item.path;

  // 28-bar smooth spectrum visualizer
  useEffect(() => {
    let raf = 0;
    const draw = (now: number) => {
      const c = canvasRef.current;
      if (c) {
        const ctx = c.getContext("2d");
        if (ctx) {
          ctx.clearRect(0, 0, c.width, c.height);
          const bars = 28;
          const gap = 4;
          const w = (c.width - (bars - 1) * gap) / bars;
          const t = now / 1000;
          for (let i = 0; i < bars; i++) {
            const bell = Math.sin((i / (bars - 1)) * Math.PI);
            const amp = isPlaying ? (0.25 + 0.75 * Math.abs(Math.sin(t * 3.4 + i * 0.55) * Math.cos(t * 1.9 - i * 0.3))) * bell : 0.14;
            const h = Math.max(3, amp * c.height);
            const x = i * (w + gap);
            const y = (c.height - h) / 2;
            ctx.fillStyle = isPlaying ? `rgba(0, 122, 255, ${0.55 + 0.45 * bell})` : "rgba(148,163,184,0.3)";
            ctx.beginPath();
            ctx.roundRect(x, y, w, h, w / 2);
            ctx.fill();
          }
        }
      }
      raf = requestAnimationFrame(draw);
    };
    raf = requestAnimationFrame(draw);
    return () => cancelAnimationFrame(raf);
  }, [isPlaying]);

  // Sleep timer countdown
  useEffect(() => {
    if (sleepSec === null) return;
    if (sleepSec <= 0) {
      audioRef.current?.pause();
      setSleepSec(null);
      return;
    }
    const id = window.setTimeout(() => setSleepSec((s) => (s !== null ? s - 1 : null)), 1000);
    return () => window.clearTimeout(id);
  }, [sleepSec]);

  const playNext = () => {
    if (!queue.length) return;
    if (shuffled) {
      const next = queue[Math.floor(Math.random() * queue.length)];
      onSelectTrack(next);
      return;
    }
    const idx = queue.findIndex((q) => q.id === item.id);
    if (idx >= 0 && idx + 1 < queue.length) onSelectTrack(queue[idx + 1]);
    else if (repeatMode === "all") onSelectTrack(queue[0]);
  };

  const playPrev = () => {
    const idx = queue.findIndex((q) => q.id === item.id);
    if (idx > 0) onSelectTrack(queue[idx - 1]);
  };

  const filteredQueue = queue.filter((q) => q.name.toLowerCase().includes(queueFilter.toLowerCase()));

  return (
    <div className="flex h-full flex-col">
      <audio
        ref={audioRef}
        src={src}
        autoPlay
        onPlay={() => { setIsPlaying(true); onPlaybackState(true); }}
        onPause={() => { setIsPlaying(false); onPlaybackState(false); }}
        onLoadedMetadata={(e) => setDuration(e.currentTarget.duration || 0)}
        onTimeUpdate={(e) => setCurrentTime(e.currentTarget.currentTime)}
        onEnded={() => {
          if (repeatMode === "one" && audioRef.current) {
            audioRef.current.currentTime = 0;
            audioRef.current.play();
          } else {
            playNext();
          }
        }}
      />

      {/* Top Bar */}
      <div className="flex items-center justify-between border-b px-4 py-2.5" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
        <button onClick={onClose} className="inline-flex items-center gap-1 rounded-lg border px-2.5 py-1 text-xs font-medium cursor-pointer" style={{ borderColor: "var(--cs-border)" }}>
          <ChevronLeft size={14} /> Library
        </button>

        <div className="flex items-center gap-2 text-xs font-medium" style={{ color: "var(--cs-text-secondary)" }}>
          <span className={`h-2 w-2 rounded-full ${isPlaying ? "bg-emerald-500" : "bg-slate-400"}`} />
          {isPlaying ? "Now Playing" : "Paused"}
        </div>

        <div className="flex items-center gap-3">
          <select
            value={sleepSec ? Math.ceil(sleepSec / 60) : 0}
            onChange={(e) => {
              const m = Number(e.target.value);
              setSleepSec(m > 0 ? m * 60 : null);
            }}
            className="rounded-lg border px-2 py-1 text-xs outline-none"
            style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}
          >
            <option value={0}>Sleep: Off</option>
            <option value={15}>Sleep: 15m</option>
            <option value={30}>Sleep: 30m</option>
            <option value={60}>Sleep: 60m</option>
          </select>
          {sleepSec !== null && <span className="font-mono text-xs" style={{ color: "var(--cs-accent)" }}><Moon size={12} className="inline mr-1" />{formatTime(sleepSec)}</span>}
          <button onClick={() => onShare(item)} className="cursor-pointer opacity-75 hover:opacity-100" title="Share">
            <Share2 size={15} />
          </button>
        </div>
      </div>

      {/* Two-Column Studio Stage */}
      <div className="flex flex-1 overflow-hidden">
        <div className="flex flex-1 flex-col items-center justify-center p-8 space-y-5 overflow-y-auto">
          <div
            className="flex h-48 w-48 items-center justify-center rounded-3xl shadow-xl transition-transform duration-300"
            style={{
              background: "linear-gradient(135deg, #008080, #2563EB)",
              transform: isPlaying ? "scale(1)" : "scale(0.94)"
            }}
          >
            <Music size={64} className="text-white/90" />
          </div>

          <div className="text-center max-w-md">
            <h2 className="text-xl font-bold truncate">{item.name}</h2>
            <p className="text-xs mt-1 font-mono" style={{ color: "var(--cs-text-tertiary)" }}>
              {item.ext} · {formatBytes(item.fileSize)}
            </p>
          </div>

          <canvas ref={canvasRef} width={280} height={30} />

          {/* Scrubber */}
          <div className="w-full max-w-md space-y-1">
            <input
              type="range" min={0} max={duration || 1} step={0.1}
              value={currentTime}
              onChange={(e) => {
                const t = Number(e.target.value);
                setCurrentTime(t);
                if (audioRef.current) audioRef.current.currentTime = t;
              }}
              className="w-full accent-teal-600"
            />
            <div className="flex justify-between font-mono text-xs" style={{ color: "var(--cs-text-secondary)" }}>
              <span>{formatTime(currentTime)}</span>
              <span>-{formatTime(Math.max(0, duration - currentTime))}</span>
            </div>
          </div>

          {/* Controls */}
          <div className="flex items-center gap-6">
            <button onClick={() => setShuffled((s) => !s)} className="cursor-pointer" style={{ color: shuffled ? "var(--cs-accent)" : "var(--cs-text-secondary)" }}><Shuffle size={17} /></button>
            <button onClick={playPrev} className="cursor-pointer"><SkipBack size={20} /></button>
            <button
              onClick={() => { if (audioRef.current) { isPlaying ? audioRef.current.pause() : audioRef.current.play(); } }}
              className="flex h-12 w-12 items-center justify-center rounded-full text-white shadow-md cursor-pointer"
              style={{ background: "var(--cs-accent)" }}
            >
              {isPlaying ? <Pause size={22} /> : <Play size={22} className="ml-0.5" />}
            </button>
            <button onClick={playNext} className="cursor-pointer"><SkipForward size={20} /></button>
            <button
              onClick={() => setRepeatMode((m) => (m === "off" ? "all" : m === "all" ? "one" : "off"))}
              className="cursor-pointer"
              style={{ color: repeatMode !== "off" ? "var(--cs-accent)" : "var(--cs-text-secondary)" }}
            >
              {repeatMode === "one" ? <Repeat1 size={17} /> : <Repeat size={17} />}
            </button>
          </div>

          <div className="flex items-center gap-4 text-xs">
            <select
              value={speed}
              onChange={(e) => { const s = Number(e.target.value); setSpeed(s); if (audioRef.current) audioRef.current.playbackRate = s; }}
              className="rounded-lg border px-2 py-1"
              style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}
            >
              {[0.75, 1, 1.25, 1.5, 2].map((s) => <option key={s} value={s}>{s}×</option>)}
            </select>
            <div className="flex items-center gap-1.5">
              <button onClick={() => { setMuted(!muted); if (audioRef.current) audioRef.current.muted = !muted; }} className="cursor-pointer">
                {muted || volume === 0 ? <VolumeX size={15} /> : <Volume2 size={15} />}
              </button>
              <input
                type="range" min={0} max={1} step={0.05}
                value={muted ? 0 : volume}
                onChange={(e) => { const v = Number(e.target.value); setVolume(v); setMuted(v === 0); if (audioRef.current) { audioRef.current.volume = v; audioRef.current.muted = v === 0; } }}
                className="w-24 accent-teal-600"
              />
            </div>
          </div>
        </div>

        {/* Up Next Queue */}
        <div className="flex w-72 flex-col border-l" style={{ borderColor: "var(--cs-border)", background: "var(--cs-sidebar)" }}>
          <div className="border-b p-3 space-y-2" style={{ borderColor: "var(--cs-border)" }}>
            <div className="text-xs font-semibold">Up Next ({filteredQueue.length})</div>
            <div className="flex items-center gap-1.5 rounded-lg border px-2 py-1 text-xs" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
              <Search size={12} style={{ color: "var(--cs-text-tertiary)" }} />
              <input value={queueFilter} onChange={(e) => setQueueFilter(e.target.value)} placeholder="Filter queue…" className="w-full bg-transparent outline-none" />
            </div>
          </div>
          <div className="flex-1 overflow-y-auto p-2 space-y-1">
            {filteredQueue.map((track) => (
              <button
                key={track.id}
                onClick={() => onSelectTrack(track)}
                className="flex w-full items-center gap-2 rounded-lg px-2.5 py-2 text-left text-xs cursor-pointer"
                style={{
                  background: track.id === item.id ? "var(--cs-accent-soft)" : "transparent",
                  color: track.id === item.id ? "var(--cs-accent)" : "var(--cs-text)"
                }}
              >
                <Music size={13} className="shrink-0" />
                <span className="truncate font-medium">{track.name}</span>
              </button>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
