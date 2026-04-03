# Research Methodology: Deep Internet Research

## Objective: Generate `research-internet.md`

You are a Research AI Agent. For internet research, use Claude's **built-in tools** — these are always available and do NOT require ToolSearch:
- **`WebSearch`** — search the web for information and get results with URLs
- **`WebFetch`** — fetch and extract content from specific URLs

Do NOT use ToolSearch to find web research tools. WebSearch and WebFetch are built-in Claude tools, not MCP tools.

All dotbot task management tools were loaded in Phase 0. You should not need any additional ToolSearch calls during this research — use built-in tools for research and the already-loaded dotbot tools for task management.

Your task is to conduct comprehensive internet research covering business context, regulatory requirements, alternative products/approaches, and technical documentation for the project.

You must produce a structured research report saved as:

`.bot/workspace/product/research-internet.md`

This document must contain only verified, publicly available information and clearly distinguish facts from interpretation.

You are strictly prohibited from using emojis in the report.

## Project Context

Read `.bot/workspace/product/product.md` for all project context including:
- **Project Name** — the primary research subject
- **Executive Summary** — what the project aims to achieve
- **Problem Statement** — the business need driving this project
- **Goals & Success Criteria** — measurable outcomes
- **High-Level Approach** — technology direction and architecture

Also read `.bot/workspace/product/interview-summary.md` (if it exists) for clarified requirements from the user interview.

Use this context to scope and focus the research — do not research topics unrelated to the project's domain.

---

# Research Objectives

Your research must aim to:

- Improve strategic understanding of the project domain
- Identify industry best practices
- Identify regulatory or compliance considerations
- Identify architectural or technical patterns
- Identify common failure patterns
- Identify comparable case studies
- Identify relevant vendors, tools, frameworks, or standards
- Identify emerging risks or market shifts
- Identify measurable benchmarks or performance indicators

Do not generate speculative content. Base findings only on credible public sources.

---

# Required Research Areas

## 1. Industry Context

- Market landscape
- Industry maturity
- Key players
- Competitive dynamics
- Market trends
- Technology adoption patterns

If applicable:
- Market size
- Growth rate
- Disruption signals

---

## 2. Comparable Initiatives or Case Studies

Identify public examples of similar initiatives, projects, or transformations.

For each case:
- Organization name
- Initiative objective
- Approach taken
- Outcome (success, partial success, failure)
- Publicly cited lessons learned
- Timeline (if available)

Highlight patterns across multiple cases.

---

## 3. Technical Landscape

Identify relevant:

- Architectural patterns
- Design frameworks
- Implementation strategies
- Platform choices
- Integration patterns
- Security models
- Scalability considerations

If applicable:
- Open standards
- Reference architectures
- Regulatory technical constraints

---

## 4. Risk Landscape

Identify common risks such initiatives face:

- Technical risks
- Delivery risks
- Organizational risks
- Regulatory risks
- Vendor risks
- Budget or timeline risks

For each risk category:
- Provide examples from public cases
- Describe impact patterns
- Describe mitigation approaches used successfully

---

## 5. Regulatory and Compliance Context

If applicable to the project domain, research:

- Relevant laws
- Industry standards
- Compliance requirements
- Certification frameworks
- Data protection implications
- Cross-border considerations

Indicate jurisdiction when applicable.

---

## 6. Best Practices and Proven Approaches

Extract common best practices from:

- Industry publications
- Whitepapers
- Official documentation
- Engineering blogs
- Conference materials
- Government publications

Highlight recurring patterns across multiple independent sources.

---

## 7. Tools, Vendors, and Ecosystem

Identify:

- Commonly used platforms
- Market-leading tools
- Open-source alternatives
- Emerging vendors
- Ecosystem maturity

Do not provide promotional language. Maintain neutral analysis.

---

# Source Quality Standards

Prioritize:

- Official documentation
- Academic publications
- Government sources
- Recognized industry analysts
- Major engineering publications
- Reputable technology blogs

Avoid:

- Marketing-only materials
- Unverified opinion blogs
- AI-generated content without citations
- Low-credibility sources

Cite sources clearly in the report.

---

# Output Structure

The generated file must follow this structure:

# Internet Research Report

## 1. Executive Summary

- Key insights
- Strategic implications
- Major opportunities
- Major risks
- Confidence level in findings

---

## 2. Industry Overview

---

## 3. Comparable Case Studies

---

## 4. Technical Landscape Analysis

---

## 5. Risk Analysis

---

## 6. Regulatory and Compliance Overview

---

## 7. Best Practices and Patterns

---

## 8. Tools and Ecosystem Overview

---

## 9. Strategic Implications for the Project

Clearly connect findings back to the project's likely needs.

---

## 10. Open Questions Requiring Further Validation

Identify uncertainties or areas requiring internal clarification.

---

# Context Management

To avoid context window exhaustion during research:
- **Summarize immediately**: After reading any web page or search results, extract key facts into bullet points. Do NOT retain raw HTML output in your working context.
- **Use agents for bulk reads**: When processing multiple large web pages, spawn sub-agents to summarize each one independently.
- **Write incrementally**: Build the output file section-by-section. Write completed sections to disk before moving to the next research area.

---

# Research Standards

- Do not assume internal knowledge.
- Clearly distinguish fact from inference.
- Avoid speculation.
- Do not fabricate sources.
- If information is unavailable, explicitly state: "No reliable public information found."
- Maintain neutral, analytical tone.
- Do not use emojis anywhere in the document.
- When citing monetary amounts in non-USD currencies, always include an approximate USD equivalent in parentheses (e.g., "PKR 500,000 (~USD 1,800)"). State the exchange rate and date used in the report header.

---

# Deliverable

Output must be a single Markdown file:

`.bot/workspace/product/research-internet.md`

The document must be well-structured, analytical, evidence-based, and suitable for strategic decision-making.
