# 💾 Almacenamiento y bloqueo del state

Por defecto, Terraform guarda el estado en un archivo local, `terraform.tfstate`, junto al código. Para una persona es suficiente; para un equipo es un riesgo: dos personas con dos copias del estado acaban sobrescribiéndose o creando recursos duplicados. De ahí nacen dos conceptos clave: el **backend remoto** (un único estado compartido) y el **bloqueo** (una sola ejecución a la vez).

---

## 🗄️ Opciones de almacenamiento

A continuación, comparamos los backends más comunes según dónde guardan el estado y cómo gestionan el bloqueo.

| **Backend** | **Dónde vive el estado** | **Bloqueo** | **Uso** |
|---|---|---|---|
| **local** (defecto) | `terraform.tfstate` en el directorio | Sí, archivo `.terraform.tfstate.lock.info` (solo protege en la misma máquina) | Aprendizaje, pruebas individuales. **El del curso.** |
| **azurerm** | Blob en una cuenta de Azure Storage | Sí, lease sobre el blob | Equipos en Azure real |
| **s3**, **gcs**, **consul**, **HCP Terraform** | Servicio compartido de otro proveedor | Sí (S3 con DynamoDB o lockfile nativo) | Equipos multi-nube |

*Esta tabla resume cómo escalar tu almacenamiento desde pruebas locales hasta entornos empresariales.*

> **🔷 En Topaz.** El backend `azurerm` escribe el estado a través del plano de datos de Storage (`*.storage.topaz.local.dev:8891`), que en el emulador requiere configuración adicional y no está pensado para eso. En el curso trabajamos con el backend local, que es más que suficiente para aprender lo esencial: qué guarda el estado, cómo se bloquea y qué pasa cuando dos ejecuciones coinciden. Todo lo que practiques aquí se traslada tal cual al backend remoto.

---

## 📂 Qué hay en el directorio tras un `apply`

```bash
cd ~/mi-primer-rg && terraform apply -auto-approve      # cualquier proyecto del curso ya aplicado
ls -a
# .terraform/  .terraform.lock.hcl  main.tf  terraform.tfstate  terraform.tfstate.backup

jq '.serial, .lineage, [.resources[].type]' terraform.tfstate
# 3                                        ← serial: crece en cada escritura
# "7f3a...-...-..."                        ← lineage: identidad de este estado desde su creación
# ["azurerm_resource_group"]
```

- `terraform.tfstate`: el estado actual. JSON legible; puede contener valores sensibles, así que va en `.gitignore`.
- `terraform.tfstate.backup`: la versión anterior. Terraform la escribe antes de cada modificación; es tu primera red de seguridad si un `apply` deja el estado mal.
- `.terraform.lock.hcl`: **no** es el bloqueo del estado, sino las versiones de los providers. El nombre confunde a todo el mundo la primera vez.

---

## 🔒 Bloqueo del state en acción

El bloqueo impide que dos ejecuciones modifiquen el estado a la vez. El backend local lo implementa con un archivo que existe solo mientras hay un comando en marcha. Provócalo con dos terminales en el mismo directorio:

```bash
# Terminal 1: lanza un apply y NO respondas a la pregunta todavía
terraform apply
#   Enter a value:            ← déjalo esperando; el estado está bloqueado

# Terminal 2: mientras tanto
ls -a | grep lock
# .terraform.tfstate.lock.info          ← el bloqueo, con ID, usuario y hora
cat .terraform.tfstate.lock.info | jq .Operation
# "OperationTypeApply"

terraform plan
```

```text
╷
│ Error: Error acquiring the state lock
│
│ Error message: resource temporarily unavailable
│ Lock Info:
│   ID:        a1b2c3d4-....
│   Path:      terraform.tfstate
│   Operation: OperationTypeApply
│   Who:       usuario@equipo
│   Created:   2026-09-09 15:22:10 UTC
│
│ Terraform acquires a state lock to protect the state from being written
│ by multiple users at the same time. Please resolve the issue above and try
│ again.
╵
```

```bash
# Terminal 1: responde "no" para cancelar. El archivo de bloqueo desaparece.
# Terminal 2:
terraform plan                            # ahora funciona: No changes.

# Opción útil en pipelines: esperar en vez de fallar
terraform plan -lock-timeout=60s
```

Ese mensaje es idéntico con cualquier backend; lo único que cambia es el mecanismo debajo (archivo local, lease de blob, tabla DynamoDB). Léelo con calma: te dice *quién* tiene el bloqueo, *qué* está haciendo y *desde cuándo*.

> ⚠️ **Bloqueo huérfano.** Si un proceso muere (cierras la terminal, se corta la sesión), el bloqueo puede quedar atrás. Compruébalo antes de forzar nada: en *Who* y *Created* verás si es de otra persona trabajando ahora o de un proceso que ya no existe. Solo entonces:
> ```bash
> terraform force-unlock a1b2c3d4-....      # el ID que muestra el error
> ```
> Para simularlo en Topaz: en la Terminal 1, en vez de responder, mata el proceso con `kill -9 $(pgrep -f 'terraform apply')`; el archivo `.terraform.tfstate.lock.info` se queda y el siguiente `plan` falla hasta que hagas `force-unlock`.

---

## ☁️ Ejemplo de backend remoto (referencia para Azure real)

Cuando pases a una suscripción real en equipo, este bloque mueve el estado a un blob con bloqueo por lease. La infraestructura del estado se crea una sola vez, fuera de Terraform, y después `terraform init -migrate-state` traslada el `terraform.tfstate` local al contenedor:

```bash
# Una vez, con Azure CLI (Azure real)
az group create -n rg-tfstate -l westeurope
az storage account create -n sttfstate$RANDOM -g rg-tfstate -l westeurope \
  --sku Standard_LRS --allow-blob-public-access false --min-tls-version TLS1_2
az storage container create -n tfstate --account-name <nombre-cuenta> --auth-mode login
```

```hcl
# En el bloque terraform del proyecto
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "<nombre-cuenta>"
    container_name       = "tfstate"
    key                  = "prod.terraform.tfstate"    # un archivo por proyecto/entorno
    use_azuread_auth     = true                        # token de Entra ID, sin claves de la cuenta
  }
}
```

```bash
terraform init -migrate-state
```

Activa el versionado de blobs en la cuenta (`az storage account blob-service-properties update --enable-versioning`): es el equivalente remoto del `terraform.tfstate.backup`, con todo el historial.

> 💡 **Próximo paso.** En el Módulo 7 se detalla la configuración del backend `azurerm`: autenticación, un estado por entorno con `key` distintas, y cómo recuperar una versión anterior del blob. Lo que has visto aquí sobre el archivo de bloqueo, `force-unlock` y `-lock-timeout` se aplica sin cambios.