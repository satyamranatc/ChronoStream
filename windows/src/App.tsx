import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  Sparkles, LayoutGrid, PlayCircle, Film, Music, Image as ImageIcon, FileText,
  Heart, Clock, Copy, Wand2, Scissors, QrCode, Folder, FolderPlus, Plus,
  PanelLeft, Sun, Moon, Monitor, Laptop, Settings, Search, List as ListIcon, Grid, Share2
} from "lucide-react";
import {
  MediaItem, SidebarSelection, SmartSection, DailyUsageRecord, ConnectedDisplay,
  formatBytes, playSubtleClickSound
} from "./types";
import DashboardView from "./components/DashboardView";
import VideoStageView from "./components/VideoStageView";
import AudioStageView from "./components/AudioStageView";
import DocumentStudioView from "./components/DocumentStudioView";
import WiFiShareHubView from "./components/WiFiShareHubView";
import PDFReaderView from "./components/PDFReaderView";
import { PhotoViewerView, PhotoStudioView, VideoStudioView } from "./components/MediaViewers";
import DisplaysPopover from "./components/DisplaysPopover";
import SettingsModal from "./components/SettingsModal";

const SMART_ITEMS: { id: SmartSection; label: string; Icon: React.ElementType }[] = [
  { id: "all", label: "All Media", Icon: LayoutGrid },
  { id: "continue", label: "Continue", Icon: PlayCircle },
  { id: "videos", label: "Videos", Icon: Film },
  { id: "audio", label: "Music & Audio", Icon: Music },
  { id: "photos", label: "Photos", Icon: ImageIcon },
  { id: "documents", label: "PDF Documents", Icon: FileText },
  { id: "favorites", label: "Favorites", Icon: Heart },
  { id: "recent", label: "Recently Opened", Icon: Clock },
  { id: "duplicates", label: "Duplicates", Icon: Copy }
];

export default function App() {
  const [theme, setTheme] = useState<"light" | "dark">(() => (localStorage.getItem("cs_theme") as "light" | "dark") || "light");
  const [fontScale, setFontScale] = useState<"compact" | "comfortable" | "large">(() => (localStorage.getItem("cs_font") as "compact" | "comfortable" | "large") || "comfortable");
  const [clickSound, setClickSound] = useState<boolean>(() => localStorage.getItem("cs_click") !== "false");

  const [showSidebar, setShowSidebar] = useState(true);
  const [selection, setSelection] = useState<SidebarSelection>({ type: "dashboard" });
  const [folders, setFolders] = useState<string[]>([]);
  const [items, setItems] = useState<MediaItem[]>([]);
  const [activeItem, setActiveItem] = useState<MediaItem | null>(null);
  const [shareSeedItems, setShareSeedItems] = useState<MediaItem[]>([]);

  const [searchQuery, setSearchQuery] = useState("");
  const [viewMode, setViewMode] = useState<"grid" | "list">("grid");
  const [usageRecords, setUsageRecords] = useState<Record<string, DailyUsageRecord>>({});
  const [displays, setDisplays] = useState<ConnectedDisplay[]>([]);
  const [keepAwake, setKeepAwake] = useState(true);
  const [cinemaActive, setCinemaActive] = useState(false);
  const [showDisplays, setShowDisplays] = useState(false);
  const [showSettings, setShowSettings] = useState(false);

  const isVideoPlayingRef = useRef(false);
  const isAudioPlayingRef = useRef(false);

  // Apply Pure Light / Dark theme class
  useEffect(() => {
    document.documentElement.classList.toggle("dark", theme === "dark");
    localStorage.setItem("cs_theme", theme);
  }, [theme]);

  useEffect(() => {
    localStorage.setItem("cs_font", fontScale);
  }, [fontScale]);

  useEffect(() => {
    localStorage.setItem("cs_click", String(clickSound));
  }, [clickSound]);

  // Global subtle click feedback
  useEffect(() => {
    const onDown = (e: MouseEvent) => {
      const target = e.target as HTMLElement | null;
      if (!target || target.isContentEditable || target.tagName === "INPUT" || target.tagName === "TEXTAREA") return;
      playSubtleClickSound(clickSound);
    };
    window.addEventListener("mousedown", onDown);
    return () => window.removeEventListener("mousedown", onDown);
  }, [clickSound]);

  // Hydrate library, usage stats & displays
  useEffect(() => {
    (async () => {
      const savedFolders = await window.chronoAPI?.loadState<string[]>("folders");
      if (savedFolders?.length) {
        setFolders(savedFolders);
        const all: MediaItem[] = [];
        for (const f of savedFolders) {
          const found = await window.chronoAPI?.scanFolder(f);
          if (found) all.push(...found);
        }
        setItems(all);
      }
      const savedUsage = await window.chronoAPI?.loadState<Record<string, DailyUsageRecord>>("usage_stats");
      if (savedUsage) setUsageRecords(savedUsage);

      const disp = await window.chronoAPI?.getDisplays();
      if (disp) {
        setDisplays(disp.displays);
        setKeepAwake(disp.keepAwake);
        setCinemaActive(disp.cinemaActive);
      }
    })();

    const offDisp = window.chronoAPI?.onDisplaysChanged((next) => setDisplays(next));
    return () => { offDisp?.(); };
  }, []);

  // Local 5s usage & watch-time recorder
  useEffect(() => {
    let ticks = 0;
    const id = window.setInterval(() => {
      if (document.hidden && !isVideoPlayingRef.current && !isAudioPlayingRef.current) return;
      const key = new Date().toISOString().slice(0, 10);
      setUsageRecords((prev) => {
        const cur = prev[key] || { dateKey: key, appSeconds: 0, videoWatchedSeconds: 0, audioListenedSeconds: 0 };
        const nextRec: DailyUsageRecord = {
          dateKey: key,
          appSeconds: cur.appSeconds + (document.hidden ? 0 : 5),
          videoWatchedSeconds: cur.videoWatchedSeconds + (isVideoPlayingRef.current ? 5 : 0),
          audioListenedSeconds: cur.audioListenedSeconds + (isAudioPlayingRef.current ? 5 : 0)
        };
        const updated = { ...prev, [key]: nextRec };
        ticks += 1;
        if (ticks % 6 === 0) window.chronoAPI?.saveState("usage_stats", updated);
        return updated;
      });
    }, 5000);
    return () => window.clearInterval(id);
  }, []);

  const addFolder = async () => {
    const picked = await window.chronoAPI?.pickFolders();
    if (!picked?.length) return;
    const nextFolders = Array.from(new Set([...folders, ...picked]));
    setFolders(nextFolders);
    window.chronoAPI?.saveState("folders", nextFolders);

    const newItems: MediaItem[] = [];
    for (const f of picked) {
      const scanned = await window.chronoAPI?.scanFolder(f);
      if (scanned) newItems.push(...scanned);
    }
    setItems((prev) => {
      const map = new Map(prev.map((i) => [i.id, i]));
      for (const n of newItems) if (!map.has(n.id)) map.set(n.id, n);
      return Array.from(map.values());
    });
  };

  const openFiles = async () => {
    const picked = await window.chronoAPI?.pickFiles();
    if (!picked?.length) return;
    const p = picked[0];
    const ext = p.split(".").pop()?.toLowerCase() || "";
    const kind = ["mp4", "mov", "m4v", "mkv", "avi", "webm"].includes(ext) ? "video"
      : ["mp3", "wav", "m4a", "flac", "ogg"].includes(ext) ? "audio"
      : ["pdf"].includes(ext) ? "pdf" : "image";
    const tempItem: MediaItem = { id: p, path: p, name: p.split(/[\\/]/).pop() || p, kind, ext: ext.toUpperCase(), fileSize: 0, modifiedAt: Date.now() };
    setActiveItem(tempItem);
  };

  const duplicateIds = useMemo(() => {
    const counts = new Map<string, string[]>();
    for (const i of items) {
      if (!i.partialHash) continue;
      const arr = counts.get(i.partialHash) || [];
      arr.push(i.id);
      counts.set(i.partialHash, arr);
    }
    const set = new Set<string>();
    for (const ids of counts.values()) if (ids.length > 1) ids.forEach((x) => set.add(x));
    return set;
  }, [items]);

  const countSmart = (s: SmartSection) => {
    switch (s) {
      case "all": return items.length;
      case "continue": return items.filter((i) => (i.kind === "video" || i.kind === "audio") && (i.lastPosition || 0) > 5).length;
      case "videos": return items.filter((i) => i.kind === "video").length;
      case "audio": return items.filter((i) => i.kind === "audio").length;
      case "photos": return items.filter((i) => i.kind === "image").length;
      case "documents": return items.filter((i) => i.kind === "pdf").length;
      case "favorites": return items.filter((i) => i.isFavorite).length;
      case "recent": return items.filter((i) => i.lastOpened).length;
      case "duplicates": return duplicateIds.size;
    }
  };

  const filteredItems = useMemo(() => {
    let list = items;
    if (selection.type === "smart") {
      switch (selection.smart) {
        case "continue": list = items.filter((i) => (i.kind === "video" || i.kind === "audio") && (i.lastPosition || 0) > 5); break;
        case "videos": list = items.filter((i) => i.kind === "video"); break;
        case "audio": list = items.filter((i) => i.kind === "audio"); break;
        case "photos": list = items.filter((i) => i.kind === "image"); break;
        case "documents": list = items.filter((i) => i.kind === "pdf"); break;
        case "favorites": list = items.filter((i) => i.isFavorite); break;
        case "recent": list = items.filter((i) => i.lastOpened).sort((a, b) => (b.lastOpened || 0) - (a.lastOpened || 0)); break;
        case "duplicates": list = items.filter((i) => duplicateIds.has(i.id)); break;
      }
    } else if (selection.type === "folder") {
      list = items.filter((i) => i.path.startsWith(selection.folderPath));
    }
    const q = searchQuery.trim().toLowerCase();
    if (q) list = list.filter((i) => i.name.toLowerCase().includes(q) || i.ext.toLowerCase().includes(q));
    return list;
  }, [items, selection, searchQuery, duplicateIds]);

  const openItem = (item: MediaItem) => {
    setItems((prev) => prev.map((x) => x.id === item.id ? { ...x, lastOpened: Date.now() } : x));
    setActiveItem(item);
  };

  const shareItem = (item: MediaItem) => {
    setShareSeedItems([item]);
    setActiveItem(null);
    setSelection({ type: "wifiShare" });
  };

  const baseFontPx = fontScale === "compact" ? 13 : fontScale === "large" ? 16 : 14.5;
  const hasExternalDisplay = displays.length > 1;

  return (
    <div className="flex h-screen w-screen flex-col overflow-hidden" style={{ fontSize: `${baseFontPx}px`, background: "var(--cs-canvas)", color: "var(--cs-text)" }}>
      {/* Clean Top Window Bar (Sidebar sits cleanly BELOW this bar) */}
      <div className="flex h-11 shrink-0 items-center justify-between border-b px-3.5" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
        <div className="flex items-center gap-2.5">
          <button onClick={() => setShowSidebar((s) => !s)} className="rounded-md p-1.5 hover:bg-black/5 cursor-pointer" title="Toggle Sidebar">
            <PanelLeft size={16} />
          </button>
          <span className="font-semibold tracking-tight">ChronoStream</span>
        </div>

        <div className="relative flex items-center gap-2">
          <button
            onClick={() => setTheme((t) => (t === "light" ? "dark" : "light"))}
            className="rounded-md p-1.5 hover:bg-black/5 cursor-pointer"
            title={theme === "light" ? "Switch to Dark Theme" : "Switch to Pure Light Theme"}
          >
            {theme === "light" ? <Moon size={16} /> : <Sun size={16} className="text-amber-400" />}
          </button>

          <button
            onClick={async () => {
              const d = await window.chronoAPI?.getDisplays();
              if (d) { setDisplays(d.displays); setKeepAwake(d.keepAwake); setCinemaActive(d.cinemaActive); }
              setShowDisplays((s) => !s);
            }}
            className="inline-flex items-center gap-1 rounded-md px-2 py-1 text-xs font-medium hover:bg-black/5 cursor-pointer"
            style={{ color: hasExternalDisplay ? "var(--cs-accent)" : "var(--cs-text-secondary)" }}
            title="Displays"
          >
            {hasExternalDisplay ? <Monitor size={15} /> : <Laptop size={15} />}
            {hasExternalDisplay && <span>HDMI</span>}
          </button>

          <button onClick={() => setShowSettings(true)} className="rounded-md p-1.5 hover:bg-black/5 cursor-pointer" title="Preferences">
            <Settings size={15} />
          </button>

          {showDisplays && (
            <div className="absolute right-0 top-10 z-50">
              <DisplaysPopover
                displays={displays}
                keepAwake={keepAwake}
                cinemaActive={cinemaActive}
                activeVideoUrl={activeItem?.kind === "video" && window.chronoAPI ? window.chronoAPI.mediaUrl(activeItem.path) : null}
                onRefresh={async () => { const d = await window.chronoAPI?.getDisplays(); if (d) setDisplays(d.displays); }}
                onToggleKeepAwake={async (v) => { setKeepAwake(v); await window.chronoAPI?.setKeepAwake(v); }}
                onMoveWindow={(id) => window.chronoAPI?.moveToDisplay(id)}
                onToggleCinema={async (id) => {
                  if (cinemaActive) { await window.chronoAPI?.stopCinema(); setCinemaActive(false); }
                  else if (activeItem && window.chronoAPI) { await window.chronoAPI.startCinema(window.chronoAPI.mediaUrl(activeItem.path), id); setCinemaActive(true); }
                }}
              />
            </div>
          )}
        </div>
      </div>

      {/* Main Split Workspace */}
      <div className="flex flex-1 overflow-hidden">
        {/* Clean Below-Titlebar Sidebar */}
        {showSidebar && (
          <aside className="flex w-60 shrink-0 flex-col border-r" style={{ borderColor: "var(--cs-border)", background: "var(--cs-sidebar)" }}>
            <div className="flex-1 overflow-y-auto p-2.5 space-y-4">
              {/* Dashboard */}
              <button
                onClick={() => { setActiveItem(null); setSelection({ type: "dashboard" }); }}
                className="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-1.5 text-left font-medium cursor-pointer"
                style={{
                  background: selection.type === "dashboard" && !activeItem ? "var(--cs-accent-soft)" : "transparent",
                  color: selection.type === "dashboard" && !activeItem ? "var(--cs-accent)" : "var(--cs-text)"
                }}
              >
                <Sparkles size={15} /> Dashboard
              </button>

              {/* Library */}
              <div className="space-y-0.5">
                <div className="px-2.5 pb-1 text-[11px] font-semibold uppercase tracking-wider" style={{ color: "var(--cs-text-tertiary)" }}>Library</div>
                {SMART_ITEMS.map(({ id, label, Icon }) => {
                  const active = selection.type === "smart" && selection.smart === id && !activeItem;
                  const c = countSmart(id);
                  return (
                    <button
                      key={id}
                      onClick={() => { setActiveItem(null); setSelection({ type: "smart", smart: id }); }}
                      className="flex w-full items-center justify-between rounded-lg px-2.5 py-1.5 text-left cursor-pointer"
                      style={{ background: active ? "var(--cs-accent-soft)" : "transparent", color: active ? "var(--cs-accent)" : "var(--cs-text)" }}
                    >
                      <span className="flex items-center gap-2.5 truncate"><Icon size={15} /> <span className="truncate">{label}</span></span>
                      {c > 0 && <span className="rounded-full px-1.5 py-0.5 text-[10px] font-medium tabular-nums" style={{ background: "var(--cs-surface-subtle)", color: "var(--cs-text-secondary)" }}>{c}</span>}
                    </button>
                  );
                })}
              </div>

              {/* Studio */}
              <div className="space-y-0.5">
                <div className="px-2.5 pb-1 text-[11px] font-semibold uppercase tracking-wider" style={{ color: "var(--cs-text-tertiary)" }}>Studio</div>
                {([
                  ["docWriter", "Doc Writer", FileText],
                  ["photoStudio", "Photo Studio", Wand2],
                  ["videoStudio", "Video Studio", Scissors],
                  ["wifiShare", "Wi-Fi Share", QrCode]
                ] as const).map(([type, label, Icon]) => {
                  const active = selection.type === type && !activeItem;
                  return (
                    <button
                      key={type}
                      onClick={() => { setActiveItem(null); setSelection({ type }); }}
                      className="flex w-full items-center gap-2.5 rounded-lg px-2.5 py-1.5 text-left cursor-pointer"
                      style={{ background: active ? "var(--cs-accent-soft)" : "transparent", color: active ? "var(--cs-accent)" : "var(--cs-text)" }}
                    >
                      <Icon size={15} /> {label}
                    </button>
                  );
                })}
              </div>

              {/* Folders */}
              <div className="space-y-0.5">
                <div className="flex items-center justify-between px-2.5 pb-1">
                  <span className="text-[11px] font-semibold uppercase tracking-wider" style={{ color: "var(--cs-text-tertiary)" }}>Folders</span>
                  <button onClick={addFolder} className="flex h-5 w-5 items-center justify-center rounded-full hover:bg-black/10 cursor-pointer"><Plus size={12} /></button>
                </div>
                {folders.length === 0 ? (
                  <div className="px-2.5 text-xs" style={{ color: "var(--cs-text-tertiary)" }}>No folders added</div>
                ) : (
                  folders.map((f) => {
                    const active = selection.type === "folder" && selection.folderPath === f && !activeItem;
                    return (
                      <button
                        key={f}
                        onClick={() => { setActiveItem(null); setSelection({ type: "folder", folderPath: f }); }}
                        className="flex w-full items-center gap-2 rounded-lg px-2.5 py-1.5 text-left truncate cursor-pointer"
                        style={{ background: active ? "var(--cs-accent-soft)" : "transparent", color: active ? "var(--cs-accent)" : "var(--cs-text)" }}
                      >
                        <Folder size={14} className="shrink-0" /> <span className="truncate">{f.split(/[\\/]/).pop()}</span>
                      </button>
                    );
                  })
                )}
              </div>
            </div>

            {/* Pinned Open Folder Button */}
            <div className="border-t p-3" style={{ borderColor: "var(--cs-border)" }}>
              <button onClick={addFolder} className="flex w-full items-center justify-center gap-2 rounded-lg py-2 text-xs font-semibold text-white cursor-pointer" style={{ background: "var(--cs-accent)" }}>
                <FolderPlus size={14} /> Open Folder…
              </button>
            </div>
          </aside>
        )}

        {/* Detail Pane */}
        <main className="flex-1 overflow-hidden">
          {activeItem ? (
            activeItem.kind === "video" ? (
              <VideoStageView
                item={activeItem}
                hasExternalDisplay={hasExternalDisplay}
                onClose={() => { isVideoPlayingRef.current = false; setActiveItem(null); }}
                onShare={shareItem}
                onProgress={(id, pos, dur, playing) => {
                  isVideoPlayingRef.current = playing;
                  setItems((prev) => prev.map((x) => x.id === id ? { ...x, lastPosition: pos, duration: dur } : x));
                }}
              />
            ) : activeItem.kind === "audio" ? (
              <AudioStageView
                item={activeItem}
                queue={items.filter((i) => i.kind === "audio")}
                onSelectTrack={openItem}
                onShare={shareItem}
                onClose={() => { isAudioPlayingRef.current = false; setActiveItem(null); }}
                onPlaybackState={(playing) => { isAudioPlayingRef.current = playing; }}
              />
            ) : activeItem.kind === "pdf" ? (
              <PDFReaderView item={activeItem} onShare={shareItem} onClose={() => setActiveItem(null)} />
            ) : (
              <PhotoViewerView item={activeItem} onShare={shareItem} onClose={() => setActiveItem(null)} />
            )
          ) : selection.type === "dashboard" ? (
            <DashboardView
              items={items}
              folders={folders}
              usageRecords={usageRecords}
              onSelect={(sel) => setSelection(sel)}
              onOpenItem={openItem}
              onAddFolder={addFolder}
              onOpenFiles={openFiles}
            />
          ) : selection.type === "docWriter" ? (
            <DocumentStudioView />
          ) : selection.type === "photoStudio" ? (
            <PhotoStudioView photos={items.filter((i) => i.kind === "image")} />
          ) : selection.type === "videoStudio" ? (
            <VideoStudioView videos={items.filter((i) => i.kind === "video")} />
          ) : selection.type === "wifiShare" ? (
            <WiFiShareHubView
              initialSendItems={shareSeedItems}
              onOpenReceived={(filePath) => {
                const ext = filePath.split(".").pop()?.toLowerCase() || "";
                const kind = ["mp4", "mov", "m4v", "mkv", "avi", "webm"].includes(ext) ? "video"
                  : ["mp3", "wav", "m4a", "flac", "ogg"].includes(ext) ? "audio"
                  : ["pdf"].includes(ext) ? "pdf" : "image";
                openItem({ id: filePath, path: filePath, name: filePath.split(/[\\/]/).pop() || filePath, kind, ext: ext.toUpperCase(), fileSize: 0, modifiedAt: Date.now() });
              }}
            />
          ) : (
            /* Media Explorer (Grid & List) */
            <div className="flex h-full flex-col overflow-hidden">
              <div className="flex items-center justify-between border-b px-5 py-3" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
                <div>
                  <h2 className="text-base font-bold capitalize">
                    {selection.type === "smart" ? SMART_ITEMS.find((s) => s.id === selection.smart)?.label : selection.type === "folder" ? selection.folderPath.split(/[\\/]/).pop() : "Library"}
                  </h2>
                  <p className="text-xs" style={{ color: "var(--cs-text-secondary)" }}>{filteredItems.length} item{filteredItems.length === 1 ? "" : "s"}</p>
                </div>

                <div className="flex items-center gap-2.5">
                  <div className="flex items-center gap-1.5 rounded-lg border px-2.5 py-1.5 text-xs" style={{ borderColor: "var(--cs-border)", background: "var(--cs-canvas)" }}>
                    <Search size={13} style={{ color: "var(--cs-text-tertiary)" }} />
                    <input value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Search media…" className="w-44 bg-transparent outline-none" />
                  </div>
                  <div className="inline-flex rounded-lg p-0.5" style={{ background: "var(--cs-surface-subtle)" }}>
                    <button onClick={() => setViewMode("grid")} className="rounded p-1.5 cursor-pointer" style={{ background: viewMode === "grid" ? "var(--cs-surface)" : "transparent" }}><Grid size={14} /></button>
                    <button onClick={() => setViewMode("list")} className="rounded p-1.5 cursor-pointer" style={{ background: viewMode === "list" ? "var(--cs-surface)" : "transparent" }}><ListIcon size={14} /></button>
                  </div>
                </div>
              </div>

              {filteredItems.length === 0 ? (
                <div className="flex flex-1 flex-col items-center justify-center p-8 text-center space-y-3">
                  <FolderPlus size={40} style={{ color: "var(--cs-text-tertiary)" }} />
                  <div className="text-base font-semibold">No media items here yet</div>
                  <p className="text-xs max-w-sm" style={{ color: "var(--cs-text-secondary)" }}>Add a folder containing videos, music, photos, or PDFs to start browsing.</p>
                  <button onClick={addFolder} className="rounded-lg px-4 py-2 text-xs font-semibold text-white cursor-pointer" style={{ background: "var(--cs-accent)" }}>Open Folder…</button>
                </div>
              ) : viewMode === "grid" ? (
                <div className="flex-1 overflow-y-auto p-5 grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 auto-rows-max">
                  {filteredItems.map((item) => (
                    <div
                      key={item.id}
                      onDoubleClick={() => openItem(item)}
                      onClick={() => openItem(item)}
                      className="cs-card group rounded-2xl p-3 cursor-pointer transition hover:-translate-y-0.5 space-y-2"
                    >
                      <div className="flex h-28 items-center justify-center overflow-hidden rounded-xl" style={{ background: "var(--cs-surface-subtle)" }}>
                        {item.kind === "image" && window.chronoAPI ? (
                          <img src={window.chronoAPI.mediaUrl(item.path)} alt={item.name} loading="lazy" className="h-full w-full object-cover" />
                        ) : item.kind === "video" ? (
                          <Film size={28} style={{ color: "var(--cs-accent)" }} />
                        ) : item.kind === "audio" ? (
                          <Music size={28} className="text-blue-600" />
                        ) : (
                          <FileText size={28} className="text-orange-500" />
                        )}
                      </div>
                      <div className="flex items-start justify-between gap-1">
                        <div className="min-w-0">
                          <div className="truncate text-xs font-semibold">{item.name}</div>
                          <div className="text-[11px]" style={{ color: "var(--cs-text-tertiary)" }}>{item.ext} · {formatBytes(item.fileSize)}</div>
                        </div>
                        <button
                          onClick={(e) => { e.stopPropagation(); shareItem(item); }}
                          className="opacity-0 group-hover:opacity-75 hover:!opacity-100 p-1 cursor-pointer"
                          title="Share via Wi-Fi QR"
                        >
                          <Share2 size={13} />
                        </button>
                      </div>
                    </div>
                  ))}
                </div>
              ) : (
                <div className="flex-1 overflow-y-auto p-3 space-y-1">
                  {filteredItems.map((item) => (
                    <div
                      key={item.id}
                      onClick={() => openItem(item)}
                      className="flex items-center justify-between rounded-xl px-3 py-2 hover:bg-black/5 cursor-pointer text-xs"
                    >
                      <div className="flex items-center gap-3 min-w-0">
                        {item.kind === "video" ? <Film size={15} style={{ color: "var(--cs-accent)" }} /> : item.kind === "audio" ? <Music size={15} className="text-blue-600" /> : item.kind === "pdf" ? <FileText size={15} className="text-orange-500" /> : <ImageIcon size={15} className="text-indigo-500" />}
                        <span className="truncate font-medium">{item.name}</span>
                      </div>
                      <div className="flex items-center gap-4 shrink-0" style={{ color: "var(--cs-text-secondary)" }}>
                        <span className="font-mono text-[11px]">{item.ext}</span>
                        <span className="w-16 text-right tabular-nums">{formatBytes(item.fileSize)}</span>
                        <button onClick={(e) => { e.stopPropagation(); shareItem(item); }} className="cursor-pointer opacity-70 hover:opacity-100"><Share2 size={13} /></button>
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}
        </main>
      </div>

      {showSettings && (
        <SettingsModal
          theme={theme}
          fontScale={fontScale}
          clickSound={clickSound}
          onTheme={setTheme}
          onFontScale={setFontScale}
          onClickSound={setClickSound}
          onClose={() => setShowSettings(false)}
        />
      )}
    </div>
  );
}
