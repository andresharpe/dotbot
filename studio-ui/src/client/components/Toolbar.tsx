/**
 * Top toolbar with file commands and canvas actions.
 * Text-only button style with group separators.
 */
import { useState, useRef, useEffect } from 'react';
import { WorkflowPicker } from './WorkflowPicker';
import type { TaskType } from '../model/workflow';
import { TASK_TYPE_STYLES } from '../model/transform';

const TASK_TYPES: { type: TaskType; label: string }[] = [
  { type: 'prompt', label: 'Prompt' },
  { type: 'prompt_template', label: 'Prompt Template' },
  { type: 'script', label: 'Script' },
  { type: 'mcp', label: 'MCP Tool' },
  { type: 'task_gen', label: 'Task Generator' },
  { type: 'barrier', label: 'Barrier' },
];

interface ToolbarProps {
  currentName: string | null;
  dirty: boolean;
  loading: boolean;
  isRegistry: boolean;
  onNew: () => void;
  onOpen: (name: string) => void;
  onSave: () => void;
  onSaveAs: (name: string) => Promise<void>;
  onAddTask: (type: TaskType) => void;
  onAutoLayout: () => void;
}

export function Toolbar({
  currentName,
  dirty,
  loading,
  isRegistry,
  onNew,
  onOpen,
  onSave,
  onSaveAs,
  onAddTask,
  onAutoLayout,
}: ToolbarProps) {
  const [showPicker, setShowPicker] = useState(false);
  const [showSaveAs, setShowSaveAs] = useState(false);
  const [saveAsName, setSaveAsName] = useState('');
  const [saveAsError, setSaveAsError] = useState<string | null>(null);
  const [saveAsBusy, setSaveAsBusy] = useState(false);
  const [showAddMenu, setShowAddMenu] = useState(false);
  const addMenuRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!showAddMenu) return;
    const handleClickOutside = (e: MouseEvent) => {
      if (addMenuRef.current && !addMenuRef.current.contains(e.target as Node)) {
        setShowAddMenu(false);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [showAddMenu]);

  const handleOpen = (name: string) => {
    setShowPicker(false);
    onOpen(name);
  };

  const handleSaveAs = async () => {
    if (!saveAsName.trim()) return;
    setSaveAsError(null);
    setSaveAsBusy(true);
    try {
      await onSaveAs(saveAsName.trim());
      setShowSaveAs(false);
      setSaveAsName('');
    } catch (err: unknown) {
      setSaveAsError((err as Error).message);
    } finally {
      setSaveAsBusy(false);
    }
  };

  return (
    <>
      <div className="toolbar">
        <span className="toolbar-brand">
          <span className="toolbar-brand-dotbot">DOTBOT</span>
          <span className="toolbar-brand-separator">//</span>
          <span className="toolbar-brand-editor">Studio</span>
        </span>

        {/* File commands */}
        <div className="toolbar-group">
          <button className="toolbar-cmd" onClick={onNew} disabled={loading}>
            New
          </button>
          <button className="toolbar-cmd" onClick={() => setShowPicker(true)} disabled={loading}>
            Open
          </button>
          <button
            className="toolbar-cmd"
            onClick={onSave}
            disabled={loading || !currentName || isRegistry}
            title={isRegistry ? 'Registry workflows are read-only — use Save As' : undefined}
          >
            Save
          </button>
          <button
            className="toolbar-cmd"
            onClick={() => {
              // Strip registry prefix (e.g. "RegName:workflow" → "workflow")
              const baseName = currentName?.includes(':')
                ? currentName.split(':').slice(1).join(':')
                : currentName;
              setSaveAsName(baseName ? `${baseName}-copy` : 'new-workflow');
              setSaveAsError(null);
              setShowSaveAs(true);
            }}
            disabled={loading}
          >
            Save As
          </button>
        </div>

        <span className="toolbar-divider" />

        {/* Canvas commands */}
        <div className="toolbar-group">
          <div className="toolbar-dropdown" ref={addMenuRef}>
            <button
              className="toolbar-cmd"
              onClick={() => setShowAddMenu((v) => !v)}
              disabled={loading}
            >
              Add Task ▾
            </button>
            {showAddMenu && (
              <div className="toolbar-dropdown-menu">
                {TASK_TYPES.map(({ type, label }) => (
                  <button
                    key={type}
                    className="toolbar-dropdown-item"
                    onClick={() => {
                      onAddTask(type);
                      setShowAddMenu(false);
                    }}
                  >
                    <span
                      className="toolbar-dropdown-dot"
                      style={{ background: TASK_TYPE_STYLES[type]?.color }}
                    />
                    {label}
                  </button>
                ))}
              </div>
            )}
          </div>
          <button className="toolbar-cmd" onClick={onAutoLayout} disabled={loading}>
            Auto Layout
          </button>
        </div>

        <span className="toolbar-spacer" />

        {currentName && (
          <span className="toolbar-title">
            {currentName}
            {isRegistry && <span className="toolbar-readonly"> (read-only)</span>}
            {dirty && !isRegistry && <span className="toolbar-dirty"> (unsaved)</span>}
          </span>
        )}
        {!currentName && <span className="toolbar-title" style={{ fontStyle: 'italic' }}>New workflow</span>}
      </div>

      {/* Open dialog */}
      {showPicker && (
        <WorkflowPicker onSelect={handleOpen} onClose={() => setShowPicker(false)} />
      )}

      {/* Save As dialog */}
      {showSaveAs && (
        <div className="modal-overlay" onClick={() => !saveAsBusy && setShowSaveAs(false)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <div className="modal-title">Save Workflow As</div>
            <div className="field-group">
              <label className="field-label">Workflow Name</label>
              <input
                className="field-input"
                value={saveAsName}
                onChange={(e) => setSaveAsName(e.target.value)}
                onKeyDown={(e) => e.key === 'Enter' && handleSaveAs()}
                placeholder="my-new-workflow"
                disabled={saveAsBusy}
                autoFocus
              />
              <div className="field-hint">
                Use lowercase with hyphens. This becomes the folder name.
              </div>
              {saveAsError && (
                <div className="field-error" style={{ color: '#ef4444', marginTop: '0.5rem' }}>
                  {saveAsError}
                </div>
              )}
            </div>
            <div className="modal-actions">
              <button className="toolbar-btn" onClick={() => setShowSaveAs(false)} disabled={saveAsBusy}>
                Cancel
              </button>
              <button
                className="toolbar-btn toolbar-btn--primary"
                onClick={handleSaveAs}
                disabled={!saveAsName.trim() || saveAsBusy}
              >
                {saveAsBusy ? 'Saving...' : 'Save'}
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}
