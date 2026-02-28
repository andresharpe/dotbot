# Key Vault for JWT signing key and secret management
# Uses RBAC authorization (no access policies)

resource "azurerm_key_vault" "dotbot" {
  name                       = "kv-${var.app_name}-${var.environment}-01"
  location                   = azurerm_resource_group.dotbot.location
  resource_group_name        = azurerm_resource_group.dotbot.name
  tenant_id                  = local.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 90
  purge_protection_enabled   = true
  tags                       = local.tags
}

# RBAC: App Service Managed Identity → Key Vault Crypto User (sign/verify with keys)
resource "azurerm_role_assignment" "app_kv_crypto_user" {
  scope                = azurerm_key_vault.dotbot.id
  role_definition_name = "Key Vault Crypto User"
  principal_id         = azurerm_linux_web_app.bot.identity[0].principal_id
}

# RBAC: Terraform deployer → Key Vault Crypto Officer (create/manage keys)
resource "azurerm_role_assignment" "deployer_kv_crypto_officer" {
  scope                = azurerm_key_vault.dotbot.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# RSA-2048 key for JWT signing
resource "azurerm_key_vault_key" "jwt_signing" {
  name         = "dotbot-jwt-signing"
  key_vault_id = azurerm_key_vault.dotbot.id
  key_type     = "RSA"
  key_size     = 2048

  key_opts = [
    "sign",
    "verify",
  ]

  depends_on = [
    azurerm_role_assignment.deployer_kv_crypto_officer
  ]
}
