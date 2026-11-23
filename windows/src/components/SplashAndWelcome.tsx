import React, { useEffect, useState } from "react";
import {
  Sparkles, BookOpen, FolderOpen, ShieldCheck,
  ChevronLeft, ChevronRight, ArrowRight, FolderPlus, Play, Film, FileText, QrCode, Scissors
} from "lucide-react";

export function SplashScreen({ onFinished }: { onFinished: () => void }) {
  const [visible, setVisible] = useState(false);
  const [progress, setProgress] = useState(0);
  const [status, setStatus] = useState("Preparing workspace…");

  useEffect(() => {
    const t0 = window.setTimeout(() => setVisible(true), 40);
    const t1 = window.setTimeout(() => setProgress(58), 220);
    const t2 = window.setTimeout(() => { setStatus("Ready"); setProgress(100); }, 820);
    const t3 = window.setTimeout(() => onFinished(), 1350);
    return () => { clearTimeout(t0); clearTimeout(t1); clearTimeout(t2); clearTimeout(t3); };
  }, [onFinished]);

  return (
    <div
      className="fixed inset-0 z-[100] flex flex-col items-center justify-center transition-opacity duration-300"
      style={{ background: "var(--cs-canvas)" }}
    >
      <div
        className="pointer-events-none absolute h-[420px] w-[420px] rounded-full blur-3xl transition-all duration-1000"
        style={{
          background: "radial-gradient(circle, rgba(0,122,255,0.16) 0%, rgba(48,176,199,0.08) 45%, rgba(0,122,255,0) 72%)",
          transform: visible ? "scale(1.1)" : "scale(0.8)",
          opacity: visible ? 1 : 0
        }}
      />

      <div
        className="relative flex flex-col items-center space-y-5 transition-all duration-500"
        style={{ opacity: visible ? 1 : 0, transform: visible ? "scale(1) translateY(0)" : "scale(0.92) translateY(8px)" }}
      >
        <div
          className="flex h-24 w-24 items-center justify-center rounded-3xl border shadow-xl"
          style={{ background: "var(--cs-surface)", borderColor: "rgba(0,122,255,0.22)" }}
        >
          <div className="flex h-14 w-14 items-center justify-center rounded-2xl text-white shadow-md" style={{ background: "linear-gradient(135deg, #007AFF 0%, #0051D5 72%, #30B0C7 100%)" }}>
            <Play size={28} fill="currentColor" />
          </div>
        </div>

        <div className="text-center space-y-1">
          <h1 className="text-3xl font-bold tracking-tight">ChronoStream</h1>
          <p className="text-xs font-medium" style={{ color: "var(--cs-text-secondary)" }}>
            Unified Media &amp; Studio Suite
          </p>
        </div>

        <div className="flex flex-col items-center space-y-2 pt-1">
          <div className="h-1 w-44 overflow-hidden rounded-full" style={{ background: "var(--cs-surface-subtle)" }}>
            <div
              className="h-full rounded-full transition-all duration-500 ease-out"
              style={{ width: `${progress}%`, background: "linear-gradient(90deg, #007AFF 0%, #30B0C7 100%)" }}
            />
          </div>
          <span className="text-[11px] font-medium" style={{ color: "var(--cs-text-tertiary)" }}>{status}</span>
        </div>
      </div>
    </div>
  );
}

const SLIDES = [
  {
    badge: "SEAMLESS EXPERIENCE",
    title: "Welcome to ChronoStream",
    subtitle: "One fast, calm, offline-first workspace designed to bring all your everyday media and documents together.",
    Icon: Sparkles,
    accent: "#007AFF",
    highlights: [
      { Icon: Film, title: "Fast, Calm & Responsive", detail: "Smooth playback for long 12–24+ hour videos, music, photos, and Pure Light & Dark themes." },
      { Icon: Play, title: "Zero Friction Navigation", detail: "Exact scroll preservation when returning from any video, with your last played clip highlighted." }
    ]
  },
  {
    badge: "MANAGE EVERYTHING",
    title: "All Your Media in One Place",
    subtitle: "Browse, organize, and manage videos, music, photos, PDFs, and Word documents effortlessly.",
    Icon: FolderOpen,
    accent: "#007AFF",
    highlights: [
      { Icon: FolderOpen, title: "Explorer-Style Controls", detail: "Single-click to select, navigate with arrow keys, double-click or press Enter to play." },
      { Icon: Scissors, title: "Cut, Copy, Paste, Rename & Studios", detail: "Full right-click file actions, drag-and-drop, plus built-in Photo and Video Studios." }
    ]
  },
  {
    badge: "READ & WRITE",
    title: "Read PDFs & Books Comfortably",
    subtitle: "A distraction-free PDF book reader and native Microsoft Word (.docx) writer built right in.",
    Icon: BookOpen,
    accent: "#007AFF",
    highlights: [
      { Icon: BookOpen, title: "4 Calm Reading Themes", detail: "Paper, Sepia, Soft Gray, and Night mode with Bookmarks, Study Notes & Zen Focus." },
      { Icon: FileText, title: "Native Word (.docx) & PDF Export", detail: "Write with clean formatting and export directly to .docx or print-ready PDF." }
    ]
  },
  {
    badge: "ONE-CLICK SHARE",
    title: "Share to Android & iOS Instantly",
    subtitle: "Send or receive files with any phone over local Wi-Fi — no cables, no phone apps, no cloud uploads.",
    Icon: QrCode,
    accent: "#007AFF",
    highlights: [
      { Icon: QrCode, title: "Scan QR & Download on Any Phone", detail: "One-click sharing for videos, photos, PDFs, and collections to Android or iPhone." },
      { Icon: ShieldCheck, title: "Two-Way PIN-Protected Transfers", detail: "Receive files from your phone into your Inbox with rotating 4-digit PIN security." }
    ]
  },
  {
    badge: "READY TO START",
    title: "100% Private. Completely Yours.",
    subtitle: "ChronoStream only reads folders you explicitly add. Connect a folder now or explore the workspace.",
    Icon: ShieldCheck,
    accent: "#007AFF",
    highlights: [
      { Icon: FolderPlus, title: "You Control Folder Access", detail: "Add any local folder with one click — nothing is ever uploaded to the cloud." },
      { Icon: Sparkles, title: "Ready Whenever You Are", detail: "Click Get Started below to jump straight into ChronoStream." }
    ]
  }
];

export function WelcomeSlidesModal({
  onAddFolder,
  onStart
}: {
  onAddFolder: () => void;
  onStart: () => void;
}) {
  const [idx, setIdx] = useState(0);
  const slide = SLIDES[idx];
  const isLast = idx === SLIDES.length - 1;

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "ArrowRight") setIdx((i) => Math.min(SLIDES.length - 1, i + 1));
      else if (e.key === "ArrowLeft") setIdx((i) => Math.max(0, i - 1));
      else if (e.key === "Enter") {
        if (idx === SLIDES.length - 1) onStart();
        else setIdx((i) => i + 1);
      } else if (e.key === "Escape") onStart();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [idx, onStart]);

  return (
    <div className="fixed inset-0 z-[90] flex items-center justify-center bg-black/45 p-4 backdrop-blur-sm">
      <div
        className="flex w-full max-w-2xl flex-col overflow-hidden rounded-2xl border shadow-2xl"
        style={{ background: "var(--cs-canvas)", borderColor: "var(--cs-border)" }}
      >
        {/* Top Header */}
        <div className="flex items-center justify-between border-b px-6 py-3.5 text-xs" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
          <div className="flex items-center gap-2">
            <span className="font-bold">ChronoStream</span>
            <span style={{ color: "var(--cs-text-tertiary)" }}>· Step {idx + 1} of {SLIDES.length}</span>
          </div>
          {!isLast && (
            <button onClick={onStart} className="font-medium hover:underline cursor-pointer" style={{ color: "var(--cs-text-secondary)" }}>
              Skip
            </button>
          )}
        </div>

        {/* Slide Body */}
        <div className="flex flex-col items-center px-8 py-7 space-y-5">
          <div className="flex flex-col items-center text-center space-y-2.5">
            <div
              className="flex h-16 w-16 items-center justify-center rounded-2xl border"
              style={{ background: `${slide.accent}1A`, borderColor: `${slide.accent}38`, color: slide.accent }}
            >
              <slide.Icon size={28} />
            </div>
            <div className="text-[10px] font-bold tracking-widest uppercase" style={{ color: slide.accent }}>{slide.badge}</div>
            <h2 className="text-2xl font-bold tracking-tight">{slide.title}</h2>
            <p className="max-w-lg text-xs leading-relaxed" style={{ color: "var(--cs-text-secondary)" }}>{slide.subtitle}</p>
          </div>

          <div className="w-full max-w-xl rounded-2xl border p-5 space-y-3.5" style={{ background: "var(--cs-surface)", borderColor: "var(--cs-border)" }}>
            {slide.highlights.map((h) => (
              <div key={h.title} className="flex items-start gap-3">
                <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg" style={{ background: `${slide.accent}18`, color: slide.accent }}>
                  <h.Icon size={16} />
                </div>
                <div>
                  <div className="text-xs font-semibold">{h.title}</div>
                  <div className="text-[11px]" style={{ color: "var(--cs-text-secondary)" }}>{h.detail}</div>
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Footer Controls */}
        <div className="flex items-center justify-between border-t px-6 py-4" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
          <div className="w-24">
            {idx > 0 && (
              <button
                onClick={() => setIdx((i) => Math.max(0, i - 1))}
                className="inline-flex items-center gap-1 rounded-lg border px-3 py-1.5 text-xs font-medium cursor-pointer"
                style={{ borderColor: "var(--cs-border)" }}
              >
                <ChevronLeft size={14} /> Back
              </button>
            )}
          </div>

          <div className="flex items-center gap-1.5">
            {SLIDES.map((_, i) => (
              <button
                key={i}
                onClick={() => setIdx(i)}
                className="h-2 rounded-full transition-all cursor-pointer"
                style={{ width: i === idx ? 22 : 7, background: i === idx ? slide.accent : "var(--cs-border)" }}
              />
            ))}
          </div>

          <div className="flex items-center gap-2">
            {isLast ? (
              <>
                <button
                  onClick={onAddFolder}
                  className="inline-flex items-center gap-1.5 rounded-lg border px-3 py-1.5 text-xs font-medium cursor-pointer"
                  style={{ borderColor: "var(--cs-border)" }}
                >
                  <FolderPlus size={14} /> Add Folder…
                </button>
                <button
                  onClick={onStart}
                  className="inline-flex items-center gap-1.5 rounded-lg px-4 py-1.5 text-xs font-semibold text-white cursor-pointer"
                  style={{ background: "var(--cs-accent)" }}
                >
                  Get Started <ArrowRight size={14} />
                </button>
              </>
            ) : (
              <button
                onClick={() => setIdx((i) => Math.min(SLIDES.length - 1, i + 1))}
                className="inline-flex items-center gap-1 rounded-lg px-4 py-1.5 text-xs font-semibold text-white cursor-pointer"
                style={{ background: slide.accent }}
              >
                Next <ChevronRight size={14} />
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
