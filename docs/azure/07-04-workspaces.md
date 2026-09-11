# 🗂️ Workspaces: varios estados para un mismo código

> Un **workspace** es un estado alternativo: mismo código, mismo backend, mismas credenciales, otro `tfstate`. Sirve para desplegar la misma infraestructura varias veces sin duplicar archivos: una copia por desarrollador, una por rama, una por cliente. Es una herramienta útil y también la más malinterpretada de Terraform, porque su nombre sugiere "entorno" y no lo es: *dev* y *pro* con distinta suscripción, distintos permisos y distinto radio de explosión no deberían compartir backend ni credenciales, y eso es justo lo que un workspace obliga a compartir. Esta página enseña cómo funcionan, cómo usarlos sin aplicar en el sitio equivocado, y cuándo elegir en su lugar un directorio por entorno. Todo funciona en **Topaz**.

**🎯 Objetivos de aprendizaje**
- Explicar qué es y qué no es un workspace, y dónde guarda su estado con backend `local` y `azurerm`.
- Usar `workspace new/select/list/show/delete`, `-or-create` y `TF_WORKSPACE`.
- Parametrizar el código con un mapa indexado por `terraform.workspace` y bloquear el workspace `default`.
- Decidir entre workspaces y directorio por entorno con criterios concretos.
- Serializar por workspace en CI y separar permisos por estado en Azure real.

> **🔷 Requisitos previos.** Páginas 1 a 9 completadas y destruidas, `~/tf-st/providers.tf` disponible, `az account show --query environmentName -o tsv` → `Topaz`.

---

## 1. Qué es un workspace (y qué comparte)

```text
                 ┌── workspace "default"  →  terraform.tfstate                       (local)
un solo código ──┼── workspace "ana"      →  terraform.tfstate.d/ana/terraform.tfstate
un solo backend  ├── workspace "pr-142"   →  terraform.tfstate.d/pr-142/terraform.tfstate
una credencial   └── …
                 con backend azurerm, key = "moodle.tfstate":
                     default → tfstate/moodle.tfstate
                     ana     → tfstate/moodle.tfstateenv:ana        ◄── mismo contenedor, sufijo "env:"
                     pr-142  → tfstate/moodle.tfstateenv:pr-142
```

| **Cambia por workspace** | **Es común a todos los workspaces** |
|---|---|
| El archivo de estado y su lock · el valor de `terraform.workspace` en el código · los recursos desplegados (si el código los nombra distinto) | El código `.tf` · el bloque `backend` (cuenta, contenedor, credenciales) · la configuración del `provider` (suscripción, tenant) · la versión de Terraform y providers (`.terraform.lock.hcl`) · el directorio `.terraform/` |

> ⚠️ **Los nombres de los recursos deben incluir el workspace.** Si el código dice `name = "rg-moodle-001"`, el segundo workspace intentará crear otro grupo con el mismo nombre en la misma suscripción: para grupos de recursos lo "adoptará" silenciosamente y los dos estados creerán ser dueños del mismo objeto; para cuentas de almacenamiento fallará con *already taken*. Todo nombre lleva `${terraform.workspace}` o un derivado.

---

## 2. Comandos

| **Comando** | **Qué hace** | **Detalle que importa** |
|---|---|---|
| `workspace list` | Lista; el activo lleva `*` | Con backend `azurerm` lista los blobs `…env:*` del contenedor |
| `workspace new ana` | Crea un estado vacío y **lo selecciona** | El `select` posterior del original era redundante. `-state=archivo` lo crea a partir de un estado existente |
| `workspace select ana` | Cambia el activo | `-or-create` (≥ 1.4) lo crea si no existe: el comando de CI |
| `workspace show` | Imprime el activo | Ponlo en el prompt de la shell si trabajas con varios |
| `workspace delete ana` | Borra el estado | Rechaza si el estado no está vacío (`destroy` antes) o si está activo. `-force` borra el estado y **deja los recursos huérfanos en Azure**. `default` no se puede borrar |
| `TF_WORKSPACE=ana terraform plan` | Fija el workspace para ese comando sin cambiar el activo | Lo que usa un pipeline: sin estado "activo" que dependa del runner. Debe existir ya (o `select -or-create` antes) |
| `terraform.workspace` | Expresión: nombre del activo | Válido en `locals`, nombres, tags. No en el bloque `backend` |

---

## 3. Workspaces o directorio por entorno

El original proponía "un workspace por entorno" y a la vez un directorio por entorno. Son dos patrones distintos y hay que elegir. La regla práctica: si dos copias de la infraestructura deben tener **distinta suscripción, distintos permisos o distinta gente que puede aplicar**, son directorios. Si son copias equivalentes del mismo equipo, son workspaces.

| **Criterio** | **Workspaces** | **Directorio por entorno (página 7.5)** |
|---|---|---|
| Suscripción / tenant | La misma para todos (el `provider` es común) | Una por entorno: `pro` en su propia suscripción |
| Permisos sobre el estado | Mismo contenedor: quien lee `dev` lee `pro` (salvo ABAC, 10.7) | Contenedor o cuenta distintos; RBAC distinto; OIDC con `subject` distinto |
| Riesgo de aplicar en el sitio equivocado | Alto: un `select` olvidado y el `apply` va a `pro` | Bajo: estás en otro directorio con otro backend |
| Diferencias entre copias | Solo tamaños y cantidades (mapa por workspace). Recursos que existen en uno y no en otro: `count` condicional, se vuelve ilegible | Cada directorio compone módulos como quiera; `pro` puede tener Front Door y `dev` no |
| Versiones de módulos | La misma para todos: no puedes probar el módulo v2 en `dev` con `pro` en v1 | `source = "…?ref=v2.0.0"` por directorio: promoción gradual |
| Crear y destruir copias | Un comando: ideal para lo efímero | Un directorio nuevo + backend + pipeline: pesado para lo efímero |
| **Úsalo para** | *Sandbox* por desarrollador, entorno por PR o rama, una copia por cliente o región del **mismo** nivel | `dev` / `pre` / `pro` y cualquier separación con distinto propietario o nivel de confianza |

> **🔷 Se combinan bien.** Directorio `entornos/dev/` con su backend y, dentro, workspaces por desarrollador o por PR (`dev` + `ana`, `dev` + `pr-142`). Directorio `entornos/pro/` con un único workspace `default`. Así cada herramienta hace lo que sabe hacer.

---

## 4. Parametrizar por workspace

El patrón: un mapa en `locals` con la configuración de cada workspace permitido, indexado por `terraform.workspace`. Tiene una virtud escondida: si el workspace activo no está en el mapa (el `default` tras olvidar el `select`, o un error tipográfico), el `plan` falla antes de tocar nada.

```hcl
# locals.tf
locals {
  entornos = {
    ana    = { cidr = "10.90.0.0/16", subredes = ["web"],                   replicacion = "LRS", retencion = 7,  criticidad = "baja" }
    pr-142 = { cidr = "10.91.0.0/16", subredes = ["web"],                   replicacion = "LRS", retencion = 7,  criticidad = "baja" }
    pre    = { cidr = "10.92.0.0/16", subredes = ["web", "datos"],          replicacion = "ZRS", retencion = 14, criticidad = "media" }
  }
  ws  = terraform.workspace
  cfg = local.entornos[local.ws]     # "default" o un typo → error de clave: nada se planifica
  tags = { proyecto = "moodle", entorno = local.ws, gestion = "terraform", criticidad = local.cfg.criticidad }
}

# El tamaño de la VM o el SKU de la base de datos (página 4, solo Azure real) irían en el mismo mapa:
#   vm_size = "Standard_B2s" / "Standard_D4s_v5", db_sku = "B_Standard_B1ms" / "GP_Standard_D2ds_v4"
# Lo que NUNCA va en el mapa ni en un tfvars: contraseñas. random_password + Key Vault (página 6) o ephemeral (≥ 1.10).
```

| **Alternativa** | **Cuándo** | **Pega** |
|---|---|---|
| Mapa en `locals` (arriba) | Pocos workspaces conocidos de antemano | Cada workspace nuevo exige tocar el código (que es también una ventaja: queda en Git) |
| `terraform apply -var-file=vars/${ws}.tfvars` | Muchos valores por workspace | Nadie te impide pasar `pre.tfvars` con el workspace `ana` activo. Un `precondition` que compare `var.entorno == terraform.workspace` lo evita |
| Un valor por defecto para workspaces desconocidos (`try(local.entornos[ws], local.entornos.ana)`) | Entornos por PR con nombre dinámico (`pr-<n>`) | Pierdes la protección contra `default`. Compénsalo con `precondition { condition = terraform.workspace != "default" }` |
| `environments/dev/terraform.tfvars` (el original) | Nunca así | Terraform solo carga automáticamente `terraform.tfvars` y `*.auto.tfvars` del directorio actual. Ese archivo no se lee: el apply iría con los valores por defecto |

---

## 5. Laboratorio en Topaz

```bash
mkdir -p ~/tf-ws && cd ~/tf-ws && cp ~/tf-st/providers.tf .
# locals.tf: el bloque de 10.4 tal cual
cat > main.tf <<'EOF'
resource "azurerm_resource_group" "moodle" {
  name     = "rg-moodle-${local.ws}-001"
  location = "eastus"
  tags     = local.tags
  lifecycle {
    ignore_changes = [tags]
    precondition {
      condition     = terraform.workspace != "default"
      error_message = "No se despliega en el workspace 'default'. Usa: terraform workspace select <nombre>"
    }
  }
}
resource "azurerm_virtual_network" "moodle" {
  name                = "vnet-moodle-${local.ws}"
  resource_group_name = azurerm_resource_group.moodle.name
  location            = azurerm_resource_group.moodle.location
  address_space       = [local.cfg.cidr]
  tags                = local.tags
}
resource "azurerm_subnet" "moodle" {
  for_each             = { for i, s in local.cfg.subredes : s => i + 1 }
  name                 = "snet-${each.key}"
  resource_group_name  = azurerm_resource_group.moodle.name
  virtual_network_name = azurerm_virtual_network.moodle.name
  address_prefixes     = [cidrsubnet(local.cfg.cidr, 8, each.value)]
}
resource "random_string" "sufijo" {
  length  = 6
  upper   = false
  special = false
}
resource "azurerm_storage_account" "moodledata" {
  name                            = "stmoodle${replace(local.ws, "-", "")}${random_string.sufijo.result}"
  resource_group_name             = azurerm_resource_group.moodle.name
  location                        = azurerm_resource_group.moodle.location
  account_tier                    = "Standard"
  account_replication_type        = local.cfg.replicacion
  min_tls_version                 = "TLS1_2"
  allow_nested_items_to_be_public = false
  shared_access_key_enabled       = false
  blob_properties { delete_retention_policy { days = local.cfg.retencion } }
  tags = local.tags
}
output "workspace"  { value = terraform.workspace }
output "resumen"    { value = { grupo = azurerm_resource_group.moodle.name, subredes = keys(azurerm_subnet.moodle), replicacion = local.cfg.replicacion } }
EOF
terraform init

# ─── 1. default está protegido ──────────────────────────────────────────────────
terraform workspace list                       # * default
terraform plan                                 # Error: Invalid index … key "default" (el mapa) — y si lo quitaras, el precondition

# ─── 2. Primer workspace ────────────────────────────────────────────────────────
terraform workspace new ana                    # "Created and switched to workspace "ana"!"  (no hace falta select)
terraform workspace show                       # ana
terraform apply -auto-approve                  # 5 to add: grupo, vnet, 1 subred, sufijo, cuenta LRS
ls terraform.tfstate.d/                        # ana/
terraform output resumen

# ─── 3. Segundo workspace: estado vacío, recursos nuevos ────────────────────────
terraform workspace new pre
terraform state list                           # (vacío)
terraform apply -auto-approve                  # 6 to add: 2 subredes, cuenta ZRS
az group list --query "[?starts_with(name,'rg-moodle')].{grupo:name, entorno:tags.entorno}" -o table   # ambos conviven
ls terraform.tfstate.d/                        # ana/  pre/

# ─── 4. Sin cambiar el activo: TF_WORKSPACE ─────────────────────────────────────
terraform workspace show                       # pre
TF_WORKSPACE=ana terraform output workspace    # "ana"
TF_WORKSPACE=pr-142 terraform plan             # Error: workspace "pr-142" does not exist  → hay que crearlo:
terraform workspace select -or-create pr-142 && terraform workspace select pre

# ─── 5. El código es común: un cambio afecta a todos ────────────────────────────
sed -i 's/gestion = "terraform"/gestion = "terraform", curso = "moodle-azure"/' locals.tf
terraform plan | grep -E "to add|update"       # pre: update in-place en vnet y cuenta (el grupo ignora tags)
TF_WORKSPACE=ana terraform plan | grep -E "to add|update"   # ana: lo mismo. Ambos deben aplicarse; hasta entonces, drift de código
terraform apply -auto-approve && TF_WORKSPACE=ana terraform apply -auto-approve

# ─── 6. Sin sufijo de workspace en el nombre: la colisión ───────────────────────
# Prueba mental (no lo ejecutes): cambia name a "rg-moodle-001" y aplica en ana y pre.
# Grupo: ambos estados "poseen" el mismo. Cuenta: el segundo falla con StorageAccountAlreadyTaken.

# ─── 7. Borrar un workspace ─────────────────────────────────────────────────────
terraform workspace delete pre                 # Error: Workspace "pre" is not empty  (y además está activo)
terraform destroy -auto-approve                # 6 destroyed (en pre)
terraform workspace select ana && terraform workspace delete pre    # ahora sí
terraform workspace delete pr-142              # vacío: se borra directamente
terraform destroy -auto-approve                # ana
terraform workspace select default && terraform workspace delete ana
terraform workspace list                       # * default
ls terraform.tfstate.d/ 2>/dev/null            # vacío o inexistente
```

---

## 6. Azure real: backend remoto, permisos y CI

```bash
# Con el backend de la página 7 (key = "moodle/dev.tfstate") los workspaces se guardan como blobs hermanos:
az storage blob list --account-name $ST -c tfstate --prefix moodle/ --auth-mode login --query "[].name" -o tsv
#   moodle/dev.tfstate              ← default
#   moodle/dev.tfstateenv:ana
#   moodle/dev.tfstateenv:pr-142
terraform workspace list            # lee esa lista: default, ana, pr-142

# Permiso por workspace (ABAC): que el pipeline de PR solo toque blobs "…env:pr-*"
az role assignment create --assignee-object-id <sp-ci-pr> --assignee-principal-type ServicePrincipal \
  --role "Storage Blob Data Contributor" --scope "<id del contenedor tfstate>" \
  --condition "@Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path] StringLike 'moodle/dev.tfstateenv:pr-*'" \
  --condition-version 2.0
# Es el límite práctico del aislamiento por workspace: útil para PRs, insuficiente para separar pro de dev.
```

```yaml
# .github/workflows/pr-env.yml  (entorno efímero por PR; OIDC y backend como en las páginas 6 y 7)
on:
  pull_request: { types: [opened, synchronize, closed] }
concurrency:
  group: moodle-dev-pr-${{ github.event.number }}      # un lock de cola por workspace (página 8)
  cancel-in-progress: false
env:
  TF_WORKSPACE: pr-${{ github.event.number }}          # todos los pasos usan este workspace; nada de "select" con estado en el runner
jobs:
  desplegar:
    if: github.event.action != 'closed'
    steps:
      - run: terraform init -input=false
      - run: terraform workspace select -or-create "$TF_WORKSPACE"   # TF_WORKSPACE exige que exista: créalo aquí
      - run: terraform apply -input=false -auto-approve -lock-timeout=10m
  destruir:
    if: github.event.action == 'closed'
    steps:
      - run: terraform init -input=false
      - run: terraform destroy -input=false -auto-approve -lock-timeout=10m
      - run: unset TF_WORKSPACE && terraform workspace select default && terraform workspace delete "pr-${{ github.event.number }}"
```

---

## 7. Errores comunes

> ⚠️ **Solución de problemas**
> 
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | *Invalid index … The given key does not identify an element* sobre `local.entornos` | Workspace activo fuera del mapa: `default` o un typo. `workspace show` y `select`. Es la protección funcionando |
> | *Resource precondition failed: No se despliega en 'default'* | Igual que arriba, con mensaje propio. Si el mapa ya protege, el `precondition` es redundante pero más legible |
> | Aplicaste en el workspace equivocado | Si los nombres llevan el workspace, has creado una copia extra: `destroy` en ese workspace. Si no lo llevan, dos estados comparten recursos: `state rm` en el equivocado y revisa a mano. Y la lección: `workspace show` en el prompt |
> | *StorageAccountAlreadyTaken* / *already exists* en el segundo workspace | Nombre sin `${terraform.workspace}`. Añádelo (o un derivado con `replace` si el recurso no admite guiones) |
> | *Workspace "pr-142" does not exist* con `TF_WORKSPACE` | La variable no crea: `terraform workspace select -or-create` antes (o `workspace new`) |
> | *Workspace "pre" is not empty* al borrar | `destroy` primero. `-force` borra el estado y deja los recursos vivos y sin dueño: solo si ya los borraste por otro camino |
> | *Cannot delete the currently active workspace* / *cannot delete "default"* | Cambia a otro antes. `default` siempre existe y no se puede borrar; si no lo usas, déjalo vacío y protegido con el mapa o el `precondition` |
> | El `plan` de `pre` muestra cambios que no has hecho | Alguien cambió el código (común) y aplicó solo en su workspace. Cada cambio de código debe aplicarse en todos los workspaces vivos; hasta entonces hay *drift de código*. En CI: un job por workspace tras el merge |
> | *Variables not allowed* al usar `terraform.workspace` en el bloque `backend` | El backend no admite expresiones. Los workspaces ya separan el estado por sí solos (sufijo `env:`); no hace falta cambiar la `key` |
> | El `environments/dev/terraform.tfvars` del original no tiene efecto | Terraform solo carga solo `terraform.tfvars` y `*.auto.tfvars` del directorio actual. Pásalo con `-var-file` o, mejor, usa el mapa de 10.4 |
> | `workspace list` con backend `azurerm` muestra workspaces que nadie creó | Cualquier blob `<key>env:<x>` del contenedor cuenta como workspace: restos de PRs cuyo job `destruir` falló. `state list` en cada uno; si están vacíos, `workspace delete` |
> | Un `random_password` distinto por workspace "se pierde" al borrar el workspace | Comportamiento esperado: vive en ese estado. Si la contraseña debe sobrevivir, guárdala en Key Vault (página 6) antes de destruir |
> | En Topaz, los grupos de dos workspaces aparecen con la misma tag `entorno` | El grupo lleva `ignore_changes = [tags]` por la lectura de tags del emulador (página 2): la tag se pone al crear y no se corrige después. Compruébalo en `vnet` o en la cuenta, que sí las actualizan |

---

## 8. Autoevaluación

1. **¿Qué cambia entre dos workspaces y qué no?**
   Cambia solo el archivo de estado (y su lock) y el valor de `terraform.workspace`. Comparten código, backend, credenciales, suscripción del `provider` y versiones de providers.
2. **¿Por qué HashiCorp desaconseja un workspace por entorno (dev/pre/pro)?**
   Porque esos entornos deberían tener distinta suscripción, distintos permisos y distinto radio de explosión, y el workspace obliga a compartir backend y credenciales. Un `select` olvidado aplica en producción.
3. **¿Para qué sí son la herramienta adecuada?**
   Copias equivalentes del mismo nivel y del mismo equipo: *sandbox* por desarrollador, entorno efímero por PR o rama, una copia por cliente o región.
4. **¿Dónde guarda el estado cada workspace con backend `local` y con `azurerm`?**
   Local: `terraform.tfstate.d/<nombre>/terraform.tfstate`. Azurerm: un blob hermano con sufijo `<key>env:<nombre>` en el mismo contenedor. `default` usa la ruta sin sufijo.
5. **¿Qué protege el mapa `local.entornos[terraform.workspace]`?**
   Si el workspace activo no está en el mapa (`default` o un typo), el `plan` falla por clave inexistente antes de tocar nada.
6. **¿Por qué todos los nombres deben incluir `${terraform.workspace}`?**
   Los workspaces comparten suscripción. Sin sufijo, el segundo workspace colisiona: adopta el mismo grupo de recursos (dos estados dueños de un objeto) o falla con *already taken* en cuentas de almacenamiento.
7. **¿Qué está mal en `environments/dev/terraform.tfvars` junto a `workspace new dev`?**
   Mezcla dos patrones y además ese archivo no se carga: Terraform solo lee automáticamente `terraform.tfvars` y `*.auto.tfvars` del directorio actual. Y contenía una contraseña en claro.
8. **¿Qué diferencia hay entre `workspace select` y `TF_WORKSPACE`?**
   `select` cambia el activo y lo guarda en `.terraform/environment` del directorio. `TF_WORKSPACE` lo fija por comando sin estado en disco: es lo que usa un pipeline, junto a `select -or-create` para crearlo.
9. **¿Qué pasa con `workspace delete -force`?**
   Borra el estado aunque no esté vacío: los recursos siguen en Azure sin ningún estado que los gobierne. Solo tras un `destroy` o si ya se borraron por otro camino.
10. **¿Qué es el "drift de código" entre workspaces y cómo se evita?**
    El código es común, pero cada workspace se aplica por separado: un cambio aplicado solo en `ana` deja a `pre` con un `plan` pendiente. Se evita aplicando en todos los workspaces vivos tras cada merge (un job por workspace en CI).
11. **¿Cómo se combinan bien workspaces y directorios?**
    Directorio por entorno real (`dev`, `pre`, `pro`) con su propio backend y permisos; dentro de `dev`, workspaces efímeros por persona o PR. `pro` solo con `default`.

---

## 9. Referencias

- [Workspaces](https://developer.hashicorp.com/terraform/language/state/workspaces) (incluye la sección *When to use multiple workspaces*, con la recomendación de no usarlos para separar entornos) y [workspaces en la CLI](https://developer.hashicorp.com/terraform/cli/workspaces)
- [Comandos `terraform workspace`](https://developer.hashicorp.com/terraform/cli/commands/workspace) (`new`, `select -or-create`, `list`, `show`, `delete`) y [variable `TF_WORKSPACE`](https://developer.hashicorp.com/terraform/cli/config/environment-variables#tf_workspace)
- [Backend `azurerm`](https://developer.hashicorp.com/terraform/language/backend/azurerm) (nomenclatura `env:` de los blobs por workspace) y [configuración parcial por directorio](https://developer.hashicorp.com/terraform/language/backend#partial-configuration)
- [Archivos `.tfvars` y cuáles se cargan automáticamente](https://developer.hashicorp.com/terraform/language/values/variables#variable-definitions-tfvars-files), [`precondition`](https://developer.hashicorp.com/terraform/language/expressions/custom-conditions#preconditions-and-postconditions) y [variables `ephemeral`](https://developer.hashicorp.com/terraform/language/values/variables#ephemeral-variables)
- [Guía de estilo: múltiples entornos](https://developer.hashicorp.com/terraform/language/style#multiple-environments) y [`cidrsubnet`](https://developer.hashicorp.com/terraform/language/functions/cidrsubnet)
- [Condiciones ABAC en RBAC de Azure](https://learn.microsoft.com/es-es/azure/role-based-access-control/conditions-overview) y [ejemplos ABAC para blobs](https://learn.microsoft.com/es-es/azure/storage/blobs/storage-auth-abac-examples) (permisos por prefijo de blob)
- [Concurrencia en GitHub Actions](https://docs.github.com/actions/using-jobs/using-concurrency) y [evento `pull_request`](https://docs.github.com/actions/using-workflows/events-that-trigger-workflows#pull_request) (entornos efímeros por PR)
- [Documentación de Moodle para administradores](https://docs.moodle.org/es/Administrador) (contexto de la aplicación del laboratorio final)
- [Azure Local Emulator (Topaz)](https://github.com/Azure/azure-local-emulator)