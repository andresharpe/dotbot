# Research Output Quality Standard

This standard applies to all research artifacts produced by research-category tasks. Research outputs are written to `.bot/workspace/product/briefing/` and serve as the evidence base for all downstream planning, implementation, and decision-making.

## Structure Requirements

1. **Title and metadata** — every research document must start with a clear title and context section identifying the initiative, scope, and date of research.

2. **Executive summary** — a concise (5-10 sentence) summary of key findings, status, and recommended actions. A reader should understand the essentials without reading the full document.

3. **Mandatory sections** — each research methodology defines required sections. All must be present. If a section has no findings, explicitly state "No evidence found" or "Not applicable" — do not omit the section.

4. **Tables over prose** — use tables for inventories, comparisons, and structured data. Prose should be reserved for analysis, synthesis, and recommendations.

## Evidence Standards

1. **No assumptions** — every claim must cite a source: Jira ticket key, Confluence page title, file path, class name, URL, or other verifiable reference.

2. **Source attribution** — use inline citations. For Jira: ticket key (e.g., `PROJ-1234`). For Confluence: page title. For code: `repo/path/to/file.cs:L42`. For web: full URL.

3. **Missing evidence** — if expected information is not found, explicitly state: "No evidence found for [topic]." Do not silently omit gaps.

4. **Contradictions** — if sources conflict, document both positions with their sources and flag the contradiction for resolution.

5. **Recency** — prefer the most recent information. When citing dated sources, include the date.

## Privacy

1. **No absolute file system paths** — never include paths like `C:\Users\...`, `/home/...`, or `/Users/...`. These trigger the pre-commit privacy scan and leak local environment details.

2. **No credentials** — no API keys, tokens, passwords, or connection strings in research output.

3. **Relative paths only** — when referencing local files, use paths relative to the project root (e.g., `repos/MyRepo/src/Program.cs` not `/c/Users/dev/repos/MyRepo/src/Program.cs`).

4. **Repo references by name** — reference repositories by name (e.g., "the OrderService repo"), not by full clone path.

## Quality Checks

1. **Completeness** — all methodology-required sections are present and populated (or explicitly marked as empty with reason).

2. **No placeholders** — no `{{VARIABLE}}` template markers, no `TODO`, no `TBD` in the final output. If a value could not be resolved, use `<!-- UNRESOLVED: reason -->`.

3. **No speculation** — distinguish fact from inference. Use language like "Based on [evidence], it appears that..." rather than "The system probably..."

4. **No emojis** — research documents are formal artifacts. No emojis anywhere.

5. **Neutral tone** — analytical, not promotional or alarmist. Present findings objectively.

6. **Actionable recommendations** — the "Recommended Next Actions" or equivalent section must contain concrete, specific actions — not vague suggestions.

## Format Standards

1. **Markdown** — all research outputs are Markdown files.

2. **Heading hierarchy** — use `#` for document title, `##` for major sections, `###` for subsections. Do not skip levels.

3. **Tables** — use GitHub-flavored Markdown tables. Include header row and alignment.

4. **Code references** — use backtick formatting for file paths, class names, method names, and code snippets.

5. **Line length** — no hard wrapping. Let the renderer handle line breaks.

6. **File naming** — follow the naming convention specified by the research methodology (e.g., `research-documents.md`, `repos/OrderService.md`).
