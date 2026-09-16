# modules/red/outputs.tf
output "vnet_id" {
  description = "ID de la red virtual"
  value       = azurerm_virtual_network.this.id
}

output "subred_ids" {
  description = "ID de cada subred, por nombre corto"
  value       = { for k, s in azurerm_subnet.this : k => s.id }
}
