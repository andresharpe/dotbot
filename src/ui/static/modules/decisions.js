/**
 * Decisions module
 * Grouped list with inline expand, sidebar counts, and create/edit modal.
 */

// ── State ─────────────────────────────────────────────────────────────────────

let _decisions          = [];
let _expandedDecisionId = null;
let _editingDecisionId  = null;   // null = create mode

// ── Init ──────────────────────────────────────────────────────────────────────

async function initDecisions() {
    _bindCreateButton();
    _bindModal();
    _bindListDelegation();
    await _loadDecisions();
}

function _bindListDelegation() {
    const container = document.getElementById('decision-list');
    if (!container) return;

    container.addEventListener('click', (e) => {
        const row = e.target.closest('.decision-row');
        if (!row) return;
        const decisionId = row.dataset.decisionId;
        if (!decisionId || !isValidDecisionId(decisionId)) return;

        const actionEl = e.target.closest('[data-action]');
        if (!actionEl) return;
        const action = actionEl.dataset.action;

        if (action === 'accept') {
            e.stopPropagation();
            decisionAccept(decisionId);
        } else if (action === 'deprecate') {
            e.stopPropagation();
            decisionDeprecate(decisionId);
        } else if (action === 'edit') {
            e.stopPropagation();
            _openEditModal(decisionId);
        } else if (action === 'toggle') {
            toggleDecisionExpand(decisionId);
        }
    });
}

// ── Data loading ──────────────────────────────────────────────────────────────

async function _loadDecisions() {
    try {
        const res  = await fetch(`${API_BASE}/api/decisions`);
        const data = await res.json();
        _decisions = data.decisions || [];
        _renderList();
        _updateDecisionSidebar();
    } catch (e) {
        console.error('Failed to load decisions', e);
    }
}

// ── List rendering ────────────────────────────────────────────────────────────

function _renderList() {
    const container = document.getElementById('decision-list');
    if (!container) return;

    if (!_decisions || _decisions.length === 0) {
        container.innerHTML = '<div class="empty-state">No decisions yet. Create one or run the interview workflow to generate them automatically.</div>';
        return;
    }

    const statusOrder  = ['proposed', 'accepted', 'deprecated', 'superseded'];
    const statusLabels = { proposed: 'Proposed', accepted: 'Accepted', deprecated: 'Deprecated', superseded: 'Superseded' };

    const groups = {};
    for (const dec of _decisions) {
        const s = dec.status || 'proposed';
        if (!groups[s]) groups[s] = [];
        groups[s].push(dec);
    }

    let html = '';
    for (const status of statusOrder) {
        if (!groups[status] || groups[status].length === 0) continue;

        html += `<div class="decision-group">`;
        html += `<div class="decision-group-header">${statusLabels[status] || status}</div>`;

        for (const dec of groups[status]) {
            const isExpanded  = _expandedDecisionId === dec.id;
            const statusClass = `decision-status-${dec.status}`;
            const date        = _friendlyDate(dec.date);
            const typeBadge   = dec.type ? `<span class="decision-type-badge">${escapeHtml(dec.type)}</span>` : '';
            const impactBadge = dec.impact ? `<span class="decision-impact-badge impact-${escapeAttr(dec.impact)}">${escapeHtml(dec.impact)}</span>` : '';

            html += `<div class="decision-row${isExpanded ? ' expanded' : ''}" data-decision-id="${escapeAttr(dec.id)}">`;

            // ── Collapsed row (always visible) ────────────────────────
            html += `<div class="decision-row-main" data-action="toggle">`;
            html += `  <span class="decision-row-id">${escapeHtml(dec.id ?? '')}</span>`;
            html += `  <span class="decision-status-badge ${statusClass}">${escapeHtml(dec.status)}</span>`;
            html += `  ${typeBadge}`;
            html += `  ${impactBadge}`;
            html += `  <span class="decision-row-title">${escapeHtml(dec.title ?? '')}</span>`;
            html += `  <span class="decision-row-date">${date}</span>`;
            html += `  <div class="decision-row-actions">`;
            if (dec.status === 'proposed') {
                html += `<button class="process-action-btn primary" data-action="accept">Accept</button>`;
            }
            if (dec.status === 'accepted') {
                html += `<button class="process-action-btn danger" data-action="deprecate">Deprecate</button>`;
            }
            html += `    <button class="process-action-btn" data-action="edit">Edit</button>`;
            html += `  </div>`;
            html += `</div>`; // .decision-row-main

            // ── Expanded detail (inline) ───────────────────────────────
            if (isExpanded) {
                html += `<div class="decision-detail">`;

                // Meta bar
                const metaParts = [];
                if (dec.date) metaParts.push(`<span class="decision-meta-item"><b>Date:</b> ${_friendlyDate(dec.date)}</span>`);
                if (dec.stakeholders && dec.stakeholders.length > 0) {
                    metaParts.push(`<span class="decision-meta-item"><b>Stakeholders:</b> ${dec.stakeholders.map(s => escapeHtml(s)).join(', ')}</span>`);
                }
                if (dec.tags && dec.tags.length > 0) {
                    metaParts.push(`<span class="decision-meta-item"><b>Tags:</b> ${dec.tags.map(t => escapeHtml(t)).join(', ')}</span>`);
                }
                if (dec.related_decision_ids && dec.related_decision_ids.length > 0) {
                    metaParts.push(`<span class="decision-meta-item"><b>Related:</b> ${dec.related_decision_ids.map(id => escapeHtml(id)).join(', ')}</span>`);
                }
                if (dec.superseded_by) {
                    metaParts.push(`<span class="decision-meta-item"><b>Superseded by:</b> ${escapeHtml(dec.superseded_by)}</span>`);
                }
                if (dec.supersedes) {
                    metaParts.push(`<span class="decision-meta-item"><b>Supersedes:</b> ${escapeHtml(dec.supersedes)}</span>`);
                }
                if (dec.deprecation_reason) {
                    metaParts.push(`<span class="decision-meta-item"><b>Deprecation reason:</b> ${escapeHtml(dec.deprecation_reason)}</span>`);
                }
                if (metaParts.length > 0) {
                    html += `<div class="decision-detail-meta">${metaParts.join('')}</div>`;
                }

                // Content sections
                const contentFields = [
                    { key: 'context', label: 'Context' },
                    { key: 'decision', label: 'Decision' },
                    { key: 'consequences', label: 'Consequences' }
                ];
                for (const { key, label } of contentFields) {
                    if (dec[key]) {
                        html += `<div class="decision-section">`;
                        html += `  <div class="decision-section-title">${label}</div>`;
                        html += `  <div class="decision-section-body">${escapeHtml(dec[key])}</div>`;
                        html += `</div>`;
                    }
                }

                // Alternatives considered
                if (dec.alternatives_considered && dec.alternatives_considered.length > 0) {
                    html += `<div class="decision-section">`;
                    html += `  <div class="decision-section-title">Alternatives Considered</div>`;
                    html += `  <div class="decision-section-body">`;
                    for (const alt of dec.alternatives_considered) {
                        html += `<div><b>${escapeHtml(alt.option || '')}</b>`;
                        if (alt.reason_rejected) html += ` — ${escapeHtml(alt.reason_rejected)}`;
                        html += `</div>`;
                    }
                    html += `  </div>`;
                    html += `</div>`;
                }

                html += `</div>`; // .decision-detail
            }

            html += `</div>`; // .decision-row
        }

        html += `</div>`; // .decision-group
    }

    container.innerHTML = html;
}

function _friendlyDate(iso) {
    if (!iso) return '';
    try {
        return new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric', year: 'numeric' });
    } catch { return iso; }
}

// ── Expand / collapse ─────────────────────────────────────────────────────────

async function toggleDecisionExpand(decisionId) {
    if (_expandedDecisionId === decisionId) {
        _expandedDecisionId = null;
        _renderList();
        return;
    }

    // Fetch detail on first expand if not yet cached
    const existing = _decisions.find(d => d.id === decisionId);
    if (existing && !existing._detailLoaded) {
        try {
            const res  = await fetch(`${API_BASE}/api/decisions/${decisionId}`);
            const data = await res.json();
            if (data.success !== false) {
                Object.assign(existing, data);
                existing._detailLoaded = true;
            }
        } catch (e) { /* render without full detail */ }
    }

    _expandedDecisionId = decisionId;
    _renderList();
}

// ── Sidebar counts ────────────────────────────────────────────────────────────

function _updateDecisionSidebar() {
    const counts = { proposed: 0, accepted: 0, deprecated: 0, superseded: 0 };
    for (const dec of _decisions) {
        if (counts[dec.status] !== undefined) counts[dec.status]++;
    }
    const set = (id, val) => { const el = document.getElementById(id); if (el) el.textContent = val; };
    set('decision-count-proposed',   counts.proposed);
    set('decision-count-accepted',   counts.accepted);
    set('decision-count-deprecated', counts.deprecated);
    set('decision-count-superseded', counts.superseded);
    set('decision-count-total',      _decisions.length);
}

// ── Status transitions ────────────────────────────────────────────────────────

async function decisionAccept(decisionId) {
    await _transitionStatus(decisionId, 'accepted');
}

async function decisionDeprecate(decisionId) {
    const reason = prompt('Reason for deprecation (optional):') ?? '';
    await _transitionStatus(decisionId, 'deprecated', null, reason);
}

async function _transitionStatus(decisionId, newStatus, supersededBy, reason) {
    try {
        const res = await fetch(`${API_BASE}/api/decisions/${decisionId}/status`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'X-Dotbot-Request': '1' },
            body: JSON.stringify({ status: newStatus, superseded_by: supersededBy, reason })
        });
        const data = await res.json();
        if (data.success) {
            showToast(data.message || `Decision ${newStatus}`, 'success');
            _expandedDecisionId = null;
            await _loadDecisions();
        } else {
            showToast(data.error || 'Transition failed', 'error');
        }
    } catch (e) {
        showToast('Request failed', 'error');
    }
}

// ── Create button ─────────────────────────────────────────────────────────────

function _bindCreateButton() {
    const btn = document.getElementById('decision-create-btn');
    if (btn) btn.addEventListener('click', _openCreateModal);
}

// ── Modal ─────────────────────────────────────────────────────────────────────

function _bindModal() {
    const cancelBtn = document.getElementById('decision-modal-cancel');
    const closeBtn  = document.getElementById('decision-modal-close');
    const saveBtn   = document.getElementById('decision-modal-save');
    if (cancelBtn) cancelBtn.addEventListener('click', _closeModal);
    if (closeBtn)  closeBtn.addEventListener('click', _closeModal);
    if (saveBtn)   saveBtn.addEventListener('click', _saveDecision);

    const overlay = document.getElementById('decision-modal-overlay');
    if (overlay) overlay.addEventListener('click', (e) => { if (e.target === overlay) _closeModal(); });
}

function _openCreateModal() {
    _editingDecisionId = null;
    document.getElementById('decision-modal-title').textContent = 'New Decision';
    _clearForm();
    const statusEl = document.getElementById('decision-form-status');
    if (statusEl) statusEl.disabled = false;
    document.getElementById('decision-modal-overlay').classList.add('visible');
}

async function _openEditModal(decisionId) {
    _editingDecisionId = decisionId;
    document.getElementById('decision-modal-title').textContent = `Edit ${decisionId}`;
    try {
        const res  = await fetch(`${API_BASE}/api/decisions/${decisionId}`);
        const data = await res.json();
        if (!data.success) { showToast(data.error || 'Failed to load decision', 'error'); return; }

        document.getElementById('decision-form-title').value        = data.title ?? '';
        const statusEl = document.getElementById('decision-form-status');
        statusEl.value    = data.status ?? 'proposed';
        statusEl.disabled = true;
        document.getElementById('decision-form-type').value         = data.type ?? 'technical';
        document.getElementById('decision-form-impact').value       = data.impact ?? 'medium';
        document.getElementById('decision-form-context').value      = data.context ?? '';
        document.getElementById('decision-form-decision').value     = data.decision ?? '';
        document.getElementById('decision-form-consequences').value = data.consequences ?? '';
        document.getElementById('decision-form-stakeholders').value = (data.stakeholders || []).join(', ');
        document.getElementById('decision-form-tags').value         = (data.tags || []).join(', ');

        document.getElementById('decision-modal-overlay').classList.add('visible');
    } catch (e) {
        showToast('Failed to load decision for editing', 'error');
    }
}

function _closeModal() {
    document.getElementById('decision-modal-overlay').classList.remove('visible');
    _editingDecisionId = null;
}

function _clearForm() {
    ['title', 'context', 'decision', 'consequences', 'stakeholders', 'tags'].forEach(f => {
        const el = document.getElementById(`decision-form-${f}`);
        if (el) el.value = '';
    });
    const statusEl = document.getElementById('decision-form-status');
    if (statusEl) statusEl.value = 'proposed';
    const typeEl = document.getElementById('decision-form-type');
    if (typeEl) typeEl.value = 'technical';
    const impactEl = document.getElementById('decision-form-impact');
    if (impactEl) impactEl.value = 'medium';
}

async function _saveDecision() {
    const title        = document.getElementById('decision-form-title')?.value?.trim();
    const status       = document.getElementById('decision-form-status')?.value;
    const type         = document.getElementById('decision-form-type')?.value;
    const impact       = document.getElementById('decision-form-impact')?.value;
    const context      = document.getElementById('decision-form-context')?.value?.trim();
    const decision     = document.getElementById('decision-form-decision')?.value?.trim();
    const consequences = document.getElementById('decision-form-consequences')?.value?.trim();
    const stakeholders = (document.getElementById('decision-form-stakeholders')?.value || '').split(',').map(s => s.trim()).filter(Boolean);
    const tags         = (document.getElementById('decision-form-tags')?.value || '').split(',').map(s => s.trim()).filter(Boolean);

    if (!title || !context || !decision) {
        showToast('Title, Context, and Decision are required', 'error');
        return;
    }

    const payload = _editingDecisionId
        ? { title, type, impact, context, decision, consequences, stakeholders, tags }
        : { title, status, type, impact, context, decision, consequences, stakeholders, tags };

    try {
        let res;
        if (_editingDecisionId) {
            res = await fetch(`${API_BASE}/api/decisions/${_editingDecisionId}`, {
                method: 'PUT',
                headers: { 'Content-Type': 'application/json', 'X-Dotbot-Request': '1' },
                body: JSON.stringify(payload)
            });
        } else {
            res = await fetch(`${API_BASE}/api/decisions`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json', 'X-Dotbot-Request': '1' },
                body: JSON.stringify(payload)
            });
        }
        const data = await res.json();
        if (data.success) {
            showToast(data.message || 'Decision saved', 'success');
            _closeModal();
            await _loadDecisions();
            if (data.decision_id) {
                _expandedDecisionId = data.decision_id;
                _renderList();
            }
        } else {
            showToast(data.error || 'Save failed', 'error');
        }
    } catch (e) {
        showToast('Request failed', 'error');
    }
}

// ── Public lookup ─────────────────────────────────────────────────────────────

async function reloadDecisions() {
    await _loadDecisions();
}

function getDecisionById(decisionId) {
    return _decisions.find(d => d.id === decisionId) || null;
}

// escapeHtml is provided by modules/utils.js (loaded earlier)
