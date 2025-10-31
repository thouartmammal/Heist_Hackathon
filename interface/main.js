const { app, BrowserWindow,ipcMain ,Notification } = require("electron");
let win;
const path = require("path");

function createWindow() {
  const win = new BrowserWindow({
    width: 1000,
    height: 700,
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false
    }
  });

  win.loadFile("index.html");
}

app.whenReady().then(()=>{
    createWindow();

  // ✅ Listen for notification requests from the renderer
  ipcMain.on("show-notification", (event, { title, body }) => {
    new Notification({ title, body }).show();
  });
});

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") app.quit();
});

app.on("activate", () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow();
});
