/**
 * Collapsible right-side panel with Workflow and Tasks tabs.
 * Recipe fields (prompts, agents, skills) get rich editing.
 * All other fields are plain text / YAML editors.
 */
import { useState, useEffect, useRef, useCallback } from 'react';
import { createPortal } from 'react-dom';
import YAML from 'yaml';
import type { WorkflowManifest, Task, TaskType } from '../model/workflow';
import { TASK_TYPE_STYLES } from '../model/transform';

/** Properties that apply to specific task types (beyond universal ones) */
const TYPE_FIELDS: Record<TaskType, Set<string>> = {
  prompt:          new Set(['workflow', 'outputs', 'outputs_dir', 'min_output_count', 'front_matter_docs', 'commit', 'post_script', 'model']),
  prompt_template: new Set(['workflow', 'outputs', 'outputs_dir', 'min_output_count', 'front_matter_docs', 'commit', 'post_script', 'model']),
  script:          new Set(['script', 'model']),
  mcp:             new Set(['mcp_tool', 'mcp_args', 'model']),
  task_gen:        new Set(['workflow', 'script', 'outputs', 'outputs_dir', 'min_output_count', 'commit', 'post_script', 'model']),
  barrier:         new Set([]),
};

function hasField(type: TaskType, field: string): boolean {
  return TYPE_FIELDS[type]?.has(field) ?? false;
}

type TabId = 'workflow' | 'tasks';

interface PropertiesPanelProps {
  collapsed: boolean;
  onToggleCollapse: () => void;
  activeTab: TabId;
  onTabChange: (tab: TabId) => void;
  manifest: WorkflowManifest;
  onUpdateManifest: (updates: Partial<WorkflowManifest>) => void;
  selectedTask: Task | null;
  allTaskNames: string[];
  promptFiles: string[];
  agentFiles: string[];
  skillFiles: string[];
  onUpdateTask: (updates: Partial<Task>) => void;
  onRemoveTask: () => void;
  onEditPromptFile: (filename: string | null) => void;
  onEditAgentFile: (agentName: string | null) => void;
  onEditSkillFile: (skillName: string | null) => void;
  width: number;
  toggleRight: number;
}

export function PropertiesPanel({
  collapsed,
  onToggleCollapse,
  activeTab,
  onTabChange,
  manifest,
  onUpdateManifest,
  selectedTask,
  allTaskNames,
  promptFiles,
  agentFiles,
  skillFiles,
  onUpdateTask,
  onRemoveTask,
  onEditPromptFile,
  onEditAgentFile,
  onEditSkillFile,
  width,
  toggleRight,
}: PropertiesPanelProps) {
  return (
    <>
      <button
        className="panel-collapse-toggle"
        style={{ right: toggleRight }}
        onClick={onToggleCollapse}
        title={collapsed ? 'Show properties' : 'Hide properties'}
      >
        <svg width="16" height="16" viewBox="0 0 16 16" fill="none">
          {collapsed ? (
            <path d="M10 3L5 8L10 13" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
          ) : (
            <path d="M6 3L11 8L6 13" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" />
          )}
        </svg>
      </button>

      {!collapsed && (
        <div className="properties-panel" style={{ width }}>
          <div className="panel-tabs">
            <button
              className={`panel-tab ${activeTab === 'workflow' ? 'panel-tab--active' : ''}`}
              onClick={() => onTabChange('workflow')}
            >
              Workflow
            </button>
            <button
              className={`panel-tab ${activeTab === 'tasks' ? 'panel-tab--active' : ''}`}
              onClick={() => onTabChange('tasks')}
            >
              Tasks
            </button>
          </div>

          <div className="panel-body">
            {activeTab === 'workflow' && (
              <WorkflowFields
                manifest={manifest}
                onUpdate={onUpdateManifest}
                agentFiles={agentFiles}
                skillFiles={skillFiles}
                onEditAgentFile={onEditAgentFile}
                onEditSkillFile={onEditSkillFile}
              />
            )}
            {activeTab === 'tasks' && (
              selectedTask ? (
                <TaskFields
                  task={selectedTask}
                  allTaskNames={allTaskNames}
                  promptFiles={promptFiles}
                  onUpdate={onUpdateTask}
                  onRemove={onRemoveTask}
                  onEditPromptFile={onEditPromptFile}
                />
              ) : (
                <div className="panel-empty-state">
                  Select a task on the canvas to edit its properties
                </div>
              )
            )}
          </div>
        </div>
      )}
    </>
  );
}

/* ── Tooltip ── */

function FieldTooltip({ text }: { text: string }) {
  const [visible, setVisible] = useState(false);
  const [pos, setPos] = useState<{ top: number; right: number }>({ top: 8, right: 8 });
  const iconRef = useRef<HTMLButtonElement>(null);
  const popupRef = useRef<HTMLDivElement>(null);
  const tooltipId = useRef(`tooltip-${Math.random().toString(36).slice(2)}`);

  const updatePosition = useCallback(() => {
    if (!iconRef.current || !popupRef.current) return;
    const padding = 8;
    const gap = 6;
    const iconRect = iconRef.current.getBoundingClientRect();
    const popupRect = popupRef.current.getBoundingClientRect();

    const preferredTop = iconRect.top - popupRect.height - gap;
    const top = Math.min(Math.max(preferredTop, padding), Math.max(padding, window.innerHeight - popupRect.height - padding));

    const preferredRight = window.innerWidth - iconRect.right;
    const right = Math.min(Math.max(preferredRight, padding), Math.max(padding, window.innerWidth - popupRect.width - padding));

    setPos({ top, right });
  }, []);

  useEffect(() => {
    if (!visible) return;
    updatePosition();
    window.addEventListener('resize', updatePosition);
    window.addEventListener('scroll', updatePosition, true);
    return () => {
      window.removeEventListener('resize', updatePosition);
      window.removeEventListener('scroll', updatePosition, true);
    };
  }, [visible, updatePosition]);

  const show = () => setVisible(true);
  const hide = () => setVisible(false);

  return (
    <span className="field-tooltip">
      <button
        type="button"
        className="field-tooltip-icon"
        ref={iconRef}
        aria-label="Help"
        aria-describedby={visible ? tooltipId.current : undefined}
        onMouseEnter={show}
        onMouseLeave={hide}
        onFocus={show}
        onBlur={hide}
        onKeyDown={(e) => e.key === 'Escape' && hide()}
        onClick={(e) => e.stopPropagation()}
      >
        ?
      </button>
      {visible && createPortal(
        <div
          id={tooltipId.current}
          role="tooltip"
          ref={popupRef}
          className="field-tooltip-popup"
          style={{ top: pos.top, right: pos.right }}
        >
          {text}
        </div>,
        document.body
      )}
    </span>
  );
}

/* ── YAML field helper ── */

function YamlField({
  label,
  value,
  onChange,
  placeholder,
  tooltip,
}: {
  label: string;
  value: unknown;
  onChange: (parsed: unknown) => void;
  placeholder?: string;
  tooltip?: string;
}) {
  const serialize = (v: unknown) =>
    v && Object.keys(v as object).length > 0
      ? YAML.stringify(v, { indent: 2, lineWidth: 80 }).trimEnd()
      : '';
  const [text, setText] = useState(() => serialize(value));
  const [parseError, setParseError] = useState<string | null>(null);
  const prevSerializedRef = useRef(serialize(value));

  // Re-sync local text when external value changes
  useEffect(() => {
    const newSerialized = serialize(value);
    if (newSerialized !== prevSerializedRef.current) {
      prevSerializedRef.current = newSerialized;
      setText(newSerialized);
      setParseError(null);
    }
  }, [value]);

  const handleBlur = () => {
    if (!text.trim()) {
      setParseError(null);
      onChange(undefined);
      return;
    }
    try {
      const parsed = YAML.parse(text);
      setParseError(null);
      onChange(parsed);
    } catch (err: unknown) {
      setParseError((err as Error).message);
    }
  };

  return (
    <div className="field-group">
      <label className="field-label">
        {label}
        {tooltip && <FieldTooltip text={tooltip} />}
      </label>
      <textarea
        className="field-textarea field-yaml"
        value={text}
        onChange={(e) => setText(e.target.value)}
        onBlur={handleBlur}
        rows={Math.max(4, text.split('\n').length + 1)}
        spellCheck={false}
        placeholder={placeholder}
      />
      {parseError && (
        <div className="field-hint" style={{ color: 'var(--color-error)' }}>
          YAML error: {parseError}
        </div>
      )}
    </div>
  );
}

/* ── MCP Args field helper (blur-based JSON parsing) ── */

function McpArgsField({
  value,
  onChange,
}: {
  value: Record<string, unknown> | undefined;
  onChange: (parsed: Record<string, unknown> | undefined) => void;
}) {
  const serialize = (v: Record<string, unknown> | undefined) =>
    v ? JSON.stringify(v, null, 2) : '';
  const [text, setText] = useState(() => serialize(value));
  const [parseError, setParseError] = useState<string | null>(null);
  const prevRef = useRef(serialize(value));

  useEffect(() => {
    const s = serialize(value);
    if (s !== prevRef.current) {
      prevRef.current = s;
      setText(s);
      setParseError(null);
    }
  }, [value]);

  const handleBlur = () => {
    if (!text.trim()) {
      setParseError(null);
      onChange(undefined);
      return;
    }
    try {
      const parsed = JSON.parse(text);
      setParseError(null);
      onChange(parsed);
    } catch (err: unknown) {
      setParseError((err as Error).message);
    }
  };

  return (
    <div className="field-group">
      <label className="field-label">
        MCP Args (JSON)
        <FieldTooltip text="JSON arguments passed to the MCP tool. Must match the tool's expected input schema." />
      </label>
      <textarea
        className="field-textarea field-yaml"
        value={text}
        onChange={(e) => setText(e.target.value)}
        onBlur={handleBlur}
        rows={Math.max(3, text.split('\n').length + 1)}
        spellCheck={false}
        placeholder='{"input_file": "workflow.yaml"}'
      />
      {parseError && (
        <div className="field-hint" style={{ color: 'var(--color-error)' }}>
          JSON error: {parseError}
        </div>
      )}
    </div>
  );
}

/* ── Workflow fields ── */

function WorkflowFields({
  manifest,
  onUpdate,
  agentFiles,
  skillFiles,
  onEditAgentFile,
  onEditSkillFile,
}: {
  manifest: WorkflowManifest;
  onUpdate: (updates: Partial<WorkflowManifest>) => void;
  agentFiles: string[];
  skillFiles: string[];
  onEditAgentFile: (agentName: string | null) => void;
  onEditSkillFile: (skillName: string | null) => void;
}) {
  return (
    <>
      {/* ── Required fields ── */}
      <div className="field-group">
        <label className="field-label field-required">
          Name
          <FieldTooltip text="Machine-readable identifier for this workflow. Used in file names and references. No spaces." />
        </label>
        <input
          className="field-input"
          value={manifest.name}
          onChange={(e) => onUpdate({ name: e.target.value })}
        />
      </div>

      <div className="field-group">
        <label className="field-label field-required">
          Version
          <FieldTooltip text="Semantic version string, e.g. 1.0.0. Increment on each release." />
        </label>
        <input
          className="field-input"
          value={manifest.version}
          onChange={(e) => onUpdate({ version: e.target.value })}
        />
      </div>

      <div className="field-group">
        <label className="field-label field-required">
          Description
          <FieldTooltip text="Human-readable summary shown in the workflow browser and marketplace." />
        </label>
        <textarea
          className="field-textarea"
          value={manifest.description}
          onChange={(e) => onUpdate({ description: e.target.value })}
          rows={3}
        />
      </div>

      <div className="field-group">
        <label className="field-label field-required">
          Min dotbot Version
          <FieldTooltip text="Minimum dotbot version required to run this workflow, e.g. 0.9.0." />
        </label>
        <input
          className="field-input"
          value={manifest.min_dotbot_version}
          onChange={(e) => onUpdate({ min_dotbot_version: e.target.value })}
        />
      </div>

      {/* ── Recipe fields (rich editing) ── */}
      <div className="field-group">
        <div className="field-label-row">
          <label className="field-label">
            Agents
            <FieldTooltip text="AI personas (system prompts) injected into the model's context for every task in this workflow." />
          </label>
          <div className="field-actions">
            <button
              className="field-action-btn"
              title="Edit first selected agent"
              onClick={() => {
                const first = (manifest.agents || []).find((a) => agentFiles.includes(a));
                onEditAgentFile(first || null);
              }}
              disabled={(manifest.agents || []).length === 0}
            >
              Edit
            </button>
            <button
              className="field-action-btn"
              title="Create new agent"
              onClick={() => onEditAgentFile(null)}
            >
              New
            </button>
          </div>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
          {agentFiles.map((name) => (
            <label key={name} className="field-checkbox">
              <input
                type="checkbox"
                checked={(manifest.agents || []).includes(name)}
                onChange={(e) => {
                  const current = manifest.agents || [];
                  const updated = e.target.checked
                    ? [...current, name]
                    : current.filter((a) => a !== name);
                  onUpdate({ agents: updated.length > 0 ? updated : undefined });
                }}
              />
              {name}
            </label>
          ))}
          {agentFiles.length === 0 && (
            <div className="field-hint">No agents found. Click New to create one.</div>
          )}
        </div>
      </div>

      <div className="field-group">
        <div className="field-label-row">
          <label className="field-label">
            Skills
            <FieldTooltip text="Reusable technical guidance documents injected into task prompts as additional context." />
          </label>
          <div className="field-actions">
            <button
              className="field-action-btn"
              title="Edit first selected skill"
              onClick={() => {
                const first = (manifest.skills || []).find((s) => skillFiles.includes(s));
                onEditSkillFile(first || null);
              }}
              disabled={(manifest.skills || []).length === 0}
            >
              Edit
            </button>
            <button
              className="field-action-btn"
              title="Create new skill"
              onClick={() => onEditSkillFile(null)}
            >
              New
            </button>
          </div>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
          {skillFiles.map((name) => (
            <label key={name} className="field-checkbox">
              <input
                type="checkbox"
                checked={(manifest.skills || []).includes(name)}
                onChange={(e) => {
                  const current = manifest.skills || [];
                  const updated = e.target.checked
                    ? [...current, name]
                    : current.filter((s) => s !== name);
                  onUpdate({ skills: updated.length > 0 ? updated : undefined });
                }}
              />
              {name}
            </label>
          ))}
          {skillFiles.length === 0 && (
            <div className="field-hint">No skills found. Click New to create one.</div>
          )}
        </div>
      </div>

      {/* ── Optional fields ── */}
      <div className="field-group">
        <label className="field-label">
          Rerun Strategy
          <FieldTooltip text="How to handle re-running a previously run workflow. Default inherits project settings. Fresh deletes prior outputs and starts clean. Continue resumes from the last completed task." />
        </label>
        <select
          className="field-select"
          value={manifest.rerun || ''}
          onChange={(e) =>
            onUpdate({ rerun: (e.target.value || undefined) as 'fresh' | 'continue' | undefined })
          }
        >
          <option value="">Default</option>
          <option value="fresh">Fresh</option>
          <option value="continue">Continue</option>
        </select>
      </div>

      <div className="field-group">
        <label className="field-label">
          Icon
          <FieldTooltip text="Icon name from the dotbot icon set, e.g. terminal or search. Displayed in the workflow browser." />
        </label>
        <input
          className="field-input"
          value={manifest.icon || ''}
          onChange={(e) => onUpdate({ icon: e.target.value || undefined })}
          placeholder="e.g., terminal, search"
        />
      </div>

      <div className="field-group">
        <label className="field-label">
          License
          <FieldTooltip text="SPDX license identifier, e.g. MIT or Apache-2.0. Shown in the marketplace." />
        </label>
        <input
          className="field-input"
          value={manifest.license || ''}
          onChange={(e) => onUpdate({ license: e.target.value || undefined })}
          placeholder="e.g., MIT"
        />
      </div>

      <div className="field-group">
        <label className="field-label">
          Tags
          <FieldTooltip text="Free-form labels for filtering and discovery in the workflow browser. Comma-separated." />
        </label>
        <input
          className="field-input"
          value={(manifest.tags || []).join(', ')}
          onChange={(e) =>
            onUpdate({
              tags: e.target.value
                .split(',')
                .map((t) => t.trim())
                .filter(Boolean),
            })
          }
          placeholder="core, framework"
        />
        <div className="field-hint">Comma-separated</div>
      </div>

      <div className="field-group">
        <label className="field-label">
          Categories
          <FieldTooltip text="Structured classifications for the marketplace browser, e.g. Development, AI. Comma-separated." />
        </label>
        <input
          className="field-input"
          value={(manifest.categories || []).join(', ')}
          onChange={(e) =>
            onUpdate({
              categories: e.target.value
                .split(',')
                .map((t) => t.trim())
                .filter(Boolean),
            })
          }
          placeholder="Development, AI"
        />
        <div className="field-hint">Comma-separated</div>
      </div>

      <div className="field-group">
        <label className="field-label">
          Author Name
          <FieldTooltip text="Display name of the workflow's author." />
        </label>
        <input
          className="field-input"
          value={manifest.author?.name || ''}
          onChange={(e) =>
            onUpdate({
              author: { ...manifest.author, name: e.target.value, url: manifest.author?.url },
            })
          }
        />
      </div>

      <div className="field-group">
        <label className="field-label">
          Author URL
          <FieldTooltip text="URL for the author's profile, GitHub page, or website." />
        </label>
        <input
          className="field-input"
          value={manifest.author?.url || ''}
          onChange={(e) =>
            onUpdate({
              author: { name: manifest.author?.name || '', url: e.target.value || undefined },
            })
          }
        />
      </div>

      <div className="field-group">
        <label className="field-label">
          Repository
          <FieldTooltip text="URL of the source repository for this workflow." />
        </label>
        <input
          className="field-input"
          value={manifest.repository || ''}
          onChange={(e) => onUpdate({ repository: e.target.value || undefined })}
          placeholder="https://github.com/..."
        />
      </div>

      <div className="field-group">
        <label className="field-label">
          Homepage
          <FieldTooltip text="URL to documentation or a project website for this workflow." />
        </label>
        <input
          className="field-input"
          value={manifest.homepage || ''}
          onChange={(e) => onUpdate({ homepage: e.target.value || undefined })}
        />
      </div>

      {/* ── Advanced YAML fields ── */}
      <YamlField
        label="Requires"
        tooltip="YAML block declaring environment variables, tool dependencies, or other prerequisites that must be satisfied before the workflow runs."
        value={manifest.requires}
        onChange={(parsed) => onUpdate({ requires: parsed as WorkflowManifest['requires'] })}
        placeholder="env_vars:\n  - var: MY_KEY\n    name: My API Key\n    message: Required\n    hint: Set in .env.local"
      />

      <YamlField
        label="Form"
        tooltip="YAML block defining user-selectable modes or pre-run form fields presented to the user when the workflow starts."
        value={manifest.form}
        onChange={(parsed) => onUpdate({ form: parsed as WorkflowManifest['form'] })}
        placeholder="modes:\n  - id: default\n    label: Default Mode"
      />

      <YamlField
        label="Domain"
        tooltip="YAML block defining task categories and domain-specific vocabulary used for task classification and analysis."
        value={manifest.domain}
        onChange={(parsed) => onUpdate({ domain: parsed as WorkflowManifest['domain'] })}
        placeholder="task_categories:\n  - research\n  - implementation"
      />
    </>
  );
}

/* ── Task fields ── */

function TaskFields({
  task,
  allTaskNames,
  promptFiles,
  onUpdate,
  onRemove,
  onEditPromptFile,
}: {
  task: Task;
  allTaskNames: string[];
  promptFiles: string[];
  onUpdate: (updates: Partial<Task>) => void;
  onRemove: () => void;
  onEditPromptFile: (filename: string | null) => void;
}) {
  const otherTasks = allTaskNames.filter((n) => n !== task.name);

  return (
    <>
      {/* ── Type (read-only, always first) ── */}
      <div className="field-group">
        <label className="field-label field-required">
          Type
          <FieldTooltip text="The execution model for this task. Determines which fields are available. Cannot be changed after creation — delete and re-add to change type." />
        </label>
        <div className="task-type-badge" style={{ borderColor: TASK_TYPE_STYLES[task.type]?.color }}>
          <span className="toolbar-dropdown-dot" style={{ background: TASK_TYPE_STYLES[task.type]?.color }} />
          {TASK_TYPE_STYLES[task.type]?.label || task.type}
        </div>
        <div className="field-hint">To change type, delete this task and add a new one</div>
      </div>

      {/* ── Required fields ── */}
      <div className="field-group">
        <label className="field-label field-required">
          Name
          <FieldTooltip text="Unique identifier for this task within the workflow. Used in depends_on references. No spaces." />
        </label>
        <input
          className="field-input"
          value={task.name}
          onChange={(e) => onUpdate({ name: e.target.value })}
        />
      </div>

      <div className="field-group">
        <label className="field-label field-required">
          Priority
          <FieldTooltip text="Execution order hint. Lower numbers run first when tasks have no direct dependencies between them." />
        </label>
        <input
          className="field-input"
          type="number"
          value={task.priority}
          onChange={(e) => onUpdate({ priority: parseInt(e.target.value) || 0 })}
        />
      </div>

      {/* Prompt File — recipe field with rich editing */}
      {hasField(task.type, 'workflow') && (
        <div className="field-group">
          <div className="field-label-row">
            <label className="field-label field-required">
              Prompt File
              <FieldTooltip text="The Markdown prompt document that drives this task's AI invocation. Defines the instructions given to the model." />
            </label>
            <div className="field-actions">
              <button
                className="field-action-btn"
                title="Edit prompt file"
                onClick={() => onEditPromptFile(task.workflow || null)}
                disabled={!task.workflow}
              >
                Edit
              </button>
              <button
                className="field-action-btn"
                title="Create new prompt file"
                onClick={() => onEditPromptFile(null)}
              >
                New
              </button>
            </div>
          </div>
          <select
            className="field-select"
            value={task.workflow || ''}
            onChange={(e) => onUpdate({ workflow: e.target.value || undefined })}
          >
            <option value="">-- Select --</option>
            {promptFiles
              .filter((f) => f.endsWith('.md'))
              .map((f) => (
                <option key={f} value={f}>{f}</option>
              ))}
          </select>
        </div>
      )}

      {/* Script — plain text */}
      {hasField(task.type, 'script') && (
        <div className="field-group">
          <label className="field-label field-required">
            Script
            <FieldTooltip text="PowerShell script filename to execute, relative to .bot/scripts/. E.g. expand-task-groups.ps1." />
          </label>
          <input
            className="field-input"
            value={task.script || ''}
            onChange={(e) => onUpdate({ script: e.target.value || undefined })}
            placeholder="e.g., expand-task-groups.ps1"
          />
        </div>
      )}

      {/* MCP — plain text */}
      {hasField(task.type, 'mcp_tool') && (
        <>
          <div className="field-group">
            <label className="field-label field-required">
              MCP Tool
              <FieldTooltip text="Name of the MCP (Model Context Protocol) tool to invoke. E.g. bs_yaml_aggregate." />
            </label>
            <input
              className="field-input"
              value={task.mcp_tool || ''}
              onChange={(e) => onUpdate({ mcp_tool: e.target.value || undefined })}
              placeholder="e.g., bs_yaml_aggregate"
            />
          </div>
          <McpArgsField
            value={task.mcp_args}
            onChange={(parsed) => onUpdate({ mcp_args: parsed })}
          />
        </>
      )}

      {/* ── Optional fields ── */}

      <div className="field-group">
        <label className="field-label">
          Depends On
          <FieldTooltip text="Tasks that must complete successfully before this task can start. You can also drag edges between nodes on the canvas." />
        </label>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
          {otherTasks.map((name) => (
            <label key={name} className="field-checkbox">
              <input
                type="checkbox"
                checked={(task.depends_on || []).includes(name)}
                onChange={(e) => {
                  const current = task.depends_on || [];
                  const updated = e.target.checked
                    ? [...current, name]
                    : current.filter((d) => d !== name);
                  onUpdate({ depends_on: updated.length > 0 ? updated : undefined });
                }}
              />
              {name}
            </label>
          ))}
        </div>
        <div className="field-hint">Or drag edges on the canvas</div>
      </div>

      <div className="field-group">
        <label className="field-label">
          Condition
          <FieldTooltip text="File-existence glob pattern that gates this task. The task is skipped if the pattern doesn't match any files. Prefix with ! to skip when the file exists." />
        </label>
        <input
          className="field-input"
          value={task.condition || ''}
          onChange={(e) => onUpdate({ condition: e.target.value || undefined })}
          placeholder="e.g., .git/refs/heads/*"
        />
        <div className="field-hint">File-existence condition (prefix ! to negate)</div>
      </div>

      <div className="field-group">
        <label className="field-checkbox">
          <input
            type="checkbox"
            checked={task.optional ?? false}
            onChange={(e) => onUpdate({ optional: e.target.checked || undefined })}
          />
          Optional
          <FieldTooltip text="When checked, a failure in this task will not block dependent tasks or halt the workflow." />
        </label>
      </div>

      <div className="field-group">
        <label className="field-label">
          On Failure
          <FieldTooltip text="What happens when this task fails. Default follows workflow settings. Halt stops the entire workflow. Continue skips this task and proceeds to the next." />
        </label>
        <select
          className="field-select"
          value={task.on_failure || ''}
          onChange={(e) =>
            onUpdate({ on_failure: (e.target.value || undefined) as 'halt' | 'continue' | undefined })
          }
        >
          <option value="">Default</option>
          <option value="halt">Halt</option>
          <option value="continue">Continue</option>
        </select>
      </div>

      {hasField(task.type, 'outputs') && (
        <div className="field-group">
          <label className="field-label">
            Outputs
            <FieldTooltip text="Filenames this task is expected to produce. The runtime verifies these files exist after the task completes." />
          </label>
          <input
            className="field-input"
            value={(task.outputs || []).join(', ')}
            onChange={(e) =>
              onUpdate({
                outputs: e.target.value
                  .split(',')
                  .map((s) => s.trim())
                  .filter(Boolean),
              })
            }
            placeholder="product.md, roadmap.md"
          />
          <div className="field-hint">Comma-separated output filenames</div>
        </div>
      )}

      {hasField(task.type, 'outputs_dir') && (
        <>
          <div className="field-group">
            <label className="field-label">
              Outputs Dir
              <FieldTooltip text="Directory where this task writes multiple output files. Used together with Min Output Count to verify completion." />
            </label>
            <input
              className="field-input"
              value={task.outputs_dir || ''}
              onChange={(e) => onUpdate({ outputs_dir: e.target.value || undefined })}
              placeholder="e.g., tasks/todo"
            />
          </div>

          {task.outputs_dir && hasField(task.type, 'min_output_count') && (
            <div className="field-group">
              <label className="field-label">
                Min Output Count
                <FieldTooltip text="Minimum number of files that must exist in Outputs Dir after this task completes. The task fails if fewer files are found." />
              </label>
              <input
                className="field-input"
                type="number"
                value={task.min_output_count ?? ''}
                onChange={(e) =>
                  onUpdate({ min_output_count: e.target.value ? parseInt(e.target.value) : undefined })
                }
              />
            </div>
          )}
        </>
      )}

      {hasField(task.type, 'front_matter_docs') && (
        <div className="field-group">
          <label className="field-label">
            Front Matter Docs
            <FieldTooltip text="Markdown files whose YAML front matter is extracted and injected into the task prompt as structured context." />
          </label>
          <input
            className="field-input"
            value={(task.front_matter_docs || []).join(', ')}
            onChange={(e) =>
              onUpdate({
                front_matter_docs: e.target.value
                  .split(',')
                  .map((s) => s.trim())
                  .filter(Boolean),
              })
            }
            placeholder="mission.md, tech-stack.md"
          />
          <div className="field-hint">Comma-separated doc filenames for front matter injection</div>
        </div>
      )}

      {hasField(task.type, 'commit') && (
        <>
          <div className="field-group">
            <label className="field-label">
              Commit Paths
              <FieldTooltip text="File paths staged and committed to git after this task completes successfully. Comma-separated glob patterns." />
            </label>
            <input
              className="field-input"
              value={(task.commit?.paths || []).join(', ')}
              onChange={(e) => {
                const paths = e.target.value.split(',').map((s) => s.trim()).filter(Boolean);
                if (paths.length > 0 || task.commit?.message) {
                  onUpdate({ commit: { paths, message: task.commit?.message || '' } });
                } else {
                  onUpdate({ commit: undefined });
                }
              }}
              placeholder="workspace/product/, workspace/tasks/"
            />
          </div>

          <div className="field-group">
            <label className="field-label">
              Commit Message
              <FieldTooltip text="Git commit message used when auto-committing this task's outputs." />
            </label>
            <input
              className="field-input"
              value={task.commit?.message || ''}
              onChange={(e) => {
                if (e.target.value || (task.commit?.paths?.length ?? 0) > 0) {
                  onUpdate({ commit: { paths: task.commit?.paths || [], message: e.target.value } });
                } else {
                  onUpdate({ commit: undefined });
                }
              }}
              placeholder="chore(kickstart): ..."
            />
          </div>
        </>
      )}

      {/* Post Script — plain text */}
      {hasField(task.type, 'post_script') && (
        <div className="field-group">
          <label className="field-label">
            Post Script
            <FieldTooltip text="PowerShell script run after the task completes. Used for post-processing, cleanup, or side effects." />
          </label>
          <input
            className="field-input"
            value={task.post_script || ''}
            onChange={(e) => onUpdate({ post_script: e.target.value || undefined })}
            placeholder="e.g., post-phase-task-groups.ps1"
          />
        </div>
      )}

      {hasField(task.type, 'model') && (
        <div className="field-group">
          <label className="field-label">
            Model Override
            <FieldTooltip text="Model ID to use for this task instead of the project default. E.g. claude-opus-4-6 or gpt-4o. Leave blank to use the default." />
          </label>
          <input
            className="field-input"
            value={task.model || ''}
            onChange={(e) => onUpdate({ model: e.target.value || undefined })}
            placeholder="Leave blank for default"
          />
        </div>
      )}

      <div style={{ marginTop: 24, paddingTop: 16, borderTop: '1px solid var(--bezel-edge)' }}>
        <button
          className="toolbar-btn toolbar-btn--danger"
          onClick={onRemove}
          style={{ width: '100%', justifyContent: 'center' }}
        >
          Delete Task
        </button>
      </div>
    </>
  );
}
