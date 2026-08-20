/**
 * Shared localStorage helpers (dotbot:* keys).
 * The splitter/column-resize machinery that used to live here died with the
 * contextual sidebar and the pipeline kanban (#606); these helpers remain
 * because other modules persist state through them (e.g. shell.js rail pin).
 */

function layoutGet(key) {
    try { return window.localStorage.getItem(key); } catch (e) { return null; }
}

function layoutSet(key, value) {
    try { window.localStorage.setItem(key, value); } catch (e) { /* ignore */ }
}

function layoutRemove(key) {
    try { window.localStorage.removeItem(key); } catch (e) { /* ignore */ }
}
