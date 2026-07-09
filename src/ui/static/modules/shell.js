// Shell chrome behaviour (v4 navigation shell, #551/#605).
// Rail items delegate to switchToTab() so all tab side effects (polling
// start/stop, decision reloads, settings init) keep working unchanged.

const RAIL_PIN_KEY = 'dotbot:shell:railPinned';

function initShell() {
    const shell = document.getElementById('shell');
    if (!shell) return;

    document.querySelectorAll('.shell-rail-item[data-tab]').forEach(item => {
        item.addEventListener('click', (e) => {
            e.preventDefault();
            switchToTab(item.dataset.tab);
        });
    });

    const pinBtn = document.getElementById('shell-rail-pin');
    if (pinBtn) {
        if (layoutGet(RAIL_PIN_KEY) === '1') {
            shell.dataset.rail = 'pinned';
        }
        updatePinButton(shell, pinBtn);
        pinBtn.addEventListener('click', () => {
            const pinned = shell.dataset.rail === 'pinned';
            if (pinned) {
                delete shell.dataset.rail;
                layoutRemove(RAIL_PIN_KEY);
            } else {
                shell.dataset.rail = 'pinned';
                layoutSet(RAIL_PIN_KEY, '1');
            }
            updatePinButton(shell, pinBtn);
        });
    }
}

function updatePinButton(shell, pinBtn) {
    const pinned = shell.dataset.rail === 'pinned';
    pinBtn.querySelector('.shell-rail-icon').textContent = pinned ? '⇤' : '⇥';
    pinBtn.querySelector('.shell-rail-label').textContent = pinned ? 'Unpin rail' : 'Pin rail';
    pinBtn.title = pinned ? 'Collapse rail to icons' : 'Pin rail open';
}

// Called from switchToTab() so rail state follows every tab change,
// whatever triggered it (rail click, logo click, editor.js jump).
function syncRailActive(tabId) {
    document.querySelectorAll('.shell-rail-item[data-tab]').forEach(item => {
        if (item.dataset.tab === tabId) {
            item.setAttribute('aria-current', 'page');
        } else {
            item.removeAttribute('aria-current');
        }
    });
}
