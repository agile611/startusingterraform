# modules/storage/outputs.tf
output "nombre" {
  description = "Nombre de la cuenta"
  value       = azurerm_storage_account.this.name
}

output "id" {
  description = "ID de la cuenta"
  value       = azurerm_storage_account.this.id
}

output "solo_https" {
  description = "Si la cuenta exige HTTPS"
  value       = azurerm_storage_account.this.https_traffic_only_enabled
}
