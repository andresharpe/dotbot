/**
 * TypeScript types matching the dotbot workflow.yaml schema.
 * Derived from all 4 existing workflows: default, kickstart-from-scratch,
 * kickstart-via-jira, kickstart-via-pr.
 */

export interface WorkflowManifest {
  name: string;
  version: string;
  description: string;
  icon?: string;
  license?: string;
  tags?: string[];
  categories?: string[];
  repository?: string;
  homepage?: string;
  min_dotbot_version: string;
  author?: WorkflowAuthor;
  rerun?: 'fresh' | 'continue';
  agents?: string[];
  skills?: string[];
  requires?: WorkflowRequires;
  form?: WorkflowForm;
  domain?: Record<string, unknown>;
  tasks: Task[];
}

export interface WorkflowAuthor {
  name: string;
  url?: string;
}

export interface WorkflowRequires {
  env_vars?: EnvVarRequirement[];
  mcp_servers?: NamedRequirement[];
  cli_tools?: NamedRequirement[];
}

export interface EnvVarRequirement {
  var: string;
  name: string;
  message: string;
  hint: string;
}

export interface NamedRequirement {
  name: string;
  message: string;
  hint: string;
}

export interface WorkflowForm {
  description?: string;
  interview_label?: string;
  interview_hint?: string;
  prompt_placeholder?: string;
  modes?: FormMode[];
}

export interface FormMode {
  id: string;
  condition?: string | string[];
  label?: string;
  description?: string;
  button?: string;
  prompt_placeholder?: string;
  show_interview?: boolean;
  show_files?: boolean;
  hidden?: boolean;
}

export type TaskType = 'prompt' | 'script' | 'mcp' | 'task_gen' | 'prompt_template' | 'barrier';

export interface TaskCommit {
  paths: string[];
  message: string;
}

export interface Task {
  name: string;
  type: TaskType;
  workflow?: string;
  script?: string;
  mcp_tool?: string;
  mcp_args?: Record<string, unknown>;
  depends_on?: string[];
  condition?: string;
  optional?: boolean;
  outputs?: string[];
  outputs_dir?: string;
  min_output_count?: number;
  front_matter_docs?: string[];
  commit?: TaskCommit;
  priority: number;
  on_failure?: 'halt' | 'continue';
  post_script?: string;
  model?: string;
}

/** Summary returned when listing workflows */
export interface WorkflowSummary {
  folder: string;
  name: string;
  description: string;
  version: string;
  taskCount: number;
}

/** Layout data stored in sidecar file */
export interface WorkflowLayout {
  positions: Record<string, { x: number; y: number }>;
}

/** Create a blank workflow manifest */
export function createEmptyManifest(name: string): WorkflowManifest {
  return {
    name,
    version: '1.0.0',
    description: '',
    min_dotbot_version: '3.5.0',
    requires: {},
    tasks: [],
  };
}

/** Create a blank task of a specific type */
export function createEmptyTask(name: string, priority: number, type: TaskType = 'prompt'): Task {
  return {
    name,
    type,
    priority,
  };
}
