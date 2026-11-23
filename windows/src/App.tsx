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
import { SplashScreen, WelcomeSlidesModal } from "./components/SplashAndWelcome";

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
  const [lastOpenedId, setLastOpenedId] = useState<string | null>(null);
  const [focusedId, setFocusedId] = useState<string | null>(null);
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set());
  const [selectMode, setSelectMode] = useState(false);
  const [clipboard, setClipboard] = useState<{ paths: string[]; mode: "copy" | "move" } | null>(null);
  const [contextMenu, setContextMenu] = useState<{ x: number; y: number; item: MediaItem } | null>(null);
  const [renameTarget, setRenameTarget] = useState<MediaItem | null>(null);
  const [renameDraft, setRenameDraft] = useState("");
  const [fileToast, setFileToast] = useState<string | null>(null);
  const [shareSeedItems, setShareSeedItems] = useState<MediaItem[]>([]);

  const [searchQuery, setSearchQuery] = useState("");
  const [viewMode, setViewMode] = useState<"grid" | "list">("grid");
  const [usageRecords, setUsageRecords] = useState<Record<string, DailyUsageRecord>>({});
  const [displays, setDisplays] = useState<ConnectedDisplay[]>([]);
  const [keepAwake, setKeepAwake] = useState(true);
  const [cinemaActive, setCinemaActive] = useState(false);
  const [showDisplays, setShowDisplays] = useState(false);
  const [showSettings, setShowSettings] = useState(false);
  const [showSplash, setShowSplash] = useState(true);
  const [showWelcome, setShowWelcome] = useState(false);
  const [showConnectPrompt, setShowConnectPrompt] = useState(false);
  const foldersLoadedRef = useRef(false);
  const hasFoldersRef = useRef(false);

  const isVideoPlayingRef = useRef(false);
  const isAudioPlayingRef = useRef(false);
  const explorerScrollRef = useRef<HTMLDivElement | null>(null);
  const savedScrollTopRef = useRef<number>(0);

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
      foldersLoadedRef.current = true;
      if (savedFolders?.length) {
        hasFoldersRef.current = true;
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
    if (explorerScrollRef.current) {
      savedScrollTopRef.current = explorerScrollRef.current.scrollTop;
    }
    setLastOpenedId(item.id);
    setItems((prev) => prev.map((x) => x.id === item.id ? { ...x, lastOpened: Date.now() } : x));
    setActiveItem(item);
  };

  // Restore exact explorer scroll position when returning from a video/viewer
  useEffect(() => {
    if (!activeItem && explorerScrollRef.current && savedScrollTopRef.current > 0) {
      const targetTop = savedScrollTopRef.current;
      requestAnimationFrame(() => {
        if (explorerScrollRef.current) {
          explorerScrollRef.current.scrollTop = targetTop;
        }
      });
    }
  }, [activeItem, viewMode]);

  const flashFileToast = (msg: string) => {
    setFileToast(msg);
    window.setTimeout(() => setFileToast((cur) => (cur === msg ? null : cur)), 2200);
  };

  const rescanFolders = async () => {
    const all: MediaItem[] = [];
    for (const f of folders) {
      const found = await window.chronoAPI?.scanFolder(f);
      if (found) all.push(...found);
    }
    setItems(all);
  };

  const toggleSelect = (id: string) => {
    setSelectedIds((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id); else next.add(id);
      return next;
    });
  };

  const targetsForItem = (item: MediaItem): MediaItem[] => {
    if (selectedIds.has(item.id) && selectedIds.size > 1) {
      return filteredItems.filter((x) => selectedIds.has(x.id));
    }
    return [item];
  };

  const handleCardClick = (e: React.MouseEvent, item: MediaItem) => {
    if (e.shiftKey && focusedId) {
      const a = filteredItems.findIndex((x) => x.id === focusedId);
      const b = filteredItems.findIndex((x) => x.id === item.id);
      if (a !== -1 && b !== -1) {
        const [lo, hi] = a < b ? [a, b] : [b, a];
        setSelectedIds(new Set(filteredItems.slice(lo, hi + 1).map((x) => x.id)));
        setFocusedId(item.id);
        return;
      }
    }
    if (selectMode || e.ctrlKey || e.metaKey) {
      toggleSelect(item.id);
      setFocusedId(item.id);
    } else {
      // Single click selects (Explorer-style); double-click or Enter plays
      setSelectedIds(new Set([item.id]));
      setFocusedId(item.id);
    }
  };

  // Arrow-key navigation, Enter to play, Esc to clear, Ctrl+C/X/V/A/Delete in explorer
  useEffect(() => {
    if (activeItem || renameTarget || showSettings) return;
    if (selection.type !== "smart" && selection.type !== "folder" && selection.type !== "collection") return;
    const onKey = (e: KeyboardEvent) => {
      const tag = (e.target as HTMLElement)?.tagName;
      if (tag === "INPUT" || tag === "TEXTAREA" || (e.target as HTMLElement)?.isContentEditable) return;
      if (!filteredItems.length) return;

      const mod = e.ctrlKey || e.metaKey;
      const sel = filteredItems.filter((x) => selectedIds.has(x.id));
      if (mod) {
        if (e.key.toLowerCase() === "a") { e.preventDefault(); setSelectedIds(new Set(filteredItems.map((x) => x.id))); return; }
        if (e.key.toLowerCase() === "c" && sel.length) { e.preventDefault(); handleCopyCut(sel, "copy"); return; }
        if (e.key.toLowerCase() === "x" && sel.length) { e.preventDefault(); handleCopyCut(sel, "move"); return; }
        if (e.key.toLowerCase() === "v" && clipboard) { e.preventDefault(); handlePaste(); return; }
        return;
      }

      const curId = focusedId || Array.from(selectedIds)[0] || lastOpenedId;
      const curIdx = curId ? filteredItems.findIndex((x) => x.id === curId) : -1;
      const w = explorerScrollRef.current?.clientWidth || 1000;
      const cols = viewMode === "grid" ? (w >= 1280 ? 5 : w >= 1024 ? 4 : w >= 640 ? 3 : 2) : 1;

      const moveBy = (delta: number) => {
        e.preventDefault();
        const nextIdx = curIdx === -1 ? 0 : Math.max(0, Math.min(filteredItems.length - 1, curIdx + delta));
        const target = filteredItems[nextIdx];
        setFocusedId(target.id);
        setSelectedIds(new Set([target.id]));
        const el = explorerScrollRef.current?.querySelector(`[data-item-id="${CSS.escape(target.id)}"]`);
        el?.scrollIntoView({ block: "nearest" });
      };

      if (e.key === "ArrowLeft") moveBy(-1);
      else if (e.key === "ArrowRight") moveBy(1);
      else if (e.key === "ArrowUp") moveBy(-cols);
      else if (e.key === "ArrowDown") moveBy(cols);
      else if (e.key === "Enter" && curIdx !== -1) { e.preventDefault(); openItem(filteredItems[curIdx]); }
      else if (e.key === "Delete" && sel.length) { e.preventDefault(); handleTrash(sel); }
      else if (e.key === "Escape") { setSelectedIds(new Set()); setSelectMode(false); }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [activeItem, renameTarget, showSettings, selection, filteredItems, focusedId, selectedIds, lastOpenedId, viewMode, clipboard]);

  const handleCopyCut = (targets: MediaItem[], mode: "copy" | "move") => {
    setClipboard({ paths: targets.map((t) => t.path), mode });
    flashFileToast(`${mode === "move" ? "Cut" : "Copied"} ${targets.length} item${targets.length === 1 ? "" : "s"}`);
  };

  const handlePaste = async (destDir: string | null = null) => {
    if (!clipboard?.paths.length || !window.chronoAPI) return;
    const target = destDir || (selection.type === "folder" ? selection.folderPath : null);
    const res = await window.chronoAPI.transferFiles(clipboard.paths, target, clipboard.mode);
    if (res.ok && !res.canceled) {
      if (clipboard.mode === "move") setClipboard(null);
      await rescanFolders();
      flashFileToast(`${clipboard.mode === "move" ? "Moved" : "Pasted"} ${res.transferred?.length || 0} item(s)`);
    }
  };

  const handleMove = async (targets: MediaItem[]) => {
    if (!targets.length || !window.chronoAPI) return;
    const res = await window.chronoAPI.transferFiles(targets.map((t) => t.path), null, "move");
    if (res.ok && !res.canceled) {
      setSelectedIds(new Set());
      await rescanFolders();
      flashFileToast(`Moved ${res.transferred?.length || 0} item(s)`);
    }
  };

  const handleDuplicate = async (targets: MediaItem[]) => {
    if (!targets.length || !window.chronoAPI) return;
    const res = await window.chronoAPI.duplicateFiles(targets.map((t) => t.path));
    if (res.ok) {
      await rescanFolders();
      flashFileToast(`Duplicated ${res.created.length} item(s)`);
    }
  };

  const handleTrash = async (targets: MediaItem[]) => {
    if (!targets.length || !window.chronoAPI) return;
    const res = await window.chronoAPI.trashFiles(targets.map((t) => t.path));
    if (res.ok) {
      const removed = new Set(res.trashed);
      setItems((prev) => prev.filter((x) => !removed.has(x.path)));
      setSelectedIds((prev) => {
        const next = new Set(prev);
        targets.forEach((t) => next.delete(t.id));
        return next;
      });
      flashFileToast(`Moved ${res.trashed.length} item(s) to Recycle Bin`);
    }
  };

  const commitRename = async () => {
    if (!renameTarget || !window.chronoAPI) return;
    const res = await window.chronoAPI.renameFile(renameTarget.path, renameDraft);
    if (res.ok && res.newPath && res.newName) {
      setItems((prev) => prev.map((x) => x.id === renameTarget.id ? { ...x, id: res.newPath!, path: res.newPath!, name: res.newName! } : x));
      if (lastOpenedId === renameTarget.id) setLastOpenedId(res.newPath);
      flashFileToast(`Renamed to ${res.newName}`);
      setRenameTarget(null);
    }
  };

  // Close right-click menu on outside click
  useEffect(() => {
    if (!contextMenu) return;
    const close = () => setContextMenu(null);
    window.addEventListener("click", close);
    return () => window.removeEventListener("click", close);
  }, [contextMenu]);

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
                <div className="flex items-center gap-1.5 px-2.5 pb-1">
                  <span className="text-[11px] font-semibold uppercase tracking-wider" style={{ color: "var(--cs-text-tertiary)" }}>Folders</span>
                  <button onClick={addFolder} className="flex h-4 w-4 items-center justify-center rounded-full hover:bg-teal-600 hover:text-white cursor-pointer" style={{ background: "var(--cs-surface-subtle)" }} title="Add Folder"><Plus size={11} /></button>
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
                  <button
                    onClick={() => { setSelectMode((s) => !s); if (selectMode) setSelectedIds(new Set()); }}
                    className={`rounded-lg border px-2.5 py-1.5 text-xs font-medium cursor-pointer ${selectMode ? "text-white" : ""}`}
                    style={selectMode ? { borderColor: "var(--cs-accent)", background: "var(--cs-accent)" } : { borderColor: "var(--cs-border)", background: "var(--cs-canvas)" }}
                  >
                    {selectMode ? "Done Selecting" : "Select"}
                  </button>
                  {clipboard && (
                    <button
                      onClick={() => handlePaste()}
                      className="rounded-lg px-2.5 py-1.5 text-xs font-medium text-white cursor-pointer"
                      style={{ background: "var(--cs-accent)" }}
                    >
                      Paste ({clipboard.paths.length})
                    </button>
                  )}
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

              {(selectMode || selectedIds.size > 1) && (
                <div className="flex flex-wrap items-center justify-between gap-2 border-b px-5 py-2 text-xs" style={{ borderColor: "var(--cs-border)", background: "var(--cs-accent-soft)" }}>
                  <div className="flex items-center gap-2">
                    <span className="font-semibold">{selectedIds.size > 0 ? `${selectedIds.size} selected` : "Click or Ctrl+Click items to select"}</span>
                    <button onClick={() => setSelectedIds(new Set(filteredItems.map((i) => i.id)))} className="rounded bg-white/70 px-2 py-0.5 font-medium cursor-pointer dark:bg-black/30">Select All</button>
                    {selectedIds.size > 0 && <button onClick={() => setSelectedIds(new Set())} className="rounded bg-white/70 px-2 py-0.5 cursor-pointer dark:bg-black/30">Clear</button>}
                  </div>
                  <div className="flex items-center gap-1.5">
                    {(() => {
                      const sel = filteredItems.filter((i) => selectedIds.has(i.id));
                      return (
                        <>
                          <button disabled={!sel.length} onClick={() => handleCopyCut(sel, "move")} className="rounded bg-white/80 px-2 py-1 font-medium disabled:opacity-40 cursor-pointer dark:bg-black/30">Cut</button>
                          <button disabled={!sel.length} onClick={() => handleCopyCut(sel, "copy")} className="rounded bg-white/80 px-2 py-1 font-medium disabled:opacity-40 cursor-pointer dark:bg-black/30">Copy</button>
                          <button disabled={!sel.length} onClick={() => handleMove(sel)} className="rounded bg-white/80 px-2 py-1 font-medium disabled:opacity-40 cursor-pointer dark:bg-black/30">Move…</button>
                          <button disabled={!sel.length} onClick={() => handleTrash(sel)} className="rounded bg-red-600 px-2 py-1 font-medium text-white disabled:opacity-40 cursor-pointer">Delete</button>
                        </>
                      );
                    })()}
                  </div>
                </div>
              )}

              {filteredItems.length === 0 ? (
                <div className="flex flex-1 flex-col items-center justify-center p-8 text-center space-y-3">
                  <FolderPlus size={40} style={{ color: "var(--cs-text-tertiary)" }} />
                  <div className="text-base font-semibold">No media items here yet</div>
                  <p className="text-xs max-w-sm" style={{ color: "var(--cs-text-secondary)" }}>Add a folder containing videos, music, photos, or PDFs to start browsing.</p>
                  <button onClick={addFolder} className="rounded-lg px-4 py-2 text-xs font-semibold text-white cursor-pointer" style={{ background: "var(--cs-accent)" }}>Open Folder…</button>
                </div>
              ) : viewMode === "grid" ? (
                <div ref={explorerScrollRef} className="flex-1 overflow-y-auto p-5 grid grid-cols-2 gap-4 sm:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5 auto-rows-max">
                  {filteredItems.map((item) => {
                    const isLastPlayed = item.id === lastOpenedId;
                    const isSelected = selectedIds.has(item.id);
                    return (
                      <div
                        key={item.id}
                        data-item-id={item.id}
                        draggable
                        onDragStart={(e) => {
                          e.preventDefault();
                          window.chronoAPI?.startFileDrag(item.path);
                        }}
                        onContextMenu={(e) => {
                          e.preventDefault();
                          setContextMenu({ x: e.clientX, y: e.clientY, item });
                        }}
                        onDoubleClick={() => openItem(item)}
                        onClick={(e) => handleCardClick(e, item)}
                        className={`cs-card group rounded-2xl p-3 cursor-pointer transition hover:-translate-y-0.5 space-y-2 ${isSelected ? "ring-2 ring-blue-500 shadow-md" : isLastPlayed ? "ring-2 ring-teal-500 shadow-md" : ""}`}
                        style={isSelected || isLastPlayed ? { background: "var(--cs-accent-soft)" } : undefined}
                      >
                        <div className="relative flex h-28 items-center justify-center overflow-hidden rounded-xl" style={{ background: "var(--cs-surface-subtle)" }}>
                          {item.kind === "image" && window.chronoAPI ? (
                            <img src={window.chronoAPI.mediaUrl(item.path)} alt={item.name} loading="lazy" className="h-full w-full object-cover" />
                          ) : item.kind === "video" ? (
                            <Film size={28} style={{ color: "var(--cs-accent)" }} />
                          ) : item.kind === "audio" ? (
                            <Music size={28} style={{ color: "var(--cs-accent)" }} />
                          ) : (
                            <FileText size={28} style={{ color: "var(--cs-accent)" }} />
                          )}
                          {isLastPlayed && (
                            <span className="absolute left-2 top-2 rounded-full bg-teal-600 px-2 py-0.5 text-[10px] font-semibold text-white shadow">
                              Last Played
                            </span>
                          )}
                          {(selectMode || isSelected) && (
                            <span className={`absolute right-2 top-2 flex h-5 w-5 items-center justify-center rounded-full text-[11px] font-bold ${isSelected ? "bg-teal-700 text-white" : "bg-black/35 text-white"}`}>
                              {isSelected ? "✓" : ""}
                            </span>
                          )}
                        </div>
                        <div className="flex items-start justify-between gap-1">
                          <div className="min-w-0">
                            <div className={`truncate text-xs font-semibold ${isSelected || isLastPlayed ? "text-teal-700 dark:text-teal-300" : ""}`}>{item.name}</div>
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
                    );
                  })}
                </div>
              ) : (
                <div ref={explorerScrollRef} className="flex-1 overflow-y-auto p-3 space-y-1">
                  {filteredItems.map((item) => {
                    const isLastPlayed = item.id === lastOpenedId;
                    const isSelected = selectedIds.has(item.id);
                    return (
                      <div
                        key={item.id}
                        data-item-id={item.id}
                        draggable
                        onDragStart={(e) => {
                          e.preventDefault();
                          window.chronoAPI?.startFileDrag(item.path);
                        }}
                        onContextMenu={(e) => {
                          e.preventDefault();
                          setContextMenu({ x: e.clientX, y: e.clientY, item });
                        }}
                        onClick={(e) => handleCardClick(e, item)}
                        onDoubleClick={() => openItem(item)}
                        className={`flex items-center justify-between rounded-xl px-3 py-2 hover:bg-black/5 cursor-pointer text-xs ${isSelected ? "ring-1 ring-teal-700" : isLastPlayed ? "ring-1 ring-teal-500" : ""}`}
                        style={isSelected || isLastPlayed ? { background: "var(--cs-accent-soft)" } : undefined}
                      >
                        <div className="flex items-center gap-3 min-w-0">
                          {item.kind === "video" ? <Film size={15} style={{ color: "var(--cs-accent)" }} /> : item.kind === "audio" ? <Music size={15} style={{ color: "var(--cs-accent)" }} /> : item.kind === "pdf" ? <FileText size={15} style={{ color: "var(--cs-accent)" }} /> : <ImageIcon size={15} style={{ color: "var(--cs-accent)" }} />}
                          <span className={`truncate font-medium ${isLastPlayed ? "font-semibold text-teal-700 dark:text-teal-300" : ""}`}>{item.name}</span>
                          {isLastPlayed && (
                            <span className="shrink-0 rounded-full bg-teal-600 px-2 py-0.5 text-[10px] font-semibold text-white">Last Played</span>
                          )}
                        </div>
                        <div className="flex items-center gap-4 shrink-0" style={{ color: "var(--cs-text-secondary)" }}>
                          <span className="font-mono text-[11px]">{item.ext}</span>
                          <span className="w-16 text-right tabular-nums">{formatBytes(item.fileSize)}</span>
                          <button onClick={(e) => { e.stopPropagation(); shareItem(item); }} className="cursor-pointer opacity-70 hover:opacity-100"><Share2 size={13} /></button>
                        </div>
                      </div>
                    );
                  })}
                </div>
              )}
            </div>
          )}
        </main>
      </div>

      {contextMenu && (
        <div
          className="fixed z-50 w-52 rounded-xl border py-1.5 text-xs shadow-xl"
          style={{ left: Math.min(contextMenu.x, window.innerWidth - 220), top: Math.min(contextMenu.y, window.innerHeight - 320), borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}
          onClick={(e) => e.stopPropagation()}
        >
          {(() => {
            const targets = targetsForItem(contextMenu.item);
            const suf = targets.length > 1 ? ` (${targets.length})` : "";
            const run = (fn: () => void) => { setContextMenu(null); fn(); };
            return (
              <>
                <button onClick={() => run(() => openItem(contextMenu.item))} className="flex w-full px-3 py-1.5 text-left hover:bg-black/5 cursor-pointer">Open</button>
                <button onClick={() => run(() => toggleSelect(contextMenu.item.id))} className="flex w-full px-3 py-1.5 text-left hover:bg-black/5 cursor-pointer">{selectedIds.has(contextMenu.item.id) ? "Deselect" : "Select"}</button>
                <div className="my-1 border-t" style={{ borderColor: "var(--cs-border)" }} />
                <button onClick={() => run(() => handleCopyCut(targets, "move"))} className="flex w-full px-3 py-1.5 text-left hover:bg-black/5 cursor-pointer">Cut{suf}</button>
                <button onClick={() => run(() => handleCopyCut(targets, "copy"))} className="flex w-full px-3 py-1.5 text-left hover:bg-black/5 cursor-pointer">Copy{suf}</button>
                {clipboard && <button onClick={() => run(() => handlePaste())} className="flex w-full px-3 py-1.5 text-left hover:bg-black/5 cursor-pointer">Paste Here</button>}
                <button onClick={() => run(() => handleDuplicate(targets))} className="flex w-full px-3 py-1.5 text-left hover:bg-black/5 cursor-pointer">Duplicate{suf}</button>
                {targets.length === 1 && (
                  <button onClick={() => run(() => { setRenameDraft(contextMenu.item.name); setRenameTarget(contextMenu.item); })} className="flex w-full px-3 py-1.5 text-left hover:bg-black/5 cursor-pointer">Rename…</button>
                )}
                <button onClick={() => run(() => handleMove(targets))} className="flex w-full px-3 py-1.5 text-left hover:bg-black/5 cursor-pointer">Move to Folder…{suf}</button>
                <div className="my-1 border-t" style={{ borderColor: "var(--cs-border)" }} />
                <button onClick={() => run(() => shareItem(contextMenu.item))} className="flex w-full px-3 py-1.5 text-left hover:bg-black/5 cursor-pointer">Share via Wi-Fi QR</button>
                <button onClick={() => run(() => window.chronoAPI?.revealInExplorer(contextMenu.item.path))} className="flex w-full px-3 py-1.5 text-left hover:bg-black/5 cursor-pointer">Reveal in Explorer</button>
                <div className="my-1 border-t" style={{ borderColor: "var(--cs-border)" }} />
                <button onClick={() => run(() => handleTrash(targets))} className="flex w-full px-3 py-1.5 text-left text-red-600 hover:bg-red-500/10 cursor-pointer">Move to Recycle Bin{suf}</button>
              </>
            );
          })()}
        </div>
      )}

      {renameTarget && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4">
          <div className="w-full max-w-sm rounded-2xl border p-5 shadow-2xl space-y-4" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
            <div className="text-sm font-bold">Rename File</div>
            <input
              autoFocus
              value={renameDraft}
              onChange={(e) => setRenameDraft(e.target.value)}
              onKeyDown={(e) => { if (e.key === "Enter") commitRename(); if (e.key === "Escape") setRenameTarget(null); }}
              className="w-full rounded-lg border px-3 py-2 text-xs outline-none"
              style={{ borderColor: "var(--cs-border)", background: "var(--cs-canvas)" }}
            />
            <div className="flex justify-end gap-2 text-xs">
              <button onClick={() => setRenameTarget(null)} className="rounded-lg border px-3 py-1.5 cursor-pointer" style={{ borderColor: "var(--cs-border)" }}>Cancel</button>
              <button onClick={commitRename} className="rounded-lg bg-teal-600 px-3 py-1.5 font-semibold text-white cursor-pointer">Rename</button>
            </div>
          </div>
        </div>
      )}

      {fileToast && (
        <div className="fixed bottom-5 left-1/2 z-50 -translate-x-1/2 rounded-full border border-teal-500/40 bg-black/80 px-4 py-2 text-xs font-medium text-white shadow-lg">
          {fileToast}
        </div>
      )}

      {showSplash && (
        <SplashScreen
          onFinished={() => {
            setShowSplash(false);
            if (localStorage.getItem("cs_onboarding_v2") !== "1") {
              setShowWelcome(true);
            } else if (!hasFoldersRef.current && folders.length === 0) {
              setShowConnectPrompt(true);
            }
          }}
        />
      )}

      {showWelcome && (
        <WelcomeSlidesModal
          onAddFolder={() => {
            localStorage.setItem("cs_onboarding_v2", "1");
            setShowWelcome(false);
            addFolder();
          }}
          onStart={() => {
            localStorage.setItem("cs_onboarding_v2", "1");
            setShowWelcome(false);
            if (!hasFoldersRef.current && folders.length === 0) {
              setShowConnectPrompt(true);
            }
          }}
        />
      )}

      {showConnectPrompt && (
        <div className="fixed inset-0 z-[85] flex items-center justify-center bg-black/45 p-4 backdrop-blur-sm">
          <div className="w-full max-w-md rounded-2xl border p-6 text-center shadow-2xl space-y-4" style={{ background: "var(--cs-surface)", borderColor: "var(--cs-border)" }}>
            <div className="mx-auto flex h-14 w-14 items-center justify-center rounded-2xl bg-teal-600/15 text-teal-600">
              <FolderPlus size={26} />
            </div>
            <div className="space-y-1.5">
              <h3 className="text-base font-bold">Connect a Media Folder</h3>
              <p className="text-xs leading-relaxed" style={{ color: "var(--cs-text-secondary)" }}>
                Hey! Connect any folder with your videos, music, photos, or PDFs so ChronoStream can show your library right away.
              </p>
            </div>
            <div className="flex justify-center gap-2.5 pt-1 text-xs">
              <button onClick={() => setShowConnectPrompt(false)} className="rounded-lg border px-4 py-2 font-medium cursor-pointer" style={{ borderColor: "var(--cs-border)" }}>
                Not Now
              </button>
              <button onClick={() => { setShowConnectPrompt(false); addFolder(); }} className="inline-flex items-center gap-1.5 rounded-lg px-4 py-2 font-semibold text-white cursor-pointer" style={{ background: "var(--cs-accent)" }}>
                <FolderPlus size={14} /> Connect Folder…
              </button>
            </div>
          </div>
        </div>
      )}

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
