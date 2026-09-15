# 🎛️ Meta-argumentos: `lifecycle`, `provider`, y lo que no lo es (`dynamic`, provisioners)

> Un meta-argumento es un argumento que acepta *cualquier* recurso, sea del provider que sea, porque no lo interpreta el provider sino Terraform. Hay cinco: `depends_on`, `count` y `for_each` ([página 6](index.md#pagina-6)), `provider` y `lifecycle`. Esta página cubre los dos que faltan, y dentro de `lifecycle` los seis ajustes que cambian cómo Terraform planifica: cuándo ignorar una diferencia, cuándo negarse a destruir, en qué orden reemplazar, qué obliga a reemplazar y qué condiciones deben cumplirse antes y después. Después trata dos cosas que el original llamaba meta-argumentos y no lo son: los bloques `dynamic`, que son una expresión para generar bloques anidados, y los *provisioners*, que son una puerta de escape del modelo declarativo con un coste que conviene ver antes de decidir usarlos. Cada ajuste tiene su experimento en el emulador: se provoca la situación y se lee el plan. Lo que Topaz no puede enseñar (bloqueos de Azure, dos suscripciones) va al bloque de Azure real.

**🎯 Objetivos de aprendizaje**
- Distinguir un meta-argumento de un argumento del provider y de una expresión del lenguaje.
- Usar `ignore_changes` para convivir con cambios externos legítimos, y saber qué se pierde al hacerlo.
- Explicar los límites de `prevent_destroy` y completarlo con bloqueos de Azure.
- Leer un plan `+/-` frente a `-/+` y resolver el conflicto de nombres de `create_before_destroy`.
- Forzar reemplazos con `replace_triggered_by` y validar con `precondition`/`postcondition`.
- Generar bloques anidados con `dynamic` y decidir cuándo no hacerlo.
- Observar por qué un provisioner rompe el modelo, y qué lo sustituye.

> **🔷 Requisitos previos.** [Páginas 5](index.md#pagina-5) y 6: sintaxis, estado, `for_each` y bloques `moved`. Topaz con `Microsoft.Storage` y `Microsoft.Network`.

---

## 1. Qué es y qué no es un meta-argumento

| **Nombre** | **Qué es** | **Quién lo interpreta** |
|---|---|---|
| `depends_on`, `count`, `for_each`, `provider`, `lifecycle` | **Meta-argumentos**: válidos en todo recurso | Terraform, antes de hablar con el provider |
| `name`, `location`, `security_rule {}` | Argumentos y bloques del recurso | El provider: los envía a la API |
| `dynamic "x" {}` | Expresión del lenguaje que genera bloques anidados repetibles | Terraform, al evaluar la configuración. Solo vale para bloques que el provider define como repetibles |
| `provisioner "x" {}`, `connection {}` | Bloques especiales que ejecutan acciones fuera del modelo declarativo | Terraform, en el apply, sin pasar por el plan |

---

## 2. `lifecycle`: seis formas de cambiar el plan

### `ignore_changes`: convivir con cambios externos
Hay atributos que otro sistema modifica legítimamente: Azure Policy añade etiquetas, un autoscaler cambia el número de instancias, un operador rota una fecha. Sin `ignore_changes`, cada plan intenta revertirlo: deriva perpetua. Con él, Terraform no compara ese atributo después de la creación. Se pierde, a cambio, la detección de deriva sobre ese atributo: por eso se ignora lo mínimo (`tags["Owner"]`, no `tags`), y `ignore_changes = all` se reserva para recursos que Terraform crea y no debe volver a tocar.

### `prevent_destroy`: negarse a destruir
Si un plan incluye destruir ese recurso, Terraform aborta el plan *entero*. Tiene tres límites que el original no menciona: (1) si quitas el bloque `resource` del código, quitas también el `lifecycle`, y Terraform destruye sin protestar; (2) no protege de nada que ocurra fuera de Terraform (`az storage account delete`, el portal); (3) bloquea también los reemplazos, así que un cambio inocente en un atributo que fuerza reemplazo hace fallar todo el plan. Es una barandilla para el flujo de Terraform; el bloqueo real de la plataforma es `azurerm_management_lock` (bloque de Azure real).

### `create_before_destroy`: el orden del reemplazo
Por defecto un reemplazo es `-/+`: destruir, luego crear. Con `create_before_destroy` es `+/-`: crear el nuevo, reconectar, destruir el viejo. En Azure tiene una trampa: los nombres son únicos en su ámbito, así que el nuevo no puede llamarse igual que el viejo mientras ambos existen. La solución es un sufijo que cambie exactamente cuando cambia lo que fuerza el reemplazo: `random_id` con `keepers`. Y es contagioso: todo lo que dependa del recurso hereda el comportamiento.

### `replace_triggered_by`: forzar reemplazo por otro cambio
A veces un recurso debe recrearse cuando cambia otro aunque ninguno de sus argumentos cambie: una VM cuando cambia su fichero de cloud-init, un contenedor cuando cambia la configuración que lee. Se declara la relación y Terraform planifica el reemplazo. Se combina bien con `terraform_data`, que guarda un valor (un hash de fichero) sin crear nada.

### `precondition` y `postcondition`: contratos
Una `precondition` se evalúa en el plan sobre variables y datos conocidos: "la región está en la lista permitida". Una `postcondition` se evalúa tras el apply sobre `self`: "el storage que ha quedado tiene TLS 1.2". Si fallan, el mensaje es tuyo, no el críptico de la API. Son la forma de dejar en el código lo que hoy está en un comentario.

```hcl
variable "location" { type = string, default = "eastus" }
variable "kind"     { type = string, default = "StorageV2" }        # cambiarlo fuerza reemplazo: sirve para el experimento

resource "azurerm_resource_group" "lab" {
  name     = "rg-meta"
  location = var.location
  tags     = { Team = "infra" }                                       # tags es un MAPA, no un bloque: nada de dynamic aquí
  lifecycle {
    ignore_changes = [tags["Owner"], tags["CostCenter"]]              # solo las claves que otro sistema gestiona
  }
}

resource "random_id" "sufijo" {
  byte_length = 3
  keepers     = { kind = var.kind }                                   # el sufijo cambia exactamente cuando cambia lo que fuerza el reemplazo
}

resource "azurerm_storage_account" "datos" {
  name                      = "stmeta${random_id.sufijo.hex}"        # nombre distinto para el nuevo: sin esto, +/- choca con el viejo
  resource_group_name       = azurerm_resource_group.lab.name
  location                  = azurerm_resource_group.lab.location
  account_tier              = "Standard"
  account_replication_type  = "LRS"
  account_kind              = var.kind
  min_tls_version           = "TLS1_2"
  shared_access_key_enabled = false
  lifecycle {
    create_before_destroy = true
    precondition {
      condition     = contains(["eastus", "westeurope"], var.location)
      error_message = "Región ${var.location} no permitida: solo eastus o westeurope (política del curso)."
    }
    postcondition {
      condition     = self.min_tls_version == "TLS1_2" && !self.shared_access_key_enabled
      error_message = "El storage ha quedado sin el endurecimiento mínimo."
    }
  }
}

resource "terraform_data" "config" {                                  # sustituye a null_resource (Terraform 1.4+): guarda un valor, no crea nada
  input = filemd5("${path.module}/config.json")
}

resource "azurerm_storage_container" "config" {
  name                  = "config"
  storage_account_id    = azurerm_storage_account.datos.id
  container_access_type = "private"
  lifecycle {
    replace_triggered_by = [terraform_data.config]                    # cambia el fichero → se recrea el contenedor, aunque nada suyo cambie
  }
}

resource "azurerm_storage_account" "estado" {
  name                      = "stmetaestado01"
  resource_group_name       = azurerm_resource_group.lab.name
  location                  = azurerm_resource_group.lab.location
  account_tier              = "Standard"
  account_replication_type  = "LRS"
  min_tls_version           = "TLS1_2"
  shared_access_key_enabled = false
  lifecycle { prevent_destroy = true }                                # barandilla del flujo Terraform; el bloqueo real va en Azure (bloque A)
}
```

---

## 3. `provider`: alias para más de un destino

Un recurso usa por defecto el provider sin alias de su tipo. Con `provider = azurerm.hub` usa otro bloque `provider` con la misma fuente y distinta configuración: otra suscripción, otro tenant, otra nube. Es como una configuración crea recursos en la suscripción de conectividad y en la de la aplicación a la vez, cada uno con su identidad. En Topaz hay una sola suscripción; el ejemplo va en el bloque de Azure real, pero la sintaxis se puede validar aquí.

```hcl
provider "azurerm" {                       # el de siempre: la suscripción de la aplicación
  features {}
  subscription_id = var.subscription_id
}
provider "azurerm" {
  alias           = "hub"                  # la suscripción de red compartida
  features {}
  subscription_id = var.hub_subscription_id
}
resource "azurerm_virtual_network_peering" "a_hub" {
  provider                  = azurerm.hub  # este recurso se crea en la OTRA suscripción
  name                      = "moodle-a-hub"
  resource_group_name       = "rg-hub"
  virtual_network_name      = "vnet-hub"
  remote_virtual_network_id = azurerm_virtual_network.moodle.id
}
# En módulos: el módulo declara configuration_aliases y quien lo llama pasa providers = { azurerm.hub = azurerm.hub } (página 8)
```

---

## 4. `dynamic`: generar bloques anidados

Algunos recursos tienen bloques que pueden repetirse: `security_rule` en un NSG, `ip_configuration` en una NIC, `network_rules`… `dynamic` genera uno por elemento de una colección. Solo vale para bloques repetibles: aplicarlo a un argumento (como `tags`, que es un mapa) es un error de sintaxis, y es exactamente lo que hacía el ejercicio del original.

```hcl
variable "reglas" {
  type = list(object({ nombre = string, puerto = number, origen = optional(string, "*") }))
  default = [
    { nombre = "https", puerto = 443 },
    { nombre = "ssh",   puerto = 22, origen = "10.20.3.0/24" },       # solo desde la subred bastion
  ]
}
resource "azurerm_network_security_group" "web" {
  name                = "nsg-web-dyn"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  dynamic "security_rule" {                                           # el nombre del bloque que se genera
    for_each = { for i, r in var.reglas : r.nombre => merge(r, { prioridad = 100 + i }) }
    iterator = regla                                                  # opcional; sin él, el iterador se llama como el bloque
    content {
      name                       = "permitir-${regla.key}"
      priority                   = regla.value.prioridad
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = tostring(regla.value.puerto)
      source_address_prefix      = regla.value.origen
      destination_address_prefix = "*"
    }
  }
}
# Alternativa (página 6): azurerm_network_security_rule con for_each, una regla = un recurso con su propia dirección en el estado.
# dynamic: todo en un recurso, un solo PUT. for_each separado: planes más legibles, borrado individual, import más fácil.
# Regla del curso: si existe el recurso separado y las reglas cambian a menudo, for_each; dynamic para bloques sin recurso propio.
```

---

## 5. Provisioners: la puerta de escape y su precio

Un provisioner ejecuta un comando (en local o por SSH) cuando el recurso se crea, o cuando se destruye. Lo que ocurre dentro **no aparece en el plan**, no se compara con nada en el siguiente `plan` y, si falla, deja el recurso *tainted*: creado en Azure pero marcado para reemplazo. Es imperativo dentro de lo declarativo, y por eso la documentación lo titula "un último recurso". El original lo presentaba como "automatización de tareas" y proponía `null_resource` como alternativa: `null_resource` es solo un sitio donde colgar un provisioner, y hoy lo sustituye `terraform_data`.

| **Lo que el original quería** | **Con provisioner** | **Sin provisioner** |
|---|---|---|
| Instalar nginx en la VM | `remote-exec`: SSH, clave en disco, IP alcanzable, VM arrancada | `custom_data` con cloud-init: la plataforma lo ejecuta al arrancar, sin conexión desde fuera ([página 9](index.md#pagina-9)) |
| Copiar un fichero a la VM | `file` | `write_files` en cloud-init, o el fichero en un blob que la VM lee con su identidad administrada |
| Registrar la creación en un log | `local-exec` con `echo >> log` | El estado y el historial de Git ya lo registran; el pipeline guarda el plan ([página 14](index.md#pagina-14)). Un log local no es fuente de verdad |
| Ejecutar algo que no tiene recurso | `terraform_data` + `local-exec` | Buscar el recurso (`azapi_resource_action` cubre casi toda la API de Azure). Si de verdad no existe, provisioner con `triggers_replace` y asumir el coste |

---

## 6. Laboratorio en Topaz

Ocho bloques, uno por ajuste. Cada uno provoca la situación y lee el plan. Guarda el código de 7.2 en `main.tf` y el NSG de 7.4 en `nsg.tf`.

```bash
source ~/.topaz/topaz.env && az account show --query environmentName -o tsv   # Topaz
mkdir -p ~/tf-meta && cd ~/tf-meta && cp ~/tf-st/providers.tf . && git init -q
echo '{"version": 1}' > config.json
terraform init >/dev/null && terraform apply -auto-approve && git add . && git commit -qm base

# ─── 1. ignore_changes: "Azure Policy" etiqueta el grupo ─────────────────────────
az group update -n rg-meta --set tags.Owner=finanzas tags.CostCenter=CC-42 -o none   # el cambio externo legítimo
terraform plan | grep -E "Plan:|No changes"                          # No changes: Owner y CostCenter se ignoran
az group update -n rg-meta --set tags.Team=otro -o none              # cambio externo NO legítimo
terraform plan | grep -E '~ tags|"Team"'                             # ~ tags: Team "otro" → "infra": este sí se detecta y se corrige
terraform apply -auto-approve
az group show -n rg-meta --query tags -o json                        # Team infra, Owner finanzas, CostCenter CC-42: conviven

# ─── 2. prevent_destroy y sus tres límites ───────────────────────────────────────
terraform destroy -auto-approve 2>&1 | grep -A2 "Instance cannot be destroyed"
#   Error: Instance cannot be destroyed … azurerm_storage_account.estado has lifecycle.prevent_destroy set
#   (límite 3: el destroy ENTERO se aborta, incluidos los recursos que sí querías borrar)
az storage account delete -n stmetaestado01 -g rg-meta --yes         # límite 2: fuera de Terraform nadie lo impide (Topaz no tiene bloqueos)
terraform plan | grep -E "estado.*will be created"                   # el plan lo recrea: detectó la pérdida, no la evitó
terraform apply -auto-approve
#   límite 1: si borras el bloque resource "estado" del código, el lifecycle se va con él y el plan dice "will be destroyed" sin error.
#   Pruébalo con git stash después: no lo apliques ahora.

# ─── 3. create_before_destroy: +/- frente a -/+ ──────────────────────────────────
terraform plan -var kind=BlobStorage | grep -E "sufijo|datos|Plan:|must be replaced"
#   random_id.sufijo must be replaced (keepers cambian) → azurerm_storage_account.datos must be replaced
#   +/- (create replacement and then destroy): el orden invertido, visible en el símbolo
terraform apply -auto-approve -var kind=BlobStorage 2>&1 | grep -E "Creating|Destroying|complete" | grep datos
#   Creating… → Creation complete → Destroying (deposed) → Destruction complete: el nuevo existe antes de que el viejo desaparezca
terraform apply -auto-approve                                        # vuelta a StorageV2: otro reemplazo, mismo orden
#   Quita el random_id y pon name = "stmetadatos01": el mismo cambio da "StorageAccountAlreadyTaken" (o el error equivalente de tu versión de Topaz):
#   el nuevo no puede nacer con el nombre del viejo mientras el viejo vive. Es el conflicto que el original no menciona.

# ─── 4. replace_triggered_by ─────────────────────────────────────────────────────
terraform plan | grep -E "Plan:|No changes"                          # No changes
echo '{"version": 2}' > config.json                                  # nada del contenedor cambia; solo el fichero
terraform plan | grep -E "config|Plan:"
#   terraform_data.config must be replaced (input cambió)
#   azurerm_storage_container.config must be replaced: "Replacement triggered by terraform_data.config"
terraform apply -auto-approve

# ─── 5. precondition y postcondition ─────────────────────────────────────────────
terraform plan -var location=northeurope 2>&1 | grep -A1 "Resource precondition failed"
#   Error: Resource precondition failed … Región northeurope no permitida: solo eastus o westeurope (política del curso).
#   Falla en el PLAN, con tu mensaje, antes de tocar nada. Sin la precondition, el error llegaría (o no) desde la API.
sed -i 's/min_tls_version           = "TLS1_2"\n  shared_access_key_enabled = false\n  lifecycle {\n    create/&/' main.tf   # (sin cambios: solo para mostrar dónde iría el fallo)
#   Para ver fallar la postcondition: cambia shared_access_key_enabled a true en "datos" y aplica: el recurso se crea y
#   DESPUÉS Terraform informa del contrato roto. La postcondition no impide el cambio; lo hace visible y falla el apply.

# ─── 6. dynamic: añadir una regla ────────────────────────────────────────────────
terraform state list | grep nsg                                      # un solo recurso: las reglas viven dentro
sed -i 's/{ nombre = "ssh",/{ nombre = "http",  puerto = 80 },\n    { nombre = "ssh",/' nsg.tf
terraform plan | grep -E "~ update in-place|security_rule|Plan:"     # ~ azurerm_network_security_group.web: update in-place, Plan: 0 add 1 change
#   Con azurerm_network_security_rule + for_each (página 6) sería "+ 1 to add": un recurso nuevo, no un cambio en uno existente.
terraform apply -auto-approve
az network nsg rule list -g rg-meta --nsg-name nsg-web-dyn --query "[].{regla:name, prio:priority, origen:sourceAddressPrefix}" -o table

# ─── 7. Un provisioner, para ver lo que NO se ve ────────────────────────────────
cat > prov.tf <<'EOF'
resource "terraform_data" "registro" {
  triggers_replace = [azurerm_resource_group.lab.id]
  provisioner "local-exec" { command = "echo \"grupo ${azurerm_resource_group.lab.name} listo $(date -Is)\" >> registro.log" }
  provisioner "local-exec" { when = destroy, command = "echo \"destruido $(date -Is)\" >> registro.log" }
}
EOF
terraform plan | grep -E "registro|Plan:"                            # + terraform_data.registro. Del comando, ni rastro: el plan no sabe qué hará
terraform apply -auto-approve && cat registro.log
rm registro.log && terraform apply -auto-approve && ls registro.log 2>&1
#   No such file: el provisioner corre solo al crear. Nadie detecta que el "resultado" desapareció. Eso es no tener estado.
sed -i 's/echo \\"grupo/exit 1; echo \\"grupo/' prov.tf && terraform apply -replace=terraform_data.registro -auto-approve 2>&1 | tail -3
terraform state show terraform_data.registro | grep -i tainted       # (tainted): creado, pero marcado para reemplazo en el siguiente apply
rm prov.tf && terraform apply -auto-approve                          # el when = destroy ya no existe en el código: tampoco se ejecuta

# ─── 8. Limpiar (prevent_destroy obliga a quitar primero el bloque) ─────────────
sed -i '/lifecycle { prevent_destroy = true }/d' main.tf             # límite 1, usado a propósito: sin el lifecycle, el destroy pasa
terraform destroy -auto-approve
cd ~ && rm -rf ~/tf-meta
```

```bash
# ─── Solo Azure real ────────────────────────────────────────────────────────────
# A. El bloqueo que sí protege de az y del portal: azurerm_management_lock (Topaz no evalúa bloqueos)
cat > lock.tf <<'EOF'
resource "azurerm_management_lock" "estado" {
  name       = "no-borrar-estado"
  scope      = azurerm_storage_account.estado.id
  lock_level = "CanNotDelete"                                        # ReadOnly bloquearía también escrituras (y a Terraform)
  notes      = "Storage del estado remoto. Quitar el bloqueo requiere Owner o User Access Administrator."
}
EOF
terraform apply -auto-approve
az storage account delete -n stmetaestado01 -g rg-meta --yes         # ScopeLocked: ahora sí lo impide la plataforma
#   prevent_destroy protege el flujo de Terraform; el lock protege de todo lo demás. Se usan juntos (página 15).
#   Ojo: el lock también bloquea a Terraform si intenta reemplazar el recurso: hay que quitarlo antes, a conciencia.

# B. Dos suscripciones con provider alias
export TF_VAR_hub_subscription_id=$(az account list --query "[?name=='conectividad'].id" -o tsv)
terraform plan                                                       # el peering aparece con "provider = azurerm.hub": mismo grafo, dos destinos
#   La identidad que aplica necesita permisos en AMBAS suscripciones: Network Contributor en el hub basta para el peering.

# C. create_before_destroy con IP pública: la razón real del meta-argumento
#   Una VM detrás de una IP pública: cambiar la imagen fuerza reemplazo. Con -/+ el servicio cae mientras se recrea.
#   Con +/- y un nombre con sufijo, la nueva VM existe y la IP se reasocia antes de destruir la vieja: segundos de corte, no minutos.
#   Se monta completo en la página 9 con la VM de Moodle.
```

---

## 7. Errores comunes

> ⚠️ **Solución de problemas**
>
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | `Unsupported block type: Blocks of type "tags" are not expected here` (el ejercicio del original) | `tags` es un argumento de tipo mapa. `tags = merge(local.comunes, var.tags)`. `dynamic` solo para bloques repetibles |
> | `ignore_changes = [tags]` para arreglar una etiqueta | Ignora todas y pierdes la deriva de las tuyas. `tags["Owner"]`: solo la clave que otro sistema gestiona (bloque 1) |
> | `ignore_changes = all` en un recurso que sí gestionas | Terraform deja de comparar todo después de crearlo: cualquier cambio externo pasa inadvertido. Reservado a recursos "crear y no tocar" (una imagen inicial, un secreto que otro rota) |
> | `ignore_changes` con un valor que no es una referencia a atributo (`ignore_changes = [var.x]`) | Solo acepta atributos del propio recurso, sin `self.`: `[tags["Owner"], account_kind]` |
> | `Instance cannot be destroyed` al hacer un cambio que parecía inocente | `prevent_destroy` bloquea también los reemplazos, y el atributo que cambiaste fuerza reemplazo (mira "forces replacement" en el plan). Decide a conciencia: revertir el cambio o quitar la protección temporalmente en un commit propio |
> | Un recurso con `prevent_destroy` desaparece sin que Terraform se queje | Alguien quitó el bloque `resource` completo (límite 1) o lo borró desde `az`/portal (límite 2). Lo primero se para en revisión de código; lo segundo, con `azurerm_management_lock` (bloque A) |
> | `StorageAccountAlreadyTaken` (o equivalente) con `create_before_destroy` | El nuevo intenta nacer con el nombre del viejo mientras el viejo vive. Sufijo con `random_id` y `keepers` ligados al atributo que fuerza el reemplazo (bloque 3) |
> | Recursos que no tienen `create_before_destroy` aparecen con `+/-` | Es contagioso: lo heredan las dependencias del recurso que lo tiene. No es un error, pero hay que saberlo para leer el plan |
> | `ScopeLocked` al aplicar en Azure real | Un `azurerm_management_lock` protege el recurso que Terraform intenta borrar o reemplazar. Es la protección funcionando; si el cambio es legítimo, quitar el lock primero (Owner o UAA), en un paso separado y registrado |
> | `replace_triggered_by` apunta a una variable o un local | Solo acepta referencias a recursos o atributos de recursos. Envuelve el valor en `terraform_data { input = … }` y referencia eso (bloque 4) |
> | `precondition` que referencia `self` | En el plan `self` aún no existe. `precondition` es para variables, locals y data; `postcondition` para `self` |
> | "La `postcondition` falló pero el recurso está creado" | Es su comportamiento: valida *después*. No impide; hace visible y falla el apply. Lo que debe impedirse va en `precondition` o en `validation` de la variable |
> | `dynamic` sobre un bloque que solo admite una instancia (`identity`, `features`) | Funciona solo si `for_each` produce 0 o 1 elementos: es el truco para bloques opcionales (`for_each = var.identidad ? [1] : []`). Con más de uno, el provider lo rechaza |
> | Un NSG con `dynamic "security_rule"` y, además, `azurerm_network_security_rule` apuntando al mismo NSG | Dos gestores de las mismas reglas: cada apply borra las del otro. Elige uno por NSG (7.4). Si has heredado la mezcla, migra las inline a recursos con `import` |
> | `provider = "azurerm.hub"` entre comillas | Es una referencia, no un string: `provider = azurerm.hub`. Y el alias debe existir en un bloque `provider` del mismo módulo raíz (o venir por `configuration_aliases`) |
> | Módulo que usa `azurerm.hub` falla con `Provider configuration not present` | El módulo debe declararlo en `required_providers { azurerm = { configuration_aliases = [azurerm.hub] } }` y quien lo llama pasar `providers = { azurerm.hub = azurerm.hub }` ([página 8](index.md#pagina-8)) |
> | Recurso *tainted* tras un apply | Un provisioner falló: el recurso existe pero se reemplazará en el siguiente apply. Arregla el comando (o quítalo) y aplica; `terraform untaint` solo si el recurso está bien y el fallo era del script |
> | Provisioner `when = destroy` que no se ejecuta | Solo corre si el bloque sigue en el código al destruir. Si quitaste el recurso entero, ya no existe (bloque 7). Y no puede referenciar nada fuera de `self`, `count.index` y `each.key` |
> | `null_resource` con `triggers` (el original) | Funciona, pero necesita el provider `null`. `terraform_data` con `triggers_replace` viene con Terraform 1.4+ y hace lo mismo |
> | `${self.tags.Name}`, `self.public_ip` (el original, AWS) | Atributos de `aws_instance`. En azurerm la IP pública es otro recurso y no se conoce hasta después: motivo adicional para no configurar la VM desde fuera |
> | `remote-exec` contra Topaz | No hay VM real a la que conectarse: el provisioner falla y deja el recurso tainted. En Topaz la configuración interna de la VM no se puede probar; en Azure real, cloud-init ([página 9](index.md#pagina-9)) |

---

## 8. Autoevaluación

1. **¿Qué distingue a un meta-argumento de un argumento normal?**
   Lo interpreta Terraform, no el provider, y por eso vale en cualquier recurso. Son cinco: `depends_on`, `count`, `for_each`, `provider`, `lifecycle`.
2. **¿Por qué `dynamic "tags"` no compila en un grupo de recursos?**
   `tags` es un argumento de tipo mapa, no un bloque repetible. Se rellena con `merge()`.
3. **¿Qué se pierde con `ignore_changes`?**
   La detección de deriva sobre ese atributo. Por eso se ignora lo mínimo: claves concretas, no el mapa entero.
4. **¿Cuáles son los tres límites de `prevent_destroy`?**
   Desaparece si quitas el bloque `resource`; no protege de cambios fuera de Terraform; bloquea también reemplazos y aborta el plan entero.
5. **¿Qué protege de un `az storage account delete`?**
   `azurerm_management_lock` con `CanNotDelete`. Es un control de la plataforma, no del flujo de Terraform.
6. **¿Qué significan `-/+` y `+/-` en un plan?**
   Reemplazo destruyendo primero (por defecto) y reemplazo creando primero (`create_before_destroy`).
7. **¿Por qué `create_before_destroy` necesita `random_id` en Azure?**
   Los nombres son únicos en su ámbito: el nuevo no puede llamarse como el viejo mientras coexisten. `keepers` hace que el sufijo cambie solo cuando toca.
8. **¿Para qué sirve `replace_triggered_by`?**
   Recrear un recurso cuando cambia otro aunque ninguno de sus argumentos cambie. Con `terraform_data` se liga a cualquier valor, como el hash de un fichero.
9. **¿Cuándo se evalúa una `precondition` y cuándo una `postcondition`?**
   La primera en el plan, sobre datos conocidos; la segunda tras el apply, sobre `self`. La primera impide; la segunda hace visible.
10. **¿`dynamic` o `for_each` con recurso separado para las reglas de un NSG?**
    Si existe el recurso separado y las reglas cambian a menudo, `for_each`: planes legibles, borrado individual. `dynamic` para bloques sin recurso propio. Nunca ambos en el mismo NSG.
11. **¿Qué hace `provider = azurerm.hub`?**
    Envía ese recurso a otra configuración del mismo provider: otra suscripción, tenant o nube. Sin comillas, y el alias debe existir.
12. **¿Por qué un provisioner "rompe el modelo"?**
    Lo que hace no aparece en el plan, no se compara en el siguiente y, si falla, deja el recurso tainted. No tiene estado: nadie detecta que su resultado desapareció.
13. **¿Qué sustituye a `remote-exec` para configurar una VM?**
    `custom_data` con cloud-init: la plataforma lo ejecuta al arrancar, sin SSH desde fuera ni clave en disco. Para lo posterior, Ansible.
14. **¿Qué sustituye a `null_resource`?**
    `terraform_data` (Terraform 1.4+), sin provider adicional, con `input` y `triggers_replace`.

---

## 9. Referencias

- [Meta-argumento `lifecycle`](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle): `create_before_destroy`, `prevent_destroy`, `ignore_changes`, `replace_triggered_by`, condiciones (HashiCorp)
- [Condiciones personalizadas](https://developer.hashicorp.com/terraform/language/expressions/custom-conditions): `precondition`, `postcondition` y `validation`
- [Meta-argumento `provider`](https://developer.hashicorp.com/terraform/language/meta-arguments/provider) y [configuraciones con alias](https://developer.hashicorp.com/terraform/language/providers/configuration#alias-multiple-provider-configurations)
- [Bloques `dynamic`](https://developer.hashicorp.com/terraform/language/expressions/dynamic-blocks), con el aviso de la propia documentación sobre su abuso
- [Provisioners: un último recurso](https://developer.hashicorp.com/terraform/language/resources/provisioners/syntax) y [el recurso `terraform_data`](https://developer.hashicorp.com/terraform/language/resources/terraform-data)
- [Recursos tainted: `taint`, `untaint` y `-replace`](https://developer.hashicorp.com/terraform/cli/commands/taint)
- [`random_id` y `keepers`](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/id) (provider hashicorp/random)
- [`azurerm_management_lock`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/management_lock) y [bloqueos de recursos en Azure](https://learn.microsoft.com/es-es/azure/azure-resource-manager/management/lock-resources) (Microsoft Learn)
- [`azurerm_network_security_group`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_group): el bloque `security_rule` y la advertencia sobre mezclarlo con reglas separadas
- [cloud-init en VMs de Azure](https://learn.microsoft.com/es-es/azure/virtual-machines/linux/using-cloud-init): la alternativa a `remote-exec`
- [`azapi_resource_action`](https://registry.terraform.io/providers/Azure/azapi/latest/docs/resources/resource_action): acciones de la API sin provisioner
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)