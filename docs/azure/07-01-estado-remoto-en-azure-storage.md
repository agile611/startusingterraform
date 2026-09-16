# 🔐 Estado remoto en Azure Storage

## 1. Qué contiene el estado y por qué sacarlo del disco

```json
{
  "version": 4,                              # formato del archivo (no cambia desde 0.12)
  "terraform_version": "1.9.5",              # quién lo escribió: una versión más nueva lo hace ilegible para las antiguas
  "serial": 17,                              # se incrementa en cada escritura: detecta pisar un estado más reciente
  "lineage": "5f1c…-…",                      # identidad del estado desde su creación: impide mezclar dos proyectos
  "outputs": { … },
  "resources": [
    {
      "module": "module.red",                # dirección completa: module.red.azurerm_subnet.this["backend"]
      "mode": "managed",                     # managed = resource; data = data source
      "type": "azurerm_subnet",
      "name": "this",
      "instances": [ { "index_key": "backend", "attributes": { "id": "/subscriptions/…", … },
                       "dependencies": [ "module.red.azurerm_virtual_network.this" ] } ]
    }
  ]
}
```

> ⚠️ **El estado contiene secretos en claro.** La contraseña de SQL de la [página 4](index.md#pagina-4), la clave de la cuenta de almacenamiento de la [página 5](index.md#pagina-5) (`primary_access_key`) y cualquier `random_password` están en `attributes` tal cual. `sensitive = true` solo los oculta en la consola. Quien pueda leer el estado puede leer todos los secretos de la infraestructura: por eso el contenedor del estado se protege como un Key Vault, y por eso `*.tfstate*` está en el `.gitignore` desde la [página 1](index.md#pagina-1).

| **Necesidad** | **Estado local** | **Backend `azurerm`** |
|---|---|---|
| Varias personas y un pipeline | ❌ Cada uno tiene su copia; la segunda persona destruye lo de la primera | ✅ Una sola copia; bloqueo por *lease* del blob durante cada operación |
| Perderlo o corromperlo | ⚠️ Solo `terraform.tfstate.backup` (la versión anterior) | ✅ Versionado de blobs + soft delete + `snapshot = true`. No es "automático": lo configuras tú en 7.2 |
| Quién lo lee o cambia | ❌ Quien tenga el disco | ✅ RBAC de datos sobre el contenedor; logs de diagnóstico con identidad y hora |
| Secretos | ❌ En claro en un portátil, a un `git add` de distancia | ⚠️ En claro también, pero cifrados en reposo, sin acceso público y con permisos explícitos |
| En Topaz | ✅ | ❌ plano de datos. Se practica la mecánica con `backend "local"` (7.7) |

---

## 2. Bootstrap: la cuenta que guarda el estado

El huevo y la gallina: la cuenta del estado se crea con Terraform, pero ese Terraform aún no tiene dónde guardar su estado. La respuesta estándar es un proyecto `bootstrap` pequeño, separado, cuyo estado **sí** es local (y se guarda en un lugar seguro o se migra a su propia cuenta después). Cambia una vez al año; el resto de proyectos solo lo referencian.

```bash
mkdir -p ~/tf-estado/{bootstrap,app} && cd ~/tf-estado/bootstrap
cp ~/tf-st/providers.tf .                 # data_plane_available = false y storage_use_azuread = true
printf 'terraform.tfstate*\n.terraform/\n*.tfvars\n*.json\n' > ../.gitignore
```

```hcl
# bootstrap/main.tf
variable "replicacion"  { type = string, default = "LRS" }    # en Azure real: ZRS o GZRS. El estado es lo único que no puedes regenerar
variable "asignar_rbac" { type = bool,   default = false }    # Microsoft.Authorization: solo Azure real
variable "bloquear"     { type = bool,   default = false }    # Microsoft.Authorization/locks: solo Azure real
variable "principal_id" { type = string, default = null }     # Object ID de tu usuario o del grupo "tf-operadores"

locals { tags = { proyecto = "tfstate", gestion = "terraform", criticidad = "alta" } }

resource "azurerm_resource_group" "estado" {
  name     = "rg-tfstate-001"
  location = "eastus"
  tags     = local.tags
  lifecycle { ignore_changes = [tags] }
}

resource "random_string" "sufijo" {
  length  = 8
  upper   = false
  special = false
}

resource "azurerm_storage_account" "estado" {
  name                     = "sttfstate${random_string.sufijo.result}"   # 17 caracteres, único global
  resource_group_name      = azurerm_resource_group.estado.name
  location                 = azurerm_resource_group.estado.location
  account_kind             = "StorageV2"
  account_tier             = "Standard"
  account_replication_type = var.replicacion
  access_tier              = "Hot"                # el estado se lee en cada plan: nunca Cool

  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false         # SIN claves: el backend usa use_azuread_auth. Quien no tenga rol, no lee el estado
  public_network_access_enabled   = true          # false + private endpoint cuando los agentes de CI estén en tu red

  blob_properties {
    versioning_enabled = true                     # cada apply deja una versión anterior recuperable
    delete_retention_policy { days = 30 }         # un rm del blob se deshace durante 30 días
    container_delete_retention_policy { days = 30 }
    change_feed_enabled = true                    # registro de quién escribió qué versión y cuándo
  }
  tags = local.tags
}

resource "azurerm_storage_container" "tfstate" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.estado.id      # ARM: funciona en Topaz ([página 5](index.md#pagina-5))
  container_access_type = "private"
}

# Solo Azure real: quién puede leer y escribir el estado. Ámbito: el contenedor, no la cuenta ni el grupo
resource "azurerm_role_assignment" "operadores" {
  count                = var.asignar_rbac && var.principal_id != null ? 1 : 0
  scope                = azurerm_storage_container.tfstate.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.principal_id
}

# Solo Azure real: nadie borra la cuenta del estado por accidente
resource "azurerm_management_lock" "estado" {
  count      = var.bloquear ? 1 : 0
  name       = "no-borrar-estado"
  scope      = azurerm_resource_group.estado.id
  lock_level = "CanNotDelete"
}

# bootstrap/outputs.tf
output "cuenta"     { value = azurerm_storage_account.estado.name }
output "contenedor" { value = azurerm_storage_container.tfstate.name }
output "bloque_backend" {
  description = "Pégalo en el providers.tf de cada proyecto (Azure real)"
  value       = <<-EOT
    backend "azurerm" {
      resource_group_name  = "${azurerm_resource_group.estado.name}"
      storage_account_name = "${azurerm_storage_account.estado.name}"
      container_name       = "${azurerm_storage_container.tfstate.name}"
      key                  = "<proyecto>/<entorno>.tfstate"
      use_azuread_auth     = true
    }
  EOT
}
```

```bash
terraform init && terraform validate
terraform apply -auto-approve                       # Plan: 4 to add (grupo, sufijo, cuenta, contenedor). Rol y lock: count = 0
terraform output bloque_backend                     # el texto que usarán los demás proyectos
az storage account show -g rg-tfstate-001 -n "$(terraform output -raw cuenta)" \
  --query "{claves:allowSharedKeyAccess, publico:allowBlobPublicAccess, tls:minimumTlsVersion}" -o table
# claves = False: sin rol de datos, nadie (ni tú) puede leer el estado

# NO destruyas el bootstrap todavía: la sección 7.8 lo reutiliza. Su propio estado queda local en este directorio.
```

> **🔷 Dónde vive el estado del bootstrap.** Tres opciones, de más simple a más ordenada: (1) local, copiado a un lugar seguro (Key Vault como secreto, o el propio contenedor `tfstate` subido a mano *una vez*); (2) migrado a la cuenta que él mismo creó, con `init -migrate-state` tras el primer `apply`: es legítimo y habitual; (3) una segunda cuenta de bootstrap en otra región. Lo que no debe pasar es que el estado del bootstrap esté en un portátil sin copia: si se pierde, la cuenta sigue existiendo pero habrá que `import`arla.

---

## 3. Operaciones sobre el estado

Todas funcionan igual con estado local y remoto: la familia `terraform state` y los bloques declarativos `moved`, `import` y `removed`, que dejan el cambio en el código y en el historial de Git en lugar de en la terminal de una persona.

| **Comando o bloque** | **Qué hace** | **Toca Azure** |
|---|---|---|
| `state list` / `state show <dir>` | Lista direcciones; muestra los atributos guardados de una (incluidos secretos) | No |
| `state pull > copia.json` | Descarga el estado tal cual. Es la copia de seguridad manual antes de cualquier cirugía | No |
| `state push copia.json` | Sube un estado. Rechaza `serial` menor o `lineage` distinto; `-force` lo salta (última opción) | No |
| `moved { from = A to = B }` | Renombrar un recurso o módulo sin destruirlo. Sustituye a `state mv`; se borra del código tras aplicarlo | No |
| `import { to = A id = "/subscriptions/…" }` | Adoptar un recurso creado a mano. `plan -generate-config-out=gen.tf` escribe el bloque por ti | Lee |
| `removed { from = A lifecycle { destroy = false } }` | Olvidar un recurso sin borrarlo en Azure (pasa a otro proyecto o a gestión manual). Sustituye a `state rm` | No |
| `plan -refresh-only` / `apply -refresh-only` | Detectar *drift* (cambios hechos fuera de Terraform) y aceptar la realidad en el estado sin tocar recursos | Lee |
| `apply -replace=<dir>` | Recrear un recurso concreto (sustituye al antiguo `taint`) | Sí |

> ⚠️ **Nunca edites el `tfstate` a mano.** El original subía el archivo con `az storage blob upload` y después ejecutaba `init -migrate-state`: eso produce dos estados con distinto `lineage` y Terraform pregunta cuál sobrescribir. La secuencia es siempre `state pull` (copia), cambio con `moved`/`removed`/`state mv`, y `plan` hasta ver *No changes*. Si un `state push` exige `-force`, algo has entendido mal: para antes.

---

## 4. Bloqueos: cómo funcionan de verdad

El original afirmaba que "Azure Storage no tiene locks nativos" y proponía crear un *lease* a mano. Es al revés: el backend `azurerm` toma un **lease infinito** sobre el blob del estado al empezar cada `plan`, `apply` o comando `state`, escribe quién lo tiene en los metadatos (`terraformlockid`) y lo libera al terminar. Si tú creas el lease con `az storage blob lease create`, lo que consigues es que Terraform no pueda escribir.

```text
Terminal A                                    │ Terminal B
──────────────────────────────────────────────┼──────────────────────────────────────────────
terraform apply                               │
  → adquiere lease del blob app/lab.tfstate   │
  → escribe metadata terraformlockid          │ terraform plan
  → "Do you want to perform these actions?"   │   Error: Error acquiring the state lock
  (espera tu respuesta: el lock sigue tomado) │   Lock Info:
                                              │     ID:        8f2c…-…      ◄── lo que pide force-unlock
                                              │     Path:      tfstate/app/lab.tfstate
                                              │     Operation: OperationTypeApply
                                              │     Who:       ana@portatil-ana
                                              │     Created:   2026-09-10 13:04:11 UTC
yes                                           │
  → aplica, escribe el estado, libera lease   │ terraform plan -lock-timeout=5m   ◄── mejor que fallar: espera
                                              │   (reintenta hasta 5 min y continúa)
```

| **Situación** | **Qué hacer** |
|---|---|
| Otra persona o el pipeline está aplicando | Esperar. `-lock-timeout=10m` en CI para que el job reintente en vez de fallar. Mirar `Who`, no adivinar |
| El proceso que tenía el lock murió (Ctrl+C, agente cancelado, portátil apagado) | Comprobar que no hay ningún `terraform` vivo (`Who` dice dónde). Luego `terraform force-unlock <ID>`: usa el ID para asegurarse de que liberas *ese* lock |
| `force-unlock` falla o el ID se ha perdido | `az storage blob lease break --blob-name app/lab.tfstate -c tfstate --account-name … --auth-mode login` y borrar el metadato `terraformlockid` |
| Ver el lock desde fuera de Terraform | `az storage blob show … --query "{lease:properties.lease.status, lock:metadata.terraformlockid}"`; el valor es el *Lock Info* en base64 |
| Tentación: `-lock=false` | Solo para `plan` de lectura en CI de PR, nunca para `apply`. Es la forma más rápida de corromper un estado compartido |

---

## 5. Configurar el backend

```hcl
# providers.tf del proyecto de aplicación (Azure real). El bloque backend NO admite variables ni interpolación.
terraform {
  required_version = ">= 1.7.0"
  required_providers { azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" } }

  backend "azurerm" {
    resource_group_name  = "rg-tfstate-001"
    storage_account_name = "sttfstateXXXXXXXX"     # salida del bootstrap
    container_name       = "tfstate"
    key                  = "app/lab.tfstate"       # <proyecto>/<entorno>: nunca "terraform.tfstate" para todo
    use_azuread_auth     = true                    # Entra ID; la cuenta tiene las claves desactivadas
    snapshot             = true                    # snapshot del blob antes de cada escritura (además del versionado)
    # use_oidc = true                              # en GitHub Actions / Azure DevOps (página 6)
    # use_msi  = true                              # en una VM o agente con identidad gestionada
  }
}
```

```bash
# Configuración parcial: el mismo código para lab, pre y pro. En el .tf solo queda el tipo:
terraform { backend "azurerm" {} }

# backends/lab.hcl
resource_group_name  = "rg-tfstate-001"
storage_account_name = "sttfstateXXXXXXXX"
container_name       = "tfstate"
key                  = "app/lab.tfstate"
use_azuread_auth     = true

terraform init -backend-config=backends/lab.hcl              # o -backend-config="key=app/pro.tfstate" suelto
terraform init -backend-config=backends/pro.hcl -reconfigure # cambiar de entorno: -reconfigure, NO -migrate-state
```

| **Decisión** | **Recomendación** |
|---|---|
| Un estado por… | Proyecto **y** entorno. Un estado gigante hace lento cada `plan` y convierte cualquier error en un incidente global. Los proyectos se enlazan con `data "terraform_remote_state"` o, mejor, con `data` sources por nombre |
| Entornos: `key` distinta o *workspaces* | `key` + configuración parcial. Los workspaces (`terraform workspace new pro`) guardan el blob como `app.tfstateenv:pro`, comparten backend y credenciales, y es fácil aplicar en `pro` creyendo estar en `lab` |
| Replicación de la cuenta | ZRS como mínimo; GZRS si la región cae y debes seguir operando. El estado es el único artefacto que no puedes regenerar con un `apply` |
| `access_key` / `sas_token` | No. Existen por compatibilidad. Con `shared_access_key_enabled = false` en la cuenta, ni siquiera funcionan |
| Red | Producción: `public_network_access_enabled = false` + private endpoint, y los agentes de CI dentro de la VNet. Mientras tanto, reglas de firewall con las IPs de los agentes |

---

## 6. Quién accede y cómo

| **Quién** | **Cómo se autentica** | **Rol y ámbito** |
|---|---|---|
| Personas del equipo | `az login` + `use_azuread_auth` | *Storage Blob Data Contributor* sobre el contenedor `tfstate`, asignado a un **grupo** de Entra ID (`tf-operadores`), no persona a persona |
| Revisores, auditoría | Igual | *Storage Blob Data Reader*: pueden `plan` y `state list`, no `apply` |
| GitHub Actions / Azure DevOps | OIDC: `use_oidc = true` o `ARM_USE_OIDC=true` ([página 6](index.md#pagina-6)) | Contributor sobre el **contenedor**, con `key` restringida por condición ABAC si hay varios equipos en la misma cuenta |
| Agente en una VM de Azure | `use_msi = true`: identidad gestionada de la VM (`identity { type = "SystemAssigned" }` en `azurerm_linux_virtual_machine`) | Igual que el pipeline. No hay ningún secreto en la VM |
| Cualquiera con la clave de cuenta | Imposible: `shared_access_key_enabled = false` | La clave no se puede auditar ni caduca; el original la usaba incluso para crear el contenedor |

> **🔷 Contributor en el grupo no sirve para nada aquí.** El original asignaba *Contributor* sobre `rg-terraform-backend` "para acceder al backend". Contributor es un rol de ARM: permite crear y borrar la cuenta, pero **no leer un blob**. Leer y escribir el estado exige un rol de *datos*. Al revés también: quien solo tiene *Storage Blob Data Contributor* puede usar el estado pero no puede tocar la cuenta, que es justo lo que quieres para un pipeline.

---

## 7. Laboratorio en Topaz: la mecánica con backend local

El backend `local` con `path` explícito se comporta como cualquier otro: `init -migrate-state` hace las mismas preguntas, los bloqueos producen el mismo mensaje y los comandos `state` son idénticos. Practicas aquí la secuencia exacta que repetirás en 7.8 con `azurerm`.

```bash
cd ~/tf-estado/app && cp ~/tf-st/providers.tf .

# app/main.tf: recursos de red (Microsoft.Network, ✅ Topaz)
cat > main.tf <<'EOF'
resource "azurerm_resource_group" "app" {
  name     = "rg-app-lab-001"
  location = "eastus"
  lifecycle { ignore_changes = [tags] }
}
resource "azurerm_virtual_network" "app" {
  name                = "vnet-app-lab"
  resource_group_name = azurerm_resource_group.app.name
  location            = azurerm_resource_group.app.location
  address_space       = ["10.70.0.0/16"]
}
resource "azurerm_subnet" "app" {
  for_each             = { web = 1, datos = 2 }
  name                 = "snet-${each.key}"
  resource_group_name  = azurerm_resource_group.app.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = [cidrsubnet("10.70.0.0/16", 8, each.value)]
}
EOF

terraform init && terraform apply -auto-approve       # 4 to add; estado en ./terraform.tfstate
ls terraform.tfstate*                                  # terraform.tfstate (y .backup tras el segundo apply)

# ─── 1. Anatomía ───────────────────────────────────────────────────────────────
terraform state pull | jq '{version, terraform_version, serial, lineage, recursos: [.resources[] | .type + "." + .name]}'
terraform state show 'azurerm_subnet.app["datos"]'     # los atributos guardados; con comillas por los corchetes

# ─── 2. Migración (misma mecánica que hacia azurerm) ────────────────────────────
mkdir -p estados
cat > backend.tf <<'EOF'
terraform { backend "local" { path = "estados/app-lab.tfstate" } }
EOF
terraform init -migrate-state
#   Do you want to copy existing state to the new backend?  → yes
#   Successfully configured the backend "local"!
terraform plan                                         # No changes: la migración fue limpia
ls estados/                                            # app-lab.tfstate
rm terraform.tfstate terraform.tfstate.backup          # ya no se usan (Terraform los deja como reliquia)

# ─── 3. Bloqueo ────────────────────────────────────────────────────────────────
terraform apply                                        # NO respondas todavía: tiene el lock
# En OTRA terminal:
#   cd ~/tf-estado/app && terraform plan
#     Error: Error acquiring the state lock  ... Lock Info: ID, Operation, Who, Created
#   terraform plan -lock-timeout=2m                    # espera; responde "no" en la primera y verás cómo continúa
#   terraform force-unlock <ID>                        # solo si la primera terminal hubiera muerto

# ─── 4. Refactor sin destruir: moved ───────────────────────────────────────────
sed -i 's/"azurerm_virtual_network" "app"/"azurerm_virtual_network" "principal"/; s/azurerm_virtual_network.app.name/azurerm_virtual_network.principal.name/' main.tf
terraform plan                                         # 1 to add, 1 to destroy: renombrar = recrear. MAL
cat >> main.tf <<'EOF'
moved {
  from = azurerm_virtual_network.app
  to   = azurerm_virtual_network.principal
}
EOF
terraform plan                                         # "azurerm_virtual_network.app has moved to …principal"  0 to add
terraform apply -auto-approve                          # solo actualiza el estado; el bloque moved se puede borrar después

# ─── 5. Drift: alguien toca Azure a mano ───────────────────────────────────────
az network vnet subnet delete -g rg-app-lab-001 --vnet-name vnet-app-lab -n snet-datos
terraform plan -refresh-only                           # "azurerm_subnet.app["datos"] has been deleted": solo informa
terraform plan                                         # 1 to add: lo recrearía
terraform apply -auto-approve                          # lo recrea. (apply -refresh-only lo habría olvidado en vez de recrearlo)

# ─── 6. Olvidar sin borrar: removed ────────────────────────────────────────────
cat >> main.tf <<'EOF'
removed {
  from = azurerm_subnet.app["web"]
  lifecycle { destroy = false }
}
EOF
terraform apply -auto-approve                          # "will no longer be managed" ; sigue existiendo en Azure
az network vnet subnet show -g rg-app-lab-001 --vnet-name vnet-app-lab -n snet-web --query name -o tsv

# ─── 7. Adoptar: import ────────────────────────────────────────────────────────
# Borra el bloque removed y devuelve la subred al estado:
sed -i '/^removed {/,/^}/d' main.tf
cat > import.tf <<EOF
import {
  to = azurerm_subnet.app["web"]
  id = "$(az network vnet subnet show -g rg-app-lab-001 --vnet-name vnet-app-lab -n snet-web --query id -o tsv)"
}
EOF
terraform plan                                         # "1 to import"
terraform apply -auto-approve && rm import.tf

# ─── 8. Copia y restauración manual ────────────────────────────────────────────
terraform state pull > copia-$(date +%F).json
terraform state push copia-$(date +%F).json            # sube tal cual: mismo lineage, serial >= actual
terraform plan                                         # No changes

# ─── 9. Volver a local implícito y limpiar ─────────────────────────────────────
rm backend.tf && terraform init -migrate-state         # el estado vuelve a ./terraform.tfstate
terraform destroy -auto-approve
```

> **🔷 Lo que cambia con `azurerm`: casi nada.** Los pasos 1 a 9 son los mismos. Las diferencias: el lock es un lease en el blob (y se puede ver y romper con `az`), el `state pull` de seguridad se vuelve opcional porque el versionado ya guarda cada escritura, y `init -migrate-state` pide además que estés autenticado con un rol de datos. Por eso el bootstrap tiene las claves desactivadas: el primer error que verás en Azure real si falta el rol es un 403, no un estado corrupto.

---

## 8. Azure real: activar el backend, restaurar y auditar

```bash
# Bootstrap: quitar metadata_host y resource_provider_registrations, subscription_id real, data_plane_available = true
cd ~/tf-estado/bootstrap && az login
GRUPO=$(az ad group create --display-name tf-operadores --mail-nickname tf-operadores --query id -o tsv)
az ad group member add -g "$GRUPO" --member-id "$(az ad signed-in-user show --query id -o tsv)"
terraform init -reconfigure
terraform apply -auto-approve -var replicacion=ZRS -var asignar_rbac=true -var principal_id="$GRUPO" -var bloquear=true
terraform output bloque_backend                         # copia el bloque (o escribe backends/lab.hcl)
ST=$(terraform output -raw cuenta)

# App: activar el backend y migrar
cd ../app && terraform output bloque_backend -state=../bootstrap/terraform.tfstate -raw > backend.tf 2>/dev/null || true
#   (o pega el bloque a mano dentro de terraform { … } y cambia key por "app/lab.tfstate")
terraform init -migrate-state                           # copia el estado local al blob. El rol tarda 1-5 min: si 403, espera
terraform plan                                          # No changes
rm -f terraform.tfstate terraform.tfstate.backup        # el local ya es una reliquia con secretos: bórralo
az storage blob list --account-name "$ST" -c tfstate --auth-mode login -o table   # app/lab.tfstate

# Ver el lock mientras otro apply está esperando confirmación
az storage blob show --account-name "$ST" -c tfstate -n app/lab.tfstate --auth-mode login \
  --query "{lease:properties.lease.status, lock:metadata.terraformlockid}" -o table
echo "<valor de lock>" | base64 -d | jq .           # ID, Who, Created

# Restaurar la versión anterior del estado (versionado del bootstrap)
az storage blob list --account-name "$ST" -c tfstate --prefix app/lab.tfstate --include v --auth-mode login \
  --query "[].{version:versionId, actual:isCurrentVersion, bytes:properties.contentLength}" -o table
az storage blob download --account-name "$ST" -c tfstate -n app/lab.tfstate --auth-mode login \
  --version-id "<versionId anterior>" -f anterior.json
jq '.serial' anterior.json                              # debe ser menor que el actual: sube el serial antes de push
terraform state push anterior.json                      # rechaza serial menor: edita .serial al actual+1, o usa -force con cuidado

# Quién ha leído o escrito el estado: logs de diagnóstico del servicio Blob a Log Analytics (Microsoft.Insights)
az monitor diagnostic-settings create --name audit-tfstate \
  --resource "$(az storage account show -g rg-tfstate-001 -n $ST --query id -o tsv)/blobServices/default" \
  --workspace "<id del workspace>" --logs '[{"category":"StorageRead","enabled":true},{"category":"StorageWrite","enabled":true}]'
# KQL: StorageBlobLogs | where ObjectKey endswith "lab.tfstate" | project TimeGenerated, OperationName, RequesterUpn, StatusCode

# Destruir en orden: primero la app, luego devolver el bootstrap a local, luego quitar el lock y destruir
terraform destroy -auto-approve
cd ../bootstrap && terraform apply -auto-approve -var asignar_rbac=true -var principal_id="$GRUPO" -var bloquear=false
terraform destroy -auto-approve
```

| **Capa de protección** | **Contra qué** | **Cómo se recupera** |
|---|---|---|
| Lease del backend | Dos escrituras simultáneas | No hay nada que recuperar: la segunda operación espera o falla antes de tocar el blob |
| `serial` y `lineage` | Subir un estado viejo o de otro proyecto | `state push` lo rechaza; solo `-force` lo salta |
| Versionado + `snapshot = true` | Un `apply` que dejó el estado mal | `az storage blob download --version-id` + `state push` (ajustando `serial`) |
| Soft delete (30 días) | Borrar el blob o el contenedor | `az storage blob undelete` / `az storage container restore` |
| Bloqueo `CanNotDelete` | Borrar la cuenta o el grupo | No hace falta: la operación falla con *ScopeLocked* |
| ZRS / GZRS | Caída de un centro de datos o de la región | Transparente (ZRS); failover de cuenta o lectura en la secundaria (RA-GZRS) |
| Logs de diagnóstico | No saber quién hizo qué | Consulta KQL en Log Analytics: identidad, operación, hora, código de estado |

---

## 9. Errores comunes

> ⚠️ **Solución de problemas**
> 
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | *no such host* / *could not resolve* en `init` con backend `azurerm` en Topaz | El backend usa el plano de datos del blob, que el emulador no tiene. En Topaz, backend `local` (7.7); el bloque `azurerm` solo en Azure real |
> | *Backend initialization required* / *Backend configuration changed* | Has tocado el bloque `backend`. Si quieres mover el estado: `init -migrate-state`. Si solo cambias de entorno con configuración parcial: `init -reconfigure`. Confundirlos copia el estado de `lab` encima del de `pro` |
> | *Error acquiring the state lock* … *LeaseAlreadyPresent* | Otra operación en curso o un lease huérfano. Lee `Who` y `Created`; si el proceso no existe, `force-unlock <ID>`; si tú creaste el lease a mano siguiendo el original, `az storage blob lease break` |
> | *Failed to unlock state: … lock ID does not match* | Has pasado un ID de otro lock (o inventado). Copia el ID exacto del mensaje de error; nunca uses `-lock=false` como atajo |
> | *AuthorizationPermissionMismatch* (403) en `init` o `plan` | Tienes rol de ARM pero no de datos. Necesitas *Storage Blob Data Contributor* (o Reader para solo `plan`) sobre el contenedor; tras asignarlo, espera hasta 5 minutos |
> | *KeyBasedAuthenticationNotPermitted* | La cuenta tiene `shared_access_key_enabled = false` y falta `use_azuread_auth = true` en el backend (o `--auth-mode login` en `az`). Es la cuenta haciendo su trabajo |
> | *Variables not allowed* en el bloque `backend` | El backend se evalúa antes que las variables. Usa configuración parcial: `backend "azurerm" {}` + `-backend-config=backends/lab.hcl` |
> | *Error: state snapshot was created by Terraform v1.10.x, which is newer than current v1.9.x* | Alguien aplicó con una versión más nueva. Fija `required_version` y la misma versión en CI y portátiles (`.terraform-version` con tenv/tfenv) |
> | `state push`: *serial … is lower than the current* / *lineage mismatch* | Intentas subir una versión antigua o de otro proyecto. Si es una restauración deliberada, edita `serial` al actual + 1; si el linaje no coincide, es otro estado: para |
> | Tras la migración, `plan` quiere crear todo de nuevo | Respondiste *no* a "copy existing state" o la `key` apunta a un blob distinto. Vuelve al backend anterior con `-reconfigure`, comprueba `state list` y repite la migración |
> | El `plan` propone destruir y recrear tras renombrar un recurso o módulo | Renombrar cambia la dirección en el estado. Añade un bloque `moved` (o `state mv`) antes de aplicar |
> | *Resource already managed by Terraform* al importar | Ya está en el estado con otra dirección. `state list | grep` y usa `moved` en vez de `import` |
> | *ScopeLocked* al destruir el bootstrap | El bloqueo `CanNotDelete`. Primero `apply -var bloquear=false`, después `destroy` |
> | Aparece `terraform.tfstate` en `git status` | Falta el `.gitignore` o está en otro directorio. Si ya se ha subido, contiene secretos: rota las contraseñas y claves que incluya, no basta con borrar el commit |

---

## 10. Autoevaluación

1. **¿Para qué sirven `serial` y `lineage`?**
   `serial` crece en cada escritura y evita pisar un estado más reciente; `lineage` identifica el estado desde su creación y impide mezclar dos proyectos. `state push` comprueba ambos.
2. **¿Por qué el backend `azurerm` no funciona en Topaz y qué se practica en su lugar?**
   Lee y escribe el blob por el plano de datos, que el emulador no implementa. Se practica la misma mecánica (migración, bloqueo, `state`, `moved`, `import`, `removed`) con el backend `local` y `path` explícito.
3. **¿Qué pasa si creas un lease a mano sobre el blob del estado, como proponía el original?**
   Terraform no puede escribir: el backend toma el lease él mismo en cada operación y lo libera al terminar. El lease manual es un bloqueo contra Terraform, no a su favor.
4. **¿Cómo sabes quién tiene el lock?**
   El mensaje de error incluye `ID`, `Who`, `Operation` y `Created`. Desde fuera, el metadato `terraformlockid` del blob (base64). `state pull` no muestra nada de eso.
5. **¿Cuándo usas `init -migrate-state` y cuándo `init -reconfigure`?**
   `-migrate-state` copia el estado del backend anterior al nuevo (local → azurerm). `-reconfigure` descarta el anterior sin copiar: es el correcto al cambiar de entorno con configuración parcial.
6. **¿Por qué el contenedor del estado se protege como un Key Vault?**
   El `tfstate` contiene en claro todas las contraseñas, claves y cadenas de conexión de la infraestructura. `sensitive = true` solo oculta la consola.
7. **¿Por qué Contributor sobre el grupo de recursos no permite usar el backend?**
   Es un rol de ARM: crea y borra la cuenta, pero no lee blobs. Leer y escribir el estado exige un rol de datos: *Storage Blob Data Contributor* (o Reader para solo `plan`).
8. **¿Qué diferencia hay entre `apply -refresh-only` y `apply` tras un drift?**
   `-refresh-only` acepta la realidad en el estado (si borraron una subred, la olvida). `apply` normal la recrea para que Azure vuelva a coincidir con el código.
9. **¿Cómo restauras el estado tras un `apply` que lo dejó mal?**
   Descargas la versión anterior del blob con `--version-id` (versionado del bootstrap), ajustas `serial` al actual + 1 y haces `state push`. Después, `plan` hasta ver *No changes*.
10. **¿Por qué una `key` por proyecto y entorno en vez de `terraform.tfstate` para todo?**
    Un estado gigante hace lento cada `plan`, convierte cualquier error en incidente global y obliga a dar acceso a todo a quien solo necesita una parte.
11. **¿Qué tres cosas hacen que el bootstrap sea seguro sin claves?**
    `shared_access_key_enabled = false` (solo Entra ID), *Storage Blob Data Contributor* asignado a un grupo sobre el contenedor, y versionado + soft delete + bloqueo `CanNotDelete` para recuperar y no perder.

---

## 11. Referencias

- [El estado de Terraform](https://developer.hashicorp.com/terraform/language/state), [datos sensibles en el estado](https://developer.hashicorp.com/terraform/language/state/sensitive-data) y [bloqueo del estado](https://developer.hashicorp.com/terraform/language/state/locking)
- [Backend `azurerm`](https://developer.hashicorp.com/terraform/language/backend/azurerm), [configuración parcial](https://developer.hashicorp.com/terraform/language/backend#partial-configuration) y [backend `local`](https://developer.hashicorp.com/terraform/language/backend/local)
- [Comandos `terraform state`](https://developer.hashicorp.com/terraform/cli/commands/state), [`force-unlock`](https://developer.hashicorp.com/terraform/cli/commands/force-unlock) y [`init -migrate-state` / `-reconfigure`](https://developer.hashicorp.com/terraform/cli/commands/init)
- [Bloque `moved`](https://developer.hashicorp.com/terraform/language/moved), [bloque `import`](https://developer.hashicorp.com/terraform/language/import), [bloque `removed`](https://developer.hashicorp.com/terraform/language/resources/syntax#removing-resources) y [modo `-refresh-only`](https://developer.hashicorp.com/terraform/cli/commands/plan#planning-modes)
- [Workspaces](https://developer.hashicorp.com/terraform/language/state/workspaces) y [`terraform_remote_state`](https://developer.hashicorp.com/terraform/language/state/remote-state-data)
- [Almacenar el estado en Azure Storage](https://learn.microsoft.com/es-es/azure/developer/terraform/store-state-in-azure-storage) (Microsoft Learn)
- [Versionado de blobs](https://learn.microsoft.com/es-es/azure/storage/blobs/versioning-overview), [soft delete](https://learn.microsoft.com/es-es/azure/storage/blobs/soft-delete-blob-overview), [change feed](https://learn.microsoft.com/es-es/azure/storage/blobs/storage-blob-change-feed) y [leases de blob](https://learn.microsoft.com/es-es/rest/api/storageservices/lease-blob)
- [Desactivar la autorización por clave compartida](https://learn.microsoft.com/es-es/azure/storage/common/shared-key-authorization-prevent) y [roles RBAC de datos](https://learn.microsoft.com/es-es/azure/storage/blobs/assign-azure-role-data-access)
- [Monitorizar Blob Storage](https://learn.microsoft.com/es-es/azure/storage/blobs/monitor-blob-storage) y [tabla `StorageBlobLogs`](https://learn.microsoft.com/es-es/azure/azure-monitor/reference/tables/storagebloblogs)
- [Identidades gestionadas](https://learn.microsoft.com/es-es/entra/identity/managed-identities-azure-resources/overview) y [OIDC desde GitHub Actions](https://learn.microsoft.com/es-es/azure/developer/github/connect-from-azure-openid-connect)
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)