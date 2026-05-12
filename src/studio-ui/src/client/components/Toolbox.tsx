/**
 * Collapsible left-side toolbox panel with task type items.
 * Supports both click-to-add and drag-to-canvas.
 */
import type { TaskType } from '../model/workflow';
import { TASK_TYPE_STYLES } from '../model/transform';

const TASK_TYPES: { type: TaskType; label: string; description: string }[] = [
  { type: 'prompt', label: 'Prompt', description: 'AI-executed task using a prompt file' },
  { type: 'prompt_template', label: 'Prompt Template', description: 'AI task with custom prompt template' },
  { type: 'script', label: 'Script', description: 'Execute a PowerShell script' },
  { type: 'mcp', label: 'MCP Tool', description: 'Call an MCP tool directly' },
  { type: 'task_gen', label: 'Task Generator', description: 'Script that generates tasks dynamically' },
  { type: 'barrier', label: 'Barrier', description: 'Synchronization point for dependencies' },
];

interface ToolboxProps {
  collapsed: boolean;
  onToggleCollapse: () => void;
  onAddTask: (type: TaskType) => void;
  width: number;
  toggleLeft: number;
}

export function Toolbox({ collapsed, onToggleCollapse, onAddTask, width, toggleLeft }: ToolboxProps) {
  const handleDragStart = (e: React.DragEvent, type: TaskType) => {
    e.dataTransfer.setData('application/dotbot-task-type', type);
    e.dataTransfer.effectAllowed = 'move';
  };

  return (
    <>
      {/* Collapse toggle — always visible at the top-left edge */}
      <button
        className="toolbox-collapse-toggle"
        style={{ left: toggleLeft }}
        onClick={onToggleCollapse}
        title={collapsed ? 'Show toolbox' : 'Hide toolbox'}
      >
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
          {collapsed ? (
            <path d="M6 3L11 8L6 13" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
          ) : (
            <path d="M10 3L5 8L10 13" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
          )}
        </svg>
      </button>

      {!collapsed && (
        <div className="toolbox-panel" style={{ width }}>
          <div className="toolbox-header">Task Types</div>
          <div className="toolbox-items">
            {TASK_TYPES.map(({ type, label, description }) => (
              <div
                key={type}
                className="toolbox-item"
                draggable
                onDragStart={(e) => handleDragStart(e, type)}
                onClick={() => onAddTask(type)}
                title={description}
              >
                <div className="toolbox-item-color" style={{ background: TASK_TYPE_STYLES[type]?.color }} />
                <div className="toolbox-item-content">
                  <div className="toolbox-item-label">{label}</div>
                  <div className="toolbox-item-desc">{description}</div>
                </div>
              </div>
            ))}
          </div>
          <div className="toolbox-hint">Click to add or drag onto canvas</div>
        </div>
      )}
    </>
  );
}
