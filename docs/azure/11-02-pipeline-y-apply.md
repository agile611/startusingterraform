# 🧾 Plan y apply en automatización: el fichero, las políticas y el fallo a medias

> La [página 13](index.md#pagina-13) construyó el pipeline alrededor de dos comandos sin abrirlos. Esta los abre. Un `plan` no es un texto en pantalla: es un fichero con el estado previo, la configuración completa, los valores de las variables y la lista exacta de acciones, y ese fichero solo se puede aplicar mientras nada haya cambiado. Un `apply` no es atómico: si falla el recurso ocho de doce, los siete anteriores existen y el estado lo sabe. Entender las dos cosas cambia cómo se diseña la automatización: qué se guarda, qué se compara, qué se comprueba antes de aplicar y qué se hace cuando la ejecución se rompe. La página recorre el contenido del plan con `terraform show -json`, las tres formas legítimas de separar plan y apply, las políticas que se evalúan sobre el JSON (con `jq`, con OPA y con `terraform test`), las salvaguardas en el código (`prevent_destroy`, precondiciones) y la recuperación de un apply parcial. Todo el laboratorio funciona en **Topaz**: son ficheros que Terraform produce y comandos que ejecuta contra el emulador.

**🎯 Objetivos de aprendizaje**
- Describir qué contiene un fichero de plan, quién puede leerlo y cuándo deja de ser aplicable.
- Leer el JSON del plan: acciones, valores antes/después, marcas sensibles y motivos de reemplazo.
- Elegir entre las tres formas de separar plan y apply y aplicar la comparación de planes para detectar cambios entre revisión y ejecución.
- Escribir políticas sobre el plan con `jq`, OPA/conftest y `terraform test`, y salvaguardas en el código.
- Recuperar un apply parcial, un `errored.tfstate` y un recurso *tainted*; usar `-replace` y `-target` solo como emergencia auditada.

> **🔷 Requisitos previos.** [Páginas 1](index.md#pagina-1) a 13 completadas y destruidas, backend `azurerm` de la [página 4](index.md#pagina-4) en Topaz, `~/tf-st/providers.tf`, Terraform `1.11.x`, `jq`, `unzip`, Docker (para conftest), `az account show --query environmentName -o tsv` → `Topaz`.

---

## 1. Qué hay dentro de un plan

`terraform plan` hace tres cosas en orden: **refresca** (lee cada recurso del estado en Azure para conocer su situación real), **compara** (configuración deseada contra situación real) y **ordena** (construye el grafo de acciones). Con `-out`, el resultado se guarda en un fichero que es, en realidad, un ZIP con cinco piezas.

| **Pieza** | **Contenido** | **Consecuencia** |
|---|---|---|
| `tfplan` | Acciones por recurso, valores planificados, **valores de todas las variables no efímeras**, versión de Terraform, hash del backend | El fichero es tan secreto como el estado ([página 10](index.md#pagina-10)) |
| `tfstate` | El estado previo refrescado, con *lineage* y *serial* | Si el estado remoto cambia de serial, el plan queda *stale* |
| `tfstate-prev` | El estado antes de refrescar | Permite mostrar la deriva detectada durante el plan |
| `tfconfig/` | Copia completa de los `.tf` y módulos | El apply no relee tu directorio: aplica lo que el plan capturó |
| `.terraform.lock.hcl` | Versiones y hashes de providers | El apply exige los mismos providers y la misma versión de Terraform |

```bash
# El JSON del plan: la interfaz para máquinas (comentarios en PR, políticas, comparaciones)
terraform show -json plan.tfplan | jq '{
  terraform_version, applyable, complete, errored,
  variables: (.variables | keys),                                # nombres; los valores están en .variables[].value
  cambios: [.resource_changes[] | select(.change.actions != ["no-op"]) | {address, actions: .change.actions, reason: .action_reason}]
}'
# Acciones posibles: ["no-op"] ["create"] ["read"] ["update"] ["delete"] ["delete","create"] ["create","delete"] ["forget"]
# Por qué se reemplaza: .change.replace_paths (el atributo que fuerza el reemplazo) y .action_reason ("replace_because_cannot_update", "replace_by_request" con -replace, "delete_because_no_resource_config"…)
terraform show -json plan.tfplan | jq '.resource_changes[] | select(.change.actions == ["delete","create"]) | {address, por: .change.replace_paths}'
# Lo sensible viene marcado aparte: .change.after_sensitive tiene true donde .change.after tiene un valor que no debe mostrarse
# Lo desconocido hasta el apply: .change.after_unknown (ids, fqdn…)

# Códigos de salida con -detailed-exitcode (página 13): 0 sin cambios · 1 error · 2 cambios
# La versión legible, sin color, con sensibles ocultos: el artefacto adecuado para un revisor humano
terraform show -no-color plan.tfplan > plan.txt
```

> **⚠️ Tres condiciones para que un plan siga siendo aplicable.** La misma versión de Terraform que lo creó; la misma configuración (el apply usa la copia interna, pero avisa si el directorio difiere); y, sobre todo, el mismo *serial* del estado remoto. Cualquier apply, import o `state mv` entre medias produce *Saved plan is stale*. No es un fallo del pipeline: es Terraform negándose a ejecutar decisiones tomadas sobre una realidad que ya no existe.

---

## 2. Qué hace el apply, y qué no

`terraform apply plan.tfplan` no replanifica ni pregunta: ejecuta el grafo del fichero, en paralelo (diez recursos a la vez por defecto), escribiendo el estado tras cada recurso. Por eso `-auto-approve` con un fichero de plan es redundante, y por eso un apply que falla a medias no deja "nada": deja todo lo que ya se creó, registrado.

```bash
terraform apply plan.tfplan                         # sin prompt; -auto-approve no hace nada aquí. -var no está permitido…
TF_VAR_api_key_sms="$(…)" terraform apply plan.tfplan   # …salvo para variables ephemeral, que no viajan en el plan y hay que volver a dar ([página 10](index.md#pagina-10))
terraform apply -lock-timeout=10m plan.tfplan       # espera el lease hasta 10 min en lugar de fallar al instante (no lo libera: [página 13](index.md#pagina-13))
terraform apply -parallelism=4 plan.tfplan          # menos concurrencia: útil con límites de API de Azure (429) o Topaz en una máquina pequeña
terraform apply -json plan.tfplan | jq -r 'select(.type == "apply_complete" or .type == "apply_errored") | "\(.hook.resource.addr): \(.type)"'
#   salida legible por máquinas, línea a línea: qué recurso terminó, cuál falló, cuánto tardó (.hook.elapsed_seconds)

# Sin fichero de plan: apply planifica y pide confirmación; -auto-approve la salta. Solo tiene sentido fuera del pipeline o en dev.
terraform apply -var-file=envs/dev.tfvars -auto-approve
```

| **Qué falla** | **Qué queda** | **Recuperación** |
|---|---|---|
| Un recurso (Azure devuelve error) | Los anteriores creados y en el estado; los dependientes no se intentan; el apply termina con código 1 | Corrige la causa y vuelve a planificar: el nuevo plan solo contiene lo que falta |
| Un provisioner | El recurso existe pero queda *tainted*: el siguiente plan lo reemplaza | Si el recurso está bien, `terraform untaint`; si no, deja que lo reemplace |
| La escritura del estado al backend | Terraform escribe `errored.tfstate` en el directorio y avisa | `terraform state push errored.tfstate`: el único caso en que `state push` es correcto |
| El runner (cancelado, perdido) | Estado parcial guardado hasta el último recurso completado; el lease queda tomado | `force-unlock` con el ID ([página 13](index.md#pagina-13)), luego plan: detecta lo creado que no llegó al estado solo si tiene `import`; revisa en Azure |

---

## 3. Separar plan y apply: tres formas, una comparación

El original separa plan y apply subiendo `tfplan` como artefacto y descargándolo en otro job. Eso tiene dos problemas ya vistos (el fichero contiene los secretos; caduca) y uno nuevo: el revisor aprueba mirando la pantalla del plan de la PR, pero lo que se aplica es otro plan, hecho después del merge. ¿Cómo se sabe que son iguales? Comparándolos.

| **Patrón** | **Cómo** | **Cuándo** |
|---|---|---|
| **Mismo job** ([página 13](index.md#pagina-13)) | `plan -out` y `apply` seguidos, detrás de la puerta del *environment*; el plan de la PR es solo para revisar | Por defecto. Sin artefactos, sin caducidad, compatible con variables efímeras |
| **Mismo job + comparación** | Antes de aplicar, se reduce el plan a una huella (direcciones + acciones) y se compara con la huella que la PR publicó; si difieren, el job se detiene | Producción: garantiza que lo aprobado es lo aplicado, aunque haya pasado tiempo o alguien tocara Azure |
| **Artefacto** (el original, bien hecho) | El fichero se cifra antes de subir (`age`, clave de Key Vault), retención de horas, misma versión de Terraform fijada, y el apply asume que puede estar *stale* | Solo si una norma exige aplicar el fichero exacto que se revisó. Incompatible con variables efímeras |

```bash
# Huella de un plan: qué recursos y qué acciones, sin valores (así se puede publicar en la PR sin filtrar nada)
huella() { terraform show -json "$1" | jq -S '[.resource_changes[] | select(.change.actions != ["no-op"]) | {address, actions: .change.actions, replace: .change.replace_paths}]'; }

# En el job de plan de la PR (página 13): la huella va al comentario y se guarda como output del check
huella plan.tfplan | tee huella.json | sha256sum | cut -c1-16      # p. ej. 3f9a1c…; el comentario de la PR la muestra

# En el job de apply: replanifica, calcula la huella y compárala con la aprobada (leída del comentario de la PR o del check)
terraform plan -var-file=envs/pro.tfvars -out=plan.tfplan -detailed-exitcode; code=$?
[ $code -eq 2 ] || exit $code
if [ "$(huella plan.tfplan | sha256sum)" != "$(cat huella_aprobada.sha)" ]; then
  echo "::error::El plan difiere del aprobado en la PR"; diff <(huella plan.tfplan) huella_aprobada.json; exit 1
fi
terraform apply plan.tfplan
# Diferencias legítimas (un id que ahora se conoce) no cambian la huella: solo direcciones y acciones. Una deriva sí la cambia: y eso es lo que quieres parar.
```

---

## 4. Políticas sobre el plan: lo que un revisor no debería tener que mirar

Un revisor humano detecta un cambio de talla mal pensado; no debería ser quien detecte que un plan borra la base de datos, abre un storage al público o crea un recurso sin etiquetas. Eso lo comprueba el pipeline sobre el JSON del plan, entre el `plan` y el `apply`, y lo bloquea. Hay tres herramientas, de menos a más formal, y una cuarta línea de defensa dentro del propio código.

```bash
# 1. jq: suficiente para tres o cuatro reglas
terraform show -json plan.tfplan > plan.json
jq -e '[.resource_changes[] | select(.change.actions | index("delete")) | select(.type | IN("azurerm_mysql_flexible_server","azurerm_storage_account","azurerm_key_vault"))] | length == 0' plan.json \
  || { echo "::error::El plan destruye un recurso con datos"; exit 1; }
jq -e '[.resource_changes[] | select(.change.actions | index("create") or index("update")) | select(.change.after.tags? != null) | select((.change.after.tags | has("proyecto") and has("entorno")) | not)] | length == 0' plan.json \
  || { echo "::error::Recursos sin tags obligatorias"; exit 1; }

# 2. OPA / conftest: reglas en Rego, versionadas junto al código, con tests propios. policy/moodle.rego:
#   package main
#   import rego.v1
#   datos := {"azurerm_mysql_flexible_server", "azurerm_storage_account", "azurerm_key_vault"}
#   deny contains msg if {
#     rc := input.resource_changes[_]; "delete" in rc.change.actions; rc.type in datos
#     msg := sprintf("%s: destruir un recurso con datos requiere un cambio separado y aprobado", [rc.address])
#   }
#   deny contains msg if {
#     rc := input.resource_changes[_]; rc.type == "azurerm_storage_account"; rc.change.after.allow_nested_items_to_be_public == true
#     msg := sprintf("%s: blobs públicos no permitidos", [rc.address])
#   }
#   warn contains msg if {
#     rc := input.resource_changes[_]; rc.change.actions == ["delete", "create"]
#     msg := sprintf("%s se reemplaza (%v): confirma que no hay datos dentro", [rc.address, rc.change.replace_paths])
#   }
docker run --rm -v "$PWD:/p" openpolicyagent/conftest test /p/plan.json -p /p/policy --all-namespaces   # deny → código 1; warn → aviso

# 3. terraform test (1.6+): aserciones sobre el plan con la sintaxis de Terraform, en tests/politicas.tftest.hcl
#   variables { entorno = "pro"  location = "eastus" }
#   run "pro_sin_borrados" {
#     command = plan
#     assert {
#       condition     = azurerm_storage_account.moodledata.shared_access_key_enabled == false
#       error_message = "moodledata debe tener las claves compartidas desactivadas"
#     }
#     assert {
#       condition     = alltrue([for k in ["proyecto", "entorno", "gestion"] : contains(keys(azurerm_resource_group.moodle.tags), k)])
#       error_message = "faltan tags obligatorias en el grupo de recursos"
#     }
#   }
terraform test                     # habla con el provider (Topaz): planifica de verdad, sin crear nada con command = plan

# 4. Dentro del código: la última línea, que actúa también fuera del pipeline
resource "azurerm_mysql_flexible_server" "moodle" {
  # …
  lifecycle {
    prevent_destroy = true                        # el plan que lo borraría falla: "Instance cannot be destroyed"
    precondition {
      condition     = var.entorno != "pro" || var.mysql_sku != "B_Standard_B1ms"
      error_message = "En pro no se admite la talla Burstable B1ms."
    }
  }
}
check "backups_pro" {                             # check: avisa sin bloquear; para lo que quieres saber pero no impedir
  assert {
    condition     = var.entorno != "pro" || azurerm_mysql_flexible_server.moodle.geo_redundant_backup_enabled
    error_message = "Pro sin backup georredundante."
  }
}
```

> **🔷 Cuál elegir.** `jq` para empezar hoy con dos reglas en el propio workflow. Conftest cuando las reglas son más de cinco, las comparten varios repositorios o alguien pregunta "¿dónde está escrito que no se puede?". `terraform test` para lo que depende de tus variables y módulos, porque habla el mismo lenguaje que el código. `prevent_destroy` y las precondiciones, siempre: protegen también al que ejecuta `destroy` desde su portátil un viernes.

---

## 5. Emergencias: `-replace`, `-target` y el retroceso

El original propone `-target` para "probar cambios específicos" y ordenar los recursos en el fichero para resolver dependencias. Lo segundo no hace nada: HCL es declarativo y el orden lo dan las referencias entre recursos (y `depends_on` cuando la dependencia no es visible en un atributo). Lo primero es una herramienta de emergencia: aplica un subconjunto del grafo y deja el resto sin reconciliar, con la advertencia *Resource targeting is in effect*. Tiene su sitio, pero no en el flujo normal.

```bash
# Reemplazar un recurso que está corrupto pero cuya configuración no ha cambiado (una VM que no arranca)
terraform plan -replace=azurerm_linux_virtual_machine_scale_set.web -out=plan.tfplan     # action_reason: "replace_by_request"

# Aplicar solo una parte, porque el resto del plan está bloqueado por algo ajeno (un límite de cuota) y hay que sacar un arreglo ya
terraform plan -target=azurerm_key_vault_secret.sms -out=plan.tfplan
#   Warning: Resource targeting is in effect … The -target option is not for routine use
#   Después, obligatorio: un plan completo sin -target, para que el estado vuelva a coincidir con el código.

# En el pipeline, las emergencias entran por workflow_dispatch con inputs, quedan en el log con quién y por qué, y pasan por el mismo environment:
#   on: { workflow_dispatch: { inputs: { replace: { description: "Dirección a reemplazar" }, motivo: { required: true } } } }
#   run: terraform plan ${{ inputs.replace && format('-replace={0}', inputs.replace) || '' }} -out=plan.tfplan …

# Retroceder un cambio: revertir el commit y dejar que el pipeline aplique. NUNCA terraform state push de un estado antiguo:
# el estado describe lo que existe, no lo que quieres; empujar uno viejo hace que Terraform crea que recursos reales no existen (y los recree) o que existen (y falle).
git revert <sha> && git push          # → PR → plan (deshace exactamente lo que el commit hizo) → aprobación → apply

# Un arreglo manual urgente en el portal: primero reconoce la deriva, después decide
terraform plan -refresh-only               # muestra lo que cambió fuera; apply -refresh-only acepta esos valores en el estado sin tocar Azure
#   Si el cambio se queda: llévalo al código. Si no: el siguiente apply normal lo revierte.
```

---

## 6. Laboratorio en Topaz

Todo el laboratorio ocurre entre ficheros que Terraform produce y el emulador: se abre un plan, se comparan dos, se caduca uno, se evalúan políticas con `jq`, conftest y `terraform test`, se provoca un apply parcial con un provisioner que falla y se recupera, y se prueban `prevent_destroy` y `-replace`.

```bash
mkdir -p ~/tf-plan/{policy,tests} && cd ~/tf-plan && cp ~/tf-st/providers.tf .

# ─── 1. Código con salvaguardas y un fallo provocado ─────────────────────────────
cat > main.tf <<'EOF'
variable "entorno"  { type = string, default = "dev" }
variable "location" { type = string, default = "eastus" }
variable "fallar"   { type = bool,   default = false }
variable "publico"  { type = bool,   default = false }
locals { tags = { proyecto = "moodle", entorno = var.entorno, gestion = "terraform" } }
resource "azurerm_resource_group" "lab" { name = "rg-plan-lab-${var.entorno}", location = var.location, tags = local.tags }
resource "azurerm_storage_account" "datos" {
  name = "stplan${substr(md5(azurerm_resource_group.lab.id), 0, 8)}"
  resource_group_name = azurerm_resource_group.lab.name, location = azurerm_resource_group.lab.location
  account_tier = "Standard", account_replication_type = "LRS", min_tls_version = "TLS1_2", shared_access_key_enabled = false
  allow_nested_items_to_be_public = var.publico
  tags = local.tags
  lifecycle {
    prevent_destroy = true
    precondition { condition = var.entorno != "pro" || !var.publico, error_message = "En pro no se admiten blobs públicos." }
  }
}
resource "terraform_data" "post" {                        # simula un paso posterior que puede fallar en el apply (no en el plan)
  triggers_replace = [var.fallar]
  provisioner "local-exec" { command = var.fallar ? "echo 'fallo simulado' && exit 1" : "echo ok" }
  depends_on = [azurerm_storage_account.datos]
}
check "tls" { assert { condition = azurerm_storage_account.datos.min_tls_version == "TLS1_2", error_message = "El TLS mínimo debe ser 1.2." } }
output "storage" { value = azurerm_storage_account.datos.name }
EOF
cat > policy/moodle.rego <<'EOF'
package main
import rego.v1
datos := {"azurerm_mysql_flexible_server", "azurerm_storage_account", "azurerm_key_vault"}
deny contains msg if {
  rc := input.resource_changes[_]
  "delete" in rc.change.actions
  rc.type in datos
  msg := sprintf("%s: destruir un recurso con datos requiere un cambio separado y aprobado", [rc.address])
}
deny contains msg if {
  rc := input.resource_changes[_]
  rc.type == "azurerm_storage_account"
  rc.change.after.allow_nested_items_to_be_public == true
  msg := sprintf("%s: blobs públicos no permitidos", [rc.address])
}
warn contains msg if {
  rc := input.resource_changes[_]
  rc.change.actions == ["delete", "create"]
  msg := sprintf("%s se reemplaza (%v): confirma que no hay datos dentro", [rc.address, rc.change.replace_paths])
}
EOF
cat > tests/politicas.tftest.hcl <<'EOF'
run "pro_seguro" {
  command   = plan
  variables { entorno = "pro" }
  assert {
    condition     = azurerm_storage_account.datos.shared_access_key_enabled == false
    error_message = "Las claves compartidas deben estar desactivadas."
  }
  assert {
    condition     = alltrue([for k in ["proyecto", "entorno", "gestion"] : contains(keys(azurerm_resource_group.lab.tags), k)])
    error_message = "Faltan tags obligatorias."
  }
}
run "pro_publico_rechazado" {
  command         = plan
  variables       { entorno = "pro", publico = true }
  expect_failures = [azurerm_storage_account.datos]     # la precondition debe fallar: el test pasa si el plan falla ahí
}
EOF
terraform init >/dev/null

# ─── 2. Abrir un plan ─────────────────────────────────────────────────────────────
terraform plan -out=plan.tfplan >/dev/null
mkdir -p /tmp/plan && unzip -oq plan.tfplan -d /tmp/plan && ls -A /tmp/plan          # tfplan tfstate tfstate-prev tfconfig/ .terraform.lock.hcl
ls /tmp/plan/tfconfig                                                                # tu main.tf, copiado: el apply usa esto, no tu directorio
terraform show -json plan.tfplan | jq '{terraform_version, applyable, variables, cambios: [.resource_changes[] | {address, actions: .change.actions}]}'
#   variables: {"entorno":{"value":"dev"}, "fallar":{"value":false}, …}  ← con valor. Un tfvars con contraseña estaría aquí (página 10)
terraform show -json plan.tfplan | jq '.resource_changes[] | select(.address == "azurerm_storage_account.datos") | .change.after_unknown | keys'
#   ["id","primary_blob_endpoint",…]: lo que solo se sabe tras el apply
terraform show -no-color plan.tfplan | head -20                                      # la versión para humanos, sensibles ocultos

# ─── 3. Dos planes, una huella ────────────────────────────────────────────────────
huella() { terraform show -json "$1" | jq -S '[.resource_changes[] | select(.change.actions != ["no-op"]) | {address, actions: .change.actions, replace: .change.replace_paths}]'; }
huella plan.tfplan | tee huella_aprobada.json | sha256sum | cut -c1-16              # lo que la PR publicaría
terraform plan -out=plan2.tfplan >/dev/null                                          # el plan del job de apply, minutos después
diff <(huella plan.tfplan) <(huella plan2.tfplan) && echo "misma huella: lo aprobado es lo que se aplica"

# ─── 4. Caducidad ────────────────────────────────────────────────────────────────
terraform apply plan2.tfplan                                                         # sin prompt: el fichero ya es la decisión
terraform apply plan.tfplan
#   Error: Saved plan is stale — el serial del estado cambió con el apply anterior. El "artefacto" del original moriría aquí.
terraform plan -detailed-exitcode >/dev/null; echo "código: $?"                     # 0: nada pendiente

# ─── 5. Políticas: jq, conftest, terraform test ──────────────────────────────────
terraform plan -var publico=true -out=malo.tfplan >/dev/null && terraform show -json malo.tfplan > malo.json
jq -e '[.resource_changes[] | select(.type == "azurerm_storage_account") | select(.change.after.allow_nested_items_to_be_public == true)] | length == 0' malo.json \
  || echo "jq: bloqueado (blobs públicos)"
docker run --rm -v "$PWD:/p" openpolicyagent/conftest test /p/malo.json -p /p/policy --all-namespaces
#   FAIL - … azurerm_storage_account.datos: blobs públicos no permitidos   (1 test, 1 failure) → código 1
terraform plan -destroy -var publico=false -out=borra.tfplan 2>/dev/null || true    # falla por prevent_destroy (paso 7); la política de conftest lo pararía igual
terraform test
#   run "pro_seguro"… pass · run "pro_publico_rechazado"… pass   (la precondition falló como se esperaba)
#   Ninguno creó nada: command = plan planifica contra Topaz y descarta.

# ─── 6. Apply a medias y recuperación ────────────────────────────────────────────
terraform apply -var fallar=true -auto-approve
#   azurerm_storage_account.datos: (sin cambios)
#   terraform_data.post: Provisioning with 'local-exec'… fallo simulado
#   Error: local-exec provisioner error … Apply no termina con "complete": código 1
terraform state list                                                                 # el storage sigue ahí; terraform_data.post también, marcado
terraform state show terraform_data.post | head -3                                   # "# terraform_data.post: (tainted)"
terraform plan -var fallar=true -no-color | grep -E "tainted|must be replaced"      # el siguiente plan lo reemplaza
terraform untaint terraform_data.post                                                # si el recurso estuviera bien: se levanta la marca
terraform plan -var fallar=false -out=fix.tfplan >/dev/null && terraform apply fix.tfplan   # el arreglo solo toca lo que faltaba
terraform apply -json -var fallar=false -auto-approve | jq -r 'select(.type == "apply_complete" or .type == "apply_errored") | "\(.hook.resource.addr): \(.type) (\(.hook.elapsed_seconds // 0)s)"'
#   salida por recurso, legible por máquinas: lo que un dashboard de despliegues consume
# errored.tfstate no se puede provocar en Topaz sin apagar el emulador a mitad de apply; se ve en el bloque de Azure real.

# ─── 7. Salvaguardas y emergencias ───────────────────────────────────────────────
terraform plan -destroy
#   Error: Instance cannot be destroyed — azurerm_storage_account.datos has lifecycle.prevent_destroy set … 
terraform plan -var entorno=pro -var publico=true
#   Error: Resource precondition failed — En pro no se admiten blobs públicos.
terraform plan -replace=terraform_data.post -out=rep.tfplan >/dev/null && terraform show -json rep.tfplan | jq -r '.resource_changes[] | select(.address == "terraform_data.post") | .action_reason'
#   replace_by_request
terraform plan -target=terraform_data.post -no-color 2>&1 | grep -A3 "Warning: Resource targeting"
#   "…The -target option is not for routine use, and is provided only for exceptional situations…"
terraform plan -refresh-only -detailed-exitcode >/dev/null; echo "deriva: $?"       # 0 ahora; 2 tras tocar algo con az ([página 13](index.md#pagina-13))

# ─── 8. Limpiar ──────────────────────────────────────────────────────────────────
sed -i 's/prevent_destroy = true/prevent_destroy = false/' main.tf                   # la salvaguarda protege también de este comando: hay que quitarla a propósito
terraform destroy -auto-approve
rm -f *.tfplan *.json huella_aprobada.json && rm -rf /tmp/plan
```

```bash
# ─── Solo Azure real ────────────────────────────────────────────────────────────
# A. errored.tfstate: el recurso se created, el estado no se puede escribir. Provócalo quitando el rol sobre el contenedor durante un apply largo:
az role assignment delete --assignee <principal_id de id-moodle-tf> --role "Storage Blob Data Contributor" --scope <id del contenedor tfstate>
#   (en otra terminal, mientras corre el apply)
#   Error: Failed to save state … Terraform wrote the state to errored.tfstate …
az role assignment create --assignee … --role "Storage Blob Data Contributor" --scope …
terraform state push errored.tfstate                # el único state push legítimo; luego terraform plan debe dar 0 cambios
rm errored.tfstate

# B. Límites de la API de Azure: applies con muchos recursos devuelven 429 TooManyRequests; el provider reintenta, pero el tiempo se dispara
terraform apply -parallelism=5 -json plan.tfplan | jq -r 'select(.type == "diagnostic") | .diagnostic.summary' | sort | uniq -c
#   Si aparecen reintentos, baja la concurrencia en el pipeline y divide el cambio en PRs más pequeñas.

# C. Políticas en el pipeline (página 13), entre plan y apply, en el mismo job:
#   - run: terraform show -json plan.tfplan > plan.json && docker run --rm -v "$PWD:/p" openpolicyagent/conftest test /p/plan.json -p /p/policy --all-namespaces
#   - run: terraform test
#   Y la huella del plan de la PR guardada como output del check; el apply la compara antes de ejecutar (14.3).
```

---

## 7. Errores comunes

> ⚠️ **Solución de problemas**
>
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | *Saved plan is stale* | El serial del estado cambió entre plan y apply (otro apply, un import, un `state mv`). Plan y apply en el mismo job; el plan de la PR es para revisar. Si necesitas garantía de identidad, la huella (14.3) |
> | *The plan file was created by Terraform v1.11.4 but this is v1.12.x* | Versiones distintas entre jobs (`terraform_version: latest`). Una sola variable `TF_VERSION` y `required_version` en el código ([página 13](index.md#pagina-13)) |
> | *Can't set variables when applying a saved plan* | Las variables ya están dentro del fichero; `-var` no se admite. La excepción son las `ephemeral`, que no viajan y hay que volver a dar por `TF_VAR_` ([página 10](index.md#pagina-10)) |
> | `-auto-approve` junto a un fichero de plan, o `deployInputs: {"autoApprove": false}` (el original) | Aplicar un fichero de plan nunca pregunta: `-auto-approve` es redundante y `deployInputs` no existe en `TerraformTaskV4`. La aprobación es del pipeline (*environment*), no del comando |
> | `tfplan` subido con `upload-artifact` y descargado en otro job | Contiene los valores de todas las variables no efímeras y el estado previo: es un secreto descargable y, además, caduca. Mismo job; si una norma exige el fichero exacto, cifrado y con retención de horas (14.3) |
> | `terraform init && terraform validate` falla en el job de validación sin credenciales | `init` intenta conectar al backend. Para validar sin tocar Azure: `init -backend=false` |
> | *Error: Instance cannot be destroyed … prevent_destroy* en un destroy legítimo | Está haciendo su trabajo. Quita la marca en un commit propio (que pasa por la PR y queda auditado), aplica, y vuelve a ponerla si el recurso sigue existiendo. Nunca `-target` para esquivarla |
> | *Resource precondition failed* en un entorno donde no debería aplicar | La condición no distingue entornos. Formúlala como implicación: `var.entorno != "pro" || <regla>` |
> | El apply falla en el recurso 8 de 12 y "no se ha creado nada" | Sí se ha creado: los siete anteriores están en el estado. No borres nada a mano: corrige la causa y planifica; el nuevo plan solo contiene lo que falta |
> | *… is tainted, so must be replaced* | Un provisioner falló tras crear el recurso. Si el recurso es correcto, `terraform untaint`; si no, deja que el plan lo reemplace. Y plantéate si ese provisioner debería ser cloud-init o una extensión ([página 15](index.md#pagina-15)) |
> | *Failed to save state … wrote the state to errored.tfstate* | Los recursos se crearon pero el backend no aceptó la escritura (rol quitado, token caducado, red). Restaura el acceso y `terraform state push errored.tfstate`: el único `state push` correcto. Comprueba con un plan a 0 |
> | "Retroceder" con `state push` de un estado antiguo | El estado describe lo que existe, no lo que quieres: un estado viejo hace que Terraform recree recursos que existen o dé por existentes los que no. Retroceso = `git revert` → PR → plan → apply |
> | "Ordena los recursos en el fichero para arreglar dependencias" (el original) | HCL es declarativo: el orden lo dan las referencias entre atributos. Si la dependencia no aparece en ningún atributo (una asignación de rol que debe existir antes del cloud-init), `depends_on` |
> | `-target` en el flujo normal "para probar" | Deja el estado sin reconciliar con el código y Terraform lo advierte. Solo emergencias, por `workflow_dispatch` con motivo, y siempre seguido de un plan completo |
> | `terraform refresh` (el original) | Retirado. `plan -refresh-only` muestra la deriva; `apply -refresh-only` la acepta en el estado sin tocar Azure |
> | "Timeout en el pipeline para liberar locks" (el original) | `-lock-timeout` espera, no libera. El lease lo libera el proceso que lo tomó o `force-unlock` con su ID tras confirmar que ese proceso murió ([página 13](index.md#pagina-13)) |
> | conftest no encuentra las reglas o pasa todo | Las reglas van en `package main` o hay que pasar `--all-namespaces`; `deny` falla el test, `warn` solo avisa. Prueba la política contra un plan que sabes que debe fallar, como en el laboratorio |
> | `terraform test` crea recursos reales | Sin `command = plan`, el `run` hace apply (y destroy al final). Para políticas sobre el plan, siempre `command = plan` |
> | *429 TooManyRequests* en applies grandes | Límites de la API de Azure con diez operaciones en paralelo. `-parallelism=5` y cambios más pequeños; el provider reintenta pero el tiempo crece |
> | En Topaz: no hay 429, `errored.tfstate` no se puede provocar, el apply es demasiado rápido para cancelarlo | Esperado: el emulador no impone límites ni tiene identidades a las que quitar roles. Todo lo demás de la página (plan, huella, caducidad, políticas, taint, prevent_destroy, replace) funciona igual que en Azure |

---

## 8. Autoevaluación

1. **¿Qué cinco piezas contiene un fichero de plan y cuál lo convierte en secreto?**
   `tfplan`, `tfstate`, `tfstate-prev`, `tfconfig/` y `.terraform.lock.hcl`. El `tfplan` incluye los valores de todas las variables no efímeras, y el `tfstate` es el estado completo.
2. **¿Qué tres condiciones debe cumplir un plan para seguir siendo aplicable?**
   Misma versión de Terraform, misma configuración y mismo serial del estado remoto. Si el serial cambia: *Saved plan is stale*.
3. **¿Por qué `terraform apply plan.tfplan -auto-approve` es redundante?**
   Aplicar un fichero de plan nunca pide confirmación: el fichero ya es la decisión. La aprobación pertenece al pipeline.
4. **¿Qué es la huella de un plan y qué problema resuelve?**
   La lista de direcciones, acciones y rutas de reemplazo, sin valores. Permite comprobar que el plan que se aplica tras el merge es el mismo que se aprobó en la PR, sin filtrar nada.
5. **¿Cuándo es legítimo subir el plan como artefacto?**
   Solo si una norma exige aplicar el fichero exacto revisado; entonces cifrado, con retención corta, misma versión fijada y asumiendo que puede caducar. Nunca con variables efímeras.
6. **Un apply falla en el recurso 8 de 12. ¿Qué existe y qué haces?**
   Los siete anteriores existen y están en el estado; los dependientes no se intentaron. Corregir la causa y planificar: el nuevo plan solo contiene lo pendiente.
7. **¿Qué significa *tainted* y cuándo usas `untaint`?**
   Un provisioner falló tras crear el recurso; el siguiente plan lo reemplazará. `untaint` si has verificado que el recurso está bien y solo falló el paso posterior.
8. **¿Cuál es el único caso en que `terraform state push` es correcto?**
   Tras *Failed to save state*, empujando el `errored.tfstate` que Terraform acaba de escribir, una vez restaurado el acceso al backend.
9. **¿Cómo se retrocede un cambio y por qué no con un estado antiguo?**
   `git revert` → PR → plan → apply. Un estado antiguo describe una realidad que ya no existe: Terraform recrearía recursos existentes o fallaría sobre los que faltan.
10. **¿Qué diferencia hay entre `jq`, conftest y `terraform test` como políticas?**
    `jq` para dos o tres reglas dentro del workflow; conftest cuando las reglas son muchas, compartidas y necesitan sus propios tests; `terraform test` para reglas que dependen de tus variables y módulos, en el lenguaje del código.
11. **¿Qué aportan `prevent_destroy` y las precondiciones que las políticas del pipeline no aportan?**
    Actúan también fuera del pipeline: protegen al que ejecuta `destroy` o un plan desde su portátil.
12. **¿Cuándo son aceptables `-replace` y `-target`?**
    Como emergencia auditada: entran por `workflow_dispatch` con motivo, pasan por el mismo *environment*, y a `-target` le sigue siempre un plan completo para reconciliar el estado.

---

## 9. Referencias

- [`terraform plan`](https://developer.hashicorp.com/terraform/cli/commands/plan) (`-out`, `-detailed-exitcode`, `-refresh-only`, `-replace`, `-target`) y [`terraform apply`](https://developer.hashicorp.com/terraform/cli/commands/apply) (`-parallelism`, `-json`, `-lock-timeout`)
- [Formato JSON de planes y estado](https://developer.hashicorp.com/terraform/internals/json-format) (`resource_changes`, `action_reason`, `after_sensitive`, `after_unknown`) y [salida legible por máquinas](https://developer.hashicorp.com/terraform/internals/machine-readable-ui) (`apply -json`)
- [`terraform show`](https://developer.hashicorp.com/terraform/cli/commands/show), [`taint`/`untaint`](https://developer.hashicorp.com/terraform/cli/commands/taint) y [`state push`](https://developer.hashicorp.com/terraform/cli/commands/state/push) (caso `errored.tfstate`)
- [Meta-argumento `lifecycle`](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle) (`prevent_destroy`, `precondition`, `postcondition`) y [bloques `check`](https://developer.hashicorp.com/terraform/language/checks)
- [`terraform test`](https://developer.hashicorp.com/terraform/language/tests) (`command = plan`, `expect_failures`)
- [conftest](https://www.conftest.dev/) y [OPA con planes de Terraform](https://www.openpolicyagent.org/docs/latest/terraform/)
- [Terraform en automatización](https://developer.hashicorp.com/terraform/tutorials/automation/automate-terraform) (plan y apply separados, `TF_IN_AUTOMATION`)
- [Límites de la API de Azure Resource Manager](https://learn.microsoft.com/es-es/azure/azure-resource-manager/management/request-limits-and-throttling) (429)
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)