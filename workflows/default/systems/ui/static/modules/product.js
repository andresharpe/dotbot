/**
 * DOTBOT Control Panel - Product Documentation
 * Product documentation viewer management
 */

/**
 * Initialize product navigation
 */
async function initProductNav() {
    const navContainer = document.querySelector('.product-nav');
    const viewer = document.getElementById('doc-viewer');

    if (!navContainer) return;

    // Fetch available docs from API
    try {
        const response = await fetch(`${API_BASE}/api/product/list`);
        if (!response.ok) throw new Error('Failed to fetch product docs');

        const data = await response.json();
        const docs = data.docs || [];

        if (docs.length === 0) {
            navContainer.innerHTML = '<div class="empty-state">No product docs</div>';
            return;
        }

        // Build nav items dynamically
        navContainer.innerHTML = docs.map((doc, index) => `
            <div class="product-nav-item${index === 0 ? ' active' : ''}" data-doc="${escapeHtml(doc.name)}">
                <span class="item-icon doc">${escapeHtml(doc.name.charAt(0).toUpperCase())}</span>
                <span>${escapeHtml(doc.filename)}</span>
            </div>
        `).join('');

        // Add click handlers
        navContainer.querySelectorAll('.product-nav-item').forEach(item => {
            item.addEventListener('click', () => {
                navContainer.querySelectorAll('.product-nav-item').forEach(i => i.classList.remove('active'));
                item.classList.add('active');
                loadProductDoc(item.dataset.doc);
            });
        });

        // Load first doc
        if (docs.length > 0) {
            loadProductDoc(docs[0].name);
        }
    } catch (error) {
        console.error('Failed to load product docs:', error);
        navContainer.innerHTML = '<div class="empty-state">Error loading docs</div>';
    }
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
 * Update product file navigation in sidebar
 */
async function updateProductFileNav() {
    const container = document.getElementById('product-file-nav');
    if (!container || container.dataset.loaded === 'true') return;

    try {
        const response = await fetch(`${API_BASE}/api/product/list`);
        if (!response.ok) throw new Error('Failed to fetch product docs');

        const data = await response.json();
        const docs = data.docs || [];

        if (docs.length === 0) {
            if (typeof kickstartInProgress !== 'undefined' && kickstartInProgress) {
                const desc = (typeof analyseInProgress !== 'undefined' && analyseInProgress)
                    ? 'Analysing codebase — creating product documents...'
                    : 'Kickstart in progress — creating product documents...';
                container.innerHTML = `
                    <div class="kickstart-sidebar-cta in-progress">
                        <div class="kickstart-glyph">◈</div>
                        <div class="kickstart-description">${desc}</div>
                    </div>
                `;
            } else if (typeof isNewProject !== 'undefined' && isNewProject) {
                if (typeof hasExistingCode !== 'undefined' && hasExistingCode) {
                    container.innerHTML = `
                        <div class="kickstart-sidebar-cta">
                            <div class="kickstart-glyph">◈</div>
                            <div class="kickstart-description">Existing code detected. Analyse your project to create product docs.</div>
                            <button class="kickstart-btn" onclick="openAnalyseModal()">ANALYSE</button>
                        </div>
                    `;
                } else {
                    container.innerHTML = `
                        <div class="kickstart-sidebar-cta">
                            <div class="kickstart-glyph">◈</div>
                            <div class="kickstart-description">No product docs yet. Kickstart your project to create them.</div>
                            <button class="kickstart-btn" onclick="openKickstartModal()">KICKSTART</button>
                        </div>
                    `;
                }
            } else {
                container.innerHTML = '<div class="empty-state">No product docs</div>';
            }
            return;
        }

        container.innerHTML = docs.map((doc, index) => `
            <div class="file-nav-item${index === 0 ? ' active' : ''}" data-doc="${escapeHtml(doc.name)}">
                <span class="item-icon doc">${escapeHtml(doc.name.charAt(0).toUpperCase())}</span>
                <span>${escapeHtml(doc.filename)}</span>
            </div>
        `).join('');

        container.dataset.loaded = 'true';

        // Add click handlers
        container.querySelectorAll('.file-nav-item').forEach(item => {
            item.addEventListener('click', () => {
                container.querySelectorAll('.file-nav-item').forEach(i => i.classList.remove('active'));
                item.classList.add('active');
                loadProductDoc(item.dataset.doc);
            });
        });

        // Load the first document automatically
        if (docs.length > 0) {
            loadProductDoc(docs[0].name);
        }
    } catch (error) {
        console.error('Failed to load product file nav:', error);
        container.innerHTML = '<div class="empty-state">Error loading docs</div>';
    }
}
