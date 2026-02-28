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
 * Shows "KICKSTART PROJECT" for greenfield or "ANALYSE PROJECT" for existing code
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
        if (submitBtn) {
            submitBtn.classList.remove('loading');
            submitBtn.disabled = false;
        }
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
 * Submit the kickstart request to the backend
 */
async function submitKickstart() {
    const textarea = document.getElementById('kickstart-prompt');
    const submitBtn = document.getElementById('kickstart-submit');

    const prompt = textarea?.value?.trim();
    const needsInterview = document.getElementById('kickstart-interview')?.checked ?? true;

    if (!prompt) {
        showToast('Please describe your project', 'warning');
        return;
    }

    // Set loading state
    if (submitBtn) {
        submitBtn.classList.add('loading');
        submitBtn.disabled = true;
    }

    try {
        const response = await fetch(`${API_BASE}/api/product/kickstart`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                prompt: prompt,
                needs_interview: needsInterview,
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
