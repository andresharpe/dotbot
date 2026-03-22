// Activity Oscilloscope Renderer
// Creates a retro CRT-style waveform display for bot activity
// Colors are read from CSS theme variables (--color-primary-rgb)
//
// DUAL PURPOSE:
// 1. EVENT MONITORING: Visualizes bot activity events as waveforms (tool use, text output, etc.)
// 2. STATE DISPLAY: Shows current session state (running, paused, stopped, idle) for context
//
// The waveform represents EVENTS - what the bot is doing
// The state indicator shows STATUS - whether the bot can do things
//
// States:
// - RUNNING: Bot is actively working (bright primary color, full event amplitude)
// - PAUSED: Bot is suspended by user (dimmed primary, reduced events)
// - IDLE: Bot is waiting for work (warm dim primary, moderate events)
// - STOPPED: Bot session ended (very dim, no events)
// - OFFLINE: No session exists (minimal glow, no events)

class ActivityScope {
    constructor(canvasId) {
        this.canvas = document.getElementById(canvasId);
        if (!this.canvas) {
            console.error(`Canvas element '${canvasId}' not found`);
            return;
        }

        this.ctx = this.canvas.getContext('2d');
        this.width = this.canvas.width;
        this.height = this.canvas.height || 100;  // Default to 100px
        this.centerY = this.height / 2;

        // Waveform data buffer
        this.waveData = new Float32Array(this.width);
        this.waveVelocity = new Float32Array(this.width); // For momentum

        // Event injection position (right side, flows left)
        this.injectPosition = this.width - 50;

        // Session state
        this.state = 'stopped';  // 'running', 'paused', 'stopped'
        this.stateMessage = 'IDLE';
        this.pulseIntensity = 0;

        // Theme colors (read from CSS variables)
        this.updateThemeColors();

        // CRT styling
        this.setupStyle();

        // Start animation loop
        this.animate();
    }

    // Read theme colors from CSS variables
    updateThemeColors() {
        const style = getComputedStyle(document.documentElement);
        const primaryRgb = style.getPropertyValue('--color-primary-rgb').trim() || '232 160 48';
        const primaryDimRgb = style.getPropertyValue('--color-primary-dim-rgb').trim() || '184 120 32';

        // Parse RGB values
        const [r, g, b] = primaryRgb.split(' ').map(Number);
        const [rd, gd, bd] = primaryDimRgb.split(' ').map(Number);

        // Store color variants
        this.colors = {
            primary: `rgb(${r}, ${g}, ${b})`,
            primaryDim: `rgb(${rd}, ${gd}, ${bd})`,
            primaryVeryDim: `rgb(${Math.floor(r * 0.4)}, ${Math.floor(g * 0.4)}, ${Math.floor(b * 0.4)})`,
            primaryFaint: `rgb(${Math.floor(r * 0.25)}, ${Math.floor(g * 0.25)}, ${Math.floor(b * 0.25)})`,
            primaryAlmost: `rgb(${Math.floor(r * 0.55)}, ${Math.floor(g * 0.55)}, ${Math.floor(b * 0.55)})`,
            // Store RGB components for rgba() usage
            r, g, b
        };
    }

    setupStyle() {
        // Phosphor glow (matching CSS theme)
        this.ctx.strokeStyle = this.colors.primary;
        this.ctx.lineWidth = 2;
        this.ctx.shadowBlur = 12;
        this.ctx.shadowColor = this.colors.primary;
        this.ctx.lineCap = 'round';
        this.ctx.lineJoin = 'round';
    }
    
    setState(newState) {
        // Only update if state actually changed
        if (this.state === newState) return;
        
        const previousState = this.state;
        this.state = newState;
        
        switch(newState) {
            case 'running':
                this.stateMessage = 'RUNNING';
                this.pulseIntensity = 1.0;
                // Inject a startup sweep only when transitioning from non-running
                if (previousState !== 'paused') {
                    this.injectSweep(1.0);
                }
                break;
                
            case 'paused':
                this.stateMessage = 'PAUSED';
                this.pulseIntensity = 0.3;
                // Inject a dampening wave
                this.injectDamped(0.5, 50);
                break;
                
            case 'stopped':
                this.stateMessage = 'STOPPED';
                this.pulseIntensity = 0.1;
                // Inject a small noise burst
                this.injectNoise(0.3, 20);
                break;
                
            case 'idle':
                this.stateMessage = 'IDLE';
                this.pulseIntensity = 0.05;
                // Just a small blip to show system is alive
                this.injectBlip(0.2);
                break;
                
            default:
                this.stateMessage = 'OFFLINE';
                this.pulseIntensity = 0;
        }
    }
    
    addEvent(event) {
        // This method handles EVENTS (activity from the bot)
        // State is displayed separately for context
        
        if (!event || !event.semantic) return;
        
        // Filter events based on current state
        // - stopped: no events processed (system is off)
        // - idle: process events but at reduced amplitude (system waiting)
        // - paused: process events at reduced amplitude (system suspended)
        // - running: full amplitude events
        
        if (this.state === 'stopped' || this.state === 'offline') {
            // Don't visualize events when system is stopped/offline
            return;
        }
        
        // Adjust amplitude based on state
        let stateMultiplier = 1.0;
        if (this.state === 'paused') {
            stateMultiplier = 0.3;  // Heavily reduced when paused
        } else if (this.state === 'idle') {
            stateMultiplier = 0.6;  // Moderately reduced when idle
        }
        
        // Map semantic hints to waveform modifications
        // Increased base amplitude for visibility
        const amplitude = (event.intensity === 'bright' ? 1.5 : 
                          event.intensity === 'pulse' ? 1.2 : 0.8) * stateMultiplier;
        const duration = 40; // samples
        
        switch(event.semantic) {
            case 'pulse':
                this.injectPulse(amplitude, duration);
                break;
            case 'flow':
                this.injectSine(amplitude, duration * 2);
                break;
            case 'sweep':
                this.injectSweep(amplitude);
                break;
            case 'noise':
                this.injectNoise(amplitude, duration);
                break;
            case 'complete':
                this.injectDamped(amplitude, duration * 3);
                break;
            case 'steady':
                // Regular activity - small pulse with some noise
                this.injectPulse(amplitude * 0.6, duration);
                this.injectNoise(amplitude * 0.2, 10);
                break;
            default:
                // Unknown semantic - still show something visible
                this.injectBlip(amplitude * 0.5);
        }
    }
    
    // Waveform injection methods
    injectPulse(amplitude, duration) {
        // Sharp spike with more energy
        const pos = this.injectPosition;
        this.waveVelocity[pos] += amplitude * 3;
        
        // More pronounced pre and post oscillations
        if (pos > 2) this.waveVelocity[pos - 2] -= amplitude * 0.3;
        if (pos > 1) this.waveVelocity[pos - 1] -= amplitude * 0.5;
        if (pos < this.width - 1) this.waveVelocity[pos + 1] -= amplitude * 0.5;
        if (pos < this.width - 2) this.waveVelocity[pos + 2] -= amplitude * 0.3;
    }
    
    injectSine(amplitude, duration) {
        // Smooth sine wave
        for (let i = 0; i < duration && (this.injectPosition + i) < this.width; i++) {
            const phase = (i / duration) * Math.PI * 2;
            this.waveData[this.injectPosition + i] += Math.sin(phase) * amplitude;
        }
    }
    
    injectSweep(amplitude) {
        // Horizontal line (like a radar sweep)
        for (let i = 0; i < 100 && (this.injectPosition + i) < this.width; i++) {
            this.waveData[this.injectPosition + i] = amplitude * (1 - i / 100);
        }
    }
    
    injectNoise(amplitude, duration) {
        // Random interference
        for (let i = 0; i < duration && (this.injectPosition + i) < this.width; i++) {
            this.waveData[this.injectPosition + i] += (Math.random() - 0.5) * amplitude * 2;
            this.waveVelocity[this.injectPosition + i] += (Math.random() - 0.5) * amplitude;
        }
    }
    
    injectDamped(amplitude, duration) {
        // Dampening oscillation (like a struck bell)
        for (let i = 0; i < duration && (this.injectPosition + i) < this.width; i++) {
            const damping = Math.exp(-i / 10);
            const oscillation = Math.sin(i * 0.5) * damping;
            this.waveData[this.injectPosition + i] += oscillation * amplitude;
        }
    }
    
    injectBlip(amplitude) {
        // Small but visible disturbance
        const pos = this.injectPosition;
        this.waveData[pos] += amplitude;
        this.waveVelocity[pos] += amplitude * 0.5;
        if (pos > 0) this.waveData[pos - 1] += amplitude * 0.3;
        if (pos < this.width - 1) this.waveData[pos + 1] += amplitude * 0.3;
    }
    
    animate() {
        // Shift waveform left (creates scrolling effect)
        for (let i = 0; i < this.width - 1; i++) {
            this.waveData[i] = this.waveData[i + 1];
            this.waveVelocity[i] = this.waveVelocity[i + 1];
        }
        
        // Clear rightmost position
        this.waveData[this.width - 1] = 0;
        this.waveVelocity[this.width - 1] = 0;
        
        // Apply physics (momentum and damping)
        for (let i = 1; i < this.width - 1; i++) {
            // Spring force to neighbors (creates wave propagation)
            const springForce = (this.waveData[i - 1] + this.waveData[i + 1]) * 0.1 - this.waveData[i] * 0.2;
            this.waveVelocity[i] += springForce;
            
            // Apply velocity
            this.waveData[i] += this.waveVelocity[i];
            
            // Damping (phosphor decay)
            this.waveData[i] *= 0.98;
            this.waveVelocity[i] *= 0.95;
        }
        
        // Add baseline noise
        for (let i = this.width - 10; i < this.width; i++) {
            this.waveData[i] += (Math.random() - 0.5) * 0.02;
        }
        
        this.render();
        requestAnimationFrame(() => this.animate());
    }
    
    render() {
        // Clear with phosphor persistence effect
        this.ctx.fillStyle = 'rgba(0, 0, 0, 0.15)';
        this.ctx.fillRect(0, 0, this.width, this.height);
        
        // Draw grid (subtle)
        this.drawGrid();
        
        // Adjust colors based on state (using theme colors)
        let waveColor = this.colors.primary;  // Default for running
        let glowIntensity = 15;

        switch(this.state) {
            case 'paused':
                waveColor = this.colors.primaryDim;
                glowIntensity = 8;
                break;
            case 'stopped':
                waveColor = this.colors.primaryVeryDim;
                glowIntensity = 4;
                break;
            case 'idle':
                waveColor = this.colors.primaryAlmost;
                glowIntensity = 6;
                break;
            case 'offline':
                waveColor = this.colors.primaryFaint;
                glowIntensity = 2;
                break;
            // 'running' uses defaults
        }
        
        // Draw waveform
        this.ctx.beginPath();
        this.ctx.strokeStyle = waveColor;
        this.ctx.lineWidth = 2;
        this.ctx.shadowBlur = glowIntensity;
        this.ctx.shadowColor = waveColor;
        
        for (let x = 0; x < this.width; x++) {
            const y = this.centerY + (this.waveData[x] * this.centerY * 0.8);
            
            if (x === 0) {
                this.ctx.moveTo(x, y);
            } else {
                this.ctx.lineTo(x, y);
            }
        }
        
        this.ctx.stroke();
        
        // Draw intensity spots for recent high-amplitude areas
        this.ctx.globalCompositeOperation = 'screen';
        for (let x = this.width - 100; x < this.width; x++) {
            const intensity = Math.abs(this.waveData[x]);
            if (intensity > 0.5) {
                const y = this.centerY + (this.waveData[x] * this.centerY * 0.8);
                this.ctx.fillStyle = `rgba(${this.colors.r}, ${this.colors.g}, ${this.colors.b}, ${intensity * 0.4})`;
                this.ctx.beginPath();
                this.ctx.arc(x, y, intensity * 10, 0, Math.PI * 2);
                this.ctx.fill();
            }
        }
        this.ctx.globalCompositeOperation = 'source-over';
        
        // Draw state indicator
        this.drawStateIndicator();
    }
    
    drawStateIndicator() {
        // State text in top-left corner
        this.ctx.font = '10px monospace';
        this.ctx.shadowBlur = 0;

        let indicatorColor = this.colors.primary;  // Default for running
        switch(this.state) {
            case 'paused':
                indicatorColor = this.colors.primaryDim;
                break;
            case 'stopped':
                indicatorColor = this.colors.primaryVeryDim;
                break;
            case 'idle':
                indicatorColor = this.colors.primaryAlmost;
                break;
            case 'offline':
                indicatorColor = this.colors.primaryFaint;
                break;
        }

        // Draw state box
        this.ctx.fillStyle = 'rgba(0, 0, 0, 0.5)';
        this.ctx.fillRect(10, 10, 80, 20);

        // Draw state text
        this.ctx.fillStyle = indicatorColor;
        this.ctx.fillText(this.stateMessage, 15, 24);

        // Draw state-specific indicators
        if (this.state === 'running') {
            // Pulsing dot for running
            const pulse = (Math.sin(Date.now() / 500) + 1) / 2;
            this.ctx.fillStyle = `rgba(${this.colors.r}, ${this.colors.g}, ${this.colors.b}, ${0.5 + pulse * 0.5})`;
            this.ctx.beginPath();
            this.ctx.arc(75, 20, 3, 0, Math.PI * 2);
            this.ctx.fill();
        } else if (this.state === 'paused') {
            // Pause bars
            this.ctx.fillStyle = indicatorColor;
            this.ctx.fillRect(72, 16, 2, 8);
            this.ctx.fillRect(76, 16, 2, 8);
        } else if (this.state === 'idle') {
            // Slow pulsing dot for idle (waiting for work)
            const pulse = (Math.sin(Date.now() / 2000) + 1) / 2;  // Slower pulse
            const {r, g, b} = this.colors;
            this.ctx.fillStyle = `rgba(${Math.floor(r * 0.55)}, ${Math.floor(g * 0.55)}, ${Math.floor(b * 0.55)}, ${0.3 + pulse * 0.3})`;
            this.ctx.beginPath();
            this.ctx.arc(75, 20, 2, 0, Math.PI * 2);
            this.ctx.fill();
        } else if (this.state === 'stopped') {
            // Square for stopped
            this.ctx.fillStyle = indicatorColor;
            this.ctx.fillRect(72, 17, 6, 6);
        }
        // offline has no indicator
    }
    
    drawGrid() {
        this.ctx.strokeStyle = `rgba(${this.colors.r}, ${this.colors.g}, ${this.colors.b}, 0.08)`;
        this.ctx.lineWidth = 1;
        this.ctx.shadowBlur = 0;

        // Horizontal center line
        this.ctx.beginPath();
        this.ctx.moveTo(0, this.centerY);
        this.ctx.lineTo(this.width, this.centerY);
        this.ctx.stroke();

        // Vertical grid lines
        for (let x = 0; x < this.width; x += 50) {
            this.ctx.beginPath();
            this.ctx.moveTo(x, 0);
            this.ctx.lineTo(x, this.height);
            this.ctx.stroke();
        }

        // Horizontal grid lines
        for (let y = 0; y < this.height; y += 40) {
            this.ctx.beginPath();
            this.ctx.moveTo(0, y);
            this.ctx.lineTo(this.width, y);
            this.ctx.stroke();
        }
    }
}

// Export for use in other scripts
window.ActivityScope = ActivityScope;