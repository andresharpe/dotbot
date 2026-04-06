/**
 * Theme switching for the workflow editor.
 * Reads theme-config.json and applies CSS custom property overrides at runtime.
 * Matches the Outpost's theme system from theme.js.
 */

interface ThemePreset {
  name: string;
  [key: string]: string | number[];
}

interface ThemeConfig {
  presets: Record<string, ThemePreset>;
}

const COLOR_KEYS = [
  'primary', 'primary-dim', 'secondary', 'tertiary',
  'success', 'success-dim', 'error', 'warning', 'info', 'muted', 'bezel',
  'bg-deep', 'bg-panel', 'bg-module', 'bg-screen',
];

let config: ThemeConfig | null = null;
let currentPreset = 'amber';

/** Load the theme config (called once at startup) */
export async function loadThemeConfig(): Promise<void> {
  try {
    const res = await fetch('/theme-config.json');
    if (res.ok) {
      config = await res.json();
    }
  } catch {
    // Use CSS defaults
  }
}

/** Get available preset names */
export function getPresetNames(): { id: string; name: string }[] {
  if (!config) return [{ id: 'amber', name: 'Amber Classic' }];
  return Object.entries(config.presets).map(([id, preset]) => ({
    id,
    name: preset.name,
  }));
}

/** Get current preset id */
export function getCurrentPreset(): string {
  return currentPreset;
}

/** Apply a theme preset by setting CSS custom properties on :root */
export function applyPreset(presetId: string): void {
  if (!config?.presets[presetId]) return;
  const preset = config.presets[presetId];
  const root = document.documentElement;

  for (const key of COLOR_KEYS) {
    const value = preset[key];
    if (Array.isArray(value)) {
      const cssVar = key.startsWith('bg-') ? `--color-${key}-rgb` : `--color-${key}-rgb`;
      root.style.setProperty(cssVar, value.join(' '));
    }
  }

  currentPreset = presetId;

  // Persist to localStorage
  try {
    localStorage.setItem('dotbot-editor-theme', presetId);
  } catch {
    // Ignore storage errors
  }
}

/** Initialize theme from localStorage or default */
export async function initTheme(): Promise<void> {
  await loadThemeConfig();

  let saved = 'amber';
  try {
    saved = localStorage.getItem('dotbot-editor-theme') || 'amber';
  } catch {
    // Ignore
  }

  if (config?.presets[saved]) {
    applyPreset(saved);
  }
}
