import React, { useEffect, useState } from "react";
import {
  Film, Music, Image as ImageIcon, FileText, Clock, Play, FolderPlus,
  RefreshCw, Sparkles, Scissors, Wand2
} from "lucide-react";
import {
  BarChart, Bar, XAxis, YAxis, Tooltip, ResponsiveContainer, PieChart, Pie, Cell
} from "recharts";
import {
  MediaItem, DailyUsageRecord, SidebarSelection, formatBytes, formatHoursMinutes, formatTime
} from "../types";

interface Props {
  items: MediaItem[];
  folders: string[];
  usageRecords: Record<string, DailyUsageRecord>;
  onSelect: (sel: SidebarSelection) => void;
  onOpenItem: (item: MediaItem) => void;
  onAddFolder: () => void;
  onOpenFiles: () => void;
}

export default function DashboardView({
  items, folders, usageRecords, onSelect, onOpenItem, onAddFolder, onOpenFiles
}: Props) {
  const [activeTab, setActiveTab] = useState<"stats" | "explore">("stats");
  const [weather, setWeather] = useState<{ temp: number; cond: string } | null>(null);
  const [quote, setQuote] = useState<{ quote: string; author: string } | null>(null);
  const [wikiPhoto, setWikiPhoto] = useState<{ url: string; desc: string } | null>(null);
  const [onThisDay, setOnThisDay] = useState<string | null>(null);

  const hour = new Date().getHours();
  const greeting =
    hour >= 5 && hour < 12 ? "Good Morning" :
    hour >= 12 && hour < 17 ? "Good Afternoon" :
    hour >= 17 && hour < 22 ? "Good Evening" : "Late Night Studio";

  const fetchFeed = async () => {
    try {
      const wRes = await fetch("https://api.open-meteo.com/v1/forecast?latitude=22.7196&longitude=75.8577&current=temperature_2m,weather_code");
      const wJson = await wRes.json();
      if (wJson?.current) {
        const code = wJson.current.weather_code ?? 0;
        const cond = code === 0 ? "Clear" : code <= 2 ? "Partly Cloudy" : code === 3 ? "Overcast" : code >= 51 ? "Rain" : "Calm";
        setWeather({ temp: Math.round(wJson.current.temperature_2m), cond });
      }
    } catch {}

    try {
      const qRes = await fetch("https://dummyjson.com/quotes/random");
      const qJson = await qRes.json();
      if (qJson?.quote) setQuote({ quote: qJson.quote, author: qJson.author });
    } catch {}

    try {
      const now = new Date();
      const y = now.getFullYear();
      const m = String(now.getMonth() + 1).padStart(2, "0");
      const d = String(now.getDate()).padStart(2, "0");
      const fRes = await fetch(`https://en.wikipedia.org/api/rest_v1/feed/featured/${y}/${m}/${d}`);
      const fJson = await fRes.json();
      if (fJson?.image?.thumbnail?.source) {
        setWikiPhoto({
          url: fJson.image.thumbnail.source,
          desc: fJson.image.description?.text || "Featured Wikimedia photograph of the day."
        });
      }
      if (fJson?.onthisday?.[0]?.text) {
        const first = fJson.onthisday[0];
        setOnThisDay(first.year ? `${first.year} — ${first.text}` : first.text);
      }
    } catch {}
  };

  useEffect(() => { fetchFeed(); }, []);

  // Build last 7 days chart data
  const todayKey = new Date().toISOString().slice(0, 10);
  const todayRec = usageRecords[todayKey] || { dateKey: todayKey, appSeconds: 0, videoWatchedSeconds: 0, audioListenedSeconds: 0 };

  const last7Days = Array.from({ length: 7 }).map((_, i) => {
    const dt = new Date();
    dt.setDate(dt.getDate() - (6 - i));
    const key = dt.toISOString().slice(0, 10);
    const rec = usageRecords[key] || { appSeconds: 0, videoWatchedSeconds: 0, audioListenedSeconds: 0 };
    return {
      day: i === 6 ? "Today" : dt.toLocaleDateString("en-US", { weekday: "short" }),
      inApp: Number((rec.appSeconds / 60).toFixed(1)),
      watched: Number((rec.videoWatchedSeconds / 60).toFixed(1)),
      audio: Number((rec.audioListenedSeconds / 60).toFixed(1))
    };
  });

  const weekApp = last7Days.reduce((a, b) => a + b.inApp * 60, 0);
  const weekVideo = last7Days.reduce((a, b) => a + b.watched * 60, 0);
  const weekAudio = last7Days.reduce((a, b) => a + b.audio * 60, 0);

  const allApp = Object.values(usageRecords).reduce((a, r) => a + r.appSeconds, 0);
  const allVideo = Object.values(usageRecords).reduce((a, r) => a + r.videoWatchedSeconds, 0);
  const allAudio = Object.values(usageRecords).reduce((a, r) => a + r.audioListenedSeconds, 0);

  const browseMins = Math.max(0, (weekApp - weekVideo - weekAudio) / 60);
  const donutData = [
    { name: "Video Watched", value: weekVideo / 60, color: "#007AFF" },
    { name: "Audio Listened", value: weekAudio / 60, color: "#30B0C7" },
    { name: "Library & Studio", value: browseMins, color: "#B8DAFF" }
  ].filter((d) => d.value > 0);

  const totalBytes = items.reduce((s, i) => s + i.fileSize, 0);
  const byKind = (k: MediaItem["kind"]) => items.filter((i) => i.kind === k);
  const bytesKind = (k: MediaItem["kind"]) => byKind(k).reduce((s, i) => s + i.fileSize, 0);
  const continueItems = items
    .filter((i) => (i.kind === "video" || i.kind === "audio") && (i.lastPosition || 0) > 5)
    .sort((a, b) => (b.lastOpened || 0) - (a.lastOpened || 0))
    .slice(0, 8);

  return (
    <div className="h-full overflow-y-auto p-6 space-y-5">
      {/* Animated Hero Banner */}
      <div className="cs-card relative overflow-hidden rounded-2xl p-6">
        <svg className="pointer-events-none absolute inset-x-0 bottom-0 h-28 w-full opacity-20" viewBox="0 0 1200 120" preserveAspectRatio="none">
          <path d="M0,60 C260,115 540,10 820,65 C980,95 1110,45 1200,70 L1200,120 L0,120 Z" fill="var(--cs-accent)" />
        </svg>

        <div className="relative z-10 space-y-2">
          <div className="flex items-center gap-2 text-xs font-semibold" style={{ color: "var(--cs-accent)" }}>
            <span>{new Date().toLocaleDateString("en-US", { weekday: "long", month: "long", day: "numeric" })}</span>
            {weather && <span style={{ color: "var(--cs-text-secondary)" }}>· {weather.temp}°C {weather.cond}</span>}
          </div>
          <h1 className="text-3xl font-bold tracking-tight">{greeting}</h1>
          <p className="text-sm" style={{ color: "var(--cs-text-secondary)" }}>
            {items.length} media items indexed across {folders.length} folder{folders.length === 1 ? "" : "s"} · {formatBytes(totalBytes)} total
          </p>

          <div className="flex flex-wrap gap-2 pt-2">
            <button onClick={onOpenFiles} className="inline-flex items-center gap-1.5 rounded-lg px-3.5 py-1.5 text-sm font-medium text-white cursor-pointer" style={{ background: "var(--cs-accent)" }}>
              <Play size={14} /> Open Media
            </button>
            <button onClick={onAddFolder} className="inline-flex items-center gap-1.5 rounded-lg border px-3 py-1.5 text-sm font-medium cursor-pointer" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
              <FolderPlus size={14} /> Add Folder
            </button>
            <button onClick={() => onSelect({ type: "docWriter" })} className="inline-flex items-center gap-1.5 rounded-lg border px-3 py-1.5 text-sm font-medium cursor-pointer" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
              <FileText size={14} /> Doc Writer
            </button>
            <button onClick={() => onSelect({ type: "photoStudio" })} className="inline-flex items-center gap-1.5 rounded-lg border px-3 py-1.5 text-sm font-medium cursor-pointer" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
              <Wand2 size={14} /> Photo Studio
            </button>
            <button onClick={() => onSelect({ type: "videoStudio" })} className="inline-flex items-center gap-1.5 rounded-lg border px-3 py-1.5 text-sm font-medium cursor-pointer" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
              <Scissors size={14} /> Video Studio
            </button>
          </div>
        </div>
      </div>

      {/* 2-Tab Switcher: Stats & Activity vs Explore Today */}
      <div className="flex items-center justify-between">
        <div className="inline-flex rounded-lg p-1" style={{ background: "var(--cs-surface-subtle)" }}>
          <button
            onClick={() => setActiveTab("stats")}
            className={`rounded-md px-4 py-1.5 text-sm font-medium transition cursor-pointer ${activeTab === "stats" ? "shadow-sm" : ""}`}
            style={{
              background: activeTab === "stats" ? "var(--cs-surface)" : "transparent",
              color: activeTab === "stats" ? "var(--cs-text)" : "var(--cs-text-secondary)"
            }}
          >
            Stats &amp; Activity
          </button>
          <button
            onClick={() => setActiveTab("explore")}
            className={`rounded-md px-4 py-1.5 text-sm font-medium transition cursor-pointer ${activeTab === "explore" ? "shadow-sm" : ""}`}
            style={{
              background: activeTab === "explore" ? "var(--cs-surface)" : "transparent",
              color: activeTab === "explore" ? "var(--cs-text)" : "var(--cs-text-secondary)"
            }}
          >
            Explore Today
          </button>
        </div>
        <span className="text-xs" style={{ color: "var(--cs-text-tertiary)" }}>
          {activeTab === "stats" ? "Recorded locally · 100% private" : "Live Feed"}
        </span>
      </div>

      {activeTab === "stats" ? (
        <div className="space-y-5">
          {/* 3 Usage KPI Cards */}
          <div className="grid grid-cols-1 gap-4 md:grid-cols-3">
            {[
              { title: "Time in ChronoStream", today: formatHoursMinutes(todayRec.appSeconds), week: formatHoursMinutes(weekApp), all: formatHoursMinutes(allApp), color: "#007AFF", Icon: Clock },
              { title: "Video Watched", today: formatHoursMinutes(todayRec.videoWatchedSeconds), week: formatHoursMinutes(weekVideo), all: formatHoursMinutes(allVideo), color: "#0051D5", Icon: Film },
              { title: "Audio Listened", today: formatHoursMinutes(todayRec.audioListenedSeconds), week: formatHoursMinutes(weekAudio), all: formatHoursMinutes(allAudio), color: "#30B0C7", Icon: Music }
            ].map((k) => (
              <div key={k.title} className="cs-card rounded-2xl p-4 space-y-2.5">
                <div className="flex items-center justify-between">
                  <div className="flex h-8 w-8 items-center justify-center rounded-lg" style={{ background: `${k.color}1F`, color: k.color }}>
                    <k.Icon size={16} />
                  </div>
                  <span className="rounded-full px-2 py-0.5 text-xs" style={{ background: "var(--cs-surface-subtle)", color: "var(--cs-text-secondary)" }}>Today</span>
                </div>
                <div className="text-2xl font-bold tabular-nums">{k.today}</div>
                <div className="flex items-center justify-between text-xs">
                  <span style={{ color: "var(--cs-text-secondary)" }}>{k.title}</span>
                  <span className="tabular-nums" style={{ color: "var(--cs-text-tertiary)" }}>7d: {k.week} · All: {k.all}</span>
                </div>
              </div>
            ))}
          </div>

          {/* 2 Beautiful Native-Style Charts */}
          <div className="grid grid-cols-1 gap-4 lg:grid-cols-3">
            <div className="cs-card rounded-2xl p-5 lg:col-span-2">
              <div className="mb-3 flex items-center justify-between">
                <div>
                  <h3 className="text-sm font-semibold">7-Day Activity</h3>
                  <p className="text-xs" style={{ color: "var(--cs-text-secondary)" }}>Minutes spent in app vs. video watched</p>
                </div>
                <div className="flex gap-3 text-xs" style={{ color: "var(--cs-text-secondary)" }}>
                  <span className="flex items-center gap-1.5"><span className="h-2 w-2 rounded-full" style={{ background: "#B8DAFF" }} /> In App</span>
                  <span className="flex items-center gap-1.5"><span className="h-2 w-2 rounded-full" style={{ background: "#007AFF" }} /> Watched</span>
                </div>
              </div>
              <div className="h-48 w-full">
                <ResponsiveContainer width="100%" height="100%">
                  <BarChart data={last7Days}>
                    <XAxis dataKey="day" tick={{ fontSize: 11 }} stroke="var(--cs-text-tertiary)" axisLine={false} tickLine={false} />
                    <YAxis tick={{ fontSize: 11 }} stroke="var(--cs-text-tertiary)" axisLine={false} tickLine={false} unit="m" />
                    <Tooltip contentStyle={{ borderRadius: 10, border: "1px solid var(--cs-border)", background: "var(--cs-surface)", fontSize: 12 }} />
                    <Bar dataKey="inApp" name="In App (min)" fill="#B8DAFF" radius={[6, 6, 0, 0]} />
                    <Bar dataKey="watched" name="Watched (min)" fill="#007AFF" radius={[6, 6, 0, 0]} />
                  </BarChart>
                </ResponsiveContainer>
              </div>
            </div>

            <div className="cs-card rounded-2xl p-5 flex flex-col justify-between">
              <div>
                <h3 className="text-sm font-semibold">Time Breakdown</h3>
                <p className="text-xs" style={{ color: "var(--cs-text-secondary)" }}>Last 7 days ({formatHoursMinutes(weekApp)} total)</p>
              </div>
              <div className="h-40 w-full flex items-center justify-center">
                {donutData.length === 0 ? (
                  <div className="flex h-28 w-28 items-center justify-center rounded-full border-[14px] text-xs font-medium" style={{ borderColor: "var(--cs-surface-subtle)", color: "var(--cs-text-tertiary)" }}>
                    0m
                  </div>
                ) : (
                  <ResponsiveContainer width="100%" height="100%">
                    <PieChart>
                      <Pie data={donutData} dataKey="value" innerRadius={42} outerRadius={62} paddingAngle={donutData.length > 1 ? 3 : 0}>
                        {donutData.map((d) => <Cell key={d.name} fill={d.color} />)}
                      </Pie>
                      <Tooltip contentStyle={{ borderRadius: 10, border: "1px solid var(--cs-border)", background: "var(--cs-surface)", fontSize: 12 }} />
                    </PieChart>
                  </ResponsiveContainer>
                )}
              </div>
              <div className="space-y-1 text-xs">
                {donutData.map((d) => (
                  <div key={d.name} className="flex items-center justify-between">
                    <span className="flex items-center gap-1.5" style={{ color: "var(--cs-text-secondary)" }}>
                      <span className="h-2 w-2 rounded-full" style={{ background: d.color }} /> {d.name}
                    </span>
                    <span className="font-medium tabular-nums">{d.value.toFixed(1)}m</span>
                  </div>
                ))}
              </div>
            </div>
          </div>

          {/* Media Library Counters */}
          <div className="grid grid-cols-2 gap-4 md:grid-cols-4">
            {[
              { title: "Videos", count: byKind("video").length, size: bytesKind("video"), color: "#007AFF", Icon: Film, smart: "videos" as const },
              { title: "Music & Audio", count: byKind("audio").length, size: bytesKind("audio"), color: "#0051D5", Icon: Music, smart: "audio" as const },
              { title: "Photos", count: byKind("image").length, size: bytesKind("image"), color: "#30B0C7", Icon: ImageIcon, smart: "photos" as const },
              { title: "PDF Documents", count: byKind("pdf").length, size: bytesKind("pdf"), color: "#5AC8FA", Icon: FileText, smart: "documents" as const }
            ].map((c) => (
              <button
                key={c.title}
                onClick={() => onSelect({ type: "smart", smart: c.smart })}
                className="cs-card rounded-2xl p-4 text-left transition hover:scale-[1.01] cursor-pointer"
              >
                <div className="mb-2 flex h-8 w-8 items-center justify-center rounded-lg" style={{ background: `${c.color}1F`, color: c.color }}>
                  <c.Icon size={16} />
                </div>
                <div className="text-2xl font-bold tabular-nums">{c.count}</div>
                <div className="mt-1 flex items-center justify-between text-xs">
                  <span style={{ color: "var(--cs-text-secondary)" }}>{c.title}</span>
                  <span style={{ color: "var(--cs-text-tertiary)" }}>{formatBytes(c.size)}</span>
                </div>
              </button>
            ))}
          </div>

          {/* Continue Watching */}
          {continueItems.length > 0 && (
            <div className="space-y-2.5">
              <h3 className="text-sm font-semibold">Continue Watching &amp; Listening</h3>
              <div className="flex gap-3 overflow-x-auto pb-1">
                {continueItems.map((item) => (
                  <button
                    key={item.id}
                    onClick={() => onOpenItem(item)}
                    className="cs-card w-56 shrink-0 rounded-xl p-3 text-left cursor-pointer"
                  >
                    <div className="text-xs font-semibold" style={{ color: "var(--cs-accent)" }}>
                      Resume {formatTime(item.lastPosition || 0)}
                    </div>
                    <div className="truncate text-sm font-medium">{item.name}</div>
                    <div className="text-xs" style={{ color: "var(--cs-text-tertiary)" }}>{formatBytes(item.fileSize)}</div>
                  </button>
                ))}
              </div>
            </div>
          )}
        </div>
      ) : (
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2">
          <div className="cs-card rounded-2xl p-4 space-y-3">
            <div className="text-xs font-semibold" style={{ color: "var(--cs-accent)" }}>Picture of the Day</div>
            {wikiPhoto ? (
              <>
                <img src={wikiPhoto.url} alt="Picture of the Day" className="h-48 w-full rounded-xl object-cover" />
                <p className="text-xs line-clamp-3" style={{ color: "var(--cs-text-secondary)" }}>{wikiPhoto.desc}</p>
              </>
            ) : (
              <div className="flex h-48 items-center justify-center rounded-xl text-xs" style={{ background: "var(--cs-surface-subtle)", color: "var(--cs-text-secondary)" }}>
                Connect to Wi-Fi to load Wikimedia Picture of the Day
              </div>
            )}
          </div>

          <div className="space-y-4">
            <div className="cs-card rounded-2xl p-4 space-y-2">
              <div className="flex items-center justify-between">
                <span className="text-xs font-semibold" style={{ color: "var(--cs-accent)" }}>Daily Reflection</span>
                <button onClick={fetchFeed} className="cursor-pointer opacity-70 hover:opacity-100" title="Refresh">
                  <RefreshCw size={13} />
                </button>
              </div>
              {quote ? (
                <>
                  <p className="text-sm leading-relaxed">“{quote.quote}”</p>
                  <p className="text-xs font-medium" style={{ color: "var(--cs-text-secondary)" }}>— {quote.author}</p>
                </>
              ) : (
                <p className="text-xs" style={{ color: "var(--cs-text-secondary)" }}>Loading reflection…</p>
              )}
            </div>

            <div className="cs-card rounded-2xl p-4 space-y-1.5">
              <div className="flex items-center gap-1.5 text-xs font-semibold" style={{ color: "var(--cs-accent)" }}>
                <Sparkles size={13} /> On This Day in History
              </div>
              <p className="text-xs leading-relaxed" style={{ color: "var(--cs-text-secondary)" }}>
                {onThisDay || "Connect to the internet to view today's historical highlight."}
              </p>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
