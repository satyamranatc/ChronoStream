const { contextBridge, ipcRenderer } = require("electron");

contextBridge.exposeInMainWorld("chronoAPI", {
  mediaUrl: (filePath) => `chronostream-media://local?path=${encodeURIComponent(filePath)}`,
  pickFolders: () => ipcRenderer.invoke("fs:pick-folders"),
  pickFiles: () => ipcRenderer.invoke("fs:pick-files"),
  scanFolder: (folderPath) => ipcRenderer.invoke("fs:scan-folder", folderPath),
  revealInExplorer: (filePath) => ipcRenderer.invoke("fs:reveal", filePath),
  openInboxFolder: () => ipcRenderer.invoke("fs:open-inbox"),
  readTextFile: (filePath) => ipcRenderer.invoke("fs:read-text", filePath),
  renameFile: (filePath, newName) => ipcRenderer.invoke("fs:rename", filePath, newName),
  trashFiles: (paths) => ipcRenderer.invoke("fs:trash", paths),
  duplicateFiles: (paths) => ipcRenderer.invoke("fs:duplicate", paths),
  transferFiles: (paths, destDir, mode) => ipcRenderer.invoke("fs:transfer", paths, destDir, mode),
  startFileDrag: (filePath) => ipcRenderer.send("fs:start-drag", filePath),

  loadState: (key) => ipcRenderer.invoke("state:load", key),
  saveState: (key, value) => ipcRenderer.invoke("state:save", key, value),

  prepareVideoPlayback: (filePath) => ipcRenderer.invoke("video:prepare-playback", filePath),
  runVideoStudioOp: (payload) => ipcRenderer.invoke("video:studio-op", payload),

  getDisplays: () => ipcRenderer.invoke("displays:list"),
  setKeepAwake: (on) => ipcRenderer.invoke("displays:keep-awake", on),
  moveToDisplay: (id) => ipcRenderer.invoke("displays:move-window", id),
  startCinema: (mediaUrl, displayId) => ipcRenderer.invoke("displays:start-cinema", mediaUrl, displayId),
  stopCinema: () => ipcRenderer.invoke("displays:stop-cinema"),
  onDisplaysChanged: (cb) => {
    const handler = (_e, data) => cb(data);
    ipcRenderer.on("displays:changed", handler);
    return () => ipcRenderer.removeListener("displays:changed", handler);
  },

  startWiFiSend: (paths, requirePin) => ipcRenderer.invoke("wifi:start-send", paths, requirePin),
  stopWiFiSend: () => ipcRenderer.invoke("wifi:stop-send"),
  startWiFiReceive: () => ipcRenderer.invoke("wifi:start-receive"),
  rotateReceivePIN: () => ipcRenderer.invoke("wifi:rotate-pin"),
  stopWiFiReceive: () => ipcRenderer.invoke("wifi:stop-receive"),
  listInbox: () => ipcRenderer.invoke("wifi:list-inbox"),
  onReceivedWiFiFile: (cb) => {
    const handler = (_e, data) => cb(data);
    ipcRenderer.on("wifi:received-file", handler);
    return () => ipcRenderer.removeListener("wifi:received-file", handler);
  },

  listSavedDocs: () => ipcRenderer.invoke("docs:list"),
  saveDocx: (payload) => ipcRenderer.invoke("docs:save-docx", payload),
  openDocx: (filePath) => ipcRenderer.invoke("docs:open-docx", filePath),
  exportDocPDF: (payload) => ipcRenderer.invoke("docs:export-pdf", payload),
  deleteDoc: (filePath) => ipcRenderer.invoke("docs:delete", filePath),
  openDocsFolder: () => ipcRenderer.invoke("docs:open-folder")
});
