/**
 * DOTBOT Control Panel - Aether Module
 * Ambient feedback system for visual synchronization
 *
 * Lexicon:
 *   Conduit = Bridge device
 *   Token = API username
 *   Node = Light
 *   Cluster = Light group
 *   Scan = Discovery
 *   Bond = Pairing
 *   Pulse = Flash
 *   Radiate = Set color
 */

const Aether = (function() {
    // Configuration
    const STORAGE_KEY = 'aether_link';
    const BOND_TIMEOUT = 30000; // 30 seconds for bonding
    const BOND_POLL_INTERVAL = 1000; // Poll every second during bonding

    // State tracking for event detection
    let _lastTaskId = null;
    let _lastFailures = 0;
    let _initialized = false;
    let _linked = false;

    // Stats tracking
    let _stats = { starts: 0, completes: 0, errors: 0 };
    let _lastEvent = null;
    let _conduit = null;
    let _token = null;
    let _selectedNodes = [];
    let _bondingInterval = null;
    let _bondingTimeout = null;
    let _nodeNamesCache = {};  // { "1": "Living Room", "2": "Kitchen" }

    // Activity breathing rhythm (2 second throb for responsiveness)
    let _lastActivityPulse = 0;
    let _breathePhase = false;  // false = bright, true = dim
    const ACTIVITY_PULSE_INTERVAL = 2000; // 2 seconds between throbs

    // Idle breathing (continuous throb while connected)
    let _idleBreatheInterval = null;
    const IDLE_BREATHE_INTERVAL = 4000; // 4 seconds between idle breaths
    let _connectionFailures = 0;
    const MAX_CONNECTION_FAILURES = 3; // Stop idle breathing after 3 failures

    // Theme color sequence for celebrations
    const THEME_COLORS = ['primary', 'success', 'warning', 'secondary', 'primary'];

    /**
     * Convert RGB to CIE xy color space for Hue API
     */
    function rgbToXy(r, g, b) {
        // Normalize RGB values
        r = r / 255;
        g = g / 255;
        b = b / 255;

        // Apply gamma correction
        r = (r > 0.04045) ? Math.pow((r + 0.055) / 1.055, 2.4) : r / 12.92;
        g = (g > 0.04045) ? Math.pow((g + 0.055) / 1.055, 2.4) : g / 12.92;
        b = (b > 0.04045) ? Math.pow((b + 0.055) / 1.055, 2.4) : b / 12.92;

        // Convert to XYZ (Wide RGB D65)
        const X = r * 0.649926 + g * 0.103455 + b * 0.197109;
        const Y = r * 0.234327 + g * 0.743075 + b * 0.022598;
        const Z = r * 0.0000000 + g * 0.053077 + b * 1.035763;

        // Calculate xy
        const sum = X + Y + Z;
        if (sum === 0) return [0.3227, 0.329]; // White point
        return [X / sum, Y / sum];
    }

    /**
     * Get color from current theme CSS variables
     * Reads directly from --color-{name}-rgb variables set by theme system
     */
    function getThemeColor(colorName) {
        const root = document.documentElement;
        const style = getComputedStyle(root);

        // Read RGB from CSS variable (format: "R G B" space-separated)
        const rgbStr = style.getPropertyValue(`--color-${colorName}-rgb`)?.trim();

        if (rgbStr) {
            const parts = rgbStr.split(/\s+/).map(Number);
            if (parts.length >= 3 && !isNaN(parts[0])) {
                const [r, g, b] = parts;
                return { xy: rgbToXy(r, g, b), bri: 254 };
            }
        }

        // If color not found, try primary as default
        if (colorName !== 'primary') {
            return getThemeColor('primary');
        }

        // Ultimate fallback - white
        return { xy: [0.3227, 0.329], bri: 254 };
    }

    // Dynamic color getter
    function COLORS(name) {
        return getThemeColor(name);
    }

    /**
     * Initialize Aether - check for cached link, attempt discovery
     * @returns {Promise<{status: string, conduit?: string}>}
     */
    async function init() {
        // Check backend for existing link
        const cached = await loadLink();

        if (cached && cached.conduit && cached.token) {
            _conduit = cached.conduit;
            _token = cached.token;
            _selectedNodes = cached.nodes || [];

            // Verify the link is still valid at cached IP
            const valid = await verifyLink();
            if (valid) {
                _linked = true;
                showNavItem(true);
                startIdleBreathe();  // Start continuous breathing
                return { status: 'linked', conduit: _conduit };
            }

            // Verify failed — try discovery, then re-verify (IP may have changed)
            const discovered = await scan();
            if (discovered) {
                if (discovered.ip !== _conduit) {
                    _conduit = discovered.ip;
                }
                // Re-verify at discovered IP (handles both same-IP transient failure and IP change)
                const validAtDiscoveredIp = await verifyLink();
                if (validAtDiscoveredIp) {
                    _linked = true;
                    await saveLink();
                    showNavItem(true);
                    startIdleBreathe();
                    return { status: 'linked', conduit: _conduit };
                }
            }

            // Token no longer valid anywhere - clear and require re-bond
            await clearLink();
        }

        // Try discovery
        const discovered = await scan();
        if (discovered) {
            showNavItem(true);
            return { status: 'detected', conduit: discovered.ip };
        }

        return { status: 'absent' };
    }

    /**
     * Scan for conduits on the network
     * @returns {Promise<{ip: string, id: string}|null>}
     */
    async function scan() {
        try {
            const response = await fetch(`${API_BASE}/api/aether/scan`);
            if (!response.ok) return null;

            const data = await response.json();
            if (data.found && data.conduit) {
                return { ip: data.conduit, id: data.id };
            }
        } catch (e) {
            // Scan failed silently
        }
        return null;
    }

    /**
     * Start the bonding process - 30s window to press conduit button
     * @returns {Promise<boolean>}
     */
    async function startBonding() {
        const discovered = await scan();
        if (!discovered) {
            updateBondUI('error', 'No conduit detected on network');
            return false;
        }

        _conduit = discovered.ip;
        updateBondUI('waiting', 'Press the button on your conduit...');
        startBondCountdown(30);

        return new Promise((resolve) => {
            let elapsed = 0;
            let bonded = false;

            _bondingInterval = setInterval(async () => {
                if (bonded) return;  // Already bonded, skip overlapping ticks
                elapsed += BOND_POLL_INTERVAL;

                // Try to create a token
                const token = await attemptBond(discovered.ip);
                if (bonded) return;  // Another tick beat us to it
                if (token) {
                    bonded = true;
                    stopBonding();
                    _token = token;
                    _linked = true;
                    saveLink();
                    updateBondUI('success', 'Bond established');
                    showNavItem(true);
                    startIdleBreathe();  // Start continuous breathing

                    // Trigger bond success effect
                    pulse('success');
                    if (typeof activityScope !== 'undefined' && activityScope) {
                        activityScope.injectDamped(1.2, 80);
                    }

                    // Load nodes after short delay
                    setTimeout(() => loadNodes(), 500);
                    resolve(true);
                    return;
                }

                if (elapsed >= BOND_TIMEOUT) {
                    stopBonding();
                    updateBondUI('timeout', 'Bonding timed out');
                    resolve(false);
                }
            }, BOND_POLL_INTERVAL);

            _bondingTimeout = setTimeout(() => {
                stopBonding();
                updateBondUI('timeout', 'Bonding timed out');
                resolve(false);
            }, BOND_TIMEOUT + 500);
        });
    }

    /**
     * Attempt to create a bond (register with conduit)
     */
    async function attemptBond(ip) {
        try {
            const response = await fetch(`${API_BASE}/api/aether/bond`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ conduit: ip })
            });

            if (!response.ok) return null;

            const data = await response.json();
            if (data.success && data.username) {
                return data.username;
            }
        } catch (e) {
            // Expected to fail until button is pressed
        }
        return null;
    }

    /**
     * Stop the bonding process
     */
    function stopBonding() {
        if (_bondingInterval) {
            clearInterval(_bondingInterval);
            _bondingInterval = null;
        }
        if (_bondingTimeout) {
            clearTimeout(_bondingTimeout);
            _bondingTimeout = null;
        }
        stopBondCountdown();
    }

    /**
     * Verify the current link is still valid
     */
    async function verifyLink() {
        if (!_conduit || !_token) return false;

        try {
            const response = await fetch(`${API_BASE}/api/aether/verify`);
            if (!response.ok) return false;
            const data = await response.json();
            return data.valid === true;
        } catch (e) {
            return false;
        }
    }

    /**
     * Load available nodes from the conduit
     * Auto-selects all reachable nodes if none are selected
     * Updates node names cache from bridge data
     */
    async function loadNodes() {
        if (!_linked || !_conduit || !_token) return [];

        try {
            const response = await fetch(`${API_BASE}/api/aether/nodes`);
            if (!response.ok) return [];

            const data = await response.json();
            if (!data.success) return [];

            const nodes = data.nodes || [];

            for (const node of nodes) {
                // Cache node names for preservation
                _nodeNamesCache[node.id] = node.name;
            }

            // Auto-select all reachable nodes if none selected
            if (_selectedNodes.length === 0) {
                _selectedNodes = nodes
                    .filter(n => n.reachable)
                    .map(n => n.id);
                await saveLink();
            }

            renderNodeList(nodes);
            return nodes;
        } catch (e) {
            return [];
        }
    }

    /**
     * Process state update from polling - detect events and trigger effects
     * Oscilloscope effects work regardless of light connection
     */
    function processState(state) {
        const currentTaskId = state.tasks?.current?.id || null;
        const failures = state.session?.consecutive_failures || 0;

        // First poll establishes baseline - don't fire events
        if (!_initialized) {
            _lastTaskId = currentTaskId;
            _lastFailures = failures;
            _initialized = true;
            return;
        }

        // Task start: new task ID appears (different from last seen)
        if (currentTaskId && currentTaskId !== _lastTaskId) {
            _stats.starts++;
            _lastEvent = { type: 'START', time: new Date(), taskId: currentTaskId };
            updateStatsUI();
            if (_linked && _selectedNodes.length > 0) {
                celebrateColors();  // Dramatic cycle through all theme colors
            }
            if (typeof activityScope !== 'undefined' && activityScope) {
                activityScope.injectPulse(1.5, 40);
            }
        }

        // Task complete: task ID disappears without new failures
        if (_lastTaskId && !currentTaskId && failures <= _lastFailures) {
            _stats.completes++;
            _lastEvent = { type: 'COMPLETE', time: new Date(), taskId: _lastTaskId };
            updateStatsUI();
            if (_linked && _selectedNodes.length > 0) {
                celebrateColors();  // Dramatic cycle through all theme colors
            }
            if (typeof activityScope !== 'undefined' && activityScope) {
                activityScope.injectSweep(1.0);
            }
        }

        // Error: failures increased
        if (failures > _lastFailures) {
            _stats.errors++;
            _lastEvent = { type: 'ERROR', time: new Date(), failures };
            updateStatsUI();
            if (_linked && _selectedNodes.length > 0) {
                pulse('warning');  // Warning color from theme
            }
            if (typeof activityScope !== 'undefined' && activityScope) {
                activityScope.injectNoise(0.8, 40);
            }
        }

        // Update tracking
        _lastTaskId = currentTaskId;
        _lastFailures = failures;
    }

    /**
     * Process activity event - respond to tool calls, writes, errors during tasks
     */
    function processActivity(event) {
        const type = (event.type || '').toLowerCase();

        // Different effects for different activity types
        switch (type) {
            case 'write':
            case 'edit':
            case 'bash':
            case 'shell':
                // Coding activity - breathing throb (bright↔dim) every 3-5 seconds
                const now = Date.now();
                if (now - _lastActivityPulse >= ACTIVITY_PULSE_INTERVAL) {
                    _lastActivityPulse = now;
                    if (_linked && _selectedNodes.length > 0) {
                        breathe('primary');
                    }
                }
                if (type === 'write' || type === 'edit') {
                    _stats.starts++; // Count as activity
                    updateStatsUI();
                }
                break;

            case 'error':
                // Errors - warning alert
                if (_linked && _selectedNodes.length > 0) {
                    pulse('warning');
                }
                _stats.errors++;
                _lastEvent = { type: 'ERROR', time: new Date() };
                updateStatsUI();
                break;

            case 'rate_limit':
                // Rate limit - slow warning pulse
                if (_linked && _selectedNodes.length > 0) {
                    radiate('warning', 150);
                }
                break;

            case 'text':
                // Text message - go mental with color cycle!
                if (_linked && _selectedNodes.length > 0) {
                    celebrateColors();
                }
                break;
        }
    }

    /**
     * Send a command to selected nodes via backend proxy
     * Returns true if any node succeeded, false otherwise
     */
    async function sendCommand(state) {
        if (!_linked || !_conduit || !_token || _selectedNodes.length === 0) return false;

        try {
            const response = await fetch(`${API_BASE}/api/aether/command`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    nodes: _selectedNodes,
                    state: state
                })
            });
            return response.ok;
        } catch (e) {
            return false;
        }
    }

    /**
     * Breathe - throb between bright and dim in the primary color
     * Creates a gentle pulsing effect during coding
     * Returns true if successful, false if connection failed
     */
    async function breathe(colorName) {
        if (!_linked || !_conduit || !_token || _selectedNodes.length === 0) return false;

        const color = COLORS(colorName);
        _breathePhase = !_breathePhase;  // Toggle phase

        const brightness = _breathePhase ? 80 : 254;  // Dim or bright
        const transition = _breathePhase ? 8 : 5;     // 800ms to dim, 500ms to bright

        return await sendCommand({
            on: true,
            xy: color.xy,
            bri: brightness,
            transitiontime: transition
        });
    }

    /**
     * Start idle breathing - continuous gentle throb while connected
     * Automatically stops if bridge becomes unreachable
     */
    function startIdleBreathe() {
        if (_idleBreatheInterval) return;  // Already running
        _connectionFailures = 0;  // Reset failure counter

        _idleBreatheInterval = setInterval(async () => {
            // Only breathe if linked and no recent activity pulse
            if (_linked && _selectedNodes.length > 0) {
                const now = Date.now();
                // Only idle-breathe if no activity in last 2 seconds
                if (now - _lastActivityPulse >= 2000) {
                    const success = await breathe('primary');
                    if (success) {
                        _connectionFailures = 0;  // Reset on success
                    } else {
                        _connectionFailures++;
                        if (_connectionFailures >= MAX_CONNECTION_FAILURES) {
                            stopIdleBreathe();
                        }
                    }
                }
            }
        }, IDLE_BREATHE_INTERVAL);
    }

    /**
     * Stop idle breathing
     */
    function stopIdleBreathe() {
        if (_idleBreatheInterval) {
            clearInterval(_idleBreatheInterval);
            _idleBreatheInterval = null;
        }
    }

    /**
     * Celebrate - dramatic cycle through all theme colors
     * Used for task start and task complete
     */
    async function celebrateColors() {
        if (!_linked || !_conduit || !_token || _selectedNodes.length === 0) return;

        // Cycle through theme colors with bright flashes
        for (let i = 0; i < THEME_COLORS.length; i++) {
            const colorName = THEME_COLORS[i];
            const color = COLORS(colorName);

            await sendCommand({
                on: true,
                xy: color.xy,
                bri: 254,
                transitiontime: 1  // 100ms quick transition
            });

            // Wait between colors (200ms per color)
            if (i < THEME_COLORS.length - 1) {
                await new Promise(resolve => setTimeout(resolve, 200));
            }
        }
    }

    /**
     * Bright pulse - full brightness theme color
     */
    async function pulseBright(colorName) {
        if (!_linked || !_conduit || !_token || _selectedNodes.length === 0) return;

        const color = COLORS(colorName);
        await sendCommand({
            on: true,
            xy: color.xy,
            bri: 254,
            transitiontime: 1  // 100ms quick
        });
    }

    /**
     * Quick pulse - shorter duration for frequent events
     */
    async function pulseQuick(colorName, brightness) {
        if (!_linked || !_conduit || !_token || _selectedNodes.length === 0) return;

        const color = COLORS(colorName);
        const bri = brightness || 100;

        await sendCommand({
            on: true,
            xy: color.xy,
            bri: bri,
            transitiontime: 1  // 100ms transition
        });
    }

    /**
     * Pulse (flash) selected nodes with a color
     */
    async function pulse(colorName) {
        if (!_linked || !_conduit || !_token || _selectedNodes.length === 0) return;

        const color = COLORS(colorName);
        await sendCommand({
            alert: 'select',
            xy: color.xy
        });
    }

    /**
     * Radiate (set sustained color) on selected nodes
     */
    async function radiate(colorName, brightness) {
        if (!_linked || !_conduit || !_token || _selectedNodes.length === 0) return;

        const color = COLORS(colorName);
        const bri = brightness || color.bri;

        await sendCommand({
            on: true,
            xy: color.xy,
            bri: bri
        });
    }

    /**
     * Save link to backend
     * Saves nodes with names for preservation across restarts
     */
    async function saveLink() {
        // Build nodes array with names from cache
        const nodesWithNames = _selectedNodes.map(id => ({
            id: id,
            name: _nodeNamesCache[id] || `Node ${id}`
        }));

        const data = {
            linked: true,
            conduit: _conduit,
            token: _token,
            nodes: nodesWithNames,
            linkedAt: new Date().toISOString()
        };
        try {
            await fetch(`${API_BASE}/api/aether/config`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(data)
            });
        } catch (e) {
            // Ignore save failures
        }
    }

    /**
     * Load link from backend
     * Handles both old format (nodes as string array) and new format (nodes as objects)
     */
    async function loadLink() {
        try {
            const response = await fetch(`${API_BASE}/api/aether/config`);
            if (!response.ok) return null;
            const data = await response.json();

            // Handle node format migration: array of objects → populate cache, extract IDs
            if (data.nodes && Array.isArray(data.nodes) && data.nodes.length > 0) {
                if (typeof data.nodes[0] === 'object') {
                    // New format: [{id: "1", name: "Living Room"}, ...]
                    _nodeNamesCache = {};
                    data.nodes.forEach(n => _nodeNamesCache[n.id] = n.name);
                    // Convert to ID array for _selectedNodes compatibility
                    data.nodes = data.nodes.map(n => n.id);
                }
                // Old format: ["1", "2", ...] - keep as-is, names will be loaded from bridge
            }

            // Return data even if not linked (for preserved settings)
            return data;
        } catch (e) {
            return null;
        }
    }

    /**
     * Clear link from backend
     * Preserves conduit, token, and nodes for easy re-linking
     * Only sets linked to false
     */
    async function clearLink() {
        stopIdleBreathe();  // Stop continuous breathing
        _linked = false;
        // Keep _conduit, _token, _selectedNodes, _nodeNamesCache in memory for recovery

        try {
            // Build nodes with names for preservation
            const nodesWithNames = _selectedNodes.map(id => ({
                id: id,
                name: _nodeNamesCache[id] || `Node ${id}`
            }));

            await fetch(`${API_BASE}/api/aether/config`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    linked: false,
                    conduit: _conduit,
                    token: _token,
                    nodes: nodesWithNames,
                    linkedAt: new Date().toISOString()
                })
            });
        } catch (e) {
            // Ignore
        }
    }

    /**
     * Unlink from conduit
     */
    async function unlink() {
        await clearLink();
        showNavItem(false);
        renderUnlinkedUI();
    }

    /**
     * Toggle node selection
     */
    async function toggleNode(nodeId) {
        const idx = _selectedNodes.indexOf(nodeId);
        if (idx >= 0) {
            _selectedNodes.splice(idx, 1);
        } else {
            _selectedNodes.push(nodeId);
        }
        await saveLink();
        updateNodeCheckboxes();
    }

    // ========== UI HELPERS ==========

    function showNavItem(show) {
        const navItem = document.getElementById('aetherNavItem');
        if (navItem) {
            navItem.style.display = show ? 'block' : 'none';
            navItem.setAttribute('data-bonded', _linked ? 'true' : 'false');
        }
    }

    function updateBondUI(status, message) {
        const bondStatus = document.getElementById('aetherBondStatus');
        const bondMessage = document.getElementById('aetherBondMessage');

        if (bondStatus) {
            bondStatus.className = 'aether-bond-status ' + status;
        }
        if (bondMessage) {
            bondMessage.textContent = message;
        }

        // Switch panels based on success
        if (status === 'success') {
            setTimeout(() => {
                const bondPanel = document.getElementById('aetherBondPanel');
                const configPanel = document.getElementById('aetherConfigPanel');
                if (bondPanel) bondPanel.style.display = 'none';
                if (configPanel) configPanel.style.display = 'block';
            }, 1000);
        }
    }

    function startBondCountdown(seconds) {
        const countdown = document.getElementById('aetherCountdown');
        if (!countdown) return;

        let remaining = seconds;
        countdown.textContent = remaining;
        countdown.style.display = 'block';

        const timer = setInterval(() => {
            remaining--;
            countdown.textContent = remaining;
            if (remaining <= 0) {
                clearInterval(timer);
                countdown.style.display = 'none';
            }
        }, 1000);

        countdown._timer = timer;
    }

    function stopBondCountdown() {
        const countdown = document.getElementById('aetherCountdown');
        if (countdown && countdown._timer) {
            clearInterval(countdown._timer);
            countdown.style.display = 'none';
        }
    }

    function renderNodeList(nodes) {
        const container = document.getElementById('aetherNodeList');
        if (!container) return;

        if (nodes.length === 0) {
            container.innerHTML = '<div class="aether-empty">No nodes found</div>';
            return;
        }

        container.innerHTML = nodes.map(node => `
            <label class="aether-node-item">
                <input type="checkbox"
                       value="${node.id}"
                       ${_selectedNodes.includes(node.id) ? 'checked' : ''}
                       ${!node.reachable ? 'disabled' : ''}>
                <span class="aether-node-name">${node.name}</span>
                <span class="aether-node-status ${node.reachable ? 'on' : 'off'}"></span>
            </label>
        `).join('');

        // Add event listeners
        container.querySelectorAll('input[type="checkbox"]').forEach(cb => {
            cb.addEventListener('change', (e) => {
                toggleNode(e.target.value);
            });
        });
    }

    function updateNodeCheckboxes() {
        const container = document.getElementById('aetherNodeList');
        if (!container) return;

        container.querySelectorAll('input[type="checkbox"]').forEach(cb => {
            cb.checked = _selectedNodes.includes(cb.value);
        });
    }

    function updateStatsUI() {
        const startEl = document.getElementById('aetherStartCount');
        const completeEl = document.getElementById('aetherCompleteCount');
        const errorEl = document.getElementById('aetherErrorCount');
        const lastEventEl = document.getElementById('aetherLastEvent');

        if (startEl) startEl.textContent = _stats.starts;
        if (completeEl) completeEl.textContent = _stats.completes;
        if (errorEl) errorEl.textContent = _stats.errors;

        if (lastEventEl && _lastEvent) {
            const timeStr = _lastEvent.time.toLocaleTimeString();
            const colorVar = _lastEvent.type === 'START' ? '--color-success' :
                             _lastEvent.type === 'COMPLETE' ? '--color-secondary' : '--color-primary';
            lastEventEl.innerHTML = `<span class="event-type" style="color: var(${colorVar})">${_lastEvent.type}</span><span class="event-time">${timeStr}</span>`;
        }
    }

    function renderUnlinkedUI() {
        const bondPanel = document.getElementById('aetherBondPanel');
        const configPanel = document.getElementById('aetherConfigPanel');

        if (bondPanel) bondPanel.style.display = 'block';
        if (configPanel) configPanel.style.display = 'none';

        updateBondUI('idle', 'Press to begin bonding');
    }

    function renderLinkedUI() {
        const bondPanel = document.getElementById('aetherBondPanel');
        const configPanel = document.getElementById('aetherConfigPanel');
        const conduitInfo = document.getElementById('aetherConduitInfo');

        if (bondPanel) bondPanel.style.display = 'none';
        if (configPanel) configPanel.style.display = 'block';
        if (conduitInfo) conduitInfo.textContent = _conduit || 'Unknown';
    }

    /**
     * Initialize settings panel UI
     */
    function initSettingsPanel() {
        if (_linked) {
            renderLinkedUI();
            loadNodes();
        } else {
            renderUnlinkedUI();
        }

        // Bond button
        const bondBtn = document.getElementById('aetherBondBtn');
        if (bondBtn) {
            bondBtn.addEventListener('click', () => {
                startBonding();
            });
        }

        // Test pulse button
        const testBtn = document.getElementById('aetherTestBtn');
        if (testBtn) {
            testBtn.addEventListener('click', () => {
                pulse('primary');
            });
        }

        // Unlink button
        const unlinkBtn = document.getElementById('aetherUnlinkBtn');
        if (unlinkBtn) {
            unlinkBtn.addEventListener('click', () => {
                if (confirm('Disconnect from conduit?')) {
                    unlink();
                }
            });
        }
    }

    // Public API
    return {
        init,
        scan,
        startBonding,
        stopBonding,
        loadNodes,
        processState,
        processActivity,
        pulse,
        pulseQuick,
        pulseBright,
        breathe,
        celebrateColors,
        radiate,
        startIdleBreathe,
        stopIdleBreathe,
        unlink,
        toggleNode,
        initSettingsPanel,
        isLinked: () => _linked,
        getConduit: () => _conduit,
        getSelectedNodes: () => _selectedNodes,
        getStats: () => ({ ..._stats }),
        getLastEvent: () => _lastEvent
    };
})();
