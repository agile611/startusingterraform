# 🔗 Dependencias: el grafo, `depends_on`, `count` y `for_each`

> En la práctica 1 se vio que el orden de creación no está escrito en ningún sitio: Terraform lo deduce de las referencias. Esta página cuenta el resto de esa historia. Primero, qué pasa cuando dos recursos deben ir en orden pero *no hay dato que referenciar*: para eso existe `depends_on`, y para eso solamente. Después, cómo se pasa de escribir un recurso a escribir *N*: `count` los numera y `for_each` les da nombre, y esa diferencia, que parece cosmética, decide si quitar un elemento del medio destruye uno o destruye dos. El laboratorio lo demuestra con cuentas de almacenamiento en el emulador, migra de un mecanismo al otro sin destruir nada con bloques `moved`, y muestra el error que aparece cuando las claves de `for_each` dependen de algo que Terraform aún no conoce. Al terminar, la red del Moodle (tres subredes, tres NSG y sus reglas) sale de un solo mapa.

**🎯 Objetivos de aprendizaje**
- Leer el grafo de dependencias y distinguir una dependencia de datos de una dependencia de orden.
- Usar `depends_on` solo cuando no hay referencia posible, y conocer su coste.
- Explicar por qué `count` renumera al quitar un elemento y `for_each` no.
- Construir mapas con expresiones `for` para alimentar `for_each`, incluido el caso de conjuntos de números.
- Migrar de `count` a `for_each` con `moved` sin destruir recursos.
- Reconocer el error de claves desconocidas hasta el apply y saber evitarlo.

> **🔷 Requisitos previos.** Página 5 (sintaxis de HCL: variables, locals, tipos, expresiones `for`) y la práctica 1. Topaz con `Microsoft.Network` y `Microsoft.Storage`, que son la base del laboratorio.

---

## 1. El grafo: dependencias implícitas

Cada vez que un argumento contiene una referencia a otro recurso (`azurerm_subnet.web.id`), Terraform añade una arista al grafo. Antes de aplicar, ordena el grafo: lo que no depende de nada va primero, en paralelo (hasta 10 a la vez por defecto); lo demás espera a lo que referencia. Al destruir, recorre el grafo al revés. Esto cubre el 95 % de los casos, y tiene una ventaja que `depends_on` no tiene: Terraform sabe *qué dato* viaja por la arista, así que puede planificar con precisión qué cambia si ese dato cambia.

Hay dos formas de verlo: `terraform graph` dibuja las aristas, y el propio `apply` muestra el orden con sus "Creating…" / "Creation complete". El laboratorio usa las dos.

---

## 2. `depends_on`: cuando hay orden pero no hay dato

A veces un recurso debe esperar a otro y ninguno de sus argumentos puede referenciarlo. Ejemplo real en Azure: una interfaz de red se coloca en una subred (referencia implícita), pero *nada* en la interfaz menciona la asociación entre esa subred y su grupo de seguridad. Sin `depends_on`, Terraform puede crear la interfaz mientras la subred aún no está protegida. Es una dependencia de orden sin dato: el caso exacto de `depends_on`.

```hcl
resource "azurerm_network_interface" "moodle" {
  name                = "nic-moodle"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  ip_configuration {
    name                          = "interna"
    subnet_id                     = azurerm_subnet.s["web"].id     # dependencia de DATOS: implícita, precisa
    private_ip_address_allocation = "Dynamic"
  }
  # Dependencia de ORDEN: nada aquí puede referenciar la asociación NSG-subred, pero la interfaz no debe
  # existir antes de que la subred esté protegida. depends_on es de grano grueso: espera a TODAS las instancias.
  depends_on = [azurerm_subnet_network_security_group_association.s]
}
```

| **Caso** | **¿`depends_on`?** | **Por qué** |
|---|---|---|
| Registro DNS con la IP de un recurso (el original) | **No** | `records = [azurerm_public_ip.web.ip_address]` ya es la dependencia. El `depends_on` del original solo servía para esperar a un provisioner que no debería existir |
| NIC tras la asociación NSG-subred | Sí | Orden sin dato (6.2) |
| Secreto en Key Vault tras la asignación de rol que permite escribirlo | Sí, y a menudo `time_sleep` | El secreto no referencia el rol; RBAC tarda hasta un minuto en propagarse. Bloque de Azure real |
| Módulo que necesita que otro módulo haya terminado | Mejor pasar un output | `depends_on` en módulos retrasa *todo* el módulo y convierte sus datos en "known after apply" |
| Data source que debe leer después de un cambio | A veces | Con `depends_on` la lectura se posterga al apply: el plan pierde precisión. Es el coste |

> ⚠️ **Sobre el provisioner del original.** `remote-exec` ejecuta comandos por SSH desde la máquina que aplica: necesita una IP alcanzable, una clave privada en disco y que la VM esté arrancada, y si falla deja el recurso *tainted*. Nada de eso es declarativo ni funciona en Topaz. Lo que va dentro de la máquina va en `custom_data` (cloud-init) o en Ansible (página 8).

---

## 3. `count`: N instancias numeradas

`count = 3` crea `recurso[0]`, `[1]` y `[2]`. La identidad de cada instancia en el estado es su **posición**. Eso tiene una consecuencia que el original no cuenta: si las instancias se alimentan de una lista y quitas el elemento del medio, todo lo que había detrás se desplaza una posición. Terraform ve que `[1]` ahora debe llamarse como antes se llamaba `[2]`, y como el nombre fuerza reemplazo, destruye y recrea `[1]` además de destruir `[2]`. Querías borrar uno; el plan borra dos y crea uno.

```hcl
variable "cuentas" {
  type    = list(string)
  default = ["logs", "media", "backup"]
}
resource "azurerm_storage_account" "count" {
  count                     = length(var.cuentas)
  name                      = "stcount${var.cuentas[count.index]}"   # el nombre viene de la POSICIÓN
  resource_group_name       = azurerm_resource_group.lab.name
  location                  = azurerm_resource_group.lab.location
  account_tier              = "Standard"
  account_replication_type  = "LRS"
  min_tls_version           = "TLS1_2"
  shared_access_key_enabled = false
}
output "ids_count" { value = azurerm_storage_account.count[*].id }   # splat: solo funciona con count
```

`count` sigue siendo la herramienta correcta en dos casos: **cero o uno** (`count = var.crear_bastion ? 1 : 0`: un recurso condicional) e instancias **de verdad intercambiables**, sin nombre propio, que se escalan por número. Para todo lo que tiene nombre, `for_each`.

---

## 4. `for_each`: N instancias con nombre

`for_each` acepta un `map` o un `set(string)`. La identidad de cada instancia es su **clave**: `recurso["logs"]`. Quitar `"media"` del mapa destruye `recurso["media"]` y nada más, porque las demás claves no se mueven. Dentro del bloque, `each.key` es la clave y `each.value` el valor (en un set, ambos son el mismo string).

```hcl
# Mismas cuentas, con nombre en vez de posición
resource "azurerm_storage_account" "each" {
  for_each                  = toset(var.cuentas)
  name                      = "steach${each.key}"
  resource_group_name       = azurerm_resource_group.lab.name
  location                  = azurerm_resource_group.lab.location
  account_tier              = "Standard"
  account_replication_type  = "LRS"
  min_tls_version           = "TLS1_2"
  shared_access_key_enabled = false
}
output "ids_each" { value = { for k, s in azurerm_storage_account.each : k => s.id } }   # no hay splat: values() o un for

# La red del Moodle desde un solo mapa de objetos: cada valor lleva su configuración
locals {
  subredes = {
    web     = { prefijo = "10.20.1.0/24", puertos = [80, 443] }
    db      = { prefijo = "10.20.2.0/24", puertos = [3306] }
    bastion = { prefijo = "10.20.3.0/24", puertos = [22] }
  }
  # for_each no acepta números ni listas anidadas: se aplana a un mapa con clave string única
  reglas = { for r in flatten([
    for nombre, s in local.subredes : [for p in s.puertos : { clave = "${nombre}-${p}", subred = nombre, puerto = p }]
  ]) : r.clave => r }
}
resource "azurerm_subnet" "s" {
  for_each             = local.subredes
  name                 = "snet-${each.key}"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.moodle.name
  address_prefixes     = [each.value.prefijo]
}
resource "azurerm_network_security_group" "s" {
  for_each            = local.subredes
  name                = "nsg-${each.key}"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
}
resource "azurerm_network_security_rule" "s" {
  for_each                    = local.reglas                        # "web-80", "web-443", "db-3306", "bastion-22"
  name                        = "permitir-${each.value.puerto}"
  priority                    = 100 + index(local.subredes[each.value.subred].puertos, each.value.puerto)   # 100, 101…; no 100 + puerto
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = tostring(each.value.puerto)
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.s[each.value.subred].name   # instancia concreta de otro for_each
}
resource "azurerm_subnet_network_security_group_association" "s" {
  for_each                  = local.subredes
  subnet_id                 = azurerm_subnet.s[each.key].id
  network_security_group_id = azurerm_network_security_group.s[each.key].id
}
```

Dos reglas que Terraform impone y conviene saber antes de que aparezcan como error: las claves deben ser **strings** (de ahí el `for` que aplana los puertos) y deben ser **conocidas en el plan**: no pueden derivar de un atributo que otro recurso devolverá al aplicar (un `id`, por ejemplo). Los valores sí pueden ser desconocidos; las claves no. Lo mismo vale para `count`.

---

## 5. Migrar de `count` a `for_each` sin destruir

Cambiar un recurso de `count` a `for_each` cambia las direcciones en el estado (`[0]` pasa a `["logs"]`), y Terraform, sin más información, destruiría las tres instancias y crearía tres nuevas. El bloque `moved` (Terraform 1.1+) le dice que son las mismas: el plan sale sin destrucciones y el estado se actualiza. Los bloques `moved` se quedan en el código (documentan la historia) o se retiran cuando todos los entornos han aplicado.

```hcl
moved { from = azurerm_storage_account.count[0]  to = azurerm_storage_account.count["logs"] }
moved { from = azurerm_storage_account.count[1]  to = azurerm_storage_account.count["media"] }
moved { from = azurerm_storage_account.count[2]  to = azurerm_storage_account.count["backup"] }
# y el recurso pasa a: for_each = toset(var.cuentas), name = "stcount${each.key}"
# Plan: 0 to add, 0 to change, 0 to destroy. Tres líneas "has moved to".
```

---

## 6. Laboratorio en Topaz

Seis bloques: el grafo y el orden; quitar el del medio con `count`; lo mismo con `for_each`; la red desde el mapa y qué cambia al añadir un puerto; la migración con `moved`; y el error de clave desconocida.

```bash
source ~/.topaz/topaz.env && az account show --query environmentName -o tsv   # Topaz
mkdir -p ~/tf-deps && cd ~/tf-deps && cp ~/tf-st/providers.tf . && git init -q
cat > base.tf <<'EOF'
resource "azurerm_resource_group" "lab" { name = "rg-deps", location = "eastus" }
resource "azurerm_virtual_network" "moodle" {
  name = "vnet-moodle", resource_group_name = azurerm_resource_group.lab.name
  location = azurerm_resource_group.lab.location, address_space = ["10.20.0.0/16"]
}
EOF
# guarda: red.tf (locals, subnets, NSG, reglas, asociaciones y la NIC de 6.2/6.4), count.tf (6.3), foreach.tf (la cuenta "each" de 6.4)
terraform init >/dev/null && terraform validate && git add . && git commit -qm "base"

# ─── 1. El grafo y el orden ──────────────────────────────────────────────────────
terraform graph -type=plan | grep -E 'nic-moodle|network_interface' | head          # las aristas de la NIC: subred (dato) y asociación (depends_on)
terraform apply -auto-approve 2>&1 | grep -E "Creating|Creation complete" | awk '{print $1, $2, $NF}' | head -30
#   Las tres cuentas "count" y las tres "each" salen a la vez (no dependen entre sí). La NIC sale al final: esperó a las tres asociaciones.
terraform state list | wc -l                                                         # 22
terraform output -json ids_each | jq 'keys'                                          # ["backup","logs","media"]: claves, no posiciones

# ─── 2. count: quitar el del medio ───────────────────────────────────────────────
sed -i 's/\["logs", "media", "backup"\]/["logs", "backup"]/' count.tf
terraform plan | grep -E "must be replaced|will be destroyed|Plan:"
#   azurerm_storage_account.count[1] must be replaced   (stcountmedia → stcountbackup: el nombre cambió de posición)
#   azurerm_storage_account.count[2] will be destroyed
#   Plan: 1 to add, 0 to change, 2 to destroy.          ← querías borrar una: se borran dos y se crea una
git checkout count.tf                                                                # no apliques: no hace falta romperlo para aprenderlo

# ─── 3. for_each: quitar el del medio ────────────────────────────────────────────
sed -i 's/\["logs", "media", "backup"\]/["logs", "backup"]/' foreach.tf              # la variable es la misma lista; toset() la convierte en claves
terraform plan | grep -E "will be destroyed|Plan:"
#   azurerm_storage_account.each["media"] will be destroyed
#   Plan: 0 to add, 0 to change, 1 to destroy.          ← exactamente lo que pediste
terraform apply -auto-approve && git checkout foreach.tf && terraform apply -auto-approve   # la volvemos a crear para el bloque 5

# ─── 4. La red desde el mapa: añadir un puerto ───────────────────────────────────
terraform state list | grep security_rule                                            # ["web-80"] ["web-443"] ["db-3306"] ["bastion-22"]
sed -i 's/puertos = \[80, 443\]/puertos = [80, 443, 8080]/' red.tf
terraform plan | grep -E "will be created|Plan:"                                     # + azurerm_network_security_rule.s["web-8080"]  Plan: 1 to add
#   Con count sobre una lista de puertos, añadir 8080 al final también daría 1 to add; insertarlo en medio habría reemplazado los siguientes.
terraform apply -auto-approve
az network nsg rule list -g rg-deps --nsg-name nsg-web --query "[].{regla:name, prioridad:priority, puerto:destinationPortRange}" -o table   # 100, 101, 102

# ─── 5. Migrar count → for_each con moved ────────────────────────────────────────
cat >> count.tf <<'EOF'
moved { from = azurerm_storage_account.count[0]  to = azurerm_storage_account.count["logs"] }
moved { from = azurerm_storage_account.count[1]  to = azurerm_storage_account.count["media"] }
moved { from = azurerm_storage_account.count[2]  to = azurerm_storage_account.count["backup"] }
EOF
sed -i 's/count *= length(var.cuentas)/for_each = toset(var.cuentas)/; s/\${var.cuentas\[count.index\]}/${each.key}/; s/\.count\[\*\]\.id/.count[*].id/' count.tf
sed -i 's/value = azurerm_storage_account.count\[\*\].id/value = values(azurerm_storage_account.count)[*].id/' count.tf   # el splat directo ya no vale
terraform plan | grep -E "has moved|Plan:"
#   azurerm_storage_account.count[0] has moved to azurerm_storage_account.count["logs"]  (x3)
#   Plan: 0 to add, 0 to change, 0 to destroy.
terraform apply -auto-approve && terraform state list | grep 'count\['                # ["backup"] ["logs"] ["media"]
#   Sin los moved, el mismo cambio habría sido: 3 to add, 3 to destroy. Con datos dentro, eso es una pérdida.
git add . && git commit -qm "count → for_each con moved"

# ─── 6. El error de clave desconocida ────────────────────────────────────────────
cat > malo.tf <<'EOF'
resource "azurerm_storage_container" "malo" {
  for_each              = toset(values(azurerm_storage_account.each)[*].id)   # las claves serían ids que aún no existen
  name                  = "datos"
  storage_account_id    = each.key
  container_access_type = "private"
}
EOF
terraform apply -auto-approve                                                        # las cuentas existen: el plan pasa (las claves ya son conocidas)
terraform destroy -target=azurerm_storage_account.each -auto-approve >/dev/null      # simulamos un despliegue desde cero para esas cuentas
terraform plan
#   Error: Invalid for_each argument
#   The "for_each" set includes values derived from resource attributes that cannot be determined until apply…
#   En el primer apply de un entorno nuevo, este código falla. Funcionaba solo porque las cuentas ya existían.
cat > malo.tf <<'EOF'
resource "azurerm_storage_container" "bien" {
  for_each              = azurerm_storage_account.each                        # claves = "logs", "media", "backup": conocidas en el plan
  name                  = "datos"
  storage_account_id    = each.value.id                                       # el VALOR puede ser desconocido; la CLAVE no
  container_access_type = "private"
}
EOF
terraform plan | grep -E "Plan:"                                                     # Plan: 6 to add (3 cuentas + 3 contenedores): sin error
terraform apply -auto-approve

# ─── 7. Limpiar ──────────────────────────────────────────────────────────────────
terraform destroy -auto-approve                                                      # orden inverso al grafo: NIC primero, grupo al final
cd ~ && rm -rf ~/tf-deps
```

```bash
# ─── Solo Azure real ────────────────────────────────────────────────────────────
# A. El depends_on que Topaz no puede enseñar: RBAC tarda en propagarse
#    Key Vault con RBAC: quien aplica necesita el rol "Key Vault Secrets Officer" ANTES de escribir un secreto.
#    El secreto no referencia la asignación (no hay dato), y la asignación tarda hasta un minuto en ser efectiva.
cat > kv.tf <<'EOF'
data "azurerm_client_config" "yo" {}
resource "azurerm_key_vault" "moodle" {
  name                       = "kv-deps-${substr(md5(azurerm_resource_group.lab.id), 0, 8)}"
  resource_group_name        = azurerm_resource_group.lab.name
  location                   = azurerm_resource_group.lab.location
  tenant_id                  = data.azurerm_client_config.yo.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  purge_protection_enabled   = false
}
resource "azurerm_role_assignment" "secretos" {
  scope                = azurerm_key_vault.moodle.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.yo.object_id
}
resource "time_sleep" "rbac" {                              # provider hashicorp/time: espera declarativa, sin provisioner
  depends_on      = [azurerm_role_assignment.secretos]
  create_duration = "60s"
}
resource "azurerm_key_vault_secret" "prueba" {
  name         = "prueba"
  value        = "no-es-un-secreto-real"
  key_vault_id = azurerm_key_vault.moodle.id
  depends_on   = [time_sleep.rbac]                          # orden sin dato: el caso legítimo
}
EOF
terraform init -upgrade >/dev/null && terraform apply -auto-approve
#   Sin time_sleep + depends_on: "Error: … ForbiddenByRbac" en el primer apply, y éxito al reintentar. Un error intermitente que parece azar y no lo es.
#   Necesitas User Access Administrator o RBAC Administrator en el grupo para crear la asignación (página 4).

# B. count para "cero o uno": un bastion condicional
cat > bastion.tf <<'EOF'
variable "crear_bastion" { type = bool, default = false }
resource "azurerm_public_ip" "bastion" {
  count               = var.crear_bastion ? 1 : 0
  name                = "pip-bastion"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  allocation_method   = "Static"
  sku                 = "Standard"
}
output "bastion_ip" { value = one(azurerm_public_ip.bastion[*].ip_address) }   # one(): null si count = 0, el valor si 1
EOF
terraform apply -auto-approve -var crear_bastion=true && terraform output bastion_ip
terraform apply -auto-approve -var crear_bastion=false                               # - azurerm_public_ip.bastion[0]: el condicional, borrado

# C. El backend pool del original, bien hecho: una asociación por NIC, con for_each sobre el mismo mapa
#    (el argumento ip_configurations del original no existe; la relación NIC ↔ pool es un recurso propio)
#    resource "azurerm_network_interface_backend_address_pool_association" "web" {
#      for_each                = azurerm_network_interface.web           # una por NIC, con la misma clave
#      network_interface_id    = each.value.id
#      ip_configuration_name   = "interna"
#      backend_address_pool_id = azurerm_lb_backend_address_pool.web.id
#    }
#    Se aplica en la página 9 con el balanceador completo.

terraform destroy -auto-approve
```

---

## 7. Errores comunes

> ⚠️ **Solución de problemas**
>
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | `depends_on` en un recurso que ya referencia al otro (el original: DNS e IP) | Redundante: la referencia ya es la dependencia. Quítalo; `depends_on` solo cuando no hay dato que referenciar |
> | `provisioner "remote-exec"` para instalar software (el original) | Imperativo, frágil, deja recursos *tainted*, no funciona en Topaz. `custom_data` con cloud-init o Ansible (página 8) |
> | `The given "for_each" argument value is unsuitable: … set of number` (el original: `toset([80, 443, 22])`) | `for_each` solo acepta `map` o `set(string)`. Construye el mapa con `for` y claves string (`"${nombre}-${puerto}"`), o `toset([for p in var.puertos : tostring(p)])` |
> | `priority = 100 + each.value` con el puerto como valor (el original) | Puerto 8080 → prioridad 8180, fuera del rango 100–4096. Usa `index()` sobre la lista de puertos, o un contador en el `for` |
> | `ip_configurations = [for nic in …]` en el backend pool (el original) | El argumento no existe. La relación NIC-pool es `azurerm_network_interface_backend_address_pool_association`, una por NIC con `for_each` (bloque C) |
> | Quitar un elemento de una lista con `count` destruye más de uno | Renumeración (bloque 2). Migra a `for_each` con `moved` (6.5). Si has de mantener `count`, quita solo del final |
> | `Invalid for_each argument … cannot be determined until apply` | Las claves derivan de un atributo desconocido (un `id`). Usa como claves algo que ya esté en el código: el propio mapa de entrada o el recurso completo (`for_each = azurerm_storage_account.each`), y el `id` en `each.value` (bloque 6) |
> | "Funcionaba ayer y hoy en el entorno nuevo falla con ese error" | Mismo caso: en el entorno viejo las claves ya eran conocidas. Prueba siempre desde cero (`terraform test`, página 9) para que aparezca antes |
> | `Error: Missing resource instance key` al referenciar `azurerm_subnet.s.id` | Con `for_each`/`count` el recurso es un mapa/lista: `azurerm_subnet.s["web"].id`, `[0].id`, o `values(…)[*].id` para todos |
> | Splat `[*]` sobre un recurso con `for_each` devuelve error | El splat es solo para listas. `values(recurso)[*].id` o `{ for k, v in recurso : k => v.id }` |
> | Cambiar de `count` a `for_each` planifica destruir y recrear todo | Faltan los bloques `moved` (6.5). Alternativa antigua: `terraform state mv`, imperativo y fuera del código |
> | `depends_on` en un bloque `module` y todo sale "known after apply" | Retrasa el módulo entero, incluidos sus data sources. Pasa un output del módulo anterior como variable: dependencia de datos, precisa |
> | `ForbiddenByRbac` intermitente al escribir en Key Vault | Propagación de RBAC. `time_sleep` con `depends_on` de la asignación, y el secreto con `depends_on` del sleep (bloque A). Solo en Azure real |
> | Mezclar `count` y `for_each` en el mismo recurso | Terraform lo rechaza al validar. Si hay replicación y variación, modela un mapa de objetos y usa `for_each`; si hay un condicional sobre un mapa, filtra el mapa (`for_each = var.crear ? local.mapa : {}`) |
> | `${azurerm_virtual_machine.web.id}` (el original) | Interpolación antigua (Terraform 0.11). Referencia directa: `azurerm_linux_virtual_machine.web.id`. `${}` solo dentro de strings |

---

## 8. Autoevaluación

1. **¿Qué es una dependencia implícita y por qué es preferible?**
   Una referencia a un atributo de otro recurso. Terraform sabe qué dato viaja y planifica con precisión qué cambia si ese dato cambia.
2. **¿Cuándo es legítimo `depends_on`?**
   Cuando hay orden pero no hay dato: la NIC tras la asociación NSG-subred, el secreto tras la asignación de rol.
3. **¿Qué coste tiene `depends_on`?**
   Es de grano grueso (espera a todas las instancias) y posterga lecturas al apply, con lo que el plan pierde precisión. En módulos, retrasa el módulo entero.
4. **¿Por qué `count` destruye dos al quitar el del medio?**
   La identidad es la posición. Al desplazarse la lista, la instancia `[1]` tiene que llamarse como `[2]`, y el cambio de nombre fuerza reemplazo.
5. **¿Por qué `for_each` no?**
   La identidad es la clave. Quitar `"media"` destruye `["media"]` y las demás claves no se mueven.
6. **¿Cuándo sigue siendo correcto `count`?**
   Cero o uno (recurso condicional) e instancias realmente intercambiables sin nombre propio.
7. **¿Qué tipos acepta `for_each`?**
   `map` o `set(string)`. Ni listas ni conjuntos de números: se convierten con `toset` y `tostring`, o se construye un mapa con `for`.
8. **¿Qué tiene que ser conocido en el plan: la clave o el valor?**
   La clave. El valor puede ser "known after apply". Por eso `for_each = recurso` funciona y `for_each = toset(recurso[*].id)` falla en un entorno nuevo.
9. **¿Cómo se migra de `count` a `for_each` sin destruir?**
   Bloques `moved` de `[i]` a `["clave"]`. El plan muestra "has moved to" y 0 to destroy.
10. **¿Cómo se obtienen todos los ids de un recurso con `for_each`?**
    `values(recurso)[*].id` o un `for`. El splat directo `recurso[*]` es solo para `count`.
11. **¿Por qué el original usaba `depends_on` en el registro DNS?**
    Para esperar a un `remote-exec`. La IP ya era dependencia implícita; el problema real era el provisioner, no la falta de `depends_on`.
12. **¿Qué reemplaza al `remote-exec` del original?**
    `custom_data` con cloud-init para el arranque; Ansible para configuración posterior. Ninguno rompe el modelo declarativo ni deja recursos *tainted*.

---

## 9. Referencias

- [Dependencias entre recursos](https://developer.hashicorp.com/terraform/language/resources/behavior#resource-dependencies) y [`depends_on`](https://developer.hashicorp.com/terraform/language/meta-arguments/depends_on) (HashiCorp)
- [`count`](https://developer.hashicorp.com/terraform/language/meta-arguments/count) y [`for_each`](https://developer.hashicorp.com/terraform/language/meta-arguments/for_each), incluidas las limitaciones sobre claves desconocidas
- [Bloques `moved`](https://developer.hashicorp.com/terraform/language/moved) para refactorizar sin destruir
- [Expresiones `for`](https://developer.hashicorp.com/terraform/language/expressions/for), [`flatten`](https://developer.hashicorp.com/terraform/language/functions/flatten), [`one`](https://developer.hashicorp.com/terraform/language/functions/one) y [expresiones splat](https://developer.hashicorp.com/terraform/language/expressions/splat)
- [Provisioners: un último recurso](https://developer.hashicorp.com/terraform/language/resources/provisioners/syntax) (HashiCorp, con ese título)
- [`terraform graph`](https://developer.hashicorp.com/terraform/cli/commands/graph)
- [`time_sleep`](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep) (provider hashicorp/time)
- [`azurerm_network_security_rule`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_rule), [`azurerm_subnet_network_security_group_association`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet_network_security_group_association) y [`azurerm_network_interface_backend_address_pool_association`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_interface_backend_address_pool_association)
- [Key Vault con RBAC](https://learn.microsoft.com/es-es/azure/key-vault/general/rbac-guide) y [propagación de asignaciones de rol](https://learn.microsoft.com/es-es/azure/role-based-access-control/troubleshooting#symptom---role-assignment-changes-are-not-being-detected) (Microsoft Learn)
- [Azure Local Emulator (Topaz)](https://github.com/Azure/azure-local-emulator)