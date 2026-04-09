/**
 * Main application component for the dotbot Studio.
 * Orchestrates the toolbar, canvas, file editor, and unified properties panel.
 */
import { useState, useCallback, useEffect, useRef } from 'react';
import { ReactFlowProvider } from '@xyflow/react';
import { useWorkflow } from './hooks/useWorkflow';
import { Canvas } from './components/Canvas';
import { Toolbar } from './components/Toolbar';
import { Toolbox } from './components/Toolbox';
import { PropertiesPanel } from './components/PropertiesPanel';
import { PromptEditor } from './components/PromptEditor';
import type { TaskNodeData } from './model/transform';
import type { TaskType } from './model/workflow';

type TabId = 'workflow' | 'tasks';
type ViewMode = 'canvas' | 'fileEditor';

const MIN_PANEL_WIDTH = 200;
const MIN_CANVAS_GAP = 80;
const DEFAULT_PANEL_WIDTH = 320;
const DEFAULT_TOOLBOX_WIDTH = 220;

/** Context for opening the file editor from different sources */
export interface FileEditorContext {
  basePath: string;
  extension: string;
  files: string[];
  initialFile: string | null;
  label: string;
}

export function App() {
  const wf = useWorkflow();
  const [panelCollapsed, setPanelCollapsed] = useState(false);
  const [toolboxCollapsed, setToolboxCollapsed] = useState(false);
  const [panelWidth, setPanelWidth] = useState(DEFAULT_PANEL_WIDTH);
  const [toolboxWidth, setToolboxWidth] = useState(DEFAULT_TOOLBOX_WIDTH);
  const [activeTab, setActiveTab] = useState<TabId>('workflow');
  const [selectedTaskId, setSelectedTaskId] = useState<string | null>(null);
  const [viewMode, setViewMode] = useState<ViewMode>('canvas');
  const [editorContext, setEditorContext] = useState<FileEditorContext | null>(null);
  const resizingRef = useRef<'panel' | 'toolbox' | null>(null);
  const panelWidthRef = useRef(panelWidth);
  const toolboxWidthRef = useRef(toolboxWidth);
  const panelCollapsedRef = useRef(panelCollapsed);
  const toolboxCollapsedRef = useRef(toolboxCollapsed);
  panelWidthRef.current = panelWidth;
  toolboxWidthRef.current = toolboxWidth;
  panelCollapsedRef.current = panelCollapsed;
  toolboxCollapsedRef.current = toolboxCollapsed;

  useEffect(() => {
    if (!wf.dirty) return;
    const handler = (e: BeforeUnloadEvent) => {
      e.preventDefault();
    };
    window.addEventListener('beforeunload', handler);
    return () => window.removeEventListener('beforeunload', handler);
  }, [wf.dirty]);

  // Auto-open workflow from URL parameter: ?workflow=<name>
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const workflowName = params.get('workflow');
    if (workflowName) {
      wf.openWorkflow(workflowName);
    }
    // Run once on mount only
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Ctrl+S / Cmd+S to save from main canvas
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key === 's' && viewMode === 'canvas') {
        e.preventDefault();
        wf.saveWorkflow();
      }
    };
    window.addEventListener('keydown', handler);
    return () => window.removeEventListener('keydown', handler);
  }, [viewMode, wf.saveWorkflow]);

  // Global mouse handlers for resize dragging
  useEffect(() => {
    const handleMouseMove = (e: MouseEvent) => {
      if (!resizingRef.current) return;
      e.preventDefault();
      if (resizingRef.current === 'panel') {
        const otherWidth = toolboxCollapsedRef.current ? 0 : toolboxWidthRef.current;
        const maxWidth = window.innerWidth - otherWidth - MIN_CANVAS_GAP;
        const newWidth = Math.min(maxWidth, Math.max(MIN_PANEL_WIDTH, window.innerWidth - e.clientX));
        setPanelWidth(newWidth);
      } else if (resizingRef.current === 'toolbox') {
        const otherWidth = panelCollapsedRef.current ? 0 : panelWidthRef.current;
        const maxWidth = window.innerWidth - otherWidth - MIN_CANVAS_GAP;
        const newWidth = Math.min(maxWidth, Math.max(MIN_PANEL_WIDTH, e.clientX));
        setToolboxWidth(newWidth);
      }
    };
    const handleMouseUp = () => {
      if (resizingRef.current) {
        resizingRef.current = null;
        document.body.style.cursor = '';
        document.body.style.userSelect = '';
      }
    };
    window.addEventListener('mousemove', handleMouseMove);
    window.addEventListener('mouseup', handleMouseUp);
    return () => {
      window.removeEventListener('mousemove', handleMouseMove);
      window.removeEventListener('mouseup', handleMouseUp);
    };
  }, []);

  const startResizePanel = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    resizingRef.current = 'panel';
    document.body.style.cursor = 'col-resize';
    document.body.style.userSelect = 'none';
  }, []);

  const startResizeToolbox = useCallback((e: React.MouseEvent) => {
    e.preventDefault();
    resizingRef.current = 'toolbox';
    document.body.style.cursor = 'col-resize';
    document.body.style.userSelect = 'none';
  }, []);

  const handleNodeClick = useCallback((nodeId: string) => {
    setSelectedTaskId(nodeId);
    setActiveTab('tasks');
    setPanelCollapsed(false);
  }, []);

  const openFileEditor = useCallback((ctx: FileEditorContext) => {
    if (!wf.currentName) return;
    setEditorContext(ctx);
    setViewMode('fileEditor');
  }, [wf.currentName]);

  const handleEditPromptFile = useCallback((filename: string | null) => {
    openFileEditor({
      basePath: 'recipes/prompts',
      extension: '.md',
      files: wf.promptFiles,
      initialFile: filename,
      label: 'Prompt',
    });
  }, [openFileEditor, wf.promptFiles]);

  const handleEditAgentFile = useCallback((agentName: string | null) => {
    openFileEditor({
      basePath: agentName ? `recipes/agents/${agentName}` : 'recipes/agents',
      extension: '.md',
      files: wf.agentFiles.map((a) => `${a}/AGENT.md`),
      initialFile: agentName ? 'AGENT.md' : null,
      label: 'Agent',
    });
  }, [openFileEditor, wf.agentFiles]);

  const handleEditSkillFile = useCallback((skillName: string | null) => {
    openFileEditor({
      basePath: skillName ? `recipes/skills/${skillName}` : 'recipes/skills',
      extension: '.md',
      files: wf.skillFiles.map((s) => `${s}/SKILL.md`),
      initialFile: skillName ? 'SKILL.md' : null,
      label: 'Skill',
    });
  }, [openFileEditor, wf.skillFiles]);

  const handleCloseEditor = useCallback((filesChanged: boolean) => {
    setViewMode('canvas');
    setEditorContext(null);
    if (filesChanged) {
      wf.refreshFiles();
    }
  }, [wf.refreshFiles]);

  const selectedNode = selectedTaskId
    ? wf.nodes.find((n) => n.id === selectedTaskId)
    : null;
  const selectedTask = selectedNode
    ? (selectedNode.data as TaskNodeData).task
    : null;

  const allTaskNames = wf.nodes.map((n) => n.id);

  return (
    <ReactFlowProvider>
      <div className="app-container">
        <div style={{ display: viewMode === 'canvas' ? 'contents' : 'none' }}>
            <Toolbar
              currentName={wf.currentName}
              dirty={wf.dirty}
              loading={wf.loading}
              isRegistry={wf.isRegistry}
              onNew={wf.newWorkflow}
              onOpen={wf.openWorkflow}
              onSave={wf.saveWorkflow}
              onSaveAs={wf.saveWorkflowAs}
              onAddTask={(type: TaskType) => wf.addTask(type)}
              onAutoLayout={wf.autoLayout}
            />

            {wf.validationErrors.length > 0 && (
              <div className="validation-bar">
                {wf.validationErrors.length} validation issue(s):&nbsp;
                {wf.validationErrors.map((e, i) => (
                  <span key={i}>{e.message}{i < wf.validationErrors.length - 1 ? '; ' : ''}</span>
                ))}
              </div>
            )}

            <div className="main-content">
              <Toolbox
                collapsed={toolboxCollapsed}
                onToggleCollapse={() => setToolboxCollapsed((prev) => !prev)}
                onAddTask={(type: TaskType) => wf.addTask(type)}
                width={toolboxWidth}
                toggleLeft={toolboxCollapsed ? 8 : toolboxWidth + 8}
              />
              {!toolboxCollapsed && (
                <div className="resize-handle resize-handle--right" onMouseDown={startResizeToolbox} />
              )}

              <div className="canvas-area">
                {wf.nodes.length === 0 && !wf.loading ? (
                  <div className="empty-state">
                    <div className="empty-state-title">No tasks yet</div>
                    <div className="empty-state-hint">
                      Drag a task type from the toolbox or use "Add Task" in the toolbar
                    </div>
                  </div>
                ) : (
                  <Canvas
                    nodes={wf.nodes}
                    edges={wf.edges}
                    onNodesChange={wf.onNodesChange}
                    onEdgesChange={wf.onEdgesChange}
                    onConnect={wf.onConnect}
                    onNodeClick={handleNodeClick}
                    onDropTask={(type: TaskType, position: { x: number; y: number }) => wf.addTask(type, position)}
                    workflowKey={wf.currentName}
                  />
                )}
              </div>

              {!panelCollapsed && (
                <div className="resize-handle resize-handle--left" onMouseDown={startResizePanel} />
              )}
              <PropertiesPanel
                collapsed={panelCollapsed}
                onToggleCollapse={() => setPanelCollapsed((prev) => !prev)}
                activeTab={activeTab}
                onTabChange={setActiveTab}
                manifest={wf.manifest}
                onUpdateManifest={wf.updateManifestMeta}
                selectedTask={selectedTask}
                allTaskNames={allTaskNames}
                promptFiles={wf.promptFiles}
                agentFiles={wf.agentFiles}
                skillFiles={wf.skillFiles}
                onUpdateTask={(updates) => {
                  wf.updateTask(selectedTaskId!, updates);
                  if (updates.name && updates.name !== selectedTaskId) {
                    setSelectedTaskId(updates.name);
                  }
                }}
                onRemoveTask={() => {
                  wf.removeTask(selectedTaskId!);
                  setSelectedTaskId(null);
                }}
                onEditPromptFile={handleEditPromptFile}
                onEditAgentFile={handleEditAgentFile}
                onEditSkillFile={handleEditSkillFile}
                width={panelWidth}
                toggleRight={panelCollapsed ? 8 : panelWidth + 8}
              />
            </div>
        </div>

        {viewMode === 'fileEditor' && wf.currentName && editorContext && (
          <PromptEditor
            workflowName={wf.currentName}
            basePath={editorContext.basePath}
            extension={editorContext.extension}
            initialFile={editorContext.initialFile}
            availableFiles={editorContext.files}
            label={editorContext.label}
            onClose={handleCloseEditor}
          />
        )}

        {wf.loading && <div className="loading-overlay">Loading...</div>}

        {wf.error && (
          <div className="error-toast">
            {wf.error}
            <button onClick={wf.clearError}>Dismiss</button>
          </div>
        )}
      </div>
    </ReactFlowProvider>
  );
}
