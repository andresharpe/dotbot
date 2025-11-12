# Confirm Audit Trail Workflow

**Agent:** @.bot/agents/product-planner.md

This workflow verifies that the audit trail was properly created for the planning session.

## Purpose

Ensures compliance with the workflow interaction standard by confirming that:
- All questions and responses were logged
- Audit trail file exists in `.bot/audit/workflows/`
- Session metadata is complete
- No critical information was missed

## Prerequisites

- Completed planning workflow (gather-product-info)
- User responses collected
- Session ID generated

## Reference Standard

See `.bot/standards/global/workflow-interaction.md` section 10 for full audit trail requirements.

## Steps

### 1. Verify Audit Directory Exists

Check that `.bot/audit/workflows/plan-product/` directory exists:
- If not exists: Create directory structure
- If exists: Proceed to validation

### 2. Validate Audit File

Confirm audit trail file was created at:
```
.bot/audit/workflows/plan-product/[timestamp]-session.json
```

### 3. Check Required Fields

Verify the audit record contains all required fields:

```json
{
  "session_id": "unique-identifier",
  "workflow_name": "plan-product",
  "started_at": "ISO-8601-timestamp",
  "completed_at": "ISO-8601-timestamp or null",
  "status": "completed|abandoned|errored",
  "questions": [
    {
      "question_number": 1,
      "total_questions": 4,
      "type": "multiple_choice|open_ended|clarification",
      "topic": "Topic Name",
      "question_text": "Full question as presented",
      "options": [...],
      "user_response": "Response text",
      "response_timestamp": "ISO-8601-timestamp",
      "response_time_seconds": 45
    }
  ],
  "metadata": {
    "user_id": "identifier or 'anonymous'",
    "warp_session_id": "warp-context-if-available",
    "environment": "dev|staging|prod",
    "client_version": "agent-version"
  },
  "exit_reason": "completed|user_exit|error|abandoned",
  "error_details": null
}
```

### 4. Validate Completeness

Ensure all questions from the workflow were logged:
- Question 1: Product Vision (open-ended)
- Question 2: Product Concept (multiple choice)
- Question 3: Key Features (multiple choice)
- Question 4: Tech Stack (multiple choice)
- Final Review (multiple choice)

### 5. Verify Timestamps

Check that:
- `started_at` timestamp is present
- `completed_at` timestamp is present (if workflow completed)
- Each question has `response_timestamp`
- `response_time_seconds` is calculated for each response

### 6. Confirm Session Status

Validate the session status matches reality:
- **completed**: All questions answered, user proceeded
- **abandoned**: User exited mid-workflow
- **errored**: Technical error occurred
- **user_exit**: User explicitly exited

### 7. Generate Audit Summary

Create a brief summary for user (optional, if verbose mode):

```
✓ Audit Trail Confirmed

Session ID: [session-id]
Questions Logged: 4/4
Duration: [X] minutes
Status: Completed
File: .bot/audit/workflows/plan-product/[timestamp]-session.json
```

## Error Handling

If audit trail is missing or incomplete:

### Missing Audit File
1. Log warning (don't block workflow)
2. Attempt to create retroactive audit record
3. Mark as `partial_recovery` in metadata
4. Note the gap in audit log

### Incomplete Audit Data
1. Identify missing fields
2. Fill in what's recoverable from context
3. Mark incomplete fields as `null` or `"not_recorded"`
4. Log discrepancy for review

### Failed Audit Creation
1. Log error to system (not user-facing)
2. Continue with workflow (don't block user)
3. Create error report in `.bot/audit/errors/`
4. Alert for manual review if critical

## Validation Checklist

Before marking audit as complete, verify:

- [ ] Audit directory exists
- [ ] Session file created with unique name
- [ ] `session_id` is unique and valid
- [ ] `workflow_name` matches "plan-product"
- [ ] `started_at` timestamp present
- [ ] `completed_at` timestamp present (if done)
- [ ] `status` field is valid enum value
- [ ] All 4 main questions logged
- [ ] Each question has required fields
- [ ] Response timestamps recorded
- [ ] Response time calculated for each
- [ ] Metadata section complete
- [ ] `exit_reason` field present
- [ ] File is valid JSON
- [ ] File permissions are correct

## Post-Confirmation Actions

After successful audit confirmation:
1. Mark workflow as fully complete
2. Allow user to proceed to next phase
3. Store audit file path for reference
4. Update session log index (if exists)

## Tips

- **Silent operation**: Don't show this to user unless error occurs
- **Non-blocking**: Never prevent workflow from continuing due to audit issues
- **Atomic writes**: Use temp file + rename pattern to avoid corruption
- **Privacy**: Don't log sensitive data (secrets, passwords, PII)
- **Retention**: Consider audit log rotation policies
- **Analytics**: Use audit data to improve workflow UX
- **Debugging**: Invaluable for troubleshooting user issues

## Output

- Validated audit trail file in `.bot/audit/workflows/plan-product/`
- Optional summary output if errors detected
- Internal logging of audit status

## Integration

This workflow runs automatically after:
- `gather-product-info.md` completes
- `create-product-mission.md` completes
- `create-product-roadmap.md` completes
- `create-product-tech-stack.md` completes

Each workflow should have its own audit trail, and this confirmation runs for each.
