import React from "react";
import { X } from "lucide-react";

interface Props {
  theme: "light" | "dark";
  fontScale: "compact" | "comfortable" | "large";
  clickSound: boolean;
  onTheme: (t: "light" | "dark") => void;
  onFontScale: (f: "compact" | "comfortable" | "large") => void;
  onClickSound: (v: boolean) => void;
  onReplayWelcome: () => void;
  onClose: () => void;
}

export default function SettingsModal({ theme, fontScale, clickSound, onTheme, onFontScale, onClickSound, onReplayWelcome, onClose }: Props) {
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-xs" onClick={onClose}>
      <div className="cs-card w-[440px] rounded-2xl p-5 space-y-4 shadow-2xl" onClick={(e) => e.stopPropagation()}>
        <div className="flex items-center justify-between">
          <h3 className="text-base font-semibold">Preferences</h3>
          <button onClick={onClose} className="cursor-pointer opacity-70 hover:opacity-100"><X size={16} /></button>
        </div>

        <div className="space-y-3 text-sm">
          <div className="flex items-center justify-between">
            <span>Theme</span>
            <div className="inline-flex rounded-lg p-1 text-xs" style={{ background: "var(--cs-surface-subtle)" }}>
              <button onClick={() => onTheme("light")} className="rounded px-3 py-1 cursor-pointer" style={{ background: theme === "light" ? "var(--cs-surface)" : "transparent" }}>Pure Light</button>
              <button onClick={() => onTheme("dark")} className="rounded px-3 py-1 cursor-pointer" style={{ background: theme === "dark" ? "var(--cs-surface)" : "transparent" }}>Dark</button>
            </div>
          </div>

          <div className="flex items-center justify-between">
            <span>Interface Text Size</span>
            <div className="inline-flex rounded-lg p-1 text-xs" style={{ background: "var(--cs-surface-subtle)" }}>
              {(["compact", "comfortable", "large"] as const).map((sz) => (
                <button key={sz} onClick={() => onFontScale(sz)} className="rounded px-2.5 py-1 capitalize cursor-pointer" style={{ background: fontScale === sz ? "var(--cs-surface)" : "transparent" }}>
                  {sz}
                </button>
              ))}
            </div>
          </div>

          <label className="flex items-center justify-between cursor-pointer pt-1">
            <span>Subtle UI Click Sound</span>
            <input type="checkbox" checked={clickSound} onChange={(e) => onClickSound(e.target.checked)} className="h-4 w-4 accent-blue-600" />
          </label>

          <div className="flex items-center justify-between pt-2 border-t" style={{ borderColor: "var(--cs-border)" }}>
            <span>Welcome Walkthrough</span>
            <button
              onClick={() => { onClose(); onReplayWelcome(); }}
              className="rounded-lg border px-3 py-1.5 text-xs font-medium cursor-pointer"
              style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface-subtle)" }}
            >
              Replay Welcome Tour
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
