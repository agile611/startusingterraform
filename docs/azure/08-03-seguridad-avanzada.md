# 🔐 Seguridad avanzada: secretos, identidad, guardarraíles

> La seguridad de una plataforma gestionada con Terraform tiene cuatro capas y cada una falla de forma distinta: el **código** (un secreto en un `.tf` vive para siempre en Git), el **estado** (guarda en claro todo lo que el provider devuelve, marcado como `sensitive` o no), la **identidad** con la que Terraform actúa (si puede hacerlo todo, un error lo hace todo) y la **configuración de los recursos** que despliega. Esta página recorre las cuatro con las herramientas que el propio Terraform trae desde 1.10/1.11 (valores `ephemeral`, atributos *write-only*, bloques `check`) y con las de Azure (Key Vault con RBAC, identidades gestionadas, Azure Policy, locks). Todo lo que es plano de gestión y todo lo que es puro Terraform funciona en **Topaz**; lo que exige el plano de datos de Key Vault, Policy o RBAC se marca como Azure real.

**🎯 Objetivos de aprendizaje**
- Demostrar que `sensitive` no protege el estado y evitar que un secreto llegue a él con `ephemeral` y `value_wo`.
- Crear un Key Vault endurecido (RBAC, *soft delete*, *purge protection*, red cerrada, diagnóstico) y escribir y leer secretos sin exponerlos.
- Configurar el provider con identidad gestionada u OIDC y repartir permisos con mínimo privilegio.
- Poner guardarraíles en dos tiempos: `plan` (`validation`, `check`, Trivy/Checkov) y `apply` (Azure Policy, locks).
- Tratar el estado como el secreto que es.

> **🔷 Requisitos previos.** Páginas 1 a 12 completadas y destruidas, `~/tf-st/providers.tf` disponible, Terraform `>= 1.11` (atributos *write-only*), provider `random >= 3.7` (recurso `ephemeral`), `jq`, opcionalmente `trivy` y `gitleaks`, `az account show --query environmentName -o tsv` → `Topaz`.

---

## 1. Dónde se filtra un secreto

| **Lugar** | **Cómo llega** | **Defensa** |
|---|---|---|
| Código y Git | Literal en `.tf` (el original), `terraform.tfvars` con contraseñas, `.tfstate` local commiteado | `.gitignore` (`*.tfstate*`, `*.tfvars`, `.terraform/`), gitleaks en pre-commit y CI; los secretos se generan (`random_password`) o se leen (Key Vault), nunca se escriben |
| Plan y logs | `plan` muestra valores; `show -json` los muestra *todos*; el artefacto `tfplan` los contiene | `sensitive = true` oculta en consola; `ephemeral` ni siquiera lo incluye; artefactos con retención corta (página 12) |
| Estado | Todo atributo que el provider devuelve: contraseñas de `random_password`, claves de cuenta, cadenas de conexión. `sensitive` **no** lo cifra | Backend endurecido (13.5); valores `ephemeral` y atributos *write-only* (`value_wo`) que no se guardan; `shared_access_key_enabled = false` para que no haya claves que guardar |
| Identidad de Terraform | `ARM_CLIENT_SECRET` en variables de CI, SP con *Owner* en la suscripción | OIDC / identidad gestionada (13.3): sin secreto; roles acotados al grupo y separados plan/apply |
| Recursos desplegados | Cuenta con acceso público, Key Vault con *access policies* abiertas, TLS 1.0 | Guardarraíles en `plan` (13.4) y Azure Policy en `apply`; módulos con valores seguros por defecto (página 11) |

---

## 2. Secretos: Key Vault sin que el secreto pase por Terraform

El bloque del original tiene el secreto en el código y, aunque lo moviéramos a una variable, acabaría en el estado: el recurso `azurerm_key_vault_secret` guarda `value`. La solución moderna son tres piezas: un **recurso `ephemeral`** que genera la contraseña sin persistirla, un **atributo *write-only*** (`value_wo`) que la escribe en Key Vault sin guardarla, y un **data `ephemeral`** para leerla cuando otro recurso la necesite. Terraform solo conserva `value_wo_version`, un entero que subes cuando quieres rotar.

```hcl
data "azurerm_client_config" "actual" {}

resource "azurerm_key_vault" "moodle" {
  name                          = "kv-moodle-${var.entorno}-${random_string.sufijo.result}"   # 3-24 chars, único global
  resource_group_name           = azurerm_resource_group.moodle.name
  location                      = azurerm_resource_group.moodle.location
  tenant_id                     = data.azurerm_client_config.actual.tenant_id
  sku_name                      = "standard"
  rbac_authorization_enabled    = true          # roles de Azure, no access policies: auditable y con PIM
  soft_delete_retention_days    = 90
  purge_protection_enabled      = var.entorno == "pro"   # en pro: irreversible 90 días. En lab: false, o no podrás destruir
  public_network_access_enabled = false
  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = var.ips_admin                        # solo en entornos sin Private Endpoint
  }
  tags = local.tags
}
# Quien ejecuta Terraform necesita escribir secretos: rol acotado al vault, no al grupo (solo Azure real)
resource "azurerm_role_assignment" "tf_secrets_officer" {
  scope                = azurerm_key_vault.moodle.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.actual.object_id
}

# 1. Generar sin persistir (random >= 3.7, Terraform >= 1.10)
ephemeral "random_password" "db" {
  length           = 32
  override_special = "!#$%&*()-_=+[]{}<>:?"
}
# 2. Escribir sin guardar (Terraform >= 1.11; azurerm 4.x)
resource "azurerm_key_vault_secret" "db" {
  name             = "moodle-db-password"
  key_vault_id     = azurerm_key_vault.moodle.id
  value_wo         = ephemeral.random_password.db.result   # no aparece en plan ni en estado
  value_wo_version = 1                                     # súbelo a 2 para rotar: Terraform regenera y reescribe
  content_type     = "password"
  expiration_date  = timeadd(plantimestamp(), "8760h")
  depends_on       = [azurerm_role_assignment.tf_secrets_officer]
}
# 3. Leer sin guardar, donde haga falta (página 4: la VM o el servidor MySQL)
ephemeral "azurerm_key_vault_secret" "db" {
  name         = azurerm_key_vault_secret.db.name
  key_vault_id = azurerm_key_vault.moodle.id
}
resource "azurerm_mysql_flexible_server" "moodle" {
  # …
  administrator_password_wo         = ephemeral.azurerm_key_vault_secret.db.value
  administrator_password_wo_version = azurerm_key_vault_secret.db.value_wo_version
}
# Auditoría: quién leyó qué (Log Analytics de la página 5)
resource "azurerm_monitor_diagnostic_setting" "kv" {
  name                       = "diag-kv"
  target_resource_id         = azurerm_key_vault.moodle.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.moodle.id
  enabled_log { category = "AuditEvent" }
}
```

| **Mecanismo** | **Consola** | **Plan (`show -json`)** | **Estado** |
|---|---|---|---|
| `sensitive = true` | Oculto | En claro | En claro |
| `ephemeral` (variable, recurso, data, output) | No aparece | No aparece | No aparece; se recalcula en cada operación |
| Atributo *write-only* (`*_wo`) | No aparece | No aparece | Solo `*_wo_version`; el valor se reenvía cuando cambia la versión |

> ⚠️ **Purge protection es irreversible.** Con `purge_protection_enabled = true`, un vault borrado queda en *soft delete* 90 días y **nadie** puede purgarlo ni reutilizar su nombre. Es lo correcto en producción y un problema en un laboratorio: en Topaz o en pruebas, `false` y `features { key_vault { purge_soft_delete_on_destroy = true } }` en el provider.

---

## 3. Identidad: con qué actúa Terraform

El bloque del original no puede funcionar: el `provider` se evalúa antes de crear nada, así que no puede recibir el `client_id` de una identidad que ese mismo código crea; además falta `use_msi`. La identidad gestionada es la de la **máquina donde corre Terraform** (una VM de agente, un runner en AKS o Container Apps), y se configura por variables de entorno, no en el código.

```bash
# En la VM/agente con identidad asignada por el usuario: nada de secretos, nada en el .tf
export ARM_USE_MSI=true
export ARM_CLIENT_ID=<client_id de la UAMI>        # omítelo si es identidad asignada por el sistema
export ARM_SUBSCRIPTION_ID=<sub> ARM_TENANT_ID=<tenant>
export ARM_USE_AZUREAD=true                          # el backend también con la identidad, sin claves de cuenta
terraform init && terraform plan

# En un pipeline (página 12): OIDC
export ARM_USE_OIDC=true ARM_CLIENT_ID=… ARM_TENANT_ID=… ARM_SUBSCRIPTION_ID=…

# En tu portátil: Azure CLI (az login); en Topaz, el providers.tf de la página 1
# El bloque provider queda vacío de credenciales en los tres casos:
```
```hcl
provider "azurerm" { features {} }
```

| **Quién** | **Rol y ámbito** | **Por qué** |
|---|---|---|
| Identidad de `plan` (PR, drift) | *Reader* en la suscripción + *Storage Blob Data Contributor* en el contenedor de estado | Refresca y planifica; el lock exige escribir el blob. No puede cambiar nada |
| Identidad de `apply` | *Contributor* en **el grupo** del entorno + blob del estado + *Key Vault Secrets Officer* en el vault | Nunca *Owner*, nunca la suscripción entera. Si crea asignaciones de rol, *Role Based Access Control Administrator* con `condition` que limite qué roles puede dar |
| Recursos desplegados (VM, App) | Identidad propia con *Key Vault Secrets User* sobre secretos concretos, *Storage Blob Data Reader* sobre su contenedor | La aplicación lee su secreto en arranque; Terraform no lo inyecta por `custom_data` |
| Personas | *Reader* permanente; roles de escritura mediante PIM, con caducidad | Los cambios entran por el pipeline (página 12); el portal es para mirar |

---

## 4. Guardarraíles: en el `plan` y en el `apply`

Azure Policy con efecto `deny` rechaza el recurso cuando ARM lo recibe, es decir, **a mitad de un `apply`**: el plan no lo ve venir. Por eso se necesitan dos capas: Terraform y los escáneres detectan en `plan`, Policy garantiza en `apply` aunque alguien use el portal.

```hcl
# ── Capa 1: Terraform (falla en plan, ✅ Topaz) ─────────────────────────────────
variable "location" {
  type = string
  validation {
    condition     = contains(["westeurope", "spaincentral", "eastus"], var.location)
    error_message = "Región fuera de la lista permitida."
  }
}
check "almacenamiento_endurecido" {          # aviso en plan/apply, no bloquea: para políticas que se están introduciendo
  assert {
    condition     = alltrue([for s in values(azurerm_storage_account.moodle) : s.min_tls_version == "TLS1_2" && !s.allow_nested_items_to_be_public])
    error_message = "Alguna cuenta permite TLS < 1.2 o blobs públicos."
  }
}
resource "azurerm_key_vault" "moodle" {
  # …
  lifecycle {
    precondition {                            # bloquea el plan
      condition     = var.entorno != "pro" || var.purge_protection
      error_message = "En pro, purge_protection es obligatorio."
    }
  }
}
# Escáneres (sin Azure): trivy config . ; checkov -d . ; tflint con ruleset azurerm
# Políticas propias sobre el plan: terraform show -json tfplan | conftest test - -p politicas/   (OPA/Rego)

# ── Capa 2: Azure Policy (falla en apply, solo Azure real) ──────────────────────
data "azurerm_policy_definition_built_in" "regiones" { display_name = "Allowed locations" }
data "azurerm_policy_definition_built_in" "kv_purge" { display_name = "Key vaults should have deletion protection enabled" }
data "azurerm_policy_definition_built_in" "st_tls"   { display_name = "Storage accounts should have the specified minimum TLS version" }

resource "azurerm_subscription_policy_assignment" "regiones" {
  name                 = "regiones-permitidas"
  subscription_id      = data.azurerm_subscription.actual.id
  policy_definition_id = data.azurerm_policy_definition_built_in.regiones.id
  parameters           = jsonencode({ listOfAllowedLocations = { value = ["westeurope", "spaincentral"] } })
}
resource "azurerm_resource_group_policy_assignment" "kv_purge" {
  name                 = "kv-purge-protection"
  resource_group_id    = azurerm_resource_group.moodle.id
  policy_definition_id = data.azurerm_policy_definition_built_in.kv_purge.id
  enforce              = var.entorno == "pro"       # false = auditar sin bloquear (efecto "audit" en la práctica)
}

# Si necesitas una definición propia, la regla del original corregida:
resource "azurerm_policy_definition" "regiones_custom" {
  name         = "regiones-permitidas-custom"
  policy_type  = "Custom"
  mode         = "Indexed"                          # solo recursos con location/tags; "All" incluiría grupos y globales
  display_name = "Regiones permitidas"
  parameters   = jsonencode({ allowedLocations = { type = "Array", metadata = { strongType = "location" } } })
  policy_rule  = jsonencode({
    if   = { allOf = [{ field = "location", notIn = "[parameters('allowedLocations')]" }, { field = "location", notEquals = "global" }] }
    then = { effect = "deny" }
  })
}
```

| **Herramienta** | **Cuándo actúa** | **Alcance** | **Topaz** |
|---|---|---|---|
| `validation` / `precondition` | `plan`, bloquea | Solo este código | ✅ |
| `check` | `plan`/`apply`, avisa | Este código, también sobre `data` (estado real) | ✅ |
| Trivy / Checkov / TFLint | Pre-commit y CI, bloquea | Catálogo de reglas de la industria (CIS, WAF) | ✅ (no usan Azure) |
| OPA / Conftest sobre `plan -json` | CI, bloquea | Reglas propias de la organización | ✅ |
| Azure Policy | `apply` (ARM), bloquea o audita | Todo: Terraform, portal, CLI, Bicep | ❌ Azure real |
| Locks (`azurerm_management_lock`) | Al borrar o modificar | Todo; el `destroy` de Terraform también falla | ❌ Azure real (en Topaz: `prevent_destroy`) |

---

## 5. El estado es un secreto; los recursos críticos no se borran

El bloque `backend` del original no protege nada por sí solo. La cuenta de la página 7 ya lo hace; aquí está la lista completa de lo que la convierte en un almacén de secretos y de lo que evita un `destroy` accidental.

| **Medida** | **Cómo** |
|---|---|
| Sin claves de cuenta | `shared_access_key_enabled = false` en la cuenta; `use_azuread_auth = true` en el backend; RBAC por contenedor y, para PRs, ABAC por prefijo de blob (página 10) |
| Recuperable | `versioning_enabled`, `delete_retention_policy` y `container_delete_retention_policy` (30 días); `state pull` a un archivo antes de cualquier cirugía (página 9) |
| Inaccesible desde fuera | `public_network_access_enabled = false` + Private Endpoint desde la red del agente, o `network_rules { default_action = "Deny" }` con las IPs del runner; las personas leen el estado con *Storage Blob Data Reader*, nunca con la clave |
| Auditado | `azurerm_monitor_diagnostic_setting` sobre el servicio blob (`StorageRead`, `StorageWrite`) hacia Log Analytics: quién descargó el estado y cuándo |
| Con menos secretos dentro | `ephemeral` y `*_wo` (13.2); `features { storage { data_plane_available = false } }` para que el provider no liste claves que no vas a usar; identidades gestionadas en vez de contraseñas en los recursos |
| Protegido contra `destroy` | `prevent_destroy = true` en el código (Terraform se niega) y `azurerm_management_lock` *CanNotDelete* sobre el grupo del estado (Azure se niega, aunque el borrado venga del portal) |

```hcl
# Capa Terraform: falla en plan, ✅ Topaz
resource "azurerm_storage_account" "tfstate" {
  # …
  lifecycle { prevent_destroy = true }        # "Instance cannot be destroyed": hay que quitar la línea a propósito
}
# Capa Azure: falla en ARM, solo Azure real. El lock se gestiona desde OTRO estado (el de plataforma) o a mano,
# porque si vive en el mismo estado, "terraform destroy" lo quita primero y luego borra todo.
resource "azurerm_management_lock" "tfstate" {
  name       = "no-borrar-estado"
  scope      = azurerm_resource_group.tfstate.id
  lock_level = "CanNotDelete"
  notes      = "Contiene los estados de Terraform. Retirar el lock exige aprobación."
}
```

---

## 6. Laboratorio en Topaz

Cinco experimentos sobre el propio Terraform y una cuenta de almacenamiento. Ninguno necesita Key Vault ni Policy: la lección es ver con tus ojos qué hay dentro del estado y qué deja de haber.

```bash
mkdir -p ~/tf-sec && cd ~/tf-sec && cp ~/tf-st/providers.tf . && git init -q
printf '*.tfstate\n*.tfstate.*\n*.tfvars\n!*.auto.tfvars.example\n.terraform/\n*.tfplan\ncrash.log\n' > .gitignore

# ─── 1. "sensitive" oculta en consola. Y nada más ───────────────────────────────
cat > main.tf <<'EOF'
terraform { required_providers { random = { source = "hashicorp/random", version = ">= 3.7" } } }
resource "random_password" "persistida" { length = 24 }
output "pw" { value = random_password.persistida.result, sensitive = true }
EOF
terraform init && terraform apply -auto-approve                    # pw = <sensitive>
terraform output pw                                                # <sensitive>
terraform output -raw pw; echo                                     # en claro: cualquiera con el estado la tiene
terraform state pull | jq -r '.resources[] | select(.type=="random_password") | .instances[0].attributes.result'   # en claro
terraform show -json | jq -r '.values.root_module.resources[0].values.result'                                     # en claro
git add -A && git status --short                                   # el .tfstate NO aparece: el .gitignore hace su trabajo

# ─── 2. "ephemeral": no hay nada que leer porque nada se guarda ─────────────────
cat > main.tf <<'EOF'
terraform { required_providers { random = { source = "hashicorp/random", version = ">= 3.7" } } }
ephemeral "random_password" "efimera" { length = 24 }
resource "terraform_data" "intento" { input = ephemeral.random_password.efimera.result }
EOF
terraform apply -auto-approve                                      # Error: Invalid use of ephemeral value — se niega a persistirlo
sed -i '/terraform_data/d' main.tf
terraform apply -auto-approve                                      # "0 to add": el recurso ephemeral existe solo durante la operación
terraform state pull | jq '.resources | length'                    # 0 (el random_password del paso 1 se destruyó al desaparecer del código)
# Un valor ephemeral solo puede ir a: otro ephemeral, un atributo *_wo, provider config, provisioners o locals que no persisten.

# ─── 3. El estado guarda claves que tú nunca escribiste ─────────────────────────
cat > main.tf <<'EOF'
resource "azurerm_resource_group" "sec" {
  name     = "rg-sec-lab-001"
  location = "eastus"
  lifecycle { ignore_changes = [tags] }
}
resource "azurerm_storage_account" "sec" {
  name                            = "stseclab${substr(md5(azurerm_resource_group.sec.id), 0, 8)}"
  resource_group_name             = azurerm_resource_group.sec.name
  location                        = azurerm_resource_group.sec.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  public_network_access_enabled   = false
}
EOF
terraform init && terraform apply -auto-approve
terraform state pull | jq -r '.resources[] | select(.type=="azurerm_storage_account") | .instances[0].attributes | {primary_access_key, primary_connection_string}'
#   Las claves están ahí, en claro, aunque shared_access_key_enabled = false las inutilice y aunque el provider las marque sensitive.
#   (En Topaz serán claves ficticias; en Azure real, las de verdad.) Por eso el estado se protege como un secreto.
terraform state pull | jq '[.. | strings | select(test("(?i)key|password|secret|token"))] | length'   # cuántos valores "sospechosos" hay

# ─── 4. Guardarraíles en plan: validation, precondition, check ──────────────────
cat > guardas.tf <<'EOF'
variable "location" {
  type    = string
  default = "eastus"
  validation {
    condition     = contains(["eastus", "westeurope", "spaincentral"], var.location)
    error_message = "Región fuera de la lista permitida: eastus, westeurope, spaincentral."
  }
}
variable "entorno" { type = string, default = "lab" }
check "cuenta_endurecida" {
  assert {
    condition     = azurerm_storage_account.sec.min_tls_version == "TLS1_2" && !azurerm_storage_account.sec.allow_nested_items_to_be_public && !azurerm_storage_account.sec.shared_access_key_enabled
    error_message = "La cuenta admite TLS < 1.2, blobs públicos o claves compartidas."
  }
}
EOF
sed -i 's/location = "eastus"/location = var.location/' main.tf
terraform plan -var location=brazilsouth                           # Error: Invalid value for variable — antes de tocar nada
terraform plan                                                     # No changes
sed -i 's/shared_access_key_enabled       = false/shared_access_key_enabled       = true/' main.tf
terraform plan | grep -A3 "Check block"                            # Warning: Check block assertion failed — avisa, no bloquea
sed -i 's/shared_access_key_enabled       = true/shared_access_key_enabled       = false/' main.tf
cat >> main.tf <<'EOF'
resource "terraform_data" "politica_pro" {
  lifecycle {
    precondition {
      condition     = var.entorno != "pro" || var.location != "eastus"
      error_message = "En pro no se despliega en eastus (residencia de datos)."
    }
  }
}
EOF
terraform plan -var entorno=pro                                    # Error: Resource precondition failed — bloquea
terraform plan                                                     # OK en lab

# ─── 5. prevent_destroy: el destroy accidental ──────────────────────────────────
sed -i 's/  public_network_access_enabled   = false/  public_network_access_enabled   = false\n  lifecycle { prevent_destroy = true }/' main.tf
terraform apply -auto-approve                                      # solo actualiza el estado
terraform destroy -auto-approve                                    # Error: Instance cannot be destroyed … lifecycle.prevent_destroy
terraform plan -replace=azurerm_storage_account.sec                # tampoco: -replace también destruye

# ─── 6. Escáneres sin Azure ─────────────────────────────────────────────────────
command -v trivy >/dev/null && trivy config . --severity HIGH,CRITICAL   # revisa la cuenta: debería salir limpia; quita min_tls_version y repite
printf 'db_password = "SuperSecretPassword123!"\n' > secreto.auto.tfvars    # el error del original, en un archivo que Git ignora…
command -v gitleaks >/dev/null && gitleaks detect --no-git -v            # …pero gitleaks lo encuentra igual en el directorio
rm secreto.auto.tfvars

# ─── 7. Limpiar ────────────────────────────────────────────────────────────────
sed -i '/prevent_destroy/d' main.tf && terraform destroy -auto-approve
```

```bash
# ─── Solo Azure real: Key Vault con secreto write-only, Policy y lock ───────────
# main.tf: los bloques de 13.2 (vault + role_assignment + ephemeral random_password + azurerm_key_vault_secret con value_wo)
#          y de 13.4 (assignment de "Allowed locations" con enforce = false para auditar primero)
terraform apply -auto-approve
terraform state pull | jq -r '.resources[] | select(.type=="azurerm_key_vault_secret") | .instances[0].attributes | {value, value_wo_version}'
#   value: null · value_wo_version: 1 — el secreto existe en Key Vault y no existe en el estado
az keyvault secret show --vault-name $KV -n moodle-db-password --query "attributes.enabled"   # true (no imprimas .value)
sed -i 's/value_wo_version = 1/value_wo_version = 2/' main.tf && terraform apply -auto-approve  # rotación: nueva contraseña, nuevo version
az keyvault secret list-versions --vault-name $KV -n moodle-db-password --query "length(@)"   # 2
az policy state list -g rg-moodle-dev-001 --query "[?complianceState=='NonCompliant'].resourceId" -o tsv   # qué incumple antes de enforce
az lock create -g rg-tfstate -n no-borrar-estado -t CanNotDelete -o none
terraform destroy -target=azurerm_storage_account.tfstate         # Error … ScopeLocked: el lock manda, aunque quitaras prevent_destroy
```

---

## 7. Errores comunes

> ⚠️ **Solución de problemas**
>
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | Un secreto en un `.tf` (el `value = "SuperSecret…"` del original) | Vive en Git para siempre, aunque lo borres en el siguiente commit. Rota el secreto *ya*; después limpia el historial (`git filter-repo`) y añade gitleaks al pre-commit |
> | *Invalid use of ephemeral value* | Intentas guardar un valor efímero en un atributo normal, un output raíz o un `terraform_data`. Solo puede ir a `*_wo`, otro `ephemeral`, configuración de provider o provisioner |
> | *Unsupported argument: value_wo* / *Unsupported block type "ephemeral"* | Terraform < 1.11 (write-only) o < 1.10 (ephemeral), o provider antiguo (`random < 3.7`, `azurerm` sin soporte en ese recurso). Sube versiones en `required_version`/`required_providers` |
> | Rotaste el secreto en Key Vault a mano y Terraform no se entera | Con `value_wo` Terraform no lee el valor: solo compara `value_wo_version`. La rotación se hace subiendo la versión en el código; si la hizo otro, sube la versión igualmente para volver a alinear |
> | *ForbiddenByRbac* / *The user, group or application does not have secrets set permission* | Vault con `rbac_authorization_enabled = true` y la identidad de Terraform sin *Key Vault Secrets Officer*. Asigna el rol y añade `depends_on`: la propagación de RBAC tarda hasta unos minutos; reintenta |
> | *ForbiddenByConnection* / *Client address is not authorized* | `network_acls default_action = "Deny"` y el runner no está en `ip_rules` ni llega por Private Endpoint. Añade la IP del agente o ejecuta Terraform desde la red |
> | *A vault with the same name already exists in deleted state* | Soft delete: `az keyvault purge -n …` si no tiene *purge protection*; si la tiene, espera 90 días o cambia el nombre. En labs: `purge_protection_enabled = false` y `purge_soft_delete_on_destroy = true` |
> | El `provider` con `client_id = azurerm_user_assigned_identity.x.client_id` (original) da *Cycle* o *Provider configuration not known* | El provider se configura antes de crear recursos y no puede depender de uno. La identidad es la de la máquina que ejecuta Terraform: `ARM_USE_MSI=true` (+ `ARM_CLIENT_ID` si es UAMI) por entorno |
> | *ManagedIdentityCredential authentication unavailable* | No hay IMDS: no estás en una VM/AKS/Container App con identidad, o la UAMI no está asignada al recurso. En el portátil usa `az login`; en CI, OIDC |
> | *AuthorizationFailed* al crear `azurerm_role_assignment` | *Contributor* no puede asignar roles. Da a la identidad de apply *Role Based Access Control Administrator* con `condition` que limite a roles concretos (nunca *Owner*) |
> | *RequestDisallowedByPolicy* a mitad de un `apply` | Azure Policy actúa en ARM, no en plan. Los recursos previos ya se crearon: corrige y vuelve a aplicar. Para verlo antes, replica la regla como `validation`/`precondition` o política OPA sobre el plan |
> | La política del original no hace nada o falla al crearse | El alias `Microsoft.Compute/virtualMachines/location` no existe y `.list[0]` no es sintaxis de Policy. Usa `field = "location"` con `notIn` y excluye `global`; o directamente la *built-in* "Allowed locations" |
> | *Instance cannot be destroyed* cuando sí quieres destruir | `prevent_destroy` funcionando. Quita la línea en un commit revisado, aplica, y vuelve a ponerla. No lo hagas con `state rm`: dejaría el recurso huérfano |
> | *ScopeLocked* en `destroy` o al modificar | Lock de Azure. *CanNotDelete* bloquea borrados; *ReadOnly* bloquea también actualizaciones (y listKeys, con lo que el backend con claves deja de funcionar: otra razón para `use_azuread_auth`). Retirar el lock es una operación aprobada, no un paso del pipeline |
> | El lock del grupo de estado desaparece en cada `destroy` | Está en el mismo estado que protege: Terraform lo quita primero. Gestiónalo desde el estado de plataforma o a mano |
> | `terraform show -json` en el comentario de la PR expone valores | El JSON no respeta `sensitive` (solo lo marca). Usa `show -no-color` para humanos y `ephemeral`/`*_wo` para que no haya nada que mostrar |

---

## 8. Autoevaluación

1. **¿Qué protege `sensitive = true` y qué no?**
   Oculta el valor en la salida de consola. No lo cifra ni lo excluye del estado, del `tfplan` ni de `show -json`.
2. **¿Qué diferencia hay entre un recurso `ephemeral` y un atributo *write-only*?**
   El `ephemeral` produce un valor que solo existe durante la operación y no se persiste. El atributo `*_wo` permite enviar ese valor a un recurso real sin guardarlo; solo se conserva `*_wo_version`.
3. **¿Cómo se rota un secreto escrito con `value_wo`?**
   Subiendo `value_wo_version`. Terraform regenera el valor efímero y lo reenvía; Key Vault conserva la versión anterior.
4. **¿Por qué el bloque `provider` del original con `client_id = azurerm_user_assigned_identity…` no puede funcionar?**
   El provider se configura antes de crear recursos y no puede depender de uno. La identidad gestionada es la de la máquina donde corre Terraform y se activa con `ARM_USE_MSI`.
5. **¿Qué roles necesita la identidad de `apply` y cuáles no debe tener?**
   *Contributor* acotado al grupo del entorno, *Storage Blob Data Contributor* en el contenedor de estado y *Key Vault Secrets Officer* en el vault. Nunca *Owner* ni ámbito de suscripción.
6. **¿En qué momento actúa Azure Policy y qué implica para Terraform?**
   Cuando ARM recibe el recurso, a mitad del `apply`. El plan no lo anticipa, así que se duplica la regla en `validation`/`precondition` o en OPA para fallar antes.
7. **¿Qué está mal en la definición de Policy del original?**
   Usa un alias inexistente, una sintaxis inválida (`.list[0]`), no declara `parameters` y solo cubre VMs. La *built-in* "Allowed locations" hace lo que pretendía.
8. **¿Cuándo `check` y cuándo `precondition`?**
   `check` avisa sin bloquear: para introducir una norma y medir su cumplimiento. `precondition` bloquea: para normas ya obligatorias.
9. **¿Por qué el estado contiene claves de la cuenta de almacenamiento si nunca las escribiste?**
   El provider guarda todo lo que la API devuelve, incluidas `primary_access_key` y cadenas de conexión. Por eso el estado se protege como un secreto y se desactivan las claves compartidas.
10. **¿Qué diferencia hay entre `prevent_destroy` y un lock *CanNotDelete*?**
    `prevent_destroy` lo aplica Terraform y solo protege frente a este código. El lock lo aplica Azure frente a cualquier vía (portal, CLI, otro Terraform). Se complementan; el lock debe vivir fuera del estado que protege.
11. **¿Por qué `purge_protection_enabled = true` es un problema en un laboratorio?**
    Es irreversible: el vault borrado queda 90 días sin poder purgarse ni reutilizar su nombre. En pruebas se desactiva y se usa `purge_soft_delete_on_destroy`.

---

## 9. Referencias

- [Recursos `ephemeral`](https://developer.hashicorp.com/terraform/language/resources/ephemeral), [atributos *write-only*](https://developer.hashicorp.com/terraform/language/resources/ephemeral/write-only), [variables `ephemeral`](https://developer.hashicorp.com/terraform/language/values/variables#ephemeral-variables) y [datos sensibles en el estado](https://developer.hashicorp.com/terraform/language/state/sensitive-data)
- [`ephemeral "random_password"`](https://registry.terraform.io/providers/hashicorp/random/latest/docs/ephemeral-resources/password), [`azurerm_key_vault_secret` (`value_wo`)](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault_secret) y [`ephemeral "azurerm_key_vault_secret"`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/ephemeral-resources/key_vault_secret)
- [Key Vault: características de seguridad](https://learn.microsoft.com/es-es/azure/key-vault/general/security-features), [RBAC en Key Vault](https://learn.microsoft.com/es-es/azure/key-vault/general/rbac-guide) y [soft delete y purge protection](https://learn.microsoft.com/es-es/azure/key-vault/general/soft-delete-overview)
- [Provider azurerm: identidad gestionada (`use_msi`)](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/managed_service_identity), [OIDC](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/service_principal_oidc) y [buenas prácticas de RBAC](https://learn.microsoft.com/es-es/azure/role-based-access-control/best-practices) (mínimo privilegio, PIM, condiciones)
- [Bloques `check`](https://developer.hashicorp.com/terraform/language/checks), [`validation` y `precondition`](https://developer.hashicorp.com/terraform/language/expressions/custom-conditions) y [`prevent_destroy`](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle#prevent_destroy)
- [Azure Policy: estructura de la regla](https://learn.microsoft.com/es-es/azure/governance/policy/concepts/definition-structure-policy-rule), [políticas integradas](https://learn.microsoft.com/es-es/azure/governance/policy/samples/built-in-policies) y [`azurerm_subscription_policy_assignment`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subscription_policy_assignment)
- [Locks de recursos](https://learn.microsoft.com/es-es/azure/azure-resource-manager/management/lock-resources) y [`azurerm_management_lock`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/management_lock)
- [Trivy config](https://aquasecurity.github.io/trivy/latest/docs/scanner/misconfiguration/), [Checkov](https://www.checkov.io/), [gitleaks](https://github.com/gitleaks/gitleaks) y [Conftest (OPA)](https://www.conftest.dev/)
- [Well-Architected Framework: pilar de seguridad](https://learn.microsoft.com/es-es/azure/well-architected/security/) y [Microsoft Cloud Security Benchmark](https://learn.microsoft.com/es-es/security/benchmark/azure/)
- [Azure Local Emulator (Topaz)](https://github.com/Azure/azure-local-emulator)