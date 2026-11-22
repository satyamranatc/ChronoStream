import React, { useEffect, useState } from "react";
import { QrCode, Plus, ShieldCheck, Copy, Check, RefreshCw, FolderOpen, X } from "lucide-react";
import { MediaItem, ReceivedFile, formatBytes } from "../types";

interface Props {
  initialSendItems?: MediaItem[];
  onOpenReceived: (filePath: string) => void;
}

export default function WiFiShareHubView({ initialSendItems = [], onOpenReceived }: Props) {
  const [direction, setDirection] = useState<"send" | "receive">("send");
  const [sendPaths, setSendPaths] = useState<string[]>(initialSendItems.map((i) => i.path));
  const [requirePin, setRequirePin] = useState(true);
  const [sendSession, setSendSession] = useState<{ shareURL: string; qrDataUrl: string; pin: string } | null>(null);
  const [receiveSession, setReceiveSession] = useState<{ receiverURL: string; qrDataUrl: string; pin: string } | null>(null);
  const [inbox, setInbox] = useState<ReceivedFile[]>([]);
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    window.chronoAPI?.listInbox().then(setInbox);
    const off = window.chronoAPI?.onReceivedWiFiFile((file) => {
      setInbox((prev) => [file, ...prev]);
    });
    return () => {
      off?.();
      window.chronoAPI?.stopWiFiSend();
      window.chronoAPI?.stopWiFiReceive();
    };
  }, []);

  const pickFiles = async () => {
    const picked = await window.chronoAPI?.pickFiles();
    if (picked?.length) {
      const merged = Array.from(new Set([...sendPaths, ...picked]));
      setSendPaths(merged);
      startSend(merged, requirePin);
    }
  };

  const startSend = async (paths: string[], pinRequired: boolean) => {
    setError(null);
    try {
      const res = await window.chronoAPI?.startWiFiSend(paths, pinRequired);
      if (res) setSendSession(res);
    } catch (e: unknown) {
      setError((e as Error).message);
    }
  };

  const startReceive = async () => {
    setError(null);
    try {
      const res = await window.chronoAPI?.startWiFiReceive();
      if (res) setReceiveSession(res);
    } catch (e: unknown) {
      setError((e as Error).message);
    }
  };

  return (
    <div className="flex h-full flex-col overflow-hidden">
      {/* Header */}
      <div className="flex items-center justify-between border-b px-5 py-3" style={{ borderColor: "var(--cs-border)", background: "var(--cs-surface)" }}>
        <div className="flex items-center gap-3">
          <div className="flex h-8 w-8 items-center justify-center rounded-lg" style={{ background: "var(--cs-accent-soft)", color: "var(--cs-accent)" }}>
            <QrCode size={17} />
          </div>
          <div>
            <h2 className="text-sm font-semibold">Wi-Fi Share</h2>
            <p className="text-xs" style={{ color: "var(--cs-text-secondary)" }}>Android &amp; iPhone · Token + 4-Digit PIN · Zero Cloud</p>
          </div>
        </div>

        <div className="inline-flex rounded-lg p-1" style={{ background: "var(--cs-surface-subtle)" }}>
          <button onClick={() => setDirection("send")} className={`rounded-md px-4 py-1 text-xs font-medium cursor-pointer ${direction === "send" ? "shadow-sm" : ""}`} style={{ background: direction === "send" ? "var(--cs-surface)" : "transparent" }}>Send</button>
          <button onClick={() => setDirection("receive")} className={`rounded-md px-4 py-1 text-xs font-medium cursor-pointer ${direction === "receive" ? "shadow-sm" : ""}`} style={{ background: direction === "receive" ? "var(--cs-surface)" : "transparent" }}>Receive</button>
        </div>
      </div>

      {error && <div className="bg-amber-500/15 px-5 py-2 text-xs text-amber-700 dark:text-amber-300">{error}</div>}

      {direction === "send" ? (
        <div className="flex flex-1 overflow-hidden">
          <div className="flex w-72 flex-col border-r" style={{ borderColor: "var(--cs-border)", background: "var(--cs-sidebar)" }}>
            <div className="flex items-center justify-between border-b px-3 py-2.5" style={{ borderColor: "var(--cs-border)" }}>
              <span className="text-xs font-semibold">Files ({sendPaths.length})</span>
              <button onClick={pickFiles} className="inline-flex items-center gap-1 rounded-lg px-2.5 py-1 text-xs font-medium text-white cursor-pointer" style={{ background: "var(--cs-accent)" }}>
                <Plus size={12} /> Choose
              </button>
            </div>
            <div className="flex-1 overflow-y-auto p-2 space-y-1">
              {sendPaths.map((p) => (
                <div key={p} className="flex items-center justify-between rounded-lg px-2.5 py-2 text-xs" style={{ background: "var(--cs-surface)" }}>
                  <span className="truncate">{p.split(/[\\/]/).pop()}</span>
                  <button onClick={() => setSendPaths((prev) => prev.filter((x) => x !== p))} className="cursor-pointer opacity-60 hover:opacity-100"><X size={13} /></button>
                </div>
              ))}
            </div>
          </div>

          <div className="flex flex-1 flex-col items-center justify-center p-6 space-y-4 overflow-y-auto">
            {sendSession ? (
              <>
                <img src={sendSession.qrDataUrl} alt="QR Code" className="h-48 w-48 rounded-2xl bg-white p-3 shadow-md" />
                <div className="text-center">
                  <div className="text-base font-bold">Scan with Android or iPhone</div>
                  <div className="text-xs" style={{ color: "var(--cs-text-secondary)" }}>Opens in Chrome or Safari — no phone app required.</div>
                </div>
                <div className="flex items-center gap-4 rounded-xl border px-4 py-2" style={{ borderColor: "var(--cs-accent)", background: "var(--cs-accent-soft)" }}>
                  <ShieldCheck size={18} style={{ color: "var(--cs-accent)" }} />
                  <div>
                    <div className="text-[10px] font-bold uppercase opacity-70">Security PIN</div>
                    <div className="font-mono text-lg font-bold tracking-widest">{sendSession.pin}</div>
                  </div>
                </div>
                <div className="flex gap-2">
                  <button
                    onClick={() => { navigator.clipboard.writeText(sendSession.shareURL); setCopied(true); setTimeout(() => setCopied(false), 1500); }}
                    className="inline-flex items-center gap-1 rounded-lg border px-3 py-1.5 text-xs font-medium cursor-pointer"
                    style={{ borderColor: "var(--cs-border)" }}
                  >
                    {copied ? <Check size={13} /> : <Copy size={13} />} {copied ? "Copied" : "Copy Link"}
                  </button>
                  <button
                    onClick={async () => { await window.chronoAPI?.stopWiFiSend(); setSendSession(null); }}
                    className="rounded-lg border border-red-500/40 px-3 py-1.5 text-xs font-medium text-red-500 cursor-pointer"
                  >
                    Stop
                  </button>
                </div>
              </>
            ) : (
              <div className="text-center space-y-3 max-w-sm">
                <ShieldCheck size={40} className="mx-auto" style={{ color: "var(--cs-accent)" }} />
                <div className="text-base font-semibold">Select files to generate a secure Wi-Fi QR</div>
                <p className="text-xs" style={{ color: "var(--cs-text-secondary)" }}>Protected by a 24-char session token, 4-digit PIN, 5-attempt lockout, and 10-minute auto-expiry.</p>
                <button
                  disabled={sendPaths.length === 0}
                  onClick={() => startSend(sendPaths, requirePin)}
                  className="rounded-lg px-4 py-2 text-xs font-semibold text-white disabled:opacity-40 cursor-pointer"
                  style={{ background: "var(--cs-accent)" }}
                >
                  Start QR Share
                </button>
              </div>
            )}
          </div>
        </div>
      ) : (
        <div className="flex flex-1 overflow-hidden">
          <div className="flex flex-1 flex-col items-center justify-center p-6 space-y-4 overflow-y-auto">
            {receiveSession ? (
              <>
                <img src={receiveSession.qrDataUrl} alt="Receive QR" className="h-48 w-48 rounded-2xl bg-white p-3 shadow-md" />
                <div className="text-center">
                  <div className="text-base font-bold">Scan from Android or iPhone</div>
                  <div className="text-xs" style={{ color: "var(--cs-text-secondary)" }}>Enter the 4-digit PIN on your phone to unlock secure LAN upload.</div>
                </div>
                <div className="flex items-center gap-3 rounded-xl border px-4 py-2" style={{ borderColor: "var(--cs-accent)", background: "var(--cs-accent-soft)" }}>
                  <ShieldCheck size={18} style={{ color: "var(--cs-accent)" }} />
                  <div>
                    <div className="text-[10px] font-bold uppercase opacity-70">Security PIN</div>
                    <div className="font-mono text-lg font-bold tracking-widest">{receiveSession.pin}</div>
                  </div>
                  <button
                    onClick={async () => { const p = await window.chronoAPI?.rotateReceivePIN(); if (p) setReceiveSession((s) => s ? { ...s, pin: p } : null); }}
                    className="rounded-md border p-1.5 cursor-pointer"
                    style={{ borderColor: "var(--cs-border)" }}
                    title="Rotate PIN"
                  >
                    <RefreshCw size={13} />
                  </button>
                </div>
                <button
                  onClick={async () => { await window.chronoAPI?.stopWiFiReceive(); setReceiveSession(null); }}
                  className="rounded-lg border border-red-500/40 px-3 py-1.5 text-xs font-medium text-red-500 cursor-pointer"
                >
                  Stop Session
                </button>
              </>
            ) : (
              <div className="text-center space-y-3 max-w-sm">
                <ShieldCheck size={40} className="mx-auto" style={{ color: "var(--cs-accent)" }} />
                <div className="text-base font-semibold">Receive Files from Android or iPhone</div>
                <p className="text-xs" style={{ color: "var(--cs-text-secondary)" }}>No port stays open in the background. Start an on-demand 10-minute PIN-protected session.</p>
                <button onClick={startReceive} className="rounded-lg px-4 py-2 text-xs font-semibold text-white cursor-pointer" style={{ background: "var(--cs-accent)" }}>
                  Start Secure Receive Session
                </button>
              </div>
            )}
          </div>

          <div className="flex w-72 flex-col border-l" style={{ borderColor: "var(--cs-border)", background: "var(--cs-sidebar)" }}>
            <div className="flex items-center justify-between border-b px-3 py-2.5" style={{ borderColor: "var(--cs-border)" }}>
              <span className="text-xs font-semibold">Inbox ({inbox.length})</span>
              <button onClick={() => window.chronoAPI?.openInboxFolder()} className="inline-flex items-center gap-1 rounded border px-2 py-0.5 text-xs cursor-pointer" style={{ borderColor: "var(--cs-border)" }}>
                <FolderOpen size={12} /> Folder
              </button>
            </div>
            <div className="flex-1 overflow-y-auto p-2 space-y-1">
              {inbox.map((f) => (
                <div key={f.path} className="flex items-center justify-between rounded-lg px-2.5 py-2 text-xs" style={{ background: "var(--cs-surface)" }}>
                  <div className="min-w-0 pr-2">
                    <div className="truncate font-medium">{f.name}</div>
                    <div className="text-[10px]" style={{ color: "var(--cs-text-tertiary)" }}>{formatBytes(f.size)}</div>
                  </div>
                  <button onClick={() => onOpenReceived(f.path)} className="rounded px-2 py-1 text-[11px] font-medium text-white cursor-pointer" style={{ background: "var(--cs-accent)" }}>Open</button>
                </div>
              ))}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
