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

            // Build folder tree from items
            const tree = buildFolderTree(items, 'file');
            const hasFolders = Object.keys(tree.folders).length > 0;

            const renderItem = (item) => {
                const isSelected = item.type === selectedType && item.file === selectedFile;
                const displayName = item.file.split('/').pop().replace(/\.md$/, '');
                const safeType = (item.type || '').replace(/[^a-zA-Z0-9_-]/g, '');
                return `
                    <div class="chain-layer-item${isSelected ? ' selected' : ''}" data-type="${escapeHtml(item.type)}" data-file="${escapeHtml(item.file)}">
                        <span class="item-icon ${safeType}">${layer.icon}</span>
                        <span class="item-name">${escapeHtml(displayName)}</span>
                    </div>
                `;
            };

            html += `
                <div class="chain-layer">
                    <div class="chain-layer-header" data-layer="${layer.key}">
                        <span class="chain-layer-title">${layer.title}</span>
                        <span class="chain-layer-count">${items.length}</span>
                    </div>
                    <div class="chain-layer-items">
            `;

            if (hasFolders) {
                const renderTreeItems = (node) => {
                    let out = node.items.map(renderItem).join('');
                    for (const sub of Object.keys(node.folders).sort()) {
                        const subFolder = node.folders[sub];
                        out += renderFolderGroup(sub, renderTreeItems(subFolder), countTreeItems(subFolder));
                    }
                    return out;
                };

                // Render root-level items first
                html += tree.items.map(renderItem).join('');

                // Render folder groups (recursively for nested subfolders)
                for (const folderName of Object.keys(tree.folders).sort()) {
                    const folder = tree.folders[folderName];
                    const contentHtml = renderTreeItems(folder);
                    html += renderFolderGroup(folderName, contentHtml, countTreeItems(folder));
                }
            } else {
                // Render flat (no folders) — use original name for display
                html += items.map(item => {
                    const isSelected = item.type === selectedType && item.file === selectedFile;
                    const safeType = (item.type || '').replace(/[^a-zA-Z0-9_-]/g, '');
                    return `
                        <div class="chain-layer-item${isSelected ? ' selected' : ''}" data-type="${escapeHtml(item.type)}" data-file="${escapeHtml(item.file)}">
                            <span class="item-icon ${safeType}">${layer.icon}</span>
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

    // Add click handlers for folder headers (collapse/expand) — shared utility
    attachFolderToggleHandlers(container);

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
 * Render task-runner workflow progress at top of relationship panel.
 * Data comes from buildWorkflowPanelData(state) — same source as Overview tab.
 *
 * @param {Array} workflows - Array of workflow objects from buildWorkflowPanelData
 */
function renderWorkflowTaskProgress(workflows) {
    const container = document.getElementById('relationship-tree');
    if (!container) return;

    // Always clean up previous renders (legacy kickstart + our own wrapper)
    const existingLegacy = container.querySelector('.kickstart-phases');
    if (existingLegacy) existingLegacy.remove();

    // Preserve collapsed state before removing
    const prevCollapsed = {};
    container.querySelectorAll('.wf-accordion-section').forEach(section => {
        const name = section.dataset.workflow;
        if (name) prevCollapsed[name] = section.classList.contains('collapsed');
    });
    const existingWrapper = container.querySelector('.workflow-task-progress');
    const wrapperWasCollapsed = existingWrapper ? existingWrapper.classList.contains('collapsed') : false;
    if (existingWrapper) existingWrapper.remove();

    if (!workflows || workflows.length === 0) return;

    const taskStatusIcons = {
        'done':        '<span class="phase-icon phase-completed">&#10003;</span>',
        'in-progress': '<span class="led pulse"></span>',
        'analysing':   '<span class="led pulse"></span>',
        'needs-input': '<span class="led amber"></span>',
        'analysed':    '<span class="phase-icon phase-pending">&#9675;</span>',
        'todo':        '<span class="phase-icon phase-pending">&#9675;</span>',
        'skipped':     '<span class="phase-icon phase-skipped">&#8211;</span>',
        'cancelled':   '<span class="phase-icon phase-skipped">&#8211;</span>'
    };

    // Aggregate totals
    let totalDone = 0, totalAll = 0;
    workflows.forEach(wf => {
        const c = wf.counts || {};
        totalDone += (c.done || 0) + (c.skipped || 0);
        totalAll += c.total || 0;
    });

    let innerHtml = '';

    workflows.forEach(wf => {
        const counts = wf.counts || {};
        const doneCount = (counts.done || 0) + (counts.skipped || 0);
        const totalCount = counts.total || 0;
        const activeCount = (counts.in_progress || 0) + (counts.analysing || 0);
        const pct = totalCount > 0 ? Math.round((doneCount / totalCount) * 100) : 0;

        // Default: running/incomplete expanded, others collapsed (unless user toggled)
        let isCollapsed;
        if (wf.workflow_name in prevCollapsed) {
            isCollapsed = prevCollapsed[wf.workflow_name];
        } else if (workflows.length === 1) {
            isCollapsed = false;
        } else {
            isCollapsed = wf.status !== 'running' && wf.status !== 'incomplete';
        }

        const statusLed = wf.status === 'running'
            ? '<span class="led pulse" style="margin-right:6px"></span>'
            : '';

        innerHtml += `
            <div class="wf-accordion-section${isCollapsed ? ' collapsed' : ''}" data-workflow="${escapeAttr(wf.workflow_name)}">
                <div class="chain-layer-header wf-accordion-header" data-workflow="${escapeAttr(wf.workflow_name)}">
                    ${statusLed}
                    <span class="chain-layer-title">${escapeHtml(wf.workflow_name)}</span>
                    <span class="chain-layer-count">${doneCount}/${totalCount}</span>
                </div>
                <div class="wf-accordion-body">
                    <div class="child-task-progress">
                        <div class="child-task-bar-track">
                            <div class="child-task-bar-fill" style="width: ${pct}%"></div>
                        </div>
                        <span class="child-task-summary">${doneCount}/${totalCount} done${activeCount ? `, ${activeCount} active` : ''}</span>
                    </div>
                    <div class="child-task-items">
        `;

        (wf.tasks || []).forEach(task => {
            const icon = taskStatusIcons[task.status] || taskStatusIcons['todo'];
            innerHtml += `
                        <div class="chain-layer-item child-task-item child-task-${task.status}">
                            ${icon}
                            <span class="item-name">${escapeHtml(task.name)}</span>
                        </div>
            `;
        });

        innerHtml += `
                    </div>
        `;

        // Resume button per workflow
        if (wf.status === 'running') {
            innerHtml += `<div class="kickstart-resume-row"><button class="kickstart-resume-btn" disabled>RUNNING...</button></div>`;
        } else if (wf.can_resume) {
            innerHtml += `<div class="kickstart-resume-row"><button class="kickstart-resume-btn" data-resume-wf="${escapeAttr(wf.workflow_name)}">RESUME</button></div>`;
        } else if (wf.status === 'completed') {
            innerHtml += `<div class="kickstart-resume-row"><button class="kickstart-resume-btn" disabled>COMPLETED</button></div>`;
        }

        innerHtml += `
                </div>
            </div>
        `;
    });

    const wrapperHtml = `
        <div class="workflow-task-progress${wrapperWasCollapsed ? ' collapsed' : ''}">
            <div class="chain-layer-header" data-layer="workflow-task-progress">
                <span class="chain-layer-title">Task Progress</span>
                <span class="chain-layer-count">${totalDone}/${totalAll}</span>
            </div>
            <div class="chain-layer-items">
                ${innerHtml}
            </div>
        </div>
    `;

    container.insertAdjacentHTML('afterbegin', wrapperHtml);

    // Wrapper collapse/expand handler
    const wrapperHeader = container.querySelector('.workflow-task-progress > .chain-layer-header');
    if (wrapperHeader) {
        wrapperHeader.addEventListener('click', () => {
            wrapperHeader.closest('.workflow-task-progress').classList.toggle('collapsed');
        });
    }

    // Accordion collapse/expand handlers
    container.querySelectorAll('.workflow-task-progress .wf-accordion-header').forEach(header => {
        header.addEventListener('click', () => {
            header.closest('.wf-accordion-section').classList.toggle('collapsed');
        });
    });

    // Resume button handlers
    container.querySelectorAll('.workflow-task-progress .kickstart-resume-btn[data-resume-wf]').forEach(btn => {
        btn.addEventListener('click', () => {
            resumeWorkflow(btn.dataset.resumeWf);
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

// ========== WORKFLOW DETAIL PANEL (master-detail navigation) ==========

/** Map directory/group name to an icon name from our material icons library */
function dirIcon(name) {
    // Strip workflow prefix (e.g. "iwg-bs-scoring/agents" → "agents")
    const base = name.includes('/') ? name.split('/').pop() : name;
    const map = {
        'agents': 'smartToy',
        'skills': 'extension',
        'tools': 'buildCircle',
        'commands': 'terminal',
        'standards': 'description',
        'workflows': 'accountTree',
        'research': 'science',
        'includes': 'dataObject',
    };
    return map[base] || 'folder';
}

// Track last rendered workflow data to avoid unnecessary re-renders
let lastWorkflowNavData = null;

/**
 * Render the workflow navigation tree in the left panel.
 * Shows workflow headers with hierarchy trees (agents, skills, tools)
 * plus the existing prompts directories for file browsing.
 * @param {Array} workflows - Array of workflow objects from /api/workflows/installed
 */
function renderWorkflowDetailPanel(workflows) {
    const container = document.getElementById('wf-nav-tree');
    if (!container) return;

    // Skip re-render if data hasn't changed (compare serialized)
    const dirCount = discoveredDirectories ? discoveredDirectories.length : 0;
    const dataKey = JSON.stringify({ d: dirCount, w: workflows?.map(w => `${w.name}:${w.status}:${w.tasks?.done}:${w.tasks?.total}`) });
    if (dataKey === lastWorkflowNavData) return;
    lastWorkflowNavData = dataKey;

    // Preserve expand/collapse state
    const expandedWfs = new Set();
    const expandedGroups = new Set();
    container.querySelectorAll('.wf-section:not(.collapsed)').forEach(s => expandedWfs.add(s.dataset.workflow));
    container.querySelectorAll('.wf-group:not(.collapsed)').forEach(g => expandedGroups.add(g.dataset.groupKey));

    const wfList = workflows || [];

    // Default: expand all workflow sections (but groups inside stay collapsed for lazy loading)
    if (expandedWfs.size === 0) {
        wfList.forEach(w => expandedWfs.add(w.name));
    }

    let html = '';

    wfList.forEach(wf => {
        const isExpanded = expandedWfs.has(wf.name);
        const isRunning = wf.status === 'running' || wf.has_running_process;
        const ledClass = isRunning ? 'led pulse' : 'led off';
        const done = wf.tasks?.done || 0;
        const total = wf.tasks?.total || 0;
        const pct = total > 0 ? Math.round((done / total) * 100) : 0;

        html += `<div class="wf-section${isExpanded ? '' : ' collapsed'}" data-workflow="${escapeHtml(wf.name)}">`;

        // Workflow header row
        html += `
            <div class="wf-header${isRunning ? ' running' : ''}">
                <span class="${ledClass}"></span>
                <span class="wf-header-icon">${getIcon('accountTree', 14)}</span>
                <span class="wf-header-name">${escapeHtml(wf.name)}</span>
                <div class="wf-header-actions">
                    <button class="ctrl-btn-xs wf-studio-btn" data-workflow="${escapeHtml(wf.name)}" title="Open in Studio">${getIcon('edit', 12)}</button>
                    <button class="ctrl-btn-xs primary wf-run-btn" data-workflow="${escapeHtml(wf.name)}" data-has-form="${!!wf.has_form}" ${isRunning ? 'disabled' : ''} title="Run">${getIcon('playArrow', 12)}</button>
                    <button class="ctrl-btn-xs wf-stop-btn" data-workflow="${escapeHtml(wf.name)}" ${!isRunning ? 'disabled' : ''} title="Stop">${getIcon('stop', 12)}</button>
                </div>
            </div>
        `;

        // Workflow detail (expanded content)
        html += '<div class="wf-detail">';

        // Progress bar (if tasks exist)
        if (total > 0) {
            html += `
                <div class="wf-progress-row">
                    <div class="child-task-bar-track"><div class="child-task-bar-fill" style="width:${pct}%"></div></div>
                    <span class="wf-progress-pct">${pct}%</span>
                </div>
            `;
        }

        // Hierarchy groups: Agents, Skills, Tools — lazy-loaded from API for correct file paths
        const groups = [
            { key: 'agents', label: 'Agents', icon: 'smartToy', dirName: wf.is_default ? 'agents' : `${wf.name}/agents`, count: (wf.agents || []).length },
            { key: 'skills', label: 'Skills', icon: 'extension', dirName: wf.is_default ? 'skills' : `${wf.name}/skills`, count: (wf.skills || []).length },
            { key: 'tools',  label: 'Tools',  icon: 'buildCircle', dirName: wf.is_default ? 'tools' : `${wf.name}/tools`, count: (wf.tools || []).length }
        ];

        // Find the matching discoveredDirectory for shortType lookup
        groups.forEach(group => {
            if (group.count === 0) return;
            const dir = discoveredDirectories?.find(d => d.name === group.dirName);
            const shortType = dir ? dir.shortType : group.key.substring(0, 3);
            const groupKey = `${wf.name}:${group.key}`;
            const groupExpanded = expandedGroups.has(groupKey);
            html += `
                <div class="wf-group${groupExpanded ? '' : ' collapsed'}" data-group-key="${groupKey}">
                    <div class="wf-group-header">
                        <span class="wf-group-toggle">${groupExpanded ? '\u25bc' : '\u25b6'}</span>
                        <span class="wf-group-icon">${getIcon(group.icon, 13)}</span>
                        <span class="wf-group-label">${group.label}</span>
                        <span class="wf-group-count">${group.count}</span>
                    </div>
                    <div class="wf-group-items" data-dir-type="${shortType}" data-dir-name="${group.dirName}">
                        <div class="loading-state" style="font-size:10px">Loading...</div>
                    </div>
                </div>
            `;
        });

        // Show prompts directories scoped to this workflow (skip those already rendered as manifest groups)
        if (discoveredDirectories && discoveredDirectories.length > 0) {
            // Build set of dirNames already rendered as manifest groups above
            const renderedDirNames = new Set(groups.filter(g => g.count > 0).map(g => g.dirName));
            discoveredDirectories.forEach(dir => {
                if (renderedDirNames.has(dir.name)) return; // Already shown as manifest group
                if (wf.is_default) {
                    if (dir.workflow) return; // Skip workflow-scoped dirs
                } else {
                    if (dir.workflow !== wf.name) return; // Only show dirs belonging to this workflow
                }
                const label = dir.workflow ? dir.displayName.split(' / ').pop() : dir.displayName;
                const groupKey = `${wf.name}:dir:${dir.name}`;
                const groupExpanded = expandedGroups.has(groupKey);
                html += `
                    <div class="wf-group${groupExpanded ? '' : ' collapsed'}" data-group-key="${groupKey}">
                        <div class="wf-group-header">
                            <span class="wf-group-toggle">${groupExpanded ? '\u25bc' : '\u25b6'}</span>
                            <span class="wf-group-icon">${getIcon(dirIcon(dir.name), 13)}</span>
                            <span class="wf-group-label">${escapeHtml(label)}</span>
                        </div>
                        <div class="wf-group-items" data-dir-type="${dir.shortType}" data-dir-name="${dir.name}">
                            <div class="loading-state" style="font-size:10px">Loading...</div>
                        </div>
                    </div>
                `;
            });
        }

        // Inline metadata details
        if (wf.description || wf.version || wf.author || (wf.tags && wf.tags.length > 0)) {
            html += '<div class="wf-inline-meta">';
            if (wf.description) {
                html += `<div class="wf-meta-desc">${escapeHtml(wf.description)}</div>`;
            }
            if (wf.version || wf.author) {
                html += '<div class="wf-meta-rows">';
                if (wf.version) html += `<div class="wf-meta-row"><span class="wf-meta-label">Version</span><span class="wf-meta-value">${escapeHtml(wf.version)}</span></div>`;
                if (wf.author) {
                    const authorName = typeof wf.author === 'string' ? wf.author : (wf.author.name || '');
                    if (authorName) html += `<div class="wf-meta-row"><span class="wf-meta-label">Author</span><span class="wf-meta-value">${escapeHtml(authorName)}</span></div>`;
                }
                if (wf.license) html += `<div class="wf-meta-row"><span class="wf-meta-label">License</span><span class="wf-meta-value">${escapeHtml(wf.license)}</span></div>`;
                if (wf.tasks && wf.tasks.total > 0) html += `<div class="wf-meta-row"><span class="wf-meta-label">Tasks</span><span class="wf-meta-value">${wf.tasks.done}/${wf.tasks.total}</span></div>`;
                html += '</div>';
            }
            if (wf.tags && wf.tags.length > 0) {
                html += '<div class="wf-meta-tags">';
                wf.tags.forEach(tag => { html += `<span class="wf-meta-tag">${escapeHtml(tag)}</span>`; });
                html += '</div>';
            }
            if (wf.categories && wf.categories.length > 0) {
                html += '<div class="wf-meta-tags">';
                wf.categories.forEach(cat => { html += `<span class="wf-meta-tag cat">${escapeHtml(cat)}</span>`; });
                html += '</div>';
            }
            if (wf.repository || wf.homepage) {
                html += '<div class="wf-meta-links">';
                if (wf.repository) html += `<a href="${escapeHtml(wf.repository)}" target="_blank" class="wf-meta-link">${getIcon('link', 12)} Repo</a>`;
                if (wf.homepage) html += `<a href="${escapeHtml(wf.homepage)}" target="_blank" class="wf-meta-link">${getIcon('launch', 12)} Home</a>`;
                html += '</div>';
            }
            html += '</div>';
        }

        html += '</div></div>'; // close wf-detail, wf-section
    });

    container.innerHTML = html;

    // Wire event handlers
    // Run/Stop buttons
    container.querySelectorAll('.wf-run-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            const name = btn.dataset.workflow;
            const hasForm = btn.dataset.hasForm === 'true';
            runWorkflow(name, hasForm);
        });
    });
    container.querySelectorAll('.wf-stop-btn').forEach(btn => {
        btn.addEventListener('click', () => stopWorkflow(btn.dataset.workflow));
    });
    container.querySelectorAll('.wf-studio-btn').forEach(btn => {
        btn.addEventListener('click', () => launchStudio(btn.dataset.workflow));
    });

    // Workflow header click → expand/collapse
    container.querySelectorAll('.wf-header').forEach(header => {
        header.addEventListener('click', (e) => {
            if (e.target.closest('button')) return; // Don't toggle on Run/Stop click
            const section = header.closest('.wf-section');
            section.classList.toggle('collapsed');
            // Update sidebar metadata for the expanded workflow
            const wfName = section.dataset.workflow;
            const wf = wfList.find(w => w.name === wfName);
            if (wf && !section.classList.contains('collapsed')) {
                renderWorkflowMetaSidebar(wf);
            }
        });
    });

    // Group header click → expand/collapse
    container.querySelectorAll('.wf-group-header').forEach(header => {
        header.addEventListener('click', () => {
            const group = header.closest('.wf-group');
            group.classList.toggle('collapsed');
            const toggle = header.querySelector('.wf-group-toggle');
            if (toggle) toggle.textContent = group.classList.contains('collapsed') ? '\u25b6' : '\u25bc';

            // Lazy-load directory items if not yet loaded
            const itemsContainer = group.querySelector('.wf-group-items[data-dir-type]');
            if (itemsContainer && !itemsContainer.dataset.loaded && !group.classList.contains('collapsed')) {
                loadWfGroupItems(itemsContainer, itemsContainer.dataset.dirType, itemsContainer.dataset.dirName);
            }
        });
    });

    // Tree item click → show in viewer
    container.querySelectorAll('.wf-tree-item').forEach(item => {
        item.addEventListener('click', (e) => {
            e.stopPropagation();
            const type = item.dataset.type;
            const file = item.dataset.file;
            if (type && file) {
                container.querySelectorAll('.wf-tree-item.selected').forEach(el => el.classList.remove('selected'));
                item.classList.add('selected');
                showWorkflowItem(type, file);
            }
        });
    });

    // Update sidebar for the first expanded workflow
    const firstExpanded = wfList.find(w => expandedWfs.has(w.name)) || wfList[0];
    if (firstExpanded) renderWorkflowMetaSidebar(firstExpanded);
}

/**
 * Lazy-load items for a prompts directory group in the workflow nav tree
 */
async function loadWfGroupItems(container, shortType, dirName) {
    container.dataset.loaded = '1';
    try {
        const response = await fetch(`${API_BASE}/api/${dirName}/list`);
        if (!response.ok) throw new Error('Failed to fetch');
        const data = await response.json();
        const groups = data.groups || [];

        // Flatten all items, using folder name as display name for subdirectory items
        // e.g. agents/implementer/AGENT.md → display as "implementer"
        const allItems = [];
        const seen = new Set(); // Deduplicate: one entry per folder for single-file dirs
        groups.forEach(g => {
            (g.items || []).forEach(item => {
                const parts = (item.filename || '').split('/');
                let displayName;
                if (parts.length > 1) {
                    // Subdirectory item: use the directory name as display name
                    displayName = parts[0];
                } else {
                    // Root-level item: use the basename
                    displayName = item.name || item.basename;
                }
                // Deduplicate by display name (one entry per agent/skill directory)
                if (seen.has(displayName)) return;
                seen.add(displayName);
                allItems.push({ filename: item.filename, displayName });
            });
        });

        if (allItems.length === 0) {
            container.innerHTML = '<div class="empty-state" style="font-size:10px">(empty)</div>';
            return;
        }

        container.innerHTML = allItems.map(item => `
            <div class="wf-tree-item" data-type="${shortType}" data-file="${escapeHtml(item.filename)}">
                <span class="wf-tree-item-name">${escapeHtml(item.displayName)}</span>
            </div>
        `).join('');

        // Wire click handlers
        container.querySelectorAll('.wf-tree-item').forEach(el => {
            el.addEventListener('click', (e) => {
                e.stopPropagation();
                const type = el.dataset.type;
                const file = el.dataset.file;
                if (type && file) {
                    document.querySelectorAll('#wf-nav-tree .wf-tree-item.selected').forEach(s => s.classList.remove('selected'));
                    el.classList.add('selected');
                    showWorkflowItem(type, file);
                }
            });
        });
    } catch (error) {
        container.innerHTML = '<div class="empty-state" style="font-size:10px">Error</div>';
    }
}

/**
 * Render workflow metadata in the sidebar context panel
 * @param {Object|null} wf - Workflow object from /api/workflows/installed
 */
function renderWorkflowMetaSidebar(wf) {
    const container = document.getElementById('wf-meta-content');
    if (!container) return;

    if (!wf) {
        container.innerHTML = '<div class="empty-state">No workflow selected</div>';
        return;
    }

    let html = '';

    // Description
    if (wf.description) {
        html += `<div class="wf-meta-desc">${escapeHtml(wf.description)}</div>`;
    }

    // Metadata rows
    html += '<div class="wf-meta-rows">';
    if (wf.version) html += `<div class="wf-meta-row"><span class="wf-meta-label">Version</span><span class="wf-meta-value">${escapeHtml(wf.version)}</span></div>`;
    if (wf.author) {
        const authorName = typeof wf.author === 'string' ? wf.author : (wf.author.name || '');
        if (authorName) html += `<div class="wf-meta-row"><span class="wf-meta-label">Author</span><span class="wf-meta-value">${escapeHtml(authorName)}</span></div>`;
    }
    if (wf.license) html += `<div class="wf-meta-row"><span class="wf-meta-label">License</span><span class="wf-meta-value">${escapeHtml(wf.license)}</span></div>`;
    if (wf.rerun) html += `<div class="wf-meta-row"><span class="wf-meta-label">Re-run</span><span class="wf-meta-value">${escapeHtml(wf.rerun)}</span></div>`;
    html += '</div>';

    // Tags
    if (wf.tags && wf.tags.length > 0) {
        html += '<div class="wf-meta-tags">';
        wf.tags.forEach(tag => {
            html += `<span class="wf-meta-tag">${escapeHtml(tag)}</span>`;
        });
        html += '</div>';
    }

    // Categories
    if (wf.categories && wf.categories.length > 0) {
        html += '<div class="wf-meta-tags">';
        wf.categories.forEach(cat => {
            html += `<span class="wf-meta-tag cat">${escapeHtml(cat)}</span>`;
        });
        html += '</div>';
    }

    // Links
    if (wf.repository || wf.homepage) {
        html += '<div class="wf-meta-links">';
        if (wf.repository) html += `<a href="${escapeHtml(wf.repository)}" target="_blank" class="wf-meta-link">${getIcon('link', 12)} Repository</a>`;
        if (wf.homepage) html += `<a href="${escapeHtml(wf.homepage)}" target="_blank" class="wf-meta-link">${getIcon('launch', 12)} Homepage</a>`;
        html += '</div>';
    }

    container.innerHTML = html;
}
