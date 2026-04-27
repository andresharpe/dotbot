/**
 * DOTBOT Control Panel - Task Modal
 * Task modal display and management
 */

/**
 * Initialize task click handlers
 */
function initTaskClicks() {
    // Current task click
    document.getElementById('current-task')?.addEventListener('click', (e) => {
        if (lastState?.tasks?.current) {
            showTaskModal(lastState.tasks.current);
        }
    });

    // Delegate for dynamic task lists
    document.addEventListener('click', async (e) => {
        // Handle decision link clicks (from Related Decisions tags)
        const decLink = e.target.closest('[data-decision-link]');
        if (decLink) {
            const decisionId = decLink.dataset.decisionLink;
            if (decisionId && isValidDecisionId(decisionId)) {
                switchToTab('decisions');
                await reloadDecisions();
                toggleDecisionExpand(decisionId);
            }
            return;
        }

        if (e.target.closest('.roadmap-task-action') || e.target.closest('.roadmap-header-action')) {
            return;
        }

        const taskItem = e.target.closest('.task-list-item, .pipeline-task');
        if (taskItem && taskItem.dataset.taskId) {
            const task = findTaskById(taskItem.dataset.taskId);
            if (task) {
                showTaskModal(task);
            }
        }
    });
}

/**
 * Find task by ID in the current state
 * @param {string} id - Task ID
 * @returns {Object|null} Task object or null
 */
function findTaskById(id) {
    if (!lastState?.tasks) return null;

    if (lastState.tasks.current?.id === id) return lastState.tasks.current;

    const upcoming = lastState.tasks.upcoming?.find(t => t.id === id);
    if (upcoming) return upcoming;

    const analysing = lastState.tasks.analysing_list?.find(t => t.id === id);
    if (analysing) return analysing;

    const needsInput = lastState.tasks.needs_input_list?.find(t => t.id === id);
    if (needsInput) return needsInput;

    const analysed = lastState.tasks.analysed_list?.find(t => t.id === id);
    if (analysed) return analysed;

    const completed = lastState.tasks.recent_completed?.find(t => t.id === id);
    if (completed) return completed;

    const skipped = lastState.tasks.skipped_list?.find(t => t.id === id);
    if (skipped) return skipped;

    return null;
}

/**
 * Show task details modal with sidebar navigation
 * @param {Object} task - Task object to display
 */
function showTaskModal(task) {
    const modal = document.getElementById('task-modal');
    const titleEl = document.getElementById('modal-task-name');
    const contentEl = document.getElementById('modal-task-content');

    if (!modal || !task) return;

    titleEl.textContent = task.name || task.id || 'Task Details';

    // Determine which sections have content
    const hasSteps = task.steps && task.steps.length > 0;
    const hasCriteria = task.acceptance_criteria && task.acceptance_criteria.length > 0;
    const hasAnalysis = !!task.analysis;
    const hasCommits = task.commit_sha || (task.commits && task.commits.length > 0);
    const analysisLog = task.analysis?.analysis_activity_log || task.analysis?.activity_log;
    const executionLog = task.execution_activity_log || task.activity_log;
    const hasAnalysisActivity = analysisLog && analysisLog.length > 0;
    const hasExecutionActivity = executionLog && executionLog.length > 0;

    // Build sidebar navigation
    let sidebarHtml = `
        <div class="task-modal-nav">
            <div class="task-modal-nav-item active" data-section="overview">
                <span class="nav-icon">◇</span>Overview
            </div>
            <div class="task-modal-nav-item ${!hasSteps && !hasCriteria ? 'disabled' : ''}" data-section="requirements">
                <span class="nav-icon">☐</span>Requirements
            </div>
            <div class="task-modal-nav-item ${!hasAnalysis ? 'disabled' : ''}" data-section="analysis">
                <span class="nav-icon">◈</span>Analysis
            </div>
            <div class="task-modal-nav-item ${!hasCommits ? 'disabled' : ''}" data-section="commits">
                <span class="nav-icon">⎇</span>Commits
            </div>
            <div class="task-modal-nav-item ${!hasAnalysisActivity ? 'disabled' : ''}" data-section="analysis-activity">
                <span class="nav-icon">◎</span>Analysis Activity
            </div>
            <div class="task-modal-nav-item ${!hasExecutionActivity ? 'disabled' : ''}" data-section="execution-activity">
                <span class="nav-icon">▶</span>Execution Activity
            </div>
        </div>
    `;

    // Build main content sections
    let mainHtml = '';

    // === OVERVIEW SECTION ===
    mainHtml += `<div class="task-modal-section active" data-section="overview">`;
    mainHtml += buildOverviewSection(task);
    mainHtml += `</div>`;

    // === REQUIREMENTS SECTION ===
    mainHtml += `<div class="task-modal-section" data-section="requirements">`;
    mainHtml += buildRequirementsSection(task);
    mainHtml += `</div>`;

    // === ANALYSIS SECTION ===
    mainHtml += `<div class="task-modal-section" data-section="analysis">`;
    mainHtml += buildAnalysisSection(task);
    mainHtml += `</div>`;

    // === COMMITS SECTION ===
    mainHtml += `<div class="task-modal-section" data-section="commits">`;
    mainHtml += buildCommitsSection(task);
    mainHtml += `</div>`;

    // === ANALYSIS ACTIVITY SECTION ===
    mainHtml += `<div class="task-modal-section activity-fill" data-section="analysis-activity">`;
    mainHtml += buildAnalysisActivitySection(task);
    mainHtml += `</div>`;

    // === EXECUTION ACTIVITY SECTION ===
    mainHtml += `<div class="task-modal-section activity-fill" data-section="execution-activity">`;
    mainHtml += buildExecutionActivitySection(task);
    mainHtml += `</div>`;

    // Compose full layout
    const html = `
        <div class="task-modal-layout">
            <div class="task-modal-sidebar">${sidebarHtml}</div>
            <div class="task-modal-main">${mainHtml}</div>
        </div>
    `;

    contentEl.innerHTML = html;

    // Setup navigation click handlers
    contentEl.querySelectorAll('.task-modal-nav-item:not(.disabled)').forEach(item => {
        item.addEventListener('click', () => {
            const section = item.dataset.section;
            // Update nav active state
            contentEl.querySelectorAll('.task-modal-nav-item').forEach(n => n.classList.remove('active'));
            item.classList.add('active');
            // Update section visibility
            contentEl.querySelectorAll('.task-modal-section').forEach(s => s.classList.remove('active'));
            contentEl.querySelector(`.task-modal-section[data-section="${section}"]`)?.classList.add('active');
        });
    });

    modal.classList.add('visible');
}

/**
 * Build Overview section HTML
 */
function buildOverviewSection(task) {
    let html = '';

    // Task identity
    html += `<div class="task-identity">`;
    html += `<div class="task-identity-id">${escapeHtml(task.id || '')}</div>`;
    html += `<div class="task-identity-name">${escapeHtml(task.name || task.id || 'Unknown')}</div>`;
    if (task.description) {
        html += `<div class="task-identity-description">${escapeHtml(task.description)}</div>`;
    }
    html += `</div>`;

    // Metadata grid
    html += `<div class="task-meta-grid">`;
    if (task.status) {
        html += `<div class="task-meta-item">
            <span class="task-meta-label">Status</span>
            <span class="task-meta-value status-${escapeHtml(task.status)}">${escapeHtml(task.status)}${task.needs_interview ? '<span class="task-badge badge-needs-input">Needs Interview</span>' : ''}${task.notification ? `<span class="task-badge badge-notified">Sent via ${escapeHtml(task.notification.channel || 'ext')}</span>` : ''}</span>
        </div>`;
    }
    if (task.category) {
        html += `<div class="task-meta-item">
            <span class="task-meta-label">Category</span>
            <span class="task-meta-value">${escapeHtml(task.category)}</span>
        </div>`;
    }
    if (task.priority) {
        html += `<div class="task-meta-item">
            <span class="task-meta-label">Priority</span>
            <span class="task-meta-value">${escapeHtml(String(task.priority))}</span>
        </div>`;
    }
    if (task.effort) {
        html += `<div class="task-meta-item">
            <span class="task-meta-label">Effort</span>
            <span class="task-meta-value">${escapeHtml(task.effort)}</span>
        </div>`;
    }
    if (task.workflow) {
        html += `<div class="task-meta-item">
            <span class="task-meta-label">Workflow</span>
            <span class="task-meta-value"><span class="task-tag tag-workflow">${escapeHtml(task.workflow)}</span></span>
        </div>`;
    }
    if (task.type) {
        html += `<div class="task-meta-item">
            <span class="task-meta-label">Type</span>
            <span class="task-meta-value"><span class="task-tag tag-type">${escapeHtml(task.type)}</span></span>
        </div>`;
    }
    html += `</div>`;

    // Dates grid
    const hasDates = task.created_at || task.started_at || task.completed_at || task.updated_at ||
                     task.analysis_started_at || task.analysis_completed_at;
    if (hasDates) {
        html += `<div class="task-dates-grid">`;
        if (task.created_at) {
            html += `<div class="task-date-item">
                <span class="task-date-label">Created</span>
                <span class="task-date-value">${formatFriendlyDate(task.created_at)}</span>
            </div>`;
        }
        if (task.analysis_started_at) {
            html += `<div class="task-date-item">
                <span class="task-date-label">Analysis Started</span>
                <span class="task-date-value">${formatFriendlyDate(task.analysis_started_at)}</span>
            </div>`;
        }
        if (task.analysis_completed_at) {
            html += `<div class="task-date-item">
                <span class="task-date-label">Analysis Completed</span>
                <span class="task-date-value">${formatFriendlyDate(task.analysis_completed_at)}</span>
            </div>`;
        }
        if (task.started_at) {
            html += `<div class="task-date-item">
                <span class="task-date-label">Execution Started</span>
                <span class="task-date-value">${formatFriendlyDate(task.started_at)}</span>
            </div>`;
        }
        if (task.completed_at) {
            const duration = formatTaskDuration(task);
            html += `<div class="task-date-item highlight">
                <span class="task-date-label">Completed</span>
                <span class="task-date-value">${formatFriendlyDate(task.completed_at)}${duration ? `<span class="task-duration-badge">(${duration})</span>` : ''}</span>
            </div>`;
        }
        if (task.updated_at && !task.completed_at) {
            html += `<div class="task-date-item">
                <span class="task-date-label">Last Updated</span>
                <span class="task-date-value">${formatFriendlyDate(task.updated_at)}</span>
            </div>`;
        }
        html += `</div>`;
    }

    // Dependencies
    if (Array.isArray(task.dependencies) && task.dependencies.length > 0) {
        html += `<div class="task-list-section">`;
        html += `<div class="task-list-header">Dependencies</div>`;
        html += `<div class="task-tags">`;
        task.dependencies.forEach(d => {
            html += `<span class="task-tag tag-dependency">${escapeHtml(d)}</span>`;
        });
        html += `</div></div>`;
    }

    // References (agents & standards)
    const hasRefs = (task.applicable_agents && task.applicable_agents.length > 0) ||
                    (task.applicable_standards && task.applicable_standards.length > 0);
    if (hasRefs) {
        html += `<div class="task-list-section">`;
        html += `<div class="task-list-header">References</div>`;
        html += `<div class="task-tags">`;
        if (task.applicable_agents) {
            const agents = Array.isArray(task.applicable_agents) ? task.applicable_agents : [task.applicable_agents];
            agents.forEach(a => {
                if (a) html += `<span class="task-tag tag-agent">${escapeHtml(a)}</span>`;
            });
        }
        if (task.applicable_standards) {
            const standards = Array.isArray(task.applicable_standards) ? task.applicable_standards : [task.applicable_standards];
            standards.forEach(s => {
                if (s) html += `<span class="task-tag tag-standard">${escapeHtml(s)}</span>`;
            });
        }
        html += `</div></div>`;
    }

    // Skip history
    if (Array.isArray(task.skip_history) && task.skip_history.length > 0) {
        html += `<div class="task-list-section">`;
        html += `<div class="task-list-header">Skip History</div>`;
        html += `<div class="skip-history-list">`;
        task.skip_history.forEach(skip => {
            const timestamp = skip.timestamp ? formatFriendlyDate(skip.timestamp) : '';
            const reason = skip.reason || 'Unknown';
            html += `<div class="skip-history-item">`;
            html += `<div class="skip-reason">${escapeHtml(reason)}</div>`;
            if (timestamp) {
                html += `<div class="skip-timestamp">${timestamp}</div>`;
            }
            html += `</div>`;
        });
        html += `</div></div>`;
    }

    // Related Decisions
    const validDecisions = Array.isArray(task.applicable_decisions) ? task.applicable_decisions.filter(id => id && isValidDecisionId(id)) : [];
    if (validDecisions.length > 0) {
        html += `<div class="task-list-section">`;
        html += `<div class="task-list-header">Related Decisions</div>`;
        html += `<div class="task-tags">`;
        validDecisions.forEach(decisionId => {
            const dec = typeof getDecisionById === 'function' ? getDecisionById(decisionId) : null;
            const label = dec ? `${escapeHtml(decisionId)}: ${escapeHtml(dec.title)}` : escapeHtml(decisionId);
            const statusClass = dec ? ` tag-decision-${escapeAttr(dec.status)}` : '';
            html += `<span class="task-tag tag-decision${statusClass}" title="${dec ? escapeAttr(dec.title) : ''}" data-decision-link="${escapeAttr(decisionId)}" style="cursor:pointer">${label}</span>`;
        });
        html += `</div></div>`;
    }

    // Plan button
    if (task.plan_path) {
        html += `<div class="task-plan-button">`;
        html += `<button class="ctrl-btn primary" onclick="showPlanModal('${escapeHtml(task.id)}')">`;
        html += `<span class="btn-icon">&#128203;</span> View Implementation Plan`;
        html += `</button></div>`;
    }

    return html;
}

/**
 * Normalize task list items into displayable text.
 */
function getTaskListDisplayText(item) {
    if (item == null) return '';
    if (typeof item === 'string') return item;
    if (typeof item !== 'object') return `${item}`;

    for (const key of ['text', 'title', 'name', 'description', 'criterion', 'label', 'value', 'step', 'requirement', 'content', 'summary']) {
        if (typeof item[key] === 'string' && item[key].trim()) {
            return item[key];
        }
    }

    const firstStringValue = Object.values(item).find(value => typeof value === 'string' && value.trim());
    return firstStringValue || '';
}

function normalizeTaskListItems(value) {
    const items = Array.isArray(value) ? value : (value == null ? [] : [value]);
    return items.map(item => getTaskListDisplayText(item)).filter(Boolean);
}

/**
 * Build Requirements section HTML
 */
function buildRequirementsSection(task) {
    let html = '';
    const stepsArr = normalizeTaskListItems(task.steps);
    const criteriaArr = normalizeTaskListItems(task.acceptance_criteria);
    const hasSteps = stepsArr.length > 0;
    const hasCriteria = criteriaArr.length > 0;

    if (!hasSteps && !hasCriteria) {
        html += `<div class="task-empty-state">No requirements defined for this task.</div>`;
        return html;
    }

    if (hasSteps) {
        html += `<div class="task-list-section">`;
        html += `<div class="task-list-header">Implementation Steps</div>`;
        html += `<ol class="task-numbered-list">`;
        stepsArr.forEach(step => {
            html += `<li>${escapeHtml(step)}</li>`;
        });
        html += `</ol></div>`;
    }

    if (hasCriteria) {
        html += `<div class="task-list-section">`;
        html += `<div class="task-list-header">Acceptance Criteria</div>`;
        html += `<ul class="task-bullet-list">`;
        criteriaArr.forEach(criteria => {
            html += `<li>${escapeHtml(criteria)}</li>`;
        });
        html += `</ul></div>`;
    }

    return html;
}

/**
 * Build Analysis section HTML
 */
function buildAnalysisSection(task) {
    let html = '';

    if (!task.analysis) {
        html += `<div class="task-empty-state">No pre-flight analysis available.</div>`;
        return html;
    }

    const analysis = task.analysis;

    // Analysis metadata
    const hasMetadata = task.analysed_by || task.analysis_completed_at || analysis.implementation?.estimated_tokens;
    if (hasMetadata) {
        html += `<div class="task-meta-grid">`;
        if (task.analysed_by) {
            html += `<div class="task-meta-item">
                <span class="task-meta-label">Analysed By</span>
                <span class="task-meta-value">${escapeHtml(task.analysed_by)}</span>
            </div>`;
        }
        if (task.analysis_completed_at) {
            html += `<div class="task-meta-item">
                <span class="task-meta-label">Completed</span>
                <span class="task-meta-value">${formatFriendlyDate(task.analysis_completed_at)}</span>
            </div>`;
        }
        if (analysis.implementation?.estimated_tokens) {
            html += `<div class="task-meta-item">
                <span class="task-meta-label">Est. Tokens</span>
                <span class="task-meta-value">${analysis.implementation.estimated_tokens.toLocaleString()}</span>
            </div>`;
        }
        html += `</div>`;
    }

    // Implementation approach
    if (analysis.implementation?.approach) {
        html += `<div class="analysis-block">`;
        html += `<div class="analysis-block-header">Implementation Approach</div>`;
        html += `<div class="analysis-block-content">${escapeHtml(analysis.implementation.approach)}</div>`;
        html += `</div>`;
    }

    // Key patterns
    if (analysis.implementation?.key_patterns) {
        html += `<div class="analysis-block">`;
        html += `<div class="analysis-block-header">Key Patterns</div>`;
        html += `<div class="analysis-block-content">${escapeHtml(analysis.implementation.key_patterns)}</div>`;
        html += `</div>`;
    }

    // Context summary
    if (analysis.entities?.context_summary) {
        html += `<div class="analysis-block">`;
        html += `<div class="analysis-block-header">Context</div>`;
        html += `<div class="analysis-block-content">${escapeHtml(analysis.entities.context_summary)}</div>`;
        html += `</div>`;
    }

    // Entity arrays
    if (analysis.entities?.primary?.length > 0 || analysis.entities?.related?.length > 0) {
        html += `<div class="analysis-block">`;
        html += `<div class="analysis-block-header">Entities</div>`;
        html += `<div class="analysis-entities-content">`;
        if (analysis.entities.primary?.length > 0) {
            html += `<div class="entity-group"><span class="entity-group-label">Primary:</span>`;
            html += `<div class="entity-tags">`;
            analysis.entities.primary.forEach(e => {
                html += `<span class="entity-tag entity-primary">${escapeHtml(e)}</span>`;
            });
            html += `</div></div>`;
        }
        if (analysis.entities.related?.length > 0) {
            html += `<div class="entity-group"><span class="entity-group-label">Related:</span>`;
            html += `<div class="entity-tags">`;
            analysis.entities.related.forEach(e => {
                html += `<span class="entity-tag entity-related">${escapeHtml(e)}</span>`;
            });
            html += `</div></div>`;
        }
        html += `</div></div>`;
    }

    // Files to modify
    if (analysis.files?.to_modify?.length > 0) {
        html += `<div class="analysis-block">`;
        html += `<div class="analysis-block-header">Files to Modify</div>`;
        html += `<ul class="analysis-files-list">`;
        analysis.files.to_modify.forEach(f => {
            html += `<li>${escapeHtml(f)}</li>`;
        });
        html += `</ul></div>`;
    }

    // Patterns from
    if (analysis.files?.patterns_from?.length > 0) {
        html += `<div class="analysis-block">`;
        html += `<div class="analysis-block-header">Pattern References</div>`;
        html += `<ul class="analysis-files-list">`;
        analysis.files.patterns_from.forEach(f => {
            html += `<li>${escapeHtml(f)}</li>`;
        });
        html += `</ul></div>`;
    }

    // Tests to update
    if (analysis.files?.tests_to_update?.length > 0) {
        html += `<div class="analysis-block">`;
        html += `<div class="analysis-block-header">Tests to Update</div>`;
        html += `<ul class="analysis-files-list tests-list">`;
        analysis.files.tests_to_update.forEach(f => {
            html += `<li>${escapeHtml(f)}</li>`;
        });
        html += `</ul></div>`;
    }

    // Dependencies
    const hasDeps = analysis.dependencies?.task_dependencies?.length > 0 ||
                    analysis.dependencies?.implicit_dependencies?.length > 0 ||
                    analysis.dependencies?.blocking_issues?.length > 0;
    if (hasDeps) {
        html += `<div class="analysis-block">`;
        html += `<div class="analysis-block-header">Dependencies</div>`;
        html += `<div class="analysis-deps-content">`;
        if (analysis.dependencies.task_dependencies?.length > 0) {
            html += `<div class="deps-group"><span class="deps-label">Task Dependencies:</span>`;
            html += `<div class="deps-tags">`;
            analysis.dependencies.task_dependencies.forEach(d => {
                html += `<span class="deps-tag">${escapeHtml(d)}</span>`;
            });
            html += `</div></div>`;
        }
        if (analysis.dependencies.implicit_dependencies?.length > 0) {
            html += `<div class="deps-group"><span class="deps-label">Implicit:</span>`;
            html += `<ul class="deps-list">`;
            analysis.dependencies.implicit_dependencies.forEach(d => {
                html += `<li>${escapeHtml(d)}</li>`;
            });
            html += `</ul></div>`;
        }
        if (analysis.dependencies.blocking_issues?.length > 0) {
            html += `<div class="deps-group"><span class="deps-label">Blocking Issues:</span>`;
            html += `<ul class="deps-list blocking">`;
            analysis.dependencies.blocking_issues.forEach(d => {
                html += `<li>${escapeHtml(d)}</li>`;
            });
            html += `</ul></div>`;
        }
        html += `</div></div>`;
    }

    // Standards
    const hasStandards = analysis.standards?.applicable?.length > 0 ||
                         (analysis.standards?.relevant_sections && Object.keys(analysis.standards.relevant_sections).length > 0);
    if (hasStandards) {
        html += `<div class="analysis-block">`;
        html += `<div class="analysis-block-header">Standards</div>`;
        if (analysis.standards.applicable?.length > 0) {
            html += `<ul class="analysis-files-list">`;
            analysis.standards.applicable.forEach(s => {
                html += `<li>${escapeHtml(s)}</li>`;
            });
            html += `</ul>`;
        }
        if (analysis.standards.relevant_sections && Object.keys(analysis.standards.relevant_sections).length > 0) {
            html += `<div class="standards-sections">`;
            Object.entries(analysis.standards.relevant_sections).forEach(([file, sections]) => {
                html += `<div class="standards-file">`;
                html += `<span class="standards-file-name">${escapeHtml(file)}</span>`;
                if (Array.isArray(sections) && sections.length > 0) {
                    html += `<ul class="standards-section-list">`;
                    sections.forEach(section => {
                        html += `<li>${escapeHtml(section)}</li>`;
                    });
                    html += `</ul>`;
                }
                html += `</div>`;
            });
            html += `</div>`;
        }
        html += `</div>`;
    }

    // Product Context (collapsible)
    const hasProductCtx = analysis.product_context?.mission_summary ||
                          analysis.product_context?.entity_definitions ||
                          analysis.product_context?.tech_stack_relevant;
    if (hasProductCtx) {
        const contextId = `product-ctx-${Date.now()}`;
        html += `<div class="analysis-block collapsible-section collapsed" data-collapsible="${contextId}">`;
        html += `<div class="collapsible-header" onclick="toggleCollapsible('${contextId}')">`;
        html += `<span class="collapsible-icon">▶</span>`;
        html += `<span class="analysis-block-header">Product Context</span>`;
        html += `</div>`;
        html += `<div class="collapsible-content">`;
        if (analysis.product_context.mission_summary) {
            html += `<div class="product-ctx-item">`;
            html += `<span class="product-ctx-label">Mission:</span>`;
            html += `<span class="product-ctx-value">${escapeHtml(analysis.product_context.mission_summary)}</span>`;
            html += `</div>`;
        }
        if (analysis.product_context.entity_definitions) {
            html += `<div class="product-ctx-item">`;
            html += `<span class="product-ctx-label">Entities:</span>`;
            html += `<span class="product-ctx-value">${escapeHtml(analysis.product_context.entity_definitions)}</span>`;
            html += `</div>`;
        }
        if (analysis.product_context.tech_stack_relevant) {
            html += `<div class="product-ctx-item">`;
            html += `<span class="product-ctx-label">Tech Stack:</span>`;
            html += `<span class="product-ctx-value">${escapeHtml(analysis.product_context.tech_stack_relevant)}</span>`;
            html += `</div>`;
        }
        html += `</div></div>`;
    }

    // Risks
    if (analysis.implementation?.risks?.length > 0) {
        html += `<div class="analysis-block">`;
        html += `<div class="analysis-block-header">Identified Risks</div>`;
        html += `<ul class="analysis-risks-list">`;
        analysis.implementation.risks.forEach(r => {
            html += `<li>${escapeHtml(r)}</li>`;
        });
        html += `</ul></div>`;
    }

    // Questions Resolved
    if (analysis.questions_resolved?.length > 0) {
        html += `<div class="analysis-block">`;
        html += `<div class="analysis-block-header">Questions Resolved</div>`;
        html += `<div class="qa-list">`;
        analysis.questions_resolved.forEach(qa => {
            html += `<div class="qa-item">`;
            html += `<div class="qa-question">Q: ${escapeHtml(qa.question || '')}</div>`;
            html += `<div class="qa-answer">A: ${escapeHtml(qa.answer || '')}</div>`;
            if (qa.attachments && qa.attachments.length > 0) {
                html += `<div class="qa-attachments">`;
                qa.attachments.forEach(att => {
                    html += `<span class="qa-attachment-badge">${escapeHtml(att.name)}</span>`;
                });
                html += `</div>`;
            }
            if (qa.answered_at) {
                html += `<div class="qa-timestamp">${formatFriendlyDate(qa.answered_at)}</div>`;
            }
            html += `</div>`;
        });
        html += `</div></div>`;
    }

    return html;
}

/**
 * Build Commits section HTML
 */
function buildCommitsSection(task) {
    let html = '';

    const commits = task.commits || (task.commit_sha ? [{
        commit_sha: task.commit_sha,
        commit_subject: task.commit_subject,
        commit_timestamp: null,
        files_created: task.files_created,
        files_modified: task.files_modified,
        files_deleted: task.files_deleted
    }] : []);

    if (commits.length === 0) {
        html += `<div class="task-empty-state">No commits recorded for this task.</div>`;
        return html;
    }

    html += `<div class="commits-list">`;
    commits.forEach(commit => {
        html += `<div class="commit-card">`;
        html += `<div class="commit-card-header">`;
        html += `<span class="commit-sha-badge">${escapeHtml(commit.commit_sha?.substring(0, 8) || '')}</span>`;
        html += `<span class="commit-subject-text">${escapeHtml(commit.commit_subject || '')}</span>`;
        if (commit.commit_timestamp) {
            html += `<span class="commit-timestamp">${formatFriendlyDate(commit.commit_timestamp)}</span>`;
        }
        html += `</div>`;

        // File changes
        const hasChanges = (commit.files_created?.length || 0) +
                          (commit.files_modified?.length || 0) +
                          (commit.files_deleted?.length || 0) > 0;

        if (hasChanges) {
            html += `<div class="commit-files">`;
            if (commit.files_created?.length) {
                commit.files_created.forEach(f => {
                    html += `<div class="commit-file file-created"><span class="commit-file-badge">A</span>${escapeHtml(f)}</div>`;
                });
            }
            if (commit.files_modified?.length) {
                commit.files_modified.forEach(f => {
                    html += `<div class="commit-file file-modified"><span class="commit-file-badge">M</span>${escapeHtml(f)}</div>`;
                });
            }
            if (commit.files_deleted?.length) {
                commit.files_deleted.forEach(f => {
                    html += `<div class="commit-file file-deleted"><span class="commit-file-badge">D</span>${escapeHtml(f)}</div>`;
                });
            }
            html += `</div>`;
        }
        html += `</div>`;
    });
    html += `</div>`;

    return html;
}

/**
 * Build Analysis Activity section HTML
 */
function buildAnalysisActivitySection(task) {
    let html = '';

    // Get analysis activity log with backward compatibility
    const analysisLog = task.analysis?.analysis_activity_log || task.analysis?.activity_log;

    if (!analysisLog || analysisLog.length === 0) {
        html += `<div class="task-empty-state">No analysis activity recorded for this task.</div>`;
        return html;
    }

    html += `<div class="activity-section">`;
    html += `<div class="activity-header">`;
    html += `<span class="activity-title">Analysis Activity</span>`;
    html += `<span class="activity-count">${analysisLog.length} events</span>`;
    html += `</div>`;
    html += `<div class="activity-list">`;
    analysisLog.forEach(entry => {
        html += buildActivityItem(entry);
    });
    html += `</div></div>`;

    return html;
}

/**
 * Build Execution Activity section HTML
 */
function buildExecutionActivitySection(task) {
    let html = '';

    // Get execution activity log with backward compatibility
    const executionLog = task.execution_activity_log || task.activity_log;

    if (!executionLog || executionLog.length === 0) {
        html += `<div class="task-empty-state">No execution activity recorded for this task.</div>`;
        return html;
    }

    html += `<div class="activity-section">`;
    html += `<div class="activity-header">`;
    html += `<span class="activity-title">Execution Activity</span>`;
    html += `<span class="activity-count">${executionLog.length} events</span>`;
    html += `</div>`;
    html += `<div class="activity-list">`;
    executionLog.forEach(entry => {
        html += buildActivityItem(entry);
    });
    html += `</div></div>`;

    return html;
}

/**
 * Build single activity item HTML
 */
function buildActivityItem(entry) {
    const { displayType, displayMessage } = formatActivityEntry(entry);
    const typeClass = getActivityTypeClass(entry.type);
    const icon = getActivityIcon(entry.type);
    const time = entry.timestamp ? formatCompactTime(entry.timestamp) : '';

    // Determine data-type attribute for styling
    let dataType = 'other';
    const t = (entry.type || '').toLowerCase();
    if (t === 'read') dataType = 'read';
    else if (t === 'write') dataType = 'write';
    else if (t === 'edit') dataType = 'edit';
    else if (t === 'bash') dataType = 'bash';
    else if (t === 'glob' || t === 'grep') dataType = 'search';
    else if (t === 'text') dataType = 'text';
    else if (t === 'done') dataType = 'done';
    else if (t === 'init') dataType = 'init';
    else if (t.startsWith('mcp__') || t.startsWith('mcp_')) dataType = 'mcp';

    let html = `<div class="activity-item" data-type="${dataType}">`;
    html += `<span class="activity-item-icon">${icon}</span>`;
    html += `<span class="activity-item-type">${escapeHtml(displayType)}</span>`;
    if (displayMessage) {
        html += `<span class="activity-item-message">${escapeHtml(truncateMessage(displayMessage, 80))}</span>`;
    }
    if (time) {
        html += `<span class="activity-item-time">${time}</span>`;
    }
    html += `</div>`;

    return html;
}

/**
 * Initialize modal close handlers
 */
function initModalClose() {
    const modal = document.getElementById('task-modal');
    const closeBtn = document.getElementById('modal-close');

    closeBtn?.addEventListener('click', () => {
        modal?.classList.remove('visible');
    });

    modal?.addEventListener('click', (e) => {
        if (e.target === modal) {
            modal.classList.remove('visible');
        }
    });

    document.addEventListener('keydown', (e) => {
        if (e.key === 'Escape') {
            modal?.classList.remove('visible');
            document.getElementById('plan-modal')?.classList.remove('visible');
        }
    });

    // Initialize plan modal close handlers
    initPlanModalClose();
}

/**
 * Show plan in modal with markdown rendering
 * @param {string} taskId - The task ID to show the plan for
 */
async function showPlanModal(taskId) {
    const planModal = document.getElementById('plan-modal');
    const contentEl = document.getElementById('plan-modal-content');
    const titleEl = document.getElementById('plan-modal-title');

    if (!planModal || !contentEl || !titleEl) return;

    // Show loading state
    contentEl.innerHTML = '<div class="loading-state">Loading plan...</div>';
    planModal.classList.add('visible');

    // Fetch plan content via API endpoint
    try {
        const response = await fetch(`/api/plan/${taskId}`);
        const data = await response.json();

        if (data.has_plan) {
            titleEl.textContent = `Plan: ${data.task_name}`;
            // Use existing markdown renderer if available, otherwise show raw
            if (typeof markdownToHtml === 'function') {
                contentEl.innerHTML = markdownToHtml(data.content);
                // Render any Mermaid diagrams
                if (typeof renderMermaidDiagrams === 'function') {
                    renderMermaidDiagrams(contentEl);
                }
            } else {
                contentEl.innerHTML = `<pre>${escapeHtml(data.content)}</pre>`;
            }
        } else {
            contentEl.innerHTML = '<p class="no-plan">No plan found for this task.</p>';
        }
    } catch (err) {
        contentEl.innerHTML = `<p class="error">Error loading plan: ${escapeHtml(err.message)}</p>`;
    }
}

/**
 * Toggle collapsible section visibility
 * @param {string} id - The collapsible section identifier
 */
function toggleCollapsible(id) {
    const section = document.querySelector(`[data-collapsible="${id}"]`);
    if (section) {
        section.classList.toggle('collapsed');
    }
}

/**
 * Initialize plan modal close handlers
 */
function initPlanModalClose() {
    const modal = document.getElementById('plan-modal');
    const closeBtn = document.getElementById('plan-modal-close');
    const backBtn = document.getElementById('plan-modal-back');

    closeBtn?.addEventListener('click', () => modal?.classList.remove('visible'));
    backBtn?.addEventListener('click', () => modal?.classList.remove('visible'));

    modal?.addEventListener('click', (e) => {
        if (e.target === modal) {
            modal.classList.remove('visible');
        }
    });
}





