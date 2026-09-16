# modules/storage/variables.tf
variable "nombre" {
  type        = string
  description = "Nombre de la cuenta: 3-24 caracteres, minúsculas y dígitos, único global"
  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.nombre))
    error_message = "Solo minúsculas y dígitos, de 3 a 24 caracteres."
  }
}

variable "resource_group_name" {
  type        = string
  description = "Grupo de recursos"
}

variable "location" {
  type        = string
  description = "Región de Azure"
}

variable "replicacion" {
  type        = string
  description = "Tipo de replicación"
  default     = "LRS"
  validation {
    condition     = contains(["LRS", "ZRS", "GRS"], var.replicacion)
    error_message = "LRS, ZRS o GRS."
  }
}

variable "tags" {
  type        = map(string)
  description = "Etiquetas"
  default     = {}
}
