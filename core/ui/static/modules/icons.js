/**
 * DOTBOT Control Panel - Icon System
 * Material icon loading and retrieval
 */

/**
 * Load material icons from JSON file
 */
async function loadMaterialIcons() {
    try {
        const response = await fetch('/material-icons.json');
        const data = await response.json();
        materialIcons = data.icons;

        // Replace icon placeholders in the DOM
        replaceIconPlaceholders();
    } catch (error) {
        console.error('Failed to load material icons:', error);
        materialIcons = {};
    }
}

/**
 * Get SVG icon markup
 * @param {string} name - Icon name
 * @param {number} size - Icon size in pixels
 * @param {string} className - Additional CSS class
 * @returns {string} SVG markup
 */
function getIcon(name, size = 16, className = '') {
    if (!materialIcons || !materialIcons[name]) {
        console.warn(`Icon not found: ${name}`);
        return '';
    }

    const icon = materialIcons[name];
    return `<svg width="${size}" height="${size}" viewBox="${icon.viewBox}" fill="currentColor" class="${className}" style="vertical-align: middle;">
        <path d="${icon.path}"/>
    </svg>`;
}

/**
 * Replace icon placeholders in the DOM with actual icons
 */
function replaceIconPlaceholders() {
    // Replace control button icons
    const startBtn = document.querySelector('.ctrl-btn[data-action="start"]');
    if (startBtn) startBtn.innerHTML = getIcon('playArrow') + ' PLAY';

    const pauseBtn = document.querySelector('.ctrl-btn[data-action="pause"]');
    if (pauseBtn) pauseBtn.innerHTML = getIcon('pause') + ' PAUSE';

    const resumeBtn = document.querySelector('.ctrl-btn[data-action="resume"]');
    if (resumeBtn) resumeBtn.innerHTML = getIcon('playArrow') + ' RESUME';

    const stopBtn = document.querySelector('.ctrl-btn[data-action="stop"]');
    if (stopBtn) stopBtn.innerHTML = getIcon('stop') + ' STOP';

    // Replace hamburger menu with menu icon
    const hamburger = document.getElementById('hamburger-menu');
    if (hamburger) {
        hamburger.innerHTML = getIcon('menu', 24);
    }

    // Replace sidebar toggles with expand icons
    document.querySelectorAll('.sidebar-toggle').forEach(toggle => {
        toggle.innerHTML = getIcon('expandMore', 16);
    });

    // Replace modal close buttons
    document.querySelectorAll('.modal-close, .inspector-close').forEach(closeBtn => {
        closeBtn.innerHTML = getIcon('close', 20);
    });

    // Replace panic button icon
    const panicIcon = document.querySelector('.panic-icon');
    if (panicIcon) {
        panicIcon.innerHTML = getIcon('restart', 18);
    }

    // Replace whisper button icon
    const whisperIcon = document.querySelector('.whisper-icon');
    if (whisperIcon) {
        whisperIcon.innerHTML = getIcon('chatBubble', 14);
    }

    // Replace whisper modal header icon
    const whisperModalIcon = document.querySelector('.whisper-modal .modal-icon');
    if (whisperModalIcon) {
        whisperModalIcon.innerHTML = getIcon('chatBubble', 18);
    }
}
