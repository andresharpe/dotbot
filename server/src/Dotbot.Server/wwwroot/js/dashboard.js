// ============================================================
// DOTBOT DASHBOARD — Vanilla JS
// ============================================================

(function () {
    'use strict';

    // --- State ---
    let allInstances = [];
    let byPerson = {};     // email -> [{ instance, recipient, response }]
    let byProject = {};    // projectId -> { name, instances[] }
    let currentSort = { key: 'createdAt', dir: 'desc' };
    let selectedPerson = null;
    let selectedProject = null;
    let refreshTimer = null;
    let nudgeCooldowns = {}; // key -> timestamp

    // --- Helpers ---
    function buildRecipientPills(recipients, max) {
        if (!recipients || recipients.length === 0) return '';
        // Sort: non-responders first, then responders
        const sorted = [...recipients].sort((a, b) => (a.hasResponse ? 1 : 0) - (b.hasResponse ? 1 : 0));
        const visible = sorted.slice(0, max);
        let html = visible.map(r => {
            const local = (r.email || '').split('@')[0];
            const cls = r.hasResponse ? 'responded' : 'waiting';
            return `<span class="recipient-pill ${cls}">${esc(local)}</span>`;
        }).join('');
        if (recipients.length > max) {
            html += `<span class="recipient-pill overflow">\u2026</span>`;
        }
        return `<div class="recipient-pills">${html}</div>`;
    }

    // --- Init ---
    document.addEventListener('DOMContentLoaded', () => {
        wireTabSwitching();
        wireFilters();
        wireSorting();
        fetchData();
        refreshTimer = setInterval(fetchData, 30000);
    });

    // --- Data Fetching ---
    async function fetchData() {
        try {
            const resp = await fetch('/api/dashboard/instances');
            if (!resp.ok) {
                if (resp.status === 401 || resp.status === 403) {
                    window.location.reload();
                    return;
                }
                throw new Error(`HTTP ${resp.status}`);
            }
            allInstances = await resp.json();
            buildDerivedData();
            render();
            updateRefreshTime();
        } catch (err) {
            console.error('Failed to fetch dashboard data:', err);
        }
    }

    function buildDerivedData() {
        byPerson = {};
        byProject = {};

        for (const inst of allInstances) {
            // By project
            if (!byProject[inst.projectId]) {
                byProject[inst.projectId] = { name: inst.projectName, instances: [] };
            }
            byProject[inst.projectId].instances.push(inst);

            // By person
            for (const r of inst.recipients) {
                const email = (r.email || '').toLowerCase();
                if (!email) continue;
                if (!byPerson[email]) byPerson[email] = [];
                byPerson[email].push({
                    instance: inst,
                    recipient: r,
                    hasResponse: r.hasResponse,
                    selectedOption: r.selectedOption
                });
            }
        }
    }

    // --- Render ---
    function render() {
        renderStats();
        renderOverviewTable();
        renderPersonList();
        renderProjectList();
        populateProjectFilter();

        // Re-render detail panels if something is selected
        if (selectedPerson) renderPersonDetail(selectedPerson);
        if (selectedProject) renderProjectDetail(selectedProject);
    }

    // --- Stats ---
    function renderStats() {
        const counts = { total: 0, pending: 0, sent: 0, reminded: 0, escalated: 0, responded: 0 };
        for (const inst of allInstances) {
            for (const r of inst.recipients) {
                counts.total++;
                if (r.hasResponse) {
                    counts.responded++;
                } else if (r.status === 'escalated') {
                    counts.escalated++;
                } else if (r.status === 'reminded') {
                    counts.reminded++;
                } else if (r.status === 'sent') {
                    counts.sent++;
                } else {
                    counts.pending++;
                }
            }
        }
        document.getElementById('stat-total').textContent = counts.total;
        document.getElementById('stat-pending').textContent = counts.pending;
        document.getElementById('stat-sent').textContent = counts.sent;
        document.getElementById('stat-reminded').textContent = counts.reminded;
        document.getElementById('stat-escalated').textContent = counts.escalated;
        document.getElementById('stat-responded').textContent = counts.responded;
    }

    // --- Overview — Card-based Instance List ---
    function renderOverviewTable() {
        const filtered = getFilteredInstances();
        const sorted = sortInstances(filtered);
        const container = document.getElementById('instances-list');
        const empty = document.getElementById('empty-overview');
        const countBadge = document.getElementById('instance-count');

        if (countBadge) countBadge.textContent = sorted.length;

        if (sorted.length === 0) {
            container.innerHTML = '';
            empty.style.display = 'flex';
            return;
        }
        empty.style.display = 'none';

        container.innerHTML = sorted.map(inst => {
            const pct = inst.totalRecipients > 0
                ? Math.round((inst.respondedCount / inst.totalRecipients) * 100) : 0;
            return `<div class="instance-card status-${inst.overallStatus}" data-instance-id="${inst.instanceId}" data-project-id="${inst.projectId}">
                <div class="instance-card-title">
                    <span class="led led-${inst.overallStatus}"></span>
                    ${esc(inst.questionTitle)}
                </div>
                ${buildRecipientPills(inst.recipients, 2)}
                <span class="instance-card-project">${esc(inst.projectName)}</span>
                <div class="instance-card-progress">
                    <div class="progress-bar-sm"><div class="progress-fill" style="width:${pct}%"></div></div>
                    <span class="progress-text">${inst.respondedCount}/${inst.totalRecipients}</span>
                </div>
                <span class="instance-card-time">${timeAgo(inst.createdAt)}</span>
            </div>`;
        }).join('');

        // Wire click handlers for detail modal
        container.querySelectorAll('.instance-card').forEach(card => {
            card.addEventListener('click', () => {
                const id = card.dataset.instanceId;
                const projId = card.dataset.projectId;
                const inst = allInstances.find(i => i.instanceId === id && i.projectId === projId);
                if (inst) showInstanceDetail(inst);
            });
        });
    }

    function getFilteredInstances() {
        const search = (document.getElementById('filter-search').value || '').toLowerCase();
        const statusFilter = document.getElementById('filter-status').value;
        const projectFilter = document.getElementById('filter-project').value;
        const channelFilter = document.getElementById('filter-channel').value;

        return allInstances.filter(inst => {
            // Text search
            if (search) {
                const hay = `${inst.questionTitle} ${inst.projectName} ${inst.recipients.map(r => r.email).join(' ')}`.toLowerCase();
                if (!hay.includes(search)) return false;
            }
            // Status filter — match if any recipient has this status
            if (statusFilter) {
                if (statusFilter === 'responded') {
                    if (!inst.recipients.some(r => r.hasResponse)) return false;
                } else {
                    if (!inst.recipients.some(r => r.status === statusFilter)) return false;
                }
            }
            // Project filter
            if (projectFilter && inst.projectId !== projectFilter) return false;
            // Channel filter
            if (channelFilter && !inst.recipients.some(r => r.channel === channelFilter)) return false;
            return true;
        });
    }

    function sortInstances(list) {
        const { key, dir } = currentSort;
        return [...list].sort((a, b) => {
            let va = a[key], vb = b[key];
            if (key === 'createdAt') {
                va = new Date(va || 0).getTime();
                vb = new Date(vb || 0).getTime();
            } else if (typeof va === 'string') {
                va = va.toLowerCase();
                vb = (vb || '').toLowerCase();
            }
            if (va < vb) return dir === 'asc' ? -1 : 1;
            if (va > vb) return dir === 'asc' ? 1 : -1;
            return 0;
        });
    }

    // --- Instance Detail Modal — Unified Single View ---
    function showInstanceDetail(inst) {
        const overlay = document.createElement('div');
        overlay.className = 'instance-detail-overlay';
        overlay.addEventListener('click', (e) => {
            if (e.target === overlay) overlay.remove();
        });

        // Escape key handler
        const escHandler = (e) => {
            if (e.key === 'Escape') { overlay.remove(); document.removeEventListener('keydown', escHandler); }
        };
        document.addEventListener('keydown', escHandler);

        const pct = inst.totalRecipients > 0
            ? Math.round((inst.respondedCount / inst.totalRecipients) * 100) : 0;

        // Build response lookup by email AND AAD Object ID (case-insensitive)
        const responseLookup = {};
        const responseByAad = {};
        for (const rd of (inst.responseDetails || [])) {
            const emailKey = (rd.responderEmail || '').toLowerCase();
            if (emailKey) responseLookup[emailKey] = rd;
            const aadKey = (rd.responderAadObjectId || '').toLowerCase();
            if (aadKey) responseByAad[aadKey] = rd;
        }

        // Build unified recipients: merge recipient + response
        const unified = inst.recipients.map(r => {
            const emailKey = (r.email || '').toLowerCase();
            const aadKey = (r.aadObjectId || '').toLowerCase();
            const response = (emailKey && responseLookup[emailKey])
                || (aadKey && responseByAad[aadKey])
                || null;
            const effectiveStatus = r.hasResponse ? 'responded' : r.status;
            return { recipient: r, response, effectiveStatus };
        });

        // Sort: non-responders first (by severity), then responders (by submittedAt desc)
        const statusPriority = { escalated: 0, reminded: 1, sent: 2, scheduled: 3, pending: 4, failed: 5 };
        unified.sort((a, b) => {
            const aResp = a.effectiveStatus === 'responded';
            const bResp = b.effectiveStatus === 'responded';
            if (aResp !== bResp) return aResp ? 1 : -1; // non-responders first
            if (!aResp && !bResp) {
                // Sort non-responders by severity
                const aPri = statusPriority[a.effectiveStatus] ?? 99;
                const bPri = statusPriority[b.effectiveStatus] ?? 99;
                return aPri - bPri;
            }
            // Both responded — sort by submittedAt desc
            const aTime = a.response?.submittedAt ? new Date(a.response.submittedAt).getTime() : 0;
            const bTime = b.response?.submittedAt ? new Date(b.response.submittedAt).getTime() : 0;
            return bTime - aTime;
        });

        // --- Metadata strip ---
        const metaHtml = `<div class="instance-meta-strip">
            <div class="instance-meta-item">
                <span class="instance-meta-label">Project</span>
                <span class="instance-meta-value">${esc(inst.projectName)}</span>
            </div>
            <div class="instance-meta-item">
                <span class="instance-meta-label">Status</span>
                <span class="instance-meta-value"><span class="led led-${inst.overallStatus}"></span>${inst.overallStatus}</span>
            </div>
            <div class="instance-meta-item">
                <span class="instance-meta-label">Created</span>
                <span class="instance-meta-value">${inst.createdAt ? new Date(inst.createdAt).toLocaleString() : '-'}</span>
            </div>
            <div class="instance-meta-item">
                <span class="instance-meta-label">Created By</span>
                <span class="instance-meta-value">${esc(inst.createdBy || '-')}</span>
            </div>
            <div class="instance-meta-item">
                <span class="instance-meta-label">Progress</span>
                <span class="instance-meta-value">${inst.respondedCount} / ${inst.totalRecipients} (${pct}%)</span>
            </div>
        </div>
        <div class="instance-progress-bar"><div class="progress-fill" style="width:${pct}%"></div></div>`;

        // --- Collapsible Question section ---
        const optionsHtml = (inst.templateOptions || []).map(o =>
            `<div class="instance-option-row">
                <span class="instance-option-key">${esc(o.key)}</span>
                <span class="instance-option-title">${esc(o.title)}</span>
                ${o.summary ? `<span class="instance-option-summary">${esc(o.summary)}</span>` : ''}
                ${o.isRecommended ? `<span class="instance-option-recommended">Recommended</span>` : ''}
            </div>`
        ).join('');

        const hasQuestionContent = inst.templateDescription || inst.templateContext || (inst.templateOptions && inst.templateOptions.length);
        const questionHtml = hasQuestionContent ? `<div class="instance-collapsible" data-collapsible="question">
            <div class="instance-collapsible-header">
                <span class="chevron">&#9654;</span> Question Details
            </div>
            <div class="instance-collapsible-content">
                ${inst.templateDescription ? `<div class="instance-description-text">${esc(inst.templateDescription)}</div>` : ''}
                ${inst.templateContext ? `<div class="detail-section-title">Context</div><div class="instance-context-block">${esc(inst.templateContext)}</div>` : ''}
                ${(inst.templateOptions && inst.templateOptions.length) ? `<div class="detail-section-title">Options</div><div class="instance-options-list">${optionsHtml}</div>` : ''}
            </div>
        </div>` : '';

        // --- Unified recipient rows ---
        const recipientRowsHtml = unified.map(({ recipient: r, response, effectiveStatus }) => {
            const canNudge = !r.hasResponse && (r.status === 'sent' || r.status === 'reminded' || r.status === 'scheduled');
            const nudgeId = `nudge-modal-${inst.instanceId}-${r.email}`;

            let contentHtml = '';
            if (effectiveStatus === 'responded' && response) {
                const optionKey = response.selectedKey || '';
                const optionTitle = response.selectedOptionTitle || '';
                const freeText = response.freeText || '';
                contentHtml = `<div class="row-response">
                    ${optionKey ? `<span class="instance-option-badge">${esc(optionKey)}</span>` : ''}
                    ${optionTitle ? `<span class="row-response-title">${esc(optionTitle)}</span>` : ''}
                    <span class="row-response-time">${response.submittedAt ? timeAgo(response.submittedAt) : ''}</span>
                </div>
                ${freeText ? `<div class="instance-freetext-preview">${esc(freeText)}</div>` : ''}`;
            } else {
                contentHtml = `<div class="row-status">
                    <span class="row-status-text">${effectiveStatus}</span>
                    <div class="row-timestamps">
                        <span>Sent: ${r.sentAt ? timeAgo(r.sentAt) : '-'}</span>
                        ${r.lastReminderAt ? `<span>Reminded: ${timeAgo(r.lastReminderAt)}</span>` : ''}
                        ${r.escalatedAt ? `<span>Escalated: ${timeAgo(r.escalatedAt)}</span>` : ''}
                    </div>
                </div>`;
            }

            return `<div class="instance-unified-row status-${effectiveStatus}">
                <div class="row-identity">
                    <span class="led led-${effectiveStatus}"></span>
                    <span class="row-email">${esc(r.email || 'unknown')}</span>
                    <span class="row-channel">${r.channel}</span>
                </div>
                <div class="row-content">${contentHtml}</div>
                <div class="row-actions">
                    ${canNudge ? `<button class="ctrl-btn-sm nudge" id="${nudgeId}"
                        data-project="${inst.projectId}" data-instance="${inst.instanceId}" data-email="${r.email}">NUDGE</button>` : ''}
                </div>
            </div>`;
        }).join('');

        // --- Assemble modal ---
        overlay.innerHTML = `<div class="instance-detail-modal">
            <div class="module-header">
                <span>${esc(inst.questionTitle)}<span class="version-badge">v${inst.questionVersion ?? '?'}</span></span>
                <button class="close-btn">&times;</button>
            </div>
            <div class="instance-modal-body">
                ${metaHtml}
                ${questionHtml}
                <div class="detail-section-title">Recipients &amp; Responses (${inst.recipients.length})</div>
                ${recipientRowsHtml || '<div class="empty-state">No recipients.</div>'}
            </div>
            <div class="instance-modal-footer">
                <div class="delete-area">
                    <button class="btn-delete">Delete Instance</button>
                </div>
                <span class="instance-id-text">${esc(inst.instanceId)}</span>
            </div>
        </div>`;

        document.body.appendChild(overlay);

        // Close button
        overlay.querySelector('.close-btn').addEventListener('click', () => {
            overlay.remove();
            document.removeEventListener('keydown', escHandler);
        });

        // Wire collapsible sections
        overlay.querySelectorAll('.instance-collapsible-header').forEach(header => {
            header.addEventListener('click', () => {
                header.parentElement.classList.toggle('expanded');
            });
        });

        // Wire freetext expand
        overlay.querySelectorAll('.instance-freetext-preview').forEach(el => {
            el.addEventListener('click', (e) => {
                e.stopPropagation();
                el.classList.toggle('expanded');
            });
        });

        // Wire nudge buttons
        overlay.querySelectorAll('.ctrl-btn-sm.nudge').forEach(wireNudgeButton);

        // Wire delete button
        wireDeleteButton(overlay, inst, escHandler);
    }

    // --- Delete Button (two-stage confirmation) ---
    function wireDeleteButton(overlay, inst, escHandler) {
        const btn = overlay.querySelector('.btn-delete');
        if (!btn) return;
        const area = btn.parentElement;
        let confirmState = false;
        let revertTimer = null;

        btn.addEventListener('click', async () => {
            if (!confirmState) {
                // First click: switch to confirmation state
                confirmState = true;
                btn.textContent = 'Confirm Delete';
                btn.classList.add('confirm');
                const cancelBtn = document.createElement('button');
                cancelBtn.className = 'btn-cancel';
                cancelBtn.textContent = 'Cancel';
                area.appendChild(cancelBtn);

                cancelBtn.addEventListener('click', () => {
                    resetDeleteState();
                });

                revertTimer = setTimeout(() => {
                    resetDeleteState();
                }, 5000);
            } else {
                // Second click: perform delete
                clearTimeout(revertTimer);
                btn.textContent = 'Deleting...';
                btn.style.pointerEvents = 'none';

                try {
                    const resp = await fetch(`/api/dashboard/instances/${encodeURIComponent(inst.projectId)}/${encodeURIComponent(inst.instanceId)}`, {
                        method: 'DELETE'
                    });
                    if (resp.ok) {
                        const idx = allInstances.findIndex(i => i.instanceId === inst.instanceId && i.projectId === inst.projectId);
                        if (idx !== -1) allInstances.splice(idx, 1);
                        buildDerivedData();
                        render();
                        overlay.remove();
                        document.removeEventListener('keydown', escHandler);
                    } else {
                        btn.textContent = 'Failed';
                        btn.classList.remove('confirm');
                        setTimeout(() => resetDeleteState(), 3000);
                    }
                } catch {
                    btn.textContent = 'Failed';
                    btn.classList.remove('confirm');
                    setTimeout(() => resetDeleteState(), 3000);
                }
            }
        });

        function resetDeleteState() {
            clearTimeout(revertTimer);
            confirmState = false;
            btn.textContent = 'Delete Instance';
            btn.classList.remove('confirm');
            btn.style.pointerEvents = '';
            const cancelBtn = area.querySelector('.btn-cancel');
            if (cancelBtn) cancelBtn.remove();
        }
    }

    // --- By Person ---
    function renderPersonList() {
        const search = (document.getElementById('person-search').value || '').toLowerCase();
        const container = document.getElementById('person-list');
        const entries = Object.entries(byPerson)
            .filter(([email]) => !search || email.includes(search))
            .sort((a, b) => a[0].localeCompare(b[0]));

        container.innerHTML = entries.map(([email, items]) => {
            const total = items.length;
            const responded = items.filter(i => i.hasResponse).length;
            const overdue = items.some(i => !i.hasResponse && (i.recipient.status === 'escalated' || i.recipient.status === 'reminded'));
            let ledClass = 'led-sent';
            if (responded === total) ledClass = 'led-responded';
            else if (overdue) ledClass = 'led-escalated';

            return `<div class="list-item ${selectedPerson === email ? 'active' : ''}" data-email="${esc(email)}">
                <span class="led ${ledClass}"></span>
                <div class="list-item-info">
                    <div class="list-item-name">${esc(email)}</div>
                    <div class="list-item-meta">${responded} of ${total} answered</div>
                </div>
                <span class="list-item-badge">${responded}/${total}</span>
            </div>`;
        }).join('');

        container.querySelectorAll('.list-item').forEach(el => {
            el.addEventListener('click', () => {
                selectedPerson = el.dataset.email;
                renderPersonList();
                renderPersonDetail(selectedPerson);
            });
        });
    }

    function renderPersonDetail(email) {
        const panel = document.getElementById('person-detail');
        const items = byPerson[email];
        if (!items || items.length === 0) {
            panel.innerHTML = '<div class="empty-state">No data for this person.</div>';
            return;
        }

        panel.innerHTML = items.map(item => {
            const r = item.recipient;
            const inst = item.instance;
            const status = item.hasResponse ? 'responded' : r.status;
            const canNudge = !item.hasResponse && (r.status === 'sent' || r.status === 'reminded' || r.status === 'scheduled');
            const nudgeId = `nudge-person-${inst.instanceId}-${email}`;

            return `<div class="detail-card status-${status}">
                <div class="detail-card-header">
                    <div>
                        <div class="detail-card-title"><span class="led led-${status}"></span>${esc(inst.questionTitle)}</div>
                        <div class="detail-card-subtitle">${esc(inst.projectName)}</div>
                    </div>
                    ${canNudge ? `<button class="ctrl-btn-sm nudge" id="${nudgeId}"
                        data-project="${inst.projectId}" data-instance="${inst.instanceId}" data-email="${email}">NUDGE</button>` : ''}
                </div>
                <div class="detail-card-meta">
                    <span>Channel: ${r.channel}</span>
                    <span>Sent: ${r.sentAt ? timeAgo(r.sentAt) : 'pending'}</span>
                    ${r.lastReminderAt ? `<span>Reminded: ${timeAgo(r.lastReminderAt)}</span>` : ''}
                    ${r.escalatedAt ? `<span>Escalated: ${timeAgo(r.escalatedAt)}</span>` : ''}
                </div>
                ${item.hasResponse ? `<div class="detail-card-response">Answered: ${esc(item.selectedOption || 'response submitted')}</div>` : ''}
            </div>`;
        }).join('');

        panel.querySelectorAll('.ctrl-btn-sm.nudge').forEach(wireNudgeButton);

        // Wire click on detail cards to open instance dialog
        panel.querySelectorAll('.detail-card').forEach((card, idx) => {
            card.style.cursor = 'pointer';
            card.addEventListener('click', (e) => {
                if (e.target.closest('.ctrl-btn-sm')) return; // skip if clicking nudge
                showInstanceDetail(items[idx].instance);
            });
        });
    }

    // --- By Project ---
    function renderProjectList() {
        const search = (document.getElementById('project-search').value || '').toLowerCase();
        const container = document.getElementById('project-list');
        const entries = Object.entries(byProject)
            .filter(([, data]) => !search || data.name.toLowerCase().includes(search))
            .sort((a, b) => a[1].name.localeCompare(b[1].name));

        container.innerHTML = entries.map(([id, data]) => {
            const totalRecipients = data.instances.reduce((s, i) => s + i.totalRecipients, 0);
            const totalResponded = data.instances.reduce((s, i) => s + i.respondedCount, 0);
            const pct = totalRecipients > 0 ? Math.round((totalResponded / totalRecipients) * 100) : 0;

            return `<div class="list-item ${selectedProject === id ? 'active' : ''}" data-project="${esc(id)}">
                <div class="list-item-info">
                    <div class="list-item-name">${esc(data.name)}</div>
                    <div class="list-item-meta">${data.instances.length} question${data.instances.length !== 1 ? 's' : ''}</div>
                    <div class="progress-bar" style="margin-top:4px"><div class="progress-fill" style="width:${pct}%"></div></div>
                </div>
                <span class="list-item-badge">${pct}%</span>
            </div>`;
        }).join('');

        container.querySelectorAll('.list-item').forEach(el => {
            el.addEventListener('click', () => {
                selectedProject = el.dataset.project;
                renderProjectList();
                renderProjectDetail(selectedProject);
            });
        });
    }

    function renderProjectDetail(projectId) {
        const panel = document.getElementById('project-detail');
        const data = byProject[projectId];
        if (!data) {
            panel.innerHTML = '<div class="empty-state">No data for this project.</div>';
            return;
        }

        const totalRecipients = data.instances.reduce((s, i) => s + i.totalRecipients, 0);
        const totalResponded = data.instances.reduce((s, i) => s + i.respondedCount, 0);

        let html = `<div style="margin-bottom:12px">
            <div class="detail-card-title" style="font-size:14px;margin-bottom:4px">${esc(data.name)}</div>
            <div class="detail-card-meta">
                <span>${data.instances.length} instances</span>
                <span>${totalResponded} of ${totalRecipients} responses</span>
            </div>
        </div>`;

        for (const inst of data.instances) {
            const pct = inst.totalRecipients > 0
                ? Math.round((inst.respondedCount / inst.totalRecipients) * 100) : 0;
            const rowId = `row-${inst.instanceId}`;

            const recipientRows = inst.recipients.map(r => {
                const canNudge = !r.hasResponse && (r.status === 'sent' || r.status === 'reminded' || r.status === 'scheduled');
                const nudgeId = `nudge-proj-${inst.instanceId}-${r.email}`;
                return `<div class="recipient-row">
                    <div class="recipient-info">
                        <span class="led led-${r.hasResponse ? 'responded' : r.status}"></span>
                        <span class="recipient-email">${esc(r.email || 'unknown')}</span>
                        <span class="recipient-channel">${r.channel}</span>
                    </div>
                    <span class="recipient-status">${r.hasResponse ? 'responded' : r.status}</span>
                    <div class="recipient-actions">
                        ${r.hasResponse ? `<span style="font-size:10px;color:var(--color-success)">${esc(r.selectedOption || 'answered')}</span>` : ''}
                        ${canNudge ? `<button class="ctrl-btn-sm nudge" id="${nudgeId}"
                            data-project="${inst.projectId}" data-instance="${inst.instanceId}" data-email="${r.email}">NUDGE</button>` : ''}
                    </div>
                </div>`;
            }).join('');

            html += `<div class="instance-row" id="${rowId}">
                <div class="instance-row-header">
                    <div class="instance-row-title"><span class="led led-${inst.overallStatus}"></span>${esc(inst.questionTitle)}</div>
                    <div class="instance-row-progress">
                        <button class="ctrl-btn-sm view-instance-btn" data-instance-id="${inst.instanceId}" data-project-id="${inst.projectId}">VIEW</button>
                        <span>${inst.respondedCount}/${inst.totalRecipients}</span>
                        <div class="progress-bar-sm" style="width:60px"><div class="progress-fill" style="width:${pct}%"></div></div>
                        <span class="chevron">&#9654;</span>
                    </div>
                </div>
                <div class="instance-row-body">${recipientRows}</div>
            </div>`;
        }

        panel.innerHTML = html;

        // Wire expandable rows
        panel.querySelectorAll('.instance-row-header').forEach(header => {
            header.addEventListener('click', () => {
                header.parentElement.classList.toggle('expanded');
            });
        });

        // Wire VIEW buttons
        panel.querySelectorAll('.view-instance-btn').forEach(btn => {
            btn.addEventListener('click', (e) => {
                e.stopPropagation();
                const inst = data.instances.find(i =>
                    i.instanceId === btn.dataset.instanceId && i.projectId === btn.dataset.projectId);
                if (inst) showInstanceDetail(inst);
            });
        });

        // Wire nudge buttons
        panel.querySelectorAll('.ctrl-btn-sm.nudge').forEach(wireNudgeButton);
    }

    // --- Nudge ---
    function wireNudgeButton(btn) {
        btn.addEventListener('click', async (e) => {
            e.stopPropagation();
            const projectId = btn.dataset.project;
            const instanceId = btn.dataset.instance;
            const email = btn.dataset.email;
            const cooldownKey = `${instanceId}-${email}`;

            if (nudgeCooldowns[cooldownKey] && Date.now() < nudgeCooldowns[cooldownKey]) return;

            btn.textContent = 'Sending...';
            btn.classList.add('sending');
            btn.classList.remove('failed');

            try {
                const resp = await fetch('/api/dashboard/nudge', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ projectId, instanceId, recipientEmail: email })
                });
                const data = await resp.json();

                if (resp.ok && data.success) {
                    btn.textContent = 'Nudged';
                    btn.classList.remove('sending');
                    btn.classList.add('success');
                    nudgeCooldowns[cooldownKey] = Date.now() + 60000;
                    setTimeout(() => {
                        btn.textContent = 'NUDGE';
                        btn.classList.remove('success');
                    }, 60000);
                } else {
                    btn.textContent = 'Failed';
                    btn.classList.remove('sending');
                    btn.classList.add('failed');
                    setTimeout(() => {
                        btn.textContent = 'NUDGE';
                        btn.classList.remove('failed');
                    }, 3000);
                }
            } catch {
                btn.textContent = 'Failed';
                btn.classList.remove('sending');
                btn.classList.add('failed');
                setTimeout(() => {
                    btn.textContent = 'NUDGE';
                    btn.classList.remove('failed');
                }, 3000);
            }
        });
    }

    // --- Tab Switching ---
    function wireTabSwitching() {
        document.querySelectorAll('.tab').forEach(tab => {
            tab.addEventListener('click', () => {
                document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
                document.querySelectorAll('.tab-pane').forEach(p => p.classList.remove('active'));
                tab.classList.add('active');
                document.getElementById(`tab-${tab.dataset.tab}`).classList.add('active');
            });
        });
    }

    // --- Filters ---
    function wireFilters() {
        ['filter-search', 'filter-status', 'filter-project', 'filter-channel'].forEach(id => {
            document.getElementById(id).addEventListener('input', () => renderOverviewTable());
            document.getElementById(id).addEventListener('change', () => renderOverviewTable());
        });
        document.getElementById('person-search').addEventListener('input', () => renderPersonList());
        document.getElementById('project-search').addEventListener('input', () => renderProjectList());
    }

    function populateProjectFilter() {
        const select = document.getElementById('filter-project');
        const current = select.value;
        const projects = [...new Set(allInstances.map(i => i.projectId))].sort();

        // Keep the "All Projects" option, replace the rest
        while (select.options.length > 1) select.remove(1);
        for (const p of projects) {
            const name = allInstances.find(i => i.projectId === p)?.projectName || p;
            const opt = new Option(name, p);
            select.add(opt);
        }
        select.value = current;
    }

    // --- Sorting (sort-bar buttons) ---
    function wireSorting() {
        document.querySelectorAll('.sort-btn').forEach(btn => {
            btn.addEventListener('click', () => {
                const key = btn.dataset.sort;
                if (currentSort.key === key) {
                    currentSort.dir = currentSort.dir === 'asc' ? 'desc' : 'asc';
                } else {
                    currentSort = { key, dir: 'asc' };
                }
                // Update sort indicators
                document.querySelectorAll('.sort-btn').forEach(b => {
                    b.classList.remove('active');
                    const arrow = b.querySelector('.sort-arrow');
                    if (arrow) arrow.remove();
                });
                btn.classList.add('active');
                const arrow = document.createElement('span');
                arrow.className = 'sort-arrow';
                arrow.innerHTML = currentSort.dir === 'asc' ? ' &#9650;' : ' &#9660;';
                btn.appendChild(arrow);
                renderOverviewTable();
            });
        });
    }

    // --- Utilities ---
    function timeAgo(dateStr) {
        if (!dateStr) return '-';
        const now = Date.now();
        const then = new Date(dateStr).getTime();
        const diff = now - then;
        const secs = Math.floor(diff / 1000);
        if (secs < 60) return 'just now';
        const mins = Math.floor(secs / 60);
        if (mins < 60) return `${mins}m ago`;
        const hours = Math.floor(mins / 60);
        if (hours < 24) return `${hours}h ago`;
        const days = Math.floor(hours / 24);
        if (days < 30) return `${days}d ago`;
        const months = Math.floor(days / 30);
        return `${months}mo ago`;
    }

    function esc(str) {
        if (!str) return '';
        const div = document.createElement('div');
        div.textContent = str;
        return div.innerHTML;
    }

    function updateRefreshTime() {
        const el = document.getElementById('last-refresh');
        el.textContent = `Last refresh: ${new Date().toLocaleTimeString()}`;
    }
})();
