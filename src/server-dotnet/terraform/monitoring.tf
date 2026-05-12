# Log Analytics Workspace (required by Application Insights)
resource "azurerm_log_analytics_workspace" "dotbot" {
  name                = "law-${var.app_name}-${var.environment}-01"
  location            = azurerm_resource_group.dotbot.location
  resource_group_name = azurerm_resource_group.dotbot.name
  sku                 = var.log_analytics_sku
  retention_in_days   = 30
  tags                = local.tags
}

# Application Insights
resource "azurerm_application_insights" "dotbot" {
  name                = "ai-${var.app_name}-${var.environment}-01"
  location            = azurerm_resource_group.dotbot.location
  resource_group_name = azurerm_resource_group.dotbot.name
  workspace_id        = azurerm_log_analytics_workspace.dotbot.id
  application_type    = "web"
  tags                = local.tags
}
