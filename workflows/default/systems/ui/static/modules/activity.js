/**
 * DOTBOT Control Panel - Activity Oscilloscope
 * Activity oscilloscope display and event handling
 */

/**
 * Initialize activity oscilloscope
 */
function initActivityScope() {
    if (typeof ActivityScope !== 'undefined') {
        activityScope = new ActivityScope('scope-canvas');
        // Start with offline state until we get first poll
        activityScope.setState('offline');
    } else {
        console.warn('ActivityScope not loaded');
    }
}

/**
 * Update text display with event data
 * @param {Object} event - Event object
 * @param {boolean} isRateLimit - Whether this is a rate limit event
 */
function updateTextDisplay(event, isRateLimit = false) {
    const textEl = document.getElementById('text-output');
    if (!textEl) return;

    let msg = event.message || '';
    if (msg.length > 150) {
        msg = msg.substring(0, 147) + '...';
    }

    textEl.textContent = msg;
    textEl.classList.remove('waiting');

    // Apply rate-limit styling if this is a rate limit event
    if (isRateLimit) {
        textEl.classList.add('rate-limit');
        startGlitchAcceleration(textEl);
    } else {
        textEl.classList.remove('rate-limit');
        stopGlitchAcceleration(textEl);
    }
}

/**
 * Update command display with event data
 * @param {Object} event - Event object
 */
function updateCommandDisplay(event) {
    const cmdEl = document.getElementById('command-text');
    const pillEl = document.getElementById('tool-pill');

    let msg = event.message || '';

    // Clean up shell commands
    if (msg.length > 80) {
        const cmdMatch = msg.match(/&&\s*(.+)$/);
        if (cmdMatch) {
            msg = cmdMatch[1];
        }
        if (msg.length > 80) {
            msg = msg.substring(0, 77) + '...';
        }
    }

    if (cmdEl) {
        cmdEl.textContent = msg;
    }
    if (pillEl) {
        pillEl.textContent = event.type || 'TOOL';
    }
}

/**
 * Map raw event type to oscilloscope visualization
 * @param {Object} event - Raw event
 * @returns {Object} Event with scope visualization properties
 */
function mapEventToScope(event) {
    const type = event.type || '';

    // Determine waveform shape based on event type
    let semantic = 'pulse';  // default
    let intensity = 'normal';

    switch (type.toLowerCase()) {
        case 'text':
            semantic = 'flow';      // Smooth sine for Claude output
            intensity = 'bright';
            break;
        case 'bash':
        case 'shell':
            semantic = 'pulse';     // Sharp spike for commands
            intensity = 'pulse';
            break;
        case 'read':
        case 'search':
        case 'grep':
        case 'glob':
            semantic = 'flow';      // Smooth for reads/searches
            break;
        case 'write':
        case 'edit':
            semantic = 'pulse';     // Spike for writes
            intensity = 'pulse';
            break;
        case 'error':
            semantic = 'noise';     // Jagged for errors
            intensity = 'bright';
            break;
        case 'rate_limit':
            semantic = 'noise';     // Jagged for rate limits
            intensity = 'bright';
            break;
        case 'done':
            semantic = 'complete';  // Dampening wave
            break;
        case 'init':
            semantic = 'sweep';     // Startup sweep
            intensity = 'bright';
            break;
    }

    return {
        ...event,
        semantic,
        intensity
    };
}

/**
 * Update activity display with event data
 * @param {Object} event - Event object
 */
function updateActivityDisplay(event) {
    const textEl = document.getElementById('text-output');
    const cmdEl = document.getElementById('command-text');
    const pillEl = document.getElementById('tool-pill');

    const eventType = (event.type || '').toLowerCase();
    let msg = event.message || event.summary || '';

    // Clean up shell commands - extract the actual command
    if (msg.length > 100) {
        const cmdMatch = msg.match(/&&\s*(.+)$/);
        if (cmdMatch) {
            msg = cmdMatch[1];
        }
        if (msg.length > 100) {
            msg = msg.substring(0, 97) + '...';
        }
    }

    // Route to appropriate display based on event type
    if (eventType === 'text') {
        // Claude's text output -> green area
        if (textEl) {
            textEl.textContent = msg;
            textEl.classList.remove('waiting');
        }
        lastTextOutput = msg;
    } else {
        // Tool/command activity -> amber command row
        if (cmdEl) {
            cmdEl.textContent = msg;
        }
        if (pillEl) {
            pillEl.textContent = event.type || 'TOOL';
        }
    }
}

/**
 * Start glitch acceleration effect for rate limiting
 * @param {HTMLElement} el - Element to apply effect to
 */
function startGlitchAcceleration(el) {
    // Clear any existing timer
    if (rateLimitGlitchTimer) {
        clearInterval(rateLimitGlitchTimer);
    }

    // Start slow (1.5s) and accelerate to fast (0.15s), then cycle back
    let speed = 1.5;
    let accelerating = true;
    el.style.setProperty('--glitch-speed', speed + 's');
    el.classList.add('glitch-slow');

    rateLimitGlitchTimer = setInterval(() => {
        if (accelerating) {
            speed = speed * 0.90;  // Accelerate by 10% each tick
            if (speed <= 0.15) {
                speed = 0.15;
                accelerating = false;
                el.classList.remove('glitch-slow');  // Remove scale effect at high speed
            }
        } else {
            speed = speed * 1.12;  // Decelerate by 12% each tick
            if (speed >= 1.5) {
                speed = 1.5;
                accelerating = true;
                el.classList.add('glitch-slow');  // Add scale effect back at slow speed
            }
        }
        el.style.setProperty('--glitch-speed', speed + 's');
    }, 200);
}

/**
 * Stop glitch acceleration effect
 * @param {HTMLElement} el - Element to remove effect from
 */
function stopGlitchAcceleration(el) {
    if (rateLimitGlitchTimer) {
        clearInterval(rateLimitGlitchTimer);
        rateLimitGlitchTimer = null;
    }
    el.style.removeProperty('--glitch-speed');
    el.classList.remove('glitch-slow');
}
