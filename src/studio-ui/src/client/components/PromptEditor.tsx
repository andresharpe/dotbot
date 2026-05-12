/**
 * Full-screen file editor view.
 * Replaces the canvas area when editing prompt, script, agent, or skill files.
 * Supports New, Open, Save, Save As operations.
 */
import { useState, useEffect, useCallback, useRef } from 'react';
import * as api from '../hooks/useApi';

interface PromptEditorProps {
  /** Currently loaded workflow name (needed for API calls) */
  workflowName: string;
  /** Base path within the workflow folder (e.g., 'recipes/prompts', '') */
  basePath: string;
  /** File extension (e.g., '.md', '.ps1') */
  extension: string;
  /** Initial file to open (null = new file) */
  initialFile: string | null;
  /** Available files for the Open picker */
  availableFiles: string[];
  /** Label for the editor (e.g., 'Prompt', 'Script', 'Agent') */
  label: string;
  /** Called when the user clicks "← Canvas" to return */
  onClose: (filesChanged: boolean) => void;
}

export function PromptEditor({
  workflowName,
  basePath,
  extension,
  initialFile,
  availableFiles,
  label,
  onClose,
}: PromptEditorProps) {
  const [currentFile, setCurrentFile] = useState<string | null>(initialFile);
  const [content, setContent] = useState('');
  const [savedContent, setSavedContent] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [showOpenPicker, setShowOpenPicker] = useState(false);
  const [showSaveAs, setShowSaveAs] = useState(false);
  const [saveAsName, setSaveAsName] = useState('');
  const [saveAsBusy, setSaveAsBusy] = useState(false);
  const [saveAsError, setSaveAsError] = useState<string | null>(null);
  const [files, setFiles] = useState<string[]>(availableFiles);
  const [filesChanged, setFilesChanged] = useState(false);
  const textareaRef = useRef<HTMLTextAreaElement>(null);

  const dirty = content !== savedContent;

  const filePath = (filename: string) =>
    basePath ? `${basePath}/${filename}` : filename;

  const defaultNewName = `new-${label.toLowerCase()}${extension}`;

  // Load file content on mount or when context changes
  useEffect(() => {
    if (!initialFile) return;
    setLoading(true);
    setError(null);
    const path = basePath ? `${basePath}/${initialFile}` : initialFile;
    api.readWorkflowFile(workflowName, path)
      .then((text) => {
        setContent(text);
        setSavedContent(text);
        setCurrentFile(initialFile);
      })
      .catch((err) => setError(err.message))
      .finally(() => setLoading(false));
  }, [workflowName, basePath, initialFile]);

  const handleNew = useCallback(() => {
    if (dirty && !window.confirm('You have unsaved changes. Discard them?')) return;
    setCurrentFile(null);
    setContent('');
    setSavedContent('');
    setError(null);
  }, [dirty]);

  const handleOpen = useCallback(async (filename: string) => {
    if (dirty && !window.confirm('You have unsaved changes. Discard them?')) return;
    setShowOpenPicker(false);
    setLoading(true);
    setError(null);
    try {
      const text = await api.readWorkflowFile(workflowName, filePath(filename));
      setContent(text);
      setSavedContent(text);
      setCurrentFile(filename);
    } catch (err: unknown) {
      setError((err as Error).message);
    } finally {
      setLoading(false);
    }
  }, [workflowName, basePath, dirty]);

  const handleSave = useCallback(async () => {
    if (!currentFile) {
      setSaveAsName(defaultNewName);
      setSaveAsError(null);
      setShowSaveAs(true);
      return;
    }
    setLoading(true);
    setError(null);
    try {
      await api.saveWorkflowFile(workflowName, filePath(currentFile), content);
      setSavedContent(content);
      setFilesChanged(true);
    } catch (err: unknown) {
      setError((err as Error).message);
    } finally {
      setLoading(false);
    }
  }, [workflowName, basePath, currentFile, content, defaultNewName]);

  const handleSaveAs = useCallback(async () => {
    if (!saveAsName.trim()) return;
    let filename = saveAsName.trim();
    if (!filename.endsWith(extension)) {
      filename = `${filename}${extension}`;
    }
    setSaveAsError(null);
    setSaveAsBusy(true);
    try {
      await api.saveWorkflowFile(workflowName, filePath(filename), content);
      setCurrentFile(filename);
      setSavedContent(content);
      setShowSaveAs(false);
      setSaveAsName('');
      setFilesChanged(true);
      // Add to local file list if not already present
      setFiles((prev) => prev.includes(filename) ? prev : [...prev, filename].sort());
    } catch (err: unknown) {
      setSaveAsError((err as Error).message);
    } finally {
      setSaveAsBusy(false);
    }
  }, [workflowName, basePath, extension, saveAsName, content]);

  const handleClose = useCallback(() => {
    if (dirty && !window.confirm('You have unsaved changes. Discard them?')) return;
    onClose(filesChanged);
  }, [dirty, filesChanged, onClose]);

  // Ctrl+S keyboard shortcut
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key === 's') {
        e.preventDefault();
        handleSave();
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [handleSave]);

  return (
    <>
      <div className="prompt-editor">
        {/* Toolbar */}
        <div className="prompt-editor-toolbar">
          <button className="toolbar-cmd" onClick={handleClose}>
            ← Canvas
          </button>

          <span className="toolbar-divider" />

          <span className="toolbar-brand">
            <span className="toolbar-brand-editor">{label} Editor</span>
          </span>

          <span className="toolbar-divider" />

          <div className="toolbar-group">
            <button className="toolbar-cmd" onClick={handleNew} disabled={loading}>
              New
            </button>
            <button className="toolbar-cmd" onClick={() => setShowOpenPicker(true)} disabled={loading}>
              Open
            </button>
            <button className="toolbar-cmd" onClick={handleSave} disabled={loading}>
              Save
            </button>
            <button
              className="toolbar-cmd"
              onClick={() => {
                const copyName = currentFile
                  ? currentFile.replace(new RegExp(`\\${extension}$`), `-copy${extension}`)
                  : defaultNewName;
                setSaveAsName(copyName);
                setSaveAsError(null);
                setShowSaveAs(true);
              }}
              disabled={loading}
            >
              Save As
            </button>
          </div>

          <span className="toolbar-spacer" />

          {currentFile && (
            <span className="toolbar-title">
              {basePath ? `${basePath}/` : ''}{currentFile}
              {dirty && <span className="toolbar-dirty"> (unsaved)</span>}
            </span>
          )}
          {!currentFile && (
            <span className="toolbar-title" style={{ fontStyle: 'italic' }}>
              New {label.toLowerCase()}{dirty && <span className="toolbar-dirty"> (unsaved)</span>}
            </span>
          )}
        </div>

        {/* Error bar */}
        {error && (
          <div className="validation-bar">
            {error}
            <button
              style={{ marginLeft: 8, background: 'none', border: 'none', color: 'inherit', cursor: 'pointer', textDecoration: 'underline' }}
              onClick={() => setError(null)}
            >
              Dismiss
            </button>
          </div>
        )}

        {/* Editor area */}
        <div className="prompt-editor-body">
          {loading ? (
            <div className="prompt-editor-loading">Loading...</div>
          ) : (
            <textarea
              ref={textareaRef}
              className="prompt-editor-textarea"
              value={content}
              onChange={(e) => setContent(e.target.value)}
              spellCheck={false}
              placeholder={`Write your ${label.toLowerCase()} file here...`}
            />
          )}
        </div>
      </div>

      {/* Open picker modal */}
      {showOpenPicker && (
        <div className="modal-overlay" onClick={() => setShowOpenPicker(false)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <div className="modal-title">Open {label} File</div>
            {files.length === 0 ? (
              <div className="panel-empty-state">No {label.toLowerCase()} files found</div>
            ) : (
              <ul className="workflow-list">
                {files.map((f) => (
                  <li
                    key={f}
                    className="workflow-list-item"
                    onClick={() => handleOpen(f)}
                  >
                    <span className="workflow-list-item-name">{f}</span>
                  </li>
                ))}
              </ul>
            )}
            <div className="modal-actions">
              <button className="toolbar-btn" onClick={() => setShowOpenPicker(false)}>
                Cancel
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Save As modal */}
      {showSaveAs && (
        <div className="modal-overlay" onClick={() => !saveAsBusy && setShowSaveAs(false)}>
          <div className="modal" onClick={(e) => e.stopPropagation()}>
            <div className="modal-title">Save {label} As</div>
            <div className="field-group">
              <label className="field-label">Filename</label>
              <input
                className="field-input"
                value={saveAsName}
                onChange={(e) => setSaveAsName(e.target.value)}
                onKeyDown={(e) => e.key === 'Enter' && handleSaveAs()}
                placeholder={defaultNewName}
                disabled={saveAsBusy}
                autoFocus
              />
              <div className="field-hint">{extension} extension will be added automatically if missing</div>
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
