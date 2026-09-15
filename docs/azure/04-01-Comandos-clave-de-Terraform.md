# ⚙️ Comandos clave de Terraform: init, plan, apply, destroy

> **Terraform** gestiona infraestructura de forma declarativa: tú describes el estado deseado y la herramienta calcula y ejecuta los cambios. Cuatro comandos forman el ciclo de vida de cualquier proyecto: `init`, `plan`, `apply` y `destroy`. En este módulo los ejecutarás contra el **emulador Topaz** y aprenderás a leer lo que cada uno responde. Donde el emulador difiere de Azure real, lo verás en un recuadro **🔷 En Topaz**.

**🎯 Objetivos de aprendizaje**
- Entender qué hace cada comando, cuándo se ejecuta y con qué habla (Internet, disco o emulador).
- Ejecutar el flujo completo y verificarlo con Azure CLI.
- Leer un plan: los símbolos `+`, `~`, `-` y `-/+`.
- Usar planes guardados, `-auto-approve` y `-target` sabiendo sus riesgos.
- Reconocer los errores habituales de cada fase y resolverlos.

> **🔷 Requisitos previos**
> - Contenedor `azure-environment` en marcha y certificado del emulador instalado.
> - Terraform ≥ 1.5 y Azure CLI autenticada en la nube `Topaz`: `az account show --query environmentName -o tsv` → `Topaz`.
> - Laboratorio "Crear tu primer Resource Group" completado.

---

## 1. Visión general del flujo

```text
  Escribir .tf
       │
       ▼
  terraform init ──── descarga providers (Internet) ── crea .terraform/ y .terraform.lock.hcl
       │
       ▼
  terraform plan ──── lee estado + consulta Topaz ──── muestra + ~ - -/+   (no cambia nada)
       │
       ▼
  terraform apply ─── ejecuta el plan en Topaz ─────── actualiza terraform.tfstate, muestra outputs
       │
       ├──► modificar .tf ──► plan ──► apply   (ciclo diario)
       │
       ▼
  terraform destroy ─ elimina lo que está en el estado
```
*Figura 1: ciclo de vida. Solo `plan`, `apply` y `destroy` hablan con el emulador; `init` habla con Internet.*

| **Comando** | **Pregunta que responde** | **Toca Topaz** | **Modifica** |
|---|---|---|---|
| `init` | ¿Tengo las herramientas? | No | `.terraform/`, lock file |
| `plan` | ¿Qué cambiaría? | Sí (solo lectura) | Nada |
| `apply` | Hazlo | Sí (escritura) | Recursos y estado |
| `destroy` | Deshazlo todo | Sí (escritura) | Recursos y estado |

---

## 2. Detalle de cada comando

### 2.1. `terraform init`

Prepara el directorio. Es el primer comando tras crear o clonar una configuración, y hay que repetirlo cuando cambian los providers, los módulos o el backend.

- Descarga los providers de `required_providers` a `.terraform/providers/`.
- Escribe `.terraform.lock.hcl` con las versiones exactas y sus hashes (se versiona en Git).
- Inicializa el backend: local por defecto, remoto si hay bloque `backend`.
- Descarga los módulos referenciados con `source`.

```bash
terraform init                 # normal
terraform init -upgrade        # acepta versiones más nuevas dentro de la restricción y actualiza el lock
terraform init -reconfigure    # reinicia el backend sin migrar estado
terraform init -migrate-state  # cambia de backend llevándose el estado
```

> **🔷 En Topaz.** `init` no toca el emulador: necesita Internet para llegar a `registry.terraform.io`. Si falla, el emulador no tiene nada que ver. Puedes hacer `init` con el contenedor apagado.

### 2.2. `terraform plan`

Calcula la diferencia entre lo declarado y lo que existe, y la muestra sin cambiar nada. Es la red de seguridad del flujo.

- Refresca el estado consultando la API (lee cada recurso del estado en Topaz).
- Compara con la configuración y lista las acciones por recurso.
- Detecta errores de sintaxis, tipos, referencias y autenticación antes de tocar nada.
- `-out=archivo` guarda el plan en binario para aplicarlo exactamente después.

| **Símbolo** | **Acción** | **Cuándo** |
|---|---|---|
| `+ create` | Crear | El recurso está en el código y no en el estado |
| `~ update in-place` | Modificar sin recrear | Cambió un argumento que la API permite editar (tags, address_space) |
| `-/+ replace` | Destruir y crear | Cambió un argumento inmutable (`name`, `location`). El plan marca la causa con *# forces replacement* |
| `- destroy` | Eliminar | El recurso está en el estado y ya no en el código |

```bash
terraform plan                        # muestra y descarta
terraform plan -out=tfplan            # guarda el plan
terraform show tfplan                 # lo relee en texto
terraform apply tfplan                # aplica exactamente eso, sin volver a preguntar
terraform plan -detailed-exitcode     # CI: 0 sin cambios, 1 error, 2 hay cambios
terraform plan -destroy               # previsualiza un destroy
```

> ⚠️ **Lee siempre el plan.** Busca primero la línea *Plan: X to add, Y to change, Z to destroy*. Si Z no es cero y no lo esperabas, para. Un `-/+ replace` sobre un grupo de recursos destruye todo su contenido.

### 2.3. `terraform apply`

Ejecuta el plan. Sin argumentos genera uno nuevo y pide confirmación; con un archivo de plan aplica exactamente lo revisado.

- Recorre el grafo de dependencias: en paralelo lo independiente, en orden lo dependiente.
- Actualiza `terraform.tfstate` tras cada recurso (y guarda una copia en `terraform.tfstate.backup`).
- Muestra los `output` al terminar.
- `-auto-approve` omite la confirmación: solo en pipelines o laboratorios.

```bash
terraform apply                       # plan + confirmación "yes"
terraform apply tfplan                # plan guardado, sin confirmación
terraform apply -auto-approve         # sin confirmación (cuidado)
terraform apply -var entorno=test     # sobrescribe una variable
terraform apply -refresh-only         # solo sincroniza el estado con la realidad, sin cambiar recursos
```

### 2.4. `terraform destroy`

Elimina todo lo que está en el estado, en orden inverso al de creación. Es `apply` con un plan en el que todo es `- destroy`.

- Solo afecta a recursos del estado: lo creado con `az` o a mano no lo ve.
- `lifecycle { prevent_destroy = true }` en un recurso hace que el `destroy` falle antes de empezar: es la protección para producción.
- `terraform state rm` **no elimina nada**: saca el recurso del estado y Terraform deja de gestionarlo. El objeto sigue existiendo en la nube.

```bash
terraform destroy                     # confirmación "yes"
terraform destroy -auto-approve       # laboratorios
terraform destroy -target=azurerm_virtual_network.lab   # solo ese recurso y sus dependientes
```

> **🔷 En Topaz.** Si `destroy` se niega a borrar un grupo porque contiene recursos creados con `az`, añade en el provider `features { resource_group { prevent_deletion_if_contains_resources = false } }`, o bórralos antes con `az resource delete`.

### 2.5. Comandos de apoyo

```bash
terraform fmt                 # formatea los .tf
terraform validate            # sintaxis y tipos, sin red (requiere init)
terraform output [-raw NOMBRE]
terraform state list          # qué hay en el estado
terraform state show DIRECCION
terraform show                # estado completo en texto
terraform providers           # versiones instaladas
```

---

## 3. Ejemplo práctico completo

Un grupo de recursos y una red virtual, para poder ver los cuatro símbolos del plan.

### Paso 1. Sesión y directorio

```bash
az account show --query '{cloud:environmentName, sub:id}' -o json    # Topaz / ...0001
mkdir -p ~/tf-comandos-clave && cd ~/tf-comandos-clave
```

### Paso 2. `main.tf`

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  metadata_host                   = "topaz.local.dev:8899"
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}

variable "nombre_rg" {
  description = "Nombre del grupo de recursos"
  type        = string
  default     = "rg-comandos-lab-001"
}

variable "ubicacion" {
  type    = string
  default = "eastus"
}

locals {
  tags = {
    entorno = "laboratorio"
    curso   = "terraform-azure"
  }
}

resource "azurerm_resource_group" "lab" {
  name     = var.nombre_rg
  location = var.ubicacion
  tags     = local.tags

  lifecycle {
    ignore_changes = [tags]          # Topaz no devuelve las tags del grupo
  }
}

resource "azurerm_virtual_network" "lab" {
  name                = "vnet-comandos-lab"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["10.0.0.0/16"]
  tags                = local.tags
}

output "nombre_del_rg" {
  value = azurerm_resource_group.lab.name
}

output "id_vnet" {
  value = azurerm_virtual_network.lab.id
}
```
Sin `timestamp()`: un `default` solo admite literales, y una etiqueta que cambia sola produciría un `~ update` en cada ejecución.

### Paso 3. `init`

```bash
terraform init
ls -a                    # .terraform/  .terraform.lock.hcl  main.tf
```

```text
Initializing provider plugins...
- Finding hashicorp/azurerm versions matching "~> 4.0"...
- Installing hashicorp/azurerm v4.x.x...
Terraform has been successfully initialized!
```

### Paso 4. `plan` guardado

```bash
terraform fmt && terraform validate
terraform plan -out=tfplan
```

```text
  # azurerm_resource_group.lab will be created
  + resource "azurerm_resource_group" "lab" {
      + id       = (known after apply)
      + location = "eastus"
      + name     = "rg-comandos-lab-001"
      ...
    }

  # azurerm_virtual_network.lab will be created
  + resource "azurerm_virtual_network" "lab" {
      + address_space       = [ + "10.0.0.0/16" ]
      + name                = "vnet-comandos-lab"
      + resource_group_name = "rg-comandos-lab-001"
      ...
    }

Plan: 2 to add, 0 to change, 0 to destroy.
Saved the plan to: tfplan
```
Este es el primer comando que habla con Topaz: autentica, lee los endpoints y comprueba que los recursos no existen. Si aparece un error de certificado o `401`, el problema está en la sesión o el certificado, no en el código.

### Paso 5. `apply` del plan guardado

```bash
terraform apply tfplan          # no pregunta: ya revisaste ese plan exacto
```

```text
azurerm_resource_group.lab: Creating...
azurerm_resource_group.lab: Creation complete after 1s [id=/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-comandos-lab-001]
azurerm_virtual_network.lab: Creating...
azurerm_virtual_network.lab: Creation complete after 3s [id=.../virtualNetworks/vnet-comandos-lab]

Apply complete! Resources: 2 added, 0 changed, 0 destroyed.

Outputs:

id_vnet = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-comandos-lab-001/providers/Microsoft.Network/virtualNetworks/vnet-comandos-lab"
nombre_del_rg = "rg-comandos-lab-001"
```
El grupo se crea antes que la red porque la red lo referencia. Ha aparecido `terraform.tfstate`.

### Paso 6. Verificar e idempotencia

> **🔷 En Topaz no hay Portal.** Se verifica con Azure CLI, un cliente independiente contra la misma API.

```bash
az resource list -g $(terraform output -raw nombre_del_rg) -o table
terraform state list
# azurerm_resource_group.lab
# azurerm_virtual_network.lab

terraform plan
# No changes. Your infrastructure matches the configuration.
```
Ese *No changes* es la propiedad más importante de Terraform: ejecutar el mismo código dos veces no hace nada la segunda.

### Paso 7. Ver `~ update` y `-/+ replace`

Edita `main.tf`: en la VNet, cambia `address_space` a `["10.0.0.0/16", "10.1.0.0/16"]`. Luego:

```bash
terraform plan
```

```text
  # azurerm_virtual_network.lab will be updated in-place
  ~ resource "azurerm_virtual_network" "lab" {
      ~ address_space = [
            "10.0.0.0/16",
          + "10.1.0.0/16",
        ]
    }

Plan: 0 to add, 1 to change, 0 to destroy.
```

Ahora cambia el `name` de la VNet a `"vnet-comandos-lab-2"`:

```text
  # azurerm_virtual_network.lab must be replaced
-/+ resource "azurerm_virtual_network" "lab" {
      ~ name = "vnet-comandos-lab" -> "vnet-comandos-lab-2" # forces replacement
      ...
    }

Plan: 1 to add, 0 to change, 1 to destroy.
```
El nombre es inmutable en ARM, así que Terraform propone destruir y crear. Aplica la primera modificación si quieres (`terraform apply`, `yes`); deshaz la segunda antes de seguir: *1 to destroy* es la línea que debe hacerte parar a pensar.

### Paso 8. `destroy`

```bash
terraform plan -destroy         # previsualiza: Plan: 0 to add, 0 to change, 2 to destroy.
terraform destroy               # yes
```

```text
azurerm_virtual_network.lab: Destroying...
azurerm_virtual_network.lab: Destruction complete after 2s
azurerm_resource_group.lab: Destroying...
azurerm_resource_group.lab: Destruction complete after 1s

Destroy complete! Resources: 2 destroyed.
```

```bash
az group list -o table          # rg-comandos-lab-001 ya no aparece
terraform state list            # vacío
```
Orden inverso al de creación: primero la red, luego el grupo.

---

## 4. Variaciones y buenas prácticas

> 💡 **`-target`: actuar sobre un recurso concreto**
> ```bash
> terraform plan  -target=azurerm_virtual_network.lab
> terraform apply -target=azurerm_virtual_network.lab
> ```
> Terraform incluye automáticamente las dependencias del objetivo, pero avisa: *Resource targeting is in effect*. Es una herramienta de depuración; tras usarla, ejecuta un `plan` completo para comprobar que no queda nada pendiente.

> 💡 **Versionado de providers**
> ```hcl
> version = "~> 4.0"      # recomendado: cualquier 4.x; el lock file fija la exacta
> version = "= 4.57.0"    # exacta: seguro, pero obliga a editar el .tf para actualizar
> ```
> Con `~>` y `.terraform.lock.hcl` en Git tienes reproducibilidad sin rigidez: `init -upgrade` es el único camino para cambiar de versión, y queda registrado en el commit.

> 💡 **Planes guardados en pipelines**
> ```bash
> # Etapa 1 (pull request): terraform plan -out=tfplan -detailed-exitcode
> # Etapa 2 (tras aprobación): terraform apply tfplan
> ```
> El archivo de plan garantiza que se aplica exactamente lo que se revisó. Contiene valores sensibles: trátalo como un secreto y no lo subas a Git (añade `tfplan` y `*.tfstate*` a `.gitignore`).

> 💡 **Backend remoto (Azure real)**
> ```hcl
> terraform {
>   backend "azurerm" {
>     resource_group_name  = "rg-tfstate"
>     storage_account_name = "sttfstate001"
>     container_name       = "tfstate"
>     key                  = "comandos.tfstate"
>   }
> }
> # terraform init -migrate-state
> ```
> **🔷 En Topaz.** El backend `azurerm` depende del plano de datos de Storage del emulador y no está pensado para guardar estado. En el curso el estado es local; este bloque es para tu primera suscripción real en equipo, donde aporta bloqueo y un único estado compartido.
{ .topaz-note }

> ⚠️ **Errores comunes por fase**
> 
> | **Fase** | **Mensaje** | **Solución** |
> |---|---|---|
> | `plan` sin `init` | *Required plugins are not installed ... Run "terraform init"* | `terraform init` |
> | `init` | *Failed to query available provider packages* | Conexión a Internet; no es Topaz |
> | `plan` | *x509: certificate signed by unknown authority* | Reinstala el certificado del emulador |
> | `plan` | `401` / *obtaining Authorization Token from the Azure CLI* | `az cloud set --name Topaz && az login --use-device-code` |
> | `plan` | *SubscriptionNotFound* | Falta `metadata_host`: estás hablando con Azure real |
> | `apply` | *Saved plan is stale* | El estado cambió tras guardar el plan; genera uno nuevo |
> | `apply` | *A resource with the ID ... already exists* | Existe en Topaz y no en el estado: `terraform import` o `az group delete` |
> | `destroy` | *Instance cannot be destroyed ... prevent_destroy* | Está protegido; quita el `lifecycle` solo si de verdad quieres borrarlo |
> | cualquiera | *Error acquiring the state lock* | Otro proceso tiene el estado; espera, o `terraform force-unlock ID` si fue un proceso muerto |

---

## 5. Autoevaluación

1. **¿Qué hace `terraform init` y con qué habla?**
   Descarga providers y módulos, escribe el lock file e inicializa el backend. Habla con Internet, nunca con el emulador.
2. **¿Qué significa cada símbolo del plan?**
   `+` crear, `~` modificar sin recrear, `-/+` destruir y crear (argumento inmutable, marcado con *forces replacement*), `-` eliminar.
3. **¿Cuál es la primera línea del plan que debes leer?**
   *Plan: X to add, Y to change, Z to destroy.* Si Z no es cero y no lo esperabas, no apliques.
4. **¿Qué garantiza `terraform apply tfplan` frente a `terraform apply`?**
   Que se ejecuta exactamente el plan revisado; si el estado cambió entre medias, falla con *Saved plan is stale* en vez de hacer otra cosa.
5. **¿Qué hace `-auto-approve` y cuándo es aceptable?**
   Omite la confirmación. Solo en pipelines que ya aprobaron un plan o en laboratorios desechables.
6. **¿Qué diferencia hay entre `terraform destroy` y `terraform state rm`?**
   `destroy` elimina los recursos en la nube. `state rm` solo los saca del estado: siguen existiendo, pero Terraform deja de gestionarlos.
7. **¿Cómo verificas un `apply` en Topaz?**
   Con Azure CLI (`az resource list -g ...`), un cliente independiente contra la misma API, y con `terraform plan`, que debe decir *No changes*.

---

## 6. Referencias

- [`terraform init`](https://developer.hashicorp.com/terraform/cli/commands/init), [`plan`](https://developer.hashicorp.com/terraform/cli/commands/plan), [`apply`](https://developer.hashicorp.com/terraform/cli/commands/apply), [`destroy`](https://developer.hashicorp.com/terraform/cli/commands/destroy)
- [Flujo de trabajo básico de la CLI](https://developer.hashicorp.com/terraform/cli/run)
- [Comandos de estado (`state list`, `state rm`, `import`)](https://developer.hashicorp.com/terraform/cli/state)
- [Meta-argumento `lifecycle` (`prevent_destroy`, `ignore_changes`)](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle)
- [El archivo `.terraform.lock.hcl`](https://developer.hashicorp.com/terraform/language/files/dependency-lock)
- [Backend `azurerm`](https://developer.hashicorp.com/terraform/language/backend/azurerm)
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)