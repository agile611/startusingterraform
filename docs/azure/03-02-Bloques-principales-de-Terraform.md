# 🧱 Bloques principales de Terraform: `terraform`, `provider` y `resource`

Toda configuración de Terraform se apoya en tres bloques: `terraform` dice qué versiones y providers hacen falta, `provider` establece cómo hablar con la nube y `resource` declara qué debe existir. En este módulo verás cada uno en detalle y los aplicarás en un laboratorio contra el **emulador Topaz**. Donde el emulador difiere de Azure real, lo verás señalado en un recuadro **🔷 En Topaz**.

**Tabla de contenidos**
1. [El bloque `terraform`](#1-el-bloque-terraform)
2. [El bloque `provider`](#2-el-bloque-provider)
3. [El bloque `resource`](#3-el-bloque-resource)
4. [Cómo trabajan juntos](#4-cómo-trabajan-juntos)
5. [Laboratorio: `bloques-lab`](#5-laboratorio-bloques-lab)
6. [Errores comunes](#6-errores-comunes)
7. [Buenas prácticas](#7-buenas-prácticas)
8. [Referencias](#8-referencias)

> **🔷 Requisitos previos.** Contenedor `azure-environment` en marcha, certificado instalado, Azure CLI autenticada en la nube `Topaz` y la Prueba de humo superada. Comprueba en cinco segundos: `az account show --query environmentName -o tsv` debe responder `Topaz`.

---

## 1. El bloque `terraform`

> **Propósito:** configurar a Terraform mismo: qué versión del binario se admite, qué providers hacen falta y de dónde se descargan, y dónde se guarda el estado.

Es opcional, pero omitirlo es una mala idea: sin él, `terraform init` descarga la última versión de cada provider, y un salto de versión mayor puede romper una configuración que ayer funcionaba.

### 1.1. Sintaxis

```hcl
terraform {
  # Versión del binario de Terraform admitida
  required_version = ">= 1.5.0"

  # Providers necesarios: de dónde vienen y qué versiones se aceptan
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"          # cualquier 4.x; nunca 5.0
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Dónde vive el estado. Sin este bloque: terraform.tfstate local (lo que usamos en el curso)
  # backend "azurerm" {
  #   resource_group_name  = "rg-tfstate"
  #   storage_account_name = "sttfstate001"
  #   container_name       = "tfstate"
  #   key                  = "prod.terraform.tfstate"
  # }
}
```

| **Argumento** | **Qué hace** | **Detalle** |
|---|---|---|
| `required_version` | Restringe la versión del binario | Operadores: `=`, `!=`, `>=`, `<`, `~>`. Si no se cumple, Terraform se detiene antes de hacer nada. |
| `required_providers` | Declara cada provider | `source` con formato `NAMESPACE/NOMBRE` (registry.terraform.io implícito); `version` con restricción. El nombre local (`azurerm`, `random`) es el que luego usa el bloque `provider`. |
| `backend` | Ubicación del estado | Uno como máximo. Sin él, estado local. Cambiarlo exige `terraform init -migrate-state`. |

> 💡 **Reglas sintácticas.** El bloque `terraform` no lleva etiquetas. Puede haber varios en el módulo raíz (Terraform los fusiona), pero la convención es uno solo en `versions.tf`. Dentro de él no se pueden usar variables ni referencias: todo son literales, porque se evalúa antes de que exista nada más. El argumento `experiments` que aparece en material antiguo (`module_var_optional_attrs`) ya no es válido: esa característica es estable desde Terraform 1.3.

> **🔷 En Topaz.** El `backend "azurerm"` guarda el estado en un blob y usa el plano de datos de Storage (`*.storage.topaz.local.dev:8891`), que en el emulador requiere configuración extra y no está pensado para eso. En el curso usamos el backend local; el bloque comentado es el que activarás cuando trabajes en equipo sobre Azure real. La versión de `~> 4.0` es la que soporta `metadata_host`, imprescindible para apuntar al emulador.

El provider `random` del ejemplo es deliberado: no habla con ninguna nube, así que funciona igual en Topaz y en Azure real, y te permite ver un proyecto con **dos providers** de verdad. Lo usaremos en el laboratorio para generar un sufijo de nombre.

---

## 2. El bloque `provider`

> **Propósito:** configurar un plugin concreto: a qué endpoint se conecta, con qué credenciales y con qué opciones globales. Sin él, Terraform no puede hablar con ninguna API.

### 2.1. Sintaxis y configuración para el curso

```hcl
provider "azurerm" {
  # Obligatorio en azurerm desde la v2.0, aunque esté vacío
  features {}

  # --- Lo único específico del emulador ---
  metadata_host                   = "topaz.local.dev:8899"   # descubre los endpoints de Topaz
  resource_provider_registrations = "none"                   # el emulador no registra providers de ARM

  # Obligatorio en azurerm 4.x (en Azure real, tu suscripción)
  subscription_id = "00000000-0000-0000-0000-000000000001"
}

# El provider random no necesita configuración, pero declararlo documenta que se usa
provider "random" {}
```

La etiqueta del bloque (`"azurerm"`) debe coincidir con el nombre local declarado en `required_providers`. El bloque `features {}` es un bloque anidado, no un argumento: de ahí las llaves.

> 🚨 **Regla crítica para Azure.** Si falta `features {}`, el error es literal: *Insufficient features blocks: At least 1 "features" blocks are required*. Dentro puedes ajustar comportamientos globales, por ejemplo `resource_group { prevent_deletion_if_contains_resources = false }`, que evita que `destroy` se niegue a borrar un grupo con restos creados fuera de Terraform.

### 2.2. Autenticación

El provider busca credenciales en este orden: argumentos explícitos del bloque → variables de entorno `ARM_*` → sesión de Azure CLI → identidad administrada / OIDC del pipeline. En el curso usamos la sesión de Azure CLI, exactamente como harías en tu portátil contra Azure real.

> **✅ Desarrollo (y el laboratorio): sesión de Azure CLI**
> ```bash
> az cloud set --name Topaz          # en Azure real: az cloud set --name AzureCloud
> az login --use-device-code
> az account show --query '{cloud:environmentName, sub:id}' -o json
> # El provider reutiliza este token: no hay que escribir ninguna credencial en el .tf
> ```

> **ℹ️ Configuración por variables de entorno (misma configuración en varios entornos)**
> Todo argumento del provider tiene su equivalente `ARM_*`. Si los exportas, el bloque queda idéntico al de Azure real:
> ```bash
> # Topaz
> export ARM_METADATA_HOSTNAME=topaz.local.dev:8899
> export ARM_RESOURCE_PROVIDER_REGISTRATIONS=none
> export ARM_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000001
> 
> # Azure real con entidad de servicio (pipelines): solo estas cuatro
> export ARM_SUBSCRIPTION_ID=...  ARM_TENANT_ID=...  ARM_CLIENT_ID=...  ARM_CLIENT_SECRET=...
> ```
> Y el bloque se reduce a:
> ```hcl
> provider "azurerm" {
>   features {}
> }
> ```

> 🚨 **⚠️ Nunca: secretos en el `.tf`**
> ```hcl
> provider "azurerm" {
>   features {}
>   client_id     = "xxxxxxxx-..."
>   client_secret = "S3cr3t..."     # acaba en Git y en cualquier copia del código
> }
> ```
> Los secretos en texto plano viajan con el repositorio y con cada copia de seguridad. En Topaz no hay entidades de servicio (el usuario `topazadmin` lo puede todo), así que ni siquiera tienes la tentación.

### 2.3. Varios providers del mismo tipo: `alias`

Un segundo bloque `provider "azurerm"` necesita un `alias`; los recursos eligen cuál usar con el meta-argumento `provider`. El caso típico en Azure real es desplegar en dos suscripciones; en Topaz solo hay una, pero la mecánica es idéntica y se puede practicar:

```hcl
# Provider por defecto: lo usan los recursos que no dicen nada
provider "azurerm" {
  features {}
  metadata_host                   = "topaz.local.dev:8899"
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}

# Segundo provider. En Azure real cambiarías subscription_id; en Topaz apunta al mismo emulador
provider "azurerm" {
  alias = "secundario"
  features {}
  metadata_host                   = "topaz.local.dev:8899"
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}

resource "azurerm_resource_group" "principal" {
  name     = "rg-alias-principal"
  location = "eastus"
}

resource "azurerm_resource_group" "secundario" {
  provider = azurerm.secundario        # referencia sin comillas: TIPO.ALIAS
  name     = "rg-alias-secundario"
  location = "eastus"
}
```

---

## 3. El bloque `resource`

> **Propósito:** declarar un objeto de infraestructura que Terraform debe crear, mantener y, llegado el caso, destruir. Cada bloque `resource` corresponde a un objeto real en la nube.

### 3.1. Sintaxis

```hcl
resource "TIPO" "NOMBRE_LOCAL" {
  # Argumentos propios del tipo (los define el provider)
  argumento = expresión

  # Bloques anidados, para configuraciones estructuradas
  bloque_anidado {
    argumento = expresión
  }

  # Meta-argumentos: existen en todos los recursos, de cualquier provider
  provider   = azurerm.secundario          # qué configuración de provider usar
  count      = 1                           # número de instancias (o for_each = mapa/set)
  depends_on = [azurerm_x.y]               # dependencia que el código no expresa
  lifecycle {
    create_before_destroy = true           # al reemplazar, crea el nuevo antes de borrar el viejo
    prevent_destroy       = false          # true bloquea cualquier destroy del recurso
    ignore_changes        = [tags]         # atributos cuya deriva se ignora
  }
}
```

- **`TIPO`**: `<provider>_<recurso>`. El prefijo enlaza con el nombre local del provider: `azurerm_resource_group`, `random_string`.
- **`NOMBRE_LOCAL`**: identificador dentro de la configuración. **No es el nombre en Azure**; ese va en el argumento `name`. Cambiar el nombre local sin más hace que Terraform quiera destruir y recrear (se evita con un bloque `moved {}`).
- **Argumentos**: los dicta la documentación del recurso en el Registry. Los obligatorios y los opcionales varían por tipo.
- **Atributos**: valores que el recurso exporta tras crearse (`id`, `default_hostname`...). Se leen, no se escriben.

### 3.2. Ejemplo completo: grupo, red y subred

```hcl
locals {
  tags = {
    entorno = "produccion"
    equipo  = "infraestructura"
    costo   = "centro"
  }
}

# 1. Contenedor lógico
resource "azurerm_resource_group" "red" {
  name     = "rg-red-produccion-001"
  location = "eastus"
  tags     = local.tags

  lifecycle {
    ignore_changes = [tags]              # Topaz no devuelve las tags del grupo
  }
}

# 2. Red virtual: depende del grupo por las dos referencias
resource "azurerm_virtual_network" "principal" {
  name                = "vnet-produccion"
  location            = azurerm_resource_group.red.location
  resource_group_name = azurerm_resource_group.red.name
  address_space       = ["10.0.0.0/16"]
  tags                = local.tags
}

# 3. Subred: depende de la VNet. No admite tags (es un recurso hijo)
resource "azurerm_subnet" "frontend" {
  name                 = "snet-frontend"
  resource_group_name  = azurerm_resource_group.red.name
  virtual_network_name = azurerm_virtual_network.principal.name
  address_prefixes     = ["10.0.1.0/24"]
}
```

> **🔷 En Topaz: por qué `local.tags` y no `azurerm_resource_group.red.tags`.** Heredar las etiquetas por referencia al grupo es un patrón habitual en material sobre Azure. En el emulador falla con *Provider produced inconsistent final plan*: Topaz crea el grupo pero devuelve `tags: null`, y el valor planificado deja de coincidir con el real. Declarar las etiquetas en `locals` resuelve el problema y es, además, la práctica recomendada en cualquier entorno: la configuración depende de lo que tú declaras, no de lo que el servidor devuelve.

### 3.3. Referencias entre recursos

```hcl
# Sintaxis: TIPO.NOMBRE_LOCAL.ATRIBUTO
azurerm_resource_group.red.id                       # "/subscriptions/.../resourceGroups/rg-red-produccion-001"
azurerm_virtual_network.principal.address_space[0]  # "10.0.0.0/16"
azurerm_subnet.frontend.id

# Con count / for_each se indexa la instancia
azurerm_resource_group.respaldo[0].name
azurerm_subnet.zonas["frontend"].address_prefixes
```

Cada referencia crea una arista en el grafo de dependencias: Terraform crea primero lo referenciado y destruye en orden inverso. Por eso `depends_on` casi nunca es necesario; se reserva para dependencias reales que el código no expresa (por ejemplo, una asignación de rol que debe existir antes de que otro recurso la use).

---

## 4. Cómo trabajan juntos

| **Bloque** | **Responde a** | **Cuándo se evalúa** | **Archivo habitual** |
|---|---|---|---|
| `terraform` | ¿Con qué herramientas trabajo? | `terraform init`: descarga providers, configura el backend | `versions.tf` |
| `provider` | ¿Con quién hablo y cómo me identifico? | `plan`/`apply`: primera llamada a la API | `versions.tf` o `providers.tf` |
| `resource` | ¿Qué debe existir? | `plan` construye el grafo; `apply` lo ejecuta | `main.tf`, `network.tf`... |

**Orden de procesamiento:**
1. `init` lee `terraform`, descarga los providers que cumplen las restricciones y anota las versiones exactas en `.terraform.lock.hcl`.
2. `plan` carga todos los `.tf`, valida tipos y construye el grafo de dependencias a partir de las referencias.
3. Configura cada `provider` y obtiene credenciales (en el curso, de la sesión de `az`).
4. Refresca el estado de los recursos existentes y calcula la diferencia con lo declarado.
5. `apply` ejecuta el plan recorriendo el grafo: en paralelo lo independiente, en orden lo dependiente.

> **🔷 En Topaz.** Los pasos 1 y 2 no tocan el emulador: `init` descarga los providers de Internet y `validate` trabaja en local. El primer contacto con Topaz es el paso 3. Por eso, si algo falla en `init` o `validate`, el problema está en tu código o en tu conexión a Internet, nunca en el emulador.

---

## 5. Laboratorio: `bloques-lab`

Vas a crear un grupo de recursos con nombre único y una red virtual, usando los tres bloques y dos providers. Todo contra Topaz.

### Paso 1. Directorio y archivos

```bash
mkdir -p ~/bloques-lab && cd ~/bloques-lab
```

```hcl
# archivo: versions.tf
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
  metadata_host                   = "topaz.local.dev:8899"
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}
```

```hcl
# archivo: main.tf
variable "ubicacion" {
  description = "Región de Azure"
  type        = string
  default     = "eastus"
}

locals {
  tags = {
    entorno = "laboratorio"
    curso   = "terraform-azure"
  }
}

# Provider random: sufijo único para el nombre, generado en local
resource "random_string" "sufijo" {
  length  = 4
  lower   = true
  upper   = false
  numeric = true
  special = false
}

resource "azurerm_resource_group" "lab" {
  name     = "rg-bloques-lab-${random_string.sufijo.result}"
  location = var.ubicacion
  tags     = local.tags

  lifecycle {
    ignore_changes = [tags]
  }
}

resource "azurerm_virtual_network" "lab" {
  name                = "vnet-lab"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["10.0.0.0/16"]
  tags                = local.tags
}

output "grupo" {
  value = azurerm_resource_group.lab.name
}

output "vnet_id" {
  value = azurerm_virtual_network.lab.id
}
```

### Paso 2. `init`

```bash
terraform init
```

```text
Initializing the backend...
Initializing provider plugins...
- Finding hashicorp/azurerm versions matching "~> 4.0"...
- Finding hashicorp/random versions matching "~> 3.6"...
- Installing hashicorp/azurerm v4.x.x...
- Installing hashicorp/random v3.x.x...

Terraform has created a lock file .terraform.lock.hcl to record the provider
selections it made above. Include this file in your version control repository...

Terraform has been successfully initialized!
```

Dos providers descargados: el bloque `terraform` ha hecho su trabajo. El archivo `.terraform.lock.hcl` fija las versiones exactas; se versiona en Git.

### Paso 3. `validate` y `plan`

```bash
terraform fmt
terraform validate        # Success! The configuration is valid.
terraform plan
```

```text
Terraform will perform the following actions:

  # azurerm_resource_group.lab will be created
  + resource "azurerm_resource_group" "lab" {
      + id       = (known after apply)
      + location = "eastus"
      + name     = (known after apply)
      + tags     = {
          + "curso"   = "terraform-azure"
          + "entorno" = "laboratorio"
        }
    }

  # azurerm_virtual_network.lab will be created
  + resource "azurerm_virtual_network" "lab" {
      + address_space       = [ + "10.0.0.0/16" ]
      + id                  = (known after apply)
      + location            = "eastus"
      + name                = "vnet-lab"
      + resource_group_name = (known after apply)
      ...
    }

  # random_string.sufijo will be created
  + resource "random_string" "sufijo" {
      + length  = 4
      + result  = (known after apply)
      ...
    }

Plan: 3 to add, 0 to change, 0 to destroy.
```

Fíjate en `name = (known after apply)` en el grupo: depende del sufijo aleatorio, que no existe hasta el `apply`. Ese *known after apply* se propaga a `resource_group_name` de la VNet: es el grafo de dependencias haciéndose visible.

### Paso 4. `apply`

```bash
terraform apply           # escribe yes
```

```text
random_string.sufijo: Creating...
random_string.sufijo: Creation complete after 0s [id=x7k2]
azurerm_resource_group.lab: Creating...
azurerm_resource_group.lab: Creation complete after 2s [id=/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-bloques-lab-x7k2]
azurerm_virtual_network.lab: Creating...
azurerm_virtual_network.lab: Creation complete after 4s [id=.../resourceGroups/rg-bloques-lab-x7k2/providers/Microsoft.Network/virtualNetworks/vnet-lab]

Apply complete! Resources: 3 added, 0 changed, 0 destroyed.

Outputs:

grupo = "rg-bloques-lab-x7k2"
vnet_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-bloques-lab-x7k2/providers/Microsoft.Network/virtualNetworks/vnet-lab"
```

El orden de creación es el del grafo: primero el sufijo, luego el grupo, luego la red. Tu sufijo será distinto.

### Paso 5. Verificar por el otro camino

> **🔷 En Topaz no hay Portal.** La verificación independiente se hace con Azure CLI, que es un cliente distinto de Terraform hablando con la misma API.

```bash
RG=$(terraform output -raw grupo)
az group show -n $RG --query '{nombre:name, ubicacion:location, estado:properties.provisioningState}' -o json
az resource list -g $RG -o table
az network vnet show -g $RG -n vnet-lab --query addressSpace.addressPrefixes -o json   # ["10.0.0.0/16"]

terraform plan            # No changes. Your infrastructure matches the configuration.
```

### Paso 6. Experimentos rápidos

```hcl
# a) Quita features {} del provider y ejecuta plan → verás el error de la sección 6
# b) Comenta metadata_host y ejecuta plan → Terraform intentará hablar con Azure real
# c) Cambia el nombre local "lab" por "laboratorio" en el grupo y ejecuta plan:
#    Terraform propone destruir y crear. Evítalo con un bloque moved:
moved {
  from = azurerm_resource_group.lab
  to   = azurerm_resource_group.laboratorio
}
```

### Paso 7. Limpiar

```bash
terraform destroy         # yes → Destroy complete! Resources: 3 destroyed.
az group list -o table    # el grupo ya no aparece
```

En el emulador no hay coste, pero el hábito de destruir lo que no se usa es de los que conviene fijar antes de pasar a una suscripción real.

---

## 6. Errores comunes

| **Bloque** | **Mensaje** | **Causa** | **Solución** |
|---|---|---|---|
| `terraform` | *Unsupported Terraform Core version* | El binario no cumple `required_version` | Actualiza Terraform o relaja la restricción |
| `terraform` | *Failed to query available provider packages* | Sin acceso a registry.terraform.io, o `source` mal escrito | Comprueba la conexión a Internet (no es Topaz: `init` no toca el emulador) y el formato `hashicorp/azurerm` |
| `terraform` | *Backend configuration changed* | Se añadió, quitó o modificó el bloque `backend` tras el `init` | `terraform init -migrate-state` (o `-reconfigure` si no quieres migrar) |
| `provider` | *Insufficient features blocks: At least 1 "features" blocks are required* | Falta `features {}` en `provider "azurerm"` | Añádelo, aunque esté vacío |
| `provider` | *subscription_id is a required provider property* | azurerm 4.x exige la suscripción explícita | `subscription_id` en el bloque o `ARM_SUBSCRIPTION_ID` |
| `provider` | *SubscriptionNotFound* | Falta `metadata_host`: Terraform habla con Azure real y la suscripción `...0001` no existe allí | Añade `metadata_host = "topaz.local.dev:8899"` |
| `provider` | *building account: could not acquire access token... Azure CLI* / `401` | Sesión de `az` caducada o en otra nube | `az cloud set --name Topaz && az login --use-device-code` |
| `provider` | *x509: certificate signed by unknown authority* | Terraform no confía en el certificado del emulador | `export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt`; reinstala el certificado si recreaste el contenedor |
| `provider` | *Duplicate provider configuration* | Dos bloques `provider "azurerm"` sin `alias` | Añade `alias` al segundo y `provider = azurerm.<alias>` en los recursos que lo usen |
| `resource` | *Missing required argument* | Falta un argumento obligatorio del tipo (p. ej. `address_space` en una VNet) | Consulta la página del recurso en el Registry: sección *Argument Reference* |
| `resource` | *Unsupported argument* | Argumento inexistente para ese tipo (p. ej. `tags` en `azurerm_subnet`) o nombre mal escrito | Elimínalo o corrige el nombre; `validate` indica archivo y línea |
| `resource` | *Duplicate resource "azurerm_resource_group" configuration* | Dos bloques con el mismo tipo y nombre local (típico al copiar entre archivos) | Renombra uno: `grep -rn 'resource "azurerm_resource_group"' *.tf` |
| `resource` | *Cycle: azurerm_a.x, azurerm_b.y* | Dependencia circular: cada recurso referencia al otro | Rompe el ciclo quitando una referencia o moviendo el valor a `locals`; revisa los `depends_on` añadidos "por si acaso" |
| `resource` | *A resource with the ID "..." already exists* | El objeto existe en el emulador pero no en el estado (estado borrado, o creado con `az`) | `terraform import` / bloque `import {}`, o `az group delete` si era un resto |
| `resource` | *Provider produced inconsistent final plan ... .tags ... but now null* | Etiquetas heredadas por referencia al grupo; Topaz devuelve `null` | Etiquetas en `locals` y `tags = local.tags`; `ignore_changes = [tags]` en el grupo |
| `resource` | *must be replaced* tras renombrar el bloque | Cambió el nombre local; Terraform lo ve como un recurso nuevo | Bloque `moved { from = ... to = ... }` (Paso 6 del laboratorio) |

> 💡 **Cómo saber qué bloque falla.** Si el error aparece en `init`, es el bloque `terraform`. Si aparece en `validate`, es sintaxis o argumentos de `resource`. Si aparece en `plan` antes de listar cambios, es el `provider` (autenticación, certificado, endpoint). Si aparece en `apply`, es la API del emulador respondiendo a un `resource`.

---

## 7. Buenas prácticas

> **✅ Fija versiones y versiona el lock.** `required_version` y `required_providers` siempre, con `~>` sobre la versión mayor. El archivo `.terraform.lock.hcl` va a Git: garantiza que todo el equipo (y el pipeline) usa exactamente los mismos binarios. Para actualizar de forma consciente: `terraform init -upgrade`.

> **✅ Un archivo para `terraform` y `provider`.** La convención es `versions.tf` (o `providers.tf`). Es lo primero que revisa quien llega a un proyecto y lo único que cambia entre Topaz y Azure real.

> **ℹ️ Configuración del provider fuera del código cuando sea posible.** Con `ARM_METADATA_HOSTNAME`, `ARM_RESOURCE_PROVIDER_REGISTRATIONS` y `ARM_SUBSCRIPTION_ID` exportadas en el laboratorio, el bloque `provider` queda idéntico al de producción y el mismo repositorio sirve en ambos sitios. Ni secretos ni endpoints en los `.tf`.

> **ℹ️ Nombre local ≠ nombre en Azure.** El nombre local describe el papel del recurso en la configuración (`azurerm_resource_group.red`); el argumento `name` sigue la convención de nombrado de Azure (`rg-red-produccion-001`). Si solo hay un recurso de un tipo, `this` o `main` son nombres locales aceptados.

> **⚠️ Referencias implícitas antes que `depends_on`.** Si un recurso necesita otro, usa un atributo de ese otro (`resource_group_name = azurerm_resource_group.red.name`): la dependencia queda documentada en el propio argumento. `depends_on` solo cuando no hay ningún atributo que referenciar, y siempre con un comentario que explique por qué.

> **⚠️ Valores compartidos en `locals`, no heredados de recursos.** Etiquetas, prefijos y ubicaciones que usan varios recursos se declaran una vez y se referencian como `local.x`. Heredarlos leyendo atributos de otro recurso hace que tu configuración dependa de lo que la API devuelva, y ya has visto en Topaz lo que pasa cuando devuelve algo distinto.

> **📝 Plantilla mínima para cualquier proyecto del curso**
> ```hcl
> # versions.tf
> terraform {
>   required_version = ">= 1.5.0"
>   required_providers {
>     azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
>   }
> }
> 
> provider "azurerm" {
>   features {}
>   metadata_host                   = "topaz.local.dev:8899"      # quitar en Azure real
>   resource_provider_registrations = "none"                      # quitar en Azure real
>   subscription_id                 = "00000000-0000-0000-0000-000000000001"
> }
> 
> # main.tf
> locals {
>   tags = { entorno = "dev", gestionado = "terraform" }
> }
> 
> resource "azurerm_resource_group" "this" {
>   name     = "rg-<app>-dev-001"
>   location = "eastus"
>   tags     = local.tags
>   lifecycle { ignore_changes = [tags] }
> }
> ```

---

## 8. Referencias

### Terraform
- [El bloque `terraform`](https://developer.hashicorp.com/terraform/language/terraform)
- [Requisitos de providers y restricciones de versión](https://developer.hashicorp.com/terraform/language/providers/requirements)
- [Configuración de providers y `alias`](https://developer.hashicorp.com/terraform/language/providers/configuration)
- [Sintaxis del bloque `resource`](https://developer.hashicorp.com/terraform/language/resources/syntax)
- [Meta-argumento `lifecycle`](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle) y [`depends_on`](https://developer.hashicorp.com/terraform/language/meta-arguments/depends_on)
- [Bloque `moved` para renombrar recursos](https://developer.hashicorp.com/terraform/language/moved)
- [El archivo `.terraform.lock.hcl`](https://developer.hashicorp.com/terraform/language/files/dependency-lock)

### Providers
- [Provider azurerm: argumentos del bloque provider](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs) (`metadata_host`, `features`, autenticación)
- [Autenticación con Azure CLI](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/azure_cli)
- [Recurso `random_string`](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string)
- [Recurso `azurerm_virtual_network`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network)
- [Azure Local Emulator (Topaz)](https://github.com/Azure/azure-local-emulator)