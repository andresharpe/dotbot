/**
 * Layout persistence: draggable panel splitter + resizable pipeline columns.
 * Storage keys: dotbot:layout:sidebarWidth, dotbot:layout:columnWidths
 */

const SIDEBAR_MIN = 160;
const SIDEBAR_MAX = 520;
const SIDEBAR_DEFAULT = 280;
const COLUMN_MIN = 120;
const STORAGE_SIDEBAR = 'dotbot:layout:sidebarWidth';
const STORAGE_COLUMNS = 'dotbot:layout:columnWidths';

// ── Storage helpers ──────────────────────────────────────────────────────────

function layoutGet(key) {
    try { return window.localStorage.getItem(key); } catch (e) { return null; }
}

function layoutSet(key, value) {
    try { window.localStorage.setItem(key, value); } catch (e) { /* ignore */ }
}

function layoutRemove(key) {
    try { window.localStorage.removeItem(key); } catch (e) { /* ignore */ }
}

// ── Sidebar width ────────────────────────────────────────────────────────────

function applySidebarWidth(px) {
    document.documentElement.style.setProperty('--sidebar-width', `${px}px`);
}

function restoreSidebarWidth() {
    const stored = layoutGet(STORAGE_SIDEBAR);
    if (stored) {
        const px = parseInt(stored, 10);
        if (px >= SIDEBAR_MIN && px <= SIDEBAR_MAX) applySidebarWidth(px);
    }
}

function initPanelSplitter() {
    const splitter = document.getElementById('panel-splitter');
    const layout = document.getElementById('main-layout');
    if (!splitter || !layout) return;

    let dragging = false;
    let startX = 0;
    let startWidth = 0;

    splitter.addEventListener('mousedown', (e) => {
        dragging = true;
        startX = e.clientX;
        startWidth = parseInt(getComputedStyle(document.documentElement).getPropertyValue('--sidebar-width'), 10) || SIDEBAR_DEFAULT;
        splitter.classList.add('dragging');
        document.body.style.cursor = 'col-resize';
        document.body.style.userSelect = 'none';
        e.preventDefault();
    });

    document.addEventListener('mousemove', (e) => {
        if (!dragging) return;
        const delta = e.clientX - startX;
        const newWidth = Math.max(SIDEBAR_MIN, Math.min(SIDEBAR_MAX, startWidth + delta));
        applySidebarWidth(newWidth);
    });

    document.addEventListener('mouseup', () => {
        if (!dragging) return;
        dragging = false;
        splitter.classList.remove('dragging');
        document.body.style.cursor = '';
        document.body.style.userSelect = '';
        const current = parseInt(getComputedStyle(document.documentElement).getPropertyValue('--sidebar-width'), 10);
        if (current !== SIDEBAR_DEFAULT) {
            layoutSet(STORAGE_SIDEBAR, current);
        } else {
            layoutRemove(STORAGE_SIDEBAR);
        }
    });

    splitter.addEventListener('dblclick', () => {
        applySidebarWidth(SIDEBAR_DEFAULT);
        layoutRemove(STORAGE_SIDEBAR);
    });
}

// ── Pipeline column resize ───────────────────────────────────────────────────

function loadColumnWidths() {
    try {
        const raw = layoutGet(STORAGE_COLUMNS);
        return raw ? JSON.parse(raw) : {};
    } catch (e) { return {}; }
}

function saveColumnWidths(map) {
    try { layoutSet(STORAGE_COLUMNS, JSON.stringify(map)); } catch (e) { /* ignore */ }
}

function getColumnKey(col) {
    const label = col.querySelector('.column-label');
    return label ? label.textContent.trim().replace(/\s+/g, '_') : null;
}

function applyColumnWidth(col, px) {
    col.style.flex = 'none';
    col.style.width = `${px}px`;
}

function resetColumnWidth(col) {
    col.style.flex = '';
    col.style.width = '';
}

function initColumnResizeHandles() {
    const container = document.querySelector('.pipeline-container');
    if (!container) return;

    const columns = Array.from(container.querySelectorAll('.pipeline-column'));
    const widths = loadColumnWidths();

    columns.forEach((col) => {
        const key = getColumnKey(col);
        if (key && widths[key]) {
            applyColumnWidth(col, widths[key]);
        }

        const header = col.querySelector('.column-header');
        if (!header) return;

        const handle = document.createElement('div');
        handle.className = 'column-resize-handle';
        handle.title = 'Drag to resize · Double-click to reset';
        header.appendChild(handle);

        let dragging = false;
        let startX = 0;
        let startWidth = 0;

        handle.addEventListener('mousedown', (e) => {
            dragging = true;
            startX = e.clientX;
            startWidth = col.getBoundingClientRect().width;
            handle.classList.add('dragging');
            document.body.style.cursor = 'col-resize';
            document.body.style.userSelect = 'none';
            e.preventDefault();
            e.stopPropagation();
        });

        document.addEventListener('mousemove', (e) => {
            if (!dragging) return;
            const delta = e.clientX - startX;
            const newWidth = Math.max(COLUMN_MIN, startWidth + delta);
            applyColumnWidth(col, newWidth);
        });

        document.addEventListener('mouseup', () => {
            if (!dragging) return;
            dragging = false;
            handle.classList.remove('dragging');
            document.body.style.cursor = '';
            document.body.style.userSelect = '';

            if (key) {
                const map = loadColumnWidths();
                map[key] = Math.round(col.getBoundingClientRect().width);
                saveColumnWidths(map);
            }
        });

        handle.addEventListener('dblclick', (e) => {
            e.stopPropagation();
            resetColumnWidth(col);
            if (key) {
                const map = loadColumnWidths();
                delete map[key];
                if (Object.keys(map).length) {
                    saveColumnWidths(map);
                } else {
                    layoutRemove(STORAGE_COLUMNS);
                }
            }
        });
    });
}

// ── Init ─────────────────────────────────────────────────────────────────────

// Restore sidebar width before first paint to avoid flash.
restoreSidebarWidth();

document.addEventListener('DOMContentLoaded', () => {
    initPanelSplitter();
    initColumnResizeHandles();
});
