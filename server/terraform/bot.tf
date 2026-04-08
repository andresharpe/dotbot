# Bot Service + Teams channel via Azure CLI (no native Terraform resource)
# Same pattern as Helia project

# Ensure Bot Service exists, set endpoint, enable Teams channel
resource "null_resource" "ensure_bot" {
  triggers = {
    backend_host = azurerm_linux_web_app.bot.default_hostname
    app_id       = local.bot_app_id
    bot_name     = local.bot_service_name
    bot_rg       = var.resource_group_name
    bot_sku      = var.bot_sku
  }

  provisioner "local-exec" {
    interpreter = ["pwsh", "-Command"]
    command = <<-EOT
      $ErrorActionPreference = 'Stop'
      $bot = az bot show --name ${local.bot_service_name} --resource-group ${var.resource_group_name} --query name -o tsv 2>$null
      if (-not $bot) {
        Write-Host "Creating Bot Service ${local.bot_service_name} in RG ${var.resource_group_name}..."
        az bot create `
          --resource-group ${var.resource_group_name} `
          --name ${local.bot_service_name} `
          --app-type SingleTenant `
          --tenant-id ${local.tenant_id} `
          --sku ${var.bot_sku} `
          --location global `
          --appid ${local.bot_app_id} `
          --endpoint https://${azurerm_linux_web_app.bot.default_hostname}/api/messages `
          --display-name "Dotbot" | Out-Null

        az bot msteams create `
          --resource-group ${var.resource_group_name} `
          --name ${local.bot_service_name} | Out-Null
      }
      else {
        Write-Host "Bot exists; updating endpoint and Teams channel..."
        az bot update `
          --name ${local.bot_service_name} `
          --resource-group ${var.resource_group_name} `
          --endpoint https://${azurerm_linux_web_app.bot.default_hostname}/api/messages | Out-Null

        az bot msteams update `
          --resource-group ${var.resource_group_name} `
          --name ${local.bot_service_name} | Out-Null
      }
    EOT
  }

  depends_on = [
    azurerm_linux_web_app.bot
  ]
}
