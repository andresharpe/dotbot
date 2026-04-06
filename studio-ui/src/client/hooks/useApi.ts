/**
 * Fetch wrapper for the studio backend API.
 *
 * The server is a raw file-I/O proxy — all YAML parsing, serialization,
 * and validation is handled client-side via yaml-service.ts.
 */

const BASE_URL = '/api/studio';

async function handleResponse<T>(res: Response): Promise<T> {
  if (!res.ok) {
    const body = await res.json().catch(() => ({ error: res.statusText }));
    throw new Error(body.error || body.errors?.map((e: { message: string }) => e.message).join(', ') || res.statusText);
  }
  return res.json();
}

/** Raw data returned from listing endpoint (folder name + raw YAML text) */
export interface WorkflowListItem {
  folder: string;
  yaml: string | null;
}

/** Raw data returned when loading a single workflow */
export interface WorkflowRawData {
  yaml: string | null;
  layout: string | null;
  promptFiles: string[];
  agentFiles: string[];
  skillFiles: string[];
}

/** List all available workflows (returns folder names + raw YAML) */
export async function listWorkflows(): Promise<WorkflowListItem[]> {
  const res = await fetch(BASE_URL);
  return handleResponse(res);
}

/** Load a single workflow (raw YAML + layout JSON string + prompt files) */
export async function loadWorkflow(name: string): Promise<WorkflowRawData> {
  const res = await fetch(`${BASE_URL}/${encodeURIComponent(name)}`);
  return handleResponse(res);
}

/** Save a workflow (send raw YAML string + optional layout JSON string) */
export async function saveWorkflow(
  name: string,
  yaml: string,
  layout?: string,
): Promise<void> {
  const res = await fetch(`${BASE_URL}/${encodeURIComponent(name)}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ yaml, layout }),
  });
  await handleResponse(res);
}

/** Create a new empty workflow */
export async function createWorkflow(name: string): Promise<void> {
  const res = await fetch(BASE_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ name }),
  });
  await handleResponse(res);
}

/** Copy a workflow to a new name (Save As) */
export async function copyWorkflow(sourceName: string, newName: string): Promise<void> {
  const res = await fetch(`${BASE_URL}/${encodeURIComponent(sourceName)}/copy`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ newName }),
  });
  await handleResponse(res);
}

/** Delete a workflow */
export async function deleteWorkflow(name: string): Promise<void> {
  const res = await fetch(`${BASE_URL}/${encodeURIComponent(name)}`, {
    method: 'DELETE',
  });
  await handleResponse(res);
}

/** List files in a workflow folder */
export async function listWorkflowFiles(name: string): Promise<string[]> {
  const res = await fetch(`${BASE_URL}/${encodeURIComponent(name)}/files`);
  return handleResponse(res);
}

/** Encode a file path for use in URLs (encode each segment individually) */
function encodeFilePath(filePath: string): string {
  return filePath.split('/').map(encodeURIComponent).join('/');
}

/** Read a specific file from a workflow */
export async function readWorkflowFile(name: string, filePath: string): Promise<string> {
  const res = await fetch(`${BASE_URL}/${encodeURIComponent(name)}/files/${encodeFilePath(filePath)}`);
  if (!res.ok) throw new Error(`Failed to read file: ${res.statusText}`);
  return res.text();
}

/** Write/create a file in a workflow folder */
export async function saveWorkflowFile(name: string, filePath: string, content: string): Promise<void> {
  const res = await fetch(`${BASE_URL}/${encodeURIComponent(name)}/files/${encodeFilePath(filePath)}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'text/plain; charset=utf-8' },
    body: content,
  });
  await handleResponse(res);
}

/** List prompt files in a workflow's recipes/prompts/ folder */
export async function listPromptFiles(name: string): Promise<string[]> {
  const res = await fetch(`${BASE_URL}/${encodeURIComponent(name)}`);
  const data: WorkflowRawData = await handleResponse(res);
  return data.promptFiles;
}
