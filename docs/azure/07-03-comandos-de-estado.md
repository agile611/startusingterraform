# 🧭 Cirugía del estado: importar, mover, recrear, olvidar

> El estado relaciona cada dirección del código (`module.red.azurerm_subnet.this["web"]`) con un id real de Azure. Cuando cambias el código sin que cambie la infraestructura (renombrar, mover a un módulo, pasar de `count` a `for_each`) o cuando la infraestructura existe sin que exista el código (recursos creados a mano), esa relación se rompe y el `plan` propone destruir y crear. Esta página enseña a reparar la relación sin tocar Azure: los bloques declarativos `import`, `moved` y `removed`, sus equivalentes imperativos `terraform import`, `state mv` y `state rm`, y `apply -replace` para cuando sí quieres recrear. Todo funciona en **Topaz**: el laboratorio usa recursos de red y una cuenta de almacenamiento por el plano de gestión.

**🎯 Objetivos de aprendizaje**
- Escribir direcciones de estado correctas: módulos, `count`, `for_each` y cuándo hacen falta comillas.
- Adoptar un recurso creado a mano con el bloque `import` y generar su configuración con `-generate-config-out`.
- Renombrar recursos, moverlos a un módulo y pasar de `count` a `for_each` con `moved`, sin destruir nada.
- Recrear un recurso concreto con `apply -replace` y saber por qué `taint` ya no se usa.
- Sacar un recurso del estado sin borrarlo (`removed`) y dividir un proyecto en dos con `state mv -state-out`.

> **🔷 Requisitos previos.** [Páginas 1](index.md#pagina-1) a 8 completadas y destruidas, `~/tf-st/providers.tf` disponible, Terraform `>= 1.7` (bloque `removed`; `import` y `-generate-config-out` desde 1.5), `jq`, `az account show --query environmentName -o tsv` → `Topaz`.

---

## 1. Direcciones: cómo se llama cada cosa en el estado

Todos los comandos de esta página reciben una *dirección*. El original usaba `module.red.mi_ip`, que no existe: dentro de un módulo la dirección sigue necesitando tipo y nombre.

| **Código** | **Dirección** | **En la shell** |
|---|---|---|
| `resource "azurerm_subnet" "web"` | `azurerm_subnet.web` | Sin comillas: puntos y guiones no molestan |
| … con `count = 2` | `azurerm_subnet.web[0]`, `[1]` | Comillas simples: `'azurerm_subnet.web[0]'` (los corchetes son *glob* en bash) |
| … con `for_each` | `azurerm_subnet.web["datos"]` | Comillas simples fuera, dobles dentro: `'azurerm_subnet.web["datos"]'` |
| `module "red" { … }` → dentro `resource "azurerm_subnet" "this"` | `module.red.azurerm_subnet.this["web"]` | El módulo entero: `module.red` (válido en `moved`, `state mv`, `state rm`) |
| `module "red" { for_each = … }` | `module.red["hub"].azurerm_virtual_network.this` | Igual que arriba |
| `data "azurerm_client_config" "actual"` | `data.azurerm_client_config.actual` | Los `data` están en el estado pero no se importan ni mueven: se releen |

```bash
terraform state list                                  # todas las direcciones, la fuente de verdad para copiar y pegar
terraform state list module.red                       # filtrar por prefijo
terraform state show 'module.red.azurerm_subnet.this["web"]'   # atributos guardados (incluye secretos si los hay)
terraform state pull | jq -r '.resources[] | .module // "root" + " " + .type + "." + .name'
```

---

## 2. Importar: adoptar lo que ya existe

Importar añade al estado un recurso que existe en Azure y lo enlaza con un bloque `resource`. Desde ese momento Terraform lo gestiona por completo; lo que exige es que el código describa el recurso tal como está, o el siguiente `plan` intentará "corregirlo". La forma moderna es el bloque `import`, que queda en Git, admite `for_each` y puede escribir el código por ti.

```bash
# 1. Obtén el id EXACTO (los ids de ARM distinguen mayúsculas: resourceGroups, networkSecurityGroups…)
az network nsg show -g rg-cmd-lab-001 -n nsg-web --query id -o tsv

# 2. Bloque import (en import.tf, temporal). El "to" aún no existe en el código
import {
  to = azurerm_network_security_group.web
  id = "/subscriptions/…/resourceGroups/rg-cmd-lab-001/providers/Microsoft.Network/networkSecurityGroups/nsg-web"
}

# 3. Deja que Terraform escriba el bloque resource a partir de lo que lee en Azure
terraform plan -generate-config-out=generado.tf     # "1 to import"; crea generado.tf
#    Revisa generado.tf: trae TODOS los atributos (muchos en null o por defecto). Recórtalo al mínimo
#    que quieras gobernar, sustituye literales por referencias (resource_group_name = azurerm_resource_group.lab.name),
#    muévelo a main.tf y borra generado.tf
terraform plan                                       # "1 to import, 0 to change": el código coincide
terraform apply -auto-approve && rm import.tf        # el bloque import se retira una vez aplicado

# Forma imperativa (equivalente, sin rastro en Git; el bloque resource debe existir ANTES):
terraform import azurerm_network_security_group.web "$(az network nsg show -g rg-cmd-lab-001 -n nsg-web --query id -o tsv)"

# Varios de golpe:
import {
  for_each = { web = "…/networkSecurityGroups/nsg-web", datos = "…/networkSecurityGroups/nsg-datos" }
  to       = azurerm_network_security_group.this[each.key]
  id       = each.value
}
```

| **Recurso** | **Id que espera `import`** | **Cómo obtenerlo** |
|---|---|---|
| Casi todos (grupo, VNet, NSG, cuenta, VM…) | El id de ARM completo | `az <servicio> show … --query id -o tsv` |
| Subred, regla de NSG (recursos hijo) | Id de ARM que incluye al padre: `…/virtualNetworks/vnet/subnets/snet-web` | `az network vnet subnet show … --query id` |
| Contenedor de blobs (azurerm 4.x con `storage_account_id`) | `…/storageAccounts/st…/blobServices/default/containers/tfstate` | `az storage container-rm show … --query id` (ARM, ✅ Topaz) |
| Asignación de rol | `<scope>/providers/Microsoft.Authorization/roleAssignments/<guid>` | `az role assignment list --scope … --query "[].id"` (solo Azure real) |
| `random_password`, `tls_private_key`… | No se pueden importar: no existen fuera del estado | Se regeneran (y se rota el secreto) o se leen de Key Vault con un `data` |

> ⚠️ **El código generado no es el código final.** `-generate-config-out` vuelca todos los atributos que el provider devuelve, incluidos los calculados y los que no deberías fijar. Aplicarlo tal cual funciona, pero deja un bloque de 60 líneas ilegible que además referencia el grupo por su nombre literal. La regla es la misma que en la [página 6](index.md#pagina-6): gobierna lo que decides, referencia lo demás, y `plan` hasta ver *0 to change*.

---

## 3. Mover: refactorizar sin destruir

Renombrar un recurso, meterlo en un módulo o cambiar su `count` por `for_each` cambia su dirección. Para Terraform, la dirección antigua "ha desaparecido" (destruir) y la nueva "es nueva" (crear). El bloque `moved` le dice que son la misma cosa; `state mv` hace lo mismo desde la terminal.

| **Refactor** | **Bloque `moved`** |
|---|---|
| Renombrar un recurso | `moved { from = azurerm_subnet.web to = azurerm_subnet.frontal }` |
| Meterlo en un módulo | `moved { from = azurerm_virtual_network.lab to = module.red.azurerm_virtual_network.this }` |
| Renombrar un módulo (mueve todo su contenido) | `moved { from = module.red to = module.red_principal }` |
| `count` → `for_each` | `moved { from = azurerm_subnet.this[0] to = azurerm_subnet.this["web"] }` (uno por índice) |
| Recurso suelto → instancia de `for_each` | `moved { from = azurerm_subnet.web to = azurerm_subnet.this["web"] }` |
| Módulo sin `for_each` → con `for_each` | `moved { from = module.red to = module.red["hub"] }` |

| **&nbsp;** | **Bloque `moved`** | **`terraform state mv`** |
|---|---|---|
| Dónde queda | En el código y en Git: quien haga `pull` obtiene el mismo resultado | En el estado, una sola vez; sin rastro salvo el historial de la terminal |
| Cuándo se aplica | En el siguiente `plan`/`apply`, con el lock tomado | Inmediatamente (toma el lock). `-dry-run` para ver sin tocar |
| En módulos publicados | ✅ El autor del módulo añade el `moved` y todos los consumidores migran al actualizar | ❌ Cada consumidor a mano |
| Entre dos estados | ❌ | ✅ `-state-out=../otro/terraform.tfstate`: dividir un proyecto |
| Después | Se puede borrar el bloque una vez aplicado en todos los entornos (o dejarlo: es inofensivo) | Nada que limpiar |

---

## 4. Recrear: `-replace`, no `taint`

`terraform taint` marcaba un recurso en el estado para que el *siguiente* `apply`, de quien fuera, lo recreara. Está deprecado desde Terraform 0.15.2 y al ejecutarlo avisa: el problema es que modifica el estado compartido de forma silenciosa, y otra persona puede lanzar ese `apply` sin saber qué va a destruir. La opción `-replace` hace lo mismo pero en la operación actual, visible en el plan.

```bash
terraform plan  -replace='module.red.azurerm_subnet.this["web"]'      # "# module.red.azurerm_subnet.this["web"] will be replaced, as requested"
terraform apply -replace='module.red.azurerm_subnet.this["web"]'      # varios: repite -replace
terraform taint 'module.red.azurerm_subnet.this["web"]'               # funciona, pero: "Warning: Command taint is deprecated"
terraform untaint 'module.red.azurerm_subnet.this["web"]'             # deshace la marca. Útil si heredas un estado con recursos tainted

# Declarativo: recrear B cada vez que A cambie (por ejemplo, una extensión de VM cuando cambia el script)
resource "azurerm_virtual_machine_extension" "bootstrap" {
  # …
  lifecycle { replace_triggered_by = [azurerm_storage_blob.script.content_md5] }
}
```

| **Cuándo recrear a mano** | **Cuándo no** |
|---|---|
| Una VM cuya extensión falló a medias y quedó en estado inconsistente; un recurso que Azure reporta como sano pero no funciona; probar que el módulo es reproducible | "Tiene una configuración incorrecta y no se puede actualizar" (el ejemplo del original): primero mira *por qué*. Si es un atributo *ForceNew*, el plan ya propone reemplazo sin que lo pidas. Si es un error del provider, `-replace` no lo arregla |
| Cuentas de almacenamiento, bases de datos, Key Vaults: **nunca** con `-replace` a la ligera: se destruyen los datos. Y con `prevent_destroy = true` ni siquiera te dejará | &nbsp; |

---

## 5. Olvidar, dividir y el resto de la caja de herramientas

| **Herramienta** | **Para qué** | **Cuidado con** |
|---|---|---|
| `removed { from = A lifecycle { destroy = false } }` | Dejar de gestionar un recurso sin borrarlo: pasa a otro proyecto o a gestión manual. Se retira el `resource` del código y se añade este bloque | Con `destroy = true` (o sin `lifecycle`) lo destruye: es el comportamiento normal de borrar el bloque |
| `terraform state rm A` | Lo mismo, imperativo. Acepta módulos enteros | Si el `resource` sigue en el código, el siguiente `plan` intentará *crearlo* y fallará por nombre duplicado |
| `state mv -state-out=../b/terraform.tfstate A A` | Dividir un proyecto: mueve el recurso al estado de otro directorio. Después, el código se mueve a `b/` y en `a/` se referencia con `data` | Con backend remoto: `state pull` en ambos, `mv` entre archivos locales, `state push` en ambos. Copia antes |
| `state replace-provider hashicorp/azurerm registry.terraform.io/hashicorp/azurerm` | Cambiar la dirección del provider en el estado (migraciones antiguas, forks, registries privados) | Solo la dirección; no cambia versiones ni esquemas |
| `apply -target=A` | Aplicar solo un recurso y sus dependencias. Para salir de un atolladero, no para el día a día | Deja el resto sin aplicar y Terraform lo recuerda: el plan siguiente lo avisa. Nunca en CI |
| `apply -refresh-only` | Aceptar en el estado cambios hechos fuera (drift) sin tocar Azure | Si alguien borró algo, lo olvida; si quieres recrearlo, `apply` normal ([página 7](index.md#pagina-7)) |

---

## 6. Laboratorio en Topaz

Un proyecto plano de red que iremos refactorizando sin destruir nada. Cada paso termina con un `plan` que debe decir *No changes*: es la prueba de que la cirugía salió bien.

```bash
mkdir -p ~/tf-cmd && cd ~/tf-cmd && cp ~/tf-st/providers.tf .
cat > main.tf <<'EOF'
resource "azurerm_resource_group" "lab" {
  name     = "rg-cmd-lab-001"
  location = "eastus"
  lifecycle { ignore_changes = [tags] }
}
resource "azurerm_virtual_network" "lab" {
  name                = "vnet-cmd-lab"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  address_space       = ["10.80.0.0/16"]
}
resource "azurerm_subnet" "web" {
  name                 = "snet-web"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.80.1.0/24"]
}
resource "azurerm_subnet" "datos" {
  name                 = "snet-datos"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.80.2.0/24"]
}
EOF
terraform init && terraform apply -auto-approve          # 4 to add
terraform state list                                      # 4 direcciones planas

# ─── 1. Importar: un NSG creado "a mano" ────────────────────────────────────────
az network nsg create -g rg-cmd-lab-001 -n nsg-web -l eastus -o none
NSG_ID=$(az network nsg show -g rg-cmd-lab-001 -n nsg-web --query id -o tsv)
cat > import.tf <<EOF
import {
  to = azurerm_network_security_group.web
  id = "$NSG_ID"
}
EOF
terraform plan -generate-config-out=generado.tf           # 1 to import
cat generado.tf                                           # bloque completo con literales y atributos por defecto
# Sustitúyelo por la versión mínima con referencias:
cat >> main.tf <<'EOF'
resource "azurerm_network_security_group" "web" {
  name                = "nsg-web"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
}
EOF
rm generado.tf
terraform plan                                            # 1 to import, 0 to change. Si dice "1 to change", falta o sobra un atributo
terraform apply -auto-approve && rm import.tf
terraform state show azurerm_network_security_group.web | head -5

# ─── 2. Renombrar: moved ────────────────────────────────────────────────────────
sed -i 's/"azurerm_subnet" "web"/"azurerm_subnet" "frontal"/' main.tf
terraform plan                                            # 1 to add, 1 to destroy: renombrar = recrear. MAL
cat >> main.tf <<'EOF'
moved {
  from = azurerm_subnet.web
  to   = azurerm_subnet.frontal
}
EOF
terraform plan                                            # "azurerm_subnet.web has moved to azurerm_subnet.frontal" · No changes
terraform apply -auto-approve                             # solo escribe el estado

# ─── 3. count/recursos sueltos → for_each ───────────────────────────────────────
# Sustituye los dos bloques azurerm_subnet por uno solo:
python3 - <<'EOF'
import re
s = open("main.tf").read()
s = re.sub(r'resource "azurerm_subnet" "frontal" \{.*?\n\}\n', '', s, flags=re.S)
s = re.sub(r'resource "azurerm_subnet" "datos" \{.*?\n\}\n', '', s, flags=re.S)
s = re.sub(r'moved \{.*?\n\}\n', '', s, flags=re.S)
s += '''
resource "azurerm_subnet" "this" {
  for_each             = { web = "10.80.1.0/24", datos = "10.80.2.0/24" }
  name                 = "snet-${each.key}"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = [each.value]
}
moved { from = azurerm_subnet.frontal  to = azurerm_subnet.this["web"] }
moved { from = azurerm_subnet.datos    to = azurerm_subnet.this["datos"] }
'''
open("main.tf", "w").write(s)
EOF
terraform fmt && terraform plan                           # 2 movidas · No changes
terraform apply -auto-approve
terraform state list                                      # azurerm_subnet.this["datos"], azurerm_subnet.this["web"]

# ─── 4. Mover a un módulo ───────────────────────────────────────────────────────
mkdir -p modules/red
cat > modules/red/main.tf <<'EOF'
variable "nombre"              { type = string }
variable "resource_group_name" { type = string }
variable "location"            { type = string }
variable "address_space"       { type = string }
variable "subredes"            { type = map(string) }

resource "azurerm_virtual_network" "this" {
  name                = var.nombre
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [var.address_space]
}
resource "azurerm_subnet" "this" {
  for_each             = var.subredes
  name                 = "snet-${each.key}"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [each.value]
}
output "subnet_ids" { value = { for k, s in azurerm_subnet.this : k => s.id } }
EOF
# En main.tf: borra la VNet, las subredes y los moved anteriores; añade la llamada y los nuevos moved
python3 - <<'EOF'
import re
s = open("main.tf").read()
s = re.sub(r'resource "azurerm_virtual_network" "lab" \{.*?\n\}\n', '', s, flags=re.S)
s = re.sub(r'resource "azurerm_subnet" "this" \{.*?\n\}\n', '', s, flags=re.S)
s = re.sub(r'moved \{[^\n]*\}\n', '', s)
s += '''
module "red" {
  source              = "./modules/red"
  nombre              = "vnet-cmd-lab"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  address_space       = "10.80.0.0/16"
  subredes            = { web = "10.80.1.0/24", datos = "10.80.2.0/24" }
}
moved { from = azurerm_virtual_network.lab  to = module.red.azurerm_virtual_network.this }
moved { from = azurerm_subnet.this          to = module.red.azurerm_subnet.this }   # mueve TODAS las instancias
'''
open("main.tf", "w").write(s)
EOF
terraform init && terraform fmt && terraform plan          # 3 movidas · No changes
terraform apply -auto-approve
terraform state list                                      # module.red.azurerm_virtual_network.this, module.red.azurerm_subnet.this["web"], …

# ─── 5. Recrear un recurso concreto: -replace ───────────────────────────────────
terraform plan  -replace='module.red.azurerm_subnet.this["web"]'   # "will be replaced, as requested": 1 to add, 1 to destroy
terraform apply -replace='module.red.azurerm_subnet.this["web"]' -auto-approve
terraform taint 'module.red.azurerm_subnet.this["datos"]'          # "Warning: Command taint is deprecated"
terraform plan                                            # 1 to add, 1 to destroy: la marca está en el estado, invisible para otros
terraform untaint 'module.red.azurerm_subnet.this["datos"]'        # quita la marca
terraform plan                                            # No changes

# ─── 6. Olvidar sin borrar: removed ────────────────────────────────────────────
# El NSG pasa a gestionarse desde otro proyecto: quitamos el resource y añadimos removed
python3 - <<'EOF'
import re
s = open("main.tf").read()
s = re.sub(r'resource "azurerm_network_security_group" "web" \{.*?\n\}\n', '', s, flags=re.S)
s += '''
removed {
  from = azurerm_network_security_group.web
  lifecycle { destroy = false }
}
'''
open("main.tf", "w").write(s)
EOF
terraform plan                                            # "will no longer be managed by Terraform, but will not be destroyed"
terraform apply -auto-approve
az network nsg show -g rg-cmd-lab-001 -n nsg-web --query name -o tsv     # nsg-web: sigue existiendo
terraform state list | grep -c nsg                        # 0
sed -i '/^removed {/,/^}/d' main.tf                       # el bloque removed se retira una vez aplicado

# ─── 7. Dividir un proyecto: state mv -state-out ───────────────────────────────
# El NSG (y cualquier otro recurso de seguridad) tendrá su propio proyecto ~/tf-cmd-seg
mkdir -p ~/tf-cmd-seg && cp providers.tf ~/tf-cmd-seg/
cat > ~/tf-cmd-seg/main.tf <<'EOF'
data "azurerm_resource_group" "lab" { name = "rg-cmd-lab-001" }       # el grupo lo gobierna el otro proyecto: se lee, no se crea

resource "azurerm_network_security_group" "web" {
  name                = "nsg-web"
  resource_group_name = data.azurerm_resource_group.lab.name
  location            = data.azurerm_resource_group.lab.location
}
EOF
# Primero volvemos a adoptar el NSG aquí para tener algo que mover (import imperativo, para variar):
cat >> main.tf <<'EOF'
resource "azurerm_network_security_group" "web" {
  name                = "nsg-web"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
}
EOF
terraform import azurerm_network_security_group.web "$NSG_ID"
terraform plan                                            # No changes

# Ahora la división: copia, mueve entre estados, limpia el código de origen
terraform state pull > copia-antes-de-dividir.json
cd ~/tf-cmd-seg && terraform init && cd ~/tf-cmd
terraform state mv -state-out=../tf-cmd-seg/terraform.tfstate \
  azurerm_network_security_group.web azurerm_network_security_group.web
#   "Move "azurerm_network_security_group.web" to "azurerm_network_security_group.web"  · Successfully moved 1 object(s)."
sed -i '/^resource "azurerm_network_security_group" "web" {/,/^}/d' main.tf
terraform plan                                            # No changes: aquí ya no está
cd ~/tf-cmd-seg && terraform plan                         # No changes: aquí está, y el data lee el grupo
terraform state list                                      # data.azurerm_resource_group.lab, azurerm_network_security_group.web
#   Con backend remoto sería: state pull en ambos → mv entre los dos archivos locales → state push en ambos (página 7)

# ─── 8. Limpiar ────────────────────────────────────────────────────────────────
terraform destroy -auto-approve                           # tf-cmd-seg: borra el NSG (el data no se destruye)
cd ~/tf-cmd && terraform destroy -auto-approve            # grupo, VNet, subredes
```

> **🔷 La regla del laboratorio.** Cada paso ha terminado en *No changes* (o en el reemplazo que se pidió expresamente). Si en tu Topaz un `plan` tras `moved` muestra un *update in-place* de tags o de algún atributo que el emulador devuelve vacío, no es un fallo de la cirugía: es la misma diferencia de lectura anotada en la columna "En Topaz" de las páginas anteriores. Lo que nunca debe aparecer tras un `moved` o un `import` correcto es un *destroy*.

---

## 7. Errores comunes

> ⚠️ **Solución de problemas**
> 
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | *Resource already managed by Terraform* al importar | Ya está en el estado, quizá con otra dirección. `state list | grep`; si es un renombrado, usa `moved`, no `import` |
> | *Cannot import non-existent remote object* | El id está mal: mayúsculas de ARM (`resourceGroups`, `networkSecurityGroups`), subscription equivocada o recurso ya borrado. Cópialo de `az … show --query id`, nunca a mano |
> | *Configuration for import target does not exist* | Falta el bloque `resource` al que apunta `to`. Escríbelo o usa `-generate-config-out` |
> | Tras importar, `plan` dice *1 to change* (o *replace*) | El código no coincide con la realidad. Compara `state show` con tu bloque; si el atributo es *ForceNew*, arregla el código, no apliques: destruiría el recurso que acabas de adoptar |
> | *Invalid target address* / *Unknown resource* en `state mv` | Dirección mal escrita (el `module.red.mi_ip` del original). Necesita tipo y nombre: `module.red.azurerm_public_ip.mi_ip`. Copia de `state list` |
> | *no matches found: azurerm_subnet.this[0]* (zsh) o el corchete desaparece (bash) | La shell interpreta `[]` como *glob*. Comillas simples alrededor de toda la dirección |
> | *Moved object still exists* | El bloque `resource` con el nombre antiguo (`from`) sigue en el código. `moved` exige que solo exista el nuevo |
> | *Resource type mismatch* en `moved` | `moved` solo mueve entre el mismo tipo. Cambiar `azurerm_virtual_machine` por `azurerm_linux_virtual_machine` exige `removed` + `import` |
> | Tras mover un módulo, el `plan` quiere recrear los recursos con `for_each` | Faltan las claves: `moved` de `module.red` a `module.red["hub"]` mueve todo; pero de `azurerm_subnet.a` a `this["web"]` hace falta un bloque por instancia |
> | *Warning: Command taint is deprecated* | Usa `apply -replace=<dir>`. Si heredas un estado con recursos marcados, `untaint` sigue disponible |
> | Tras `state rm`, el `plan` quiere crear el recurso y `apply` falla con *already exists* | Olvidaste quitar el `resource` del código. `removed` te obliga a hacerlo; `state rm` no. Vuelve a importarlo o borra el bloque |
> | *Instance cannot be destroyed* con `-replace` | `prevent_destroy = true` está haciendo su trabajo. Si de verdad quieres recrearlo, quítalo en el código, aplica, y vuelve a ponerlo |
> | `state mv -state-out`: *Failed to load state: file does not exist* | El destino debe existir: haz `terraform init` (y, si hace falta, un `apply` vacío) en el otro directorio antes de mover |
> | `plan` tras `-target`: *Resource targeting is in effect … the plan may be incomplete* | Aviso esperado. Lanza un `apply` completo en cuanto salgas del atolladero; no dejes el estado a medias |
> | El `import` del contenedor falla con *parsing … expected …/blobServices/default/containers/…* | En azurerm 4.x con `storage_account_id` el id es el de ARM (`az storage container-rm show`), no la URL `https://….blob.core.windows.net/…` de 3.x |

---

## 8. Autoevaluación

1. **¿Por qué renombrar un recurso hace que `plan` proponga destruir y crear?**
   El estado enlaza direcciones con ids. La dirección antigua ya no está en el código (destruir) y la nueva no está en el estado (crear). `moved` le dice a Terraform que son el mismo objeto.
2. **¿Qué está mal en `terraform state mv 'azurerm_public_ip.mi_ip' 'module.red.mi_ip'`?**
   El destino no es una dirección válida: dentro de un módulo sigue haciendo falta tipo y nombre (`module.red.azurerm_public_ip.mi_ip`), y el módulo debe existir en el código con ese recurso.
3. **¿"El recurso importado no se gestionará automáticamente" es cierto?**
   No. Tras importar, Terraform lo gestiona por completo. Lo que hace falta es que el código coincida con la realidad, o el siguiente `apply` lo "corregirá". `-generate-config-out` ayuda a escribir ese código.
4. **¿Por qué `taint` está deprecado y qué lo sustituye?**
   Marca el estado compartido de forma silenciosa: otra persona puede lanzar el `apply` que destruye sin saberlo. `apply -replace=<dir>` hace lo mismo en la operación actual, visible en el plan.
5. **¿Cuándo prefieres `moved` a `state mv` y al revés?**
   `moved` siempre que sea posible: queda en Git, se aplica con el lock y funciona en módulos publicados. `state mv` es imprescindible para mover entre dos estados (`-state-out`).
6. **¿Cuántos bloques `moved` hacen falta para pasar dos recursos sueltos a un `for_each`? ¿Y para renombrar un módulo con veinte recursos?**
   Dos (uno por instancia destino). Uno: `moved { from = module.a to = module.b }` arrastra todo su contenido.
7. **¿Qué diferencia hay entre `removed` con `destroy = false` y borrar el bloque `resource`?**
   Borrar el bloque destruye el recurso en Azure. `removed` con `destroy = false` solo lo saca del estado: el recurso sigue existiendo, gestionado desde otro sitio.
8. **¿Por qué los ids de ARM fallan al importar si los escribes a mano?**
   Distinguen mayúsculas en los segmentos (`resourceGroups`, `virtualNetworks`). Se obtienen con `az … show --query id -o tsv`.
9. **¿Qué recursos no se pueden importar?**
   Los que no existen fuera del estado: `random_*`, `tls_private_key`, `null_resource`. Se regeneran (rotando el secreto) o se sustituyen por un `data` que lea el valor de Key Vault.
10. **¿Qué comando es el juez de que una cirugía salió bien?**
    `terraform plan` con *No changes*. Cualquier *destroy* tras un `moved` o un `import` significa que algo está mal escrito; no apliques.

---

## 9. Referencias

- [Direcciones de recursos](https://developer.hashicorp.com/terraform/cli/state/resource-addressing) y [comandos `terraform state`](https://developer.hashicorp.com/terraform/cli/commands/state) (`list`, `show`, `mv`, `rm`, `pull`, `push`, `replace-provider`)
- [Bloque `import`](https://developer.hashicorp.com/terraform/language/import), [generar configuración con `-generate-config-out`](https://developer.hashicorp.com/terraform/language/import/generating-configuration) y [`terraform import` (CLI)](https://developer.hashicorp.com/terraform/cli/commands/import)
- [Bloque `moved`](https://developer.hashicorp.com/terraform/language/moved), [refactorizar módulos](https://developer.hashicorp.com/terraform/language/modules/develop/refactoring) y [bloque `removed`](https://developer.hashicorp.com/terraform/language/resources/syntax#removing-resources)
- [Opción `-replace`](https://developer.hashicorp.com/terraform/cli/commands/plan#replace-address), [`taint` (deprecado)](https://developer.hashicorp.com/terraform/cli/commands/taint) y [`replace_triggered_by`](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle#replace_triggered_by)
- [Resource targeting (`-target`)](https://developer.hashicorp.com/terraform/cli/commands/plan#resource-targeting) y [modo `-refresh-only`](https://developer.hashicorp.com/terraform/cli/commands/plan#planning-modes)
- [Sección *Import* de cada recurso azurerm](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_group#import) (formato exacto del id) y [reglas de nombres e ids de ARM](https://learn.microsoft.com/es-es/azure/azure-resource-manager/management/resource-name-rules)
- [Azure Export for Terraform (aztfexport)](https://learn.microsoft.com/es-es/azure/developer/terraform/azure-export-for-terraform/export-terraform-overview): importación masiva de un grupo de recursos existente
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)