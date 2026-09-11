# 🧩 Variables en Terraform

> Una **variable de entrada** es un parámetro de tu configuración: el mismo código crea un grupo de recursos en `dev` o en `prod`, con una red pequeña o grande, según los valores que le pases. Sin variables, cada entorno sería una copia del código con pequeños cambios; con ellas, hay un único código y varios archivos de valores. En este módulo trabajarás contra el **emulador Topaz**; donde difiere de Azure real, lo verás en un recuadro **🔷 En Topaz**.

**🎯 Objetivos de aprendizaje**
- Declarar variables con tipo, descripción, valor por defecto y reglas de validación.
- Distinguir los tipos primitivos y compuestos, y elegir el adecuado.
- Asignar valores de seis formas distintas y conocer su orden de precedencia.
- Diferenciar `variable`, `locals` y `output`.
- Proteger valores sensibles y evitar que aparezcan en la consola.
- Desplegar la misma configuración en dos entornos con archivos `.tfvars`.

> **🔷 Requisitos previos**
> - Contenedor `azure-environment` en marcha y certificado del emulador instalado.
> - Terraform ≥ 1.5 y Azure CLI autenticada en la nube `Topaz`: `az account show --query environmentName -o tsv` → `Topaz`.
> - Módulos anteriores completados (sintaxis HCL, comandos clave, primer Resource Group).

---

## 1. Para qué sirven las variables

- **Parametrizar:** cambiar nombre, región o tamaño sin tocar el código.
- **Reutilizar:** un módulo se invoca muchas veces con valores distintos.
- **Separar código y configuración:** el `.tf` se versiona; los `.tfvars` de cada entorno también, salvo los que contienen secretos.
- **Validar:** rechazar valores incorrectos antes de que lleguen a la API.
- **Proteger:** marcar valores sensibles para que no se impriman.

Terraform tiene tres tipos de "valores con nombre" que conviene no confundir:

| **Bloque** | **Papel** | **Quién le da valor** | **Se referencia como** |
|---|---|---|---|
| `variable` | Entrada (parámetro) | Quien ejecuta: CLI, tfvars, entorno | `var.nombre` |
| `locals` | Valor interno calculado | El propio código, con expresiones | `local.nombre` |
| `output` | Salida (resultado) | Los recursos, tras el apply | `module.x.nombre` (desde fuera) |

---

## 2. Tipos de variables

El argumento `type` es opcional, pero declararlo siempre es una buena práctica: Terraform rechaza valores incorrectos en el `plan`, con un mensaje claro, en lugar de fallar en la API.

### 2.1. Primitivos

| **Tipo** | **Descripción** | **Ejemplo** |
|---|---|---|
| `string` | Texto: nombres, regiones, SKUs | `"eastus"` |
| `number` | Entero o decimal | `3`, `0.5` |
| `bool` | Verdadero o falso | `true` |

### 2.2. Compuestos

Los tipos compuestos llevan entre paréntesis el tipo de sus elementos. `list` y `map` sin argumento son sintaxis heredada y equivalen a `list(any)`: funcionan, pero pierdes la comprobación.

| **Tipo** | **Descripción** | **Ejemplo** |
|---|---|---|
| `list(string)` | Secuencia ordenada, admite repetidos, se indexa `var.x[0]` | `["10.0.0.0/16", "10.1.0.0/16"]` |
| `set(string)` | Sin orden ni repetidos; el tipo natural para `for_each` | `["dev", "test", "prod"]` |
| `map(string)` | Pares clave-valor, todos del mismo tipo | `{ entorno = "dev", equipo = "infra" }` |
| `object({...})` | Estructura con atributos de tipos distintos | `{ nombre = "vnet", cidr = ["10.0.0.0/16"] }` |
| `tuple([...])` | Secuencia fija con tipo por posición (poco frecuente) | `["web", 2, true]` |
| `any` | Terraform infiere el tipo del valor recibido | Evítalo salvo en módulos genéricos |

```hcl
variable "red" {
  description = "Definición de la red virtual"
  type = object({
    nombre        = string
    address_space = list(string)
    subredes      = map(string)            # nombre => prefijo
  })
  default = {
    nombre        = "vnet-lab"
    address_space = ["10.0.0.0/16"]
    subredes = {
      web  = "10.0.1.0/24"
      data = "10.0.2.0/24"
    }
  }
}

# Uso:  var.red.nombre   var.red.address_space[0]   var.red.subredes["web"]
```

Desde Terraform 1.3, un atributo de `object` puede ser opcional: `cidr = optional(string, "10.0.0.0/16")`. Así el usuario solo indica lo que quiere cambiar.

---

## 3. Declaración completa

Un bloque `variable` admite seis argumentos. Solo el nombre es obligatorio, pero en un proyecto real se usan al menos los tres primeros.

| **Argumento** | **Función** |
|---|---|
| `description` | Documentación. Aparece cuando Terraform pide el valor de forma interactiva y en la documentación generada del módulo. |
| `type` | Restricción de tipo. Terraform convierte cuando puede (`"3"` → `3`) y falla cuando no. |
| `default` | Valor si nadie da otro. Debe ser un **literal**: no admite funciones ni referencias. Sin `default`, la variable es obligatoria. |
| `validation` | Una o varias reglas `condition` + `error_message`. Se evalúan en el `plan`. |
| `sensitive` | Oculta el valor en la salida de `plan` y `apply`. No lo cifra en el estado. |
| `nullable` | `false` impide pasar `null` explícitamente (útil para que `null` no anule el `default`). |

```hcl
variable "entorno" {
  description = "Entorno de despliegue"
  type        = string
  default     = "dev"
  nullable    = false

  validation {
    condition     = contains(["dev", "test", "prod"], var.entorno)
    error_message = "El entorno debe ser dev, test o prod."
  }
}

variable "ubicacion" {
  description = "Región de Azure"
  type        = string
  default     = "eastus"

  validation {
    condition     = can(regex("^[a-z0-9]+$", var.ubicacion))
    error_message = "Usa el nombre corto de la región (eastus, westeurope), no el nombre largo."
  }
}

variable "nombre_storage" {
  description = "Nombre de la cuenta de almacenamiento (3-24 caracteres, minúsculas y dígitos)"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.nombre_storage))
    error_message = "Solo minúsculas y dígitos, entre 3 y 24 caracteres, sin guiones."
  }
}

variable "clave_api" {
  description = "Clave de un servicio externo (ejemplo de valor sensible)"
  type        = string
  sensitive   = true
  default     = null
}
```

> **🔷 En Topaz.** Las validaciones son la mejor defensa en el emulador: Topaz no siempre devuelve los mismos mensajes de error que Azure ante un valor inválido (por ejemplo, un nombre de cuenta con mayúsculas). Con `validation` el error lo da Terraform, con tu texto, antes de llamar a la API. Usa `eastus` como región por defecto: es la que funciona en todos los servicios del emulador.

> ⚠️ **`sensitive` no cifra.** El valor sigue en `terraform.tfstate` en texto plano. Protege el estado (backend remoto con acceso restringido, nunca en Git) y, para secretos reales, guárdalos en Key Vault y pásalos por referencia.

---

## 4. Cómo asignar valores y en qué orden ganan

Una variable puede recibir su valor de seis sitios. Cuando hay varios, Terraform aplica esta precedencia (el último gana):

| **#** | **Origen** | **Ejemplo** | **Uso típico** |
|---|---|---|---|
| 1 | `default` en la declaración | `default = "dev"` | Valor razonable para el 80 % de los casos |
| 2 | Variable de entorno `TF_VAR_nombre` | `export TF_VAR_entorno=test` | Pipelines, secretos |
| 3 | `terraform.tfvars` o `terraform.tfvars.json` | Se carga solo si existe | Valores del proyecto |
| 4 | `*.auto.tfvars` | `local.auto.tfvars`, en orden alfabético | Ajustes personales (en `.gitignore`) |
| 5 | `-var-file` | `-var-file=prod.tfvars` | Un archivo por entorno |
| 6 | `-var` | `-var entorno=prod` | Pruebas puntuales |

Los orígenes 5 y 6 se aplican en el orden en que aparecen en la línea de comandos. Si una variable sin `default` no recibe valor por ninguna vía, Terraform lo pide de forma interactiva mostrando la `description`; en un pipeline eso es un error, así que allí se usa `-input=false`.

```bash
# Valores compuestos por CLI: sintaxis HCL entre comillas simples
terraform plan -var 'etiquetas={equipo="infra",coste="CC-1"}'
terraform plan -var 'address_space=["10.5.0.0/16"]'

# Variable de entorno para un secreto (no queda en el historial del shell si se lee de un gestor)
export TF_VAR_clave_api=$(cat ~/.secretos/clave)
```

> ⚠️ **`-var` queda en el historial.** Un secreto pasado con `-var clave=...` se guarda en `~/.bash_history`. Para secretos usa `TF_VAR_` o un archivo `secretos.auto.tfvars` excluido de Git.

---

## 5. `variable` frente a `locals`

La regla práctica: si el valor lo decide quien ejecuta, es una `variable`; si se calcula a partir de otros valores, es un `local`.

```hcl
variable "proyecto" { type = string, default = "webapp" }
variable "entorno"  { type = string, default = "dev" }

locals {
  # Prefijo de nombres derivado de las variables: nadie lo pasa desde fuera
  prefijo = "${var.proyecto}-${var.entorno}"

  # Etiquetas comunes: se combinan las fijas con las que aporte el usuario
  tags = merge(
    {
      proyecto = var.proyecto
      entorno  = var.entorno
      gestion  = "terraform"
    },
    var.etiquetas_extra
  )

  # Lógica condicional: en prod, más redundancia
  replicacion = var.entorno == "prod" ? "GRS" : "LRS"
}

# Uso: name = "rg-${local.prefijo}-001"    tags = local.tags
```

Un `local` puede usar funciones, referencias a recursos y otros locals; un `default` no. Esa es la razón por la que los nombres compuestos, las fechas o los cálculos van siempre en `locals`.

---

## 6. Ejemplo práctico: dos entornos, un solo código

Crearás un grupo de recursos, una red virtual y una cuenta de almacenamiento, y los desplegarás como `dev` y como `prod` cambiando solo el archivo de valores.

### Paso 1. Sesión y estructura

```bash
az account show --query environmentName -o tsv          # Topaz
mkdir -p ~/tf-variables && cd ~/tf-variables
touch providers.tf variables.tf main.tf outputs.tf dev.tfvars prod.tfvars
```
Separar en archivos es convención, no obligación: Terraform carga todos los `.tf` del directorio como si fueran uno.

### Paso 2. `providers.tf`

```hcl
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

### Paso 3. `variables.tf`

```hcl
variable "proyecto" {
  description = "Nombre corto del proyecto, usado como prefijo"
  type        = string
  default     = "webapp"

  validation {
    condition     = can(regex("^[a-z0-9]{2,10}$", var.proyecto))
    error_message = "Solo minúsculas y dígitos, de 2 a 10 caracteres."
  }
}

variable "entorno" {
  description = "Entorno: dev, test o prod"
  type        = string
  nullable    = false

  validation {
    condition     = contains(["dev", "test", "prod"], var.entorno)
    error_message = "El entorno debe ser dev, test o prod."
  }
}

variable "ubicacion" {
  description = "Región de Azure (nombre corto)"
  type        = string
  default     = "eastus"
}

variable "red" {
  description = "Espacio de direcciones y subredes de la red virtual"
  type = object({
    address_space = list(string)
    subredes      = map(string)
  })
  default = {
    address_space = ["10.0.0.0/16"]
    subredes      = { web = "10.0.1.0/24" }
  }
}

variable "storage" {
  description = "Nivel y replicación de la cuenta de almacenamiento"
  type = object({
    tier        = optional(string, "Standard")
    replicacion = optional(string, "LRS")
  })
  default = {}

  validation {
    condition     = contains(["LRS", "GRS", "ZRS"], var.storage.replicacion)
    error_message = "La replicación debe ser LRS, GRS o ZRS."
  }
}

variable "etiquetas_extra" {
  description = "Etiquetas adicionales que se combinan con las comunes"
  type        = map(string)
  default     = {}
}
```
`entorno` no tiene `default`: es obligatoria a propósito, para que nadie despliegue "sin querer" en el entorno equivocado.

### Paso 4. `main.tf`

```hcl
locals {
  prefijo = "${var.proyecto}-${var.entorno}"
  tags = merge(
    { proyecto = var.proyecto, entorno = var.entorno, gestion = "terraform" },
    var.etiquetas_extra
  )
}

resource "azurerm_resource_group" "principal" {
  name     = "rg-${local.prefijo}-001"
  location = var.ubicacion
  tags     = local.tags

  lifecycle {
    ignore_changes = [tags]          # Topaz no devuelve las tags del grupo
  }
}

resource "azurerm_virtual_network" "principal" {
  name                = "vnet-${local.prefijo}"
  location            = azurerm_resource_group.principal.location
  resource_group_name = azurerm_resource_group.principal.name
  address_space       = var.red.address_space
  tags                = local.tags
}

resource "azurerm_subnet" "subredes" {
  for_each = var.red.subredes

  name                 = "snet-${each.key}"
  resource_group_name  = azurerm_resource_group.principal.name
  virtual_network_name = azurerm_virtual_network.principal.name
  address_prefixes     = [each.value]
}

resource "azurerm_storage_account" "principal" {
  # Sin guiones y en minúsculas: la validación de var.proyecto lo garantiza
  name                     = "st${var.proyecto}${var.entorno}001"
  resource_group_name      = azurerm_resource_group.principal.name
  location                 = azurerm_resource_group.principal.location
  account_tier             = var.storage.tier
  account_replication_type = var.storage.replicacion
  tags                     = local.tags
}
```

> **🔷 En Topaz.** Grupos, redes virtuales, subredes y cuentas de almacenamiento están soportados en el plano de control del emulador. El nombre de la cuenta debe ser único en Topaz igual que en Azure: si otra persona del curso usa el mismo `proyecto`, cambia el tuyo en `terraform.tfvars`.

### Paso 5. `outputs.tf` y archivos de valores

```hcl
# outputs.tf
output "grupo" {
  value = azurerm_resource_group.principal.name
}

output "subredes" {
  description = "Mapa nombre => id de las subredes creadas"
  value       = { for k, s in azurerm_subnet.subredes : k => s.id }
}

output "storage_endpoint" {
  value = azurerm_storage_account.principal.primary_blob_endpoint
}
```

```hcl
# dev.tfvars
entorno = "dev"

etiquetas_extra = {
  coste = "CC-DEV"
}
```

```hcl
# prod.tfvars
entorno = "prod"

red = {
  address_space = ["10.10.0.0/16"]
  subredes = {
    web  = "10.10.1.0/24"
    api  = "10.10.2.0/24"
    data = "10.10.3.0/24"
  }
}

storage = {
  replicacion = "GRS"
}

etiquetas_extra = {
  coste       = "CC-PROD"
  criticidad  = "alta"
}
```
Fíjate en que `dev.tfvars` solo indica el entorno: todo lo demás viene de los `default`. `prod.tfvars` sobrescribe lo que necesita y nada más.

### Paso 6. Desplegar `dev`

```bash
terraform init
terraform plan -var-file=dev.tfvars
```

```text
  # azurerm_resource_group.principal will be created
      + name     = "rg-webapp-dev-001"
  # azurerm_virtual_network.principal will be created
      + address_space = [ + "10.0.0.0/16" ]
  # azurerm_subnet.subredes["web"] will be created
      + address_prefixes = [ + "10.0.1.0/24" ]
  # azurerm_storage_account.principal will be created
      + name                     = "stwebappdev001"
      + account_replication_type = "LRS"

Plan: 4 to add, 0 to change, 0 to destroy.
```

```bash
terraform apply -var-file=dev.tfvars          # yes
az resource list -g rg-webapp-dev-001 -o table
terraform output subredes
```

### Paso 7. Provocar un error de validación

```bash
terraform plan -var-file=dev.tfvars -var entorno=staging
```

```text
╷
│ Error: Invalid value for variable
│
│   on variables.tf line 12:
│   12: variable "entorno" {
│     ├────────────────
│     │ var.entorno is "staging"
│
│ El entorno debe ser dev, test o prod.
│
│ This was checked by the validation rule at variables.tf:17,3-13.
╵
```
El error llega antes de tocar Topaz, con tu mensaje. Observa también que `-var` (origen 6) ha ganado a `-var-file` (origen 5): es la precedencia de la sección 4 en acción. Prueba además `-var 'storage={replicacion="RAGRS"}'` para ver la segunda validación.

### Paso 8. Desplegar `prod` en paralelo

Aplicar `prod.tfvars` sobre el mismo estado reemplazaría los recursos de `dev` (el nombre cambia). Para tener ambos a la vez, usa un **workspace**, que da a cada entorno su propio estado:

```bash
terraform workspace new prod                  # crea y cambia; el estado de dev queda en "default"
terraform plan -var-file=prod.tfvars          # Plan: 6 to add (3 subredes)
terraform apply -var-file=prod.tfvars         # yes

az group list --query "[].name" -o tsv        # rg-webapp-dev-001  rg-webapp-prod-001
terraform workspace list                      # default  * prod
```
Cada workspace tiene su `terraform.tfstate` (en `terraform.tfstate.d/prod/`). Combinar `workspace` + `-var-file` del mismo nombre es un patrón habitual; en el Módulo 7 verás la alternativa con directorios separados y backend remoto.

### Paso 9. Limpieza

```bash
terraform destroy -var-file=prod.tfvars       # en el workspace prod
terraform workspace select default
terraform destroy -var-file=dev.tfvars
terraform workspace delete prod
az group list -o table                        # vacío
```
Un `destroy` necesita los mismos valores que el `apply`: sin `-var-file`, Terraform pediría `entorno` de forma interactiva.

---

## 7. Buenas prácticas

✅ **Recomendaciones clave:**
- **Siempre `type` y `description`.** Son la documentación del módulo y la primera línea de defensa.
- **Tipos con argumento:** `list(string)`, no `list`; `map(string)`, no `map`.
- **`default` solo para valores realmente razonables.** Lo que debe decidirse conscientemente (entorno, región de producción) va sin default.
- **`validation` para todo lo que la API rechazaría** (longitud de nombres, listas cerradas, formatos CIDR con `cidrhost()`).
- **Un `.tfvars` por entorno**, versionado en Git; los secretos en `TF_VAR_` o en `*.auto.tfvars` ignorados.
- **Los cálculos van en `locals`**: nombres compuestos, `merge()` de etiquetas, condicionales.
- **`sensitive = true`** en cualquier valor que no quieras ver en un log de CI.
- **`terraform fmt` y `terraform validate`** antes de cada commit: `validate` comprueba tipos y validaciones sin tocar el emulador.

⚠️ **Errores comunes:**

| **Mensaje** | **Causa** | **Solución** |
|---|---|---|
| *Variables not allowed ... in a default value* | Función o referencia en `default` | Mover el cálculo a `locals` |
| *No value for required variable* | Variable sin `default` y sin valor, con `-input=false` | Pasar `-var-file` o `TF_VAR_` |
| *Invalid value for input variable ... string required* | El tipo del valor no coincide con `type` | Revisar el `.tfvars`: las listas van entre `[ ]` y los mapas entre `{ }` |
| *Value for undeclared variable* (aviso) | El `.tfvars` asigna una variable que ningún `.tf` declara | Errata en el nombre, o declarar la variable |
| *Invalid value for variable* + tu mensaje | Falló una regla `validation` | Es el comportamiento deseado: corregir el valor |
| *Output refers to sensitive values* | Un `output` expone una variable `sensitive` | Añadir `sensitive = true` al output |
| Plan con `-/+ replace` inesperado al cambiar de `.tfvars` | Se aplica `prod.tfvars` sobre el estado de `dev` | Un workspace o un directorio por entorno |
| *StorageAccountAlreadyTaken* | Otro alumno usa el mismo `proyecto` en Topaz | Cambiar `proyecto` en tu `terraform.tfvars` |

---

## 8. Autoevaluación

1. **¿Qué diferencia hay entre `variable` y `locals`?**
   La variable la fija quien ejecuta (CLI, tfvars, entorno) y solo admite literales en su `default`. El local lo calcula el código con expresiones, funciones y referencias. Nombres compuestos, `merge()` de etiquetas y condicionales van en `locals`.
2. **¿Por qué `list(string)` en lugar de `list`?**
   `list` sin argumento es sintaxis heredada equivalente a `list(any)`: funciona, pero Terraform no comprueba el tipo de los elementos.
3. **Si una variable está en `terraform.tfvars`, en `TF_VAR_` y en `-var`, ¿qué valor gana?**
   El de `-var`. El orden es: default → `TF_VAR_` → `terraform.tfvars` → `*.auto.tfvars` → `-var-file` → `-var`, y el último gana.
4. **¿Qué protege `sensitive = true` y qué no?**
   Oculta el valor en la salida de `plan` y `apply`. No lo cifra: sigue en texto plano en `terraform.tfstate`, por lo que el estado debe protegerse aparte.
5. **¿Por qué `entorno` no tiene `default` en el ejemplo?**
   Para que sea obligatoria: nadie despliega en un entorno "por defecto" sin haberlo decidido explícitamente.
6. **¿Cuándo se evalúa un bloque `validation` y qué ventaja tiene en Topaz?**
   En el `plan`, antes de llamar a la API. En el emulador es especialmente útil porque sus mensajes de error ante valores inválidos no siempre coinciden con los de Azure; con `validation` el error lo da Terraform con tu texto.
7. **¿Por qué aplicar `prod.tfvars` sobre el estado de `dev` no crea un segundo entorno?**
   Porque el estado sigue apuntando a los mismos recursos: al cambiar los nombres, Terraform propone reemplazarlos. Para dos entornos simultáneos hace falta un estado por entorno (workspace o directorio).
8. **¿Cómo pasas un mapa por línea de comandos?**
   Con sintaxis HCL entre comillas simples: `-var 'etiquetas={equipo="infra"}'`.

---

## 9. Referencias

- [Variables de entrada](https://developer.hashicorp.com/terraform/language/values/variables) (declaración, validación, precedencia)
- [Valores locales](https://developer.hashicorp.com/terraform/language/values/locals) y [outputs](https://developer.hashicorp.com/terraform/language/values/outputs)
- [Restricciones de tipo](https://developer.hashicorp.com/terraform/language/expressions/type-constraints) (`object`, `optional()`, `any`)
- [Validación de variables](https://developer.hashicorp.com/terraform/language/expressions/custom-conditions#input-variable-validation)
- [Workspaces de la CLI](https://developer.hashicorp.com/terraform/cli/workspaces)
- [`merge()`](https://developer.hashicorp.com/terraform/language/functions/merge), [`contains()`](https://developer.hashicorp.com/terraform/language/functions/contains), [`can()`](https://developer.hashicorp.com/terraform/language/functions/can)
- [Recurso `azurerm_storage_account`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account) y [`azurerm_subnet`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet)
- [Azure Local Emulator (Topaz)](https://github.com/Azure/azure-local-emulator)