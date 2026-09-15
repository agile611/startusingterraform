# 🔎 Verificación y validación de recursos en Azure

Un `Apply complete!` dice que Terraform terminó, no que la infraestructura sea la que querías. En este módulo aprenderás a comprobarlo por varios caminos independientes: el estado de Terraform, la API del emulador a través de Azure CLI y, cuando sea posible, el propio recurso funcionando. Todo se ejecuta contra **Topaz**; donde el emulador no ofrece lo que Azure real sí (portal, métricas, costes), lo verás señalado en un recuadro **🔷 En Topaz** junto con lo que harías en una suscripción de verdad.

**Tabla de contenidos**
1. [Objetivos de aprendizaje](#1-objetivos-de-aprendizaje)
2. [Verificación desde Terraform (sustituye al Portal)](#2-verificación-desde-terraform)
3. [Verificación mediante Azure CLI](#3-verificación-mediante-azure-cli)
4. [Azure PowerShell (solo Azure real)](#4-azure-powershell-solo-azure-real)
5. [Funcionalidad, monitorización y salud](#5-funcionalidad-monitorización-y-salud)
6. [Verificación automatizada](#6-verificación-automatizada)
7. [Solución de problemas comunes](#7-solución-de-problemas-comunes)
8. [Buenas prácticas de verificación](#8-buenas-prácticas-de-verificación)
9. [Recursos adicionales](#9-recursos-adicionales)

> **🔷 Punto de partida.** Este módulo verifica el despliegue del módulo anterior: grupo `rg-webapp-produccion-001` en `eastus` con VNet, subred, plan de App Service y aplicación web (la cuenta de almacenamiento es opcional). Ejecuta los comandos desde el directorio del proyecto (`~/recursos`) con la CLI en la nube `Topaz`.

---

## 1. Objetivos de aprendizaje

1. Verificar un despliegue de Terraform por **tres vías independientes**: estado local, API de Azure (CLI) y funcionalidad del recurso.
2. Interpretar `terraform state`, `terraform show` y `terraform plan -detailed-exitcode` como herramientas de validación.
3. Usar consultas JMESPath en Azure CLI para validar ubicación, etiquetas, tipos y estado de aprovisionamiento.
4. Escribir un script de verificación reutilizable que sirva tanto en el emulador como en Azure real.
5. Distinguir qué comprobaciones son posibles en Topaz y cuáles exigen una suscripción real (portal, métricas, costes).
6. Diagnosticar discrepancias entre lo declarado, lo que hay en el estado y lo que existe en la nube.

---

## 2. Verificación desde Terraform

> **🔷 En Topaz no hay Azure Portal.** El emulador expone la API de Resource Manager, pero no una interfaz web. En el laboratorio, la "vista visual" del despliegue la dan `terraform show` y las salidas `-o table` de la CLI. Al final de esta sección tienes la equivalencia con el Portal para cuando trabajes en Azure real.

### 2.1. ¿Qué cree Terraform que existe?

El estado es la memoria de Terraform. Empieza por leerlo:

```bash
cd ~/recursos
terraform state list
```

```text
azurerm_linux_web_app.produccion
azurerm_resource_group.produccion
azurerm_service_plan.produccion
azurerm_subnet.produccion
azurerm_virtual_network.produccion
```

Si falta un recurso que está en tu `.tf`, el `apply` no lo llegó a crear (o se creó fuera de Terraform). Si sobra uno que ya no está en el código, el siguiente `plan` propondrá destruirlo.

### 2.2. Detalle de un recurso

```bash
# Un recurso concreto, con todos sus atributos tal como los devolvió el emulador
terraform state show azurerm_virtual_network.produccion

# Todo el despliegue, legible
terraform show

# Todo el despliegue, en JSON para filtrar con jq
terraform show -json | jq -r '.values.root_module.resources[] | "\(.type)\t\(.values.name)\t\(.values.location // "-")"'
```

Fíjate en que `state show` muestra **lo que el servidor devolvió**, no lo que tú escribiste. Es la forma más rápida de descubrir atributos que el emulador ignora o normaliza.

### 2.3. Outputs: los valores que importan

Declara como `output` lo que quieras verificar sin bucear en el estado. Añade a tu proyecto un `outputs.tf`:

```hcl
# archivo: outputs.tf
output "resource_group_id" {
  value = azurerm_resource_group.produccion.id
}

output "vnet_address_space" {
  value = azurerm_virtual_network.produccion.address_space
}

output "web_app_hostname" {
  value = azurerm_linux_web_app.produccion.default_hostname
}

output "resumen" {
  value = {
    grupo     = azurerm_resource_group.produccion.name
    ubicacion = azurerm_resource_group.produccion.location
    recursos  = 5
  }
}
```

```bash
terraform apply -refresh-only -auto-approve   # registra los outputs sin tocar recursos
terraform output                               # todos
terraform output -raw web_app_hostname         # uno, sin comillas (ideal para scripts)
terraform output -json | jq .resumen.value
```

### 2.4. La prueba definitiva: `plan` sin cambios

Un `plan` limpio significa que configuración, estado y realidad coinciden. Con `-detailed-exitcode` el resultado es un código de salida que un script puede evaluar:

```bash
terraform plan -detailed-exitcode -input=false
echo "Código de salida: $?"
# 0 = sin cambios (todo coincide)   2 = hay cambios (drift o código nuevo)   1 = error
```

> **🔷 En Topaz.** Si el `plan` devuelve 2 y el único cambio es `tags` en el grupo de recursos, es la limitación del emulador que ya conoces (no devuelve las etiquetas del grupo). El `lifecycle { ignore_changes = [tags] }` del módulo anterior lo elimina; si lo has quitado, vuélvelo a poner.

### 2.5. Equivalencia con Azure Portal (Azure real)

Cuando trabajes contra una suscripción real, cada comprobación anterior tiene su vista en [portal.azure.com](https://portal.azure.com). Aquí tienes la correspondencia directa:

| **Qué verificas** | **En el laboratorio (Topaz)** | **En Azure Portal** |
|---|---|---|
| El grupo existe, ubicación, etiquetas | `az group show` | Grupos de recursos → buscar el nombre → *Información general* |
| Inventario de recursos | `terraform state list`, `az resource list -o table` | Hoja del grupo → *Recursos* |
| Propiedades de un recurso | `terraform state show`, `az resource show` | Recurso → *Información general* / *Propiedades* / *Vista JSON* |
| Quién hizo qué y cuándo | No disponible | Hoja del grupo → *Registro de actividad*, filtrar por *Escribir* |
| Coste del despliegue | No aplica (coste cero) | Hoja del grupo → *Análisis de costos* |

*Esta tabla te permite traducir mentalmente los comandos de CLI/Terraform a la interfaz gráfica que encontrarás en un entorno productivo de Azure.*

---

## 3. Verificación mediante Azure CLI

La CLI es un cliente independiente de Terraform: si ambos ven lo mismo, el despliegue es real. Antes de nada, confirma que hablas con el emulador:

```bash
az account show --query '{cloud:environmentName, sub:id}' -o json
# Esperado: "cloud": "Topaz", "sub": "00000000-0000-0000-0000-000000000001"
```

### 3.1. Inventario básico

```bash
RG=rg-webapp-produccion-001

az group show -n $RG -o table
az resource list -g $RG -o table
az resource list -g $RG --query "length([])" -o tsv      # número de recursos (sin contar el grupo)
```

El número debe coincidir con `terraform state list` menos uno (el grupo no aparece en `az resource list`). Si desplegaste VNet, subred, plan y web app, la subred tampoco cuenta: es un recurso hijo y la CLI la lista dentro de la VNet. Espera **3**.

### 3.2. Filtrado por tipo

```bash
az resource list -g $RG --resource-type Microsoft.Network/virtualNetworks -o table
az resource list -g $RG --resource-type Microsoft.Web/serverfarms       -o table   # planes de App Service
az resource list -g $RG --resource-type Microsoft.Web/sites             -o table   # aplicaciones web
az resource list -g $RG --resource-type Microsoft.Storage/storageAccounts -o table

# Subredes: cuelgan de la VNet
az network vnet subnet list -g $RG --vnet-name vnet-webapp-produccion -o table
```

### 3.3. Consultas JMESPath: ubicación y etiquetas

```bash
# Nombre, tipo y ubicación de todo
az resource list -g $RG --query "[].{nombre:name, tipo:type, ubicacion:location}" -o table

# Recursos fuera de la región esperada (debe devolver lista vacía)
az resource list -g $RG --query "[?location!='eastus'].{nombre:name, ubicacion:location}" -o json

# Recursos con la etiqueta correcta
az resource list -g $RG --query "[?tags.entorno=='produccion'].{nombre:name, entorno:tags.entorno}" -o table

# Recursos SIN la etiqueta obligatoria (debe devolver lista vacía)
az resource list -g $RG --query '[?tags.entorno==`null`].name' -o tsv
```

> **🔷 En Topaz.** Las etiquetas de la VNet, el plan y la web app se devuelven correctamente. Las del **grupo de recursos** no: `az group show -n $RG --query tags` devuelve `null` aunque las declaraste. Por eso el script de la sección 6 valida las etiquetas sobre la VNet y no sobre el grupo. En Azure real ambas funcionan.

### 3.4. Estado de aprovisionamiento

`az resource list` **no devuelve** `properties`; hay que consultar cada recurso. Este bucle lo hace por ti:

```bash
az group show -n $RG --query properties.provisioningState -o tsv     # Succeeded

for id in $(az resource list -g $RG --query "[].id" -o tsv); do
  az resource show --ids "$id" --query "{nombre:name, estado:properties.provisioningState}" -o tsv
done
```

> 💡 **🔷 En Topaz** algunos tipos de recurso pueden devolver el estado vacío en lugar de `Succeeded`: el emulador no implementa todas las propiedades. Trátalo como "existe y no ha fallado". En Azure real, cualquier valor distinto de `Succeeded` (`Failed`, `Canceled`, `Updating`) merece investigación.

### 3.5. Historial: qué hay y qué no

> 🚨 **Idea errónea frecuente:** `az deployment group list` no muestra nada creado por Terraform. Esos comandos listan *despliegues ARM* (plantillas ARM o Bicep). Terraform llama directamente a la API de cada recurso y no genera despliegues. Su historial es el estado (`terraform.tfstate` y sus copias `.backup`) y, en Azure real, el *Registro de actividad*.

```bash
# Historial local de Terraform
ls -la terraform.tfstate*
terraform state pull | jq '{serial, terraform_version, recursos: (.resources | length)}'

# Azure real (no disponible en Topaz): operaciones de escritura del último día
az monitor activity-log list -g $RG --offset 1d \
  --query "[?contains(operationName.value,'write')].{hora:eventTimestamp, op:operationName.localizedValue, estado:status.value}" -o table
```

### 3.6. Detalle por tipo de recurso

```bash
# Red: espacio de direcciones y subredes
az network vnet show -g $RG -n vnet-webapp-produccion \
  --query "{espacio:addressSpace.addressPrefixes, subredes:subnets[].{nombre:name, prefijo:addressPrefix}}" -o json

# App Service: plan y aplicación
az appservice plan show -g $RG -n asp-webapp-produccion --query "{sku:sku.name, so:kind}" -o json
az webapp show -g $RG -n app-webapp-produccion-001 --query "{estado:state, host:defaultHostName, plan:appServicePlanId}" -o json

# Storage (si lo desplegaste)
az storage account show -g $RG -n stgwebappprod001 --query "{tier:sku.tier, replicacion:sku.name, kind:kind}" -o json
```

Compara cada valor con tu `.tf`: `10.0.0.0/16`, `10.0.1.0/24`, `S1`, `Standard_LRS`. Esta es la verificación de *configuración*, un nivel por encima de la de *existencia*.

---

## 4. Azure PowerShell (solo Azure real)

> **🔷 Fuera del alcance en Topaz.** El módulo `Az` de PowerShell puede apuntar a nubes personalizadas con `Add-AzEnvironment`, pero requiere declarar a mano cada endpoint del emulador y no está soportado oficialmente. En el curso usamos Azure CLI como cliente de verificación. Esta sección queda como referencia para equipos que trabajen en Windows contra Azure real.

```powershell
Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force
Connect-AzAccount
Set-AzContext -Subscription "<id-de-suscripcion>"

$rg = Get-AzResourceGroup -Name "rg-webapp-produccion-001"
"{0}  {1}  {2}" -f $rg.ResourceGroupName, $rg.Location, $rg.ProvisioningState
$rg.Tags

$recursos = Get-AzResource -ResourceGroupName $rg.ResourceGroupName
"Total: $($recursos.Count)"
$recursos | Group-Object ResourceType | Format-Table Name, Count -AutoSize
$recursos | Where-Object { -not $_.Tags.entorno } | Select-Object Name, ResourceType   # sin etiqueta obligatoria
```

Los equivalentes CLI de la sección 3 cubren exactamente lo mismo; elige la herramienta con la que tu equipo esté más cómodo, pero no mezcles ambas en el mismo script.

---

## 5. Funcionalidad, monitorización y salud

Que un recurso exista no significa que funcione. Este nivel de verificación es donde el emulador y Azure real más se separan, así que empezamos por el mapa:

| **Comprobación** | **Topaz** | **Azure real** |
|---|---|---|
| Plano de control (existe, propiedades, etiquetas) | ✅ Completo | ✅ |
| Plano de datos de Storage (crear contenedor, subir blob) | ⚠️ Sí, si el puerto 8891 y `/etc/hosts` están configurados | ✅ |
| Petición HTTP a la web app | ❌ No hay runtime detrás del recurso | ✅ `curl https://<host>.azurewebsites.net` |
| Métricas, alertas, Log Analytics, Advisor | ❌ No implementado | ✅ |
| Análisis de costes | ❌ No aplica | ✅ |

*Utiliza esta tabla para saber rápidamente hasta dónde puedes llegar probando en local frente a un entorno cloud real.*

### 5.1. Prueba funcional en Topaz: el plano de datos de Storage

Si desplegaste la cuenta de almacenamiento (y tienes el puerto 8891 publicado y `stgwebappprod001.storage.topaz.local.dev` en `/etc/hosts`), puedes ir más allá del plano de control:

```bash
SA=stgwebappprod001
KEY=$(az storage account keys list -g $RG -n $SA --query "[0].value" -o tsv)

az storage container create -n verificacion --account-name $SA --account-key "$KEY"
echo "hola topaz" > /tmp/prueba.txt
az storage blob upload -c verificacion -f /tmp/prueba.txt -n prueba.txt --account-name $SA --account-key "$KEY"
az storage blob list -c verificacion --account-name $SA --account-key "$KEY" -o table
```

Si el `upload` funciona, has verificado la cadena completa: ARM creó la cuenta, el emulador expone su plano de datos y las credenciales son válidas.

### 5.2. Salud de una aplicación web (Azure real)

```bash
HOST=$(terraform output -raw web_app_hostname)
curl -s -o /dev/null -w "HTTP %{http_code}  %{time_total}s\n" "https://$HOST/"
curl -s "https://$HOST/health" | jq '.status == "ok"'     # si la app expone /health
```

> **🔷 En Topaz** el `default_hostname` se devuelve, pero no hay ningún servidor escuchando: el emulador modela el recurso, no ejecuta tu código. El `curl` fallará por resolución de nombres o conexión rechazada, y es normal.

### 5.3. Métricas y alertas (Azure real)

En una suscripción real, tras 5–10 minutos de actividad, los recursos publican métricas en Azure Monitor. Una alerta típica de CPU sobre una VM:

```bash
AG=$(az monitor action-group create -g $RG -n ag-notificaciones --short-name agnot \
       --action email admin admin@empresa.com --query id -o tsv)

az monitor metrics alert create -g $RG -n alta-cpu-vm \
  --scopes $(az vm show -g $RG -n vm-resiliente --query id -o tsv) \
  --condition "avg Percentage CPU > 80" --window-size 5m --evaluation-frequency 1m \
  --severity 2 --action $AG --description "CPU media > 80% durante 5 minutos"
```

Y una consulta KQL en Log Analytics para peticiones fallidas en la última hora:

```bash
WS=$(az monitor log-analytics workspace list -g $RG --query "[0].customerId" -o tsv)
az monitor log-analytics query -w $WS -o table --analytics-query "
AppRequests
| where TimeGenerated >= ago(1h)
| summarize Total=count(), Fallidas=countif(Success == false), Duracion=avg(DurationMs) by bin(TimeGenerated, 5m)
| order by TimeGenerated desc"
```

> **🔷 En Topaz.** Ninguno de estos comandos funciona: el emulador no implementa `Microsoft.Insights` ni `Microsoft.OperationalInsights`. Si los ejecutas, verás un `404` o *NoRegisteredProviderFound*. No es un error tuyo: guarda estos ejemplos para la suscripción real, donde son la base de la verificación a medio plazo (sección 8.1).

---

## 6. Verificación automatizada

Todo lo anterior se convierte en un script que devuelve `0` si el despliegue es correcto y distinto de cero si no. Ese script es la pieza que después se conecta a cualquier pipeline.

> **🔷 En Topaz.** Un runner de GitHub Actions o Azure DevOps hospedado en la nube **no puede alcanzar** `topaz.local.dev`: el emulador vive en tu máquina. En el laboratorio ejecutas el script en local; los YAML de 6.2 y 6.3 son plantillas para un *self-hosted runner* instalado en el mismo host que el contenedor, o para Azure real cambiando dos variables.

### 6.1. Script de verificación reutilizable

Guárdalo como `~/recursos/verify-deployment.sh`. Los valores esperados van en variables al principio; en Azure real solo cambian la ubicación y el número de recursos.

```bash
#!/usr/bin/env bash
# verify-deployment.sh — verificación post-apply (Topaz y Azure real)
set -uo pipefail

RG="${RG:-rg-webapp-produccion-001}"
EXPECTED_LOCATION="${EXPECTED_LOCATION:-eastus}"
EXPECTED_TAGS="entorno=produccion aplicacion=webapp equipo=infraestructura"
EXPECTED_TYPES=("Microsoft.Network/virtualNetworks" "Microsoft.Web/serverfarms" "Microsoft.Web/sites")
TAG_SOURCE_TYPE="Microsoft.Network/virtualNetworks"   # en Topaz el RG no devuelve tags; validamos sobre la VNet

errores=0
ok()   { echo "  ✅ $*"; }
fail() { echo "  ❌ $*"; errores=$((errores+1)); }
warn() { echo "  ⚠️  $*"; }

echo "=== 1. Contexto ==="
CLOUD=$(az account show --query environmentName -o tsv 2>/dev/null) || { fail "Azure CLI sin sesión"; exit 1; }
ok "Nube: $CLOUD"

echo "=== 2. Grupo de recursos ==="
if ! GROUP=$(az group show -n "$RG" -o json 2>/dev/null); then
  fail "El grupo $RG no existe"; exit 1
fi
LOC=$(echo "$GROUP" | jq -r .location)
[ "$LOC" = "$EXPECTED_LOCATION" ] && ok "Ubicación: $LOC" || fail "Ubicación $LOC (esperada $EXPECTED_LOCATION)"
STATE=$(echo "$GROUP" | jq -r .properties.provisioningState)
[ "$STATE" = "Succeeded" ] && ok "Estado: $STATE" || fail "Estado del grupo: $STATE"

echo "=== 3. Recursos esperados ==="
for tipo in "${EXPECTED_TYPES[@]}"; do
  n=$(az resource list -g "$RG" --resource-type "$tipo" --query "length([])" -o tsv)
  [ "$n" -gt 0 ] && ok "$n × $tipo" || fail "Falta $tipo"
done

echo "=== 4. Ubicación de todos los recursos ==="
fuera=$(az resource list -g "$RG" --query "[?location!='$EXPECTED_LOCATION'].name" -o tsv)
[ -z "$fuera" ] && ok "Todos en $EXPECTED_LOCATION" || fail "Fuera de región: $fuera"

echo "=== 5. Etiquetas (sobre $TAG_SOURCE_TYPE) ==="
TAGS=$(az resource list -g "$RG" --resource-type "$TAG_SOURCE_TYPE" --query "[0].tags" -o json)
for par in $EXPECTED_TAGS; do
  k=${par%%=*}; v=${par#*=}
  actual=$(echo "$TAGS" | jq -r --arg k "$k" '.[$k] // "null"')
  [ "$actual" = "$v" ] && ok "$k=$v" || fail "$k: '$actual' (esperado '$v')"
done
sin_tag=$(az resource list -g "$RG" --query '[?tags.entorno==`null`].name' -o tsv)
[ -z "$sin_tag" ] && ok "Ningún recurso sin etiqueta 'entorno'" || warn "Sin etiqueta 'entorno': $sin_tag"

echo "=== 6. Estado de aprovisionamiento ==="
for id in $(az resource list -g "$RG" --query "[].id" -o tsv); do
  read -r nombre estado <<< "$(az resource show --ids "$id" --query "[name, properties.provisioningState]" -o tsv | tr '\n' ' ')"
  case "$estado" in
    Succeeded) ok "$nombre" ;;
    ""|None)   warn "$nombre: estado no informado (habitual en Topaz)" ;;
    *)         fail "$nombre: $estado" ;;
  esac
done

echo "=== 7. Terraform: sin drift ==="
if [ -f terraform.tfstate ] || [ -d .terraform ]; then
  terraform plan -detailed-exitcode -input=false -no-color > /tmp/plan.txt 2>&1; rc=$?
  case $rc in
    0) ok "plan sin cambios" ;;
    2) fail "plan con cambios pendientes (ver /tmp/plan.txt)" ;;
    *) fail "plan con error (ver /tmp/plan.txt)" ;;
  esac
else
  warn "No hay proyecto Terraform en este directorio; se omite"
fi

echo
if [ "$errores" -eq 0 ]; then
  echo "🎉 Verificación superada"; exit 0
else
  echo "💥 $errores comprobación(es) fallida(s)"; exit 1
fi
```

```bash
chmod +x verify-deployment.sh
./verify-deployment.sh
echo "Código de salida: $?"

# Contra Azure real, sin tocar el script:
RG=rg-webapp-prod-001-weu EXPECTED_LOCATION=westeurope ./verify-deployment.sh
```

> 💡 **Dos detalles de bash que conviene fijar.** Los bucles `for` se cierran con `done`, no con `fi`; es un error muy común al copiar ejemplos y provoca *syntax error near unexpected token*. Y las etiquetas se leen con `jq --arg` en vez de interpolar la clave en la cadena: así funciona también con claves que llevan guiones, como `fecha-creacion`.

### 6.2. GitHub Actions (self-hosted runner o Azure real)

```yaml
# .github/workflows/terraform-verify.yml
name: Verificar despliegue

on:
  workflow_run:
    workflows: ["Terraform Deploy"]
    types: [completed]

jobs:
  verify:
    # 'self-hosted' para Topaz (runner en el mismo host que el emulador); 'ubuntu-latest' para Azure real
    runs-on: self-hosted
    if: ${{ github.event.workflow_run.conclusion == 'success' }}
    env:
      RG: rg-webapp-produccion-001
      EXPECTED_LOCATION: eastus
      SSL_CERT_FILE: /etc/ssl/certs/ca-certificates.crt   # confianza en el certificado de Topaz (Terraform)
      REQUESTS_CA_BUNDLE: /etc/ssl/certs/ca-certificates.crt   # ídem para Azure CLI
    steps:
      - uses: actions/checkout@v4

      # Azure real: sustituye este paso por azure/login@v2 con secrets.AZURE_CREDENTIALS
      - name: Sesión con Topaz
        run: |
          az cloud set --name Topaz
          az account show > /dev/null || { echo "::error::Sesión de az caducada; ejecuta az login en el runner"; exit 1; }

      - uses: hashicorp/setup-terraform@v3
      - run: terraform init -input=false

      - name: Verificar despliegue
        run: ./verify-deployment.sh
```

### 6.3. Azure DevOps Pipelines

```yaml
# azure-pipelines.yml
trigger:
  - main

variables:
  RG: rg-webapp-produccion-001
  EXPECTED_LOCATION: eastus

stages:
  - stage: Verify
    displayName: Verificar despliegue
    jobs:
      - job: VerifyDeployment
        pool:
          name: LabTopaz          # pool de agentes self-hosted; para Azure real: vmImage: ubuntu-latest
        steps:
          # Azure real: usa la tarea AzureCLI@2 con azureSubscription en lugar de este script
          - script: |
              az cloud set --name Topaz
              az account show > /dev/null || { echo "##[error]Sesión de az caducada"; exit 1; }
            displayName: Sesión con Topaz

          - script: terraform init -input=false
            displayName: terraform init

          - script: ./verify-deployment.sh
            displayName: Verificar despliegue
            env:
              SSL_CERT_FILE: /etc/ssl/certs/ca-certificates.crt
              REQUESTS_CA_BUNDLE: /etc/ssl/certs/ca-certificates.crt
```

La lógica vive en el script, no en el YAML: así la pruebas en tu terminal, la versionas con el resto del proyecto y la misma copia sirve para GitHub, Azure DevOps o GitLab.

---

## 7. Solución de problemas comunes

### 7.1. Discrepancias entre Terraform y la CLI

> 🚨 **Síntoma:** `terraform state list` muestra recursos que `az resource list` no devuelve

**Causa:** el recurso se borró fuera de Terraform (con `az` o recreando el contenedor del emulador, que arranca vacío).
**Solución:** `terraform plan` detectará la ausencia y propondrá recrearlos. Si recreaste el contenedor, todo el estado es obsoleto: elimina `terraform.tfstate*` y aplica de nuevo, o ejecuta `terraform state rm` recurso a recurso.

> 🚨 **Síntoma:** `az resource list` muestra recursos que no están en el estado

**Causa:** se crearon con `az`, desde otro directorio de Terraform, o el estado se perdió.
**Solución:** impórtalos (`terraform import` o bloque `import {}`) si deben gestionarse desde este proyecto; bórralos con `az` si eran restos de pruebas. Nunca los dejes en tierra de nadie.

> 🚨 **Síntoma:** `plan -detailed-exitcode` devuelve 2 justo después de un `apply` limpio

**Causa:** el servidor normaliza o descarta algún atributo (en Topaz, las etiquetas del grupo de recursos; en Azure real, mayúsculas en ubicaciones o valores por defecto que el provider no conoce).
**Solución:** lee el `plan`: si el cambio es siempre el mismo y no importa, `lifecycle { ignore_changes = [...] }`. Si es un atributo que sí importa, es un bug del provider o del emulador que conviene reportar.

### 7.2. Azure CLI

> 🚨 **Síntoma:** `az resource list` devuelve lista vacía o `ResourceGroupNotFound`

1. Confirma la nube: `az account show --query environmentName` debe decir `Topaz`. Si dice `AzureCloud`, estás consultando Azure real: `az cloud set --name Topaz`.
2. Confirma el nombre exacto: `az group list -o table`.
3. Comprueba que el contenedor está en marcha: `docker ps --filter name=azure-environment`.
4. Para ver la petición HTTP real, añade `--debug`.

> 🚨 **Síntoma:** la consulta `--query` devuelve `null` o falla con *invalid jmespath*

1. Los literales JMESPath van entre acentos graves: `[?tags.entorno==`null`]`. En bash, encierra toda la consulta entre comillas simples para que no se interpreten.
2. `az resource list` no devuelve `properties`; usa `az resource show --ids` o el comando específico del tipo (`az network vnet show`, `az webapp show`).
3. Comprueba el nombre exacto del campo con `-o json` sin filtro antes de escribir la consulta.

> 🚨 **Síntoma:** `az deployment group list` no muestra el despliegue de Terraform

**Causa:** no es un fallo. Terraform no crea despliegues ARM; llama a la API de cada recurso. Ese comando solo lista plantillas ARM o Bicep.
**Solución:** el historial de Terraform es su estado (`terraform state pull`, ficheros `.backup`) y, en Azure real, el Registro de actividad.

### 7.3. Autenticación y conectividad

| **Error** | **Causa** | **Solución** |
|---|---|---|
| `401` / `InvalidAuthenticationToken` | Sesión de `az` caducada (el emulador emite tokens de corta duración) | `az login --use-device-code` |
| `SSLError` / `CERTIFICATE_VERIFY_FAILED` | La CLI (Python) no confía en el certificado de Topaz | `export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt` |
| `x509: certificate signed by unknown authority` | Terraform (Go) no confía en el certificado | `export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt` |
| `Connection refused` / `i/o timeout` | Contenedor parado o `/etc/hosts` sin la entrada | `docker start azure-environment`; revisa `/etc/hosts` |
| `AuthorizationFailed` | Solo en Azure real: faltan permisos RBAC (mínimo **Lector** para verificar) | `az role assignment list --assignee <quien> --all -o table` |

### 7.4. Verificación funcional y métricas

> 🚨 **Síntoma:** `az storage container create` se queda colgado o falla por nombre no resuelto

**Causa:** el plano de datos de Storage vive en `<cuenta>.storage.topaz.local.dev:8891` y ese nombre no está en `/etc/hosts` o el puerto no está publicado.
**Solución:** añade la entrada apuntando a `127.0.0.1` y recrea el contenedor con `-p 8891:8891` (recuerda reinstalar el certificado después).

> 🚨 **Síntoma:** `curl` a la web app falla; `az monitor` devuelve 404

**Causa:** límites del emulador: no ejecuta aplicaciones ni implementa Azure Monitor.
**Solución:** ninguna en Topaz. En Azure real, espera 5–10 minutos tras el despliegue para que aparezcan métricas, genera tráfico y amplía el intervalo de consulta si sigue vacío.

---

## 8. Buenas prácticas de verificación

### 8.1. Estrategia por capas

| **Nivel** | **Método** | **Cuándo** | **Topaz** |
|---|---|---|---|
| Inmediato | `terraform state list`, `az resource list -o table`, `plan -detailed-exitcode` | Tras cada `apply` | ✅ |
| Corto plazo | Consultas de configuración por recurso, script `verify-deployment.sh`, prueba de plano de datos | Antes de dar el despliegue por bueno | ✅ (Storage con 8891) |
| Medio plazo | Métricas, logs, health checks HTTP | Primer día de operación | ❌ Solo Azure real |
| Largo plazo | Auditoría de etiquetas y nombrado, Azure Policy, revisión de costes | Semanal / mensual | ⚠️ Solo etiquetas y nombrado |

*Esta tabla resume cómo escalar tus validaciones desde la ejecución local hasta la operación continua.*

### 8.2. Lista de verificación post-despliegue

**✅ Existencia y estado**
- `terraform state list` contiene todos los recursos del `.tf`.
- `az resource list` los devuelve todos (menos grupo y recursos hijos).
- El grupo está en `Succeeded`; ningún recurso en `Failed`.
- `terraform plan -detailed-exitcode` devuelve 0.

**ℹ️ Configuración y etiquetado**
- Ubicación de todos los recursos = la declarada.
- Etiquetas `entorno`, `aplicacion`, `equipo`, `costo` presentes en cada recurso que las admite.
- Valores críticos coinciden: espacio de direcciones, SKU del plan, replicación de Storage.
- Relaciones correctas: la subred cuelga de la VNet, la web app apunta al plan.

**⚠️ Funcionalidad (lo que Topaz permite)**
- Storage: crear un contenedor y subir un blob funciona.
- Los `outputs` devuelven valores no nulos (`terraform output -json | jq`).
- En Azure real, además: la web app responde 200, latencia dentro de límites, sin excepciones en los logs.

**📝 Gobernanza**
- No hay recursos fuera del estado de Terraform ("huérfanos").
- Nombres conforme a la convención `<tipo>-<app>-<entorno>-<instancia>`.
- En Azure real: sin violaciones de Azure Policy y coste acorde al SKU elegido.

### 8.3. Principios

- **Dos fuentes independientes.** Terraform y la CLI hablan con la misma API pero por caminos distintos; si coinciden, el despliegue es real. Nunca valides solo con la herramienta que hizo el cambio.
- **Un script, no una lista de comandos.** Lo que no está en un script con código de salida no se ejecuta la segunda vez.
- **Verifica la configuración, no solo la existencia.** Una VNet con el espacio de direcciones equivocado "existe" perfectamente.
- **Trata el `plan` limpio como prueba de aceptación.** Es la afirmación más fuerte que Terraform puede hacer: código, estado y realidad coinciden.
- **Conoce los límites de tu entorno.** En Topaz, una verificación funcional que falla no siempre es un error; en Azure real, siempre lo es.

---

## 9. Recursos adicionales

### Terraform
- [Comandos `terraform state`](https://developer.hashicorp.com/terraform/cli/commands/state)
- [`plan -detailed-exitcode`](https://developer.hashicorp.com/terraform/cli/commands/plan#detailed-exitcode)
- [Valores de salida (`output`)](https://developer.hashicorp.com/terraform/language/values/outputs)
- [`terraform show -json`](https://developer.hashicorp.com/terraform/cli/commands/show)

### Azure CLI
- [Consultas JMESPath con `--query`](https://learn.microsoft.com/es-es/cli/azure/query-azure-cli)
- [Referencia de `az resource`](https://learn.microsoft.com/es-es/cli/azure/resource)
- [Referencia de `az monitor`](https://learn.microsoft.com/es-es/cli/azure/monitor) (Azure real)
- [Tutorial de JMESPath](https://jmespath.org/tutorial.html)
- [Manual de jq](https://jqlang.github.io/jq/manual/)

### Emulador y automatización
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md): servicios soportados
- [Self-hosted runners en GitHub Actions](https://docs.github.com/actions/hosting-your-own-runners)
- [Agentes self-hosted en Azure DevOps](https://learn.microsoft.com/es-es/azure/devops/pipelines/agents/agents)