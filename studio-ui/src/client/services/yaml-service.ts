/**
 * Client-side YAML parsing, serialization, and validation for workflow manifests.
 * Uses the `yaml` npm package (v2).
 */
import YAML from 'yaml';
import type { WorkflowManifest } from '../model/workflow';

/**
 * Parse a workflow.yaml string into a WorkflowManifest.
 */
export function parseWorkflowYaml(content: string): WorkflowManifest {
  const doc = YAML.parse(content) as WorkflowManifest;
  if (!doc) {
    throw new Error('Empty or invalid YAML document');
  }
  return doc;
}

/**
 * Serialize a WorkflowManifest back to YAML string.
 */
export function serializeWorkflowYaml(manifest: WorkflowManifest): string {
  return YAML.stringify(manifest, {
    indent: 2,
    lineWidth: 120,
    defaultStringType: 'PLAIN',
    defaultKeyType: 'PLAIN',
    nullStr: '',
  });
}

export interface ValidationError {
  field: string;
  message: string;
}

/**
 * Validate a workflow manifest against dotbot's constraints.
 */
export function validateManifest(manifest: WorkflowManifest): ValidationError[] {
  const errors: ValidationError[] = [];

  if (!manifest.name?.trim()) {
    errors.push({ field: 'name', message: 'Workflow name is required' });
  }
  if (!manifest.version?.trim()) {
    errors.push({ field: 'version', message: 'Version is required' });
  }
  if (!manifest.min_dotbot_version?.trim()) {
    errors.push({ field: 'min_dotbot_version', message: 'Minimum dotbot version is required' });
  }

  if (!manifest.tasks || manifest.tasks.length === 0) {
    errors.push({ field: 'tasks', message: 'At least one task is required' });
    return errors;
  }

  const taskNames = new Set<string>();

  for (let i = 0; i < manifest.tasks.length; i++) {
    const task = manifest.tasks[i];
    const prefix = `tasks[${i}]`;

    if (!task.name?.trim()) {
      errors.push({ field: `${prefix}.name`, message: 'Task name is required' });
    } else {
      if (taskNames.has(task.name)) {
        errors.push({ field: `${prefix}.name`, message: `Duplicate task name: '${task.name}'` });
      }
      taskNames.add(task.name);
    }

    if (task.priority == null) {
      errors.push({ field: `${prefix}.priority`, message: 'Task priority is required' });
    }

    if (task.depends_on) {
      for (const dep of task.depends_on) {
        if (!manifest.tasks.some((t) => t.name === dep)) {
          errors.push({
            field: `${prefix}.depends_on`,
            message: `Dependency '${dep}' not found in tasks`,
          });
        }
      }
    }
  }

  const priorities = manifest.tasks.map((t) => t.priority).filter((p) => p != null);
  for (let i = 1; i < priorities.length; i++) {
    if (priorities[i] < priorities[i - 1]) {
      errors.push({
        field: 'tasks',
        message: `Task priorities must be non-decreasing (priority ${priorities[i]} after ${priorities[i - 1]})`,
      });
      break;
    }
  }

  return errors;
}
