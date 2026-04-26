/**
 * DOTBOT Control Panel - Actions Module
 * Handles action-required items: questions, split approvals, and task creation
 */

// State for action items
let actionItems = [];
let selectedAnswers = {};    // { taskId: [selectedKeys] }
let answerAttachments = {};          // { taskId: [{ name, size, content (base64) }] }
let kickstartAttachments = {};       // { "processId:questionId": [{ name, size, content }] }
let actionWidgetSuppressUntil = 0;

const ANSWER_ALLOWED_EXTENSIONS = ['.md', '.docx', '.xlsx', '.pdf', '.txt'];
const ANSWER_MAX_FILE_SIZE = 15 * 1024 * 1024; // 15 MB

/**
 * Initialize action-required functionality
 */
function initActions() {
    // Widget click handler
    const widget = document.getElementById('action-widget');
    widget?.addEventListener('click', openSlideout);

    // Slideout close handlers
    const overlay = document.getElementById('slideout-overlay');
    const closeBtn = document.getElementById('slideout-close');

    overlay?.addEventListener('click', closeSlideout);
    closeBtn?.addEventListener('click', closeSlideout);

    // Escape key to close
    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') {
            closeSlideout();
            closeTaskCreateModal();
            if (typeof closeKickstartModal === 'function') closeKickstartModal();
        }
    });

    // Initialize task creation modal
    initTaskCreateModal();

    // Initialize git commit button
    initGitCommitButton();
}

/**
 * Initialize task creation modal handlers
 */
function initTaskCreateModal() {
    const modal = document.getElementById('task-create-modal');
    const closeBtn = document.getElementById('task-create-modal-close');
    const cancelBtn = document.getElementById('task-create-cancel');
    const submitBtn = document.getElementById('task-create-submit');
    const textarea = document.getElementById('task-create-prompt');

    // Add task button handlers (both overview and pipeline)
    document.getElementById('add-task-btn-upcoming')?.addEventListener('click', openTaskCreateModal);
    document.getElementById('add-task-btn-pipeline')?.addEventListener('click', openTaskCreateModal);

    // Close handlers
    closeBtn?.addEventListener('click', closeTaskCreateModal);
    cancelBtn?.addEventListener('click', closeTaskCreateModal);
    modal?.addEventListener('click', (e) => {
        if (e.target === modal) {
            closeTaskCreateModal();
        }
    });

    // Submit handler
    submitBtn?.addEventListener('click', submitTaskCreate);

    // Ctrl+Enter to submit
    textarea?.addEventListener('keydown', (e) => {
        if ((e.ctrlKey || e.metaKey) && e.key === 'Enter') {
            e.preventDefault();
            submitTaskCreate();
        }
    });
}

/**
 * Open task creation modal
 */
function openTaskCreateModal() {
    const modal = document.getElementById('task-create-modal');
    const textarea = document.getElementById('task-create-prompt');

    if (modal) {
        modal.classList.add('visible');
        // Focus the textarea after a brief delay for the modal animation
        setTimeout(() => textarea?.focus(), 100);
    }
}

/**
 * Close task creation modal
 */
function closeTaskCreateModal() {
    const modal = document.getElementById('task-create-modal');
    const textarea = document.getElementById('task-create-prompt');
    const submitBtn = document.getElementById('task-create-submit');
    const interviewCheckbox = document.getElementById('task-create-interview');

    if (modal) {
        modal.classList.remove('visible');
        // Clear the form
        if (textarea) textarea.value = '';
        if (interviewCheckbox) interviewCheckbox.checked = false;
        // Reset button state
        if (submitBtn) {
            submitBtn.classList.remove('loading');
            submitBtn.disabled = false;
        }
    }
}

/**
 * Submit task creation request
 */
async function submitTaskCreate() {
    const textarea = document.getElementById('task-create-prompt');
    const submitBtn = document.getElementById('task-create-submit');
    const interviewCheckbox = document.getElementById('task-create-interview');

    const prompt = textarea?.value?.trim();
    const needsInterview = interviewCheckbox?.checked || false;

    if (!prompt) {
        showToast('Please describe the task you want to create', 'warning');
        return;
    }

    // Set loading state
    if (submitBtn) {
        submitBtn.classList.add('loading');
        submitBtn.disabled = true;
    }

    try {
        const response = await fetch(`${API_BASE}/api/task/create`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ prompt, needs_interview: needsInterview })
        });

        const result = await response.json();

        if (result.success) {
            closeTaskCreateModal();
            // Show success feedback
            showSignalFeedback('Task creation started. Claude is processing your request...', 'success');
            // Trigger state refresh after a delay to pick up the new task
            setTimeout(() => {
                if (typeof pollState === 'function') {
                    pollState();
                }
            }, 2000);
        } else {
            showToast('Failed to create task: ' + (result.error || 'Unknown error'), 'error');
            // Reset button state on error
            if (submitBtn) {
                submitBtn.classList.remove('loading');
                submitBtn.disabled = false;
            }
        }
    } catch (error) {
        console.error('Error creating task:', error);
        showToast('Error creating task: ' + error.message, 'error');
        // Reset button state on error
        if (submitBtn) {
            submitBtn.classList.remove('loading');
            submitBtn.disabled = false;
        }
    }
}

/**
 * Show signal feedback message
 * @param {string} message - Message to display
 * @param {string} type - Feedback type (success, error, info)
 */
function showSignalFeedback(message, type) {
    const feedback = document.getElementById('signal-status');
    if (feedback) {
        feedback.textContent = message;
        feedback.className = `signal-feedback visible ${type || ''}`;
        // Hide after 5 seconds
        setTimeout(() => {
            feedback.classList.remove('visible');
        }, 5000);
    }
}

/**
 * Update action widget visibility and count
 * @param {number} count - Number of action-required items
 */
function updateActionWidget(count, { fromPoll = false } = {}) {
    if (fromPoll && Date.now() < actionWidgetSuppressUntil) return;

    const widget = document.getElementById('action-widget');
    const countEl = document.getElementById('action-widget-count');

    if (!widget) return;

    if (count > 0) {
        widget.classList.remove('hidden');
        if (countEl) countEl.textContent = count;
    } else {
        widget.classList.add('hidden');
    }
}

/**
 * Open the slide-out panel and fetch action items
 */
async function openSlideout() {
    const overlay = document.getElementById('slideout-overlay');
    const panel = document.getElementById('slideout-panel');

    overlay?.classList.add('visible');
    panel?.classList.add('visible');

    // Fetch and render action items
    await fetchAndRenderActionItems();
}

/**
 * Close the slide-out panel
 */
function closeSlideout() {
    const overlay = document.getElementById('slideout-overlay');
    const panel = document.getElementById('slideout-panel');

    overlay?.classList.remove('visible');
    panel?.classList.remove('visible');
}

/**
 * Fetch action items from the API and render them
 */
async function fetchAndRenderActionItems() {
    const content = document.getElementById('slideout-content');
    if (!content) return;

    content.innerHTML = '<div class="loading-state">Loading...</div>';

    try {
        const response = await fetch(`${API_BASE}/api/tasks/action-required`);
        const data = await response.json();

        if (data.success && data.items && data.items.length > 0) {
            actionItems = data.items;
            renderActionItems(content, data.items);
        } else {
            content.innerHTML = '<div class="empty-state">No pending actions</div>';
            actionItems = [];
        }
    } catch (error) {
        console.error('Failed to fetch action items:', error);
        content.innerHTML = '<div class="empty-state">Error loading actions</div>';
    }
}

/**
 * Render action items in the slide-out panel
 * @param {HTMLElement} container - Container element
 * @param {Array} items - Action items to render
 */
function renderActionItems(container, items) {
    container.innerHTML = items.map(item => {
        if (item.type === 'question') {
            return renderQuestionItem(item);
        } else if (item.type === 'task-questions') {
            return renderTaskQuestionsItem(item);
        } else if (item.type === 'split') {
            return renderSplitItem(item);
        } else if (item.type === 'kickstart-questions') {
            return renderKickstartQuestionsItem(item);
        }
        return '';
    }).join('');

    // Attach event handlers
    attachActionHandlers(container);
}

/**
 * Render a question action item
 * @param {Object} item - Question item
 * @returns {string} HTML string
 */
function renderQuestionItem(item) {
    const question = item.question || {};
    const options = question.options || [];
    const isMultiSelect = question.multi_select || false;

    // Initialize selected answers for this task
    if (!selectedAnswers[item.task_id]) {
        selectedAnswers[item.task_id] = [];
    }

    return `
        <div class="action-item" data-task-id="${escapeHtml(item.task_id)}" data-type="question">
            <div class="action-item-header">
                <span class="action-item-type question">Question</span>
                <span class="action-item-task">${escapeHtml(item.task_name)}</span>
            </div>
            <div class="action-item-body">
                <div class="action-question-text">${escapeHtml(question.question || 'No question text')}</div>
                ${question.context ? `<div class="action-question-context">${escapeHtml(question.context)}</div>` : ''}
                
                ${isMultiSelect ? '<div class="multi-select-hint">Select one or more options</div>' : ''}
                
                <div class="answer-options" data-multi-select="${isMultiSelect}">
                    ${options.map(opt => `
                        <div class="answer-option"
                             data-key="${escapeHtml(opt.key)}"
                             data-label="${escapeHtml(opt.label)}">
                            <span class="answer-key">${escapeHtml(opt.key)}</span>
                            <div class="answer-content">
                                <div class="answer-label">${escapeHtml(opt.label)}</div>
                                ${opt.rationale ? `<div class="answer-rationale">${escapeHtml(opt.rationale)}</div>` : ''}
                            </div>
                        </div>
                    `).join('')}
                </div>
                
                <div class="custom-answer-section">
                    <div class="custom-answer-label">Or provide custom response</div>
                    <textarea class="custom-answer-input" placeholder="Type a custom answer..."></textarea>
                </div>

                <div class="answer-attachments-section">
                    <div class="answer-attachments-label">Attach files (optional)</div>
                    <div class="answer-dropzone" data-task-id="${escapeHtml(item.task_id)}">
                        <div class="dropzone-content">
                            <div class="dropzone-icon">&#9671;</div>
                            <div class="dropzone-text">Drop files here or click to browse</div>
                            <div class="dropzone-hint">.md .docx .xlsx .pdf .txt &mdash; max 15 MB each</div>
                        </div>
                    </div>
                    <input type="file" class="answer-file-input" style="display: none;" multiple accept=".md,.docx,.xlsx,.pdf,.txt">
                    <div class="answer-file-list"></div>
                </div>

                <div class="action-submit">
                    <button class="ctrl-btn primary submit-answer">Submit Answer</button>
                </div>
            </div>
        </div>
    `;
}

/**
 * Render a task-questions action item (batch questions from task_mark_needs_input)
 * @param {Object} item - Task questions item
 * @returns {string} HTML string
 */
function renderTaskQuestionsItem(item) {
    const questions = item.questions || [];
    const taskId = item.task_id;

    return `
        <div class="action-item" data-task-id="${escapeAttr(taskId)}" data-type="task-questions">
            <div class="action-item-header">
                <span class="action-item-type question">Questions (${questions.length})</span>
                <span class="action-item-task">${escapeHtml(item.task_name)}</span>
            </div>
            <div class="action-item-body">
                ${questions.map((q, idx) => `
                    ${idx > 0 ? '<div class="question-divider"></div>' : ''}
                    <div class="task-question-block" data-question-id="${escapeAttr(q.id)}" data-task-id="${escapeAttr(taskId)}">
                        <div class="action-question-text"><span class="question-number">Q${idx + 1}.</span> ${escapeHtml(q.question)}</div>
                        ${q.context ? `<div class="action-question-context">${escapeHtml(q.context)}</div>` : ''}
                        <div class="answer-options" data-multi-select="false">
                            ${(q.options || []).map(opt => `
                                <div class="answer-option"
                                     data-key="${escapeAttr(opt.key)}"
                                     data-label="${escapeAttr(opt.label)}"
                                     data-question-key="${escapeAttr(q.id)}">
                                    <span class="answer-key">${escapeHtml(opt.key)}</span>
                                    <div class="answer-content">
                                        <div class="answer-label">${escapeHtml(opt.label)}</div>
                                        ${opt.rationale ? `<div class="answer-rationale">${escapeHtml(opt.rationale)}</div>` : ''}
                                    </div>
                                </div>
                            `).join('')}
                        </div>
                        <div class="kickstart-question-freetext">
                            <textarea class="kickstart-freetext-input" placeholder="Or type a custom answer..."></textarea>
                        </div>
                        <div class="interview-question-submit">
                            <button class="ctrl-btn-sm primary submit-task-question" data-task-id="${escapeAttr(taskId)}" data-question-id="${escapeAttr(q.id)}">Submit Q${idx + 1}</button>
                        </div>
                    </div>
                `).join('')}
            </div>
        </div>
    `;
}

/**
 * Submit a single task question from the batch (task-questions type)
 * @param {string} taskId - Task ID
 * @param {string} questionId - Question ID
 */
async function submitTaskQuestion(taskId, questionId) {
    const container = document.querySelector(`.action-item[data-task-id="${CSS.escape(taskId)}"][data-type="task-questions"]`);
    if (!container) return;

    const questionBlock = container.querySelector(`.task-question-block[data-question-id="${CSS.escape(questionId)}"]`);
    if (!questionBlock) return;

    // Get selected option for this question
    const selectedOption = questionBlock.querySelector(`.answer-option.selected[data-question-key="${CSS.escape(questionId)}"]`);
    const freetextEl = questionBlock.querySelector('.kickstart-freetext-input');
    const freetext = freetextEl ? freetextEl.value.trim() : '';

    const answer = selectedOption ? selectedOption.dataset.key : null;
    const customText = freetext || null;

    if (!answer && !customText) {
        alert('Please select an option or type a custom answer.');
        return;
    }

    const submitBtn = questionBlock.querySelector('.ctrl-btn-sm.primary');
    const originalBtnText = submitBtn ? submitBtn.textContent : '';
    if (submitBtn) {
        submitBtn.disabled = true;
        submitBtn.textContent = 'Submitting...';
    }

    try {
        const response = await fetch(`${API_BASE}/api/task/answer`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                task_id: taskId,
                question_id: questionId,
                answer: answer,
                custom_text: customText
            })
        });
        const result = await response.json();

        if (result.success) {
            // Mark this question block as answered
            questionBlock.classList.add('answered');
            questionBlock.innerHTML = `<div class="interview-answered-notice">Q answered ✓ — ${result.questions_remaining_count > 0 ? result.questions_remaining_count + ' question(s) still pending' : 'all done, task resuming...'}</div>`;

            // Refresh after a short delay
            setTimeout(() => fetchAndRenderActionItems(), 1500);
        } else {
            if (submitBtn) {
                submitBtn.disabled = false;
                submitBtn.textContent = originalBtnText;
            }
            alert('Failed to submit answer: ' + (result.error || 'Unknown error'));
        }
    } catch (err) {
        if (submitBtn) {
            submitBtn.disabled = false;
            submitBtn.textContent = originalBtnText;
        }
        alert('Network error: ' + err.message);
    }
}

/**
 * Render a split approval action item
 * @param {Object} item - Split item
 * @returns {string} HTML string
 */
function renderSplitItem(item) {
    const proposal = item.split_proposal || {};
    const subTasks = proposal.sub_tasks || [];

    return `
        <div class="action-item" data-task-id="${escapeHtml(item.task_id)}" data-type="split">
            <div class="action-item-header">
                <span class="action-item-type split">Split Proposal</span>
                <span class="action-item-task">${escapeHtml(item.task_name)}</span>
            </div>
            <div class="action-item-body">
                ${proposal.reason ? `<div class="split-reason">${escapeHtml(proposal.reason)}</div>` : ''}
                
                <div class="split-tasks">
                    ${subTasks.map((task, idx) => `
                        <div class="split-task-item">
                            <span class="split-task-name">${idx + 1}. ${escapeHtml(task.name)}</span>
                            ${task.effort ? `<span class="split-task-effort">${escapeHtml(task.effort)}</span>` : ''}
                        </div>
                    `).join('')}
                </div>
                
                <div class="action-submit">
                    <button class="ctrl-btn reject-split">Reject</button>
                    <button class="ctrl-btn primary approve-split">Approve Split</button>
                </div>
            </div>
        </div>
    `;
}

/**
 * Render a kickstart interview questions item (all questions in one card)
 * @param {Object} item - Kickstart questions item
 * @returns {string} HTML string
 */
function renderKickstartQuestionsItem(item) {
    const questionsData = item.questions || {};
    const questions = questionsData.questions || [];
    const round = item.interview_round || 1;
    const roundLabel = round > 1 ? ` (Round ${round})` : '';

    return `
        <div class="action-item" data-process-id="${escapeHtml(item.process_id)}" data-type="kickstart-questions">
            <div class="action-item-header">
                <span class="action-item-type kickstart">Kickstart Interview${escapeHtml(roundLabel)}</span>
                <span class="action-item-task">${escapeHtml(item.description || 'Project Setup')}</span>
            </div>
            <div class="action-item-body">
                ${questions.map((q, idx) => `
                    ${idx > 0 ? '<div class="question-divider"></div>' : ''}
                    <div class="kickstart-question" data-question-id="${escapeHtml(q.id)}">
                        <div class="action-question-text"><span class="question-number">Q${idx + 1}.</span> ${escapeHtml(q.question)}</div>
                        ${q.context ? `<div class="action-question-context">${escapeHtml(q.context)}</div>` : ''}
                        <div class="answer-options" data-multi-select="false">
                            ${(q.options || []).map(opt => `
                                <div class="answer-option"
                                     data-key="${escapeHtml(opt.key)}"
                                     data-label="${escapeHtml(opt.label)}"
                                     data-question-key="${escapeHtml(q.id)}">
                                    <span class="answer-key">${escapeHtml(opt.key)}</span>
                                    <div class="answer-content">
                                        <div class="answer-label">${escapeHtml(opt.label)}</div>
                                        ${opt.rationale ? `<div class="answer-rationale">${escapeHtml(opt.rationale)}</div>` : ''}
                                    </div>
                                </div>
                            `).join('')}
                        </div>
                        <div class="kickstart-question-freetext">
                            <textarea class="kickstart-freetext-input" placeholder="Or type a custom answer..."></textarea>
                        </div>
                        <div class="answer-attachments-section" data-process-id="${escapeHtml(item.process_id)}" data-question-id="${escapeHtml(q.id)}">
                            <div class="answer-attachments-label">Attach files (optional)</div>
                            <div class="answer-dropzone" data-process-id="${escapeHtml(item.process_id)}" data-question-id="${escapeHtml(q.id)}">
                                <div class="dropzone-content">
                                    <div class="dropzone-icon">&#9671;</div>
                                    <div class="dropzone-text">Drop files here or click to browse</div>
                                    <div class="dropzone-hint">.md .docx .xlsx .pdf .txt &mdash; max 15 MB each</div>
                                </div>
                            </div>
                            <input type="file" class="answer-file-input" style="display: none;" multiple accept=".md,.docx,.xlsx,.pdf,.txt">
                            <div class="answer-file-list"></div>
                        </div>
                        <div class="kickstart-question-submit">
                            <button class="ctrl-btn-sm primary submit-single-kickstart">Submit Q${idx + 1}</button>
                        </div>
                    </div>
                `).join('')}

                <div class="action-submit">
                    <button class="ctrl-btn skip-interview">Skip & Continue</button>
                    <button class="ctrl-btn primary submit-interview">Submit All</button>
                </div>
            </div>
        </div>
    `;
}

/**
 * Attach event handlers to action items
 * @param {HTMLElement} container - Container element
 */
function attachActionHandlers(container) {
    // Answer option selection
    container.querySelectorAll('.answer-option').forEach(option => {
        option.addEventListener('click', (e) => {
            const optionsContainer = option.closest('.answer-options');
            const isMultiSelect = optionsContainer?.dataset.multiSelect === 'true';
            const taskId = option.closest('.action-item')?.dataset.taskId;
            const key = option.dataset.key;
            const label = option.dataset.label;
            const value = label ? `${key}: ${label}` : key;

            if (!taskId) return;

            if (isMultiSelect) {
                // Toggle selection
                option.classList.toggle('selected');
                if (option.classList.contains('selected')) {
                    if (!selectedAnswers[taskId]) selectedAnswers[taskId] = [];
                    if (!selectedAnswers[taskId].includes(value)) {
                        selectedAnswers[taskId].push(value);
                    }
                } else {
                    selectedAnswers[taskId] = selectedAnswers[taskId].filter(v => v !== value);
                }
            } else {
                // Single select - clear others
                optionsContainer?.querySelectorAll('.answer-option').forEach(opt => {
                    opt.classList.remove('selected');
                });
                option.classList.add('selected');
                selectedAnswers[taskId] = [value];
            }
        });
    });

    // Submit answer buttons
    container.querySelectorAll('.submit-answer').forEach(btn => {
        btn.addEventListener('click', async (e) => {
            const actionItem = btn.closest('.action-item');
            const taskId = actionItem?.dataset.taskId;
            if (!taskId) return;

            const selected = selectedAnswers[taskId] || [];
            const customText = actionItem.querySelector('.custom-answer-input')?.value?.trim() || '';
            const hasAttachments = (answerAttachments[taskId] || []).length > 0;

            if (selected.length === 0 && !customText && !hasAttachments) {
                showToast('Please select an option, provide a custom answer, or attach a file', 'warning');
                return;
            }

            btn.disabled = true;
            btn.textContent = 'Submitting...';

            try {
                const attachments = (answerAttachments[taskId] || []).map(f => ({
                    name: f.name,
                    size: f.size,
                    content: f.content
                }));

                const response = await fetch(`${API_BASE}/api/task/answer`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({
                        task_id: taskId,
                        answer: selected.length === 1 ? selected[0]
                              : selected.length > 1 ? selected
                              : customText || '',
                        custom_text: customText || null,
                        attachments: attachments.length > 0 ? attachments : null
                    })
                });

                const result = await response.json();

                if (result.success) {
                    // Remove the answered item from UI
                    actionItem.remove();
                    delete selectedAnswers[taskId];
                    delete answerAttachments[taskId];

                    // Update widget count and suppress poll updates to prevent flicker
                    const remaining = document.querySelectorAll('.action-item').length;
                    updateActionWidget(remaining);
                    actionWidgetSuppressUntil = Date.now() + 4000;

                    if (remaining === 0) {
                        document.getElementById('slideout-content').innerHTML =
                            '<div class="empty-state">No pending actions</div>';
                    }

                    // Trigger state refresh
                    if (typeof pollState === 'function') {
                        pollState();
                    }
                } else {
                    showToast('Failed to submit answer: ' + (result.error || 'Unknown error'), 'error');
                    btn.disabled = false;
                    btn.textContent = 'Submit Answer';
                }
            } catch (error) {
                console.error('Error submitting answer:', error);
                showToast('Error submitting answer', 'error');
                btn.disabled = false;
                btn.textContent = 'Submit Answer';
            }
        });
    });

    // Answer attachment dropzones (task questions and kickstart questions)
    container.querySelectorAll('.answer-dropzone').forEach(dropzone => {
        const taskId = dropzone.dataset.taskId;
        const questionId = dropzone.dataset.questionId;
        const processId = dropzone.dataset.processId;
        const section = dropzone.closest('.answer-attachments-section');
        const fileInput = section?.querySelector('.answer-file-input');

        const handleFiles = (files) => {
            if (taskId) {
                handleAnswerFiles(taskId, files, section);
            } else if (processId && questionId) {
                handleKickstartFiles(processId, questionId, files, section);
            }
        };

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
            if (e.dataTransfer.files.length > 0) handleFiles(e.dataTransfer.files);
        });

        fileInput?.addEventListener('change', (e) => {
            if (e.target.files.length > 0) {
                handleFiles(e.target.files);
                e.target.value = '';
            }
        });
    });

    // Approve split buttons
    container.querySelectorAll('.approve-split').forEach(btn => {
        btn.addEventListener('click', () => handleSplitAction(btn, true));
    });

    // Reject split buttons
    container.querySelectorAll('.reject-split').forEach(btn => {
        btn.addEventListener('click', () => handleSplitAction(btn, false));
    });

    // Task batch questions: per-question option selection
    container.querySelectorAll('.task-question-block .answer-option').forEach(option => {
        option.addEventListener('click', () => {
            const questionBlock = option.closest('.task-question-block');
            if (!questionBlock) return;
            if (questionBlock.classList.contains('answered')) return;

            questionBlock.querySelectorAll('.answer-option').forEach(opt => opt.classList.remove('selected'));
            option.classList.add('selected');
            const freetext = questionBlock.querySelector('.kickstart-freetext-input');
            if (freetext) freetext.value = '';
        });
    });

    // Task batch questions: clear selection when typing free text
    container.querySelectorAll('.task-question-block .kickstart-freetext-input').forEach(textarea => {
        textarea.addEventListener('input', () => {
            const questionBlock = textarea.closest('.task-question-block');
            if (questionBlock?.classList.contains('answered')) return;
            if (textarea.value.trim()) {
                questionBlock?.querySelectorAll('.answer-option').forEach(opt => opt.classList.remove('selected'));
            }
        });
    });

    // Kickstart interview: per-question option selection
    container.querySelectorAll('.kickstart-question .answer-option').forEach(option => {
        option.addEventListener('click', () => {
            const questionEl = option.closest('.kickstart-question');
            if (!questionEl) return;
            if (questionEl.classList.contains('answered')) return;

            // Single-select within each question
            questionEl.querySelectorAll('.answer-option').forEach(opt => {
                opt.classList.remove('selected');
            });
            option.classList.add('selected');
            // Clear free text when an option is selected
            const freetext = questionEl.querySelector('.kickstart-freetext-input');
            if (freetext) freetext.value = '';
        });
    });

    // Kickstart interview: clear option selection when typing free text
    container.querySelectorAll('.kickstart-freetext-input').forEach(textarea => {
        textarea.addEventListener('input', () => {
            const questionEl = textarea.closest('.kickstart-question');
            if (questionEl?.classList.contains('answered')) return;

            if (textarea.value.trim()) {
                if (questionEl) {
                    questionEl.querySelectorAll('.answer-option').forEach(opt => opt.classList.remove('selected'));
                }
            }
        });
    });

    // Task batch questions: per-question submit
    container.querySelectorAll('.submit-task-question').forEach(btn => {
        btn.addEventListener('click', () => submitTaskQuestion(btn.dataset.taskId, btn.dataset.questionId));
    });

    // Kickstart interview: per-question submit
    container.querySelectorAll('.submit-single-kickstart').forEach(btn => {
        btn.addEventListener('click', () => handleSingleKickstartAnswer(btn));
    });

    // Submit interview answers
    container.querySelectorAll('.submit-interview').forEach(btn => {
        btn.addEventListener('click', () => handleInterviewSubmit(btn, false));
    });

    // Skip interview
    container.querySelectorAll('.skip-interview').forEach(btn => {
        btn.addEventListener('click', () => handleInterviewSubmit(btn, true));
    });
}

/**
 * Handle split approval/rejection
 * @param {HTMLElement} btn - Button element
 * @param {boolean} approved - Whether approved or rejected
 */

/**
 * Handle file selection for answer attachments
 */
function handleAnswerFiles(taskId, fileList, section) {
    if (!answerAttachments[taskId]) {
        answerAttachments[taskId] = [];
    }

    for (const file of Array.from(fileList)) {
        const ext = file.name.slice(file.name.lastIndexOf('.')).toLowerCase();
        if (!ANSWER_ALLOWED_EXTENSIONS.includes(ext)) {
            showToast(`"${file.name}" is not allowed. Use one of: ${ANSWER_ALLOWED_EXTENSIONS.join(', ')}`, 'warning');
            continue;
        }
        if (file.size > ANSWER_MAX_FILE_SIZE) {
            showToast(`"${file.name}" exceeds the 15 MB limit`, 'warning');
            continue;
        }
        if (answerAttachments[taskId].some(f => f.name === file.name)) {
            showToast(`"${file.name}" is already attached`, 'warning');
            continue;
        }

        const reader = new FileReader();
        reader.onload = (e) => {
            const base64 = e.target.result.split(',')[1];
            answerAttachments[taskId].push({ name: file.name, size: file.size, content: base64 });
            updateAnswerFileList(taskId, section);
        };
        reader.onerror = () => showToast(`Could not read "${file.name}"`, 'error');
        reader.readAsDataURL(file);
    }
}

function updateAnswerFileList(taskId, section) {
    const container = section?.querySelector('.answer-file-list');
    if (!container) return;
    const files = answerAttachments[taskId] || [];
    if (files.length === 0) {
        container.innerHTML = '';
        return;
    }
    container.innerHTML = files.map((file, idx) => {
        const sizeStr = file.size < 1024 ? `${file.size} B` : `${Math.round(file.size / 1024)} KB`;
        return `<div class="answer-file-item">
            <span class="answer-file-icon">&#9671;</span>
            <span class="answer-file-name">${escapeHtml(file.name)}</span>
            <span class="answer-file-size">${sizeStr}</span>
            <button class="answer-file-remove" data-idx="${idx}" data-task-id="${escapeHtml(taskId)}" title="Remove">&times;</button>
        </div>`;
    }).join('');
    container.querySelectorAll('.answer-file-remove').forEach(btn => {
        btn.addEventListener('click', () => removeAnswerFile(Number(btn.dataset.idx), btn.dataset.taskId));
    });
}

function handleKickstartFiles(processId, questionId, fileList, section) {
    const key = `${processId}:${questionId}`;
    if (!kickstartAttachments[key]) kickstartAttachments[key] = [];

    for (const file of Array.from(fileList)) {
        const ext = file.name.slice(file.name.lastIndexOf('.')).toLowerCase();
        if (!ANSWER_ALLOWED_EXTENSIONS.includes(ext)) {
            showToast(`"${file.name}" is not allowed. Use one of: ${ANSWER_ALLOWED_EXTENSIONS.join(', ')}`, 'warning');
            continue;
        }
        if (file.size > ANSWER_MAX_FILE_SIZE) {
            showToast(`"${file.name}" exceeds the 15 MB limit`, 'warning');
            continue;
        }
        if (kickstartAttachments[key].some(f => f.name === file.name)) {
            showToast(`"${file.name}" is already attached`, 'warning');
            continue;
        }

        const reader = new FileReader();
        reader.onload = (e) => {
            const base64 = e.target.result.split(',')[1];
            kickstartAttachments[key].push({ name: file.name, size: file.size, content: base64 });
            updateKickstartFileList(key, section);
        };
        reader.onerror = () => showToast(`Could not read "${file.name}"`, 'error');
        reader.readAsDataURL(file);
    }
}

function updateKickstartFileList(key, section) {
    const container = section?.querySelector('.answer-file-list');
    if (!container) return;
    const files = kickstartAttachments[key] || [];
    if (files.length === 0) { container.innerHTML = ''; return; }
    container.innerHTML = files.map((file, idx) => {
        const sizeStr = file.size < 1024 ? `${file.size} B` : `${Math.round(file.size / 1024)} KB`;
        return `<div class="answer-file-item">
            <span class="answer-file-icon">&#9671;</span>
            <span class="answer-file-name">${escapeHtml(file.name)}</span>
            <span class="answer-file-size">${sizeStr}</span>
            <button class="answer-file-remove" data-idx="${idx}" data-key="${escapeHtml(key)}" title="Remove">&times;</button>
        </div>`;
    }).join('');
    container.querySelectorAll('.answer-file-remove').forEach(btn => {
        btn.addEventListener('click', () => removeKickstartQuestionFile(Number(btn.dataset.idx), btn.dataset.key));
    });
}

window.removeKickstartQuestionFile = function(index, key) {
    if (kickstartAttachments[key]) {
        kickstartAttachments[key].splice(index, 1);
        const [processId, questionId] = key.split(':');
        const section = document.querySelector(`.answer-attachments-section[data-process-id="${CSS.escape(processId)}"][data-question-id="${CSS.escape(questionId)}"]`);
        updateKickstartFileList(key, section);
    }
};

window.removeAnswerFile = function(index, taskId) {
    if (answerAttachments[taskId]) {
        answerAttachments[taskId].splice(index, 1);
        // Re-render: find the section for this task
        const actionItem = document.querySelector(`.action-item[data-task-id="${CSS.escape(taskId)}"]`);
        const section = actionItem?.querySelector('.answer-attachments-section');
        updateAnswerFileList(taskId, section);
    }
};

/**
 * Initialize git commit button handler
 */
function initGitCommitButton() {
    const btn = document.getElementById('git-commit-btn');
    btn?.addEventListener('click', submitGitCommit);
}

/**
 * Update git commit button visibility based on git status
 * Called from notifications.js updateGitPanel when git status changes.
 * Also resets loading state when repo becomes clean (operation completed).
 * @param {boolean} isClean - Whether the repo is clean
 */
function updateGitCommitButton(isClean) {
    const actionDiv = document.getElementById('git-commit-action');
    const btn = document.getElementById('git-commit-btn');
    if (!actionDiv) return;

    if (isClean) {
        actionDiv.style.display = 'none';
        // Reset button state when repo is clean (commit completed successfully)
        if (btn) {
            btn.disabled = false;
            btn.classList.remove('loading');
        }
    } else {
        actionDiv.style.display = 'block';
    }
}

/**
 * Submit git commit-and-push request via Claude
 * Button remains disabled until git status polling detects repo is clean again.
 */
async function submitGitCommit() {
    const btn = document.getElementById('git-commit-btn');
    if (!btn || btn.disabled) return;

    // Set loading state - button stays disabled until git status shows clean
    btn.disabled = true;
    btn.classList.add('loading');

    try {
        const response = await fetch(`${API_BASE}/api/git/commit-and-push`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' }
        });

        const result = await response.json();

        if (result.success) {
            showSignalFeedback('Commit started. Claude is organizing and pushing changes...', 'success');
            // Poll git status more frequently for a while to pick up changes
            // Button will be re-enabled by updateGitCommitButton when repo becomes clean
            setTimeout(() => {
                if (typeof pollGitStatus === 'function') pollGitStatus();
            }, 5000);
            setTimeout(() => {
                if (typeof pollGitStatus === 'function') pollGitStatus();
            }, 15000);
            setTimeout(() => {
                if (typeof pollGitStatus === 'function') pollGitStatus();
            }, 30000);
        } else {
            showToast('Failed to start commit: ' + (result.error || 'Unknown error'), 'error');
            // Re-enable button on API error - operation didn't start
            btn.disabled = false;
            btn.classList.remove('loading');
        }
    } catch (error) {
        console.error('Error starting commit:', error);
        showToast('Error starting commit: ' + error.message, 'error');
        // Re-enable button on network/fetch error - operation didn't start
        btn.disabled = false;
        btn.classList.remove('loading');
    }
    // Note: No finally block that auto-re-enables. Button stays disabled until:
    // 1. Git status polling detects repo is clean (updateGitCommitButton resets state)
    // 2. An error occurred (handled in catch blocks above)
}

/**
 * Handle interview answer submission or skip
 * @param {HTMLElement} btn - Button element
 * @param {boolean} skipped - Whether the user is skipping
 */
/**
 * Handle individual kickstart question submission from the slideout
 * Toggles the question between submitted/editable before final "Submit All"
 * @param {HTMLElement} questionEl - Question element
 * @param {boolean} submitted - Whether question is currently submitted
 */
function setKickstartQuestionSubmittedState(questionEl, submitted) {
    const actionBody = questionEl.closest('.action-item-body');
    const questionEls = actionBody ? Array.from(actionBody.querySelectorAll('.kickstart-question')) : [];
    const questionIndex = Math.max(1, questionEls.indexOf(questionEl) + 1);
    const submitBtn = questionEl.querySelector('.submit-single-kickstart');
    const freetextInput = questionEl.querySelector('.kickstart-freetext-input');

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
 * Handle individual kickstart question submission from the slideout
 * Allows toggling back to edit if the user changes their mind
 * @param {HTMLElement} btn - The per-question submit button
 */
function handleSingleKickstartAnswer(btn) {
    const questionEl = btn.closest('.kickstart-question');
    if (!questionEl) return;

    if (questionEl.classList.contains('answered')) {
        setKickstartQuestionSubmittedState(questionEl, false);
        return;
    }

    const selectedOpt = questionEl.querySelector('.answer-option.selected');
    const freetext = questionEl.querySelector('.kickstart-freetext-input')?.value?.trim() || '';
    const actionItem = questionEl.closest('.action-item');
    const processId = actionItem?.dataset.processId;
    const questionId = questionEl.dataset.questionId;
    const hasAttachments = processId && questionId
        ? (kickstartAttachments[`${processId}:${questionId}`] || []).length > 0
        : false;

    if (!selectedOpt && !freetext && !hasAttachments) {
        showToast('Please select an option, type a custom answer, or attach a file', 'warning');
        return;
    }

    setKickstartQuestionSubmittedState(questionEl, true);
}

async function handleInterviewSubmit(btn, skipped) {
    const actionItem = btn.closest('.action-item');
    const processId = actionItem?.dataset.processId;
    if (!processId) return;

    if (!skipped) {
        // Validate all questions have answers (option or free text)
        const questionEls = actionItem.querySelectorAll('.kickstart-question');
        const answers = [];
        let allAnswered = true;

        questionEls.forEach(qEl => {
            const questionId = qEl.dataset.questionId;
            const selectedOpt = qEl.querySelector('.answer-option.selected');
            const freetext = qEl.querySelector('.kickstart-freetext-input')?.value?.trim() || '';
            const questionText = qEl.querySelector('.action-question-text')?.textContent || '';
            const attachKey = `${processId}:${questionId}`;
            const qAttachments = (kickstartAttachments[attachKey] || []).map(f => ({
                name: f.name, size: f.size, content: f.content
            }));

            const hasQAttachments = qAttachments.length > 0;

            if (!selectedOpt && !freetext && !hasQAttachments) {
                allAnswered = false;
            } else if (!selectedOpt && !freetext && hasQAttachments) {
                // Attachments only — server will set answer text from saved paths
                answers.push({ question_id: questionId, question: questionText, answer: '', attachments: qAttachments });
            } else if (freetext) {
                const entry = { question_id: questionId, question: questionText, answer: freetext };
                if (qAttachments.length > 0) entry.attachments = qAttachments;
                answers.push(entry);
            } else {
                const key = selectedOpt.dataset.key;
                const label = selectedOpt.querySelector('.answer-label')?.textContent || key;
                const entry = { question_id: questionId, question: questionText, answer: `${key}: ${label}` };
                if (qAttachments.length > 0) entry.attachments = qAttachments;
                answers.push(entry);
            }
        });

        if (!allAnswered) {
            showToast('Please answer all questions before submitting', 'warning');
            return;
        }

        btn.disabled = true;
        btn.textContent = 'Submitting...';

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
                // Clean up attachment state for this process
                Object.keys(kickstartAttachments).forEach(k => {
                    if (k.startsWith(`${processId}:`)) delete kickstartAttachments[k];
                });
                actionItem.remove();
                const remaining = document.querySelectorAll('.action-item').length;
                updateActionWidget(remaining);
                actionWidgetSuppressUntil = Date.now() + 4000;
                if (remaining === 0) {
                    document.getElementById('slideout-content').innerHTML =
                        '<div class="empty-state">No pending actions</div>';
                }
                showToast('Interview answers submitted', 'success');
                if (typeof pollState === 'function') pollState();
            } else {
                showToast('Failed to submit answers: ' + (result.error || 'Unknown error'), 'error');
                btn.disabled = false;
                btn.textContent = 'Submit Answers';
            }
        } catch (error) {
            console.error('Error submitting interview answers:', error);
            showToast('Error submitting answers', 'error');
            btn.disabled = false;
            btn.textContent = 'Submit Answers';
        }
    } else {
        // Skip
        btn.disabled = true;
        btn.textContent = 'Skipping...';

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
                actionItem.remove();
                const remaining = document.querySelectorAll('.action-item').length;
                updateActionWidget(remaining);
                actionWidgetSuppressUntil = Date.now() + 4000;
                if (remaining === 0) {
                    document.getElementById('slideout-content').innerHTML =
                        '<div class="empty-state">No pending actions</div>';
                }
                showToast('Interview skipped — proceeding with kickstart', 'info');
                if (typeof pollState === 'function') pollState();
            } else {
                showToast('Failed to skip: ' + (result.error || 'Unknown error'), 'error');
                btn.disabled = false;
                btn.textContent = 'Skip & Continue';
            }
        } catch (error) {
            console.error('Error skipping interview:', error);
            showToast('Error skipping interview', 'error');
            btn.disabled = false;
            btn.textContent = 'Skip & Continue';
        }
    }
}

async function handleSplitAction(btn, approved) {
    const actionItem = btn.closest('.action-item');
    const taskId = actionItem?.dataset.taskId;
    if (!taskId) return;

    btn.disabled = true;
    btn.textContent = approved ? 'Approving...' : 'Rejecting...';

    try {
        const response = await fetch(`${API_BASE}/api/task/approve-split`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                task_id: taskId,
                approved: approved
            })
        });

        const result = await response.json();

        if (result.success) {
            // Remove the item from UI
            actionItem.remove();

            // Update widget count and suppress poll updates to prevent flicker
            const remaining = document.querySelectorAll('.action-item').length;
            updateActionWidget(remaining);
            actionWidgetSuppressUntil = Date.now() + 4000;

            if (remaining === 0) {
                document.getElementById('slideout-content').innerHTML =
                    '<div class="empty-state">No pending actions</div>';
            }

            // Trigger state refresh
            if (typeof pollState === 'function') {
                pollState();
            }
        } else {
            showToast('Failed to process split: ' + (result.error || 'Unknown error'), 'error');
            btn.disabled = false;
            btn.textContent = approved ? 'Approve Split' : 'Reject';
        }
    } catch (error) {
        console.error('Error processing split:', error);
        showToast('Error processing split', 'error');
        btn.disabled = false;
        btn.textContent = approved ? 'Approve Split' : 'Reject';
    }
}
