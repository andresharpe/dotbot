/**
 * DOTBOT Control Panel - Editor Integration
 * Editor detection, selection, and launch-from-dashboard
 */

// Editor registry — id, display name, CLI command(s), default args, inline SVG icon
const EDITORS = [
    {
        id: 'vscode',
        name: 'VS Code',
        commands: ['code'],
        args: '{path}',
        icon: `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M17.583 2.213l-4.52 4.285L7.52 2.04 2 4.98v14.04l5.52 2.94 5.543-4.46 4.52 4.287L22 19.56V4.44l-4.417-2.227zM7.52 14.98l-3.36-2.48 3.36-2.48v4.96zm5.043-2.48L7.52 8.06V5.52l8.4 6.98-3.357.001zM7.52 15.94l5.043-4.44 3.357.001-8.4 6.979v-2.54zm10.32 1.84l-3.36-2.82 3.36-2.82v5.64z"/></svg>`
    },
    {
        id: 'visual-studio',
        name: 'Visual Studio',
        commands: ['devenv'],
        args: '{path}',
        icon: `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M17.583 2.213L12 7.5 6.417 2.213 2 4.427v15.146l4.417 2.214L12 16.5l5.583 5.287L22 19.573V4.427l-4.417-2.214zM6.417 16.5V7.5L12 12l-5.583 4.5zm11.166 0L12 12l5.583-4.5v9z"/></svg>`
    },
    {
        id: 'cursor',
        name: 'Cursor',
        commands: ['cursor'],
        args: '{path}',
        icon: `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M5.5 2l13 10-13 10V2zm2 3.74v12.52L15.34 12 7.5 5.74z"/></svg>`
    },
    {
        id: 'windsurf',
        name: 'Windsurf',
        commands: ['windsurf'],
        args: '{path}',
        icon: `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 17.5C3 17.5 7.5 3 12 3s9 14.5 9 14.5H3zm9-11c-2.5 0-5.5 8-6.5 8.5h13C17.5 14.5 14.5 6.5 12 6.5z"/></svg>`
    },
    {
        id: 'rider',
        name: 'JetBrains Rider',
        commands: ['rider64', 'rider', 'rider.sh'],
        args: '{path}',
        icon: `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 3h18v18H3V3zm2 2v14h14V5H5zm2 2h4v2H7V7zm0 4h10v2H7v-2zm0 4h7v2H7v-2z"/></svg>`
    },
    {
        id: 'idea',
        name: 'JetBrains IDEA',
        commands: ['idea64', 'idea', 'idea.sh'],
        args: '{path}',
        icon: `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 3h18v18H3V3zm2 2v14h14V5H5zm2 2h4v2H7V7zm0 4h10v2H7v-2zm0 4h7v2H7v-2z"/></svg>`
    },
    {
        id: 'webstorm',
        name: 'WebStorm',
        commands: ['webstorm64', 'webstorm', 'webstorm.sh'],
        args: '{path}',
        icon: `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 3h18v18H3V3zm2 2v14h14V5H5zm1.5 2h2.4l1.35 4.8h.05L11.65 7h2.4l1.35 4.8h.05L16.8 7h2.4l-2.55 8h-2.4L12.9 10.5h-.05L11.5 15H9.1L6.5 7zm.5 10h7v1H7v-1z"/></svg>`
    },
    {
        id: 'sublime',
        name: 'Sublime Text',
        commands: ['subl', 'sublime_text'],
        args: '{path}',
        icon: `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M20.35 5.15l-9.5 4.15v3.2l9.5-4.15v-3.2zm-16.7 2.5l9.5 4.15v3.2l-9.5-4.15v-3.2zm16.7 5l-9.5 4.15v3.2l9.5-4.15v-3.2zm-16.7 2.5l9.5 4.15v3.2l-9.5-4.15v-3.2z"/></svg>`
    },
    {
        id: 'atom',
        name: 'Atom',
        commands: ['atom'],
        args: '{path}',
        icon: `<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="12" r="2.5"/><ellipse cx="12" cy="12" rx="10" ry="4.5" fill="none" stroke="currentColor" stroke-width="1.2"/><ellipse cx="12" cy="12" rx="10" ry="4.5" fill="none" stroke="currentColor" stroke-width="1.2" transform="rotate(60 12 12)"/><ellipse cx="12" cy="12" rx="10" ry="4.5" fill="none" stroke="currentColor" stroke-width="1.2" transform="rotate(120 12 12)"/></svg>`
    },
    {
        id: 'notepadpp',
        name: 'Notepad++',
        commands: ['notepad++'],
        args: '{path}',
        icon: `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M5 3h10l4 4v14H5V3zm2 2v14h10V8h-3V5H7zm2 6h6v1.5H9V11zm0 3h6v1.5H9V14z"/></svg>`
    },
    {
        id: 'vim',
        name: 'Vim',
        commands: ['vim'],
        args: '{path}',
        icon: `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 2l4.5 10L3 22h3l4.5-10L6 2H3zm8 0l4.5 10L11 22h3l4.5-10L14 2h-3zm6 9h4v2h-4v-2z"/></svg>`
    },
    {
        id: 'neovim',
        name: 'Neovim',
        commands: ['nvim'],
        args: '{path}',
        icon: `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M2 2l7 10L2 22h3.5L12 12 5.5 2H2zm10 0l7 10-7 10h3.5L22 12 15.5 2H12z"/></svg>`
    },
    {
        id: 'emacs',
        name: 'Emacs',
        commands: ['emacs', 'emacsclient'],
        args: '{path}',
        icon: `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2zm0 18c-4.41 0-8-3.59-8-8s3.59-8 8-8 8 3.59 8 8-3.59 8-8 8zm-3-7h2v-2h2v2h2v2h-2v2h-2v-2H9v-2z"/></svg>`
    },
    {
        id: 'nano',
        name: 'Nano',
        commands: ['nano'],
        args: '{path}',
        icon: `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M6 3h8l4 4v14H6V3zm2 2v14h8V8h-3V5H8zm2 6h4v1.5h-4V11zm0 3h4v1.5h-4V14z"/></svg>`
    },
    {
        id: 'helix',
        name: 'Helix',
        commands: ['hx'],
        args: '{path}',
        icon: `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M7 2l5 10L7 22h2.5l5-10-5-10H7zm5 0l5 10-5 10h2.5l5-10-5-10H12z"/></svg>`
    }
];

// Generic editor icon for "off" / unconfigured state
const GENERIC_EDITOR_ICON = `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M14.6 16.6l4.6-4.6-4.6-4.6L16 6l6 6-6 6-1.4-1.4zm-5.2 0L4.8 12l4.6-4.6L8 6l-6 6 6 6 1.4-1.4z"/></svg>`;

// State
let editorSetting = { name: 'off', custom_command: '' };
let installedEditors = [];
let editorDetectionDone = false;

/**
 * Initialize editor feature — fetch config and render header button
 */
async function initEditor() {
    try {
        // Load editor config from settings.default.json via API
        const response = await fetch(`${API_BASE}/api/config/editor`);
        if (response.ok) {
            const data = await response.json();
            editorSetting = {
                name: data.name || 'off',
                custom_command: data.custom_command || ''
            };
            if (data.installed) {
                installedEditors = data.installed;
                editorDetectionDone = true;
            }
        }
    } catch (e) {
        console.warn('Failed to load editor config:', e);
    }
    renderEditorButton();
}

/**
 * Render or update the header editor button
 */
function renderEditorButton() {
    const btn = document.getElementById('editor-btn');
    const iconEl = document.getElementById('editor-btn-icon');
    const labelEl = document.getElementById('editor-btn-label');
    if (!btn || !iconEl || !labelEl) return;

    if (editorSetting.name === 'off') {
        // Dimmed state — clicking goes to settings
        btn.classList.add('dimmed');
        btn.title = 'Configure editor';
        iconEl.innerHTML = GENERIC_EDITOR_ICON;
        labelEl.textContent = '';
        btn.onclick = () => {
            // Navigate to Settings > Editor tab
            document.querySelector('[data-tab="settings"]')?.click();
            setTimeout(() => {
                document.querySelector('[data-settings-section="editor"]')?.click();
            }, 100);
        };
    } else if (editorSetting.name === 'custom') {
        btn.classList.remove('dimmed');
        btn.title = `Open in custom editor`;
        iconEl.innerHTML = GENERIC_EDITOR_ICON;
        labelEl.textContent = 'Editor';
        btn.onclick = openEditor;
    } else {
        const editor = EDITORS.find(e => e.id === editorSetting.name);
        if (editor) {
            btn.classList.remove('dimmed');
            btn.title = `Open in ${editor.name}`;
            iconEl.innerHTML = editor.icon;
            labelEl.textContent = editor.name;
            btn.onclick = openEditor;
        }
    }
}

/**
 * Call server to open the configured editor
 */
async function openEditor() {
    const btn = document.getElementById('editor-btn');
    if (!btn || btn.classList.contains('dimmed')) return;

    btn.classList.add('launching');
    try {
        const response = await fetch(`${API_BASE}/api/open-editor`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({})
        });
        const result = await response.json();
        if (!result.success) {
            console.error('Failed to open editor:', result.error);
            btn.classList.add('error');
            setTimeout(() => btn.classList.remove('error'), 2000);
        }
    } catch (e) {
        console.error('Error opening editor:', e);
        btn.classList.add('error');
        setTimeout(() => btn.classList.remove('error'), 2000);
    } finally {
        setTimeout(() => btn.classList.remove('launching'), 600);
    }
}

/**
 * Render the Settings > Editor section content
 */
async function renderEditorSettings() {
    const container = document.getElementById('editor-grid');
    if (!container) return;

    // Refresh installed editor detection
    if (!editorDetectionDone) {
        await refreshInstalledEditors();
    }

    // Build the grid
    container.innerHTML = '';

    // "Off" option
    const offCard = createEditorCard('off', 'Off', GENERIC_EDITOR_ICON, true, editorSetting.name === 'off');
    container.appendChild(offCard);

    // Predefined editors
    for (const editor of EDITORS) {
        const installed = installedEditors.includes(editor.id);
        const active = editorSetting.name === editor.id;
        const card = createEditorCard(editor.id, editor.name, editor.icon, installed, active);
        container.appendChild(card);
    }

    // Custom option
    const customCard = createEditorCard('custom', 'Custom', GENERIC_EDITOR_ICON, true, editorSetting.name === 'custom');
    container.appendChild(customCard);

    // Show/hide custom command input
    updateCustomCommandVisibility();

    // Set custom command input value
    const cmdInput = document.getElementById('editor-custom-command');
    if (cmdInput) {
        cmdInput.value = editorSetting.custom_command || '';
    }
}

/**
 * Create an editor selection card
 */
function createEditorCard(id, name, icon, available, active) {
    const card = document.createElement('div');
    card.className = 'model-option editor-option' + (active ? ' active' : '') + (!available ? ' disabled' : '');
    card.dataset.editorId = id;

    card.innerHTML = `
        <span class="editor-option-icon">${icon}</span>
        <span class="editor-option-name">${name}</span>
        ${!available ? '<span class="editor-not-installed">not found</span>' : ''}
    `;

    if (available) {
        card.addEventListener('click', () => selectEditor(id));
    }

    return card;
}

/**
 * Handle editor selection in settings
 */
async function selectEditor(editorId) {
    editorSetting.name = editorId;

    // Update active state in grid
    document.querySelectorAll('.editor-option').forEach(el => {
        el.classList.toggle('active', el.dataset.editorId === editorId);
    });

    // Show/hide custom command input
    updateCustomCommandVisibility();

    // Save to server
    await saveEditorConfig();

    // Update header button
    renderEditorButton();
}

/**
 * Show/hide the custom command input based on selection
 */
function updateCustomCommandVisibility() {
    const customSection = document.getElementById('editor-custom-section');
    if (customSection) {
        customSection.style.display = editorSetting.name === 'custom' ? 'block' : 'none';
    }
}

/**
 * Save editor configuration to server
 */
async function saveEditorConfig() {
    try {
        await fetch(`${API_BASE}/api/config/editor`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                name: editorSetting.name,
                custom_command: editorSetting.custom_command
            })
        });
    } catch (e) {
        console.error('Failed to save editor config:', e);
    }
}

/**
 * Refresh installed editors from server (with detection scan)
 */
async function refreshInstalledEditors() {
    try {
        const response = await fetch(`${API_BASE}/api/editors?refresh=true`);
        if (response.ok) {
            const data = await response.json();
            installedEditors = data.installed || [];
            editorDetectionDone = true;
        }
    } catch (e) {
        console.warn('Failed to detect editors:', e);
    }
}

/**
 * Initialize editor custom command input handler
 */
function initEditorCustomInput() {
    const cmdInput = document.getElementById('editor-custom-command');
    if (!cmdInput) return;

    let saveTimeout = null;
    cmdInput.addEventListener('input', () => {
        editorSetting.custom_command = cmdInput.value;
        // Debounce save
        clearTimeout(saveTimeout);
        saveTimeout = setTimeout(async () => {
            await saveEditorConfig();
            renderEditorButton();
        }, 500);
    });
}
