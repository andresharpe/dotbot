/**
 * DOTBOT Control Panel - Kickstart Module
 * Handles new project detection and kickstart flow
 */

// State
let isNewProject = false;
let kickstartInProgress = false;
let analyseInProgress = false;
let workflowLaunchFiles = [];       // { name, size, content (base64) }
let workflowLaunchName = null; // workflow name that triggered the modal
let workflowLaunchUseTaskRunner = false; // when true, submit routes to task-runner engine
let kickstartProcessId = null; // process_id returned from backend
let kickstartPolling = null;   // interval ID for doc appearance detection
let roadmapPolling = null;     // interval ID for task creation detection
let kickstartDialog = null;    // workflow-driven dialog config from /api/info
let kickstartPhases = [];      // workflow-driven phases from /api/info
let workflowLaunchMode = null;      // server-evaluated form mode from workflow manifest
let workflowLaunchSubmitting = false; // in-flight guard against double submit
let preflightController = null;  // AbortController for preflight fetch + animation

/**
 * Cancellable delay — rejects with AbortError when signal aborts.
 * Used in place of chained setTimeout calls so preflight animation
 * can be halted mid-flight.
 */
function preflightSleep(ms, signal) {
    return new Promise((resolve, reject) => {
        if (signal && signal.aborted) {
            reject(new DOMException('aborted', 'AbortError'));
            return;
        }
        const id = setTimeout(() => {
            if (signal) signal.removeEventListener('abort', onAbort);
            resolve();
        }, ms);
        function onAbort() {
            clearTimeout(id);
            reject(new DOMException('aborted', 'AbortError'));
        }
        if (signal) signal.addEventListener('abort', onAbort, { once: true });
    });
}

/**
 * Initialize kickstart functionality
 * Checks if this is a new project and sets up event handlers
 */
async function initKickstart() {
    // Seed elements that carry a data-default with the default text so the
    // modal never briefly renders with an empty label before the dialog
    // config arrives. data-default stays the single source of truth (see
    // #workflow-launch-interview-label / #workflow-launch-interview-hint in index.html).
    document.querySelectorAll('[data-default]').forEach(el => {
        if (!el.textContent) el.textContent = el.dataset.default;
    });

    // Determine isNewProject from the product list. Prefer the server-inlined
    // bootstrap (issue #269) and consume it so later calls fetch fresh data.
    let productListData = null;
    if (typeof window !== 'undefined' && window.__DOTBOT_BOOTSTRAP__ && window.__DOTBOT_BOOTSTRAP__.productList) {
        productListData = window.__DOTBOT_BOOTSTRAP__.productList;
        window.__DOTBOT_BOOTSTRAP__.productList = null;
    }
    if (!productListData) {
        try {
            const response = await fetch(`${API_BASE}/api/product/list`);
            if (response.ok) productListData = await response.json();
        } catch (error) {
            console.warn('Could not check product docs for kickstart:', error);
        }
    }
    if (productListData) {
        const docs = productListData.docs || [];
        const mdDocs = docs.filter(d => d.type === 'md');
        isNewProject = mdDocs.length === 0;
    }

    // Now that isNewProject is set, re-trigger executive summary display
    if (isNewProject && typeof updateExecutiveSummary === 'function') {
        updateExecutiveSummary();
    }

    // Apply workflow-driven dialog text from /api/info (active/default workflow).
    // Per-workflow modals re-fetch this from /api/workflows/{name}/form via
    // applyKickstartDialog when openWorkflowLaunchDialog runs (issue #235).
    // Reuse the inlined bootstrap info if initProjectName hasn't already consumed it.
    let info = null;
    if (typeof window !== 'undefined' && window.__DOTBOT_BOOTSTRAP__ && window.__DOTBOT_BOOTSTRAP__.info) {
        info = window.__DOTBOT_BOOTSTRAP__.info;
        window.__DOTBOT_BOOTSTRAP__.info = null;
    }
    if (!info) {
        try {
            const infoResp = await fetch(`${API_BASE}/api/info`);
            if (infoResp.ok) info = await infoResp.json();
        } catch (error) {
            console.warn('Could not load kickstart dialog config:', error);
        }
    }
    if (info) {
        applyKickstartDialog(
            info.kickstart_dialog || null,
            info.kickstart_phases || [],
            info.kickstart_mode || null
        );

        // Re-render executive summary now that dialog/phases are loaded
        if (typeof updateExecutiveSummary === 'function') {
            updateExecutiveSummary();
        }
    }

    // Bind kickstart modal handlers
    const modal = document.getElementById('workflow-launch-modal');
    const closeBtn = document.getElementById('workflow-launch-modal-close');
    const cancelBtn = document.getElementById('workflow-launch-cancel');
    const submitBtn = document.getElementById('workflow-launch-submit');
    const textarea = document.getElementById('workflow-launch-prompt');
    const dropzone = document.getElementById('workflow-launch-dropzone');
    const fileInput = document.getElementById('workflow-launch-file-input');

    // Close handlers
    closeBtn?.addEventListener('click', closeKickstartModal);
    cancelBtn?.addEventListener('click', closeKickstartModal);
    modal?.addEventListener('click', (e) => {
        if (e.target === modal) closeKickstartModal();
    });

    // Submit handler
    submitBtn?.addEventListener('click', submitKickstart);

    // Ctrl+Enter to submit
    textarea?.addEventListener('keydown', (e) => {
        if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
            e.preventDefault();
            submitKickstart();
        }
    });

    // Bind analyse modal handlers
    const analyseModal = document.getElementById('analyse-modal');
    const analyseCloseBtn = document.getElementById('analyse-modal-close');
    const analyseCancelBtn = document.getElementById('analyse-cancel');
    const analyseSubmitBtn = document.getElementById('analyse-submit');
    const analyseTextarea = document.getElementById('analyse-prompt');

    analyseCloseBtn?.addEventListener('click', closeAnalyseModal);
    analyseCancelBtn?.addEventListener('click', closeAnalyseModal);
    analyseModal?.addEventListener('click', (e) => {
        if (e.target === analyseModal) closeAnalyseModal();
    });

    analyseSubmitBtn?.addEventListener('click', submitAnalyse);

    analyseTextarea?.addEventListener('keydown', (e) => {
        if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
            e.preventDefault();
            submitAnalyse();
        }
    });

    // Dropzone handlers
    if (dropzone) {
        dropzone.addEventListener('click', () => fileInput?.click());

        dropzone.addEventListener('dragover', (e) => {
            e.preventDefault();
            dropzone.classList.add('dragover');
        });

        dropzone.addEventListener('dragleave', (e) => {
            e.preventDefault();
            dropzone.classList.remove('dragover');
        });

        dropzone.addEventListener('drop', (e) => {
            e.preventDefault();
            dropzone.classList.remove('dragover');
            if (e.dataTransfer.files.length > 0) {
                handleFiles(e.dataTransfer.files);
            }
        });
    }

    // File input handler
    fileInput?.addEventListener('change', (e) => {
        if (e.target.files.length > 0) {
            handleFiles(e.target.files);
            e.target.value = ''; // Reset so same file can be selected again
        }
    });
}

/**
 * Render kickstart CTA into a container element
 * Uses server-evaluated kickstart_mode from workflow manifest form.modes
 * to determine what CTA to show. Falls back to generic display if no mode.
 * @param {HTMLElement} container - Container to render into
 */
function renderKickstartCTA(container) {
    if (kickstartInProgress) {
        const modeLabel = workflowLaunchMode?.label || 'Kickstart';
        container.innerHTML = `
            <div class="kickstart-cta in-progress">
                <div class="kickstart-glyph">◈</div>
                <div class="kickstart-title">${escapeHtml(modeLabel)} In Progress</div>
                <div class="workflow-launch-description">Creating product documents. Check the Processes tab for details.</div>
            </div>
        `;
        return;
    }

    // Multi-workflow cards: show card grid when workflows are installed
    if (installedWorkflows && installedWorkflows.length > 0 && !kickstartInProgress) {
        renderWorkflowCardGrid(container);
        return;
    }

    // Mode-driven CTA from workflow manifest form.modes
    if (workflowLaunchMode && !workflowLaunchMode.hidden) {
        const title = workflowLaunchMode.label || currentWorkflowName || 'Workflow';
        const desc = workflowLaunchMode.description || kickstartDialog?.description || 'Run the configured workflow.';
        const buttonText = workflowLaunchMode.button || 'RUN WORKFLOW';
        const phaseNames = (kickstartPhases || []).map(p => escapeHtml(p.name)).join(' <span class="phase-sep">·</span> ');
        container.innerHTML = `
            <div class="kickstart-cta">
                <div class="kickstart-glyph">◈</div>
                <div class="kickstart-title">${escapeHtml(title)}</div>
                <div class="workflow-launch-description">${escapeHtml(desc)}</div>
                ${phaseNames ? `<div class="kickstart-phase-inline">${phaseNames}</div>` : ''}
                <button class="kickstart-btn" onclick="openWorkflowLaunchDialog(currentWorkflowName)" style="margin-top: 1.5rem">${escapeHtml(buttonText)}</button>
            </div>
        `;
        return;
    }

    // Workflow with phases but no mode — show workflow-specific CTA
    if (kickstartDialog && kickstartPhases.length > 0) {
        const title = currentWorkflowName || 'Workflow';
        const desc = kickstartDialog.description || 'Run the configured workflow.';
        const phaseNames = kickstartPhases.map(p => escapeHtml(p.name)).join(' <span class="phase-sep">·</span> ');
        container.innerHTML = `
            <div class="kickstart-cta">
                <div class="kickstart-glyph">◈</div>
                <div class="kickstart-title">${escapeHtml(title)}</div>
                <div class="workflow-launch-description">${escapeHtml(desc)}</div>
                <div class="kickstart-phase-inline">${phaseNames}</div>
                <button class="kickstart-btn" onclick="openWorkflowLaunchDialog(currentWorkflowName)" style="margin-top: 1.5rem">RUN WORKFLOW</button>
            </div>
        `;
        return;
    }

    // No mode, no workflow — generic fallback
    container.innerHTML = `
        <div class="kickstart-cta">
            <div class="kickstart-glyph">◈</div>
            <div class="kickstart-title">New Project</div>
            <div class="workflow-launch-description">
                Describe your project and let Claude create your foundational product documents.
            </div>
            <button class="kickstart-btn" onclick="openWorkflowLaunchDialog(currentWorkflowName)">KICKSTART PROJECT</button>
        </div>
    `;
}

/**
 * Render workflow card grid in the executive summary area.
 * Each installed workflow gets a card with progress + run/stop.
 * @param {HTMLElement} container - Container to render into
 */
function renderWorkflowCardGrid(container) {
    // Fetch latest workflow data from state
    const workflows = lastState?.workflows || {};
    const names = installedWorkflows || [];

    if (names.length === 0) {
        container.style.display = 'none';
        return;
    }

    let html = '<div class="module-header" style="margin-bottom: 12px;"><span class="module-title">◈ Workflows</span></div><div class="workflow-card-grid">';
    names.forEach(name => {
        const wf = workflows[name] || { todo: 0, in_progress: 0, done: 0, total: 0 };
        const total = wf.total || 0;
        const done = wf.done || 0;
        const pct = total > 0 ? Math.round((done / total) * 100) : 0;
        const isRunning = wf.process_alive || false;
        const borderClass = isRunning ? 'workflow-card running' : 'workflow-card';
        const ledClass = isRunning ? 'led pulse' : 'led off';

        html += `
            <div class="${borderClass}">
                <div class="workflow-card-header">
                    <span class="${ledClass}"></span>
                    <span class="workflow-card-name">${escapeHtml(name)}</span>
                    <div class="workflow-card-actions">
                        <button class="ctrl-btn-xs primary wf-run-btn" title="Run ${escapeHtml(name)}" ${isRunning || Object.keys(installedWorkflowMap).length === 0 ? 'disabled' : ''}>Run</button>
                        <button class="ctrl-btn-xs wf-stop-btn" title="Stop ${escapeHtml(name)}" ${!isRunning ? 'disabled' : ''}>Stop</button>
                    </div>
                </div>
                <div class="workflow-card-progress">
                    <div class="workflow-card-bar-track">
                        <div class="workflow-card-bar-fill" style="width: ${pct}%"></div>
                    </div>
                </div>
                <div class="workflow-card-stats">
                    ${wf.todo ? `<span>${wf.todo} todo</span>` : ''}
                    ${wf.in_progress ? `<span>${wf.in_progress} running</span>` : ''}
                    ${done ? `<span>${done} done</span>` : ''}
                    ${total === 0 ? '<span>No tasks</span>' : `<span>${pct}%</span>`}
                </div>
            </div>
        `;
    });
    html += '</div>';

    container.innerHTML = html;

    // Bind event handlers using raw workflow names (avoids inline onclick XSS issues)
    const cards = container.querySelectorAll('.workflow-card, .workflow-card.running');
    cards.forEach((card, index) => {
        const wfName = names[index];
        if (!wfName) return;
        const runBtn = card.querySelector('.wf-run-btn');
        if (runBtn) runBtn.addEventListener('click', () => {
            const wfMeta = installedWorkflowMap[wfName];
            runWorkflow(wfName, !!(wfMeta && wfMeta.has_form));
        });
        const stopBtn = card.querySelector('.wf-stop-btn');
        if (stopBtn) stopBtn.addEventListener('click', () => stopWorkflow(wfName));
    });
    container.style.display = 'block';
}

/**
 * Apply a workflow's kickstart dialog config to the modal DOM.
 *
 * Sets description, interview label/hint, prompt placeholder, section
 * visibility, and renders the phase checklist. Called from initKickstart
 * (active workflow) and openWorkflowLaunchDialog (per-workflow lookup) so the
 * modal always reflects the workflow the user actually selected.
 *
 * @param {object|null} dialog - kickstart dialog object from manifest form block
 * @param {Array} phases - phase list converted from manifest tasks
 * @param {object|null} mode - active form mode (kickstart_mode)
 */
function applyKickstartDialog(dialog, phases, mode) {
    kickstartDialog = dialog || null;
    kickstartPhases = phases || [];
    workflowLaunchMode = mode || null;

    const descEl = document.getElementById('workflow-launch-description');
    const labelEl = document.getElementById('workflow-launch-interview-label');
    const hintEl = document.getElementById('workflow-launch-interview-hint');
    const promptEl = document.getElementById('workflow-launch-prompt');
    const promptGroup = promptEl?.closest('.form-group');
    const filesGroup = document.getElementById('workflow-launch-dropzone')?.closest('.form-group');
    const interviewOption = document.getElementById('workflow-launch-interview')?.closest('.form-option');
    const awOption = document.getElementById('workflow-launch-auto-workflow')?.closest('.form-option');

    // Reset sections to visible (in case a previous workflow hid them)
    if (descEl) descEl.style.display = '';
    if (promptGroup) promptGroup.style.display = '';
    if (filesGroup) filesGroup.style.display = '';
    if (interviewOption) interviewOption.style.display = '';
    if (awOption) awOption.style.display = '';

    // Reset dialog-controlled content before applying new values so a workflow
    // that omits a field does not inherit the previous workflow's text (#235).
    if (descEl) descEl.textContent = '';
    // Fall back to data-default attributes defined in index.html — the
    // workflow-configured interview_label/interview_hint can be empty when
    // the server defaults show_interview to true without supplying text
    // (e.g. a mode that omits show_interview in its form block).
    if (labelEl) labelEl.textContent = labelEl.dataset.default || '';
    if (hintEl) hintEl.textContent = hintEl.dataset.default || '';
    if (promptEl) promptEl.placeholder = '';

    // Remove any auto-detect button injected on a previous apply so repeated
    // calls (per-workflow form re-fetch) don't stack duplicates.
    document.getElementById('kickstart-auto-detect-container')?.remove();

    if (dialog) {
        if (descEl && dialog.description != null) descEl.textContent = dialog.description;
        if (labelEl && dialog.interview_label != null) labelEl.textContent = dialog.interview_label;
        if (hintEl && dialog.interview_hint != null) hintEl.textContent = dialog.interview_hint;
        if (promptEl && dialog.prompt_placeholder != null) promptEl.placeholder = dialog.prompt_placeholder;

        // Auto-detect button: generate project description from README / CLAUDE.md
        if (promptEl && dialog.show_prompt !== false) {
            const btnContainer = document.createElement('div');
            btnContainer.id = 'kickstart-auto-detect-container';
            btnContainer.style.cssText = 'margin-top: 6px; text-align: right;';
            const autoBtn = document.createElement('button');
            autoBtn.type = 'button';
            autoBtn.className = 'ctrl-btn-sm';
            autoBtn.textContent = '\u27F3 Auto-detect';
            autoBtn.title = 'Generate project description from README or CLAUDE.md';
            autoBtn.addEventListener('click', async () => {
                autoBtn.disabled = true;
                const origText = autoBtn.textContent;
                autoBtn.textContent = '\u27F3 Scanning\u2026';
                try {
                    // POST + X-Dotbot-Request header: this endpoint calls the LLM
                    // provider and must be protected from cross-site GET abuse.
                    // CSRF protection is enforced by the server for POST requests,
                    // and browsers require CORS preflight for custom headers so
                    // a malicious page cannot silently trigger provider calls.
                    const resp = await fetch(`${API_BASE}/api/project/summary`, {
                        method: 'POST',
                        headers: { 'X-Dotbot-Request': '1', 'Content-Type': 'application/json' },
                    });
                    const data = await resp.json();
                    if (data.success && data.summary) {
                        promptEl.value = data.summary;
                        autoBtn.textContent = '\u2713 Done';
                        setTimeout(() => { autoBtn.textContent = origText; }, 2000);
                    } else {
                        autoBtn.textContent = '\u2717 No docs found';
                        setTimeout(() => { autoBtn.textContent = origText; }, 2000);
                    }
                } catch {
                    autoBtn.textContent = '\u2717 Failed';
                    setTimeout(() => { autoBtn.textContent = origText; }, 2000);
                } finally {
                    autoBtn.disabled = false;
                }
            });
            btnContainer.appendChild(autoBtn);
            promptEl.parentNode.insertBefore(btnContainer, promptEl.nextSibling);
        }

        if (dialog.show_prompt === false) {
            if (promptGroup) promptGroup.style.display = 'none';
            if (descEl) descEl.style.display = 'none';
        }
        if (dialog.show_files === false) {
            if (filesGroup) filesGroup.style.display = 'none';
        }
        if (dialog.show_interview === false) {
            if (interviewOption) interviewOption.style.display = 'none';
        }
        if (dialog.show_auto_workflow === false) {
            if (awOption) awOption.style.display = 'none';
        }
    }

    // Render phase checklist. Build nodes via the DOM API (not innerHTML) so
    // manifest-supplied names/ids cannot inject markup.
    const container = document.getElementById('workflow-launch-phases-container');
    const wrapper = document.getElementById('workflow-launch-phase-list');
    if (container && wrapper) {
        container.replaceChildren();
        if (kickstartPhases.length > 0) {
            wrapper.style.display = 'block';
            kickstartPhases.forEach(p => {
                const phaseItem = document.createElement('div');
                const phaseName = p.name ?? '';
                if (p.optional) {
                    phaseItem.className = 'phase-item';

                    const label = document.createElement('label');
                    label.className = 'form-checkbox-label';

                    const checkbox = document.createElement('input');
                    checkbox.type = 'checkbox';
                    checkbox.className = 'kickstart-phase-toggle';
                    checkbox.checked = true;
                    checkbox.dataset.phaseId = String(p.id ?? '');

                    const text = document.createElement('span');
                    text.className = 'form-checkbox-text';
                    text.textContent = phaseName;

                    label.appendChild(checkbox);
                    label.appendChild(text);
                    phaseItem.appendChild(label);
                } else {
                    phaseItem.className = 'phase-item phase-fixed';

                    const bullet = document.createElement('span');
                    bullet.className = 'phase-bullet';
                    bullet.textContent = '\u203a';

                    const text = document.createElement('span');
                    text.className = 'form-checkbox-text';
                    text.textContent = phaseName;

                    phaseItem.appendChild(bullet);
                    phaseItem.appendChild(text);
                }
                container.appendChild(phaseItem);
            });
        } else {
            wrapper.style.display = 'none';
        }
    }
}

/**
 * Open the kickstart modal for a specific workflow.
 *
 * Fetches the per-workflow form config from /api/workflows/{name}/form
 * and applies it to the DOM before showing the modal. This ensures the
 * modal reflects the selected workflow's form rather than the workflow
 * loaded at page-init time (issue #235).
 *
 * @param {string} workflowName - The workflow name from the click context
 * @param {object} [options] - Optional flags (e.g. { useTaskRunner: true })
 */
async function openWorkflowLaunchDialog(workflowName, options) {
    const modal = document.getElementById('workflow-launch-modal');
    const textarea = document.getElementById('workflow-launch-prompt');

    // Store which workflow triggered the modal so the submit path uses the right one
    workflowLaunchName = workflowName || null;
    workflowLaunchUseTaskRunner = !!(options && options.useTaskRunner);

    // Show the modal immediately so the click feels responsive — the form
    // config is fetched in parallel and applied (or reset) when it arrives.
    if (modal) {
        modal.classList.add('visible');
        setTimeout(() => textarea?.focus(), 100);
    }

    // Set title from workflow name immediately so it's correct before the
    // async form fetch completes. Falls back to generic label when no name.
    const titleEl = document.getElementById('workflow-launch-modal-title');
    if (titleEl) {
        const displayName = workflowName
            ? workflowName.replace(/-/g, ' ').replace(/\b\w/g, c => c.toUpperCase())
            : 'Kickstart Project';
        titleEl.textContent = displayName;
    }

    if (!workflowName) return;

    // Re-fetch this workflow's form config so the modal reflects the
    // selected workflow rather than whichever workflow was active at init.
    // Capture the request target so rapid clicks on different workflows
    // can discard stale responses instead of overwriting the latest one.
    const requestedFor = workflowName;
    let applied = false;
    try {
        const resp = await fetch(`${API_BASE}/api/workflows/${encodeURIComponent(workflowName)}/form`);
        if (workflowLaunchName !== requestedFor) return; // superseded by a newer click
        if (resp.ok) {
            const data = await resp.json();
            if (workflowLaunchName !== requestedFor) return;
            if (data && data.success && data.dialog) {
                applyKickstartDialog(data.dialog, data.phases || [], data.mode || null);
                applied = true;
            } else {
                // success without a usable dialog (e.g. workflow has no form
                // block) must fall through to the generic fallback below so we
                // never leave the previous workflow's config on screen (#235).
                console.warn(`Workflow form lookup returned no usable dialog for "${workflowName}"`, data);
            }
        } else {
            console.warn(`Workflow form lookup failed for "${workflowName}": HTTP ${resp.status}`);
        }
    } catch (error) {
        if (workflowLaunchName !== requestedFor) return;
        console.warn(`Could not load form config for workflow "${workflowName}":`, error);
    }

    if (!applied) {
        // Reset the DOM to a generic placeholder state so we never silently
        // display another workflow's configuration (the exact bug in #235).
        applyKickstartDialog(
            {
                description: `Configure workflow: ${workflowName}`,
                interview_label: '',
                interview_hint: '',
                prompt_placeholder: ''
            },
            [],
            null
        );
        if (typeof showToast === 'function') {
            showToast(`Could not load form for workflow "${workflowName}"`, 'warning', 6000);
        }
    }
}

/**
 * Close the kickstart modal and reset form
 */
function closeKickstartModal() {
    // Abort pending preflight animation/fetch so closing the modal
    // (via X, backdrop click, or Esc) cannot let executeWorkflowLaunch fire
    // after the modal is gone. Controller not nulled so the
    // `signal.aborted` guard in executeWorkflowLaunch still sees it.
    preflightController?.abort();

    const modal = document.getElementById('workflow-launch-modal');
    const textarea = document.getElementById('workflow-launch-prompt');
    const submitBtn = document.getElementById('workflow-launch-submit');

    if (modal) {
        modal.classList.remove('visible');
        if (textarea) textarea.value = '';
        workflowLaunchFiles = [];
        workflowLaunchName = null;
        workflowLaunchUseTaskRunner = false;
        workflowLaunchSubmitting = false;
        updateFileList();
        const interviewCheckbox = document.getElementById('workflow-launch-interview');
        if (interviewCheckbox) interviewCheckbox.checked = true;
        const awCheckbox = document.getElementById('workflow-launch-auto-workflow');
        if (awCheckbox) awCheckbox.checked = true;
        if (submitBtn) {
            submitBtn.classList.remove('loading');
            submitBtn.disabled = false;
        }

        // Reset to form phase in case we were on preflight
        const phaseForm = document.getElementById('workflow-launch-phase-form');
        const phasePreflight = document.getElementById('workflow-launch-phase-preflight');
        const footerForm = document.getElementById('workflow-launch-footer-form');
        const footerPreflight = document.getElementById('workflow-launch-footer-preflight');
        if (phasePreflight) phasePreflight.classList.add('hidden');
        if (phaseForm) phaseForm.classList.remove('hidden');
        if (footerPreflight) footerPreflight.classList.add('hidden');
        if (footerForm) footerForm.classList.remove('hidden');
    }
}

/**
 * Handle file selection (from drop or browse)
 * @param {FileList} fileList - Files to process
 */
function handleFiles(fileList) {
    const files = Array.from(fileList);

    for (const file of files) {
        // Check for duplicate
        if (workflowLaunchFiles.some(f => f.name === file.name)) {
            showToast(`File "${file.name}" already added`, 'warning');
            continue;
        }

        // Read as base64
        const reader = new FileReader();
        reader.onload = (e) => {
            // readAsDataURL gives "data:...;base64,XXXXX" — extract just the base64 part
            const base64 = e.target.result.split(',')[1];
            workflowLaunchFiles.push({
                name: file.name,
                size: file.size,
                content: base64
            });
            updateFileList();
        };
        reader.onerror = () => {
            showToast(`Could not read file "${file.name}"`, 'error');
        };
        reader.readAsDataURL(file);
    }
}

/**
 * Re-render the file list from workflowLaunchFiles[]
 */
function updateFileList() {
    const container = document.getElementById('workflow-launch-file-list');
    if (!container) return;

    if (workflowLaunchFiles.length === 0) {
        container.innerHTML = '';
        return;
    }

    container.innerHTML = workflowLaunchFiles.map((file, index) => {
        const sizeStr = file.size < 1024
            ? `${file.size} B`
            : `${Math.round(file.size / 1024)} KB`;

        return `
            <div class="kickstart-file-item">
                <span class="kickstart-file-icon">◇</span>
                <span class="kickstart-file-name">${escapeHtml(file.name)}</span>
                <span class="kickstart-file-size">${sizeStr}</span>
                <button class="kickstart-file-remove" onclick="removeKickstartFile(${index})" title="Remove file">&times;</button>
            </div>
        `;
    }).join('');
}

/**
 * Remove a file from the kickstart file list
 * @param {number} index - Index in workflowLaunchFiles array
 */
function removeKickstartFile(index) {
    workflowLaunchFiles.splice(index, 1);
    updateFileList();
}

/**
 * Submit the kickstart request — runs preflight checks first
 */
async function submitKickstart() {
    const textarea = document.getElementById('workflow-launch-prompt');
    const submitBtn = document.getElementById('workflow-launch-submit');

    const rawPrompt = textarea?.value?.trim();
    // Use default_prompt from workflow dialog config when prompt field is hidden or empty
    const prompt = rawPrompt || (kickstartDialog?.default_prompt) || '';
    const needsInterview = kickstartDialog?.show_interview === false
        ? false
        : (document.getElementById('workflow-launch-interview')?.checked ?? true);
    const autoWorkflow = kickstartDialog?.show_auto_workflow === false
        ? true
        : (document.getElementById('workflow-launch-auto-workflow')?.checked ?? true);

    const skipPhases = [];
    document.querySelectorAll('.kickstart-phase-toggle:not(:checked)').forEach(cb => {
        skipPhases.push(cb.dataset.phaseId);
    });

    if (!prompt) {
        showToast('Please describe your project', 'warning');
        return;
    }

    // In-flight guard: prevent double submit while a previous request is still pending
    if (workflowLaunchSubmitting) {
        return;
    }
    workflowLaunchSubmitting = true;

    // Set loading state — keep the form visible with a disabled-looking submit button
    // while we decide whether preflight needs to run. This avoids a jarring
    // form → preflight → form flicker when no preflight checks are configured.
    if (submitBtn) {
        submitBtn.classList.add('loading');
        submitBtn.disabled = true;
    }

    preflightController?.abort();
    preflightController = new AbortController();
    const signal = preflightController.signal;

    try {
        // Fetch preflight checks in background — form phase is still visible
        const preResp = await fetch(`${API_BASE}/api/product/preflight`, { signal });
        const preflight = await preResp.json();
        const checks = preflight.checks || [];

        if (checks.length === 0) {
            // No preflight configured — skip the preflight phase entirely and
            // go straight to kickstart. The form stays visible with the submit
            // button disabled until executeWorkflowLaunch resolves and closes the modal.
            await executeWorkflowLaunch(prompt, needsInterview, autoWorkflow, skipPhases);
        } else {
            // Swap to the preflight phase now that we know we actually have checks to animate
            showPreflightPhaseChecking(prompt, needsInterview, autoWorkflow, skipPhases);
            await runPreflightAnimation(checks, preflight.success, prompt, needsInterview, autoWorkflow, skipPhases, signal);
        }
    } catch (error) {
        if (error.name === 'AbortError') return;
        console.error('Error during preflight:', error);
        resetToFormPhase();
        showToast('Error running preflight checks: ' + error.message, 'error');
        if (submitBtn) {
            submitBtn.classList.remove('loading');
            submitBtn.disabled = false;
        }
        workflowLaunchSubmitting = false;
    }
}

/**
 * Execute the actual kickstart POST request
 */
async function executeWorkflowLaunch(prompt, needsInterview, autoWorkflow, skipPhases = []) {
    // Belt-and-braces: if the preflight was aborted between the last
    // await and now, bail out before issuing the workflow POST.
    if (preflightController?.signal.aborted) return;

    const submitBtn = document.getElementById('workflow-launch-submit');

    // When launched from a per-workflow Run button, route through the task-runner
    // engine instead of the legacy kickstart engine
    if (workflowLaunchUseTaskRunner && workflowLaunchName) {
        try {
            const response = await fetch(`${API_BASE}/api/workflows/${encodeURIComponent(workflowLaunchName)}/run`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    prompt: prompt,
                    files: workflowLaunchFiles.map(f => ({
                        name: f.name,
                        content: f.content
                    }))
                })
            });

            const result = await response.json();

            if (result.success) {
                const wfName = workflowLaunchName;
                closeKickstartModal();
                showToast(`Workflow "${wfName}" started (${result.tasks_created} tasks)`, 'success', 8000);
                if (typeof pollState === 'function') await pollState();
            } else {
                showToast('Failed to start workflow: ' + (result.error || 'Unknown error'), 'error');
                if (submitBtn) {
                    submitBtn.classList.remove('loading');
                    submitBtn.disabled = false;
                }
                workflowLaunchSubmitting = false;
            }
        } catch (error) {
            console.error('Error starting workflow via task-runner:', error);
            showToast('Error starting workflow: ' + error.message, 'error');
            if (submitBtn) {
                submitBtn.classList.remove('loading');
                submitBtn.disabled = false;
            }
            workflowLaunchSubmitting = false;
        }
        return;
    }

    try {
        const response = await fetch(`${API_BASE}/api/product/kickstart`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                prompt: prompt,
                needs_interview: needsInterview,
                auto_workflow: autoWorkflow,
                skip_phases: skipPhases,
                workflow_name: workflowLaunchName || undefined,
                files: workflowLaunchFiles.map(f => ({
                    name: f.name,
                    content: f.content
                }))
            })
        });

        const result = await response.json();

        if (result.success) {
            closeKickstartModal();
            kickstartInProgress = true;
            kickstartProcessId = result.process_id || null;

            // Re-render CTAs to show in-progress state
            if (typeof updateExecutiveSummary === 'function') updateExecutiveSummary();
            const navContainer = document.getElementById('product-file-nav');
            if (navContainer) {
                delete navContainer.dataset.loaded;
                if (typeof updateProductFileNav === 'function') updateProductFileNav();
            }

            showToast('Kickstart initiated! Claude is creating your product documents...', 'success', 8000);
            startKickstartPolling();
        } else {
            showToast('Failed to kickstart: ' + (result.error || 'Unknown error'), 'error');
            if (submitBtn) {
                submitBtn.classList.remove('loading');
                submitBtn.disabled = false;
            }
            workflowLaunchSubmitting = false;
        }
    } catch (error) {
        console.error('Error starting kickstart:', error);
        showToast('Error starting kickstart: ' + error.message, 'error');
        if (submitBtn) {
            submitBtn.classList.remove('loading');
            submitBtn.disabled = false;
        }
        workflowLaunchSubmitting = false;
    }
}

/**
 * Show the preflight phase immediately with a "Checking..." spinner
 * before results arrive from the server.
 */
function showPreflightPhaseChecking(prompt, needsInterview, autoWorkflow, skipPhases = []) {
    const phaseForm = document.getElementById('workflow-launch-phase-form');
    const phasePreflight = document.getElementById('workflow-launch-phase-preflight');
    const footerForm = document.getElementById('workflow-launch-footer-form');
    const footerPreflight = document.getElementById('workflow-launch-footer-preflight');
    const checklist = document.getElementById('preflight-checklist');
    const footer = document.getElementById('preflight-footer');
    const backBtn = document.getElementById('workflow-launch-preflight-back');
    const retryBtn = document.getElementById('workflow-launch-preflight-retry');

    // Swap phases
    phaseForm.classList.add('hidden');
    phasePreflight.classList.remove('hidden');
    footerForm.classList.add('hidden');
    footerPreflight.classList.remove('hidden');
    retryBtn.classList.add('hidden');
    footer.innerHTML = '';

    // Show loading indicator
    checklist.innerHTML = `
        <div class="preflight-check revealed">
            <span class="led pulse"></span>
            <span class="preflight-check-label">Running preflight checks\u2026</span>
            <span class="preflight-check-status"></span>
        </div>
    `;

    // Bind back handler
    backBtn.onclick = resetToFormPhase;
}

/**
 * Animate preflight checks and, on success, fire executeWorkflowLaunch.
 * All delays are cancellable via `signal` so Back aborts cleanly.
 */
async function runPreflightAnimation(checks, allPassed, prompt, needsInterview, autoWorkflow, skipPhases, signal) {
    const phaseForm = document.getElementById('workflow-launch-phase-form');
    const phasePreflight = document.getElementById('workflow-launch-phase-preflight');
    const footerForm = document.getElementById('workflow-launch-footer-form');
    const footerPreflight = document.getElementById('workflow-launch-footer-preflight');
    const checklist = document.getElementById('preflight-checklist');
    const footer = document.getElementById('preflight-footer');
    const backBtn = document.getElementById('workflow-launch-preflight-back');
    const retryBtn = document.getElementById('workflow-launch-preflight-retry');

    // Ensure preflight phase is visible (no-op for initial flow, needed for retry)
    phaseForm.classList.add('hidden');
    phasePreflight.classList.remove('hidden');
    footerForm.classList.add('hidden');
    footerPreflight.classList.remove('hidden');
    retryBtn.classList.add('hidden');
    footer.innerHTML = '';

    checklist.innerHTML = checks.map((check, i) => `
        <div class="preflight-check" data-index="${i}">
            <span class="led off"></span>
            <span class="preflight-check-label">${escapeHtml(check.message || check.name)}</span>
            <span class="preflight-check-status"></span>
        </div>
        <div class="preflight-check-hint hidden" data-hint-index="${i}"></div>
    `).join('');

    backBtn.onclick = resetToFormPhase;
    retryBtn.onclick = () => retryPreflight(prompt, needsInterview, autoWorkflow, skipPhases);

    try {
        const rows = checklist.querySelectorAll('.preflight-check');

        // Staggered reveal (100ms apart)
        for (let i = 0; i < rows.length; i++) {
            await preflightSleep(i === 0 ? 0 : 100, signal);
            rows[i].classList.add('revealed');
        }

        await preflightSleep(200, signal);

        // Resolve each check at 400ms intervals
        for (let i = 0; i < checks.length; i++) {
            if (i > 0) await preflightSleep(400, signal);
            await resolvePreflightCheck(i, checks[i], signal);
        }

        await preflightSleep(200, signal);
        showPreflightResult(allPassed, footer);

        if (allPassed) {
            await preflightSleep(1500, signal);
            await executeWorkflowLaunch(prompt, needsInterview, autoWorkflow, skipPhases);
        } else {
            retryBtn.classList.remove('hidden');
        }
    } catch (error) {
        if (error.name !== 'AbortError') throw error;
        // Aborted by Back — resetToFormPhase already handled UI rollback.
    }
}

/**
 * Animate a single preflight check: LED off → pulse → green/red
 */
async function resolvePreflightCheck(index, check, signal) {
    const row = document.querySelector(`.preflight-check[data-index="${index}"]`);
    if (!row) return;

    const led = row.querySelector('.led');
    const status = row.querySelector('.preflight-check-status');
    const hintEl = document.querySelector(`.preflight-check-hint[data-hint-index="${index}"]`);

    // Pulse briefly
    led.classList.remove('off');
    led.classList.add('pulse');

    await preflightSleep(200, signal);
    led.classList.remove('pulse');

    if (check.passed) {
        row.classList.add('passed');
        row.setAttribute('data-type', 'success');
        status.textContent = 'PASS';
    } else {
        row.classList.add('failed');
        row.setAttribute('data-type', 'error');
        status.textContent = 'FAIL';

        if (hintEl && check.hint) {
            hintEl.textContent = '\u2192 ' + check.hint;
            hintEl.classList.remove('hidden');
        }
    }
}

/**
 * Show the "ALL SYSTEMS GO" or "PREFLIGHT FAILED" footer text
 */
function showPreflightResult(allPassed, footerEl) {
    if (allPassed) {
        footerEl.innerHTML = '<span class="preflight-footer-text success">ALL SYSTEMS GO</span>';
    } else {
        footerEl.innerHTML = '<span class="preflight-footer-text error">PREFLIGHT FAILED</span>';
    }
}

/**
 * Back button — return to form phase
 */
function resetToFormPhase() {
    // Abort any pending preflight animation/fetch — prevents executeWorkflowLaunch
    // from firing after Back is clicked. Controller not nulled so the
    // `signal.aborted` guard in executeWorkflowLaunch still sees it.
    preflightController?.abort();

    const phaseForm = document.getElementById('workflow-launch-phase-form');
    const phasePreflight = document.getElementById('workflow-launch-phase-preflight');
    const footerForm = document.getElementById('workflow-launch-footer-form');
    const footerPreflight = document.getElementById('workflow-launch-footer-preflight');
    const submitBtn = document.getElementById('workflow-launch-submit');

    phasePreflight.classList.add('hidden');
    phaseForm.classList.remove('hidden');
    footerPreflight.classList.add('hidden');
    footerForm.classList.remove('hidden');

    if (submitBtn) {
        submitBtn.classList.remove('loading');
        submitBtn.disabled = false;
    }

    // Clear the in-flight submit guard so returning to the form phase
    // (via Back button or error path) re-enables resubmission. Without this,
    // the flag set by submitKickstart() stays true forever and every
    // subsequent Kickstart click early-returns silently.
    workflowLaunchSubmitting = false;
}

/**
 * Retry preflight checks — re-fetch and re-animate
 */
async function retryPreflight(prompt, needsInterview, autoWorkflow, skipPhases = []) {
    preflightController?.abort();
    preflightController = new AbortController();
    const signal = preflightController.signal;

    try {
        const preResp = await fetch(`${API_BASE}/api/product/preflight`, { signal });
        const preflight = await preResp.json();
        const checks = preflight.checks || [];

        if (checks.length === 0) {
            await executeWorkflowLaunch(prompt, needsInterview, autoWorkflow, skipPhases);
        } else {
            await runPreflightAnimation(checks, preflight.success, prompt, needsInterview, autoWorkflow, skipPhases, signal);
        }
    } catch (error) {
        if (error.name === 'AbortError') return;
        showToast('Error retrying preflight: ' + error.message, 'error');
    }
}

/**
 * Start polling for kickstart/analyse process completion.
 * The main 3-second state poll (ui-updates.js) handles refreshing the sidebar
 * as product docs appear via product_docs count tracking. This polling just
 * monitors whether the background process is still running so we can finalize
 * the in-progress CTA and show completion toasts.
 */
function startKickstartPolling() {
    if (kickstartPolling) clearInterval(kickstartPolling);

    let attempts = 0;
    const maxAttempts = 120; // 10 minutes at 5s intervals
    let docsAppeared = false;

    kickstartPolling = setInterval(async () => {
        attempts++;
        if (attempts > maxAttempts) {
            clearInterval(kickstartPolling);
            kickstartPolling = null;
            kickstartInProgress = false;
            isNewProject = false;
            if (typeof updateExecutiveSummary === 'function') updateExecutiveSummary();
            return;
        }

        try {
            // Check if the background process is still running
            let processStillRunning = false;
            if (kickstartProcessId) {
                const procResp = await fetch(`${API_BASE}/api/processes`);
                if (procResp.ok) {
                    const procData = await procResp.json();
                    const procs = procData.processes || [];
                    processStillRunning = procs.some(
                        p => p.id === kickstartProcessId && (p.status === 'running' || p.status === 'starting')
                    );
                }
            }

            // Check if docs have appeared (for toast messaging)
            if (!docsAppeared) {
                const response = await fetch(`${API_BASE}/api/product/list`);
                if (response.ok) {
                    const data = await response.json();
                    const docs = data.docs || [];
                    if (docs.length > 0) {
                        docsAppeared = true;
                        isNewProject = false;
                    }
                }
            }

            // Process finished — finalize
            if (!processStillRunning && (docsAppeared || attempts > 5)) {
                clearInterval(kickstartPolling);
                kickstartPolling = null;
                kickstartInProgress = false;
                isNewProject = false;

                if (typeof updateExecutiveSummary === 'function') updateExecutiveSummary();

                if (analyseInProgress) {
                    analyseInProgress = false;
                    showToast('Product documents created from your codebase!', 'success');
                } else if (docsAppeared) {
                    showToast('Product documents created! Now planning roadmap...', 'success');
                    startRoadmapPolling();
                }
            }
        } catch (error) {
            // Silently continue polling
        }
    }, 5000);
}

/**
 * Open the analyse modal
 */
function openAnalyseModal() {
    const modal = document.getElementById('analyse-modal');
    const textarea = document.getElementById('analyse-prompt');

    if (modal) {
        modal.classList.add('visible');
        setTimeout(() => textarea?.focus(), 100);
    }
}

/**
 * Close the analyse modal and reset form
 */
function closeAnalyseModal() {
    const modal = document.getElementById('analyse-modal');
    const textarea = document.getElementById('analyse-prompt');
    const submitBtn = document.getElementById('analyse-submit');

    if (modal) {
        modal.classList.remove('visible');
        if (textarea) textarea.value = '';
        if (submitBtn) {
            submitBtn.classList.remove('loading');
            submitBtn.disabled = false;
        }
    }
}

/**
 * Submit the analyse request to the backend
 */
async function submitAnalyse() {
    const textarea = document.getElementById('analyse-prompt');
    const modelSelect = document.getElementById('analyse-model');
    const submitBtn = document.getElementById('analyse-submit');

    const prompt = textarea?.value?.trim() || '';
    const model = modelSelect?.value || 'Sonnet';

    // Set loading state
    if (submitBtn) {
        submitBtn.classList.add('loading');
        submitBtn.disabled = true;
    }

    try {
        const response = await fetch(`${API_BASE}/api/product/analyse`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ prompt, model })
        });

        const result = await response.json();

        if (result.success) {
            closeAnalyseModal();
            kickstartInProgress = true;
            analyseInProgress = true;

            // Re-render CTAs to show in-progress state
            if (typeof updateExecutiveSummary === 'function') updateExecutiveSummary();
            const navContainer = document.getElementById('product-file-nav');
            if (navContainer) {
                delete navContainer.dataset.loaded;
                if (typeof updateProductFileNav === 'function') updateProductFileNav();
            }

            showToast('Analyse initiated! Claude is scanning your codebase...', 'success', 8000);
            startKickstartPolling();
        } else {
            showToast('Failed to analyse: ' + (result.error || 'Unknown error'), 'error');
            if (submitBtn) {
                submitBtn.classList.remove('loading');
                submitBtn.disabled = false;
            }
        }
    } catch (error) {
        console.error('Error starting analyse:', error);
        showToast('Error starting analyse: ' + error.message, 'error');
        if (submitBtn) {
            submitBtn.classList.remove('loading');
            submitBtn.disabled = false;
        }
    }
}

/**
 * Poll for task creation after roadmap planning
 * Watches /api/state for tasks to appear (todo > 0)
 */
function startRoadmapPolling() {
    if (roadmapPolling) clearInterval(roadmapPolling);

    let attempts = 0;
    const maxAttempts = 120; // 10 minutes at 5s intervals

    roadmapPolling = setInterval(async () => {
        attempts++;
        if (attempts > maxAttempts) {
            clearInterval(roadmapPolling);
            roadmapPolling = null;
            showToast('Roadmap planning is taking longer than expected. Check the Pipeline tab for progress.', 'warning', 10000);
            return;
        }

        try {
            const response = await fetch(`${API_BASE}/api/state`);
            if (!response.ok) return;

            const state = await response.json();

            if (state.tasks && state.tasks.todo > 0) {
                clearInterval(roadmapPolling);
                roadmapPolling = null;

                const taskCount = state.tasks.todo;
                showToast(`Roadmap created! ${taskCount} task${taskCount !== 1 ? 's' : ''} ready in the pipeline.`, 'success', 10000);

                // Refresh product nav to show roadmap-overview.md
                const navContainer = document.getElementById('product-file-nav');
                if (navContainer) delete navContainer.dataset.loaded;
                if (typeof updateProductFileNav === 'function') {
                    updateProductFileNav();
                }
            }
        } catch (error) {
            // Silently continue polling
        }
    }, 5000);
}

/**
 * Resume an incomplete kickstart from the next pending/failed phase (legacy)
 */
async function resumeKickstart() {
    try {
        const response = await fetch(`${API_BASE}/api/product/kickstart/resume`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' }
        });

        const result = await response.json();

        if (result.success) {
            kickstartInProgress = true;
            kickstartProcessId = result.process_id || null;
            showToast(`Kickstart resuming from "${result.resume_from}"...`, 'success', 8000);
            startKickstartPolling();
        } else {
            showToast('Failed to resume: ' + (result.error || 'Unknown error'), 'error');
        }
    } catch (error) {
        console.error('Error resuming kickstart:', error);
        showToast('Error resuming kickstart: ' + error.message, 'error');
    }
}

/**
 * Resume a workflow by launching a task-runner in continue mode.
 * Uses /api/process/launch — no new backend endpoint needed.
 */
async function resumeWorkflow(workflowName) {
    try {
        const response = await fetch(`${API_BASE}/api/process/launch`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                type: 'task-runner',
                continue: true,
                workflow_name: workflowName,
                description: `Resume workflow: ${workflowName}`
            })
        });

        const result = await response.json();

        if (result.success) {
            showToast(`Workflow "${workflowName}" resuming...`, 'success', 8000);
        } else {
            showToast('Failed to resume: ' + (result.error || 'Unknown error'), 'error');
        }
    } catch (error) {
        console.error('Error resuming workflow:', error);
        showToast('Error resuming workflow: ' + error.message, 'error');
    }
}

/**
 * Build side panel data from /api/state — single source of truth.
 * Returns an array of workflow objects, each with tasks (priority-sorted),
 * counts, and resume state. Workflows are sorted alphabetically for
 * stable display ordering.
 *
 * Returns: [{ workflow_name, tasks, counts, can_resume, status }, ...] or null
 */
function buildWorkflowPanelData(state) {
    if (!state || !state.workflows) return null;

    const wfNames = Object.keys(state.workflows).sort();
    const results = [];

    // Collect all tasks from state.tasks lists into a flat array
    const taskLists = [
        { list: state.tasks.current ? [state.tasks.current] : [], status: null },
        { list: state.tasks.upcoming || [], status: 'todo' },
        { list: state.tasks.analysed_list || [], status: 'analysed' },
        { list: state.tasks.analysing_list || [], status: 'analysing' },
        { list: state.tasks.needs_input_list || [], status: 'needs-input' },
        { list: state.tasks.recent_completed || [], status: 'done' },
        { list: state.tasks.skipped_list || [], status: 'skipped' }
    ];

    for (const wfName of wfNames) {
        const wf = state.workflows[wfName];
        if (!wf || wf.total === 0) continue;

        // Collect tasks for this workflow
        const allTasks = [];
        const seenIds = new Set();
        for (const { list, status } of taskLists) {
            for (const task of list) {
                if (!task || !task.id) continue;
                if (task.workflow !== wfName) continue;
                if (seenIds.has(task.id)) continue;
                seenIds.add(task.id);
                allTasks.push({
                    id: task.id,
                    name: task.name,
                    status: task.status || status,
                    priority: task.priority != null ? parseInt(task.priority) : 99
                });
            }
        }

        allTasks.sort((a, b) => {
            const priorityDiff = a.priority - b.priority;
            if (priorityDiff !== 0) return priorityDiff;
            const nameDiff = String(a.name || '').localeCompare(String(b.name || ''));
            if (nameDiff !== 0) return nameDiff;
            return String(a.id).localeCompare(String(b.id));
        });

        // Determine resume state
        const pending = (wf.todo || 0) + (wf.analysing || 0) + (wf.needs_input || 0) +
                        (wf.analysed || 0) + (wf.in_progress || 0);
        const processRunning = !!wf.process_alive;
        const allDone = pending === 0 && wf.total > 0;

        let panelStatus, canResume;
        if (processRunning) {
            panelStatus = 'running';
            canResume = false;
        } else if (allDone) {
            panelStatus = 'completed';
            canResume = false;
        } else if (pending > 0) {
            panelStatus = 'incomplete';
            canResume = true;
        } else {
            panelStatus = 'not-started';
            canResume = false;
        }

        results.push({
            workflow_name: wfName,
            tasks: allTasks,
            counts: wf,
            status: panelStatus,
            can_resume: canResume
        });
    }

    if (results.length === 0) return null;

    // Stable alphabetical order (running state only affects expand/collapse, not position)
    results.sort((a, b) => a.workflow_name.localeCompare(b.workflow_name));

    return results;
}

/**
 * Render workflow task panel on the Overview tab (multi-workflow accordion).
 * Each workflow gets a collapsible section with its own task list, progress bar,
 * and Resume button. Running workflows are expanded by default, others collapsed.
 * Data comes from /api/state (via buildWorkflowPanelData), not a separate endpoint.
 *
 * @param {Array} workflows - Array of workflow objects from buildWorkflowPanelData
 */
function renderOverviewKickstartPhases(workflows) {
    const container = document.getElementById('overview-kickstart-phases');
    const sidePanel = document.getElementById('overview-side-panel');
    if (!container || !sidePanel || !workflows || workflows.length === 0) {
        if (sidePanel) sidePanel.style.display = 'none';
        return;
    }

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

    // Preserve per-workflow collapsed state from previous render
    const prevCollapsed = {};
    container.querySelectorAll('.wf-accordion-section').forEach(section => {
        const name = section.dataset.workflow;
        if (name) prevCollapsed[name] = section.classList.contains('collapsed');
    });

    // Aggregate totals for header
    let totalDone = 0, totalAll = 0;
    workflows.forEach(wf => {
        const c = wf.counts || {};
        totalDone += (c.done || 0) + (c.skipped || 0);
        totalAll += c.total || 0;
    });

    let html = '';

    workflows.forEach((wf, idx) => {
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
            isCollapsed = false; // Single workflow always expanded
        } else {
            isCollapsed = wf.status !== 'running' && wf.status !== 'incomplete';
        }

        const statusLed = wf.status === 'running'
            ? '<span class="led pulse" style="margin-right:6px"></span>'
            : '';

        html += `
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
            html += `
                        <div class="chain-layer-item child-task-item child-task-${task.status}">
                            ${icon}
                            <span class="item-name">${escapeHtml(task.name)}</span>
                        </div>
            `;
        });

        html += `
                    </div>
        `;

        // Resume button per workflow
        if (wf.status === 'running') {
            html += `<div class="kickstart-resume-row"><button class="kickstart-resume-btn" disabled>RUNNING...</button></div>`;
        } else if (wf.can_resume) {
            html += `<div class="kickstart-resume-row"><button class="kickstart-resume-btn" data-resume-wf="${escapeAttr(wf.workflow_name)}">RESUME</button></div>`;
        } else if (wf.status === 'completed') {
            html += `<div class="kickstart-resume-row"><button class="kickstart-resume-btn" disabled>COMPLETED</button></div>`;
        }

        html += `
                </div>
            </div>
        `;
    });

    container.innerHTML = html;
    sidePanel.style.display = 'flex';

    // Update side panel header with aggregate counts
    const sideTitleEl = document.getElementById('overview-side-title');
    if (sideTitleEl) {
        sideTitleEl.textContent = workflows.length === 1
            ? (workflows[0].workflow_name || 'Workflow Progress')
            : 'Workflow Progress';
    }
    const sideCountEl = document.getElementById('overview-side-count');
    if (sideCountEl) {
        sideCountEl.textContent = `${totalDone}/${totalAll}`;
    }

    // Accordion collapse/expand handlers
    container.querySelectorAll('.wf-accordion-header').forEach(header => {
        header.addEventListener('click', () => {
            header.closest('.wf-accordion-section').classList.toggle('collapsed');
        });
    });

    // Resume button handlers (data-attribute based, no inline onclick)
    container.querySelectorAll('.kickstart-resume-btn[data-resume-wf]').forEach(btn => {
        btn.addEventListener('click', () => {
            resumeWorkflow(btn.dataset.resumeWf);
        });
    });

    // Bind side-panel header toggle (once)
    const panelHeader = document.getElementById('overview-side-toggle');
    if (panelHeader && !panelHeader.dataset.bound) {
        panelHeader.dataset.bound = '1';
        panelHeader.addEventListener('click', () => {
            sidePanel.classList.toggle('collapsed');
        });
    }
}
