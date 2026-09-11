# 📦 Creación de grupos de recursos y recursos con Terraform

En este módulo crearás grupos de recursos primero con Azure CLI y después con Terraform, compararás ambos enfoques y añadirás recursos dentro del grupo. Todo se ejecuta contra el **emulador Topaz** del curso: los comandos son idénticos a los de Azure real, pero sin coste y sin riesgo. Donde el emulador se comporta de forma distinta, lo verás señalado en un recuadro **🔷 En Topaz**.

**Tabla de contenidos**
1. [Conceptos fundamentales](#1-conceptos-fundamentales)
2. [Creación de grupos de recursos con Azure CLI](#2-creación-de-grupos-de-recursos-con-azure-cli)
3. [Creación de grupos de recursos con Terraform](#3-creación-de-grupos-de-recursos-con-terraform)
4. [Comparación: Azure CLI vs Terraform](#4-comparación-azure-cli-vs-terraform-para-grupos-de-recursos)
5. [Creación de recursos adicionales con Terraform](#5-creación-de-recursos-adicionales-con-terraform)
6. [Buenas prácticas y convenciones de nombrado](#6-buenas-prácticas-y-convenciones-de-nombrado)
7. [Solución de problemas comunes](#7-solución-de-problemas-comunes)
8. [Recursos adicionales](#8-recursos-adicionales)

> **🔷 Requisitos previos.** Este módulo da por hecho que el entorno está montado y verificado: contenedor `azure-environment` en marcha, certificado instalado, Azure CLI autenticada en la nube `Topaz` y la **Prueba de humo** superada. Si algo de eso falla, vuelve a la guía *Entorno Práctico: Terraform + Azure Emulator + Topaz* antes de continuar.

---

## 1. Conceptos fundamentales

Antes de proceder con la creación práctica, es esencial comprender qué son los grupos de recursos y por qué son fundamentales en la arquitectura de Azure.

### 1.1. ¿Qué es un Grupo de Recursos en Azure?

Un **Grupo de Recursos** es un contenedor lógico que permite agrupar y gestionar recursos relacionados de Azure como una unidad única. Es fundamental para:

- **Gestión del ciclo de vida:** implementar, actualizar o eliminar todos los recursos del grupo como una sola operación.
- **Control de acceso:** aplicar políticas de acceso (RBAC) a nivel de grupo para todos los recursos contenidos.
- **Facturación y etiquetado:** agrupar costes y aplicar etiquetas consistentes.
- **Implementación:** facilitar despliegues repetibles mediante plantillas.

**Características clave:**

- Un recurso pertenece a exactamente un grupo de recursos.
- Los grupos de recursos no pueden anidarse.
- Los recursos dentro de un grupo pueden estar en diferentes regiones de Azure.
- El grupo de recursos en sí no incurre en costes directos.
- Al eliminar el grupo se eliminan todos los recursos que contiene.

### 1.2. ¿Por qué usar Terraform para gestionar grupos de recursos?

Aunque Azure CLI es excelente para operaciones ad hoc, Terraform ofrece ventajas significativas para la gestión de infraestructura:

- **Estado declarativo:** defines el estado deseado y Terraform determina las acciones necesarias.
- **Historial de cambios:** el archivo de estado rastrea qué recursos existen y sus configuraciones.
- **Reusabilidad:** los mismos archivos pueden crear entornos idénticos (dev, test, prod).
- **Colaboración:** el código de infraestructura puede versionarse en Git.
- **Planificación segura:** `terraform plan` muestra exactamente qué cambiará antes de aplicar.

> **🔷 En Topaz.** El emulador implementa Azure Resource Manager, así que los grupos de recursos se comportan igual que en Azure real: mismo modelo, mismos comandos, mismas respuestas JSON. Lo que no existe es facturación ni RBAC real: el usuario `topazadmin` puede hacerlo todo. Los conceptos de coste y permisos de este módulo los aplicarás tal cual cuando pases a una suscripción de verdad.

---

## 2. Creación de grupos de recursos con Azure CLI

Azure CLI proporciona un método directo e interactivo para crear y gestionar grupos de recursos. Es ideal para tareas administrativas rápidas y para aprender el modelo antes de automatizarlo.

Antes de empezar, confirma que la CLI habla con el emulador y no con Azure real:

```bash
az account show --query '{cloud:environmentName, sub:id}' -o json
# Esperado: "cloud": "Topaz", "sub": "00000000-0000-0000-0000-000000000001"
```

### 2.1. Creación básica

El comando fundamental para crear un grupo de recursos es:

```bash
az group create --name mi-rg-produccion --location eastus
```

Parámetros esenciales:

- **`--name` o `-n`**: Nombre único del grupo de recursos dentro de la suscripción. Debe seguir las convenciones de nombrado (ver sección 6).
- **`--location` o `-l`**: Región de Azure donde se almacenan los metadatos del grupo. Aunque los recursos pueden estar en otras regiones, esta ubicación determina dónde se guarda la información de gestión.

> **Ejemplo con valores reales:**
> ```bash
> az group create --name rg-webapp-prod-001 --location westeurope
> ```

> **🔷 En Topaz.** La ubicación es nominal: el emulador acepta el valor y lo devuelve, pero no hay centros de datos detrás. En el curso usamos siempre `eastus` por coherencia con el resto de prácticas. Cualquier otro nombre de región válido funcionará igual.

### 2.2. Opciones avanzadas

Azure CLI ofrece parámetros adicionales para casos de uso específicos.

**Etiquetas (tags) durante la creación**

```bash
az group create --name rg-analisis-finanzas --location eastus \
  --tags entorno=produccion departamento=finanzas costo=centro
```

> **🔷 En Topaz.** El emulador acepta el parámetro `--tags`, pero en los grupos de recursos puede no devolver las etiquetas en la respuesta (`"tags": null`). No es un fallo tuyo: la sintaxis es la correcta y en Azure real las verás reflejadas. Este detalle tiene consecuencias en Terraform que se explican en la sección 3.3.

**Modo sin espera**

Por defecto, el comando espera hasta que la operación se completa. Para scripts donde no se necesita esperar:

```bash
az group create --name rg-temporal --location eastus --no-wait
```

### 2.3. Verificación tras la creación

Después de crear el grupo, verifica su existencia y propiedades:

```bash
az group show --name mi-rg-produccion --output json
```

Salida esperada. Fíjate en el `id`: la suscripción `...0001` solo existe en el emulador, lo que confirma que no has tocado Azure real:

```json
{
  "id": "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/mi-rg-produccion",
  "location": "eastus",
  "managedBy": null,
  "name": "mi-rg-produccion",
  "properties": {
    "provisioningState": "Succeeded"
  },
  "tags": null,
  "type": "Microsoft.Resources/resourceGroups"
}
```

### 2.4. Listar todos los grupos de recursos

```bash
az group list --output table
```

### 2.5. Eliminación de grupos de recursos

> 🚨 **¡Extremo cuidado!** Eliminar un grupo de recursos elimina **todos** los recursos contenidos en él. Esta acción es irreversible. En el emulador el daño es nulo, pero adquiere el hábito ahora: en Azure real este comando borra producción sin preguntar dos veces.

```bash
az group delete --name mi-rg-antiguo --yes --no-wait
```

Parámetros habituales en scripts:
- `--yes`: omite la solicitud de confirmación.
- `--no-wait`: retorna inmediatamente sin esperar a que termine la eliminación.
- `--verbose`: muestra información detallada del proceso.

---

## 3. Creación de grupos de recursos con Terraform

Terraform gestiona grupos de recursos como cualquier otro recurso de Azure, aprovechando su enfoque declarativo y su capacidad de planificación.

### 3.1. Estructura básica de un proyecto Terraform

Un proyecto típico para gestionar grupos de recursos incluye estos archivos:

```text
infraestructura/
├── main.tf          # Configuración principal de recursos
├── variables.tf     # Variables de entrada
├── outputs.tf       # Valores de salida
├── versions.tf      # Restricciones de versiones y configuración del provider
└── terraform.tfvars # Valores de variables (no versionar si contiene secretos)
```

Terraform lee todos los archivos `.tf` del directorio como si fueran uno solo; la división es solo para las personas. En una práctica pequeña puedes tenerlo todo en `main.tf`, como hiciste en la Prueba de humo.

### 3.2. Configuración del provider de Azure

Antes de crear cualquier recurso debe configurarse el provider. Este bloque es el mismo que ya validaste en la Prueba de humo y se hace una sola vez por proyecto:

```hcl
# archivo: versions.tf
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

  # Apuntar al emulador Topaz (descubre los endpoints en /metadata/endpoints)
  metadata_host                   = "topaz.local.dev:8899"
  # El emulador no implementa el registro de resource providers
  resource_provider_registrations = "none"
  # Obligatorio en azurerm 4.x; suscripción por defecto del emulador
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}
```

> **🔷 En Topaz vs Azure real.** Las dos líneas `metadata_host` y `resource_provider_registrations` son las únicas que distinguen este provider del que usarías contra Azure. Si prefieres que el código no sepa nada del entorno, quítalas del `.tf` y expórtalas como variables: `ARM_METADATA_HOSTNAME=topaz.local.dev:8899` y `ARM_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000001`. El provider las lee automáticamente y el mismo código sirve en cualquier host del curso.

### 3.3. Definición del grupo de recursos en Terraform

La creación de un grupo de recursos se define mediante el recurso `azurerm_resource_group`. Las etiquetas se declaran una sola vez en un bloque `locals` para que todos los recursos del proyecto las compartan:

```hcl
# archivo: main.tf
locals {
  tags = {
    entorno    = "produccion"
    aplicacion = "webapp"
    equipo     = "infraestructura"
    costo      = "centro"
  }
}

resource "azurerm_resource_group" "produccion" {
  name     = "rg-webapp-produccion-001"
  location = "eastus"
  tags     = local.tags

  lifecycle {
    # Topaz no devuelve las etiquetas del grupo en sus respuestas;
    # sin esto, cada plan propondría volver a añadirlas.
    ignore_changes = [tags]
  }
}
```

Atributos importantes:
- **`name`**: Nombre del grupo de recursos. Debe ser único dentro de la suscripción.
- **`location`**: Región de Azure. El provider acepta tanto el código corto (`eastus`) como el nombre largo (`East US`) y los normaliza. En el curso usamos el código corto, que es el mismo que aparece en las salidas de `az`.
- **`tags`**: Diccionario de pares clave-valor para organización, facturación y automatización. Aquí apunta a `local.tags`.
- **`lifecycle.ignore_changes`**: Indica a Terraform que no considere diferencias en los atributos listados al comparar el estado con la realidad. Es inocuo en Azure real (donde no hay diferencia) y evita ruido en el emulador.

> **🔷 Por qué un `locals` y no heredar del grupo.** Un patrón habitual es escribir `tags = azurerm_resource_group.produccion.tags` en los demás recursos para "heredar" las etiquetas. En Azure real funciona porque ARM devuelve las etiquetas al crear el grupo. En Topaz, el emulador responde con `tags: null`, así que ese atributo pasa de tener cuatro valores en el `plan` a ser `null` en el `apply`, y Terraform aborta con *Provider produced inconsistent final plan* en todos los recursos dependientes (ver 7.1). Con `local.tags`, el valor viene de tu configuración y no de lo que el servidor devuelva: es más robusto en cualquier entorno y, de paso, la buena práctica recomendada.

### 3.4. Flujo de trabajo estándar con Terraform

Una vez definidos los archivos, sigue este proceso:

1. **Inicializar el entorno de trabajo**
   ```bash
   terraform init
   ```
   Descarga los providers necesarios y configura el backend para el estado.
2. **Validar la sintaxis** (sin red ni credenciales)
   ```bash
   terraform validate
   ```
3. **Crear un plan de ejecución**
   ```bash
   terraform plan
   ```
   Muestra exactamente qué cambios se aplicarán. **Revisa siempre esta salida antes de aplicar.**
4. **Aplicar los cambios**
   ```bash
   terraform apply
   ```
   Terraform solicitará confirmación. Escribe `yes` para proceder.

> ✅ **Salida esperada de `terraform plan`:**
> ```text
> Terraform will perform the following actions:
> 
>   # azurerm_resource_group.produccion will be created
>   + resource "azurerm_resource_group" "produccion" {
>       + id       = (known after apply)
>       + location = "eastus"
>       + name     = "rg-webapp-produccion-001"
>       + tags     = {
>           + "aplicacion" = "webapp"
>           + "costo"      = "centro"
>           + "entorno"    = "produccion"
>           + "equipo"     = "infraestructura"
>         }
>     }
> 
> Plan: 1 to add, 0 to change, 0 to destroy.
> ```

Tras el `apply`, cierra el círculo comprobando el recurso por el otro camino:

```bash
az group show -n rg-webapp-produccion-001 --query '{nombre:name, ubicacion:location, tags:tags}' -o json
terraform plan     # debe responder: No changes.
```

> **🔷 En Topaz.** Es normal que `tags` aparezca como `null` en la salida de `az` aunque las hayas declarado. Gracias al `ignore_changes` de la sección 3.3, el segundo `plan` responde `No changes` igualmente. Si lo quitas, verás un `~ update in-place` perpetuo en el grupo: buen experimento para entender qué hace `lifecycle`.

### 3.5. Eliminación de recursos con Terraform

Para eliminar el grupo de recursos y todos sus recursos asociados:

```bash
terraform destroy
```

Terraform mostrará qué recursos se eliminarán y solicitará confirmación antes de proceder.

> 💡 **Nota:** no mezcles herramientas sobre el mismo recurso. Si borras con `az group delete` un grupo que creó Terraform, el estado quedará desincronizado y el siguiente `plan` intentará recrearlo. La regla: lo que crea Terraform, lo destruye Terraform.

---

## 4. Comparación: Azure CLI vs Terraform para grupos de recursos

Ambas herramientas tienen sus casos de uso ideales. Comprender sus diferencias ayuda a elegir la aproximación correcta para cada situación.

| **Aspecto** | **Azure CLI** | **Terraform** |
|---|---|---|
| **Enfoque** | Imperativo (cómo hacerlo) | Declarativo (qué se quiere lograr) |
| **Mejor para** | Tareas ad hoc, administración rápida, aprendizaje | Infraestructura como código, entornos reproducibles, CI/CD |
| **Estado** | Ninguno (consulta el estado actual de Azure) | Mantiene un archivo de estado que rastrea lo que existe |
| **Planificación** | No hay plan previo; los comandos se ejecutan inmediatamente | `terraform plan` muestra los cambios antes de aplicar |
| **Control de versiones** | Los comandos no se versionan fácilmente | El código de infraestructura se versiona en Git |
| **Colaboración** | Difícil rastrear quién hizo qué y cuándo | Revisión de cambios mediante pull requests |
| **Reproducibilidad** | Requiere documentar manualmente los pasos | El mismo código crea entornos idénticos |
| **Curva de aprendizaje** | Más baja para operaciones simples | Requiere comprender HCL y el concepto de estado |
| **Cómo sabe dónde está Topaz** | `az cloud set --name Topaz` | `metadata_host` en el provider (o `ARM_METADATA_HOSTNAME`) |

**Recomendación:** usa Azure CLI para tareas administrativas puntuales, para verificar lo que Terraform ha hecho y para el aprendizaje inicial. Para cualquier cosa que vaya a repetirse, necesite versionarse o forme parte de un entorno de desarrollo o producción, usa Terraform.

---

## 5. Creación de recursos adicionales con Terraform

Una vez creado el grupo de recursos, lo habitual es crear recursos dentro de él. Los ejemplos siguientes van en archivos separados del mismo directorio y hacen referencia al grupo `azurerm_resource_group.produccion` de la sección 3.3 para `location` y `resource_group_name`: así Terraform deduce solo el orden de creación. Las etiquetas, en cambio, siempre vienen de `local.tags`.

> **🔷 Qué implementa el emulador.** Topaz cubre Resource Manager, redes básicas, Storage, Key Vault, máquinas virtuales y App Service, pero no todas las propiedades de cada recurso. Si un `apply` falla en un atributo concreto, la estrategia es simplificar el bloque (quitar el atributo) y volver a intentarlo. El objetivo del curso es aprender Terraform, no agotar la API de Azure.

### 5.1. Red virtual y subred

La base de casi cualquier arquitectura en Azure:

```hcl
# archivo: network.tf
resource "azurerm_virtual_network" "produccion" {
  name                = "vnet-webapp-produccion"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.produccion.location
  resource_group_name = azurerm_resource_group.produccion.name

  tags = local.tags
}

resource "azurerm_subnet" "produccion" {
  name                 = "snet-webapp-produccion"
  resource_group_name  = azurerm_resource_group.produccion.name
  virtual_network_name = azurerm_virtual_network.produccion.name
  address_prefixes     = ["10.0.1.0/24"]
  # Las subredes no admiten tags: son un recurso hijo de la VNet
}
```

Observa `tags = local.tags`: todos los recursos comparten el mismo mapa definido en `main.tf`. Si cambias una etiqueta allí, el siguiente `plan` propagará el cambio a todo el proyecto sin depender de lo que el servidor haya devuelto para ningún recurso.

### 5.2. Cuenta de almacenamiento

Para almacenamiento de objetos, discos o archivos:

```hcl
# archivo: storage.tf
resource "azurerm_storage_account" "produccion" {
  name                     = "stgwebappprod001"  # único globalmente; solo minúsculas y números, 3-24 caracteres
  resource_group_name      = azurerm_resource_group.produccion.name
  location                 = azurerm_resource_group.produccion.location
  account_tier             = "Standard"
  account_replication_type = "LRS"

  tags = local.tags
}
```

> **🔷 Atención en Topaz.** Tras crear la cuenta por ARM, el provider consulta su *plano de datos* en `https://stgwebappprod001.storage.topaz.local.dev:8891`. Si ese nombre no resuelve a `127.0.0.1` en `/etc/hosts` o el contenedor no publica el puerto 8891, el `apply` o el siguiente `plan` se quedarán colgados en `Still creating...` o `Refreshing state...`. Antes de usar este recurso, añade la entrada y recrea el contenedor con `-p 8891:8891` (y repite la instalación del certificado). Si no quieres complicarte, deja este ejemplo para el final o sáltalo: red y App Service no tienen este problema.

### 5.3. Plan de App Service y aplicación web

Para hospedar aplicaciones web. En azurerm 4.x los recursos son `azurerm_service_plan` y `azurerm_linux_web_app` (los antiguos `azurerm_app_service_plan` y `azurerm_app_service` ya no existen):

```hcl
# archivo: appservice.tf
resource "azurerm_service_plan" "produccion" {
  name                = "asp-webapp-produccion"
  location            = azurerm_resource_group.produccion.location
  resource_group_name = azurerm_resource_group.produccion.name
  os_type             = "Linux"
  sku_name            = "S1"

  tags = local.tags
}

resource "azurerm_linux_web_app" "produccion" {
  name                = "app-webapp-produccion-001"
  location            = azurerm_resource_group.produccion.location
  resource_group_name = azurerm_resource_group.produccion.name
  service_plan_id     = azurerm_service_plan.produccion.id

  site_config {
    http2_enabled = true
    application_stack {
      dotnet_version = "8.0"
    }
  }

  tags = local.tags
}
```

Tras el `apply`, comprueba el árbol completo de recursos del grupo con la CLI:

```bash
az resource list -g rg-webapp-produccion-001 --query '[].{nombre:name, tipo:type}' -o table
```

> 💡 **Si ya tenías el proyecto con `tags = azurerm_resource_group.produccion.tags`:** no hace falta destruir nada. Sustituye las referencias, valida y vuelve a aplicar; Terraform solo creará lo que falte.
> ```bash
> sed -i 's/azurerm_resource_group\.produccion\.tags/local.tags/g' *.tf
> grep -n 'tags' *.tf        # solo debe quedar local.tags (y el bloque locals)
> terraform validate && terraform apply
> ```

---

## 6. Buenas prácticas y convenciones de nombrado

Seguir convenciones establecidas mejora significativamente la mantenibilidad y reduce errores. El emulador es permisivo con algunas de estas reglas; Azure real no lo es, así que conviene practicarlas desde ahora.

### 6.1. Convenciones de nombrado para grupos de recursos

Microsoft recomienda el siguiente patrón:

```text
<tipo>-<aplicación>-<entorno>-[<instancia>]-[<región>]
```

Ejemplos:
- `rg-webapp-prod-001-weu`: aplicación web, producción, instancia 001, West Europe.
- `rg-sql-dev-002-eus`: base de datos SQL, desarrollo, instancia 002, East US.
- `rg-aks-test-001`: clúster AKS, pruebas, instancia 001.

> **Reglas técnicas de Azure:**
> - Usa abreviaturas estándar de regiones (`weu` = West Europe, `eus` = East US…).
> - Máximo 90 caracteres.
> - Letras, números, guiones, guiones bajos, puntos y paréntesis; no puede terminar en punto.
> - Las cuentas de almacenamiento son la excepción: solo minúsculas y números, 3–24 caracteres, únicas en todo Azure.

### 6.2. Estrategia de etiquetado (tagging)

Una estrategia consistente de etiquetas es crucial para la gobernanza:

| **Etiqueta** | **Descripción** | **Ejemplo de valor** |
|---|---|---|
| `entorno` | Entorno de implementación | desarrollo, prueba, produccion |
| `aplicacion` | Nombre de la aplicación o sistema | webapp, api, analizador-datos |
| `equipo` | Equipo responsable | infraestructura, desarrolladores, datos |
| `costo` | Centro de coste para facturación | centro, proyecto-xyz, cliente-abc |
| `version` | Versión de la aplicación o infraestructura | v1.2.3, release-2026-q3 |
| `fecha-creacion` | Fecha de creación del recurso | 2026-09-09 |

En Terraform, la forma de aplicar esta estrategia sin repetirte es la que ya usa el módulo: un único bloque `locals { tags = { ... } }` y `tags = local.tags` en cada recurso. Si mañana el equipo cambia de nombre, lo editas en una línea y el `plan` propaga el cambio a todos los recursos.

> **🔷 En Topaz.** Los recursos hijos (VNet, plan de App Service, cuenta de almacenamiento) guardan y devuelven las etiquetas correctamente, así que puedes verificarlas con `az resource show --ids <id> --query tags`. El grupo de recursos es la excepción: el emulador las acepta pero las devuelve como `null`, de ahí el `ignore_changes` de la sección 3.3. Lo que no verás en ningún caso es su efecto en facturación ni en Azure Policy, porque el emulador no implementa ninguna de las dos.

### 6.3. Selección de ubicación (location)

La elección de región afecta a rendimiento, costes y cumplimiento:

- **Latencia:** elige la región más cercana a tus usuarios finales.
- **Servicios disponibles:** algunos servicios solo existen en ciertas regiones.
- **Costes:** los precios varían significativamente entre regiones.
- **Cumplimiento:** algunos datos deben residir en regiones concretas por regulación (RGPD, HIPAA, etc.).
- **Disponibilidad:** para alta disponibilidad, distribuye entre regiones emparejadas.

> **🔷 En Topaz.** Nada de lo anterior tiene efecto en el emulador: todas las regiones son el mismo contenedor. Usa `eastus` en las prácticas y guarda estos criterios para cuando el mismo código se aplique a una suscripción real, que es justo la ventaja de Terraform: cambiar la región es cambiar una variable.

---

## 7. Solución de problemas comunes

Empezamos por los errores que **sí** verás en el laboratorio (son del entorno, no del código) y seguimos con los que aparecen tanto en Topaz como en Azure real.

### 7.1. Errores propios del entorno Topaz

Si el `apply` falla, casi siempre es una de estas capas. Las cuatro primeras tienen su apartado en la guía del entorno; las tres últimas son limitaciones del emulador que se resuelven en el propio `.tf`:

| **Error** | **Qué capa está rota** | **Solución** |
|---|---|---|
| `x509: certificate signed by unknown authority` | Confianza TLS en Go: certificado obsoleto tras recrear el contenedor o `SSL_CERT_FILE` ausente | Guía del entorno → *Caso resuelto x509* |
| `SubscriptionNotFound` | Terraform habla con Azure real: falta `metadata_host` | Añade `metadata_host = "topaz.local.dev:8899"` al provider |
| `401`, `AADSTS...` o *obtaining Authorization Token from the Azure CLI* | Sesión de `az` caducada o en otra nube | `az cloud set --name Topaz && az login --use-device-code` |
| `dial tcp ... i/o timeout` | Red: `/etc/hosts` sin la entrada o contenedor parado | `docker start azure-environment`; revisa `/etc/hosts` |
| *subscription_id is a required provider property* | Falta el argumento en azurerm 4.x | Añade `subscription_id` o exporta `ARM_SUBSCRIPTION_ID` |
| `Provider produced inconsistent final plan ... .tags: was cty.MapVal(...), but now null` | Un recurso hereda `tags` por referencia al grupo (`azurerm_resource_group.x.tags`) y el emulador devuelve `null` tras crearlo | Etiquetas en `locals` y `tags = local.tags` en todos los recursos. [Ver caso resuelto](#caso-tags) |
| `~ update in-place` perpetuo en el grupo de recursos, solo en `tags` | Mismo origen: el emulador no devuelve las etiquetas del grupo, así que cada `plan` quiere volver a ponerlas | `lifecycle { ignore_changes = [tags] }` en el grupo (sección 3.3) |
| Colgado en `Still creating...` o `Refreshing state...` con una cuenta de almacenamiento | El plano de datos `*.storage.topaz.local.dev:8891` no resuelve o el puerto no está publicado | Ver recuadro de la sección 5.2 |

> 💡 **Regla práctica:** si has recreado el contenedor desde la última vez que todo funcionó, el certificado y la sesión de `az` han cambiado. Repite en orden: certificado → `az login` → `terraform apply`. Y si dudas de si el problema es del entorno o del código, ejecuta la **Prueba de humo**: si pasa, el problema está en tu `.tf`.

#### 🛠️ Caso resuelto: el grupo se crea, pero los demás recursos fallan con *inconsistent final plan*

```text
azurerm_resource_group.produccion: Creation complete after 20s [id=/subscriptions/.../resourceGroups/rg-webapp-produccion-001]
╷
│ Error: Provider produced inconsistent final plan
│
│ When expanding the plan for azurerm_virtual_network.produccion to include new values learned so far
│ during apply, provider "registry.terraform.io/hashicorp/azurerm" produced an invalid new value for
│ .tags: was cty.MapVal(map[string]cty.Value{"aplicacion":cty.StringVal("webapp"), ...}), but now null.
│
│ This is a bug in the provider, which should be reported in the provider's own issue tracker.
╵
(y el mismo error para azurerm_service_plan.produccion y azurerm_storage_account.produccion)
```

**Qué está pasando.** A pesar de lo que dice el mensaje, no es un bug del provider ni un error de tu sintaxis: es una limitación del emulador combinada con un patrón de código frágil.

1. En el `plan`, `azurerm_resource_group.produccion.tags` es conocido (viene de tu `.tf`), así que Terraform planifica los recursos dependientes con ese mapa de cuatro etiquetas.
2. Terraform crea el grupo. **Topaz responde sin etiquetas** (`tags: null`) y el provider guarda en el estado lo que el servidor devuelve.
3. Al expandir el plan de la VNet, el plan de App Service y la cuenta de almacenamiento, el valor heredado ya es `null`: distinto de lo planificado → error en los tres. La subred, que no lleva `tags`, no aparece en la lista; ese detalle confirma el diagnóstico.

Compruébalo en cinco segundos:

```bash
az group show -n rg-webapp-produccion-001 --query tags -o json
# Topaz: null
```

**Arreglo.** Deja de heredar y declara las etiquetas una vez en `locals`, como en la sección 3.3. No hace falta destruir nada: el grupo ya está en el estado y Terraform solo creará los recursos que faltan.

```bash
# 1. Añade el bloque locals a main.tf (ver 3.3) si aún no lo tienes
# 2. Sustituye las referencias en todos los .tf
sed -i 's/azurerm_resource_group\.produccion\.tags/local.tags/g' *.tf
grep -n 'tags' *.tf              # solo debe quedar local.tags y el bloque locals

# 3. Evita el update perpetuo en el grupo
#    (añade lifecycle { ignore_changes = [tags] } al azurerm_resource_group)

terraform validate
terraform apply                  # Plan: 5 to add, 0 to change, 0 to destroy
terraform plan                   # No changes.
```

> 💡 **Lección para llevar.** Terraform exige que lo que se planifica sea lo que se aplica. Cuando un atributo de tu configuración depende de lo que otro recurso *devuelve* (y no de lo que tú *declaras*), estás confiando en que la API se comporte exactamente como esperas. En Azure real eso se cumple; en un emulador, en una API en previsualización o en una nube soberana, puede no cumplirse. Declarar los valores compartidos en `locals` o `variables` elimina esa dependencia y es la práctica recomendada en cualquier entorno.

### 7.2. Errores al crear grupos de recursos con Azure CLI

> 🚨 **Error:** `(InvalidResourceGroupName) Resource group name <nombre> is invalid.`

**Causa:** el nombre contiene caracteres no permitidos, es demasiado largo o termina en punto.
**Solución:** usa letras, números, guiones y guiones bajos. Máximo 90 caracteres. Revisa la sección 6.1.

> 🚨 **Error:** `(InvalidResourceLocation) Location <lugar> is not available for resource group.`

**Causa:** la región especificada no existe o no está disponible para la suscripción.
**Solución:** en Azure real, consulta las regiones con `az account list-locations -o table`. En Topaz este comando puede no estar implementado; usa `eastus`, que es la región de referencia del curso.

### 7.3. Errores comunes en Terraform

> 🚨 **Error:** `Unsupported block type` o `Argument or block definition required` en `terraform validate`

**Causa:** sintaxis HCL incorrecta. El caso más habitual al copiar y pegar es un bloque huérfano fuera de cualquier `resource` o una llave de cierre de más o de menos.
**Solución:** `validate` indica el archivo y la línea exacta. Ejecuta `terraform fmt` para reindentar: los bloques mal cerrados quedan a la vista.

> 🚨 **Error:** `Error: A resource with the ID "/subscriptions/.../resourceGroups/rg-..." already exists`

**Causa:** el grupo ya existe en el emulador (lo creaste con `az group create` o con otro directorio de Terraform) pero no está en este estado.
**Solución:** impórtalo al estado con `terraform import azurerm_resource_group.produccion /subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-webapp-produccion-001`, o bórralo con `az group delete` si era un resto de pruebas.

> 🚨 **Error:** `Error: Failed to get existing resource group: ResourceGroupNotFound`

**Causa:** intentas crear un recurso en un grupo que no existe, o el grupo fue borrado por fuera de Terraform.
**Solución:**
1. Referencia siempre el grupo como `azurerm_resource_group.<nombre>.name`, no como cadena literal: así Terraform sabe que debe crearlo antes.
2. Si el grupo se borró con `az group delete`, ejecuta `terraform plan`: Terraform detectará la ausencia y propondrá recrearlo.
3. Verifica que el nombre coincide exactamente entre la configuración y lo que existe en el emulador (`az group list -o table`).

> 🚨 **Plan inesperado:** `azurerm_resource_group.produccion must be replaced` tras cambiar solo el `name`

**Causa:** el nombre de un grupo de recursos es inmutable en Azure. Cambiarlo en el `.tf` equivale a destruir el grupo (con todo su contenido) y crear otro.
**Solución:** lee siempre el `plan` buscando la palabra *replaced*. Si de verdad quieres renombrar, hazlo de forma consciente: crea el grupo nuevo, mueve o recrea los recursos y elimina el antiguo.

### 7.4. Problemas de autenticación y permisos

> 🚨 **Error:** `(AuthorizationFailed) The client '<email>' with object id '<object-id>' does not have authorization to perform action 'Microsoft.Resources/subscriptions/resourceGroups/write'...`

**Causa:** la cuenta de usuario o la entidad de servicio no tiene permisos suficientes.
**Solución (Azure real):**
1. Verifica tus roles con `az role assignment list --assignee <email-u-object-id>`.
2. Para crear grupos de recursos necesitas, como mínimo, el rol **Colaborador** en el ámbito de la suscripción o un rol personalizado con `resourceGroups/write`.
3. Para operaciones completas con Terraform, lo habitual es una entidad de servicio con rol **Colaborador** en la suscripción.

> **🔷 En Topaz.** Este error no ocurre: el emulador no implementa RBAC y `topazadmin` tiene todos los permisos. Si ves un fallo de autenticación en el laboratorio, será un `401` por sesión caducada (sección 7.1), no un `AuthorizationFailed`.

---

## 8. Recursos adicionales

### Documentación oficial de Microsoft
- [Azure Resource Manager: información general](https://learn.microsoft.com/es-es/azure/azure-resource-manager/management/overview)
- [Administrar grupos de recursos con Azure CLI](https://learn.microsoft.com/es-es/azure/azure-resource-manager/management/manage-resource-groups-cli)
- [Referencia de `az group`](https://learn.microsoft.com/es-es/cli/azure/group)
- [Etiquetar recursos de Azure](https://learn.microsoft.com/es-es/azure/azure-resource-manager/management/tag-resources)
- [Convenciones de nombrado (Cloud Adoption Framework)](https://learn.microsoft.com/es-es/azure/cloud-adoption-framework/ready/azure-best-practices/resource-naming)

### Terraform y el provider azurerm
- [Documentación del provider azurerm](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs) (incluye `metadata_host` y `resource_provider_registrations`)
- [Recurso `azurerm_resource_group`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/resource_group)
- [Guía de migración a azurerm 4.0](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/4.0-upgrade-guide)
- [Valores locales (`locals`)](https://developer.hashicorp.com/terraform/language/values/locals)
- [Meta-argumento `lifecycle` e `ignore_changes`](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle)
- [Tutorial: Terraform con Azure](https://developer.hashicorp.com/terraform/tutorials/azure-get-started)
- [Importar recursos existentes al estado](https://developer.hashicorp.com/terraform/cli/import)

### Emulador y herramientas
- [Azure Local Emulator (Topaz)](https://github.com/Azure/azure-local-emulator): servicios soportados y limitaciones
- [Extensión Terraform para VS Code](https://marketplace.visualstudio.com/items?itemName=HashiCorp.terraform)
- [pre-commit-terraform](https://github.com/antonbabenko/pre-commit-terraform) (validación automática antes de cada commit)
- [tfupdate](https://github.com/minamijoyo/tfupdate) (mantener actualizadas las versiones de providers)