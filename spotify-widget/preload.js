const { contextBridge, ipcRenderer } = require('electron');

const SEND = [
  'login', 'context-menu', 'popup-done', 'drag-start', 'drag-end', 'control',
  'chip-drag-start', 'chip-drag-end', 'chip-inserted', 'notch-interactive', 'notch-expanded',
];
const RECV = ['track', 'status', 'popup', 'lyrics', 'notice', 'chip', 'chip-show', 'chip-land', 'chip-mode', 'chip-docked', 'chip-undocked', 'sandy', 'sfx', 'mode', 'peek'];

contextBridge.exposeInMainWorld('spotify', {
  send: (ch, data) => SEND.includes(ch) && ipcRenderer.send(ch, data),
  on: (ch, fn) => RECV.includes(ch) && ipcRenderer.on(ch, (_e, data) => fn(data)),
  getState: () => ipcRenderer.invoke('get-state'),
});
