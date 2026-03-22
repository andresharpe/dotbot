/**
 * DOTBOT Control Panel - Sidebar Management
 * Dynamic sidebar loading and rendering
 */

/**
 * Initialize sidebar collapse functionality
 */
function initSidebarCollapse() {
    const headers = document.querySelectorAll('.sidebar-header');
    headers.forEach(header => {
        header.addEventListener('click', () => {
            const section = header.closest('.sidebar-section');
            const isCollapsed = section.classList.toggle('collapsed');
            const toggle = header.querySelector('.sidebar-toggle');
            if (toggle) {
                toggle.innerHTML = getIcon(isCollapsed ? 'chevronRight' : 'expandMore', 16);
            }
        });
    });
}

/**
 * Initialize collapse for dynamically created sections
 * @param {HTMLElement} container - Container element
 */
function initSidebarCollapseForContainer(container) {
    container.querySelectorAll('.sidebar-header').forEach(header => {
        header.addEventListener('click', () => {
            const section = header.closest('.sidebar-section');
            const content = section.querySelector('.sidebar-content');
            const isCollapsed = section.classList.toggle('collapsed');
            content.style.display = isCollapsed ? 'none' : 'block';
            const toggle = header.querySelector('.sidebar-toggle');
            if (toggle) {
                toggle.innerHTML = getIcon(isCollapsed ? 'chevronRight' : 'expandMore', 16);
            }
        });
    });
}

/**
 * Initialize the sidebar with dynamic content
 */
async function initSidebar() {
    const container = document.getElementById('prompts-sidebar');
    if (!container) return;

    try {
        // Fetch available directories from the server
        const response = await fetch(`${API_BASE}/api/prompts/directories`);
        if (!response.ok) throw new Error('Failed to fetch directories');

        const data = await response.json();
        discoveredDirectories = data.directories || [];

        if (discoveredDirectories.length === 0) {
            container.innerHTML = '<div class="empty-state">No prompt directories found</div>';
            return;
        }

        // Generate sidebar sections dynamically
        let html = '';
        for (const dir of discoveredDirectories) {
            html += `
                <div class="sidebar-section" data-section="${escapeHtml(dir.name)}">
                    <div class="sidebar-header">
                        <span class="sidebar-title">◈ ${escapeHtml(dir.displayName)}</span>
                        <span class="sidebar-toggle">${getIcon('expandMore', 16)}</span>
                    </div>
                    <div class="sidebar-content" id="${escapeHtml(dir.name)}-list">
                        <div class="loading-state">Loading...</div>
                    </div>
                </div>
            `;
        }
        container.innerHTML = html;

        // Initialize collapse functionality for new sections
        initSidebarCollapseForContainer(container);

        // Load each section's content
        for (const dir of discoveredDirectories) {
            await loadSidebarSection(dir.name, dir.shortType, `#${dir.name}-list`);
        }

    } catch (error) {
        console.error('Failed to load sidebar directories:', error);
        container.innerHTML = '<div class="error-state">Error loading directories</div>';
    }
}

/**
 * Load content for a sidebar section
 * @param {string} type - Section type
 * @param {string} shortType - Short type identifier
 * @param {string} selector - CSS selector for container
 */
async function loadSidebarSection(type, shortType, selector) {
    const container = document.querySelector(selector);
    if (!container) return;

    // Show loading state
    container.innerHTML = '<div class="loading-state">Loading...</div>';

    try {
        const response = await fetch(`${API_BASE}/api/${type}/list`);
        if (!response.ok) throw new Error(`Failed to fetch ${type}`);

        const data = await response.json();
        const groups = data.groups || [];
        const items = data.items || []; // Fallback for old format

        // Handle new grouped format
        if (groups.length > 0) {
            renderGroupedItems(container, groups, type, shortType);
        }
        // Fallback to old flat format
        else if (items.length > 0) {
            renderFlatItems(container, items, type, shortType);
        } else {
            container.innerHTML = '<div class="empty-state">(empty)</div>';
        }

    } catch (error) {
        console.error(`Error loading ${type}:`, error);
        container.innerHTML = '<div class="empty-state">Error loading items</div>';
    }
}

/**
 * Render grouped sidebar items
 * @param {HTMLElement} container - Container element
 * @param {Array} groups - Grouped items
 * @param {string} type - Item type
 * @param {string} shortType - Short type identifier
 */
function renderGroupedItems(container, groups, type, shortType) {
    // Use provided shortType, or derive from type name
    shortType = shortType || type.substring(0, 3);
    const iconLetter = shortType.charAt(0).toUpperCase();

    let html = '';

    groups.forEach(group => {
        const folderName = group.folder || '(root)';
        const isRoot = !group.folder;

        if (!isRoot) {
            // Create collapsible folder group
            html += `
                <div class="sidebar-folder">
                    <div class="folder-header" data-folder="${escapeHtml(folderName)}">
                        <span class="folder-toggle">${getIcon('expandMore', 14)}</span>
                        <span class="folder-name">${escapeHtml(folderName)}</span>
                        <span class="folder-count">${group.items.length}</span>
                    </div>
                    <div class="folder-items">`;
        }

        // Add items
        group.items.forEach(item => {
            html += `
                <div class="sidebar-item ${!isRoot ? 'indented' : ''}" data-type="${shortType}" data-file="${escapeHtml(item.filename)}">
                    <span class="item-icon ${shortType}">${iconLetter}</span>
                    <span class="item-name">${escapeHtml(item.name)}</span>
                </div>`;
        });

        if (!isRoot) {
            html += `
                    </div>
                </div>`;
        }
    });

    container.innerHTML = html;

    // Add click handlers for items
    container.querySelectorAll('.sidebar-item').forEach(item => {
        item.addEventListener('click', (e) => {
            e.stopPropagation();
            const fileType = item.dataset.type;
            const fileName = item.dataset.file;
            if (fileType && fileName) {
                showWorkflowItem(fileType, fileName);
            }
        });
    });

    // Add click handlers for folder toggles
    container.querySelectorAll('.folder-header').forEach(header => {
        header.addEventListener('click', (e) => {
            e.stopPropagation();
            const folder = header.closest('.sidebar-folder');
            const isCollapsed = folder.classList.toggle('collapsed');
            const toggle = header.querySelector('.folder-toggle');
            toggle.innerHTML = getIcon(isCollapsed ? 'chevronRight' : 'expandMore', 14);
        });
    });
}

/**
 * Render flat sidebar items
 * @param {HTMLElement} container - Container element
 * @param {Array} items - Items to render
 * @param {string} type - Item type
 * @param {string} shortType - Short type identifier
 */
function renderFlatItems(container, items, type, shortType) {
    // Use provided shortType, or derive from type name
    shortType = shortType || type.substring(0, 3);
    const iconLetter = shortType.charAt(0).toUpperCase();

    container.innerHTML = items.map(item => `
        <div class="sidebar-item" data-type="${shortType}" data-file="${escapeHtml(item.filename)}">
            <span class="item-icon ${shortType}">${iconLetter}</span>
            <span class="item-name">${escapeHtml(item.name)}</span>
        </div>
    `).join('');

    // Add click handlers
    container.querySelectorAll('.sidebar-item').forEach(item => {
        item.addEventListener('click', (e) => {
            e.stopPropagation();
            const fileType = item.dataset.type;
            const fileName = item.dataset.file;
            if (fileType && fileName) {
                showWorkflowItem(fileType, fileName);
            }
        });
    });
}

/**
 * Initialize sidebar item click handlers
 */
function initSidebarItemClicks() {
    document.querySelectorAll('.sidebar-item').forEach(item => {
        item.addEventListener('click', (e) => {
            e.stopPropagation();
            const type = item.dataset.type;
            const file = item.dataset.file;
            if (type && file) {
                showWorkflowItem(type, file);
            }
        });
    });
}
