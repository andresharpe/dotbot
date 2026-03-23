/**
 * DOTBOT Control Panel - UI Updates
 * DOM updates from state changes
 */

/**
 * Update all UI elements from state
 * @param {Object} state - State object from server
 */
function updateUI(state) {
    if (typeof normalizeRoadmapTaskState === 'function') {
        normalizeRoadmapTaskState(state);
    }
    updateTimestamp(state.instance_id);
    updateTaskCounts(state.tasks);
    updateProgressPercent(state.tasks);
    updateSessionInfo(state.session);
    updateRunningStatus(state.session, state.control, state.analysis, state.loops);
    updateCurrentTask(state.tasks.current);
    updateUpcomingTasks(state.tasks.upcoming);
    updateCompletedTasks(state.tasks.recent_completed, state.tasks.skipped_list);
    updatePipelineView(state.tasks);
    updateControlSignalStatus(state.control);
    updateControlButtonStates(state.session, state.control, state.loops);

    // Update steering panel with instance info
    if (state.instances) {
        updateSteeringPanel(state.instances);
    }

    // Update task summary in pipeline context panel
    if (state.tasks) {
        updateTaskSummary(state.tasks);
    }

    // Update per-workflow control LEDs/buttons
    if (state.workflows && typeof updateWorkflowControlStates === 'function') {
        updateWorkflowControlStates(state.workflows);
    }

    // Refresh product file nav when doc count changes
    if (state.product_docs !== undefined && state.product_docs !== lastProductDocCount) {
        lastProductDocCount = state.product_docs;
        const navContainer = document.getElementById('product-file-nav');
        if (navContainer) delete navContainer.dataset.loaded;
        if (typeof updateProductFileNav === 'function') updateProductFileNav();
        if (typeof initProjectName === 'function') initProjectName();
    }

    // Update active processes widget on Overview tab
    updateActiveProcessesWidget();

    // Check for notable state changes and show notifications
    if (typeof checkNotifications === 'function') {
        checkNotifications(state);
    }
}

/**
 * Update timestamp display
 */
function updateTimestamp(instanceId) {
    setElementText('last-update', new Date().toLocaleTimeString());
    setElementText('instance-id', instanceId || '--');
    // Update footer mission on each poll to ensure it's current
    updateFooterMission();
}

/**
 * Update task count displays
 * @param {Object} tasks - Tasks object from state
 */
function updateTaskCounts(tasks) {
    // Overview stats
    setElementText('todo-count', tasks.todo);
    setElementText('progress-count', tasks.in_progress);
    setElementText('done-count', (tasks.done || 0) + (tasks.skipped || 0));
    setElementText('analysing-count', tasks.analysing || 0);
    setElementText('needs-input-count', tasks.needs_input || 0);
    setElementText('analysed-count', tasks.analysed || 0);

    // Pipeline counts - Unified pipeline
    setElementText('pipeline-todo-count', tasks.todo);
    setElementText('pipeline-working-count', (tasks.analysing || 0) + (tasks.in_progress || 0));
    setElementText('pipeline-needs-input-count', tasks.needs_input || 0);
    setElementText('pipeline-done-count', (tasks.done || 0) + (tasks.skipped || 0));
    // Legacy pipeline counts (kept for backward compat)
    setElementText('pipeline-analysing-count', tasks.analysing || 0);
    setElementText('pipeline-analysed-count', tasks.analysed || 0);
    setElementText('pipeline-ready-count', tasks.analysed || 0);
    setElementText('pipeline-progress-count', tasks.in_progress);
    
    // Update action widget
    if (typeof updateActionWidget === 'function') {
        updateActionWidget(tasks.action_required || 0, { fromPoll: true });
    }
}

/**
 * Update progress percentage display
 * @param {Object} tasks - Tasks object from state
 */
function updateProgressPercent(tasks) {
    // Include all statuses in total for accurate progress
    const total = (tasks.todo || 0) + (tasks.analysing || 0) + (tasks.needs_input || 0) + 
                  (tasks.analysed || 0) + (tasks.in_progress || 0) + (tasks.done || 0);
    const percent = total > 0 ? Math.round((tasks.done / total) * 100) : 0;
    setElementText('progress-percent', `${percent}%`);
}

/**
 * Update session info display
 * @param {Object} session - Session object from state
 */
function updateSessionInfo(session) {
    if (!session) {
        setElementText('session-id', '--');
        setElementText('session-status-detail', '--');
        setElementText('session-started', '--');
        setElementText('session-runtime', '--');
        setElementText('session-tasks-completed', '--');
        setElementText('session-tasks-skipped', '--');
        setElementText('session-failures', '--');
        setElementText('handoff-text', 'No handoff notes available');
        sessionStartTime = null;
        // Reset timer state
        sessionTimerElapsed = 0;
        sessionTimerLastResumed = null;
        sessionTimerStatus = null;
        sessionTimerSessionId = null;
        return;
    }

    const sessionId = session.session_id || '--';
    setElementText('session-id', sessionId);

    const status = session.status || 'unknown';
    setElementText('session-status-detail', status.toUpperCase());

    if (session.started_at) {
        const started = new Date(session.started_at);
        setElementText('session-started', started.toLocaleTimeString());
        sessionStartTime = started;
    } else {
        setElementText('session-started', '--');
        sessionStartTime = null;
    }

    // Handle timer state transitions based on session status changes
    updateTimerState(session);

    setElementText('session-tasks-completed', session.tasks_completed || 0);
    setElementText('session-tasks-skipped', session.tasks_skipped || 0);
    setElementText('session-failures', session.consecutive_failures || 0);

    // Handoff preview (mock - would come from API)
    if (session.status === 'running') {
        setElementText('handoff-text', 'Session in progress. Handoff notes will be generated on pause or completion.');
    }
}

/**
 * Manage timer state transitions based on session status changes.
 * Tracks accumulated elapsed time so pause/resume works correctly.
 * @param {Object} session - Session object from state
 */
function updateTimerState(session) {
    const newStatus = session.status || 'unknown';
    const newSessionId = session.session_id || null;

    // Detect new session (or first load) - initialize timer
    if (newSessionId && newSessionId !== sessionTimerSessionId) {
        sessionTimerSessionId = newSessionId;
        // On first load, seed elapsed from server's runtime_minutes if available
        // This gives a reasonable starting point for sessions already in progress
        if (session.runtime_minutes > 0) {
            sessionTimerElapsed = session.runtime_minutes * 60000;
        } else {
            sessionTimerElapsed = 0;
        }
        sessionTimerLastResumed = (newStatus === 'running') ? new Date() : null;
        sessionTimerStatus = newStatus;
        return;
    }

    // No status change - nothing to do
    if (newStatus === sessionTimerStatus) return;

    const prevStatus = sessionTimerStatus;
    sessionTimerStatus = newStatus;

    // Transition: anything -> running (start or resume)
    if (newStatus === 'running') {
        sessionTimerLastResumed = new Date();
        return;
    }

    // Transition: running -> paused/stopped/stopping (freeze elapsed time)
    if (prevStatus === 'running' && newStatus !== 'running') {
        if (sessionTimerLastResumed) {
            sessionTimerElapsed += (new Date() - sessionTimerLastResumed);
        }
        sessionTimerLastResumed = null;
        return;
    }
}

/**
 * Update running status indicators
 * @param {Object} session - Session object from state
 * @param {Object} control - Control object from state
 * @param {Object} analysis - Analysis loop state (optional)
 * @param {Object} loops - Combined loop state (optional)
 */
function updateRunningStatus(session, control, analysis, loops) {
    const runningLed = document.getElementById('running-led');
    const runningStatus = document.getElementById('running-status');
    const agentLed = document.getElementById('agent-led');
    const agentState = document.getElementById('agent-state');

    // Update loop status LEDs
    const workflowLed = document.getElementById('workflow-loop-led');
    const workflowActive = loops?.workflow_alive ?? false;
    // Legacy LEDs (kept for backward compat if old HTML is cached)
    const analysisLed = document.getElementById('analysis-loop-led');
    const executionLed = document.getElementById('execution-loop-led');

    // Use loops.analysis_alive if available (PID-validated), fall back to signal file check
    const analysisActive = loops?.analysis_alive ?? analysis?.running;
    const executionActive = loops?.execution_alive ?? control?.running;

    if (workflowLed) {
        workflowLed.className = workflowActive ? 'led pulse' : 'led off';
    }

    if (analysisLed) {
        analysisLed.className = analysisActive ? 'led pulse' : 'led off';
    }

    if (executionLed) {
        executionLed.className = executionActive ? 'led pulse' : 'led off';
    }

    if (!session) {
        if (runningLed) runningLed.className = 'led off';
        if (runningStatus) runningStatus.textContent = 'No Session';
        if (agentLed) agentLed.className = 'led off';
        if (agentState) agentState.innerHTML = '<span class="led off"></span><span>Idle</span>';
        // Update oscilloscope to offline/stopped state
        if (activityScope) activityScope.setState('stopped');
        return;
    }

    const status = session.status || 'unknown';

    // Helper to set LED state
    const setLed = (el, type, pulse) => {
        if (!el) return;
        el.className = pulse ? 'led pulse' : 'led';
        if (type) el.dataset.type = type;
        else delete el.dataset.type;
    };

    switch (status) {
        case 'running':
            setLed(runningLed, null, true);
            if (runningStatus) runningStatus.textContent = 'Running';
            setLed(agentLed, null, true);
            if (agentState) agentState.innerHTML = '<span class="led pulse"></span><span>Processing</span>';
            // Update oscilloscope to running state
            if (activityScope) activityScope.setState('running');
            break;
        case 'paused':
            setLed(runningLed, 'warning', false);
            if (runningStatus) runningStatus.textContent = 'Paused';
            setLed(agentLed, 'warning', false);
            if (agentState) agentState.innerHTML = '<span class="led" data-type="warning"></span><span>Paused</span>';
            // Update oscilloscope to paused state
            if (activityScope) activityScope.setState('paused');
            break;
        case 'stopping':
            setLed(runningLed, 'warning', true);
            if (runningStatus) runningStatus.textContent = 'Stopping';
            setLed(agentLed, 'warning', true);
            if (agentState) agentState.innerHTML = '<span class="led pulse" data-type="warning"></span><span>Stopping</span>';
            // Update oscilloscope to paused (stopping is similar)
            if (activityScope) activityScope.setState('paused');
            break;
        case 'idle':
            setLed(runningLed, null, false);
            if (runningStatus) runningStatus.textContent = 'Idle';
            setLed(agentLed, null, false);
            if (agentState) agentState.innerHTML = '<span class="led"></span><span>Idle</span>';
            // Update oscilloscope to idle state
            if (activityScope) activityScope.setState('idle');
            break;
        default:
            if (runningLed) runningLed.className = 'led off';
            if (runningStatus) runningStatus.textContent = 'Stopped';
            if (agentLed) agentLed.className = 'led off';
            if (agentState) agentState.innerHTML = '<span class="led off"></span><span>Idle</span>';
            // Update oscilloscope to stopped state
            if (activityScope) activityScope.setState('stopped');
    }
}

/**
 * Update current task display
 * @param {Object} task - Current task object
 */
function updateCurrentTask(task) {
    const container = document.getElementById('current-task');
    const statusBadge = document.getElementById('current-task-status');
    const agentTask = document.getElementById('agent-current-task');

    if (!task) {
        if (container) container.innerHTML = '<div class="empty-state">No task in progress</div>';
        if (statusBadge) statusBadge.textContent = '--';
        if (agentTask) agentTask.textContent = 'No active task';
        return;
    }

    const isAnalysing = task.status === 'analysing';
    if (statusBadge) statusBadge.textContent = isAnalysing ? 'ANALYSING' : 'ACTIVE';
    if (agentTask) agentTask.textContent = task.name || task.id || 'Working...';

    if (container) {
        container.innerHTML = `
            <div class="task-name">${escapeHtml(task.name || task.id || 'Unknown')}</div>
            ${task.description ? `<div class="task-description">${escapeHtml(task.description)}</div>` : ''}
            <div class="task-meta">
                ${task.category ? `<span><span data-type="primary">◈</span> ${escapeHtml(task.category)}</span>` : ''}
                ${task.priority ? `<span><span data-type="secondary">↑</span> P${escapeHtml(task.priority)}</span>` : ''}
            </div>
        `;
    }
}

/**
 * Update upcoming tasks list
 * @param {Array} tasks - Array of upcoming tasks
 */
function updateUpcomingTasks(tasks) {
    const container = document.getElementById('upcoming-tasks');

    // Ensure tasks is an array
    const taskList = Array.isArray(tasks) ? tasks : [];

    if (!container) return;

    if (taskList.length === 0) {
        container.innerHTML = '<div class="empty-state">No upcoming tasks</div>';
        return;
    }

    container.innerHTML = taskList.map(task => `
        <div class="task-list-item" data-task-id="${escapeHtml(task.id || '')}">
            <span class="task-list-item-name">${escapeHtml(task.name || task.id || 'Unknown')}</span>
            <span class="task-list-item-meta">${escapeHtml(task.category || '')}${task.workflow ? ` · ${escapeHtml(task.workflow)}` : ''}</span>
        </div>
    `).join('');
}

/**
 * Update completed tasks list
 * @param {Array} tasks - Array of completed tasks
 */
function updateCompletedTasks(tasks, skippedTasks) {
    const container = document.getElementById('completed-tasks');

    // Merge completed and skipped tasks
    const completedList = Array.isArray(tasks) ? tasks : [];
    const skippedList = Array.isArray(skippedTasks) ? skippedTasks : [];
    const taskList = [...completedList, ...skippedList];

    if (!container) return;

    if (taskList.length === 0) {
        container.innerHTML = '<div class="empty-state">No completed tasks yet</div>';
        return;
    }

    container.innerHTML = taskList.map(task => {
        const isSkipped = task.status === 'skipped';
        const meta = isSkipped ? 'skipped' : (task.category || '');
        const workflowSuffix = task.workflow ? ` · ${escapeHtml(task.workflow)}` : '';
        return `
            <div class="task-list-item done" data-task-id="${escapeHtml(task.id || '')}">
                <span class="task-list-item-name">${escapeHtml(task.name || task.id || 'Unknown')}</span>
                <span class="task-list-item-meta">${escapeHtml(meta)}${workflowSuffix}</span>
            </div>
        `;
    }).join('');
}

/**
 * Update pipeline view
 * @param {Object} tasks - Tasks object from state
 */
function updatePipelineView(tasks) {
    let upcoming = Array.isArray(tasks.upcoming) ? tasks.upcoming : [];
    let completed = Array.isArray(tasks.recent_completed) ? tasks.recent_completed : [];
    let analysing = Array.isArray(tasks.analysing_list) ? tasks.analysing_list : [];
    let needsInput = Array.isArray(tasks.needs_input_list) ? tasks.needs_input_list : [];
    let analysed = Array.isArray(tasks.analysed_list) ? tasks.analysed_list : [];
    let inProgress = tasks.current ? [tasks.current] : [];

    // Apply workflow filter if set
    if (pipelineWorkflowFilter) {
        const wf = pipelineWorkflowFilter;
        upcoming = upcoming.filter(t => t.workflow === wf);
        completed = completed.filter(t => t.workflow === wf);
        analysing = analysing.filter(t => t.workflow === wf);
        needsInput = needsInput.filter(t => t.workflow === wf);
        analysed = analysed.filter(t => t.workflow === wf);
        inProgress = inProgress.filter(t => t.workflow === wf);
    }

    // Update filter dropdown options from state.workflows
    updatePipelineFilterOptions();

    // Unified pipeline columns
    updatePipelineColumn('pipeline-todo', upcoming, 'todo');

    // "Working" combines analysing + analysed + in-progress (all actively being processed)
    const working = [...analysing, ...analysed, ...inProgress];
    // Tag each task with its phase for sub-label display
    working.forEach(t => {
        if (analysing.includes(t)) t._phase = 'analysing';
        else if (analysed.includes(t)) t._phase = 'ready';
        else t._phase = 'executing';
    });
    updatePipelineColumn('pipeline-working', working, 'active');

    updatePipelineColumn('pipeline-needs-input', needsInput, 'needs-input');
    const skipped = Array.isArray(tasks.skipped_list) ? tasks.skipped_list : [];
    const doneAndSkipped = [...completed, ...skipped];
    updatePipelineColumn('pipeline-done', doneAndSkipped, 'done');

    // Legacy columns (for backward compat if old HTML is cached)
    updatePipelineColumn('pipeline-analysing', analysing, 'analysing');
    updatePipelineColumn('pipeline-analysed', analysed, 'analysed');
    updatePipelineColumn('pipeline-ready', analysed, 'ready');
    updatePipelineColumn('pipeline-progress', inProgress, 'active');
}

/**
 * Update a pipeline column
 * @param {string} containerId - Container element ID
 * @param {Array} tasks - Tasks to display
 * @param {string} type - Column type (todo, active, done)
 */
function updatePipelineColumn(containerId, tasks, type) {
    const container = document.getElementById(containerId);
    if (!container) return;

    // Ensure tasks is an array
    const taskList = Array.isArray(tasks) ? tasks : [];

    // Track total task count for infinite scroll
    pipelineTaskCounts[containerId] = taskList.length;

    if (taskList.length === 0) {
        container.innerHTML = `<div class="empty-state">No tasks</div>`;
        return;
    }

    // Get display limit for this column
    const limit = pipelineDisplayLimits[containerId] || 10;
    const visibleTasks = taskList.slice(0, limit);

    container.innerHTML = visibleTasks.map(task => {
        const priorityClass = task.priority == 1 ? 'priority-high' :
                              task.priority == 2 ? 'priority-med' : '';
        const ignoreState = task.ignore_state || {};
        const roadmapClasses = [
            ignoreState.effective ? 'ignored' : '',
            ignoreState.manual ? 'manual-ignored' : '',
            ignoreState.auto ? 'blocked' : ''
        ].filter(Boolean).join(' ');

        // Format duration or completed date for done items
        let completedBadge = '';
        if (type === 'done' && task.status === 'skipped') {
            completedBadge = `<span class="task-tag phase-tag">skipped</span>`;
        } else if (type === 'done' && task.completed_at) {
            const duration = formatTaskDuration(task) || formatCompactDate(task.completed_at);
            completedBadge = `<span class="task-tag completed-date">${duration}</span>`;
        }

        // Show phase sub-label for tasks in the "Working" column
        const phaseLabel = task._phase ? `<span class="task-tag phase-tag">${escapeHtml(task._phase)}</span>` : '';
        const roadmapStateTags = typeof buildRoadmapTaskStatusTags === 'function'
            ? buildRoadmapTaskStatusTags(task, type)
            : '';
        const roadmapIgnoreHint = typeof buildRoadmapTaskIgnoreHint === 'function'
            ? buildRoadmapTaskIgnoreHint(task, type)
            : '';
        const roadmapActions = typeof buildRoadmapTaskActionsMarkup === 'function'
            ? buildRoadmapTaskActionsMarkup(task, type)
            : '';

        return `
            <div class="pipeline-task ${type === 'active' ? 'active' : ''} ${priorityClass} ${roadmapClasses}" data-task-id="${escapeHtml(task.id || '')}">
                <div class="task-id">${escapeHtml(task.id || '')}</div>
                <div class="task-title">${escapeHtml(task.name || task.id || 'Unknown')}</div>
                <div class="task-tags">
                    ${task.category ? `<span class="task-tag">${escapeHtml(task.category)}</span>` : ''}
                    ${task.workflow ? `<span class="task-tag tag-workflow">${escapeHtml(task.workflow)}</span>` : ''}
                    ${task.type && task.type !== 'prompt' ? `<span class="task-tag tag-type">${escapeHtml(task.type)}</span>` : ''}
                    ${phaseLabel}
                    ${type === 'active' && !task._phase ? '<span class="task-tag">↻ agent</span>' : ''}
                    ${roadmapStateTags}
                </div>
                ${roadmapIgnoreHint}
                ${roadmapActions}
                ${completedBadge}
            </div>
        `;
    }).join('');
}
/**
 * Update pipeline filter dropdown options from latest state
 */
function updatePipelineFilterOptions() {
    const select = document.getElementById('pipeline-workflow-filter');
    if (!select) return;
    const workflows = lastState?.workflows ? Object.keys(lastState.workflows) : [];
    // Only update if options changed
    const currentOptions = Array.from(select.options).slice(1).map(o => o.value);
    if (JSON.stringify(currentOptions) === JSON.stringify(workflows)) return;
    // Preserve current selection
    const current = select.value;
    select.innerHTML = '<option value="">All Workflows</option>' +
        workflows.map(name => `<option value="${escapeHtml(name)}"${name === current ? ' selected' : ''}>${escapeHtml(name)}</option>`).join('');
}

function initPipelineInfiniteScroll() {
    const columnIds = [
        'pipeline-todo', 'pipeline-working', 'pipeline-needs-input', 'pipeline-done',
        // Legacy columns (backward compat)
        'pipeline-analysing', 'pipeline-analysed', 'pipeline-ready', 'pipeline-progress'
    ];

    columnIds.forEach(containerId => {
        const container = document.getElementById(containerId);
        if (!container) return;

        container.addEventListener('scroll', () => {
            // Check if scrolled near bottom (within 50px)
            const scrollBottom = container.scrollHeight - container.scrollTop - container.clientHeight;
            if (scrollBottom < 50) {
                const currentLimit = pipelineDisplayLimits[containerId] || 10;
                const totalTasks = pipelineTaskCounts[containerId] || 0;

                // Load more if there are more tasks available
                if (currentLimit < totalTasks) {
                    pipelineDisplayLimits[containerId] = currentLimit + 5;

                    // Re-render with updated limit
                    if (lastState?.tasks) {
                        updatePipelineView(lastState.tasks);
                    }
                }
            }
        });
    });
}

/**
 * Update control signal status display
 * @param {Object} control - Control object from state
 */
function updateControlSignalStatus(control) {
    const controlLed = document.getElementById('control-led');
    const controlStatus = document.getElementById('control-signal-status');

    if (!control) {
        if (controlLed) controlLed.className = 'led off';
        if (controlStatus) controlStatus.textContent = 'No Signal';
        return;
    }

    const setControlLed = (type) => {
        if (!controlLed) return;
        controlLed.className = 'led';
        if (type) controlLed.dataset.type = type;
        else delete controlLed.dataset.type;
    };

    if (control.stop) {
        setControlLed('error');
        if (controlStatus) controlStatus.textContent = 'Stop Pending';
    } else if (control.pause) {
        setControlLed('warning');
        if (controlStatus) controlStatus.textContent = 'Pause Pending';
    } else if (control.resume) {
        setControlLed('info');
        if (controlStatus) controlStatus.textContent = 'Resume Pending';
    } else {
        if (controlLed) controlLed.className = 'led off';
        if (controlStatus) controlStatus.textContent = 'No Signal';
    }
}

/**
 * Update control button enabled/disabled states
 * @param {Object} session - Session object from state
 * @param {Object} control - Control object from state
 * @param {Object} loops - Combined loop state (optional)
 */
function updateControlButtonStates(session, control, loops) {
    const analysisAlive = loops?.analysis_alive ?? false;
    const executionAlive = loops?.execution_alive ?? false;
    const workflowAlive = loops?.workflow_alive ?? false;
    const anyAlive = loops?.any_alive ?? false;

    const btnMap = [
        // Unified workflow controls
        { action: 'start-workflow', enabled: !workflowAlive && !analysisAlive && !executionAlive },
        { action: 'stop-workflow', enabled: workflowAlive },
        { action: 'kill-workflow', enabled: workflowAlive },
        // Legacy controls (kept for backward compat)
        { action: 'start-analysis', enabled: !analysisAlive && !workflowAlive },
        { action: 'stop-analysis', enabled: analysisAlive },
        { action: 'kill-analysis', enabled: analysisAlive },
        { action: 'start-execution', enabled: !executionAlive && !workflowAlive },
        { action: 'stop-execution', enabled: executionAlive },
        { action: 'kill-execution', enabled: executionAlive },
        { action: 'start-both', enabled: (!analysisAlive || !executionAlive) && !workflowAlive },
        { action: 'stop-all', enabled: anyAlive },
        { action: 'kill-all', enabled: anyAlive },
    ];

    for (const { action, enabled } of btnMap) {
        const btn = document.querySelector(`[data-action="${action}"]`);
        if (btn) btn.disabled = !enabled;
    }
}

/**
 * Set connection status display
 * @param {string} status - Connection status (connected, error, connecting)
 */
function setConnectionStatus(status) {
    const led = document.getElementById('connection-led');
    const text = document.getElementById('connection-status');

    if (!led || !text) return;

    switch (status) {
        case 'connected':
            led.className = 'led';
            delete led.dataset.type;
            text.textContent = 'CONNECTED';
            isConnected = true;
            break;
        case 'error':
            led.className = 'led';
            led.dataset.type = 'error';
            text.textContent = 'ERROR';
            isConnected = false;
            break;
        default:
            led.className = 'led pulse';
            led.dataset.type = 'warning';
            text.textContent = 'CONNECTING';
            isConnected = false;
    }
}

/**
 * Start runtime timer
 */
function startRuntimeTimer() {
    runtimeTimer = setInterval(updateRuntime, 1000);
}

/**
 * Update runtime display.
 * Uses accumulated elapsed time model to correctly handle pause/resume.
 */
function updateRuntime() {
    if (!sessionStartTime) return;

    // Calculate total elapsed: accumulated + current running segment
    let totalElapsed = sessionTimerElapsed;
    if (sessionTimerLastResumed) {
        totalElapsed += (new Date() - sessionTimerLastResumed);
    }

    const hours = Math.floor(totalElapsed / 3600000);
    const mins = Math.floor((totalElapsed % 3600000) / 60000);
    const secs = Math.floor((totalElapsed % 60000) / 1000);

    const runtime = hours > 0
        ? `${hours}h ${mins}m ${secs}s`
        : mins > 0
            ? `${mins}m ${secs}s`
            : `${secs}s`;

    setElementText('session-runtime', runtime);
}

/**
 * Initialize project name from API
 */
async function initProjectName() {
    try {
        const response = await fetch(`${API_BASE}/api/info`);
        if (response.ok) {
            const info = await response.json();
            projectName = info.project_name || 'unknown';
            projectRoot = info.full_path || 'unknown';
            executiveSummary = info.executive_summary || null;
            hasExistingCode = info.has_existing_code || false;
            const workflowName = info.workflow || null;
            currentWorkflowName = workflowName;
            updateWorkflowBadge(workflowName);
            updateWorkflowPills(info.installed_workflows || []);
        }
    } catch (error) {
        console.warn('Could not fetch project info:', error);
        projectName = 'unknown';
        projectRoot = 'unknown';
        executiveSummary = null;
        currentWorkflowName = null;
    }
    updateProjectBadge();
    updateFooterMission();
    updateExecutiveSummary();
}

/**
 * Update project badge in header
 */
function updateProjectBadge() {
    const badge = document.getElementById('project-name');
    if (badge) {
        badge.textContent = projectName;
    }
}

/**
 * Update workflow badge in header
 * @param {string|null} name - Active workflow name, or null to hide
 */
function updateWorkflowBadge(name) {
    currentWorkflowName = name || null;
    const badge = document.getElementById('workflow-badge');
    if (!badge) return;
    if (name) {
        badge.textContent = name;
        badge.style.display = 'inline-flex';
    } else {
        badge.style.display = 'none';
    }
}

/**
 * Update workflow pills in header from installed_workflows
 * @param {Array} workflows - Array of workflow name strings
 */
function updateWorkflowPills(workflows) {
    const container = document.getElementById('workflow-pills');
    if (!container) return;
    installedWorkflows = workflows || [];
    if (workflows && workflows.length > 0) {
        // Strip the registry prefix (e.g. "iwg:iwg-bs-scoring" -> "iwg-bs-scoring")
        // so we can de-duplicate against the active workflow badge
        const activeBase = currentWorkflowName
            ? currentWorkflowName.replace(/^[^:]+:/, '')
            : null;
        const filtered = workflows.filter(name => name !== currentWorkflowName && name !== activeBase);
        container.innerHTML = filtered.map(name =>
            `<span class="workflow-pill" title="Installed workflow: ${escapeHtml(name)}">${escapeHtml(name)}</span>`
        ).join('');
    } else {
        container.innerHTML = '';
    }
}

/**
 * Update footer mission text
 */
function updateFooterMission() {
    const footerMission = document.getElementById('footer-mission');
    if (footerMission) {
        footerMission.textContent = projectRoot;
        footerMission.title = projectRoot; // Add tooltip for full path
    }
}

/**
 * Update executive summary display
 */
function updateExecutiveSummary() {
    const container = document.getElementById('executive-summary');
    if (!container) return;

    if (executiveSummary) {
        // Normal: show executive summary from product docs
        container.innerHTML = `<div class="summary-title">◈ Executive Summary</div><p>${escapeHtml(executiveSummary)}</p>`;
        container.style.display = 'block';
    } else if (typeof isNewProject !== 'undefined' && isNewProject) {
        // New project: show kickstart CTA in this slot
        renderKickstartCTA(container);
        container.style.display = 'block';
    } else {
        container.style.display = 'none';
    }
}

/**
 * Update the Active Processes widget on the Overview tab.
 * Uses processesData from processes.js if available, otherwise fetches.
 */
async function updateActiveProcessesWidget() {
    const listEl = document.getElementById('active-processes-list');
    const countBadge = document.getElementById('active-process-count');
    const viewAllLink = document.getElementById('view-all-processes');

    if (!listEl) return;

    // Use cached process data if available (populated by Processes tab or previous fetch)
    let processes = (typeof processesData !== 'undefined' && processesData.length > 0) ? processesData : null;

    // Only fetch if we have no cached data at all (first load)
    if (!processes && !updateActiveProcessesWidget._fetched) {
        updateActiveProcessesWidget._fetched = true;
        try {
            const response = await fetch(`${API_BASE}/api/processes`);
            if (response.ok) {
                const data = await response.json();
                processes = data.processes || [];
                processesData = processes; // Cache for reuse
            }
        } catch (e) {
            // Silently fail - widget is supplementary
        }
    }
    if (!processes) processes = [];

    const running = processes.filter(p => p.status === 'running' || p.status === 'starting');

    if (countBadge) countBadge.textContent = running.length;

    if (running.length === 0) {
        listEl.innerHTML = '<div class="empty-state">No running processes</div>';
        if (viewAllLink) viewAllLink.style.display = 'none';
        return;
    }

    let html = '';
    for (const proc of running.slice(0, 5)) {
        const typeLabel = proc.type ? proc.type.charAt(0).toUpperCase() + proc.type.slice(1) : '--';
        const name = proc.task_name || proc.description || proc.id;
        const timeAgo = (typeof getTimeAgo === 'function') ? getTimeAgo(proc.started_at) : '';
        html += `<div class="active-process-row">`;
        html += `  <span class="led active"></span>`;
        html += `  <span class="active-process-type">${typeLabel}</span>`;
        html += `  <span class="active-process-name">${escapeHtml(name)}</span>`;
        html += `  <span class="active-process-time">${timeAgo}</span>`;
        html += `</div>`;
    }
    listEl.innerHTML = html;

    if (viewAllLink) {
        viewAllLink.style.display = processes.length > 0 ? '' : 'none';
    }
}

/**
 * Update steering panel with instance information
 * @param {Object} instances - Instances object from state
 */
function updateSteeringPanel(instances) {
    ['workflow', 'analysis', 'execution'].forEach(type => {
        const btn = document.getElementById(`btn-${type}`);
        const led = document.getElementById(`led-${type}`);
        const pid = document.getElementById(`pid-${type}`);
        const inst = instances?.[type];

        const isAlive = inst?.alive === true;

        if (btn) btn.disabled = !isAlive;
        if (led) led.className = 'instance-led ' + (isAlive ? 'alive' : 'dead');
        if (pid) pid.textContent = inst?.pid ? `#${inst.pid}` : '';
    });

    // Update status text for selected instance
    if (typeof updateSteeringStatus === 'function') {
        updateSteeringStatus(instances);
    }

    // Enable/disable whisper input based on selection and instance status
    const canSend = typeof getSelectedInstance === 'function' &&
                    getSelectedInstance() &&
                    instances?.[getSelectedInstance()]?.alive;
    const input = document.getElementById('whisper-input');
    const priority = document.getElementById('whisper-priority');
    const sendBtn = document.getElementById('whisper-send');
    if (input) input.disabled = !canSend;
    if (priority) priority.disabled = !canSend;
    if (sendBtn) sendBtn.disabled = !canSend;
}

