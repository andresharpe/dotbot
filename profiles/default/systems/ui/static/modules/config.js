/**
 * DOTBOT Control Panel - Configuration and Shared State
 * Central configuration constants and global state variables
 */

// Constants
const POLL_INTERVAL = 3000;  // 3 seconds - good balance for responsiveness vs server load
const API_BASE = '';
const CACHE_TTL = 5 * 60 * 1000; // 5 minutes

// CSRF protection: inject X-Dotbot-Request header on all POST/PUT/DELETE requests.
// Browsers enforce CORS preflight for custom headers, blocking cross-origin attacks.
(function() {
    const _origFetch = window.fetch;
    window.fetch = function(input, init) {
        init = init || {};
        const method = (init.method || 'GET').toUpperCase();
        if (method === 'POST' || method === 'PUT' || method === 'DELETE') {
            init.headers = init.headers || {};
            if (init.headers instanceof Headers) {
                init.headers.set('X-Dotbot-Request', '1');
            } else {
                init.headers['X-Dotbot-Request'] = '1';
            }
        }
        return _origFetch.call(this, input, init);
    };
})();

// State
let isConnected = false;
let lastState = null;
let pollTimer = null;
let sessionStartTime = null;
let runtimeTimer = null;

// Timer pause/resume state
let sessionTimerElapsed = 0;       // Accumulated elapsed ms (frozen when paused)
let sessionTimerLastResumed = null; // Date when timer last started/resumed running
let sessionTimerStatus = null;      // Previous session status for detecting transitions
let sessionTimerSessionId = null;   // Track session ID to detect new sessions
let projectName = 'unknown';
let projectRoot = 'unknown';
let executiveSummary = null;
let hasExistingCode = false;
let lastProductDocCount = -1;
let materialIcons = null;
let activityScope = null;
let activityPosition = 0;  // Start from beginning on page load
let activityTimer = null;
let currentTheme = null;  // Current theme configuration

// Store discovered directories for use in relationship tree
let discoveredDirectories = [];

// Pipeline column display limits (for infinite scroll)
let pipelineDisplayLimits = {
    'pipeline-todo': 10,
    'pipeline-progress': 10,
    'pipeline-done': 10
};
let pipelineTaskCounts = {
    'pipeline-todo': 0,
    'pipeline-progress': 0,
    'pipeline-done': 0
};

// Workflow viewer state
let currentWorkflowItem = { type: null, file: null };

// Client-side cache for file data (reduces API calls)
const fileDataCache = new Map();

// Polling state
let lastPollTime = null;
let activityInitialized = false;

// Rate limit glitch timer
let rateLimitGlitchTimer = null;

// Last text output for activity display
let lastTextOutput = '';
