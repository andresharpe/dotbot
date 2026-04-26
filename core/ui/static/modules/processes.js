/**
 * DOTBOT Control Panel - Processes Module
 * Manages the Processes tab: listing, launching, stopping, and whispering to processes
 */

// Process state
let processesData = [];
let processPollingTimer = null;
let expandedProcessId = null;
let processOutputPositions = {};  // Track output position per process
let processOutputCache = {};      // Cache events per process to avoid flash on re-render

/**
 * Initialize the Processes tab
 */
function initProcesses() {
    // No-op — process list is rendered via polling
}

/**
 * Start polling for processes (called when Processes tab becomes active)
 */
function startProcessPolling() {
    pollProcesses();
    if (!processPollingTimer) {
        processPollingTimer = setInterval(pollProcesses, 3000);
    }
}

/**
 * Stop process polling (called when leaving Processes tab)
 */
function stopProcessPolling() {
    if (processPollingTimer) {
        clearInterval(processPollingTimer);
        processPollingTimer = null;
    }
}

/**
 * Poll for process list
 */
async function pollProcesses() {
    try {
        const response = await fetch(`${API_BASE}/api/processes`);
        if (!response.ok) return;
        const data = await response.json();
        processesData = data.processes || [];

        // Prune cache entries for processes no longer in the list
        const activeIds = new Set(processesData.map(p => p.id));
        for (const id in processOutputCache) {
            if (!activeIds.has(id)) {
                delete processOutputCache[id];
                delete processOutputPositions[id];
            }
        }

        renderProcessList(processesData);
        updateProcessSidebar(processesData);

        // If a process is expanded and running, poll its output
        if (expandedProcessId) {
            const proc = processesData.find(p => p.id === expandedProcessId);
            if (proc) {
                pollProcessOutput(expandedProcessId);
            }
        }
    } catch (error) {
        console.error('Process poll error:', error);
    }
}

/**
 * Render the grouped process list
 */
function renderProcessList(processes) {
    const container = document.getElementById('process-list');
    if (!container) return;

    if (!processes || processes.length === 0) {
        container.innerHTML = '<div class="empty-state">No processes</div>';
        return;
    }

    // Group by type
    const groups = {};
    const typeOrder = ['task-runner', 'analysis', 'execution', 'kickstart', 'analyse', 'planning', 'commit', 'task-creation'];
    const typeLabels = {
        'task-runner': 'Task Runner',
        'analysis': 'Analysis',
        'execution': 'Execution',
        'kickstart': 'Kickstart',
        'analyse': 'Analyse',
        'planning': 'Planning',
        'commit': 'Commit',
        'task-creation': 'Task Creation'
    };

    for (const proc of processes) {
        const type = proc.type || 'unknown';
        if (!groups[type]) groups[type] = [];
        groups[type].push(proc);
    }

    // Sort within groups: running first, then needs-input, then completed, then failed/stopped
    const statusOrder = { 'starting': 0, 'running': 1, 'needs-input': 2, 'completed': 3, 'stopped': 4, 'failed': 5 };
    for (const type in groups) {
        groups[type].sort((a, b) => (statusOrder[a.status] || 5) - (statusOrder[b.status] || 5));
    }

    let html = '';
    for (const type of typeOrder) {
        if (!groups[type] || groups[type].length === 0) continue;

        html += `<div class="process-group">`;
        html += `<div class="process-group-header">${typeLabels[type] || type}</div>`;

        for (const proc of groups[type]) {
            const statusClass = getProcessStatusClass(proc.status, proc);
            const statusIcon = getProcessStatusIcon(proc.status, proc);
            const timeAgo = getTimeAgo(proc.started_at);
            const displayName = proc.task_name || proc.description || proc.id;
            const isExpanded = expandedProcessId === proc.id;
            const isRunning = proc.status === 'running' || proc.status === 'starting';
            const isNeedsInput = proc.status === 'needs-input';
            const isActive = isRunning || isNeedsInput;

            // TTL countdown for failed/stopped
            let ttlHtml = '';
            if ((proc.status === 'failed' || proc.status === 'stopped') && proc.failed_at) {
                const failedAt = new Date(proc.failed_at);
                const ttlMs = 5 * 60 * 1000 - (Date.now() - failedAt.getTime());
                if (ttlMs > 0) {
                    const ttlMin = Math.ceil(ttlMs / 60000);
                    ttlHtml = `<span class="process-ttl">(clears in ${ttlMin}min)</span>`;
                }
            }

            html += `<div class="process-row ${statusClass} ${isExpanded ? 'expanded' : ''}" data-process-id="${proc.id}">`;
            html += `  <div class="process-row-main" onclick="toggleProcessExpand('${proc.id}')">`;
            html += `    <span class="process-status-icon">${statusIcon}</span>`;
            html += `    <span class="process-id">${proc.id}</span>`;
            html += `    <span class="process-name">${escapeHtml(displayName)}</span>`;
            html += `    <span class="process-time">${timeAgo}</span>`;
            const displayStatus = isProcessCrashed(proc) ? 'crashed' : proc.status;
            html += `    <span class="process-status-label">${displayStatus}${ttlHtml}</span>`;

            if (isNeedsInput) {
                html += `    <div class="process-actions">`;
                html += `      <button class="process-action-btn primary" onclick="event.stopPropagation(); toggleProcessExpand('${proc.id}')" title="Answer Questions">Answer</button>`;
                html += `      <button class="process-action-btn" onclick="event.stopPropagation(); stopProcess('${proc.id}')" title="Graceful Stop">S</button>`;
                html += `      <button class="process-action-btn danger" onclick="event.stopPropagation(); killProcess('${proc.id}')" title="Kill (immediate)">K</button>`;
                html += `    </div>`;
            } else if (isRunning) {
                html += `    <div class="process-actions">`;
                html += `      <button class="process-action-btn" onclick="event.stopPropagation(); showProcessWhisper('${proc.id}')" title="Whisper">W</button>`;
                html += `      <button class="process-action-btn" onclick="event.stopPropagation(); stopProcess('${proc.id}')" title="Graceful Stop">S</button>`;
                html += `      <button class="process-action-btn danger" onclick="event.stopPropagation(); killProcess('${proc.id}')" title="Kill (immediate)">K</button>`;
                html += `    </div>`;
            }

            html += `  </div>`;

            const heartbeatStatusText = stripConsoleSequences(proc.heartbeat_status);
            const heartbeatNextActionText = stripConsoleSequences(proc.heartbeat_next_action);

            // Heartbeat subtitle — visible without expanding
            if (isActive && heartbeatStatusText) {
                html += `<div class="process-heartbeat-subtitle">${escapeHtml(heartbeatStatusText)}</div>`;
            }

            // Expanded detail panel
            if (isExpanded) {
                html += `<div class="process-detail">`;

                // Metadata
                html += `<div class="process-meta">`;
                html += `  <span class="process-meta-item"><b>Model:</b> ${proc.model || '--'}</span>`;
                html += `  <span class="process-meta-item"><b>Tasks:</b> ${proc.tasks_completed || 0}</span>`;
                if (heartbeatStatusText) {
                    html += `  <span class="process-meta-item"><b>Status:</b> ${escapeHtml(heartbeatStatusText)}</span>`;
                }
                if (heartbeatNextActionText) {
                    html += `  <span class="process-meta-item"><b>Next:</b> ${escapeHtml(heartbeatNextActionText)}</span>`;
                }
                html += `</div>`;

                // Interview questions UI (when needs-input with pending_questions)
                if (isNeedsInput && proc.pending_questions) {
                    const questionsData = proc.pending_questions;
                    const questions = questionsData.questions || [];
                    const round = proc.interview_round || 1;
                    const roundLabel = round > 1 ? ` (Round ${round})` : '';

                    html += `<div class="process-interview" data-process-id="${proc.id}">`;
                    html += `  <div class="process-interview-header">Interview Questions${escapeHtml(roundLabel)}</div>`;

                    questions.forEach((q, idx) => {
                        if (idx > 0) html += '<div class="question-divider"></div>';
                        html += `<div class="interview-question" data-question-id="${escapeHtml(q.id)}">`;
                        html += `  <div class="interview-question-text"><span class="question-number">Q${idx + 1}.</span> ${escapeHtml(q.question)}</div>`;
                        if (q.context) {
                            html += `  <div class="interview-question-context">${escapeHtml(q.context)}</div>`;
                        }
                        html += `  <div class="interview-options">`;
                        (q.options || []).forEach(opt => {
                            html += `<div class="interview-option" data-key="${escapeHtml(opt.key)}" data-question-key="${escapeHtml(q.id)}" onclick="selectInterviewOption(this)">`;
                            html += `  <span class="interview-option-key">${escapeHtml(opt.key)}</span>`;
                            html += `  <div class="interview-option-content">`;
                            html += `    <div class="interview-option-label">${escapeHtml(opt.label)}</div>`;
                            if (opt.rationale) {
                                html += `    <div class="interview-option-rationale">${escapeHtml(opt.rationale)}</div>`;
                            }
                            html += `  </div>`;
                            html += `</div>`;
                        });
                        html += `  </div>`;
                        html += `  <div class="interview-freetext">`;
                        html += `    <textarea class="interview-freetext-input" placeholder="Or type a custom answer..." oninput="handleInterviewFreetextInput(this)"></textarea>`;
                        html += `  </div>`;
                        html += `  <div class="interview-question-submit">`;
                        html += `    <button class="ctrl-btn-sm primary" onclick="submitSingleInterviewFromProcess('${proc.id}', '${escapeHtml(q.id)}')">Submit Q${idx + 1}</button>`;
                        html += `  </div>`;
                        html += `</div>`;
                    });

                    html += `<div class="process-interview-actions">`;
                    html += `  <button class="ctrl-btn" onclick="submitInterviewFromProcess('${proc.id}', true)">Skip & Continue</button>`;
                    html += `  <button class="ctrl-btn primary" onclick="submitInterviewFromProcess('${proc.id}', false)">Submit All</button>`;
                    html += `</div>`;
                    html += `</div>`;
                }

                // Output viewer
                html += `<div class="process-output" id="process-output-${proc.id}">`;
                html += `  <div class="loading-state">Loading output...</div>`;
                html += `</div>`;

                // Inline whisper for running processes
                if (isRunning) {
                    html += `<div class="process-whisper-inline">`;
                    html += `  <input type="text" class="process-whisper-input" id="whisper-input-${proc.id}" placeholder="Send guidance..." maxlength="500">`;
                    html += `  <select class="process-whisper-priority" id="whisper-priority-${proc.id}">`;
                    html += `    <option value="normal">Normal</option>`;
                    html += `    <option value="urgent">Urgent</option>`;
                    html += `  </select>`;
                    html += `  <button class="ctrl-btn-sm primary" onclick="sendProcessWhisper('${proc.id}')">Send</button>`;
                    html += `</div>`;
                }

                html += `</div>`;
            }

            html += `</div>`;
        }

        html += `</div>`;
    }

    container.innerHTML = html;

    // Hydrate output from cache immediately to avoid "Loading output..." flash
    if (expandedProcessId && processOutputCache[expandedProcessId]?.length) {
        const outputEl = document.getElementById(`process-output-${expandedProcessId}`);
        if (outputEl) {
            outputEl.innerHTML = renderOutputHtml(processOutputCache[expandedProcessId]);
            outputEl.scrollTop = outputEl.scrollHeight;
        }
    }
}

/**
 * Toggle process row expansion
 */
function toggleProcessExpand(processId) {
    if (expandedProcessId === processId) {
        expandedProcessId = null;
    } else {
        expandedProcessId = processId;
    }
    renderProcessList(processesData);

    // If expanded and no cache yet, fetch from scratch; otherwise poll for new events only
    if (expandedProcessId) {
        if (!processOutputCache[expandedProcessId]?.length) {
            processOutputPositions[processId] = 0;
        }
        pollProcessOutput(expandedProcessId);
    }
}

/**
 * Render event array to HTML string
 */
function renderOutputHtml(events) {
    let html = '';
    for (const evt of events) {
        const ts = evt.timestamp ? new Date(evt.timestamp).toLocaleTimeString() : '';
        const typeClass = evt.type === 'rate_limit' ? 'warning' : (evt.type === 'text' ? 'text' : 'tool');
        const messageText = stripConsoleSequences(evt.message || '');
        html += `<div class="process-output-line ${typeClass}">`;
        html += `  <span class="output-time">${ts}</span>`;
        html += `  <span class="output-type">${escapeHtml(evt.type || '')}</span>`;
        html += `  <span class="output-msg">${escapeHtml(messageText)}</span>`;
        html += `</div>`;
    }
    return html;
}

/**
 * Poll process output/activity stream
 */
async function pollProcessOutput(processId) {
    try {
        const position = processOutputPositions[processId] || 0;
        const response = await fetch(`${API_BASE}/api/process/${processId}/output?position=${position}&tail=50`);
        if (!response.ok) return;

        const data = await response.json();
        if (data.position !== undefined) {
            processOutputPositions[processId] = data.position;
        }

        const outputEl = document.getElementById(`process-output-${processId}`);
        if (!outputEl) return;

        if (data.events && data.events.length > 0) {
            // Append new events to cache
            if (!processOutputCache[processId]) processOutputCache[processId] = [];
            processOutputCache[processId].push(...data.events);

            // Clear empty-state / loading placeholder before appending
            const placeholder = outputEl.querySelector('.loading-state, .empty-state');
            if (placeholder) outputEl.innerHTML = '';

            // Append only new events to the DOM
            outputEl.insertAdjacentHTML('beforeend', renderOutputHtml(data.events));
            outputEl.scrollTop = outputEl.scrollHeight;
        } else if (position === 0 && !processOutputCache[processId]?.length) {
            outputEl.innerHTML = '<div class="empty-state">No output yet</div>';
        }
    } catch (error) {
        console.error('Process output poll error:', error);
    }
}

/**
 * Stop a process
 */
async function stopProcess(processId) {
    try {
        const response = await fetch(`${API_BASE}/api/process/${processId}/stop`, {
            method: 'POST'
        });
        const data = await response.json();
        if (data.success) {
            showToast(`Stop signal sent to ${processId}`, 'success');
            pollProcesses();
        } else {
            showToast(`Stop failed: ${data.error || 'Unknown error'}`, 'error');
        }
    } catch (error) {
        showToast(`Stop error: ${error.message}`, 'error');
    }
}

/**
 * Kill a process immediately via PID
 */
async function killProcess(processId) {
    if (!confirm(`Kill process ${processId} immediately? This will terminate it without finishing the current task.`)) {
        return;
    }

    try {
        const response = await fetch(`${API_BASE}/api/process/${processId}/kill`, {
            method: 'POST'
        });
        const data = await response.json();
        if (data.success) {
            showToast(`Process ${processId} killed`, 'warning');
            pollProcesses();
        } else {
            showToast(`Kill failed: ${data.error || 'Unknown error'}`, 'error');
        }
    } catch (error) {
        showToast(`Kill error: ${error.message}`, 'error');
    }
}

/**
 * Show whisper input for a process (uses inline whisper in expanded view)
 */
function showProcessWhisper(processId) {
    // Expand the process row first
    if (expandedProcessId !== processId) {
        toggleProcessExpand(processId);
    }
    // Focus the whisper input after render
    setTimeout(() => {
        const input = document.getElementById(`whisper-input-${processId}`);
        if (input) input.focus();
    }, 100);
}

/**
 * Send a whisper to a process
 */
async function sendProcessWhisper(processId) {
    const input = document.getElementById(`whisper-input-${processId}`);
    const prioritySelect = document.getElementById(`whisper-priority-${processId}`);

    const message = input?.value?.trim();
    if (!message) return;

    const priority = prioritySelect?.value || 'normal';

    try {
        const response = await fetch(`${API_BASE}/api/process/${processId}/whisper`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ message, priority })
        });
        const data = await response.json();
        if (data.success) {
            showToast(`Whisper sent to ${processId}`, 'success');
            if (input) input.value = '';
        } else {
            showToast(`Whisper failed: ${data.error || 'Unknown error'}`, 'error');
        }
    } catch (error) {
        showToast(`Whisper error: ${error.message}`, 'error');
    }
}

// --- Helpers ---

function isProcessCrashed(proc) {
    // A process is "crashed" if it went to stopped without a user-initiated stop,
    // detected by having error set or failed_at without completed_at
    return proc.status === 'stopped' && proc.error && !proc.completed_at;
}

function getProcessStatusClass(status, proc) {
    if (proc && isProcessCrashed(proc)) return 'status-failed';
    switch (status) {
        case 'running':
        case 'starting': return 'status-running';
        case 'needs-input': return 'status-needs-input';
        case 'completed': return 'status-completed';
        case 'failed': return 'status-failed';
        case 'stopped': return 'status-stopped';
        default: return '';
    }
}

function getProcessStatusIcon(status, proc) {
    if (proc && isProcessCrashed(proc)) return '<span class="led error"></span>';
    switch (status) {
        case 'running':
        case 'starting': return '<span class="led active"></span>';
        case 'needs-input': return '<span class="led warning"></span>';
        case 'completed': return '<span class="led success"></span>';
        case 'failed': return '<span class="led error"></span>';
        case 'stopped': return '<span class="led off"></span>';
        default: return '<span class="led off"></span>';
    }
}

function getTimeAgo(isoString) {
    if (!isoString) return '--';
    const diff = Date.now() - new Date(isoString).getTime();
    const mins = Math.floor(diff / 60000);
    if (mins < 1) return 'just now';
    if (mins < 60) return `${mins}min ago`;
    const hours = Math.floor(mins / 60);
    if (hours < 24) return `${hours}h ago`;
    return `${Math.floor(hours / 24)}d ago`;
}

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

/**
 * Toggle interview option selection (single-select per question)
 */
function selectInterviewOption(element) {
    const questionEl = element.closest('.interview-question');
    if (!questionEl) return;
    if (questionEl.classList.contains('answered')) return;

    // Single-select within each question
    questionEl.querySelectorAll('.interview-option').forEach(opt => {
        opt.classList.remove('selected');
    });
    element.classList.add('selected');
    // Clear free text when an option is selected
    const freetext = questionEl.querySelector('.interview-freetext-input');
    if (freetext) freetext.value = '';
}

/**
 * Clear option selection when typing free text in process interview
 * @param {HTMLTextAreaElement} textarea - The free text input
 */
function handleInterviewFreetextInput(textarea) {
    const questionEl = textarea.closest('.interview-question');
    if (questionEl?.classList.contains('answered')) return;

    if (textarea.value.trim()) {
        if (questionEl) {
            questionEl.querySelectorAll('.interview-option').forEach(opt => opt.classList.remove('selected'));
        }
    }
}

/**
 * Toggle submitted/editable state for a single process interview question
 * @param {HTMLElement} questionEl - Interview question element
 * @param {boolean} submitted - Whether question is currently submitted
 */
function setProcessInterviewQuestionSubmittedState(questionEl, submitted) {
    const questionContainer = questionEl.parentElement;
    const questionEls = questionContainer ? Array.from(questionContainer.querySelectorAll('.interview-question')) : [];
    const questionIndex = Math.max(1, questionEls.indexOf(questionEl) + 1);
    const submitBtn = questionEl.querySelector('.interview-question-submit .ctrl-btn-sm');
    const freetextInput = questionEl.querySelector('.interview-freetext-input');

    questionEl.classList.toggle('answered', submitted);

    if (freetextInput) {
        freetextInput.disabled = submitted;
    }

    if (submitBtn) {
        submitBtn.disabled = false;
        submitBtn.textContent = submitted
            ? `Edit Q${questionIndex}`
            : `Submit Q${questionIndex}`;
    }
}

/**
 * Submit a single interview question from the Process tab
 * Allows toggling back to edit if the user changes their mind
 * @param {string} processId - Process ID
 * @param {string} questionId - Question ID
 */
async function submitSingleInterviewFromProcess(processId, questionId) {
    const container = document.querySelector(`.process-interview[data-process-id="${processId}"]`);
    if (!container) return;

    const questionEl = container.querySelector(`.interview-question[data-question-id="${questionId}"]`);
    if (!questionEl) return;

    if (questionEl.classList.contains('answered')) {
        setProcessInterviewQuestionSubmittedState(questionEl, false);
        return;
    }

    const selectedOpt = questionEl.querySelector('.interview-option.selected');
    const freetext = questionEl.querySelector('.interview-freetext-input')?.value?.trim() || '';

    if (!selectedOpt && !freetext) {
        showToast('Please select an option or type a custom answer', 'warning');
        return;
    }

    setProcessInterviewQuestionSubmittedState(questionEl, true);
}

/**
 * Submit interview answers from the Process tab
 * @param {string} processId - Process ID
 * @param {boolean} skipped - Whether user is skipping the interview
 */
async function submitInterviewFromProcess(processId, skipped) {
    const container = document.querySelector(`.process-interview[data-process-id="${processId}"]`);
    if (!container) return;

    if (!skipped) {
        // Collect answers from all questions (option or free text)
        const questionEls = container.querySelectorAll('.interview-question');
        const answers = [];
        let allAnswered = true;

        questionEls.forEach(qEl => {
            const questionId = qEl.dataset.questionId;
            const selectedOpt = qEl.querySelector('.interview-option.selected');
            const freetext = qEl.querySelector('.interview-freetext-input')?.value?.trim() || '';
            const questionText = qEl.querySelector('.interview-question-text')?.textContent || '';

            if (!selectedOpt && !freetext) {
                allAnswered = false;
            } else if (freetext) {
                answers.push({
                    question_id: questionId,
                    question: questionText,
                    answer: freetext
                });
            } else {
                const key = selectedOpt.dataset.key;
                const label = selectedOpt.querySelector('.interview-option-label')?.textContent || key;
                answers.push({
                    question_id: questionId,
                    question: questionText,
                    answer: `${key}: ${label}`
                });
            }
        });

        if (!allAnswered) {
            showToast('Please answer all questions before submitting', 'warning');
            return;
        }

        try {
            const response = await fetch(`${API_BASE}/api/process/answer`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    process_id: processId,
                    answers: answers,
                    skipped: false
                })
            });

            const result = await response.json();
            if (result.success) {
                showToast('Interview answers submitted', 'success');
                pollProcesses();
            } else {
                showToast('Failed to submit answers: ' + (result.error || 'Unknown error'), 'error');
            }
        } catch (error) {
            console.error('Error submitting interview answers:', error);
            showToast('Error submitting answers', 'error');
        }
    } else {
        // Skip
        try {
            const response = await fetch(`${API_BASE}/api/process/answer`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    process_id: processId,
                    answers: [],
                    skipped: true
                })
            });

            const result = await response.json();
            if (result.success) {
                showToast('Interview skipped — proceeding with kickstart', 'info');
                pollProcesses();
            } else {
                showToast('Failed to skip: ' + (result.error || 'Unknown error'), 'error');
            }
        } catch (error) {
            console.error('Error skipping interview:', error);
            showToast('Error skipping interview', 'error');
        }
    }
}

/**
 * Update the process summary counts in the sidebar
 * Called from pollProcesses after data is fetched
 */
function updateProcessSidebar(processes) {
    const running = processes.filter(p => p.status === 'running' || p.status === 'starting').length;
    const completed = processes.filter(p => p.status === 'completed').length;
    const failed = processes.filter(p => p.status === 'failed' || p.status === 'stopped').length;
    const totalTasks = processes.reduce((sum, p) => sum + (p.tasks_completed || 0), 0);

    const runEl = document.getElementById('proc-running-count');
    const compEl = document.getElementById('proc-completed-count');
    const failEl = document.getElementById('proc-failed-count');
    const taskEl = document.getElementById('proc-total-tasks');

    if (runEl) runEl.textContent = running;
    if (compEl) compEl.textContent = completed;
    if (failEl) failEl.textContent = failed;
    if (taskEl) taskEl.textContent = totalTasks;
}
