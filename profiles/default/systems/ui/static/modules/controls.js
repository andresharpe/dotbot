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
 * Current provider data from /api/providers
 */
let providerData = null;

/**
 * Fetch provider data from the API and populate model options
 */
async function loadProviderData() {
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

        // Re-render model grids with new data
        initAnalysisModelSelector();
        initExecutionModelSelector();

        // Render provider selector
        initProviderSelector();

        // Re-apply saved settings so model selections aren't lost by grid re-render
        loadSettings();
    } catch (error) {
        console.error('Failed to load provider data:', error);
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

    grid.innerHTML = (providerData.providers || []).map(p => `
        <div class="model-option${p.name === providerData.active ? ' active' : ''}${!p.installed ? ' disabled' : ''}" data-provider="${p.name}">
            <div class="model-option-header">
                <span class="model-option-name">${p.display_name}</span>
                ${!p.installed ? '<span class="model-option-badge" style="opacity:0.5">Not installed</span>' : ''}
            </div>
        </div>
    `).join('');

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

                initProviderSelector();
                initAnalysisModelSelector();
                initExecutionModelSelector();

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
                await stopProcessesByType('workflow');
                break;
            case 'kill-workflow':
                await killProcessesByType('workflow');
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

/**
 * Launch a unified workflow process (analyse then execute per task)
 */
async function launchWorkflow() {
    try {
        const response = await fetch(`${API_BASE}/api/process/launch`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ type: 'workflow', continue: true })
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
        textEl.textContent = inst.status + (inst.next_action ? `\n→ ${inst.next_action}` : '');
        textEl.className = 'steering-text';
    } else {
        textEl.textContent = 'Awaiting heartbeat...';
        textEl.className = 'steering-text muted';
    }
}
