/**
 * DOTBOT Control Panel - Theme System
 * Theme management and CSS variable application
 */

/**
 * Load theme configuration and apply CSS variables
 */
async function loadTheme() {
    try {
        const response = await fetch('/api/theme');
        if (!response.ok) {
            console.warn('Failed to load theme, using defaults');
            document.body.classList.add('theme-loaded');
            return;
        }
        const config = await response.json();
        currentTheme = config;
        applyTheme(config.mappings);
        document.body.classList.add('theme-loaded');
    } catch (error) {
        console.warn('Error loading theme:', error);
        document.body.classList.add('theme-loaded');
    }
}

/**
 * Apply theme mappings to CSS variables
 * @param {Object} mappings - Object with semantic color names and RGB values
 */
function applyTheme(mappings) {
    const root = document.documentElement;
    for (const [name, rgb] of Object.entries(mappings)) {
        root.style.setProperty(`--color-${name}-rgb`, `${rgb.r} ${rgb.g} ${rgb.b}`);
    }

    // Update ActivityScope colors if it exists
    if (activityScope && typeof activityScope.updateThemeColors === 'function') {
        activityScope.updateThemeColors();
        activityScope.setupStyle();
    }
}

/**
 * Switch to a theme preset
 * @param {string} presetName - Name of the preset (e.g., 'amber', 'green', 'cyan')
 */
async function setThemePreset(presetName) {
    try {
        const response = await fetch('/api/theme', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ preset: presetName })
        });
        if (!response.ok) {
            console.error('Failed to set theme preset');
            return;
        }
        const config = await response.json();
        currentTheme = config;
        applyTheme(config.mappings);
    } catch (error) {
        console.error('Error setting theme preset:', error);
    }
}

/**
 * Get available theme presets
 * @returns {Object} Available presets from current theme config
 */
function getThemePresets() {
    return currentTheme?.presets || {};
}

/**
 * Get current theme name
 * @returns {string} Current theme name
 */
function getCurrentThemeName() {
    return currentTheme?.name || 'Unknown';
}

/**
 * Initialize the theme selector UI in settings
 */
function initThemeSelector() {
    const themeGrid = document.getElementById('theme-grid');

    if (!themeGrid || !currentTheme) return;

    // Clear existing content
    themeGrid.innerHTML = '';

    // Get presets from theme config
    const presets = currentTheme.presets || {};

    // Create theme options
    for (const [key, preset] of Object.entries(presets)) {
        const option = document.createElement('div');
        option.className = 'theme-option';
        option.dataset.theme = key;

        // Check if this is the active theme
        if (currentTheme.name === preset.name) {
            option.classList.add('active');
        }

        // Get the primary color for preview
        const [r, g, b] = preset.primary;

        option.innerHTML = `
            <div class="theme-preview" style="background: rgba(${r}, ${g}, ${b}, 0.1);">
                <div class="theme-preview-wave" style="background: rgb(${r}, ${g}, ${b}); color: rgb(${r}, ${g}, ${b});"></div>
            </div>
            <div class="theme-option-name">${preset.name}</div>
        `;

        option.addEventListener('click', () => selectTheme(key));
        themeGrid.appendChild(option);
    }
}

/**
 * Select a theme and apply it
 * @param {string} themeKey - The preset key (e.g., 'amber', 'green')
 */
async function selectTheme(themeKey) {
    await setThemePreset(themeKey);

    // Update UI to reflect selection
    const themeGrid = document.getElementById('theme-grid');

    if (themeGrid) {
        // Update active state
        themeGrid.querySelectorAll('.theme-option').forEach(opt => {
            opt.classList.toggle('active', opt.dataset.theme === themeKey);
        });
    }

    // Pulse Aether lights to preview new theme color
    if (typeof Aether !== 'undefined' && Aether.isLinked()) {
        // Small delay to ensure CSS variables are updated
        setTimeout(() => {
            Aether.pulseBright('primary');
        }, 100);
    }
}

/**
 * Initialize settings navigation
 */
function initSettingsNav() {
    const navItems = document.querySelectorAll('.settings-nav-item');
    const sections = document.querySelectorAll('.settings-section');

    navItems.forEach(item => {
        item.addEventListener('click', () => {
            const targetSection = item.dataset.settingsSection;

            // Update nav active state
            navItems.forEach(nav => nav.classList.remove('active'));
            item.classList.add('active');

            // Show/hide sections
            sections.forEach(section => {
                const sectionId = section.id.replace('settings-', '');
                section.classList.toggle('hidden', sectionId !== targetSection);
            });

            // Render editor settings from cache; use Rescan button for explicit re-detection
            if (targetSection === 'editor' && typeof renderEditorSettings === 'function') {
                if (!editorDetectionDone) {
                    refreshInstalledEditors(false).then(() => {
                        renderEditorSettings();
                        initEditorCustomInput();
                    });
                } else {
                    renderEditorSettings();
                    initEditorCustomInput();
                }
            }

            // Initialize Aether panel when selected
            if (targetSection === 'aether' && typeof Aether !== 'undefined') {
                Aether.initSettingsPanel();
            }
        });
    });
}
