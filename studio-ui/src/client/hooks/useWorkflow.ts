/**
 * Central state management hook for the workflow editor.
 * Manages the current workflow manifest, React Flow nodes/edges, and dirty state.
 */
import { useState, useCallback, useRef, useEffect } from 'react';
import { applyNodeChanges } from '@xyflow/react';
import type { Node, Edge } from '@xyflow/react';
import type { WorkflowManifest, WorkflowLayout, Task } from '../model/workflow';
import { createEmptyManifest, createEmptyTask } from '../model/workflow';
import type { TaskNodeData } from '../model/transform';
import { tasksToFlow, flowToTasks, extractLayout, applyDagreLayout } from '../model/transform';
import { parseWorkflowYaml, serializeWorkflowYaml, validateManifest } from '../services/yaml-service';
import * as api from './useApi';

export interface WorkflowState {
  /** Currently loaded workflow name (null if unsaved new workflow) */
  currentName: string | null;
  /** The full manifest */
  manifest: WorkflowManifest;
  /** React Flow nodes */
  nodes: Node<TaskNodeData>[];
  /** React Flow edges */
  edges: Edge[];
  /** Whether there are unsaved changes */
  dirty: boolean;
  /** Validation errors */
  validationErrors: { field: string; message: string }[];
  /** Available prompt files in the workflow folder */
  promptFiles: string[];
  /** Available agent folders */
  agentFiles: string[];
  /** Available skill folders */
  skillFiles: string[];
  /** Loading state */
  loading: boolean;
  /** Error message */
  error: string | null;
}

export interface WorkflowActions {
  newWorkflow: () => void;
  openWorkflow: (name: string) => Promise<void>;
  saveWorkflow: () => Promise<void>;
  saveWorkflowAs: (newName: string) => Promise<void>;
  updateManifestMeta: (updates: Partial<WorkflowManifest>) => void;
  updateTask: (taskName: string, updates: Partial<Task>) => void;
  addTask: (type: import('../model/workflow').TaskType, position?: { x: number; y: number }) => void;
  removeTask: (taskName: string) => void;
  setNodes: (nodes: Node<TaskNodeData>[]) => void;
  setEdges: (edges: Edge[]) => void;
  onNodesChange: (changes: import('@xyflow/react').NodeChange[]) => void;
  onEdgesChange: (changes: import('@xyflow/react').EdgeChange[]) => void;
  onConnect: (connection: import('@xyflow/react').Connection) => void;
  autoLayout: () => void;
  clearError: () => void;
  refreshFiles: () => Promise<void>;
}

export function useWorkflow(): WorkflowState & WorkflowActions {
  const [currentName, setCurrentName] = useState<string | null>(null);
  const [manifest, setManifest] = useState<WorkflowManifest>(createEmptyManifest('new-workflow'));
  const [nodes, setNodes] = useState<Node<TaskNodeData>[]>([]);
  const [edges, setEdges] = useState<Edge[]>([]);
  const [dirty, setDirty] = useState(false);
  const [validationErrors, setValidationErrors] = useState<{ field: string; message: string }[]>([]);
  const [promptFiles, setPromptFiles] = useState<string[]>([]);
  const [agentFiles, setAgentFiles] = useState<string[]>([]);
  const [skillFiles, setSkillFiles] = useState<string[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const layoutRef = useRef<WorkflowLayout | null>(null);

  // Revalidate manifest whenever metadata or tasks change
  useEffect(() => {
    const tasks = nodes.map((n) => n.data.task);
    const current = { ...manifest, tasks };
    setValidationErrors(validateManifest(current));
  }, [manifest, nodes]);

  const rebuildFlow = useCallback((tasks: Task[], layout?: WorkflowLayout | null) => {
    const { nodes: newNodes, edges: newEdges } = tasksToFlow(tasks, layout);
    setNodes(newNodes);
    setEdges(newEdges);
  }, []);

  const syncTasksFromNodes = useCallback((currentNodes: Node<TaskNodeData>[], currentEdges: Edge[]) => {
    // Update depends_on from edges
    const depsMap = new Map<string, string[]>();
    for (const edge of currentEdges) {
      const deps = depsMap.get(edge.target) || [];
      deps.push(edge.source);
      depsMap.set(edge.target, deps);
    }

    const tasks = currentNodes.map((node) => {
      const task = { ...node.data.task };
      const deps = depsMap.get(node.id);
      task.depends_on = deps && deps.length > 0 ? deps : undefined;
      return task;
    });

    return tasks.sort((a, b) => a.priority - b.priority);
  }, []);

  // -- Actions --

  const newWorkflow = useCallback(() => {
    if (dirty && !window.confirm('You have unsaved changes. Discard them and create a new workflow?')) {
      return;
    }
    const m = createEmptyManifest('new-workflow');
    setManifest(m);
    setCurrentName(null);
    setNodes([]);
    setEdges([]);
    setDirty(false);
    setValidationErrors([]);
    setPromptFiles([]);
    setAgentFiles([]);
    setSkillFiles([]);
    layoutRef.current = null;
    setError(null);
  }, [dirty]);

  const openWorkflow = useCallback(async (name: string) => {
    if (dirty && !window.confirm('You have unsaved changes. Discard them and open another workflow?')) {
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const data = await api.loadWorkflow(name);
      if (!data.yaml) {
        throw new Error(`Workflow '${name}' has no workflow.yaml file`);
      }
      const manifest = parseWorkflowYaml(data.yaml);
      const validation = validateManifest(manifest);
      let layout: WorkflowLayout | null = null;
      if (data.layout) {
        try {
          layout = JSON.parse(data.layout);
        } catch {
          // Ignore invalid layout
        }
      }
      setManifest(manifest);
      setCurrentName(name);
      setValidationErrors(validation);
      setPromptFiles(data.promptFiles);
      setAgentFiles(data.agentFiles || []);
      setSkillFiles(data.skillFiles || []);
      layoutRef.current = layout;
      rebuildFlow(manifest.tasks, layout);
      setDirty(false);
    } catch (err: unknown) {
      setError((err as Error).message);
    } finally {
      setLoading(false);
    }
  }, [dirty, rebuildFlow]);

  const saveWorkflow = useCallback(async () => {
    if (!currentName) {
      setError('No workflow name — use Save As for new workflows');
      return;
    }
    setLoading(true);
    setError(null);
    try {
      const tasks = syncTasksFromNodes(nodes, edges);
      const updated = { ...manifest, tasks };
      const layout = extractLayout(nodes);
      const yaml = serializeWorkflowYaml(updated);
      const layoutJson = JSON.stringify(layout, null, 2);
      await api.saveWorkflow(currentName, yaml, layoutJson);
      setManifest(updated);
      layoutRef.current = layout;
      setDirty(false);
    } catch (err: unknown) {
      setError((err as Error).message);
    } finally {
      setLoading(false);
    }
  }, [currentName, manifest, nodes, edges, syncTasksFromNodes]);

  const saveWorkflowAs = useCallback(async (newName: string) => {
    setLoading(true);
    setError(null);
    try {
      if (currentName) {
        // Copy existing, then overwrite with current state
        await api.copyWorkflow(currentName, newName);
      } else {
        await api.createWorkflow(newName);
      }
      const tasks = syncTasksFromNodes(nodes, edges);
      const updated = { ...manifest, name: newName, tasks };
      const layout = extractLayout(nodes);
      const yaml = serializeWorkflowYaml(updated);
      const layoutJson = JSON.stringify(layout, null, 2);
      await api.saveWorkflow(newName, yaml, layoutJson);
      setManifest(updated);
      setCurrentName(newName);
      layoutRef.current = layout;
      setDirty(false);
    } catch (err: unknown) {
      setError((err as Error).message);
      throw err; // Re-throw so callers (e.g. Save As dialog) can handle it
    } finally {
      setLoading(false);
    }
  }, [currentName, manifest, nodes, edges, syncTasksFromNodes]);

  const updateManifestMeta = useCallback((updates: Partial<WorkflowManifest>) => {
    setManifest((prev) => ({ ...prev, ...updates }));
    setDirty(true);
  }, []);

  const updateTask = useCallback((taskName: string, updates: Partial<Task>) => {
    setNodes((prev) =>
      prev.map((node) => {
        if (node.id !== taskName) return node;
        const updatedTask = { ...node.data.task, ...updates };
        const newId = updates.name || node.id;
        return {
          ...node,
          id: newId,
          data: {
            ...node.data,
            task: updatedTask,
            label: updatedTask.name,
            taskType: updatedTask.type,
            isOptional: updatedTask.optional ?? false,
            hasCondition: !!updatedTask.condition,
          },
        };
      }),
    );
    // Update edges and other tasks' depends_on if task was renamed
    if (updates.name && updates.name !== taskName) {
      const newName = updates.name;
      setEdges((prev) =>
        prev.map((edge) => {
          const newSource = edge.source === taskName ? newName : edge.source;
          const newTarget = edge.target === taskName ? newName : edge.target;
          return {
            ...edge,
            id: `${newSource}->${newTarget}`,
            source: newSource,
            target: newTarget,
          };
        }),
      );
      // Update depends_on references in all other nodes
      setNodes((prev) =>
        prev.map((node) => {
          if (node.id === newName) return node; // skip the renamed node itself
          const deps = node.data.task.depends_on;
          if (!deps || !deps.includes(taskName)) return node;
          const updatedDeps = deps.map((d) => (d === taskName ? newName : d));
          return {
            ...node,
            data: {
              ...node.data,
              task: { ...node.data.task, depends_on: updatedDeps },
            },
          };
        }),
      );
    }
    // Sync edges when depends_on changes from the panel
    if ('depends_on' in updates) {
      const nodeId = updates.name || taskName;
      const newDeps = updates.depends_on || [];
      setEdges((prev) => {
        // Remove edges targeting this node that are no longer in depends_on
        const kept = prev.filter(
          (e) => e.target !== nodeId || newDeps.includes(e.source),
        );
        // Add edges for new dependencies not yet represented
        const existingSources = new Set(
          kept.filter((e) => e.target === nodeId).map((e) => e.source),
        );
        const added = newDeps
          .filter((dep) => !existingSources.has(dep))
          .map((dep) => ({
            id: `${dep}->${nodeId}`,
            source: dep,
            target: nodeId,
            type: 'dependencyEdge',
          }));
        return [...kept, ...added];
      });
    }
    setDirty(true);
  }, []);

  const addTask = useCallback((type: import('../model/workflow').TaskType, position?: { x: number; y: number }) => {
    const maxPriority = nodes.reduce((max, n) => Math.max(max, n.data.task.priority), -1);
    const newPriority = maxPriority + 1;
    const name = `New Task ${newPriority}`;
    const task = createEmptyTask(name, newPriority, type);
    const newNode: Node<TaskNodeData> = {
      id: name,
      type: 'taskNode',
      position: position ?? { x: 100, y: (nodes.length + 1) * 120 },
      width: 220,
      height: 80,
      data: {
        task,
        label: name,
        taskType: task.type,
        isOptional: false,
        hasCondition: false,
      },
    };
    setNodes((prev) => [...prev, newNode]);
    setDirty(true);
  }, [nodes]);

  const removeTask = useCallback((taskName: string) => {
    setNodes((prev) => prev.filter((n) => n.id !== taskName));
    setEdges((prev) => prev.filter((e) => e.source !== taskName && e.target !== taskName));
    setDirty(true);
  }, []);

  const onNodesChange = useCallback((changes: import('@xyflow/react').NodeChange[]) => {
    setNodes((prev) => applyNodeChanges(changes, prev) as Node<TaskNodeData>[]);
    const hasPositionChange = changes.some((c) => c.type === 'position' && c.dragging);
    const hasRemoval = changes.some((c) => c.type === 'remove');
    if (hasPositionChange || hasRemoval) setDirty(true);
  }, []);

  const onEdgesChange = useCallback((changes: import('@xyflow/react').EdgeChange[]) => {
    // Compute removed edges from current state before mutating
    const removeIds = new Set(
      changes.filter((c) => c.type === 'remove').map((c) => c.id),
    );
    const removedEdges = removeIds.size > 0
      ? edges.filter((e) => removeIds.has(e.id)).map((e) => ({ source: e.source, target: e.target }))
      : [];

    setEdges((prev) => {
      const updated = [...prev];
      for (const change of changes) {
        if (change.type === 'remove') {
          const idx = updated.findIndex((e) => e.id === change.id);
          if (idx >= 0) {
            updated.splice(idx, 1);
          }
        }
      }
      return updated;
    });

    // Sync: remove source from target's depends_on for each removed edge
    if (removedEdges.length > 0) {
      setNodes((prev) =>
        prev.map((node) => {
          const removals = removedEdges
            .filter((e) => e.target === node.id)
            .map((e) => e.source);
          if (removals.length === 0) return node;
          const task = { ...node.data.task };
          const current = task.depends_on || [];
          const updated = current.filter((d) => !removals.includes(d));
          task.depends_on = updated.length > 0 ? updated : undefined;
          return { ...node, data: { ...node.data, task } };
        }),
      );
    }

    setDirty(true);
  }, [edges]);

  const onConnect = useCallback((connection: import('@xyflow/react').Connection) => {
    if (!connection.source || !connection.target) return;
    const id = `${connection.source}->${connection.target}`;
    setEdges((prev) => {
      if (prev.some((e) => e.id === id)) return prev;
      return [
        ...prev,
        {
          id,
          source: connection.source,
          target: connection.target,
          type: 'dependencyEdge',
        },
      ];
    });
    // Sync: add source to target's depends_on
    const source = connection.source;
    const target = connection.target;
    setNodes((prev) =>
      prev.map((node) => {
        if (node.id !== target) return node;
        const task = { ...node.data.task };
        const current = task.depends_on || [];
        if (!current.includes(source)) {
          task.depends_on = [...current, source];
        }
        return { ...node, data: { ...node.data, task } };
      }),
    );
    setDirty(true);
  }, []);

  const autoLayout = useCallback(() => {
    setNodes((prev) => {
      const updated = prev.map((n) => ({ ...n }));
      applyDagreLayout(updated, edges);
      return updated;
    });
    setDirty(true);
  }, [edges]);

  const clearError = useCallback(() => setError(null), []);

  const refreshFiles = useCallback(async () => {
    if (!currentName) return;
    try {
      const data = await api.loadWorkflow(currentName);
      setPromptFiles(data.promptFiles);
      setAgentFiles(data.agentFiles || []);
      setSkillFiles(data.skillFiles || []);
    } catch {
      // Non-critical
    }
  }, [currentName]);

  return {
    currentName,
    manifest,
    nodes,
    edges,
    dirty,
    validationErrors,
    promptFiles,
    agentFiles,
    skillFiles,
    loading,
    error,
    newWorkflow,
    openWorkflow,
    saveWorkflow,
    saveWorkflowAs,
    updateManifestMeta,
    updateTask,
    addTask,
    removeTask,
    setNodes,
    setEdges,
    onNodesChange,
    onEdgesChange,
    onConnect,
    autoLayout,
    clearError,
    refreshFiles,
  };
}
