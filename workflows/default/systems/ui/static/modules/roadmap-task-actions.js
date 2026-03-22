/**
 * DOTBOT Control Panel - Roadmap Task Actions
 * Ignore, edit, delete, history, and restore flows for roadmap todo tasks.
 */

let roadmapEditingTaskId = null;
let roadmapEditingTaskSource = null;

function getRoadmapActor() {
    return currentWorkflowName ? `ui:${currentWorkflowName}` : 'ui';
}

function formatRoadmapAuditActor(record) {
    const actor = record?.captured_by || record?.updated_by || '';
    const user = record?.captured_by_user || record?.updated_by_user || '';

    if (user && actor && user !== actor) {
        return `${user} via ${actor}`;
    }

    return user || actor || 'unknown';
}
function getRoadmapTaskById(taskId) {
    if (!lastState?.tasks?.upcoming) return null;
    return lastState.tasks.upcoming.find(task => task.id === taskId) || null;
}

function getRoadmapTaskSlug(name) {
    return (name || '')
        .replace(/[^a-zA-Z0-9\s-]/g, '')
        .replace(/\s+/g, '-')
        .toLowerCase();
}

function addRoadmapTaskReference(referenceMap, alias, taskId) {
    const normalizedAlias = `${alias ?? ''}`.trim().toLowerCase();
    if (!normalizedAlias) {
        return;
    }

    referenceMap.set(normalizedAlias, taskId);
}

function getRoadmapDependencyTokens(dependency) {
    const rawDependency = `${dependency ?? ''}`.trim();
    if (!rawDependency) {
        return [];
    }

    const tokens = [];
    const addToken = (value) => {
        const normalizedValue = `${value ?? ''}`.trim().toLowerCase();
        if (!normalizedValue || tokens.includes(normalizedValue)) {
            return;
        }

        tokens.push(normalizedValue);
    };

    addToken(rawDependency);

    const ordinalMatch = rawDependency.match(/^tasks?\s+(.+)$/i);
    if (ordinalMatch) {
        const ordinalExpression = ordinalMatch[1].trim();
        addToken(ordinalExpression);

        ordinalExpression.split(/\s*,\s*/).forEach(part => {
            const normalizedPart = part.replace(/^tasks?\s+/i, '').trim();
            if (!normalizedPart) {
                return;
            }

            addToken(normalizedPart);
            addToken(`task ${normalizedPart}`);
        });

        return tokens;
    }

    rawDependency.split(/\s*,\s*/).forEach(part => {
        addToken(part);
    });

    return tokens;
}

function getRoadmapTaskDependencies(task) {
    const explicitDependencies = Array.isArray(task?.dependencies)
        ? task.dependencies
        : task?.dependencies
            ? [task.dependencies]
            : [];

    const normalizedExplicitDependencies = explicitDependencies.filter(dependency => `${dependency ?? ''}`.trim());
    if (normalizedExplicitDependencies.length > 0) {
        return normalizedExplicitDependencies;
    }

    const roadmapDependencies = Array.isArray(task?.roadmap_dependencies)
        ? task.roadmap_dependencies
        : task?.roadmap_dependencies
            ? [task.roadmap_dependencies]
            : [];

    return roadmapDependencies.filter(dependency => `${dependency ?? ''}`.trim());
}

function normalizeRoadmapTaskState(state) {
    const upcoming = Array.isArray(state?.tasks?.upcoming) ? state.tasks.upcoming : [];
    if (upcoming.length === 0) return;

    const taskMap = new Map();
    const referenceMap = new Map();

    upcoming.forEach((task, index) => {
        const position = index + 1;
        taskMap.set(task.id, task);
        addRoadmapTaskReference(referenceMap, task.id, task.id);
        addRoadmapTaskReference(referenceMap, position, task.id);
        addRoadmapTaskReference(referenceMap, `task ${position}`, task.id);
        if (task.name) {
            addRoadmapTaskReference(referenceMap, task.name, task.id);
            const slug = getRoadmapTaskSlug(task.name);
            if (slug) {
                addRoadmapTaskReference(referenceMap, slug, task.id);
            }
        }
    });

    const memo = new Map();
    const resolving = new Set();

    const normalizeIgnoreState = (taskId) => {
        if (memo.has(taskId)) {
            return memo.get(taskId);
        }

        if (resolving.has(taskId)) {
            return {
                task_id: taskId,
                manual: false,
                effective: false,
                auto: false,
                blocking_task_ids: [],
                blocking_task_names: [],
                updated_at: null,
                updated_by: null,
                updated_by_user: null
            };
        }

        resolving.add(taskId);
        const task = taskMap.get(taskId);
        const manual = !!task?.ignore?.manual;
        const updatedAt = task?.ignore?.updated_at || null;
        const updatedBy = task?.ignore?.updated_by || null;
        const updatedByUser = task?.ignore?.updated_by_user || null;
        const dependencies = getRoadmapTaskDependencies(task);

        const blockingTaskIds = [];
        dependencies.forEach(dependency => {
            const dependencyTaskIds = [...new Set(
                getRoadmapDependencyTokens(dependency)
                    .map(token => referenceMap.get(token))
                    .filter(Boolean)
            )];

            dependencyTaskIds.forEach(dependencyTaskId => {
                if (!taskMap.has(dependencyTaskId)) {
                    return;
                }

                const dependencyState = normalizeIgnoreState(dependencyTaskId);
                if (!dependencyState.effective) {
                    return;
                }

                if (dependencyState.manual) {
                    if (!blockingTaskIds.includes(dependencyTaskId)) {
                        blockingTaskIds.push(dependencyTaskId);
                    }
                    return;
                }

                if (Array.isArray(dependencyState.blocking_task_ids) && dependencyState.blocking_task_ids.length > 0) {
                    dependencyState.blocking_task_ids.forEach(blockingTaskId => {
                        if (!blockingTaskIds.includes(blockingTaskId)) {
                            blockingTaskIds.push(blockingTaskId);
                        }
                    });
                    return;
                }

                if (!blockingTaskIds.includes(dependencyTaskId)) {
                    blockingTaskIds.push(dependencyTaskId);
                }
            });
        });

        const blockingTaskNames = blockingTaskIds.map(blockingTaskId => {
            const blockingTask = taskMap.get(blockingTaskId);
            return blockingTask?.name || blockingTaskId;
        });

        const ignoreState = {
            task_id: taskId,
            manual,
            effective: manual || blockingTaskIds.length > 0,
            auto: !manual && blockingTaskIds.length > 0,
            blocking_task_ids: blockingTaskIds,
            blocking_task_names: [...new Set(blockingTaskNames)],
            updated_at: updatedAt,
            updated_by: updatedBy,
            updated_by_user: updatedByUser
        };

        memo.set(taskId, ignoreState);
        resolving.delete(taskId);
        return ignoreState;
    };

    upcoming.forEach(task => {
        const ignoreState = normalizeIgnoreState(task.id);
        task.ignore_state = ignoreState;
        task.ignored = ignoreState.effective;
        task.disabled = ignoreState.auto;
    });
}
function buildRoadmapTaskStatusTags(task, type) {
    if (type !== 'todo') return '';

    const ignoreState = task.ignore_state || {};
    const tags = [];

    if (ignoreState.manual) {
        tags.push('<span class="task-tag task-tag-ignored">ignored</span>');
    } else if (ignoreState.auto) {
        tags.push('<span class="task-tag task-tag-blocked">blocked</span>');
    }

    return tags.join('');
}

function buildRoadmapTaskIgnoreHint(task, type) {
    if (type !== 'todo') return '';

    const ignoreState = task.ignore_state || {};
    if (ignoreState.auto && Array.isArray(ignoreState.blocking_task_names) && ignoreState.blocking_task_names.length > 0) {
        return `<div class="roadmap-task-note">Blocked by ${escapeHtml(ignoreState.blocking_task_names.join(', '))}</div>`;
    }

    if (ignoreState.manual) {
        const actorLabel = formatRoadmapAuditActor({
            updated_by: ignoreState.updated_by,
            updated_by_user: ignoreState.updated_by_user
        });
        const actor = actorLabel && actorLabel !== 'unknown' ? ` by ${escapeHtml(actorLabel)}` : '';
        return `<div class="roadmap-task-note">Ignored${actor}</div>`;
    }

    return '';
}
function buildRoadmapTaskActionsMarkup(task, type) {
    if (type !== 'todo') return '';

    const ignoreState = task.ignore_state || {};
    const ignoreLabel = ignoreState.manual ? 'ACKNOWLEDGE' : ignoreState.auto ? 'BLOCKED' : 'IGNORE';
    const ignoreDisabled = ignoreState.auto ? 'disabled' : '';
    const nextIgnored = ignoreState.manual ? 'false' : 'true';
    const ignoreClasses = [
        'roadmap-task-action',
        ignoreState.manual ? 'acknowledged' : '',
        ignoreState.auto ? 'blocked-state' : ''
    ].filter(Boolean).join(' ');

    return `
        <div class="roadmap-task-actions">
            <button class="${ignoreClasses}" data-task-action="toggle-ignore" data-task-id="${escapeHtml(task.id || '')}" data-ignore-target="${nextIgnored}" ${ignoreDisabled}>${ignoreLabel}</button>
            <button class="roadmap-task-action" data-task-action="edit-task" data-task-id="${escapeHtml(task.id || '')}">EDIT</button>
            <button class="roadmap-task-action danger" data-task-action="delete-task" data-task-id="${escapeHtml(task.id || '')}">DELETE</button>
        </div>
    `;
}

function initRoadmapTaskActions() {
    document.addEventListener('click', async (event) => {
        const actionButton = event.target.closest('[data-task-action]');
        if (!actionButton) return;

        event.preventDefault();
        event.stopPropagation();

        if (actionButton.disabled) {
            return;
        }

        const { taskAction, taskId, versionId, ignoreTarget } = actionButton.dataset;

        switch (taskAction) {
            case 'toggle-ignore':
                await toggleRoadmapTaskIgnore(taskId, ignoreTarget === 'true');
                break;
            case 'edit-task':
                openRoadmapTaskEditModal(taskId);
                break;
            case 'delete-task':
                await deleteRoadmapTask(taskId);
                break;
            case 'restore-version':
                await restoreRoadmapTaskVersion(taskId, versionId);
                break;
            default:
                break;
        }
    });

    document.getElementById('roadmap-deleted-btn')?.addEventListener('click', openDeletedTasksModal);

    document.getElementById('task-edit-modal-close')?.addEventListener('click', closeRoadmapTaskEditModal);
    document.getElementById('task-edit-cancel')?.addEventListener('click', closeRoadmapTaskEditModal);
    document.getElementById('task-edit-save')?.addEventListener('click', submitRoadmapTaskEdit);
    document.getElementById('task-edit-refresh-history')?.addEventListener('click', () => {
        if (roadmapEditingTaskId) {
            loadRoadmapTaskHistory(roadmapEditingTaskId);
        }
    });
    document.getElementById('task-edit-modal')?.addEventListener('click', (event) => {
        if (event.target.id === 'task-edit-modal') {
            closeRoadmapTaskEditModal();
        }
    });

    document.getElementById('deleted-tasks-close')?.addEventListener('click', closeDeletedTasksModal);
    document.getElementById('deleted-tasks-modal-close')?.addEventListener('click', closeDeletedTasksModal);
    document.getElementById('deleted-tasks-modal')?.addEventListener('click', (event) => {
        if (event.target.id === 'deleted-tasks-modal') {
            closeDeletedTasksModal();
        }
    });

    document.addEventListener('keydown', (event) => {
        if (event.key !== 'Escape') return;
        closeRoadmapTaskEditModal();
        closeDeletedTasksModal();
    });
}

function openRoadmapTaskEditModal(taskId) {
    const task = getRoadmapTaskById(taskId);
    if (!task) {
        showToast('Task not found in roadmap state', 'error');
        return;
    }

    roadmapEditingTaskId = taskId;
    roadmapEditingTaskSource = task;
    document.getElementById('task-edit-modal-title').textContent = `Edit Task: ${task.name || task.id}`;
    document.getElementById('task-edit-id').value = task.id || '';
    document.getElementById('task-edit-name').value = task.name || '';
    document.getElementById('task-edit-description').value = task.description || '';
    document.getElementById('task-edit-category').value = task.category || '';
    document.getElementById('task-edit-priority').value = task.priority || '';
    document.getElementById('task-edit-effort').value = task.effort || '';
    document.getElementById('task-edit-dependencies').value = formatTaskListForTextarea(task.dependencies);
    document.getElementById('task-edit-steps').value = formatTaskListForTextarea(task.steps);
    document.getElementById('task-edit-criteria').value = formatTaskListForTextarea(task.acceptance_criteria);
    document.getElementById('task-edit-history-list').innerHTML = '<div class="loading-state">Loading version history...</div>';

    document.getElementById('task-edit-modal')?.classList.add('visible');
    loadRoadmapTaskHistory(taskId);
}

function closeRoadmapTaskEditModal() {
    roadmapEditingTaskId = null;
    roadmapEditingTaskSource = null;
    document.getElementById('task-edit-modal')?.classList.remove('visible');
}

function getTaskListItemText(item) {
    if (item == null) {
        return '';
    }

    if (typeof item === 'string') {
        return item;
    }

    if (typeof item !== 'object') {
        return `${item}`;
    }

    for (const key of ['text', 'title', 'name', 'description', 'criterion', 'label', 'value', 'step', 'requirement', 'content', 'summary']) {
        if (typeof item[key] === 'string' && item[key].trim()) {
            return item[key];
        }
    }

    const firstStringValue = Object.values(item).find(value => typeof value === 'string' && value.trim());
    return firstStringValue || '';
}

function getTaskListObjectTextKey(sourceItems) {
    if (!Array.isArray(sourceItems)) {
        return null;
    }

    for (const item of sourceItems) {
        if (!item || typeof item !== 'object' || Array.isArray(item)) {
            continue;
        }

        for (const key of ['text', 'title', 'name', 'description', 'criterion', 'label', 'value', 'step', 'requirement', 'content', 'summary']) {
            if (typeof item[key] === 'string' || key in item) {
                return key;
            }
        }

        for (const [key, value] of Object.entries(item)) {
            if (typeof value === 'string' && value.trim()) {
                return key;
            }
        }
    }

    return null;
}

function formatTaskListForTextarea(value) {
    if (!Array.isArray(value)) {
        return value ? `${value}` : '';
    }

    return value
        .map(item => getTaskListItemText(item))
        .filter(Boolean)
        .join('\n');
}

function parseTaskListFromTextarea(value) {
    return value
        .split(/\r?\n/)
        .map(item => item.trim())
        .filter(Boolean);
}

function mergeTaskListFromTextarea(value, sourceItems) {
    const lines = parseTaskListFromTextarea(value);
    const textKey = getTaskListObjectTextKey(sourceItems);
    if (!textKey) {
        return lines;
    }

    const templates = Array.isArray(sourceItems)
        ? sourceItems.filter(item => item && typeof item === 'object' && !Array.isArray(item))
        : [];
    const fallbackTemplate = templates[templates.length - 1] || {};

    return lines.map((line, index) => {
        const template = templates[index] || fallbackTemplate;
        const nextItem = { ...template, [textKey]: line };

        if (!templates[index]) {
            for (const flagKey of ['done', 'met', 'checked', 'completed']) {
                if (flagKey in nextItem) {
                    nextItem[flagKey] = false;
                }
            }
        }

        return nextItem;
    });
}

async function toggleRoadmapTaskIgnore(taskId, ignored) {
    try {
        const response = await fetch(`${API_BASE}/api/task/ignore`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                task_id: taskId,
                ignored,
                actor: getRoadmapActor()
            })
        });
        const result = await response.json();
        if (!result.success) {
            throw new Error(result.error || 'Unknown error');
        }

        showToast(ignored ? 'Task ignored' : 'Task restored to roadmap', 'success');
        refreshRoadmapState(100);
    } catch (error) {
        showToast(`Failed to update ignore state: ${error.message}`, 'error');
    }
}

async function submitRoadmapTaskEdit() {
    const taskId = document.getElementById('task-edit-id')?.value;
    const name = document.getElementById('task-edit-name')?.value?.trim() || '';
    const description = document.getElementById('task-edit-description')?.value?.trim() || '';
    const category = document.getElementById('task-edit-category')?.value?.trim() || '';
    const priorityValue = document.getElementById('task-edit-priority')?.value?.trim() || '';
    const effort = document.getElementById('task-edit-effort')?.value?.trim() || '';
    const dependencies = parseTaskListFromTextarea(document.getElementById('task-edit-dependencies')?.value || '');
    const steps = mergeTaskListFromTextarea(document.getElementById('task-edit-steps')?.value || '', roadmapEditingTaskSource?.steps);
    const acceptanceCriteria = mergeTaskListFromTextarea(document.getElementById('task-edit-criteria')?.value || '', roadmapEditingTaskSource?.acceptance_criteria);
    const saveButton = document.getElementById('task-edit-save');

    if (!taskId || !name || !description) {
        showToast('Task name and description are required', 'warning');
        return;
    }

    const priority = Number.parseInt(priorityValue, 10);
    if (Number.isNaN(priority)) {
        showToast('Priority must be a number', 'warning');
        return;
    }

    const updates = {
        name,
        description,
        category,
        priority,
        effort,
        dependencies,
        steps,
        acceptance_criteria: acceptanceCriteria
    };

    try {
        if (saveButton) {
            saveButton.disabled = true;
            saveButton.textContent = 'Saving...';
        }

        const response = await fetch(`${API_BASE}/api/task/edit`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                task_id: taskId,
                actor: getRoadmapActor(),
                updates
            })
        });
        const result = await response.json();
        if (!result.success) {
            throw new Error(result.error || 'Unknown error');
        }

        showToast('Task updated and versioned', 'success');
        closeRoadmapTaskEditModal();
        refreshRoadmapState(100);
    } catch (error) {
        showToast(`Failed to save task: ${error.message}`, 'error');
    } finally {
        if (saveButton) {
            saveButton.disabled = false;
            saveButton.textContent = 'Save Changes';
        }
    }
}

async function loadRoadmapTaskHistory(taskId) {
    const historyList = document.getElementById('task-edit-history-list');
    if (!historyList) return;

    historyList.innerHTML = '<div class="loading-state">Loading version history...</div>';

    try {
        const response = await fetch(`${API_BASE}/api/task/history/${encodeURIComponent(taskId)}`);
        if (!response.ok) {
            const message = await response.text();
            throw new Error(message || `HTTP ${response.status}`);
        }

        const history = await response.json();
        if (history?.success === false) {
            throw new Error(history.error || 'Failed to load history');
        }

        historyList.innerHTML = renderRoadmapTaskHistory(history);
    } catch (error) {
        historyList.innerHTML = `<div class="empty-state">Failed to load history: ${escapeHtml(error.message)}</div>`;
    }
}

function renderRoadmapTaskHistory(history) {
    const editedVersions = Array.isArray(history?.edited_versions) ? history.edited_versions : [];
    const deletedVersions = Array.isArray(history?.deleted_versions) ? history.deleted_versions : [];
    const versions = [...editedVersions, ...deletedVersions]
        .sort((left, right) => new Date(right.captured_at || 0) - new Date(left.captured_at || 0));

    if (versions.length === 0) {
        return '<div class="empty-state">No prior versions recorded for this task.</div>';
    }

    return versions.map(version => {
        const description = version?.task?.description || 'No description snapshot';
        const kindLabel = version.archive_kind === 'delete' ? 'DELETE' : 'EDIT';
        return `
            <div class="task-version-card">
                <div class="task-version-meta">
                    <span class="task-version-kind ${version.archive_kind === 'delete' ? 'delete' : 'edit'}">${kindLabel}</span>
                    <span class="task-version-time">${escapeHtml(formatFriendlyDate(version.captured_at))}</span>
                </div>
                <div class="task-version-title">${escapeHtml(version?.task?.name || history.task_id || 'Task version')}</div>
                <div class="task-version-description">${escapeHtml(description)}</div>
                <div class="task-version-footer">
                    <span class="task-version-actor">${escapeHtml(formatRoadmapAuditActor(version))}</span>
                    <button class="roadmap-task-action" data-task-action="restore-version" data-task-id="${escapeHtml(version.task_id || history.task_id || '')}" data-version-id="${escapeHtml(version.version_id || '')}">Restore</button>
                </div>
            </div>
        `;
    }).join('');
}

async function deleteRoadmapTask(taskId) {
    const task = getRoadmapTaskById(taskId);
    const taskLabel = task?.name || taskId;
    if (!window.confirm(`Delete "${taskLabel}" from the roadmap?`)) {
        return;
    }

    try {
        const response = await fetch(`${API_BASE}/api/task/delete`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                task_id: taskId,
                actor: getRoadmapActor()
            })
        });
        const result = await response.json();
        if (!result.success) {
            throw new Error(result.error || 'Unknown error');
        }

        showToast('Task deleted and archived', 'success');
        closeRoadmapTaskEditModal();
        refreshRoadmapState(100);
    } catch (error) {
        showToast(`Failed to delete task: ${error.message}`, 'error');
    }
}

async function restoreRoadmapTaskVersion(taskId, versionId) {
    try {
        const response = await fetch(`${API_BASE}/api/task/restore-version`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                task_id: taskId,
                version_id: versionId,
                actor: getRoadmapActor()
            })
        });
        const result = await response.json();
        if (!result.success) {
            throw new Error(result.error || 'Unknown error');
        }

        showToast('Task version restored', 'success');
        closeRoadmapTaskEditModal();
        refreshRoadmapState(100);
        if (document.getElementById('deleted-tasks-modal')?.classList.contains('visible')) {
            setTimeout(openDeletedTasksModal, 200);
        }
    } catch (error) {
        showToast(`Failed to restore version: ${error.message}`, 'error');
    }
}

async function openDeletedTasksModal() {
    const modal = document.getElementById('deleted-tasks-modal');
    const list = document.getElementById('deleted-tasks-list');
    const summary = document.getElementById('deleted-tasks-summary');
    if (!modal || !list || !summary) return;

    modal.classList.add('visible');
    list.innerHTML = '<div class="loading-state">Loading deleted task archive...</div>';
    summary.textContent = 'Loading archive...';

    try {
        const response = await fetch(`${API_BASE}/api/task/deleted`);
        if (!response.ok) {
            const message = await response.text();
            throw new Error(message || `HTTP ${response.status}`);
        }
        const data = await response.json();
        const versions = Array.isArray(data?.deleted_versions) ? data.deleted_versions : [];
        const restoredCount = versions.filter(version => version?.is_restored === true).length;
        const pendingRestoreCount = versions.length - restoredCount;
        summary.textContent = `${versions.length} archived deletion${versions.length === 1 ? '' : 's'} | ${pendingRestoreCount} pending restore`;

        if (versions.length === 0) {
            list.innerHTML = '<div class="empty-state">No deleted tasks archived yet.</div>';
            return;
        }

        list.innerHTML = versions.map(version => {
            const isRestored = version?.is_restored === true;
            const cardClasses = ['task-version-card', 'deleted-archive-card', isRestored ? 'restored' : ''].filter(Boolean).join(' ');
            const actionLabel = isRestored ? 'RESTORED' : 'Restore';
            const actionAttrs = isRestored ? 'disabled aria-disabled="true"' : '';
            const restoredBadge = isRestored ? '<span class="task-version-kind restored">RESTORED</span>' : '';
            const restoredWatermark = isRestored ? '<div class="task-version-watermark">RESTORED</div>' : '';

            return `
                <div class="${cardClasses}">
                    ${restoredWatermark}
                    <div class="task-version-meta">
                        <span class="task-version-kind delete">DELETE</span>
                        ${restoredBadge}
                        <span class="task-version-time">${escapeHtml(formatFriendlyDate(version.captured_at))}</span>
                    </div>
                    <div class="task-version-title">${escapeHtml(version?.task?.name || version.task_id || 'Deleted task')}</div>
                    <div class="task-version-description">${escapeHtml(version?.task?.description || 'No archived description')}</div>
                    <div class="task-version-footer deleted-archive-footer">
                        <span class="task-version-actor deleted-archive-actor">${escapeHtml(formatRoadmapAuditActor(version))}</span>
                        <button type="button" class="deleted-archive-action${isRestored ? ' restored-state' : ''}" data-task-action="restore-version" data-task-id="${escapeHtml(version.task_id || '')}" data-version-id="${escapeHtml(version.version_id || '')}" ${actionAttrs}>${actionLabel}</button>
                    </div>
                </div>
            `;
        }).join('');
    } catch (error) {
        summary.textContent = 'Archive unavailable';
        list.innerHTML = `<div class="empty-state">Failed to load deleted archive: ${escapeHtml(error.message)}</div>`;
    }
}
function closeDeletedTasksModal() {
    document.getElementById('deleted-tasks-modal')?.classList.remove('visible');
}

function refreshRoadmapState(delayMs = 0) {
    window.setTimeout(() => {
        if (typeof pollState === 'function') {
            pollState();
        }
    }, delayMs);
}










