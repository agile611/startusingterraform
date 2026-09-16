# variables.tf
variable "proyecto" {
  type        = string
  description = "Nombre corto del proyecto (minúsculas y dígitos)"
  validation {
    condition     = can(regex("^[a-z0-9]{2,10}$", var.proyecto))
    error_message = "De 2 a 10 caracteres, solo minúsculas y dígitos."
  }
}

variable "entorno" {
  type        = string
  description = "Entorno de despliegue"
  validation {
    condition     = contains(["dev", "test", "prod"], var.entorno)
    error_message = "dev, test o prod."
  }
}

variable "ubicacion" {
  type        = string
  description = "Región de Azure"
  default     = "eastus"
}

variable "sufijo" {
  type        = string
  description = "Sufijo único por alumno para nombres globales"
  default     = "001"
}

variable "subredes" {
  type        = map(string)
  description = "Subredes por nombre corto"
  default     = { web = "10.0.1.0/24", data = "10.0.2.0/24" }
}

variable "storage_replicacion" {
  type        = string
  description = "Replicación de la cuenta de almacenamiento"
  default     = "LRS"
}

variable "tags" {
  type        = map(string)
  description = "Etiquetas de negocio. Obligatorias: propietario y coste"
  validation {
    condition     = alltrue([for k in ["propietario", "coste"] : contains(keys(var.tags), k)])
    error_message = "Las etiquetas 'propietario' y 'coste' son obligatorias."
  }
}
