# Create Project README Workflow

**Agent:** @.bot/agents/product-planner.md

This workflow creates a comprehensive README.md for new projects.

## Purpose

A good README serves as the entry point for anyone interacting with your project. It:
- Explains what the project is and why it exists
- Provides setup and installation instructions
- Documents how to use the project
- Guides contributors on how to get involved

## Prerequisites

- Project name and description
- Tech stack information
- Installation requirements
- Basic usage patterns

## When This Runs

This workflow runs automatically during project setup if no README.md exists in the project root.

## Steps

### 1. Check for Existing README

Before creating, verify if README.md already exists:
- If exists: Skip this workflow
- If not exists: Proceed with generation

### 2. Gather README Content

Use information from previous workflows:
- Product vision and mission
- Tech stack details
- Key features
- Target users

### 3. Generate README Structure

Create README.md with these sections:

## Output Template

```markdown
# [Product Name]

> [One-line description from product vision]

## Overview

[Brief description of what the product does and why it exists - 2-3 sentences]

## Problem

[Problem statement from product mission]

## Solution

[Value proposition - how this product solves the problem]

## Features

- **[Feature 1]**: [Brief description]
- **[Feature 2]**: [Brief description]
- **[Feature 3]**: [Brief description]

## Tech Stack

### Frontend
- [Technology] - [Brief rationale]

### Backend
- [Technology] - [Brief rationale]

### Database
- [Technology] - [Brief rationale]

### Infrastructure
- [Technology] - [Brief rationale]

## Getting Started

### Prerequisites

- [Requirement 1]
- [Requirement 2]

### Installation

```bash
# Clone the repository
git clone [repository-url]

# Install dependencies
[installation commands based on tech stack]
```

### Configuration

[Environment variables or config files needed]

### Running Locally

```bash
[Commands to run the project]
```

## Usage

[Basic usage examples or API endpoints]

## Development

### Project Structure

```
[Basic folder structure]
```

### Running Tests

```bash
[Test commands]
```

### Code Style

[Link to coding standards or linting commands]

## Roadmap

See [roadmap.md](.bot/product/roadmap.md) for detailed feature planning.

**Upcoming:**
- [Phase 1 highlights]
- [Phase 2 highlights]

## Contributing

[Contribution guidelines if applicable]

## License

[License information]

## Contact

[Contact or support information]
```

## Customization Based on Tech Stack

### For Web Applications
Include:
- Browser compatibility
- Deployment instructions
- Environment setup

### For APIs
Include:
- Endpoint documentation
- Authentication details
- Example requests/responses

### For Libraries/Packages
Include:
- Installation via package manager
- Import/usage examples
- API reference link

### For CLI Tools
Include:
- Installation instructions
- Command reference
- Configuration options

## Post-Generation Steps

1. **Review for completeness**: Ensure all sections are populated
2. **Add badges** (optional): Build status, coverage, version
3. **Add screenshots** (if UI): Visuals help understanding
4. **Verify links**: Ensure all referenced files exist
5. **Commit**: Add README.md to version control

## Tips

- Keep it concise but comprehensive
- Write for someone unfamiliar with the project
- Update regularly as project evolves
- Include actual examples, not placeholders
- Make setup instructions foolproof
- Link to additional documentation
- Use clear, simple language
- Test instructions on a fresh machine

## Output

Creates `README.md` in project root directory.
