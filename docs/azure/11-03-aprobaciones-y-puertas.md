# 🚧 Aprobaciones y puertas: seis capas entre el commit y Azure

> Las páginas 13 y 14 dejaron un pipeline con una aprobación delante de producción y políticas sobre el plan. Esta página se pregunta qué pasa cuando alguien no usa el pipeline. Un revisor cansado aprueba sin mirar; un `workflow_dispatch` mal condicionado aplica desde una rama equivocada; un compañero con permisos ejecuta `terraform destroy` desde su portátil un viernes. Ninguna puerta del pipeline detiene eso. Por eso las puertas se organizan en **capas**: la rama (quién puede fusionar y con qué comprobaciones), el código (análisis estático), el plan (políticas), el humano (revisores, ventanas horarias), Azure (políticas con *deny*, bloqueos de borrado, roles acotados) y la verificación posterior (pruebas de humo, plan a cero). Cada capa para algo que la anterior no ve, y cada una se abre de una forma explícita que deja rastro. El laboratorio ejecuta en **Topaz** todas las puertas que son scripts (destrucción, etiquetas, horario, humo) y crea los recursos de protección (bloqueos, asignaciones de política); su *efecto*, que lo evalúa ARM, se comprueba en el bloque de Azure real.

**🎯 Objetivos de aprendizaje**
- Situar cada control en una de las seis capas y explicar qué detiene y a quién.
- Configurar reglas de rama, CODEOWNERS y comprobaciones requeridas para que la fusión sea la primera puerta.
- Poner la aprobación humana en el job correcto, con *wait timer*, ramas permitidas y sin auto-aprobación; en Azure DevOps, los *checks* equivalentes.
- Desplegar con Terraform las puertas que viven en Azure (bloqueos, Azure Policy) y aplicar el patrón de dos PRs para cambios destructivos.
- Añadir puertas posteriores al apply (pruebas de humo, plan a cero) entre dev y pro, y auditar quién aprobó qué.

> **🔷 Requisitos previos.** Páginas 1 a 14 completadas y destruidas, backend de la página 4 en Topaz, `~/tf-st/providers.tf`, Terraform `1.11.x`, `jq`, `az account show --query environmentName -o tsv` → `Topaz`. Para el bloque de Azure real: `gh` autenticado con permisos de administración del repositorio.

---

## 1. Seis capas, y a quién detiene cada una

El original clasifica las puertas por tipo (automática, manual, temporal, de seguridad). Es más útil clasificarlas por **dónde viven**, porque eso determina a quién detienen. Las cuatro primeras capas están en el pipeline: detienen al pipeline. Las dos últimas están en Azure o miran a Azure: detienen a cualquiera.

| **Capa** | **Qué detiene** | **A quién no detiene** | **Herramienta** |
|---|---|---|---|
| **1. Rama** | Fusionar sin revisión, sin que las comprobaciones pasen, con la rama desactualizada, sin el dueño del directorio | A quien tenga permiso de *bypass*; a quien no pase por Git | *Rulesets*, CODEOWNERS, *required status checks*; en DevOps, *branch policies* |
| **2. Código** | Formato, sintaxis, configuraciones inseguras, secretos en el repositorio | A lo que solo se ve con el estado delante (qué se destruye) | `fmt`, `validate`, tflint, trivy, gitleaks (página 13) |
| **3. Plan** | Destrucción de recursos con datos, reemplazos, ausencia de etiquetas, valores prohibidos | A quien ejecute Terraform fuera del pipeline | `jq`, conftest, `terraform test` (página 14) |
| **4. Humano** | Lo que ninguna regla formula: "¿es este el momento?", "¿es esto lo que acordamos?" | A sí mismo, si aprueba sin leer; por eso necesita el resumen delante | *Environments*: revisores, *wait timer*, ramas; DevOps: *Approvals*, *Business hours* |
| **5. Azure** | Borrar un recurso bloqueado, crear fuera de las regiones permitidas, sin etiqueta obligatoria, con una identidad sin rol | A un *Owner* que quite el bloqueo o la política primero (y eso queda en el Activity Log) | Bloqueos `CanNotDelete`, Azure Policy con *deny*, RBAC acotado (página 12) |
| **6. Verificación** | Que pro reciba un cambio que en dev no funciona; que el apply deje deriva | Nada que ya haya pasado: es la última, mira hacia atrás | Pruebas de humo con `az` y `curl`, `plan -detailed-exitcode` = 0, escaneo de política |

> **⚠️ Toda puerta tiene que poder abrirse.** Una puerta que nadie puede abrir se rodea (se desactiva el check, se aplica desde el portátil). El diseño correcto es que cada puerta se abra con un acto *explícito y auditado*: una etiqueta en la PR puesta por un dueño, un `workflow_dispatch` con campo `motivo` obligatorio, un commit propio que quita un bloqueo. Lo que se prohíbe no es pasar: es pasar sin dejar rastro.

---

## 2. Capa 1: la fusión es la primera puerta

El original no protege la rama: cualquier push a `main` dispara el apply. Con una regla de rama, `main` solo recibe fusiones de PRs que hayan pasado las comprobaciones exactas del workflow de la página 13 y que haya aprobado alguien distinto del autor; si el directorio `infra/` tiene dueños, uno de ellos.

```bash
# .github/CODEOWNERS: quien debe aprobar cambios en infraestructura (equipo, no persona)
infra/            @moodle-org/plataforma
.github/workflows/ @moodle-org/plataforma          # el pipeline es infraestructura: cambiarlo también requiere dueño

# Regla de rama (ruleset) sobre main: sin borrado, sin force-push, PR con una aprobación de CODEOWNERS,
# aprobaciones invalidadas si llegan commits nuevos, y las comprobaciones del workflow como requisito
gh api -X POST repos/{owner}/{repo}/rulesets --input - <<'EOF'
{
  "name": "main", "target": "branch", "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "pull_request", "parameters": {
        "required_approving_review_count": 1, "require_code_owner_review": true,
        "dismiss_stale_reviews_on_push": true, "require_last_push_approval": true,
        "required_review_thread_resolution": true } },
    { "type": "required_status_checks", "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [ { "context": "comprobar" }, { "context": "plan (dev)" }, { "context": "plan (pro)" } ] } }
  ]
}
EOF
# strict = la rama debe estar al día con main: el plan que se revisó se hizo sobre el código que se va a fusionar
# Los "context" son los nombres exactos de los jobs (con la matriz entre paréntesis). Si renombras un job, la regla deja de exigirlo.
gh api repos/{owner}/{repo}/rulesets --jq '.[].name'

# Azure DevOps: la política de rama equivale al ruleset
az repos policy approver-count create --branch main --repository-id <id> --minimum-approver-count 1 --creator-vote-counts false --reset-on-source-push true --blocking true --enabled true --org … -p …
az repos policy build create --branch main --repository-id <id> --build-definition-id <id del pipeline> --display-name "terraform plan" --manual-queue-only false --queue-on-source-update-only false --valid-duration 0 --blocking true --enabled true --org … -p …
az repos policy required-reviewer create --branch main --repository-id <id> --required-reviewer-ids <grupo plataforma> --path-filter "/infra/*" --blocking true --enabled true --org … -p …
```

---

## 3. Capa 4: la puerta humana, bien colocada

El original crea un job `Approve_Prod` con `environment: 'Producción'` cuyo único paso es un `echo`, y después un `Deploy_Prod` sin *environment*. La aprobación protege el `echo`; el apply corre libre. La regla es simple: **el *environment* va en el job que ejecuta el apply**, y ese job debe mostrar al revisor lo que va a aprobar antes de pedir la aprobación. Como la aprobación detiene el job *antes* de que empiece, el resumen tiene que venir de otro sitio: el comentario de la PR y la huella (página 14), enlazados desde el *summary* del job de plan.

```bash
# Environment moodle-pro: revisores, ramas, espera mínima y sin auto-aprobación
gh api -X PUT repos/{owner}/{repo}/environments/moodle-pro --input - <<EOF
{
  "wait_timer": 10,
  "prevent_self_review": true,
  "reviewers": [ { "type": "Team", "id": $(gh api orgs/moodle-org/teams/plataforma --jq .id) } ],
  "deployment_branch_policy": { "protected_branches": true, "custom_branch_policies": false }
}
EOF
# wait_timer (minutos): tiempo entre que el job queda listo y puede ejecutarse aunque ya esté aprobado. Diez minutos bastan
#   para que un "aprobado" reflejo se pueda cancelar. No es una ventana horaria: para eso, un paso (15.6) o el check de DevOps.
# prevent_self_review: quien lanzó el workflow (el autor del merge) no puede aprobar su propio despliegue.

# Lo que el revisor tiene delante: el summary del job de plan enlaza al comentario de la PR y publica la huella
- run: |
    { echo "## Plan pro"; cat resumen.md; echo; echo "Huella: \`$(sha256sum huella.json | cut -c1-16)\`";
      echo; echo "Políticas: conftest ✅ · terraform test ✅"; echo; echo "[Plan completo en la PR](${{ github.event.pull_request.html_url }})"; } >> "$GITHUB_STEP_SUMMARY"

# Quién aprobó, cuándo y con qué comentario: la auditoría de la capa 4
gh api repos/{owner}/{repo}/actions/runs/<run_id>/approvals --jq '.[] | {quien: .user.login, estado: .state, comentario: .comment, environments: [.environments[].name]}'
gh api repos/{owner}/{repo}/deployments --jq '.[] | select(.environment == "moodle-pro") | {sha, creador: .creator.login, cuando: .created_at}' | head -5

# Azure DevOps: los checks del environment, y el "gate" clásico que el original menciona ya no existe como tal
#   Approvals            → revisores (mínimo, plazo, ¿puede aprobar quien lanzó?: no)
#   Branch control       → solo refs/heads/main, y verificar que la rama está protegida
#   Business hours       → ventana horaria nativa (L-V 9:00-17:00 Europe/Madrid)
#   Exclusive lock       → una ejecución a la vez sobre el environment (página 13)
#   Required template    → el job debe venir de templates/tf.yml: nadie inventa otro apply
#   Invoke Azure Function / REST API → una puerta programada (¿hay un incidente abierto? ¿está en cambio congelado?)
az devops invoke --area pipelines --resource approvals --route-parameters project=<proyecto> --api-version 7.1-preview --org … \
  --query "value[].{quien:steps[0].actualApprover.displayName, estado:status, cuando:steps[0].lastModifiedOn}" -o table
```

---

## 4. Capa 5: las puertas que viven en Azure

Todo lo anterior detiene al pipeline. Estas tres puertas las evalúa Azure Resource Manager en cada petición, venga del pipeline, del portal, de `az` o de un Terraform ejecutado en un portátil. Y las tres se despliegan con Terraform, así que forman parte del código que las otras capas protegen.

```hcl
# 1. Bloqueo de borrado: nadie borra el recurso (ni su grupo) mientras el bloqueo exista, sea quien sea
resource "azurerm_management_lock" "datos" {
  count      = var.proteger ? 1 : 0                # el interruptor: quitar el bloqueo es un cambio de código, con su PR
  name       = "no-borrar"
  scope      = azurerm_storage_account.moodledata.id
  lock_level = "CanNotDelete"                       # ReadOnly también impide modificar: demasiado para un recurso vivo
  notes      = "Datos de Moodle. Quitar solo con proteger=false en un PR propio, aprobado en moodle-pro."
}
# Un destroy contra él: Error: deleting … StatusCode=409 … ScopeLocked … "The scope … cannot perform delete operation because following scope(s) are locked"
# Junto con prevent_destroy (página 14) son dos capas distintas: una la evalúa Terraform antes de intentarlo; otra Azure cuando lo intenta.

# 2. Azure Policy con efecto deny: ARM rechaza la petición que no cumple, en el apply, con RequestDisallowedByPolicy
resource "azurerm_resource_group_policy_assignment" "ubicaciones" {
  name                 = "ubicaciones-permitidas"
  resource_group_id    = azurerm_resource_group.moodle.id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c"   # built-in "Allowed locations"
  parameters           = jsonencode({ listOfAllowedLocations = { value = ["eastus", "westeurope"] } })
}
resource "azurerm_resource_group_policy_assignment" "tag_entorno" {
  name                 = "tag-entorno-obligatoria"
  resource_group_id    = azurerm_resource_group.moodle.id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/871b6d14-10aa-478d-b590-94f262ecfa99"   # built-in "Require a tag on resources"
  parameters           = jsonencode({ tagName = { value = "entorno" } })
}
# La política no la "consulta" el pipeline (el az policy state list del original mide lo que ya existe y tarda horas):
# la aplica ARM al recibir la petición. La puerta del pipeline es la de la capa 3, que detecta lo mismo antes y con mejor mensaje.

# 3. RBAC acotado (página 12): la identidad de dev no tiene rol sobre el grupo de pro. No es una comprobación: es la ausencia de permiso.

# El patrón de dos PRs para un cambio destructivo legítimo (retirar el storage antiguo tras una migración):
#   PR 1: proteger = false (+ quitar prevent_destroy). Plan: "1 to destroy" del bloqueo, nada más. Se aprueba, se aplica.
#   PR 2: eliminar el recurso. Plan: "1 to destroy". Etiqueta destruccion-aprobada (15.6), se aprueba, se aplica.
# Dos aprobaciones, dos entradas en el Activity Log, ninguna sorpresa en un plan mezclado con otros cambios.
```

> **🔷 El bloqueo del estado también.** El grupo de recursos `rg-tfstate` de la página 4 merece su propio `CanNotDelete`: perder el estado es peor que perder cualquier recurso, porque se pierde la capacidad de gestionarlos todos. Se crea desde la configuración de plataforma, no desde la de Moodle, para que un `destroy` de Moodle no pueda ni intentarlo.

---

## 5. Capa 6: la puerta entre dev y pro es que dev funcione

El original propone "canary releases" y "rollback automático". Para infraestructura, la progresión gradual es otra: el cambio se aplica en dev, se **verifica** que dev funciona, y solo entonces pro queda disponible para su aprobación. La verificación es un job con dos partes: pruebas de humo (el recurso existe con la configuración esperada y responde) y plan a cero (el apply no dejó nada pendiente ni deriva).

```yaml
# En el workflow de la página 13, entre aplicar (dev) y aplicar (pro):
  verificar_dev:
    needs: aplicar                                   # el job de matriz; con max-parallel: 1 y fail-fast, aquí dev ya terminó
    if: needs.aplicar.result == 'success'
    runs-on: ubuntu-latest
    permissions: { id-token: write, contents: read }
    environment: moodle-dev
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: ${{ env.TF_VERSION }}, terraform_wrapper: false }
      - run: infra/ci/gate.sh humo dev               # el script del laboratorio (15.6); solo lectura
        env: { ARM_USE_OIDC: "true", ARM_CLIENT_ID: ${{ vars.AZURE_CLIENT_ID_dev }}, ARM_TENANT_ID: ${{ vars.AZURE_TENANT_ID }}, ARM_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }} }
  aplicar_pro:
    needs: verificar_dev                             # pro no existe como opción hasta que dev está verificado
    environment: moodle-pro
    …

# Lo que comprueba "humo" para Moodle (con lo que hay en Topaz: control plane + datos de storage/Key Vault):
#   - terraform output -json → nombres reales, no supuestos
#   - az storage account show → TLS mínimo, claves compartidas desactivadas, etiquetas presentes
#   - az keyvault secret list → los secretos que Moodle necesita existen (sin leer valores)
#   - terraform plan -detailed-exitcode → 0: el apply dejó el estado igual al código y a Azure
# En Azure real, además: curl -sf https://<fqdn>/login/index.php → 200 y az policy state trigger-scan sobre el grupo.
```

---

## 6. Laboratorio en Topaz

El laboratorio escribe `ci/gate.sh` con cuatro puertas que son scripts (destrucción con apertura por etiqueta, ventana horaria con apertura por motivo, pruebas de humo y plan a cero) y las ejecuta contra Topaz igual que las ejecutaría el runner. Además despliega con Terraform las puertas de la capa 5 (bloqueo de borrado y asignación de política) y recorre el patrón de dos PRs. Lo que evalúa ARM (que el bloqueo rechace un *delete*, que la política rechace una región) se comprueba en el bloque de Azure real.

```bash
mkdir -p ~/tf-gates/ci && cd ~/tf-gates && cp ~/tf-st/providers.tf .

# ─── 1. Código con las puertas de la capa 5 ──────────────────────────────────────
cat > main.tf <<'EOF'
variable "entorno"   { type = string, default = "dev" }
variable "location"  { type = string, default = "eastus" }
variable "proteger"  { type = bool,   default = true }     # bloqueo de borrado
variable "politicas" { type = bool,   default = false }    # asignación de Azure Policy: se activa en Azure real
locals { tags = { proyecto = "moodle", entorno = var.entorno, gestion = "terraform" } }
resource "azurerm_resource_group" "lab" { name = "rg-gates-lab-${var.entorno}", location = var.location, tags = local.tags }
resource "azurerm_storage_account" "datos" {
  name = "stgates${substr(md5(azurerm_resource_group.lab.id), 0, 8)}"
  resource_group_name = azurerm_resource_group.lab.name, location = azurerm_resource_group.lab.location
  account_tier = "Standard", account_replication_type = "LRS", min_tls_version = "TLS1_2", shared_access_key_enabled = false
  tags = local.tags
}
resource "azurerm_management_lock" "datos" {
  count      = var.proteger ? 1 : 0
  name       = "no-borrar"
  scope      = azurerm_storage_account.datos.id
  lock_level = "CanNotDelete"
  notes      = "Datos de Moodle. Quitar solo con proteger=false en un PR propio, aprobado en moodle-pro."
}
resource "azurerm_resource_group_policy_assignment" "ubicaciones" {
  count                = var.politicas ? 1 : 0
  name                 = "ubicaciones-permitidas"
  resource_group_id    = azurerm_resource_group.lab.id
  policy_definition_id = "/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c"
  parameters           = jsonencode({ listOfAllowedLocations = { value = ["eastus", "westeurope"] } })
}
output "storage" { value = azurerm_storage_account.datos.name }
output "grupo"   { value = azurerm_resource_group.lab.name }
EOF

# ─── 2. El script de puertas: lo que el runner ejecuta ───────────────────────────
cat > ci/gate.sh <<'EOF'
#!/usr/bin/env bash
# Uso: ci/gate.sh destruccion <plan.tfplan> [etiquetas.json] | horario | humo <entorno>
set -euo pipefail
cd "$(dirname "$0")/.."
protegidos='["azurerm_storage_account","azurerm_key_vault","azurerm_mysql_flexible_server","azurerm_management_lock"]'
case "$1" in
  destruccion)
    plan=$2; etiquetas=${3:-/dev/null}
    borrados=$(terraform show -json "$plan" | jq -r --argjson p "$protegidos" \
      '[.resource_changes[] | select(.change.actions | index("delete")) | select(.type | IN($p[]))] | .[].address')
    [ -z "$borrados" ] && { echo "sin destrucciones de recursos protegidos"; exit 0; }
    if jq -e 'index("destruccion-aprobada")' "$etiquetas" >/dev/null 2>&1; then
      echo "::warning::Destrucción autorizada por etiqueta destruccion-aprobada:"; echo "$borrados"; exit 0
    fi
    echo "::error::El plan destruye recursos protegidos y la PR no lleva la etiqueta destruccion-aprobada:"; echo "$borrados"; exit 1 ;;
  horario)
    export TZ=Europe/Madrid; dia=$(date +%u); hora=$(date +%H)
    if [ "${FORZAR_HORARIO:-}" = "1" ]; then echo "::warning::Ventana horaria forzada. Motivo: ${MOTIVO:?FORZAR_HORARIO exige MOTIVO}"; exit 0; fi
    if [ "$dia" -ge 6 ] || [ "$hora" -lt 9 ] || [ "$hora" -ge 17 ]; then echo "::error::Fuera de ventana L-V 09:00-17:00 $TZ: $(date)"; exit 1; fi
    echo "dentro de ventana: $(date)" ;;
  humo)
    env=$2; st=$(terraform output -raw storage); rg=$(terraform output -raw grupo)
    az storage account show -n "$st" -g "$rg" --query "{tls:minimumTlsVersion, claves:allowSharedKeyAccess, entorno:tags.entorno}" -o json | tee humo.json
    jq -e --arg e "$env" '.tls == "TLS1_2" and .claves == false and .entorno == $e' humo.json >/dev/null || { echo "::error::humo: configuración inesperada"; exit 1; }
    set +e; terraform plan -detailed-exitcode -var entorno="$env" >/dev/null; code=$?; set -e
    [ "$code" -eq 0 ] || { echo "::error::humo: el plan no está a cero (código $code)"; exit 1; }
    echo "humo OK: configuración correcta y plan a cero" ;;
esac
EOF
chmod +x ci/gate.sh
terraform init >/dev/null

# ─── 3. Plan limpio pasa la puerta de destrucción; apply; humo ───────────────────
terraform plan -out=plan.tfplan >/dev/null
ci/gate.sh destruccion plan.tfplan; echo "salida: $?"                    # 0: sin destrucciones
terraform apply plan.tfplan
az lock list -g rg-gates-lab-dev --resource-type Microsoft.Storage/storageAccounts --resource-name "$(terraform output -raw storage)" -o table   # no-borrar · CanNotDelete
ci/gate.sh humo dev; echo "salida: $?"                                   # humo OK, plan a cero

# ─── 4. La puerta de destrucción, cerrada y abierta ──────────────────────────────
terraform plan -destroy -out=borra.tfplan >/dev/null
ci/gate.sh destruccion borra.tfplan; echo "salida: $?"                   # ::error:: … azurerm_storage_account.datos, azurerm_management_lock.datos[0] → 1
echo '["revisado","destruccion-aprobada"]' > etiquetas.json              # lo que el workflow pasa con toJSON(github.event.pull_request.labels.*.name)
ci/gate.sh destruccion borra.tfplan etiquetas.json; echo "salida: $?"    # ::warning:: autorizada → 0. La etiqueta la pone un CODEOWNER, y queda en la PR.
echo '["revisado"]' > etiquetas.json && ci/gate.sh destruccion borra.tfplan etiquetas.json; echo "salida: $?"   # 1 otra vez

# ─── 5. Patrón de dos PRs: primero el bloqueo, después el recurso ────────────────
terraform plan -var proteger=false -out=pr1.tfplan                       # Plan: 0 to add, 0 to change, 1 to destroy  ← solo el bloqueo
ci/gate.sh destruccion pr1.tfplan; echo "salida: $?"                     # 1: azurerm_management_lock es protegido; también pide etiqueta
terraform apply pr1.tfplan                                               # "PR 1" aplicada
az lock list -g rg-gates-lab-dev -o table                                # vacío
terraform plan -destroy -var proteger=false -out=pr2.tfplan              # "PR 2": 2 to destroy (storage y grupo); en el caso real, solo el recurso retirado
ci/gate.sh destruccion pr2.tfplan <(echo '["destruccion-aprobada"]'); echo "salida: $?"   # 0 con etiqueta
terraform apply -var proteger=true -auto-approve                         # volvemos a proteger para los pasos siguientes

# ─── 6. Ventana horaria y su apertura auditada ───────────────────────────────────
ci/gate.sh horario; echo "salida: $?"                                    # 0 o 1 según la hora en que leas esto
FORZAR_HORARIO=1 ci/gate.sh horario; echo "salida: $?"                   # error: FORZAR_HORARIO exige MOTIVO → 1
FORZAR_HORARIO=1 MOTIVO="INC-4821: certificado caducado" ci/gate.sh horario; echo "salida: $?"   # ::warning:: con el motivo en el log → 0
#   En el workflow: FORZAR_HORARIO y MOTIVO vienen de inputs de workflow_dispatch (motivo required: true); en un push no existen.

# ─── 7. Humo que falla: deriva tras el apply ─────────────────────────────────────
az storage account update -n "$(terraform output -raw storage)" -g rg-gates-lab-dev --min-tls-version TLS1_0 -o none
ci/gate.sh humo dev; echo "salida: $?"                                   # ::error:: configuración inesperada → 1: pro no se abre
terraform apply -auto-approve >/dev/null && ci/gate.sh humo dev          # el apply corrige; humo OK

# ─── 8. Limpiar (en el orden que el bloqueo obliga) ──────────────────────────────
terraform apply -var proteger=false -auto-approve                        # quitar el bloqueo es un paso propio, también aquí
terraform destroy -var proteger=false -auto-approve
rm -f *.tfplan etiquetas.json humo.json
```

```bash
# ─── Solo Azure real ────────────────────────────────────────────────────────────
# A. El bloqueo detiene a cualquiera: a az, al portal y a Terraform
terraform apply -auto-approve                                            # con proteger=true
az storage account delete -n "$(terraform output -raw storage)" -g rg-gates-lab-dev --yes
#   (ScopeLocked) The scope '/subscriptions/…/storageAccounts/stgates…' cannot perform delete operation because following scope(s) are locked: … Please remove the lock and try again.
terraform destroy -auto-approve
#   Error: deleting Storage Account … StatusCode=409 … ScopeLocked   ← el destroy desde el portátil muere aquí, sin pipeline
az monitor activity-log list -g rg-gates-lab-dev --offset 10m --query "[?contains(operationName.value,'delete')].{quien:caller, que:operationName.localizedValue, estado:status.value}" -o table
#   los intentos fallidos también quedan registrados: la puerta de la capa 5 deja rastro de quién la empujó

# B. La política la evalúa ARM en la petición, con el mensaje que el pipeline no tendría que dar
terraform apply -var politicas=true -auto-approve
az storage account create -n stfuera$RANDOM -g rg-gates-lab-dev -l northeurope --sku Standard_LRS
#   (RequestDisallowedByPolicy) Resource 'stfuera…' was disallowed by policy. Policy identifiers: … "ubicaciones-permitidas" …
az policy state trigger-scan -g rg-gates-lab-dev && az policy state summarize -g rg-gates-lab-dev --query "results.nonCompliantResources"   # la evaluación de lo existente, para la capa 6

# C. Las puertas del pipeline (GitHub): ruleset, environment, etiquetas y auditoría
gh api -X POST repos/{owner}/{repo}/rulesets --input ruleset-main.json      # 15.2
gh api -X PUT repos/{owner}/{repo}/environments/moodle-pro --input env-pro.json   # 15.3: wait_timer, prevent_self_review, equipo revisor
gh label create destruccion-aprobada --color B60205 --description "Un CODEOWNER autoriza las destrucciones de este plan"
#   En el job de plan: - run: ci/gate.sh destruccion plan.tfplan <(echo '${{ toJSON(github.event.pull_request.labels.*.name) }}')
#   Solo un equipo debería poder etiquetar: en Settings → Moderation, o comprobando en el script quién puso la etiqueta con gh api …/issues/N/events
gh api repos/{owner}/{repo}/actions/runs/<run_id>/approvals --jq '.[] | {quien: .user.login, estado: .state, comentario: .comment}'
gh api repos/{owner}/{repo}/rulesets/<id> --jq '.rules[].type'                # qué exige main hoy
gh api "repos/{owner}/{repo}/rules/branches/main" --jq '.[].type'            # lo mismo, visto desde la rama (incluye rulesets de la organización)

# D. Azure DevOps: checks del environment y auditoría
az pipelines environment list --org … -p … -o table
az devops invoke --area pipelines --resource approvals --route-parameters project=<proyecto> --api-version 7.1-preview --org … \
  --query "value[].{quien:steps[0].actualApprover.displayName, estado:status, cuando:steps[0].lastModifiedOn}" -o table
az devops security permission list … | grep -i "bypass"                      # quién puede saltarse las políticas de rama: esa lista debería ser muy corta
```

---

## 7. Errores comunes

> ⚠️ **Solución de problemas**
>
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | `grep -q "destroy" tfplan` nunca bloquea nada (el original) | El fichero de plan es un ZIP binario. La destrucción se detecta en el JSON de `terraform show -json`, en `resource_changes[].change.actions` (página 14); el script `destruccion` del laboratorio |
> | El job de aprobación tiene el *environment* y el de apply no (el original) | La aprobación protege un `echo`; el apply corre libre. El *environment* va en el job que ejecuta `terraform apply` |
> | `if [ $? -ne 0 ]` en un paso nuevo tras CodeQL o las pruebas (el original) | Cada paso empieza con `$?` a 0: la condición nunca se cumple. Un paso que falla ya detiene el job; no hace falta comprobarlo después. Y CodeQL no analiza HCL: la puerta de código es tflint/trivy/gitleaks |
> | `trstringer/manual-approval` con `APPROVAL_SECRET` e `issue-number` vacío | Acción de terceros que abre un issue y espera comentarios; en un evento `push` no hay número de PR. La aprobación nativa son los *environments* con revisores, *wait timer* y *prevent self-review* |
> | `az policy state list` como puerta previa al apply (el original) | Mide el cumplimiento de lo que ya existe, con horas de retraso; no evalúa el cambio. La política con *deny* la aplica ARM en el propio apply; lo que quieres saber antes lo dice la capa 3 sobre el plan |
> | *RequestDisallowedByPolicy* en el apply, con el plan aprobado | Una política de Azure que la capa 3 no replica. Añade la regla equivalente a conftest para que el mensaje llegue en la PR, no en el apply; y comprueba con `az policy assignment list --disable-scope-strict-match` qué políticas heredan del grupo o la suscripción |
> | *ScopeLocked* (409) en un destroy que sí querías hacer | La puerta funciona. Patrón de dos PRs: primero `proteger = false`, aprobado y aplicado; después el recurso. Nunca `az lock delete` a mano antes de un apply: es exactamente lo que el Activity Log mostraría como sospechoso |
> | El bloqueo `CanNotDelete` no aparece en el plan de destroy como error | Terraform no sabe de bloqueos hasta que Azure rechaza la petición: el plan de destroy siempre parece viable. La capa que avisa antes es `prevent_destroy` (página 14); las dos juntas cubren plan y apply |
> | Un plan de destroy sobre el bloqueo y el recurso a la vez | Terraform borra primero el bloqueo (depende del recurso) y después el recurso: el bloqueo no protege de un destroy que también lo elimina a él. Por eso `azurerm_management_lock` está en la lista de protegidos del script, y por eso el bloqueo del estado se crea desde otra configuración |
> | "El job de pro no se dispara nunca" con *required reviewers* | Está esperando aprobación en la pestaña del run, sin avisar a nadie si no hay notificaciones configuradas. Revisores como equipo (no persona), notificaciones del equipo activas, y el *summary* del job de plan con el enlace |
> | El autor del cambio aprueba su propio despliegue | `prevent_self_review: true` en el environment; en la rama, `require_last_push_approval` para que quien empujó el último commit no cuente como aprobador. En DevOps, "el solicitante no puede aprobar" en el check |
> | La regla de rama exige un check que ya no existe (*Expected — Waiting for status to be reported*) | Renombraste el job o cambió el nombre de la matriz. Los `context` del ruleset son nombres exactos; actualízalos en el mismo PR que cambia el workflow |
> | Un *Owner* del repositorio fusiona sin cumplir la regla | Tiene *bypass*. Revisa `bypass_actors` del ruleset: debería estar vacío o limitarse a una app de emergencia. El que puede saltarse la puerta es parte del modelo de amenaza |
> | `wait_timer` usado como ventana horaria | Es una espera relativa (minutos desde que el job queda listo), no un horario. La ventana es el paso `horario` con apertura por `MOTIVO`, o el check *Business hours* en DevOps |
> | La etiqueta `destruccion-aprobada` la puede poner cualquiera | Poner etiquetas requiere permiso *triage*; si el equipo es amplio, el script debe comprobar quién la puso (`gh api …/issues/N/events`, evento `labeled`) contra la lista de CODEOWNERS |
> | "Rollback automático" y "canary" para infraestructura (el original) | Un recurso no se despliega al 10 %. La progresión es dev → verificación (humo, plan a cero) → pro; el retroceso es `git revert` por el mismo flujo (página 14) |
> | Demasiadas puertas: el equipo aplica desde el portátil para "ir rápido" | Señal de que una puerta no tiene apertura razonable. Cada puerta debe abrirse con un acto auditado y proporcionado; y la capa 5 (RBAC: nadie tiene rol de escritura en pro salvo la identidad del pipeline) hace que el portátil no sea una opción |
> | En Topaz: el bloqueo se crea pero un `az storage account delete` lo ignora; la asignación de política no se puede crear o no rechaza nada | Esperado: el emulador acepta los tipos `Microsoft.Authorization/*` en distinto grado según la versión, y no evalúa políticas ni bloqueos en las peticiones. Por eso el laboratorio no intenta borrar con el bloqueo puesto, y `politicas` va a `false`. Ambas cosas se ven en el bloque de Azure real |

---

## 8. Autoevaluación

1. **¿Cuáles son las seis capas y qué distingue a las dos últimas?**
   Rama, código, plan, humano, Azure, verificación. Las cuatro primeras detienen al pipeline; las de Azure detienen a cualquiera, y la de verificación mira hacia atrás.
2. **¿Por qué `grep "destroy" tfplan` no bloquea nada?**
   El fichero de plan es un ZIP binario. La destrucción se detecta en el JSON de `terraform show -json`, en `resource_changes[].change.actions`.
3. **¿En qué job va el *environment* con revisores y por qué?**
   En el que ejecuta `terraform apply`. Si va en otro, la aprobación protege ese otro job y el apply corre sin ella.
4. **¿Qué garantiza `strict_required_status_checks_policy`?**
   Que la rama esté al día con `main` antes de fusionar: el plan que se revisó se hizo sobre el código que realmente se va a fusionar.
5. **¿Qué hace `wait_timer` y qué no hace?**
   Espera un número de minutos desde que el job queda listo, aunque ya esté aprobado; da margen para cancelar una aprobación reflejo. No es una ventana horaria.
6. **¿Por qué `az policy state list` no sirve como puerta previa?**
   Evalúa lo que ya existe, con retraso de horas, no el cambio propuesto. La política con *deny* la aplica ARM en la petición; lo que se quiere saber antes lo da la capa 3 sobre el plan.
7. **¿Qué diferencia hay entre `prevent_destroy` y un bloqueo `CanNotDelete`?**
   `prevent_destroy` lo evalúa Terraform al planificar, solo para quien use ese código. El bloqueo lo evalúa Azure al recibir la petición, para cualquiera. Son capas distintas y se complementan.
8. **¿Por qué el bloqueo no protege de un destroy que también lo elimina a él?**
   Terraform borra primero el bloqueo (depende del recurso) y luego el recurso. Por eso el script trata `azurerm_management_lock` como protegido y el bloqueo del estado se crea desde otra configuración.
9. **Describe el patrón de dos PRs.**
   PR 1 quita la protección (bloqueo, `prevent_destroy`): su plan solo destruye el bloqueo. PR 2 elimina el recurso, con etiqueta de autorización. Dos aprobaciones, dos rastros, sin destrucciones mezcladas con otros cambios.
10. **¿Cómo se abre cada puerta de forma auditada?**
    Destrucción: etiqueta puesta por un CODEOWNER. Horario: `workflow_dispatch` con `motivo` obligatorio. Bloqueo: commit propio que cambia `proteger`. Lo prohibido no es pasar, es pasar sin rastro.
11. **¿Qué comprueba la puerta de verificación entre dev y pro?**
    Que los recursos existen con la configuración esperada (humo, solo lectura) y que `plan -detailed-exitcode` devuelve 0: el apply no dejó nada pendiente ni deriva.
12. **¿Dónde queda registrado quién aprobó un despliegue?**
    GitHub: `/actions/runs/{id}/approvals` y los *deployments* del environment. DevOps: la API de *approvals*. Y en Azure, el Activity Log muestra qué identidad ejecutó cada operación, incluidos los intentos rechazados.

---

## 9. Referencias

- [Reglas disponibles en *rulesets*](https://docs.github.com/es/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets) y [CODEOWNERS](https://docs.github.com/es/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners)
- [Environments](https://docs.github.com/es/actions/managing-workflow-runs-and-deployments/managing-deployments/managing-environments-for-deployment) (*required reviewers*, *wait timer*, *prevent self-review*, *deployment branches*) y [historial de aprobaciones (REST)](https://docs.github.com/es/rest/actions/workflow-runs#get-the-review-history-for-a-workflow-run)
- [Approvals and checks en Azure DevOps](https://learn.microsoft.com/es-es/azure/devops/pipelines/process/approvals) (Approvals, Branch control, Business hours, Exclusive lock, Required template, Invoke REST API) y [directivas de rama](https://learn.microsoft.com/es-es/azure/devops/repos/git/branch-policies)
- [Bloqueos de recursos](https://learn.microsoft.com/es-es/azure/azure-resource-manager/management/lock-resources) (`CanNotDelete`, `ReadOnly`) y [`azurerm_management_lock`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/management_lock)
- [Azure Policy: efecto *deny*](https://learn.microsoft.com/es-es/azure/governance/policy/concepts/effect-deny), [definiciones integradas](https://learn.microsoft.com/es-es/azure/governance/policy/samples/built-in-policies) y [`azurerm_resource_group_policy_assignment`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group_policy_assignment)
- [`workflow_dispatch` con inputs](https://docs.github.com/es/actions/writing-workflows/choosing-when-your-workflow-runs/events-that-trigger-workflows#workflow_dispatch) y [resumen del job (`GITHUB_STEP_SUMMARY`)](https://docs.github.com/es/actions/writing-workflows/choosing-what-your-workflow-does/workflow-commands-for-github-actions#adding-a-job-summary)
- [Activity Log de Azure](https://learn.microsoft.com/es-es/azure/azure-monitor/essentials/activity-log) (quién intentó qué, incluidos los rechazos)
- [Azure Local Emulator (Topaz)](https://github.com/Azure/azure-local-emulator)