import React from "react";
import { Laptop, Monitor, RefreshCw } from "lucide-react";
import { ConnectedDisplay } from "../types";

interface Props {
  displays: ConnectedDisplay[];
  keepAwake: boolean;
  cinemaActive: boolean;
  activeVideoUrl: string | null;
  onRefresh: () => void;
  onToggleKeepAwake: (v: boolean) => void;
  onMoveWindow: (id: number) => void;
  onToggleCinema: (id: number) => void;
}

export default function DisplaysPopover({
  displays, keepAwake, cinemaActive, activeVideoUrl, onRefresh, onToggleKeepAwake, onMoveWindow, onToggleCinema
}: Props) {
  const hasExternal = displays.length > 1;
  return (
    <div className="cs-card w-84 rounded-2xl p-4 space-y-3.5 shadow-2xl">
      <div className="flex items-center justify-between">
        <span className="text-sm font-semibold">Displays</span>
        <div className="flex items-center gap-2">
          <span className="inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-[11px] font-medium" style={{ background: "var(--cs-surface-subtle)", color: "var(--cs-text-secondary)" }}>
            <span className={`h-1.5 w-1.5 rounded-full ${hasExternal ? "bg-emerald-500" : "bg-slate-400"}`} />
            {hasExternal ? "HDMI Connected" : "Single Display"}
          </span>
          <button onClick={onRefresh} className="cursor-pointer opacity-70 hover:opacity-100"><RefreshCw size={13} /></button>
        </div>
      </div>

      <div className="overflow-hidden rounded-xl border divide-y" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface-subtle)" }}>
        {displays.map((d) => (
          <div key={d.id} className="flex items-center justify-between px-3 py-2.5 gap-2">
            <div className="flex items-center gap-2.5 min-w-0">
              <div className="flex h-8 w-8 shrink-0 items-center justify-center rounded-full" style={{ background: d.isMain ? "rgba(148,163,184,0.18)" : "var(--cs-accent-soft)", color: d.isMain ? "var(--cs-text)" : "var(--cs-accent)" }}>
                {d.isMain ? <Laptop size={15} /> : <Monitor size={15} />}
              </div>
              <div className="min-w-0">
                <div className="truncate text-xs font-medium">{d.name}</div>
                <div className="font-mono text-[10px]" style={{ color: "var(--cs-text-secondary)" }}>
                  {d.width}×{d.height} · {d.refreshRateHz} Hz{d.isMain ? " · Main" : ""}
                </div>
              </div>
            </div>

            <div className="flex items-center gap-1.5 shrink-0">
              {displays.length > 1 && (
                <button onClick={() => onMoveWindow(d.id)} className="rounded-md border px-2 py-0.5 text-[11px] cursor-pointer" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>Move</button>
              )}
              {!d.isMain && activeVideoUrl && (
                <button onClick={() => onToggleCinema(d.id)} className="rounded-md px-2 py-0.5 text-[11px] font-medium text-white cursor-pointer" style={{ background: cinemaActive ? "#DC2626" : "var(--cs-accent)" }}>
                  {cinemaActive ? "Stop" : "Cinema"}
                </button>
              )}
            </div>
          </div>
        ))}
      </div>

      <div className="rounded-xl border px-3 py-2.5 flex items-center justify-between" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface-subtle)" }}>
        <div>
          <div className="text-xs font-medium">Keep External Display Awake</div>
          <div className="text-[10px]" style={{ color: "var(--cs-text-secondary)" }}>Prevents idle sleep while connected</div>
        </div>
        <input type="checkbox" checked={keepAwake} onChange={(e) => onToggleKeepAwake(e.target.checked)} className="h-4 w-4 accent-teal-600 cursor-pointer" />
      </div>
    </div>
  );
}
