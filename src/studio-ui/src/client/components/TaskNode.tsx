/**
 * Custom React Flow node representing a workflow task.
 * Displays task name, type badge, and indicators for optional/condition.
 */
import { memo } from 'react';
import { Handle, Position, type NodeProps } from '@xyflow/react';
import type { TaskNodeData } from '../model/transform';
import { TASK_TYPE_STYLES } from '../model/transform';

function TaskNodeComponent({ data, selected }: NodeProps) {
  const nodeData = data as unknown as TaskNodeData;
  const style = TASK_TYPE_STYLES[nodeData.taskType] || TASK_TYPE_STYLES.prompt;

  return (
    <div
      style={{
        background: 'var(--bg-module)',
        border: selected ? '2px solid var(--color-secondary)' : '1px solid var(--bezel-edge)',
        borderRadius: 4,
        padding: '10px 14px',
        minWidth: 200,
        borderStyle: nodeData.isOptional ? 'dashed' : 'solid',
        boxShadow: selected
          ? '0 0 12px var(--secondary-glow)'
          : '0 2px 8px rgba(0,0,0,0.3)',
        cursor: 'grab',
        fontFamily: "var(--font-mono)",
      }}
    >
      <Handle type="target" position={Position.Top} style={handleStyle} />

      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4 }}>
        <span
          style={{
            display: 'inline-block',
            padding: '1px 6px',
            borderRadius: 3,
            fontSize: 9,
            fontWeight: 600,
            background: style.color,
            color: 'var(--bg-deep)',
            textTransform: 'uppercase',
            letterSpacing: '0.05em',
            textShadow: `0 0 8px ${style.color}`,
          }}
        >
          {style.label}
        </span>
        {nodeData.hasCondition && (
          <span style={{ fontSize: 9, color: 'var(--color-warning)' }} title="Has condition">
            ?
          </span>
        )}
        {nodeData.isOptional && (
          <span style={{ fontSize: 9, color: 'var(--color-muted)', fontStyle: 'italic' }}>opt</span>
        )}
      </div>

      <div
        style={{
          fontSize: 11,
          fontWeight: 500,
          color: 'var(--color-primary)',
          whiteSpace: 'nowrap',
          overflow: 'hidden',
          textOverflow: 'ellipsis',
          maxWidth: 200,
        }}
      >
        {nodeData.label}
      </div>

      <div style={{ fontSize: 9, color: 'var(--color-muted)', marginTop: 2 }}>
        Priority: {nodeData.task.priority}
      </div>

      <Handle type="source" position={Position.Bottom} style={handleStyle} />
    </div>
  );
}

const handleStyle: React.CSSProperties = {
  width: 8,
  height: 8,
  background: 'var(--color-secondary)',
  border: '2px solid var(--bg-module)',
  boxShadow: '0 0 6px var(--secondary-glow)',
};

export const TaskNode = memo(TaskNodeComponent);
