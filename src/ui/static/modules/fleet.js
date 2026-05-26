/**
 * Fleet runtime picker.
 */

let fleetRefreshTimer = null;

function getSelectedRuntimeId() {
    try { return window.localStorage.getItem('dotbot:selectedRuntimeId') || ''; } catch (e) { return ''; }
}

function setSelectedRuntimeId(runtimeId) {
    try {
        if (runtimeId) {
            window.localStorage.setItem('dotbot:selectedRuntimeId', runtimeId);
        } else {
            window.localStorage.removeItem('dotbot:selectedRuntimeId');
        }
    } catch (e) {
        // Ignore storage failures; the picker will still update until reload.
    }
}

function runtimeLabel(runtime) {
    const name = runtime.project_name || runtime.runtime_id || 'runtime';
    const machine = runtime.machine ? ` @ ${runtime.machine}` : '';
    const status = runtime.status === 'online' ? '' : ` (${runtime.status})`;
    return `${name}${machine}${status}`;
}

async function refreshFleetRuntimes() {
    const select = document.getElementById('runtime-picker');
    const status = document.getElementById('runtime-picker-status');
    if (!select) return;

    try {
        const response = await fetch('/api/fleet/runtimes');
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const data = await response.json();
        const runtimes = Array.isArray(data.runtimes) ? data.runtimes : [];
        const selected = getSelectedRuntimeId();

        select.innerHTML = '';
        const localOption = document.createElement('option');
        localOption.value = '';
        localOption.textContent = 'Local dashboard';
        select.appendChild(localOption);

        runtimes.forEach((runtime) => {
            const option = document.createElement('option');
            option.value = runtime.runtime_id;
            option.textContent = runtimeLabel(runtime);
            select.appendChild(option);
        });

        if (selected && runtimes.some((runtime) => runtime.runtime_id === selected)) {
            select.value = selected;
        } else if (selected) {
            setSelectedRuntimeId('');
            select.value = '';
        }

        if (status) {
            status.textContent = runtimes.length > 0 ? `${runtimes.length}` : '0';
            status.title = `${runtimes.length} registered runtime${runtimes.length === 1 ? '' : 's'}`;
        }
    } catch (error) {
        if (status) {
            status.textContent = '!';
            status.title = `Fleet unavailable: ${error.message}`;
        }
    }
}

function initializeFleetPicker() {
    const select = document.getElementById('runtime-picker');
    if (!select) return;

    select.value = getSelectedRuntimeId();
    select.addEventListener('change', () => {
        setSelectedRuntimeId(select.value);
        window.location.reload();
    });

    refreshFleetRuntimes();
    if (fleetRefreshTimer) clearInterval(fleetRefreshTimer);
    fleetRefreshTimer = setInterval(refreshFleetRuntimes, 5000);
}

document.addEventListener('DOMContentLoaded', initializeFleetPicker);
