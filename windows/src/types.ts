export type MediaKind = "video" | "audio" | "image" | "pdf" | "file";

export interface MediaItem {
  id: string;
  path: string;
  name: string;
  kind: MediaKind;
  ext: string;
  fileSize: number;
  modifiedAt: number;
  partialHash?: string | null;
  isFavorite?: boolean;
  lastPosition?: number;
  duration?: number;
  lastOpened?: number;
}

export interface CustomCollection {
  id: string;
  name: string;
  itemIds: string[];
}

export type SmartSection =
  | "all"
  | "continue"
  | "videos"
  | "audio"
  | "photos"
  | "documents"
  | "favorites"
  | "recent"
  | "duplicates";

export type SidebarSelection =
  | { type: "dashboard" }
  | { type: "smart"; smart: SmartSection }
  | { type: "folder"; folderPath: string }
  | { type: "collection"; id: string }
  | { type: "docWriter" }
  | { type: "photoStudio" }
  | { type: "videoStudio" }
  | { type: "wifiShare" };

export interface DailyUsageRecord {
  dateKey: string;
  appSeconds: number;
  videoWatchedSeconds: number;
  audioListenedSeconds: number;
}

export interface ConnectedDisplay {
  id: number;
  name: string;
  width: number;
  height: number;
  refreshRateHz: number;
  scaleFactor: number;
  isBuiltIn: boolean;
  isMain: boolean;
}

export interface ReceivedFile {
  path: string;
  name: string;
  size: number;
  receivedAt: number;
}

export interface SavedDoc {
  path: string;
  title: string;
  ext: string;
  size: number;
  modifiedAt: number;
}

export function formatBytes(bytes: number): string {
  if (!bytes || bytes <= 0) return "0 B";
  const units = ["B", "KB", "MB", "GB", "TB"];
  const idx = Math.min(units.length - 1, Math.floor(Math.log(bytes) / Math.log(1024)));
  return `${(bytes / Math.pow(1024, idx)).toFixed(idx === 0 ? 0 : 1)} ${units[idx]}`;
}

export function formatTime(sec: number): string {
  if (!Number.isFinite(sec) || sec < 0) return "0:00";
  const total = Math.floor(sec);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  return `${m}:${String(s).padStart(2, "0")}`;
}

export function formatHoursMinutes(seconds: number): string {
  const totalMin = Math.round(seconds / 60);
  if (totalMin < 1) return seconds > 0 ? `${Math.round(seconds)}s` : "0m";
  const h = Math.floor(totalMin / 60);
  const m = totalMin % 60;
  if (h > 0) return m > 0 ? `${h}h ${m}m` : `${h}h`;
  return `${m}m`;
}

export function playSubtleClickSound(enabled: boolean) {
  if (!enabled) return;
  try {
    const AudioCtx = window.AudioContext || (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
    if (!AudioCtx) return;
    const ctx = new AudioCtx();
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.type = "sine";
    osc.frequency.setValueAtTime(1180, ctx.currentTime);
    osc.frequency.exponentialRampToValueAtTime(640, ctx.currentTime + 0.032);
    gain.gain.setValueAtTime(0.04, ctx.currentTime);
    gain.gain.exponentialRampToValueAtTime(0.0001, ctx.currentTime + 0.035);
    osc.connect(gain);
    gain.connect(ctx.destination);
    osc.start();
    osc.stop(ctx.currentTime + 0.036);
    setTimeout(() => ctx.close(), 80);
  } catch {}
}

declare global {
  interface Window {
    chronoAPI?: {
      mediaUrl: (p: string) => string;
      pickFolders: () => Promise<string[]>;
      pickFiles: () => Promise<string[]>;
      scanFolder: (p: string) => Promise<MediaItem[]>;
      revealInExplorer: (p: string) => Promise<void>;
      openInboxFolder: () => Promise<void>;
      readTextFile: (p: string) => Promise<string | null>;
      writeTextFile: (p: string, content: string) => Promise<{ ok: boolean; error?: string }>;
      openExternalFile: (p: string) => Promise<string>;
      saveSnapshot: (dataUrl: string, baseName: string) => Promise<{ ok: boolean; path?: string; name?: string; error?: string }>;
      renameFile: (p: string, newName: string) => Promise<{ ok: boolean; newPath?: string; newName?: string; error?: string }>;
      trashFiles: (paths: string[]) => Promise<{ ok: boolean; trashed: string[] }>;
      duplicateFiles: (paths: string[]) => Promise<{ ok: boolean; created: string[] }>;
      transferFiles: (paths: string[], destDir: string | null, mode: "copy" | "move") => Promise<{ ok: boolean; canceled?: boolean; destDir?: string; transferred?: { from: string; to: string }[] }>;
      startFileDrag: (p: string) => void;
      loadState: <T>(key: string) => Promise<T | null>;
      saveState: (key: string, value: unknown) => Promise<boolean>;
      prepareVideoPlayback: (p: string) => Promise<{ path: string; remuxed: boolean; error?: string }>;
      runVideoStudioOp: (payload: Record<string, unknown>) => Promise<{ ok: boolean; outputPath?: string; error?: string; canceled?: boolean }>;
      getDisplays: () => Promise<{ displays: ConnectedDisplay[]; keepAwake: boolean; cinemaActive: boolean; localIP: string | null }>;
      setKeepAwake: (on: boolean) => Promise<boolean>;
      moveToDisplay: (id: number) => Promise<boolean>;
      startCinema: (mediaUrl: string, displayId?: number) => Promise<boolean>;
      stopCinema: () => Promise<boolean>;
      onDisplaysChanged: (cb: (displays: ConnectedDisplay[]) => void) => () => void;
      startWiFiSend: (paths: string[], requirePin: boolean) => Promise<{ shareURL: string; qrDataUrl: string; pin: string; requirePin: boolean; expiresAt: number }>;
      stopWiFiSend: () => Promise<boolean>;
      startWiFiReceive: () => Promise<{ receiverURL: string; qrDataUrl: string; pin: string; expiresAt: number }>;
      rotateReceivePIN: () => Promise<string | null>;
      stopWiFiReceive: () => Promise<boolean>;
      listInbox: () => Promise<ReceivedFile[]>;
      onReceivedWiFiFile: (cb: (file: ReceivedFile) => void) => () => void;
      listSavedDocs: () => Promise<SavedDoc[]>;
      saveDocx: (payload: { title: string; plainText: string; existingPath?: string | null }) => Promise<{ ok: boolean; path: string; name: string }>;
      openDocx: (filePath?: string) => Promise<{ path: string; title: string; html: string } | null>;
      exportDocPDF: (payload: { title: string; html: string }) => Promise<{ ok: boolean; path?: string }>;
      deleteDoc: (filePath: string) => Promise<boolean>;
      openDocsFolder: () => Promise<void>;
    };
  }
}
