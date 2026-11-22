import React, { useEffect, useState } from "react";
import {
  ChevronLeft, PanelLeft, Bookmark, BookmarkCheck, Maximize2, Minimize2,
  Share2, Plus, Trash2, BookOpen
} from "lucide-react";
import { MediaItem } from "../types";

type ReadingTheme = "paper" | "sepia" | "eink" | "night";

interface BookNote {
  id: string;
  page: number;
  text: string;
  createdAt: number;
}

interface BookState {
  lastPage: number;
  bookmarks: number[];
  notes: BookNote[];
}

interface Props {
  item: MediaItem;
  onShare: (item: MediaItem) => void;
  onClose: () => void;
}

export default function PDFReaderView({ item, onShare, onClose }: Props) {
  const [readingTheme, setReadingTheme] = useState<ReadingTheme>(() => (localStorage.getItem("cs_pdf_theme") as ReadingTheme) || "paper");
  const [showSidebar, setShowSidebar] = useState(true);
  const [sidebarTab, setSidebarTab] = useState<"bookmarks" | "notes">("bookmarks");
  const [zenMode, setZenMode] = useState(false);

  const [currentPage, setCurrentPage] = useState(1);
  const [bookmarks, setBookmarks] = useState<number[]>([]);
  const [notes, setNotes] = useState<BookNote[]>([]);
  const [noteInput, setNoteInput] = useState("");
  const [jumpInput, setJumpInput] = useState("");
  const [reloadNonce, setReloadNonce] = useState(0);

  const baseSrc = window.chronoAPI ? window.chronoAPI.mediaUrl(item.path) : item.path;
  const pdfSrc = `${baseSrc}#page=${currentPage}&view=FitH&n=${reloadNonce}`;

  useEffect(() => {
    localStorage.setItem("cs_pdf_theme", readingTheme);
  }, [readingTheme]);

  // Load saved reading progress, bookmarks & notes for this book
  useEffect(() => {
    (async () => {
      const all = (await window.chronoAPI?.loadState<Record<string, BookState>>("pdf_reader_state")) || {};
      const st = all[item.path];
      if (st) {
        setCurrentPage(Math.max(1, st.lastPage || 1));
        setBookmarks(st.bookmarks || []);
        setNotes(st.notes || []);
      } else {
        setCurrentPage(1);
        setBookmarks([]);
        setNotes([]);
      }
    })();
  }, [item.path]);

  const persistState = async (nextPage: number, nextBookmarks: number[], nextNotes: BookNote[]) => {
    if (!window.chronoAPI) return;
    const all = (await window.chronoAPI.loadState<Record<string, BookState>>("pdf_reader_state")) || {};
    all[item.path] = { lastPage: nextPage, bookmarks: nextBookmarks, notes: nextNotes };
    await window.chronoAPI.saveState("pdf_reader_state", all);
  };

  const goToPage = (p: number) => {
    const clean = Math.max(1, p);
    setCurrentPage(clean);
    setReloadNonce((n) => n + 1);
    persistState(clean, bookmarks, notes);
  };

  const toggleBookmark = () => {
    const exists = bookmarks.includes(currentPage);
    const next = exists ? bookmarks.filter((b) => b !== currentPage) : [...bookmarks, currentPage].sort((a, b) => a - b);
    setBookmarks(next);
    persistState(currentPage, next, notes);
  };

  const addNote = () => {
    const trimmed = noteInput.trim();
    if (!trimmed) return;
    const next: BookNote[] = [{ id: String(Date.now()), page: currentPage, text: trimmed, createdAt: Date.now() }, ...notes];
    setNotes(next);
    setNoteInput("");
    persistState(currentPage, bookmarks, next);
  };

  const deleteNote = (id: string) => {
    const next = notes.filter((n) => n.id !== id);
    setNotes(next);
    persistState(currentPage, bookmarks, next);
  };

  const iframeFilter =
    readingTheme === "sepia" ? "sepia(0.32) contrast(0.96) brightness(0.97)" :
    readingTheme === "eink" ? "grayscale(0.75) contrast(0.92) brightness(0.96)" :
    readingTheme === "night" ? "invert(0.91) hue-rotate(180deg) contrast(0.92)" : "none";

  const isBookmarked = bookmarks.includes(currentPage);

  return (
    <div className="flex h-full flex-col overflow-hidden">
      {/* Top Book Reader Toolbar */}
      {!zenMode && (
        <div className="flex flex-wrap items-center justify-between gap-2 border-b px-4 py-2" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
          <div className="flex items-center gap-2 min-w-0">
            <button onClick={onClose} className="inline-flex items-center gap-1 rounded-lg border px-2.5 py-1 text-xs font-medium cursor-pointer" style={{ borderColor: "var(--cs-border)" }}>
              <ChevronLeft size={14} /> Library
            </button>
            <button onClick={() => setShowSidebar((s) => !s)} className="rounded-lg border p-1.5 cursor-pointer" style={{ borderColor: "var(--cs-border)" }} title="Toggle Bookmarks & Notes">
              <PanelLeft size={14} />
            </button>
            <BookOpen size={15} style={{ color: "var(--cs-accent)" }} className="shrink-0" />
            <span className="truncate text-sm font-semibold max-w-xs">{item.name}</span>
          </div>

          <div className="flex items-center gap-2">
            {/* 4 Eye-Friendly Reading Themes */}
            <div className="inline-flex items-center gap-1 rounded-lg p-1 text-xs" style={{ background: "var(--cs-surface-subtle)" }}>
              {([
                ["paper", "Paper", "#FFFFFF"],
                ["sepia", "Sepia", "#F5E9D0"],
                ["eink", "Gray", "#E2E5E8"],
                ["night", "Night", "#1C1F24"]
              ] as const).map(([key, label, swatch]) => (
                <button
                  key={key}
                  onClick={() => setReadingTheme(key)}
                  className="inline-flex items-center gap-1.5 rounded-md px-2 py-1 cursor-pointer"
                  style={{ background: readingTheme === key ? "var(--cs-surface)" : "transparent" }}
                >
                  <span className="h-2.5 w-2.5 rounded-full border border-black/20" style={{ background: swatch }} />
                  <span>{label}</span>
                </button>
              ))}
            </div>

            <button
              onClick={toggleBookmark}
              className="inline-flex items-center gap-1 rounded-lg border px-2.5 py-1 text-xs font-medium cursor-pointer"
              style={{ borderColor: "var(--cs-border)", color: isBookmarked ? "var(--cs-accent)" : "var(--cs-text)" }}
              title="Bookmark Current Page"
            >
              {isBookmarked ? <BookmarkCheck size={14} /> : <Bookmark size={14} />}
              <span>p.{currentPage}</span>
            </button>

            <button onClick={() => setZenMode(true)} className="rounded-lg border p-1.5 cursor-pointer" style={{ borderColor: "var(--cs-border)" }} title="Zen Reading Focus Mode">
              <Maximize2 size={14} />
            </button>

            <button onClick={() => onShare(item)} className="rounded-lg border p-1.5 cursor-pointer" style={{ borderColor: "var(--cs-border)" }} title="Share via Wi-Fi QR">
              <Share2 size={14} />
            </button>
          </div>
        </div>
      )}

      {/* Main Split Reader */}
      <div className="flex flex-1 overflow-hidden">
        {showSidebar && !zenMode && (
          <aside className="flex w-64 shrink-0 flex-col border-r" style={{ borderColor: "var(--cs-border)", background: "var(--cs-sidebar)" }}>
            <div className="p-2.5 border-b" style={{ borderColor: "var(--cs-border)" }}>
              <div className="grid grid-cols-2 rounded-lg p-0.5 text-xs" style={{ background: "var(--cs-surface-subtle)" }}>
                <button onClick={() => setSidebarTab("bookmarks")} className="rounded-md py-1 font-medium cursor-pointer" style={{ background: sidebarTab === "bookmarks" ? "var(--cs-surface)" : "transparent" }}>
                  Bookmarks ({bookmarks.length})
                </button>
                <button onClick={() => setSidebarTab("notes")} className="rounded-md py-1 font-medium cursor-pointer" style={{ background: sidebarTab === "notes" ? "var(--cs-surface)" : "transparent" }}>
                  Notes ({notes.length})
                </button>
              </div>
            </div>

            {sidebarTab === "bookmarks" ? (
              <div className="flex-1 overflow-y-auto p-2.5 space-y-1.5">
                {bookmarks.length === 0 ? (
                  <div className="p-4 text-center text-xs space-y-2" style={{ color: "var(--cs-text-tertiary)" }}>
                    <p>No bookmarks yet.</p>
                    <button onClick={toggleBookmark} className="rounded-lg border px-3 py-1 text-xs cursor-pointer" style={{ borderColor: "var(--cs-border)", color: "var(--cs-text)" }}>
                      Bookmark Page {currentPage}
                    </button>
                  </div>
                ) : (
                  bookmarks.map((p) => (
                    <div key={p} className="flex items-center justify-between rounded-lg px-2.5 py-2 text-xs" style={{ background: p === currentPage ? "var(--cs-accent-soft)" : "var(--cs-surface)" }}>
                      <button onClick={() => goToPage(p)} className="flex items-center gap-2 font-medium cursor-pointer" style={{ color: p === currentPage ? "var(--cs-accent)" : "var(--cs-text)" }}>
                        <BookmarkCheck size={13} /> Page {p}
                      </button>
                      <button onClick={() => { const next = bookmarks.filter((x) => x !== p); setBookmarks(next); persistState(currentPage, next, notes); }} className="opacity-60 hover:opacity-100 cursor-pointer">
                        <Trash2 size={12} />
                      </button>
                    </div>
                  ))
                )}
              </div>
            ) : (
              <div className="flex flex-1 flex-col overflow-hidden">
                <div className="p-2.5 border-b space-y-2" style={{ borderColor: "var(--cs-border)" }}>
                  <textarea
                    value={noteInput}
                    onChange={(e) => setNoteInput(e.target.value)}
                    placeholder={`Write a study note for Page ${currentPage}…`}
                    rows={3}
                    className="w-full rounded-lg border p-2 text-xs outline-none resize-none"
                    style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}
                  />
                  <button
                    disabled={!noteInput.trim()}
                    onClick={addNote}
                    className="flex w-full items-center justify-center gap-1 rounded-lg py-1.5 text-xs font-medium text-white disabled:opacity-40 cursor-pointer"
                    style={{ background: "var(--cs-accent)" }}
                  >
                    <Plus size={13} /> Save Note (Page {currentPage})
                  </button>
                </div>

                <div className="flex-1 overflow-y-auto p-2.5 space-y-2">
                  {notes.map((n) => (
                    <div key={n.id} className="rounded-lg border p-2.5 text-xs space-y-1" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
                      <div className="flex items-center justify-between">
                        <button onClick={() => goToPage(n.page)} className="font-semibold cursor-pointer" style={{ color: "var(--cs-accent)" }}>Page {n.page}</button>
                        <button onClick={() => deleteNote(n.id)} className="opacity-60 hover:opacity-100 cursor-pointer"><Trash2 size={12} /></button>
                      </div>
                      <p className="leading-relaxed whitespace-pre-wrap">{n.text}</p>
                    </div>
                  ))}
                </div>
              </div>
            )}
          </aside>
        )}

        {/* PDF Book Canvas */}
        <div className="relative flex-1 overflow-hidden bg-zinc-900">
          <iframe
            key={pdfSrc}
            src={pdfSrc}
            title={item.name}
            style={{ filter: iframeFilter }}
            className="h-full w-full border-0 bg-white transition-[filter] duration-200"
          />

          {zenMode && (
            <button
              onClick={() => setZenMode(false)}
              className="absolute right-4 top-4 inline-flex items-center gap-1.5 rounded-lg px-3 py-1.5 text-xs font-semibold text-white shadow-lg cursor-pointer"
              style={{ background: "var(--cs-accent)" }}
            >
              <Minimize2 size={13} /> Exit Focus
            </button>
          )}
        </div>
      </div>

      {/* Bottom Reading Navigation Bar */}
      {!zenMode && (
        <div className="flex items-center justify-between border-t px-4 py-2 text-xs" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
          <div className="flex items-center gap-2">
            <button onClick={() => goToPage(currentPage - 1)} disabled={currentPage <= 1} className="rounded border px-2 py-0.5 disabled:opacity-40 cursor-pointer" style={{ borderColor: "var(--cs-border)" }}>Prev</button>
            <span className="font-mono font-medium">Page {currentPage}</span>
            <button onClick={() => goToPage(currentPage + 1)} className="rounded border px-2 py-0.5 cursor-pointer" style={{ borderColor: "var(--cs-border)" }}>Next</button>
          </div>

          <form
            onSubmit={(e) => {
              e.preventDefault();
              const n = parseInt(jumpInput, 10);
              if (!Number.isNaN(n) && n >= 1) goToPage(n);
              setJumpInput("");
            }}
            className="flex items-center gap-1.5"
          >
            <span style={{ color: "var(--cs-text-secondary)" }}>Jump to page:</span>
            <input
              value={jumpInput}
              onChange={(e) => setJumpInput(e.target.value)}
              placeholder="#"
              className="w-14 rounded border px-2 py-0.5 text-center outline-none"
              style={{ borderColor: "var(--cs-border)", background: "var(--cs-canvas)" }}
            />
          </form>
        </div>
      )}
    </div>
  );
}
