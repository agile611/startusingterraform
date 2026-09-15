# 🔌 Configuración del provider azurerm

> **El provider azurerm** es el plugin que conecta Terraform con Azure Resource Manager (ARM). Se encarga de autenticarse, traducir tu HCL a llamadas a la API y gestionar las particularidades de cada tipo de recurso. En este módulo verás su sintaxis, los métodos de autenticación y la configuración avanzada, y lo verificarás con un laboratorio contra el **emulador Topaz**. Donde el emulador difiere de Azure real, lo verás en un recuadro **🔷 En Topaz**.

**Tabla de contenidos**
1. [Sintaxis básica y configuración del curso](#1-sintaxis-básica-y-configuración-del-curso)
2. [Métodos de autenticación](#2-métodos-de-autenticación)
3. [Configuración avanzada](#3-configuración-avanzada)
4. [Relación con `terraform` y `resource`](#4-relación-con-terraform-y-resource)
5. [LAB: verificar el provider](#5-lab-verificar-el-provider)
6. [Preguntas frecuentes](#6-preguntas-frecuentes)
7. [Buenas prácticas y errores comunes](#7-buenas-prácticas-y-errores-comunes)
8. [Referencias](#8-referencias)

> **🔷 Requisitos previos.** Contenedor `azure-environment` en marcha, certificado instalado, Azure CLI autenticada en la nube `Topaz` y la Prueba de humo superada. Comprueba en cinco segundos: `az account show --query environmentName -o tsv` debe responder `Topaz`.

---

## 1. Sintaxis básica y configuración del curso

La configuración mínima contra Azure real es un bloque con `features {}`, obligatorio desde la versión 2.0 del provider, y, en azurerm 4.x, la suscripción:

```hcl
# Azure real
provider "azurerm" {
  features {}
  subscription_id = "<id-de-tu-suscripcion>"
}
```

Para el emulador se añaden dos argumentos. Este es el bloque que usarás en todo el curso:

```hcl
# Topaz
provider "azurerm" {
  features {}

  metadata_host                   = "topaz.local.dev:8899"
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}
```

| **Argumento** | **Qué hace** | **Azure real** |
|---|---|---|
| `features {}` | Bloque anidado obligatorio; ajusta comportamientos globales (sección 3.3) | Igual |
| `metadata_host` | Host del que el provider descarga `/metadata/endpoints` para saber dónde están ARM, la autoridad de tokens, Storage, etc. Es lo que hace que Terraform hable con el emulador y no con Azure | Se omite (usa `management.azure.com`) |
| `resource_provider_registrations` | Qué resource providers de ARM registra el provider al arrancar. Topaz no implementa ese registro, así que `"none"` | Se omite (valor `"core"`). Sustituye a `skip_provider_registration` de la 3.x |
| `subscription_id` | Suscripción de trabajo. Obligatorio en 4.x | Tu suscripción |

> 🚨 **⚠️ Error común.** Omitir `features {}` produce, literalmente: *Error: Insufficient features blocks — At least 1 "features" blocks are required.* Material antiguo cita *missing required argument "features"*; el texto cambió, la causa es la misma.

> **🔷 En Topaz.** Azure CLI usa exactamente el mismo mecanismo: cuando registraste la nube con `az cloud register --name Topaz --endpoint-resource-manager ...` (o desde la URL de metadatos), le diste la misma información que `metadata_host` le da al provider. Dos clientes, un solo punto de descubrimiento: `curl -sk https://topaz.local.dev:8899/metadata/endpoints?api-version=2022-09-01 | jq` te muestra lo que ambos leen.

---

## 2. Métodos de autenticación

El provider decide cómo autenticarse según lo que encuentre configurado, con esta prioridad: argumentos explícitos del bloque, variables de entorno `ARM_*`, y, si nada indica otra cosa, la sesión de Azure CLI. Los métodos disponibles son cuatro:

| **Método** | **Para** | **Topaz** |
|---|---|---|
| Azure CLI (`az login`) | Desarrollo, aprendizaje | ✅ El método del curso |
| Entidad de servicio (secreto, certificado u OIDC) | Pipelines CI/CD, producción | ❌ No hay Entra ID en el emulador |
| Identidad administrada | Terraform ejecutándose dentro de Azure | ❌ Requiere un recurso real de Azure |
| Variables `ARM_*` | Cualquier método, sin tocar el `.tf` | ✅ Para `metadata_host` y compañía |

### 2.1. Azure CLI (el método del laboratorio)

> **✅ Pasos**
> ```bash
> az cloud set --name Topaz                 # Azure real: az cloud set --name AzureCloud
> az login --use-device-code                # usuario topazadmin
> az account show --query '{cloud:environmentName, sub:id, user:user.name}' -o json
> # Esperado: "cloud": "Topaz", "sub": "00000000-0000-0000-0000-000000000001"
> ```
> El provider reutiliza el token de la CLI: no hay que escribir ninguna credencial en el `.tf`. Si tienes varias suscripciones en Azure real, `az account set --subscription "<nombre-o-id>"` antes de trabajar.

> **🔷 En Topaz.** Los tokens del emulador caducan pronto. Si un `plan` que ayer funcionaba falla con `401` o *obtaining Authorization Token from the Azure CLI*, no es tu código: repite `az login`. Y si recreaste el contenedor, la sesión anterior no vale: certificado → `az login` → Terraform, en ese orden.

### 2.2. Entidad de servicio (Azure real)

Una identidad de aplicación con permisos acotados y sin interacción humana. Es el estándar en pipelines. El bloque `provider` no cambia; las credenciales entran por el entorno:

```bash
# Crear la entidad (una vez, con permisos de administrador)
az ad sp create-for-rbac --name sp-terraform-curso --role Contributor \
  --scopes /subscriptions/<id-suscripcion>

# En el runner del pipeline (variables protegidas, nunca en el repositorio)
export ARM_SUBSCRIPTION_ID="..."
export ARM_TENANT_ID="..."
export ARM_CLIENT_ID="..."
export ARM_CLIENT_SECRET="..."      # o ARM_CLIENT_CERTIFICATE_PATH, o ARM_USE_OIDC=true
```

```hcl
provider "azurerm" {
  features {}                       # sin cambios
}
```

> 🚨 **⚠️ Seguridad.** `ARM_CLIENT_SECRET` nunca va en un `.tf`, un `.tfvars` ni en Git. Usa los secretos protegidos de tu plataforma CI/CD, Azure Key Vault o, mejor aún, **OIDC** (federación de identidad): sin secreto que rotar ni filtrar. En Topaz nada de esto aplica: el usuario `topazadmin` lo puede todo y no existen entidades de servicio.

### 2.3. Identidad administrada (Azure real)

Cuando Terraform corre dentro de un recurso de Azure con identidad asignada (VM, App Service, agente de DevOps en Azure, Cloud Shell), no hace falta ninguna credencial:

```bash
export ARM_USE_MSI=true
export ARM_SUBSCRIPTION_ID="..."
# Requisito: la identidad del recurso tiene un rol (p. ej. Contributor) en el ámbito donde despliega
az role assignment create --assignee <principal-id> --role Contributor --scope /subscriptions/<id>
```

### 2.4. Variables `ARM_*`: el mismo código en Topaz y en Azure

Todo argumento del provider tiene equivalente en variable de entorno. Si exportas las de Topaz, el bloque queda idéntico al de producción:

```bash
# ~/.bashrc del laboratorio
export ARM_METADATA_HOSTNAME=topaz.local.dev:8899
export ARM_RESOURCE_PROVIDER_REGISTRATIONS=none
export ARM_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000001
```

```hcl
# El .tf ya no sabe nada del emulador:
provider "azurerm" {
  features {}
}
```

Los argumentos explícitos en el bloque ganan a las variables de entorno, así que si mantienes las tres líneas en el `.tf` las variables no tienen efecto: elige un estilo y sé consistente.

---

## 3. Configuración avanzada

### 3.1. Nubes distintas de la pública: `environment` y `metadata_host`

El provider soporta dos formas de apuntar a algo que no sea Azure público:

```hcl
# Nubes soberanas conocidas: environment
provider "azurerm" {
  features {}
  environment     = "usgovernment"      # o "china". Azure Alemania cerró en 2021
  subscription_id = "..."
}

# Nubes personalizadas (Azure Stack Hub, emuladores): metadata_host
provider "azurerm" {
  features {}
  metadata_host                   = "topaz.local.dev:8899"
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}
```

`environment` selecciona un conjunto de endpoints precargado; `metadata_host` los descubre en tiempo de ejecución. Son excluyentes: si defines `metadata_host`, no pongas `environment`. Topaz es, a efectos del provider, una nube más: por eso el resto de la configuración es idéntica.

### 3.2. Varios providers: `alias`

Para desplegar en varias suscripciones o nubes desde una misma configuración. En Topaz solo hay una suscripción, pero la mecánica se practica igual:

```hcl
provider "azurerm" {                    # por defecto (sin alias)
  features {}
  metadata_host                   = "topaz.local.dev:8899"
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}

provider "azurerm" {
  alias = "compartido"                  # en Azure real: otra subscription_id (hub, conectividad...)
  features {}
  metadata_host                   = "topaz.local.dev:8899"
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}

resource "azurerm_resource_group" "app" {
  name     = "rg-alias-app"
  location = "eastus"                   # usa el provider por defecto
}

resource "azurerm_resource_group" "hub" {
  provider = azurerm.compartido         # TIPO.ALIAS, sin comillas
  name     = "rg-alias-hub"
  location = "eastus"
}
```

Un alias no puede configurarse con variables de entorno distintas por instancia: si dos alias necesitan credenciales diferentes en Azure real, esas diferencias van en el bloque (o en un módulo con `providers = { azurerm = azurerm.compartido }`).

### 3.3. El bloque `features` no está vacío

Contiene sub-bloques que cambian el comportamiento global de familias de recursos. Estos son los más útiles, con los valores por defecto comentados:

```hcl
provider "azurerm" {
  features {
    resource_group {
      # false: destroy borra el grupo aunque contenga recursos creados fuera de Terraform
      prevent_deletion_if_contains_resources = false      # defecto: true
    }
    key_vault {
      # Key Vault tiene borrado suave; estas dos hacen que destroy lo elimine del todo
      purge_soft_delete_on_destroy    = true               # defecto: true
      recover_soft_deleted_key_vaults = true               # defecto: true
    }
    virtual_machine {
      delete_os_disk_on_deletion = true                    # defecto: true
    }
    template_deployment {
      delete_nested_items_during_deletion = true           # defecto: true
    }
  }
  metadata_host                   = "topaz.local.dev:8899"
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}
```

> **🔷 En Topaz.** `prevent_deletion_if_contains_resources = false` es práctico en el laboratorio: si creaste algo con `az` dentro de un grupo gestionado por Terraform, `destroy` no se detendrá. Los de `key_vault` dependen de que el emulador implemente el borrado suave; si un `destroy` de Key Vault falla en Topaz, prueba con `purge_soft_delete_on_destroy = false`.

### 3.4. Otros argumentos que conviene conocer

- `storage_use_azuread = true`: el provider accede al plano de datos de Storage con el token de Entra ID en vez de con las claves de la cuenta. En Topaz déjalo por defecto.
- `partner_id`: GUID de atribución para partners de Microsoft. Sin efecto en el emulador.
- `disable_terraform_partner_id = true`: evita que el provider añada su propio identificador a las peticiones.

---

## 4. Relación con `terraform` y `resource`

### 4.1. El bloque `terraform` dice qué versión; el bloque `provider` dice cómo conectar

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"          # >= 4.0.0 y < 5.0.0; metadata_host requiere 4.x
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

El nombre local `azurerm` de `required_providers` es el que enlaza con la etiqueta `provider "azurerm"` y con el prefijo `azurerm_` de cada recurso. Tras `init`, `terraform providers` muestra qué versión exacta se instaló y `.terraform.lock.hcl` la fija para todo el equipo.

> 🚨 **⚠️ Versiones.** Sin restricción, `init` instala la última versión; un salto de mayor (3.x → 4.x) cambió argumentos del propio provider (`skip_provider_registration` desapareció, `subscription_id` pasó a ser obligatorio). Usa siempre `~>` y actualiza de forma consciente con `terraform init -upgrade`.

### 4.2. Los recursos usan el provider implícita o explícitamente

```hcl
# Un solo provider: uso implícito
resource "azurerm_resource_group" "app" {
  name     = "rg-app-dev-001"
  location = "eastus"
}

# Varios providers: el meta-argumento provider elige
resource "azurerm_resource_group" "hub" {
  provider = azurerm.compartido
  name     = "rg-hub-dev-001"
  location = "eastus"
}
```

---

## 5. LAB: verificar el provider

Un proyecto mínimo para comprobar que el provider autentica, descubre los endpoints del emulador y crea un recurso. Usa `random_string` para el nombre único: la función `timestamp()` que aparece en algunos tutoriales cambia en cada ejecución y obliga a reemplazar el recurso en cada `apply`.

### Paso 1. Proyecto

```bash
mkdir -p ~/provider-lab && cd ~/provider-lab
```

```hcl
# archivo: main.tf
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  metadata_host                   = "topaz.local.dev:8899"
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}

variable "ubicacion" {
  type    = string
  default = "eastus"
}

resource "random_string" "sufijo" {
  length  = 4
  upper   = false
  special = false
}

resource "azurerm_resource_group" "verificacion" {
  name     = "rg-provider-lab-${random_string.sufijo.result}"
  location = var.ubicacion
  tags = {
    entorno   = "verificacion"
    proposito = "provider-config"
  }
  lifecycle {
    ignore_changes = [tags]        # Topaz no devuelve las tags del grupo
  }
}

output "grupo" {
  value = azurerm_resource_group.verificacion.name
}

output "id_grupo" {
  value = azurerm_resource_group.verificacion.id
}
```

### Paso 2. `init` y comprobación de versiones

```bash
terraform init
terraform providers
# Providers required by configuration:
# ├── provider[registry.terraform.io/hashicorp/azurerm] ~> 4.0
# └── provider[registry.terraform.io/hashicorp/random] ~> 3.6
grep -A1 'hashicorp/azurerm' .terraform.lock.hcl     # versión exacta instalada
```

`init` no toca el emulador: si falla aquí, es Internet o el bloque `terraform`.

### Paso 3. `plan`: primer contacto con Topaz

```bash
terraform plan
# Plan: 2 to add, 0 to change, 0 to destroy.
```

Si el plan llega a listar los recursos, el provider ha autenticado y ha leído los endpoints del emulador. Para verlo con tus propios ojos:

```bash
TF_LOG=DEBUG terraform plan 2>&1 | grep -m3 -iE 'metadata|topaz.local.dev'
# Verás la petición a https://topaz.local.dev:8899/metadata/endpoints y las llamadas a ARM del emulador
```

### Paso 4. `apply` y verificación cruzada

```bash
terraform apply -auto-approve
# Apply complete! Resources: 2 added...
# grupo = "rg-provider-lab-k3x9"

RG=$(terraform output -raw grupo)
az group show -n $RG --query '{nombre:name, ubicacion:location, estado:properties.provisioningState}' -o json
terraform output -raw id_grupo      # empieza por /subscriptions/00000000-0000-0000-0000-000000000001/
terraform plan                      # No changes.
```

> **🔷 En Topaz no hay Portal.** La verificación independiente es Azure CLI: otro cliente, misma API. El `id` con la suscripción `...0001` es la prueba de que no has tocado Azure real.

### Paso 5. Provoca los tres errores clásicos

```bash
# a) Comenta features {...} → plan:   Insufficient features blocks
# b) Comenta metadata_host   → plan:   SubscriptionNotFound (¡estás hablando con Azure real!)
# c) Comenta subscription_id → plan:   subscription_id is a required provider property
# Restaura el archivo tras cada prueba: terraform plan debe volver a decir "No changes."
```

### Paso 6. Limpiar

```bash
terraform destroy -auto-approve
az group list --query "[?starts_with(name,'rg-provider-lab')].name" -o tsv    # vacío
```

---

## 6. Preguntas frecuentes

> **¿Qué pasa si olvido `features {}`?**  
> *Insufficient features blocks: At least 1 "features" blocks are required.* Es obligatorio desde la 2.0, aunque esté vacío.

> **¿Cómo sé a qué nube y suscripción apunta mi configuración?**  
> Antes de ejecutar: `az account show --query '{cloud:environmentName, sub:id}'` y el `metadata_host` / `subscription_id` del bloque (o `env | grep ARM_`). Tras un `apply`, cualquier `id` de recurso lleva la suscripción. `terraform plan` no la muestra por sí mismo.

> **¿Por qué `SubscriptionNotFound` si la suscripción está bien escrita?**  
> Falta `metadata_host`: Terraform ha ido a Azure real, donde la suscripción `...0001` no existe. Es el error más frecuente al copiar un provider de un tutorial.

> **¿Puedo tener varios providers azurerm?**  
> Sí, con `alias`, y eligiéndolo en cada recurso con `provider = azurerm.<alias>`. En Topaz todos apuntan a la misma suscripción; en Azure real es la forma habitual de desplegar en varias.

> **¿Es seguro poner `client_secret` en un `.tfvars`?**  
> No. Los `.tfvars` acaban en Git con la misma facilidad que los `.tf`. Variables protegidas del pipeline, Key Vault u OIDC.

> **¿Qué versión uso en producción?**  
> `~> 4.0` (o más ajustada, `~> 4.20`), con el `.terraform.lock.hcl` versionado. Nunca sin restricción.

> **¿Qué cambia cuando pase de Topaz a Azure real?**  
> Quitar `metadata_host` y `resource_provider_registrations`, poner tu `subscription_id` y hacer `az cloud set --name AzureCloud && az login`. El resto del código no se toca.

---

## 7. Buenas prácticas y errores comunes

> **✅ Buenas prácticas**
> - `features {}` siempre; úsalo para fijar comportamientos globales de forma explícita.
> - Provider en `versions.tf`: lo único que cambia entre Topaz y Azure real vive en un solo archivo.
> - Configuración del entorno por variables `ARM_*` cuando quieras un `.tf` portable.
> - Versión restringida (`~>`) y lock file en Git; `init -upgrade` de forma deliberada.
> - En Azure real: entidad de servicio con mínimo privilegio, preferiblemente OIDC; secretos solo en el almacén del pipeline.
> - Documenta en un comentario qué método de autenticación usa cada entorno.

> 🚨 **⚠️ Errores comunes**
> - **Sin `features`** → *Insufficient features blocks*.
> - **Sin `metadata_host`** en Topaz → *SubscriptionNotFound*: has hablado con Azure real.
> - **Sin `subscription_id`** en 4.x → *subscription_id is a required provider property*.
> - **`skip_provider_registration`** copiado de un ejemplo 3.x → *Unsupported argument*; ahora es `resource_provider_registrations`.
> - **Sesión de `az` en otra nube** → `401`; comprueba `environmentName`.
> - **Certificado obsoleto** tras recrear el contenedor → *x509: certificate signed by unknown authority*.
> - **Secretos en el código**: en Topaz no hay, pero el hábito de no escribirlos se adquiere ahora.
> - **`version = "latest"`** no existe; omitir la versión equivale a "la que toque hoy".

---

## 8. Referencias

- [Provider azurerm: referencia de argumentos](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs) (`metadata_host`, `features`, `resource_provider_registrations`)
- [Guía del bloque `features`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/features-block): todos los sub-bloques y sus valores por defecto
- [Autenticación con Azure CLI](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/azure_cli)
- [Autenticación con entidad de servicio (secreto)](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/service_principal_client_secret) y [con OIDC](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/service_principal_oidc)
- [Autenticación con identidad administrada](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/managed_service_identity)
- [Guía de migración a azurerm 4.0](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/4.0-upgrade-guide) (`subscription_id` obligatorio, `resource_provider_registrations`)
- [Configuración de providers y `alias`](https://developer.hashicorp.com/terraform/language/providers/configuration) (documentación de Terraform)
- [Restricciones de versión y `.terraform.lock.hcl`](https://developer.hashicorp.com/terraform/language/providers/requirements)
- [Recurso `random_string`](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string)
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md): endpoints de metadatos y servicios soportados