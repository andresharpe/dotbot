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

    // Start/stop process polling based on tab
    if (tabId === 'processes') {
        startProcessPolling();
    } else {
        stopProcessPolling();
    }

    // Update task summary when switching to pipeline tab
    if (tabId === 'pipeline' && lastState?.tasks) {
        updateTaskSummary(lastState.tasks);
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
 * Update task summary in pipeline context panel
 * @param {Object} tasks - Tasks object from state
 */
function updateTaskSummary(tasks) {
    // Update count badges in context panel
    setElementText('context-todo-count', tasks.todo || 0);
    setElementText('context-analysing-count', tasks.analysing || 0);
    setElementText('context-needs-input-count', tasks.needs_input || 0);
    setElementText('context-analysed-count', tasks.analysed || 0);
    setElementText('context-progress-count', tasks.in_progress || 0);
    setElementText('context-done-count', tasks.done || 0);
    setElementText('context-skipped-count', tasks.skipped || 0);
    setElementText('context-cancelled-count', tasks.cancelled || 0);

    // Update progress bar - include all statuses in total
    const total = (tasks.todo || 0) + (tasks.analysing || 0) + (tasks.needs_input || 0) +
                  (tasks.analysed || 0) + (tasks.in_progress || 0) + (tasks.done || 0);
    const percent = total > 0 ? Math.round((tasks.done / total) * 100) : 0;

    const progressBar = document.getElementById('context-progress-bar');
    const progressLabel = document.getElementById('context-progress-label');

    if (progressBar) progressBar.style.width = `${percent}%`;
    if (progressLabel) progressLabel.textContent = `${percent}%`;
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
