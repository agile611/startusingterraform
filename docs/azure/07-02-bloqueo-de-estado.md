# 🔒 Bloqueo del estado

## 1. Cómo bloquea el backend azurerm

El proceso de bloqueo sigue una secuencia estricta para garantizar que nadie más modifique el estado mientras se evalúan o aplican cambios.

```text
terraform apply
   │
   ├─ 1. Lock()      → PUT lease (duración infinita) sobre tfstate/app/lab.tfstate
   │                  → PUT metadata terraformlockid = base64({ID, Operation, Who, Version, Created, Path})
   │                    si el lease ya existe → "Error acquiring the state lock" + Lock Info del metadato
   ├─ 2. GET estado  → lee el blob (con el lease-id)
   ├─ 3. plan        → "Do you want to perform these actions?"   ◄── el lock sigue tomado mientras piensas
   ├─ 4. apply       → cambios en Azure
   ├─ 5. PUT estado  → escribe el blob (serial + 1; snapshot si snapshot = true)
   └─ 6. Unlock()    → DELETE metadata, release lease
```

Aquí tienes una clasificación clara de qué comandos interactúan con el bloqueo:

| **Toman el bloqueo** | **No lo toman (solo leen)** |
|---|---|
| `plan`, `apply`, `destroy`, `refresh`, `import`, `state mv/rm/push/replace-provider`, `init -migrate-state`, `test` (runs con apply) | `state list`, `state show`, `state pull`, `output`, `show`, `validate`, `fmt`, `graph` |

> ⚠️ **El lease manual del original bloquea a Terraform, no a los demás.** Los scripts `apply_lock.sh` creaban un lease sobre el blob y después lanzaban `terraform apply`. Terraform intenta su propio lease, lo encuentra ocupado y falla: *state blob is already locked*, y sin Lock Info porque nadie escribió el metadato. Además, ninguno de esos comandos existe tal como estaban: `az storage blob lease create` es `lease acquire`, `lease list` no existe (se consulta con `blob show`) y `--lease-duration 3600` es inválido: Azure solo admite 15-60 segundos o -1 (infinito). El bloqueo correcto es no hacer nada: el backend lo gestiona.

---

## 2. Anatomía de un bloqueo

Cuando Terraform no puede adquirir el bloqueo, devuelve un mensaje detallado. Leer este mensaje es clave para saber cómo actuar.

```text
│ Error: Error acquiring the state lock
│
│ Error message: state blob is already locked
│ Lock Info:
│   ID:        1f6c3a2e-9b1d-4c0e-8a7f-2d5e6b8c9a01   ◄── lo único que acepta force-unlock
│   Path:      tfstate/app/lab.tfstate                 ◄── qué estado (contenedor/key)
│   Operation: OperationTypeApply                      ◄── plan, apply, destroy, migration…
│   Who:       ana@portatil-ana                        ◄── usuario@host del proceso: a quién preguntar
│   Version:   1.9.5
│   Created:   2026-09-10 13:04:11.418 +0000 UTC       ◄── hace 2 minutos: espera. Hace 2 días: huérfano
│   Info:
│
│ Terraform acquires a state lock to protect the state from being written
│ by multiple users at the same time. Please resolve the issue above and try
│ again. For most commands, you can disable locking with the "-lock=false"
│ flag, but this is not recommended.
```

| **Lo que dice Lock Info** | **Decisión** |
|---|---|
| `Created` reciente, `Who` es una persona o el pipeline | Esperar. `terraform plan -lock-timeout=5m` reintenta solo. Si es una persona, pregúntale: puede estar delante de "Do you want to perform these actions?" |
| `Who` eres tú en este mismo host, y no tienes ningún terraform abierto | Un proceso murió sin liberar (Ctrl+C dos veces, terminal cerrada, agente cancelado). `terraform force-unlock <ID>` |
| `Created` de hace horas y `Who` es un runner de CI (`runner@fv-az123`) | Job cancelado o runner destruido. Comprueba en la plataforma que no hay ejecuciones activas y `force-unlock` |
| Sin Lock Info: solo *already locked* o *LeaseAlreadyPresent* | Alguien creó el lease fuera de Terraform (los scripts del original). `az storage blob lease break` |

> **🔷 `-lock=false` no es una solución.** Desactiva la comprobación: el comando se ejecuta como si nadie más estuviera trabajando. Tiene un único uso legítimo: un `plan` de solo lectura en la PR de CI, donde no se escribe estado y no se quiere esperar al `apply` de otra rama. En `apply`, `destroy` o cualquier comando `state` es la causa directa del estado corrupto que la página del original decía querer evitar.

---

## 3. Laboratorio en Topaz: el backend local también bloquea

El backend local bloquea con un `flock` del sistema operativo y escribe el mismo Lock Info en un archivo `.<nombre>.lock.info` junto al estado. Misma interfaz, mismo mensaje, mismo `force-unlock`. Retoma el proyecto de la [página 7](index.md#pagina-7):

```bash
cd ~/tf-estado/app && mkdir -p estados
cat > backend.tf <<'EOF'
terraform { backend "local" { path = "estados/app-lab.tfstate" } }
EOF
terraform init -reconfigure && terraform apply -auto-approve      # 4 to add (grupo, vnet, 2 subredes; main.tf de la [página 7](index.md#pagina-7))

# ─── 1. Provocar el bloqueo ─────────────────────────────────────────────────────
# Terminal A:
terraform apply                                       # se queda en "Do you want to perform these actions?": NO respondas
# Terminal B:
cd ~/tf-estado/app
ls -a estados/                                        # app-lab.tfstate  .app-lab.tfstate.lock.info   ◄── existe mientras A tiene el lock
jq . estados/.app-lab.tfstate.lock.info               # {"ID": "…", "Operation": "OperationTypeApply", "Who": "root@terraform00", "Created": "…"}
terraform plan
#   Error: Error acquiring the state lock
#   Error message: resource temporarily unavailable      ◄── el flock; en azurerm diría "state blob is already locked"
#   Lock Info: ID … Who: root@terraform00 …
terraform state list                                  # funciona: los comandos de lectura no bloquean
terraform plan -lock=false                            # funciona: y por eso es peligroso en apply

# ─── 2. Esperar en vez de fallar ────────────────────────────────────────────────
# Terminal B:
terraform plan -lock-timeout=2m                       # "Acquiring state lock. This may take a few moments…" y reintenta
# Terminal A: responde  no
# Terminal B continúa solo en cuanto A libera. Es lo que usará el pipeline (8.5)

# ─── 3. Un proceso colgado (no muerto): simula un agente congelado ──────────────
# Terminal A:
terraform apply &                                     # en segundo plano; se para a esperar la confirmación
kill -STOP %1                                         # congela el proceso: tiene el lock y no lo soltará
# Terminal B:
terraform plan                                        # bloqueado, Lock Info con Who = tú
ps -ef | grep '[t]erraform apply'                     # el proceso EXISTE: no es huérfano. force-unlock sería un error
# Terminal A:
kill -CONT %1 && fg                                   # descongela; responde  no

# ─── 4. force-unlock: solo con el ID ────────────────────────────────────────────
# Terminal A: terraform apply  (deja la pregunta abierta)
# Terminal B:
ID=$(jq -r .ID estados/.app-lab.tfstate.lock.info)
terraform force-unlock "$ID"                          # pide confirmación: "yes". El archivo .lock.info desaparece
terraform force-unlock 00000000-0000-0000-0000-000000000000   # ID equivocado: "lock ID does not match": la salvaguarda
# Terminal A: responde  no  → Terraform intenta liberar un lock que ya no es suyo y avisa: "Failed to unlock state"
# En azurerm el efecto es idéntico: el lease se rompe y el metadato se borra. La operación de A, si siguiera,
# fallaría al escribir porque su lease-id ya no es válido: el estado no se corrompe, pero A termina con error.

# ─── 5. Lo que el local NO reproduce: el bloqueo huérfano ───────────────────────
terraform apply & sleep 3; kill -9 %1                 # muerte súbita
terraform plan                                        # FUNCIONA: el SO liberó el flock al morir el proceso
# En azurerm, el lease infinito sobrevive al proceso: es exactamente el caso que requiere force-unlock (8.4)

terraform destroy -auto-approve
```

---

## 4. Azure real: ver, romper y no crear leases

En un entorno real con Azure Storage, las herramientas de CLI te permiten inspeccionar y gestionar el estado del *lease* directamente.

```bash
# Con el backend azurerm de la página 7 (use_azuread_auth = true, claves desactivadas en la cuenta)
ST=sttfstateXXXXXXXX; BLOB=app/lab.tfstate

# Ver el bloqueo desde fuera mientras otro apply espera confirmación
az storage blob show --account-name $ST -c tfstate -n $BLOB --auth-mode login \
  --query "{lease:properties.lease.status, duracion:properties.lease.duration, lock:metadata.terraformlockid}" -o table
#   lease = locked, duracion = infinite, lock = eyJJRCI6…
az storage blob show --account-name $ST -c tfstate -n $BLOB --auth-mode login \
  --query metadata.terraformlockid -o tsv | base64 -d | jq .        # el Lock Info completo: ID, Who, Created

# Bloqueo huérfano (agente cancelado, portátil apagado). Orden: confirmar → force-unlock → si falla, romper el lease
terraform force-unlock <ID>                                          # 1º: usa el backend, limpia lease y metadato
az storage blob lease break --account-name $ST -c tfstate -b $BLOB --auth-mode login   # 2º: si force-unlock no puede
az storage blob metadata update --account-name $ST -c tfstate -n $BLOB --auth-mode login --metadata ""   # y quita el metadato

# El experimento del original, para ver por qué está mal
az storage blob lease acquire --account-name $ST -c tfstate -b $BLOB --auth-mode login --lease-duration 60
terraform plan                                                      # Error acquiring the state lock: state blob is already locked (sin Lock Info)
sleep 60 && terraform plan                                          # el lease de 60 s caducó: vuelve a funcionar
# Con --lease-duration -1 (infinito), como hacían los scripts, solo lo arregla "lease break"

# Quién bloqueó qué y cuándo: los logs de diagnóstico de la página 7 registran las operaciones de lease
# KQL: StorageBlobLogs | where OperationName == "LeaseBlob" and ObjectKey endswith "lab.tfstate"
#      | project TimeGenerated, RequesterUpn, StatusCode, LeaseAction = tostring(parse_json(Uri))
```

A continuación, una comparativa para entender qué protege cada mecanismo:

| **Mecanismo** | **Protege contra** | **No protege contra** |
|---|---|---|
| Lease del blob (bloqueo del estado) | Dos operaciones de escritura simultáneas sobre el mismo estado | Borrar el blob, la cuenta o el grupo; aplicar un plan obsoleto; dos proyectos que gestionan el mismo recurso |
| `azurerm_management_lock` CanNotDelete (ARM) | Borrar la cuenta, el contenedor o el grupo del estado | Escrituras concurrentes: los locks de ARM no actúan sobre el plano de datos. Un ReadOnly sobre la cuenta tampoco impide modificar blobs |
| `serial` del estado | Escribir una versión más antigua (`state push`) o aplicar un tfplan guardado sobre un estado que cambió (*Saved plan is stale*) | Nada en tiempo real: se comprueba al escribir |
| Versionado + soft delete | Recuperar tras cualquiera de los fallos anteriores | Que ocurran |

> **🔷 El lock de ARM del original no es state locking.** Crear un `CanNotDelete` sobre el contenedor `tfstate` es buena idea (la [página 7](index.md#pagina-7) lo hace sobre el grupo), pero por otro motivo: impide que alguien borre el contenedor con todos los estados dentro. No tiene ningún efecto sobre dos `apply` concurrentes; de eso se ocupa el lease. Son capas complementarias, no alternativas.

---

## 5. Bloqueo en CI/CD

Un pipeline no necesita scripts de lease: el backend bloquea igual que en tu terminal. Lo que sí necesita son tres cosas que el original no tenía: serializar los jobs que tocan el mismo estado, esperar en vez de fallar cuando otro job lo tiene, y un camino para liberar un bloqueo huérfano cuando un runner se cancela a mitad de `apply`.

```yaml
# .github/workflows/terraform.yml  (fragmentos; el resto como en la página 6: OIDC, fmt, validate, test)
concurrency:
  group: tfstate-app-${{ github.event.inputs.entorno || 'lab' }}   # un grupo por estado: los jobs se encolan, no compiten
  cancel-in-progress: false                                         # NUNCA cancelar un apply a medias: deja el lock huérfano

jobs:
  plan:
    steps:
      - run: terraform plan -input=false -lock=false -out=tfplan    # PR: solo lectura, no esperar al apply de otra rama
  aplicar:
    environment: lab
    steps:
      - run: terraform apply -input=false -lock-timeout=10m tfplan  # espera hasta 10 min al lock; "stale plan" si el estado cambió

  # Liberación manual de un bloqueo huérfano: workflow_dispatch con el ID, deja rastro de quién lo ejecutó
  force-unlock:
    if: github.event_name == 'workflow_dispatch' && github.event.inputs.lock_id != ''
    environment: lab                                                # con revisores: dos personas para romper un lock
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
      - run: terraform init -input=false
      - run: terraform force-unlock -force ${{ github.event.inputs.lock_id }}   # -force: sin prompt interactivo
```

```yaml
# azure-pipelines.yml  (fragmento equivalente)
stages:
- stage: aplicar
  lockBehavior: sequential                 # las ejecuciones del stage se encolan en orden
  jobs:
  - deployment: apply
    environment: lab                       # con "Exclusive lock" y aprobaciones en el environment
    strategy:
      runOnce:
        deploy:
          steps:
          - task: TerraformTaskV4@4
            inputs:
              command: apply
              commandOptions: '-input=false -lock-timeout=10m tfplan'
              environmentServiceNameAzureRM: 'sc-tf-lab'   # service connection con Workload Identity Federation (OIDC): sin secreto
```

| **Decisión** | **Motivo** |
|---|---|
| `concurrency` / `lockBehavior` por estado | Evita el conflicto antes de que exista: el segundo job ni siquiera arranca hasta que el primero termina. El lease queda como red de seguridad |
| `cancel-in-progress: false` | Cancelar un apply mata el proceso: recursos a medio crear y lease huérfano. Cancelar un plan de PR sí es aceptable |
| `-lock-timeout=10m` en `apply` | Una persona aplicando desde su portátil no debe hacer fallar el pipeline: que espere |
| `-lock=false` solo en el `plan` de PR | No escribe estado; un plan sobre un estado que está cambiando solo produce un plan que habrá que repetir |
| Job `force-unlock` con aprobación | Romper un lock es una acción auditable: queda quién lo pidió, quién lo aprobó y qué ID se liberó. Mejor que un `az storage blob lease break` desde un portátil |
| Sin `secrets.AZURE_CREDENTIALS` ni claves de cuenta | OIDC ([página 6](index.md#pagina-6)) y `use_azuread_auth`. Los scripts del original necesitaban la clave para el lease: con `shared_access_key_enabled = false` ni siquiera funcionarían |

---

## 6. Lo que el bloqueo no resuelve

El bloqueo del estado es fundamental, pero no es una solución mágica para todos los problemas de concurrencia o gestión.

| **Problema** | **Por qué el lock no lo evita** | **Qué lo evita** |
|---|---|---|
| Dos personas aplican en secuencia con código distinto: la segunda deshace lo de la primera | No hay concurrencia; cada `apply` es correcto respecto a su código | Un solo origen de verdad (rama `main`) y aplicar solo desde el pipeline |
| Aplicar un `tfplan` de hace una hora | El lock se toma al aplicar, no al planificar | El serial: *Saved plan is stale*. Volver a planificar |
| Dos proyectos (dos estados) gestionan el mismo recurso | Cada estado tiene su propio lease; se pisan en Azure, no en el blob | Un recurso, un estado. Compartir por `data` sources, no duplicando `resource` |
| Cambios a mano en el portal mientras nadie aplica | No pasan por Terraform | `plan -refresh-only` programado ([página 6](index.md#pagina-6)), RBAC que no dé Contributor a personas en producción |
| Un `apply` interrumpido deja recursos creados y no registrados | El lock protege el archivo, no la transacción con Azure | Terraform escribe el estado tras cada recurso; lo que falte se adopta con `import` o se borra a mano |

---

## 7. Errores comunes

> ⚠️ **Solución de problemas**
>
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | *Error acquiring the state lock* con Lock Info reciente | Otra operación en curso. No es un error: es el bloqueo funcionando. Espera o usa `-lock-timeout=5m`; pregunta a `Who` antes de tocar nada |
> | Lock Info con `Created` de hace horas o días | Bloqueo huérfano: proceso muerto, runner cancelado, portátil apagado. Confirma que no existe el proceso y `terraform force-unlock <ID>` |
> | *state blob is already locked* sin Lock Info | Alguien creó el lease fuera de Terraform (scripts del original, o una herramienta externa). `force-unlock` no puede: `az storage blob lease break … --auth-mode login` |
> | *Failed to unlock state: … lock ID does not match* | El ID no es el del lock actual: copiado mal o de un error antiguo. Vuelve a lanzar `plan` para obtener el ID vigente. Nunca respondas con `-lock=false` |
> | *Failed to unlock state* al terminar un `apply` que sí funcionó | Alguien hizo `force-unlock` de tu lock mientras trabajabas. El estado se escribió; comprueba con `plan` y habla con quien lo rompió: el ID identifica al proceso, no a la persona |
> | *Error: Saved plan is stale* al aplicar un `tfplan` | El serial del estado cambió desde que se generó el plan. No es un problema de lock: vuelve a `plan -out` y revisa la diferencia |
> | *LeaseIdMissing* / *LeaseIdMismatchWithBlobOperation* (412) | Un proceso intenta escribir el blob con un lease que ya no es suyo (le rompieron el lock). El estado no se corrompe; el proceso termina con error. Relanza cuando el lock esté libre |
> | *InvalidHeaderValue* al hacer `lease acquire --lease-duration 3600` | Azure solo admite 15-60 segundos o -1. Y recuerda: no deberías crear leases a mano sobre el blob del estado |
> | `az storage blob lease list`: *'list' is not in the 'az storage blob lease' command group* | No existe. El estado del lease se consulta con `az storage blob show --query properties.lease` |
> | *AuthorizationPermissionMismatch* al romper un lease | Romper un lease es una operación de escritura: necesitas *Storage Blob Data Contributor*; Reader no basta. Ni Contributor de ARM: no toca el plano de datos |
> | En Topaz, `kill -9` del `apply` y el siguiente `plan` funciona sin `force-unlock` | Comportamiento correcto del backend local: el sistema operativo libera el flock al morir el proceso. En `azurerm` el lease sobrevive: no extrapoles |
> | El pipeline falla con *Error acquiring the state lock* cada vez que alguien aplica desde su portátil | Falta `-lock-timeout` en el `apply` del job. Y a medio plazo: nadie aplica desde el portátil en entornos con pipeline |
> | Cancelar un job de GitHub Actions deja el lock tomado | `cancel-in-progress: true` en el grupo de concurrencia, o cancelación manual. Ponlo en `false` para `apply` y usa el job `force-unlock` con aprobación para limpiar |
> | Un ReadOnly de ARM sobre la cuenta y Terraform sigue escribiendo el estado | Los locks de ARM no gobiernan el plano de datos. Para impedir escrituras en el blob: quitar el rol de datos, no poner locks. Para evitar borrados: `CanNotDelete` |

---

## 8. Autoevaluación

1. **¿Es cierto que Azure Blob Storage no tiene bloqueo nativo para Terraform?**
   No. El backend `azurerm` toma un lease infinito del blob al empezar cada operación de escritura, guarda el Lock Info en el metadato `terraformlockid` y lo libera al terminar. No hace falta ningún script.
2. **¿Qué ocurre si creas un lease a mano antes de `terraform apply`, como hacía el original?**
   Terraform intenta su propio lease, lo encuentra ocupado y falla con *state blob is already locked*, sin Lock Info. Has bloqueado a Terraform, no a los demás.
3. **¿Qué comandos toman el bloqueo y cuáles no?**
   Lo toman los que pueden escribir: `plan`, `apply`, `destroy`, `import`, `state mv/rm/push`, `init -migrate-state`. No lo toman los de solo lectura: `state list/show/pull`, `output`, `validate`.
4. **¿Qué tres campos del Lock Info deciden qué hacer?**
   `Created` (reciente: espera; antiguo: huérfano), `Who` (a quién preguntar, o si el proceso existe) e `ID` (lo único que acepta `force-unlock`).
5. **¿Por qué `force-unlock` exige el ID?**
   Para garantizar que liberas ese lock y no uno que otra persona acaba de tomar. Con un ID equivocado falla con *lock ID does not match*: es la salvaguarda.
6. **¿Cuándo es legítimo `-lock=false`?**
   Solo en un `plan` de solo lectura en la PR de CI. Nunca en `apply`, `destroy` ni comandos `state`: es la causa directa de estados corruptos.
7. **¿Qué diferencia hay entre el bloqueo del estado y un `CanNotDelete` de ARM sobre el contenedor?**
   El lease impide escrituras concurrentes en el blob; el lock de ARM impide borrar el contenedor o la cuenta. El de ARM no actúa sobre el plano de datos, así que no evita dos `apply` a la vez. Son complementarios.
8. **¿Qué reproduce el backend local de Topaz y qué no?**
   Reproduce el mensaje, el Lock Info (archivo `.lock.info`), `-lock-timeout` y `force-unlock`. No reproduce el bloqueo huérfano: el sistema operativo libera el flock al morir el proceso, mientras que el lease de Azure sobrevive.
9. **¿Qué tres medidas sustituyen a los scripts de lease en un pipeline?**
   `concurrency` (o `lockBehavior: sequential`) por estado para encolar jobs, `-lock-timeout` en el `apply` para esperar en vez de fallar, y un job manual de `force-unlock` con aprobación para bloqueos huérfanos.
10. **¿Por qué `cancel-in-progress: false` en el job de apply?**
    Cancelar mata el proceso a mitad: recursos a medio crear y un lease huérfano. El plan de PR sí se puede cancelar porque no escribe estado.
11. **¿Qué protege contra aplicar un tfplan obsoleto, si el lock no lo hace?**
    El serial del estado: si cambió desde que se generó el plan, Terraform rechaza el `apply` con *Saved plan is stale*.

---

## 9. Referencias

- Bloqueo del estado, `terraform force-unlock` y opciones `-lock` y `-lock-timeout`
- Backend `azurerm` y backend `local`
- Operación Lease Blob (REST), `az storage blob lease` y concurrencia en Blob Storage
- Bloqueos de Azure Resource Manager (y por qué no afectan al plano de datos)
- Monitorizar Blob Storage y tabla `StorageBlobLogs`
- Concurrencia en GitHub Actions, environments con revisores y exclusive lock en Azure Pipelines
- Service connection con Workload Identity Federation
- Azure Local Emulator (Topaz)