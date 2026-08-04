/**
 * DOTBOT Control Panel - Configuration and Shared State
 * Central configuration constants and global state variables
 */

// Constants
const POLL_INTERVAL = 3000;  // 3 seconds - good balance for responsiveness vs server load
const API_BASE = '';
const CACHE_TTL = 5 * 60 * 1000; // 5 minutes

// CSRF protection: inject X-Dotbot-Request header on same-origin (or API_BASE /api/*) POST/PUT/DELETE requests.
// Browsers enforce CORS preflight for custom headers, so we avoid adding this header to arbitrary cross-origin requests.
(function() {
    const _origFetch = window.fetch;
    function shouldFleetProxy(path) {
        if (!path || !path.startsWith('/api/')) return false;
        if (path.startsWith('/api/fleet/')) return false;
        if (path === '/api/theme') return false;
        if (path.startsWith('/api/config/')) return false;
        if (path === '/api/settings' || path === '/api/providers' || path === '/api/editors') return false;
        return (
            path === '/api/info' ||
            path === '/api/state' ||
            path === '/api/state/poll' ||
            path === '/api/activity/tail' ||
            path === '/api/processes' ||
            path.startsWith('/api/process/') ||
            path === '/api/workflows/installed' ||
            /^\/api\/workflows\/[^/]+\/(run|stop)$/.test(path) ||
            path === '/api/tasks/run-pending' ||
            path === '/api/tasks/stop-pending' ||
            path === '/api/control' ||
            path === '/api/whisper'
        );
    }

    window.fetch = function(input, init) {
        init = init || {};
        const method = (init.method || 'GET').toUpperCase();
        const selectedRuntime = window.localStorage ? window.localStorage.getItem('dotbot:selectedRuntimeId') : null;

        // Resolve the request URL to determine origin.
        let requestUrl = null;
        try {
            const rawUrl = typeof input === 'string'
                ? input
                : (input && typeof input === 'object' && 'url' in input)
                    ? input.url
                    : null;
            if (rawUrl) {
                requestUrl = new URL(rawUrl, window.location.href);
            }
        } catch (e) {
            // If URL resolution fails, treat as non-same-origin for header injection purposes.
            requestUrl = null;
        }

        if (selectedRuntime && requestUrl && requestUrl.origin === window.location.origin && shouldFleetProxy(requestUrl.pathname)) {
            const proxyPath = `/api/fleet/runtimes/${encodeURIComponent(selectedRuntime)}/proxy${requestUrl.pathname}${requestUrl.search}`;
            if (typeof input === 'string') {
                input = proxyPath;
            } else if (input instanceof Request) {
                input = new Request(proxyPath, input);
            } else if (input && typeof input === 'object' && 'url' in input) {
                input = proxyPath;
            }
            requestUrl = new URL(proxyPath, window.location.href);
        }

        let isSameOrigin = false;
        let isApiBase = false;
        if (requestUrl) {
            isSameOrigin = requestUrl.origin === window.location.origin;
            // When API_BASE is non-empty (e.g. proxied to a different host),
            // also inject the header for requests targeting that API origin.
            if (API_BASE) {
                try {
                    const apiBaseUrl = new URL(API_BASE, window.location.href);
                    const apiPrefix = new URL('api/', apiBaseUrl.href).href;
                    isApiBase = requestUrl.href.startsWith(apiPrefix);
                } catch (e) {
                    // If API_BASE is not a valid URL, ignore API base matching.
                    isApiBase = false;
                }
            }
        }

        if ((isSameOrigin || isApiBase) && (method === 'POST' || method === 'PUT' || method === 'DELETE')) {
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
let currentWorkflowName = null;
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

// Workflow viewer state
let currentWorkflowItem = { type: null, file: null };

// Installed workflows (from /api/info)
let installedWorkflows = [];

// Installed workflow metadata keyed by name (from /api/workflows/installed)
let installedWorkflowMap = {};

// Pipeline workflow filter (null = show all)
let pipelineWorkflowFilter = null;

// Client-side cache for file data (reduces API calls)
const fileDataCache = new Map();

// Polling state
let lastPollTime = null;
let activityInitialized = false;

// Rate limit glitch timer
let rateLimitGlitchTimer = null;

// Last text output for activity display
let lastTextOutput = '';
