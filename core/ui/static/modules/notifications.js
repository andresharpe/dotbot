/**
 * DOTBOT Control Panel - Notifications Module
 * Tracks state changes and shows toast notifications for important events.
 * Also manages git status polling and display.
 */

// Previous state for change detection
let prevNotifyState = null;
let notificationSoundEnabled = false;

// Git status polling interval (slower than main poll since git is heavier)
const GIT_POLL_INTERVAL = 10000; // 10 seconds
let gitPollTimer = null;
let lastGitStatus = null;

/**
 * Initialize notifications system
 */
function initNotifications() {
    if (typeof initNotificationAudio === 'function') {
        initNotificationAudio();
    }

    // Start git status polling
    pollGitStatus();
    gitPollTimer = setInterval(pollGitStatus, GIT_POLL_INTERVAL);
}

function setNotificationSoundEnabled(enabled) {
    notificationSoundEnabled = !!enabled;
    if (!notificationSoundEnabled && typeof stopNotificationAudio === 'function') {
        stopNotificationAudio();
    }
}

function playConfiguredNotificationSound(cue, options = {}) {
    if (!notificationSoundEnabled || typeof playNotificationSound !== 'function') return;
    playNotificationSound(cue, options);
}

/**
 * Check state for notable changes and fire toast notifications
 * Called from updateUI on each poll cycle.
 * @param {Object} state - Current state from server
 */
function checkNotifications(state) {
    if (!prevNotifyState) {
        // First load - just store state, don't fire notifications
        prevNotifyState = snapshotState(state);
        return;
    }

    const prev = prevNotifyState;
    const curr = snapshotState(state);
    const taskMoves = getTaskMoves(prev, curr);

    // Task completed
    if (curr.done > prev.done) {
        const count = curr.done - prev.done;
        const taskName = findNewlyCompletedTask(state, prev);
        if (taskName) {
            showToast(`Task completed: ${taskName}`, 'success', 6000);
        } else {
            showToast(`${count} task${count > 1 ? 's' : ''} completed`, 'success', 6000);
        }
    }

    // Task needs input (action required increased)
    if (curr.needsInput > prev.needsInput) {
        const count = curr.needsInput - prev.needsInput;
        showToast(`${count} task${count > 1 ? 's' : ''} need${count === 1 ? 's' : ''} your input`, 'warning', 8000);
    }

    // New task started (in-progress increased)
    if (curr.inProgress > prev.inProgress && curr.currentTaskName && curr.currentTaskName !== prev.currentTaskName) {
        showToast(`Started: ${curr.currentTaskName}`, 'info', 5000);
    }

    // Session status changes
    if (curr.sessionStatus !== prev.sessionStatus && prev.sessionStatus) {
        if (curr.sessionStatus === 'running' && prev.sessionStatus !== 'running') {
            showToast('Session started', 'info', 4000);
            playConfiguredNotificationSound('session');
        } else if (curr.sessionStatus === 'paused' && prev.sessionStatus === 'running') {
            showToast('Session paused', 'warning', 4000);
            playConfiguredNotificationSound('warning');
        } else if (curr.sessionStatus === 'stopped' && prev.sessionStatus === 'running') {
            showToast('Session stopped', 'info', 4000);
            playConfiguredNotificationSound('warning');
        }
    }

    // Consecutive failures increased
    if (curr.failures > prev.failures && curr.failures > 0) {
        showToast(`Consecutive failure #${curr.failures}`, 'error', 6000);
        playConfiguredNotificationSound('error');
    }

    // Task skipped
    if (curr.skipped > prev.skipped) {
        showToast('Task skipped', 'warning', 5000);
    }

    if (taskMoves.length > 0) {
        playTaskMoveSounds(taskMoves);
    } else if (hasTaskMovement(prev, curr)) {
        playConfiguredNotificationSound('movement');
    }

    prevNotifyState = curr;
}

/**
 * Extract a snapshot of values we want to track for change detection
 * @param {Object} state - Full state object
 * @returns {Object} Snapshot of tracked values
 */
function snapshotState(state) {
    return {
        todo: state.tasks?.todo || 0,
        analysing: state.tasks?.analysing || 0,
        analysed: state.tasks?.analysed || 0,
        done: state.tasks?.done || 0,
        inProgress: state.tasks?.in_progress || 0,
        needsInput: state.tasks?.needs_input || 0,
        skipped: state.tasks?.skipped || 0,
        currentTaskName: state.tasks?.current?.name || null,
        sessionStatus: state.session?.status || null,
        failures: state.session?.consecutive_failures || 0,
        taskStages: buildTaskStageMap(state.tasks),
        // Store completed task IDs for diff
        completedIds: (state.tasks?.recent_completed || []).map(t => t.id)
    };
}

/**
 * Find a newly completed task name by comparing previous and current state
 * @param {Object} state - Current state
 * @param {Object} prev - Previous snapshot
 * @returns {string|null} Name of newly completed task, or null
 */
function findNewlyCompletedTask(state, prev) {
    const currentCompleted = state.tasks?.recent_completed || [];
    const prevIds = new Set(prev.completedIds || []);

    for (const task of currentCompleted) {
        if (!prevIds.has(task.id)) {
            return task.name || task.id;
        }
    }
    return null;
}

function hasTaskMovement(prev, curr) {
    return prev.todo !== curr.todo ||
        prev.analysing !== curr.analysing ||
        prev.analysed !== curr.analysed ||
        prev.done !== curr.done ||
        prev.inProgress !== curr.inProgress ||
        prev.needsInput !== curr.needsInput ||
        prev.skipped !== curr.skipped;
}

function buildTaskStageMap(tasks) {
    const stageMap = {};

    for (const task of tasks?.upcoming || []) {
        if (task?.id) stageMap[task.id] = 'todo';
    }
    for (const task of tasks?.analysing_list || []) {
        if (task?.id) stageMap[task.id] = 'analysing';
    }
    for (const task of tasks?.analysed_list || []) {
        if (task?.id) stageMap[task.id] = 'analysed';
    }
    for (const task of tasks?.needs_input_list || []) {
        if (task?.id) stageMap[task.id] = 'needs_input';
    }
    if (tasks?.current?.id) {
        stageMap[tasks.current.id] = 'in_progress';
    }
    for (const task of tasks?.recent_completed || []) {
        if (task?.id) stageMap[task.id] = 'done';
    }
    for (const task of tasks?.skipped_list || []) {
        if (task?.id) stageMap[task.id] = 'skipped';
    }

    return stageMap;
}

function getTaskMoves(prev, curr) {
    const moves = [];
    const prevStages = prev.taskStages || {};
    const currStages = curr.taskStages || {};

    for (const [taskId, toStage] of Object.entries(currStages)) {
        const fromStage = prevStages[taskId];
        if ((fromStage && fromStage !== toStage) || (!fromStage && toStage !== 'todo')) {
            moves.push({ taskId, fromStage, toStage });
        }
    }

    return moves;
}

function playTaskMoveSounds(moves) {
    const maxQueuedMoves = 8;
    const queue = moves
        .map((move, index) => ({ move, index }))
        .sort((a, b) => {
            const priorityDiff = getTaskMovePriority(b.move) - getTaskMovePriority(a.move);
            return priorityDiff !== 0 ? priorityDiff : a.index - b.index;
        })
        .slice(0, maxQueuedMoves)
        .map(entry => entry.move);

    queue.forEach((move, index) => {
        playConfiguredNotificationSound(getCueForTaskMove(move), { delayMs: index * 240 });
    });

    if (moves.length > maxQueuedMoves) {
        playConfiguredNotificationSound('warning', { delayMs: queue.length * 240 });
    }
}

function getCueForTaskMove(move) {
    if (move.toStage === 'needs_input') return 'horn';
    if (move.toStage === 'done') return 'success';
    if (move.toStage === 'in_progress') return 'start';
    if (move.toStage === 'skipped') return 'skipped';
    if (move.toStage === 'todo' && move.fromStage !== 'todo') return 'warning';
    return 'movement';
}

function getTaskMovePriority(move) {
    if (move.toStage === 'needs_input') return 5;
    if (move.toStage === 'done') return 4;
    if (move.toStage === 'in_progress') return 3;
    if (move.toStage === 'skipped') return 2;
    if (move.toStage === 'todo' && move.fromStage !== 'todo') return 1;
    return 0;
}

/**
 * Git status code mappings for user-friendly display
 */
const GIT_STATUS_MAP = {
    'A': { label: 'Add', cssClass: 'added' },
    'M': { label: 'Mod', cssClass: 'modified' },
    'D': { label: 'Del', cssClass: 'deleted' },
    'R': { label: 'Ren', cssClass: 'modified' },
    'C': { label: 'Copy', cssClass: 'added' },
    '?': { label: 'New', cssClass: 'untracked' },
    '??': { label: 'New', cssClass: 'untracked' },
};

/**
 * Get CSS class for git file status letter
 * @param {string} status - Git status letter (A, M, D, ?)
 * @returns {string} CSS class
 */
function getGitStatusClass(status) {
    return (GIT_STATUS_MAP[status] || { cssClass: 'modified' }).cssClass;
}

/**
 * Get user-friendly label for git file status letter
 * @param {string} status - Git status letter (A, M, D, ?)
 * @returns {string} Friendly label
 */
function getGitStatusLabel(status) {
    return (GIT_STATUS_MAP[status] || { label: status }).label;
}

/**
 * Poll git status endpoint and update the sidebar panel
 */
async function pollGitStatus() {
    try {
        const response = await fetch(`${API_BASE}/api/git-status`);
        if (!response.ok) return;

        const git = await response.json();
        lastGitStatus = git;
        updateGitPanel(git);
    } catch (error) {
        console.warn('Git status poll error:', error);
    }
}

/**
 * Update the git status panel in the sidebar
 * @param {Object} git - Git status object from API
 */
function updateGitPanel(git) {
    // Update commit button visibility (defined in actions.js)
    if (typeof updateGitCommitButton === 'function') {
        updateGitCommitButton(git.clean);
    }

    // Branch name
    setElementText('git-branch', git.branch || '--');

    // Commit hash
    setElementText('git-commit', git.commit || '');

    // LED indicator
    const gitLed = document.getElementById('git-led');
    if (gitLed) {
        if (git.clean) {
            gitLed.className = 'led';
            delete gitLed.dataset.type;
        } else {
            gitLed.className = 'led';
            gitLed.dataset.type = 'warning';
        }
    }

    // Upstream status
    const upstreamRow = document.getElementById('git-upstream-row');
    const upstreamLabel = document.getElementById('git-upstream-label');
    if (upstreamRow && upstreamLabel) {
        if (git.upstream) {
            upstreamRow.style.display = 'flex';
            if (git.ahead > 0 && git.behind > 0) {
                upstreamLabel.innerHTML = `<span class="ahead">+${git.ahead}</span> / <span class="behind">-${git.behind}</span>`;
            } else if (git.ahead > 0) {
                upstreamLabel.innerHTML = `<span class="ahead">+${git.ahead} ahead</span>`;
            } else if (git.behind > 0) {
                upstreamLabel.innerHTML = `<span class="behind">-${git.behind} behind</span>`;
            } else {
                upstreamLabel.innerHTML = `<span class="synced">Up to date</span>`;
            }
        } else {
            upstreamRow.style.display = 'none';
        }
    }

    // Count badges
    const stagedBadge = document.getElementById('git-staged-count');
    const unstagedBadge = document.getElementById('git-unstaged-count');
    const untrackedBadge = document.getElementById('git-untracked-count');
    const cleanBadge = document.getElementById('git-clean-badge');

    if (git.clean) {
        if (stagedBadge) stagedBadge.style.display = 'none';
        if (unstagedBadge) unstagedBadge.style.display = 'none';
        if (untrackedBadge) untrackedBadge.style.display = 'none';
        if (cleanBadge) cleanBadge.style.display = 'inline';
    } else {
        if (cleanBadge) cleanBadge.style.display = 'none';

        if (stagedBadge) {
            if (git.staged_count > 0) {
                stagedBadge.style.display = 'inline-flex';
                stagedBadge.innerHTML = `<span class="badge-label">Staged</span><span class="badge-count">${git.staged_count}</span>`;
            } else {
                stagedBadge.style.display = 'none';
            }
        }

        if (unstagedBadge) {
            if (git.unstaged_count > 0) {
                unstagedBadge.style.display = 'inline-flex';
                unstagedBadge.innerHTML = `<span class="badge-label">Modified</span><span class="badge-count">${git.unstaged_count}</span>`;
            } else {
                unstagedBadge.style.display = 'none';
            }
        }

        if (untrackedBadge) {
            if (git.untracked_count > 0) {
                untrackedBadge.style.display = 'inline-flex';
                untrackedBadge.innerHTML = `<span class="badge-label">Untracked</span><span class="badge-count">${git.untracked_count}</span>`;
            } else {
                untrackedBadge.style.display = 'none';
            }
        }
    }

    // File list (show top changed files when not clean)
    const filesList = document.getElementById('git-files-list');
    if (filesList) {
        if (git.clean) {
            filesList.style.display = 'none';
            filesList.innerHTML = '';
        } else {
            filesList.style.display = 'block';
            const files = [];

            // Add staged files
            if (git.staged && git.staged.length > 0) {
                git.staged.forEach(f => {
                    files.push({ status: f.status, file: f.file, type: 'staged' });
                });
            }

            // Add unstaged files (avoid duplicates with staged)
            if (git.unstaged && git.unstaged.length > 0) {
                const stagedFiles = new Set((git.staged || []).map(f => f.file));
                git.unstaged.forEach(f => {
                    if (!stagedFiles.has(f.file)) {
                        files.push({ status: f.status, file: f.file, type: 'unstaged' });
                    }
                });
            }

            // Add untracked files
            if (git.untracked && git.untracked.length > 0) {
                git.untracked.forEach(f => {
                    files.push({ status: '?', file: f, type: 'untracked' });
                });
            }

            // Limit display to 10 files
            const displayFiles = files.slice(0, 10);
            const remaining = files.length - displayFiles.length;

            filesList.innerHTML = displayFiles.map(f => {
                const statusClass = getGitStatusClass(f.status);
                const statusLabel = getGitStatusLabel(f.status);
                const shortFile = shortenPath(f.file);
                return `<div class="git-file-item" title="${escapeHtml(f.file)}">
                    <span class="git-file-status ${statusClass}">${escapeHtml(statusLabel)}</span>
                    <span class="git-file-name">${escapeHtml(shortFile)}</span>
                </div>`;
            }).join('') + (remaining > 0 ? `<div class="git-file-item"><span class="git-file-status" style="background: none;">…</span><span class="git-file-name" style="color: var(--label-color)">${remaining} more</span></div>` : '');
        }
    }
}

/**
 * Shorten a file path for display
 * @param {string} path - Full file path
 * @returns {string} Shortened path
 */
function shortenPath(path) {
    if (!path) return '';
    // If path has more than 3 segments, abbreviate middle ones
    const parts = path.replace(/\\/g, '/').split('/');
    if (parts.length <= 3) return parts.join('/');
    return parts[0] + '/…/' + parts.slice(-2).join('/');
}
