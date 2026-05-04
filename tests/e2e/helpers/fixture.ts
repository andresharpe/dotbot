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
export const PROCESSES_DIR = path.join(BOT_DIR, ".control", "processes");

export type TaskStatus =
  | "todo"
  | "analysing"
  | "analysed"
  | "needs-input"
  | "in-progress"
  | "done"
  | "skipped"
  | "cancelled"
  | "split";

export interface SeededTask {
  id: string;
  shortId: string;
  filePath: string;
  status: TaskStatus;
}

export function seedTask(
  status: TaskStatus,
  overrides: Record<string, unknown> = {},
): SeededTask {
  const id = (overrides.id as string) ?? randomUUID();
  const shortId = id.slice(0, 8);
  const name = (overrides.name as string) ?? `e2e-${shortId}`;

  const task = {
    id,
    name,
    description: `E2E fixture task ${shortId}`,
    category: "feature",
    status,
    priority: 50,
    effort: "S",
    created_at: new Date().toISOString().replace(/\.\d+Z$/, "Z"),
    workflow: "start-from-prompt",
    ...overrides,
  };

  const dir = path.join(TASKS_DIR, status);
  fs.mkdirSync(dir, { recursive: true });
  const filePath = path.join(dir, `${name}-${shortId}.json`);
  fs.writeFileSync(filePath, JSON.stringify(task, null, 2), "utf8");
  return { id, shortId, filePath, status };
}

export function moveTask(task: SeededTask, newStatus: TaskStatus): SeededTask {
  const targetDir = path.join(TASKS_DIR, newStatus);
  fs.mkdirSync(targetDir, { recursive: true });
  const newPath = path.join(targetDir, path.basename(task.filePath));
  fs.renameSync(task.filePath, newPath);
  return { ...task, filePath: newPath, status: newStatus };
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

export function removeProcess(proc: SeededProcess): void {
  if (fs.existsSync(proc.filePath)) {
    fs.unlinkSync(proc.filePath);
  }
}
