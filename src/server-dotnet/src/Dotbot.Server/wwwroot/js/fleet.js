// ============================================================
// DOTBOT FLEET DASHBOARD (#547) — Vanilla JS
// Hydrates the Fleet surface from /api/fleet/* (mock data now; live in #598).
// ============================================================

(function () {
    'use strict';

    const _dtFormatter = new Intl.DateTimeFormat('en-US', {
        weekday: 'short', month: 'short', day: 'numeric',
        year: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false
    });
    const _timeFormatter = new Intl.DateTimeFormat('en-US', {
        hour: '2-digit', minute: '2-digit', hour12: false
    });

    let refreshTimer = null;
    let appReadySignalled = false;

    // --- Init ---
    document.addEventListener('DOMContentLoaded', () => {
        fetchData();
        refreshTimer = setInterval(fetchData, 30000);
    });

    // --- Data fetching ---
    async function fetchData() {
        try {
            const [instances, alerts] = await Promise.all([
                fetchJson('/api/fleet/instances'),
                fetchJson('/api/fleet/alerts')
            ]);
            if (instances === null || alerts === null) return; // auth reload in flight
            renderInstances(instances);
            renderAlerts(alerts);
            updateRefreshTime();
            signalAppReady();
        } catch (err) {
            console.error('Failed to fetch fleet data:', err);
        }
    }

    async function fetchJson(url) {
        const resp = await fetch(url);
        if (!resp.ok) {
            if (resp.status === 401 || resp.status === 403) {
                window.location.reload();
                return null;
            }
            throw new Error(`HTTP ${resp.status} for ${url}`);
        }
        return resp.json();
    }

    // --- Instances ---
    function renderInstances(instances) {
        const list = instances || [];

        const counts = {
            total: list.length,
            online: list.filter(i => i.status === 'online').length,
            stale: list.filter(i => i.status === 'stale').length,
            error: list.filter(i => i.status === 'error').length,
            drones: list.filter(i => i.kind === 'drone').length
        };
        setText('stat-total', counts.total);
        setText('stat-online', counts.online);
        setText('stat-stale', counts.stale);
        setText('stat-error', counts.error);
        setText('stat-drones', counts.drones);
        setText('fleet-instance-count', counts.total);

        const container = document.getElementById('fleet-instances-list');
        const empty = document.getElementById('fleet-instances-empty');
        container.innerHTML = list.map(renderInstanceCard).join('');
        empty.style.display = list.length === 0 ? '' : 'none';
    }

    function renderInstanceCard(inst) {
        const status = inst.status || 'online';
        const staleBadge = status === 'stale'
            ? `<span class="fleet-stale-badge">STALE</span>` : '';
        const meta = [
            metaItem('status', status),
            metaItem('uptime', formatUptime(inst.uptimeSeconds)),
            metaItem('workflow', inst.activeWorkflow || '—'),
            metaItem('tasks', inst.taskCount != null ? inst.taskCount : 0),
            metaItem('last seen', timeAgo(inst.lastHeartbeatAt))
        ].join('');

        return `<div class="instance-card fleet-card status-${esc(status)}" `
            + `data-instance-id="${esc(inst.instanceId)}" data-kind="${esc(inst.kind)}" data-status="${esc(status)}">`
            + `<div class="instance-card-title">`
            + `<span class="led led-${esc(status)}"></span> ${esc(inst.name)}`
            + `<span class="fleet-kind-badge">${esc(inst.kind)}</span>${staleBadge}</div>`
            + `<div class="fleet-card-meta">${meta}</div>`
            + renderDroneUtil(inst.droneUtilization)
            + `</div>`;
    }

    function renderDroneUtil(util) {
        if (!util) return '';
        const max = util.maxConcurrent || 0;
        const pct = max > 0 ? Math.round((util.load / max) * 100) : 0;
        const success = Math.round((util.successRate || 0) * 100);
        return `<div class="fleet-drone-util">`
            + `<div class="fleet-util-row"><span class="fleet-meta-label">load</span> `
            + `<span>${util.load}/${max}</span>`
            + `<div class="progress-bar-sm"><div class="progress-fill" style="width:${pct}%"></div></div></div>`
            + `<div class="fleet-util-stats">`
            + `<span class="fleet-meta"><span class="fleet-meta-label">success</span> ${success}%</span>`
            + `<span class="fleet-meta"><span class="fleet-meta-label">avg</span> ${formatDuration(util.avgDurationSeconds)}</span>`
            + `</div></div>`;
    }

    function metaItem(label, value) {
        return `<span class="fleet-meta"><span class="fleet-meta-label">${esc(label)}</span> ${esc(String(value))}</span>`;
    }

    // --- Alerts ---
    function renderAlerts(alerts) {
        const all = alerts || [];
        const active = all.filter(a => a.status === 'active');
        const cleared = all.filter(a => a.status === 'cleared');

        setText('stat-alerts', active.length);
        renderAlertBanner(active);

        renderAlertList('fleet-alerts-active', 'fleet-alerts-empty', 'fleet-alerts-count', active, false);
        renderAlertList('fleet-alerts-history', 'fleet-history-empty', 'fleet-history-count', cleared, true);
    }

    function renderAlertBanner(active) {
        const banner = document.getElementById('fleet-alert-banner');
        if (active.length === 0) {
            banner.style.display = 'none';
            banner.textContent = '';
            return;
        }
        const critical = active.filter(a => a.severity === 'critical').length;
        const topSeverity = critical > 0 ? 'critical'
            : (active.some(a => a.severity === 'warning') ? 'warning' : 'info');
        const detail = critical > 0 ? ` — ${critical} critical` : '';
        banner.dataset.severity = topSeverity;
        banner.textContent = `${active.length} active alert${active.length === 1 ? '' : 's'}${detail}`;
        banner.style.display = '';
    }

    function renderAlertList(listId, emptyId, countId, alerts, isHistory) {
        setText(countId, alerts.length);
        const container = document.getElementById(listId);
        const empty = document.getElementById(emptyId);
        container.innerHTML = alerts.map(a => renderAlertRow(a, isHistory)).join('');
        empty.style.display = alerts.length === 0 ? '' : 'none';
    }

    function renderAlertRow(alert, isHistory) {
        const sev = alert.severity || 'info';
        const resolved = isHistory && alert.resolvedAt
            ? `<div class="fleet-alert-resolved">resolved ${esc(formatDashboardDateTime(alert.resolvedAt))}</div>`
            : '';
        return `<div class="fleet-alert-row" data-alert-id="${esc(alert.id)}" data-severity="${esc(sev)}">`
            + `<div class="fleet-alert-head">`
            + `<span class="fleet-severity-badge sev-${esc(sev)}">${esc(sev)}</span>`
            + `<span class="fleet-alert-instance">${esc(alert.instanceId)}</span>`
            + `<span class="fleet-alert-time">${esc(formatDashboardDateTime(alert.createdAt))}</span>`
            + `</div>`
            + `<div class="fleet-alert-msg">${esc(alert.message)}</div>`
            + resolved
            + `</div>`;
    }

    // --- Readiness signal (mirrors the Outpost shell; enables deterministic tests) ---
    function signalAppReady() {
        if (appReadySignalled) return;
        document.body.dataset.appReady = '1';
        appReadySignalled = true;
    }

    // --- Helpers ---
    function setText(id, value) {
        const el = document.getElementById(id);
        if (el) el.textContent = value;
    }

    function formatUptime(seconds) {
        if (!seconds || seconds <= 0) return '—';
        const mins = Math.floor(seconds / 60);
        if (mins < 60) return `${mins}m`;
        const hours = Math.floor(mins / 60);
        if (hours < 24) return `${hours}h ${mins % 60}m`;
        const days = Math.floor(hours / 24);
        return `${days}d ${hours % 24}h`;
    }

    function formatDuration(seconds) {
        if (!seconds || seconds <= 0) return '—';
        if (seconds < 60) return `${seconds}s`;
        const mins = Math.floor(seconds / 60);
        return `${mins}m ${seconds % 60}s`;
    }

    function timeAgo(dateStr) {
        if (!dateStr) return '-';
        const now = Date.now();
        const then = new Date(dateStr).getTime();
        if (isNaN(then)) return '-';
        const secs = Math.floor((now - then) / 1000);
        if (secs < 60) return 'just now';
        const mins = Math.floor(secs / 60);
        if (mins < 60) return `${mins}m ago`;
        const hours = Math.floor(mins / 60);
        if (hours < 24) return `${hours}h ago`;
        const days = Math.floor(hours / 24);
        if (days < 30) return `${days}d ago`;
        return `${Math.floor(days / 30)}mo ago`;
    }

    function formatDashboardDateTime(date) {
        try {
            const d = date instanceof Date ? date : new Date(date);
            if (isNaN(d.getTime())) return String(date);
            const parts = _dtFormatter.formatToParts(d);
            const get = (t) => (parts.find(p => p.type === t) || {}).value || '';
            return `${get('month')} ${get('day')} ${get('hour')}:${get('minute')}`;
        } catch (e) { return String(date); }
    }

    function formatDashboardTime(date) {
        try {
            const d = date instanceof Date ? date : new Date(date);
            if (isNaN(d.getTime())) return '';
            const parts = _timeFormatter.formatToParts(d);
            const get = (t) => (parts.find(p => p.type === t) || {}).value || '';
            return `${get('hour')}:${get('minute')}`;
        } catch (e) { return ''; }
    }

    function esc(str) {
        if (str === null || str === undefined) return '';
        const div = document.createElement('div');
        div.textContent = str;
        return div.innerHTML;
    }

    function updateRefreshTime() {
        const el = document.getElementById('last-refresh');
        if (el) el.textContent = `Last refresh: ${formatDashboardTime(new Date())}`;
    }
})();
