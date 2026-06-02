/**
 * DOTBOT Control Panel - Workflow Runs
 *
 * Renders every workflow run (including concurrent runs and multiple instances
 * of the same workflow) grouped by run, instead of flattening all tasks into a
 * single board. Data comes from state.workflow_runs (built server-side in
 * StateBuilder._Get-WorkflowRunsSummary) — no extra fetch.
 *
 * Each run is a collapsible card: status LED + workflow name + short run id +
 * progress, with that run's task list in the body. Running runs expand by
 * default; clicking a header toggles a run open/closed (the picker).
 */

// Per-run status → LED colour + label. data-type drives --type-color in theme.css.
// type maps to a theme.css data-type (drives --type-color/--type-glow); `off`
// renders a grey .led.off for neutral/terminal states (no valid data-type for
// "muted", so an off LED is used instead of letting it fall back to green).
const RUN_STATUS_META = {
    running:       { type: 'secondary', label: 'RUNNING',     pulse: true },
    'needs-input': { type: 'warning',   label: 'NEEDS INPUT', pulse: true },
    completed:     { type: 'success',   label: 'COMPLETED',   pulse: false },
    failed:        { type: 'error',     label: 'FAILED',      pulse: false },
    stopped:       { type: 'warning',   label: 'STOPPED',     pulse: false },
    cancelled:     { type: '',          label: 'CANCELLED',   pulse: false, off: true },
    unknown:       { type: '',          label: '—',           pulse: false, off: true }
};

// Reuse the same task-status glyphs as the workflow accordion for consistency.
const RUN_TASK_STATUS_ICONS = {
    'done':         '<span class="phase-icon phase-completed">&#10003;</span>',
    'in-progress':  '<span class="led pulse" data-type="secondary"></span>',
    'analysing':    '<span class="led pulse" data-type="secondary"></span>',
    'needs-input':  '<span class="led" data-type="warning"></span>',
    'needs-review': '<span class="led" data-type="warning"></span>',
    'analysed':     '<span class="phase-icon phase-pending">&#9675;</span>',
    'todo':         '<span class="phase-icon phase-pending">&#9675;</span>',
    'skipped':      '<span class="phase-icon phase-skipped">&#8211;</span>',
    'cancelled':    '<span class="phase-icon phase-skipped">&#8211;</span>',
    'failed':       '<span class="phase-icon phase-skipped">&#10007;</span>'
};

// Order + labels for the per-run count chips (only non-zero ones render).
const RUN_CHIP_ORDER = [
    ['in-progress', 'active'],
    ['analysing',   'analysing'],
    ['needs-input', 'needs input'],
    ['todo',        'todo'],
    ['done',        'done'],
    ['skipped',     'skipped'],
    ['failed',      'failed'],
    ['cancelled',   'cancelled']
];

function shortRunId(runId) {
    if (!runId) return '';
    return runId.startsWith('wr_') ? runId.slice(3) : runId;
}

/**
 * Render the workflow-runs panel from state.workflow_runs.
 * @param {object} state - the full /api/state payload
 */
function renderWorkflowRuns(state) {
    const container = document.getElementById('workflow-runs-list');
    if (!container) return;

    const runs = (state && Array.isArray(state.workflow_runs)) ? state.workflow_runs : [];

    const badge = document.getElementById('workflow-runs-count');
    if (badge) {
        const active = runs.filter(r => r && r.status === 'running').length;
        badge.textContent = runs.length ? `${active}/${runs.length}` : '0';
    }

    if (runs.length === 0) {
        container.innerHTML = '<div class="empty-state">No workflow runs yet</div>';
        return;
    }

    // Preserve per-run collapsed state across polls.
    const prevCollapsed = {};
    container.querySelectorAll('.run-card').forEach(card => {
        const rid = card.dataset.runId;
        if (rid) prevCollapsed[rid] = card.classList.contains('collapsed');
    });

    let html = '';

    runs.forEach(run => {
        if (!run) return;
        const counts = run.task_counts || {};
        const total = counts.total || 0;
        const doneCount = (counts['done'] || 0) + (counts['skipped'] || 0) + (counts['cancelled'] || 0);
        const activeCount = (counts['in-progress'] || 0) + (counts['analysing'] || 0);
        const pct = total > 0 ? Math.round((doneCount / total) * 100) : 0;
        const meta = RUN_STATUS_META[run.status] || RUN_STATUS_META.unknown;

        let isCollapsed;
        if (run.run_id in prevCollapsed) {
            isCollapsed = prevCollapsed[run.run_id];
        } else {
            isCollapsed = run.status !== 'running' && run.status !== 'needs-input';
        }

        const led = meta.off
            ? '<span class="led off"></span>'
            : `<span class="led${meta.pulse ? ' pulse' : ''}" data-type="${meta.type}"></span>`;

        let chips = '';
        RUN_CHIP_ORDER.forEach(([key, label]) => {
            const v = counts[key] || 0;
            if (v > 0) chips += `<span class="run-chip" data-status="${key}">${v} ${label}</span>`;
        });

        let items = '';
        (run.tasks || []).forEach(task => {
            const icon = RUN_TASK_STATUS_ICONS[task.status] || RUN_TASK_STATUS_ICONS['todo'];
            items += `
                <div class="chain-layer-item child-task-item child-task-${escapeAttr(task.status)}">
                    ${icon}
                    <span class="item-name">${escapeHtml(task.name || task.id || '')}</span>
                </div>`;
        });
        const shown = (run.tasks || []).length;
        if (run.tasks_total && run.tasks_total > shown) {
            items += `<div class="run-task-more">+${run.tasks_total - shown} more</div>`;
        }

        html += `
            <div class="run-card${isCollapsed ? ' collapsed' : ''}" data-run-id="${escapeAttr(run.run_id)}" data-status="${escapeAttr(run.status)}">
                <div class="chain-layer-header run-card-header">
                    ${led}
                    <span class="chain-layer-title run-workflow">${escapeHtml(run.workflow_name || 'workflow')}</span>
                    <span class="run-id-chip" title="${escapeAttr(run.run_id)}">${escapeHtml(shortRunId(run.run_id))}</span>
                    <span class="run-status-text" data-type="${meta.type}">${meta.label}</span>
                    <span class="chain-layer-count run-count">${doneCount}/${total}</span>
                </div>
                <div class="run-card-body">
                    <div class="child-task-progress run-progress">
                        <div class="child-task-bar-track">
                            <div class="child-task-bar-fill" style="width: ${pct}%"></div>
                        </div>
                        <span class="child-task-summary">${doneCount}/${total} done${activeCount ? `, ${activeCount} active` : ''}</span>
                    </div>
                    ${chips ? `<div class="run-chips">${chips}</div>` : ''}
                    <div class="child-task-items run-task-items">
                        ${items || '<div class="empty-state" style="font-size:10px">(no tasks)</div>'}
                    </div>
                </div>
            </div>`;
    });

    container.innerHTML = html;

    container.querySelectorAll('.run-card-header').forEach(header => {
        header.addEventListener('click', () => {
            header.closest('.run-card').classList.toggle('collapsed');
        });
    });
}
