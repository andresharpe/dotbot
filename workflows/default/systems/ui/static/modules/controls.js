/**
 * DOTBOT Control Panel - Control Buttons
 * Control panel button handlers and settings management
 */

/**
 * Current loop mode ("analysis", "execution", or "both")
 */
let currentLoopMode = 'both';

/**
 * Dynamic model options fetched from provider config.
 * Populated by loadProviderData().
 */
let ANALYSIS_MODEL_OPTIONS = [];
let EXECUTION_MODEL_OPTIONS = [];

/**
 * Unfiltered model options (before permission mode exclusions).
 * Stored on first load so switching modes can restore full list.
 */
let UNFILTERED_MODEL_OPTIONS = null;

/**
 * Current provider data from /api/providers
 */
let providerData = null;

/**
 * In-flight workflow runs keyed by workflow name.
 * Used by runWorkflow() to guard against rapid double-clicks across all
 * call sites (control panel row, workflow grid, kickstart workflow list).
 */
const runWorkflowInFlight = new Set();

/**
 * Fetch provider data from the API and populate model options
 */
async function loadProviderData() {
    // Show loading state
    const providerLoading = document.getElementById('provider-loading');
    const providerGrid = document.getElementById('provider-grid');
    if (providerLoading) providerLoading.style.display = '';
    if (providerGrid) providerGrid.style.display = 'none';

    try {
        const response = await fetch(`${API_BASE}/api/providers`);
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        providerData = await response.json();

        // Use provider models for both analysis and execution grids
        ANALYSIS_MODEL_OPTIONS = (providerData.models || []).map(m => ({
            id: m.id || m.name,
            name: m.name,
            badge: m.badge || null,
            description: m.description || ''
        }));
        EXECUTION_MODEL_OPTIONS = ANALYSIS_MODEL_OPTIONS;

        // Store unfiltered model options
        UNFILTERED_MODEL_OPTIONS = {
            analysis: [...ANALYSIS_MODEL_OPTIONS],
            execution: [...EXECUTION_MODEL_OPTIONS]
        };

        // Hide loading, show grid
        if (providerLoading) providerLoading.style.display = 'none';
        if (providerGrid) providerGrid.style.display = '';

        // Re-render model grids with new data
        initAnalysisModelSelector();
        initExecutionModelSelector();

        // Render provider selector and permission mode selector
        initProviderSelector();
        initPermissionModeSelector();

        // Re-apply saved settings so model selections aren't lost by grid re-render
        loadSettings();
    } catch (error) {
        console.error('Failed to load provider data:', error);
        // Hide loading on error
        if (providerLoading) providerLoading.style.display = 'none';
        if (providerGrid) providerGrid.style.display = '';
        // Fallback to Claude defaults if API fails
        const fallback = [
            { id: 'Opus', name: 'Opus', badge: 'Recommended', description: 'Most capable model' },
            { id: 'Sonnet', name: 'Sonnet', badge: null, description: 'Balanced performance' },
            { id: 'Haiku', name: 'Haiku', badge: null, description: 'Lightweight and fast' }
        ];
        ANALYSIS_MODEL_OPTIONS = fallback;
        EXECUTION_MODEL_OPTIONS = fallback;
        initAnalysisModelSelector();
        initExecutionModelSelector();
        loadSettings();
    }
}

/**
 * Initialize provider selector UI
 */
function initProviderSelector() {
    const grid = document.getElementById('provider-grid');
    if (!grid || !providerData) return;

    grid.innerHTML = (providerData.providers || []).map(p => {
        let statusLine = '';
        if (!p.installed) {
            statusLine = '<div class="model-option-description" style="opacity:0.5">Not installed</div>';
        } else if (p.accessible === false) {
            const authHint = p.name === 'gemini' ? 'Set GEMINI_API_KEY for headless use' : 'Not authenticated';
            statusLine = `<div class="model-option-description" style="color:var(--color-primary-dim)">${authHint}</div>`;
        } else {
            const parts = [];
            if (p.version) parts.push(`v${p.version}`);
            if (p.plan_type) {
                const planLabel = p.plan_type.charAt(0).toUpperCase() + p.plan_type.slice(1);
                parts.push(`${planLabel} plan`);
            }
            if (parts.length) {
                statusLine = `<div class="model-option-description">${parts.join(' · ')}</div>`;
            }
        }
        return `
        <div class="model-option${p.name === providerData.active ? ' active' : ''}${!p.installed ? ' disabled' : ''}" data-provider="${p.name}">
            <div class="model-option-header">
                <span class="model-option-name">${p.display_name}</span>
            </div>
            ${statusLine}
        </div>`;
    }).join('');

    grid.querySelectorAll('.model-option:not(.disabled)').forEach(option => {
        option.addEventListener('click', async () => {
            const providerName = option.dataset.provider;
            if (providerName === providerData.active) return;

            // Save provider change
            try {
                const response = await fetch(`${API_BASE}/api/providers`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ provider: providerName })
                });
                if (!response.ok) throw new Error(`HTTP ${response.status}`);
                const result = await response.json();
                if (result.error) throw new Error(result.error);
                providerData = result;

                // Update models and re-render
                ANALYSIS_MODEL_OPTIONS = (providerData.models || []).map(m => ({
                    id: m.id || m.name,
                    name: m.name,
                    badge: m.badge || null,
                    description: m.description || ''
                }));
                EXECUTION_MODEL_OPTIONS = ANALYSIS_MODEL_OPTIONS;

                // Reset unfiltered model cache for new provider
                UNFILTERED_MODEL_OPTIONS = {
                    analysis: [...ANALYSIS_MODEL_OPTIONS],
                    execution: [...EXECUTION_MODEL_OPTIONS]
                };

                initProviderSelector();
                initAnalysisModelSelector();
                initExecutionModelSelector();

                // Reset permission mode to new provider's default
                initPermissionModeSelector();
                if (providerData.default_permission_mode) {
                    saveSetting('permissionMode', providerData.default_permission_mode);
                }

                // Select default model for new provider
                if (ANALYSIS_MODEL_OPTIONS.length > 0) {
                    selectAnalysisModel(ANALYSIS_MODEL_OPTIONS[0].id, true);
                    selectExecutionModel(ANALYSIS_MODEL_OPTIONS[0].id, true);
                }
            } catch (error) {
                console.error('Failed to change provider:', error);
            }
        });
    });
}

/**
 * Load settings from server and update UI
 */
async function loadSettings() {
    try {
        const response = await fetch(`${API_BASE}/api/settings`);
        const settings = await response.json();

        // Update toggle states
        const showDebugToggle = document.getElementById('setting-show-debug');
        const showVerboseToggle = document.getElementById('setting-show-verbose');

        if (showDebugToggle) {
            showDebugToggle.checked = settings.showDebug || false;
        }
        if (showVerboseToggle) {
            showVerboseToggle.checked = settings.showVerbose || false;
        }

        // Restore permission mode selection (before models, since it filters them)
        if (settings.permissionMode && providerData?.permission_modes?.[settings.permissionMode]) {
            selectPermissionMode(settings.permissionMode, false);
        }

        // Update model selection
        const savedAnalysisModel = settings.analysisModel || 'Opus';
        const savedExecutionModel = settings.executionModel || 'Opus';
        selectAnalysisModel(savedAnalysisModel, false);
        selectExecutionModel(savedExecutionModel, false);
    } catch (error) {
        console.error('Failed to load settings:', error);
    }
}

/**
 * Save a setting to the server
 * @param {string} key - Setting key
 * @param {any} value - Setting value
 */
async function saveSetting(key, value) {
    try {
        const body = {};
        body[key] = value;

        const response = await fetch(`${API_BASE}/api/settings`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        });

        const result = await response.json();
        if (!result.success) {
            console.error('Failed to save setting:', result.error);
        }
    } catch (error) {
        console.error('Failed to save setting:', error);
    }
}

/**
 * Initialize settings toggle handlers
 */
function initSettingsToggles() {
    const showDebugToggle = document.getElementById('setting-show-debug');
    const showVerboseToggle = document.getElementById('setting-show-verbose');

    if (showDebugToggle) {
        showDebugToggle.addEventListener('change', (e) => {
            saveSetting('showDebug', e.target.checked);
        });
    }

    if (showVerboseToggle) {
        showVerboseToggle.addEventListener('change', (e) => {
            saveSetting('showVerbose', e.target.checked);
        });
    }

    // Load provider data (populates model options dynamically)
    loadProviderData();

    // Initialize model selectors (will be re-rendered after provider data loads)
    initAnalysisModelSelector();
    initExecutionModelSelector();

    // Initialize analysis settings
    initAnalysisSettings();

    // Initialize verification settings
    initVerificationSettings();

    // Initialize cost settings
    initCostSettings();

    // Initialize mothership settings
    initMothershipSettings();

    // Load initial settings
    loadSettings();
}

/**
 * Initialize analysis model selector UI
 */
function initAnalysisModelSelector() {
    const modelGrid = document.getElementById('analysis-model-grid');
    if (!modelGrid) return;

    modelGrid.innerHTML = ANALYSIS_MODEL_OPTIONS.map(model => `
        <div class="model-option" data-model="${model.id}">
            <div class="model-option-header">
                <span class="model-option-name">${model.name}</span>
                ${model.badge ? `<span class="model-option-badge">${model.badge}</span>` : ''}
            </div>
            <div class="model-option-description">${model.description}</div>
        </div>
    `).join('');

    // Add click handlers
    modelGrid.querySelectorAll('.model-option').forEach(option => {
        option.addEventListener('click', () => {
            const modelId = option.dataset.model;
            selectAnalysisModel(modelId, true);
        });
    });
}

/**
 * Select analysis model and update UI
 * @param {string} modelId - Model ID to select
 * @param {boolean} save - Whether to save the setting
 */
function selectAnalysisModel(modelId, save = true) {
    const modelGrid = document.getElementById('analysis-model-grid');
    if (!modelGrid) return;

    // Update active state
    modelGrid.querySelectorAll('.model-option').forEach(option => {
        option.classList.toggle('active', option.dataset.model === modelId);
    });

    // Save setting
    if (save) {
        saveSetting('analysisModel', modelId);
    }
}

/**
 * Initialize execution model selector UI
 */
function initExecutionModelSelector() {
    const modelGrid = document.getElementById('execution-model-grid');
    if (!modelGrid) return;

    modelGrid.innerHTML = EXECUTION_MODEL_OPTIONS.map(model => `
        <div class="model-option" data-model="${model.id}">
            <div class="model-option-header">
                <span class="model-option-name">${model.name}</span>
                ${model.badge ? `<span class="model-option-badge">${model.badge}</span>` : ''}
            </div>
            <div class="model-option-description">${model.description}</div>
        </div>
    `).join('');

    // Add click handlers
    modelGrid.querySelectorAll('.model-option').forEach(option => {
        option.addEventListener('click', () => {
            const modelId = option.dataset.model;
            selectExecutionModel(modelId, true);
        });
    });
}

/**
 * Select execution model and update UI
 * @param {string} modelId - Model ID to select
 * @param {boolean} save - Whether to save the setting
 */
function selectExecutionModel(modelId, save = true) {
    const modelGrid = document.getElementById('execution-model-grid');
    if (!modelGrid) return;

    // Update active state
    modelGrid.querySelectorAll('.model-option').forEach(option => {
        option.classList.toggle('active', option.dataset.model === modelId);
    });

    // Save setting
    if (save) {
        saveSetting('executionModel', modelId);
    }
}

/**
 * Initialize permission mode selector UI
 */
function initPermissionModeSelector() {
    const section = document.getElementById('permission-mode-section');
    const grid = document.getElementById('permission-mode-grid');
    if (!grid || !providerData?.permission_modes) {
        if (section) section.style.display = 'none';
        return;
    }

    // Hide if active provider is not installed
    const activeProvider = (providerData.providers || []).find(p => p.name === providerData.active);
    if (activeProvider && !activeProvider.installed) {
        section.style.display = 'none';
        return;
    }

    section.style.display = '';
    const modes = providerData.permission_modes;
    const planType = activeProvider?.plan_type;

    // Compute effective mode — fall back to provider default if active mode is plan-restricted
    let activeMode = providerData.active_permission_mode || providerData.default_permission_mode;
    const activeModeConfig = modes[activeMode];
    if (activeModeConfig?.restrictions && planType && ['max', 'pro'].includes(planType)) {
        activeMode = providerData.default_permission_mode;
    }

    grid.innerHTML = Object.entries(modes).map(([key, mode]) => {
        // Determine if this mode is unavailable due to plan restrictions
        const planRestricted = mode.restrictions && planType && ['max', 'pro'].includes(planType);
        const disabledClass = planRestricted ? ' disabled' : '';
        const activeClass = (!planRestricted && key === activeMode) ? ' active' : '';

        let restrictionLine = '';
        if (planRestricted) {
            const planLabel = planType.charAt(0).toUpperCase() + planType.slice(1);
            restrictionLine = `<div class="model-option-description" style="color:var(--color-error);margin-top:4px;">Requires Team, Enterprise, or API plan</div>`;
        }

        return `
        <div class="model-option${activeClass}${disabledClass}" data-permission-mode="${key}">
            <div class="model-option-header">
                <span class="model-option-name">${mode.display_name}</span>
            </div>
            <div class="model-option-description">${mode.description}</div>
            ${restrictionLine}
        </div>`;
    }).join('');

    // Only add click handlers to non-disabled options
    grid.querySelectorAll('.model-option:not(.disabled)').forEach(option => {
        option.addEventListener('click', () => {
            const modeKey = option.dataset.permissionMode;
            selectPermissionMode(modeKey, true);
        });
    });

    updatePermissionModeNote(activeMode);
    filterModelsForPermissionMode(activeMode);
}

/**
 * Select a permission mode and update UI
 * @param {string} modeKey - Permission mode key
 * @param {boolean} save - Whether to save the setting
 */
function selectPermissionMode(modeKey, save = true) {
    const grid = document.getElementById('permission-mode-grid');
    if (!grid) return;

    grid.querySelectorAll('.model-option').forEach(option => {
        option.classList.toggle('active', option.dataset.permissionMode === modeKey);
    });

    updatePermissionModeNote(modeKey);
    filterModelsForPermissionMode(modeKey);

    if (save) {
        saveSetting('permissionMode', modeKey);
    }
}

/**
 * Filter model options based on permission mode restrictions
 * @param {string} modeKey - Permission mode key
 */
function filterModelsForPermissionMode(modeKey) {
    if (!providerData?.permission_modes?.[modeKey]) return;

    // Store unfiltered options on first call
    if (!UNFILTERED_MODEL_OPTIONS) {
        UNFILTERED_MODEL_OPTIONS = {
            analysis: [...ANALYSIS_MODEL_OPTIONS],
            execution: [...EXECUTION_MODEL_OPTIONS]
        };
    }

    // Capture current selections before re-render
    const analysisGrid = document.getElementById('analysis-model-grid');
    const executionGrid = document.getElementById('execution-model-grid');
    const currentAnalysis = analysisGrid?.querySelector('.model-option.active')?.dataset?.model;
    const currentExecution = executionGrid?.querySelector('.model-option.active')?.dataset?.model;

    const excluded = providerData.permission_modes[modeKey].restrictions?.excluded_models || [];

    if (excluded.length > 0) {
        ANALYSIS_MODEL_OPTIONS = UNFILTERED_MODEL_OPTIONS.analysis.filter(m => !excluded.includes(m.id));
        EXECUTION_MODEL_OPTIONS = UNFILTERED_MODEL_OPTIONS.execution.filter(m => !excluded.includes(m.id));
    } else {
        ANALYSIS_MODEL_OPTIONS = [...UNFILTERED_MODEL_OPTIONS.analysis];
        EXECUTION_MODEL_OPTIONS = [...UNFILTERED_MODEL_OPTIONS.execution];
    }

    initAnalysisModelSelector();
    initExecutionModelSelector();

    // Re-apply selections, falling back to first available if excluded
    const analysisModel = (currentAnalysis && !excluded.includes(currentAnalysis)) ? currentAnalysis : ANALYSIS_MODEL_OPTIONS[0]?.id;
    const executionModel = (currentExecution && !excluded.includes(currentExecution)) ? currentExecution : EXECUTION_MODEL_OPTIONS[0]?.id;
    if (analysisModel) selectAnalysisModel(analysisModel, excluded.includes(currentAnalysis));
    if (executionModel) selectExecutionModel(executionModel, excluded.includes(currentExecution));
}

/**
 * Update the permission mode note with contextual guidance
 * @param {string} modeKey - Permission mode key
 */
function updatePermissionModeNote(modeKey) {
    const note = document.getElementById('permission-mode-note');
    if (!note) return;

    const activeProvider = (providerData?.providers || []).find(p => p.name === providerData?.active);
    const planType = activeProvider?.plan_type;

    // Check if any mode has plan restrictions that apply
    const hasRestrictedModes = planType && ['max', 'pro'].includes(planType) &&
        Object.values(providerData?.permission_modes || {}).some(m => m.restrictions);

    if (hasRestrictedModes) {
        const planLabel = planType.charAt(0).toUpperCase() + planType.slice(1);
        note.style.display = '';
        note.className = 'settings-note primary';
        note.innerHTML = `Some permission modes require a Team, Enterprise, or API plan. Your current plan: <strong>${planLabel}</strong>.`;
        return;
    }

    // Show accessibility warning
    if (activeProvider && activeProvider.installed && activeProvider.accessible === false) {
        note.style.display = '';
        note.className = 'settings-note';
        note.textContent = 'Coding agent is installed but not authenticated. Permission mode will apply once authenticated.';
        return;
    }

    note.style.display = 'none';
}

/**
 * Initialize control button click handlers
 */
function initControlButtons() {
    const controls = document.getElementById('controls');
    if (!controls) return;

    controls.addEventListener('click', async (e) => {
        const btn = e.target.closest('.ctrl-btn, .ctrl-btn-xs');
        if (!btn || btn.disabled) return;

        const action = btn.dataset.action;
        if (!action) return;

        switch (action) {
            case 'start-workflow':
                await launchWorkflow();
                break;
            case 'stop-workflow':
                await stopProcessesByType('task-runner');
                break;
            case 'kill-workflow':
                await killProcessesByType('task-runner');
                break;
            // Legacy actions kept for backward compat
            case 'start-analysis':
                await launchProcessFromOverview('analysis');
                break;
            case 'start-execution':
                await launchProcessFromOverview('execution');
                break;
            case 'start-both':
                await launchBoth();
                break;
            case 'stop-analysis':
                await stopProcessesByType('analysis');
                break;
            case 'stop-execution':
                await stopProcessesByType('execution');
                break;
            case 'stop-all':
                await stopAllProcesses();
                break;
            case 'kill-analysis':
                await killProcessesByType('analysis');
                break;
            case 'kill-execution':
                await killProcessesByType('execution');
                break;
            case 'kill-all':
                await killAllProcesses();
                break;
            default:
                await sendControlSignal(action);
        }
    });

    // Panic reset button handler
    const panicBtn = document.getElementById('panic-reset');
    if (panicBtn) {
        panicBtn.addEventListener('click', async () => {
            if (panicBtn.disabled) return;
            await sendControlSignal('reset');
        });
    }
}

/**
 * Current loop mode (kept for backward compat with sendControlSignal)
 */
function getLoopMode() {
    return currentLoopMode;
}

/**
 * Launch a process from the Overview quick launch buttons
 * @param {string} type - Process type ("analysis" or "execution")
 */
async function launchProcessFromOverview(type) {
    const signalStatus = document.getElementById('signal-status');

    try {
        const response = await fetch(`${API_BASE}/api/process/launch`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ type, continue: true })
        });

        const data = await response.json();

        if (data.success) {
            showSignalFeedback(`Launched ${type}: ${data.process_id}`);
            showToast(`${type} process launched`, 'success');
        } else {
            showSignalFeedback(`Error: ${data.error || 'Launch failed'}`);
        }

        await pollState();

    } catch (error) {
        console.error('Launch error:', error);
        showSignalFeedback(`Error: ${error.message}`);
    }
}

// ========== PER-WORKFLOW CONTROLS ==========

/**
 * Render per-workflow control rows from installed workflows data.
 * The generic workflow control row is hidden; per-workflow controls replace it.
 * @param {Array} workflows - Array of workflow objects from /api/workflows/installed
 */
function renderWorkflowControls(workflows) {
    const container = document.getElementById('workflow-controls-container');
    if (!container) return;

    if (!workflows || workflows.length === 0) {
        container.innerHTML = '';
        return;
    }

    container.innerHTML = workflows.map(wf => {
        const isRunning = wf.has_running_process || wf.status === 'running';
        const ledClass = isRunning ? 'led pulse' : 'led off';
        const displayName = escapeHtml(wf.name);
        const desc = wf.description ? escapeHtml(wf.description.substring(0, 60)) : '';
        return `
            <div class="process-control-row">
                <div class="process-control-header">
                    <span class="${ledClass} wf-led"></span>
                    <span class="process-control-label" title="${desc}">${displayName}</span>
                </div>
                <div class="process-control-actions">
                    <button class="ctrl-btn-xs primary wf-run-btn" title="Create tasks and start workflow" ${isRunning ? 'disabled' : ''}>Run</button>
                    <button class="ctrl-btn-xs wf-stop-btn" title="Stop workflow: ${displayName}" ${!isRunning ? 'disabled' : ''}>Stop</button>
                </div>
            </div>
        `;
    }).join('');

    // Bind workflow metadata and event handlers using raw workflow names
    const rows = container.querySelectorAll('.process-control-row');
    rows.forEach((row, index) => {
        const wf = workflows[index];
        if (!wf) return;
        row.dataset.workflow = wf.name;
        const led = row.querySelector('.wf-led');
        if (led) led.id = `wf-led-${wf.name}`;
        const runBtn = row.querySelector('.wf-run-btn');
        if (runBtn) runBtn.addEventListener('click', () => runWorkflow(wf.name, wf.has_form, runBtn));
        const stopBtn = row.querySelector('.wf-stop-btn');
        if (stopBtn) stopBtn.addEventListener('click', () => stopWorkflow(wf.name));
    });
}

/**
 * Run a named workflow via API
 * If the workflow has a form (show_interview/show_files), open the kickstart modal instead.
 * @param {string} name - Workflow name
 * @param {boolean} hasForm - Whether the workflow defines a form requiring user input
 * @param {HTMLElement} [runBtn] - The Run button element; disabled during the call to guard against rapid double-clicks.
 */
async function runWorkflow(name, hasForm, runBtn) {
    // Guard against rapid double-clicks by tracking in-flight runs by workflow
    // name. This covers all call sites (control panel row, workflow grid,
    // kickstart workflow list) regardless of whether the caller passes a
    // button reference.
    if (runWorkflowInFlight.has(name)) return;
    runWorkflowInFlight.add(name);
    if (runBtn) runBtn.disabled = true;

    // If workflow has a form, open the kickstart modal so the user can provide
    // project context and upload files before tasks are created.
    // The modal submission routes to the task-runner engine (not kickstart).
    if (hasForm) {
        try {
            if (typeof openKickstartModal === 'function') {
                await openKickstartModal(name, { useTaskRunner: true });
            } else {
                console.warn('Workflow requires a form but kickstart modal is not available');
                showToast('Kickstart modal is not available', 'warning');
            }
        } finally {
            // Release the in-flight guard and re-enable the button once the
            // modal is open. The modal has its own kickstartSubmitting guard
            // from here on.
            runWorkflowInFlight.delete(name);
            if (runBtn) runBtn.disabled = false;
        }
        return;
    }

    try {
        const response = await fetch(`${API_BASE}/api/workflows/${encodeURIComponent(name)}/run`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({})
        });
        const data = await response.json();
        if (data.success) {
            showSignalFeedback(`Launched workflow: ${name} (${data.tasks_created} tasks)`);
            showToast(`Workflow "${name}" started`, 'success');
        } else {
            showSignalFeedback(`Error: ${data.error || 'Run failed'}`);
        }
        await pollState();
    } catch (error) {
        console.error('Run workflow error:', error);
        showSignalFeedback(`Error: ${error.message}`);
    } finally {
        runWorkflowInFlight.delete(name);
        if (runBtn) runBtn.disabled = false;
    }
}

/**
 * Stop a named workflow via API
 * @param {string} name - Workflow name
 */
async function stopWorkflow(name) {
    try {
        const response = await fetch(`${API_BASE}/api/workflows/${encodeURIComponent(name)}/stop`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({})
        });
        const data = await response.json();
        if (data.success) {
            showSignalFeedback(`Stop signal sent to workflow: ${name}`);
            showToast(`Workflow "${name}" stop signal sent`, 'success');
        } else {
            showSignalFeedback(`Error: ${data.error || 'Stop failed'}`);
        }
        await pollState();
    } catch (error) {
        console.error('Stop workflow error:', error);
        showSignalFeedback(`Error: ${error.message}`);
    }
}

/**
 * Launch the visual studio for a specific workflow.
 * POSTs to /api/launch-studio which starts the studio server if needed,
 * then opens the studio URL in a new tab with the workflow pre-selected.
 * @param {string} workflowName - Workflow name to open in the studio
 */
async function launchStudio(workflowName) {
    try {
        const response = await fetch(`${API_BASE}/api/launch-studio`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ workflow: workflowName })
        });
        const data = await response.json();
        if (data.success && data.url) {
            window.open(data.url, '_blank');
        } else {
            showToast(data.error || 'Failed to launch studio', 'warning');
        }
    } catch (error) {
        console.error('Launch studio error:', error);
        showToast(`Studio launch failed: ${error.message}`, 'warning');
    }
}

/**
 * Update per-workflow LED states from polling state
 * @param {Object} workflowsState - workflows object from state (keyed by name)
 */
function updateWorkflowControlStates(workflowsState) {
    if (!workflowsState) return;
    const container = document.getElementById('workflow-controls-container');
    if (!container) return;

    container.querySelectorAll('.process-control-row[data-workflow]').forEach(row => {
        const name = row.dataset.workflow;
        const wfState = workflowsState[name];
        const led = row.querySelector('.led');
        const runBtn = row.querySelector('.ctrl-btn-xs.primary');
        const stopBtn = row.querySelector('.ctrl-btn-xs:not(.primary)');
        const isAlive = wfState?.process_alive || false;

        if (led) led.className = isAlive ? 'led pulse' : 'led off';
        if (runBtn) runBtn.disabled = isAlive;
        if (stopBtn) stopBtn.disabled = !isAlive;
    });
}

/**
 * Launch a unified workflow process (analyse then execute per task)
 */
async function launchWorkflow() {
    try {
        const response = await fetch(`${API_BASE}/api/process/launch`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ type: 'task-runner', continue: true })
        });

        const data = await response.json();

        if (data.success) {
            showSignalFeedback(`Launched workflow: ${data.process_id}`);
            showToast('Workflow process launched', 'success');
        } else {
            showSignalFeedback(`Error: ${data.error || 'Launch failed'}`);
        }

        await pollState();

    } catch (error) {
        console.error('Launch workflow error:', error);
        showSignalFeedback(`Error: ${error.message}`);
    }
}

/**
 * Stop all running processes
 */
async function stopAllProcesses() {
    try {
        const response = await fetch(`${API_BASE}/api/control`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ action: 'stop' })
        });

        const result = await response.json();
        showSignalFeedback('Stop signal sent to all processes');
        await pollState();

    } catch (error) {
        console.error('Stop all error:', error);
        showSignalFeedback(`Error: ${error.message}`);
    }
}

/**
 * Launch both analysis and execution processes
 */
async function launchBoth() {
    try {
        const [analysisRes, executionRes] = await Promise.all([
            fetch(`${API_BASE}/api/process/launch`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ type: 'analysis', continue: true })
            }),
            fetch(`${API_BASE}/api/process/launch`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ type: 'execution', continue: true })
            })
        ]);

        const analysisData = await analysisRes.json();
        const executionData = await executionRes.json();

        const launched = [];
        if (analysisData.success) launched.push('analysis');
        if (executionData.success) launched.push('execution');

        if (launched.length > 0) {
            showSignalFeedback(`Launched: ${launched.join(', ')}`);
            showToast(`${launched.length} process(es) launched`, 'success');
        } else {
            showSignalFeedback('Launch failed');
        }

        await pollState();

    } catch (error) {
        console.error('Launch both error:', error);
        showSignalFeedback(`Error: ${error.message}`);
    }
}

/**
 * Gracefully stop processes by type
 * @param {string} type - Process type ("analysis" or "execution")
 */
async function stopProcessesByType(type) {
    try {
        const response = await fetch(`${API_BASE}/api/process/stop-by-type`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ type })
        });

        const data = await response.json();
        if (data.success) {
            showSignalFeedback(`Stop signal sent to ${data.count} ${type} process(es)`);
            showToast(`${type} stop signal sent`, 'success');
        } else {
            showSignalFeedback(`Error: ${data.error || 'Stop failed'}`);
        }

        await pollState();

    } catch (error) {
        console.error('Stop by type error:', error);
        showSignalFeedback(`Error: ${error.message}`);
    }
}

/**
 * Kill processes by type (immediate termination via PID)
 * @param {string} type - Process type ("analysis" or "execution")
 */
async function killProcessesByType(type) {
    if (!confirm(`Kill all ${type} processes immediately? This will terminate them without finishing their current task.`)) {
        return;
    }

    try {
        const response = await fetch(`${API_BASE}/api/process/kill-by-type`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ type })
        });

        const data = await response.json();
        if (data.success) {
            showSignalFeedback(`Killed ${data.count} ${type} process(es)`);
            showToast(`${type} process(es) killed`, 'warning');
        } else {
            showSignalFeedback(`Error: ${data.error || 'Kill failed'}`);
        }

        await pollState();

    } catch (error) {
        console.error('Kill by type error:', error);
        showSignalFeedback(`Error: ${error.message}`);
    }
}

/**
 * Kill all running processes immediately
 */
async function killAllProcesses() {
    if (!confirm('Kill ALL running processes immediately? This will terminate them without finishing their current task.')) {
        return;
    }

    try {
        const response = await fetch(`${API_BASE}/api/process/kill-all`, {
            method: 'POST'
        });

        const data = await response.json();
        if (data.success) {
            showSignalFeedback(`Killed ${data.count} process(es)`);
            showToast(`All processes killed (${data.count})`, 'warning');
        } else {
            showSignalFeedback(`Error: ${data.error || 'Kill failed'}`);
        }

        await pollState();

    } catch (error) {
        console.error('Kill all error:', error);
        showSignalFeedback(`Error: ${error.message}`);
    }
}

/**
 * Send control signal to the server (legacy, used by reset)
 * @param {string} action - Action to send (reset)
 */
async function sendControlSignal(action) {
    const signalStatus = document.getElementById('signal-status');

    try {
        const buttons = document.querySelectorAll('.ctrl-btn, .panic-btn');
        buttons.forEach(btn => btn.disabled = true);

        const body = { action };

        const response = await fetch(`${API_BASE}/api/control`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        });

        const result = await response.json();

        if (signalStatus) {
            signalStatus.textContent = `Signal sent: ${action.toUpperCase()}`;
            signalStatus.classList.add('visible');
            setTimeout(() => signalStatus.classList.remove('visible'), 3000);
        }

        await pollState();

    } catch (error) {
        console.error('Control signal error:', error);
        if (signalStatus) {
            signalStatus.textContent = `Error: ${error.message}`;
            signalStatus.classList.add('visible');
        }
    } finally {
        const panicBtn = document.querySelector('.panic-btn');
        if (panicBtn) panicBtn.disabled = false;
    }
}

// ========== ANALYSIS SETTINGS ==========

const EFFORT_OPTIONS = [
    { id: 'XS', name: 'XS', description: '~1 day' },
    { id: 'S', name: 'S', description: '2-3 days' },
    { id: 'M', name: 'M', description: '~1 week' },
    { id: 'L', name: 'L', description: '~2 weeks' },
    { id: 'XL', name: 'XL', description: '3+ weeks' }
];

const ANALYSIS_MODE_OPTIONS = [
    { id: 'on-demand', name: 'On-Demand', badge: 'Recommended', description: 'Analyse tasks when triggered by the execution loop' },
    { id: 'batch', name: 'Batch', badge: null, description: 'Analyse all pending tasks in a single batch run' }
];

/**
 * Load analysis settings from server
 */
async function loadAnalysisSettings() {
    try {
        const response = await fetch(`${API_BASE}/api/config/analysis`);
        const data = await response.json();

        // Auto-approve toggle
        const toggle = document.getElementById('setting-auto-approve-splits');
        if (toggle) toggle.checked = data.auto_approve_splits || false;

        // Effort threshold
        selectEffortThreshold(data.split_threshold_effort || 'XL', false);

        // Mode
        selectAnalysisMode(data.mode || 'on-demand', false);

        // Timeout
        const timeoutInput = document.getElementById('setting-question-timeout');
        if (timeoutInput) {
            timeoutInput.value = data.question_timeout_hours != null ? data.question_timeout_hours : '';
        }
    } catch (error) {
        console.error('Failed to load analysis settings:', error);
    }
}

/**
 * Save a single analysis setting
 */
async function saveAnalysisSetting(key, value) {
    try {
        const body = {};
        body[key] = value;
        const response = await fetch(`${API_BASE}/api/config/analysis`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        });
        const result = await response.json();
        if (!result.success) {
            console.error('Failed to save analysis setting:', result.error);
        }
    } catch (error) {
        console.error('Failed to save analysis setting:', error);
    }
}

/**
 * Initialize effort threshold selector
 */
function initEffortThresholdSelector() {
    const grid = document.getElementById('effort-threshold-grid');
    if (!grid) return;

    grid.innerHTML = EFFORT_OPTIONS.map(opt => `
        <div class="model-option" data-effort="${opt.id}">
            <div class="model-option-header">
                <span class="model-option-name">${opt.name}</span>
            </div>
            <div class="model-option-description">${opt.description}</div>
        </div>
    `).join('');

    grid.querySelectorAll('.model-option').forEach(option => {
        option.addEventListener('click', () => {
            selectEffortThreshold(option.dataset.effort, true);
        });
    });
}

/**
 * Select effort threshold and update UI
 */
function selectEffortThreshold(id, save = true) {
    const grid = document.getElementById('effort-threshold-grid');
    if (!grid) return;

    grid.querySelectorAll('.model-option').forEach(option => {
        option.classList.toggle('active', option.dataset.effort === id);
    });

    if (save) {
        saveAnalysisSetting('split_threshold_effort', id);
    }
}

/**
 * Initialize analysis mode selector
 */
function initAnalysisModeSelector() {
    const grid = document.getElementById('analysis-mode-grid');
    if (!grid) return;

    grid.innerHTML = ANALYSIS_MODE_OPTIONS.map(opt => `
        <div class="model-option" data-mode="${opt.id}">
            <div class="model-option-header">
                <span class="model-option-name">${opt.name}</span>
                ${opt.badge ? `<span class="model-option-badge">${opt.badge}</span>` : ''}
            </div>
            <div class="model-option-description">${opt.description}</div>
        </div>
    `).join('');

    grid.querySelectorAll('.model-option').forEach(option => {
        option.addEventListener('click', () => {
            selectAnalysisMode(option.dataset.mode, true);
        });
    });
}

/**
 * Select analysis mode and update UI
 */
function selectAnalysisMode(id, save = true) {
    const grid = document.getElementById('analysis-mode-grid');
    if (!grid) return;

    grid.querySelectorAll('.model-option').forEach(option => {
        option.classList.toggle('active', option.dataset.mode === id);
    });

    if (save) {
        saveAnalysisSetting('mode', id);
    }
}

/**
 * Initialize all analysis settings
 */
function initAnalysisSettings() {
    // Auto-approve toggle
    const toggle = document.getElementById('setting-auto-approve-splits');
    if (toggle) {
        toggle.addEventListener('change', (e) => {
            saveAnalysisSetting('auto_approve_splits', e.target.checked);
        });
    }

    // Question timeout input (debounced)
    const timeoutInput = document.getElementById('setting-question-timeout');
    if (timeoutInput) {
        let debounceTimer = null;
        timeoutInput.addEventListener('input', () => {
            // Clamp to non-negative
            if (timeoutInput.value !== '' && parseInt(timeoutInput.value, 10) < 0) {
                timeoutInput.value = 0;
            }
            clearTimeout(debounceTimer);
            debounceTimer = setTimeout(() => {
                const val = timeoutInput.value.trim();
                const parsed = parseInt(val, 10);
                saveAnalysisSetting('question_timeout_hours', val === '' ? null : Math.max(0, parsed));
            }, 500);
        });
    }

    // Grid selectors
    initEffortThresholdSelector();
    initAnalysisModeSelector();

    // Load current values
    loadAnalysisSettings();
}

// ========== VERIFICATION SETTINGS ==========

/**
 * Load verification scripts from server
 */
async function loadVerificationScripts() {
    try {
        const response = await fetch(`${API_BASE}/api/config/verification`);
        const data = await response.json();
        renderVerificationScripts(data.scripts || []);
    } catch (error) {
        console.error('Failed to load verification scripts:', error);
    }
}

/**
 * Render verification scripts list
 */
function renderVerificationScripts(scripts) {
    const container = document.getElementById('verification-scripts-list');
    if (!container) return;

    if (!scripts.length) {
        container.innerHTML = '<div class="empty-state">No verification scripts configured</div>';
        return;
    }

    container.innerHTML = scripts.map(script => {
        const isCore = script.core === true;
        return `
            <div class="verify-script-row${isCore ? ' verify-core' : ''}">
                <div class="verify-script-info">
                    <div class="verify-script-header">
                        <span class="verify-script-name">${script.name}</span>
                        ${isCore ? '<span class="verify-core-badge">CORE</span>' : ''}
                    </div>
                    <span class="verify-script-desc">${script.description || ''}</span>
                </div>
                <div class="verify-script-controls">
                    <span class="verify-timeout">${script.timeout_seconds}s</span>
                    <label class="toggle-switch${isCore ? ' toggle-disabled' : ''}">
                        <input type="checkbox" ${script.required ? 'checked' : ''} ${isCore ? 'disabled' : ''}
                            data-script-name="${script.name}">
                        <span class="toggle-slider"></span>
                    </label>
                </div>
            </div>
        `;
    }).join('');

    // Wire change handlers for non-core scripts
    container.querySelectorAll('input[data-script-name]:not([disabled])').forEach(input => {
        input.addEventListener('change', async (e) => {
            await saveVerificationSetting(e.target.dataset.scriptName, e.target.checked);
        });
    });
}

/**
 * Save a verification script setting
 */
async function saveVerificationSetting(name, required) {
    try {
        const response = await fetch(`${API_BASE}/api/config/verification`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name, required })
        });
        const result = await response.json();
        if (!result.success) {
            console.error('Failed to save verification setting:', result.error);
            // Reload to revert UI state
            loadVerificationScripts();
        }
    } catch (error) {
        console.error('Failed to save verification setting:', error);
        loadVerificationScripts();
    }
}

/**
 * Initialize verification settings
 */
function initVerificationSettings() {
    loadVerificationScripts();
}

// ========== COST SETTINGS ==========

/**
 * Load cost settings from server
 */
async function loadCostSettings() {
    try {
        const response = await fetch(`${API_BASE}/api/config/costs`);
        const data = await response.json();

        const rateInput = document.getElementById('setting-hourly-rate');
        const aiCostInput = document.getElementById('setting-ai-cost-per-task');
        const factorInput = document.getElementById('setting-ai-speedup-factor');
        const currencyInput = document.getElementById('setting-currency');

        if (rateInput) rateInput.value = data.hourly_rate ?? 50;
        if (aiCostInput) aiCostInput.value = data.ai_cost_per_task ?? 0.50;
        if (factorInput) factorInput.value = data.ai_speedup_factor ?? 10;
        if (currencyInput) currencyInput.value = data.currency ?? 'USD';
    } catch (error) {
        console.error('Failed to load cost settings:', error);
    }
}

/**
 * Save a single cost setting
 */
async function saveCostSetting(key, value) {
    try {
        const body = {};
        body[key] = value;
        const response = await fetch(`${API_BASE}/api/config/costs`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        });
        const result = await response.json();
        if (!result.success) {
            console.error('Failed to save cost setting:', result.error);
        }
    } catch (error) {
        console.error('Failed to save cost setting:', error);
    }
}

/**
 * Initialize cost settings handlers
 */
function initCostSettings() {
    const inputs = [
        { id: 'setting-hourly-rate', key: 'hourly_rate', parse: v => parseFloat(v) || 0 },
        { id: 'setting-ai-cost-per-task', key: 'ai_cost_per_task', parse: v => parseFloat(v) || 0 },
        { id: 'setting-ai-speedup-factor', key: 'ai_speedup_factor', parse: v => Math.max(1, parseFloat(v) || 1) },
        { id: 'setting-currency', key: 'currency', parse: v => v.trim() || 'USD' }
    ];

    inputs.forEach(({ id, key, parse }) => {
        const input = document.getElementById(id);
        if (!input) return;
        let debounceTimer = null;
        input.addEventListener('input', () => {
            clearTimeout(debounceTimer);
            debounceTimer = setTimeout(() => {
                saveCostSetting(key, parse(input.value));
            }, 500);
        });
    });

    loadCostSettings();
}

// ========== MOTHERSHIP SETTINGS ==========

/**
 * Load mothership settings from server and update health indicator
 */
async function loadMothershipSettings() {
    try {
        const response = await fetch(`${API_BASE}/api/config/mothership`);
        if (!response.ok) return;
        const data = await response.json();

        const el = (id) => document.getElementById(id);

        const enabledToggle = el('notif-enabled');
        if (enabledToggle) enabledToggle.checked = !!data.enabled;

        const soundEnabledToggle = el('notif-sound-enabled');
        if (soundEnabledToggle) soundEnabledToggle.checked = !!data.sound_enabled;
        if (typeof setNotificationSoundEnabled === 'function') {
            setNotificationSoundEnabled(!!data.sound_enabled);
        }

        const serverUrl = el('notif-server-url');
        if (serverUrl) serverUrl.value = data.server_url || '';

        const apiKey = el('notif-api-key');
        if (apiKey) apiKey.placeholder = data.api_key_set ? 'Key is set (enter new to change)' : 'Enter API key';

        const channel = el('notif-channel');
        if (channel) channel.value = data.channel || 'teams';

        const recipients = el('notif-recipients');
        if (recipients) recipients.value = (data.recipients || []).join(', ');

        const projectName = el('notif-project-name');
        if (projectName) projectName.value = data.project_name || '';

        const projectDesc = el('notif-project-desc');
        if (projectDesc) projectDesc.value = data.project_description || '';

        const pollInterval = el('notif-poll-interval');
        if (pollInterval) pollInterval.value = data.poll_interval_seconds || 30;

        const syncTasks = el('ms-sync-tasks');
        if (syncTasks) syncTasks.checked = data.sync_tasks !== false;

        const syncQuestions = el('ms-sync-questions');
        if (syncQuestions) syncQuestions.checked = data.sync_questions !== false;

        // Auto-check health if enabled and URL is set
        if (data.enabled && data.server_url) {
            checkMothershipHealth();
        } else {
            updateMothershipHealthUI(data.enabled ? null : 'disabled');
        }
    } catch (error) {
        console.error('Failed to load mothership settings:', error);
    }
}

/**
 * Save a mothership setting
 */
async function saveMothershipSetting(body) {
    try {
        const response = await fetch(`${API_BASE}/api/config/mothership`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body)
        });
        const result = await response.json();
        if (!result.success) {
            console.error('Failed to save mothership setting:', result.error);
        }
    } catch (error) {
        console.error('Failed to save mothership setting:', error);
    }
}

/**
 * Check mothership server health and update indicator
 */
async function checkMothershipHealth() {
    const dot = document.getElementById('mothership-health-dot');
    const label = document.getElementById('mothership-health-label');
    if (dot) dot.className = 'health-dot health-checking';
    if (label) label.textContent = 'Checking...';

    try {
        const response = await fetch(`${API_BASE}/api/config/mothership/test`, { method: 'POST' });
        const result = await response.json();
        updateMothershipHealthUI(result.reachable ? 'connected' : 'unreachable');
    } catch (error) {
        updateMothershipHealthUI('error');
    }
}

/**
 * Update the mothership health indicator UI
 */
function updateMothershipHealthUI(status) {
    const dot = document.getElementById('mothership-health-dot');
    const label = document.getElementById('mothership-health-label');
    if (!dot || !label) return;

    dot.className = 'health-dot';
    switch (status) {
        case 'connected':
            dot.classList.add('health-connected');
            label.textContent = 'Connected';
            break;
        case 'unreachable':
            dot.classList.add('health-unreachable');
            label.textContent = 'Unreachable';
            break;
        case 'disabled':
            dot.classList.add('health-disabled');
            label.textContent = 'Disabled';
            break;
        case 'error':
            dot.classList.add('health-unreachable');
            label.textContent = 'Error';
            break;
        default:
            dot.classList.add('health-disabled');
            label.textContent = 'Unknown';
    }
}

/**
 * Test mothership server connectivity (manual button)
 */
async function testMothershipServer() {
    const statusEl = document.getElementById('notif-test-status');
    const btn = document.getElementById('notif-test-btn');
    if (statusEl) statusEl.textContent = 'Testing...';
    if (btn) btn.disabled = true;

    try {
        const response = await fetch(`${API_BASE}/api/config/mothership/test`, { method: 'POST' });
        const result = await response.json();
        if (statusEl) {
            if (result.reachable) {
                statusEl.textContent = 'Connected';
                statusEl.style.color = 'var(--color-success)';
            } else {
                statusEl.textContent = result.error || 'Unreachable';
                statusEl.style.color = 'var(--color-error)';
            }
        }
        updateMothershipHealthUI(result.reachable ? 'connected' : 'unreachable');
    } catch (error) {
        if (statusEl) {
            statusEl.textContent = 'Test failed';
            statusEl.style.color = 'var(--color-error)';
        }
        updateMothershipHealthUI('error');
    } finally {
        if (btn) btn.disabled = false;
    }
}

/**
 * Initialize mothership settings handlers
 */
function initMothershipSettings() {
    // Toggle
    const enabledToggle = document.getElementById('notif-enabled');
    if (enabledToggle) {
        enabledToggle.addEventListener('change', () => {
            saveMothershipSetting({ enabled: enabledToggle.checked });
            if (enabledToggle.checked) {
                checkMothershipHealth();
            } else {
                updateMothershipHealthUI('disabled');
            }
        });
    }

    const soundEnabledToggle = document.getElementById('notif-sound-enabled');
    if (soundEnabledToggle) {
        soundEnabledToggle.addEventListener('change', () => {
            if (typeof setNotificationSoundEnabled === 'function') {
                setNotificationSoundEnabled(soundEnabledToggle.checked);
            }
            saveMothershipSetting({ sound_enabled: soundEnabledToggle.checked });
        });
    }

    // Sync toggles (feature not yet implemented in runtime behavior)
    const syncTasks = document.getElementById('ms-sync-tasks');
    if (syncTasks) {
        // Hide the control so users are not misled by a non-functional toggle.
        syncTasks.style.display = 'none';
        const syncTasksLabel = document.querySelector('label[for="ms-sync-tasks"]');
        if (syncTasksLabel) {
            syncTasksLabel.style.display = 'none';
        }
    }

    const syncQuestions = document.getElementById('ms-sync-questions');
    if (syncQuestions) {
        // Hide the control so users are not misled by a non-functional toggle.
        syncQuestions.style.display = 'none';
        const syncQuestionsLabel = document.querySelector('label[for="ms-sync-questions"]');
        if (syncQuestionsLabel) {
            syncQuestionsLabel.style.display = 'none';
        }
    }

    // Text/select inputs with debounce
    const inputs = [
        { id: 'notif-server-url', key: 'server_url', parse: v => v.trim() },
        { id: 'notif-api-key', key: 'api_key', parse: v => v.trim() },
        { id: 'notif-project-name', key: 'project_name', parse: v => v.trim() },
        { id: 'notif-project-desc', key: 'project_description', parse: v => v.trim() },
        { id: 'notif-poll-interval', key: 'poll_interval_seconds', parse: v => Math.max(5, parseInt(v) || 30) },
        { id: 'notif-recipients', key: 'recipients', parse: v => v.split(',').map(s => s.trim()).filter(Boolean) }
    ];

    inputs.forEach(({ id, key, parse }) => {
        const input = document.getElementById(id);
        if (!input) return;
        let debounceTimer = null;
        input.addEventListener('input', () => {
            clearTimeout(debounceTimer);
            debounceTimer = setTimeout(() => {
                const body = {};
                body[key] = parse(input.value);
                saveMothershipSetting(body);
            }, 800);
        });
    });

    // Channel select (no debounce needed)
    const channel = document.getElementById('notif-channel');
    if (channel) {
        channel.addEventListener('change', () => {
            saveMothershipSetting({ channel: channel.value });
        });
    }

    // Test button
    const testBtn = document.getElementById('notif-test-btn');
    if (testBtn) {
        testBtn.addEventListener('click', testMothershipServer);
    }

    loadMothershipSettings();
}

// ========== STEERING ==========
let selectedInstance = null;

/**
 * Initialize steering panel event handlers (now in modal)
 */
function initSteeringPanel() {
    // Instance selector buttons
    document.querySelectorAll('.instance-btn').forEach(btn => {
        btn.addEventListener('click', () => {
            if (btn.disabled) return;
            selectInstance(btn.dataset.instance);
        });
    });

    // Whisper send handlers
    document.getElementById('whisper-send')?.addEventListener('click', sendWhisper);
    document.getElementById('whisper-input')?.addEventListener('keypress', (e) => {
        if (e.key === 'Enter') sendWhisper();
    });

    // Initialize whisper modal toggle
    initWhisperModal();
}

/**
 * Initialize whisper modal toggle handlers
 */
function initWhisperModal() {
    const whisperBtn = document.getElementById('whisper-btn');
    const whisperModal = document.getElementById('whisper-modal');
    const whisperModalClose = document.getElementById('whisper-modal-close');

    if (!whisperBtn || !whisperModal) return;

    // Open modal on button click
    whisperBtn.addEventListener('click', () => {
        whisperModal.classList.add('visible');
        // Focus the input if an instance is selected
        const input = document.getElementById('whisper-input');
        if (input && !input.disabled) {
            setTimeout(() => input.focus(), 100);
        }
    });

    // Close modal on X button click
    whisperModalClose?.addEventListener('click', () => {
        whisperModal.classList.remove('visible');
    });

    // Close modal on backdrop click
    whisperModal.addEventListener('click', (e) => {
        if (e.target === whisperModal) {
            whisperModal.classList.remove('visible');
        }
    });

    // Close modal on Escape key
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape' && whisperModal.classList.contains('visible')) {
            whisperModal.classList.remove('visible');
        }
    });
}

/**
 * Select an instance for steering
 * @param {string} type - Instance type ("analysis" or "execution")
 */
function selectInstance(type) {
    selectedInstance = type;
    document.querySelectorAll('.instance-btn').forEach(b => b.classList.remove('active'));
    document.getElementById(`btn-${type}`)?.classList.add('active');

    // Update status text immediately from last known state
    if (lastState?.instances) {
        updateSteeringStatus(lastState.instances);
    }
}

/**
 * Get the currently selected instance
 * @returns {string|null} Selected instance type
 */
function getSelectedInstance() {
    return selectedInstance;
}

/**
 * Send a whisper to the selected instance
 */
async function sendWhisper() {
    if (!selectedInstance) return;
    const input = document.getElementById('whisper-input');
    const message = input?.value?.trim();
    if (!message) return;

    const btn = document.getElementById('whisper-send');
    const originalText = btn.textContent;
    btn.disabled = true;
    btn.textContent = '...';

    try {
        const response = await fetch(`${API_BASE}/api/whisper`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                instance_type: selectedInstance,
                message: message,
                priority: document.getElementById('whisper-priority')?.value || 'normal'
            })
        });
        const result = await response.json();
        if (result.success) {
            input.value = '';
            showSignalFeedback(`Whisper → ${selectedInstance}`);
        } else {
            throw new Error(result.error);
        }
    } catch (e) {
        showSignalFeedback(`Error: ${e.message}`);
    } finally {
        btn.disabled = false;
        btn.textContent = originalText;
    }
}

/**
 * Show feedback in the signal feedback area
 * @param {string} message - Message to display
 */
function showSignalFeedback(message) {
    const signalStatus = document.getElementById('signal-status');
    if (signalStatus) {
        signalStatus.textContent = message;
        signalStatus.classList.add('visible');
        setTimeout(() => signalStatus.classList.remove('visible'), 3000);
    }
}

/**
 * Update steering status text for selected instance
 * @param {Object} instances - Instances object from state
 */
function updateSteeringStatus(instances) {
    const textEl = document.getElementById('steering-text');
    if (!textEl) return;

    if (!selectedInstance) {
        textEl.textContent = 'No instance selected';
        textEl.className = 'steering-text muted';
        return;
    }

    const inst = instances?.[selectedInstance];
    if (!inst?.alive) {
        textEl.textContent = `${selectedInstance} not running`;
        textEl.className = 'steering-text muted';
    } else if (inst.status) {
        const statusText = stripConsoleSequences(inst.status);
        const nextActionText = stripConsoleSequences(inst.next_action);
        if (statusText) {
            textEl.textContent = statusText + (nextActionText ? `\n→ ${nextActionText}` : '');
            textEl.className = 'steering-text';
        } else {
            textEl.textContent = 'Awaiting heartbeat...';
            textEl.className = 'steering-text muted';
        }
    } else {
        textEl.textContent = 'Awaiting heartbeat...';
        textEl.className = 'steering-text muted';
    }
}
