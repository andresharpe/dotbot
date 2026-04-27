/**
 * DOTBOT Control Panel - Mermaid Diagram Loader
 * Lazy-loads Mermaid.js and renders diagrams with CRT-themed styling
 */

// Mermaid local path (v10.9.0) - bundled for offline support
const MERMAID_LOCAL_PATH = 'lib/mermaid.min.js';

// State tracking
let mermaidLoaded = false;
let mermaidLoading = false;
let mermaidLoadPromise = null;

/**
 * Lazy-load Mermaid.js from CDN
 * @returns {Promise<boolean>} True if loaded successfully
 */
async function loadMermaid() {
    // Already loaded
    if (mermaidLoaded && window.mermaid) {
        return true;
    }

    // Currently loading - wait for existing promise
    if (mermaidLoading && mermaidLoadPromise) {
        return mermaidLoadPromise;
    }

    // Start loading
    mermaidLoading = true;
    mermaidLoadPromise = new Promise((resolve) => {
        const script = document.createElement('script');
        script.src = MERMAID_LOCAL_PATH;
        script.async = true;

        script.onload = () => {
            mermaidLoaded = true;
            mermaidLoading = false;
            initMermaidConfig();
            console.log('[Mermaid] Loaded successfully');
            resolve(true);
        };

        script.onerror = () => {
            mermaidLoading = false;
            console.error('[Mermaid] Failed to load');
            resolve(false);
        };

        document.head.appendChild(script);
    });

    return mermaidLoadPromise;
}

/**
 * Initialize Mermaid with CRT-themed configuration
 */
function initMermaidConfig() {
    if (!window.mermaid) return;

    // Get CSS variable values for theming
    const styles = getComputedStyle(document.documentElement);
    const bgColor = styles.getPropertyValue('--bg-screen').trim() || '#0a0a0a';
    const primaryColor = styles.getPropertyValue('--color-secondary').trim() || '#5fb3b3';
    const secondaryColor = styles.getPropertyValue('--color-primary').trim() || '#ffb454';
    const textColor = styles.getPropertyValue('--color-primary-dim').trim() || '#c4a35a';
    const lineColor = styles.getPropertyValue('--color-primary').trim() || '#ffb454';

    window.mermaid.initialize({
        startOnLoad: false,
        theme: 'base',
        themeVariables: {
            // General
            background: bgColor,
            primaryColor: primaryColor,
            primaryTextColor: textColor,
            primaryBorderColor: primaryColor,
            secondaryColor: secondaryColor,
            secondaryTextColor: textColor,
            secondaryBorderColor: secondaryColor,
            tertiaryColor: bgColor,
            tertiaryTextColor: textColor,
            tertiaryBorderColor: lineColor,

            // Flowchart
            lineColor: lineColor,
            nodeTextColor: textColor,
            nodeBorder: primaryColor,
            mainBkg: bgColor,
            nodeTextColor: textColor,

            // Sequence diagram
            actorBkg: bgColor,
            actorBorder: primaryColor,
            actorTextColor: textColor,
            actorLineColor: lineColor,
            signalColor: lineColor,
            signalTextColor: textColor,
            labelBoxBkgColor: bgColor,
            labelBoxBorderColor: primaryColor,
            labelTextColor: textColor,
            loopTextColor: textColor,
            noteBkgColor: bgColor,
            noteBorderColor: secondaryColor,
            noteTextColor: textColor,

            // State diagram
            labelColor: textColor,

            // ER diagram
            entityBorder: primaryColor,
            entityBkg: bgColor,
            entityTextColor: textColor,
            attributeBackgroundColorOdd: bgColor,
            attributeBackgroundColorEven: bgColor,
            relationColor: lineColor,
            relationLabelBackground: bgColor,
            relationLabelColor: textColor,

            // Gantt
            gridColor: lineColor,
            todayLineColor: secondaryColor,
            taskTextColor: textColor,
            taskTextOutsideColor: textColor,
            sectionBkgColor: bgColor,
            altSectionBkgColor: bgColor,
            taskBkgColor: primaryColor,
            taskBorderColor: primaryColor,
            doneTaskBkgColor: secondaryColor,
            doneTaskBorderColor: secondaryColor,

            // Fonts
            fontFamily: '"JetBrains Mono", "Fira Code", monospace',
            fontSize: '12px'
        },
        flowchart: {
            curve: 'basis',
            padding: 15,
            htmlLabels: true,
            useMaxWidth: true
        },
        sequence: {
            useMaxWidth: true,
            boxMargin: 10,
            mirrorActors: false
        },
        er: {
            useMaxWidth: true,
            entityPadding: 15,
            minEntityWidth: 100,
            minEntityHeight: 75
        },
        gantt: {
            useMaxWidth: true,
            barHeight: 20,
            barGap: 4,
            topPadding: 50,
            leftPadding: 175,
            gridLineStartPadding: 35,
            fontSize: 11,
            sectionFontSize: 11
        },
        stateDiagram: {
            useMaxWidth: true
        }
    });
}

/**
 * Render all pending Mermaid diagrams in a container
 * @param {HTMLElement} container - Container to search for diagrams
 */
async function renderMermaidDiagrams(container) {
    if (!container) return;

    // Find all mermaid containers that need rendering
    const mermaidContainers = container.querySelectorAll('.mermaid-container[data-pending="true"]');

    if (mermaidContainers.length === 0) return;

    // Load mermaid if needed
    const loaded = await loadMermaid();

    if (!loaded) {
        // Show fallback for all containers
        mermaidContainers.forEach(mc => {
            showMermaidFallback(mc, 'Failed to load Mermaid.js');
        });
        return;
    }

    // Render each diagram
    for (const mc of mermaidContainers) {
        await renderSingleDiagram(mc);
    }
}

/**
 * Render a single Mermaid diagram
 * @param {HTMLElement} container - The mermaid-container element
 */
async function renderSingleDiagram(container) {
    const syntaxEl = container.querySelector('.mermaid-syntax');
    const loadingEl = container.querySelector('.mermaid-loading');
    const renderedEl = container.querySelector('.mermaid-rendered');
    const fallbackEl = container.querySelector('.mermaid-fallback');

    if (!syntaxEl || !renderedEl) return;

    const syntax = syntaxEl.textContent;

    try {
        // Generate unique ID for this diagram
        const id = 'mermaid-' + Math.random().toString(36).substr(2, 9);

        // Render the diagram
        const { svg } = await window.mermaid.render(id, syntax);

        // Show rendered content
        renderedEl.innerHTML = svg;
        renderedEl.style.display = 'flex';

        // Hide loading and fallback
        if (loadingEl) loadingEl.style.display = 'none';
        if (fallbackEl) fallbackEl.style.display = 'none';

        // Mark as rendered
        container.dataset.pending = 'false';
        container.dataset.rendered = 'true';

    } catch (error) {
        console.error('[Mermaid] Render error:', error);
        showMermaidFallback(container, error.message || 'Syntax error');
    }
}

/**
 * Show fallback content when rendering fails
 * @param {HTMLElement} container - The mermaid-container element
 * @param {string} errorMessage - Error message to display
 */
function showMermaidFallback(container, errorMessage) {
    const loadingEl = container.querySelector('.mermaid-loading');
    const renderedEl = container.querySelector('.mermaid-rendered');
    const fallbackEl = container.querySelector('.mermaid-fallback');

    // Hide loading and rendered
    if (loadingEl) loadingEl.style.display = 'none';
    if (renderedEl) renderedEl.style.display = 'none';

    // Show fallback
    if (fallbackEl) {
        fallbackEl.style.display = 'block';
    }

    // Add error message if not already present
    let errorEl = container.querySelector('.mermaid-error');
    if (!errorEl) {
        errorEl = document.createElement('div');
        errorEl.className = 'mermaid-error';
        container.appendChild(errorEl);
    }
    errorEl.textContent = errorMessage;

    // Mark as failed
    container.dataset.pending = 'false';
    container.dataset.rendered = 'false';
}

/**
 * Refresh Mermaid theme (call after theme change)
 * Re-renders all diagrams with new theme colors
 */
async function refreshMermaidTheme() {
    if (!mermaidLoaded || !window.mermaid) return;

    // Re-initialize config with new colors
    initMermaidConfig();

    // Find all rendered diagrams and re-render them
    const renderedContainers = document.querySelectorAll('.mermaid-container[data-rendered="true"]');

    for (const container of renderedContainers) {
        // Mark as pending again
        container.dataset.pending = 'true';
        container.dataset.rendered = 'false';

        // Reset display states
        const loadingEl = container.querySelector('.mermaid-loading');
        const renderedEl = container.querySelector('.mermaid-rendered');
        const fallbackEl = container.querySelector('.mermaid-fallback');
        const errorEl = container.querySelector('.mermaid-error');

        if (loadingEl) loadingEl.style.display = 'block';
        if (renderedEl) {
            renderedEl.style.display = 'none';
            renderedEl.innerHTML = '';
        }
        if (fallbackEl) fallbackEl.style.display = 'none';
        if (errorEl) errorEl.remove();

        // Re-render
        await renderSingleDiagram(container);
    }
}

// Export functions for use in other modules
window.renderMermaidDiagrams = renderMermaidDiagrams;
window.refreshMermaidTheme = refreshMermaidTheme;
