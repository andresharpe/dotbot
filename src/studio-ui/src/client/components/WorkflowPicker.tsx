/**
 * Modal dialog listing available workflows for the Open command.
 */
import { useEffect, useState } from 'react';
import { listWorkflows } from '../hooks/useApi';
import { parseWorkflowYaml } from '../services/yaml-service';
import type { WorkflowSummary } from '../model/workflow';

interface WorkflowPickerProps {
  onSelect: (name: string) => void;
  onClose: () => void;
}

export function WorkflowPicker({ onSelect, onClose }: WorkflowPickerProps) {
  const [workflows, setWorkflows] = useState<WorkflowSummary[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    listWorkflows()
      .then((items) => {
        if (cancelled) return;
        const summaries: WorkflowSummary[] = items.map((item) => {
          if (item.yaml) {
            try {
              const manifest = parseWorkflowYaml(item.yaml);
              return {
                folder: item.folder,
                name: manifest.name || item.folder,
                description: manifest.description || '',
                version: manifest.version || '',
                taskCount: manifest.tasks?.length || 0,
                registry: item.registry || null,
              };
            } catch {
              // Fall through to default
            }
          }
          return {
            folder: item.folder,
            name: item.folder,
            description: '(unable to read workflow.yaml)',
            version: '',
            taskCount: 0,
            registry: item.registry || null,
          };
        });
        setWorkflows(summaries);
      })
      .catch((err) => {
        if (!cancelled) setError(err.message);
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => { cancelled = true; };
  }, []);

  return (
    <div className="modal-overlay" onClick={onClose}>
      <div className="modal" onClick={(e) => e.stopPropagation()}>
        <div className="modal-title">Open Workflow</div>

        {loading && <div style={{ color: 'var(--color-muted)', padding: 20 }}>Loading workflows...</div>}
        {error && <div style={{ color: 'var(--color-error)', padding: 20 }}>{error}</div>}

        {!loading && !error && workflows.length === 0 && (
          <div style={{ color: 'var(--color-muted)', padding: 20 }}>
            No workflows found in ~/dotbot/workflows/ or registries
          </div>
        )}

        {!loading && !error && workflows.length > 0 && (
          <ul className="workflow-list">
            {workflows.map((wf) => (
              <li
                key={wf.folder}
                className="workflow-list-item"
                onClick={() => onSelect(wf.folder)}
              >
                <div>
                  <div className="workflow-list-item-name">
                    {wf.name}
                    {wf.registry && (
                      <span style={{
                        marginLeft: 8,
                        fontSize: '0.7em',
                        padding: '2px 6px',
                        borderRadius: 3,
                        background: 'var(--color-surface, #1a1a2e)',
                        border: '1px solid var(--color-border, #333)',
                        color: 'var(--color-accent, #f0c040)',
                        verticalAlign: 'middle',
                      }}>{wf.registry}</span>
                    )}
                  </div>
                  <div className="workflow-list-item-meta">
                    {wf.description ? wf.description.slice(0, 80) : 'No description'}
                  </div>
                </div>
                <div className="workflow-list-item-meta">
                  {wf.taskCount} tasks &middot; v{wf.version}
                </div>
              </li>
            ))}
          </ul>
        )}

        <div className="modal-actions">
          <button className="toolbar-btn" onClick={onClose}>
            Cancel
          </button>
        </div>
      </div>
    </div>
  );
}
