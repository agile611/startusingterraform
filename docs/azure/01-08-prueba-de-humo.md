Aquí tienes la conversión completa del documento HTML a formato Markdown estructurado y limpio:

---

# 🧪 Prueba de humo: ¿habla Terraform con Topaz?

Un `main.tf` de un solo recurso para comprobar, en menos de un minuto, que toda la cadena funciona: resolución de nombres, confianza TLS, `metadata_host`, token de Azure CLI y el Resource Manager del emulador. Si esta prueba pasa, cualquier error posterior en la práctica de la VM será del recurso, no del entorno.

**Contenido**
1. [Antes de empezar](#requisitos)
2. [El `main.tf` mínimo](#maintf)
3. [Ejecutar la prueba](#ejecutar)
4. [Verificar desde Azure CLI](#verificar)
5. [Si algo falla](#errores)
6. [Limpiar y siguiente paso](#limpiar)

---

<a id="requisitos"></a>
## ✅ Antes de empezar

Esta prueba da por hechos los pasos 4 a 7 de **Operaciones sobre el Contenedor** de la guía del entorno. Comprueba en 15 segundos que están en su sitio:

```bash
# Contenedor arriba y publicando el puerto
docker ps --filter name=azure-environment --format '{{.Names}}  {{.Status}}  {{.Ports}}'

# TLS: el bundle del sistema valida el certificado del emulador (Go y Python lo leen de aquí)
echo "SSL_CERT_FILE=$SSL_CERT_FILE"
curl -s --noproxy '*' -o /dev/null -w 'HTTP %{http_code}\n' \
  'https://topaz.local.dev:8899/metadata/endpoints?api-version=2022-09-01'

# Azure CLI autenticada en la nube Topaz
az account show --query '{cloud:environmentName, sub:id}' -o json
```

Debes ver `Up`, `HTTP 200` y `"cloud": "Topaz"`. Si alguno falla, vuelve a la guía del entorno antes de seguir: Terraform no va a arreglar lo que la CLI no tiene resuelto.

---

<a id="maintf"></a>
## 📄 El `main.tf` mínimo

Un grupo de recursos es el objeto más simple que existe en Azure Resource Manager: no depende de nada y el emulador lo implementa completo. Por eso es el candidato perfecto para la prueba. Crea el directorio y el archivo:

```bash
mkdir -p /home/curso/terraform/humo && cd /home/curso/terraform/humo
nano main.tf
```

Contenido de `main.tf`:

```hcl
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}

provider "azurerm" {
  features {}
  metadata_host                   = "topaz.local.dev:8899"
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-humo"
  location = "eastus"
}

output "rg_id" {
  value = azurerm_resource_group.rg.id
}
```

Cada línea del bloque `provider` tiene un motivo; ninguna sobra:

| **Argumento** | **Para qué sirve** | **Si falta…** |
|---|---|---|
| `version = "~> 4.0"` | Fija la *major* del provider; `resource_provider_registrations` solo existe en 4.x | Un `init` en otra máquina puede traer una versión incompatible |
| `features {}` | Bloque obligatorio del provider, aunque esté vacío | Error de validación |
| `metadata_host` | Le dice a Terraform dónde descubrir los endpoints del emulador | Terraform habla con Azure real → `SubscriptionNotFound` |
| `resource_provider_registrations = "none"` | Evita que el provider intente registrar *resource providers*, algo que el emulador no implementa | Error al arrancar el provider |
| `subscription_id` | Obligatorio en azurerm 4.x | Error: *subscription_id is a required provider property* |

> 💡 **Fíjate en lo que no está.** No hay `tenant_id` ni `use_cli`: el provider usa la CLI por defecto y toma el tenant de `az account show`. Tampoco hay `backend`: el estado se guarda en `terraform.tfstate` dentro del directorio, que es justo lo que queremos en una prueba desechable.

---

<a id="ejecutar"></a>
## ▶️ Ejecutar la prueba

Tres comandos, en este orden. El segundo es el que la gente se salta y el que más tiempo ahorra:

```bash
terraform init                 # descarga el provider azurerm 4.x
terraform validate             # sintaxis y esquema, sin tocar el emulador
terraform apply -auto-approve  # crea el grupo de recursos
```

Salida esperada al final del `apply`:

```text
azurerm_resource_group.rg: Creating...
azurerm_resource_group.rg: Creation complete after 1s [id=/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-humo]

Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

Outputs:

rg_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-humo"
```

El `output` no es decorativo: el ID incluye la suscripción `...0001`, que solo existe en el emulador. Verla ahí es la prueba de que el recurso **no** se ha creado en Azure real.

> **Nota:** `terraform validate` no necesita credenciales ni red, así que es la forma más rápida de cazar errores de sintaxis. El clásico al copiar y pegar es dejar un bloque huérfano al final del archivo (por ejemplo, un `os_profile_linux_config { ... }` de una VM anterior): `validate` lo señala con *Unsupported block type* o *Argument or block definition required* y el número de línea exacto.

---

<a id="verificar"></a>
## 🔎 Verificar desde Azure CLI

Terraform dice que ha creado el grupo; comprueba que el emulador opina lo mismo consultándolo por otro camino:

```bash
az group show -n rg-humo --query '{nombre:name, ubicacion:location, id:id}' -o json
```

```json
{
  "id": "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-humo",
  "nombre": "rg-humo",
  "ubicacion": "eastus"
}
```

Si aparece, has cerrado el círculo: Terraform (Go) y Azure CLI (Python) ven el mismo recurso en el mismo emulador. Un segundo `terraform plan` debe responder `No changes`, lo que confirma además que el estado local coincide con la realidad.

---

<a id="errores"></a>
## 🛠️ Si algo falla

La ventaja de una prueba con un solo recurso es que cada error apunta a una capa concreta. Localiza el tuyo y ve directamente al apartado de la guía del entorno que lo trata:

| **Error** | **Qué capa está rota** | **Dónde mirar** |
|---|---|---|
| `Unsupported block type` en `validate` | Sintaxis: bloque fuera de un `resource` | El propio `main.tf`; compáralo con el de arriba |
| `x509: certificate signed by unknown authority` | Confianza TLS en Go: certificado obsoleto o `SSL_CERT_FILE` ausente | Guía del entorno → *Caso resuelto x509* |
| `SubscriptionNotFound` | Terraform habla con Azure real: falta `metadata_host` | Guía del entorno → *Desplegar con Terraform*, paso 1 |
| `401`, `AADSTS...` o *obtaining Authorization Token from the Azure CLI* | Sesión de `az` caducada o en otra nube | Guía del entorno → paso 7, `az login --use-device-code` |
| `dial tcp ... i/o timeout` | Red: `/etc/hosts` o contenedor parado | Guía del entorno → *curl (28) Timeout* |
| *subscription_id is a required provider property* | Falta el argumento en azurerm 4.x | Añade `subscription_id` o exporta `ARM_SUBSCRIPTION_ID` |

> **Regla práctica:** si has recreado el contenedor `azure-environment` desde la última vez que todo funcionó, el certificado y la sesión de `az` han cambiado. Repite en orden: certificado (paso 4) → `az login` (paso 7) → `terraform apply`. Saltarse el primero da el error `x509`; saltarse el segundo, el `401`.

---

<a id="limpiar"></a>
## 🧹 Limpiar y siguiente paso

El grupo `rg-humo` ya ha cumplido su función. Destrúyelo desde el mismo directorio y comprueba que la CLI también lo da por desaparecido:

```bash
terraform destroy -auto-approve
az group show -n rg-humo 2>&1 | head -1
# Esperado: (ResourceGroupNotFound) ...
```

Con el entorno validado, ya puedes pasar a la práctica principal en `/home/curso/terraform/nemo`: el `main.tf` de la máquina virtual reutiliza **exactamente el mismo bloque `provider`** que acabas de probar, así que cualquier error que aparezca allí será del recurso (NIC, subnet, imagen, disco), no de la conexión con Topaz.

> 💡 **Para llevar.** Antes de desplegar algo complejo contra un entorno nuevo, despliega primero lo más simple que exista. Un recurso sin dependencias aísla los problemas de *entorno* (red, TLS, credenciales, endpoints) de los problemas de *código*. Es la misma idea que un `ping` antes de un `ssh`: barato, rápido y te dice exactamente dónde mirar.

