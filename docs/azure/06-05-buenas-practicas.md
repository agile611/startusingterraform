# 🛠️ Buenas prácticas

> En las cinco páginas anteriores has aplicado, casi sin nombrarlas, la mayoría de las prácticas que aquí se consolidan: interruptores con `count`, `locals` para las tags, sufijos aleatorios, validaciones, secretos fuera del código. Esta página las ordena y añade las que faltan: módulos, convención de nombres, estado remoto, mínimos privilegios, bloqueos, alertas, pruebas automáticas y un pipeline. El laboratorio es un módulo local de red que se prueba con `terraform test` contra **Topaz**; lo que el emulador no implementa (`Microsoft.Authorization`, `Microsoft.Insights`, `Microsoft.KeyVault`) se queda en `plan`.

**🎯 Objetivos de aprendizaje**
- Estructurar un proyecto con módulos locales, variables validadas, `locals` y outputs documentados.
- Aplicar una convención de nombres y tags obligatorias.
- Gestionar el estado: comandos `state`, backend remoto con Entra ID y bloqueo.
- Aplicar mínimos privilegios, bloqueos de borrado y alertas con los recursos correctos.
- Automatizar `fmt`, `validate`, `test`, análisis estático y `plan` en un pipeline sin secretos.

> **🔷 Requisitos previos.** [Páginas 1](index.md#pagina-1) a 5 completadas y destruidas, `~/tf-sql/providers.tf` disponible, Terraform `>= 1.6` (para `terraform test`; `terraform version`), `az account show --query environmentName -o tsv` → `Topaz`.

---

## 6.1. Estructura del proyecto y módulos

Un módulo es un directorio con archivos `.tf` que se invoca con un bloque `module`. El original usaba `Azure/network/azurerm` del registro público: está en mantenimiento, fija provider 2.x y oculta lo que hace. Empieza siempre con módulos **locales** que puedas leer; pasa al registro (Azure Verified Modules) cuando entiendas qué reemplazan.

```text
~/tf-bp/
├── providers.tf            # terraform {} + provider "azurerm" (copiado de tf-sql)
├── variables.tf            # entradas del root, con validation
├── locals.tf               # tags, nombres derivados
├── main.tf                 # grupo + llamada al módulo + recursos opcionales
├── outputs.tf
├── terraform.tfvars        # valores de este entorno (no se versiona si tiene secretos)
├── modules/
│   └── red/                # un módulo = un directorio
│       ├── main.tf
│       ├── variables.tf
│       └── outputs.tf
└── tests/
    └── red.tftest.hcl      # pruebas nativas (6.6)
```

```hcl
# modules/red/variables.tf
variable "nombre" {
  type        = string
  description = "Nombre de la VNet (con prefijo vnet-)"
  validation {
    condition     = startswith(var.nombre, "vnet-")
    error_message = "El nombre debe empezar por vnet- (convención del curso)."
  }
}
variable "resource_group_name" { type = string }
variable "location"            { type = string }
variable "espacio" {
  type        = string
  description = "CIDR de la VNet"
  default     = "10.0.0.0/16"
}
variable "subredes" {
  type        = map(number)                 # nombre => índice; el módulo calcula el CIDR con cidrsubnet
  description = "Subredes /24 dentro del espacio"
}
variable "tags" {
  type    = map(string)
  default = {}
}

# modules/red/main.tf
resource "azurerm_virtual_network" "this" {
  name                = var.nombre
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.espacio]
  tags                = var.tags
}

resource "azurerm_subnet" "this" {
  for_each             = var.subredes
  name                 = "snet-${each.key}"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [cidrsubnet(var.espacio, 8, each.value)]   # /16 + 8 bits = /24
}

# modules/red/outputs.tf
output "vnet_id"   { value = azurerm_virtual_network.this.id }
output "vnet_name" { value = azurerm_virtual_network.this.name }
output "subnet_ids" {
  description = "Mapa nombre => id, para NICs, private endpoints o peering"
  value       = { for k, s in azurerm_subnet.this : k => s.id }
}
```

```hcl
# main.tf (root)
resource "azurerm_resource_group" "bp" {
  name     = local.nombre_rg
  location = var.location
  tags     = local.tags
  lifecycle { ignore_changes = [tags] }     # Topaz no devuelve las tags del grupo
}

module "red" {
  source              = "./modules/red"    # ruta local: sin versión, se lee del disco en cada init
  nombre              = "vnet-${var.proyecto}-${var.entorno}"
  resource_group_name = azurerm_resource_group.bp.name
  location            = azurerm_resource_group.bp.location
  espacio             = "10.60.0.0/16"
  subredes            = { frontend = 1, backend = 2 }
  tags                = local.tags
}
```

| **Regla** | **Por qué** |
|---|---|
| El módulo no declara `provider` ni `backend` | Los hereda del root. Un módulo con provider propio no puede usarse con `for_each` ni destruirse limpiamente |
| Recibe el grupo y la ubicación como variables | Un módulo que crea su propio grupo no es reutilizable dentro de uno existente |
| Expone ids en outputs, no objetos completos | La interfaz estable es el id; el objeto cambia con cada versión del provider |
| Los módulos remotos llevan versión fija | `source = "Azure/avm-res-network-virtualnetwork/azurerm"` + `version = "0.x.y"`: sin versión, cada `init` puede traer cambios |

---

## 6.2. Variables, locals, nombres y tags

```hcl
# variables.tf (root)
variable "proyecto" {
  type        = string
  default     = "bp"
  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.proyecto))
    error_message = "Minúsculas y dígitos, 2-8 caracteres: forma parte de nombres con límite de longitud."
  }
}
variable "entorno" {
  type    = string
  default = "lab"
  validation {
    condition     = contains(["lab", "dev", "pre", "pro"], var.entorno)
    error_message = "Entornos permitidos: lab, dev, pre, pro."
  }
}
variable "location" {
  type    = string
  default = "eastus"
}
variable "propietario" {
  type        = string
  description = "Equipo o persona responsable (tag obligatoria)"
}
variable "email_alertas" {
  type    = string
  default = "ops@example.com"
}
variable "principal_id" {
  type        = string
  description = "Object ID que recibirá el rol Reader (null en Topaz)"
  default     = null
}
variable "asignar_rbac"      { type = bool, default = false }   # Microsoft.Authorization/roleAssignments
variable "bloquear"          { type = bool, default = false }   # Microsoft.Authorization/locks
variable "desplegar_alertas" { type = bool, default = false }   # Microsoft.Insights
variable "desplegar_kv"      { type = bool, default = false }   # Microsoft.KeyVault
variable "vm_id" {
  type        = string
  description = "Id de una VM existente para la alerta de CPU (null si no hay)"
  default     = null
}

# locals.tf
locals {
  nombre_rg = "rg-${var.proyecto}-${var.entorno}-001"          # rg-bp-lab-001
  tags = merge(
    {
      entorno     = var.entorno
      proyecto    = var.proyecto
      propietario = var.propietario
      gestion     = "terraform"
      coste       = "cc-${var.proyecto}"                        # centro de coste para la facturación
    },
    var.entorno == "pro" ? { criticidad = "alta" } : {}
  )
}

# terraform.tfvars
propietario = "equipo-plataforma"
```

| **Recurso** | **Patrón (Cloud Adoption Framework)** | **Ejemplo** |
|---|---|---|
| Grupo de recursos | `rg-<proyecto>-<entorno>-<nnn>` | `rg-bp-lab-001` |
| Red / subred / NSG | `vnet-`, `snet-`, `nsg-` | `vnet-bp-lab`, `snet-backend` |
| Cuenta de almacenamiento | `st<proyecto><sufijo>` (sin guiones, ≤ 24) | `stbpk7f2m9q1` |
| Key Vault / SQL | `kv-` (≤ 24), `sql-` + sufijo: nombres globales | `kv-bp-k7f2m9` |

> **🔷 Tags: pocas, obligatorias y calculadas.** El original ponía `Environment = "demo"` y `Owner = "admin"` a mano en cada recurso. Tres problemas: se escriben distinto en cada archivo, nadie las actualiza y "admin" no es un propietario. Con `local.tags` y `merge()` hay una sola definición, el propietario es una variable sin valor por defecto (obligatoria), y Azure Policy puede exigirlas en producción. En Topaz recuerda que el grupo necesita `ignore_changes = [tags]`.

---

## 6.3. El estado: comandos y backend remoto

El original decía "validar estado: `terraform validate`". `validate` comprueba la sintaxis del código y no lee el estado. El estado se inspecciona y se corrige con la familia `terraform state`:

```bash
terraform state list                                   # qué hay en el estado (incluye module.red.*)
terraform state show module.red.azurerm_subnet.this[\"backend\"]   # atributos de un recurso
terraform state mv module.red.azurerm_virtual_network.this module.red2.azurerm_virtual_network.this
                                                       # renombrar sin destruir (refactor de módulos)
terraform state rm azurerm_management_lock.rg[0]       # olvidar un recurso sin borrarlo en Azure
terraform import azurerm_resource_group.bp /subscriptions/.../resourceGroups/rg-bp-lab-001
                                                       # adoptar algo creado a mano (o bloque import {} desde 1.5)
terraform apply -replace=module.red.azurerm_subnet.this[\"frontend\"]   # forzar recreación de uno
terraform plan -refresh-only                           # ver drift sin proponer cambios
```

Mientras el estado sea un archivo local, solo una persona puede trabajar y un `rm` accidental lo destruye. El backend `azurerm` lo guarda en el contenedor de blobs de la [página 5](index.md#pagina-5), con bloqueo (lease) para que dos `apply` no colisionen:

```hcl
# providers.tf — bloque backend, SOLO en Azure real (ver cuadro)
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    random  = { source = "hashicorp/random",  version = "~> 3.6" }
  }
  backend "azurerm" {
    resource_group_name  = "rg-st-001"
    storage_account_name = "stlabXXXXXXXX"          # la cuenta de la [página 5](index.md#pagina-5)
    container_name       = "tfstate"                 # un contenedor dedicado, privado, con versionado
    key                  = "bp/lab.tfstate"          # una ruta por proyecto y entorno
    use_azuread_auth     = true                      # Entra ID: sin clave de cuenta; requiere Storage Blob Data Contributor
  }
}

# Migrar el estado local existente al backend:
#   terraform init -migrate-state
# Volver a local (por ejemplo, para destruir la cuenta):
#   comentar el bloque backend y  terraform init -migrate-state
```

> ⚠️ **En Topaz el backend `azurerm` no funciona.** El backend lee y escribe el blob del estado por el plano de datos (`blob.core.windows.net`), que el emulador no tiene ([página 5](index.md#pagina-5)). En el laboratorio el estado sigue siendo local y protegido por el `.gitignore`; el bloque `backend` se añade al pasar a Azure real. Nunca pongas la clave de cuenta en `access_key`: `use_azuread_auth` con tu identidad, o en CI con la identidad federada de la sección 6.7.

---

## 6.4. Seguridad: privilegios, secretos y cifrado

```hcl
# seguridad.tf
data "azurerm_client_config" "current" {}   # tenant y object id de quien ejecuta; sin llamada a ARM

# Mínimos privilegios: el rol MÁS BAJO que sirve, en el ámbito MÁS PEQUEÑO.
# El original daba Contributor (crear/borrar todo) a un service principal: es lo contrario.
resource "azurerm_role_assignment" "lectura" {
  count = var.asignar_rbac && var.principal_id != null ? 1 : 0

  scope                = azurerm_resource_group.bp.id     # el grupo, no la suscripción
  role_definition_name = "Reader"                         # o un rol específico: Network Contributor, Storage Blob Data Reader...
  principal_id         = var.principal_id                 # preferible una identidad gestionada, no un SP con secreto
}

# Key Vault: donde viven los secretos que Terraform genera (random_password) y las claves propias
resource "random_string" "sufijo" {
  length  = 6
  upper   = false
  special = false
}

resource "azurerm_key_vault" "bp" {
  count = var.desplegar_kv ? 1 : 0

  name                = "kv-${var.proyecto}-${random_string.sufijo.result}"   # 3-24, global
  resource_group_name = azurerm_resource_group.bp.name
  location            = azurerm_resource_group.bp.location
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"          # premium solo si necesitas claves respaldadas por HSM

  rbac_authorization_enabled = true         # permisos con roles (Key Vault Secrets User...), no con access policies
  purge_protection_enabled   = true         # nadie puede borrar definitivamente un secreto antes de la retención
  soft_delete_retention_days = 7            # 7-90; en producción 90

  public_network_access_enabled = true      # false + private endpoint en producción
  tags                          = local.tags
}
# El contenido (azurerm_key_vault_secret) va por el plano de datos vault.azure.net: solo Azure real.
# El patrón: value = random_password.admin.result; la aplicación lo lee con identidad gestionada.
```

| **Afirmación del original** | **Realidad** |
|---|---|
| `enabled_for_disk_encryption = true` "activa el cifrado en reposo" | Solo permite que Azure Disk Encryption lea claves de ese vault. El cifrado en reposo (SSE) está **siempre activo** en discos, Storage y SQL; lo que se decide es quién gestiona la clave (Microsoft o tú, *customer-managed key*) |
| "Cifrado en tránsito" | Se configura por servicio: `min_tls_version` y `https_traffic_only_enabled` (Storage), `minimum_tls_version` (SQL), `Encrypt=yes` en el cliente |
| `variable "admin_password" { sensitive = true }` protege la contraseña | Solo la oculta en la consola. Sigue en el estado y en el plan. Mejor: generarla con `random_password` ([página 4](index.md#pagina-4)), guardarla en Key Vault, o declararla `ephemeral = true` (Terraform ≥ 1.10) para que no se persista |
| Pasar secretos por variables de entorno | Correcto para CI: `TF_VAR_nombre` o `ARM_*`. Pero la mejor credencial es la que no existe: identidad gestionada u OIDC (6.7) |

---

## 6.5. Gobernanza: bloqueos, alertas y coste

```hcl
# gobernanza.tf
# Bloqueo de borrado: protege de un destroy accidental (también del tuyo: ver 6.9)
resource "azurerm_management_lock" "rg" {
  count = var.bloquear ? 1 : 0

  name       = "no-borrar"
  scope      = azurerm_resource_group.bp.id
  lock_level = "CanNotDelete"               # ReadOnly también impide modificar
  notes      = "Quitar con bloquear = false antes de destruir"
}

# Alerta: el original tenía namespace y métrica intercambiados, metric_name vacío
# y un management group como destino. Esto es lo que funciona:
resource "azurerm_monitor_action_group" "ops" {
  count = var.desplegar_alertas ? 1 : 0

  name                = "ag-${var.proyecto}-ops"
  resource_group_name = azurerm_resource_group.bp.name
  short_name          = "ops"               # máximo 12 caracteres; aparece en el SMS/correo
  email_receiver {
    name          = "guardia"
    email_address = var.email_alertas
  }
}

resource "azurerm_monitor_metric_alert" "cpu" {
  count = var.desplegar_alertas && var.vm_id != null ? 1 : 0

  name                = "alerta-cpu-alta"
  resource_group_name = azurerm_resource_group.bp.name
  scopes              = [var.vm_id]         # la VM de la [página 2](index.md#pagina-2), si existe
  description         = "CPU media > 80 % durante 5 minutos"
  severity            = 2                   # 0 crítico … 4 informativo
  frequency           = "PT1M"
  window_size         = "PT5M"

  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachines"   # el tipo de recurso
    metric_name      = "Percentage CPU"                      # la métrica
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 80
  }
    action { action_group_id = azurerm_monitor_action_group.ops[0].id }   # un action group, NO un management group
}
```

| **Campo de la alerta** | **Original** | **Correcto** |
|---|---|---|
| `metric_namespace` | `"Percentage CPU"` | `"Microsoft.Compute/virtualMachines"`: el tipo de recurso |
| `metric_name` | `""` | `"Percentage CPU"`; lista completa con `az monitor metrics list-definitions --resource <id>` |
| `time_aggregation` | no existe | `aggregation` |
| `action_group_id` | `azurerm_management_group` (jerarquía de suscripciones) | `azurerm_monitor_action_group`: quién recibe el aviso (correo, SMS, webhook, función) |
| `scopes` | `azurerm_virtual_machine` (recurso obsoleto) | Id de una `azurerm_linux_virtual_machine` ([página 2](index.md#pagina-2)), pasado por variable |

> **🔷 Coste: las cuatro medidas que más ahorran.**
> - **Destruir lo que no se usa.** Cada página del curso termina con `terraform destroy`: la VM de la [página 2](index.md#pagina-2) cuesta lo mismo parada que encendida si no está *deallocated*.
> - **Apagado automático.** `azurerm_dev_test_global_vm_shutdown_schedule` apaga (y desasigna) una VM a una hora fija; ideal para entornos lab y dev.
> - **Presupuesto con aviso.** `azurerm_consumption_budget_resource_group` envía al action group cuando el gasto supera el 80 % de lo previsto.
> - **Tag de centro de coste.** La tag `coste` de `local.tags` permite agrupar la factura por proyecto en Cost Management. Sin tags, la factura es un solo número.

---

## 6.6. Pruebas: fmt, validate, análisis estático y `terraform test`

El original reducía las pruebas a `tf validate` y `tf plan` (además, el binario se llama `terraform`). Hay cuatro niveles, de más barato a más caro, y cada uno detecta cosas que el anterior no ve:

| **Nivel** | **Comando** | **Detecta** | **Necesita Azure** |
|---|---|---|---|
| Formato | `terraform fmt -check -recursive` | Estilo inconsistente; falla en CI si alguien no formateó | No |
| Sintaxis y tipos | `terraform validate` | Argumentos inexistentes, referencias rotas, tipos incorrectos. No lee el estado ni llama a la API | No (sí `init`) |
| Análisis estático | `tflint --recursive`, `trivy config .` | Tamaños de VM inexistentes, nombres inválidos, TLS 1.0, contenedores públicos, secretos en claro | No |
| Comportamiento | `terraform test` | Que el módulo produce lo que promete: número de subredes, nombres, que rechaza entradas inválidas | `plan`: casi no; `apply`: sí (Topaz sirve) |

```hcl
# .tflint.hcl  (el ruleset azurerm conoce SKUs, tamaños y límites de nombre)
plugin "azurerm" {
  enabled = true
  version = "0.28.0"                       # consulta la última en el repositorio del ruleset
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}
rule "terraform_naming_convention" { enabled = true }    # snake_case en nombres de recursos y variables
rule "terraform_unused_declarations" { enabled = true }  # variables y locals que nadie usa

# Instalar y ejecutar
curl -s https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash
tflint --init && tflint --recursive

# Trivy (sucesor de tfsec): configuraciones inseguras
trivy config .                             # avisará de public_network_access_enabled = true en el Key Vault: esperado en lab
```

`terraform test` (Terraform ≥ 1.6) ejecuta archivos `.tftest.hcl` del directorio `tests/`. Cada bloque `run` hace un `plan` o un `apply` y comprueba `assert`. Lo que se crea con `apply` se destruye solo al terminar:

```hcl
# tests/red.tftest.hcl

# 1. El módulo rechaza un nombre sin el prefijo de la convención (prueba la validation, sin crear nada)
run "rechaza_nombre_sin_prefijo" {
  command = plan
  module { source = "./modules/red" }        # prueba el módulo directamente, no el root
  variables {
    nombre              = "red-sin-prefijo"
    resource_group_name = "rg-inexistente"
    location            = "eastus"
    subredes            = { a = 1 }
  }
  expect_failures = [var.nombre]             # la prueba PASA si la validación FALLA
}

# 2. El root planifica lo esperado (sin crear nada)
run "plan_root" {
  command = plan
  variables {
    propietario = "pruebas"
    entorno     = "dev"                      # nombres distintos a los del lab aplicado: sin colisiones
  }
  assert {
    condition     = azurerm_resource_group.bp.name == "rg-bp-dev-001"
    error_message = "El grupo no sigue la convención rg-<proyecto>-<entorno>-<nnn>."
  }
  assert {
    condition     = length(module.red.subnet_ids) == 2
    error_message = "Se esperaban dos subredes: frontend y backend."
  }
  assert {
    condition     = local.tags["propietario"] == "pruebas" && !contains(keys(local.tags), "criticidad")
    error_message = "Las tags no se calculan como se espera para un entorno que no es pro."
  }
}

# 3. Crea de verdad en Topaz, comprueba y destruye
run "apply_en_topaz" {
  command = apply
  variables {
    propietario = "pruebas"
    entorno     = "dev"
  }
  assert {
    condition     = startswith(module.red.vnet_name, "vnet-")
    error_message = "La VNet no lleva el prefijo vnet-."
  }
  assert {
    condition     = can(regex("/subnets/snet-backend$", module.red.subnet_ids["backend"]))
    error_message = "La subred backend no se ha creado con el nombre esperado."
  }
}
```

> **🔷 Qué probar y qué no.** Prueba la *lógica* que escribes tú: validaciones, nombres derivados, `for_each` sobre mapas, `merge` de tags, condicionales de `count`. No pruebes que Azure crea una VNet cuando se lo pides: eso lo prueba HashiCorp. Las pruebas con `command = plan` son gratis y rápidas; las de `apply` crean recursos (en Topaz, sin coste) y son la única forma de detectar errores que solo aparecen en la API, como un nombre que la validación local deja pasar.

---

## 6.7. Pipeline: plan en cada PR, apply con aprobación y sin secretos

El pipeline del original hacía `apply -auto-approve` en cada push a `main`, con acciones antiguas y, necesariamente, un secreto de service principal guardado en el repositorio. Tres cambios: el `plan` se ejecuta en la *pull request*, el `apply` solo tras aprobación humana, y la autenticación es **OIDC** (identidad federada): GitHub demuestra a Entra ID quién es y recibe un token de una hora. No hay ningún secreto que rotar ni que filtrar.

```bash
# Una vez, en Azure real: la identidad que usará el pipeline
APP_ID=$(az ad app create --display-name gh-tf-bp --query appId -o tsv)
az ad sp create --id "$APP_ID" -o none
az ad app federated-credential create --id "$APP_ID" --parameters '{
  "name":      "gh-environment-lab",
  "issuer":    "https://token.actions.githubusercontent.com",
  "subject":   "repo:MI_ORG/MI_REPO:environment:lab",      # solo jobs del environment "lab" de ese repo
  "audiences": ["api://AzureADTokenExchange"]
}'
RG_ID=$(az group show -n rg-bp-lab-001 --query id -o tsv)
ST_ID=$(az storage account show -g rg-st-001 -n stlabXXXXXXXX --query id -o tsv)
az role assignment create --assignee "$APP_ID" --role Contributor --scope "$RG_ID"     # crear recursos: solo en su grupo
az role assignment create --assignee "$APP_ID" --role "Storage Blob Data Contributor" --scope "$ST_ID"   # leer/escribir el estado
# Contributor NO puede asignar roles ni crear bloqueos: si el pipeline debe hacerlo, añade
# "Role Based Access Control Administrator" con condición, o gestiona RBAC desde otro pipeline con más privilegios.
```

```yaml
# .github/workflows/terraform.yml
name: terraform
on:
  pull_request:
    paths: ["**.tf", "**.tfvars", "tests/**", ".tflint.hcl"]
  push:
    branches: [main]

permissions:
  id-token: write          # pedir el token OIDC
  contents: read
  pull-requests: write     # comentar el plan en la PR

env:
  ARM_USE_OIDC:        "true"
  ARM_CLIENT_ID:       ${{ vars.AZURE_CLIENT_ID }}        # identificadores, no secretos: van en "variables"
  ARM_TENANT_ID:       ${{ vars.AZURE_TENANT_ID }}
  ARM_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}
  TF_VAR_propietario:  equipo-plataforma
  TF_IN_AUTOMATION:    "true"

jobs:
  verificar:
    runs-on: ubuntu-latest
    environment: lab                                       # el subject del federated credential exige este environment
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: "1.9.x" }
      - run: terraform fmt -check -recursive
      - run: terraform init -input=false
      - run: terraform validate
      - uses: terraform-linters/setup-tflint@v4
      - run: tflint --init && tflint --recursive
      - uses: aquasecurity/trivy-action@0.28.0
        with: { scan-type: config, scan-ref: ".", exit-code: "1", severity: "HIGH,CRITICAL" }
      - run: terraform test -filter=tests/red.tftest.hcl   # en Azure real, la run "apply" crea y destruye recursos de corta vida
      - run: terraform plan -input=false -no-color -out=tfplan
      - if: github.event_name == 'pull_request'            # el plan, visible en la PR para quien revisa
        run: terraform show -no-color tfplan > plan.txt && gh pr comment ${{ github.event.number }} -F plan.txt
        env: { GH_TOKEN: "${{ github.token }}" }

  aplicar:
    needs: verificar
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    environment: lab                                       # con "Required reviewers": el job espera a que alguien apruebe
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: "1.9.x" }
      - run: terraform init -input=false
      - run: terraform plan -input=false -out=tfplan       # se vuelve a planificar: el estado puede haber cambiado desde la PR
      - run: terraform apply -input=false tfplan           # aplica EXACTAMENTE ese plan, no "lo que haya"

  deriva:                                                  # detectar cambios hechos a mano: cada noche
    if: github.event_name == 'schedule'
    runs-on: ubuntu-latest
    environment: lab
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
      - run: terraform init -input=false
      - run: terraform plan -input=false -detailed-exitcode   # exit 2 = hay drift: el job falla y avisa
```

| **Decisión** | **Motivo** |
|---|---|
| `apply tfplan` en lugar de `apply -auto-approve` | Se aplica el plan revisado; si el estado cambió entre medias, Terraform rechaza el plan en vez de improvisar |
| `environment` con revisores | Es el "botón de aprobar": una persona ve el plan antes de que toque producción. Para `pro`, un environment distinto con otro federated credential y otro grupo |
| Versiones fijas de acciones y Terraform | Reproducibilidad. `checkout@v2` y `setup-terraform@v1` del original usan Node obsoleto y ya emiten avisos |
| Ningún `secrets.*` | Con OIDC no hay `ARM_CLIENT_SECRET`. Un secreto en el repo caduca, se filtra en logs y hay que rotarlo |
| Bloqueo del estado | El backend `azurerm` toma un *lease* del blob: si dos jobs coinciden, el segundo espera o falla con *state lock*, nunca corrompe |

---

## 6.8. Outputs y despliegue en Topaz

```hcl
# outputs.tf
output "grupo" {
  description = "Nombre del grupo, según la convención"
  value       = azurerm_resource_group.bp.name
}
output "vnet_id" {
  value = module.red.vnet_id                # los outputs del módulo se reexponen desde el root
}
output "subredes" {
  description = "Mapa nombre => id"
  value       = module.red.subnet_ids
}
output "tags_aplicadas" {
  value = local.tags                        # útil para comprobar el merge en test y en revisión
}
output "key_vault_uri" {
  value = one(azurerm_key_vault.bp[*].vault_uri)   # null si desplegar_kv = false
}
```

```bash
mkdir -p ~/tf-bp/modules/red ~/tf-bp/tests && cd ~/tf-bp
cp ~/tf-sql/providers.tf .                          # SIN bloque backend: en Topaz el estado es local
printf 'terraform.tfstate*\n.terraform/\n*.tfvars\ntfplan\n' > .gitignore
ls -R                                               # providers.tf variables.tf locals.tf main.tf seguridad.tf gobernanza.tf outputs.tf
                                                    # terraform.tfvars .tflint.hcl modules/red/{main,variables,outputs}.tf tests/red.tftest.hcl
terraform fmt -recursive                            # formatea todo, incluido el módulo
terraform init                                      # "Initializing modules... - red in modules/red"
terraform validate

# Pruebas ANTES del apply: la run "apply_en_topaz" usa entorno=dev, así que no colisiona con el lab
terraform test
#   tests/red.tftest.hcl... in progress
#     run "rechaza_nombre_sin_prefijo"... pass
#     run "plan_root"... pass
#     run "apply_en_topaz"... pass
#   Success! 3 passed, 0 failed.

terraform plan
#   Plan: 5 to add: grupo, random_string, vnet, snet-frontend, snet-backend
#   (rol, bloqueo, action group, alerta y Key Vault: count = 0, declarados)
terraform apply -auto-approve

terraform state list                                # fíjate en el prefijo module.red.
terraform output tags_aplicadas
az group show -n rg-bp-lab-001 --query tags         # {} en Topaz: por eso el ignore_changes
az network vnet subnet list -g rg-bp-lab-001 --vnet-name vnet-bp-lab -o table

# Ejercicios de plan: los interruptores se planifican aunque Topaz no los implemente
terraform plan -var entorno=prod                    # falla: "Entornos permitidos: lab, dev, pre, pro"
terraform plan -var bloquear=true                   # + azurerm_management_lock.rg[0]
terraform plan -var desplegar_alertas=true          # + action group; la alerta sigue en 0 porque vm_id es null
terraform plan -var desplegar_kv=true               # + azurerm_key_vault.bp[0]
terraform plan -var proyecto=bp -var entorno=pro    # tags_aplicadas incluye criticidad = "alta"

# Refactor sin destruir: renombra el módulo en main.tf a "red_principal" y luego
terraform state mv module.red module.red_principal  # o un bloque moved {} en el código, que es la forma declarativa
terraform plan                                      # No changes

terraform destroy -auto-approve
```

> **🔷 Al pasar a Azure real.** Añade el bloque `backend` de 6.3 apuntando a la cuenta de la [página 5](index.md#pagina-5) (con un contenedor `tfstate` nuevo), `terraform init -migrate-state`, y activa los interruptores de uno en uno: `asignar_rbac` con tu Object ID, `bloquear`, `desplegar_alertas` (y `vm_id` si tienes la VM de la [página 2](index.md#pagina-2)), `desplegar_kv`. Recuerda que el bloqueo protege también contra ti: antes de `destroy`, `bloquear = false` y `apply`.

---

## 6.9. Errores comunes

> ⚠️ **Solución de problemas**
> 
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | *Module not installed* | Has añadido o cambiado un bloque `module`. `terraform init` otra vez; los módulos, aunque sean locales, se registran en `init` |
> | *Unsupported argument* en la llamada al módulo | Le pasas una variable que `modules/red/variables.tf` no declara. La interfaz del módulo son sus variables: declárala o quita el argumento |
> | *Unsupported attribute* en `module.red.algo` | El root solo ve lo que el módulo expone en `outputs.tf`. Añade el output |
> | *Output refers to sensitive values* | Un output deriva de algo marcado `sensitive` (contraseña, cadena de conexión). Márcalo `sensitive = true` también |
> | *Backend configuration changed* / *Backend initialization required* | Has añadido, quitado o editado el bloque `backend`. `terraform init -migrate-state` para mover el estado, `-reconfigure` para descartar el anterior (asegúrate de saber cuál quieres) |
> | *Error acquiring the state lock* | Otro `apply` en curso, o uno que murió sin soltar el lease. Si estás seguro de que no hay nadie: `terraform force-unlock <ID>`; con el backend azurerm también `az storage blob lease break` |
> | *no such host* al hacer `init` con backend en Topaz | El backend usa el plano de datos del blob, que el emulador no tiene. Sin bloque `backend` en Topaz; estado local |
> | *ScopeLocked* / *The scope … is locked* al destruir o modificar | El bloqueo `CanNotDelete` haciendo su trabajo. `terraform destroy` intenta borrar recursos en paralelo antes de quitar el lock. Primero `bloquear = false` + `apply`, después `destroy` |
> | *AuthorizationFailed* al crear `azurerm_role_assignment` o `azurerm_management_lock` | Contributor no puede asignar roles ni bloqueos. Necesitas Owner, *User Access Administrator* o *Role Based Access Control Administrator* en ese ámbito |
> | *RoleAssignmentExists* | Alguien lo creó desde el portal. Impórtalo: bloque `import { to = azurerm_role_assignment.lectura[0], id = "/subscriptions/…/roleAssignments/<guid>" }` |
> | *Invalid metric namespace* / *metric name not found* en la alerta | `metric_namespace` debe ser el tipo de recurso (`Microsoft.Compute/virtualMachines`) y `metric_name` la métrica (`Percentage CPU`). Comprueba con `az monitor metrics list-definitions --resource <id> -o table` |
> | *VaultAlreadyExists* / *ConflictError: A vault with the same name already exists in deleted state* | El Key Vault tiene soft delete: el nombre queda reservado 7-90 días tras borrarlo. Recupéralo (`az keyvault recover -n kv-…`) o purga si no hay `purge_protection`; con protección, espera o cambia el sufijo |
> | *Test run failed* con *rechaza_nombre_sin_prefijo* "expected failure but succeeded" | Has quitado o relajado la `validation` de `nombre` en el módulo. La prueba existe precisamente para detectar eso: restáurala |
> | `terraform test` deja recursos *rg-bp-dev-001* en Topaz | La run `apply` falló a medias o se interrumpió con Ctrl+C. Terraform intenta destruir lo creado; si no pudo, `az group delete -n rg-bp-dev-001 -y` |
> | *Error: Provider produced inconsistent final plan* en el job `aplicar` | El plan guardado ya no coincide con la realidad (alguien cambió algo entre PR y merge). Es la protección funcionando: el job vuelve a planificar en su propio paso, revisa la diferencia |
> | *AADSTS70021: No matching federated identity record found* en el pipeline | El `subject` del federated credential no coincide con el job: repositorio, environment o rama distintos. Compara con `repo:ORG/REPO:environment:lab` y con el `environment:` del workflow |
> | `terraform fmt -check` falla en CI y en local pasa | Sin `-recursive` el formato no llega a `modules/` ni a `tests/`. Usa `terraform fmt -recursive` antes de subir; mejor aún, un hook de pre-commit |
> | El `plan` quiere destruir y recrear todo el módulo tras renombrarlo | Cambiar `module "red"` por `module "red_principal"` cambia las direcciones del estado. Añade `moved { from = module.red to = module.red_principal }` o `terraform state mv` antes de aplicar |

---

## 6.10. Autoevaluación

1. **¿Por qué un módulo no debe declarar su propio `provider`?**
   Lo hereda del root. Con provider propio no admite `count` ni `for_each`, y al quitar la llamada al módulo Terraform no puede destruir sus recursos porque el provider desaparece con él.
2. **¿Qué diferencia hay entre `terraform validate` y `terraform state list`?**
   `validate` comprueba la sintaxis y las referencias del código, sin leer el estado ni llamar a Azure. `state list` muestra lo que Terraform cree que existe. El original los confundía.
3. **¿Por qué el backend `azurerm` no funciona en Topaz?**
   Lee y escribe el blob del estado por el plano de datos (`blob.core.windows.net`), que el emulador no implementa. En Topaz el estado es local; el bloque `backend` se añade en Azure real con `init -migrate-state`.
4. **¿Por qué asignar `Contributor` a un service principal no es "mínimos privilegios"?**
   Contributor puede crear y borrar cualquier recurso del ámbito. Mínimos privilegios es el rol más bajo que sirve (Reader, Network Contributor, Storage Blob Data Reader) en el ámbito más pequeño (grupo o recurso), y preferiblemente sobre una identidad gestionada sin secreto.
5. **¿Qué hace realmente `enabled_for_disk_encryption` en un Key Vault?**
   Permite que Azure Disk Encryption lea claves de ese vault. No "activa el cifrado": el cifrado en reposo está siempre activo en Azure; lo que se elige es si la clave la gestiona Microsoft o tú.
6. **¿Qué protege `sensitive = true` y qué no?**
   Oculta el valor en la salida de consola. No lo quita del estado ni del plan. Para eso: `random_password` + Key Vault, o `ephemeral = true` en Terraform ≥ 1.10.
7. **¿Qué tres cosas estaban mal en la alerta del original?**
   Namespace y métrica intercambiados (`metric_name` vacío), `time_aggregation` en lugar de `aggregation`, y un management group como destino en vez de un `azurerm_monitor_action_group`.
8. **¿Por qué `terraform destroy` falla con `bloquear = true`?**
   El bloqueo `CanNotDelete` impide borrar los recursos del grupo, y destroy intenta borrarlos antes de quitar el propio lock. Primero `bloquear = false` y `apply`, después `destroy`.
9. **¿Qué significa `expect_failures = [var.nombre]` en una prueba?**
   Que la prueba pasa si la `validation` de esa variable falla. Sirve para comprobar que el módulo rechaza entradas inválidas, sin crear nada.
10. **¿Por qué el pipeline hace `apply tfplan` y no `apply -auto-approve`?**
    Aplica exactamente el plan que se revisó. Si el estado cambió entre medias, Terraform rechaza el plan en lugar de improvisar cambios que nadie ha visto.
11. **¿Qué ventaja tiene OIDC frente a un secreto de service principal en GitHub?**
    No hay secreto: GitHub demuestra su identidad a Entra ID y recibe un token de una hora, limitado al repositorio y environment del `subject`. Nada que rotar, nada que filtrar en logs.

---

## 6.11. Referencias

- [Desarrollo de módulos](https://developer.hashicorp.com/terraform/language/modules/develop), [guía de estilo de Terraform](https://developer.hashicorp.com/terraform/language/style) y [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/)
- [Comandos `terraform state`](https://developer.hashicorp.com/terraform/cli/commands/state), [bloque `moved`](https://developer.hashicorp.com/terraform/language/moved) e [bloque `import`](https://developer.hashicorp.com/terraform/language/import)
- [Backend `azurerm`](https://developer.hashicorp.com/terraform/language/backend/azurerm) y [almacenar el estado en Azure Storage](https://learn.microsoft.com/es-es/azure/developer/terraform/store-state-in-azure-storage)
- [Convención de nombres (CAF)](https://learn.microsoft.com/es-es/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming), [estrategia de tags](https://learn.microsoft.com/es-es/azure/cloud-adoption-framework/ready/azure-best-practices/resource-tagging) y [bloqueos de recursos](https://learn.microsoft.com/es-es/azure/azure-resource-manager/management/lock-resources)
- [Buenas prácticas de RBAC](https://learn.microsoft.com/es-es/azure/role-based-access-control/best-practices) y [buenas prácticas de Key Vault](https://learn.microsoft.com/es-es/azure/key-vault/general/best-practices)
- [`azurerm_monitor_metric_alert`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_metric_alert), [`azurerm_monitor_action_group`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_action_group) y [métricas de `Microsoft.Compute/virtualMachines`](https://learn.microsoft.com/es-es/azure/azure-monitor/reference/supported-metrics/microsoft-compute-virtualmachines-metrics)
- [`terraform test`](https://developer.hashicorp.com/terraform/language/tests), [variables `ephemeral`](https://developer.hashicorp.com/terraform/language/values/variables#ephemeral-variables), [tflint-ruleset-azurerm](https://github.com/terraform-linters/tflint-ruleset-azurerm) y [Trivy (misconfiguration)](https://trivy.dev/latest/docs/scanner/misconfiguration/)
- [OIDC entre GitHub Actions y Azure](https://learn.microsoft.com/es-es/azure/developer/github/connect-from-azure-openid-connect), [autenticación OIDC del provider azurerm](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/service_principal_oidc) y [environments con revisores en GitHub](https://docs.github.com/actions/deployment/targeting-different-environments/using-environments-for-deployment)
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)