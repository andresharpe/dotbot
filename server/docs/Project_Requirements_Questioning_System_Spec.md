# Project Requirements Questioning System

## Functional & Technical Specification

### Version 1.0

------------------------------------------------------------------------

# 1. Executive Summary

This system enables structured, auditable collection of architectural
and project requirement decisions from designated stakeholders via
proactive messaging channels (Microsoft Teams, Email, Jira).

The platform:

-   Sends structured A/B/C-style decision questions
-   Supports verbose option descriptions
-   Allows optional free-text justification
-   Sends automated reminders and escalations
-   Stores immutable responses in Azure Blob Storage
-   Uses lightweight infrastructure (Blob-native, no SQL/Redis)
-   Uses secure magic-link authentication with 90-day device tokens

------------------------------------------------------------------------

# 2. Architecture Overview

## 2.1 Core Components

  Component            Purpose
  -------------------- --------------------------------------------
  ASP.NET Core API     Orchestration, token handling, blob access
  Azure Blob Storage   Primary persistence
  Microsoft Graph      Teams + Email delivery
  Jira REST API        Optional Jira delivery
  Azure Key Vault      JWT signing keys
  Azure App Service    Hosting
  Managed Identity     Secure resource access

No relational database required. No Redis required.

------------------------------------------------------------------------

# 3. Design Principles

1.  Immutable question templates
2.  Immutable responses
3.  Separation of template vs delivery instance
4.  GUID-based identity
5.  Blob prefix partitioning
6.  Pluggable delivery channels
7.  Minimal infrastructure
8.  Secure but low-friction authentication

------------------------------------------------------------------------

# 4. Data Model

## 4.1 Question Definition (Template)

### Blob Path

    {env}/projects/{projectId}/questions/{questionId}/v{version}.json

### Schema

-   questionId (GUID)
-   code (string)
-   version (int)
-   type (singleChoice \| multiChoice \| etc.)
-   title
-   description
-   context
-   options\[\]
-   responseSettings
-   deliveryDefaults
-   project metadata
-   status
-   createdAt
-   createdBy

Options include:

-   optionId (GUID)
-   key (A/B/C)
-   title
-   summary
-   details (pros/cons/risk/etc.)
-   isRecommended

------------------------------------------------------------------------

## 4.2 Question Instance

Represents a delivery occurrence.

### Blob Path

    {env}/projects/{projectId}/instances/{instanceId}.json

Tracks:

-   instanceId (GUID)
-   questionId
-   questionVersion
-   sentTo\[\]
-   deliveryOverrides
-   overallStatus
-   timestamps

------------------------------------------------------------------------

## 4.3 Response

Immutable submission record.

### Blob Path

    {env}/projects/{projectId}/questions/{questionId}/instances/{instanceId}/responses/{responseId}.json

Includes:

-   responseId (GUID)
-   selectedOptionId
-   selectedKey
-   freeText
-   responderEmail
-   submittedAt
-   status

------------------------------------------------------------------------

# 5. Authentication Model

## 5.1 Magic Link

Short-lived JWT (15 minutes).

Claims:

-   email
-   questionInstanceId
-   jti
-   exp

Stored as blob under:

    {env}/tokens/jti/{jti}.json

Marked as used on first validation.

## 5.2 Persistent Device Token

After validation:

-   90-day token
-   Stored as HttpOnly secure cookie
-   Backed by blob storage

Path:

    {env}/tokens/devices/{deviceTokenId}.json

------------------------------------------------------------------------

# 6. Delivery Channels

Delivery abstraction:

interface IQuestionDeliveryProvider

Implementations:

-   TeamsDeliveryProvider
-   EmailDeliveryProvider
-   JiraDeliveryProvider

## Teams

-   Microsoft Graph application permissions
-   Adaptive Card
-   Deep link to magic link URL

## Email

-   Graph sendMail or SendGrid
-   Structured email template

## Jira

-   POST comment to issue
-   Include markdown + link

------------------------------------------------------------------------

# 7. Reminder & Escalation

Implemented via ASP.NET Core BackgroundService (no Quartz).

Runs hourly.

## Reminder Logic

If:

-   No response
-   Now \> sentAt + reminderAfterHours

Then:

-   Send reminder
-   Update instance status

## Escalation Logic

If:

-   No response
-   Now \> sentAt + escalateAfterDays

Then:

-   Notify project owner
-   Notify backup role
-   Update instance to escalated

------------------------------------------------------------------------

# 8. API Surface

POST /questions\
POST /questions/{id}/publish\
POST /instances\
POST /respond\
POST /tokens/revoke

------------------------------------------------------------------------

# 9. Security Controls

-   Managed Identity for Blob
-   Key Vault for JWT signing
-   Secure cookies (HttpOnly, Secure, SameSite=Lax)
-   Replay protection via jti tracking
-   Audit logging via App Insights

------------------------------------------------------------------------

# 10. Scalability

Scales due to:

-   Blob prefix partitioning
-   Immutable writes
-   Stateless API
-   No database contention
-   Background job processing

------------------------------------------------------------------------

# 11. Future Extensions

-   Governance dashboard
-   ADR export
-   Cognitive Search indexing
-   Weighted approvals
-   Conditional branching questions

------------------------------------------------------------------------

# 12. Conclusion

This system provides:

-   Lightweight architecture
-   Enterprise-ready governance
-   Channel flexibility
-   Secure authentication
-   Blob-native scalability

Designed for simplicity today and extensibility tomorrow.
