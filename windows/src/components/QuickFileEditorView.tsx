import React, { useEffect, useState } from "react";
import { ChevronLeft, Copy, Save, ExternalLink, Share2, Code2, FileText, Table } from "lucide-react";
import { MediaItem, formatBytes } from "../types";

export default function QuickFileEditorView({
  item,
  onShare,
  onClose
}: {
  item: MediaItem;
  onShare: (item: MediaItem) => void;
  onClose: () => void;
}) {
  const ext = (item.ext || "").toLowerCase();
  const isDocx = ["docx", "doc", "rtf", "odt"].includes(ext);
  const isXlsx = ["xlsx", "xls"].includes(ext);
  const isCSV = ["csv", "tsv"].includes(ext);
  const isHTML = ["html", "htm", "svg"].includes(ext);
  const isEditable = !isDocx && !isXlsx;

  const [text, setText] = useState("");
  const [original, setOriginal] = useState("");
  const [docxHtml, setDocxHtml] = useState<string | null>(null);
  const [showPreview, setShowPreview] = useState(isCSV);
  const [fontSize, setFontSize] = useState(13.5);
  const [status, setStatus] = useState<string | null>(null);

  const dirty = isEditable && text !== original;

  const flash = (msg: string) => {
    setStatus(msg);
    window.setTimeout(() => setStatus((cur) => (cur === msg ? null : cur)), 2000);
  };

  useEffect(() => {
    let active = true;
    setDocxHtml(null);
    setShowPreview(isCSV);
    (async () => {
      if (isDocx && ext === "docx") {
        const res = await window.chronoAPI?.openDocx(item.path);
        if (active && res?.html) setDocxHtml(res.html);
        return;
      }
      if (isEditable) {
        const raw = await window.chronoAPI?.readTextFile(item.path);
        if (active && raw !== null && raw !== undefined) {
          setText(raw);
          setOriginal(raw);
        }
      }
    })();
    return () => { active = false; };
  }, [item.path, ext, isDocx, isEditable, isCSV]);

  const saveFile = async () => {
    if (!isEditable || !window.chronoAPI) return;
    const res = await window.chronoAPI.writeTextFile(item.path, text);
    if (res.ok) {
      setOriginal(text);
      flash(`Saved ${item.name}`);
    } else {
      flash(`Save failed: ${res.error || "Unknown error"}`);
    }
  };

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "s" && isEditable) {
        e.preventDefault();
        saveFile();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [text, isEditable]);

  const rows = isCSV
    ? text.split(/\r?\n/).filter((l) => l.trim()).map((l) => l.split(ext === "tsv" ? "\t" : ",").map((c) => c.replace(/^"|"$/g, "").trim()))
    : [];

  return (
    <div className="flex h-full w-full flex-col" style={{ background: "var(--cs-canvas)" }}>
      {/* Top Bar */}
      <div className="flex items-center justify-between border-b px-4 py-2.5 gap-3" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
        <div className="flex items-center gap-2.5 min-w-0">
          <button onClick={onClose} className="inline-flex items-center gap-1 rounded-lg border px-2.5 py-1 text-xs font-medium cursor-pointer" style={{ borderColor: "var(--cs-border)" }}>
            <ChevronLeft size={14} /> Back
          </button>
          {isDocx ? <FileText size={15} style={{ color: "var(--cs-accent)" }} /> : isCSV || isXlsx ? <Table size={15} style={{ color: "var(--cs-accent)" }} /> : <Code2 size={15} style={{ color: "var(--cs-accent)" }} />}
          <span className="truncate text-sm font-semibold">{item.name}</span>
          {dirty && <span className="h-2 w-2 rounded-full" style={{ background: "var(--cs-accent)" }} title="Unsaved changes" />}
          <span className="rounded-full px-2 py-0.5 text-[10px] font-semibold uppercase" style={{ background: "var(--cs-surface-subtle)", color: "var(--cs-text-secondary)" }}>
            {ext || "FILE"}
          </span>
        </div>

        <div className="flex items-center gap-2 shrink-0">
          {(isHTML || isCSV) && (
            <div className="inline-flex rounded-lg p-0.5 text-xs" style={{ background: "var(--cs-surface-subtle)" }}>
              <button onClick={() => setShowPreview(false)} className="rounded px-2.5 py-1 cursor-pointer" style={{ background: !showPreview ? "var(--cs-surface)" : "transparent" }}>Code</button>
              <button onClick={() => setShowPreview(true)} className="rounded px-2.5 py-1 cursor-pointer" style={{ background: showPreview ? "var(--cs-surface)" : "transparent" }}>{isHTML ? "Preview" : "Table"}</button>
            </div>
          )}

          {isEditable && (
            <>
              <button onClick={() => setFontSize((s) => Math.max(10, s - 1))} className="rounded-lg border px-2 py-1 text-xs cursor-pointer" style={{ borderColor: "var(--cs-border)" }}>A-</button>
              <button onClick={() => setFontSize((s) => Math.min(22, s + 1))} className="rounded-lg border px-2 py-1 text-xs cursor-pointer" style={{ borderColor: "var(--cs-border)" }}>A+</button>
              <button onClick={() => { navigator.clipboard?.writeText(text); flash("Copied to clipboard"); }} className="inline-flex items-center gap-1 rounded-lg border px-2.5 py-1 text-xs cursor-pointer" style={{ borderColor: "var(--cs-border)" }}>
                <Copy size={12} /> Copy
              </button>
              <button disabled={!dirty} onClick={saveFile} className="inline-flex items-center gap-1 rounded-lg px-3 py-1 text-xs font-semibold text-white disabled:opacity-40 cursor-pointer" style={{ background: "var(--cs-accent)" }}>
                <Save size={12} /> Save
              </button>
            </>
          )}

          <button onClick={() => window.chronoAPI?.openExternalFile(item.path)} className="inline-flex items-center gap-1 rounded-lg border px-2.5 py-1 text-xs cursor-pointer" style={{ borderColor: "var(--cs-border)" }}>
            <ExternalLink size={12} /> Open Externally
          </button>
          <button onClick={() => onShare(item)} className="rounded-lg border p-1.5 cursor-pointer" style={{ borderColor: "var(--cs-border)" }} title="Share">
            <Share2 size={13} />
          </button>
        </div>
      </div>

      {/* Main Content */}
      <div className="flex-1 overflow-auto">
        {isDocx && docxHtml ? (
          <div className="mx-auto max-w-3xl p-8 text-sm leading-relaxed" dangerouslySetInnerHTML={{ __html: docxHtml }} />
        ) : isXlsx || (isDocx && !docxHtml) ? (
          <div className="flex h-full flex-col items-center justify-center p-8 text-center space-y-3">
            <FileText size={38} style={{ color: "var(--cs-accent)" }} />
            <div className="text-base font-semibold">{item.name}</div>
            <p className="max-w-sm text-xs" style={{ color: "var(--cs-text-secondary)" }}>
              Click below to open this Office file in your default application (Word / Excel).
            </p>
            <button onClick={() => window.chronoAPI?.openExternalFile(item.path)} className="rounded-lg px-4 py-2 text-xs font-semibold text-white cursor-pointer" style={{ background: "var(--cs-accent)" }}>
              Open in Default App
            </button>
          </div>
        ) : isHTML && showPreview ? (
          <iframe title={item.name} srcDoc={text} className="h-full w-full bg-white" sandbox="allow-scripts" />
        ) : isCSV && showPreview ? (
          <div className="p-4 overflow-auto">
            <table className="w-full border-collapse text-xs">
              <tbody>
                {rows.slice(0, 400).map((row, rIdx) => (
                  <tr key={rIdx} style={{ background: rIdx === 0 ? "var(--cs-accent-soft)" : rIdx % 2 === 1 ? "var(--cs-surface-subtle)" : "transparent" }}>
                    <td className="border px-2 py-1 text-right font-mono opacity-50" style={{ borderColor: "var(--cs-border)" }}>{rIdx + 1}</td>
                    {row.map((cell, cIdx) => (
                      <td key={cIdx} className={`border px-2.5 py-1 ${rIdx === 0 ? "font-semibold" : ""}`} style={{ borderColor: "var(--cs-border)" }}>{cell}</td>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        ) : (
          <textarea
            value={text}
            onChange={(e) => setText(e.target.value)}
            spellCheck={false}
            className="h-full w-full resize-none p-5 font-mono outline-none"
            style={{ fontSize: `${fontSize}px`, background: "var(--cs-surface)", color: "var(--cs-text)" }}
          />
        )}
      </div>

      {/* Status Bar */}
      <div className="flex items-center justify-between border-t px-4 py-1.5 text-[11px]" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)", color: "var(--cs-text-tertiary)" }}>
        <span className="truncate">{status || item.path}</span>
        <span className="shrink-0 tabular-nums">
          {isEditable ? `${text ? text.split(/\r?\n/).length : 0} lines · ${text.length} chars · ` : ""}{formatBytes(item.fileSize)}
        </span>
      </div>
    </div>
  );
}
