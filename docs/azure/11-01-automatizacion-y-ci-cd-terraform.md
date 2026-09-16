# 🤖 CI/CD para Terraform: planificar en la PR, aplicar con aprobación

## 1. El flujo: cuatro momentos, tres disparadores

El pipeline del original tiene un disparador (`push` a `main`) y un resultado (`apply -auto-approve`). Eso significa que el primer momento en que alguien ve qué va a cambiar es cuando ya ha cambiado. El flujo correcto separa la revisión de la ejecución y añade una vigilancia que el original no contempla.

| **Momento** | **Disparador** | **Qué ejecuta** | **Permisos en Azure** |
|---|---|---|---|
| **Comprobar** | Cada commit de la PR | `fmt -check`, `validate`, `tflint`, `trivy config`, `gitleaks` | Ninguno: no toca Azure (`init -backend=false`) |
| **Planificar** | PR hacia `main` | `plan -detailed-exitcode` por entorno; resumen como comentario en la PR | Lectura del estado y de los recursos (la identidad de dev) |
| **Aprobar y aplicar** | Merge en `main` (dev automático; pro tras aprobación) | `plan -out` + `apply` del mismo fichero, en el mismo job | Los roles de `id-moodle-tf-<entorno>` ([página 12](index.md#pagina-12)) |
| **Vigilar** | `schedule` diario | `plan -detailed-exitcode`; código 2 = deriva → issue o alerta | Lectura |

> **🔷 Por qué plan y apply van en el mismo job.** El fichero de plan contiene todas las variables no efímeras y todos los atributos conocidos ([página 10](index.md#pagina-10)): es un secreto. Subirlo como artefacto para que otro job lo aplique lo deja descargable por cualquiera con acceso de lectura al repositorio. Y con variables `ephemeral` el artefacto ni siquiera es aplicable sin volver a pasarlas. Por eso el job de apply replanifica y aplica el fichero que acaba de generar; la puerta de aprobación está delante del job, y el revisor decide con el plan de la PR y la rama protegida como garantía de que el código no cambió entre medias.

---

## 2. Sin secretos: lo que el pipeline necesita saber

El runner necesita cuatro datos para hablar con Azure, y ninguno es secreto: el `client_id` de `id-moodle-tf`, el `tenant_id`, el `subscription_id` y la orden de usar OIDC. El token lo emite la plataforma de CI en cada job y el provider lo intercambia por uno de Azure gracias a la credencial federada de la [página 12](index.md#pagina-12). Los secretos de Moodle (la clave del proveedor de SMS, por ejemplo) tampoco viven en el CI: el job los lee de Key Vault con la identidad ya autenticada y los pasa como variables efímeras.

```hcl
# Variables del provider y del backend: ninguna secreta. En GitHub van en "vars", en Azure DevOps en un variable group sin candado.
ARM_USE_OIDC=true                 # GitHub: el provider lee ACTIONS_ID_TOKEN_REQUEST_URL/TOKEN por sí mismo
ARM_CLIENT_ID=<client_id de id-moodle-tf-dev>
ARM_TENANT_ID=<tenant>
ARM_SUBSCRIPTION_ID=<suscripción>
ARM_USE_AZUREAD=true              # el backend azurerm autentica por Entra ID; sin access_key ([página 10](index.md#pagina-10))
TF_IN_AUTOMATION=true             # Terraform omite las sugerencias interactivas de los mensajes
TF_INPUT=0                        # nunca esperar a stdin: si falta una variable, falla

# Secretos de Moodle, dentro del job, sin pasar por la plataforma de CI:
TF_VAR_api_key_sms="$(az keyvault secret show --vault-name kv-ops-moodle -n sms-api-key --query value -o tsv)" terraform apply plan.tfplan
#   var.api_key_sms es ephemeral = true (página 10): no queda en el plan ni en el estado; el log de CI nunca lo imprime porque nadie lo imprime.

# Lo que el original hace y por qué no:
#   echo "ARM_CLIENT_ID=…" > terraform.tfvars      → ARM_* no son variables de Terraform; Terraform avisará de "value for undeclared variable"
#   secrets.ARM_CLIENT_SECRET                       → un secreto de larga duración en la plataforma de CI, justo lo que la federación elimina
#   secrets.AZURE_CLIENT_ID                         → no es secreto; enmascararlo oculta en el log lo que necesitas para depurar (página 12)
```

---

## 3. GitHub Actions: el workflow completo

Un solo fichero cubre los cuatro momentos. Fíjate en los detalles que el original omite: `permissions` mínimos en la raíz y ampliados solo donde hacen falta, `concurrency` para que dos ejecuciones no compitan por el estado, la versión de Terraform fijada, y `environment` como puerta de aprobación para producción.

```yaml
# .github/workflows/terraform.yml
name: terraform-moodle
on:
  pull_request: { branches: [main], paths: ["infra/**"] }
  push:         { branches: [main], paths: ["infra/**"] }
  schedule:     [{ cron: "0 6 * * 1-5" }]          # deriva, cada mañana laborable
  workflow_dispatch:

permissions: { contents: read }                     # mínimo en la raíz; cada job amplía lo justo
concurrency: { group: tf-moodle-${{ github.ref }}, cancel-in-progress: false }   # nunca cancelar un apply a medias

env:
  TF_VERSION: "1.11.4"                              # fijada: plan y apply con el mismo binario. El original: "latest"
  TF_IN_AUTOMATION: "true"
  TF_INPUT: "0"
  ARM_USE_OIDC: "true"
  ARM_USE_AZUREAD: "true"
  ARM_TENANT_ID: ${{ vars.AZURE_TENANT_ID }}        # vars, no secrets: no son secretos ([página 12](index.md#pagina-12))
  ARM_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}

defaults: { run: { working-directory: infra } }

jobs:
  comprobar:                                        # no toca Azure: sin id-token, sin backend
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }                    # gitleaks necesita el historial
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: "${{ env.TF_VERSION }}" }
      - run: terraform fmt -check -recursive -diff
      - run: terraform init -backend=false && terraform validate
      - uses: terraform-linters/setup-tflint@v4
      - run: tflint --init && tflint --recursive --format compact
      - uses: aquasecurity/trivy-action@0.29.0
        with: { scan-type: config, scan-ref: infra, severity: "HIGH,CRITICAL", exit-code: "1" }
      - uses: gitleaks/gitleaks-action@v2

  plan:                                             # en la PR: un plan por entorno, comentado
    if: github.event_name == 'pull_request'
    needs: comprobar
    runs-on: ubuntu-24.04
    permissions: { contents: read, id-token: write, pull-requests: write }
    strategy: { matrix: { entorno: [dev, pro] } }
    env:
      ARM_CLIENT_ID: ${{ vars[format('AZURE_CLIENT_ID_{0}', matrix.entorno)] }}   # una identidad por entorno
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: "${{ env.TF_VERSION }}", terraform_wrapper: false }   # el wrapper rompe -detailed-exitcode y los pipes
      - run: terraform init -backend-config=backends/${{ matrix.entorno }}.tfbackend
      - id: plan
        run: |
          set +e
          terraform plan -var-file=envs/${{ matrix.entorno }}.tfvars -out=plan.tfplan -detailed-exitcode -no-color 2>&1 | tee plan.txt
          code=${PIPESTATUS[0]}; echo "code=$code" >> "$GITHUB_OUTPUT"
          [ "$code" -eq 1 ] && exit 1                # 0 sin cambios, 2 con cambios, 1 error
          terraform show -json plan.tfplan | jq -r '
            [.resource_changes[] | select(.change.actions != ["no-op"])] as $c
            | "**\(env.ENTORNO)** — \($c | length) cambios: " +
              ([("create","update","delete","replace") as $a
                | ($c | map(select(($a == "replace" and (.change.actions | length) == 2) or (.change.actions == [$a]))) | length) as $n
                | select($n > 0) | "\($n) \($a)"] | join(", "))' > resumen.md
          echo; echo '<details><summary>Plan completo</summary>'; echo; echo '```'; tail -c 60000 plan.txt; echo '```'; echo '</details>'
          { echo; echo '<details><summary>Plan completo</summary>'; echo; echo '```'; tail -c 60000 plan.txt; echo '```'; echo '</details>'; } >> resumen.md
        env: { ENTORNO: "${{ matrix.entorno }}" }
      - uses: actions/github-script@v7               # un comentario por entorno, actualizado en cada push a la PR
        with:
          script: |
            const fs = require('fs'); const body = fs.readFileSync('infra/resumen.md', 'utf8');
            const marca = `<!-- tf-plan-${{ matrix.entorno }} -->`;
            const { data: comentarios } = await github.rest.issues.listComments({ ...context.repo, issue_number: context.issue.number });
            const previo = comentarios.find(c => c.body.startsWith(marca));
            const args = { ...context.repo, body: `${marca}\n${body}` };
            previo ? await github.rest.issues.updateComment({ ...args, comment_id: previo.id })
                   : await github.rest.issues.createComment({ ...args, issue_number: context.issue.number });
      # El plan.tfplan NO se sube como artefacto: contiene los valores de todas las variables no efímeras (página 10)

  aplicar:                                          # en main: dev sin puerta, pro con revisores
    if: github.event_name == 'push' || github.event_name == 'workflow_dispatch'
    needs: comprobar
    runs-on: ubuntu-24.04
    permissions: { contents: read, id-token: write }
    strategy: { matrix: { entorno: [dev, pro] }, max-parallel: 1, fail-fast: true }   # dev primero; si falla, pro no se ejecuta
    environment: moodle-${{ matrix.entorno }}       # "moodle-pro" tiene required reviewers y solo admite la rama main
    env:
      ARM_CLIENT_ID: ${{ vars[format('AZURE_CLIENT_ID_{0}', matrix.entorno)] }}
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: "${{ env.TF_VERSION }}", terraform_wrapper: false }
      - uses: azure/login@v2                        # solo para leer Key Vault con az; Terraform no lo necesita
        with: { client-id: "${{ env.ARM_CLIENT_ID }}", tenant-id: "${{ env.ARM_TENANT_ID }}", subscription-id: "${{ env.ARM_SUBSCRIPTION_ID }}" }
      - run: terraform init -backend-config=backends/${{ matrix.entorno }}.tfbackend
      - run: |                                      # plan y apply en el mismo job, con las efímeras leídas del vault en la misma línea
          export TF_VAR_api_key_sms="$(az keyvault secret show --vault-name kv-ops-moodle-${{ matrix.entorno }} -n sms-api-key --query value -o tsv)"
          terraform plan -var-file=envs/${{ matrix.entorno }}.tfvars -out=plan.tfplan -detailed-exitcode -no-color; code=$?
          [ "$code" -eq 0 ] && { echo "Sin cambios"; exit 0; }
          [ "$code" -eq 1 ] && exit 1
          terraform apply -no-color plan.tfplan

  deriva:                                           # cada mañana: ¿coincide Azure con main?
    if: github.event_name == 'schedule'
    runs-on: ubuntu-24.04
    permissions: { contents: read, id-token: write, issues: write }
    strategy: { matrix: { entorno: [dev, pro] } }
    env:
      ARM_CLIENT_ID: ${{ vars[format('AZURE_CLIENT_ID_{0}', matrix.entorno)] }}
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: "${{ env.TF_VERSION }}", terraform_wrapper: false }
      - run: terraform init -backend-config=backends/${{ matrix.entorno }}.tfbackend
      - id: plan
        run: terraform plan -var-file=envs/${{ matrix.entorno }}.tfvars -refresh-only -detailed-exitcode -no-color 2>&1 | tee deriva.txt; echo "code=${PIPESTATUS[0]}" >> "$GITHUB_OUTPUT"
      - if: steps.plan.outputs.code == '2'
        uses: actions/github-script@v7
        with:
          script: |
            const body = require('fs').readFileSync('infra/deriva.txt', 'utf8').slice(-60000);
            await github.rest.issues.create({ ...context.repo, title: `Deriva en ${{ matrix.entorno }} (${new Date().toISOString().slice(0,10)})`, labels: ['deriva'], body: '```\n' + body + '\n```' });
```

> **⚠️ El *environment* es la puerta, no `workflow_run`.** El original propone `workflow_run` para "approvals": ese disparador encadena workflows, no pide aprobación a nadie. Las aprobaciones son un *environment* con *required reviewers* y *deployment branches* limitado a `main`; el job se detiene antes de empezar hasta que alguien aprueba, y la credencial federada de pro tiene como sujeto `environment:moodle-pro` ([página 12](index.md#pagina-12)), así que ni un workflow de otra rama puede obtener un token de producción.

---

## 4. Azure DevOps: el mismo flujo con etapas

En Azure DevOps la autenticación la resuelve la **conexión de servicio** con *workload identity federation*: al crearla, DevOps genera el emisor y el sujeto que tú registras en `azurerm_federated_identity_credential` ([página 12](index.md#pagina-12), bloque B), y la tarea `AzureCLI@2` con `addSpnToEnvironment` deja en el entorno un token OIDC que el provider acepta con `ARM_OIDC_TOKEN`. Las tareas `TerraformTaskV4` del original son una extensión de terceros (Microsoft DevLabs): funcionan, pero esconden justo lo que esta página quiere que veas, así que el ejemplo usa la CLI directamente. Las aprobaciones son *Environments* con *Approvals and checks*.

```yaml
# azure-pipelines.yml
trigger: { branches: { include: [main] }, paths: { include: [infra/*] } }
pr:      { branches: { include: [main] }, paths: { include: [infra/*] } }
schedules:
  - cron: "0 6 * * 1-5"
    displayName: deriva
    branches: { include: [main] }
    always: true

pool: { vmImage: ubuntu-24.04 }
variables:
  - name: TF_VERSION
    value: "1.11.4"
  - name: TF_IN_AUTOMATION
    value: "true"
  - name: TF_INPUT
    value: "0"

# Plantilla reutilizada por todas las etapas: autenticación federada + Terraform con la CLI
# templates/tf.yml
#   parameters: { entorno: "", conexion: "", comando: "" }
#   steps:
#     - task: TerraformInstaller@1               # de la extensión oficial de Microsoft DevLabs; o: curl del zip de releases.hashicorp.com
#       inputs: { terraformVersion: $(TF_VERSION) }
#     - task: AzureCLI@2
#       inputs:
#         azureSubscription: ${{ parameters.conexion }}     # conexión con Workload identity federation → id-moodle-tf-<entorno>
#         scriptType: bash                                  # el original: 'ps' en Ubuntu
#         addSpnToEnvironment: true                         # expone servicePrincipalId, tenantId e idToken
#         workingDirectory: infra
#         inlineScript: |
#           set -euo pipefail
#           export ARM_USE_OIDC=true ARM_OIDC_TOKEN="$idToken" ARM_CLIENT_ID="$servicePrincipalId" ARM_TENANT_ID="$tenantId"
#           export ARM_SUBSCRIPTION_ID="$(az account show --query id -o tsv)" ARM_USE_AZUREAD=true
#           terraform init -backend-config=backends/${{ parameters.entorno }}.tfbackend
#           case "${{ parameters.comando }}" in
#             plan)
#               set +e; terraform plan -var-file=envs/${{ parameters.entorno }}.tfvars -detailed-exitcode -no-color | tee plan.txt; code=${PIPESTATUS[0]}; set -e
#               [ $code -eq 1 ] && exit 1
#               echo "##vso[task.setvariable variable=planCode;isOutput=true]$code"
#               echo "##vso[task.uploadsummary]$(pwd)/plan.txt" ;;               # el plan aparece en la pestaña de resumen de la ejecución
#             apply)
#               export TF_VAR_api_key_sms="$(az keyvault secret show --vault-name kv-ops-moodle-${{ parameters.entorno }} -n sms-api-key --query value -o tsv)"
#               terraform plan -var-file=envs/${{ parameters.entorno }}.tfvars -out=plan.tfplan -detailed-exitcode -no-color; code=$?
#               [ $code -eq 0 ] && exit 0; [ $code -eq 1 ] && exit 1
#               terraform apply -no-color plan.tfplan ;;
#           esac

stages:
  - stage: comprobar
    jobs:
      - job: calidad
        steps:
          - checkout: self
            fetchDepth: 0
          - script: |
              curl -sLo tf.zip https://releases.hashicorp.com/terraform/$(TF_VERSION)/terraform_$(TF_VERSION)_linux_amd64.zip && unzip -oq tf.zip -d /usr/local/bin
              cd infra && terraform fmt -check -recursive -diff && terraform init -backend=false && terraform validate
            displayName: fmt + validate
          - script: cd infra && docker run --rm -v "$PWD:/w" -w /w ghcr.io/terraform-linters/tflint --recursive && docker run --rm -v "$PWD:/w" aquasec/trivy config --severity HIGH,CRITICAL --exit-code 1 /w
            displayName: tflint + trivy
          - script: docker run --rm -v "$PWD:/repo" ghcr.io/gitleaks/gitleaks:latest git /repo
            displayName: gitleaks

  - stage: plan
    condition: eq(variables['Build.Reason'], 'PullRequest')
    dependsOn: comprobar
    jobs:
      - job: plan_dev
        steps: [{ template: templates/tf.yml, parameters: { entorno: dev, conexion: sc-moodle-dev, comando: plan } }]
      - job: plan_pro
        steps: [{ template: templates/tf.yml, parameters: { entorno: pro, conexion: sc-moodle-pro, comando: plan } }]

  - stage: aplicar_dev
    condition: and(succeeded(), ne(variables['Build.Reason'], 'PullRequest'), ne(variables['Build.Reason'], 'Schedule'))
    dependsOn: comprobar
    jobs:
      - deployment: dev
        environment: moodle-dev                     # sin checks: aplica solo
        strategy: { runOnce: { deploy: { steps: [{ checkout: self }, { template: templates/tf.yml, parameters: { entorno: dev, conexion: sc-moodle-dev, comando: apply } }] } } }
  - stage: aplicar_pro
    condition: and(succeeded(), ne(variables['Build.Reason'], 'PullRequest'), ne(variables['Build.Reason'], 'Schedule'))
    dependsOn: aplicar_dev                          # pro nunca antes que dev, ni si dev falló
    jobs:
      - deployment: pro
        environment: moodle-pro                     # Approvals and checks: aprobadores + Branch control (solo main) + Exclusive lock
        strategy: { runOnce: { deploy: { steps: [{ checkout: self }, { template: templates/tf.yml, parameters: { entorno: pro, conexion: sc-moodle-pro, comando: apply } }] } } }

  - stage: deriva
    condition: eq(variables['Build.Reason'], 'Schedule')
    dependsOn: []
    jobs:
      - job: deriva_dev
        steps:
          - template: templates/tf.yml              # la tarea AzureCLI@2 de la plantilla lleva name: tf para exponer planCode
            parameters: { entorno: dev, conexion: sc-moodle-dev, comando: plan }
          - script: az boards work-item create --type Bug --title "Deriva en dev $(date +%F)" --description "$(cat infra/plan.txt | head -c 30000)" --org $(System.CollectionUri) -p $(System.TeamProject)
            condition: eq(variables['tf.planCode'], '2')
            env: { AZURE_DEVOPS_EXT_PAT: $(System.AccessToken) }
      - job: deriva_pro
        steps:
          - template: templates/tf.yml
            parameters: { entorno: pro, conexion: sc-moodle-pro, comando: plan }
          - script: az boards work-item create --type Bug --title "Deriva en pro $(date +%F)" --description "$(cat infra/plan.txt | head -c 30000)" --org $(System.CollectionUri) -p $(System.TeamProject)
            condition: eq(variables['tf.planCode'], '2')
            env: { AZURE_DEVOPS_EXT_PAT: $(System.AccessToken) }
```

| **Necesidad** | **GitHub Actions** | **Azure DevOps** |
|---|---|---|
| Token sin secreto | `permissions: id-token: write` + `ARM_USE_OIDC`; el provider lo pide solo | Conexión de servicio con *workload identity federation*; `AzureCLI@2` con `addSpnToEnvironment` → `ARM_OIDC_TOKEN` |
| Sujeto de la credencial federada | `repo:org/repo:environment:moodle-pro` | `sc://org/proyecto/sc-moodle-pro` |
| Aprobación de producción | *Environment* con *required reviewers* y *deployment branches* = `main` | *Environment* con *Approvals* y *Branch control* |
| Una ejecución a la vez | `concurrency` por rama, `cancel-in-progress: false` | Check *Exclusive lock* en el environment |
| Plan visible para el revisor | Comentario en la PR (`github-script`), actualizado en cada push | `##vso[task.uploadsummary]` en la pestaña de resumen; o comentario en la PR con la API de Repos |
| Variables no secretas | `vars.*` por repositorio o environment | Variable group sin candado; las de conexión las inyecta la tarea |
| Deriva → aviso | Issue con etiqueta `deriva` | Work item con `az boards` |

---

## 5. El estado desde el pipeline: bloqueo, caducidad, deriva

El original recomienda "locks en Terraform Cloud" y sincronizar conflictos con `state pull`/`state push`. Lo primero es innecesario: el backend `azurerm` ya bloquea con un *lease* sobre el blob del estado. Lo segundo es peligroso: `state push` sobrescribe el estado remoto con una copia local, y "resolver un conflicto" así suele significar perder los recursos que otra ejecución acababa de crear. Tres situaciones cubren casi todo lo que le pasa al estado en CI.

```bash
# 1. Bloqueado: otra ejecución (o una cancelada a medias) tiene el lease
terraform plan
#   Error: Error acquiring the state lock
#   Lock Info:  ID: 7a3e91c2-…  Path: tfstate/moodle/dev.tfstate  Operation: OperationTypeApply
#               Who: runner@fv-az123  Created: 2026-09-10 06:02:11 UTC
#   Primero, quién: ¿sigue corriendo ese job? Si sí, espera; el bloqueo está haciendo su trabajo.
az storage blob show --account-name sttfstate… -c tfstate -n moodle/dev.tfstate --auth-mode login \
  --query "{lease:properties.lease.status, lockid:metadata.terraformlockid}" -o json
#   Solo si el job dueño está muerto (cancelado, runner perdido):
terraform force-unlock 7a3e91c2-…          # con el ID exacto del mensaje; el estado no se toca, solo el lease
#   La prevención es del pipeline: concurrency / Exclusive lock, y nunca cancel-in-progress sobre un apply.

# 2. Caduco: el plan se hizo contra un estado que ya no es el actual
terraform apply plan.tfplan
#   Error: Saved plan is stale — The given plan file can no longer be applied because the state was changed…
#   Es lo que pasa con un artefacto de plan aplicado horas después por otro job. Plan y apply en el mismo job (13.1).

# 3. Deriva: Azure difiere de main sin que nadie haya tocado el código
terraform plan -detailed-exitcode                  # 0 sin cambios · 1 error · 2 cambios (de código O de deriva)
terraform plan -refresh-only -detailed-exitcode    # 2 = solo deriva: qué cambió en Azure respecto al estado
#   Si la deriva es legítima (alguien amplió un disco en una urgencia): llévala al código y abre PR.
#   Si no lo es: el siguiente apply la revierte. En ambos casos, el issue de las 6:00 es quien lo cuenta.
```

> **🔷 `terraform_wrapper: false`.** `setup-terraform` instala por defecto un envoltorio que captura stdout, stderr y el código de salida en outputs del paso. Es cómodo para pasar el plan a otro paso, pero devuelve siempre 0 (rompe `-detailed-exitcode`), corta los pipes a `tee` y `jq`, y los outputs tienen un límite de tamaño. Con el wrapper desactivado, el script hace lo mismo que haría en tu terminal, y el laboratorio de 13.6 puede ejecutar exactamente el mismo fichero.

---

## 6. Laboratorio en Topaz

El laboratorio pone los pasos del pipeline en un script, `ci/tf.sh`, y lo ejecuta contra el emulador con el backend de la [página 4](index.md#pagina-4). Así se comprueban en local las tres cosas que el runner hace sin que las veas: los códigos de salida del plan, el bloqueo del estado y la detección de deriva. La federación y las aprobaciones, que dependen de la plataforma de CI, van en el bloque de Azure real.

```bash
mkdir -p ~/tf-ci/infra/{envs,backends,ci} && cd ~/tf-ci && git init -q && cp ~/tf-st/providers.tf infra/

# ─── 1. Código, backend parcial y entornos ────────────────────────────────────────
cat > infra/backend.tf <<'EOF'
terraform { backend "azurerm" {} }          # los valores van en backends/<entorno>.tfbackend: un fichero por entorno, mismo código
EOF
cat > infra/backends/dev.tfbackend <<'EOF'
resource_group_name  = "rg-tfstate"          # la cuenta de la [página 4](index.md#pagina-4)
storage_account_name = "sttfstatetopaz"
container_name       = "tfstate"
key                  = "moodle/dev.tfstate"
use_azuread_auth     = true
EOF
cat > infra/envs/dev.tfvars <<'EOF'
entorno  = "dev"
location = "eastus"
EOF
cat > infra/main.tf <<'EOF'
variable "entorno"  { type = string }
variable "location" { type = string }
locals { tags = { proyecto = "moodle", entorno = var.entorno, gestion = "terraform" } }
resource "azurerm_resource_group" "ci" { name = "rg-ci-lab-${var.entorno}", location = var.location, tags = local.tags }
resource "azurerm_storage_account" "ci" {
  name = "stcilab${substr(md5(azurerm_resource_group.ci.id), 0, 8)}"
  resource_group_name = azurerm_resource_group.ci.name, location = azurerm_resource_group.ci.location
  account_tier = "Standard", account_replication_type = "LRS", min_tls_version = "TLS1_2", shared_access_key_enabled = false
  tags = local.tags
}
EOF

# ─── 2. El script: los mismos comandos que el workflow ───────────────────────────
cat > infra/ci/tf.sh <<'EOF'
#!/usr/bin/env bash
# Uso: ci/tf.sh comprobar | plan <entorno> | apply <entorno> | deriva <entorno>
set -euo pipefail
export TF_IN_AUTOMATION=true TF_INPUT=0
cd "$(dirname "$0")/.."
cmd=$1; env=${2:-}
case "$cmd" in
  comprobar)
    terraform fmt -check -recursive -diff
    terraform init -backend=false >/dev/null && terraform validate
    command -v tflint >/dev/null && { tflint --init >/dev/null; tflint --recursive --format compact; }
    command -v trivy  >/dev/null && trivy config --severity HIGH,CRITICAL --exit-code 1 .
    command -v gitleaks >/dev/null && gitleaks git --pre-commit --staged --no-banner "$(git rev-parse --show-toplevel)"
    ;;
  plan|deriva)
    terraform init -reconfigure -backend-config="backends/$env.tfbackend" >/dev/null
    extra=""; [ "$cmd" = deriva ] && extra="-refresh-only"
    set +e
    terraform plan -var-file="envs/$env.tfvars" $extra -out=plan.tfplan -detailed-exitcode -no-color 2>&1 | tee plan.txt
    code=${PIPESTATUS[0]}; set -e
    echo "código de salida: $code"
    [ "$code" -eq 1 ] && exit 1
    [ "$code" -eq 2 ] && [ "$cmd" = plan ] && terraform show -json plan.tfplan | jq -r '
      [.resource_changes[] | select(.change.actions != ["no-op"])] as $c
      | "**\(env.env)** — \($c | length) cambios: " +
        ([("create","update","delete","replace") as $a
          | ($c | map(select(($a == "replace" and (.change.actions | length) == 2) or (.change.actions == [$a]))) | length) as $n
          | select($n > 0) | "\($n) \($a)"] | join(", "))' | tee resumen.md
    exit "$code"
    ;;
  apply)
    terraform init -reconfigure -backend-config="backends/$env.tfbackend" >/dev/null
    set +e; terraform plan -var-file="envs/$env.tfvars" -out=plan.tfplan -detailed-exitcode -no-color; code=$?; set -e
    [ "$code" -eq 0 ] && { echo "Sin cambios"; exit 0; }
    [ "$code" -eq 1 ] && exit 1
    terraform apply -no-color plan.tfplan
    ;;
esac
EOF
chmod +x infra/ci/tf.sh
curl -sO https://raw.githubusercontent.com/github/gitignore/main/Terraform.gitignore && mv Terraform.gitignore .gitignore && printf '*.tfplan\nplan.txt\nresumen.md\n!infra/envs/*.tfvars\n' >> .gitignore
git add -A && git commit -qm "infra inicial"

# ─── 3. Comprobar: sin tocar Azure ───────────────────────────────────────────────
infra/ci/tf.sh comprobar                    # fmt, validate, tflint, trivy, gitleaks. Sin ARM_*, sin backend.
sed -i 's/min_tls_version = "TLS1_2", //' infra/main.tf && infra/ci/tf.sh comprobar; echo "salida: $?"   # trivy: HIGH → 1
git checkout infra/main.tf

# ─── 4. Plan con código de salida, apply, plan limpio ────────────────────────────
env=dev infra/ci/tf.sh plan dev; echo "salida: $?"           # código 2, resumen.md: **dev** — 2 cambios: 2 create
terraform -chdir=infra show -json plan.tfplan | jq -c '.variables'   # el plan contiene los valores: por eso no es un artefacto público ([página 10](index.md#pagina-10))
infra/ci/tf.sh apply dev
env=dev infra/ci/tf.sh plan dev; echo "salida: $?"           # código 0: sin cambios

# ─── 5. Deriva: alguien toca Azure "desde el portal" ─────────────────────────────
az group update -n rg-ci-lab-dev --set tags.origen=portal -o none
env=dev infra/ci/tf.sh deriva dev; echo "salida: $?"         # código 2 y plan.txt con "tags: origen = portal" → el issue de las 6:00
infra/ci/tf.sh apply dev                                     # el siguiente apply la revierte
env=dev infra/ci/tf.sh deriva dev; echo "salida: $?"         # 0

# ─── 6. Bloqueo: dos ejecuciones a la vez ────────────────────────────────────────
cd infra && (sleep 90 | terraform console &) && sleep 3       # console mantiene el lease mientras lee stdin: simula un apply largo
terraform plan -var-file=envs/dev.tfvars
#   Error: Error acquiring the state lock … ID: <uuid> … Operation: OperationTypeConsole … Who: tu@equipo
az storage blob show --account-name sttfstatetopaz -c tfstate -n moodle/dev.tfstate --auth-mode login --query "{lease:properties.lease.status, lockid:metadata.terraformlockid}" -o json
terraform force-unlock -force "$(az storage blob show --account-name sttfstatetopaz -c tfstate -n moodle/dev.tfstate --auth-mode login --query metadata.terraformlockid -o tsv)"
#   (solo porque sabemos que el "otro job" es un sleep; en CI, primero confirma que la ejecución dueña ha muerto)
pkill -f "terraform console" || true; cd ..

# ─── 7. Plan caduco: el artefacto que llega tarde ────────────────────────────────
terraform -chdir=infra plan -var-file=envs/dev.tfvars -out=plan.tfplan >/dev/null
az group update -n rg-ci-lab-dev --set tags.origen=portal -o none
terraform -chdir=infra apply plan.tfplan
#   Error: Saved plan is stale. Por esto plan y apply van en el mismo job.

# ─── 8. Limpiar ──────────────────────────────────────────────────────────────────
terraform -chdir=infra destroy -var-file=envs/dev.tfvars -auto-approve && rm -f infra/plan.tfplan infra/plan.txt infra/resumen.md
```

```bash
# ─── Solo Azure real ────────────────────────────────────────────────────────────
# A. GitHub: variables (no secretos), environments y la puerta de pro
gh variable set AZURE_TENANT_ID       --body "$(az account show --query tenantId -o tsv)"
gh variable set AZURE_SUBSCRIPTION_ID --body "$(az account show --query id -o tsv)"
gh variable set AZURE_CLIENT_ID_dev   --body "$(az identity show -g rg-plataforma -n id-moodle-tf-dev --query clientId -o tsv)"
gh variable set AZURE_CLIENT_ID_pro   --body "$(az identity show -g rg-plataforma -n id-moodle-tf-pro --query clientId -o tsv)"
gh api -X PUT repos/{owner}/{repo}/environments/moodle-dev
gh api -X PUT repos/{owner}/{repo}/environments/moodle-pro \
  --input - <<EOF
{ "reviewers": [{ "type": "User", "id": $(gh api users/<revisor> --jq .id) }], "deployment_branch_policy": { "protected_branches": true, "custom_branch_policies": false } }
EOF
gh secret list                                              # debe estar vacío: el pipeline no guarda secretos
#    Credenciales federadas (página 12): sujeto "repo:org/repo:pull_request" para el plan de la PR, "…:ref:refs/heads/main" para dev,
#    "…:environment:moodle-pro" para pro. Comprueba el sub real del token en un job de prueba (página 12, bloque C).
git checkout -b prueba && sed -i 's/"LRS"/"ZRS"/' infra/main.tf && git commit -qam "ZRS" && git push -u origin prueba && gh pr create --fill
gh pr checks --watch                                        # comprobar → plan (dev, pro): el comentario aparece en la PR con "1 update"
gh pr merge --squash --delete-branch
gh run watch                                                # aplicar/dev corre; aplicar/pro queda en "Waiting for review"
gh api repos/{owner}/{repo}/actions/runs/$(gh run list -w terraform-moodle -L1 --json databaseId --jq '.[0].databaseId')/pending_deployments \
  -X POST -f state=approved -f comment="ZRS revisado" -F "environment_ids[]=$(gh api repos/{owner}/{repo}/environments/moodle-pro --jq .id)"
az monitor activity-log list --caller "$(gh variable get AZURE_CLIENT_ID_pro)" --offset 1h --query "[].{cuando:eventTimestamp, que:operationName.localizedValue}" -o table   # quién hizo el cambio: la identidad de pro ([página 14](index.md#pagina-14))

# B. Azure DevOps: la conexión de servicio federada genera issuer y subject; regístralos en la credencial (página 12, bloque B)
az devops service-endpoint list --org https://dev.azure.com/<org> -p <proyecto> --query "[?name=='sc-moodle-pro'].{issuer:authorization.parameters.workloadIdentityFederationIssuer, subject:authorization.parameters.workloadIdentityFederationSubject}" -o json
az pipelines environment list --org … -p … -o table       # moodle-dev, moodle-pro; los checks (Approvals, Branch control, Exclusive lock) se configuran en el portal del environment
az pipelines run --name terraform-moodle --branch main --org … -p …
```

---

## 7. Errores comunes

> ⚠️ **Solución de problemas**
>
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | `terraform apply -auto-approve` en cada push a `main` (el original) | Nadie ve el plan antes de que se ejecute. Plan en la PR como comentario; apply detrás de un *environment* con revisores. `-auto-approve` solo tiene sentido aplicando un fichero de plan ya revisado |
> | *Unable to get ACTIONS_ID_TOKEN_REQUEST_URL env variable* | Falta `permissions: id-token: write` en el job (la raíz tiene `contents: read` y cada job amplía lo suyo). En PRs desde *forks* el token no se emite: el plan solo corre para ramas del propio repositorio |
> | *AADSTS70021: No matching federated identity record found* | El sujeto del token no coincide con la credencial: `pull_request`, `ref:refs/heads/main` y `environment:moodle-pro` son tres sujetos y necesitan tres credenciales ([página 12](index.md#pagina-12)). En DevOps, el sujeto es `sc://org/proyecto/conexión` |
> | `-detailed-exitcode` devuelve siempre 0; `\| tee` no recibe nada | El wrapper de `setup-terraform`. `terraform_wrapper: false` en todos los jobs que ejecuten scripts |
> | *state snapshot was created by Terraform v1.12.x, which is newer than current v1.11.4* | `terraform_version: latest` del original: un job actualizó el estado con una versión nueva y el siguiente ya no puede leerlo. Versión fijada en una sola variable (`TF_VERSION`) y `required_version` en el código |
> | *Error acquiring the state lock* en cada ejecución | Un apply cancelado dejó el lease (`cancel-in-progress: true` o un runner perdido). Confirma que el job dueño no corre, `force-unlock` con el ID del mensaje, y pon `cancel-in-progress: false`. Nunca `state push` |
> | *Saved plan is stale* | El plan se aplicó contra un estado distinto del que lo generó: artefacto entre jobs, o deriva entre plan y apply. Plan y apply en el mismo job; el plan de la PR es para revisar, no para aplicar |
> | *No value for required variable "api_key_sms"* en el apply | Es `ephemeral`: no está en el fichero de plan. El paso de apply la lee de Key Vault en la misma línea, igual que el plan ([página 10](index.md#pagina-10)) |
> | *Value for undeclared variable* tras `echo "ARM_CLIENT_ID=…" > terraform.tfvars` | `ARM_*` configuran el provider por entorno, no son variables de Terraform. Borra ese paso; y el `ARM_CLIENT_SECRET` que lo acompañaba desaparece con la federación |
> | El log muestra `***` y, dos líneas después, el valor en claro | El *masking* solo cubre el valor exacto del secreto registrado; un JSON, un `-raw` o un `base64` lo destapan. El pipeline de esta página no posee el secreto: lo lee del vault y lo pasa como variable efímera en la misma línea, sin `echo` ni `-var`. El `echo "Contraseña: …"` del original imprime el secreto y lo llama "ocultar en logs" |
> | `plan.tfplan` subido con `upload-artifact` para que otro job lo aplique | Contiene los valores de todas las variables no efímeras y los atributos conocidos ([página 10](index.md#pagina-10)): cualquiera con lectura del repositorio lo descarga. Plan y apply en el mismo job; si necesitas separarlos, el artefacto va cifrado y con retención de horas |
> | `workflow_run` como "aprobación" (el original) | Encadena workflows; no pide nada a nadie. La puerta es un *environment* con *required reviewers* y *deployment branches*; en DevOps, *Approvals and checks* sobre el environment |
> | El job de pro se ejecuta desde una rama de prueba | El environment no limita las ramas. *Deployment branches* = `main`; y la credencial federada de pro con sujeto `environment:moodle-pro`, así que aunque el job arranque, no obtiene token |
> | *AuthorizationFailed* al crear un recurso desde el pipeline; en local funciona | En local usas tu usuario (Owner); el pipeline es `id-moodle-tf` con roles acotados ([página 12](index.md#pagina-12)). No añadas *Owner* sobre la suscripción como propone el original: añade el rol de datos concreto que falta y, si es una asignación de rol, el GUID a la lista de la condición |
> | *Error: building account: … subscription ID could not be determined* | azurerm 4.x exige `ARM_SUBSCRIPTION_ID` aunque la conexión ya sepa la suscripción. En DevOps, léelo con `az account show` dentro de `AzureCLI@2` |
> | DevOps: *idToken: unbound variable* o `$idToken` vacío | Falta `addSpnToEnvironment: true`, o la conexión de servicio es de tipo secreto (entonces expone `servicePrincipalKey`, no `idToken`). Recrea la conexión con *Workload identity federation* |
> | DevOps: `scriptType: 'ps'` falla en `ubuntu-latest` | `ps` es Windows PowerShell. En agentes Linux, `bash` (o `pscore` si de verdad quieres PowerShell) |
> | El schedule no se dispara, o se dispara con el código de otra rama | GitHub ejecuta `schedule` solo sobre la rama por defecto y lo desactiva tras 60 días sin actividad en el repo. DevOps necesita `branches: include: [main]` y `always: true` para correr aunque no haya commits |
> | El comentario del plan en la PR se duplica en cada push | Sin marcador no hay forma de encontrar el anterior. El script busca `<!-- tf-plan-<entorno> -->` y actualiza en lugar de crear |
> | El comentario del plan excede el límite de GitHub (65 536 caracteres) | Por eso el resumen va delante y el plan completo dentro de `<details>` recortado con `tail -c 60000`. Si el plan es tan largo, la PR es demasiado grande |
> | El pipeline aplica en dev y pro a la vez, o pro sin que dev haya terminado | `max-parallel: 1` y `fail-fast: true` en la matriz de apply; en DevOps, `dependsOn: aplicar_dev`. Una identidad por entorno garantiza además que el job de dev no puede tocar pro aunque el YAML se equivoque |
> | `tflint` o `trivy` fallan en Topaz por reglas de azurerm que no aplican al emulador | Son análisis estáticos: no hablan con Azure ni con Topaz, evalúan el código. Si una regla no aplica a tu contexto, `.tflint.hcl` o `.trivyignore` con el ID y un comentario que lo justifique, no `exit-code: 0` |
> | En Topaz: la federación no se puede probar, y el bloqueo del estado depende de la versión del emulador | Esperado: no hay emisor OIDC ni plataforma de CI dentro del emulador. El lease de blobs sí está implementado en las versiones recientes; si `force-unlock` no encuentra el ID, actualiza Topaz o ejecuta el paso 6 del laboratorio en Azure real |

---

## 8. Autoevaluación

1. **¿Por qué un pipeline de Terraform no debe aplicar en cada push a `main`?**
   Porque el primer momento en que alguien vería el cambio sería cuando ya está hecho. El plan se revisa en la PR; el apply ocurre una vez por cambio, detrás de una puerta de aprobación.
2. **¿Cuáles son los cuatro momentos del flujo y qué permisos en Azure necesita cada uno?**
   Comprobar (ninguno: `init -backend=false`), planificar (lectura), aprobar y aplicar (los roles acotados de `id-moodle-tf-<entorno>`), vigilar (lectura).
3. **¿Qué cuatro datos necesita el runner para hablar con Azure y por qué ninguno va en `secrets`?**
   `client_id`, `tenant_id`, `subscription_id` y `ARM_USE_OIDC`. Son identificadores públicos; el token lo emite la plataforma en cada job y la credencial federada lo intercambia. Enmascararlos solo estorba al depurar.
4. **¿Cómo llega al apply la clave del proveedor de SMS sin pasar por la plataforma de CI?**
   El job, ya autenticado, la lee de Key Vault con `az keyvault secret show` y la asigna a `TF_VAR_api_key_sms` en la misma línea del comando; la variable es `ephemeral`, así que no toca el plan ni el estado.
5. **¿Por qué plan y apply van en el mismo job en lugar de subir el plan como artefacto?**
   El fichero de plan contiene las variables no efímeras y los atributos conocidos: es un secreto descargable. Además, con variables efímeras no es aplicable sin volver a pasarlas, y si el estado cambia entre medias el plan está caduco.
6. **¿Qué distingue `workflow_run` de un *environment* con revisores?**
   `workflow_run` encadena workflows sin pedir nada a nadie. El *environment* detiene el job hasta que un revisor aprueba y limita las ramas que pueden desplegar; combinado con el sujeto `environment:moodle-pro` de la credencial federada, ninguna otra rama obtiene token.
7. **¿Qué significan los códigos 0, 1 y 2 de `plan -detailed-exitcode` y qué añade `-refresh-only`?**
   0 sin cambios, 1 error, 2 cambios pendientes. Con `-refresh-only`, un 2 significa que Azure difiere del estado sin que el código haya cambiado: deriva pura.
8. **¿Por qué `terraform_wrapper: false`?**
   El wrapper devuelve siempre 0 (anula `-detailed-exitcode`), corta los pipes y limita el tamaño de los outputs. Sin él, el script del workflow es idéntico al que ejecutas en local.
9. **El estado está bloqueado. ¿Qué haces antes de `force-unlock`?**
   Comprobar quién tiene el lease y si esa ejecución sigue viva. Solo si ha muerto, `force-unlock` con el ID exacto del mensaje. Nunca `state push`: sobrescribe el estado remoto.
10. **¿Qué provoca `terraform_version: latest` en un pipeline?**
    Un job actualiza el estado con una versión nueva y el siguiente, con otra, no puede leerlo. La versión se fija en una variable única y se refuerza con `required_version`.
11. **¿Cómo resuelve Azure DevOps la autenticación sin secreto y qué sujeto tiene su credencial federada?**
    Conexión de servicio con *workload identity federation*; `AzureCLI@2` con `addSpnToEnvironment` expone `idToken`, que el provider acepta como `ARM_OIDC_TOKEN`. El sujeto es `sc://org/proyecto/conexión`.
12. **¿Qué parte del pipeline se prueba en Topaz y cuál exige Azure real?**
    En Topaz, todo lo que hace el script: códigos de salida, resumen del plan, deriva, bloqueo y plan caduco. La federación, los *environments* y las aprobaciones dependen de la plataforma de CI y se prueban en Azure.

---

## 9. Referencias

- [Terraform en automatización](https://developer.hashicorp.com/terraform/tutorials/automation/automate-terraform) (`TF_IN_AUTOMATION`, `TF_INPUT`, plan y apply separados) y [`-detailed-exitcode`](https://developer.hashicorp.com/terraform/cli/commands/plan#detailed-exitcode)
- [`terraform force-unlock`](https://developer.hashicorp.com/terraform/cli/commands/force-unlock) y [backend azurerm](https://developer.hashicorp.com/terraform/language/backend/azurerm) (bloqueo por lease, `use_azuread_auth`, `use_oidc`)
- [Provider azurerm con OIDC](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/service_principal_oidc) (`ARM_USE_OIDC`, `ARM_OIDC_TOKEN`, GitHub y Azure DevOps)
- [OIDC de GitHub Actions con Azure](https://docs.github.com/es/actions/security-for-github-actions/security-hardening-your-deployments/configuring-openid-connect-in-azure) y [Environments: revisores y ramas de despliegue](https://docs.github.com/es/actions/managing-workflow-runs-and-deployments/managing-deployments/managing-environments-for-deployment)
- [`concurrency` en GitHub Actions](https://docs.github.com/es/actions/writing-workflows/choosing-what-your-workflow-does/control-the-concurrency-of-workflows-and-jobs) y [permisos del `GITHUB_TOKEN`](https://docs.github.com/es/actions/security-for-github-actions/security-guides/automatic-token-authentication#permissions-for-the-github_token)
- [`hashicorp/setup-terraform`](https://github.com/hashicorp/setup-terraform) (`terraform_wrapper`), [tflint](https://github.com/terraform-linters/tflint), [trivy-action](https://github.com/aquasecurity/trivy-action) y [gitleaks-action](https://github.com/gitleaks/gitleaks-action)
- [Conexiones de servicio a Azure con federación de identidad de carga de trabajo](https://learn.microsoft.com/es-es/azure/devops/pipelines/library/connect-to-azure) y [tarea `AzureCLI@2`](https://learn.microsoft.com/es-es/azure/devops/pipelines/tasks/reference/azure-cli-v2) (`addSpnToEnvironment`)
- [Approvals and checks en Azure DevOps](https://learn.microsoft.com/es-es/azure/devops/pipelines/process/approvals) (aprobaciones, control de rama, bloqueo exclusivo) y [desencadenadores programados](https://learn.microsoft.com/es-es/azure/devops/pipelines/process/scheduled-triggers)
- [Comandos de registro de Azure Pipelines](https://learn.microsoft.com/es-es/azure/devops/pipelines/scripts/logging-commands) (`##vso[task.setvariable]`, `uploadsummary`)
- [Pruebas de extremo a extremo con Terraform en Azure](https://learn.microsoft.com/es-es/azure/developer/terraform/best-practices-end-to-end-testing)
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)