import React, { useEffect, useRef, useState } from "react";
import {
  PanelLeft, FileText, Save, FileDown, Bold, Italic, Underline,
  AlignLeft, AlignCenter, AlignRight, List, ListOrdered, Table,
  Code, Highlighter, FolderOpen, Plus, Trash2
} from "lucide-react";
import { SavedDoc, formatBytes } from "../types";

export default function DocumentStudioView() {
  const editorRef = useRef<HTMLDivElement>(null);
  const [title, setTitle] = useState("Untitled Document");
  const [currentPath, setCurrentPath] = useState<string | null>(null);
  const [isDirty, setIsDirty] = useState(false);
  const [showSidebar, setShowSidebar] = useState(true);
  const [teachMode, setTeachMode] = useState(false);
  const [zoom, setZoom] = useState(100);
  const [savedDocs, setSavedDocs] = useState<SavedDoc[]>([]);
  const [status, setStatus] = useState<string | null>(null);
  const [stats, setStats] = useState({ words: 0, chars: 0 });

  const refreshDocs = async () => {
    if (!window.chronoAPI) return;
    setSavedDocs(await window.chronoAPI.listSavedDocs());
  };

  useEffect(() => { refreshDocs(); }, []);

  const updateStats = () => {
    const text = editorRef.current?.innerText || "";
    const words = text.trim() ? text.trim().split(/\s+/).length : 0;
    setStats({ words, chars: text.length });
  };

  const exec = (cmd: string, val?: string) => {
    document.execCommand(cmd, false, val);
    editorRef.current?.focus();
    setIsDirty(true);
    updateStats();
  };

  const handleSave = async () => {
    if (!window.chronoAPI || !editorRef.current) return;
    const res = await window.chronoAPI.saveDocx({
      title,
      plainText: editorRef.current.innerText,
      existingPath: currentPath
    });
    if (res.ok) {
      setCurrentPath(res.path);
      setIsDirty(false);
      setStatus(`Saved ${res.name}`);
      refreshDocs();
    }
  };

  const handleOpen = async (filePath?: string) => {
    if (!window.chronoAPI || !editorRef.current) return;
    const res = await window.chronoAPI.openDocx(filePath);
    if (res) {
      editorRef.current.innerHTML = res.html;
      setTitle(res.title);
      setCurrentPath(res.path);
      setIsDirty(false);
      setStatus(`Opened ${res.title}`);
      updateStats();
    }
  };

  const handleExportPDF = async () => {
    if (!window.chronoAPI || !editorRef.current) return;
    const res = await window.chronoAPI.exportDocPDF({ title, html: editorRef.current.innerHTML });
    if (res.ok) setStatus("Exported A4 PDF");
  };

  const newBlankDoc = () => {
    if (editorRef.current) editorRef.current.innerHTML = "";
    setTitle("Untitled Document");
    setCurrentPath(null);
    setIsDirty(false);
    setStatus(null);
    updateStats();
  };

  const insertTable = () => {
    exec("insertHTML", `<table style="width:100%;border-collapse:collapse;margin:12px 0"><tr><th style="border:1px solid #CBD5E1;padding:6px;background:#F1F5F9">Header 1</th><th style="border:1px solid #CBD5E1;padding:6px;background:#F1F5F9">Header 2</th><th style="border:1px solid #CBD5E1;padding:6px;background:#F1F5F9">Header 3</th></tr><tr><td style="border:1px solid #CBD5E1;padding:6px">Cell 1</td><td style="border:1px solid #CBD5E1;padding:6px">Cell 2</td><td style="border:1px solid #CBD5E1;padding:6px">Cell 3</td></tr></table><p></p>`);
  };

  const insertCallout = (label: string) => {
    exec("insertHTML", `<div style="background:#F0FDFA;border-left:4px solid #008080;padding:10px 14px;border-radius:6px;margin:10px 0"><strong>${label}:</strong> Explain clearly here…</div><p></p>`);
  };

  return (
    <div className="flex h-full overflow-hidden">
      {/* Saved Documents Sidebar */}
      {showSidebar && !teachMode && (
        <div className="flex w-60 flex-col border-r" style={{ borderColor: "var(--cs-border)", background: "var(--cs-sidebar)" }}>
          <div className="flex items-center justify-between border-b px-3 py-2.5" style={{ borderColor: "var(--cs-border)" }}>
            <span className="text-xs font-semibold">Documents</span>
            <div className="flex gap-2">
              <button onClick={newBlankDoc} className="cursor-pointer opacity-75 hover:opacity-100" title="New Blank Document"><Plus size={14} /></button>
              <button onClick={() => handleOpen()} className="cursor-pointer opacity-75 hover:opacity-100" title="Open .docx"><FolderOpen size={14} /></button>
            </div>
          </div>

          <div className="flex-1 overflow-y-auto p-2 space-y-1">
            {savedDocs.length === 0 ? (
              <div className="p-4 text-center text-xs" style={{ color: "var(--cs-text-tertiary)" }}>
                No saved docs yet. Press Save to store .docx files.
              </div>
            ) : (
              savedDocs.map((doc) => (
                <div
                  key={doc.path}
                  onClick={() => handleOpen(doc.path)}
                  className="group flex items-center justify-between rounded-lg px-2.5 py-2 cursor-pointer"
                  style={{ background: currentPath === doc.path ? "var(--cs-accent-soft)" : "transparent" }}
                >
                  <div className="flex items-center gap-2 min-w-0">
                    <span className="rounded px-1.5 py-0.5 text-[9px] font-bold bg-blue-500/15 text-blue-600">{doc.ext}</span>
                    <div className="min-w-0">
                      <div className="truncate text-xs font-medium">{doc.title}</div>
                      <div className="text-[10px]" style={{ color: "var(--cs-text-tertiary)" }}>{formatBytes(doc.size)}</div>
                    </div>
                  </div>
                  <button
                    onClick={async (e) => { e.stopPropagation(); await window.chronoAPI?.deleteDoc(doc.path); refreshDocs(); }}
                    className="opacity-0 group-hover:opacity-70 hover:!opacity-100 cursor-pointer"
                  >
                    <Trash2 size={12} />
                  </button>
                </div>
              ))
            )}
          </div>

          <button
            onClick={() => window.chronoAPI?.openDocsFolder()}
            className="border-t px-3 py-2 text-left text-xs cursor-pointer"
            style={{ borderColor: "var(--cs-border)", color: "var(--cs-text-secondary)" }}
          >
            Open Docs Folder ({savedDocs.length})
          </button>
        </div>
      )}

      {/* Main Editor Column */}
      <div className="flex flex-1 flex-col overflow-hidden">
        {/* Top Bar */}
        <div className="flex items-center justify-between border-b px-4 py-2" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
          <div className="flex items-center gap-2.5">
            {!teachMode && (
              <button onClick={() => setShowSidebar((s) => !s)} className="cursor-pointer opacity-75 hover:opacity-100">
                <PanelLeft size={16} />
              </button>
            )}
            <FileText size={16} className="text-blue-600" />
            <input
              value={title}
              onChange={(e) => { setTitle(e.target.value); setIsDirty(true); }}
              className="bg-transparent text-sm font-semibold outline-none w-52"
            />
            <span className="rounded-full bg-blue-500/15 px-2 py-0.5 text-[10px] font-bold text-blue-600">DOCX</span>
            <span className="flex items-center gap-1 text-xs" style={{ color: "var(--cs-text-secondary)" }}>
              <span className={`h-1.5 w-1.5 rounded-full ${isDirty ? "bg-amber-500" : "bg-emerald-500"}`} />
              {isDirty ? "Unsaved" : "Saved"}
            </span>
          </div>

          <div className="flex items-center gap-2">
            <button onClick={handleSave} className="inline-flex items-center gap-1.5 rounded-lg px-3 py-1 text-xs font-medium text-white cursor-pointer" style={{ background: "var(--cs-accent)" }}>
              <Save size={13} /> Save .docx
            </button>
            <button onClick={handleExportPDF} className="inline-flex items-center gap-1 rounded-lg border px-2.5 py-1 text-xs font-medium cursor-pointer" style={{ borderColor: "var(--cs-border)" }}>
              <FileDown size={13} /> Export PDF
            </button>
            <button onClick={() => setTeachMode((t) => !t)} className="rounded-lg border px-2.5 py-1 text-xs font-medium cursor-pointer" style={{ borderColor: "var(--cs-border)" }}>
              {teachMode ? "Exit Focus" : "Teach Mode"}
            </button>
          </div>
        </div>

        {/* Formatting Ribbon */}
        {!teachMode && (
          <div className="flex flex-wrap items-center gap-1 border-b px-4 py-1.5 text-xs" style={{ borderColor: "var(--cs-border)", background: "var(--cs-sidebar)" }}>
            <button onClick={() => exec("formatBlock", "H1")} className="rounded px-2 py-1 hover:bg-black/5 cursor-pointer font-semibold">H1</button>
            <button onClick={() => exec("formatBlock", "H2")} className="rounded px-2 py-1 hover:bg-black/5 cursor-pointer font-semibold">H2</button>
            <button onClick={() => exec("formatBlock", "P")} className="rounded px-2 py-1 hover:bg-black/5 cursor-pointer">Body</button>
            <span className="mx-1 h-4 w-px bg-slate-300/60" />
            <button onClick={() => exec("bold")} className="rounded p-1.5 hover:bg-black/5 cursor-pointer" title="Bold"><Bold size={14} /></button>
            <button onClick={() => exec("italic")} className="rounded p-1.5 hover:bg-black/5 cursor-pointer" title="Italic"><Italic size={14} /></button>
            <button onClick={() => exec("underline")} className="rounded p-1.5 hover:bg-black/5 cursor-pointer" title="Underline"><Underline size={14} /></button>
            <button onClick={() => exec("hiliteColor", "#FEF08A")} className="rounded p-1.5 hover:bg-black/5 cursor-pointer" title="Highlight"><Highlighter size={14} /></button>
            <span className="mx-1 h-4 w-px bg-slate-300/60" />
            <button onClick={() => exec("justifyLeft")} className="rounded p-1.5 hover:bg-black/5 cursor-pointer"><AlignLeft size={14} /></button>
            <button onClick={() => exec("justifyCenter")} className="rounded p-1.5 hover:bg-black/5 cursor-pointer"><AlignCenter size={14} /></button>
            <button onClick={() => exec("justifyRight")} className="rounded p-1.5 hover:bg-black/5 cursor-pointer"><AlignRight size={14} /></button>
            <span className="mx-1 h-4 w-px bg-slate-300/60" />
            <button onClick={() => exec("insertUnorderedList")} className="rounded p-1.5 hover:bg-black/5 cursor-pointer"><List size={14} /></button>
            <button onClick={() => exec("insertOrderedList")} className="rounded p-1.5 hover:bg-black/5 cursor-pointer"><ListOrdered size={14} /></button>
            <button onClick={insertTable} className="rounded p-1.5 hover:bg-black/5 cursor-pointer" title="Insert Table"><Table size={14} /></button>
            <button onClick={() => insertCallout("Key Concept")} className="rounded px-2 py-1 hover:bg-black/5 cursor-pointer">Callout</button>
            <button onClick={() => exec("insertHTML", `<pre style="background:#F1F5F9;padding:10px;border-radius:8px;font-family:monospace">// Code example\n</pre><p></p>`)} className="rounded p-1.5 hover:bg-black/5 cursor-pointer" title="Code Block"><Code size={14} /></button>
          </div>
        )}

        {/* Clean Blank White A4 Paper Canvas */}
        <div className="flex-1 overflow-y-auto p-6" style={{ background: "var(--cs-canvas)" }}>
          <div
            ref={editorRef}
            contentEditable
            suppressContentEditableWarning
            onInput={() => { setIsDirty(true); updateStats(); }}
            className="mx-auto min-h-[820px] max-w-[816px] rounded-md bg-white p-14 text-slate-900 shadow-md outline-none select-text leading-relaxed"
            style={{ fontSize: `${(15 * zoom) / 100}px` }}
          />
        </div>

        {/* Bottom Status Bar */}
        <div className="flex items-center justify-between border-t px-4 py-1.5 text-xs" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)", color: "var(--cs-text-secondary)" }}>
          <div>
            {stats.words} words · {stats.chars} chars · ~{Math.max(1, Math.ceil(stats.words / 200))} min read
            {status && <span className="ml-3" style={{ color: "var(--cs-accent)" }}>· {status}</span>}
          </div>
          <div className="flex items-center gap-1">
            {[75, 100, 125, 150].map((z) => (
              <button
                key={z}
                onClick={() => setZoom(z)}
                className={`rounded px-1.5 py-0.5 cursor-pointer ${zoom === z ? "font-semibold" : "opacity-60"}`}
                style={{ background: zoom === z ? "var(--cs-surface-subtle)" : "transparent" }}
              >
                {z}%
              </button>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}
