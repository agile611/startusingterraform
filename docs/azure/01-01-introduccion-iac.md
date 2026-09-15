# 📘 Infraestructura como código: qué problema resuelve y a qué precio

## 1. Qué es (y qué no es) infraestructura como código

Dos definiciones de referencia. La primera es la que el original atribuye a
Wikipedia; en realidad procede de Microsoft Learn:

> "Infrastructure as Code (IaC) is the management of infrastructure (networks,
> virtual machines, load balancers, and connection topology) in a descriptive
> model, using the same versioning as DevOps team uses for source code."
>
> — Sam Guckenheimer, *What is Infrastructure as Code?*, Microsoft Learn

> "Infrastructure as Code is an approach to infrastructure automation based on
> practices from software development. It emphasizes consistent, repeatable
> routines for provisioning and changing systems and their configuration."
>
> — Kief Morris, *Infrastructure as Code*, O'Reilly

Las dos coinciden en tres propiedades. Si falta una, hay automatización, pero
no IaC.

| Propiedad | Qué significa | Qué queda fuera |
|---|---|---|
| **Es texto** | La infraestructura está descrita en ficheros legibles por personas y por máquinas. | El portal; una plantilla exportada que nadie puede leer ni editar. |
| **Está versionada** | Cada cambio tiene autor, fecha, motivo y revisión; se puede revertir. | Un script en el escritorio de alguien; un `infra_final_v3.sh`. |
| **Es ejecutable y repetible** | La misma descripción aplicada dos veces produce el mismo resultado, y aplicada tras un cambio produce exactamente ese cambio. | Un runbook en la wiki; un script que falla la segunda vez porque "ya existe". |

La tercera propiedad es la que separa un script de una declaración, y es el
tema de 1.3. Antes, el problema.

## 2. El problema, contado con Moodle

Un centro educativo tiene un Moodle en Azure montado a mano hace tres años:
una máquina virtual, una base de datos MySQL, una cuenta de almacenamiento
para `moodledata`, una red con sus reglas, un Key Vault. Funciona. Los
problemas aparecen cuando hay que hacer algo con él.

| Situación | Sin IaC | Con IaC |
|---|---|---|
| "Necesitamos un entorno de pruebas igual que producción para probar la actualización a Moodle 5". | Dos días de clics recordando qué se configuró; el resultado se parece, pero no es igual, y las diferencias se descubren cuando algo falla. | La misma configuración con `entorno = "test"`. Veinte minutos, y las diferencias con producción son las que dice el código. |
| "¿Quién abrió el puerto 3306 a Internet y cuándo?" | El Activity Log dice quién, si no ha caducado; el porqué no lo sabe nadie. | `git log -p` sobre la regla: autor, fecha, la PR con la discusión, y quién la aprobó. |
| "El storage tiene TLS 1.0 activado, pero juraría que lo pusimos en 1.2". | Alguien lo cambió en el portal durante una urgencia. Se descubre en una auditoría. | `terraform plan` lo muestra como diferencia entre código y realidad, y el siguiente apply lo revierte. |
| "La persona que montó esto se ha ido". | La documentación está en su cabeza y en una wiki de hace dos años. | El código describe lo que existe; `terraform show` describe lo que existe de verdad. |
| "Hay que replicarlo para otro centro". | Vuelta a empezar. | Un módulo con otros parámetros —[página 9](index.md#pagina-9)—. |

Lo que estos cinco casos tienen en común no es la velocidad, aunque también:
es que **la configuración real y la descripción de la configuración son la
misma cosa**, y cuando dejan de serlo, hay una herramienta que lo dice.

## 3. Imperativo y declarativo: quién calcula la diferencia

El original compara `az group create` con un
`resource "azurerm_resource_group"`. No es buena comparación:
`az group create` es idempotente por sí solo —Azure lo trata como un
*PUT*—, así que ejecutarlo dos veces no revela nada. La diferencia aparece
con dos recursos y tres operaciones: crear, cambiar, borrar.

```hcl
# Imperativo: una lista de pasos. Tú decides qué hacer; el script solo lo ejecuta.
az group create -n rg-moodle -l eastus
az storage account create -n stmoodledata$RANDOM -g rg-moodle -l eastus --sku Standard_LRS --min-tls-version TLS1_2

#   Segunda ejecución: crea OTRA cuenta (el nombre es distinto). El script no sabe que ya había una.
#   Cambiar el TLS: hay que escribir otro comando (update), y saber que la cuenta existe.
#   Borrar la cuenta: quitar la línea del script no borra nada. Hay que escribir el delete, y acordarse del nombre.
#   Para que un script haga bien las tres cosas tiene que preguntar antes de cada paso: "¿existe? ¿cómo está?". Ese código lo escribes tú.

# Declarativo: una descripción del resultado. La herramienta compara con lo que hay y decide qué hacer.
resource "azurerm_resource_group" "moodle" {
  name     = "rg-moodle"
  location = "eastus"
}

resource "azurerm_storage_account" "datos" {
  name                     = "stmoodledata01"
  resource_group_name      = azurerm_resource_group.moodle.name
  # referencia: de aquí sale el orden, no de la posición en el fichero
  location                 = azurerm_resource_group.moodle.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
}

#   Segunda ejecución: "No changes". Cambiar el TLS: editas la línea; el plan dice "~ update in-place".
#   Borrar la cuenta: quitas el bloque; el plan dice "- destroy".
#   El "¿existe? ¿cómo está?" lo hace la herramienta, contra su estado y contra Azure.
```

!!! info "🔷 Lo imperativo no es el enemigo"
    En este curso hay scripts `bash` en casi todas las páginas: las
    comprobaciones del pipeline —[página 13](index.md#pagina-13)—, las puertas —[página 15](index.md#pagina-15)—, el
    cloud-init que instala Moodle dentro de la máquina. Son imperativos y están
    bien así, porque describen *procesos*, no *estados*.

    La declaración es para lo que tiene que existir de una forma concreta y
    seguir así; el script, para lo que tiene que ocurrir. El error es usar
    scripts para mantener estado.

## 4. Cinco palabras que se usarán en todas las páginas

| Término | Definición precisa | Dónde lo verás |
|---|---|---|
| **Idempotencia** | Aplicar la misma descripción N veces deja el sistema igual que aplicarla una. No significa "no hace nada": significa que lo que hace depende de la diferencia, no de cuántas veces se ejecuta. | Laboratorio, paso 3: *No changes*. |
| **Estado** | El registro que Terraform guarda de qué recursos reales corresponden a cada bloque del código, con sus atributos. Sin él, no sabría que `stmoodledata01` es "suyo". Es un fichero, y contiene todo lo que Azure devolvió, incluidas contraseñas. | [Página 4](index.md#pagina-4) —dónde guardarlo y cómo bloquearlo—, [página 10](index.md#pagina-10) —qué secretos contiene—. |
| **Plan** | La diferencia calculada entre el código, el estado y la realidad, expresada como acciones: crear, cambiar, reemplazar, destruir. Se puede leer, guardar, comparar y evaluar antes de ejecutar. | Todo el curso; a fondo, [página 14](index.md#pagina-14). |
| **Provider** | El plugin que traduce cada tipo de recurso a llamadas de API: `azurerm` para Azure Resource Manager. Terraform no sabe qué es una cuenta de almacenamiento; el provider sí. | [Página 3](index.md#pagina-3) —configuración y versiones—. |
| **Deriva** | Cualquier diferencia entre la realidad y el estado que no viene del código: alguien tocó el portal, un servicio cambió algo solo. IaC no la impide; la hace visible en el siguiente plan. | Laboratorio, paso 5; [página 13](index.md#pagina-13) —detección diaria—. |

## 5. Lo que IaC no resuelve, y lo que cuesta

El original lista seis beneficios y ningún coste. Los beneficios son reales;
también lo son estas cuatro cosas, y conviene saberlas antes de empezar.

- **El estado es un activo nuevo.** Antes había que proteger la
  infraestructura; ahora también el fichero que la describe, que contiene
  secretos y cuya pérdida deja los recursos huérfanos. Las [páginas 4](index.md#pagina-4), 10 y 15
  existen por esto.
- **La deriva no desaparece.** El portal sigue ahí y la gente sigue teniendo
  urgencias. IaC convierte la deriva de invisible en visible; impedirla es cosa
  de permisos —[página 12](index.md#pagina-12)— y puertas —[página 15](index.md#pagina-15)—.
- **Un error se replica con la misma eficacia que un acierto.** Un `destroy`
  mal dirigido borra en segundos lo que costó meses. Por eso se revisa el plan
  antes de aplicar —[página 13](index.md#pagina-13)— y se protegen los recursos con datos —páginas
  14 y 15—.
- **Describe recursos, no arquitectura.** Una red mal diseñada en HCL sigue
  siendo una red mal diseñada, ahora reproducible. IaC no sustituye saber qué
  se está construyendo.

| Herramienta | Qué es | Por qué el curso no la usa —o sí— |
|---|---|---|
| **ARM / Bicep** | Declarativo, nativo de Azure, sin estado propio —Azure es el estado—. | Excelente si solo hay Azure. Sin estado local no hay `plan` tan detallado ni `destroy` completo; y las ideas que enseña este curso —estado, plan, deriva, módulos— son las que Bicep no obliga a aprender. |
| **Terraform / OpenTofu** | Declarativo, multi-proveedor, con estado explícito y plan como artefacto. | El elegido: el mismo modelo sirve para Azure, GitHub, Entra ID, Kubernetes y DNS en un solo grafo. OpenTofu es compatible con casi todo lo que verás. |
| **Pulumi** | Declarativo en el modelo, imperativo en la sintaxis —Python, TypeScript…—. | Mismos conceptos —estado, plan, providers—; lenguaje general en lugar de HCL. Lo que aprendas aquí se traslada. |
| **Ansible** | Gestión de configuración: qué hay dentro de la máquina. | Complementario, no alternativo. Terraform crea la VM; dentro, el curso usa cloud-init —[página 7](index.md#pagina-7)—. |

!!! info "🔷 Por qué Topaz"
    Azure Local Emulator —nombre en clave Topaz— implementa el plano de control
    de Azure Resource Manager y los planos de datos de varios servicios en un
    contenedor local. Terraform y `az` hablan con él exactamente igual que con
    Azure: mismos tipos de recurso, mismo provider, mismo estado.

    Lo que no hay es factura, suscripción ni riesgo de borrar algo real. Cada
    página marca qué parte del laboratorio funciona en el emulador y qué parte
    —RBAC, políticas, federación, límites de API— exige Azure real.

## 6. Mapa del curso: cada promesa, dónde se cumple

| Beneficio prometido | Qué hace falta para que sea verdad | Páginas |
|---|---|---|
| Reproducibilidad | Variables por entorno, módulos, nombres que no colisionen. | 5, 6, 9 |
| Trazabilidad | Git con reglas de rama, PR con el plan como comentario, aprobaciones registradas, Activity Log. | 13, 15, 17 |
| Automatización | Un pipeline que planifica en la PR y aplica tras aprobar, sin secretos de larga duración. | 12, 13, 14 |
| Documentación viva | Código legible, `terraform show`, etiquetas coherentes; y que nadie cambie nada fuera. | 6, 12, 15 |
| Seguridad | Estado protegido, secretos fuera del código y del estado, identidades sin contraseña. | 4, 10, 11, 12, 16 |
| Control de costes | Entornos que se crean y destruyen a demanda, tallas por variable, etiquetas para imputar. | 5, 18 |

## 7. Laboratorio en Topaz

Diez minutos para sentir la diferencia de 3. Primero un script, dos veces.
Después una declaración, dos veces; luego un cambio, una deriva provocada,
una reversión con Git y un borrado quitando código. No hace falta entender
la sintaxis de HCL todavía: eso empieza en la [página 3](index.md#pagina-3). Fíjate en lo que
dice cada `plan`.

!!! danger "⚠️ Antes de nada"
    `az account show --query environmentName -o tsv` debe devolver `Topaz`.

    Si devuelve `AzureCloud`, todo lo que sigue se crearía en una suscripción
    real, con factura. Es el primer hábito del curso: mirar a dónde apuntas
    antes de aplicar.

```bash
az account show --query environmentName -o tsv          # Topaz
az account show --query environmentName -o tsv          # Topaz
mkdir -p ~/tf-iac && cd ~/tf-iac && git init -q && cp ~/tf-st/providers.tf .

# ─── 1. Imperativo, dos veces ────────────────────────────────────────────────────
cat > crear.sh <<'EOF'
#!/usr/bin/env bash
set -e
az group create -n rg-iac-script -l eastus -o none
az storage account create -n stscript$RANDOM -g rg-iac-script -l eastus --sku Standard_LRS --min-tls-version TLS1_2 -o none
echo "hecho"
EOF

chmod +x crear.sh
./crear.sh && ./crear.sh                                           # dos ejecuciones, sin error
az storage account list -g rg-iac-script --query "[].name" -o tsv  # DOS cuentas. El script no sabía que ya había una.

# Para cambiar el TLS de "la cuenta" habría que saber su nombre.
# Para borrarla, escribir el delete.
# Para que crear.sh hiciera las tres cosas bien tendrías que añadirle:
# ¿existe? ¿cómo está? ¿qué sobra?
# Ese código es el que Terraform trae.

# ─── 2. Declarativo, primera vez ─────────────────────────────────────────────────
cat > main.tf <<'EOF'
resource "azurerm_resource_group" "moodle" {
  name     = "rg-iac-tf"
  location = "eastus"
}

resource "azurerm_storage_account" "datos" {
  name                     = "stiacdatos01"
  resource_group_name      = azurerm_resource_group.moodle.name
  location                 = azurerm_resource_group.moodle.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
}
EOF

git add main.tf providers.tf && git commit -qm "storage para moodledata"
terraform init >/dev/null

# Plan: 2 to add, 0 to change, 0 to destroy.
# Lee las líneas con "+".
terraform plan

# En el curso nunca se aplica sin leer el plan;
# aquí lo acabas de leer.
terraform apply -auto-approve

# UNA cuenta
az storage account list -g rg-iac-tf --query "[].name" -o tsv

# ─── 3. Declarativo, segunda vez: idempotencia ───────────────────────────────────
# No changes. Your infrastructure matches the configuration.
terraform plan

# Apply complete! Resources: 0 added, 0 changed, 0 destroyed.
terraform apply -auto-approve

# El estado: aquí está la memoria de qué es "suyo".
ls -la terraform.tfstate

# azurerm_resource_group.moodle
# azurerm_storage_account.datos
terraform state list

# ─── 4. Un cambio: el plan lo describe antes de hacerlo ──────────────────────────
sed -i 's/"LRS"/"ZRS"/' main.tf

# ~ account_replication_type = "LRS" -> "ZRS"
# Plan: 0 to add, 1 to change, 0 to destroy
terraform plan

git commit -qam "moodledata a ZRS" && terraform apply -auto-approve
sed -i 's/"stiacdatos01"/"stiacdatos02"/' main.tf

# -/+ destroy and then create replacement
# El nombre no se puede cambiar: se reemplaza.
terraform plan

# El plan avisa de que "cambiar el nombre" es "borrar y crear otro":
# con datos dentro, eso es perder los datos. Por eso se lee.
git checkout main.tf

# ─── 5. Deriva: alguien toca el portal ───────────────────────────────────────────
# "Una urgencia"
az storage account update \
  -n stiacdatos01 \
  -g rg-iac-tf \
  --min-tls-version TLS1_0 \
  -o none

# ~ min_tls_version = "TLS1_0" -> "TLS1_2"
# Terraform quiere devolverlo a lo que dice el código.
terraform plan

# El código gana.
# La deriva no se impide —eso son permisos, página 12—;
# se detecta y se corrige.
terraform apply -auto-approve

# ─── 6. Revertir con Git: el retroceso es un commit ──────────────────────────────
# Dos commits: el inicial y "moodledata a ZRS".
git log --oneline

# Deshace el cambio a ZRS en el código…
git revert --no-edit HEAD

# …y el plan dice exactamente eso: ~ "ZRS" -> "LRS"
terraform plan
terraform apply -auto-approve

# Quién, cuándo, qué: la trazabilidad de 1.2, hoy en tu portátil;
# en el curso, en una PR.
git log -p --follow -S'ZRS' -- main.tf | head -30

# ─── 7. El código es la documentación; el estado es la realidad ──────────────────
# Lo que debería existir.
cat main.tf

# Lo que existe, con todos los atributos que Azure devolvió
# —id, endpoints… y en otros recursos, contraseñas: página 10—.
terraform show

terraform show -json |
  jq '.values.root_module.resources[] | {address, tls: .values.min_tls_version, sku: .values.account_replication_type}'

# ─── 8. Borrar quitando código ───────────────────────────────────────────────────
# El bloque desaparece del fichero.
sed -i '/resource "azurerm_storage_account" "datos"/,/^}/d' main.tf

# - destroy
# Plan: 0 to add, 0 to change, 1 to destroy
terraform plan

# En el script, quitar líneas no borraba nada.
# Aquí, quitar el bloque es una orden de borrado.
# Las dos cosas son útiles; hay que saber cuál se tiene delante.
terraform apply -auto-approve

# Vacío
az storage account list -g rg-iac-tf --query "[].name" -o tsv

# ─── 9. Limpiar ──────────────────────────────────────────────────────────────────
# Lo que Terraform creó.
terraform destroy -auto-approve

# Lo que el script creó: Terraform no lo conoce,
# hay que borrarlo a mano —y acordarse—.
az group delete -n rg-iac-script --yes --no-wait

cd ~ && rm -rf ~/tf-iac
```

!!! info "🔷 Lo que acabas de ver"
    El script hizo lo que le dijiste, dos veces, y dejó dos cuentas que ahora
    hay que recordar borrar. La declaración hizo lo que hacía falta cada vez:
    nada la segunda, un cambio la tercera, deshacer una deriva la cuarta, un
    borrado cuando quitaste el bloque.

    Y antes de cada acción, un plan que decía qué iba a pasar; uno de ellos
    avisaba de que un "cambio de nombre" era en realidad una destrucción. Todo
    el resto del curso es aprender a leer ese plan, a proteger el fichero de
    estado y a poner ese `apply` detrás de una revisión.

## 8. Errores comunes —de concepto—

!!! danger
    | Idea equivocada | Qué pasa en realidad |
    |---|---|
    | "Tengo los scripts en Git, ya hago IaC". | Texto y versionado, sí; repetible, no: el script del paso 1 crea duplicados y no sabe borrar. Falta la tercera propiedad de 1.1. |
    | "Idempotente significa que no hace nada la segunda vez". | Significa que hace *lo que falta*: nada si no falta nada, un cambio si hay diferencia, un borrado si sobra algo. Paso 3 frente a pasos 4 y 8. |
    | "El orden de los bloques en el fichero importa". | El orden lo dan las referencias —`azurerm_resource_group.moodle.name`—, no la posición. Puedes poner el storage antes que el grupo y el plan es el mismo —[página 14](index.md#pagina-14)—. |
    | "Con IaC nadie puede cambiar nada en el portal". | Sí pueden —paso 5—. IaC lo detecta y lo revierte; impedirlo es cosa de permisos —[página 12](index.md#pagina-12)— y puertas —[página 15](index.md#pagina-15)—. |
    | "El estado es un detalle interno de Terraform". | Es el fichero que sabe qué recursos son tuyos y contiene todo lo que Azure devolvió, contraseñas incluidas. Perderlo o filtrarlo son los dos incidentes más graves del curso —[páginas 4](index.md#pagina-4) y 10—. |
    | "Cambiar el nombre de un recurso es un cambio pequeño". | Para muchos recursos es borrar y crear otro —paso 4: `-/+`—. Con datos dentro, es perderlos. El plan lo dice; por eso se lee siempre. |
    | "Terraform gestiona todo lo que hay en la suscripción". | Solo lo que está en su estado. Lo que creó el script del paso 1 le es invisible; `destroy` no lo toca. Lo existente se incorpora con `import` —[página 8](index.md#pagina-8)—. |
    | "Declarativo es mejor que imperativo". | Declarativo es mejor para *estado*; imperativo para *procesos*. El curso usa los dos: HCL para lo que debe existir, bash para lo que debe ocurrir. |
    | "`-auto-approve` es normal". | En este laboratorio sí, porque acabas de leer el plan. En el curso, el apply va detrás de un plan revisado en una PR —[página 13](index.md#pagina-13)—; desde el portátil, sin `-auto-approve`. |
    | "Topaz es un Azure de juguete: lo que funciona ahí no vale". | Implementa el mismo plano de control con los mismos tipos y el mismo provider: plan, estado, deriva y módulos se comportan igual. Lo que no emula —RBAC, políticas, federación, límites— cada página lo marca y lo lleva a Azure real. |

## 9. Autoevaluación

1. **¿Cuáles son las tres propiedades de IaC y cuál falta en "scripts en Git"?**

    Texto, versionado, ejecutable y repetible. A los scripts les falta la
    tercera: la segunda ejecución no produce el mismo resultado ni saben
    cambiar o borrar.

2. **¿Qué hace la herramienta declarativa que el script no hace?**

    Calcular la diferencia entre lo deseado, lo que recuerda —estado— y lo que
    hay —Azure—, y convertirla en acciones. En el script, ese cálculo lo haces
    tú.

3. **Define idempotencia sin decir "no hace nada".**

    Aplicar la misma descripción N veces deja el sistema igual que aplicarla
    una; lo que hace en cada aplicación depende de la diferencia, no del número
    de veces.

4. **¿Qué es el estado y por qué es un activo a proteger?**

    El registro de qué recurso real corresponde a cada bloque, con todos sus
    atributos. Sin él, Terraform no sabe qué es suyo; con él en manos ajenas,
    se filtran secretos.

5. **¿Qué es un plan y qué avisó en el paso 4 del laboratorio?**

    La diferencia calculada, expresada como acciones. Avisó de que cambiar el
    nombre del storage era un reemplazo —`-/+`—: destruir y crear, con pérdida
    de datos.

6. **¿Qué es la deriva y qué hace IaC con ella?**

    Diferencia entre realidad y estado que no viene del código. IaC la muestra
    en el plan y la revierte en el apply; no la impide.

7. **¿Por qué `az group create` no sirve para ilustrar lo imperativo?**

    Es idempotente por sí solo —PUT—. La diferencia aparece con varios recursos
    y con cambiar y borrar: ahí el script necesita lógica que la declaración
    trae de serie.

8. **¿Qué pasó con las cuentas del script al final del laboratorio?**

    Terraform no las conocía: `destroy` no las tocó y hubo que borrarlas a
    mano. Solo gestiona lo que está en su estado.

9. **¿Cuándo es correcto un script imperativo en un proyecto de IaC?**

    Para procesos —comprobaciones, puertas, instalación dentro de la máquina—,
    no para mantener estado.

10. **Nombra dos costes que IaC añade.**

    El estado como activo nuevo a proteger; la capacidad de replicar un error
    —un `destroy` mal dirigido— con la misma eficacia que un acierto.

11. **¿Qué diferencia a Bicep de Terraform en cuanto al estado?**

    Bicep no tiene estado propio: Azure es el estado. Terraform lo mantiene
    explícito, lo que da un plan más completo y un `destroy` total, a cambio de
    tener que protegerlo.

12. **¿Qué comprobación se hace antes de cualquier apply en este curso, y por qué?**

    `az account show --query environmentName` debe decir `Topaz`. Si dice
    `AzureCloud`, el laboratorio crearía recursos reales con coste.

## 10. Referencias

- [¿Qué es la infraestructura como código?](https://learn.microsoft.com/es-es/devops/deliver/what-is-infrastructure-as-code)
  —Microsoft Learn; la cita de 1.1—.
- Kief Morris, *Infrastructure as Code: Dynamic Systems for the Cloud Age*,
  2.ª ed., O'Reilly, 2020 —capítulos 1 a 4: principios, deriva,
  "configuration drift" y "snowflake servers"—.
- [Introducción a Terraform](https://developer.hashicorp.com/terraform/intro)
  y [comparación con otras herramientas](https://developer.hashicorp.com/terraform/intro/vs)
  —HashiCorp—.
- [Propósito del estado](https://developer.hashicorp.com/terraform/language/state/purpose)
  —por qué Terraform lo necesita—.
- [Bicep](https://learn.microsoft.com/es-es/azure/azure-resource-manager/bicep/overview)
  y [Terraform frente a Bicep](https://learn.microsoft.com/es-es/azure/developer/terraform/comparing-terraform-and-bicep)
  —Microsoft Learn—.
- [OpenTofu](https://opentofu.org/docs/)
  —bifurcación de código abierto compatible—.
- [Azure Resource Manager](https://learn.microsoft.com/es-es/azure/azure-resource-manager/management/overview)
  —el plano de control con el que hablan Terraform y Topaz—.
- [Azure Local Emulator —Topaz—](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md).