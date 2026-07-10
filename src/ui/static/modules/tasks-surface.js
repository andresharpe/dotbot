/**
 * DOTBOT Control Panel - Unified Tasks Surface (#606/#551)
 * One task list with status filter chips + slim detail panel, replacing the
 * pipeline kanban and the Processes tab. Task actions (ignore/edit/delete +
 * history/restore) come from roadmap-task-actions.js; the deep-view modal
 * stays in tasks.js behind the panel's "Full detail" link.
 */

let activeTaskFilter = 'all';
let selectedTaskId = null;
let tasksDisplayLimit = 100;

const TASK_FILTER_LABELS = {
    'todo': 'Todo',
    'analysing': 'Analysing',
    'needs-input': 'Needs input',
    'needs-review': 'Needs review',
    'analysed': 'Analysed',
    'in-progress': 'In progress',
    'done': 'Done',
    'skipped': 'Skipped',
};

function initTasksSurface() {
    const chips = document.getElementById('task-filter-chips');
    chips?.addEventListener('click', (e) => {
        const chip = e.target.closest('.filter-chip');
        if (!chip) return;
        activeTaskFilter = chip.dataset.taskFilter || 'all';
        tasksDisplayLimit = 100;
        chips.querySelectorAll('.filter-chip').forEach(c => c.classList.toggle('active', c === chip));
        if (lastState?.tasks) updateTasksSurface(lastState.tasks);
    });

    // Row clicks open the detail panel. Guard order matters: action buttons
    // must win — roadmap-task-actions listens at document level, which fires
    // AFTER this container listener, so its stopPropagation can't protect us.
    document.getElementById('tasks-list')?.addEventListener('click', (e) => {
        if (e.target.closest('[data-task-action], .roadmap-task-action, .roadmap-header-action')) return;
        const showMore = e.target.closest('.tasks-show-more');
        if (showMore) {
            tasksDisplayLimit += 100;
            if (lastState?.tasks) updateTasksSurface(lastState.tasks);
            return;
        }
        const row = e.target.closest('.task-list-item');
        if (row && row.dataset.taskId) {
            selectedTaskId = row.dataset.taskId;
            renderTaskDetailPanel(findTaskById(selectedTaskId));
            document.querySelectorAll('#tasks-list .task-list-item').forEach(r =>
                r.classList.toggle('selected', r.dataset.taskId === selectedTaskId));
        }
    });

    document.getElementById('task-detail-panel')?.addEventListener('click', (e) => {
        const full = e.target.closest('.task-detail-full-link');
        if (full && selectedTaskId) {
            const task = findTaskById(selectedTaskId);
            if (task) showTaskModal(task);
        }
    });
}

/**
 * Map the active filter to state lists. Statuses mirror the old kanban
 * columns; needs-input combines input- and review-waiting (#500).
 */
function collectFilteredTasks(tasks) {
    const withStatus = (list, status) => (Array.isArray(list) ? list : []).map(t => ({ task: t, status }));
    const buckets = {
        'in-progress': [
            ...withStatus(tasks.in_progress_list, 'in-progress'),
            ...(tasks.current && !(tasks.in_progress_list || []).some(t => t.id === tasks.current.id)
                ? [{ task: tasks.current, status: 'in-progress' }] : []),
        ],
        'needs-input': [
            ...withStatus(tasks.needs_input_list, 'needs-input'),
            ...withStatus(tasks.needs_review_list, 'needs-review'),
        ],
        'analysing': withStatus(tasks.analysing_list, 'analysing'),
        'analysed': withStatus(tasks.analysed_list, 'analysed'),
        'todo': withStatus(tasks.upcoming, 'todo'),
        'done': withStatus(tasks.recent_completed, 'done'),
    };

    let rows;
    if (activeTaskFilter === 'all') {
        rows = [
            ...buckets['in-progress'], ...buckets['needs-input'], ...buckets['analysing'],
            ...buckets['analysed'], ...buckets['todo'], ...buckets['done'],
            ...withStatus(tasks.skipped_list, 'skipped'),
        ];
    } else {
        rows = buckets[activeTaskFilter] || [];
    }

    if (pipelineWorkflowFilter) {
        rows = rows.filter(r => r.task.workflow === pipelineWorkflowFilter);
    }
    return rows;
}

/**
 * Re-render the Tasks surface from state. Replaces updatePipelineView().
 */
function updateTasksSurface(tasks) {
    if (!tasks) return;
    if (typeof normalizeRoadmapTaskState === 'function') {
        normalizeRoadmapTaskState({ tasks });
    }
    updatePipelineFilterOptions();

    const container = document.getElementById('tasks-list');
    if (!container) return;

    const rows = collectFilteredTasks(tasks);
    if (rows.length === 0) {
        container.innerHTML = '<div class="empty-state">No tasks for this filter</div>';
    } else {
        const visible = rows.slice(0, tasksDisplayLimit);
        const rowsHtml = visible.map(({ task, status }) => {
            const ignoreState = task.ignore_state || {};
            const dimmed = ignoreState.effective ? ' ignored' : '';
            const selected = task.id === selectedTaskId ? ' selected' : '';
            const actions = (status === 'todo' && typeof buildRoadmapTaskActionsMarkup === 'function')
                ? buildRoadmapTaskActionsMarkup(task, 'todo') : '';
            const meta = [task.category, task.workflow].filter(Boolean).map(escapeHtml).join(' · ');
            return `
                <div class="task-list-item tasks-row${dimmed}${selected}" data-task-id="${escapeHtml(task.id || '')}" data-status="${status}">
                    <span class="task-status-word status-${status}">${TASK_FILTER_LABELS[status] || status}</span>
                    <span class="task-list-item-name">${escapeHtml(task.name || task.id || 'Unknown')}</span>
                    <span class="task-list-item-meta">${meta}</span>
                    <span class="task-row-actions">${actions}</span>
                </div>`;
        }).join('');
        const more = rows.length > tasksDisplayLimit
            ? `<button class="tasks-show-more ctrl-btn-sm" type="button">Show more (${rows.length - tasksDisplayLimit} remaining)</button>`
            : '';
        container.innerHTML = rowsHtml + more;
    }

    updateTasksProgressBar(tasks);

    // Keep the detail panel in sync with polled state
    if (selectedTaskId) {
        const task = findTaskById(selectedTaskId);
        if (task) {
            renderTaskDetailPanel(task);
        } else {
            selectedTaskId = null;
            renderTaskDetailPanel(null);
        }
    }
}

function updateTasksProgressBar(tasks) {
    const total = (tasks.todo || 0) + (tasks.analysing || 0) + (tasks.needs_input || 0) +
                  (tasks.needs_review || 0) + (tasks.analysed || 0) + (tasks.in_progress || 0) +
                  (tasks.done || 0);
    const percent = total > 0 ? Math.round(((tasks.done || 0) / total) * 100) : 0;
    const bar = document.getElementById('tasks-progress-bar');
    if (bar) bar.style.width = `${percent}%`;
}

/**
 * Slim detail panel: identity + requirements summary + actions.
 * "Full detail" opens the existing 6-section modal (tasks.js).
 */
function renderTaskDetailPanel(task) {
    const panel = document.getElementById('task-detail-panel');
    if (!panel) return;
    if (!task) {
        panel.innerHTML = '<div class="empty-state">Select a task to see details</div>';
        return;
    }
    const actions = (task.status === 'todo' && typeof buildRoadmapTaskActionsMarkup === 'function')
        ? `<div class="task-detail-actions">${buildRoadmapTaskActionsMarkup(task, 'todo')}</div>` : '';
    panel.innerHTML = `
        <div class="task-detail-header">
            <span class="task-detail-title">${escapeHtml(task.name || task.id || 'Task')}</span>
            <a href="#" class="task-detail-full-link" onclick="return false;">Full detail →</a>
        </div>
        ${actions}
        <div class="task-detail-body">
            ${buildOverviewSection(task)}
            ${buildRequirementsSection(task)}
        </div>`;
}
