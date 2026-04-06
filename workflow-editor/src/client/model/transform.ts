/**
 * Converts between workflow.yaml task arrays and React Flow nodes/edges.
 * Uses dagre for auto-layout when no saved positions exist.
 */
import { type Node, type Edge } from '@xyflow/react';
import Dagre from '@dagrejs/dagre';
import type { Task, WorkflowLayout } from './workflow';

/** Colors per task type — hardcoded RGB values chosen for legibility across all 6 CRT theme presets */
export const TASK_TYPE_STYLES: Record<string, { color: string; label: string }> = {
  prompt:          { color: 'rgb(80, 180, 220)',  label: 'Prompt' },
  script:          { color: 'rgb(0, 220, 120)',   label: 'Script' },
  mcp:             { color: 'rgb(180, 140, 255)', label: 'MCP' },
  task_gen:        { color: 'rgb(240, 170, 50)',  label: 'Task Gen' },
  prompt_template: { color: 'rgb(70, 160, 255)',  label: 'Template' },
  barrier:         { color: 'rgb(140, 140, 155)', label: 'Barrier' },
};

export interface TaskNodeData {
  task: Task;
  label: string;
  taskType: string;
  isOptional: boolean;
  hasCondition: boolean;
  [key: string]: unknown;
}

const NODE_WIDTH = 220;
const NODE_HEIGHT = 80;

/**
 * Convert tasks array to React Flow nodes and edges.
 */
export function tasksToFlow(
  tasks: Task[],
  layout?: WorkflowLayout | null,
): { nodes: Node<TaskNodeData>[]; edges: Edge[] } {
  const nodes: Node<TaskNodeData>[] = tasks.map((task) => ({
    id: task.name,
    type: 'taskNode',
    position: layout?.positions[task.name] ?? { x: 0, y: 0 },
    width: NODE_WIDTH,
    height: NODE_HEIGHT,
    data: {
      task,
      label: task.name,
      taskType: task.type,
      isOptional: task.optional ?? false,
      hasCondition: !!task.condition,
    },
  }));

  const edges: Edge[] = [];
  for (const task of tasks) {
    if (task.depends_on) {
      for (const dep of task.depends_on) {
        edges.push({
          id: `${dep}->${task.name}`,
          source: dep,
          target: task.name,
          type: 'dependencyEdge',
          animated: task.optional ?? false,
        });
      }
    }
  }

  // Auto-layout if no saved positions
  if (!layout) {
    applyDagreLayout(nodes, edges);
  }

  return { nodes, edges };
}

/**
 * Convert React Flow nodes back to tasks array, preserving order by priority.
 */
export function flowToTasks(nodes: Node<TaskNodeData>[]): Task[] {
  return nodes
    .map((node) => node.data.task)
    .sort((a, b) => a.priority - b.priority);
}

/**
 * Extract layout positions from current nodes for saving.
 */
export function extractLayout(nodes: Node[]): WorkflowLayout {
  const positions: Record<string, { x: number; y: number }> = {};
  for (const node of nodes) {
    positions[node.id] = { x: node.position.x, y: node.position.y };
  }
  return { positions };
}

/**
 * Apply dagre auto-layout to nodes based on edges (dependency graph).
 */
export function applyDagreLayout(nodes: Node[], edges: Edge[]): void {
  const g = new Dagre.graphlib.Graph().setDefaultEdgeLabel(() => ({}));
  g.setGraph({ rankdir: 'TB', nodesep: 60, ranksep: 80 });

  for (const node of nodes) {
    g.setNode(node.id, { width: NODE_WIDTH, height: NODE_HEIGHT });
  }

  for (const edge of edges) {
    g.setEdge(edge.source, edge.target);
  }

  Dagre.layout(g);

  for (const node of nodes) {
    const pos = g.node(node.id);
    node.position = {
      x: pos.x - NODE_WIDTH / 2,
      y: pos.y - NODE_HEIGHT / 2,
    };
  }
}
