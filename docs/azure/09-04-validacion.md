# ✅ Validación: la escalera de comprobaciones antes del `apply`

> Un error en Terraform cuesta más cuanto más tarde aparece: nada si lo detecta el editor, segundos si lo detecta `validate`, minutos si lo detecta el plan, y una VM o unos datos si lo detecta el apply. La validación consiste en poner comprobaciones baratas *antes* de las caras, y en saber qué atrapa cada una, porque ninguna lo atrapa todo: `terraform validate` acepta una cuenta de almacenamiento con el nombre en mayúsculas y una variable que nadie usa; `tflint` acepta un NSG abierto al mundo; `trivy` acepta un plan que destruye la base de datos. Esta página monta esa escalera con siete peldaños, del que corre en milisegundos sin ninguna nube al que aplica de verdad contra el emulador, y la lleva al pipeline con cada peldaño en su sitio. El original tenía dos peldaños y un pipeline que no arrancaba; aquí cada comando se ejecuta y cada fallo se provoca a propósito para verlo. Lo que necesita Azure real (el plan del PR con OIDC y Azure Policy como última barrera) va al bloque final.

**🎯 Objetivos de aprendizaje**
- Ordenar las comprobaciones por coste y explicar qué atrapa y qué se le escapa a cada una.
- Ejecutar `validate` sin backend ni credenciales, y saber por qué necesita `init`.
- Configurar `tflint` con el ruleset de Azure y reglas de convención propias.
- Añadir análisis de seguridad con `trivy config` y justificar excepciones.
- Escribir pruebas con `terraform test`: unitarias con `mock_provider` e integración contra Topaz.
- Montar el pipeline (GitHub Actions y GitLab CI) para que falle en el peldaño correcto, y el gancho local que evita llegar a él.

> **🔷 Requisitos previos.** [Páginas 5](index.md#pagina-5) a 7 (sintaxis, `validation`, `precondition`). Herramientas: `tflint`, `trivy` y `pre-commit` (`brew install tflint trivy pre-commit` o los binarios de sus releases; la [página 3](index.md#pagina-3) tiene la lista). Terraform ≥ 1.7 para `mock_provider`.

---

## 1. La escalera

| **#** | **Comprobación** | **Atrapa** | **Se le escapa** | **Necesita** |
|---|---|---|---|---|
| 1 | `terraform fmt -check` | Formato: diffs de revisión limpios | Todo lo demás | Nada |
| 2 | `terraform validate` | Sintaxis, tipos, referencias a cosas que no existen, argumentos que el provider no conoce | Valores que la API rechazará, variables sin usar, seguridad, sintaxis obsoleta | `init -backend=false` (descarga el esquema del provider). Sin credenciales |
| 3 | `tflint` + ruleset azurerm | Declaraciones sin usar, interpolación obsoleta, tamaños de VM y valores enumerados inválidos, convenciones de nombres | Seguridad, lógica, lo que depende del estado | `tflint --init` (descarga el plugin). Sin credenciales |
| 4 | `trivy config` | Malas configuraciones de seguridad: TLS antiguo, acceso público, NSG abierto, secretos en claro | Todo lo que no sea seguridad; y da falsos positivos que hay que justificar | Nada |
| 5 | `validation` / `precondition` | Las reglas *de tu equipo*: regiones permitidas, patrón de nombres, tamaños aprobados. Mensaje propio | Lo que no hayas escrito | Un `plan`; las `validation` de variables ni eso |
| 6 | `terraform plan` contra Topaz | Lo que la API rechaza, qué se destruye, deriva | Lo que solo falla al aplicar; lo que Topaz no emula | Topaz o Azure |
| 7 | `terraform test` | Que el módulo hace lo que promete, desde cero, con aserciones | Lo que no hayas afirmado | Nada con `mock_provider`; Topaz con `command = apply` |

---

## 2. `validate`: qué mira y por qué necesita `init`

`terraform validate` comprueba la configuración contra el **esquema del provider**: qué argumentos existen, de qué tipo son, cuáles son obligatorios. Ese esquema lo trae el binario del provider, así que hace falta `terraform init` para descargarlo. Con `-backend=false` no toca el estado remoto y no necesita credenciales de nada: es el `init` que corre en CI en el peldaño 2. Lo que `validate` *no* hace es hablar con la API: no sabe si un nombre está cogido, si una región existe o si un valor es válido más allá de su tipo.

---

## 3. `tflint`: el ruleset de Azure y las reglas propias

Sin configuración, `tflint` solo aplica las reglas genéricas de Terraform. El ruleset `azurerm` añade cientos de reglas generadas desde la especificación de la API: tamaños de VM, SKUs, valores enumerados. Y las reglas `terraform_*` configurables son donde van las convenciones del equipo.

```hcl
# .tflint.hcl  (en la raíz del repositorio)
config {
  call_module_type = "local"                 # analiza también los módulos locales (antes: module = true)
}
plugin "azurerm" {
  enabled = true
  version = "0.28.0"                         # fijada: el ruleset cambia con la API
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}
rule "terraform_required_version"   { enabled = true }   # todo módulo declara required_version
rule "terraform_required_providers" { enabled = true }   # y fija sus providers
rule "terraform_unused_declarations" { enabled = true }
rule "terraform_deprecated_interpolation" { enabled = true }
rule "terraform_naming_convention" {                     # convención del curso: snake_case en nombres de bloques
  enabled = true
  format  = "snake_case"
}
```

Códigos de salida: `0` sin hallazgos, `2` con hallazgos, `1` error de la herramienta. En CI se usa `--minimum-failure-severity=warning` para decidir qué rompe el pipeline y `--format sarif` para que GitHub muestre los hallazgos en el PR.

---

## 4. `trivy config`: seguridad, y excepciones con nombre

El original no tiene ningún peldaño de seguridad. `trivy config` (que absorbió a tfsec) lee HCL y señala configuraciones inseguras con un identificador estable (`AVD-AZU-…`). Como toda herramienta de este tipo, a veces se equivoca o señala algo que has decidido a conciencia: la excepción va en `.trivyignore` con el id, la razón y, si procede, una fecha de caducidad. Nunca desactivando la herramienta.

```text
# .trivyignore
# El bastion necesita SSH desde la red corporativa (prefijo concreto, no *). Revisar 2027-03.
AVD-AZU-0047 exp:2027-03-31
```

---

## 5. `terraform test`: afirmar lo que el módulo promete

Desde Terraform 1.6, los ficheros `.tftest.hcl` ejecutan la configuración y comprueban aserciones. Con `command = plan` y `mock_provider` (1.7+) no hace falta ningún endpoint: el provider devuelve valores ficticios y las aserciones sobre lo que *tú* configuras funcionan. Con `command = apply` contra Topaz se prueba de verdad desde cero, y al terminar Terraform destruye lo que creó. Es la respuesta a "funcionaba en mi entorno": el entorno de la prueba siempre está vacío.

```hcl
# tests/unitaria.tftest.hcl  — sin Topaz, sin credenciales, milisegundos
mock_provider "azurerm" {}
variables { nombre = "stvalida01" }
run "storage_endurecido" {
  command = plan
  assert {
    condition     = azurerm_storage_account.datos.min_tls_version == "TLS1_2" && !azurerm_storage_account.datos.shared_access_key_enabled
    error_message = "El storage debe salir endurecido por defecto."
  }
}
run "nombre_invalido_rechazado" {
  command         = plan
  variables       { nombre = "ST-Malo" }
  expect_failures = [var.nombre]            # la prueba PASA si la validation falla: se prueba el contrato
}

# tests/integracion.tftest.hcl  — contra Topaz: crea, afirma, destruye
run "crea_y_comprueba" {
  command = apply
  assert {
    condition     = can(regex("^/subscriptions/", azurerm_storage_account.datos.id))
    error_message = "La cuenta no se creó."
  }
}
```

---

## 6. El pipeline: cada peldaño en su sitio

Dos trabajos. El primero corre sin credenciales ni nube en menos de un minuto y bloquea el PR. El segundo levanta Topaz con el script de la [página 3](index.md#pagina-3) y hace plan y test de integración; sigue sin tocar Azure. El plan contra Azure real con OIDC es la [página 12](index.md#pagina-12).

```yaml
# .github/workflows/validar.yml
name: validar
on:
  pull_request:
  push: { branches: [main] }                 # no [push, pull_request]: cada PR correría dos veces
permissions: { contents: read, security-events: write }
env: { TF_VERSION: "1.9.5", TFLINT_VERSION: "v0.53.0" }   # fijadas: "latest" no es reproducible
jobs:
  estatico:                                  # peldaños 1–4 y 7 (unitaria): sin nube, sin credenciales
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: "${{ env.TF_VERSION }}" }
      - run: terraform fmt -check -recursive -diff
      - run: terraform init -backend=false            # el init que validate necesita, sin estado ni credenciales
      - run: terraform validate
      - uses: terraform-linters/setup-tflint@v4
        with: { tflint_version: "${{ env.TFLINT_VERSION }}" }
      - run: tflint --init                            # descarga el ruleset azurerm de .tflint.hcl
        env: { GITHUB_TOKEN: "${{ github.token }}" }  # evita el límite de la API de GitHub al descargar el plugin
      - run: tflint --recursive --format sarif --minimum-failure-severity=warning > tflint.sarif || echo "TFLINT_FALLO=1" >> $GITHUB_ENV
      - uses: github/codeql-action/upload-sarif@v3
        with: { sarif_file: tflint.sarif }            # los hallazgos aparecen en la pestaña Security y en el PR
      - run: '[ -z "$TFLINT_FALLO" ]'
      - uses: aquasecurity/trivy-action@0.28.0
        with: { scan-type: config, scan-ref: ., severity: "HIGH,CRITICAL", exit-code: "1", trivyignores: .trivyignore }
      - run: terraform test -filter=tests/unitaria.tftest.hcl
  topaz:                                     # peldaños 6 y 7 (integración): el emulador, sin Azure
    needs: estatico
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with: { terraform_version: "${{ env.TF_VERSION }}" }
      - run: ./scripts/topaz-start.sh                 # el mismo script de la [página 3](index.md#pagina-3): contenedor, certificado, topaz.env
      - run: |
          source ~/.topaz/topaz.env
          terraform init -backend=false
          terraform plan -input=false -out=plan.bin
          terraform show -json plan.bin | jq -e '[.resource_changes[].change.actions[]] | index("delete") | not' \
            || { echo "::error::El plan destruye recursos; requiere revisión explícita"; exit 1; }
          terraform test -filter=tests/integracion.tftest.hcl
```

```yaml
# .gitlab-ci.yml  (equivalente del trabajo estático)
stages: [validar]
validar:
  stage: validar
  image:
    name: hashicorp/terraform:1.9.5
    entrypoint: [""]                         # sin esto el entrypoint es "terraform" y ningún comando de shell arranca
  before_script:
    - apk add --no-cache curl bash git
    - curl -sL https://github.com/terraform-linters/tflint/releases/download/v0.53.0/tflint_linux_amd64.zip -o /tmp/tflint.zip && unzip -o /tmp/tflint.zip -d /usr/local/bin
    - curl -sL https://github.com/aquasecurity/trivy/releases/download/v0.56.2/trivy_0.56.2_Linux-64bit.tar.gz | tar xz -C /usr/local/bin trivy
  script:
    - terraform fmt -check -recursive
    - terraform init -backend=false && terraform validate
    - tflint --init && tflint --recursive --minimum-failure-severity=warning
    - trivy config --severity HIGH,CRITICAL --exit-code 1 --ignorefile .trivyignore .
    - terraform test -filter=tests/unitaria.tftest.hcl
```

Y el gancho local, para no descubrir en el PR lo que un segundo en tu máquina habría dicho:

```yaml
# .pre-commit-config.yaml   →  pre-commit install   (corre en cada git commit)
repos:
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.96.1
    hooks:
      - id: terraform_fmt
      - id: terraform_validate
        args: [--hook-config=--retry-once-with-cleanup=true, --tf-init-args=-backend=false]
      - id: terraform_tflint
        args: [--args=--config=__GIT_WORKING_DIR__/.tflint.hcl]
      - id: terraform_trivy
        args: [--args=--severity HIGH,CRITICAL]
      - id: terraform_docs                   # regenera el README del módulo desde variables y outputs
```

---

## 7. Laboratorio en Topaz

Un fichero con seis defectos sembrados, uno por peldaño. Cada peldaño atrapa el suyo y deja pasar los demás: eso es lo que hay que ver.

```bash
mkdir -p ~/tf-val/tests && cd ~/tf-val && cp ~/tf-st/providers.tf . && git init -q
# guarda .tflint.hcl (11.3) y los dos tests (11.5); luego el fichero con defectos:
cat > main.tf <<'EOF'
variable "nombre" {
  type = string
  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.nombre))
    error_message = "Nombre de storage: 3–24 caracteres, solo minúsculas y dígitos (regla de Azure)."
  }
}
variable "sin_uso" { type = string, default = "nadie me lee" }              # defecto 3a: tflint
resource "azurerm_resource_group" "lab" {
    name = "rg-val"                                                          # defecto 1: sangría (fmt)
  locaton  = "eastus"                                                        # defecto 2: argumento inexistente (validate)
}
resource "azurerm_storage_account" "datos" {
  name                      = var.nombre
  resource_group_name       = azurerm_resource_group.lab.name
  location                  = azurerm_resource_group.lab.location
  account_tier              = "Standard"
  account_replication_type  = "LRS"
  min_tls_version           = "TLS1_0"                                       # defecto 4: TLS antiguo (trivy)
  shared_access_key_enabled = false
  tags                      = { owner = "${var.sin_uso}" }                   # defecto 3b: interpolación obsoleta (tflint)
}
resource "azurerm_network_security_group" "web" {
  name                = "nsg-val"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  security_rule {
    name = "ssh", priority = 100, direction = "Inbound", access = "Allow", protocol = "Tcp"
    source_port_range = "*", destination_port_range = "22"
    source_address_prefix = "*", destination_address_prefix = "*"          # defecto 4b: SSH abierto al mundo (trivy)
  }
}
EOF

# ─── Peldaño 1: fmt ─────────────────────────────────────────────────────────────
terraform fmt -check -diff; echo "exit $?"                           # exit 3 y el diff de la línea mal sangrada
terraform fmt                                                        # lo arregla. Nada más: los otros cinco defectos siguen ahí

# ─── Peldaño 2: validate ────────────────────────────────────────────────────────
terraform validate                                                   # Error: … please run "terraform init" — el pipeline del original moría aquí
terraform init -backend=false >/dev/null && terraform validate
#   Error: Unsupported argument … An argument named "locaton" is not expected here.   (defecto 2)
sed -i 's/locaton /location/' main.tf && terraform validate         # Success! The configuration is valid.
#   Success… con TLS 1.0, SSH abierto, una variable inútil y una interpolación de 2017. validate no mira nada de eso.

# ─── Peldaño 3: tflint ──────────────────────────────────────────────────────────
tflint; echo "exit $?"                                               # exit 1: no encuentra el ruleset azurerm: falta --init (el original tampoco lo hacía)
tflint --init && tflint; echo "exit $?"
#   Warning: variable "sin_uso" is declared but not used (terraform_unused_declarations)
#   Warning: Interpolation-only expressions are deprecated (terraform_deprecated_interpolation)
#   exit 2
sed -i '/variable "sin_uso"/d; s/{ owner = "\${var.sin_uso}" }/{ owner = "curso" }/' main.tf && tflint && echo "limpio"
sed -i 's/size *= "Standard_B2s"/size = "Standard_B2xs"/' vm.tf 2>/dev/null   # si tienes la VM de la [página 9](index.md#pagina-9): azurerm_linux_virtual_machine_invalid_size

# ─── Peldaño 4: trivy ───────────────────────────────────────────────────────────
trivy config --severity HIGH,CRITICAL .
#   HIGH  Storage account uses an insecure TLS version           main.tf:…  min_tls_version = "TLS1_0"
#   HIGH  Security group rule allows ingress from public internet  main.tf:…  source_address_prefix = "*"
sed -i 's/TLS1_0/TLS1_2/; s/source_address_prefix = "\*"/source_address_prefix = "10.20.3.0\/24"/' main.tf
trivy config --severity HIGH,CRITICAL --exit-code 1 . && echo "sin hallazgos altos"

# ─── Peldaño 5: el contrato en el código ────────────────────────────────────────
terraform plan -var nombre="ST-Malo" 2>&1 | grep -A2 "Invalid value for variable"
#   Nombre de storage: 3–24 caracteres, solo minúsculas y dígitos (regla de Azure).
#   Los peldaños 1–4 lo dejaron pasar: era un string válido, seguro y bien formateado. Solo TU regla lo conoce.

# ─── Peldaño 6: plan contra Topaz ───────────────────────────────────────────────
source ~/.topaz/topaz.env && az account show --query environmentName -o tsv   # Topaz
terraform plan -var nombre=stval01 -out=plan.bin | tail -1                    # Plan: 3 to add
terraform show -json plan.bin | jq '[.resource_changes[] | {r: .address, a: .change.actions}]'   # lo que el pipeline inspecciona: ningún "delete"

# ─── Peldaño 7: terraform test ──────────────────────────────────────────────────
terraform test -filter=tests/unitaria.tftest.hcl -var nombre=stval01
#   run "storage_endurecido"… pass / run "nombre_invalido_rechazado"… pass   (sin tocar Topaz: mock_provider)
sed -i 's/TLS1_2/TLS1_1/' main.tf && terraform test -filter=tests/unitaria.tftest.hcl -var nombre=stval01 | grep -E "fail|endurecido"
#   run "storage_endurecido"… fail: El storage debe salir endurecido por defecto.   ← la regresión, atrapada en milisegundos
git checkout main.tf 2>/dev/null || sed -i 's/TLS1_1/TLS1_2/' main.tf
terraform test -filter=tests/integracion.tftest.hcl -var nombre=stval01       # crea en Topaz, afirma, destruye
az group list --query "[?name=='rg-val'].name" -o tsv                          # vacío: el test limpió tras de sí

# ─── El gancho local ────────────────────────────────────────────────────────────
# guarda .pre-commit-config.yaml (11.6)
pre-commit install && git add . && git commit -m "validación"       # corre fmt, validate, tflint y trivy antes de aceptar el commit
cd ~ && rm -rf ~/tf-val
```

```bash
# ─── Solo Azure real ────────────────────────────────────────────────────────────
# A. El peldaño 6 contra Azure, en el PR, con OIDC (la identidad federada se construye en la página 12)
#    Solo cambia el destino: el mismo plan.bin, la misma inspección de "delete", pero con estado remoto real.
#      - uses: azure/login@v2
#        with: { client-id: "${{ vars.AZURE_CLIENT_ID }}", tenant-id: "${{ vars.AZURE_TENANT_ID }}", subscription-id: "${{ vars.AZURE_SUBSCRIPTION_ID }}" }
#      - run: terraform init && terraform plan -input=false -out=plan.bin
#        env: { ARM_USE_OIDC: "true", ARM_USE_AZUREAD: "true" }
#    La identidad del PR solo tiene el rol Reader (más "Storage Blob Data Reader" en el estado): un PR puede planificar, nunca aplicar.

# B. El plan como comentario del PR: quien revisa lee el plan, no el HCL
#      - run: terraform show -no-color plan.bin > plan.txt
#      - uses: actions/github-script@v7
#        with:
#          script: |
#            const plan = require('fs').readFileSync('plan.txt','utf8').slice(0, 60000);
#            github.rest.issues.createComment({ ...context.repo, issue_number: context.issue.number,
#              body: "### Plan\n```\n" + plan + "\n```" });

# C. Azure Policy: la barrera que no depende de que nadie corra nada
#    Lo que tflint y trivy sugieren, Policy lo impide en la plataforma. Un deny de la política integrada
#    "Storage accounts should have the specified minimum TLS version" hace que el apply falle aunque el pipeline se salte.
az policy assignment create -n tls-minimo --scope "/subscriptions/$(az account show --query id -o tsv)" \
  --policy "fe83a0eb-a853-422d-aac2-1bffd182c5d0" -p '{"minimumTlsVersion":{"value":"TLS1_2"}}' --enforcement-mode Default
sed -i 's/TLS1_2/TLS1_0/' main.tf && terraform apply -auto-approve 2>&1 | grep -E "RequestDisallowedByPolicy"
#   Error: … RequestDisallowedByPolicy: Resource 'stval01' was disallowed by policy. Policy identifiers: …tls-minimo
#   trivy lo habría dicho en el peldaño 4, gratis. Policy lo dice en el 6, ya con la petición hecha. Las dos capas se necesitan.
git checkout main.tf && az policy assignment delete -n tls-minimo

# D. Ver la política en el plan, no en el apply: azurerm no evalúa Policy al planificar. Para eso existe
#    "terraform plan" + "az policy state trigger-scan" tras aplicar, o Conftest/OPA sobre plan.json (fuera del alcance del curso).
```

---

## 8. Errores comunes

> ⚠️ **Solución de problemas**
>
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | `Error: Missing required provider … please run "terraform init"` en CI (el original) | `validate` necesita el esquema del provider. `terraform init -backend=false` antes: descarga providers sin tocar estado ni credenciales |
> | `terraform init` en CI pide credenciales o falla con el backend | Falta `-backend=false`. Para validar no hace falta el estado; solo el plan (peldaño 6 en Azure real) lo necesita |
> | `tflint` exit 1: `Plugin "azurerm" not found` (el original) | Falta `tflint --init`, que descarga el ruleset declarado en `.tflint.hcl`. En CI, con `GITHUB_TOKEN` para evitar el límite de la API |
> | `tflint` pasa y aun así hay un tamaño de VM inválido | Sin el ruleset azurerm solo corren las reglas genéricas. Es el ruleset el que conoce SKUs y enumerados. O el módulo no se analizó: `--recursive` o `call_module_type = "local"` |
> | GitLab: el job termina al instante sin ejecutar nada (el original) | La imagen `hashicorp/terraform` tiene `terraform` como *entrypoint*: los comandos de shell no arrancan. `entrypoint: [""]` |
> | `curl … install_linux.sh | bash` en CI (el original) | Instala la última versión que haya ese día: el pipeline cambia sin que nadie toque nada. `setup-tflint@v4` con versión fijada, o el binario de una release concreta |
> | `terraform_version: latest`, `setup-terraform@v2` (el original) | Mismo problema; y `@v2` usa Node obsoleto. Fija la versión de Terraform igual que `required_version`, y `@v3` |
> | `on: [push, pull_request]` (el original) | Cada push a una rama con PR ejecuta el pipeline dos veces. `pull_request` más `push` solo a `main` |
> | "Success! The configuration is valid" y el apply falla | `validate` no habla con la API: nombres cogidos, regiones, cuotas, política. Es lo que atrapa el peldaño 6; ninguno anterior lo puede saber |
> | trivy señala algo que has decidido a conciencia | `.trivyignore` con el id, la razón en un comentario y `exp:` con fecha. Nunca `--severity CRITICAL` solo para que pase, ni quitar el paso |
> | trivy no encuentra nada en un fichero con TLS 1.0 | Está mirando otro directorio (`scan-ref`) o el hallazgo es `MEDIUM` y filtras `HIGH,CRITICAL`. Comprueba con `trivy config .` sin filtros |
> | Referencias a `tfsec` en guías antiguas | tfsec se integró en Trivy (2023) y está en mantenimiento. `trivy config`; los ids `AVD-AZU-*` son los mismos |
> | `terraform test` intenta conectarse a Azure en la prueba unitaria | Falta `mock_provider "azurerm" {}` en el `.tftest.hcl`, o el provider real está declarado en el test. Terraform ≥ 1.7 |
> | Aserción sobre un `id` falla con `mock_provider` | Los mocks devuelven valores ficticios para lo computado. Afirma sobre lo que *tú* configuras (TLS, tags) en la unitaria; los ids, en la de integración contra Topaz |
> | La prueba de integración deja recursos en Topaz | Falló a mitad y la destrucción no pudo completarse; Terraform lo avisa al final. `az group delete` del grupo de la prueba, o dar a cada run un nombre único para que no colisionen |
> | `expect_failures` no hace pasar la prueba | Debe apuntar exactamente a lo que falla: `var.nombre` para una `validation`, la dirección del recurso para una `precondition`. Y solo vale para condiciones tuyas, no para errores del provider |
> | El pipeline pasa y el apply destruye la base de datos | Ningún peldaño estático lo ve. Inspecciona el plan (`terraform show -json` y buscar `"delete"`) y exige aprobación humana para destrucciones ([página 12](index.md#pagina-12)). `prevent_destroy` como red ([página 7](index.md#pagina-7)) |
> | pre-commit tarda demasiado en cada commit | El hook de `validate` hace `init` por directorio. Deja en pre-commit fmt, tflint y trivy; validate y test en el pipeline. O `pre-commit run --all-files` solo antes del push |
> | `RequestDisallowedByPolicy` en el apply tras un pipeline verde | Azure Policy es una capa distinta y no se evalúa en el plan. Añade la regla equivalente en tflint/trivy o en una `validation` para que aparezca antes (bloque C) |

---

## 9. Autoevaluación

1. **¿Por qué se ordenan las comprobaciones por coste?**
   Un error cuesta más cuanto más tarde aparece. Las baratas (fmt, validate, tflint, trivy) corren en segundos sin nube; las caras (plan, test de integración) necesitan un endpoint y tiempo.
2. **¿Por qué `terraform validate` necesita `init` y por qué con `-backend=false`?**
   Comprueba contra el esquema del provider, que trae el binario descargado por `init`. `-backend=false` evita tocar el estado: sin credenciales.
3. **¿Qué acepta `validate` que no debería pasar?**
   Variables sin usar, interpolación obsoleta, TLS 1.0, NSG abierto, nombres que la API rechazará. Solo mira sintaxis, tipos y referencias.
4. **¿Qué añade el ruleset azurerm a tflint?**
   Reglas generadas de la API: tamaños de VM, SKUs, valores enumerados. Sin él, solo las reglas genéricas de Terraform.
5. **¿Qué significan los códigos de salida 0, 1 y 2 de tflint?**
   Sin hallazgos, error de la herramienta, hallazgos. El 1 suele ser "falta `--init`".
6. **¿Cómo se gestiona un falso positivo de trivy?**
   `.trivyignore` con el id, la razón y una fecha de caducidad. Nunca desactivando el paso ni subiendo el umbral.
7. **¿Qué atrapa el peldaño 5 que ninguno anterior puede?**
   Las reglas de tu equipo: un nombre en mayúsculas es un string válido, seguro y bien formateado; solo tu `validation` lo conoce.
8. **¿Cuál es la diferencia entre la prueba unitaria y la de integración en `terraform test`?**
   La unitaria usa `mock_provider` y `command = plan`: sin endpoint, milisegundos, afirma sobre lo configurado. La de integración aplica contra Topaz desde cero y destruye al terminar.
9. **¿Para qué sirve `expect_failures`?**
   Para probar que un contrato rechaza lo que debe: la prueba pasa si la `validation` o `precondition` indicada falla.
10. **¿Por qué el pipeline del original en GitLab no ejecutaba nada?**
    La imagen `hashicorp/terraform` tiene `terraform` como entrypoint; hace falta `entrypoint: [""]`.
11. **¿Por qué se fijan las versiones de Terraform y tflint en el pipeline?**
    Con `latest` el pipeline cambia sin que nadie toque el repositorio: no es reproducible y un fallo no se puede atribuir a un cambio.
12. **¿Qué comprueba el trabajo `topaz` que el estático no puede?**
    Lo que la API rechaza y qué acciones tiene el plan (ningún `delete` sin revisión), y que el módulo funciona desde cero. Sin tocar Azure.
13. **¿Qué papel tiene Azure Policy respecto a tflint y trivy?**
    Es la barrera de la plataforma: impide aunque el pipeline se salte. Pero actúa en el apply, tarde; las herramientas estáticas lo dicen antes y gratis. Se necesitan las dos capas.

---

## 10. Referencias

- [`terraform validate`](https://developer.hashicorp.com/terraform/cli/commands/validate), [`terraform fmt`](https://developer.hashicorp.com/terraform/cli/commands/fmt) e [`init -backend=false`](https://developer.hashicorp.com/terraform/cli/commands/init#backend-initialization) (HashiCorp)
- [Pruebas con `terraform test`](https://developer.hashicorp.com/terraform/language/tests), [`mock_provider`](https://developer.hashicorp.com/terraform/language/tests/mocking) y [`expect_failures`](https://developer.hashicorp.com/terraform/language/tests#expecting-failures)
- [Condiciones personalizadas](https://developer.hashicorp.com/terraform/language/expressions/custom-conditions): `validation`, `precondition`, `postcondition`
- [Formato JSON del plan](https://developer.hashicorp.com/terraform/internals/json-format) (`terraform show -json`, `resource_changes[].change.actions`)
- [tflint](https://github.com/terraform-linters/tflint), [configuración `.tflint.hcl`](https://github.com/terraform-linters/tflint/blob/master/docs/user-guide/config.md), [ruleset azurerm](https://github.com/terraform-linters/tflint-ruleset-azurerm) y [setup-tflint](https://github.com/terraform-linters/setup-tflint)
- [Trivy: escaneo de configuración](https://aquasecurity.github.io/trivy/latest/docs/scanner/misconfiguration/), [reglas `AVD-AZU-*`](https://avd.aquasec.com/misconfig/azure/) y [trivy-action](https://github.com/aquasecurity/trivy-action)
- [pre-commit-terraform](https://github.com/antonbabenko/pre-commit-terraform) y [terraform-docs](https://terraform-docs.io/)
- [setup-terraform](https://github.com/hashicorp/setup-terraform) y [subir SARIF a GitHub](https://docs.github.com/es/code-security/code-scanning/integrating-with-code-scanning/uploading-a-sarif-file-to-github)
- [GitLab CI: `image.entrypoint`](https://docs.gitlab.com/ee/ci/yaml/#imageentrypoint) y [IaC con Terraform en GitLab](https://docs.gitlab.com/ee/user/infrastructure/iac/)
- [Azure Policy](https://learn.microsoft.com/es-es/azure/governance/policy/overview) y [políticas integradas de Storage](https://learn.microsoft.com/es-es/azure/governance/policy/samples/built-in-policies#storage) (Microsoft Learn)
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)