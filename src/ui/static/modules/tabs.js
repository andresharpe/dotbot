/**
 * DOTBOT Control Panel - Tab Navigation
 * Tab switching and context panel management
 */

/**
 * Initialize tab click handlers
 */
function initTabs() {
    const tabs = document.querySelectorAll('.tab');
    tabs.forEach(tab => {
        tab.addEventListener('click', () => {
            const targetId = tab.dataset.tab;
            switchToTab(targetId);
        });
    });
}

/**
 * Switch to specified tab
 * @param {string} targetId - Tab ID to switch to
 */
function switchToTab(targetId) {
    const tabs = document.querySelectorAll('.tab');
    tabs.forEach(t => t.classList.remove('active'));

    const targetTab = document.querySelector(`.tab[data-tab="${targetId}"]`);
    if (targetTab) targetTab.classList.add('active');

    document.querySelectorAll('.tab-pane').forEach(pane => {
        pane.classList.remove('active');
    });

    const targetPane = document.getElementById(`tab-${targetId}`);
    if (targetPane) targetPane.classList.add('active');

    // Keep the shell rail's active marker in sync (modules/shell.js)
    syncRailActive(targetId);

    // Switch context panel in left sidebar
    switchContextPanel(targetId);
}

/**
 * Switch context panel based on current tab
 * @param {string} tabId - Tab ID
 */
function switchContextPanel(tabId) {
    // Hide all context panels
    document.querySelectorAll('.context-panel').forEach(panel => {
        panel.classList.add('hidden');
    });

    // Show the context panel matching the tab
    const targetPanel = document.querySelector(`.context-panel[data-context="${tabId}"]`);
    if (targetPanel) {
        targetPanel.classList.remove('hidden');
    }

    // Tasks surface hosts the process list — poll while it's visible
    if (tabId === 'tasks') {
        startProcessPolling();
        if (lastState?.tasks) updateTasksSurface(lastState.tasks);
    } else {
        stopProcessPolling();
    }

    // Reload decisions when switching to decisions tab
    if (tabId === 'decisions') {
        reloadDecisions();
    }

    // Update product file nav when switching to product tab
    if (tabId === 'product') {
        updateProductFileNav();
    }

    // Fetch workflow data immediately on tab click (don't wait for poll cycle)
    if (tabId === 'workflow') {
        if (typeof updateInstalledWorkflowControls === 'function') {
            updateInstalledWorkflowControls();
        }
    }

    // Initialize theme selector when switching to settings tab
    if (tabId === 'settings') {
        initThemeSelector();
        initSettingsNav();
    }
}

/**
 * Initialize logo click to return to overview
 */
function initLogoClick() {
    const logo = document.querySelector('.logo');
    if (logo) {
        logo.style.cursor = 'pointer';
        logo.addEventListener('click', () => {
            switchToTab('overview');
        });
    }
}

/**
 * Initialize hamburger menu for mobile
 */
function initHamburgerMenu() {
    const hamburger = document.getElementById('hamburger-menu');
    const sidebar = document.querySelector('.sidebar-left');
    const overlay = document.getElementById('mobile-overlay');

    if (!hamburger || !sidebar || !overlay) return;

    const toggleMenu = () => {
        hamburger.classList.toggle('active');
        sidebar.classList.toggle('mobile-open');
        overlay.classList.toggle('active');
    };

    hamburger.addEventListener('click', toggleMenu);
    overlay.addEventListener('click', toggleMenu);
}
