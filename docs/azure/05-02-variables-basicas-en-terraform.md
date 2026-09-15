# 🧩 Variables básicas en Terraform

> Las **variables** son el mecanismo con el que una misma configuración de Terraform sirve para desarrollo, pruebas y producción sin duplicar código: el `.tf` describe la infraestructura y las variables aportan los valores que cambian. En esta página aprenderás a declararlas, a elegir su tipo y a pasarles valores, con un ejemplo que ejecutarás contra el **emulador Topaz**. Donde el emulador difiere de Azure real, lo verás en un recuadro **🔷 En Topaz**.

**🎯 Objetivos de aprendizaje**
- Explicar qué es una variable de entrada y qué problema resuelve.
- Declarar variables con `description`, `type` y `default`.
- Usar los cinco tipos básicos: `string`, `number`, `bool`, `list` y `map`.
- Referenciarlas con `var.nombre` y ver cómo un cambio de valor cambia la infraestructura.
- Pasar valores por `terraform.tfvars`, `*.auto.tfvars`, `-var` y `TF_VAR_`.
- Escribir una primera regla de `validation`.

> **🔷 Requisitos previos**
> - Contenedor `azure-environment` en marcha y certificado del emulador instalado.
> - Terraform ≥ 1.5 y Azure CLI autenticada en la nube `Topaz`: `az account show --query environmentName -o tsv` → `Topaz`.
> - Laboratorio "Crear tu primer Resource Group" completado.

---

## 1. ¿Qué es una variable en Terraform?

Una **variable de entrada** es un parámetro de la configuración. Se declara una vez en un archivo `.tf`, se usa en tantos sitios como haga falta con `var.nombre`, y su valor lo decide quien ejecuta Terraform: en un archivo `.tfvars`, en la línea de comandos, en una variable de entorno o, si no lo recibe de ninguna parte, respondiendo a una pregunta interactiva.

**¿Por qué usar variables?**
- **Evitar duplicar código**: un solo `main.tf` para todos los entornos.
- **Separar código y configuración**: el código se revisa y versiona; los valores de cada entorno viven en su archivo.
- **Reutilizar módulos**: un módulo se invoca muchas veces con valores distintos.
- **Proteger secretos**: con `sensitive = true` el valor no se imprime en la consola.
- **Validar antes de desplegar**: un valor incorrecto falla en el `plan`, con tu mensaje, no en la API.

No confundas la variable con el **local**: la variable la fija quien ejecuta; el local (`locals { ... }`) lo calcula el código a partir de otros valores. Los verás juntos en el ejemplo.

---

## 2. Declaración de variables

Se usa el bloque `variable`, por convención en un archivo `variables.tf` (Terraform carga todos los `.tf` del directorio, así que el nombre del archivo es solo orden).

```hcl
variable "entorno" {
  description = "Nombre del entorno (dev, test, prod)"
  type        = string
  default     = "dev"          # valor si nadie indica otro
}
```

| **Argumento** | **Función** | **¿Obligatorio?** |
|---|---|---|
| `description` | Para qué sirve. Se muestra si Terraform pide el valor de forma interactiva. | No, pero ponlo siempre |
| `type` | Tipo de dato. Terraform rechaza en el `plan` un valor que no encaje. | No, pero ponlo siempre |
| `default` | Valor por defecto. Debe ser un **literal**: sin funciones ni referencias. Sin él, la variable es obligatoria. | No |

Hay tres argumentos más (`validation`, `sensitive`, `nullable`). El primero lo verás al final de esta página; los otros dos, en la siguiente.

---

## 3. Tipos de datos

Los tres primeros son **primitivos**; los dos últimos, **colecciones**, y llevan entre paréntesis el tipo de sus elementos (`list(string)`, no `list`).

```hcl
# string: texto (nombres, regiones, SKUs)
variable "nombre_proyecto" {
  type        = string
  description = "Nombre corto del proyecto, en minúsculas"
  default     = "demo"
}

# number: entero o decimal
variable "numero_subredes" {
  type        = number
  description = "Cuántas subredes crear en la red virtual"
  default     = 2
}

# bool: verdadero o falso
variable "crear_storage" {
  type        = bool
  description = "Crear o no la cuenta de almacenamiento"
  default     = true
}

# list(string): secuencia ordenada, se indexa desde 0
variable "address_space" {
  type        = list(string)
  description = "Rangos de la red virtual"
  default     = ["10.0.0.0/16"]
}

# map(string): pares clave-valor
variable "tags" {
  type        = map(string)
  description = "Etiquetas para los recursos"
  default = {
    entorno     = "dev"
    propietario = "equipo-devops"
  }
}
```

| **Tipo** | **Cómo se usa** | **En el ejemplo decide...** |
|---|---|---|
| `string` | `var.nombre_proyecto`, o dentro de texto `"rg-${var.nombre_proyecto}"` | Los nombres de todo |
| `number` | `count = var.numero_subredes` | Cuántas subredes existen |
| `bool` | `count = var.crear_storage ? 1 : 0` | Si existe la cuenta de almacenamiento |
| `list(string)` | `var.address_space` entero, o `var.address_space[0]` | El rango de la red |
| `map(string)` | `var.tags` entero, o `var.tags["entorno"]` | Las etiquetas |

---

## 4. Ejemplo práctico en Topaz

Un grupo de recursos, una red virtual con N subredes y una cuenta de almacenamiento opcional. Los cinco tipos de la sección anterior tienen aquí un efecto que podrás ver en el plan.

> **🔷 En Topaz.** El emulador no incluye el proveedor `Microsoft.Compute`, así que no se pueden crear máquinas virtuales; por eso el ejemplo usa red y almacenamiento, que sí están soportados. Las máquinas virtuales (`azurerm_linux_virtual_machine` con su interfaz de red, clave SSH e imagen `0001-com-ubuntu-server-jammy`) se ven en el módulo de Azure real.

### Paso 1. Directorio y `providers.tf`

```bash
mkdir -p ~/tf-variables-basicas && cd ~/tf-variables-basicas
```

```hcl
# providers.tf
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  metadata_host                   = "topaz.local.dev:8899"
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}
```

### Paso 2. `variables.tf`

Las cinco variables de la sección 3 más la región:

```hcl
variable "nombre_proyecto" {
  type        = string
  description = "Nombre corto del proyecto, en minúsculas y sin guiones"
  default     = "demo"
}

variable "ubicacion" {
  type        = string
  description = "Región de Azure (nombre corto)"
  default     = "eastus"
}

variable "numero_subredes" {
  type        = number
  description = "Cuántas subredes crear"
  default     = 2
}

variable "crear_storage" {
  type        = bool
  description = "Crear o no la cuenta de almacenamiento"
  default     = true
}

variable "address_space" {
  type        = list(string)
  description = "Rangos de la red virtual"
  default     = ["10.0.0.0/16"]
}

variable "tags" {
  type        = map(string)
  description = "Etiquetas para los recursos"
  default = {
    entorno     = "dev"
    propietario = "equipo-devops"
  }
}
```

### Paso 3. `main.tf`

```hcl
locals {
  # Calculado a partir de variables: por eso es un local y no un default
  tags = merge(var.tags, { gestion = "terraform" })
}

resource "azurerm_resource_group" "lab" {
  name     = "rg-${var.nombre_proyecto}-001"
  location = var.ubicacion
  tags     = local.tags

  lifecycle {
    ignore_changes = [tags]          # Topaz no devuelve las tags del grupo
  }
}

resource "azurerm_virtual_network" "lab" {
  name                = "vnet-${var.nombre_proyecto}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = var.address_space          # list(string) completa
  tags                = local.tags
}

resource "azurerm_subnet" "lab" {
  count = var.numero_subredes                      # number → cuántas copias

  name                 = "snet-${count.index + 1}"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  # Divide el primer rango en /24: 10.0.0.0/24, 10.0.1.0/24, ...
  address_prefixes = [cidrsubnet(var.address_space[0], 8, count.index)]
}

resource "azurerm_storage_account" "lab" {
  count = var.crear_storage ? 1 : 0                # bool → existe o no

  name                     = "st${var.nombre_proyecto}001"
  resource_group_name      = azurerm_resource_group.lab.name
  location                 = azurerm_resource_group.lab.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  tags                     = local.tags
}
```

### Paso 4. `outputs.tf`

```hcl
output "subredes" {
  description = "Nombre y prefijo de cada subred"
  value       = { for s in azurerm_subnet.lab : s.name => s.address_prefixes[0] }
}

output "storage" {
  description = "Endpoint de blobs, o null si no se creó la cuenta"
  value       = var.crear_storage ? azurerm_storage_account.lab[0].primary_blob_endpoint : null
}
```

### Paso 5. Desplegar con los valores por defecto

```bash
terraform init
terraform plan
```

```text
  # azurerm_resource_group.lab will be created
      + name     = "rg-demo-001"
  # azurerm_virtual_network.lab will be created
      + address_space = [ + "10.0.0.0/16" ]
  # azurerm_subnet.lab[0] will be created
      + address_prefixes = [ + "10.0.0.0/24" ]
  # azurerm_subnet.lab[1] will be created
      + address_prefixes = [ + "10.0.1.0/24" ]
  # azurerm_storage_account.lab[0] will be created
      + name = "stdemo001"

Plan: 5 to add, 0 to change, 0 to destroy.
```

```bash
terraform apply -auto-approve
terraform output subredes
# { "snet-1" = "10.0.0.0/24", "snet-2" = "10.0.1.0/24" }
az resource list -g rg-demo-001 -o table
```

Ningún archivo `.tfvars`, ningún `-var`: todo ha salido de los `default`. Ahora vas a cambiar valores sin tocar el código.

### Paso 6. Cambiar un `number` y un `bool`

```bash
terraform plan -var numero_subredes=3
#   # azurerm_subnet.lab[2] will be created  (10.0.2.0/24)
#   Plan: 1 to add, 0 to change, 0 to destroy.

terraform plan -var crear_storage=false
#   # azurerm_storage_account.lab[0] will be destroyed
#   Plan: 0 to add, 0 to change, 1 to destroy.
```

Un número más, una subred más; un `false`, una cuenta menos. Eso es lo que significa que las variables "personalizan la configuración": no cambian texto, cambian infraestructura.

---

## 5. Cómo pasar valores

Hay cuatro formas habituales, y todas las probarás sobre el proyecto que ya tienes aplicado.

### 5.1. Archivo `terraform.tfvars`

Terraform lo carga automáticamente si existe en el directorio. Es el sitio para los valores del proyecto:

```hcl
# terraform.tfvars
nombre_proyecto = "demo"
numero_subredes = 3
address_space   = ["10.0.0.0/16"]

tags = {
  entorno     = "dev"
  propietario = "tu-nombre"
  coste       = "CC-LAB"
}
```

```bash
terraform plan          # sin argumentos: Plan: 1 to add (la tercera subred), 3 to change (las tags)
```

> **🔷 En Topaz.** El grupo no aparece entre los "3 to change" gracias al `ignore_changes`; la red, las subredes no (no tienen tags) y la cuenta de almacenamiento sí. El emulador acepta y devuelve correctamente las etiquetas de la red y del storage.

### 5.2. Archivos `*.auto.tfvars`

También se cargan solos, en orden alfabético, después de `terraform.tfvars`. Útiles para ajustes personales que no se suben a Git:

```bash
echo 'nombre_proyecto = "demoana"' > personal.auto.tfvars
echo '*.auto.tfvars' >> .gitignore
terraform plan          # los nombres cambian → replace de todo: no apliques, solo observa
rm personal.auto.tfvars
```

### 5.3. Línea de comandos: `-var` y `-var-file`

```bash
terraform plan -var numero_subredes=4
terraform plan -var 'tags={entorno="test",propietario="qa"}'     # mapas y listas: sintaxis HCL entre comillas simples
terraform plan -var-file=prod.tfvars                              # un archivo que NO se carga solo (no acaba en .auto.tfvars)
```

### 5.4. Variables de entorno `TF_VAR_`

```bash
export TF_VAR_numero_subredes=1
terraform plan          # Plan: 0 to add, 0 to change, 2 to destroy  (¡gana a terraform.tfvars? No: ver abajo)
unset TF_VAR_numero_subredes
```

Ese último plan te sorprenderá: **no** propone destruir nada, porque `terraform.tfvars` (con `numero_subredes = 3`) tiene más prioridad que la variable de entorno. Este es el orden completo, de menor a mayor prioridad:

```text
default  <  TF_VAR_*  <  terraform.tfvars  <  *.auto.tfvars  <  -var-file / -var (en orden de aparición)
```

Si quieres comprobarlo, comenta la línea `numero_subredes` de `terraform.tfvars` y repite el `export`: entonces sí verás *2 to destroy*.

> ⚠️ **Secretos.** Nunca escribas contraseñas ni claves en un `.tf` (como hacía el ejemplo original con `admin_password = "P@$$w0rd1234!"`). Tampoco con `-var`, que queda en el historial del shell. Usa `TF_VAR_` leído de un gestor de secretos, o un `secretos.auto.tfvars` en `.gitignore`, y marca la variable `sensitive = true`. Para secretos reales, Azure Key Vault.

---

## 6. Validación básica

El bloque `validation` añade reglas que Terraform comprueba en el `plan`, antes de hablar con la API. Añade estas dos al `variables.tf` del ejemplo:

```hcl
variable "nombre_proyecto" {
  type        = string
  description = "Nombre corto del proyecto, en minúsculas y sin guiones"
  default     = "demo"

  validation {
    condition     = can(regex("^[a-z0-9]{2,12}$", var.nombre_proyecto))
    error_message = "Solo minúsculas y dígitos, de 2 a 12 caracteres: se usa en el nombre de la cuenta de almacenamiento."
  }
}

variable "numero_subredes" {
  type        = number
  description = "Cuántas subredes crear"
  default     = 2

  validation {
    condition     = var.numero_subredes >= 1 && var.numero_subredes <= 8
    error_message = "Entre 1 y 8 subredes."
  }
}
```

```bash
terraform plan -var nombre_proyecto=Mi-Proyecto
```

```text
│ Error: Invalid value for variable
│
│   on variables.tf line 1:
│    1: variable "nombre_proyecto" {
│     │ var.nombre_proyecto is "Mi-Proyecto"
│
│ Solo minúsculas y dígitos, de 2 a 12 caracteres: se usa en el nombre de la cuenta de almacenamiento.
```

> **🔷 En Topaz.** Las validaciones importan más que en Azure real: el emulador no siempre devuelve los mismos mensajes que Azure ante un nombre inválido, así que un error claro de Terraform ahorra tiempo de depuración. El patrón `contains([...], var.x)` del original sigue siendo válido para listas cerradas de valores (regiones permitidas, SKUs, entornos). La siguiente página amplía la validación con `sensitive`, `nullable` y tipos `object`.

### Limpieza

```bash
terraform destroy -auto-approve
az group list -o table          # rg-demo-001 ya no aparece
```

---

## 7. Errores comunes

> ⚠️ **Solución de problemas**
> 
> | **Mensaje** | **Causa** | **Solución** |
> |---|---|---|
> | *Functions may not be called here* / *Variables not allowed* | Función o referencia en un `default` | Mover el cálculo a `locals` |
> | *No value for required variable* | Sin `default` y sin valor, con `-input=false` | Pasar `-var`, `-var-file` o `TF_VAR_` |
> | *Invalid value for input variable ... a number is required* | `numero_subredes = "dos"` | Respetar el `type`; `"3"` sí se convierte, `"dos"` no |
> | *Value for undeclared variable* (aviso) | Errata en el nombre dentro del `.tfvars` | Comparar con `variables.tf` |
> | *Missing resource instance key* | Referenciar `azurerm_storage_account.lab.name` en un recurso con `count` | Indexar: `azurerm_storage_account.lab[0].name` |
> | El valor de `TF_VAR_` "no hace nada" | `terraform.tfvars` tiene más prioridad | Revisar el orden de precedencia de la sección 5 |
> | *StorageAccountAlreadyTaken* | Otro alumno usa el mismo `nombre_proyecto` en Topaz | Cambiarlo en tu `terraform.tfvars` |

---

## 8. Autoevaluación

1. **¿Qué tres argumentos deberías poner siempre al declarar una variable?**
   `description`, `type` y, si existe un valor razonable, `default`. Sin `default` la variable es obligatoria.
2. **¿Por qué `default = "rg-${timestamp()}"` no es válido?**
   Un `default` solo admite literales. Los cálculos van en `locals`.
3. **¿Qué diferencia hay entre `list` y `list(string)`?**
   `list` a secas es sintaxis heredada equivalente a `list(any)`: no comprueba el tipo de los elementos.
4. **Con `numero_subredes = 3` en `terraform.tfvars` y `TF_VAR_numero_subredes=1`, ¿cuántas subredes se crean?**
   Tres. El archivo `terraform.tfvars` tiene más prioridad que la variable de entorno; solo `*.auto.tfvars`, `-var-file` y `-var` están por encima.
5. **¿Cómo consigues que un recurso exista o no según una variable?**
   Con `count = var.crear_x ? 1 : 0`, y referenciándolo después como `recurso.nombre[0]`.
6. **¿Por qué el ejemplo original con una máquina virtual no funciona en Topaz?**
   El emulador no incluye el proveedor Compute. Además, el código referenciaba una interfaz de red no declarada, usaba contraseña con la autenticación por contraseña desactivada por defecto y una imagen retirada.
7. **¿Dónde debería vivir una contraseña que Terraform necesita?**
   Fuera del `.tf`: en `TF_VAR_` o en un `.auto.tfvars` ignorado por Git, con la variable marcada `sensitive = true`; idealmente en Key Vault.

---

## 9. Referencias

- [Variables de entrada](https://developer.hashicorp.com/terraform/language/values/variables) (declaración, tipos, precedencia)
- [Valores locales](https://developer.hashicorp.com/terraform/language/values/locals)
- [Meta-argumento `count`](https://developer.hashicorp.com/terraform/language/meta-arguments/count)
- [`cidrsubnet()`](https://developer.hashicorp.com/terraform/language/functions/cidrsubnet) y [`merge()`](https://developer.hashicorp.com/terraform/language/functions/merge)
- [Validación de variables](https://developer.hashicorp.com/terraform/language/expressions/custom-conditions#input-variable-validation)
- [Recurso `azurerm_virtual_network`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network), [`azurerm_subnet`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) y [`azurerm_storage_account`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account)
- [Reglas de nombre de las cuentas de almacenamiento](https://learn.microsoft.com/es-es/azure/storage/common/storage-account-overview#storage-account-name)
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)