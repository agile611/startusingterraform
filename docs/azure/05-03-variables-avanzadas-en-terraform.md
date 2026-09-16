## 1. Archivos `.tfvars` por entorno

Un archivo `.tfvars` contiene solo asignaciones `nombre = valor`, sin bloques `variable`. La convención es un archivo por entorno, con únicamente lo que difiere de los `default`:

```hcl
# dev.tfvars: casi todo por defecto
entorno = "dev"

# prod.tfvars: red más grande, replicación geográfica, más etiquetas
entorno = "prod"

subredes = {
  web  = { prefijo = "10.10.1.0/24" }
  api  = { prefijo = "10.10.2.0/24" }
  data = { prefijo = "10.10.3.0/24", endpoints = ["Microsoft.Storage"] }
}

storage = { replicacion = "GRS" }

etiquetas_extra = {
  coste      = "CC-12345"
  criticidad = "alta"
}
```

| **Archivo** | **¿Se carga solo?** | **Uso** |
|---|---|---|
| `terraform.tfvars` | Sí | Valores comunes del proyecto (no confundir con los `default`, que van en el bloque `variable`) |
| `*.auto.tfvars` | Sí, en orden alfabético | Ajustes personales o secretos, en `.gitignore` |
| `dev.tfvars`, `prod.tfvars` | No: `-var-file=prod.tfvars` | Un archivo por entorno, versionado |

Si una variable aparece en varios sitios gana el último de esta cadena: `default` → `TF_VAR_*` → `terraform.tfvars` → `*.auto.tfvars` → `-var-file`/`-var` en orden de aparición. Que un entorno no se cargue solo es una ventaja: obliga a decir explícitamente contra cuál se despliega.

---

## 2. Validación de variables

Cada bloque `validation` tiene una `condition` que debe ser verdadera y un `error_message`. Se evalúan en el `plan`, antes de cualquier llamada a la API. Tres patrones cubren casi todos los casos:

```hcl
# 1. Lista cerrada de valores
variable "entorno" {
  type        = string
  description = "Entorno de despliegue"
  validation {
    condition     = contains(["dev", "test", "prod"], var.entorno)
    error_message = "El entorno debe ser dev, test o prod."
  }
}

# 2. Rango numérico
variable "dias_retencion" {
  type        = number
  description = "Días de retención de blobs eliminados"
  default     = 7
  validation {
    condition     = var.dias_retencion >= 1 && var.dias_retencion <= 365
    error_message = "Entre 1 y 365 días."
  }
}

# 3. Formato con expresión regular (can() convierte el error de regex en false)
variable "proyecto" {
  type        = string
  description = "Nombre corto: se usa en el nombre de la cuenta de almacenamiento"
  default     = "webapp"
  validation {
    condition     = can(regex("^[a-z0-9]{2,10}$", var.proyecto))
    error_message = "Solo minúsculas y dígitos, de 2 a 10 caracteres, sin guiones."
  }
}
```

> **🔷 En Topaz.** Las validaciones valen más que en Azure real: el emulador no siempre devuelve los mismos mensajes que Azure ante un nombre o SKU inválido, así que un error de Terraform con tu texto ahorra depuración. Desde Terraform 1.9 la `condition` puede referenciar otras variables, lo que permite reglas como "GRS solo en prod".

---

## 3. Variables sensibles

`sensitive = true` hace que Terraform oculte el valor en la salida de `plan`, `apply` y `output`, y obliga a marcar también como sensibles los outputs que lo usen. Es una protección contra *logs*, no un cifrado. Compruébalo sin tocar Azure:

```hcl
variable "token_webhook" {
  type        = string
  description = "Token de un servicio externo"
  sensitive   = true
}

output "token" {
  value     = var.token_webhook
  sensitive = true                     # sin esto, Terraform da error
}
```

```bash
export TF_VAR_token_webhook="abc123-secreto"
terraform apply -auto-approve
#   Outputs:
#   token = <sensitive>                             ← oculto en consola

terraform output -raw token                          # abc123-secreto  (quien tiene el estado, lo tiene todo)
jq '.outputs.token.value' terraform.tfstate          # "abc123-secreto"  ← en texto claro
```

> ⚠️ **Corrección importante.** Algunos materiales afirman que las variables sensibles "no se guardan en el estado en texto claro". Es falso: acabas de verlo con `jq`. Las reglas reales son:
> - El secreto nunca va en un `.tf` ni en un `.tfvars` versionado (el ejemplo original tenía `admin_password = "P@$$w0rd1234!"` en `prod.tfvars`).
> - Se pasa por `TF_VAR_*` leído de un gestor de secretos, o por un `secretos.auto.tfvars` en `.gitignore`. No con `-var`, que queda en el historial del shell.
> - El estado se trata como un secreto: backend remoto con acceso restringido, nunca en Git.
> - En Azure real, los secretos viven en Key Vault y Terraform los lee con `data "azurerm_key_vault_secret"`.

Marca sensible la variable concreta, no un objeto completo: si `vm_config` entero es sensible, el plan ocultará también el tamaño y el nombre de usuario, y no podrás revisar lo que vas a aplicar.

---

## 4. Tipos complejos

`list` y `map` ya los conoces. Los dos que cambian la forma de trabajar son `object` con atributos opcionales y `map(object)`:

```hcl
# object con optional(): el usuario solo indica lo que quiere cambiar
variable "storage" {
  description = "Configuración de la cuenta de almacenamiento"
  type = object({
    tier        = optional(string, "Standard")
    replicacion = optional(string, "LRS")
    https_only  = optional(bool, true)
  })
  default = {}                                    # todo por defecto

  validation {
    condition     = contains(["LRS", "ZRS", "GRS"], var.storage.replicacion)
    error_message = "La replicación debe ser LRS, ZRS o GRS."
  }
}

# map(object): una entrada por subred, ideal para for_each
variable "subredes" {
  description = "Subredes de la red virtual, por nombre"
  type = map(object({
    prefijo   = string
    endpoints = optional(list(string), [])
  }))
  default = {
    web = { prefijo = "10.0.1.0/24" }
  }

  validation {
    condition     = alltrue([for s in var.subredes : can(cidrhost(s.prefijo, 0))])
    error_message = "Cada prefijo debe ser un CIDR válido, por ejemplo 10.0.1.0/24."
  }
}
```

| **Tipo** | **Cuándo usarlo** | **Cómo se recorre** |
|---|---|---|
| `list(string)` | Valores del mismo tipo con orden (rangos, IPs) | `var.x[0]`, `count` |
| `map(string)` | Clave-valor planos (etiquetas) | `var.x["clave"]`, `merge()` |
| `object({...})` | Configuración de *un* recurso con campos de tipos distintos | `var.x.campo` |
| `map(object({...}))` | *Varios* recursos del mismo tipo con configuración propia | `for_each = var.x`, `each.key`, `each.value.campo` |

Con `for_each` sobre un mapa, cada instancia se identifica por su clave (`azurerm_subnet.lab["web"]`): añadir o quitar una subred del mapa crea o destruye solo esa, sin renumerar las demás como haría `count`.

---

## 5. Ejemplo práctico en Topaz

> **🔷 En Topaz.** El emulador no incluye `Microsoft.Compute`, así que el ejemplo original con máquinas virtuales no puede ejecutarse. Red, subredes y almacenamiento sí están soportados y ejercitan los mismos conceptos: un `map(object)` decide cuántas subredes hay y cómo son, y un `object` configura la cuenta de almacenamiento.

### Paso 1. Estructura y provider

```bash
mkdir -p ~/tf-variables-avanzadas && cd ~/tf-variables-avanzadas
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

Las variables `entorno`, `proyecto`, `storage` y `subredes` de las secciones 2.2 y 2.4, más estas dos:

```hcl
variable "ubicacion" {
  type        = string
  description = "Región de Azure (nombre corto)"
  default     = "eastus"
}

variable "etiquetas_extra" {
  type        = map(string)
  description = "Etiquetas que se añaden a las comunes"
  default     = {}
}
```
`entorno` no tiene `default` a propósito: nadie despliega en un entorno que no ha elegido.

### Paso 3. `main.tf`

```hcl
locals {
  prefijo = "${var.proyecto}-${var.entorno}"
  tags = merge(
    { proyecto = var.proyecto, entorno = var.entorno, gestion = "terraform" },
    var.etiquetas_extra
  )
}

resource "azurerm_resource_group" "lab" {
  name     = "rg-${local.prefijo}-001"
  location = var.ubicacion
  tags     = local.tags

  lifecycle {
    ignore_changes = [tags]          # Topaz no devuelve las tags del grupo
  }
}

resource "azurerm_virtual_network" "lab" {
  name                = "vnet-${local.prefijo}"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = [var.entorno == "prod" ? "10.10.0.0/16" : "10.0.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "lab" {
  for_each = var.subredes

  name                 = "snet-${each.key}"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [each.value.prefijo]
  service_endpoints    = each.value.endpoints
}

resource "azurerm_storage_account" "lab" {
  name                      = "st${var.proyecto}${var.entorno}001"
  resource_group_name       = azurerm_resource_group.lab.name
  location                  = azurerm_resource_group.lab.location
  account_tier              = var.storage.tier
  account_replication_type  = var.storage.replicacion
  https_traffic_only_enabled = var.storage.https_only
  tags                      = local.tags
}

output "subredes" {
  value = { for k, s in azurerm_subnet.lab : k => s.address_prefixes[0] }
}
```

### Paso 4. Desplegar `dev`

Crea `dev.tfvars` y `prod.tfvars` con el contenido de la sección 2.1 y ejecuta:

```bash
terraform init
terraform validate                          # comprueba tipos y validaciones sin tocar Topaz
terraform plan -var-file=dev.tfvars
#   azurerm_subnet.lab["web"]        10.0.1.0/24
#   azurerm_storage_account.lab      stwebappdev001  LRS
#   Plan: 4 to add, 0 to change, 0 to destroy.
terraform apply -var-file=dev.tfvars -auto-approve
az resource list -g rg-webapp-dev-001 -o table
```

### Paso 5. Provocar las validaciones

```bash
terraform plan -var-file=dev.tfvars -var entorno=staging
#   Error: Invalid value for variable ... El entorno debe ser dev, test o prod.

terraform plan -var-file=dev.tfvars -var 'storage={replicacion="RAGRS"}'
#   La replicación debe ser LRS, ZRS o GRS.

terraform plan -var-file=dev.tfvars -var 'subredes={web={prefijo="10.0.1.0"}}'
#   Cada prefijo debe ser un CIDR válido, por ejemplo 10.0.1.0/24.
```
Los tres errores llegan antes de hablar con el emulador. Observa también que `-var` ha ganado a `-var-file`: es la precedencia de la sección 2.1.

### Paso 6. Desplegar `prod` en paralelo

Aplicar `prod.tfvars` sobre el mismo estado reemplazaría los recursos de `dev`. Cada entorno necesita su propio estado; el mecanismo más simple es un workspace:

```bash
terraform workspace new prod
terraform plan -var-file=prod.tfvars
#   azurerm_subnet.lab["web"]   ["api"]   ["data"] (con service_endpoints)
#   azurerm_storage_account.lab   stwebappprod001  GRS
#   Plan: 6 to add, 0 to change, 0 to destroy.
terraform apply -var-file=prod.tfvars -auto-approve

az group list --query "[].name" -o tsv      # rg-webapp-dev-001  rg-webapp-prod-001
```

Ahora edita `prod.tfvars`, elimina la subred `api` y vuelve a planificar: *Plan: 0 to add, 0 to change, 1 to destroy*, y solo `azurerm_subnet.lab["api"]`. Con `count`, quitar el elemento central habría renumerado y recreado `data`.

### Paso 7. Limpieza

```bash
terraform destroy -var-file=prod.tfvars -auto-approve
terraform workspace select default
terraform destroy -var-file=dev.tfvars -auto-approve
terraform workspace delete prod
az group list -o table                      # vacío
```

---

## 6. Buenas prácticas

✅ **Recomendaciones clave:**
- **Un `.tfvars` por entorno** con solo lo que difiere; los `default` cubren el resto.
- **Un estado por entorno** (workspace o directorio): nunca dos `.tfvars` sobre el mismo estado.
- **Valida lo que la API rechazaría**: listas cerradas, rangos, formatos de nombre, CIDR.
- **`optional()` en los objetos** para que el archivo de valores sea corto y legible.
- **`map(object)` + `for_each`** en lugar de `list` + `count` cuando los elementos tienen identidad.
- **`sensitive` en la variable concreta**, secreto fuera del repositorio y estado protegido.
- **`terraform validate` en cada commit**: comprueba tipos y validaciones sin red.

⚠️ **Errores comunes**

| **Mensaje** | **Causa y solución** |
|---|---|
| *Output refers to sensitive values* | Falta `sensitive = true` en el output |
| *attribute "endpoints" is required* | El atributo no está declarado como `optional()`, o la versión de Terraform es anterior a 1.3 |
| *The given key does not identify an element* | Referencia a `azurerm_subnet.lab["api"]` cuando esa clave no está en el mapa del entorno actual |
| Plan con `-/+ replace` masivo al cambiar de `.tfvars` | Dos entornos sobre un estado: usar workspaces |
| *Missing newline after argument* con HTML dentro del `.tf` | El filtro de auto-enlace de Moodle se coló al copiar: `sed -i 's/<[^>]*>//g' *.tf` |
| *StorageAccountAlreadyTaken* | Otro alumno usa el mismo `proyecto` en Topaz: cámbialo |

---

## 7. Autoevaluación

1. **¿Qué protege `sensitive = true` y qué no?**
   Oculta el valor en consola y obliga a marcar los outputs. No lo cifra: sigue en claro en `terraform.tfstate`.
2. **¿Por qué `dev.tfvars` no se carga automáticamente?**
   Solo `terraform.tfvars` y `*.auto.tfvars` se cargan solos. Los archivos de entorno exigen `-var-file`, lo que evita desplegar en el entorno equivocado por descuido.
3. **¿Ventaja de `map(object)` + `for_each` sobre `list` + `count`?**
   Cada instancia tiene una clave estable; quitar un elemento destruye solo ese, sin renumerar y recrear los demás.
4. **¿Qué aporta `optional(string, "LRS")`?**
   Que el `.tfvars` solo indique lo que cambia; el resto del objeto toma el valor por defecto.
5. **¿Cuándo se evalúa una `validation` y por qué importa en Topaz?**
   En el `plan`, antes de la API. El emulador no siempre reproduce los mensajes de error de Azure, así que el error de Terraform es más claro.
6. **¿Por qué el ejemplo original con VM no funciona?**
   Topaz no incluye Compute; además referenciaba una interfaz de red no declarada, usaba una imagen retirada y guardaba la contraseña en un `.tfvars` versionado.

---

## 8. Referencias

- [Variables de entrada](https://developer.hashicorp.com/terraform/language/values/variables) (precedencia, `sensitive`, `validation`)
- [Restricciones de tipo](https://developer.hashicorp.com/terraform/language/expressions/type-constraints) (`object`, `optional()`)
- [Meta-argumento `for_each`](https://developer.hashicorp.com/terraform/language/meta-arguments/for_each)
- [Workspaces](https://developer.hashicorp.com/terraform/cli/workspaces)
- [Datos sensibles en el estado](https://developer.hashicorp.com/terraform/language/state/sensitive-data)
- [`azurerm_subnet`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) y [`azurerm_storage_account`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account)
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)