# 🌐 Introducción a Azure y Terraform

> Este curso enseña a describir infraestructura de Azure como código con Terraform. En esta primera página verás las tres piezas que usarás en todos los laboratorios: **Azure** (qué es y cómo organiza sus recursos), **Terraform** (qué hace y cómo se trabaja con él) y **Topaz**, el emulador local de Azure contra el que ejecutarás cada ejemplo sin necesidad de suscripción ni coste. Al final desplegarás tu primera infraestructura y la verificarás con la Azure CLI.

> **🎯 Objetivos de aprendizaje**
>
> - Explicar la jerarquía de Azure: tenant, suscripción, grupo de recursos y recurso.
> - Describir qué es la infraestructura como código y qué aporta Terraform.
> - Entender qué es Topaz, qué emula y qué no.
> - Configurar el provider `azurerm` para el emulador y saber cómo cambia en Azure real.
> - Ejecutar el ciclo `init → plan → apply → destroy` sobre un grupo de recursos y una red virtual.

## 1. ¿Qué es Azure?

Microsoft Azure es la plataforma de nube pública de Microsoft: más de doscientos servicios (cómputo, red, almacenamiento, bases de datos, contenedores, IA) que se alquilan por uso y se gestionan a través de una única API, **Azure Resource Manager (ARM)**. Todo lo que hagas en Azure, desde el Portal, la CLI o Terraform, acaba en una llamada a esa API. Por eso Terraform puede gestionar cualquier recurso: habla con ARM igual que lo haría el Portal.

### Jerarquía de recursos

```text
Tenant (Microsoft Entra ID)          ← identidad: usuarios, grupos, aplicaciones
└── Suscripción                       ← facturación y límite de permisos
    └── Grupo de recursos             ← contenedor lógico con ciclo de vida común
        ├── Red virtual
        │   └── Subred
        ├── Cuenta de almacenamiento
        └── Máquina virtual ...
```

| Nivel | Qué es | En Terraform |
|---|---|---|
| **Tenant** | Directorio de identidades de la organización | `tenant_id` en el provider (Azure real) |
| **Suscripción** | Unidad de facturación; los permisos (RBAC) se asignan aquí o por debajo | `subscription_id` en el provider |
| **Grupo de recursos** | Carpeta lógica: lo que nace y muere junto va en el mismo grupo | `azurerm_resource_group`; casi todo recurso exige `resource_group_name` |
| **Recurso** | Red, cuenta de almacenamiento, VM… Cada uno pertenece a un *resource provider* (`Microsoft.Network`, `Microsoft.Storage`, `Microsoft.Compute`) | Un bloque `resource` por recurso |

Dos conceptos más que aparecen en cada laboratorio. La **región** (`location`) es el centro de datos donde vive el recurso; en código se usa el nombre corto (`eastus`, `westeurope`), no el largo ("East US"). Y el **ID de recurso** es una ruta única que codifica toda la jerarquía; lo verás en los outputs:

```text
/subscriptions/<id>/resourceGroups/rg-intro-001/providers/Microsoft.Network/virtualNetworks/vnet-intro
```

## 2. ¿Qué es Terraform?

Terraform es una herramienta de **infraestructura como código** (IaC) de HashiCorp. En lugar de crear recursos a mano o con scripts que dicen *cómo* hacerlo, escribes archivos que describen *qué* quieres que exista, y Terraform calcula y ejecuta los pasos necesarios para llegar a ese estado. Eso es lo que significa **declarativo**:

```hcl
# Imperativo (script): dice CÓMO, y falla si se ejecuta dos veces
az group create -n rg-intro-001 -l eastus
az network vnet create -g rg-intro-001 -n vnet-intro --address-prefixes 10.0.0.0/16

# Declarativo (Terraform): dice QUÉ, y se puede aplicar mil veces
resource "azurerm_resource_group" "lab" {
  name     = "rg-intro-001"
  location = "eastus"
}
```

> **Qué aporta**
>
> - **Reproducibilidad**: el mismo código produce la misma infraestructura en dev, test y prod.
> - **Estado**: Terraform recuerda qué ha creado (`terraform.tfstate`) y solo cambia lo que difiere entre código y realidad.
> - **Plan previo**: antes de tocar nada muestra exactamente qué va a crear, modificar o destruir.
> - **Multi-proveedor**: Azure, AWS, Google Cloud, Kubernetes, GitHub… con la misma sintaxis. El código de Azure lo aporta el **provider `azurerm`**.
> - **Módulos**: bloques reutilizables que un equipo comparte y versiona.

### El ciclo de trabajo

| Comando | Qué hace | ¿Habla con Azure? |
|---|---|---|
| `terraform init` | Descarga providers y módulos; crea `.terraform/` y el *lock file* | No (solo con el Registry) |
| `terraform plan` | Compara código, estado y realidad; muestra `+` crear, `~` cambiar, `-` destruir, `-/+` reemplazar | Sí, solo lectura |
| `terraform apply` | Ejecuta el plan y actualiza el estado | Sí, escritura |
| `terraform destroy` | Elimina todo lo que gestiona el estado | Sí, escritura |

Los archivos tienen extensión `.tf` y se escriben en **HCL** (HashiCorp Configuration Language). Terraform lee todos los `.tf` de un directorio como una única configuración; la división en `providers.tf`, `main.tf`, `outputs.tf` es una convención para las personas.

## 3. ¿Qué es Topaz?

**Topaz** (Azure Local Emulator) es un emulador de la API de Azure Resource Manager que se ejecuta en un contenedor local. Expone los mismos endpoints que Azure para un subconjunto de servicios, de modo que Terraform y la Azure CLI funcionan contra él sin cambiar de herramienta. En este curso es el entorno de práctica: **sin suscripción, sin coste y sin riesgo** de dejar recursos encendidos.

| Aspecto | Azure real | Topaz |
|---|---|---|
| Endpoint ARM | `management.azure.com` | `topaz.local.dev:8899` |
| Suscripción | La tuya, con facturación | `00000000-0000-0000-0000-000000000001`, fija |
| Identidad | Entra ID: usuarios, service principals, identidades administradas | Sesión de `az login` contra la nube `Topaz`; sin Entra ID |
| Herramientas | Portal, CLI, PowerShell, Terraform… | CLI y Terraform. **No hay Portal web**: se verifica todo con `az` |
| Servicios | Todos | Grupos de recursos, red y almacenamiento (plano de control). Sin Compute, bases de datos ni AKS |

> **🔷 Cómo leer las páginas del curso.** Cada laboratorio funciona en Topaz tal como está escrito. Cuando algo difiere de Azure real (un atributo que el emulador no devuelve, un servicio que no existe, un mecanismo de la plataforma como Azure Policy), aparece en un recuadro azul como este. La limitación que verás más veces: el emulador no devuelve las etiquetas del grupo de recursos, por lo que ese recurso lleva siempre `lifecycle { ignore_changes = [tags] }`.

### Verificar el entorno

```bash
terraform version                                 # Terraform v1.x
az version --query '"azure-cli"' -o tsv           # 2.x
az account show --query environmentName -o tsv    # Topaz   ← si dice AzureCloud, no estás en el emulador
az account show --query id -o tsv                 # 00000000-0000-0000-0000-000000000001
az group list -o table                            # vacío al empezar
```

## 4. Autenticación y configuración del provider

El provider `azurerm` necesita saber **a qué Azure** conectarse y **como quién**. En Topaz la respuesta es simple: al endpoint del emulador, con la sesión de la CLI. Este es el bloque que usarás en todos los laboratorios:

```hcl
# providers.tf
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
  features {}                                                     # obligatorio aunque esté vacío
  metadata_host                   = "topaz.local.dev:8899"        # endpoint del emulador
  resource_provider_registrations = "none"                        # no registrar providers al arrancar
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}
```

| Argumento | Por qué está |
|---|---|
| `features {}` | El provider lo exige siempre; dentro se ajustan comportamientos (p. ej. si borrar discos al eliminar una VM) |
| `metadata_host` | Indica al provider que descubra los endpoints en el emulador y no en Azure público |
| `resource_provider_registrations = "none"` | Por defecto el provider intenta registrar decenas de *resource providers* en la suscripción; el emulador no implementa esa operación |
| `subscription_id` | Obligatorio desde la versión 4.0 del provider |

### Autenticación en Azure real

Contra una suscripción real desaparecen `metadata_host` y `resource_provider_registrations`, y hay que elegir cómo se identifica Terraform. El original mostraba `client_secret = "tu-client-secret"` escrito en el `.tf`: es la forma que el curso enseña a evitar, porque ese archivo acaba en Git.

| Método | Cómo | Cuándo |
|---|---|---|
| Azure CLI | `az login`; el provider hereda la sesión | Trabajo interactivo de una persona (y Topaz) |
| OIDC | `use_oidc = true` + `ARM_CLIENT_ID`, `ARM_TENANT_ID` | Pipelines: sin ningún secreto almacenado |
| Identidad administrada | `use_msi = true` | Terraform ejecutándose dentro de Azure |
| Service principal con secreto | Variables de entorno `ARM_CLIENT_ID`, `ARM_CLIENT_SECRET`, `ARM_TENANT_ID`, `ARM_SUBSCRIPTION_ID` | Cuando no hay alternativa; nunca en el `.tf` |

> **🔷 En Topaz.** No existe Entra ID, así que OIDC, identidades administradas y service principals no aplican. La CLI autenticada contra la nube `Topaz` es la única vía, y el provider la usa sin configuración adicional. Los métodos de la tabla se practican en el módulo de Azure real.

## 5. Servicios principales de Azure

Los que aparecen en cualquier arquitectura, con el recurso Terraform correspondiente y su disponibilidad en el emulador:

| Servicio | Para qué | Recurso Terraform | En Topaz |
|---|---|---|---|
| Grupos de recursos | Contenedor lógico de todo lo demás | `azurerm_resource_group` | ✅ |
| Redes virtuales y subredes | Red privada donde se conectan los recursos | `azurerm_virtual_network`, `azurerm_subnet` | ✅ |
| Almacenamiento | Blobs, archivos, colas, tablas | `azurerm_storage_account` | ✅ recurso; sin plano de datos (no se suben blobs) |
| Máquinas virtuales | Cómputo IaaS Linux y Windows | `azurerm_linux_virtual_machine` | ❌ sin `Microsoft.Compute` |
| Bases de datos | SQL Database, PostgreSQL, Cosmos DB gestionados | `azurerm_mssql_server`, `azurerm_cosmosdb_account` | ❌ |
| Kubernetes (AKS) | Orquestación de contenedores | `azurerm_kubernetes_cluster` | ❌ |
| Key Vault | Secretos, claves y certificados | `azurerm_key_vault` | ❌ |

Los tres primeros bastan para aprender todo lo que Terraform tiene que enseñar (variables, outputs, estado, módulos, pruebas). Los demás se tratan en el módulo de Azure real, donde el mismo código, cambiando solo el provider, despliega en una suscripción de verdad.

## 6. Ejemplo: tu primera infraestructura

Un grupo de recursos y una red virtual, los dos recursos del ejemplo original, ahora con el provider configurado para Topaz y verificados con la CLI.

### Paso 1. Directorio y archivos

```bash
mkdir -p ~/tf-intro && cd ~/tf-intro
```

Crea `providers.tf` con el bloque de la sección 1.4 y después estos dos archivos:

```hcl
# main.tf
resource "azurerm_resource_group" "lab" {
  name     = "rg-intro-001"
  location = "eastus"                    # nombre corto, no "East US"
  tags = {
    entorno = "lab"
    gestion = "terraform"
  }

  lifecycle {
    ignore_changes = [tags]              # Topaz no devuelve las tags del grupo
  }
}

resource "azurerm_virtual_network" "lab" {
  name                = "vnet-intro"
  location            = azurerm_resource_group.lab.location   # referencia: crea la dependencia
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["10.0.0.0/16"]
  tags                = azurerm_resource_group.lab.tags
}
```

```hcl
# outputs.tf
output "grupo_recursos" {
  description = "Nombre del grupo de recursos"
  value       = azurerm_resource_group.lab.name
}

output "red_virtual_id" {
  description = "ID completo de la red virtual: observa la jerarquía"
  value       = azurerm_virtual_network.lab.id
}
```

Fíjate en `azurerm_resource_group.lab.name`: la red no repite el nombre del grupo, lo **referencia**. Así Terraform sabe que debe crear primero el grupo, y si algún día cambias el nombre, cambia en un solo sitio.

### Paso 2. `init` y `plan`

```bash
terraform init
#   Installing hashicorp/azurerm v4.x...
#   Terraform has been successfully initialized!
ls -a                                    # aparecen .terraform/ y .terraform.lock.hcl

terraform plan
```

```text
Terraform will perform the following actions:

  # azurerm_resource_group.lab will be created
  + resource "azurerm_resource_group" "lab" {
      + id       = (known after apply)
      + location = "eastus"
      + name     = "rg-intro-001"
    }

  # azurerm_virtual_network.lab will be created
  + resource "azurerm_virtual_network" "lab" {
      + address_space       = [ + "10.0.0.0/16" ]
      + name                = "vnet-intro"
      + resource_group_name = "rg-intro-001"
    }

Plan: 2 to add, 0 to change, 0 to destroy.
```

`(known after apply)` significa que ese valor lo asigna Azure al crear el recurso; Terraform lo guardará en el estado.

### Paso 3. `apply` y verificación

```bash
terraform apply                          # escribe "yes" cuando lo pida
#   Apply complete! Resources: 2 added, 0 changed, 0 destroyed.
#   Outputs:
#   grupo_recursos = "rg-intro-001"
#   red_virtual_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-intro-001/providers/Microsoft.Network/virtualNetworks/vnet-intro"

# Comprobar con la CLI que existe de verdad en el emulador
az group show -n rg-intro-001 --query "{nombre:name, region:location}" -o table
az network vnet list -g rg-intro-001 --query "[].{nombre:name, rango:addressSpace.addressPrefixes[0]}" -o table

# Idempotencia: un segundo plan no propone nada
terraform plan
#   No changes. Your infrastructure matches the configuration.
```

> **🔷 En Topaz.** Sin el `ignore_changes` del grupo, ese segundo `plan` mostraría `~ tags` en cada ejecución: el emulador acepta las etiquetas pero no las devuelve al leer, y Terraform intentaría "corregirlas" eternamente. La red virtual sí las devuelve, por eso no necesita la excepción.

### Paso 4. Un cambio y la limpieza

```bash
# Edita main.tf: address_space = ["10.0.0.0/16", "10.1.0.0/16"]
terraform plan
#   ~ address_space = [ "10.0.0.0/16", + "10.1.0.0/16" ]
#   Plan: 0 to add, 1 to change, 0 to destroy.       ← modifica en sitio, no recrea
terraform apply -auto-approve

terraform destroy                        # escribe "yes"
#   Destroy complete! Resources: 2 destroyed.
az group list -o table                   # vacío
```

Acabas de recorrer el ciclo completo: describir, planificar, aplicar, cambiar, destruir. Todo lo que sigue en el curso son formas de hacer ese ciclo más seguro, reutilizable y colaborativo.

## 7. Errores comunes

| Mensaje o síntoma | Causa y solución |
|---|---|
| *building account: could not acquire access token* | No hay sesión de CLI: `az login` contra la nube Topaz y comprueba `environmentName` |
| *connection refused* / *no such host topaz.local.dev* | Contenedor parado o certificado no instalado: revisa la guía de instalación del entorno |
| *subscription_id is a required provider property* | Provider 4.x exige el argumento: añádelo al bloque |
| El `plan` tarda y falla registrando *resource providers* | Falta `resource_provider_registrations = "none"` |
| Los recursos aparecen en Azure público, no en el emulador | Falta `metadata_host` o la CLI está en `AzureCloud` |
| *Missing required argument: features* | El bloque `features {}` es obligatorio aunque esté vacío |
| `~ tags` en cada `plan` del grupo de recursos | Limitación de Topaz: `lifecycle { ignore_changes = [tags] }` |
| *Missing newline after argument* con HTML dentro del `.tf` | El filtro de auto-enlace de Moodle se coló al copiar: `sed -i 's/<[^>]*>//g' *.tf` |

## 8. Autoevaluación

1. **¿Qué diferencia hay entre una suscripción y un grupo de recursos?**  
   La suscripción es la unidad de facturación y permisos; el grupo es un contenedor lógico dentro de ella para recursos con el mismo ciclo de vida.

2. **¿Qué significa que Terraform es declarativo?**  
   Describes el estado final deseado, no los pasos; Terraform calcula la diferencia con la realidad y la aplica, tantas veces como quieras con el mismo resultado.

3. **¿Cuál de los cuatro comandos del ciclo no habla con Azure?**  
   `terraform init`: solo descarga providers del Registry.

4. **¿Para qué sirven `metadata_host` y `resource_provider_registrations = "none"`?**  
   El primero dirige el provider al emulador; el segundo evita que intente registrar resource providers, operación que Topaz no implementa.

5. **¿Por qué no debe ir `client_secret` en el `.tf`?**  
   Ese archivo se versiona; el secreto acabaría en Git. Se usan variables de entorno `ARM_*`, o mejor OIDC, que no requiere secreto.

6. **¿Qué tres servicios del laboratorio existen en Topaz y cuál es el más notable que falta?**  
   Grupos de recursos, red y almacenamiento. Falta `Microsoft.Compute`: no hay máquinas virtuales.

7. **¿Por qué la red virtual usa `azurerm_resource_group.lab.name` en vez de escribir `"rg-intro-001"`?**  
   La referencia crea la dependencia (el grupo se crea antes) y evita duplicar el nombre.

## 9. Referencias

- [Azure Resource Manager: introducción](https://learn.microsoft.com/es-es/azure/azure-resource-manager/management/overview)
- [Organización de recursos: suscripciones y grupos](https://learn.microsoft.com/es-es/azure/cloud-adoption-framework/ready/azure-setup-guide/organize-resources) (Cloud Adoption Framework)
- [Resource providers y tipos de recurso](https://learn.microsoft.com/es-es/azure/azure-resource-manager/management/azure-services-resource-providers)
- [¿Qué es Terraform?](https://developer.hashicorp.com/terraform/intro) y [flujo de trabajo básico](https://developer.hashicorp.com/terraform/intro/core-workflow) (HashiCorp)
- [Sintaxis HCL](https://developer.hashicorp.com/terraform/language/syntax/configuration)
- [Provider `azurerm`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs) y [autenticación con Azure CLI](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/azure_cli)
- [`azurerm_resource_group`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group) y [`azurerm_virtual_network`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network)
- [Referencia de Azure CLI](https://learn.microsoft.com/es-es/cli/azure/)
- [Azure Local Emulator (Topaz)](https://github.com/Azure/azure-local-emulator)