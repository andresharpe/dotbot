/**
 * DOTBOT Control Panel - Workflow Viewer
 * Workflow viewer and relationship tree management
 */

/**
 * Get cached file data
 * @param {string} type - File type
 * @param {string} file - File name
 * @returns {Object|null} Cached data or null
 */
function getCachedFileData(type, file) {
    const key = `${type}:${file}`;
    const cached = fileDataCache.get(key);
    if (cached && (Date.now() - cached.timestamp) < CACHE_TTL) {
        return cached.data;
    }
    return null;
}

/**
 * Set cached file data
 * @param {string} type - File type
 * @param {string} file - File name
 * @param {Object} data - Data to cache
 */
function setCachedFileData(type, file, data) {
    const key = `${type}:${file}`;
    fileDataCache.set(key, { data, timestamp: Date.now() });
}

/**
 * Show workflow item in the viewer
 * @param {string} type - Item type
 * @param {string} file - File name
 */
async function showWorkflowItem(type, file) {
    const titleEl = document.getElementById('workflow-doc-title');
    const contentEl = document.getElementById('workflow-doc-content');
    const treeEl = document.getElementById('relationship-tree');

    if (!titleEl || !contentEl || !treeEl) return;

    // Switch to Workflow tab
    switchToTab('workflow');

    // Store current selection
    currentWorkflowItem = { type, file };

    // Check cache first
    const cachedData = getCachedFileData(type, file);
    if (cachedData) {
        // Immediate render from cache
        titleEl.textContent = `◈ ${file.replace(/\.md$/, '')}`;
        if (cachedData.content) {
            contentEl.innerHTML = markdownToHtml(cachedData.content);
            // Render any Mermaid diagrams
            if (typeof renderMermaidDiagrams === 'function') {
                renderMermaidDiagrams(contentEl);
            }
        } else {
            contentEl.innerHTML = '<div class="doc-placeholder">No content available</div>';
        }
        const fullChain = await buildFullChain(type, file, cachedData.references || [], cachedData.referencedBy || []);
        updateRelationshipTree(fullChain, type, file);
        return;
    }

    // Show CRT-style loading state
    titleEl.innerHTML = `◈ ${escapeHtml(file)}`;
    contentEl.innerHTML = `
        <div class="crt-loading">
            <div class="crt-loading-text">LOADING<span class="crt-loading-dots"></span></div>
            <div class="crt-loading-bar"><div class="crt-loading-progress"></div></div>
        </div>
    `;
    treeEl.innerHTML = '<div class="crt-loading-mini">...</div>';

    try {
        // Fetch file data with references from API
        const response = await fetch(`${API_BASE}/api/file/${type}/${encodeURIComponent(file)}`);
        if (!response.ok) throw new Error('Failed to fetch file data');

        const data = await response.json();

        if (!data.success) {
            throw new Error(data.error || 'Unknown error');
        }

        // Cache the result
        setCachedFileData(type, file, data);

        // Update title
        titleEl.textContent = `◈ ${file.replace(/\.md$/, '')}`;

        // Render markdown content
        if (data.content) {
            contentEl.innerHTML = markdownToHtml(data.content);
            // Render any Mermaid diagrams
            if (typeof renderMermaidDiagrams === 'function') {
                renderMermaidDiagrams(contentEl);
            }
        } else {
            contentEl.innerHTML = '<div class="doc-placeholder">No content available</div>';
        }

        // Build and update relationship tree (include both references AND referencedBy)
        const fullChain = await buildFullChain(type, file, data.references || [], data.referencedBy || []);
        updateRelationshipTree(fullChain, type, file);

    } catch (error) {
        console.error('Error loading file data:', error);
        titleEl.textContent = `◈ ${file} (error)`;
        contentEl.innerHTML = '<div class="error-state">Error loading content</div>';
        treeEl.innerHTML = '<div class="error-state">Error building relationships</div>';
    }
}

/**
 * Update relationship tree display
 * @param {Object} chain - Relationship chain data
 * @param {string} selectedType - Currently selected type
 * @param {string} selectedFile - Currently selected file
 */
function updateRelationshipTree(chain, selectedType, selectedFile) {
    const container = document.getElementById('relationship-tree');
    if (!container) return;

    // Build layers dynamically from discovered directories
    const layers = discoveredDirectories.map(dir => ({
        key: dir.name,
        title: dir.displayName,
        icon: dir.shortType.charAt(0).toUpperCase(),
        type: dir.shortType
    }));

    let html = '';
    let hasContent = false;

    layers.forEach(layer => {
        const items = chain[layer.key] || [];
        if (items.length > 0) {
            hasContent = true;

            // Group items by folder
            const grouped = {};
            items.forEach(item => {
                const parts = item.file.split('/');
                const folder = parts.length > 1 ? parts.slice(0, -1).join('/') : '(root)';
                if (!grouped[folder]) grouped[folder] = [];
                grouped[folder].push(item);
            });

            const folderKeys = Object.keys(grouped).sort();
            const hasFolders = folderKeys.length > 1 || (folderKeys.length === 1 && folderKeys[0] !== '(root)');

            html += `
                <div class="chain-layer">
                    <div class="chain-layer-header" data-layer="${layer.key}">
                        <span class="chain-layer-title">${layer.title}</span>
                        <span class="chain-layer-count">${items.length}</span>
                    </div>
                    <div class="chain-layer-items">
            `;

            if (hasFolders) {
                // Render with folder grouping
                folderKeys.forEach(folder => {
                    const folderItems = grouped[folder];
                    const folderName = folder === '(root)' ? 'root' : folder;
                    html += `
                        <div class="chain-folder">
                            <div class="chain-folder-header">
                                <span class="folder-toggle">▼</span>
                                <span class="folder-name">${escapeHtml(folderName)}</span>
                                <span class="folder-count">${folderItems.length}</span>
                            </div>
                            <div class="chain-folder-items">
                                ${folderItems.map(item => {
                                    const isSelected = item.type === selectedType && item.file === selectedFile;
                                    const displayName = item.file.split('/').pop().replace(/\.md$/, '');
                                    return `
                                        <div class="chain-layer-item${isSelected ? ' selected' : ''}" data-type="${item.type}" data-file="${escapeHtml(item.file)}">
                                            <span class="item-icon ${item.type}">${layer.icon}</span>
                                            <span class="item-name">${escapeHtml(displayName)}</span>
                                        </div>
                                    `;
                                }).join('')}
                            </div>
                        </div>
                    `;
                });
            } else {
                // Render flat (no folders)
                html += items.map(item => {
                    const isSelected = item.type === selectedType && item.file === selectedFile;
                    return `
                        <div class="chain-layer-item${isSelected ? ' selected' : ''}" data-type="${item.type}" data-file="${escapeHtml(item.file)}">
                            <span class="item-icon ${item.type}">${layer.icon}</span>
                            <span class="item-name">${escapeHtml(item.name)}</span>
                        </div>
                    `;
                }).join('');
            }

            html += `
                    </div>
                </div>
            `;
        }
    });

    if (!hasContent) {
        html = '<div class="empty-state">No relationships found</div>';
    }

    container.innerHTML = html;

    // Add click handlers for layer headers (collapse/expand)
    container.querySelectorAll('.chain-layer-header').forEach(header => {
        header.addEventListener('click', () => {
            const layer = header.closest('.chain-layer');
            layer.classList.toggle('collapsed');
        });
    });

    // Add click handlers for folder headers (collapse/expand)
    container.querySelectorAll('.chain-folder-header').forEach(header => {
        header.addEventListener('click', (e) => {
            e.stopPropagation();
            const folder = header.closest('.chain-folder');
            folder.classList.toggle('collapsed');
            const toggle = header.querySelector('.folder-toggle');
            if (toggle) toggle.textContent = folder.classList.contains('collapsed') ? '▶' : '▼';
        });
    });

    // Add click handlers for items (update selection + markdown only, don't rebuild tree)
    container.querySelectorAll('.chain-layer-item').forEach(item => {
        item.addEventListener('click', (e) => {
            e.stopPropagation();
            const type = item.dataset.type;
            const file = item.dataset.file;
            if (type && file) {
                // Update selection highlight
                container.querySelectorAll('.chain-layer-item.selected').forEach(el => el.classList.remove('selected'));
                item.classList.add('selected');

                // Update markdown content only (don't rebuild tree)
                updateWorkflowContent(type, file);
            }
        });
    });
}

/**
 * Render kickstart phase progress at top of relationship panel
 * @param {Object} data - Response from /api/kickstart/status
 */
function renderKickstartPhases(data) {
    const container = document.getElementById('relationship-tree');
    if (!container || !data || !data.phases || data.phases.length === 0) return;

    // Remove existing kickstart section if present
    const existing = container.querySelector('.kickstart-phases');
    const wasCollapsed = existing ? existing.classList.contains('collapsed') : false;
    const existingChildList = existing ? existing.querySelector('.child-task-list') : null;
    const childWasCollapsed = existingChildList ? existingChildList.classList.contains('collapsed') : true;
    if (existing) existing.remove();

    const completedCount = data.phases.filter(p => p.status === 'completed' || p.status === 'active').length;
    const totalCount = data.phases.length;

    const statusIcons = {
        completed: '<span class="phase-icon phase-completed">&#10003;</span>',
        active:    '<span class="phase-icon phase-running">&#9679;</span>',
        running:   '<span class="phase-icon phase-running">&#9679;</span>',
        failed:    '<span class="phase-icon phase-failed">&#10007;</span>',
        skipped:   '<span class="phase-icon phase-skipped">&#8211;</span>',
        pending:   '<span class="phase-icon phase-pending">&#9675;</span>',
        incomplete:'<span class="phase-icon phase-failed">&#9675;</span>'
    };

    const childStatusIcons = {
        'done':        '<span class="phase-icon phase-completed">&#10003;</span>',
        'in-progress': '<span class="led pulse"></span>',
        'analysing':   '<span class="led pulse"></span>',
        'needs-input': '<span class="led amber"></span>',
        'analysed':    '<span class="phase-icon phase-pending">&#9675;</span>',
        'todo':        '<span class="phase-icon phase-pending">&#9675;</span>',
        'skipped':     '<span class="phase-icon phase-skipped">&#8211;</span>',
        'cancelled':   '<span class="phase-icon phase-skipped">&#8211;</span>'
    };

    const sectionTitle = data.workflow_name || 'Kickstart Phases';
    let html = `
        <div class="kickstart-phases${wasCollapsed ? ' collapsed' : ''}">
            <div class="chain-layer-header" data-layer="kickstart-phases">
                <span class="chain-layer-title">${escapeHtml(sectionTitle)}</span>
                <span class="chain-layer-count">${completedCount}/${totalCount}</span>
            </div>
            <div class="chain-layer-items">
    `;

    data.phases.forEach(phase => {
        const icon = statusIcons[phase.status] || statusIcons.pending;
        html += `
            <div class="chain-layer-item kickstart-phase-item kickstart-phase-${phase.status}">
                ${icon}
                <span class="item-name">${escapeHtml(phase.name)}</span>
            </div>
        `;

        // Render child tasks for task_gen phases
        if (phase.child_tasks && phase.child_tasks.length > 0 && phase.child_counts) {
            const c = phase.child_counts;
            const done = (c.done || 0) + (c.skipped || 0);
            const total = c.total || 0;
            const pct = total > 0 ? Math.round((done / total) * 100) : 0;
            const active = (c.in_progress || 0) + (c.analysing || 0);

            html += `
                <div class="child-task-progress">
                    <div class="child-task-bar-track">
                        <div class="child-task-bar-fill" style="width: ${pct}%"></div>
                    </div>
                    <span class="child-task-summary">${done}/${total} done${active ? `, ${active} active` : ''}</span>
                </div>
                <div class="child-task-list${childWasCollapsed ? ' collapsed' : ''}">
                    <div class="child-task-toggle" title="Toggle task list">
                        <span class="folder-toggle">${childWasCollapsed ? '\u25b6' : '\u25bc'}</span>
                        <span class="child-task-toggle-label">Tasks</span>
                    </div>
                    <div class="child-task-items">
            `;
            phase.child_tasks.forEach(task => {
                const tIcon = childStatusIcons[task.status] || childStatusIcons['todo'];
                html += `
                    <div class="chain-layer-item child-task-item child-task-${task.status}">
                        ${tIcon}
                        <span class="item-name">${escapeHtml(task.name)}</span>
                    </div>
                `;
            });
            html += `
                    </div>
                </div>
            `;
        }
    });

    if (data.status === 'incomplete' && data.resume_from) {
        html += `
            <div class="kickstart-resume-row">
                <button class="kickstart-resume-btn" onclick="resumeKickstart()">RESUME</button>
            </div>
        `;
    }

    html += `
            </div>
        </div>
    `;

    // Insert at top of relationship tree
    container.insertAdjacentHTML('afterbegin', html);

    // Add collapse/expand handler
    const header = container.querySelector('.kickstart-phases .chain-layer-header');
    if (header) {
        header.addEventListener('click', () => {
            header.closest('.kickstart-phases').classList.toggle('collapsed');
        });
    }

    // Add collapse/expand handler for child task list
    container.querySelectorAll('.child-task-toggle').forEach(toggle => {
        toggle.addEventListener('click', () => {
            const list = toggle.closest('.child-task-list');
            list.classList.toggle('collapsed');
            const arrow = toggle.querySelector('.folder-toggle');
            if (arrow) arrow.textContent = list.classList.contains('collapsed') ? '\u25b6' : '\u25bc';
        });
    });
}

/**
 * Update just the markdown content without rebuilding the relationship tree
 * @param {string} type - File type
 * @param {string} file - File name
 */
async function updateWorkflowContent(type, file) {
    const titleEl = document.getElementById('workflow-doc-title');
    const contentEl = document.getElementById('workflow-doc-content');

    if (!titleEl || !contentEl) return;

    // Update current selection tracking
    currentWorkflowItem = { type, file };

    // Check cache first
    const cachedData = getCachedFileData(type, file);
    if (cachedData) {
        titleEl.textContent = `◈ ${file.replace(/\.md$/, '')}`;
        if (cachedData.content) {
            contentEl.innerHTML = markdownToHtml(cachedData.content);
            // Render any Mermaid diagrams
            if (typeof renderMermaidDiagrams === 'function') {
                renderMermaidDiagrams(contentEl);
            }
        } else {
            contentEl.innerHTML = '<div class="doc-placeholder">No content available</div>';
        }
        return;
    }

    // Show loading
    titleEl.innerHTML = `◈ ${escapeHtml(file)}`;
    contentEl.innerHTML = `
        <div class="crt-loading">
            <div class="crt-loading-text">LOADING<span class="crt-loading-dots"></span></div>
            <div class="crt-loading-bar"><div class="crt-loading-progress"></div></div>
        </div>
    `;

    try {
        const response = await fetch(`${API_BASE}/api/file/${type}/${encodeURIComponent(file)}`);
        if (!response.ok) throw new Error('Failed to fetch file data');

        const data = await response.json();
        if (!data.success) throw new Error(data.error || 'Unknown error');

        // Cache the result
        setCachedFileData(type, file, data);

        // Update content
        titleEl.textContent = `◈ ${file.replace(/\.md$/, '')}`;
        if (data.content) {
            contentEl.innerHTML = markdownToHtml(data.content);
            // Render any Mermaid diagrams
            if (typeof renderMermaidDiagrams === 'function') {
                renderMermaidDiagrams(contentEl);
            }
        } else {
            contentEl.innerHTML = '<div class="doc-placeholder">No content available</div>';
        }

    } catch (error) {
        console.error('Error loading file data:', error);
        titleEl.textContent = `◈ ${file} (error)`;
        contentEl.innerHTML = '<div class="error-state">Error loading content</div>';
    }
}

/**
 * Build full relationship chain for an item
 * @param {string} startType - Starting item type
 * @param {string} startFile - Starting file name
 * @param {Array} immediateRefs - Immediate references
 * @param {Array} immediateReferencedBy - Items that reference this
 * @returns {Object} Chain of related items by category
 */
async function buildFullChain(startType, startFile, immediateRefs, immediateReferencedBy) {
    // Build relationship chain dynamically from discovered directories
    const chain = {};
    for (const dir of discoveredDirectories) {
        chain[dir.name] = [];
    }

    const visited = new Set();

    // Add the starting file first
    const startCategory = getCategory(startType);
    if (startCategory) {
        chain[startCategory].push({
            type: startType,
            file: startFile,
            name: startFile.replace(/\.md$/, ''),
            depth: 0,
            isSelected: true
        });
    }
    visited.add(`${startType}:${startFile}`);

    // DOWNSTREAM: Add immediate references (what this file points to)
    if (immediateRefs && immediateRefs.length > 0) {
        for (const ref of immediateRefs) {
            const key = `${ref.type}:${ref.file}`;
            if (!visited.has(key)) {
                visited.add(key);
                const category = getCategory(ref.type);
                if (category && chain[category]) {
                    chain[category].push({
                        type: ref.type,
                        file: ref.file,
                        name: ref.name || ref.file.replace(/\.md$/, ''),
                        depth: 1
                    });
                }
            }
        }
    }

    // UPSTREAM: Traverse referencedBy chain to find parents
    // Build dynamic hierarchy based on directory index (first dirs are "lower")
    const typeHierarchy = {};
    discoveredDirectories.forEach((dir, index) => {
        typeHierarchy[dir.shortType] = index;
    });
    const startLevel = typeHierarchy[startType] ?? 0;

    let currentParents = (immediateReferencedBy || []).filter(ref => {
        const refLevel = typeHierarchy[ref.type] ?? 0;
        return refLevel !== startLevel; // Include items from different categories
    });

    while (currentParents.length > 0 && visited.size < 50) {
        const nextParents = [];

        for (const ref of currentParents) {
            const key = `${ref.type}:${ref.file}`;
            if (visited.has(key)) continue;
            visited.add(key);

            const category = getCategory(ref.type);
            if (category && chain[category]) {
                chain[category].push({
                    type: ref.type,
                    file: ref.file,
                    name: ref.name || ref.file.replace(/\.md$/, ''),
                    depth: -1 // Parent
                });
            }

            // Fetch this parent's referencedBy to continue up the chain
            const cached = getCachedFileData(ref.type, ref.file);
            if (cached && cached.referencedBy) {
                for (const grandparent of cached.referencedBy) {
                    const gpKey = `${grandparent.type}:${grandparent.file}`;
                    if (!visited.has(gpKey)) {
                        nextParents.push(grandparent);
                    }
                }
            } else {
                // Try to fetch if not cached
                try {
                    const response = await fetch(`${API_BASE}/api/file/${ref.type}/${encodeURIComponent(ref.file)}`);
                    if (response.ok) {
                        const data = await response.json();
                        if (data.success) {
                            setCachedFileData(ref.type, ref.file, data);
                            if (data.referencedBy) {
                                for (const grandparent of data.referencedBy) {
                                    const gpKey = `${grandparent.type}:${grandparent.file}`;
                                    if (!visited.has(gpKey)) {
                                        nextParents.push(grandparent);
                                    }
                                }
                            }
                        }
                    }
                } catch (e) {
                    // Silently continue
                }
            }
        }

        currentParents = nextParents;
    }

    return chain;
}

/**
 * Get category for a type
 * @param {string} type - Short type identifier
 * @returns {string|null} Category name or null
 */
function getCategory(type) {
    // Find the directory that matches the short type
    const dir = discoveredDirectories.find(d => d.shortType === type);
    return dir ? dir.name : null;
}
