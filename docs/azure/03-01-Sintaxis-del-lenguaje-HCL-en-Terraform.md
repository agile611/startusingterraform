# 🧩 Sintaxis del lenguaje HCL en Terraform

HashiCorp Configuration Language (HCL) es el lenguaje con el que Terraform describe infraestructura. Está pensado para que lo lean personas y lo procesen máquinas, y equilibra expresividad con simplicidad. En este módulo aprenderás sus reglas sintácticas **ejecutando cada ejemplo**: las expresiones en `terraform console` (sin red) y los bloques en un mini-proyecto contra el **emulador Topaz**.

**Tabla de contenidos**
1. [Dos formas de practicar HCL](#1-dos-formas-de-practicar-hcl)
2. [Estructura básica de un archivo](#2-estructura-básica-de-un-archivo)
3. [Comentarios y asignación](#3-comentarios-y-asignación)
4. [Tipos primitivos](#4-tipos-primitivos)
5. [Tipos compuestos](#5-tipos-compuestos)
6. [Expresiones y operadores](#6-expresiones-y-operadores)
7. [Bloques principales: proyecto `hcl-lab`](#7-bloques-principales-proyecto-hcl-lab)
8. [Funciones integradas](#8-funciones-integradas)
9. [Espacios en blanco y saltos de línea](#9-espacios-en-blanco-y-saltos-de-línea)
10. [Errores sintácticos comunes](#10-errores-sintácticos-comunes)
11. [Buenas prácticas](#11-buenas-prácticas)
12. [Referencias](#12-referencias)

---

## 1. Dos formas de practicar HCL

### 1.1. `terraform console`: sin red, sin emulador

La consola evalúa expresiones HCL al instante. Es la herramienta ideal para las secciones 4 a 6 y 8. Ábrela en un directorio vacío para que no intente cargar ninguna configuración:

```bash
mkdir -p ~/hcl-console && cd ~/hcl-console
terraform console
> upper("topaz")
"TOPAZ"
> type(["a", 1])
tuple([string, number])
> exit
```

La función `type()` solo existe en la consola y es tu mejor aliada para entender qué tipo produce cada literal. En este módulo, las líneas que empiezan por `>` son lo que escribes; la siguiente, lo que responde.

### 1.2. Proyecto `hcl-lab`: contra Topaz

Los bloques `resource`, `variable` y `output` solo se entienden aplicándolos. En la sección 7 construirás un proyecto completo en `~/hcl-lab`. Requisitos: los del curso (contenedor `azure-environment` en marcha, certificado instalado, `az` en la nube `Topaz`).

> **🔷 En Topaz.** HCL es idéntico en cualquier nube; lo único que cambia respecto a Azure real son las tres líneas del bloque `provider` que ya conoces (`metadata_host`, `resource_provider_registrations`, `subscription_id`). Todo el código de este módulo funciona sin cambios en una suscripción real quitando las dos primeras.

---

## 2. Estructura básica de un archivo

Los archivos usan la extensión `.tf` y se componen de **bloques**. Terraform lee todos los `.tf` del directorio como si fueran uno; dividirlos es una convención para las personas. Este archivo mínimo contiene los cinco bloques esenciales y se puede aplicar tal cual:

```hcl
# archivo: ~/hcl-lab/main.tf

# 1. Bloque terraform: versión y providers requeridos
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

# 2. Bloque provider: cómo hablar con la nube (aquí, el emulador)
provider "azurerm" {
  features {}
  metadata_host                   = "topaz.local.dev:8899"
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}

# 3. Bloque variable: parámetro de entrada
variable "entorno" {
  description = "Entorno de despliegue (dev, test, prod)"
  type        = string
  default     = "dev"
}

# 4. Bloque resource: lo que se crea
resource "azurerm_resource_group" "hcl" {
  name     = "rg-hcl-${var.entorno}-001"
  location = "eastus"
}

# 5. Bloque output: lo que se muestra al terminar
output "nombre_grupo" {
  value = azurerm_resource_group.hcl.name
}
```

```bash
mkdir -p ~/hcl-lab && cd ~/hcl-lab      # crea main.tf con el contenido anterior
terraform init
terraform apply -auto-approve
# Outputs:
# nombre_grupo = "rg-hcl-dev-001"

terraform plan -var entorno=prod         # el nombre cambia → "must be replaced"
```

Ese último `plan` ya enseña algo importante: la interpolación `${var.entorno}` forma parte del nombre, y el nombre de un grupo es inmutable, así que cambiar la variable implica destruir y crear. No lo apliques; lo ampliaremos en la sección 7.

---

## 3. Comentarios y asignación

```hcl
# Comentario de una línea (el estilo recomendado)
// También válido, pero terraform fmt lo convierte a #

/* Comentario
   de varias líneas: útil para desactivar un bloque temporalmente */

# Asignación: identificador = expresión. Los espacios son opcionales...
nombre  = "mi-recurso"
replicas = 3
activo = true

# ...pero terraform fmt alinea los = de argumentos consecutivos:
nombre   = "mi-recurso"
replicas = 3
activo   = true
```

> 💡 **Regla sintáctica.** `=` asigna dentro de un bloque; `==` compara dentro de una expresión. Confundirlos produce el error *Unexpected token* o, peor, una asignación donde esperabas una comparación.

---

## 4. Tipos primitivos

Pruébalos en `terraform console` (sección 1.1).

### 4.1. Cadenas (`string`)

```text
> "eastus"
"eastus"
> "Línea 1\nLínea 2\t\"entre comillas\""      # escapes: \n \t \" \\
<<EOT
Línea 1
Línea 2	"entre comillas"
EOT
> "rg-${lower("WEBAPP")}-${1 + 1}"            # interpolación: ${expresión}
"rg-webapp-2"
> "coste: %{ if 3 > 2 }alto%{ else }bajo%{ endif }"   # directiva: %{ if } / %{ for }
"coste: alto"
> "$${no_interpolar}"                        # $$ escapa el símbolo
"${no_interpolar}"
```

Para textos largos existe el **heredoc**. La variante `<<-` elimina la indentación común, lo que permite mantener el código alineado. Solo funciona en archivos `.tf`, no en la consola; lo usaremos en un `output` en la sección 7:

```hcl
descripcion = <<-EOT
  Grupo del entorno ${var.entorno}.
  Gestionado por Terraform; no editar a mano.
EOT
```

### 4.2. Números (`number`)

```text
> type(80)
number
> type(19.99)          # no hay distinción entero/decimal: todo es number
number
> 7 / 2
3.5
> 7 % 2
1
> 1.23e-4
0.000123
> tonumber("443")       # las cadenas numéricas se convierten explícita o implícitamente
443
```

### 4.3. Booleanos (`bool`)

```text
> true && !false
true
> type(true)
bool
> tobool("true")        # conversión desde cadena (útil con variables de entorno TF_VAR_*)
true
```

Existe además el valor `null`, que significa "sin valor": asignar `null` a un argumento equivale a omitirlo.

---

## 5. Tipos compuestos

### 5.1. Listas y tuplas

Un literal entre corchetes es una **tupla** (cada posición con su tipo). Cuando lo asignas a un argumento tipado `list(string)`, Terraform lo convierte a **lista** (todos los elementos del mismo tipo). El índice empieza en 0.

```text
> ["produccion", "webapp", "eastus"][0]
"produccion"
> length(["produccion", "webapp", "eastus"])
3
> slice(["a", "b", "c", "d"], 1, 3)
["b", "c"]
> type(["web", 80, true])              # tipos mixtos: tupla (válido, poco recomendable)
tuple([string, number, bool])
> type(tolist(["a", "b"]))             # homogénea y convertida: lista
list(string)
```

> ⚠️ **No existe la función `tuple()`.** `tuple([...])` y `list(...)` son *constructores de tipo* que solo se usan en el argumento `type` de una variable: `type = tuple([string, number, bool])`. Los valores se escriben siempre con corchetes.

### 5.2. Mapas y objetos

Entre llaves: pares `clave = valor`. Si todos los valores son del mismo tipo, es un **mapa**; si no, un **objeto**. Las claves son siempre cadenas y no llevan comillas si son identificadores válidos.

```text
> type({ entorno = "produccion", equipo = "infra" })
object({ entorno: string, equipo: string })
> ({ entorno = "produccion", equipo = "infra" }).entorno     # acceso con punto...
"produccion"
> ({ entorno = "produccion", equipo = "infra" })["equipo"]   # ...o con corchetes
"infra"
> merge({ a = "1", b = "2" }, { b = "X", c = "3" })          # el último gana
{ "a" = "1", "b" = "X", "c" = "3" }
> keys({ x = 1, y = 2 })
["x", "y"]
> lookup({ a = "b" }, "z", "por-defecto")
"por-defecto"
```

En un archivo `.tf` no hacen falta los paréntesis: escribirás `local.tags.entorno` o `var.subredes["frontend"]`.

### 5.3. Conjuntos (`set`)

Sin orden ni duplicados. Se crean con `toset()` y son el tipo que acepta `for_each` cuando trabajas con listas de cadenas.

```text
> toset(["webapp", "produccion", "webapp", "eastus"])
toset(["eastus", "produccion", "webapp"])
> length(toset(["a", "a", "b"]))
2
> contains(toset(["a", "b"]), "b")
true
```

---

## 6. Expresiones y operadores

### 6.1. Comparación y lógica

```text
> "prod" == "prod"
true
> 8080 >= 1024 && 8080 <= 65535
true
> "dev" == "prod" || length([1, 2]) > 0
true
> !contains(["dev", "test", "prod"], "qa")
true
```

Operadores disponibles: aritméticos `+ - * / %`, comparación `== != < <= > >=`, lógicos `&& || !`.

### 6.2. Condicional (ternario)

```text
> true ? "Premium_LRS" : "Standard_LRS"
"Premium_LRS"
> length([]) > 0 ? 3 : 1
1
```

> 💡 **Regla sintáctica.** La condición debe ser `bool` y las dos ramas deben tener tipos compatibles (Terraform intenta unificarlos; `"a" : 1` falla). HCL no tiene `if` como sentencia: el ternario y las directivas `%{ if }` son las únicas formas de condicional.

### 6.3. Expresiones `for`

Transforman y filtran colecciones. Con corchetes producen una tupla; con llaves y `=>`, un objeto.

```text
> [for t in ["web", "api", "db"] : "svc-${t}"]
["svc-web", "svc-api", "svc-db"]
> [for n in range(1, 11) : n if n % 2 == 0]
[2, 4, 6, 8, 10]
> [for s in ["auth-service", "api", "web-service"] : upper(s) if strcontains(s, "service")]
["AUTH-SERVICE", "WEB-SERVICE"]
> { for i, s in ["frontend", "backend"] : s => "10.0.${i + 1}.0/24" }
{ "backend" = "10.0.2.0/24", "frontend" = "10.0.1.0/24" }
> { for k, v in { a = 1, b = 2 } : upper(k) => v * 10 }
{ "A" = 10, "B" = 20 }
```

Fíjate en la tercera: `contains()` busca en listas; para buscar dentro de una cadena se usa `strcontains()`. Es un error muy común.

### 6.4. Splat

```text
> [{ name = "a", id = 1 }, { name = "b", id = 2 }][*].name     # equivale a [for o in ... : o.name]
["a", "b"]
```

---

## 7. Bloques principales: proyecto `hcl-lab`

Sintaxis general de un bloque: un **tipo**, cero o más **etiquetas** entre comillas y un **cuerpo** entre llaves que abre en la misma línea:

```hcl
TIPO "ETIQUETA_1" "ETIQUETA_2" {
  argumento = expresión

  BLOQUE_ANIDADO {
    argumento = expresión
  }
}
```

Vamos a ampliar el proyecto de la sección 2 hasta tener todos los bloques trabajando juntos. Sustituye el contenido de `~/hcl-lab/main.tf` por los cuatro archivos siguientes: es el mismo proyecto, repartido según la convención habitual.

### 7.1. `versions.tf`: bloques `terraform` y `provider`

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
  features {}                                    # bloque anidado obligatorio, aunque vacío

  metadata_host                   = "topaz.local.dev:8899"
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}
```

`required_version` y `version` usan *restricciones*: `>= 1.5.0` (mínimo), `~> 4.0` (cualquier 4.x, nunca 5.0), `= 4.12.0` (exacta). El `~>` es el más usado porque permite parches sin sorpresas de versión mayor.

### 7.2. `variables.tf`: bloque `variable`

```hcl
# archivo: variables.tf
variable "entorno" {
  description = "Entorno de despliegue"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "test", "prod"], var.entorno)
    error_message = "El entorno debe ser dev, test o prod."
  }
}

variable "ubicacion" {
  type    = string
  default = "eastus"
}

variable "subredes" {
  description = "Subredes a crear: nombre => índice dentro del /16"
  type        = map(number)
  default = {
    frontend = 1
    backend  = 2
  }
}

variable "puertos_permitidos" {
  type    = list(number)
  default = [443, 8080]

  validation {
    condition     = alltrue([for p in var.puertos_permitidos : p >= 1 && p <= 65535])
    error_message = "Todos los puertos deben estar entre 1 y 65535."
  }
}
```

Reglas del bloque: la única etiqueta es el nombre; `type` usa constructores (`string`, `list(number)`, `map(string)`, `object({...})`); el `default` debe ser un literal (no puede referenciar otras variables ni recursos); y `validation` puede repetirse. Los valores llegan por `-var`, por archivo `terraform.tfvars` o por variable de entorno `TF_VAR_entorno`.

### 7.3. `main.tf`: bloques `locals` y `resource`

```hcl
# archivo: main.tf
locals {
  prefijo = "hcl-${var.entorno}"                 # valor calculado, reutilizable como local.prefijo
  es_prod = var.entorno == "prod"

  tags = {
    entorno    = var.entorno
    gestionado = "terraform"
    modulo     = "sintaxis-hcl"
  }
}

resource "azurerm_resource_group" "hcl" {
  name     = "rg-${local.prefijo}-001"
  location = var.ubicacion
  tags     = local.tags

  lifecycle {
    ignore_changes = [tags]                      # Topaz no devuelve las tags del grupo
  }
}

resource "azurerm_virtual_network" "hcl" {
  name                = "vnet-${local.prefijo}"
  location            = azurerm_resource_group.hcl.location   # referencia implícita: crea primero el grupo
  resource_group_name = azurerm_resource_group.hcl.name
  address_space       = ["10.0.0.0/16"]
  tags                = local.tags
}

# for_each: una instancia por clave del mapa. Se accede con each.key / each.value
resource "azurerm_subnet" "hcl" {
  for_each = var.subredes

  name                 = "snet-${each.key}"
  resource_group_name  = azurerm_resource_group.hcl.name
  virtual_network_name = azurerm_virtual_network.hcl.name
  address_prefixes     = [cidrsubnet("10.0.0.0/16", 8, each.value)]   # 10.0.1.0/24, 10.0.2.0/24
}

# count: cero o una instancia según una condición
resource "azurerm_resource_group" "respaldo" {
  count = local.es_prod ? 1 : 0

  name     = "rg-${local.prefijo}-respaldo"
  location = var.ubicacion
  tags     = local.tags

  depends_on = [azurerm_virtual_network.hcl]     # dependencia explícita (solo cuando no hay referencia)

  lifecycle {
    ignore_changes  = [tags]
    prevent_destroy = false                      # ponlo en true para bloquear un destroy accidental
  }
}
```

Tres ideas que conviene fijar:
- **Referencias.** `azurerm_resource_group.hcl.name` es `TIPO.NOMBRE_LOCAL.ATRIBUTO`. Cada referencia crea una dependencia: Terraform ordena el grafo solo. `depends_on` se reserva para dependencias que el código no expresa.
- **`for_each` vs `count`.** `for_each` acepta un mapa o un `set(string)` y da instancias con nombre estable (`azurerm_subnet.hcl["frontend"]`). `count` da instancias numeradas (`[0]`) y se usa sobre todo para el patrón "cero o uno".
- **Meta-argumentos.** `for_each`, `count`, `depends_on`, `lifecycle` y `provider` existen en todos los recursos, sea cual sea el provider.

### 7.4. `outputs.tf`: bloque `output`

```hcl
# archivo: outputs.tf
output "grupo" {
  description = "Nombre del grupo de recursos"
  value       = azurerm_resource_group.hcl.name
}

output "subredes" {
  description = "Mapa nombre => prefijo, construido con una expresión for"
  value       = { for k, s in azurerm_subnet.hcl : k => s.address_prefixes[0] }
}

output "id_grupo" {
  value     = azurerm_resource_group.hcl.id
  sensitive = true                               # se oculta en pantalla; sigue en el estado
}

output "resumen" {
  value = <<-EOT
    Entorno ${var.entorno} en ${var.ubicacion}.
    ${length(azurerm_subnet.hcl)} subredes en ${azurerm_virtual_network.hcl.name}.
    Grupo de respaldo: %{ if local.es_prod }sí%{ else }no%{ endif }.
  EOT
}
```

### 7.5. Aplicar y observar

```bash
cd ~/hcl-lab
terraform fmt                       # alinea y normaliza
terraform validate                  # sintaxis y tipos, sin red
terraform apply -auto-approve       # Plan: 4 to add (grupo, vnet, 2 subredes)

terraform output subredes
# {
#   "backend"  = "10.0.2.0/24"
#   "frontend" = "10.0.1.0/24"
# }
terraform output -raw resumen

# Prueba la validación: debe rechazarse antes de tocar el emulador
terraform plan -var entorno=qa
# │ Error: Invalid value for variable ... El entorno debe ser dev, test o prod.

# Añade una subred sin tocar main.tf
terraform apply -auto-approve -var 'subredes={frontend=1,backend=2,datos=3}'
# Plan: 1 to add → azurerm_subnet.hcl["datos"]

# Comprueba por el otro camino
az network vnet subnet list -g rg-hcl-dev-001 --vnet-name vnet-hcl-dev \
  --query "[].{nombre:name, prefijo:addressPrefix}" -o table
```

> **🔷 En Topaz.** Todo lo anterior funciona en el emulador. Si quieres ver el `count` en acción, ejecuta `terraform apply -var entorno=prod`: el `plan` propondrá *reemplazar* el grupo y la VNet (el entorno forma parte del nombre) y añadir `azurerm_resource_group.respaldo[0]`. Es una buena ocasión para leer con calma un plan con destrucciones antes de escribir `yes`. Cuando termines el módulo: `terraform destroy -auto-approve`.

---

## 8. Funciones integradas

HCL no permite definir funciones propias; a cambio trae más de cien integradas. Estas son las que usarás a diario, con su salida en `terraform console`.

### 8.1. Cadenas

```text
> upper("eastus")                         "EASTUS"
> lower("East US")                        "east us"
> title("hola mundo")                     "Hola Mundo"
> length("hola")                          4          # no existe strlen()
> substr("hola mundo", 5, 5)              "mundo"
> strcontains("webapp-prod", "prod")      true
> replace("East US", " ", "")             "EastUS"
> split("-", "rg-webapp-prod")            ["rg", "webapp", "prod"]
> join("-", ["rg", "webapp", "prod"])     "rg-webapp-prod"
> format("rg-%s-%03d", "webapp", 7)       "rg-webapp-007"
> trimspace("  x  ")                      "x"
> regex("[0-9]+", "snet-042")             "042"
```

### 8.2. Números

```text
> abs(-42)          42
> ceil(3.2)         4
> floor(3.8)        3
> max(1, 5, 3)      5
> min([1, 5, 3]...) 1          # ... expande una lista como argumentos
> pow(2, 10)        1024
> log(100, 10)      2
> signum(-5)        -1         # no existe sign()
> parseint("ff", 16) 255
```

### 8.3. Colecciones

```text
> length(["a", "b", "c"])                     3
> element(["a", "b", "c"], 4)                 "b"        # cíclico: 4 % 3 = 1
> slice(["a", "b", "c", "d"], 1, 3)           ["b", "c"]
> concat(["a"], ["b", "c"])                   ["a", "b", "c"]
> compact(["a", "", "b", null])               ["a", "b"]
> distinct(["a", "b", "a"])                   ["a", "b"]
> flatten([["a", "b"], ["c"]])                ["a", "b", "c"]
> reverse([1, 2, 3])                          [3, 2, 1]
> sort(["c", "a", "b"])                       ["a", "b", "c"]
> keys({ x = 1, y = 2 })                      ["x", "y"]
> values({ x = 1, y = 2 })                    [1, 2]
> merge({ a = 1 }, { b = 2 })                 { "a" = 1, "b" = 2 }
> lookup({ a = 1 }, "z", 0)                   0
> zipmap(["a", "b"], [1, 2])                  { "a" = 1, "b" = 2 }
> coalesce("", null, "por-defecto")           "por-defecto"
> try(({ a = 1 }).b, "no-existe")             "no-existe"
> can(tonumber("abc"))                        false
```

### 8.4. Red, codificación y conversión

```text
> cidrsubnet("10.0.0.0/16", 8, 3)             "10.0.3.0/24"     # la que usa el proyecto hcl-lab
> cidrhost("10.0.1.0/24", 4)                  "10.0.1.4"
> jsonencode({ entorno = "dev", n = 2 })      "{\"entorno\":\"dev\",\"n\":2}"
> jsondecode("{\"a\":1}").a                   1
> base64encode("topaz")                       "dG9wYXo="
> tostring(42)                                "42"
> tonumber("42")                              42
> tolist(toset(["b", "a"]))                   ["a", "b"]
> timestamp()                                 "2026-09-09T13:59:00Z"   # cambia en cada plan: úsala con cuidado
```

Hay dos funciones que solo existen en la consola y que ya has usado: `type()` para ver el tipo de una expresión, y la propia evaluación interactiva. El resto están disponibles en cualquier `.tf`.

---

## 9. Espacios en blanco y saltos de línea

HCL es flexible con los espacios, pero **los saltos de línea sí importan**: terminan un argumento. Estas son las reglas que evitan la mayoría de errores de análisis:

```hcl
# 1. La llave de apertura va en la MISMA línea que la cabecera del bloque
resource "azurerm_resource_group" "ok" {
  name     = "x"
  location = "eastus"
}

# INVÁLIDO: "A block definition must have block content delimited by { and },
#            starting on the same line as the block header"
resource "azurerm_resource_group" "mal"
{
  name = "x"
}

# 2. En mapas y objetos, el salto de línea separa pares; la coma es opcional
tags = {
  entorno = "dev"
  equipo  = "infra"
}
tags = { entorno = "dev", equipo = "infra" }     # en una línea, coma obligatoria

# 3. En listas, la coma es SIEMPRE obligatoria; el salto de línea no la sustituye
puertos = [
  80,
  443,          # la coma final se tolera
]

# 4. Una expresión larga se parte solo dentro de paréntesis, corchetes o llaves
nombre = format(
  "rg-%s-%s-%03d",
  var.aplicacion,
  var.entorno,
  var.instancia,
)
es_valido = (
  var.entorno == "prod"
  && length(var.subredes) > 0
)

# 5. Un argumento termina en el salto de línea: dos en la misma línea es error
name = "a" location = "b"       # INVÁLIDO: "Missing newline after argument"
```

`terraform fmt` normaliza todo lo que sí es flexible (indentación de dos espacios, alineación de `=`, líneas en blanco entre bloques) y deja tal cual lo que no puede decidir por ti.

---

## 10. Errores sintácticos comunes

Los detecta `terraform validate` (o antes, `terraform fmt`) sin necesidad de hablar con el emulador. La columna de la izquierda muestra el texto literal que imprime Terraform para que puedas buscarlo.

| **Mensaje de Terraform** | **Causa** | **Incorrecto → correcto** |
|---|---|---|
| `Invalid block definition` | La `{` no está en la línea de la cabecera | `resource "azurerm_resource_group" "rg"`<br>`  name = "x"`<br>➡️<br>`resource "azurerm_resource_group" "rg" {`<br>`  name = "x"`<br>`}` |
| `Unclosed configuration block` | Falta una `}`; suele aparecer "al final del archivo" aunque el fallo esté antes | Ejecuta `terraform fmt`: la indentación resultante delata el bloque abierto |
| `Missing item separator` | Falta una coma entre elementos de una lista | `tags = ["prod" "webapp"]`<br>➡️<br>`tags = ["prod", "webapp"]` |
| `Missing newline after argument` | Sobran tokens tras una asignación: dos argumentos en una línea, o `=` donde iba `==` | `es_prod = var.entorno = "prod"`<br>➡️<br>`es_prod = var.entorno == "prod"` |
| `Invalid reference` | Una cadena sin comillas se interpreta como referencia a un recurso | `location = eastus`<br>➡️<br>`location = "eastus"` |
| `Invalid character` | Comillas tipográficas (`“ ”`) u otros caracteres pegados desde un documento de texto | `name = “rg-webapp”`<br>➡️<br>`name = "rg-webapp"` |
| `Unsupported argument` | Nombre de argumento mal escrito o inexistente para ese recurso | `locaton = "eastus"`<br>➡️<br>`location = "eastus"` |
| `Reference to undeclared input variable` | Se usa `var.x` sin un bloque `variable "x"` | Declara la variable (aunque sea sin `default`) o corrige el nombre |
| `Invalid default value for variable` | El `default` no puede convertirse al `type` declarado | `type = list(number)`<br>`default = ["http"]`<br>➡️<br>`default = [80] # "80" también vale` |
| `Invalid index` | Índice fuera de rango o clave inexistente | `local.items[2] # solo hay 2 elementos`<br>➡️<br>`try(local.items[2], null)`<br>`# o: length(local.items) > 2 ? local.items[2] : null` |
| `Variables not allowed` | El `default` de una variable referencia `var.*`, `local.*` o un recurso | Mueve el cálculo a un bloque `locals` |

> 💡 **Flujo recomendado ante cualquier error:** `terraform fmt` → `terraform validate` → leer el archivo y la línea que indica el mensaje. El 90 % de los errores de sintaxis se resuelven sin llegar a `plan`.

---

## 11. Buenas prácticas

> ✅ **Formato automático.** `terraform fmt -recursive` antes de cada commit; `terraform fmt -check` en CI para rechazar código sin formatear. No discutas de estilo: delega en la herramienta.

> ℹ️ **Nombres.**
> - `snake_case` para nombres locales de recursos, variables, outputs y locals.
> - El nombre local describe el *papel*, no el tipo: `azurerm_resource_group.red`, no `azurerm_resource_group.rg1`. El tipo ya está en la etiqueta.
> - Si solo hay un recurso de un tipo, `this` o `main` son convenciones aceptadas.
> - Los nombres en Azure (`name = ...`) siguen la convención del curso: `rg-<app>-<entorno>-<instancia>`.

> ℹ️ **Valores repetidos en `locals`.** Cualquier literal que aparezca dos veces (etiquetas, prefijos, CIDR base) va a un bloque `locals`. Ya viste en el módulo anterior por qué: en Topaz, heredar `tags` desde el grupo de recursos rompe el `apply`; con `local.tags` el valor depende de ti, no del servidor.

> ⚠️ **Recursos separados antes que bloques anidados.** Algunos recursos admiten definir hijos anidados (por ejemplo, `subnet {}` dentro de `azurerm_virtual_network`). Prefiere el recurso independiente (`azurerm_subnet`): permite `for_each`, referencias directas y cambios sin tocar al padre. Nunca mezcles ambos estilos sobre la misma VNet: el provider los pisará mutuamente.

> ⚠️ **Validaciones y descripciones en variables.** Una variable sin `description` es una variable que alguien tendrá que descifrar. Una variable sin `validation` es un error que aparecerá en el `apply` en vez de en el `plan`.

> 📝 **Recordatorio de sintaxis (para la chuleta).**
> - Cadenas siempre entre comillas dobles; interpolación con `${ }`.
> - `=` asigna, `==` compara.
> - Listas: corchetes y comas obligatorias. Mapas: llaves y saltos de línea (o comas).
> - La `{` de un bloque va en la línea de la cabecera.
> - `for_each` quiere un mapa o un set; `count` quiere un número.
> - `contains()` busca en listas; `strcontains()` en cadenas.

---

## 12. Referencias

- [Sintaxis de configuración HCL](https://developer.hashicorp.com/terraform/language/syntax/configuration)
- [Expresiones: tipos, operadores, condicionales, `for`, splat](https://developer.hashicorp.com/terraform/language/expressions)
- [Cadenas, plantillas y heredoc](https://developer.hashicorp.com/terraform/language/expressions/strings)
- [Lista completa de funciones integradas](https://developer.hashicorp.com/terraform/language/functions)
- [Variables de entrada, tipos y validaciones](https://developer.hashicorp.com/terraform/language/values/variables)
- [Meta-argumento `for_each`](https://developer.hashicorp.com/terraform/language/meta-arguments/for_each) y [`count`](https://developer.hashicorp.com/terraform/language/meta-arguments/count)
- [`terraform console`](https://developer.hashicorp.com/terraform/cli/commands/console)
- [Guía de estilo oficial de Terraform](https://developer.hashicorp.com/terraform/language/style)
- [Recurso `azurerm_subnet`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet) (usado en `hcl-lab`)