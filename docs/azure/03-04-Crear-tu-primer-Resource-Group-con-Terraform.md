# 🧪 Lab: Crear tu primer Resource Group con Terraform

> **Un Resource Group (grupo de recursos)** es el contenedor lógico de Azure Resource Manager (ARM) en el que viven casi todos los recursos: redes, cuentas de almacenamiento, aplicaciones web. Es el primer recurso que se crea en cualquier proyecto y, por eso, el primero que vas a gestionar con Terraform. Trabajarás contra el **emulador Topaz**; donde difiere de Azure real, lo verás en un recuadro **🔷 En Topaz**.

**🎯 Objetivos de aprendizaje**
- Comprender qué es un Resource Group y por qué es el punto de partida.
- Definirlo en HCL con variables, etiquetas y outputs.
- Ejecutar el flujo completo: `init` → `plan` → `apply` → `destroy`.
- Verificar el resultado con Azure CLI, un cliente independiente de Terraform.
- Leer el estado local y entender qué guarda.
- Crear varios grupos con `for_each`.

> **🔷 Requisitos previos**
> - Contenedor `azure-environment` en marcha y certificado del emulador instalado.
> - Terraform ≥ 1.5 y Azure CLI autenticada en la nube `Topaz`.
> - Prueba de humo del módulo de instalación superada.
> 
> Comprobación en cinco segundos: `az account show --query environmentName -o tsv` debe responder `Topaz`.

---

## 1. ¿Por qué empezar con un Resource Group?

- **Organización:** agrupa todo lo que pertenece a una solución (la red, la base de datos y la web de una misma aplicación).
- **Ciclo de vida:** eliminar el grupo elimina todo su contenido. Es la forma más rápida de limpiar un laboratorio.
- **Control de acceso:** los roles RBAC asignados al grupo se heredan por sus recursos.
- **Etiquetado:** las etiquetas del grupo sirven para facturación y gobernanza. No se heredan automáticamente por los recursos: hace falta una Azure Policy, o declararlas en cada uno (lo que harás con `locals`).
- **Región:** el grupo tiene una ubicación (donde se guardan sus metadatos), pero puede contener recursos de otras regiones.

```text
Suscripción 00000000-0000-0000-0000-000000000001
├── rg-webapp-prod-001                (Resource Group)
│   ├── vnet-webapp                   (Red virtual)
│   ├── stwebappprod001               (Cuenta de almacenamiento)
│   └── app-webapp-prod               (App Service)
└── rg-datos-prod-001                 (Resource Group)
    └── kv-datos-prod                 (Key Vault)
```
*Figura 1: cada grupo agrupa los recursos de una solución dentro de la suscripción.*

> **🔷 En Topaz.** Los grupos de recursos están completamente soportados: crear, leer, actualizar, listar y eliminar. No hay RBAC (el usuario `topazadmin` lo puede todo) ni Azure Policy, así que la herencia de etiquetas no se puede practicar; el resto del comportamiento es el de Azure.

---

## 2. El código, bloque a bloque

Antes de ejecutar nada, conviene entender cada parte del archivo que vas a escribir.

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
```
**Propósito:** qué versión de Terraform y del provider se admiten. `~> 4.0` acepta cualquier 4.x pero nunca 5.0. La 4.x es necesaria porque es la que soporta `metadata_host`.

```hcl
provider "azurerm" {
  features {}
  metadata_host                   = "topaz.local.dev:8899"
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}
```
**Propósito:** cómo conectar con la nube. `features {}` es un bloque obligatorio desde la versión 2.0 (contiene ajustes globales opcionales; vacío significa "valores por defecto"). Las dos líneas siguientes apuntan al emulador; en Azure real se eliminan. `subscription_id` es obligatorio en la 4.x.
**Autenticación:** el provider reutiliza la sesión de `az login`. No hay credenciales en el archivo.

```hcl
variable "nombre_rg" {
  description = "Nombre del grupo de recursos"
  type        = string
  default     = "rg-lab-basico-001"
}

variable "ubicacion" {
  description = "Región de Azure"
  type        = string
  default     = "eastus"
}
```
**Propósito:** parámetros de entrada que hacen el código reutilizable. Un `default` debe ser un literal: no admite funciones ni referencias. Algunos tutoriales ponen `timestamp()` aquí para generar nombres únicos; no es válido, y en la sección de ejercicios verás la forma correcta (`random_string`).
**Tip:** las regiones que acepta el emulador se consultan con `az account list-locations -o table`. Usa `eastus`, que es la que sabemos que funciona en todos los servicios de Topaz.

```hcl
resource "azurerm_resource_group" "lab" {
  name     = var.nombre_rg
  location = var.ubicacion

  tags = {
    entorno = "laboratorio"
    curso   = "terraform-azure"
  }

  lifecycle {
    ignore_changes = [tags]
  }
}
```
**Propósito:** el grupo que se va a crear.
- `azurerm_resource_group`: tipo de recurso, definido por el provider.
- `lab`: *nombre local*, solo existe dentro de Terraform. **No** es el nombre en Azure.
- `name`: el nombre real en Azure, tomado de la variable.
- `tags`: etiquetas para organización y gobernanza. Sin `timestamp()`: una etiqueta que cambia en cada ejecución obliga a Terraform a proponer un cambio en cada `plan`, para siempre.
- `lifecycle.ignore_changes`: indica a Terraform que no intente "corregir" las etiquetas si la API devuelve algo distinto.

> **🔷 En Topaz: por qué `ignore_changes = [tags]`.** El emulador acepta las etiquetas al crear el grupo, pero no las devuelve al leerlo. Sin esta línea, cada `plan` posterior propondría volver a ponerlas. En Azure real la línea es inofensiva y puedes quitarla.

```hcl
output "nombre_del_rg" {
  description = "Nombre del grupo creado"
  value       = azurerm_resource_group.lab.name
}

output "id_del_rg" {
  description = "ID completo del grupo en ARM"
  value       = azurerm_resource_group.lab.id
}
```
**Propósito:** qué información muestra Terraform al terminar. Sirven para verificar sin salir de la terminal, para alimentar scripts (`terraform output -raw`) y para pasar valores entre configuraciones.

---

## 3. Paso a paso

### Paso 1. Comprobar la sesión

```bash
az account show --query '{cloud:environmentName, sub:id, user:user.name}' -o json
# "cloud": "Topaz"  "sub": "00000000-0000-0000-0000-000000000001"

# Si la nube no es Topaz o el token ha caducado:
az cloud set --name Topaz && az login --use-device-code
```

> ⚠️ **Este paso es crítico.** Si la sesión apunta a `AzureCloud` y el provider al emulador (o al revés), obtendrás errores de autenticación o, peor, crearás recursos donde no querías. En Azure real, aquí es donde eliges la suscripción con `az account set --subscription "..."`.

### Paso 2. Directorio de trabajo

```bash
mkdir -p ~/mi-primer-rg && cd ~/mi-primer-rg
```
Cada proyecto de Terraform vive en su propio directorio: ahí quedarán el estado y los providers descargados, y mezclar dos proyectos en uno es fuente de conflictos.

### Paso 3. Crear `main.tf`

Con tu editor (`code main.tf`, `nano main.tf`...) crea el archivo con este contenido, que es la unión de los bloques de la sección 2:

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
  default     = "rg-lab-basico-001"
}

variable "ubicacion" {
  description = "Región de Azure"
  type        = string
  default     = "eastus"
}

resource "azurerm_resource_group" "lab" {
  name     = var.nombre_rg
  location = var.ubicacion

  tags = {
    entorno = "laboratorio"
    curso   = "terraform-azure"
  }

  lifecycle {
    ignore_changes = [tags]
  }
}

output "nombre_del_rg" {
  description = "Nombre del grupo creado"
  value       = azurerm_resource_group.lab.name
}

output "id_del_rg" {
  description = "ID completo del grupo en ARM"
  value       = azurerm_resource_group.lab.id
}
```

### Paso 4. `terraform init`

```bash
terraform init
```

```text
Initializing the backend...
Initializing provider plugins...
- Finding hashicorp/azurerm versions matching "~> 4.0"...
- Installing hashicorp/azurerm v4.x.x...
- Installed hashicorp/azurerm v4.x.x (signed by HashiCorp)

Terraform has been successfully initialized!
```
Descarga el provider en `.terraform/` y crea `.terraform.lock.hcl` con la versión exacta. Este comando no habla con el emulador: si falla, es conexión a Internet o el bloque `terraform`.

### Paso 5. `terraform plan`

```bash
terraform plan
```

```text
Terraform will perform the following actions:

  # azurerm_resource_group.lab will be created
  + resource "azurerm_resource_group" "lab" {
      + id       = (known after apply)
      + location = "eastus"
      + name     = "rg-lab-basico-001"
      + tags     = {
          + "curso"   = "terraform-azure"
          + "entorno" = "laboratorio"
        }
    }

Plan: 1 to add, 0 to change, 0 to destroy.
```
El plan es el primer contacto con Topaz: el provider autentica, lee los endpoints y comprueba que el grupo no existe. Nada se modifica. Revisa que la acción sea `+ create`, que el nombre y la ubicación sean los esperados y que el `id` quede como *known after apply* (lo asigna ARM).

### Paso 6. `terraform apply`

```bash
terraform apply
# Terraform repite el plan y pregunta:
#   Enter a value: yes        ← exactamente "yes", en minúsculas
```

```text
azurerm_resource_group.lab: Creating...
azurerm_resource_group.lab: Creation complete after 1s [id=/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-lab-basico-001]

Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

Outputs:

id_del_rg = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-lab-basico-001"
nombre_del_rg = "rg-lab-basico-001"
```
Fíjate en el `id`: la suscripción `...0001` es la prueba de que has trabajado en el emulador y no en Azure real. Ha aparecido también un archivo nuevo, `terraform.tfstate`: lo verás en el paso 8.

### Paso 7. Verificar con Azure CLI

> **🔷 En Topaz no hay Portal.** La verificación independiente se hace con Azure CLI: es otro cliente hablando con la misma API, así que si `az` ve el grupo, el grupo existe de verdad.

```bash
az group show -n $(terraform output -raw nombre_del_rg) -o json
```

```json
{
  "id": "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-lab-basico-001",
  "location": "eastus",
  "name": "rg-lab-basico-001",
  "properties": { "provisioningState": "Succeeded" },
  "type": "Microsoft.Resources/resourceGroups"
}
```
Comprueba: el `id` coincide con el output, la ubicación es `eastus` y el estado es `Succeeded`. Las etiquetas no aparecen (es la limitación del emulador que motiva el `ignore_changes`); en Azure real las verías aquí. Cierra el círculo con `terraform plan`: debe decir *No changes*.

### Paso 8. Mirar dentro del estado

```bash
terraform state list                       # azurerm_resource_group.lab
terraform state show azurerm_resource_group.lab
jq '.resources[0].instances[0].attributes.id' terraform.tfstate
```
`terraform.tfstate` es el mapa entre tu código y los objetos reales: guarda el `id` que ARM asignó y todos los atributos leídos. Sin él, Terraform no sabría que `azurerm_resource_group.lab` es `rg-lab-basico-001`. Es un JSON legible, puede contener datos sensibles y en equipo se guarda en un backend remoto con bloqueo (Ejercicio 5).

### Paso 9. `terraform destroy`

```bash
terraform destroy
#   Enter a value: yes
```

```text
azurerm_resource_group.lab: Destroying... [id=/subscriptions/.../resourceGroups/rg-lab-basico-001]
azurerm_resource_group.lab: Destruction complete after 1s

Destroy complete! Resources: 1 destroyed.
```

```bash
az group list -o table                     # rg-lab-basico-001 ya no aparece
terraform state list                       # vacío
```
En Topaz no hay coste, pero el hábito de destruir lo que no se usa es de los que conviene fijar antes de trabajar con una suscripción real.

---

## 4. Variaciones y ejercicios

### 💡 Ejercicio 1: cambiar nombre y ubicación sin tocar el código

```bash
terraform plan -var nombre_rg=rg-tusiniciales-lab -var ubicacion=westeurope
# Alternativa: archivo terraform.tfvars con
#   nombre_rg = "rg-tusiniciales-lab"
#   ubicacion = "westeurope"
```
Las variables se sobrescriben desde la línea de comandos, desde `terraform.tfvars` o con `TF_VAR_nombre_rg`. Aplica y destruye para ver el ciclo completo con otros valores.

### 💡 Ejercicio 2: etiquetas con significado

```hcl
locals {
  tags = {
    entorno      = "laboratorio"
    curso        = "terraform-azure"
    propietario  = "tu-email@ejemplo.com"
    centro_coste = "CC-12345"
    proyecto     = "aprendizaje-terraform"
  }
}

resource "azurerm_resource_group" "lab" {
  name     = var.nombre_rg
  location = var.ubicacion
  tags     = local.tags
  lifecycle { ignore_changes = [tags] }
}
```
Declararlas en `locals` permite reutilizarlas en cada recurso que añadas después (`tags = local.tags`). Evita etiquetas que cambien solas, como fechas generadas con `timestamp()`: producen un cambio en cada `plan`.

### 💡 Ejercicio 3: nombres únicos con `random_string`

Es la forma correcta de evitar colisiones cuando varias personas comparten suscripción. El sufijo se genera una vez y se guarda en el estado, así que no cambia entre ejecuciones:

```hcl
# añade a required_providers:
#   random = { source = "hashicorp/random", version = "~> 3.6" }

resource "random_string" "sufijo" {
  length  = 4
  upper   = false
  special = false
}

resource "azurerm_resource_group" "lab" {
  name     = "${var.nombre_rg}-${random_string.sufijo.result}"    # rg-lab-basico-001-k3x9
  location = var.ubicacion
  lifecycle { ignore_changes = [tags] }
}
```
Tras cambiar `required_providers` hay que volver a ejecutar `terraform init`. El provider `random` no habla con ninguna nube: funciona igual en Topaz y en Azure real.

### 💡 Ejercicio 4: un grupo por entorno con `for_each`

Ejecutar tres veces `apply -var entorno=...` sobre el mismo estado no crea tres grupos: reemplaza el mismo. Para tener dev, test y prod a la vez, se declara una colección:

```hcl
variable "entornos" {
  type    = set(string)
  default = ["dev", "test", "prod"]
}

resource "azurerm_resource_group" "entorno" {
  for_each = var.entornos

  name     = "rg-miapp-${each.key}-001"
  location = var.ubicacion
  tags     = { entorno = each.key, curso = "terraform-azure" }
  lifecycle { ignore_changes = [tags] }
}

output "grupos" {
  value = [for rg in azurerm_resource_group.entorno : rg.name]
}
```

```bash
terraform apply                                  # Plan: 3 to add
az group list --query "[?starts_with(name,'rg-miapp')].name" -o tsv
terraform apply -var 'entornos=["dev","prod"]'   # Plan: 1 to destroy (test)
terraform destroy
```
Cada instancia se referencia como `azurerm_resource_group.entorno["dev"]`. Quitar un elemento del set destruye solo ese grupo.

### 💡 Ejercicio 5 (Azure real): estado remoto

En equipo, el estado se guarda en una cuenta de almacenamiento con bloqueo, para que dos personas no apliquen a la vez:

```bash
# Infraestructura previa (una vez, con az)
az group create -n rg-tfstate -l westeurope
az storage account create -n sttfstate$RANDOM -g rg-tfstate -l westeurope --sku Standard_LRS
az storage container create -n tfstate --account-name <nombre-cuenta>

# En el bloque terraform
backend "azurerm" {
  resource_group_name  = "rg-tfstate"
  storage_account_name = "<nombre-cuenta>"
  container_name       = "tfstate"
  key                  = "mi-primer-rg.tfstate"
}
# Y después: terraform init -migrate-state
```

> **🔷 En Topaz.** El backend `azurerm` usa el plano de datos de Storage del emulador, que requiere configuración adicional y no está pensado para guardar estado. En el curso trabajamos con estado local; guarda este ejercicio para tu primera suscripción real.

---

## 5. Buenas prácticas aplicadas

**✅ Qué has hecho bien**
- **Versiones fijadas** con `~>` y lock file generado.
- **Variables** para lo que cambia entre ejecuciones; literales en los `default`.
- **Nomenclatura** `rg-<app>-<entorno>-<instancia>`, la convención de Microsoft.
- **Etiquetas estables**, sin valores que cambian solos.
- **Plan antes de apply**, y lectura del plan: acción, nombre, ubicación.
- **Verificación cruzada** con un cliente distinto (Azure CLI).
- **Estado entendido**: sabes qué guarda y por qué no se comparte por correo.
- **Limpieza** con `destroy` al terminar.

**ℹ️ Próximos pasos**
- Añadir una red virtual y subredes dentro del grupo, referenciando `azurerm_resource_group.lab.name`.
- Crear una cuenta de almacenamiento y un Key Vault (ambos soportados en Topaz).
- Extraer el grupo a un módulo reutilizable.
- En Azure real: bloqueos de recursos (`azurerm_management_lock`), Azure Policy y pipelines de CI/CD.

---

## 6. Autoevaluación

1. **¿Por qué es obligatorio `features {}` en el provider azurerm?**
   Lo exige el provider desde la versión 2.0. Sin él: *Insufficient features blocks: At least 1 "features" blocks are required*. Contiene ajustes globales opcionales; vacío significa "valores por defecto".
2. **¿Qué tres líneas del provider distinguen Topaz de Azure real?**
   `metadata_host` (descubre los endpoints del emulador), `resource_provider_registrations = "none"` y la `subscription_id` `...0001`. En Azure real se quitan las dos primeras y se pone la suscripción propia.
3. **¿Por qué no se usa `timestamp()` para el nombre ni las etiquetas?**
   Un `default` no admite funciones, y en `tags` cambiaría en cada `plan`, generando un cambio perpetuo. Para nombres únicos se usa `random_string`, cuyo valor queda fijado en el estado.
4. **¿Diferencia entre el nombre local y el nombre en Azure?**
   El nombre local (`lab`) solo existe en Terraform y sirve para referenciar el recurso. El nombre en Azure es el argumento `name`.
5. **¿Por qué `lifecycle { ignore_changes = [tags] }` en el grupo?**
   Topaz no devuelve las etiquetas al leer el grupo; sin esa línea, cada `plan` propondría volver a ponerlas. En Azure real es innecesaria.
6. **¿Por qué `plan` antes de `apply`?**
   Para ver exactamente qué va a crear, cambiar o destruir sin tocar nada, y detectar errores antes de que tengan consecuencias.
7. **¿Cómo verificas el resultado si no hay Portal?**
   Con Azure CLI (`az group show`), que es un cliente independiente de Terraform contra la misma API, y con `terraform plan`, que debe decir *No changes*.
8. **¿Qué es el estado y por qué importa en equipo?**
   El mapa entre el código y los objetos reales, con sus `id` y atributos. En equipo se guarda en un backend remoto con bloqueo para que dos personas no apliquen a la vez ni trabajen con copias divergentes.

---

## 7. Referencias

- [Recurso `azurerm_resource_group`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group)
- [Azure Resource Manager: grupos de recursos y organización](https://learn.microsoft.com/es-es/azure/azure-resource-manager/management/overview)
- [Convenciones de nomenclatura de Azure (Cloud Adoption Framework)](https://learn.microsoft.com/es-es/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming)
- [Variables de entrada](https://developer.hashicorp.com/terraform/language/values/variables) y [outputs](https://developer.hashicorp.com/terraform/language/values/outputs)
- [Meta-argumento `for_each`](https://developer.hashicorp.com/terraform/language/meta-arguments/for_each)
- [El estado de Terraform](https://developer.hashicorp.com/terraform/language/state) y [backend `azurerm`](https://developer.hashicorp.com/terraform/language/backend/azurerm)
- [Recurso `random_string`](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/string)
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)