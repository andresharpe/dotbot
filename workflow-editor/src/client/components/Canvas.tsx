/**
 * React Flow canvas wrapper with custom node/edge types and controls.
 */
import { useCallback } from 'react';
import {
  ReactFlow,
  Controls,
  MiniMap,
  useReactFlow,
  type Node,
  type Edge,
  type NodeChange,
  type EdgeChange,
  type Connection,
  type NodeTypes,
  type EdgeTypes,
  MarkerType,
} from '@xyflow/react';
import type { TaskType } from '../model/workflow';
import '@xyflow/react/dist/style.css';
import { TaskNode } from './TaskNode';
import { DependencyEdge } from './DependencyEdge';
import { TASK_TYPE_STYLES, type TaskNodeData } from '../model/transform';

const nodeTypes: NodeTypes = {
  taskNode: TaskNode,
};

const edgeTypes: EdgeTypes = {
  dependencyEdge: DependencyEdge,
};

const defaultEdgeOptions = {
  type: 'dependencyEdge',
  markerEnd: { type: MarkerType.ArrowClosed, color: '#b8a030' },
};

interface CanvasProps {
  nodes: Node<TaskNodeData>[];
  edges: Edge[];
  onNodesChange: (changes: NodeChange[]) => void;
  onEdgesChange: (changes: EdgeChange[]) => void;
  onConnect: (connection: Connection) => void;
  onNodeClick: (nodeId: string) => void;
  onDropTask?: (type: TaskType, position: { x: number; y: number }) => void;
}

export function Canvas({
  nodes,
  edges,
  onNodesChange,
  onEdgesChange,
  onConnect,
  onNodeClick,
  onDropTask,
}: CanvasProps) {
  const { screenToFlowPosition } = useReactFlow();

  const handleDragOver = useCallback((e: React.DragEvent) => {
    if (e.dataTransfer.types.includes('application/dotbot-task-type')) {
      e.preventDefault();
      e.dataTransfer.dropEffect = 'move';
    }
  }, []);

  const handleDrop = useCallback((e: React.DragEvent) => {
    const type = e.dataTransfer.getData('application/dotbot-task-type') as TaskType;
    if (!type || !onDropTask) return;
    e.preventDefault();
    const position = screenToFlowPosition({ x: e.clientX, y: e.clientY });
    onDropTask(type, position);
  }, [onDropTask, screenToFlowPosition]);

  return (
    <ReactFlow
      nodes={nodes}
      edges={edges}
      onNodesChange={onNodesChange}
      onEdgesChange={onEdgesChange}
      onConnect={onConnect}
      onNodeClick={(_event, node) => onNodeClick(node.id)}
      onDragOver={handleDragOver}
      onDrop={handleDrop}
      nodeTypes={nodeTypes}
      edgeTypes={edgeTypes}
      defaultEdgeOptions={defaultEdgeOptions}
      fitView
      fitViewOptions={{ padding: 0.3 }}
      deleteKeyCode={['Backspace', 'Delete']}
      minZoom={0.2}
      maxZoom={2}
      proOptions={{ hideAttribution: true }}
    >
      <Controls position="bottom-left" />
      <MiniMap
        position="bottom-right"
        nodeColor={(node) => {
          const data = node.data as TaskNodeData;
          return TASK_TYPE_STYLES[data?.taskType]?.color || 'rgb(80, 180, 220)';
        }}
        nodeStrokeWidth={3}
        nodeBorderRadius={3}
        maskColor="rgba(5, 5, 8, 0.6)"
        style={{ background: 'rgb(5, 5, 8)' }}
      />
    </ReactFlow>
  );
}
