# modules/red/variables.tf
variable "nombre" {
  type        = string
  description = "Nombre de la red virtual"
}

variable "resource_group_name" {
  type        = string
  description = "Grupo de recursos donde se crea la red"
}

variable "location" {
  type        = string
  description = "Región de Azure"
}

variable "address_space" {
  type        = list(string)
  description = "Rangos de la red virtual"
  default     = ["10.0.0.0/16"]
}

variable "subredes" {
  type        = map(string)
  description = "Subredes por nombre corto: { web = \"10.0.1.0/24\" }"
  validation {
    condition     = alltrue([for p in values(var.subredes) : can(cidrhost(p, 0))])
    error_message = "Cada valor debe ser un CIDR válido."
  }
}

variable "tags" {
  type        = map(string)
  description = "Etiquetas"
  default     = {}
}
