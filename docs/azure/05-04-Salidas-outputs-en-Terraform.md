## 1. ¿Para qué sirven los outputs?

Cuando creas infraestructura, Azure genera datos que no conocías de antemano: el ID completo de un recurso, el endpoint de una cuenta de almacenamiento, la clave de acceso que te permite usarla. Terraform los guarda en el estado, pero no te los muestra a menos que se lo pidas. Un output es esa petición. Se usa para:

- **Informar a la persona** que ejecuta `apply`: "este es el grupo que he creado, este es el endpoint".
- **Alimentar scripts**: un *pipeline* lee `terraform output -json` y sigue con la Azure CLI, pruebas o despliegue de aplicación.
- **Conectar módulos**: lo que un módulo expone como output, otro lo consume como argumento (`module.red.subredes`).

Un detalle que ahorra confusiones: `terraform output` **lee del estado**, no de los archivos `.tf`. Si añades un output y ejecutas `terraform output` sin haber aplicado, no aparece. Un `terraform apply` (aunque no cambie recursos) lo actualiza.

---

## 2. Sintaxis

```hcl
output "storage_endpoint_blob" {
  description = "Endpoint del servicio de blobs de la cuenta de almacenamiento"
  value       = azurerm_storage_account.lab.primary_blob_endpoint
}
```

| **Argumento** | **Función** | **¿Obligatorio?** |
|---|---|---|
| `value` | Cualquier expresión: atributo de recurso, variable, local, función, objeto construido | Sí |
| `description` | Qué contiene y para qué sirve; es la documentación del módulo | No, pero ponla siempre |
| `sensitive` | Oculta el valor en consola (sección 3.6) | Sí, si el valor deriva de algo sensible |
| `precondition` | Regla que debe cumplirse antes de publicar el valor (sección 3.7) | No |
| `depends_on` | Dependencia explícita; casi nunca hace falta | No |

Por convención los outputs van en `outputs.tf`, igual que las variables en `variables.tf`. Terraform no lo exige, pero quien abra el módulo sabrá dónde mirar.

---

## 3. Ejemplo práctico en Topaz

> **🔷 En Topaz.** El emulador no incluye `Microsoft.Compute`, así que el ejemplo original (VM con IP pública y Apache) no puede ejecutarse. Una cuenta de almacenamiento ofrece los mismos tipos de output que una VM y uno mejor: una **clave de acceso real** que Terraform obtiene de la API, perfecta para practicar outputs sensibles.

### Paso 1. Estructura y provider

```bash
mkdir -p ~/tf-outputs && cd ~/tf-outputs
```

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
  features {}
  metadata_host                   = "topaz.local.dev:8899"
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}
```

### Paso 2. `variables.tf` y `main.tf`

```hcl
# variables.tf
variable "sufijo" {
  type        = string
  description = "Sufijo único por alumno para la cuenta de almacenamiento (minúsculas y dígitos)"
  default     = "001"
  validation {
    condition     = can(regex("^[a-z0-9]{3,8}$", var.sufijo))
    error_message = "De 3 a 8 caracteres, solo minúsculas y dígitos."
  }
}

variable "crear_storage" {
  type        = bool
  description = "Crear o no la cuenta de almacenamiento"
  default     = true
}
```

```hcl
# main.tf
locals {
  tags     = { entorno = "lab", gestion = "terraform", modulo = "outputs" }
  subredes = { web = "10.0.1.0/24", data = "10.0.2.0/24" }
}

resource "azurerm_resource_group" "lab" {
  name     = "rg-outputs-${var.sufijo}"
  location = "eastus"
  tags     = local.tags

  lifecycle {
    ignore_changes = [tags]          # Topaz no devuelve las tags del grupo
  }
}

resource "azurerm_virtual_network" "lab" {
  name                = "vnet-outputs"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["10.0.0.0/16"]
  tags                = local.tags
}

resource "azurerm_subnet" "lab" {
  for_each = local.subredes

  name                 = "snet-${each.key}"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [each.value]
}

resource "azurerm_storage_account" "lab" {
  count = var.crear_storage ? 1 : 0

  name                       = "stoutputs${var.sufijo}"
  resource_group_name        = azurerm_resource_group.lab.name
  location                   = azurerm_resource_group.lab.location
  account_tier               = "Standard"
  account_replication_type   = "LRS"
  https_traffic_only_enabled = true
  tags                       = local.tags
}
```

### Paso 3. `outputs.tf` (primera versión)

```hcl
output "grupo_recursos" {
  description = "Nombre del grupo de recursos"
  value       = azurerm_resource_group.lab.name
}

output "grupo_recursos_id" {
  description = "ID completo del grupo (ruta ARM)"
  value       = azurerm_resource_group.lab.id
}

output "red_virtual" {
  description = "Nombre de la red virtual"
  value       = azurerm_virtual_network.lab.name
}

output "subredes" {
  description = "Prefijo de cada subred, por nombre corto"
  value       = { for k, s in azurerm_subnet.lab : k => s.address_prefixes[0] }
}
```

### Paso 4. Aplicar y leer

```bash
terraform init
terraform apply -auto-approve
```

```text
Apply complete! Resources: 5 added, 0 changed, 0 destroyed.

Outputs:

grupo_recursos    = "rg-outputs-001"
grupo_recursos_id = "/subscriptions/00000000-0000-0000-0000-000000000001/resourceGroups/rg-outputs-001"
red_virtual       = "vnet-outputs"
subredes = {
  "data" = "10.0.2.0/24"
  "web"  = "10.0.1.0/24"
}
```
Los outputs aparecen al final de cada `apply`. Fíjate en que el mapa `subredes` sale ordenado alfabéticamente por clave: Terraform siempre ordena los mapas, independientemente de cómo los escribas.

---

## 4. Tipos de datos en outputs

Un output no declara tipo: lo hereda de la expresión. Añade estos a `outputs.tf`; cubren los cinco tipos básicos más `object`, con valores que existen de verdad en el emulador:

```hcl
# string
output "ubicacion" {
  description = "Región donde se ha desplegado todo"
  value       = azurerm_resource_group.lab.location
}

# number (calculado: el número de subredes creadas)
output "numero_subredes" {
  description = "Cuántas subredes existen en la red virtual"
  value       = length(azurerm_subnet.lab)
}

# bool
output "storage_solo_https" {
  description = "Si la cuenta de almacenamiento exige HTTPS"
  value       = one(azurerm_storage_account.lab[*].https_traffic_only_enabled)
}

# list(string)
output "espacio_direcciones" {
  description = "Rangos de la red virtual"
  value       = azurerm_virtual_network.lab.address_space
}

# map(string)
output "etiquetas" {
  description = "Etiquetas aplicadas a la red virtual"
  value       = azurerm_virtual_network.lab.tags
}

# object construido a mano: agrupa lo que un equipo necesita saber
output "storage" {
  description = "Resumen de la cuenta de almacenamiento (null si no se creó)"
  value = var.crear_storage ? {
    nombre        = azurerm_storage_account.lab[0].name
    endpoint_blob = azurerm_storage_account.lab[0].primary_blob_endpoint
    replicacion   = azurerm_storage_account.lab[0].account_replication_type
  } : null
}
```

```bash
terraform apply -auto-approve          # "0 added, 0 changed": solo actualiza outputs
terraform output numero_subredes       # 2
terraform output storage_solo_https    # true
terraform output storage
```

> **🔷 En Topaz.** Dos detalles: `etiquetas` lee las de la **red virtual** y no las del grupo porque el emulador no devuelve las etiquetas del grupo de recursos (por eso lleva `ignore_changes`); un output de `azurerm_resource_group.lab.tags` saldría vacío. Y el `endpoint_blob` que devuelve el emulador identifica la cuenta, pero no es un servicio alcanzable como en Azure real: sirve para ver el mecanismo, no para subir blobs.

Sobre `one(azurerm_storage_account.lab[*].x)`: con `count`, el recurso es una lista. `[*]` extrae el atributo de todos los elementos y `one()` devuelve el único, o `null` si la lista está vacía. Es la forma limpia de leer un recurso condicional sin que falle cuando `count = 0`.

---

## 5. Consumir outputs

```bash
terraform output                        # todos, en formato HCL legible
terraform output subredes               # uno, en HCL
terraform output -raw grupo_recursos    # solo el valor, sin comillas: para scripts (solo string/number/bool)
terraform output -json                  # todos, en JSON
terraform output -json subredes         # uno, en JSON
```

Los dos últimos son los que usan los *pipelines*. Con `-raw` encadenas directamente con la Azure CLI:

```bash
RG=$(terraform output -raw grupo_recursos)
az resource list -g "$RG" -o table
az network vnet show -g "$RG" -n "$(terraform output -raw red_virtual)" --query addressSpace.addressPrefixes -o tsv
```

Con `-json` y `jq` recorres estructuras. Observa el formato: cada output es un objeto con `sensitive`, `type` y `value`:

```bash
terraform output -json | jq '.subredes'
```

```json
{
  "sensitive": false,
  "type": [ "object", { "data": "string", "web": "string" } ],
  "value": { "data": "10.0.2.0/24", "web": "10.0.1.0/24" }
}
```

```bash
# Recorrer el mapa y verificar cada subred contra el emulador
for s in $(terraform output -json subredes | jq -r 'keys[]'); do
  az network vnet subnet show -g "$RG" --vnet-name vnet-outputs -n "snet-$s" \
    --query "{nombre:name, prefijo:addressPrefix}" -o tsv
done
```

> ⚠️ **`-raw` solo acepta valores primitivos.** `terraform output -raw subredes` falla con *Unsupported value for raw output*: para mapas, listas y objetos usa `-json`.

---

## 6. Outputs sensibles

La cuenta de almacenamiento tiene dos claves de acceso; quien las tenga puede leer y escribir todo su contenido. Terraform las obtiene de la API y las expone como `primary_access_key` y `primary_connection_string`, ambos atributos marcados como sensibles por el provider. Si quieres publicarlos, el output **debe** llevar `sensitive = true`; si no, Terraform se niega:

```hcl
output "storage_clave_primaria" {
  description = "Clave de acceso primaria (secreto)"
  value       = one(azurerm_storage_account.lab[*].primary_access_key)
  sensitive   = true
}

output "storage_cadena_conexion" {
  description = "Cadena de conexión para SDKs y azcopy (secreto)"
  value       = one(azurerm_storage_account.lab[*].primary_connection_string)
  sensitive   = true
}
```

```bash
terraform apply -auto-approve
#   storage_clave_primaria  = <sensitive>
#   storage_cadena_conexion = <sensitive>

terraform output storage_clave_primaria          # <sensitive>
terraform output -raw storage_clave_primaria     # el valor, sin ocultar: -raw y -json lo muestran siempre
jq '.outputs.storage_clave_primaria.value' terraform.tfstate     # también en claro
```

> ⚠️ **Qué protege `sensitive` y qué no.**
> - **Protege** la consola: `plan`, `apply` y `terraform output` muestran `<sensitive>`. Eso evita que el secreto acabe en el *log* de un pipeline.
> - **No protege** el estado: acabas de leerlo con `jq`. Todos los outputs, sensibles o no, se guardan en `terraform.tfstate` en texto claro. El original decía "evita guardar outputs sensibles en el estado": no es posible; lo que se protege es el estado (backend remoto con acceso restringido, nunca en Git).
> - **No protege** frente a `-raw` ni `-json`: están pensados para scripts que necesitan el valor real.
> - Un output que *deriva* de algo sensible (por ejemplo `"clave=${...primary_access_key}"`) también debe ser sensible, o Terraform da *Output refers to sensitive values*.

> **🔷 En Topaz.** La clave que devuelve el emulador la genera el propio emulador y solo sirve dentro de él; puedes mostrarla sin riesgo. En Azure real esa misma clave da acceso total a la cuenta: la práctica correcta es no exponerla como output y que las aplicaciones se autentiquen con identidad administrada, o leerla desde Key Vault en el momento de uso.

---

## 7. Outputs dinámicos: condicionales, plantillas y precondiciones

El `value` es una expresión completa, así que puedes construir mensajes, comandos listos para copiar o valores que dependen de la configuración:

```hcl
# Condicional: texto distinto según exista o no el recurso
output "storage_endpoint_blob" {
  description = "Endpoint de blobs, o aviso si la cuenta no se creó"
  value = var.crear_storage ? azurerm_storage_account.lab[0].primary_blob_endpoint : "sin cuenta de almacenamiento (crear_storage = false)"

  precondition {
    condition     = !var.crear_storage || startswith(azurerm_storage_account.lab[0].primary_blob_endpoint, "https://")
    error_message = "El endpoint de blobs debe usar HTTPS."
  }
}

# Plantilla: un comando listo para pegar en la terminal
output "comando_verificacion" {
  description = "Comando az para listar lo desplegado"
  value       = "az resource list -g ${azurerm_resource_group.lab.name} -o table"
}

# format(): resumen legible de varias fuentes
output "resumen" {
  description = "Una línea con lo esencial del despliegue"
  value = format(
    "%s en %s: %d subredes en %s%s",
    azurerm_resource_group.lab.name,
    azurerm_resource_group.lab.location,
    length(azurerm_subnet.lab),
    azurerm_virtual_network.lab.name,
    var.crear_storage ? " + cuenta ${azurerm_storage_account.lab[0].name}" : ""
  )
}
```

```bash
terraform apply -auto-approve
terraform output -raw resumen
#   rg-outputs-001 en eastus: 2 subredes en vnet-outputs + cuenta stoutputs001

terraform plan -var crear_storage=false
#   ~ storage_endpoint_blob = "https://..." -> "sin cuenta de almacenamiento (crear_storage = false)"
#   ~ storage = { ... } -> null
#   Plan: 0 to add, 0 to change, 1 to destroy.
```

El original usaba `provisioning_state == "Succeeded"` para un "estado de la VM": ese atributo no existe en el recurso, y además un output solo se calcula cuando el recurso ya está creado, así que siempre diría "lista". La `precondition` es el mecanismo adecuado para comprobar algo del resultado: si falla, el `apply` se detiene con tu mensaje.

Para probar expresiones sin aplicar nada, `terraform console` evalúa contra el estado actual:

```bash
echo 'keys(azurerm_subnet.lab)' | terraform console
#   tolist(["data", "web"])
```

---

## 8. Outputs entre módulos

Hasta ahora los outputs están en el **módulo raíz** y los lee una persona o un script. Cuando el mismo código se convierte en un módulo hijo, sus outputs son la única forma de que el exterior acceda a lo que ha creado:

```hcl
# modules/red/outputs.tf: lo que el módulo expone
output "subred_ids" {
  description = "ID de cada subred, por nombre corto"
  value       = { for k, s in azurerm_subnet.lab : k => s.id }
}

# raíz: consumo del output del módulo
module "red" {
  source = "./modules/red"
}

output "subred_web_id" {
  value = module.red.subred_ids["web"]        # module.<nombre>.<output>
}
```

Un recurso del módulo que no está en un output es invisible desde fuera: no se puede escribir `module.red.azurerm_subnet.lab`. Por eso los outputs de un módulo son su **interfaz pública**, y su `description` es la documentación que verá quien lo use. Lo verás en profundidad en el tema de módulos.

---

## 9. Ejemplo completo: script de verificación

Este es el uso más habitual de los outputs en un equipo: un script que, tras el `apply`, comprueba contra la API que lo que Terraform cree haber creado existe de verdad. Guárdalo como `verificar.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

RG=$(terraform output -raw grupo_recursos)
VNET=$(terraform output -raw red_virtual)

echo "== Grupo de recursos =="
az group show -n "$RG" --query "{nombre:name, region:location, estado:properties.provisioningState}" -o table

echo; echo "== Subredes =="
terraform output -json subredes | jq -r 'to_entries[] | "\(.key)\t\(.value)"' | while IFS=$'\t' read -r nombre prefijo; do
  real=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET" -n "snet-$nombre" --query addressPrefix -o tsv)
  [ "$real" = "$prefijo" ] && echo "OK   snet-$nombre  $prefijo" || echo "FAIL snet-$nombre  terraform=$prefijo azure=$real"
done

echo; echo "== Almacenamiento =="
if [ "$(terraform output -json storage)" != "null" ]; then
  ST=$(terraform output -json storage | jq -r '.nombre')
  az storage account show -g "$RG" -n "$ST" --query "{nombre:name, sku:sku.name, https:enableHttpsTrafficOnly}" -o table
else
  echo "Sin cuenta de almacenamiento (crear_storage = false)"
fi

echo; terraform output -raw resumen; echo
```

```bash
chmod +x verificar.sh && ./verificar.sh
```

```text
== Grupo de recursos ==
Nombre           Region    Estado
---------------  --------  ---------
rg-outputs-001   eastus    Succeeded

== Subredes ==
OK   snet-data  10.0.2.0/24
OK   snet-web   10.0.1.0/24

== Almacenamiento ==
Nombre         Sku           Https
-------------  ------------  -------
stoutputs001   Standard_LRS  True

rg-outputs-001 en eastus: 2 subredes en vnet-outputs + cuenta stoutputs001
```

El script no contiene ni un solo nombre fijo: todo lo obtiene de los outputs. Si mañana cambias el `sufijo` o añades una subred, sigue funcionando sin tocarlo. Esa es la idea: los outputs son el contrato entre Terraform y todo lo que viene después.

### Limpieza

```bash
terraform destroy -auto-approve
terraform output                 # vacío: los outputs desaparecen con el estado
az group list -o table           # rg-outputs-001 ya no aparece
```

---

## 10. Buenas prácticas

✅ **Recomendaciones clave:**
- **Nombres descriptivos y consistentes**: `storage_endpoint_blob`, no `endpoint`. Prefijo por recurso cuando hay varios.
- **`description` siempre**: en un módulo es la documentación que ve quien lo consume.
- **Expón IDs, no solo nombres**: otros recursos y módulos casi siempre necesitan el `id` completo.
- **Agrupa en objetos** lo que se consume junto (`storage = { nombre, endpoint, replicacion }`) en vez de tres outputs sueltos.
- **`one()` y condicionales** para recursos con `count`: un output nunca debe romper el `apply` porque el recurso no exista.
- **`sensitive = true` en todo lo derivado de un secreto**, y estado protegido: la marca oculta la consola, no el `tfstate`.
- **No expongas secretos si puedes evitarlo**: en Azure real, identidad administrada o Key Vault en lugar de claves de cuenta en outputs.
- **`-raw` para primitivos, `-json` para estructuras**: es lo que los scripts deben usar, nunca parsear la salida HCL.

⚠️ **Errores comunes**

| **Mensaje o síntoma** | **Causa y solución** |
|---|---|
| El output nuevo no aparece con `terraform output` | Lee del estado, no del `.tf`: ejecuta `terraform apply` (aunque no cambie recursos) |
| *Output refers to sensitive values* | El valor deriva de un atributo sensible: añade `sensitive = true` |
| *Unsupported value for raw output* | `-raw` solo acepta string, number y bool: usa `-json` para mapas y listas |
| *Missing resource instance key* | Recurso con `count` referenciado sin índice: `lab[0].x` u `one(lab[*].x)` |
| *Invalid index* al poner `crear_storage=false` | `lab[0]` no existe: protege con condicional o `one()` |
| *Unsupported attribute* | El atributo no existe en el recurso (como `provisioning_state` en la VM del original): consulta la pestaña *Attributes Reference* del provider |
| Output `etiquetas` del grupo sale vacío | Topaz no devuelve las tags del grupo de recursos: léelas de la red virtual o del storage |
| *Missing newline after argument* con HTML en el `.tf` | Filtro de auto-enlace de Moodle al copiar: `sed -i 's/<[^>]*>//g' *.tf` |

---

## 11. Autoevaluación

1. **¿De dónde lee su valor `terraform output`?**
   Del estado. Un output añadido al `.tf` no aparece hasta el siguiente `apply`.
2. **¿Qué diferencia hay entre `terraform output x`, `-raw x` y `-json x`?**
   HCL legible; valor crudo sin comillas (solo primitivos); JSON con `sensitive`, `type` y `value`. Los dos últimos muestran también los sensibles.
3. **¿Qué hace y qué no hace `sensitive = true` en un output?**
   Oculta el valor en `plan`, `apply` y `output`. No lo cifra: sigue en claro en el estado y accesible con `-raw`/`-json`.
4. **¿Por qué `one(azurerm_storage_account.lab[*].name)` en lugar de `azurerm_storage_account.lab[0].name`?**
   Con `count = 0` el índice `[0]` falla; `one()` devuelve `null` sin error.
5. **¿Para qué sirve una `precondition` en un output?**
   Para comprobar algo del resultado antes de publicarlo; si falla, el `apply` se detiene con tu mensaje.
6. **¿Cómo accede un módulo raíz a un recurso creado dentro de un módulo hijo?**
   Solo a través de los outputs del hijo: `module.nombre.output`. Los recursos internos no son visibles.
7. **¿Por qué el output `etiquetas` del ejemplo lee la red virtual y no el grupo?**
   Topaz no devuelve las etiquetas del grupo de recursos; las de red y storage sí.

---

## 12. Referencias

- [Valores de salida](https://developer.hashicorp.com/terraform/language/values/outputs) (sintaxis, `sensitive`, `precondition`)
- [Comando `terraform output`](https://developer.hashicorp.com/terraform/cli/commands/output) (`-raw`, `-json`)
- [`one()`](https://developer.hashicorp.com/terraform/language/functions/one), [`format()`](https://developer.hashicorp.com/terraform/language/functions/format) y [expresiones `[*]`](https://developer.hashicorp.com/terraform/language/expressions/splat)
- [Condiciones personalizadas](https://developer.hashicorp.com/terraform/language/expressions/custom-conditions)
- [Datos sensibles en el estado](https://developer.hashicorp.com/terraform/language/state/sensitive-data)
- [`terraform console`](https://developer.hashicorp.com/terraform/cli/commands/console)
- [Atributos de `azurerm_storage_account`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account#attributes-reference)
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)