/**
 * DOTBOT Control Panel - Dispatch Ticker (#607/#551)
 * Two-mode shell footer: static (instance/last-update summary — the default)
 * and feed (scrolling dispatch log fed from /api/activity/tail via
 * pollActivity). Click toggles; choice persists per dotbot:shell:tickerMode.
 * Dispatch voice per spec #4.2 — terse wire-report lines ending "— M" or
 * "· stop"; events carry ids only, never task titles.
 */

const Ticker = (function() {
    const MODE_KEY = 'dotbot:shell:tickerMode'; // 'feed' | 'static'
    const MAX_ITEMS = 8;
    const MIN_CYCLE_S = 20;      // spec #11: >=20s full cycle
    const PX_PER_S = 60;

    const buffer = [];           // ring buffer of dispatch line strings
    let el = null;
    let track = null;
    let lastRendered = '';       // skip identical rebuilds (no phase reset)
    let rebuildQueued = false;
    let immediateQueued = false;
    let showingPlaceholder = false;

    function init() {
        el = document.getElementById('shell-ticker');
        track = document.getElementById('ticker-feed-track');
        if (!el || !track) return;

        if (layoutGet(MODE_KEY) === 'feed') {
            el.dataset.mode = 'feed';
        }

        el.addEventListener('click', () => {
            const feed = el.dataset.mode === 'feed';
            if (feed) {
                delete el.dataset.mode;
            } else {
                el.dataset.mode = 'feed';
            }
            layoutSet(MODE_KEY, feed ? 'static' : 'feed');
            lastRendered = '';
            render();
            el.blur(); // keep :focus-within from pausing right after a mouse toggle
        });
        el.addEventListener('keydown', (e) => {
            if (e.key === 'Enter' || e.key === ' ') {
                e.preventDefault();
                el.click();
            }
        });

        // OS flag changes must re-render: a CSS-frozen duplicated track is not
        // the spec's "latest item shown static".
        window.matchMedia('(prefers-reduced-motion: reduce)')
            .addEventListener('change', () => { lastRendered = ''; render(); });
    }

    /** Called from pollActivity for every activity event. */
    function ingest(event) {
        const line = formatDispatchLine(event);
        if (!line) return;
        buffer.push(line);
        if (buffer.length > MAX_ITEMS) buffer.shift();
        queueRender();
    }

    function reducedMotion() {
        return document.body.dataset.motion === 'reduced' ||
            window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    }

    /** Defer rebuilds to the loop boundary so the scroll never snaps back
     *  mid-cycle when events stream in every poll tick. */
    function queueRender() {
        if (!el || el.dataset.mode !== 'feed') return;
        // Placeholder has no scroll phase worth preserving — first real
        // event replaces "no transmissions" immediately. Coalesce within a
        // tick so a polled burst renders once with the whole batch, not the
        // first event now and the rest a full animation cycle later.
        if (reducedMotion() || !track.childElementCount || showingPlaceholder) {
            if (immediateQueued) return;
            immediateQueued = true;
            setTimeout(() => {
                immediateQueued = false;
                render();
            }, 0);
            return;
        }
        if (rebuildQueued) return;
        rebuildQueued = true;
        track.addEventListener('animationiteration', () => {
            rebuildQueued = false;
            render();
        }, { once: true });
    }

    function render() {
        if (!el || !track || el.dataset.mode !== 'feed') return;

        const content = buffer.length
            ? buffer.join('   ·   ')
            : 'no transmissions. standing by.';
        const signature = `${reducedMotion() ? 'R' : 'S'}|${content}`;
        if (signature === lastRendered) return;
        lastRendered = signature;
        showingPlaceholder = buffer.length === 0;

        track.replaceChildren();
        track.style.removeProperty('--ticker-duration');

        if (reducedMotion()) {
            // Latest item shown static (spec #11)
            appendEntry(buffer.length ? buffer[buffer.length - 1] : content);
            return;
        }

        // Fill one block to at least the container width, then duplicate the
        // whole block exactly once — identical halves make the -50% keyframe
        // loop seamless (odd repeat counts put the midpoint mid-sequence).
        const containerWidth = el.querySelector('.shell-ticker-feed').clientWidth || 800;
        appendEntry(content);
        while (track.scrollWidth < containerWidth) {
            appendEntry(content);
        }
        const blockCount = track.childElementCount;
        for (let i = 0; i < blockCount; i++) {
            track.appendChild(track.children[i].cloneNode(true));
        }

        const halfWidth = track.scrollWidth / 2;
        const duration = Math.max(MIN_CYCLE_S, halfWidth / PX_PER_S);
        track.style.setProperty('--ticker-duration', `${duration}s`);
    }

    function appendEntry(text) {
        const span = document.createElement('span');
        span.className = 'shell-ticker-entry';
        span.textContent = text; // textContent — never innerHTML (XSS)
        track.appendChild(span);
    }

    /**
     * Map an activity event to a dispatch-voice line, or null for events that
     * are workshop noise rather than ticker material (tool activity, text).
     */
    function formatDispatchLine(event) {
        const type = (event.type || '').toLowerCase();
        switch (type) {
            case 'task.status_changed':
                return `task ${shortEventId(event.task_id)} moved to ${event.to || 'unknown'} · stop`;
            case 'task.created':
                return `task ${shortEventId(event.task_id)} logged · stop`;
            case 'workflow.run_started':
                return `run ${shortEventId(event.run_id)} started — M`;
            case 'workflow.run_completed':
                return `run ${shortEventId(event.run_id)} completed — M`;
            case 'workflow.run_failed':
                return `run ${shortEventId(event.run_id)} failed · stop`;
            case 'workflow.run_cancelled':
                return `run ${shortEventId(event.run_id)} cancelled · stop`;
            default:
                return null;
        }
    }

    /** Unlike runs.js shortRunId (returns '' for blanks, never truncates),
     *  this shows an em-dash placeholder and caps at 8 chars — feed lines
     *  must stay fixed-width-ish and never render an empty gap. */
    function shortEventId(id) {
        if (!id) return '—';
        return String(id).replace(/^(wr_|t_)/, '').slice(0, 8);
    }

    return { init, ingest, render };
})();
