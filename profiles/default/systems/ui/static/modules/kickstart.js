/**
 * DOTBOT Control Panel - Kickstart Module
 * Handles new project detection and kickstart flow
 */

// State
let isNewProject = false;
let kickstartInProgress = false;
let analyseInProgress = false;
let kickstartFiles = [];       // { name, size, content (base64) }
let kickstartProcessId = null; // process_id returned from backend
let kickstartPolling = null;   // interval ID for doc appearance detection
let roadmapPolling = null;     // interval ID for task creation detection
let kickstartDialog = null;    // profile-driven dialog config from /api/info
let kickstartPhases = [];      // profile-driven phases from /api/info

/**
 * Initialize kickstart functionality
 * Checks if this is a new project and sets up event handlers
 */
async function initKickstart() {
    try {
        const response = await fetch(`${API_BASE}/api/product/list`);
        if (response.ok) {
            const data = await response.json();
            const docs = data.docs || [];
            isNewProject = docs.length === 0;
        }
    } catch (error) {
        console.warn('Could not check product docs for kickstart:', error);
    }

    // Now that isNewProject is set, re-trigger executive summary display
    if (isNewProject && typeof updateExecutiveSummary === 'function') {
        updateExecutiveSummary();
    }

    // Apply profile-driven dialog text from /api/info
    try {
        const infoResp = await fetch(`${API_BASE}/api/info`);
        if (infoResp.ok) {
            const info = await infoResp.json();
            kickstartDialog = info.kickstart_dialog || null;
            kickstartPhases = info.kickstart_phases || [];
            const dialog = kickstartDialog;
            if (dialog) {
                const descEl = document.getElementById('kickstart-description');
                const labelEl = document.getElementById('kickstart-interview-label');
                const hintEl = document.getElementById('kickstart-interview-hint');
                const promptEl = document.getElementById('kickstart-prompt');
                if (descEl && dialog.description) descEl.textContent = dialog.description;
                if (labelEl && dialog.interview_label) labelEl.textContent = dialog.interview_label;
                if (hintEl && dialog.interview_hint) hintEl.textContent = dialog.interview_hint;
                if (promptEl && dialog.prompt_placeholder) promptEl.placeholder = dialog.prompt_placeholder;
            }

            // Re-render executive summary now that dialog/phases are loaded
            if (typeof updateExecutiveSummary === 'function') {
                updateExecutiveSummary();
            }

            // Render phase checklist
            const phases = kickstartPhases;
            const container = document.getElementById('kickstart-phases-container');
            const wrapper = document.getElementById('kickstart-phase-list');
            if (container && phases.length > 0) {
                wrapper.style.display = 'block';
                container.innerHTML = phases.map(p => {
                    if (p.optional) {
                        return `<div class="phase-item">
                            <label class="form-checkbox-label">
                                <input type="checkbox" class="kickstart-phase-toggle" data-phase-id="${p.id}" checked>
                                <span class="form-checkbox-text">${p.name}</span>
                            </label>
                        </div>`;
                    } else {
                        return `<div class="phase-item phase-fixed">
                            <span class="phase-bullet">\u203a</span>
                            <span class="form-checkbox-text">${p.name}</span>
                        </div>`;
                    }
                }).join('');
            }
        }
    } catch (error) {
        console.warn('Could not load kickstart dialog config:', error);
    }

    // Bind kickstart modal handlers
    const modal = document.getElementById('kickstart-modal');
    const closeBtn = document.getElementById('kickstart-modal-close');
    const cancelBtn = document.getElementById('kickstart-cancel');
    const submitBtn = document.getElementById('kickstart-submit');
    const textarea = document.getElementById('kickstart-prompt');
    const dropzone = document.getElementById('kickstart-dropzone');
    const fileInput = document.getElementById('kickstart-file-input');

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
 * Shows workflow-specific CTA if a profile with phases is active,
 * otherwise "KICKSTART PROJECT" for greenfield or "ANALYSE PROJECT" for existing code
 * @param {HTMLElement} container - Container to render into
 */
function renderKickstartCTA(container) {
    if (kickstartInProgress) {
        const label = hasExistingCode ? 'Analyse In Progress' : 'Kickstart In Progress';
        const desc = hasExistingCode
            ? 'Scanning your codebase and creating product documents. Check the Processes tab for details.'
            : 'Creating product documents, task groups, and roadmap. Check the Processes tab for details.';
        container.innerHTML = `
            <div class="kickstart-cta in-progress">
                <div class="kickstart-glyph">◈</div>
                <div class="kickstart-title">${label}</div>
                <div class="kickstart-description">${desc}</div>
            </div>
        `;
        return;
    }

    // Workflow profile with phases — show profile-specific CTA instead of generic analyse
    if (kickstartDialog && kickstartPhases.length > 0) {
        const title = currentProfileName || 'Workflow';
        const desc = kickstartDialog.description || 'Run the configured workflow.';
        const phaseList = kickstartPhases.map(p =>
            `<div class="phase-item phase-fixed"><span class="phase-bullet">\u203a</span> ${escapeHtml(p.name)}</div>`
        ).join('');
        container.innerHTML = `
            <div class="kickstart-cta">
                <div class="kickstart-glyph">◈</div>
                <div class="kickstart-title">${escapeHtml(title)}</div>
                <div class="kickstart-description">${escapeHtml(desc)}</div>
                <div class="kickstart-phase-preview">${phaseList}</div>
                <button class="kickstart-btn" onclick="openKickstartModal()">RUN WORKFLOW</button>
            </div>
        `;
        return;
    }

    if (hasExistingCode) {
        container.innerHTML = `
            <div class="kickstart-cta">
                <div class="kickstart-glyph">◈</div>
                <div class="kickstart-title">Existing Project</div>
                <div class="kickstart-description">
                    Let Claude scan your codebase and generate foundational product documents — mission, tech stack, and entity model.
                </div>
                <button class="kickstart-btn" onclick="openAnalyseModal()">ANALYSE PROJECT</button>
            </div>
        `;
    } else {
        container.innerHTML = `
            <div class="kickstart-cta">
                <div class="kickstart-glyph">◈</div>
                <div class="kickstart-title">New Project</div>
                <div class="kickstart-description">
                    Describe your project and let Claude create your foundational product documents — mission, tech stack, and entity model.
                </div>
                <button class="kickstart-btn" onclick="openKickstartModal()">KICKSTART PROJECT</button>
            </div>
        `;
    }
}

/**
 * Open the kickstart modal
 */
function openKickstartModal() {
    const modal = document.getElementById('kickstart-modal');
    const textarea = document.getElementById('kickstart-prompt');

    if (modal) {
        modal.classList.add('visible');
        setTimeout(() => textarea?.focus(), 100);
    }
}

/**
 * Close the kickstart modal and reset form
 */
function closeKickstartModal() {
    const modal = document.getElementById('kickstart-modal');
    const textarea = document.getElementById('kickstart-prompt');
    const submitBtn = document.getElementById('kickstart-submit');

    if (modal) {
        modal.classList.remove('visible');
        if (textarea) textarea.value = '';
        kickstartFiles = [];
        updateFileList();
        const interviewCheckbox = document.getElementById('kickstart-interview');
        if (interviewCheckbox) interviewCheckbox.checked = true;
        const awCheckbox = document.getElementById('kickstart-auto-workflow');
        if (awCheckbox) awCheckbox.checked = true;
        if (submitBtn) {
            submitBtn.classList.remove('loading');
            submitBtn.disabled = false;
        }

        // Reset to form phase in case we were on preflight
        const phaseForm = document.getElementById('kickstart-phase-form');
        const phasePreflight = document.getElementById('kickstart-phase-preflight');
        const footerForm = document.getElementById('kickstart-footer-form');
        const footerPreflight = document.getElementById('kickstart-footer-preflight');
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
        if (kickstartFiles.some(f => f.name === file.name)) {
            showToast(`File "${file.name}" already added`, 'warning');
            continue;
        }

        // Read as base64
        const reader = new FileReader();
        reader.onload = (e) => {
            // readAsDataURL gives "data:...;base64,XXXXX" — extract just the base64 part
            const base64 = e.target.result.split(',')[1];
            kickstartFiles.push({
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
 * Re-render the file list from kickstartFiles[]
 */
function updateFileList() {
    const container = document.getElementById('kickstart-file-list');
    if (!container) return;

    if (kickstartFiles.length === 0) {
        container.innerHTML = '';
        return;
    }

    container.innerHTML = kickstartFiles.map((file, index) => {
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
 * @param {number} index - Index in kickstartFiles array
 */
function removeKickstartFile(index) {
    kickstartFiles.splice(index, 1);
    updateFileList();
}

/**
 * Submit the kickstart request — runs preflight checks first
 */
async function submitKickstart() {
    const textarea = document.getElementById('kickstart-prompt');
    const submitBtn = document.getElementById('kickstart-submit');

    const prompt = textarea?.value?.trim();
    const needsInterview = document.getElementById('kickstart-interview')?.checked ?? true;
    const autoWorkflow = document.getElementById('kickstart-auto-workflow')?.checked ?? true;

    const skipPhases = [];
    document.querySelectorAll('.kickstart-phase-toggle:not(:checked)').forEach(cb => {
        skipPhases.push(cb.dataset.phaseId);
    });

    if (!prompt) {
        showToast('Please describe your project', 'warning');
        return;
    }

    // Set loading state
    if (submitBtn) {
        submitBtn.classList.add('loading');
        submitBtn.disabled = true;
    }

    // Show preflight modal immediately with "Checking..." state
    showPreflightPhaseChecking(prompt, needsInterview, autoWorkflow, skipPhases);

    try {
        // Fetch preflight checks in background
        const preResp = await fetch(`${API_BASE}/api/product/preflight`);
        const preflight = await preResp.json();
        const checks = preflight.checks || [];

        if (checks.length === 0) {
            // No preflight configured — go straight to kickstart
            resetToFormPhase();
            await executeKickstart(prompt, needsInterview, autoWorkflow, skipPhases);
        } else {
            // Update preflight phase with real results and animate
            updatePreflightWithResults(checks, preflight.success, prompt, needsInterview, autoWorkflow, skipPhases);
        }
    } catch (error) {
        console.error('Error during preflight:', error);
        resetToFormPhase();
        showToast('Error running preflight checks: ' + error.message, 'error');
        if (submitBtn) {
            submitBtn.classList.remove('loading');
            submitBtn.disabled = false;
        }
    }
}

/**
 * Execute the actual kickstart POST request
 */
async function executeKickstart(prompt, needsInterview, autoWorkflow, skipPhases = []) {
    const submitBtn = document.getElementById('kickstart-submit');

    try {
        const response = await fetch(`${API_BASE}/api/product/kickstart`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                prompt: prompt,
                needs_interview: needsInterview,
                auto_workflow: autoWorkflow,
                skip_phases: skipPhases,
                files: kickstartFiles.map(f => ({
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
        }
    } catch (error) {
        console.error('Error starting kickstart:', error);
        showToast('Error starting kickstart: ' + error.message, 'error');
        if (submitBtn) {
            submitBtn.classList.remove('loading');
            submitBtn.disabled = false;
        }
    }
}

/**
 * Show the preflight phase immediately with a "Checking..." spinner
 * before results arrive from the server.
 */
function showPreflightPhaseChecking(prompt, needsInterview, autoWorkflow, skipPhases = []) {
    const phaseForm = document.getElementById('kickstart-phase-form');
    const phasePreflight = document.getElementById('kickstart-phase-preflight');
    const footerForm = document.getElementById('kickstart-footer-form');
    const footerPreflight = document.getElementById('kickstart-footer-preflight');
    const checklist = document.getElementById('preflight-checklist');
    const footer = document.getElementById('preflight-footer');
    const backBtn = document.getElementById('kickstart-preflight-back');
    const retryBtn = document.getElementById('kickstart-preflight-retry');

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
 * Update preflight phase with real results after server responds
 */
function updatePreflightWithResults(checks, allPassed, prompt, needsInterview, autoWorkflow, skipPhases = []) {
    const checklist = document.getElementById('preflight-checklist');
    const footer = document.getElementById('preflight-footer');
    const retryBtn = document.getElementById('kickstart-preflight-retry');
    const backBtn = document.getElementById('kickstart-preflight-back');

    // Replace loading indicator with actual check rows
    checklist.innerHTML = checks.map((check, i) => `
        <div class="preflight-check" data-index="${i}">
            <span class="led off"></span>
            <span class="preflight-check-label">${escapeHtml(check.message || check.name)}</span>
            <span class="preflight-check-status"></span>
        </div>
        <div class="preflight-check-hint hidden" data-hint-index="${i}"></div>
    `).join('');

    // Staggered reveal of rows (100ms apart)
    const rows = checklist.querySelectorAll('.preflight-check');
    rows.forEach((row, i) => {
        setTimeout(() => row.classList.add('revealed'), i * 100);
    });

    // After all revealed, resolve each at 400ms intervals
    const revealDone = rows.length * 100 + 200;
    checks.forEach((check, i) => {
        setTimeout(() => resolvePreflightCheck(i, check), revealDone + i * 400);
    });

    // Show result after all resolved
    const totalTime = revealDone + checks.length * 400 + 200;
    setTimeout(() => {
        showPreflightResult(allPassed, footer);
        if (allPassed) {
            // Auto-submit after 1.5s
            setTimeout(() => executeKickstart(prompt, needsInterview, autoWorkflow, skipPhases), 1500);
        } else {
            retryBtn.classList.remove('hidden');
        }
    }, totalTime);

    // Bind handlers
    backBtn.onclick = resetToFormPhase;
    retryBtn.onclick = () => retryPreflight(prompt, needsInterview, autoWorkflow, skipPhases);
}

/**
 * Show the preflight checklist phase with staggered animation (used by retry)
 */
function showPreflightPhase(checks, allPassed, prompt, needsInterview, autoWorkflow, skipPhases = []) {
    const phaseForm = document.getElementById('kickstart-phase-form');
    const phasePreflight = document.getElementById('kickstart-phase-preflight');
    const footerForm = document.getElementById('kickstart-footer-form');
    const footerPreflight = document.getElementById('kickstart-footer-preflight');
    const checklist = document.getElementById('preflight-checklist');
    const footer = document.getElementById('preflight-footer');
    const backBtn = document.getElementById('kickstart-preflight-back');
    const retryBtn = document.getElementById('kickstart-preflight-retry');

    // Swap phases
    phaseForm.classList.add('hidden');
    phasePreflight.classList.remove('hidden');
    footerForm.classList.add('hidden');
    footerPreflight.classList.remove('hidden');
    retryBtn.classList.add('hidden');
    footer.innerHTML = '';

    // Render check rows with dim LEDs
    checklist.innerHTML = checks.map((check, i) => `
        <div class="preflight-check" data-index="${i}">
            <span class="led off"></span>
            <span class="preflight-check-label">${escapeHtml(check.message || check.name)}</span>
            <span class="preflight-check-status"></span>
        </div>
        <div class="preflight-check-hint hidden" data-hint-index="${i}"></div>
    `).join('');

    // Staggered reveal of rows (100ms apart)
    const rows = checklist.querySelectorAll('.preflight-check');
    rows.forEach((row, i) => {
        setTimeout(() => row.classList.add('revealed'), i * 100);
    });

    // After all revealed, resolve each at 400ms intervals
    const revealDone = rows.length * 100 + 200;
    checks.forEach((check, i) => {
        setTimeout(() => resolvePreflightCheck(i, check), revealDone + i * 400);
    });

    // Show result after all resolved
    const totalTime = revealDone + checks.length * 400 + 200;
    setTimeout(() => {
        showPreflightResult(allPassed, footer);
        if (allPassed) {
            // Auto-submit after 1.5s
            setTimeout(() => executeKickstart(prompt, needsInterview, autoWorkflow, skipPhases), 1500);
        } else {
            retryBtn.classList.remove('hidden');
        }
    }, totalTime);

    // Bind handlers
    backBtn.onclick = resetToFormPhase;
    retryBtn.onclick = () => retryPreflight(prompt, needsInterview, autoWorkflow, skipPhases);
}

/**
 * Animate a single preflight check: LED off → pulse → green/red
 */
function resolvePreflightCheck(index, check) {
    const row = document.querySelector(`.preflight-check[data-index="${index}"]`);
    if (!row) return;

    const led = row.querySelector('.led');
    const status = row.querySelector('.preflight-check-status');
    const hintEl = document.querySelector(`.preflight-check-hint[data-hint-index="${index}"]`);

    // Pulse briefly
    led.classList.remove('off');
    led.classList.add('pulse');

    setTimeout(() => {
        led.classList.remove('pulse');

        if (check.passed) {
            row.classList.add('passed');
            row.setAttribute('data-type', 'success');
            status.textContent = 'PASS';
        } else {
            row.classList.add('failed');
            row.setAttribute('data-type', 'error');
            status.textContent = 'FAIL';

            // Show hint below
            if (hintEl && check.hint) {
                hintEl.textContent = '\u2192 ' + check.hint;
                hintEl.classList.remove('hidden');
            }
        }
    }, 200);
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
    const phaseForm = document.getElementById('kickstart-phase-form');
    const phasePreflight = document.getElementById('kickstart-phase-preflight');
    const footerForm = document.getElementById('kickstart-footer-form');
    const footerPreflight = document.getElementById('kickstart-footer-preflight');
    const submitBtn = document.getElementById('kickstart-submit');

    phasePreflight.classList.add('hidden');
    phaseForm.classList.remove('hidden');
    footerPreflight.classList.add('hidden');
    footerForm.classList.remove('hidden');

    if (submitBtn) {
        submitBtn.classList.remove('loading');
        submitBtn.disabled = false;
    }
}

/**
 * Retry preflight checks — re-fetch and re-animate
 */
async function retryPreflight(prompt, needsInterview, autoWorkflow, skipPhases = []) {
    try {
        const preResp = await fetch(`${API_BASE}/api/product/preflight`);
        const preflight = await preResp.json();
        const checks = preflight.checks || [];

        if (checks.length === 0) {
            await executeKickstart(prompt, needsInterview, autoWorkflow, skipPhases);
        } else {
            showPreflightPhase(checks, preflight.success, prompt, needsInterview, autoWorkflow, skipPhases);
        }
    } catch (error) {
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
 * Resume an incomplete kickstart from the next pending/failed phase
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
 * Render kickstart phases panel on the Overview tab
 * Same visual pattern as the Workflow version but targets #overview-kickstart-phases
 */
function renderOverviewKickstartPhases(data) {
    const container = document.getElementById('overview-kickstart-phases');
    const sidePanel = document.getElementById('overview-side-panel');
    if (!container || !sidePanel || !data || !data.phases || data.phases.length === 0) {
        if (sidePanel) sidePanel.style.display = 'none';
        return;
    }

    const completedCount = data.phases.filter(p => p.status === 'completed').length;
    const totalCount = data.phases.length;

    const statusIcons = {
        completed: '<span class="phase-icon phase-completed">&#10003;</span>',
        running:   '<span class="phase-icon phase-running">&#9679;</span>',
        failed:    '<span class="phase-icon phase-failed">&#10007;</span>',
        skipped:   '<span class="phase-icon phase-skipped">&#8211;</span>',
        pending:   '<span class="phase-icon phase-pending">&#9675;</span>',
        incomplete:'<span class="phase-icon phase-failed">&#9675;</span>'
    };

    // Preserve collapsed state of inner phases section
    const existing = container.querySelector('.kickstart-phases');
    const wasCollapsed = existing ? existing.classList.contains('collapsed') : false;

    let html = `
        <div class="kickstart-phases${wasCollapsed ? ' collapsed' : ''}">
            <div class="chain-layer-header" data-layer="overview-kickstart-phases">
                <span class="chain-layer-title">Kickstart Phases</span>
                <span class="chain-layer-count">${completedCount}/${totalCount}</span>
            </div>
            <div class="chain-layer-items">
    `;

    data.phases.forEach(phase => {
        const icon = statusIcons[phase.status] || statusIcons.pending;
        html += `
            <div class="chain-layer-item kickstart-phase-item kickstart-phase-${phase.status}">
                ${icon}
                <span class="item-name">${escapeHtml(phase.name)}</span>
            </div>
        `;
    });

    if (data.status === 'incomplete' && data.resume_from) {
        html += `
            <div class="kickstart-resume-row">
                <button class="kickstart-resume-btn" onclick="resumeKickstart()">RESUME</button>
            </div>
        `;
    }

    html += `
            </div>
        </div>
    `;

    container.innerHTML = html;
    sidePanel.style.display = 'flex';

    // Add collapse/expand handler for inner phases section
    const phaseHeader = container.querySelector('.kickstart-phases .chain-layer-header');
    if (phaseHeader) {
        phaseHeader.addEventListener('click', () => {
            phaseHeader.closest('.kickstart-phases').classList.toggle('collapsed');
        });
    }

    // Bind side-panel header toggle (once)
    const panelHeader = document.getElementById('overview-side-toggle');
    if (panelHeader && !panelHeader.dataset.bound) {
        panelHeader.dataset.bound = '1';
        panelHeader.addEventListener('click', () => {
            sidePanel.classList.toggle('collapsed');
        });
    }
}
