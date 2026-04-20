/**
 * DOTBOT Control Panel v4
 * Main Entry Point - Initialization Orchestration
 *
 * All functionality is split into modules loaded via separate script tags.
 * This file handles initialization and cleanup only.
 */

// ========== INITIALIZATION ==========
document.addEventListener('DOMContentLoaded', async () => {
    if (typeof initNotificationAudio === 'function') {
        initNotificationAudio();
    }

    // Load theme first (affects all UI)
    await loadTheme();

    // Load icons
    await loadMaterialIcons();

    // Initialize activity scope (visual)
    initActivityScope();

    // Server-injected bootstrap (issue #269): /api/info + /api/product/list are
    // inlined into the page as window.__DOTBOT_BOOTSTRAP__ so first paint already
    // has the correct project name and workflow badge — no "autonomous" flash.
    // Scope is intentionally narrow: only the Overview executive-summary slot.
    // Left Control panel and right Workflow accordion paint via the normal poll
    // cycle (~3s). The fetch fallback preserves dev-mode / cached-HTML behavior.
    let bootstrap = (typeof window !== 'undefined' && window.__DOTBOT_BOOTSTRAP__) || null;
    if (!bootstrap) {
        const [info, productList] = await Promise.all([
            fetch(`${API_BASE}/api/info`).then(r => r.ok ? r.json() : null).catch(() => null),
            fetch(`${API_BASE}/api/product/list`).then(r => r.ok ? r.json() : null).catch(() => null)
        ]);
        bootstrap = { info, productList };
    }

    // Hydrate project info + kickstart state from the prefetched payload so the
    // executive-summary slot renders before the slow init steps below.
    await initProjectName(bootstrap.info);
    initProcesses();
    await initKickstart(bootstrap.info, bootstrap.productList);

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
    initRoadmapTaskActions();
    initSidebarItemClicks();
    await initProductNav();
    initModalClose();
    initPipelineInfiniteScroll();

    // Pipeline workflow filter
    document.getElementById('pipeline-workflow-filter')?.addEventListener('change', (e) => {
        pipelineWorkflowFilter = e.target.value || null;
        if (lastState?.tasks) updatePipelineView(lastState.tasks);
    });
    initActions();
    initNotifications();
    await initDecisions();

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
