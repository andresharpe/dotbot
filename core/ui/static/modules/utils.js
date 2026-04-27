/**
 * DOTBOT Control Panel - Utility Functions
 * Generic utility functions used across modules
 */

/**
 * Escape HTML special characters to prevent XSS
 * @param {string} text - Text to escape
 * @returns {string} Escaped text
 */
function escapeHtml(text) {
    if (!text) return '';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

/**
 * Escape a string for safe use inside HTML attribute values (quoted with ").
 * Escapes &, <, >, ", and ' to prevent attribute breakout and XSS.
 * @param {string} text - Text to escape
 * @returns {string} Escaped text safe for attribute interpolation
 */
function escapeAttr(text) {
    if (!text) return '';
    return String(text)
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');
}

/**
 * Remove ANSI/control-sequence fragments from text before rendering.
 * Handles both real ESC-prefixed sequences and orphaned CSI fragments.
 * The orphaned fallback requires CSI-like parameter content or the common
 * parameterless "[m" reset fragment so bracketed words are preserved.
 * @param {string} text - Text to clean
 * @returns {string} Cleaned text
 */
function stripConsoleSequences(text) {
    if (text == null) return '';
    return String(text)
        .replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, '')
        .replace(/\[(?:[0-9?][0-9;?]*[ -/]*[A-Za-z]|m)/g, '')
        .trim();
}

/**
 * Validate that a string matches the expected decision ID pattern (dec-XXXXXXXX).
 * Use before passing IDs into DOM operations or API calls.
 * @param {string} id - Value to validate
 * @returns {boolean} True if valid decision ID format
 */
function isValidDecisionId(id) {
    return typeof id === 'string' && /^dec-[a-f0-9]{8}$/.test(id);
}

/**
 * Set text content of element by ID
 * @param {string} id - Element ID
 * @param {string|number} text - Text to set
 */
function setElementText(id, text) {
    const el = document.getElementById(id);
    if (el) el.textContent = text;
}

/**
 * Format ISO date string to compact display format
 * @param {string} isoString - ISO date string
 * @returns {string} Formatted date like "Jan 15 14:30"
 */
function formatCompactDate(isoString) {
    if (!isoString) return '';
    try {
        const date = new Date(isoString);
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        const month = months[date.getMonth()];
        const day = date.getDate();
        const hours = date.getHours().toString().padStart(2, '0');
        const mins = date.getMinutes().toString().padStart(2, '0');
        return `${month} ${day} ${hours}:${mins}`;
    } catch (e) {
        return '';
    }
}

/**
 * Format ISO date string to human-friendly format with day of week
 * @param {string} isoString - ISO date string
 * @returns {string} Formatted date like "Fri Dec 15 14:30"
 */
function formatFriendlyDate(isoString) {
    if (!isoString) return '';
    try {
        const date = new Date(isoString);
        const days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        const dayOfWeek = days[date.getDay()];
        const month = months[date.getMonth()];
        const dayNum = date.getDate();
        const hours = date.getHours().toString().padStart(2, '0');
        const mins = date.getMinutes().toString().padStart(2, '0');
        return `${dayOfWeek} ${month} ${dayNum} ${hours}:${mins}`;
    } catch (e) {
        return '';
    }
}

/**
 * Format ISO date string to time only
 * @param {string} isoString - ISO date string
 * @returns {string} Formatted time like "14:30:45"
 */
function formatCompactTime(isoString) {
    if (!isoString) return '';
    try {
        const date = new Date(isoString);
        const hours = date.getHours().toString().padStart(2, '0');
        const mins = date.getMinutes().toString().padStart(2, '0');
        const secs = date.getSeconds().toString().padStart(2, '0');
        return `${hours}:${mins}:${secs}`;
    } catch (e) {
        return '';
    }
}

/**
 * Truncate a message to max length with ellipsis
 * @param {string} message - Message to truncate
 * @param {number} maxLen - Maximum length
 * @returns {string} Truncated message
 */
function truncateMessage(message, maxLen) {
    if (!message) return '';
    if (message.length <= maxLen) return message;
    return message.substring(0, maxLen) + '…';
}

/**
 * Get CSS class for activity type
 * @param {string} type - Activity type
 * @returns {string} CSS class name
 */
function getActivityTypeClass(type) {
    if (!type) return 'activity-other';
    const t = type.toLowerCase();
    if (t === 'read') return 'activity-read';
    if (t === 'write') return 'activity-write';
    if (t === 'edit') return 'activity-edit';
    if (t === 'bash') return 'activity-bash';
    if (t === 'glob' || t === 'grep') return 'activity-search';
    if (t === 'text') return 'activity-text';
    if (t === 'done') return 'activity-done';
    if (t === 'init') return 'activity-init';
    if (t.startsWith('mcp__')) return 'activity-mcp';
    return 'activity-other';
}

/**
 * Get icon for activity type
 * @param {string} type - Activity type
 * @returns {string} Icon character
 */
function getActivityIcon(type) {
    if (!type) return '•';
    const t = type.toLowerCase();
    if (t === 'read') return '◇';
    if (t === 'write') return '◆';
    if (t === 'edit') return '✎';
    if (t === 'bash') return '▶';
    if (t === 'glob' || t === 'grep') return '⌕';
    if (t === 'text') return '¶';
    if (t === 'done') return '✓';
    if (t === 'init') return '⚡';
    if (t.startsWith('mcp__') || t.startsWith('mcp_')) return '⚙';
    if (t === 'task') return '☐';
    return '•';
}

/**
 * Format activity entry for display
 * For MCP tools: type becomes "Tool", message becomes the tool name
 * For others: type and message stay as-is
 * @param {Object} entry - Activity entry with type and message
 * @returns {Object} { displayType, displayMessage }
 */
function formatActivityEntry(entry) {
    const type = entry.type || '';
    const message = stripConsoleSequences(entry.message || '');
    
    // Handle MCP tool calls: mcp__server__tool_name or mcp_server__tool_name
    if (type.startsWith('mcp__') || type.startsWith('mcp_')) {
        // Extract just the tool name (last part after double underscore)
        const parts = type.split('__');
        let toolName = type;
        if (parts.length >= 3) {
            // mcp__dotbot__task_mark_done -> task_mark_done
            toolName = parts.slice(2).join('_');
        } else if (parts.length === 2) {
            // mcp__tool_name -> tool_name
            toolName = parts[1];
        }
        // Show "Tool" as type, tool name (+ message if any) as message
        const displayMessage = message ? `${toolName}: ${message}` : toolName;
        return { displayType: 'Tool', displayMessage };
    }
    
    return { displayType: type, displayMessage: message };
}

/**
 * Show a themed toast notification
 * @param {string} message - Message to display
 * @param {string} type - Toast type: 'error', 'success', 'warning', 'info'
 * @param {number} duration - Auto-dismiss time in ms (default 5000, 0 to persist)
 */
function showToast(message, type = 'info', duration = 5000) {
    const container = document.getElementById('toast-container');
    if (!container) return;

    const icons = { error: '!', success: '+', warning: '!', info: 'i' };

    const toast = document.createElement('div');
    toast.className = 'toast';
    toast.dataset.type = type;
    toast.innerHTML = `
        <span class="toast-icon">[${icons[type] || 'i'}]</span>
        <span class="toast-message">${escapeHtml(message)}</span>
        <button class="toast-close" title="Dismiss">&times;</button>
    `;

    const dismiss = () => {
        toast.classList.add('dismissing');
        toast.addEventListener('transitionend', () => toast.remove(), { once: true });
    };

    toast.querySelector('.toast-close').addEventListener('click', dismiss);

    container.appendChild(toast);
    // Trigger reflow then animate in
    requestAnimationFrame(() => toast.classList.add('visible'));

    if (duration > 0) {
        setTimeout(dismiss, duration);
    }
}

const NOTIFICATION_SAMPLE_RATE = 22050;
const NOTIFICATION_AUDIO_CHANNEL_COUNT = 12;
const notificationAudioCache = new Map();
const activeNotificationAudio = new Set();
const queuedNotificationAudioTimers = new Set();
const notificationAudioChannels = [];
const primedNotificationAudioChannels = new Set();
let notificationSilentAudioSrc = null;
let notificationAudioUnlockBound = false;
let notificationAudioUnlocked = false;
let notificationAudioPrimed = false;
let notificationAudioPriming = null;
let notificationAudioChannelCursor = 0;

/**
 * Prepare notification audio and unlock it on first user gesture.
 */
function initNotificationAudio() {
    if (notificationAudioUnlockBound) return;
    notificationAudioUnlockBound = true;

    const unlock = async () => {
        const primed = await primeNotificationAudio();
        if (!primed) return;

        notificationAudioUnlocked = true;
        document.removeEventListener('pointerdown', unlock);
        document.removeEventListener('keydown', unlock);
    };

    document.addEventListener('pointerdown', unlock, { passive: true });
    document.addEventListener('keydown', unlock);
}

/**
 * Play a short synthesized cue for in-app notifications.
 * @param {string} cue - Cue name: start, success, horn, warning, error, skipped, movement, session
 * @param {Object} options - Playback options
 */
function playNotificationSound(cue = 'movement', options = {}) {
    if (!notificationAudioUnlocked) return;

    const delayMs = Number(options.delayMs) || 0;
    const play = () => {
        const audio = getNotificationAudioChannel();
        if (!audio) return;

        audio.pause();
        audio.currentTime = 0;
        audio.src = getNotificationSoundSrc(cue);
        audio.volume = getNotificationSoundVolume(cue);
        activeNotificationAudio.add(audio);
        audio.play().catch(() => {
            activeNotificationAudio.delete(audio);
        });
    };

    if (delayMs > 0) {
        const timerId = setTimeout(() => {
            queuedNotificationAudioTimers.delete(timerId);
            play();
        }, delayMs);
        queuedNotificationAudioTimers.add(timerId);
    } else {
        play();
    }
}

function primeNotificationAudio() {
    if (notificationAudioPrimed) return Promise.resolve(true);
    if (notificationAudioPriming) return notificationAudioPriming;

    const silentSrc = getSilentNotificationSoundSrc();
    const channels = getNotificationAudioChannels();
    notificationAudioPriming = Promise.allSettled(channels.map(audio => {
        audio.pause();
        audio.currentTime = 0;
        audio.src = silentSrc;
        audio.volume = 0;
        return audio.play().then(() => {
            audio.pause();
            audio.currentTime = 0;
            primedNotificationAudioChannels.add(audio);
            return audio;
        });
    }))
        .then(results => {
            const succeeded = results.filter(result => result.status === 'fulfilled').length;
            notificationAudioPrimed = succeeded > 0;
            notificationAudioPriming = null;
            return notificationAudioPrimed;
        });

    return notificationAudioPriming;
}

function getNotificationAudioChannels() {
    if (notificationAudioChannels.length > 0) return notificationAudioChannels;

    for (let i = 0; i < NOTIFICATION_AUDIO_CHANNEL_COUNT; i++) {
        const audio = new Audio();
        audio.preload = 'auto';
        audio.addEventListener('play', () => activeNotificationAudio.add(audio));
        audio.addEventListener('ended', () => activeNotificationAudio.delete(audio));
        audio.addEventListener('pause', () => {
            if (audio.ended || audio.currentTime === 0) {
                activeNotificationAudio.delete(audio);
            }
        });
        notificationAudioChannels.push(audio);
    }

    return notificationAudioChannels;
}

function getNotificationAudioChannel() {
    const channels = primedNotificationAudioChannels.size > 0
        ? Array.from(primedNotificationAudioChannels)
        : getNotificationAudioChannels();
    const idleChannel = channels.find(audio => !activeNotificationAudio.has(audio));
    if (idleChannel) return idleChannel;

    const channel = channels[notificationAudioChannelCursor % channels.length];
    notificationAudioChannelCursor = (notificationAudioChannelCursor + 1) % channels.length;
    activeNotificationAudio.delete(channel);
    return channel;
}

function getNotificationSoundSrc(cue) {
    if (!notificationAudioCache.has(cue)) {
        const samples = synthesizeNotificationCue(cue);
        const wavBuffer = buildWavBuffer(samples, NOTIFICATION_SAMPLE_RATE);
        const src = URL.createObjectURL(new Blob([wavBuffer], { type: 'audio/wav' }));
        notificationAudioCache.set(cue, src);
    }

    return notificationAudioCache.get(cue);
}

function getSilentNotificationSoundSrc() {
    if (notificationSilentAudioSrc) return notificationSilentAudioSrc;

    const silentSamples = new Float32Array(Math.ceil(NOTIFICATION_SAMPLE_RATE * 0.05));
    const wavBuffer = buildWavBuffer(silentSamples, NOTIFICATION_SAMPLE_RATE);
    notificationSilentAudioSrc = URL.createObjectURL(new Blob([wavBuffer], { type: 'audio/wav' }));
    return notificationSilentAudioSrc;
}

function getNotificationSoundVolume(cue) {
    if (cue === 'horn') return 1;
    if (cue === 'error') return 0.95;
    return 0.9;
}

function stopNotificationAudio() {
    for (const timerId of Array.from(queuedNotificationAudioTimers)) {
        clearTimeout(timerId);
        queuedNotificationAudioTimers.delete(timerId);
    }

    for (const audio of Array.from(activeNotificationAudio)) {
        audio.pause();
        audio.currentTime = 0;
        activeNotificationAudio.delete(audio);
    }
}

function synthesizeNotificationCue(cue) {
    switch (cue) {
        case 'start':
            return renderNotificationCue(0.52, [
                { wave: 'triangle', start: 0, duration: 0.18, frequency: 480, endFrequency: 660, gain: 0.42 },
                { wave: 'sine', start: 0.16, duration: 0.24, frequency: 660, endFrequency: 920, gain: 0.35 },
                { wave: 'triangle', start: 0.18, duration: 0.22, frequency: 990, endFrequency: 1100, gain: 0.16 }
            ], { echoDelay: 0.1, echoGain: 0.14, drive: 1.18 });
        case 'success':
            return renderNotificationCue(0.8, [
                { wave: 'sine', start: 0, duration: 0.22, frequency: 523.25, gain: 0.45 },
                { wave: 'sine', start: 0.16, duration: 0.24, frequency: 659.25, gain: 0.42 },
                { wave: 'sine', start: 0.34, duration: 0.32, frequency: 783.99, gain: 0.4 },
                { wave: 'triangle', start: 0.34, duration: 0.28, frequency: 1046.5, gain: 0.16 }
            ], { echoDelay: 0.13, echoGain: 0.18, drive: 1.16 });
        case 'horn':
            return renderNotificationCue(0.95, [
                { wave: 'sawtooth', start: 0, duration: 0.32, frequency: 196, endFrequency: 174, gain: 0.42, attack: 0.04, release: 0.2 },
                { wave: 'square', start: 0, duration: 0.32, frequency: 246.94, endFrequency: 220, gain: 0.28, attack: 0.04, release: 0.18 },
                { wave: 'sawtooth', start: 0.28, duration: 0.4, frequency: 196, endFrequency: 164.81, gain: 0.44, attack: 0.03, release: 0.22 },
                { wave: 'square', start: 0.28, duration: 0.4, frequency: 246.94, endFrequency: 207.65, gain: 0.3, attack: 0.03, release: 0.22 },
                { wave: 'noise', start: 0, duration: 0.08, gain: 0.05, attack: 0.01, release: 0.7 },
                { wave: 'noise', start: 0.28, duration: 0.1, gain: 0.05, attack: 0.01, release: 0.7 }
            ], { echoDelay: 0.16, echoGain: 0.14, drive: 1.35 });
        case 'warning':
            return renderNotificationCue(0.55, [
                { wave: 'triangle', start: 0, duration: 0.16, frequency: 420, gain: 0.34 },
                { wave: 'triangle', start: 0.2, duration: 0.18, frequency: 420, gain: 0.34 }
            ], { echoDelay: 0.11, echoGain: 0.12, drive: 1.08 });
        case 'error':
            return renderNotificationCue(0.82, [
                { wave: 'sawtooth', start: 0, duration: 0.46, frequency: 180, endFrequency: 112, gain: 0.42, attack: 0.03, release: 0.18 },
                { wave: 'square', start: 0.06, duration: 0.38, frequency: 120, endFrequency: 80, gain: 0.25, attack: 0.03, release: 0.2 },
                { wave: 'noise', start: 0, duration: 0.16, gain: 0.04, attack: 0.02, release: 0.7 }
            ], { echoDelay: 0.12, echoGain: 0.1, drive: 1.25 });
        case 'skipped':
            return renderNotificationCue(0.62, [
                { wave: 'triangle', start: 0, duration: 0.18, frequency: 523.25, endFrequency: 440, gain: 0.33 },
                { wave: 'triangle', start: 0.15, duration: 0.2, frequency: 392, endFrequency: 329.63, gain: 0.28 }
            ], { echoDelay: 0.1, echoGain: 0.1, drive: 1.08 });
        case 'session':
            return renderNotificationCue(0.5, [
                { wave: 'sine', start: 0, duration: 0.16, frequency: 349.23, gain: 0.26 },
                { wave: 'sine', start: 0.14, duration: 0.2, frequency: 466.16, gain: 0.22 },
                { wave: 'triangle', start: 0.14, duration: 0.18, frequency: 698.46, gain: 0.08 }
            ], { echoDelay: 0.1, echoGain: 0.08, drive: 1.04 });
        default:
            return renderNotificationCue(0.34, [
                { wave: 'triangle', start: 0, duration: 0.12, frequency: 720, gain: 0.26 },
                { wave: 'triangle', start: 0.08, duration: 0.12, frequency: 960, gain: 0.2 }
            ], { echoDelay: 0.08, echoGain: 0.08, drive: 1.02 });
    }
}

function renderNotificationCue(durationSeconds, layers, options = {}) {
    const frameCount = Math.max(1, Math.ceil(durationSeconds * NOTIFICATION_SAMPLE_RATE));
    const samples = new Float32Array(frameCount);

    for (const layer of layers) {
        mixNotificationLayer(samples, layer);
    }

    if (options.echoDelay && options.echoGain) {
        applyNotificationEcho(samples, options.echoDelay, options.echoGain);
    }

    applyNotificationDrive(samples, options.drive || 1);
    normalizeNotificationSamples(samples, 0.92);
    return samples;
}

function mixNotificationLayer(samples, layer) {
    const startIndex = Math.max(0, Math.floor((layer.start || 0) * NOTIFICATION_SAMPLE_RATE));
    const frameCount = Math.max(1, Math.floor((layer.duration || 0.2) * NOTIFICATION_SAMPLE_RATE));
    const endIndex = Math.min(samples.length, startIndex + frameCount);
    const totalFrames = Math.max(1, endIndex - startIndex);
    const attack = layer.attack || 0.08;
    const release = layer.release || 0.22;
    const gain = layer.gain || 0.25;
    const startFrequency = layer.frequency || 440;
    const endFrequency = layer.endFrequency || startFrequency;
    const frequencyRatio = Math.max(endFrequency, 1) / Math.max(startFrequency, 1);
    let phase = 0;

    for (let i = 0; i < totalFrames; i++) {
        const sampleIndex = startIndex + i;
        const progress = totalFrames <= 1 ? 1 : i / (totalFrames - 1);
        const frequency = startFrequency * Math.pow(frequencyRatio, progress);
        const amplitude = getNotificationEnvelope(progress, attack, release) * gain;

        phase += (Math.PI * 2 * frequency) / NOTIFICATION_SAMPLE_RATE;
        samples[sampleIndex] += sampleNotificationWave(layer.wave || 'sine', phase) * amplitude;
    }
}

function getNotificationEnvelope(progress, attack, release) {
    const safeAttack = Math.max(0.001, Math.min(0.95, attack));
    const safeRelease = Math.max(0.001, Math.min(0.95, release));

    if (progress < safeAttack) {
        return progress / safeAttack;
    }

    if (progress > 1 - safeRelease) {
        return Math.max(0, (1 - progress) / safeRelease);
    }

    return 1;
}

function sampleNotificationWave(type, phase) {
    if (type === 'triangle') {
        return (2 / Math.PI) * Math.asin(Math.sin(phase));
    }
    if (type === 'square') {
        return Math.sin(phase) >= 0 ? 1 : -1;
    }
    if (type === 'sawtooth') {
        const cycle = phase / (Math.PI * 2);
        return 2 * (cycle - Math.floor(cycle + 0.5));
    }
    if (type === 'noise') {
        return (Math.random() * 2) - 1;
    }

    return Math.sin(phase);
}

function applyNotificationEcho(samples, delaySeconds, gain) {
    const delayFrames = Math.max(1, Math.floor(delaySeconds * NOTIFICATION_SAMPLE_RATE));
    for (let i = delayFrames; i < samples.length; i++) {
        samples[i] += samples[i - delayFrames] * gain;
    }
}

function applyNotificationDrive(samples, drive) {
    if (drive <= 1) return;
    for (let i = 0; i < samples.length; i++) {
        samples[i] = Math.tanh(samples[i] * drive);
    }
}

function normalizeNotificationSamples(samples, peakTarget) {
    let peak = 0;
    for (let i = 0; i < samples.length; i++) {
        peak = Math.max(peak, Math.abs(samples[i]));
    }

    if (peak <= 0) return;

    const scale = peakTarget / peak;
    for (let i = 0; i < samples.length; i++) {
        samples[i] *= scale;
    }
}

function buildWavBuffer(samples, sampleRate) {
    const buffer = new ArrayBuffer(44 + samples.length * 2);
    const view = new DataView(buffer);

    writeWavString(view, 0, 'RIFF');
    view.setUint32(4, 36 + samples.length * 2, true);
    writeWavString(view, 8, 'WAVE');
    writeWavString(view, 12, 'fmt ');
    view.setUint32(16, 16, true);
    view.setUint16(20, 1, true);
    view.setUint16(22, 1, true);
    view.setUint32(24, sampleRate, true);
    view.setUint32(28, sampleRate * 2, true);
    view.setUint16(32, 2, true);
    view.setUint16(34, 16, true);
    writeWavString(view, 36, 'data');
    view.setUint32(40, samples.length * 2, true);

    let offset = 44;
    for (let i = 0; i < samples.length; i++) {
        const sample = Math.max(-1, Math.min(1, samples[i]));
        view.setInt16(offset, sample < 0 ? sample * 0x8000 : sample * 0x7fff, true);
        offset += 2;
    }

    return buffer;
}

function writeWavString(view, offset, text) {
    for (let i = 0; i < text.length; i++) {
        view.setUint8(offset + i, text.charCodeAt(i));
    }
}

/**
 * Format duration between two ISO date strings
 * @param {string} startIso - Start ISO date string
 * @param {string} endIso - End ISO date string
 * @returns {string} Formatted duration like "2h 15m 8s" or "1d 4h 2m 9s"
 */
function formatDuration(startIso, endIso) {
    if (!startIso || !endIso) return '';
    try {
        const start = new Date(startIso);
        const end = new Date(endIso);
        const diffMs = end - start;
        if (diffMs < 0) return '';

        const totalSeconds = Math.floor(diffMs / 1000);
        const days = Math.floor(totalSeconds / 86400);
        const hours = Math.floor((totalSeconds % 86400) / 3600);
        const mins = Math.floor((totalSeconds % 3600) / 60);
        const secs = totalSeconds % 60;
        const parts = [];

        if (days > 0) parts.push(`${days}d`);
        if (hours > 0) parts.push(`${hours}h`);
        if (mins > 0) parts.push(`${mins}m`);
        if (secs > 0 || parts.length === 0) parts.push(`${secs}s`);

        return parts.join(' ');
    } catch (e) {
        return '';
    }
}

/**
 * Get the earliest timestamp that represents active work on a task.
 * Analysis time counts toward the task duration shown in DONE.
 * @param {Object} task - Task object
 * @returns {string} ISO timestamp or empty string
 */
function getTaskDurationStart(task) {
    if (!task) return '';
    return task.analysis_started_at || task.started_at || '';
}

/**
 * Format total task duration across analysis and execution.
 * @param {Object} task - Task object
 * @returns {string} Formatted duration string
 */
function formatTaskDuration(task) {
    if (!task?.completed_at) return '';
    const startIso = getTaskDurationStart(task);
    return startIso ? formatDuration(startIso, task.completed_at) : '';
}

// ── Folder Tree Utilities ────────────────────────────────────────────

/**
 * Build a nested folder tree from a flat list of items.
 * @param {Array} items - Flat array of objects
 * @param {string} pathKey - Property name containing the slash-delimited path (e.g. 'filename', 'file')
 * @returns {object} Tree: { items: [], folders: { name: tree } }
 */
function buildFolderTree(items, pathKey) {
    const root = { items: [], folders: {} };

    for (const item of items) {
        const itemPath = item[pathKey];
        if (!itemPath) continue;
        const parts = String(itemPath).split('/').filter(Boolean);
        if (parts.length === 0) continue;
        if (parts.length === 1) {
            root.items.push(item);
        } else {
            let node = root;
            for (let i = 0; i < parts.length - 1; i++) {
                const folderName = parts[i];
                if (!node.folders[folderName]) {
                    node.folders[folderName] = { items: [], folders: {} };
                }
                node = node.folders[folderName];
            }
            node.items.push(item);
        }
    }

    return root;
}

/**
 * Count total items in a folder tree node recursively.
 * @param {object} tree - Tree node from buildFolderTree
 * @returns {number}
 */
function countTreeItems(tree) {
    let count = tree.items.length;
    for (const key of Object.keys(tree.folders)) {
        count += countTreeItems(tree.folders[key]);
    }
    return count;
}

/**
 * Render a collapsible folder group wrapper (chain-folder HTML).
 * @param {string} folderName - Display name for the folder
 * @param {string} contentHtml - Inner HTML (rendered items + nested folders)
 * @param {number} itemCount - Badge count shown on the folder header
 * @returns {string} HTML string
 */
function renderFolderGroup(folderName, contentHtml, itemCount) {
    return `<div class="chain-folder">
        <div class="chain-folder-header">
            <span class="folder-toggle">&#x25BC;</span>
            <span class="folder-name">${escapeHtml(folderName)}</span>
            <span class="folder-count">${itemCount}</span>
        </div>
        <div class="chain-folder-items">
            ${contentHtml}
        </div>
    </div>`;
}

/**
 * Attach collapse/expand click handlers to all .chain-folder-header elements
 * inside a container. Toggles the 'collapsed' class and swaps the arrow icon.
 * @param {HTMLElement} container - Parent element containing .chain-folder-header elements
 */
function attachFolderToggleHandlers(container) {
    container.querySelectorAll('.chain-folder-header').forEach(header => {
        header.addEventListener('click', (e) => {
            e.stopPropagation();
            const folder = header.closest('.chain-folder');
            folder.classList.toggle('collapsed');
            const toggle = header.querySelector('.folder-toggle');
            if (toggle) toggle.innerHTML = folder.classList.contains('collapsed') ? '&#x25B6;' : '&#x25BC;';
        });
    });
}
