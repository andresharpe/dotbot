variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
  # Required — set in terraform.tfvars
}

variable "environment" {
  description = "Environment name"
  type        = string
  default     = "test"
}

variable "location" {
  description = "Azure region"
  type        = string
  default     = "westeurope"
}

variable "app_name" {
  description = "Application name"
  type        = string
  default     = "dotbot"
}

variable "resource_group_name" {
  description = "Resource group name"
  type        = string
  default     = "RG_WE_APPS_DOTBOT_TEST"
}

variable "app_service_plan_sku" {
  description = "App Service Plan SKU"
  type        = string
  default     = "B1"
}

# API key for /api/notify and /api/answers endpoints
variable "api_key" {
  description = "Shared API key for authenticating callers to the notify/answers endpoints"
  type        = string
  sensitive   = true
}

# Application secrets (provided via terraform.tfvars)
variable "microsoft_app_id" {
  description = "Microsoft Bot Framework App ID (set by Terraform if create_azuread_app = true)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "microsoft_app_password" {
  description = "Microsoft Bot Framework App Password (set by Terraform if create_azuread_app = true)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "bot_sku" {
  description = "Bot Service SKU (F0 or S1)"
  type        = string
  default     = "F0"
}

# --- Auth / Magic Link ---
variable "magic_link_expiry_minutes" {
  description = "Magic link token expiry in minutes"
  type        = number
  default     = 43200
}

variable "device_token_expiry_days" {
  description = "Device token expiry in days"
  type        = number
  default     = 90
}

# --- Email delivery channel ---
variable "email_enabled" {
  description = "Enable email delivery channel"
  type        = bool
  default     = false
}

variable "email_sender_address" {
  description = "Email sender address (Graph sendMail)"
  type        = string
  default     = ""
}

variable "email_sender_display_name" {
  description = "Email sender display name"
  type        = string
  default     = "Dotbot"
}

# --- Jira delivery channel ---
variable "jira_enabled" {
  description = "Enable Jira delivery channel"
  type        = bool
  default     = false
}

variable "jira_base_url" {
  description = "Jira instance base URL"
  type        = string
  default     = ""
}

variable "jira_username" {
  description = "Jira service account username"
  type        = string
  default     = ""
}

variable "jira_api_token" {
  description = "Jira API token"
  type        = string
  default     = ""
  sensitive   = true
}

# --- Reminder / escalation ---
variable "reminder_after_hours" {
  description = "Default hours before sending a reminder"
  type        = number
  default     = 24
}

variable "escalate_after_days" {
  description = "Default days before escalating"
  type        = number
  default     = 3
}

variable "reminder_interval_minutes" {
  description = "How often the reminder service runs (minutes)"
  type        = number
  default     = 60
}

# --- Teams proactive install ---
variable "teams_service_url" {
  description = "Teams Bot Framework service URL (region-specific)"
  type        = string
  default     = "https://smba.trafficmanager.net/emea/"
}

variable "teams_catalog_app_id" {
  description = "Teams app catalog ID (assigned by org-wide catalog, NOT the Azure AD client ID)"
  type        = string
  default     = "cfa7e7da-6bc3-4c6e-a2c6-84c22933020b"
}

variable "log_analytics_sku" {
  description = "Log Analytics Workspace SKU"
  type        = string
  default     = "PerGB2018"
}

variable "developer_name" {
  description = "Developer/organisation name for Teams app manifest"
  type        = string
  default     = "Dotbot"
}

variable "developer_website_url" {
  description = "Developer website URL for Teams app manifest"
  type        = string
  default     = ""
}

variable "developer_privacy_url" {
  description = "Developer privacy policy URL for Teams app manifest"
  type        = string
  default     = ""
}

variable "developer_terms_url" {
  description = "Developer terms of use URL for Teams app manifest"
  type        = string
  default     = ""
}

variable "tags" {
  description = "Resource tags"
  type        = map(string)
  # Set Application_Owner and System_Owner in terraform.tfvars
  default = {
    Application          = "Dotbot"
    Application_Owner    = ""
    Application_Type     = "PaaS"
    Business_Criticality = "NoBC"
    DR_Tag               = "NoDR"
    Data_Classification  = "Internal"
    Deployed_By          = "Infra_terraform"
    Environment          = "TEST"
    Incident_Severity    = "n/a"
    Managed_By           = ""
    Purpose              = "Teams_Bot_PoC"
    SLA_Tier             = "NoSLA"
    Status               = "PoC"
    System_Owner         = ""
    Take_On_Stream       = "MP"
  }
}
