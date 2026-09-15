# 🆚 Terraform frente a ARM, Bicep, Pulumi y Ansible: tres preguntas que deciden

## 1. Las tres preguntas, herramienta por herramienta

ARM y Bicep comparten fila: Bicep es un lenguaje que compila a ARM JSON y se
despliega con el mismo servicio. Terraform y OpenTofu también: OpenTofu es una
bifurcación compatible con distinta licencia.

| Pregunta | Terraform / OpenTofu | ARM / Bicep | Pulumi | Ansible |
|---|---|---|---|---|
| **¿Dónde vive el estado?** | Fichero explícito —local o backend remoto—. Sabe qué recurso es suyo y guarda todo lo que la API devolvió. | En Azure: los recursos mismos y el historial de despliegues. No hay fichero que proteger… ni que consultar. | Fichero explícito, en Pulumi Cloud o en un backend propio —Azure Blob, fichero—. | No hay. Cada ejecución consulta la realidad tarea por tarea. |
| **¿Quién calcula la diferencia?** | `plan`: código frente a estado frente a realidad, con acciones por recurso. Se guarda como fichero y se aplica ese mismo fichero. | `what-if`: ARM evalúa la plantilla contra lo existente. Informativo; el despliegue posterior recalcula, y hay "ruido" documentado. | `preview`: mismo modelo que Terraform. | `--check --diff`: cada módulo dice si cambiaría algo. Sin grafo, sin visión de conjunto. |
| **¿Qué pasa al quitar un recurso del código?** | El plan dice `destroy`. Quitar código es una orden de borrado —[página 1](index.md#pagina-1), paso 8—. | Modo *Incremental* —por defecto—: nada, el recurso sigue. *Complete*: borra todo lo del grupo que no esté en la plantilla, tuyo o no. *Deployment stacks*: borra lo que el stack gestionaba —`actionOnUnmanage`—. | Como Terraform. | Nada. Hay que escribir una tarea con `state: absent` y ejecutarla. |
| **Alcance** | Cualquier API con provider, en el mismo grafo: Azure, Entra ID, GitHub, DNS, Kubernetes, contraseñas aleatorias, claves TLS. Recursos de día 0 con `azapi`. | Azure Resource Manager, con soporte de día 0 de cada API. Extensiones —Microsoft Graph— en expansión. | Como Terraform: providers nativos más los de Terraform vía puente. | Colecciones cloud —`azure.azcollection`—, y su fuerte: lo que hay dentro de la máquina. |
| **Lenguaje y pruebas** | HCL. `terraform test` nativo —1.6+—, tflint, trivy, conftest; Terratest en Go. | Bicep —DSL— o JSON. Linter de Bicep, ARM-TTK, PSRule, what-if. | TypeScript, Python, Go, C#, Java, YAML. Pruebas con el framework del lenguaje; CrossGuard para políticas. | YAML. ansible-lint, Molecule. |
| **Licencia y coste** | Terraform: BSL 1.1 desde 1.6 —gratis salvo para productos que compitan con HashiCorp—. OpenTofu: MPL 2.0, Linux Foundation. HCP Terraform: freemium. | Incluido en Azure; Bicep es MIT. | CLI y providers Apache 2.0; Pulumi Cloud freemium; backend propio gratis. | GPL 3.0; Ansible Automation Platform de pago. |
| **¿Funciona con Topaz?** | Sí: es lo que usa el curso. | `az bicep build/lint` siempre —son locales—. `az deployment group` según la versión implemente `Microsoft.Resources/deployments`; stacks, no. | El provider `azure-native` no documenta un endpoint ARM personalizado: Azure real. | `cloud_environment` admite una URL de metadatos —pensado para Azure Stack—; sin garantía: Azure real. |

## 2. El mismo recurso en cinco sintaxis

El storage de `moodledata` con las dos propiedades de seguridad que el curso
exige en todas partes: TLS 1.2 mínimo y sin claves compartidas. Compara qué es
igual —las propiedades son las de la API de Azure en todos los casos— y qué no
—cómo se expresa la dependencia con el grupo—.

### Terraform —HCL—

```hcl
resource "azurerm_resource_group" "moodle" {
  name     = "rg-moodle"
  location = "eastus"
}

resource "azurerm_storage_account" "datos" {
  name                      = "stmoodledata01"
  resource_group_name       = azurerm_resource_group.moodle.name     # la dependencia es la referencia
  location                  = azurerm_resource_group.moodle.location
  account_tier              = "Standard"
  account_replication_type  = "LRS"
  min_tls_version           = "TLS1_2"
  shared_access_key_enabled = false
}
```

### Bicep

```bicep
// Alcance: grupo de recursos. El grupo lo crea otra cosa
// (az, o una plantilla de alcance suscripción).
param location string = resourceGroup().location
param nombre string = 'stmoodledata01'

resource datos 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  // Tipo y versión de API explícitos: soporte de día 0.
  name: nombre
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowSharedKeyAccess: false
  }
}
```

### ARM JSON —lo que Bicep compila; recortado—

```json
{
  "$schema": "https://schema.management.azure.com/schemas/2019-04-01/deploymentTemplate.json#",
  "contentVersion": "1.0.0.0",
  "parameters": {
    "location": {
      "type": "string",
      "defaultValue": "[resourceGroup().location]"
    },
    "nombre": {
      "type": "string",
      "defaultValue": "stmoodledata01"
    }
  },
  "resources": [
    {
      "type": "Microsoft.Storage/storageAccounts",
      "apiVersion": "2023-05-01",
      "name": "[parameters('nombre')]",
      "location": "[parameters('location')]",
      "sku": {
        "name": "Standard_LRS"
      },
      "kind": "StorageV2",
      "properties": {
        "minimumTlsVersion": "TLS1_2",
        "allowSharedKeyAccess": false
      }
    }
  ]
}
```

Es el formato que ARM recibe siempre: Bicep lo genera con `az bicep build`.
Escribirlo a mano ya no es la recomendación de Microsoft; leerlo sí conviene,
porque es lo que aparece en el portal —Exportar plantilla— y en los errores de
despliegue.

### Pulumi —TypeScript, provider `azure-native`—

```typescript
import * as resources from "@pulumi/azure-native/resources";
import * as storage from "@pulumi/azure-native/storage";

const moodle = new resources.ResourceGroup("moodle", {
  resourceGroupName: "rg-moodle",
  location: "eastus",
});

const datos = new storage.StorageAccount("datos", {
  accountName: "stmoodledata01",
  resourceGroupName: moodle.name, // la dependencia es la referencia, como en Terraform
  location: moodle.location,
  sku: {
    name: storage.SkuName.Standard_LRS,
  },
  kind: storage.Kind.StorageV2,
  minimumTlsVersion: storage.MinimumTlsVersion.TLS1_2,
  allowSharedKeyAccess: false,
});

// Sintaxis de programa, modelo declarativo: el código construye un grafo;
// "pulumi preview" calcula la diferencia con el estado.
// Un bucle "for" aquí es un "for_each" en HCL, no una repetición de llamadas.
```

### Ansible —colección `azure.azcollection`—

```yaml
- hosts: localhost
  connection: local

  tasks:
    - name: Grupo de recursos
      azure.azcollection.azure_rm_resourcegroup:
        name: rg-moodle
        location: eastus

    - name: Storage de moodledata
      azure.azcollection.azure_rm_storageaccount:
        resource_group: rg-moodle             # la dependencia es el orden de las tareas
        name: stmoodledata01
        account_type: Standard_LRS
        kind: StorageV2
        minimum_tls_version: TLS1_2
        allow_shared_key_access: false
        state: present                        # para borrar: state: absent, y volver a ejecutar. Quitar la tarea no borra nada.
```

!!! info "🔷 Lo que es igual y lo que no"
    Las propiedades —`Standard_LRS`, `TLS1_2`, sin claves compartidas— son las
    mismas en las cinco: todas hablan con la misma API.

    Cambia cómo se nombra el tipo —Terraform y Ansible con nombres propios del
    provider; Bicep, ARM y Pulumi con el tipo y la versión de la API—, cómo se
    declara la dependencia —referencia, orden de tareas o `dependsOn`— y, sobre
    todo, qué pasa cuando el bloque desaparece. Eso es lo que prueba el
    laboratorio.

## 3. Elegir por escenario, con razones que se puedan defender

| Escenario | Herramienta | Razón real |
|---|---|---|
| Azure y algo más en el mismo despliegue: GitHub —repos, environments—, Entra ID —grupos, aplicaciones—, DNS externo, Kubernetes, contraseñas generadas. | Terraform / OpenTofu | Un solo grafo y un solo plan para todo. Es el caso de este curso: el pipeline de la [página 13](index.md#pagina-13) crea la identidad federada, el repositorio y los recursos en la misma configuración. |
| 100 % Azure, equipo de plataforma que quiere cada API el día que sale. | Bicep | Soporte de día 0, sin fichero de estado que proteger, integración con *deployment stacks*, Policy y Template Specs. Aquí Bicep es mejor que Terraform, y hay que decirlo. |
| Plantillas exportadas del portal, Marketplace, Azure Quickstart. | ARM JSON —leer—, Bicep —escribir— | `az bicep decompile` convierte JSON en Bicep. Nadie debería escribir JSON a mano en 2026. |
| Equipo de desarrollo que quiere pruebas unitarias, tipos y abstracciones de su lenguaje. | Pulumi | Mismo modelo que Terraform con TypeScript, Python, Go o C#. El riesgo es la tentación de meter lógica imperativa en lo que debería ser una declaración. |
| Lo que hay dentro de la máquina: paquetes, ficheros, servicios, Moodle instalado y configurado. | Ansible —o cloud-init— | Complemento, no alternativa: Terraform crea la VM; Ansible o cloud-init la configuran. El curso usa cloud-init por no añadir otra herramienta —[página 8](index.md#pagina-8)—. |
| Organización con normas de licencia estrictas sobre código abierto. | OpenTofu o Bicep | Terraform es BSL desde 1.6; OpenTofu —MPL 2.0— y Bicep —MIT— son código abierto sin restricciones de uso. |
| Ya hay un equipo experto en una de ellas. | Esa | La diferencia entre Terraform y Bicep bien usados es menor que la diferencia entre cualquiera de las dos bien usada y mal usada. |

## 4. Por qué este curso usa Terraform, y qué se pierde

El original dice "liderazgo en el mercado, soporte multi-cloud e integración
con el ecosistema HashiCorp". Ninguna de las tres es la razón de verdad: el
curso no despliega en dos nubes ni usa Vault o Consul. Las razones son estas
cuatro.

- **El estado explícito enseña más.** Tener que decidir dónde vive, cómo se
  bloquea y quién lo lee —[página 4](index.md#pagina-4)— obliga a entender qué es y qué contiene.
  Con Bicep, ese conocimiento se puede posponer, y suele posponerse hasta el
  primer incidente.
- **El plan es un artefacto.** Se guarda, se comenta en la PR, se evalúa con
  políticas y se aplica exactamente ese fichero —[páginas 13](index.md#pagina-13) a 15—. `what-if`
  es un informe; el despliegue recalcula.
- **Un grafo para todo.** La identidad federada en Entra ID, el *environment*
  en GitHub y el Key Vault en Azure se crean y se destruyen juntos, con
  dependencias entre ellos.
- **Quitar código borra.** Un entorno de pruebas se destruye con un comando,
  sin modo *Complete* que arrastre lo que no era tuyo —2.5, paso 3—.

Lo que se pierde, y conviene saberlo: soporte de día 0 de cada API —`azapi` lo
mitiga, [página 8](index.md#pagina-8)—, un fichero de estado que proteger —[página 4](index.md#pagina-4)—, y una licencia
que no es código abierto —OpenTofu si importa—. Todo lo que el curso enseña
vale para Pulumi sin cambios de concepto, y para Bicep con un cambio: donde aquí
se dice "estado", allí se dice "Azure".

## 5. Laboratorio en Topaz

El mismo storage con Terraform y con Bicep, cada uno en su grupo. Después se
retira del código en los dos y se observa qué hace cada herramienta.

`az bicep build`, `lint` y `decompile` son locales y funcionan siempre;
`az deployment group` depende de que la versión de Topaz implemente
`Microsoft.Resources/deployments`: si devuelve un error de tipo no soportado,
el bloque de Bicep pasa al de Azure real y el de Terraform sigue siendo válido.

```bash
az account show --query environmentName -o tsv          # Topaz
mkdir -p ~/tf-vs/{tf,bicep} && cd ~/tf-vs/tf && cp ~/tf-st/providers.tf .

# ─── 1. Terraform: crear, retirar del código, ver el plan ────────────────────────
cat > main.tf <<'EOF'
resource "azurerm_resource_group" "moodle" {
  name     = "rg-vs-tf"
  location = "eastus"
}

resource "azurerm_storage_account" "datos" {
  name                      = "stvstf01"
  resource_group_name       = azurerm_resource_group.moodle.name
  location                  = azurerm_resource_group.moodle.location
  account_tier              = "Standard"
  account_replication_type  = "LRS"
  min_tls_version           = "TLS1_2"
  shared_access_key_enabled = false
}
EOF

terraform init >/dev/null && terraform apply -auto-approve

# El estado sabe qué dos recursos son suyos.
terraform state list

cp main.tf main.tf.completo
sed -i '/resource "azurerm_storage_account" "datos"/,/^}/d' main.tf

# Plan: 0 to add, 0 to change, 1 to destroy.
# Quitar código es una orden.
terraform plan
terraform apply -auto-approve

# Vacío.
az storage account list \
  -g rg-vs-tf \
  --query "[].name" \
  -o tsv

# Lo volvemos a crear para el paso 4.
cp main.tf.completo main.tf && terraform apply -auto-approve

# ─── 2. Bicep: lo local funciona siempre ─────────────────────────────────────────
cd ../bicep

cat > main.bicep <<'EOF'
param location string = resourceGroup().location
param nombre string = 'stvsbicep01'

resource datos 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: nombre
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowSharedKeyAccess: false
  }
}

output id string = datos.id
EOF

# Sin avisos.
az bicep lint -f main.bicep

# El JSON que ARM recibe.
az bicep build -f main.bicep &&
  jq '.resources[0] | {type, apiVersion, properties}' main.json

# Decompile sobre lo compilado: nombres de símbolo cambian, semántica no.
az bicep decompile -f main.json --force &&
  diff <(sed 's/ *$//' main.bicep) <(sed 's/ *$//' main.bicep) >/dev/null &&
  echo "ida y vuelta"

# ─── 3. Bicep: crear, retirar del código, ver qué pasa ───────────────────────────
az group create -n rg-vs-bicep -l eastus -o none

# + Microsoft.Storage/storageAccounts/stvsbicep01
# El "plan" de ARM.
az deployment group what-if \
  -g rg-vs-bicep \
  -f main.bicep

az deployment group create \
  -g rg-vs-bicep \
  -f main.bicep \
  -n primero \
  -o none

# El historial: aquí vive la memoria de ARM.
az deployment group list \
  -g rg-vs-bicep \
  --query "[].{nombre:name, modo:properties.mode, estado:properties.provisioningState}" \
  -o table

cat > vacio.bicep <<'EOF'
output nota string = 'plantilla sin recursos'
EOF

# "No change" o "Ignore": Incremental no toca lo que no nombra.
az deployment group what-if \
  -g rg-vs-bicep \
  -f vacio.bicep

az deployment group create \
  -g rg-vs-bicep \
  -f vacio.bicep \
  -n segundo \
  -o none

# stvsbicep01 SIGUE AHÍ: quitar código no borra.
az storage account list \
  -g rg-vs-bicep \
  --query "[].name" \
  -o tsv

# - Microsoft.Storage/storageAccounts/stvsbicep01: ahora sí.
az deployment group what-if \
  -g rg-vs-bicep \
  -f vacio.bicep \
  --mode Complete

az deployment group create \
  -g rg-vs-bicep \
  -f vacio.bicep \
  -n tercero \
  --mode Complete \
  -o none

# Vacío.
az storage account list \
  -g rg-vs-bicep \
  --query "[].name" \
  -o tsv

# Complete borra TODO lo del grupo que no esté en la plantilla,
# lo haya creado esta plantilla, otra, el portal o un compañero.
#
# Terraform borra lo que está en SU estado y ha desaparecido de SU código.
# Son dos respuestas distintas a la tercera pregunta.

# ─── 4. Dónde vive el estado, lado a lado ────────────────────────────────────────
cd ../tf

# Fichero local: sabe TLS, id, todo.
terraform show -json |
  jq '.values.root_module.resources[] | {address, tls: .values.min_tls_version}'

# ARM: sabe qué ids creó ese despliegue, nada más.
az deployment group show \
  -g rg-vs-bicep \
  -n primero \
  --query "properties.outputResources[].id" \
  -o tsv

# Para saber el TLS del storage de Bicep hay que preguntar al recurso:
# az storage account show.
#
# No hay "estado" que leer, porque el estado es Azure.

# ─── 5. Limpiar ──────────────────────────────────────────────────────────────────
terraform destroy -auto-approve
az group delete -n rg-vs-bicep --yes --no-wait
cd ~ && rm -rf ~/tf-vs
```

### Solo Azure real

```bash
# ─── Solo Azure real ─────────────────────────────────────────────────────────────

# A. Deployment stacks: la respuesta moderna de Bicep a "quitar código borra",
# sin el peligro de Complete.
az stack group create \
  -n moodle \
  -g rg-vs-bicep \
  -f main.bicep \
  --action-on-unmanage deleteResources \
  --deny-settings-mode none

az stack group create \
  -n moodle \
  -g rg-vs-bicep \
  -f vacio.bicep \
  --action-on-unmanage deleteResources \
  --deny-settings-mode none

# Vacío: el stack borró lo que él gestionaba, y solo eso.
az storage account list \
  -g rg-vs-bicep \
  --query "[].name" \
  -o tsv

# --deny-settings-mode denyDelete añade además lo que en Terraform+Azure
# son los bloqueos de la página 15, gestionado por el propio stack.
az stack group delete \
  -n moodle \
  -g rg-vs-bicep \
  --action-on-unmanage deleteResources \
  --yes

# B. Pulumi: mismo modelo que Terraform, estado en un Blob propio.
# Backend propio: sin Pulumi Cloud.
pulumi login 'azblob://estado-pulumi?storage_account=stestadocurso'

pulumi new azure-typescript \
  -y \
  --name moodle-vs

# El código de 2.2.
cp ~/curso/ejemplos/02/index.ts .

# + 2 to create: el "plan".
pulumi preview

# El estado, exportable y legible como el de Terraform.
pulumi up -y &&
  pulumi stack export |
  jq '.deployment.resources[].urn'

# - 1 to delete: quitar código borra, como en Terraform.
sed -i '/new storage.StorageAccount/,/^});/d' index.ts &&
  pulumi preview

pulumi destroy -y

# C. Ansible: comprobación sin grafo, borrado explícito.
ansible-galaxy collection install azure.azcollection &&
  pip install \
    -r ~/.ansible/collections/ansible_collections/azure/azcollection/requirements.txt

# Cada tarea dice "changed" o "ok":
# es el "plan" de Ansible, tarea a tarea.
ansible-playbook storage.yml --check --diff

# Segunda vez: ok=2 changed=0. Idempotente.
ansible-playbook storage.yml &&
  ansible-playbook storage.yml

# Quitar la tarea: ok=1, el storage sigue.
sed -i '/name: Storage de moodledata/,$d' storage.yml &&
  ansible-playbook storage.yml

# Para borrarlo: state: absent en la tarea, y ejecutar.
# Ansible no recuerda lo que hizo; solo sabe lo que le dices ahora.
```

## 6. Errores comunes

!!! danger
    | Idea o síntoma | Qué pasa en realidad |
    |---|---|
    | "Bicep no tiene estado" —el original—. | Azure es el estado: los recursos y el historial de despliegues. No hay fichero que proteger, pero tampoco una vista completa que consultar sin preguntar recurso a recurso —paso 4—. |
    | "Terraform es código abierto" —el original—. | BSL 1.1 desde agosto de 2023 —versión 1.6—. Gratis para casi todos los usos; no cumple la definición de código abierto. OpenTofu sí —MPL 2.0—. |
    | "Terraform solo se prueba con Terratest" —el original—. | `terraform test` es nativo desde 1.6 y escribe las pruebas en HCL —[página 9](index.md#pagina-9)—. Terratest sigue existiendo para pruebas de integración en Go. |
    | "Ansible no tiene planificación" —el original—. | `--check --diff` muestra qué cambiaría cada tarea. Lo que no hay es grafo ni borrados implícitos: no puede decir "esto sobra". |
    | Recomendar ARM JSON a "equipos con experiencia en ARM" —el original—. | Bicep compila a ARM JSON: la experiencia se conserva y la sintaxis mejora. `az bicep decompile` convierte lo existente. |
    | "Pulumi es de pago" —el original: freemium—. | CLI y providers Apache 2.0. Lo freemium es Pulumi Cloud, el backend gestionado; el estado puede ir a un Blob propio —bloque B—. |
    | Usar `--mode Complete` para "limpiar" un grupo compartido. | Borra todo lo que la plantilla no nombra, lo haya creado quien lo haya creado. Con *deployment stacks* se borra solo lo gestionado; en Terraform, solo lo del estado. |
    | Retirar un recurso de una plantilla Bicep y creer que desaparecerá. | En Incremental —por defecto— sigue ahí —paso 3—. Es la diferencia práctica más importante con Terraform y la causa habitual de recursos "fantasma" facturados. |
    | Tratar `what-if` como un plan aplicable. | Es un informe; el despliegue recalcula, y hay diferencias documentadas —"ruido"— en algunos tipos. El plan de Terraform se guarda y se aplica ese mismo fichero —[página 14](index.md#pagina-14)—. |
    | Mezclar dos herramientas sobre los mismos recursos. | Cada una cree que el recurso es suyo y revierte lo que hizo la otra: deriva perpetua. Una herramienta por recurso; si conviven, por grupo de recursos o por capa —Terraform la infraestructura, Ansible el interior de la VM—. |
    | Un bucle `for` en Pulumi que llama a la API directamente. | Es imperativo dentro de lo declarativo: el estado no lo ve. El bucle debe construir recursos —`new storage.StorageAccount`—, no ejecutar acciones. |
    | En Topaz: `az deployment group create` falla con un tipo no soportado. | La versión no implementa `Microsoft.Resources/deployments`. `bicep build/lint/decompile` siguen funcionando —son locales—; el paso 3 pasa al bloque de Azure real. El de Terraform no se ve afectado. |

## 7. Autoevaluación

1. **¿Cuáles son las tres preguntas que distinguen los modelos?**

    Dónde vive el estado, quién calcula la diferencia y qué pasa al quitar un
    recurso del código.

2. **¿Dónde vive el estado en Bicep?**

    En Azure: los recursos y el historial de despliegues. No hay fichero;
    tampoco una vista agregada sin consultar recurso a recurso.

3. **¿Qué pasa al retirar un recurso de una plantilla Bicep en modo Incremental?
   ¿Y en Complete?**

    Incremental: nada, sigue existiendo. Complete: se borra, y también todo lo
    del grupo que la plantilla no nombre, sea de quien sea.

4. **¿Qué resuelven los *deployment stacks*?**

    Borrar al retirar código sin el peligro de Complete: el stack recuerda qué
    gestiona y solo actúa sobre eso —`actionOnUnmanage`—, y puede añadir
    protección de borrado.

5. **¿En qué se diferencia `what-if` de `terraform plan`?**

    What-if es un informe; el despliegue recalcula. El plan es un fichero que se
    guarda, se evalúa y se aplica tal cual.

6. **¿Es Terraform código abierto?**

    No desde 1.6: BSL 1.1, gratis para casi todo uso pero con restricciones.
    OpenTofu —MPL 2.0— es la bifurcación abierta compatible.

7. **¿Por qué Pulumi y Terraform se comportan igual al quitar código?**

    Comparten modelo: estado explícito y diferencia calculada. Cambia la
    sintaxis —lenguaje general frente a HCL—, no el modelo.

8. **¿Cómo se borra un recurso con Ansible?**

    Con una tarea `state: absent` ejecutada. Quitar la tarea no hace nada:
    Ansible no recuerda lo que hizo.

9. **Da un escenario donde Bicep sea mejor opción que Terraform.**

    100 % Azure con necesidad de cada API el día que sale, sin querer gestionar
    un fichero de estado, con stacks, Policy y Template Specs integrados.

10. **¿Cuáles son las razones reales por las que este curso usa Terraform?**

    El estado explícito enseña más; el plan es un artefacto revisable; un grafo
    para Azure, Entra ID y GitHub; quitar código borra sin modo Complete.

11. **¿Qué es igual en las cinco sintaxis de 2.2?**

    Las propiedades del recurso: todas hablan con la misma API. Cambia cómo se
    nombra el tipo, cómo se declara la dependencia y qué pasa al retirar el
    bloque.

12. **¿Qué parte del laboratorio depende de la versión de Topaz?**

    `az deployment group` —paso 3—, que necesita
    `Microsoft.Resources/deployments`. Build, lint y decompile son locales;
    Terraform no se ve afectado.

## 8. Referencias

- [Terraform frente a Bicep](https://learn.microsoft.com/es-es/azure/developer/terraform/comparing-terraform-and-bicep)
  —Microsoft Learn; comparación oficial, honesta con ambos—.
- [Modos de despliegue de ARM](https://learn.microsoft.com/es-es/azure/azure-resource-manager/templates/deployment-modes)
  —Incremental y Complete— y
  [Deployment stacks](https://learn.microsoft.com/es-es/azure/azure-resource-manager/bicep/deployment-stacks).
- [What-if en Bicep](https://learn.microsoft.com/es-es/azure/azure-resource-manager/bicep/deploy-what-if)
  —incluye la sección sobre resultados imprecisos—.
- [Descompilar ARM JSON a Bicep](https://learn.microsoft.com/es-es/azure/azure-resource-manager/bicep/decompile).
- [Preguntas frecuentes sobre la licencia BSL](https://www.hashicorp.com/license-faq)
  —HashiCorp— y [OpenTofu](https://opentofu.org/) —Linux Foundation—.
- [`terraform test`](https://developer.hashicorp.com/terraform/language/tests)
  y [Terraform frente a otras herramientas](https://developer.hashicorp.com/terraform/intro/vs)
  —HashiCorp—.
- [Pulumi azure-native](https://www.pulumi.com/registry/packages/azure-native/)
  y [backends de estado de Pulumi](https://www.pulumi.com/docs/iac/concepts/state-and-backends/)
  —incluido Azure Blob—.
- [Colección `azure.azcollection`](https://docs.ansible.com/ansible/latest/collections/azure/azcollection/)
  y [modo check y diff](https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_checkmode.html).
- [Azure Local Emulator —Topaz—](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md).