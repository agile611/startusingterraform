# modules/storage/main.tf
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}

resource "azurerm_storage_account" "this" {
  name                     = var.nombre
  resource_group_name      = var.resource_group_name
  location                 = var.location
  account_tier             = "Standard"
  account_replication_type = var.replicacion

  # Valores seguros por defecto: quien use el módulo no puede relajarlos
  https_traffic_only_enabled = true
  min_tls_version            = "TLS1_2"

  tags = var.tags

  # En producción real: prevent_destroy = true (debe ser literal, no admite variables).
  # No se activa en el laboratorio para poder ejecutar terraform destroy y terraform test.
}
