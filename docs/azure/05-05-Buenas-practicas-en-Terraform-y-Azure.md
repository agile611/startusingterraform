## 1. Estructura del proyecto

Terraform lee todos los `.tf` de un directorio como una sola configuración, así que la división en archivos es para las personas. La convención que verás en casi cualquier repositorio profesional es esta, y es la que construirás en la sección 5.8:

```text
tf-buenas-practicas/
├── providers.tf            # bloque terraform {} (versiones) y provider "azurerm"
├── variables.tf            # entradas del módulo raíz, con type, description y validation
├── main.tf                 # locals y llamadas a módulos; pocos recursos sueltos
├── outputs.tf              # lo que el proyecto expone
├── envs/
│   ├── dev.tfvars          # solo lo que difiere del default
│   └── prod.tfvars
├── modules/
│   ├── red/                # un módulo = un componente con una responsabilidad
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   ├── outputs.tf
│   │   └── README.md       # generado con terraform-docs
│   └── storage/
│       └── ...
├── tests/
│   └── proyecto.tftest.hcl # pruebas nativas (terraform test)
├── .gitignore
├── .terraform.lock.hcl     # SÍ se versiona
└── README.md
```

| **Práctica** | **Por qué** |
|---|---|
| Un archivo por función (`providers`, `variables`, `main`, `outputs`) | Quien abre el repositorio sabe dónde mirar sin leer nada |
| Módulos en `modules/`, un componente por módulo | Se prueban, documentan y versionan por separado |
| Un `.tfvars` por entorno en `envs/` | El mismo código para todos; solo cambian valores |
| Un estado por entorno (workspace o backend distinto) | Nunca dos `.tfvars` sobre el mismo estado |
| `.terraform.lock.hcl` en Git; `.terraform/` y `*.tfstate*` fuera | Todos usan el mismo provider exacto; el estado nunca se filtra |

```text
# .gitignore mínimo para cualquier proyecto Terraform
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
crash.log
*.auto.tfvars          # ajustes personales y secretos
.terraform.tfstate.lock.info
```

---

## 2. Módulos

Un módulo es un directorio con archivos `.tf` que se invoca con un bloque `module`. Sus variables son la entrada, sus outputs la única salida. Conviene crear uno cuando un conjunto de recursos se repite (la red de cada entorno, la cuenta de almacenamiento con la configuración corporativa) o cuando quieres imponer una configuración segura por defecto.

```hcl
# Invocación de un módulo local
module "red" {
  source = "./modules/red"

  nombre              = "vnet-${local.prefijo}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  address_space       = var.address_space
  subredes            = var.subredes
  tags                = local.tags
}

# Consumo de sus outputs
output "subredes" {
  value = module.red.subred_ids
}
```

✅ **Reglas de un buen módulo**
- **Sin bloque `provider`**: solo `required_providers`. El módulo hereda el provider del raíz; así funciona igual contra Topaz y contra Azure real.
- **Interfaz pequeña y documentada**: pocas variables, todas con `type`, `description` y `validation`; outputs con `description`.
- **Valores seguros por defecto**: HTTPS obligatorio, TLS 1.2, replicación mínima. Quien lo use tiene que pedir explícitamente lo menos seguro.
- **Una responsabilidad**: "red" o "storage", no "toda la infraestructura".
- **Versión fijada** cuando el módulo es remoto: `source = "git::https://...?ref=v1.2.0"` o `version = "~> 0.4"` en el Registry.

> **🔷 En Topaz.** El módulo público `Azure/network/azurerm` que citaba el original está sin mantenimiento y sus versiones antiguas no son compatibles con el provider 4.x. La referencia actual de Microsoft son los **Azure Verified Modules** (`Azure/avm-res-network-virtualnetwork/azurerm`, etc.), pero crean recursos auxiliares (bloqueos, diagnósticos, roles) que el emulador no implementa. En el laboratorio se usan módulos locales; en una suscripción real, empieza por los AVM antes de escribir los tuyos.

---

## 3. Versiones, variables y estado

### 3.1. Fijar versiones

```hcl
terraform {
  required_version = ">= 1.6.0, < 2.0.0"     # rango: acepta parches y menores, no un salto mayor
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"                     # 4.x, nunca 5.0
    }
  }
}
```
El `~>` en el provider dice "cualquier 4.x"; la versión exacta que se descargó queda en `.terraform.lock.hcl`. Versionar ese archivo es lo que garantiza que el compañero, el pipeline y tú usáis el mismo binario. Para actualizar de forma consciente: `terraform init -upgrade`, revisar el `plan`, y hacer commit del lock.

### 3.2. Variables

- `type`, `description` y, cuando hay un valor razonable, `default`. Sin excepciones.
- `validation` para todo lo que la API rechazaría: nombres, rangos, listas cerradas, CIDR. En Topaz importa más aún, porque el emulador no siempre reproduce los mensajes de error de Azure.
- Un `.tfvars` por entorno con solo lo que difiere; los cálculos (`merge`, prefijos) en `locals`.
- `sensitive = true` en secretos, valores fuera del repositorio (`TF_VAR_` o `*.auto.tfvars` ignorado).

### 3.3. Estado

El estado contiene todo: IDs, atributos y cualquier secreto que un recurso haya devuelto. Se trata como un secreto en sí mismo:

```hcl
# Azure real: backend remoto con bloqueo automático (lease de blob) y versionado
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstate<sufijo-unico>"
    container_name       = "tfstate"
    key                  = "buenas-practicas/prod.tfstate"
    use_azuread_auth     = true          # sin claves de cuenta: RBAC "Storage Blob Data Contributor"
  }
}
```

> **🔷 En Topaz.** El backend `azurerm` necesita el plano de datos de blobs (leer, escribir y bloquear el archivo), que el emulador no ofrece: la cuenta existe como recurso ARM pero no como servicio. En el laboratorio se usa el backend local, que ya implementa bloqueo (`.terraform.tfstate.lock.info`), y se practica la disciplina que sí es transferible: estado fuera de Git, un estado por entorno con workspaces, `terraform state list` antes de tocar nada y copia de seguridad antes de operaciones de `state mv` o `rm`.

```bash
# Rutinas de estado que funcionan igual en local y en remoto
terraform state list                              # qué gestiona este estado
terraform state pull > backup-$(date +%F).tfstate # copia antes de cirugía
terraform workspace list                          # un estado por entorno
```

---

## 4. Seguridad

### 4.1. Autenticación

El provider `azurerm` admite varias formas de autenticarse. De mejor a peor:

| **Método** | **Configuración** | **Cuándo** |
|---|---|---|
| OIDC (federación de identidad) | `use_oidc = true` + `client_id`, `tenant_id` | Pipelines (GitHub Actions, Azure DevOps): sin secretos almacenados |
| Identidad administrada | `use_msi = true` | Terraform ejecutándose en una VM o agente dentro de Azure |
| Azure CLI | Nada: hereda `az login` | Trabajo interactivo de una persona |
| Service principal con secreto | `ARM_CLIENT_SECRET` | Solo si no hay alternativa; rotar y caducar |

```hcl
# Azure real, pipeline con OIDC (el original mostraba solo features {} con un comentario: eso no configura nada)
provider "azurerm" {
  features {}
  use_oidc        = true
  client_id       = var.client_id        # o ARM_CLIENT_ID
  tenant_id       = var.tenant_id        # o ARM_TENANT_ID
  subscription_id = var.subscription_id  # o ARM_SUBSCRIPTION_ID
}
```

> **🔷 En Topaz.** El emulador no tiene Entra ID: la autenticación la aporta la sesión de `az login` contra la nube `Topaz`, y el provider la hereda sin más configuración que `metadata_host`, `resource_provider_registrations = "none"` y `subscription_id`. OIDC e identidades administradas no existen en el emulador.

### 4.2. Secretos

Tres reglas, ya conocidas de las páginas anteriores, que aquí se convierten en política:

1. **Ningún secreto en `.tf` ni en `.tfvars` versionados.** Entran por `TF_VAR_` o por un `*.auto.tfvars` en `.gitignore`.
2. **`sensitive = true`** en la variable y en cualquier output derivado. Oculta la consola; el estado sigue conteniéndolo, por eso el estado se protege.
3. **Evita que el secreto exista**: identidad administrada en lugar de claves de cuenta; y si hace falta uno, se lee de Key Vault en el momento de uso.

```hcl
# Azure real: leer un secreto de Key Vault sin que pase por el repositorio
data "azurerm_key_vault" "corp" {
  name                = "kv-corp-secrets"
  resource_group_name = "rg-seguridad"
}

data "azurerm_key_vault_secret" "token" {
  name         = "webhook-token"
  key_vault_id = data.azurerm_key_vault.corp.id
}
# Uso: data.azurerm_key_vault_secret.token.value (sensible; queda en el estado)
```

> **🔷 En Topaz.** Key Vault no forma parte del laboratorio con el emulador; el bloque anterior es para Azure real. Lo que sí practicas en Topaz es la separación: secreto en `TF_VAR_`, variable sensible, estado fuera de Git. Puedes comprobar con `git grep -i password` y `git grep -i key` que nada se ha colado.

> ⚠️ **Errores que se ven en repositorios reales**
> - `admin_password = "P@$$w0rd1234!"` en un `prod.tfvars` versionado (el original lo tenía).
> - `terraform.tfstate` en Git "porque es cómodo": contiene todas las claves de todas las cuentas.
> - Un único service principal *Owner* de la suscripción para todos los entornos: mínimo privilegio significa *Contributor* sobre el grupo de recursos del entorno, y nada más.
> - Secretos pasados con `-var`: quedan en el historial del shell y en los logs del pipeline.

---

## 5. Nombres, etiquetas y coste

La gobernanza empieza en el código: si el nombre y las etiquetas son correctos desde el primer `apply`, el informe de costes, la auditoría y el *on-call* funcionan solos.

### 5.1. Convención de nombres (Cloud Adoption Framework)

| **Recurso** | **Prefijo** | **Ejemplo** | **Restricción** |
|---|---|---|---|
| Grupo de recursos | `rg-` | `rg-webapp-prod-001` | Hasta 90 caracteres |
| Red virtual | `vnet-` | `vnet-webapp-prod` | Único en el grupo |
| Subred | `snet-` | `snet-web` | Único en la red |
| Cuenta de almacenamiento | `st` | `stwebappprod001` | 3-24, solo minúsculas y dígitos, **único global** |

Los `locals` centralizan el patrón para que nadie lo escriba a mano:

```hcl
locals {
  prefijo         = "${var.proyecto}-${var.entorno}"
  nombre_rg       = "rg-${local.prefijo}-001"
  nombre_vnet     = "vnet-${local.prefijo}"
  nombre_storage  = "st${var.proyecto}${var.entorno}${var.sufijo}"   # sin guiones
}
```

### 5.2. Etiquetas obligatorias, validadas en el plan

```hcl
variable "tags" {
  type        = map(string)
  description = "Etiquetas del proyecto. Obligatorias: propietario y coste"

  validation {
    condition     = alltrue([for k in ["propietario", "coste"] : contains(keys(var.tags), k)])
    error_message = "Las etiquetas 'propietario' y 'coste' son obligatorias."
  }
}

locals {
  # Las técnicas las añade el código; las de negocio vienen del .tfvars
  tags = merge(var.tags, {
    entorno  = var.entorno
    proyecto = var.proyecto
    gestion  = "terraform"
  })
}
```

> **🔷 En Topaz.** La validación se ejecuta en el `plan` y funciona igual en el emulador. Las etiquetas se aplican bien a redes y cuentas de almacenamiento; el grupo de recursos no las devuelve al leer, de ahí el `lifecycle { ignore_changes = [tags] }` que ya conoces. En Azure real, la misma regla se refuerza con **Azure Policy** (efecto *deny* si falta la etiqueta), que el emulador no implementa.

### 5.3. Coste

- **Destruye lo efímero**: un laboratorio o un entorno de pruebas termina con `terraform destroy`. `terraform plan -destroy` muestra antes qué se va a eliminar.
- **SKU por entorno**: `LRS` en dev, `GRS` o `ZRS` en prod; tamaños de VM pequeños fuera de producción. Son variables, no código.
- **Protege lo que no debe caer**: `lifecycle { prevent_destroy = true }` en recursos con datos hace que un `destroy` accidental falle en el `plan`. Funciona en Topaz porque es una comprobación de Terraform, no de Azure.
- **Azure real**: etiquetas como dimensión en *Cost Management*, presupuestos con alertas (`azurerm_consumption_budget_resource_group`), reservas para carga estable y autoescalado para la variable.

---

## 6. Documentación

La documentación de un módulo son sus `description`. `terraform-docs` las convierte en un `README.md` con tablas de variables, outputs y recursos, y lo mantiene al día en cada commit:

```bash
# Instalación en Linux (comprueba la última versión en la página de releases)
TD=v0.20.0
curl -sSLo /tmp/td.tar.gz "https://github.com/terraform-docs/terraform-docs/releases/download/${TD}/terraform-docs-${TD}-linux-amd64.tar.gz"
tar -xzf /tmp/td.tar.gz -C /tmp terraform-docs && sudo install /tmp/terraform-docs /usr/local/bin/

# Generar el README de un módulo
terraform-docs markdown table ./modules/red > ./modules/red/README.md
```

Con un archivo `.terraform-docs.yml` en la raíz puedes inyectar las tablas entre marcadores `<!-- BEGIN_TF_DOCS -->` y `<!-- END_TF_DOCS -->` de un README escrito a mano, para combinar explicación humana con referencia generada. Además del README, un buen proyecto tiene: un `CHANGELOG.md` en los módulos versionados, ejemplos en `examples/` y revisión de código obligatoria (un `plan` adjunto a cada *pull request*).

---

## 7. Pruebas y validación

Hay cuatro niveles, de más barato a más caro. Los tres primeros no necesitan Azure; el cuarto funciona contra Topaz:

| **Nivel** | **Herramienta** | **Detecta** | **¿Necesita Azure?** |
|---|---|---|---|
| Formato y sintaxis | `terraform fmt -check`, `terraform validate` | Errores de HCL, tipos, referencias rotas | No |
| Lint | `tflint` + ruleset azurerm | SKU inexistentes, nombres inválidos, variables sin usar | No |
| Seguridad estática | `trivy config` (sucesor de tfsec) o `checkov` | Storage sin HTTPS, TLS antiguo, acceso público | No |
| Pruebas de comportamiento | `terraform test` (nativo, ≥ 1.6); Terratest en Go | Que el módulo crea lo que promete | `plan`: solo provider; `apply`: sí, y Topaz sirve |

```bash
# Instalación de tflint y trivy en Linux
curl -s https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash
curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sudo sh -s -- -b /usr/local/bin

# .tflint.hcl en la raíz del proyecto
cat > .tflint.hcl <<'EOF'
plugin "azurerm" {
  enabled = true
  version = "0.28.0"
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}
EOF

# Rutina previa a cada commit
terraform fmt -recursive -check
terraform validate
tflint --init && tflint --recursive
trivy config .
```

Y la novedad que más cambia la forma de trabajar: las pruebas nativas. Un archivo `.tftest.hcl` define escenarios (`run`) con valores de variables y aserciones (`assert`) sobre el resultado. Con `command = plan` no toca Azure; con `command = apply` despliega, comprueba y destruye automáticamente al terminar, y el emulador es el sitio ideal para ejecutarlo sin coste:

```hcl
# tests/proyecto.tftest.hcl
variables {                                  # valores comunes a todos los run
  proyecto = "test"
  entorno  = "dev"
  tags     = { propietario = "ci", coste = "CC-0000" }
}

run "rechaza_entorno_invalido" {
  command = plan
  variables { entorno = "staging" }
  expect_failures = [var.entorno]            # la prueba pasa si la validación falla
}

run "rechaza_tags_sin_coste" {
  command = plan
  variables { tags = { propietario = "ci" } }
  expect_failures = [var.tags]
}

run "nombres_siguen_convencion" {
  command = plan
  assert {
    condition     = azurerm_resource_group.lab.name == "rg-test-dev-001"
    error_message = "El grupo debe llamarse rg-<proyecto>-<entorno>-001."
  }
  assert {
    condition     = module.storage.nombre == "sttestdev001"
    error_message = "La cuenta debe llamarse st<proyecto><entorno><sufijo>, sin guiones."
  }
}

run "despliega_en_topaz" {
  command = apply                            # crea, comprueba y destruye
  assert {
    condition     = length(module.red.subred_ids) == 2
    error_message = "Se esperaban 2 subredes por defecto."
  }
  assert {
    condition     = module.storage.solo_https == true
    error_message = "La cuenta debe exigir HTTPS."
  }
}
```

Lo ejecutarás en la sección siguiente, cuando el proyecto exista. La regla de oro: **cada validación que escribas merece una prueba con `expect_failures`**; si no, nadie sabrá cuándo dejó de funcionar.

---

## 8. Ejemplo completo: un proyecto con todas las prácticas

Vas a construir la estructura de la sección 5.1 desde cero. Es el mismo trío red-subredes-almacenamiento de las páginas anteriores, ahora organizado como lo haría un equipo: dos módulos locales con valores seguros por defecto, validaciones, etiquetas obligatorias, dos entornos, pruebas y documentación generada. El código completo se puede encontrar [https://github.com/agile611/startusingterraform/tree/main/azure/tf-buenas-practicas](aquí)

### Paso 1. Esqueleto

```bash
mkdir -p ~/tf-buenas-practicas/{modules/{red,storage},envs,tests} && cd ~/tf-buenas-practicas
git init -q
cat > .gitignore <<'EOF'
.terraform/
*.tfstate
*.tfstate.*
*.tfplan
crash.log
*.auto.tfvars
.terraform.tfstate.lock.info
EOF
```

### Paso 2. Módulo `red`

```hcl
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
```

```hcl
# modules/red/main.tf
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}
# Sin bloque provider: el módulo hereda el del raíz

resource "azurerm_virtual_network" "this" {
  name                = var.nombre
  location            = var.location
  resource_group_name = var.resource_group_name
  address_space       = var.address_space
  tags                = var.tags
}

resource "azurerm_subnet" "this" {
  for_each = var.subredes

  name                 = "snet-${each.key}"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [each.value]
}
```

```hcl
# modules/red/outputs.tf
output "vnet_id" {
  description = "ID de la red virtual"
  value       = azurerm_virtual_network.this.id
}

output "subred_ids" {
  description = "ID de cada subred, por nombre corto"
  value       = { for k, s in azurerm_subnet.this : k => s.id }
}
```

### Paso 3. Módulo `storage`

```hcl
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
```

```hcl
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
```

```hcl
# modules/storage/outputs.tf
output "nombre" {
  description = "Nombre de la cuenta"
  value       = azurerm_storage_account.this.name
}

output "id" {
  description = "ID de la cuenta"
  value       = azurerm_storage_account.this.id
}

output "solo_https" {
  description = "Si la cuenta exige HTTPS"
  value       = azurerm_storage_account.this.https_traffic_only_enabled
}
```

### Paso 4. Módulo raíz

```hcl
# providers.tf
terraform {
  required_version = ">= 1.6.0, < 2.0.0"
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

```hcl
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
```

```hcl
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
```

```hcl
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
```

### Paso 5. Entornos y pruebas

```hcl
# envs/dev.tfvars
proyecto = "webapp"
entorno  = "dev"
tags = {
  propietario = "equipo-web"
  coste       = "CC-1001"
}

# envs/prod.tfvars
proyecto            = "webapp"
entorno             = "prod"
storage_replicacion = "GRS"
subredes = {
  web  = "10.0.1.0/24"
  api  = "10.0.2.0/24"
  data = "10.0.3.0/24"
}
tags = {
  propietario = "equipo-web"
  coste       = "CC-1001"
  criticidad  = "alta"
}
```

Guarda el archivo de pruebas de la sección 5.7 como `tests/proyecto.tftest.hcl`.

### Paso 6. La rutina completa

```bash
terraform init
terraform fmt -recursive
terraform validate
tflint --init && tflint --recursive
trivy config .                                  # sin hallazgos: HTTPS y TLS1_2 ya están
terraform test                                  # 4 escenarios; el último despliega y destruye en Topaz
```

```text
tests/proyecto.tftest.hcl... in progress
  run "rechaza_entorno_invalido"... pass
  run "rechaza_tags_sin_coste"... pass
  run "nombres_siguen_convencion"... pass
  run "despliega_en_topaz"... pass
tests/proyecto.tftest.hcl... tearing down
tests/proyecto.tftest.hcl... pass

Success! 4 passed, 0 failed.
```

```bash
# Desplegar dev y prod, cada uno en su estado
terraform apply -var-file=envs/dev.tfvars -auto-approve          # Plan: 5 to add
terraform workspace new prod
terraform apply -var-file=envs/prod.tfvars -auto-approve         # Plan: 6 to add
az group list --query "[].name" -o tsv                           # rg-webapp-dev-001  rg-webapp-prod-001

# Documentar los módulos
terraform-docs markdown table ./modules/red     > ./modules/red/README.md
terraform-docs markdown table ./modules/storage > ./modules/storage/README.md

# Comprobar que nada sensible va al repositorio y hacer el primer commit
git status --short                              # ni tfstate ni .terraform/ aparecen
git add -A && git commit -qm "Proyecto base con módulos, pruebas y documentación"
```

> **🔷 En Topaz.** Si el emulador rechaza algún argumento de la cuenta de almacenamiento (por ejemplo `min_tls_version` en versiones antiguas del emulador), el error aparece en el `apply` con el nombre del argumento: elimínalo del módulo y anótalo como diferencia con Azure real. `StorageAccountAlreadyTaken` significa que otro alumno usa el mismo `proyecto`+`sufijo`: cambia `sufijo` en tu `.tfvars`.

### Paso 7. Limpieza

```bash
terraform destroy -var-file=envs/prod.tfvars -auto-approve
terraform workspace select default
terraform destroy -var-file=envs/dev.tfvars -auto-approve
terraform workspace delete prod
az group list -o table                          # vacío
```

---

## 9. Lista de comprobación

Resumen de todo lo anterior en una tabla para revisar antes de cada *pull request*. La última columna indica qué puedes practicar en el emulador:

| **Área** | **Comprobación** | **En Topaz** |
|---|---|---|
| Estructura | Archivos por función, módulos por componente, un `.tfvars` por entorno | ✅ |
| Versiones | `required_version`, `~>` en providers, lock file en Git | ✅ |
| Variables | `type` + `description` + `validation`; secretos con `sensitive` y fuera del repo | ✅ |
| Estado | Fuera de Git, uno por entorno, backend remoto con bloqueo | Local + workspaces; backend `azurerm` solo en Azure real |
| Autenticación | OIDC o identidad administrada; mínimo privilegio | Solo `az login`; el resto en Azure real |
| Nombres y etiquetas | Convención CAF en `locals`; etiquetas obligatorias validadas | ✅ (tags del grupo con `ignore_changes`) |
| Seguridad de recursos | HTTPS, TLS 1.2, sin acceso público, por defecto en los módulos | ✅ |
| Pruebas | `fmt`, `validate`, `tflint`, `trivy`, `terraform test` | ✅ incluido `command = apply` |
| Documentación | `README.md` con `terraform-docs`; `plan` en cada PR | ✅ |
| Gobernanza | Azure Policy, bloqueos de recursos, presupuestos | Solo Azure real |

Ocho de diez áreas se practican íntegramente en el emulador. Las dos restantes son mecanismos de la plataforma, no de Terraform, y se cubren en el módulo de Azure real.

---

## 10. Errores comunes

> ⚠️ **Solución de problemas**
> 
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | *Module not installed* | Módulo añadido después del `init`: vuelve a ejecutar `terraform init` |
> | *Unsupported argument* al invocar el módulo | Variable no declarada en `modules/x/variables.tf`: la interfaz del módulo es cerrada |
> | *Unsupported attribute* en `module.red.x` | Solo son visibles los outputs del módulo; añade uno |
> | *Variables not allowed* en `lifecycle` | `prevent_destroy` debe ser literal; no admite `var.` |
> | Provider dentro del módulo | Rompe la reutilización y el `for_each` sobre módulos: solo `required_providers` en el hijo |
> | `terraform test`: *No value for required variable* | Falta el bloque `variables {}` global del `.tftest.hcl` o el valor en el `run` |
> | `terraform test`: *Expected failure ... did not fail* | La validación que esperabas ya no rechaza ese valor: alguien la relajó. Es la prueba haciendo su trabajo |
> | El lock file cambia en cada máquina | Falta `.terraform.lock.hcl` en Git, o se ejecutó `init -upgrade` sin querer |
> | *Backend initialization required* con `backend "azurerm"` en Topaz | El emulador no ofrece plano de datos de blobs: usa backend local en el laboratorio |
> | *Missing newline after argument* con HTML en el `.tf` | Filtro de auto-enlace de Moodle: `sed -i 's/<[^>]*>//g' **/*.tf` |

---

## 11. Autoevaluación

1. **¿Por qué se versiona `.terraform.lock.hcl` pero no `.terraform/`?**
   El lock fija la versión exacta del provider para todo el equipo; `.terraform/` es la descarga, reproducible con `init`.
2. **¿Por qué un módulo no debe contener un bloque `provider`?**
   Hereda el del raíz; así el mismo módulo funciona contra Topaz y Azure real, y admite `for_each` y `count`.
3. **¿Qué significa "valores seguros por defecto" en un módulo?**
   Que la configuración más segura (HTTPS, TLS 1.2, sin acceso público) es la que sale sin indicar nada; relajarla exige una decisión explícita.
4. **¿Por qué el backend `azurerm` no funciona en Topaz y qué se practica en su lugar?**
   Necesita leer y escribir blobs, plano de datos que el emulador no implementa. Se practica la disciplina: estado fuera de Git, uno por entorno con workspaces, copias antes de operaciones de estado.
5. **¿Qué diferencia hay entre `terraform validate`, `tflint` y `trivy config`?**
   Sintaxis y tipos; reglas del provider (SKU, nombres); configuraciones inseguras. Ninguno necesita Azure.
6. **¿Para qué sirve `expect_failures` en `terraform test`?**
   Para comprobar que una validación rechaza lo que debe rechazar; la prueba pasa si la validación falla.
7. **¿Cómo se garantiza que todos los recursos llevan la etiqueta `coste`?**
   En Terraform, con una `validation` sobre `keys(var.tags)` y `merge` en `locals`; en Azure real, además con Azure Policy en modo *deny*.
8. **¿Qué método de autenticación usa un pipeline moderno y por qué?**
   OIDC (`use_oidc = true`): no hay ningún secreto almacenado que rotar o filtrar.

---

## 12. Referencias

- [Guía de estilo de Terraform](https://developer.hashicorp.com/terraform/language/style) (HashiCorp)
- [Desarrollo de módulos](https://developer.hashicorp.com/terraform/language/modules/develop) y [estructura estándar](https://developer.hashicorp.com/terraform/language/modules/develop/structure)
- [Pruebas nativas (`terraform test`)](https://developer.hashicorp.com/terraform/language/tests)
- [Archivo de bloqueo de dependencias](https://developer.hashicorp.com/terraform/language/files/dependency-lock)
- [Autenticación OIDC del provider azurerm](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/service_principal_oidc) y [backend `azurerm`](https://developer.hashicorp.com/terraform/language/backend/azurerm)
- [Convención de nombres (Cloud Adoption Framework)](https://learn.microsoft.com/es-es/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming) y [estrategia de etiquetado](https://learn.microsoft.com/es-es/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging)
- [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/)
- [tflint](https://github.com/terraform-linters/tflint), [ruleset azurerm](https://github.com/terraform-linters/tflint-ruleset-azurerm), [trivy](https://trivy.dev/) y [terraform-docs](https://terraform-docs.io/)
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)