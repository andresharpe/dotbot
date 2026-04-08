/**
 * DOTBOT Control Panel - Product Documentation
 * Product documentation viewer with subfolder tree navigation
 */

/**
 * Initialize product navigation
 */
async function initProductNav() {
    await updateProductFileNav();
}

/**
 * Load a product document
 * @param {string} docName - Document name to load
 * @param {string} type - Document type: 'md' or 'json'
 */
async function loadProductDoc(docName, type = 'md') {
    const viewer = document.getElementById('doc-viewer');
    if (!viewer) return;

    viewer.innerHTML = '<div class="loading-state">Loading...</div>';

    try {
        const response = await fetch(`${API_BASE}/api/product/${encodeURIComponent(docName)}`);
        const data = await response.json();

        if (data.success && data.content) {
            if (type === 'json') {
                viewer.innerHTML = renderJsonViewer(data.content);
                initJsonViewer(viewer);
            } else {
                // Convert markdown to basic HTML
                viewer.innerHTML = markdownToHtml(data.content);
                // Render any Mermaid diagrams
                if (typeof renderMermaidDiagrams === 'function') {
                    renderMermaidDiagrams(viewer);
                }
            }
        } else {
            viewer.innerHTML = `<div class="doc-placeholder">Document not found: ${escapeHtml(docName)}</div>`;
        }
    } catch (error) {
        console.error('Failed to load doc:', error);
        viewer.innerHTML = '<div class="doc-placeholder">Error loading document</div>';
    }
}

let _jsonNodeCounter = 0;

/**
 * Render a JSON document with collapsible tree view
 * @param {string} content - Raw JSON string
 * @returns {string} - HTML string
 */
function renderJsonViewer(content) {
    try {
        const parsed = JSON.parse(content);
        _jsonNodeCounter = 0;
        const treeHtml = renderJsonLines(parsed, 0, null, true);
        return `<div class="json-viewer">
            <div class="json-viewer-header">
                <span class="json-viewer-label">JSON</span>
                <span class="json-viewer-controls">
                    <button type="button" class="json-ctrl-btn" data-action="collapse">− collapse all</button>
                    <button type="button" class="json-ctrl-btn" data-action="expand">+ expand all</button>
                </span>
            </div>
            <div class="json-tree">${treeHtml}</div>
        </div>`;
    } catch (e) {
        return `<div class="json-viewer"><div class="json-viewer-header"><span class="json-viewer-label">JSON</span><span class="json-viewer-error-badge">parse error</span></div><div class="json-parse-error">${escapeHtml(e.message)}</div><pre class="json-pre">${escapeHtml(content)}</pre></div>`;
    }
}

/**
 * Recursively render JSON value as collapsible tree lines
 * @param {*} value - The JSON value
 * @param {number} depth - Current nesting depth
 * @param {string|null} key - Object key for this value, or null
 * @param {boolean} isLast - Whether this is the last item in its parent
 * @returns {string} - HTML string
 */
function renderJsonLines(value, depth, key, isLast) {
    const pl = `padding-left:${depth * 14}px`;
    const keyHtml = key !== null ? `<span class="json-key">"${escapeHtml(key)}"</span>: ` : '';
    const commaHtml = isLast ? '' : '<span class="json-punct">,</span>';

    if (value === null) return `<div class="json-line" style="${pl}">${keyHtml}<span class="json-null">null</span>${commaHtml}</div>`;
    if (typeof value === 'boolean') return `<div class="json-line" style="${pl}">${keyHtml}<span class="json-bool">${value}</span>${commaHtml}</div>`;
    if (typeof value === 'number') return `<div class="json-line" style="${pl}">${keyHtml}<span class="json-number">${value}</span>${commaHtml}</div>`;
    if (typeof value === 'string') return `<div class="json-line" style="${pl}">${keyHtml}<span class="json-string">"${escapeHtml(value)}"</span>${commaHtml}</div>`;

    const isArray = Array.isArray(value);
    const keys = isArray ? null : Object.keys(value);
    const count = isArray ? value.length : keys.length;
    const open = isArray ? '[' : '{';
    const close = isArray ? ']' : '}';

    if (count === 0) {
        return `<div class="json-line" style="${pl}">${keyHtml}<span class="json-bracket">${open}${close}</span>${commaHtml}</div>`;
    }

    const id = 'jn' + (++_jsonNodeCounter);
    const summary = isArray ? `${count} item${count !== 1 ? 's' : ''}` : `${count} key${count !== 1 ? 's' : ''}`;
    const summarySpan = `<span class="json-summary json-hidden" data-collapse="${id}">…${summary}${close}</span>`;
    const commaInline = commaHtml ? `<span class="json-comma-inline json-hidden" data-collapse="${id}">${commaHtml}</span>` : '';

    const childrenHtml = isArray
        ? value.map((v, i) => renderJsonLines(v, depth + 1, null, i === value.length - 1)).join('')
        : keys.map((k, i) => renderJsonLines(value[k], depth + 1, k, i === keys.length - 1)).join('');

    const openLine = `<div class="json-line" style="${pl}">${keyHtml}<span class="json-toggle" data-target="${id}">▼</span><span class="json-bracket">${open}</span>${summarySpan}${commaInline}</div>`;
    const childrenDiv = `<div class="json-children" id="${id}">${childrenHtml}<div class="json-close-line" style="${pl}"><span class="json-bracket">${close}</span>${commaHtml}</div></div>`;
    return openLine + childrenDiv;
}

/**
 * Toggle a JSON node expanded/collapsed
 * @param {string} id - The json-children element ID
 * @param {root} id - The scope
 */
function jsonToggle(id, root) {
    const scope = root || document;
    const children = scope.getElementById ? scope.getElementById(id) : scope.querySelector('#' + id);
    if (!children) return;
    const willCollapse = !children.classList.contains('json-collapsed');
    children.classList.toggle('json-collapsed', willCollapse);
    scope.querySelectorAll(`[data-collapse="${id}"]`).forEach(el => {
        el.classList.toggle('json-hidden', !willCollapse);
    });
    const toggle = scope.querySelector(`.json-toggle[data-target="${id}"]`);
    if (toggle) toggle.textContent = willCollapse ? '▶' : '▼';
}

/**
 * Collapse or expand all nodes in a json-viewer
 * @param {HTMLElement} viewer - The .json-viewer container
 * @param {boolean} collapse - true to collapse all, false to expand all
 */
function jsonToggleAll(viewer, collapse) {
    viewer.querySelectorAll('.json-children').forEach(el => {
        const isCollapsed = el.classList.contains('json-collapsed');
        if (collapse !== isCollapsed) jsonToggle(el.id, viewer);
    });
}

function _jsonViewerClickHandler(e) {
    const toggle = e.target.closest('.json-toggle[data-target]');
    const summary = e.target.closest('.json-summary[data-collapse]');
    const ctrl = e.target.closest('.json-ctrl-btn[data-action]');
    const viewer = e.currentTarget;
    if (toggle) {
        jsonToggle(toggle.dataset.target, viewer);
    } else if (summary) {
        jsonToggle(summary.dataset.collapse, viewer);
    } else if (ctrl) {
        jsonToggleAll(ctrl.closest('.json-viewer'), ctrl.dataset.action === 'collapse');
    }
}

/**
 * Attach click event delegation for JSON tree toggles (safe to call multiple times)
 * @param {HTMLElement} container - The doc-viewer container
 */
function initJsonViewer(container) {
    container.removeEventListener('click', _jsonViewerClickHandler);
    container.addEventListener('click', _jsonViewerClickHandler);
}

/**
 * Show placeholder for non-markdown (binary) files
 * @param {object} doc - Document object with name, filename, size
 */
function showBinaryPlaceholder(doc) {
    const viewer = document.getElementById('doc-viewer');
    if (!viewer) return;

    viewer.innerHTML = `<div class="doc-placeholder">
        <div style="text-align:center; padding: 40px 20px;">
            <div style="font-size: 32px; margin-bottom: 12px; opacity: 0.4;">&#x1F4C4;</div>
            <p style="font-size: 13px; margin-bottom: 6px;"><strong>${escapeHtml(doc.filename)}</strong></p>
            <p style="font-size: 11px; color: var(--label-color);">${formatFileSize(doc.size)} &mdash; Preview not available</p>
        </div>
    </div>`;
}

/**
 * Format file size in human-readable form
 * @param {number} bytes
 * @returns {string}
 */
function formatFileSize(bytes) {
    if (bytes == null) return '0 B';
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1048576) return Math.round(bytes / 1024) + ' KB';
    return (bytes / 1048576).toFixed(1) + ' MB';
}

/**
 * Activate a product file nav item — load markdown or show binary placeholder.
 * @param {HTMLElement} item - The .file-nav-item element
 */
function activateProductItem(item) {
    const type = item.dataset.type;
    if (type === 'binary') {
        showBinaryPlaceholder({
            name: item.dataset.doc,
            filename: item.dataset.filename,
            size: parseInt(item.dataset.size, 10) || 0
        });
    } else {
        loadProductDoc(item.dataset.doc, type);
    }
}

/**
 * Render tree HTML recursively
 * @param {object} tree - Tree node from buildFolderTree (uses .items / .folders)
 * @returns {string} - HTML string
 */
function renderProductTree(tree) {
    let html = '';

    // Render root-level docs first (no folder wrapper)
    for (const doc of tree.items) {
        html += renderProductFileItem(doc);
    }

    // Render folders
    for (const folderName of Object.keys(tree.folders)) {
        const folder = tree.folders[folderName];
        const itemCount = countTreeItems(folder);
        const contentHtml = renderProductTree(folder);
        html += renderFolderGroup(folderName, contentHtml, itemCount);
    }

    return html;
}

/**
 * Render a single file nav item
 * @param {object} doc - Document object
 * @returns {string} - HTML string
 */
function renderProductFileItem(doc) {
    const type = doc.type || 'md';
    const isBinary = type !== 'md' && type !== 'json';
    const binaryClass = isBinary ? ' binary' : '';
    const displayName = doc.filename.split('/').pop().replace(/\.(md|json)$/, '');
    const icon = isBinary ? '&#x1F4C4;' : (type === 'json' ? '&#x7B;&#x7D;' : escapeHtml(displayName.charAt(0).toUpperCase()));
    return `<div class="file-nav-item${binaryClass}" data-doc="${escapeHtml(doc.name)}" data-type="${escapeHtml(type)}" data-filename="${escapeHtml(doc.filename)}" data-size="${doc.size || 0}">
        <span class="item-icon doc">${icon}</span>
        <span>${escapeHtml(displayName)}</span>
    </div>`;
}

/**
 * Update product file navigation in sidebar with tree structure
 */
async function updateProductFileNav() {
    const container = document.getElementById('product-file-nav');
    if (!container || container.dataset.loaded === 'true') return;

    // Update project info card
    updateProjectInfoCard();

    try {
        const response = await fetch(`${API_BASE}/api/product/list`);
        if (!response.ok) throw new Error('Failed to fetch product docs');

        const data = await response.json();
        const docs = data.docs || [];

        if (docs.length === 0) {
            container.innerHTML = '<div class="empty-state">No product docs</div>';
            return;
        }

        // Build and render tree
        const tree = buildFolderTree(docs, 'filename');
        container.innerHTML = renderProductTree(tree);

        container.dataset.loaded = 'true';

        // Attach folder toggle handlers (shared utility)
        attachFolderToggleHandlers(container);

        // Attach file click handlers
        container.querySelectorAll('.file-nav-item').forEach(item => {
            item.addEventListener('click', () => {
                container.querySelectorAll('.file-nav-item').forEach(i => i.classList.remove('active'));
                item.classList.add('active');
                activateProductItem(item);
            });
        });

        // Load the first document automatically
        const firstItem = container.querySelector('.file-nav-item');
        if (firstItem) {
            firstItem.classList.add('active');
            activateProductItem(firstItem);
        }
    } catch (error) {
        console.error('Failed to load product file nav:', error);
        container.innerHTML = '<div class="empty-state">Error loading docs</div>';
    }
}

/**
 * Update the project info card in the Product sidebar
 * Uses globals: projectName, currentWorkflowName, executiveSummary, projectRoot
 */
function updateProjectInfoCard() {
    const nameEl = document.getElementById('project-info-name');
    const workflowEl = document.getElementById('project-info-workflow');
    const summaryEl = document.getElementById('project-info-summary');
    const pathEl = document.getElementById('project-info-path');

    if (nameEl) {
        nameEl.textContent = projectName || '--';
    }
    if (workflowEl) {
        if (currentWorkflowName) {
            workflowEl.innerHTML = `<span class="project-info-label">Workflow</span> ${escapeHtml(currentWorkflowName)}`;
            workflowEl.style.display = '';
        } else {
            workflowEl.style.display = 'none';
        }
    }
    if (summaryEl) {
        if (executiveSummary) {
            summaryEl.textContent = executiveSummary;
            summaryEl.style.display = '';
        } else {
            summaryEl.style.display = 'none';
        }
    }
    if (pathEl) {
        if (projectRoot && projectRoot !== 'unknown') {
            pathEl.textContent = projectRoot;
            pathEl.title = projectRoot;
            pathEl.style.display = '';
        } else {
            pathEl.style.display = 'none';
        }
    }
}
