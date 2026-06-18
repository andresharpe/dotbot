# Azure AD App Registration Management
# Controls whether Terraform creates/manages the Azure AD app or uses existing one

variable "create_azuread_app" {
  description = "Create new Azure AD app registration (true) or use existing (false)"
  type        = bool
  default     = true
}

variable "azuread_app_name" {
  description = "Display name for Azure AD app"
  type        = string
  default     = "Dotbot"
}

# Create new Azure AD app registration
resource "azuread_application" "bot_app" {
  count        = var.create_azuread_app ? 1 : 0
  display_name = var.azuread_app_name

  # Required for bot framework - SingleTenant
  sign_in_audience = "AzureADMyOrg"

  # Microsoft Graph - User.Read.All + Mail.Send (Application)
  required_resource_access {
    resource_app_id = "00000003-0000-0000-c000-000000000000" # Microsoft Graph

    resource_access {
      id   = "df021288-bdef-4463-88db-98f22de89214" # User.Read.All (Application)
      type = "Role"
    }

    resource_access {
      id   = "b633e1c5-b582-4048-a93e-9f11b44c7e96" # Mail.Send (Application)
      type = "Role"
    }

    resource_access {
      id   = "74ef0291-ca83-4d02-8c7e-d2391e6a444f" # TeamsAppInstallation.ReadWriteForUser.All (Application)
      type = "Role"
    }

    resource_access {
      id   = "dc149144-f292-421e-b185-5953f2e98d7f" # AppCatalog.ReadWrite.All (Application)
      type = "Role"
    }
  }
}

# Add redirect URIs separately to avoid cycle with web app
resource "azuread_application_redirect_uris" "bot_app" {
  count          = var.create_azuread_app ? 1 : 0
  application_id = azuread_application.bot_app[0].id
  type           = "Web"

  redirect_uris = [
    "https://${azurerm_linux_web_app.bot.default_hostname}/api/messages"
  ]
}

# Create app secret
resource "azuread_application_password" "bot_app" {
  count          = var.create_azuread_app ? 1 : 0
  application_id = azuread_application.bot_app[0].id
  display_name   = "Terraform Managed - ${formatdate("YYYY-MM-DD", timestamp())}"
  end_date_relative = "8760h" # 1 year
  # Increment this value to trigger password rotation
  rotate_when_changed = {
    rotation = "1"
  }
}

# Service principal for the app
resource "azuread_service_principal" "bot_app" {
  count    = var.create_azuread_app ? 1 : 0
  client_id = azuread_application.bot_app[0].client_id
  app_role_assignment_required = false

  tags = ["WindowsAzureActiveDirectoryIntegratedApp", "Terraform"]
}

# Microsoft Graph service principal (for granting app role assignments)
data "azuread_service_principal" "msgraph" {
  client_id = "00000003-0000-0000-c000-000000000000" # Microsoft Graph
}

# Grant admin consent for User.Read.All (Application)
resource "azuread_app_role_assignment" "user_read_all" {
  count               = var.create_azuread_app ? 1 : 0
  app_role_id         = "df021288-bdef-4463-88db-98f22de89214" # User.Read.All
  principal_object_id = azuread_service_principal.bot_app[0].object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

# Grant admin consent for Mail.Send (Application)
resource "azuread_app_role_assignment" "mail_send" {
  count               = var.create_azuread_app ? 1 : 0
  app_role_id         = "b633e1c5-b582-4048-a93e-9f11b44c7e96" # Mail.Send
  principal_object_id = azuread_service_principal.bot_app[0].object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

# Grant admin consent for TeamsAppInstallation.ReadWriteForUser.All (Application)
resource "azuread_app_role_assignment" "teams_app_install" {
  count               = var.create_azuread_app ? 1 : 0
  app_role_id         = "74ef0291-ca83-4d02-8c7e-d2391e6a444f" # TeamsAppInstallation.ReadWriteForUser.All
  principal_object_id = azuread_service_principal.bot_app[0].object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

# Grant admin consent for AppCatalog.ReadWrite.All (Application)
resource "azuread_app_role_assignment" "app_catalog_readwrite" {
  count               = var.create_azuread_app ? 1 : 0
  app_role_id         = "dc149144-f292-421e-b185-5953f2e98d7f" # AppCatalog.ReadWrite.All
  principal_object_id = azuread_service_principal.bot_app[0].object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

# Get existing app when not creating new one
data "azuread_application" "bot" {
  count     = var.create_azuread_app ? 0 : 1
  client_id = var.microsoft_app_id
}

# Use either created or existing app credentials
locals {
  bot_app_id       = var.create_azuread_app ? azuread_application.bot_app[0].client_id : var.microsoft_app_id
  bot_app_password = var.create_azuread_app ? azuread_application_password.bot_app[0].value : var.microsoft_app_password
}

# Generate Teams app manifest
resource "local_file" "teams_manifest" {
  count    = var.create_azuread_app ? 1 : 0
  filename = "${path.module}/../teams-app/manifest.json"

  content = jsonencode({
    "$schema"       = "https://developer.microsoft.com/json-schemas/teams/v1.17/MicrosoftTeams.schema.json"
    manifestVersion = "1.17"
    version         = "1.0.${formatdate("YYYYMMDDhhmm", timestamp())}"
    id              = local.bot_app_id
    developer = {
      name          = var.developer_name
      websiteUrl    = var.developer_website_url
      privacyUrl    = var.developer_privacy_url
      termsOfUseUrl = var.developer_terms_url
    }
    name = {
      short = "Dotbot"
      full  = "Dotbot Question Bot"
    }
    description = {
      short = "Multi-choice question bot for development workflows"
      full  = "Dotbot sends multi-choice questions to users via Teams and collects answers for the dotbot development workflow tool."
    }
    icons = {
      outline = "outline.png"
      color   = "color.png"
    }
    accentColor = "#FFFFFF"
    bots = [
      {
        botId              = local.bot_app_id
        scopes             = ["personal"]
        supportsFiles      = false
        isNotificationOnly = false
      }
    ]
    permissions  = ["messageTeamMembers"]
    validDomains = [azurerm_linux_web_app.bot.default_hostname]
  })

  depends_on = [
    azuread_application.bot_app
  ]
}
