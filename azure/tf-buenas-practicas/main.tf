# main.tf
locals {
  prefijo = "${var.proyecto}-${var.entorno}"
  tags = merge(var.tags, {
    entorno  = var.entorno
    proyecto = var.proyecto
    gestion  = "terraform"
  })
}

resource "azurerm_resource_group" "lab" {
  name     = "rg-${local.prefijo}-001"
  location = var.ubicacion
  tags     = local.tags

  lifecycle {
    ignore_changes = [tags]            # Topaz no devuelve las tags del grupo
  }
}

module "red" {
  source = "./modules/red"

  nombre              = "vnet-${local.prefijo}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  subredes            = var.subredes
  tags                = local.tags
}

module "storage" {
  source = "./modules/storage"

  nombre              = "st${var.proyecto}${var.entorno}${var.sufijo}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  replicacion         = var.storage_replicacion
  tags                = local.tags
}
