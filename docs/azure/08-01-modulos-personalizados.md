# 📦 Módulos personalizados: diseñar, consumir, publicar

> Un módulo es una **función**: recibe variables, crea recursos y devuelve outputs. No es un "sub-proyecto" ni una carpeta donde guardar código: es la unidad con la que un equipo encapsula una decisión ("así se crea un NSG en esta empresa") para que nadie tenga que volver a tomarla. La página 6 usó un módulo de red; esta enseña a escribirlos bien: una interfaz pequeña y validada, una estructura estándar que las herramientas reconocen, consumo desde Git o un registry con versión fijada, y evolución sin romper a los consumidores. Todo funciona en **Topaz**: el laboratorio construye un módulo de grupos de seguridad de red y lo compone con el de red de la página 9.

**🎯 Objetivos de aprendizaje**
- Decidir qué entra y qué no en un módulo, y qué recibe frente a qué crea.
- Escribir variables con tipos `object`, `optional()` y `validation`, y outputs que expongan lo justo.
- Consumir módulos locales, de Git y del registry con versión fijada, con `for_each` y con providers explícitos.
- Documentar con terraform-docs, probar con `terraform test` y publicar con etiquetas semánticas.
- Cambiar un módulo sin destruir recursos de quien lo usa (`moved` dentro del módulo).

> **🔷 Requisitos previos.** Páginas 1 a 10 completadas y destruidas, `~/tf-st/providers.tf` y `~/tf-cmd/modules/red` (página 9) disponibles, Terraform `>= 1.7`, opcionalmente `terraform-docs`, `az account show --query environmentName -o tsv` → `Topaz`.

---

## 1. Qué hace un módulo y qué no

| **Pregunta de diseño** | **Respuesta habitual** | **Por qué** |
|---|---|---|
| ¿Crea el grupo de recursos o lo recibe? | Lo recibe (`resource_group_name`, `location`) | El grupo es la unidad de ciclo de vida y permisos del root. Un módulo que lo crea no puede convivir con otro en el mismo grupo (el original creaba grupo + VNet juntos) |
| ¿Cuántos recursos? | Los que forman **una** cosa con sentido: NSG + reglas + asociaciones; VNet + subredes; cuenta + contenedores | Un módulo "todo el entorno" no se reutiliza; un módulo de un solo recurso sin lógica no aporta nada sobre el `resource` |
| ¿Bloque `provider` o `backend` dentro? | Nunca (página 6). Solo `required_providers` con la versión mínima | Un módulo con provider propio no admite `for_each` ni se puede retirar limpiamente |
| ¿Nombres fijos o variables? | Variables con `validation` de convención; el módulo puede componer sufijos (`snet-${each.key}`) pero no inventar el prefijo | El nombre pertenece a quien llama; el módulo garantiza que cumple la norma |
| ¿Valores fijos (CIDR, SKU, región)? | Todo lo que pueda variar entre dos usos es variable, con `default` seguro si tiene sentido | El `address_space = ["10.0.0.0/16"]` del original impedía instanciarlo dos veces |
| ¿Módulos que llaman a módulos? | Un nivel: el root compone módulos "hoja". Evita hoja → hoja → hoja | Cada nivel añade variables de paso y oculta el plan. Componer es tarea del root |

---

## 2. Estructura estándar

```text
modules/nsg/
├── main.tf              # recursos
├── variables.tf         # entradas: description, type, default, validation
├── outputs.tf           # salidas: description, value, sensitive
├── versions.tf          # required_version + required_providers (SIN bloque provider)
├── README.md            # generado por terraform-docs; a mano solo el párrafo de propósito y el ejemplo
├── CHANGELOG.md         # qué cambió en cada versión y si rompe compatibilidad
├── examples/
│   └── basico/          # un root mínimo que llama al módulo: es la documentación viva y lo que prueba terraform test
│       └── main.tf
└── tests/
    └── nsg.tftest.hcl   # validaciones que deben fallar y un plan/apply que debe pasar
```

La estructura no es estética: el registry de Terraform, terraform-docs, TFLint y `terraform test` la asumen. Los nombres de archivo son convención, no obligación (Terraform lee todos los `.tf` del directorio), pero quien abre `variables.tf` espera encontrar la interfaz completa y nada más.

---

## 3. La interfaz: variables y outputs

```hcl
# modules/nsg/variables.tf
variable "nombre" {
  description = "Nombre del NSG. Convención CAF: nsg-<carga>-<entorno>."
  type        = string
  validation {
    condition     = can(regex("^nsg-[a-z0-9-]{2,60}$", var.nombre))
    error_message = "Debe empezar por 'nsg-' y usar solo minúsculas, dígitos y guiones."
  }
}
variable "resource_group_name" { description = "Grupo existente donde se crea el NSG."; type = string }
variable "location"            { description = "Región; normalmente la del grupo.";     type = string }

variable "reglas" {
  description = "Reglas de seguridad, indexadas por nombre. Solo 'prioridad' y 'puertos' son obligatorios."
  type = map(object({
    prioridad = number
    puertos   = list(string)
    direccion = optional(string, "Inbound")
    acceso    = optional(string, "Allow")
    protocolo = optional(string, "Tcp")
    origen    = optional(string, "*")
    destino   = optional(string, "*")
  }))
  default = {}
  validation {
    condition     = alltrue([for r in var.reglas : r.prioridad >= 100 && r.prioridad <= 4096])
    error_message = "La prioridad debe estar entre 100 y 4096."
  }
  validation {
    condition     = length(distinct([for r in var.reglas : "${r.direccion}-${r.prioridad}"])) == length(var.reglas)
    error_message = "Dos reglas de la misma dirección no pueden compartir prioridad."
  }
  validation {
    condition     = alltrue([for r in var.reglas : contains(["Inbound", "Outbound"], r.direccion) && contains(["Allow", "Deny"], r.acceso)])
    error_message = "direccion ∈ {Inbound, Outbound}; acceso ∈ {Allow, Deny}."
  }
}

variable "subnet_ids" {
  description = "Subredes a las que asociar el NSG, indexadas por un alias estable (no por el id)."
  type        = map(string)
  default     = {}
}
variable "tags" { description = "Tags heredadas del root."; type = map(string); default = {} }
```

```hcl
# modules/nsg/outputs.tf
output "id"     { description = "Id ARM del NSG."; value = azurerm_network_security_group.this.id }
output "nombre" { description = "Nombre del NSG."; value = azurerm_network_security_group.this.name }
output "reglas" {
  description = "Reglas creadas: nombre → prioridad. Útil para tests y para documentar."
  value       = { for k, r in azurerm_network_security_rule.this : k => r.priority }
}
# Lo que NO se expone: el objeto resource completo (output "nsg" { value = azurerm_network_security_group.this }).
# Acopla al consumidor a la estructura interna y filtra atributos sensibles si los hubiera.
```

| **Herramienta** | **Para qué** |
|---|---|
| `optional(tipo, default)` | Objetos con campos opcionales: el consumidor escribe 2 atributos, el módulo trabaja con 7. Sin ello, cada regla exigiría los 7 |
| `map(object)` frente a `list(object)` | Con `map`, `for_each` usa la clave como dirección estable: borrar la regla "ssh" no renumera las demás. Con `list`, quitar el elemento 0 recrea todos |
| `validation` (varias por variable) | Falla en `plan`, antes de tocar Azure, con un mensaje que explica la norma. Puede referenciar otras variables desde 1.9 |
| `nullable = false` | Impide que el consumidor pase `null` "para usar el default": con `nullable = false`, `null` se convierte en el default |
| `sensitive = true` en variables y outputs | Oculta en consola; no protege el estado (página 7). Los outputs derivados de un valor sensible deben marcarse o Terraform se niega |
| `ephemeral = true` (≥ 1.10) | Secretos que atraviesan el módulo sin quedar en estado ni plan |
| Alias estables como claves (`subnet_ids = { web = … }`) | Nunca indexar `for_each` por un valor que Terraform no conoce hasta el apply (un id): *"for_each keys must be known"* |

---

## 4. Consumir módulos

| **`source`** | **Cuándo** | **Versión** |
|---|---|---|
| `"./modules/nsg"` | Desarrollo, o módulos privados de un solo proyecto | La del repo: cambia con cada commit. Sin aislamiento |
| `"git::https://github.com/org/tf-modulos.git//nsg?ref=v1.2.0"` | Módulos compartidos entre proyectos; lo habitual | `ref=` a una etiqueta. Nunca a una rama: `init -upgrade` traería lo que haya |
| `"Azure/avm-res-network-networksecuritygroup/azurerm"` + `version = "~> 0.4"` | Azure Verified Modules: mantenidos por Microsoft, con las buenas prácticas de WAF incorporadas | Argumento `version`, solo para registries. Antes de escribir un módulo, mira si existe el AVM |
| `"app.terraform.io/org/nsg/azurerm"` / registry privado | Organizaciones con catálogo interno | Igual que el público: `version` con restricción |

```hcl
# Un NSG por subred, con reglas distintas: for_each sobre el módulo
module "nsg" {
  source   = "./modules/nsg"
  for_each = local.nsgs                       # { web = {…}, datos = {…} }

  nombre              = "nsg-${each.key}-lab"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  reglas              = each.value
  subnet_ids          = { (each.key) = module.red.subnet_ids[each.key] }
  tags                = local.tags
}
output "nsg_ids" { value = { for k, m in module.nsg : k => m.id } }

# Providers explícitos: solo cuando el módulo debe usar otra suscripción o alias
module "nsg_hub" {
  source    = "./modules/nsg"
  providers = { azurerm = azurerm.hub }       # el módulo declara configuration_aliases si lo exige
  # …
}

# depends_on en módulos: existe, pero convierte TODO el módulo en dependiente y hace el plan conservador.
# Casi siempre basta con pasar un output del otro módulo como variable: la dependencia es implícita y precisa.
```

---

## 5. Laboratorio en Topaz

```bash
mkdir -p ~/tf-mod/modules/nsg/{examples/basico,tests} && cd ~/tf-mod && cp ~/tf-st/providers.tf .
cp -r ~/tf-cmd/modules/red modules/                 # el módulo de red de la página 9

# ─── 1. El módulo ───────────────────────────────────────────────────────────────
cat > modules/nsg/versions.tf <<'EOF'
terraform {
  required_version = ">= 1.7.0"
  required_providers { azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" } }
}
EOF
# variables.tf y outputs.tf: los bloques de 11.3 tal cual
cat > modules/nsg/main.tf <<'EOF'
resource "azurerm_network_security_group" "this" {
  name                = var.nombre
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}
resource "azurerm_network_security_rule" "this" {
  for_each                    = var.reglas
  name                        = each.key
  priority                    = each.value.prioridad
  direction                   = each.value.direccion
  access                      = each.value.acceso
  protocol                    = each.value.protocolo
  source_port_range           = "*"
  destination_port_ranges     = each.value.puertos
  source_address_prefix       = each.value.origen
  destination_address_prefix  = each.value.destino
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name
}
resource "azurerm_subnet_network_security_group_association" "this" {
  for_each                  = var.subnet_ids
  subnet_id                 = each.value
  network_security_group_id = azurerm_network_security_group.this.id
}
EOF

# ─── 2. Pruebas del módulo: lo que debe fallar y lo que debe pasar ──────────────
cat > modules/nsg/tests/nsg.tftest.hcl <<'EOF'
variables {
  nombre              = "nsg-test-lab"
  resource_group_name = "rg-inexistente"
  location            = "eastus"
}
run "rechaza_nombre_sin_prefijo" {
  command = plan
  variables { nombre = "web-nsg" }
  expect_failures = [var.nombre]
}
run "rechaza_prioridad_fuera_de_rango" {
  command = plan
  variables { reglas = { http = { prioridad = 50, puertos = ["80"] } } }
  expect_failures = [var.reglas]
}
run "rechaza_prioridades_duplicadas" {
  command = plan
  variables { reglas = { a = { prioridad = 100, puertos = ["80"] }, b = { prioridad = 100, puertos = ["443"] } } }
  expect_failures = [var.reglas]
}
run "plan_valido_aplica_defaults" {
  command = plan
  variables { reglas = { https = { prioridad = 110, puertos = ["443"] } } }
  assert {
    condition     = azurerm_network_security_rule.this["https"].direction == "Inbound" && azurerm_network_security_rule.this["https"].access == "Allow"
    error_message = "Los optional() no aplicaron los valores por defecto."
  }
}
EOF
cd modules/nsg && cp ~/tf-st/providers.tf tests/providers.tf 2>/dev/null   # el test necesita el provider de Topaz; si tu layout lo requiere, muévelo a la raíz del módulo solo durante el test
terraform init && terraform test                        # 4 passed (los plan no llaman a Azure salvo para el provider)
rm -f tests/providers.tf; cd ~/tf-mod

# ─── 3. Documentación generada ──────────────────────────────────────────────────
cat > modules/nsg/README.md <<'EOF'
# nsg
Grupo de seguridad de red con reglas declaradas como mapa y asociación opcional a subredes.
Solo `prioridad` y `puertos` son obligatorios por regla; el resto tiene valores por defecto seguros (Inbound/Allow/Tcp).

<!-- BEGIN_TF_DOCS -->
<!-- END_TF_DOCS -->
EOF
terraform-docs markdown table --output-file README.md --output-mode inject modules/nsg   # rellena entre las marcas
head -40 modules/nsg/README.md                          # tabla de inputs con tipo, default y descripción; outputs; requisitos

# ─── 4. Composición en el root ──────────────────────────────────────────────────
cat > main.tf <<'EOF'
locals {
  tags = { proyecto = "modulos", entorno = "lab", gestion = "terraform" }
  nsgs = {
    web = {
      https = { prioridad = 100, puertos = ["443"] }
      http  = { prioridad = 110, puertos = ["80"] }
      ssh   = { prioridad = 4000, puertos = ["22"], acceso = "Deny" }
    }
    datos = {
      mysql_desde_web = { prioridad = 100, puertos = ["3306"], origen = "10.80.1.0/24" }
      todo_lo_demas   = { prioridad = 4000, puertos = ["*"], protocolo = "*", acceso = "Deny" }
    }
  }
}
resource "azurerm_resource_group" "lab" {
  name     = "rg-mod-lab-001"
  location = "eastus"
  tags     = local.tags
  lifecycle { ignore_changes = [tags] }
}
module "red" {
  source              = "./modules/red"
  nombre              = "vnet-mod-lab"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  address_space       = "10.80.0.0/16"
  subredes            = { web = "10.80.1.0/24", datos = "10.80.2.0/24" }
}
module "nsg" {
  source              = "./modules/nsg"
  for_each            = local.nsgs
  nombre              = "nsg-${each.key}-lab"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  reglas              = each.value
  subnet_ids          = { (each.key) = module.red.subnet_ids[each.key] }
  tags                = local.tags
}
output "nsgs" { value = { for k, m in module.nsg : k => { id = m.id, reglas = m.reglas } } }
EOF
terraform init && terraform validate && terraform plan   # 1 + 3 + (2 NSG + 5 reglas + 2 asociaciones) = 13 to add
terraform apply -auto-approve
terraform state list | grep 'module.nsg\["web"\]'         # NSG, 3 reglas, 1 asociación
az network nsg rule list -g rg-mod-lab-001 --nsg-name nsg-web-lab --query "[].{regla:name, prio:priority, acceso:access}" -o table

# ─── 5. Evolucionar el módulo sin romper al consumidor ─────────────────────────
# Cambio 1 (compatible, minor): nueva variable con default → nadie tiene que tocar nada
cat >> modules/nsg/variables.tf <<'EOF'
variable "denegar_resto_inbound" {
  description = "Añade una regla Deny * con prioridad 4096 al final del tráfico entrante."
  type        = bool
  default     = false
}
EOF
cat >> modules/nsg/main.tf <<'EOF'
resource "azurerm_network_security_rule" "deny_all" {
  count                       = var.denegar_resto_inbound ? 1 : 0
  name                        = "DenyAllInbound"
  priority                    = 4096
  direction                   = "Inbound"
  access                      = "Deny"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefix       = "*"
  destination_address_prefix  = "*"
  resource_group_name         = var.resource_group_name
  network_security_group_name = azurerm_network_security_group.this.name
}
EOF
terraform plan                                            # No changes: default = false

# Cambio 2 (renombrar un recurso interno): moved DENTRO del módulo, y todos los consumidores migran al actualizar
sed -i 's/"azurerm_network_security_group" "this"/"azurerm_network_security_group" "nsg"/; s/azurerm_network_security_group\.this\./azurerm_network_security_group.nsg./g' modules/nsg/main.tf modules/nsg/outputs.tf
terraform plan | grep -E "add|destroy"                    # 2 to add, 2 to destroy: MAL (y arrastra reglas y asociaciones)
cat >> modules/nsg/main.tf <<'EOF'
moved {
  from = azurerm_network_security_group.this
  to   = azurerm_network_security_group.nsg
}
EOF
terraform plan                                            # 2 movidas · No changes
terraform apply -auto-approve

# Cambio 3 (incompatible, major): quitar una variable o cambiar su tipo. Se documenta en CHANGELOG y se etiqueta v2.0.0;
# los consumidores con ref=v1.x no se enteran hasta que decidan subir.

# ─── 6. Publicar: etiqueta y consumo por Git ────────────────────────────────────
cd modules && git init -q && git add . && git commit -qm "nsg v1.1.0: denegar_resto_inbound" && git tag v1.1.0 && cd ..
# En un proyecto real el repo sería remoto; en local el source Git también funciona:
sed -i 's|source              = "./modules/nsg"|source              = "git::file:///root/tf-mod/modules//nsg?ref=v1.1.0"|' main.tf
terraform init                                            # "Downloading git::file:///…?ref=v1.1.0 for nsg["web"]…"
terraform plan                                            # No changes: mismo código, ahora con versión fijada
ls .terraform/modules/                                    # copia descargada por instancia; modules.json registra origen y ref

terraform destroy -auto-approve
```

> **🔷 En Topaz.** NSG, reglas y asociaciones son `Microsoft.Network` por el plano de gestión. Si el emulador no devuelve `destination_port_ranges` como lista tras el `apply`, el siguiente `plan` mostrará un *update in-place* en las reglas; anótalo en la columna "En Topaz" como en páginas anteriores. La ruta del `source` Git local (`/root/tf-mod`) asume el usuario del contenedor: ajústala con `$HOME`.

---

## 6. Versionar y publicar

| **Cambio** | **Versión (SemVer)** | **Qué hace el consumidor** |
|---|---|---|
| Corregir un bug sin cambiar la interfaz ni el plan | `v1.1.1` (patch) | Sube el `ref`, `init`, `plan` sin cambios |
| Nueva variable con default, nuevo output, recurso opcional desactivado por defecto | `v1.2.0` (minor) | Igual; activa lo nuevo cuando quiera |
| Renombrar recursos internos | minor **si** incluye `moved`; major si no | Con `moved`: `plan` muestra movidas y *No changes* |
| Quitar o renombrar variable/output, cambiar tipo, cambiar default que altera el plan, subir `required_providers` de major | `v2.0.0` (major) | Lee el CHANGELOG, adapta la llamada, revisa el plan con cuidado. Mientras, sigue en `~> 1.0` |

Un repositorio de módulos por equipo (monorepo con subdirectorios y `//nsg?ref=`) … o uno por módulo (`terraform-azurerm-nsg`, nombre que exige el registry público: `terraform-<provider>-<nombre>`). El monorepo es más cómodo al empezar; el repo por módulo permite versionar cada uno por separado y publicarlo en un registry. En ambos casos la etiqueta Git es la versión, el CHANGELOG es el contrato y el pipeline del módulo ejecuta `fmt -check`, `validate`, `tflint`, `trivy config` y `terraform test` antes de permitir la etiqueta.

```yaml
# .github/workflows/modulo.yml — se ejecuta en cada PR del repo de módulos
jobs:
  calidad:
    steps:
      - uses: hashicorp/setup-terraform@v3
      - run: terraform fmt -check -recursive
      - run: for m in modules/*/; do (cd "$m" && terraform init -backend=false && terraform validate); done
      - uses: terraform-linters/setup-tflint@v4
      - run: tflint --recursive --config "$(pwd)/.tflint.hcl"
      - uses: aquasecurity/trivy-action@0.28.0
        with: { scan-type: config, scan-ref: modules/ }
      - run: cd modules/nsg && terraform init && terraform test     # los "command = plan" no necesitan credenciales reales
  docs:
    steps:
      - uses: terraform-docs/gh-actions@v1
        with: { working-dir: modules/nsg, output-file: README.md, output-method: inject, git-push: "true" }

# Publicar: el merge a main + etiqueta. Con repo por módulo, el registry público la detecta solo.
git tag -a v1.2.0 -m "nsg: variable denegar_resto_inbound" && git push --tags
```

> **🔷 Antes de escribir un módulo, mira Azure Verified Modules.** `Azure/avm-res-network-networksecuritygroup/azurerm` ya existe, con diagnósticos, locks, roles y Private Endpoints resueltos según el Well-Architected Framework. Un módulo propio tiene sentido cuando encapsula una *decisión de tu organización* (qué reglas lleva siempre un NSG de tu empresa), no cuando reimplementa un recurso. Lo habitual es un módulo propio pequeño que llama al AVM con los valores fijados por la norma interna.

---

## 7. Errores comunes

> ⚠️ **Solución de problemas**
>
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | *Unsupported block type "mmodule"* | El typo del original. `terraform validate` lo detecta en un segundo; ponlo en el pre-commit |
> | *Module not installed* / *Module source has changed* | Tras añadir un módulo o cambiar su `source`/`ref`: `terraform init`. No hace falta `-upgrade` salvo para cambiar la versión resuelta de un registry |
> | *Unsupported argument* al llamar al módulo | Pasas una variable que el módulo no declara (o la renombraron en una versión nueva). Mira `variables.tf` o el README; comprueba el `ref` |
> | *Missing required argument* | Variable sin `default` que no has pasado. Si "casi siempre" tiene el mismo valor, el módulo debería darle un default seguro |
> | *Unsupported attribute … module.nsg is a map of object* | El módulo tiene `for_each`: `module.nsg["web"].id` o `{ for k, m in module.nsg : k => m.id }`, no `module.nsg.id` |
> | *Unsupported attribute "nsg"* al leer `module.nsg["web"].nsg` | Solo se ve lo que hay en `outputs.tf`. Los recursos internos son privados; añade un output si hace falta (y súbelo como minor) |
> | *Module does not support for_each* / *Module is incompatible with count, for_each, and depends_on* | El módulo tiene un bloque `provider` dentro. Quítalo y usa `configuration_aliases` si necesita un alias |
> | *Invalid for_each argument … keys must be known* | Indexas por un id que solo se conoce tras el apply. Usa alias estables como clave (`{ web = subnet_id }`) y el id como valor |
> | Tras quitar una regla del mapa, el `plan` destruye y recrea otras | La variable es `list(object)` y el `for_each` se indexa por posición. Cámbiala a `map(object)` (major) con `moved` de `[0]` a `["https"]` |
> | *Optional object type attributes are not allowed* / *Invalid default value for variable* | `optional()` exige Terraform ≥ 1.3 y solo vale dentro de `object({…})`. El default de un `optional` debe ser del tipo declarado |
> | *Output refers to sensitive values* | Un output deriva de una variable o atributo sensible: marca `sensitive = true` en el output (o replantea si debe salir del módulo) |
> | Actualizas el `ref` del módulo y el `plan` quiere destruir todo | La versión nueva renombró recursos sin `moved` (o cambió el tipo de `for_each`). No apliques: pide al autor los `moved`, o hazlos tú en el root con `state mv` (página 9) |
> | `terraform test`: *Provider configuration not present* o pide credenciales | Los tests cargan los providers del directorio del módulo; con `command = plan` el provider azurerm igualmente se inicializa. En Topaz, copia `providers.tf` junto al módulo solo durante el test, o declara el `provider` en el propio `.tftest.hcl` |
> | `terraform test`: *Expected failure … but the check passed* | La `validation` no rechaza lo que creías. Buena noticia: el test ha encontrado el bug antes que el consumidor |
> | El README no coincide con las variables | Se editó a mano. Solo el párrafo de propósito es manual; el resto lo regenera terraform-docs en el pipeline |
> | *Error downloading module … ref=main* trae cambios inesperados | Apuntas a una rama. Siempre `ref=v1.2.0`; en registries, `version = "~> 1.2"` |

---

## 8. Autoevaluación

1. **¿Por qué el módulo del original (grupo + VNet con CIDR fijo) no es reutilizable?**
   Crea el grupo de recursos, así que no puede convivir con otro módulo en el mismo grupo; y el `address_space` fijo hace que dos instancias colisionen. El grupo se recibe; todo lo que varía es variable.
2. **¿Qué diferencia práctica hay entre `map(object)` y `list(object)` para las reglas?**
   Con `map`, cada regla tiene una dirección estable por clave: borrar una no afecta a las demás. Con `list`, quitar el elemento 0 renumera y recrea el resto.
3. **¿Para qué sirve `optional(tipo, default)`?**
   Para que el consumidor escriba solo los campos que le importan de un objeto y el módulo rellene el resto con valores seguros. Sin ello, cada regla exigiría todos los atributos.
4. **¿Cuándo falla una `validation` y qué ventaja tiene frente a que falle Azure?**
   En `plan`, antes de tocar nada, con un mensaje que explica la norma. Azure fallaría en `apply`, a mitad de despliegue, con un error genérico.
5. **¿Por qué un módulo no debe exponer el recurso completo como output?**
   Acopla al consumidor a la estructura interna (cualquier renombrado rompe) y puede filtrar atributos sensibles. Se exponen los valores concretos: `id`, `nombre`.
6. **¿Qué está mal en `source = "git::…//nsg?ref=main"`?**
   Apunta a una rama: cada `init` puede traer código distinto. La versión es una etiqueta (`ref=v1.2.0`) o una restricción `version` en registries.
7. **¿Cómo se indexa el `for_each` de asociaciones a subredes sin caer en "keys must be known"?**
   Con alias estables como clave (`{ web = subnet_id }`), nunca con el id como clave: Terraform necesita conocer las claves en `plan`.
8. **Renombras un recurso interno del módulo. ¿Qué versión publicas?**
   Minor si añades el bloque `moved` dentro del módulo (los consumidores ven movidas y *No changes*). Major si no lo añades, porque destruirá recursos al actualizar.
9. **¿Por qué `depends_on` en un módulo es casi siempre innecesario?**
   Pasar un output del otro módulo como variable ya crea la dependencia, y de forma precisa. `depends_on` hace depender todo el módulo y vuelve el plan conservador (muchos *known after apply*).
10. **¿Cuándo escribir un módulo propio en vez de usar un Azure Verified Module?**
    Cuando encapsula una decisión de tu organización (reglas obligatorias, nombres, tags) y no cuando reimplementa un recurso. Lo habitual es un módulo propio delgado que llama al AVM con los valores fijados.
11. **¿Qué prueban los cuatro `run` del test del laboratorio?**
    Tres validaciones que deben rechazar entradas inválidas (`expect_failures`) y un plan válido que confirma que los `optional()` aplican los valores por defecto (`assert`). Ninguno crea recursos.

---

## 9. Referencias

- [Desarrollo de módulos](https://developer.hashicorp.com/terraform/language/modules/develop), [estructura estándar](https://developer.hashicorp.com/terraform/language/modules/develop/structure) y [composición de módulos](https://developer.hashicorp.com/terraform/language/modules/develop/composition)
- [Variables de entrada](https://developer.hashicorp.com/terraform/language/values/variables): [`optional()`](https://developer.hashicorp.com/terraform/language/expressions/type-constraints#optional-object-type-attributes), [`validation`](https://developer.hashicorp.com/terraform/language/values/variables#custom-validation-rules), [`nullable`](https://developer.hashicorp.com/terraform/language/values/variables#disallowing-null-input-values) y [outputs](https://developer.hashicorp.com/terraform/language/values/outputs)
- [Fuentes de módulos](https://developer.hashicorp.com/terraform/language/modules/sources) (local, Git con `ref`, registry con `version`) y [meta-argumentos en módulos](https://developer.hashicorp.com/terraform/language/modules/syntax#meta-arguments) (`for_each`, `providers`, `depends_on`)
- [Providers dentro de módulos](https://developer.hashicorp.com/terraform/language/modules/develop/providers) (`configuration_aliases`) y [refactorizar módulos con `moved`](https://developer.hashicorp.com/terraform/language/modules/develop/refactoring)
- [Terraform Test](https://developer.hashicorp.com/terraform/language/tests) (`run`, `expect_failures`, `assert`) y [publicar en el registry](https://developer.hashicorp.com/terraform/language/modules/develop/publish) (nomenclatura `terraform-<provider>-<nombre>`)
- [Azure Verified Modules](https://azure.github.io/Azure-Verified-Modules/) y [AVM: Network Security Group](https://registry.terraform.io/modules/Azure/avm-res-network-networksecuritygroup/azurerm/latest)
- [terraform-docs](https://terraform-docs.io/), [TFLint ruleset azurerm](https://github.com/terraform-linters/tflint-ruleset-azurerm), [Trivy config](https://aquasecurity.github.io/trivy/latest/docs/scanner/misconfiguration/) y [Versionado semántico](https://semver.org/lang/es/)
- [`azurerm_network_security_rule`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_rule) y [`azurerm_subnet_network_security_group_association`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet_network_security_group_association)
- [Azure Local Emulator (Topaz)](https://github.com/Azure/azure-local-emulator)