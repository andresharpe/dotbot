output "resource_group_name" {
  description = "Resource group name"
  value       = azurerm_resource_group.dotbot.name
}

output "bot_url" {
  description = "Bot App Service URL"
  value       = "https://${azurerm_linux_web_app.bot.default_hostname}"
}

output "bot_messaging_endpoint" {
  description = "Bot messaging endpoint"
  value       = "https://${azurerm_linux_web_app.bot.default_hostname}/api/messages"
}

output "azuread_app_id" {
  description = "Azure AD Application (Client) ID"
  value       = local.bot_app_id
  sensitive   = true
}

output "azuread_app_password" {
  description = "Azure AD Application Secret (Password)"
  value       = local.bot_app_password
  sensitive   = true
}

output "storage_account_name" {
  description = "Storage account name"
  value       = azurerm_storage_account.dotbot.name
}

output "key_vault_uri" {
  description = "Key Vault URI"
  value       = azurerm_key_vault.dotbot.vault_uri
}

output "managed_identity_principal_id" {
  description = "App Service Managed Identity principal ID"
  value       = azurerm_linux_web_app.bot.identity[0].principal_id
}

output "application_insights_connection_string" {
  description = "Application Insights connection string"
  value       = azurerm_application_insights.dotbot.connection_string
  sensitive   = true
}

output "application_insights_instrumentation_key" {
  description = "Application Insights instrumentation key"
  value       = azurerm_application_insights.dotbot.instrumentation_key
  sensitive   = true
}
