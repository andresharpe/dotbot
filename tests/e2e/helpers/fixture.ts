import * as fs from "node:fs";
import * as path from "node:path";
import { randomUUID } from "node:crypto";

const botDir = process.env.DOTBOT_E2E_BOT_DIR;
if (!botDir) {
  throw new Error(
    "DOTBOT_E2E_BOT_DIR not set. Layer 5 specs must be launched via tests/Test-UI-E2E.ps1.",
  );
}

export const BOT_DIR = botDir;
export const TASKS_DIR = path.join(BOT_DIR, "workspace", "tasks");
// The UI server's StateBuilder._Get-TasksGrouped walks only
// `workspace/tasks/standalone/` and `workspace/tasks/workflow-runs/<run>/`
// and groups task files by the `status` field inside the JSON. Status-named
// subdirectories (todo/, in-progress/, etc.) are no longer scanned. Seed
// every fixture under `standalone/` and toggle status by rewriting the
// file content.
export const STANDALONE_TASKS_DIR = path.join(TASKS_DIR, "standalone");
export const PROCESSES_DIR = path.join(BOT_DIR, ".control", "processes");

export type TaskStatus =
  | "todo"
  | "needs-input"
  | "in-progress"
  | "needs-review"
  | "done"
  | "failed"
  | "skipped"
  | "cancelled";

export interface SeededTask {
  id: string;
  shortId: string;
  filePath: string;
  status: TaskStatus;
}

function _IsoTimestamp(): string {
  return new Date().toISOString().replace(/\.\d+Z$/, "Z");
}

export function seedTask(
  status: TaskStatus,
  overrides: Record<string, unknown> = {},
): SeededTask {
  const id = (overrides.id as string) ?? randomUUID();
  const shortId = id.slice(0, 8);
  const name = (overrides.name as string) ?? `e2e-${shortId}`;

  const now = _IsoTimestamp();
  // Match the closed TaskInstance schema (src/runtime/Modules/Dotbot.Task/Private/TaskInstance.psm1):
  // required fields are id, name, status, provenance, created_at, updated_at,
  // completed_at, updated_by, extensions. The reader (`_Read-FlatTask` in
  // StateBuilder.psm1) is tolerant of missing top-level fields, but the
  // `provenance` block exists so the reader can surface `workflow` correctly
  // and so any future schema-asserting code path does not reject the fixture.
  const task = {
    schema_version: 2,
    id,
    name,
    description: `E2E fixture task ${shortId}`,
    category: "feature",
    status,
    priority: 50,
    effort: "S",
    created_at: now,
    updated_at: now,
    completed_at: null,
    updated_by: "e2e-fixture",
    // Standalone (ad-hoc) tasks have all-null provenance per the schema's
    // all-or-nothing rule. Tests that need a workflow-bound task can pass
    // a full provenance object via overrides.
    provenance: {
      workflow: null,
      run_id: null,
      definition_name: null,
      expanded_by: null,
    },
    extensions: {},
    ...overrides,
  };

  fs.mkdirSync(STANDALONE_TASKS_DIR, { recursive: true });
  const filePath = path.join(STANDALONE_TASKS_DIR, `${name}-${shortId}.json`);
  fs.writeFileSync(filePath, JSON.stringify(task, null, 2), "utf8");
  return { id, shortId, filePath, status };
}

export function moveTask(task: SeededTask, newStatus: TaskStatus): SeededTask {
  // v4 keeps tasks in a single directory per bucket (standalone or one of
  // workflow-runs/<run>/) and toggles status by rewriting the `status` field
  // in place. Renaming across status subdirectories is the v3 model and no
  // longer matches what the UI server scans.
  const content = JSON.parse(fs.readFileSync(task.filePath, "utf8"));
  content.status = newStatus;
  content.updated_at = _IsoTimestamp();
  fs.writeFileSync(task.filePath, JSON.stringify(content, null, 2), "utf8");
  return { ...task, status: newStatus };
}

export function removeTask(task: SeededTask): void {
  if (fs.existsSync(task.filePath)) {
    fs.unlinkSync(task.filePath);
  }
}

export interface SeededProcess {
  id: string;
  filePath: string;
}

export function seedProcess(
  overrides: Record<string, unknown> = {},
): SeededProcess {
  const id = (overrides.id as string) ?? `e2e-${randomUUID().slice(0, 8)}`;
  const proc = {
    id,
    type: "execution",
    status: "running",
    // Server's Get-Process aliveness check (ProcessAPI.psm1) flips any
    // process with a dead PID to 'stopped' on the next poll. Use the
    // test runner's own PID so the row stays in its declared status.
    pid: process.pid,
    started_at: new Date().toISOString().replace(/\.\d+Z$/, "Z"),
    last_heartbeat: new Date().toISOString().replace(/\.\d+Z$/, "Z"),
    description: `E2E fixture process ${id}`,
    workflow: "start-from-prompt",
    ...overrides,
  };

  fs.mkdirSync(PROCESSES_DIR, { recursive: true });
  const filePath = path.join(PROCESSES_DIR, `proc-${id}.json`);
  fs.writeFileSync(filePath, JSON.stringify(proc, null, 2), "utf8");
  return { id, filePath };
}

export function seedActivityEvent(
  type: string,
  fields: Record<string, unknown> = {},
): string {
  // Get-ActivityTail (ControlAPI.psm1) streams raw JSONL lines from
  // .control/activity.jsonl — appending a line is all it takes for the
  // event to reach /api/activity/tail and the polling loop.
  const id = `evt_${randomUUID().slice(0, 8)}`;
  const event = {
    id,
    type,
    timestamp: _IsoTimestamp(),
    source: "e2e",
    ...fields,
  };
  const controlDir = path.join(BOT_DIR, ".control");
  fs.mkdirSync(controlDir, { recursive: true });
  fs.appendFileSync(
    path.join(controlDir, "activity.jsonl"),
    JSON.stringify(event) + "\n",
    "utf8",
  );
  return id;
}

export function removeProcess(proc: SeededProcess): void {
  if (fs.existsSync(proc.filePath)) {
    fs.unlinkSync(proc.filePath);
  }
}
