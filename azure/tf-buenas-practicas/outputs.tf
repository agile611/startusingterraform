# outputs.tf
output "grupo_recursos" {
  description = "Nombre del grupo de recursos"
  value       = azurerm_resource_group.lab.name
}

output "subredes" {
  description = "ID de cada subred"
  value       = module.red.subred_ids
}

output "storage" {
  description = "Nombre e ID de la cuenta de almacenamiento"
  value       = { nombre = module.storage.nombre, id = module.storage.id }
}
