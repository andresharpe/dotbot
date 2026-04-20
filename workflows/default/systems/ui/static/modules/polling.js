/**
 * DOTBOT Control Panel - Polling
 * State polling and activity streaming
 */

/**
 * Start polling for state and activity
 */
function startPolling() {
    // Start interval-based polling for state (non-blocking)
    pollState();
    setInterval(pollState, POLL_INTERVAL);

    // Start activity polling
    pollActivity();
    activityTimer = setInterval(pollActivity, 2000);
}

let installedWorkflowPollCounter = 0;

/**
 * Poll server for current state
 */
async function pollState() {
    try {
        const response = await fetch(`${API_BASE}/api/state`);
        if (!response.ok) throw new Error(`HTTP ${response.status}`);

        const state = await response.json();
        lastPollTime = new Date();
        lastState = state;

        setConnectionStatus('connected');
        updateUI(state);

        // Aether ambient feedback
        if (typeof Aether !== 'undefined') {
            Aether.processState(state);
        }

        // Update Overview side panel every poll (no extra fetch — uses state already in hand)
        updateOverviewWorkflowPanel(state);

        // Update Workflow tab task progress every poll (from state, no extra fetch)
        updateWorkflowTabProgress(state);

        // Throttled: installed workflow controls (needs separate fetch)
        installedWorkflowPollCounter++;
        if (installedWorkflowPollCounter >= 5 || Object.keys(installedWorkflowMap).length === 0) {
            installedWorkflowPollCounter = 0;
            updateInstalledWorkflowControls();
        }

    } catch (error) {
        console.error('Poll error:', error);
        setConnectionStatus('error');
    }
}

/**
 * Fetch installed workflows and update control panel
 */
async function updateInstalledWorkflowControls() {
    try {
        const response = await fetch(`${API_BASE}/api/workflows/installed`);
        if (!response.ok) return;
        const data = await response.json();
        // Build a name→metadata map so all modules can look up per-workflow flags
        installedWorkflowMap = {};
        (data.workflows || []).forEach(wf => { installedWorkflowMap[wf.name] = wf; });
        if (typeof renderWorkflowControls === 'function') {
            renderWorkflowControls(data.workflows || []);
        }
        // Feed the Workflow tab's navigation tree
        if (typeof renderWorkflowDetailPanel === 'function') {
            renderWorkflowDetailPanel(data.workflows || []);
        }
        // Re-render executive summary so kickstart card grid picks up the updated map
        if (typeof updateExecutiveSummary === 'function') {
            updateExecutiveSummary();
        }
    } catch (error) {
        // Silently ignore — non-critical
    }
}

/**
 * Update Overview side panel from /api/state (no extra fetch needed)
 */
function updateOverviewWorkflowPanel(state) {
    try {
        if (state && typeof buildWorkflowPanelData === 'function') {
            const panelData = buildWorkflowPanelData(state);
            if (panelData && panelData.length > 0) {
                if (typeof renderOverviewKickstartPhases === 'function') {
                    renderOverviewKickstartPhases(panelData);
                }
            } else {
                const overviewSidePanel = document.getElementById('overview-side-panel');
                if (overviewSidePanel) overviewSidePanel.style.display = 'none';
            }
        }
    } catch (error) {
        // Silently ignore — non-critical
    }
}

/**
 * Update Workflow tab task progress from /api/state (no extra fetch needed).
 */
function updateWorkflowTabProgress(state) {
    try {
        if (state && typeof buildWorkflowPanelData === 'function' && typeof renderWorkflowTaskProgress === 'function') {
            const panelData = buildWorkflowPanelData(state);
            renderWorkflowTaskProgress(panelData || []);
        }
    } catch (error) {
        // Silently ignore — non-critical
    }
}

/**
 * Poll server for activity events
 */
async function pollActivity() {
    try {
        // On initial load, request only last 12 lines from server
        let url = `${API_BASE}/api/activity/tail?position=${activityPosition}`;
        if (!activityInitialized) {
            url += '&tail=12';
        }
        const response = await fetch(url);
        if (!response.ok) return;

        const data = await response.json();

        // Always update position
        if (data.position !== undefined) {
            activityPosition = data.position;
        }

        // Process events if any
        if (data.events && data.events.length > 0) {
            activityInitialized = true;

            // Find latest text, rate_limit, and command for display
            let latestText = null;
            let latestRateLimit = null;
            let latestCmd = null;

            for (const event of data.events) {
                const eventType = (event.type || '').toLowerCase();
                if (eventType === 'text') {
                    latestText = event;
                    latestRateLimit = null;  // Clear rate limit when new text comes
                } else if (eventType === 'rate_limit') {
                    latestRateLimit = event;
                } else {
                    latestCmd = event;
                }

                // Send to oscilloscope
                if (activityScope) {
                    const scopeEvent = mapEventToScope(event);
                    activityScope.addEvent(scopeEvent);
                }

                // Send to Aether for light effects
                if (typeof Aether !== 'undefined') {
                    Aether.processActivity(event);
                }
            }

            // Update displays with latest of each type
            // Rate limit takes precedence over text if it came after
            if (latestRateLimit) {
                updateTextDisplay(latestRateLimit, true);
            } else if (latestText) {
                updateTextDisplay(latestText, false);
            }
            if (latestCmd) {
                updateCommandDisplay(latestCmd);
            }
        }
    } catch (error) {
        console.error('Activity poll error:', error);
    }
}
