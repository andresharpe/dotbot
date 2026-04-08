terraform {
  required_version = ">= 1.6"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 2.47"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "azuread" {
}

# Get current session context (tenant ID, subscription, etc.)
data "azurerm_client_config" "current" {}

# Add Created_On_Date tag to defaults
locals {
  tags = merge(
    var.tags,
    {
      Created_On_Date = timestamp()
    }
  )
  tenant_id        = data.azurerm_client_config.current.tenant_id
  bot_service_name = "we-${var.app_name}-bot-${var.environment}-01"
}

# Resource Group
resource "azurerm_resource_group" "dotbot" {
  name     = var.resource_group_name
  location = var.location
  tags     = local.tags
}

# App Service Plan (B1 tier, Linux)
resource "azurerm_service_plan" "dotbot" {
  name                = "we-${var.app_name}-${var.environment}-plan-01"
  location            = azurerm_resource_group.dotbot.location
  resource_group_name = azurerm_resource_group.dotbot.name
  os_type             = "Linux"
  sku_name            = var.app_service_plan_sku
  tags                = local.tags
}

# App Service (Bot API)
resource "azurerm_linux_web_app" "bot" {
  name                = "we-${var.app_name}-bot-${var.environment}-01"
  location            = azurerm_resource_group.dotbot.location
  resource_group_name = azurerm_resource_group.dotbot.name
  service_plan_id     = azurerm_service_plan.dotbot.id
  https_only          = true
  tags                = local.tags

  identity {
    type = "SystemAssigned"
  }

  site_config {
    always_on                         = true
    health_check_path                 = "/api/health"
    health_check_eviction_time_in_min = 5

    application_stack {
      dotnet_version = "9.0"
    }
  }

  app_settings = {
    MicrosoftAppType     = "SingleTenant"
    MicrosoftAppId       = local.bot_app_id
    MicrosoftAppPassword = local.bot_app_password
    MicrosoftAppTenantId = local.tenant_id

    # M365 Agents SDK - Token validation
    "TokenValidation__Audiences__0" = local.bot_app_id
    "TokenValidation__TenantId"     = local.tenant_id

    # M365 Agents SDK - MSAL auth connection
    "Connections__ServiceConnection__Assembly"                = "Microsoft.Agents.Authentication.Msal"
    "Connections__ServiceConnection__Type"                    = "MsalAuth"
    "Connections__ServiceConnection__Settings__AuthType"      = "ClientSecret"
    "Connections__ServiceConnection__Settings__AuthorityEndpoint" = "https://login.microsoftonline.com/${local.tenant_id}"
    "Connections__ServiceConnection__Settings__ClientId"      = local.bot_app_id
    "Connections__ServiceConnection__Settings__ClientSecret"  = local.bot_app_password
    "Connections__ServiceConnection__Settings__Scopes__0"     = "https://api.botframework.com/.default"

    # API key for /api/notify and /api/answers
    "ApiSecurity__ApiKey" = var.api_key

    # Blob storage for persistent state (Managed Identity)
    "Environment__Name"         = var.environment
    "State__ContainerName"      = "answers"
    "BlobStorage__AccountUri"   = "https://${azurerm_storage_account.dotbot.name}.blob.core.windows.net"

    # Key Vault for JWT signing
    "Auth__KeyVaultUri"             = azurerm_key_vault.dotbot.vault_uri
    "Auth__KeyName"                 = azurerm_key_vault_key.jwt_signing.name
    "Auth__JwtIssuer"               = "dotbot"
    "Auth__JwtAudience"             = "dotbot-respond"
    "Auth__MagicLinkExpiryMinutes"  = var.magic_link_expiry_minutes
    "Auth__DeviceTokenExpiryDays"   = var.device_token_expiry_days

    # Delivery channels
    "DeliveryChannels__Email__Enabled"          = var.email_enabled
    "DeliveryChannels__Email__SenderAddress"     = var.email_sender_address
    "DeliveryChannels__Email__SenderDisplayName" = var.email_sender_display_name
    "DeliveryChannels__Jira__Enabled"            = var.jira_enabled
    "DeliveryChannels__Jira__BaseUrl"            = var.jira_base_url
    "DeliveryChannels__Jira__Username"           = var.jira_username
    "DeliveryChannels__Jira__ApiToken"           = var.jira_api_token

    # Teams proactive install
    "Teams__ServiceUrl" = var.teams_service_url
    "Teams__TeamsAppId" = var.teams_catalog_app_id

    # Reminder/escalation settings
    "Reminders__DefaultReminderAfterHours" = var.reminder_after_hours
    "Reminders__DefaultEscalateAfterDays"  = var.escalate_after_days
    "Reminders__IntervalMinutes"           = var.reminder_interval_minutes

    # Application Insights
    "APPLICATIONINSIGHTS_CONNECTION_STRING" = azurerm_application_insights.dotbot.connection_string
  }
}
