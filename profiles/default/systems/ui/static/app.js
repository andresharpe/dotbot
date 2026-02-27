/**
 * DOTBOT Control Panel v4
 * Main Entry Point - Initialization Orchestration
 *
 * All functionality is split into modules loaded via separate script tags.
 * This file handles initialization and cleanup only.
 */

// ========== INITIALIZATION ==========
document.addEventListener('DOMContentLoaded', async () => {
    // Load theme first (affects all UI)
    await loadTheme();

    // Load icons
    await loadMaterialIcons();

    // Initialize activity scope (visual)
    initActivityScope();

    // Initialize project info
    await initProjectName();

    // Initialize editor button (header)
    initEditor();

    // Initialize UI components
    initTabs();
    initLogoClick();
    initHamburgerMenu();
    initSidebarCollapse();
    await initSidebar();
    initControlButtons();
    initSteeringPanel();
    initSettingsToggles();
    initTaskClicks();
    initSidebarItemClicks();
    await initProductNav();
    initModalClose();
    initPipelineInfiniteScroll();
    initActions();
    initProcesses();
    await initKickstart();
    initNotifications();

    // Initialize Aether (ambient feedback)
    Aether.init().then(result => {
        if (result.status === 'linked' || result.status === 'detected') {
            Aether.initSettingsPanel();
        }
    });

    // Start data flows
    startPolling();
    startRuntimeTimer();
});

// ========== CLEANUP ==========
window.addEventListener('beforeunload', () => {
    if (pollTimer) clearInterval(pollTimer);
    if (runtimeTimer) clearInterval(runtimeTimer);
    if (activityTimer) clearInterval(activityTimer);
    if (gitPollTimer) clearInterval(gitPollTimer);
    if (kickstartPolling) clearInterval(kickstartPolling);
    if (processPollingTimer) clearInterval(processPollingTimer);
});
