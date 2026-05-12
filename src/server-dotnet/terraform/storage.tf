# Azure Storage Account for persistent bot state
# Stores conversation references and question answers as blobs

resource "azurerm_storage_account" "dotbot" {
  name                     = "st${var.app_name}${var.environment}01"
  resource_group_name      = azurerm_resource_group.dotbot.name
  location                 = azurerm_resource_group.dotbot.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version               = "TLS1_2"
  allow_nested_items_to_be_public = false
  tags                           = local.tags
}

# RBAC: App Service Managed Identity → Storage Blob Data Contributor
resource "azurerm_role_assignment" "app_blob_contributor" {
  scope                = azurerm_storage_account.dotbot.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_linux_web_app.bot.identity[0].principal_id
}

resource "azurerm_storage_container" "conversation_references" {
  name                  = "conversation-references"
  storage_account_id    = azurerm_storage_account.dotbot.id
  container_access_type = "private"
}

resource "azurerm_storage_container" "answers" {
  name                  = "answers"
  storage_account_id    = azurerm_storage_account.dotbot.id
  container_access_type = "private"
}
