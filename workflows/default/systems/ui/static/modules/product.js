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
 */
async function loadProductDoc(docName) {
    const viewer = document.getElementById('doc-viewer');
    if (!viewer) return;

    viewer.innerHTML = '<div class="loading-state">Loading...</div>';

    try {
        const response = await fetch(`${API_BASE}/api/product/${encodeURIComponent(docName)}`);
        const data = await response.json();

        if (data.success && data.content) {
            // Convert markdown to basic HTML
            viewer.innerHTML = markdownToHtml(data.content);
            // Render any Mermaid diagrams
            if (typeof renderMermaidDiagrams === 'function') {
                renderMermaidDiagrams(viewer);
            }
        } else {
            viewer.innerHTML = `<div class="doc-placeholder">Document not found: ${escapeHtml(docName)}</div>`;
        }
    } catch (error) {
        console.error('Failed to load doc:', error);
        viewer.innerHTML = '<div class="doc-placeholder">Error loading document</div>';
    }
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
    if (item.dataset.type === 'binary') {
        showBinaryPlaceholder({
            name: item.dataset.doc,
            filename: item.dataset.filename,
            size: parseInt(item.dataset.size, 10) || 0
        });
    } else {
        loadProductDoc(item.dataset.doc);
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
    const isBinary = type !== 'md';
    const binaryClass = isBinary ? ' binary' : '';
    const displayName = doc.filename.split('/').pop().replace(/\.md$/, '');
    const icon = isBinary ? '&#x1F4C4;' : escapeHtml(displayName.charAt(0).toUpperCase());
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
