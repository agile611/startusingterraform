# 💶 Optimización: coste y escalado como código

> El coste de una plataforma se decide en tres momentos. **Antes** de desplegar: qué tamaño, qué SKU, qué redundancia lleva cada entorno; aquí Terraform es la herramienta ideal porque el `plan` puede traducirse a euros sin tocar Azure. **Durante**: que la capacidad siga a la demanda (escalado con reglas en ambos sentidos, apagado fuera de horario, niveles de almacenamiento). **Después**: que alguien se entere cuando el gasto se desvía (presupuestos, alertas, Advisor) y que las decisiones de compromiso (reservas, *savings plans*) se tomen con datos de uso real. Esta página recorre los tres con Moodle como hilo. En **Topaz** funciona todo lo que es código y plano de gestión: tallaje por entorno, estimación de precios, Infracost, políticas de ciclo de vida de blobs, etiquetas de coste. Lo que toca facturación (presupuestos, reservas) o telemetría de escalado se marca como Azure real, y aun así se valida con `plan`.

**🎯 Objetivos de aprendizaje**
- Parametrizar tamaño, SKU y redundancia por entorno y ver la diferencia de coste en el `plan`.
- Estimar el coste con la API pública de precios de Azure e Infracost, sin credenciales.
- Escribir un autoescalado que sube *y* baja, con perfil por horario, sin oscilaciones.
- Aplicar ahorros estructurales: apagado programado, Spot, niveles de almacenamiento, retención de logs.
- Crear presupuestos que avisan y actúan; entender qué son y qué no son las reservas, y cómo se compran desde Terraform.

> **🔷 Requisitos previos.** [Páginas 1](index.md#pagina-1) a 13 completadas y destruidas, `~/tf-st/providers.tf`, Terraform `>= 1.10`, providers `http` y `azapi`, `jq`, opcionalmente `infracost` (clave gratuita), salida a Internet para `prices.azure.com`, `az account show --query environmentName -o tsv` → `Topaz`.

---

## 1. Dónde se va el dinero

| **Fuga habitual** | **Síntoma** | **Remedio en código** | **Topaz** |
|---|---|---|---|
| Dev con tamaño de pro | La misma `D4s_v5`, GRS y P30 en todos los entornos | Mapa de tallas por entorno (14.2); redundancia y SKU derivados de `var.entorno` | ✅ |
| Recursos encendidos 24×7 | VMs de dev consumiendo noches y fines de semana (≈ 70 % del mes) | `azurerm_dev_test_global_vm_shutdown_schedule`; perfil nocturno de autoescalado a 0/1 | plan ✅ / apply ❌ |
| Escalado solo hacia arriba | El VMSS llegó a 10 instancias en un pico y nunca volvió (el original) | Regla de bajada (14.3) | plan ✅ / apply ❌ |
| Datos fríos en *Hot* | Backups y `moodledata` antiguo a precio de acceso frecuente | `azurerm_storage_management_policy`: Cool a 30 d, Archive a 180 d, borrar a 365 d | ✅ (plano de gestión de Storage) |
| Logs sin límite | Log Analytics con 2 años de retención y sin tope diario | `retention_in_days = 30`, `daily_quota_gb`, tablas *Basic* para logs de acceso | ✅ |
| Huérfanos | Discos, IPs públicas y snapshots sin dueño tras borrar VMs | Todo en Terraform (nada a mano); etiquetas obligatorias; `az graph query` semanal buscando discos *Unattached* | ✅ (parcial) |
| Pagar tarifa bajo demanda por carga estable | El servidor MySQL y la VM base llevan un año encendidos | Reserva o *savings plan* (14.6) sobre la línea base, tras medir | ❌ |

---

## 2. Antes de desplegar: tallar por entorno y poner precio al `plan`

La decisión de coste más barata es la que se toma en el código. Un solo mapa de tallas evita que dev herede el dimensionamiento de pro, y dos herramientas ponen euros al `plan` sin credenciales de Azure: la **API pública de precios** (`prices.azure.com`, sin autenticación) y **Infracost**, que lee el plan en JSON.

```hcl
# tallas.tf — una fuente de verdad por entorno
variable "entorno" {
  type = string
  validation { condition = contains(["dev", "pre", "pro"], var.entorno), error_message = "dev, pre o pro." }
}
locals {
  tallas = {
    dev = { vm = "Standard_B2s",   instancias = { min = 1, max = 2 }, replicacion = "LRS", tier_blob = "Cool", la_retencion = 30, la_cuota_gb = 1,  mysql = "B_Standard_B1ms",  apagado = true  }
    pre = { vm = "Standard_B2ms",  instancias = { min = 1, max = 3 }, replicacion = "ZRS", tier_blob = "Hot",  la_retencion = 30, la_cuota_gb = 2,  mysql = "GP_Standard_D2ds_v4", apagado = true  }
    pro = { vm = "Standard_D2s_v5", instancias = { min = 2, max = 8 }, replicacion = "GZRS", tier_blob = "Hot", la_retencion = 90, la_cuota_gb = -1, mysql = "GP_Standard_D4ds_v4", apagado = false }
  }
  t = local.tallas[var.entorno]
  tags = {
    proyecto = "moodle", entorno = var.entorno, gestion = "terraform"
    centro_coste = var.centro_coste          # obligatoria: sin ella no hay showback
    propietario  = var.propietario
    caducidad    = var.entorno == "pro" ? "nunca" : timeadd(plantimestamp(), "720h")   # dev muere en 30 días si nadie lo renueva
  }
}
resource "azurerm_storage_account" "moodledata" {
  # …
  account_replication_type = local.t.replicacion
  access_tier              = local.t.tier_blob
  tags                     = local.tags
}
resource "azurerm_log_analytics_workspace" "moodle" {
  # …
  retention_in_days = local.t.la_retencion
  daily_quota_gb    = local.t.la_cuota_gb     # -1 = sin tope, solo en pro
}

# precios.tf — la API pública de precios: sin auth, funciona desde Topaz si hay Internet
data "http" "precio_vm" {
  url = "https://prices.azure.com/api/retail/prices?currencyCode='EUR'&$filter=${urlencode("armRegionName eq '${var.location}' and armSkuName eq '${local.t.vm}' and serviceName eq 'Virtual Machines' and priceType eq 'Consumption'")}"
}
data "http" "precio_vm_reserva" {
  url = "https://prices.azure.com/api/retail/prices?currencyCode='EUR'&$filter=${urlencode("armRegionName eq '${var.location}' and armSkuName eq '${local.t.vm}' and serviceName eq 'Virtual Machines' and priceType eq 'Reservation' and reservationTerm eq '1 Year'")}"
}
locals {
  linux_od  = [for i in jsondecode(data.http.precio_vm.response_body).Items : i
               if !endswith(i.productName, "Windows") && !strcontains(i.meterName, "Spot") && !strcontains(i.meterName, "Low Priority")][0]
  linux_1y  = [for i in jsondecode(data.http.precio_vm_reserva.response_body).Items : i if !endswith(i.productName, "Windows")][0]
  hora_od   = local.linux_od.retailPrice
  mes_od    = local.hora_od * 730
  mes_1y    = local.linux_1y.retailPrice / 12                      # la API da el total del término
  ahorro_1y = 1 - local.mes_1y / local.mes_od
  mes_apagado = local.t.apagado ? local.mes_od * (12 * 5) / (24 * 7) : local.mes_od   # 12 h × 5 días
}
output "coste_estimado_vm" {
  value = {
    sku            = local.t.vm
    eur_mes_24x7   = format("%.2f", local.mes_od * local.t.instancias.min)
    eur_mes_horario = format("%.2f", local.mes_apagado * local.t.instancias.min)
    eur_mes_reserva_1y = format("%.2f", local.mes_1y * local.t.instancias.min)
    ahorro_reserva = format("%.0f %%", local.ahorro_1y * 100)
  }
}
```

```bash
# Infracost: coste del plan completo, y la diferencia entre entornos o entre PR y main. Sin credenciales de Azure.
infracost auth login                                    # una vez; clave gratuita
infracost breakdown --path . --terraform-var entorno=dev
infracost breakdown --path . --terraform-var entorno=pro --format json --out-file pro.json
infracost diff --path . --terraform-var entorno=dev --compare-to pro.json
# En el pipeline (página 12): infracost comment github --path plan.json … publica el delta de coste en la PR
# Recurso de pago por uso (blobs, egress) → "usage file": infracost breakdown --usage-file infracost-usage.yml
```

---

## 3. Escalado automático: subir, bajar y no oscilar

El bloque del original crece con CPU > 75 % y no tiene ninguna regla de bajada: tras el primer pico el grupo se queda en el máximo hasta que alguien lo baje a mano. Además, `cooldown = PT1M` con ventana de 5 min produce oscilación (*flapping*). Las reglas correctas son **asimétricas**: subir rápido con un umbral alto, bajar despacio con un umbral claramente inferior, y dejar hueco entre ambos.

```hcl
resource "azurerm_linux_virtual_machine_scale_set" "web" {
  name                = "vmss-moodle-web-${var.entorno}"
  resource_group_name = azurerm_resource_group.moodle.name
  location            = azurerm_resource_group.moodle.location
  sku                 = local.t.vm
  instances           = local.t.instancias.min
  admin_username      = "moodleadmin"
  admin_ssh_key { username = "moodleadmin", public_key = var.ssh_public_key }
  source_image_reference { publisher = "Canonical", offer = "ubuntu-24_04-lts", sku = "server", version = "latest" }
  os_disk { caching = "ReadWrite", storage_account_type = var.entorno == "pro" ? "Premium_LRS" : "StandardSSD_LRS" }
  network_interface {
    name    = "nic"
    primary = true
    ip_configuration { name = "ipcfg", primary = true, subnet_id = module.red.subnet_ids["web"] }
  }
  upgrade_mode = "Rolling"
  rolling_upgrade_policy { max_batch_instance_percent = 50, max_unhealthy_instance_percent = 50, max_unhealthy_upgraded_instance_percent = 50, pause_time_between_batches = "PT1M" }
  # Spot en dev/pre: hasta ~90 % más barato; en pro, nunca para la capa web
  priority        = var.entorno == "pro" ? "Regular" : "Spot"
  eviction_policy = var.entorno == "pro" ? null : "Delete"
  max_bid_price   = var.entorno == "pro" ? null : -1     # -1 = hasta el precio bajo demanda
  lifecycle { ignore_changes = [instances] }             # el autoescalado manda: Terraform no debe "corregir" la cuenta
  tags = local.tags
}

resource "azurerm_monitor_autoscale_setting" "web" {
  name                = "autoscale-vmss-moodle-web"
  resource_group_name = azurerm_resource_group.moodle.name
  location            = azurerm_resource_group.moodle.location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.web.id
  enabled             = true

  profile {
    name = "por-defecto"
    capacity { minimum = local.t.instancias.min, default = local.t.instancias.min, maximum = local.t.instancias.max }

    rule {                                               # SUBIR: rápido, umbral alto
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_namespace   = "microsoft.compute/virtualmachinescalesets"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.web.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"                     # 10 min sostenidos, no un pico
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 70
      }
      scale_action { direction = "Increase", type = "ChangeCount", value = "1", cooldown = "PT5M" }
    }
    rule {                                               # BAJAR: despacio, umbral bajo (hueco de 40 puntos evita el flapping)
      metric_trigger {
        metric_name        = "Percentage CPU"
        metric_namespace   = "microsoft.compute/virtualmachinescalesets"
        metric_resource_id = azurerm_linux_virtual_machine_scale_set.web.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT10M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 30
      }
      scale_action { direction = "Decrease", type = "ChangeCount", value = "1", cooldown = "PT10M" }
    }
  }

  dynamic "profile" {                                     # dev/pre: fuera de horario, a la mínima expresión
    for_each = local.t.apagado ? [1] : []
    content {
      name = "noche-y-finde"
      capacity { minimum = 0, default = 0, maximum = 1 }
      recurrence {
        timezone = "Romance Standard Time"
        days     = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"]
        hours    = [20]
        minutes  = [0]
      }
    }
  }
  dynamic "profile" {
    for_each = local.t.apagado ? [1] : []
    content {
      name = "horario-laboral"
      capacity { minimum = local.t.instancias.min, default = local.t.instancias.min, maximum = local.t.instancias.max }
      recurrence { timezone = "Romance Standard Time", days = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday"], hours = [8], minutes = [0] }
    }
  }

  notification {
    email { send_to_subscription_administrator = false, custom_emails = [var.email_plataforma] }
    webhook { service_uri = var.webhook_teams }
  }
  predictive { scale_mode = var.entorno == "pro" ? "Enabled" : "Disabled", look_ahead_time = "PT15M" }   # pro: anticipa el patrón diario
}
```

> **🔷 Escalar por la métrica correcta.** La CPU es un proxy. Para Moodle detrás de un Application Gateway o Load Balancer suele ser mejor disparar por `metric_name = "TotalRequests"` del gateway (`metric_resource_id` distinto al `target_resource_id`) o por profundidad de cola si hay procesamiento asíncrono. Y recuerda: una VM sola no se autoescala; el recurso objetivo es un VMSS, un App Service Plan o un pool de AKS.

---

## 4. Ahorro estructural: apagar, enfriar, caducar

```hcl
# Apagado programado de VMs sueltas (bastión, jump host de dev). Deallocate = no se paga cómputo (sí disco e IP)
resource "azurerm_dev_test_global_vm_shutdown_schedule" "bastion" {
  count                 = local.t.apagado ? 1 : 0
  virtual_machine_id    = azurerm_linux_virtual_machine.bastion.id
  location              = azurerm_resource_group.moodle.location
  enabled               = true
  daily_recurrence_time = "2000"
  timezone              = "Romance Standard Time"
  notification_settings { enabled = true, time_in_minutes = 30, email = var.email_plataforma }
}

# Ciclo de vida de blobs: moodledata y backups envejecen hacia tiers más baratos. ✅ Topaz (plano de gestión)
resource "azurerm_storage_management_policy" "moodledata" {
  storage_account_id = azurerm_storage_account.moodledata.id
  rule {
    name    = "enfriar-y-caducar"
    enabled = true
    filters { blob_types = ["blockBlob"], prefix_match = ["moodledata/filedir/", "backups/"] }
    actions {
      base_blob {
        tier_to_cool_after_days_since_last_access_time_greater_than    = 30
        tier_to_archive_after_days_since_last_access_time_greater_than = 180
        delete_after_days_since_modification_greater_than              = var.entorno == "pro" ? 1095 : 90
      }
      snapshot { delete_after_days_since_creation_greater_than = 30 }
      version  { delete_after_days_since_creation_greater_than = 30 }
    }
  }
}
# Para que "last access time" funcione, activa el seguimiento en la cuenta:
#   blob_properties { last_access_time_enabled = true }

# IPs públicas e discos: que no sobrevivan a su VM
#   - IP pública en el LB/App Gateway, no en cada VM; sku Standard (Basic se retira)
#   - os_disk del VMSS: StandardSSD en dev; Premium solo en pro
#   - Sin "azurerm_managed_disk" sueltos con create_option = "Empty" que nadie adjunta

# Etiquetas de coste obligatorias: bloquea el plan si faltan
variable "centro_coste" {
  type = string
  validation { condition = can(regex("^CC-[0-9]{4}$", var.centro_coste)), error_message = "Formato CC-0000." }
}
check "todo_etiquetado" {
  assert {
    condition     = alltrue([for r in [azurerm_storage_account.moodledata, azurerm_log_analytics_workspace.moodle] : contains(keys(r.tags), "centro_coste")])
    error_message = "Hay recursos sin centro_coste: no aparecerán en el showback."
  }
}
```

---

## 5. Vigilar: presupuestos que avisan y actúan

El recurso del original no existe con ese nombre y su `filter` es una cadena JSON mal formada. Los recursos reales son `azurerm_consumption_budget_resource_group` y `azurerm_consumption_budget_subscription`; exigen `time_period` y al menos una `notification`. Un presupuesto **no detiene el gasto**: avisa. Para actuar, la notificación dispara un grupo de acción que puede llamar a un runbook o Logic App que apague dev.

```hcl
resource "azurerm_monitor_action_group" "finops" {
  name                = "ag-finops-${var.entorno}"
  resource_group_name = azurerm_resource_group.moodle.name
  short_name          = "finops"
  email_receiver { name = "plataforma", email_address = var.email_plataforma }
  webhook_receiver { name = "teams", service_uri = var.webhook_teams }
  # Para actuar: automation_runbook_receiver (deallocate de dev) o logic_app_receiver
}

resource "azurerm_consumption_budget_resource_group" "moodle" {
  name              = "bud-moodle-${var.entorno}-mensual"
  resource_group_id = azurerm_resource_group.moodle.id
  amount            = local.presupuesto_mensual[var.entorno]      # { dev = 150, pre = 400, pro = 2500 }
  time_grain        = "Monthly"
  time_period {
    start_date = formatdate("YYYY-MM-01'T'00:00:00Z", plantimestamp())   # primer día del mes en curso
    # sin end_date: 10 años por defecto
  }
  filter {                                                         # bloque, no cadena. En un budget de RG es opcional: afina por etiqueta
    tag { name = "proyecto", values = ["moodle"] }
  }
  notification {                                                   # 80 % del gasto real: aviso
    enabled        = true
    threshold      = 80
    operator       = "GreaterThan"
    threshold_type = "Actual"
    contact_emails = [var.email_plataforma]
    contact_groups = [azurerm_monitor_action_group.finops.id]
  }
  notification {                                                   # 100 % previsto a fin de mes: actuar antes de llegar
    enabled        = true
    threshold      = 100
    operator       = "GreaterThan"
    threshold_type = "Forecasted"
    contact_groups = [azurerm_monitor_action_group.finops.id]
    contact_roles  = ["Owner"]
  }
  lifecycle { ignore_changes = [time_period[0].start_date] }       # si no, cada mes el plan quiere cambiar la fecha
}

# Presupuesto global de la suscripción, por etiqueta centro_coste (showback)
resource "azurerm_consumption_budget_subscription" "plataforma" {
  name            = "bud-suscripcion-mensual"
  subscription_id = data.azurerm_subscription.actual.id
  amount          = 6000
  time_grain      = "Monthly"
  time_period { start_date = "2026-10-01T00:00:00Z" }
  notification { threshold = 90, operator = "GreaterThan", threshold_type = "Forecasted", contact_groups = [azurerm_monitor_action_group.finops.id] }
}

# Advisor: lo que Azure ya sabe de tu suscripción (VMs infrautilizadas, discos sueltos, reservas recomendadas)
data "azurerm_advisor_recommendations" "coste" {
  filter_by_category = ["Cost"]
}
output "recomendaciones_coste" { value = [for r in data.azurerm_advisor_recommendations.coste.recommendations : "${r.impact}: ${r.description}"] }
```

---

## 6. Reservas y *savings plans*: comprometerse con datos

El bloque del original no puede funcionar: no existe `azurerm_reservation` en el provider, y una reserva no se "asigna" a un grupo de recursos: es una compra financiera de ámbito *tenant* cuyo `billingScopeId` es una suscripción (o un perfil de facturación). Terraform puede comprarla mediante `azapi_resource` sobre `Microsoft.Capacity/reservationOrders`, pero conviene tratarla como lo que es: **un contrato de 1 o 3 años que no se destruye con `terraform destroy`** (solo se puede intercambiar o devolver con límites). La regla: primero medir la línea base con Advisor y Cost Management, después comprometer solo esa base, y dejar el pico al autoescalado bajo demanda.

| **Opción** | **A qué se aplica** | **Ahorro típico** | **Cuándo** |
|---|---|---|---|
| Bajo demanda | Todo | 0 % | Pico del autoescalado, dev/pre, cargas que cambian |
| Spot | VMs/VMSS interrumpibles | 60–90 % | Dev, pre, procesos batch, runners de CI |
| *Savings plan* (cómputo) | €/hora comprometidos en cualquier cómputo, región y familia | hasta ~65 % | Gasto estable pero con SKUs que cambian; flexibilidad sobre descuento |
| Reserva | SKU (o familia) concreta en una región: VM, MySQL Flexible, Storage, App Service… | hasta ~72 % (3 años) | Línea base de pro que no va a moverse: el servidor MySQL, las N instancias mínimas del VMSS |

```hcl
# 1. Medir antes de firmar: qué recomienda Azure con 30 días de uso real (solo Azure real)
az consumption reservation recommendation list --scope Shared --query "[?properties.skuName=='Standard_D2s_v5'].{sku:properties.skuName, cantidad:properties.recommendedQuantity, ahorro:properties.netSavings, termino:properties.term}" -o table

# 2. Comprar desde Terraform: azapi sobre Microsoft.Capacity (ámbito tenant). Estado propio, separado del de Moodle.
terraform {
  required_providers { azapi = { source = "Azure/azapi", version = "~> 2.0" } }
}
provider "azapi" {}

variable "reservas" {
  type = map(object({ sku = string, region = string, cantidad = number, termino = string, facturacion = string }))
  default = {
    web-pro = { sku = "Standard_D2s_v5",   region = "westeurope", cantidad = 2, termino = "P1Y", facturacion = "Monthly" }
  }
  validation { condition = alltrue([for r in var.reservas : contains(["P1Y", "P3Y"], r.termino)]), error_message = "P1Y o P3Y." }
}
data "azurerm_subscription" "actual" {}

# Precio y cálculo previos: la misma API que usa el portal. El "plan" aquí es literal: cuánto vas a pagar.
resource "azapi_resource_action" "calculo" {
  for_each    = var.reservas
  type        = "Microsoft.Capacity@2022-11-01"
  resource_id = "/providers/Microsoft.Capacity"
  action      = "calculatePrice"
  method      = "POST"
  body = {
    sku      = { name = each.value.sku }
    location = each.value.region
    properties = {
      reservedResourceType = "VirtualMachines"
      billingScopeId       = data.azurerm_subscription.actual.id       # una suscripción, no un grupo de recursos
      term                 = each.value.termino
      billingPlan          = each.value.facturacion
      quantity             = each.value.cantidad
      displayName          = "res-moodle-${each.key}"
      appliedScopeType     = "Shared"                                   # el descuento flota a cualquier VM del tenant que encaje
      renew                = false
      reservedResourceProperties = { instanceFlexibility = "On" }       # cualquier tamaño de la familia Dsv5
    }
  }
  response_export_values = ["properties.billingCurrencyTotal", "properties.reservationOrderId"]
}
output "precio_reservas" {
  value = { for k, c in azapi_resource_action.calculo : k => c.output.properties.billingCurrencyTotal }
}

# La compra en sí. Sin prevent_destroy no hay marcha atrás igualmente: Azure no "borra" una reserva; se devuelve o intercambia.
resource "azapi_resource" "reserva" {
  for_each  = var.comprar ? var.reservas : {}                           # var.comprar = false por defecto: el plan enseña el coste, el apply lo firma
  type      = "Microsoft.Capacity/reservationOrders@2022-11-01"
  name      = azapi_resource_action.calculo[each.key].output.properties.reservationOrderId   # el id lo asigna calculatePrice
  parent_id = "/"
  body      = azapi_resource_action.calculo[each.key].body
  lifecycle { prevent_destroy = true, ignore_changes = [body] }
}
```

> ⚠️ **Una reserva es dinero, no infraestructura.** Quien la ejecuta necesita el rol *Reservation Purchaser* (o *Owner*) sobre la suscripción de facturación; la identidad de `apply` de la [página 12](index.md#pagina-12) no debe tenerlo. Mantén las reservas en un estado y un pipeline aparte, con aprobación de quien firma el presupuesto, y con `var.comprar` a `false` por defecto para que un `apply` rutinario nunca compre nada. La cobertura y el uso se revisan cada mes: una reserva al 60 % de utilización es dinero tirado.

---

## 7. Laboratorio en Topaz

Todo lo que es código se prueba aquí: el mapa de tallas, la estimación con la API de precios, Infracost, la política de ciclo de vida de blobs y los guardarraíles de etiquetas. El autoescalado y el presupuesto se validan con `plan`: Topaz no emite métricas ni factura, pero Terraform sí comprueba la sintaxis y los tipos.

```bash
mkdir -p ~/tf-cost && cd ~/tf-cost && cp ~/tf-st/providers.tf .

# ─── 1. El mismo código, tres facturas: tallas por entorno ──────────────────────
cat > main.tf <<'EOF'
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
    http    = { source = "hashicorp/http",    version = "~> 3.4" }
  }
}
variable "entorno"      { type = string, default = "dev" }
variable "location"     { type = string, default = "eastus" }
variable "centro_coste" { type = string, default = "CC-1234"
  validation { condition = can(regex("^CC-[0-9]{4}$", var.centro_coste)), error_message = "Formato CC-0000." } }
locals {
  tallas = {
    dev = { vm = "Standard_B2s",    replicacion = "LRS",  tier_blob = "Cool", la_retencion = 30, la_cuota_gb = 1,  apagado = true  }
    pre = { vm = "Standard_B2ms",   replicacion = "ZRS",  tier_blob = "Hot",  la_retencion = 30, la_cuota_gb = 2,  apagado = true  }
    pro = { vm = "Standard_D2s_v5", replicacion = "GZRS", tier_blob = "Hot",  la_retencion = 90, la_cuota_gb = -1, apagado = false }
  }
  t    = local.tallas[var.entorno]
  tags = { proyecto = "moodle", entorno = var.entorno, gestion = "terraform", centro_coste = var.centro_coste
           caducidad = var.entorno == "pro" ? "nunca" : timeadd(plantimestamp(), "720h") }
}
resource "azurerm_resource_group" "cost" {
  name     = "rg-cost-lab-${var.entorno}"
  location = var.location
  tags     = local.tags
  lifecycle { ignore_changes = [tags] }
}
resource "azurerm_storage_account" "moodledata" {
  name                          = "stcost${var.entorno}${substr(md5(azurerm_resource_group.cost.id), 0, 6)}"
  resource_group_name           = azurerm_resource_group.cost.name
  location                      = azurerm_resource_group.cost.location
  account_tier                  = "Standard"
  account_replication_type      = local.t.replicacion
  access_tier                   = local.t.tier_blob
  min_tls_version               = "TLS1_2"
  public_network_access_enabled = false
  blob_properties { last_access_time_enabled = true }
  tags = local.tags
}
resource "azurerm_storage_management_policy" "moodledata" {
  storage_account_id = azurerm_storage_account.moodledata.id
  rule {
    name    = "enfriar-y-caducar"
    enabled = true
    filters { blob_types = ["blockBlob"], prefix_match = ["moodledata/filedir/", "backups/"] }
    actions {
      base_blob {
        tier_to_cool_after_days_since_last_access_time_greater_than    = 30
        tier_to_archive_after_days_since_last_access_time_greater_than = 180
        delete_after_days_since_modification_greater_than              = var.entorno == "pro" ? 1095 : 90
      }
      snapshot { delete_after_days_since_creation_greater_than = 30 }
    }
  }
}
resource "azurerm_log_analytics_workspace" "moodle" {
  name                = "law-cost-${var.entorno}"
  resource_group_name = azurerm_resource_group.cost.name
  location            = azurerm_resource_group.cost.location
  sku                 = "PerGB2018"
  retention_in_days   = local.t.la_retencion
  daily_quota_gb      = local.t.la_cuota_gb
  tags                = local.tags
}
check "todo_etiquetado" {
  assert {
    condition     = alltrue([for r in [azurerm_storage_account.moodledata, azurerm_log_analytics_workspace.moodle] : contains(keys(r.tags), "centro_coste")])
    error_message = "Hay recursos sin centro_coste."
  }
}
EOF
terraform init
for e in dev pre pro; do echo "── $e"; terraform plan -var entorno=$e -no-color | grep -E 'account_replication_type|access_tier|retention_in_days|daily_quota_gb' ; done
terraform apply -auto-approve                                   # dev
az storage account management-policy show --account-name $(terraform output -raw 2>/dev/null || az storage account list -g rg-cost-lab-dev --query "[0].name" -o tsv) -g rg-cost-lab-dev --query "policy.rules[0].definition.actions.baseBlob" -o json
terraform plan -var centro_coste=marketing                      # Error: Invalid value for variable — sin centro de coste no hay despliegue

# ─── 2. Poner precio al plan con la API pública (sin credenciales; requiere Internet) ───
cat > precios.tf <<'EOF'
data "http" "precio_vm" {
  url = "https://prices.azure.com/api/retail/prices?currencyCode='EUR'&$filter=${urlencode("armRegionName eq 'westeurope' and armSkuName eq '${local.t.vm}' and serviceName eq 'Virtual Machines' and priceType eq 'Consumption'")}"
}
data "http" "precio_vm_1y" {
  url = "https://prices.azure.com/api/retail/prices?currencyCode='EUR'&$filter=${urlencode("armRegionName eq 'westeurope' and armSkuName eq '${local.t.vm}' and serviceName eq 'Virtual Machines' and priceType eq 'Reservation' and reservationTerm eq '1 Year'")}"
}
locals {
  od  = [for i in jsondecode(data.http.precio_vm.response_body).Items : i if !endswith(i.productName, "Windows") && !strcontains(i.meterName, "Spot") && !strcontains(i.meterName, "Low Priority")][0]
  r1y = [for i in jsondecode(data.http.precio_vm_1y.response_body).Items : i if !endswith(i.productName, "Windows")][0]
  mes_od = local.od.retailPrice * 730
  mes_1y = local.r1y.retailPrice / 12
}
output "coste_vm" {
  value = {
    sku              = local.t.vm
    eur_mes_24x7     = format("%.2f", local.mes_od)
    eur_mes_12x5     = format("%.2f", local.mes_od * 60 / 168)
    eur_mes_reserva  = format("%.2f", local.mes_1y)
    ahorro_apagado   = format("%.0f %%", (1 - 60 / 168) * 100)
    ahorro_reserva   = format("%.0f %%", (1 - local.mes_1y / local.mes_od) * 100)
  }
}
EOF
terraform apply -auto-approve -refresh-only >/dev/null; terraform output coste_vm       # dev: B2s
terraform plan -var entorno=pro -no-color | grep -A7 'coste_vm'                            # pro: D2s_v5, ~4× más

# ─── 3. Infracost: el plan completo, en euros, y el delta entre entornos ─────────
command -v infracost >/dev/null && {
  infracost breakdown --path . --terraform-var entorno=dev
  infracost breakdown --path . --terraform-var entorno=pro --format json --out-file /tmp/pro.json
  infracost diff --path . --terraform-var entorno=dev --compare-to /tmp/pro.json
} || echo "(infracost no instalado: se omite)"

# ─── 4. Autoescalado y presupuesto: validar sin métricas ni factura ─────────────
cat > escalado.tf <<'EOF'
variable "validar_escalado" { type = bool, default = false }
resource "azurerm_linux_virtual_machine_scale_set" "web" {
  count               = var.validar_escalado ? 1 : 0
  name                = "vmss-cost-web"
  resource_group_name = azurerm_resource_group.cost.name
  location            = azurerm_resource_group.cost.location
  sku                 = local.t.vm
  instances           = 1
  admin_username      = "moodleadmin"
  admin_ssh_key { username = "moodleadmin", public_key = file("~/.ssh/id_ed25519.pub") }
  source_image_reference { publisher = "Canonical", offer = "ubuntu-24_04-lts", sku = "server", version = "latest" }
  os_disk { caching = "ReadWrite", storage_account_type = "StandardSSD_LRS" }
  network_interface {
    name = "nic"; primary = true
    ip_configuration { name = "ipcfg", primary = true, subnet_id = azurerm_subnet.web[0].id }
  }
  priority        = "Spot"
  eviction_policy = "Delete"
  max_bid_price   = -1
  lifecycle { ignore_changes = [instances] }
}
resource "azurerm_virtual_network" "web" { count = var.validar_escalado ? 1 : 0
  name = "vnet-cost", address_space = ["10.200.0.0/16"], location = azurerm_resource_group.cost.location, resource_group_name = azurerm_resource_group.cost.name }
resource "azurerm_subnet" "web" { count = var.validar_escalado ? 1 : 0
  name = "web", resource_group_name = azurerm_resource_group.cost.name, virtual_network_name = azurerm_virtual_network.web[0].name, address_prefixes = ["10.200.1.0/24"] }
resource "azurerm_monitor_autoscale_setting" "web" {
  count               = var.validar_escalado ? 1 : 0
  name                = "autoscale-vmss-cost-web"
  resource_group_name = azurerm_resource_group.cost.name
  location            = azurerm_resource_group.cost.location
  target_resource_id  = azurerm_linux_virtual_machine_scale_set.web[0].id
  profile {
    name = "por-defecto"
    capacity { minimum = 1, default = 1, maximum = 3 }
    rule {
      metric_trigger { metric_name = "Percentage CPU", metric_namespace = "microsoft.compute/virtualmachinescalesets", metric_resource_id = azurerm_linux_virtual_machine_scale_set.web[0].id, time_grain = "PT1M", statistic = "Average", time_window = "PT10M", time_aggregation = "Average", operator = "GreaterThan", threshold = 70 }
      scale_action { direction = "Increase", type = "ChangeCount", value = "1", cooldown = "PT5M" }
    }
    rule {
      metric_trigger { metric_name = "Percentage CPU", metric_namespace = "microsoft.compute/virtualmachinescalesets", metric_resource_id = azurerm_linux_virtual_machine_scale_set.web[0].id, time_grain = "PT1M", statistic = "Average", time_window = "PT10M", time_aggregation = "Average", operator = "LessThan", threshold = 30 }
      scale_action { direction = "Decrease", type = "ChangeCount", value = "1", cooldown = "PT10M" }
    }
  }
}
resource "azurerm_consumption_budget_resource_group" "cost" {
  count             = var.validar_escalado ? 1 : 0
  name              = "bud-cost-lab"
  resource_group_id = azurerm_resource_group.cost.id
  amount            = 150
  time_grain        = "Monthly"
  time_period { start_date = formatdate("YYYY-MM-01'T'00:00:00Z", plantimestamp()) }
  notification { threshold = 80,  operator = "GreaterThan", threshold_type = "Actual",     contact_emails = ["plataforma@ejemplo.edu"] }
  notification { threshold = 100, operator = "GreaterThan", threshold_type = "Forecasted", contact_emails = ["plataforma@ejemplo.edu"] }
  lifecycle { ignore_changes = [time_period[0].start_date] }
}
EOF
terraform validate && terraform plan -var validar_escalado=true -no-color | grep -E "Plan:|Increase|Decrease|Forecasted"
#   Plan: N to add — sintaxis y referencias correctas. En Topaz, el VMSS y la VNet aplican; el autoscale y el budget
#   dependen de Azure Monitor y Consumption, que el emulador no implementa: el apply se detiene ahí (compruébalo si quieres).
# Quita la regla de bajada y observa que el plan sigue siendo válido: Terraform no sabe que el diseño es malo. Tú sí.

# ─── 5. Huérfanos: buscar lo que nadie gestiona ────────────────────────────────
az disk list --query "[?diskState=='Unattached'].{n:name,gb:diskSizeGb,rg:resourceGroup}" -o table          # en Topaz: vacío o lo que hayas creado a mano
az network public-ip list --query "[?ipConfiguration==null].{n:name,rg:resourceGroup}" -o table
az resource list --query "[?tags.centro_coste==null].{n:name,t:type}" -o table                             # sin centro de coste = sin dueño

# ─── 6. Limpiar ────────────────────────────────────────────────────────────────
terraform destroy -auto-approve
```

```bash
# ─── Solo Azure real: ver el ciclo completo ─────────────────────────────────────
terraform apply -auto-approve -var validar_escalado=true -var entorno=dev
# Generar carga y observar el autoescalado (10-15 min hasta la primera acción):
az vmss list-instances -g rg-cost-lab-dev -n vmss-cost-web --query "length(@)"
az monitor autoscale show -g rg-cost-lab-dev -n autoscale-vmss-cost-web --query "profiles[0].rules[].{dir:scaleAction.direction, umbral:metricTrigger.threshold}" -o table
# Historial: qué regla disparó y cuándo
az monitor activity-log list -g rg-cost-lab-dev --offset 2h --query "[?category.value=='Autoscale'].{t:eventTimestamp, op:operationName.value}" -o table
# Presupuesto y gasto real hasta hoy
az consumption budget list -g rg-cost-lab-dev --query "[].{n:name, limite:amount, gastado:currentSpend.amount}" -o table
az costmanagement query --type ActualCost --timeframe MonthToDate --scope "/subscriptions/$SUB/resourceGroups/rg-cost-lab-dev" \
  --dataset-aggregation '{"total":{"name":"PreTaxCost","function":"Sum"}}' --dataset-grouping name=ResourceType type=Dimension -o table
# Advisor: lo que Azure ya sabe
az advisor recommendation list --category Cost --query "[].{impacto:impact, que:shortDescription.problem, recurso:resourceMetadata.resourceId}" -o table
# Reservas: recomendación con uso real, cálculo de precio y (solo si está aprobado) compra desde el estado aparte
az consumption reservation recommendation list --scope Shared -o table
```

---

## 8. Errores comunes

> ⚠️ **Solución de problemas**
>
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | *The provider hashicorp/azurerm does not support resource type "azurerm_reservation"* (original) | No existe. Las reservas se compran con `azapi_resource` sobre `Microsoft.Capacity/reservationOrders`, en un estado aparte, o desde el portal/CLI |
> | *The provider … does not support resource type "azurerm_consumption_budget"* (original) | Los recursos son `azurerm_consumption_budget_resource_group` y `…_subscription`. `filter` es un bloque, no una cadena; `time_period` y `notification` son obligatorios |
> | El VMSS llegó al máximo y nunca baja | Solo hay regla *Increase* (original). Añade la de *Decrease* con umbral claramente inferior y `cooldown` más largo |
> | El grupo sube y baja cada pocos minutos (*flapping*) | Umbrales demasiado cercanos (75/70) o `cooldown = PT1M`. Hueco de ≥ 30 puntos, `time_window ≥ PT10M`, `cooldown` de 5/10 min. Azure ya evita el *flapping* estimando la métrica tras la bajada: si la estimación dispararía una subida, no baja |
> | Cada `plan` quiere cambiar `instances` del VMSS | El autoescalado cambió la cuenta y Terraform quiere "corregirla". `lifecycle { ignore_changes = [instances] }` |
> | Cada mes el `plan` quiere cambiar `start_date` del presupuesto | `plantimestamp()` cambia. `ignore_changes = [time_period[0].start_date]` o una fecha fija |
> | *start_date must be the first of the month and not more than 12 months in the past* | Consumption exige día 1 y una fecha reciente. `formatdate("YYYY-MM-01'T'00:00:00Z", …)` |
> | El presupuesto se superó y nada se apagó | Un presupuesto solo notifica. Para actuar, `contact_groups` hacia un `azurerm_monitor_action_group` con `automation_runbook_receiver` o `logic_app_receiver`. Y las alertas de coste llegan con 8–24 h de retraso: no sirven como cortafuegos en tiempo real |
> | La API de precios devuelve varios *Items* y el `[0]` coge Windows o Spot | Un SKU tiene meters Linux, Windows, Spot y Low Priority. Filtra `productName` y `meterName` como en 14.2; comprueba `unitOfMeasure = "1 Hour"` |
> | *Error making request* en `data "http"` desde Topaz | Sin salida a Internet. La API de precios es pública pero externa. Cachea el JSON en el repo o marca el output como opcional con `try()` |
> | Infracost muestra 0 € en Storage y Log Analytics | Son recursos por uso: sin un *usage file* Infracost no sabe cuántos GB. `infracost breakdown --sync-usage-file --usage-file infracost-usage.yml` y rellena los valores |
> | La política de ciclo de vida no mueve nada a Cool | Las reglas por *last access* exigen `blob_properties { last_access_time_enabled = true }`; la ejecución es diaria y puede tardar 24–48 h. Y solo aplica a `blockBlob` |
> | *Spot VM evicted* y el sitio cae | Spot es para capacidad interrumpible. Nunca en pro para la capa web; en dev, acéptalo (o mezcla: `instances` base Regular + `spot_restore`) |
> | *AuthorizationFailed* al comprar la reserva | Falta *Reservation Purchaser* u *Owner* en la suscripción de facturación. Es correcto que la identidad de apply de Moodle no lo tenga: las reservas van en su pipeline con su aprobador |
> | Reserva al 40 % de utilización | Se compró sobre el pico, o los SKUs cambiaron. `instanceFlexibility = "On"` y ámbito *Shared* dan margen; intercambia o valora un *savings plan*. Compra solo la línea base y déjale el pico al autoescalado |
> | `terraform destroy` "borró" la reserva del estado pero sigue facturando | Azure no elimina reservas: el DELETE no existe. Es un contrato. Devolución (con límite anual) o intercambio desde el portal; `prevent_destroy` para que nadie lo intente |

---

## 9. Autoevaluación

1. **¿Qué falla en el autoescalado del original aunque el `plan` sea válido?**
   Solo tiene regla de subida: tras el primer pico el grupo se queda en el máximo. Y `cooldown` de 1 min con ventana de 5 provoca oscilación. Terraform valida sintaxis, no diseño.
2. **¿Por qué los umbrales de subida y bajada no deben ser simétricos?**
   Al bajar una instancia, la carga se reparte entre menos y la CPU sube. Si el umbral de bajada está cerca del de subida, la bajada dispara una subida. Hueco amplio y `cooldown` largo en la bajada.
3. **¿Por qué `ignore_changes = [instances]` en el VMSS?**
   El autoescalado cambia la cuenta de instancias fuera de Terraform. Sin esa línea, cada `apply` la devolvería al valor del código y desharía el escalado.
4. **¿Qué hace un presupuesto de Azure y qué no hace?**
   Notifica cuando el gasto real o previsto supera un umbral, con horas de retraso. No detiene nada: para actuar se conecta a un grupo de acción con runbook o Logic App.
5. **¿Qué diferencia hay entre `threshold_type = "Actual"` y `"Forecasted"`?**
   *Actual* compara lo gastado hasta hoy; *Forecasted* compara la proyección a fin de periodo. El segundo avisa antes de que ocurra.
6. **¿Qué está mal en el bloque de reservas del original?**
   El recurso no existe en azurerm; el ámbito de facturación no puede ser un grupo de recursos; una reserva es una compra de ámbito *tenant* que se hace vía `azapi` sobre `Microsoft.Capacity`.
7. **¿Reserva o *savings plan*?**
   Reserva: SKU y región fijos, mayor descuento; para la línea base estable (MySQL, instancias mínimas). *Savings plan*: compromiso en €/h sobre cualquier cómputo; menos descuento, más flexibilidad cuando los SKUs cambian.
8. **¿Qué debe cubrir una reserva y qué debe quedar bajo demanda?**
   La reserva cubre la línea base medida con 30 días de uso; el pico lo absorbe el autoescalado a precio bajo demanda (o Spot fuera de pro).
9. **¿Cómo se pone precio a un `plan` sin credenciales de Azure?**
   Con la API pública `prices.azure.com` desde `data "http"` (precio unitario por SKU y región) e Infracost sobre el plan en JSON (coste total y delta entre ramas o entornos).
10. **¿Por qué la etiqueta `centro_coste` se valida en el `plan`?**
    Sin ella el recurso no aparece en el *showback* y no tiene dueño. Bloquear en `plan` (`validation`) cuesta cero; buscar huérfanos después cuesta horas.
11. **¿Qué ahorra más en dev: apagar por horario o reservar?**
    Apagar: 12×5 elimina ~64 % del cómputo, sin compromiso. Reservar algo que está apagado la mayor parte del tiempo es tirar el descuento. Reservas solo donde hay 24×7.

---

## 10. Referencias

- [`azurerm_monitor_autoscale_setting`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_autoscale_setting), [buenas prácticas de autoescalado](https://learn.microsoft.com/es-es/azure/azure-monitor/autoscale/autoscale-best-practices) (umbrales, *flapping*) y [escalado predictivo](https://learn.microsoft.com/es-es/azure/azure-monitor/autoscale/autoscale-predictive)
- [`azurerm_linux_virtual_machine_scale_set`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/linux_virtual_machine_scale_set) y [Spot en VMSS](https://learn.microsoft.com/es-es/azure/virtual-machine-scale-sets/use-spot)
- [`azurerm_consumption_budget_resource_group`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/consumption_budget_resource_group), [`…_subscription`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/consumption_budget_subscription) y [presupuestos en Cost Management](https://learn.microsoft.com/es-es/azure/cost-management-billing/costs/tutorial-acm-create-budgets)
- [`azurerm_storage_management_policy`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_management_policy), [ciclo de vida de blobs](https://learn.microsoft.com/es-es/azure/storage/blobs/lifecycle-management-overview) y [`azurerm_dev_test_global_vm_shutdown_schedule`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/dev_test_global_vm_shutdown_schedule)
- [API pública de precios de Azure](https://learn.microsoft.com/es-es/rest/api/cost-management/retail-prices/azure-retail-prices), [`data "http"`](https://registry.terraform.io/providers/hashicorp/http/latest/docs/data-sources/http) y [Infracost](https://www.infracost.io/docs/) (*usage files*, comentarios en PR)
- [Reservas de Azure](https://learn.microsoft.com/es-es/azure/cost-management-billing/reservations/save-compute-costs-reservations), [savings plans](https://learn.microsoft.com/es-es/azure/cost-management-billing/savings-plan/savings-plan-compute-overview), [API `Microsoft.Capacity/reservationOrders`](https://learn.microsoft.com/es-es/rest/api/reserved-vm-instances/reservation-order/purchase) y [`azapi_resource`](https://registry.terraform.io/providers/Azure/azapi/latest/docs/resources/azapi_resource)
- [`data "azurerm_advisor_recommendations"`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/advisor_recommendations) y [recomendaciones de coste de Advisor](https://learn.microsoft.com/es-es/azure/advisor/advisor-cost-recommendations)
- [Well-Architected Framework: optimización de costes](https://learn.microsoft.com/es-es/azure/well-architected/cost-optimization/) y [FinOps en Azure](https://learn.microsoft.com/es-es/cloud-computing/finops/)
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)