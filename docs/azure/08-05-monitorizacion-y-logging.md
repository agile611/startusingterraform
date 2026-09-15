# 📈 Monitorización y logging: ver lo que pasa antes de que lo cuenten los usuarios

> Un despliegue sin telemetría no está terminado: funciona hasta que deja de hacerlo, y entonces nadie sabe por qué. Azure Monitor agrupa cuatro piezas que conviene distinguir desde el principio. **Métricas**: números cada minuto (CPU, peticiones, latencia), casi gratis, los emite la plataforma sin configurar nada. **Logs**: eventos con texto (una consulta lenta de MySQL, un 403 en Key Vault, un `PutBlob`), hay que activarlos con *diagnostic settings* y se pagan por GB en un **Log Analytics workspace**. **Trazas** de aplicación (qué hizo Moodle con cada petición): Application Insights. Y **alertas**, que convierten cualquiera de las anteriores en un aviso a una persona o una acción. Todo se declara en Terraform, y por eso el diseño de la observabilidad es parte del módulo, no un añadido del portal. En **Topaz** funciona el plano de gestión de Log Analytics (workspace, tablas, retención); las piezas que dependen de `Microsoft.Insights` (diagnostic settings, agente, alertas, Application Insights) se validan con `plan`. Para **KQL**, el lenguaje de consulta, hay algo mejor que leer: el **emulador de Kusto** en Docker, que ejecuta las mismas consultas sobre datos que tú mismo generas.

**🎯 Objetivos de aprendizaje**
- Distinguir métricas, logs, trazas y alertas, y saber qué cuesta cada una.
- Crear un Log Analytics workspace con retención, cuota y tablas *Basic* por entorno.
- Activar diagnostic settings sobre el sub-recurso correcto con `for_each`, descubriendo las categorías en vez de adivinarlas.
- Recoger syslog y rendimiento de las VMs con Azure Monitor Agent y una *data collection rule*.
- Escribir consultas KQL útiles para Moodle y probarlas en el emulador de Kusto.
- Conectar Application Insights (workspace-based) y entender cómo llega la telemetría desde PHP.
- Definir alertas de métrica, de logs y de activity log con severidad, ventana y grupo de acción, y silenciarlas en mantenimientos.

> **🔷 Requisitos previos.** [Páginas 1](index.md#pagina-1) a 13 completadas y destruidas, `~/tf-st/providers.tf`, Terraform `>= 1.10`, azurerm `~> 4.0`, Docker (para el emulador de Kusto, ≈ 4 GB de RAM), `jq`, `az account show --query environmentName -o tsv` → `Topaz`.

---

## 1. Mapa: qué señal, de dónde, a dónde

| **Señal** | **Ejemplo en Moodle** | **Cómo se activa** | **Recurso Terraform** | **Topaz** |
|---|---|---|---|---|
| Métricas de plataforma | CPU del VMSS, conexiones de MySQL, transacciones de Storage, peticiones del App Gateway | Siempre activas, 93 días, gratis. Se exportan al workspace si quieres KQL sobre ellas | — (consumo con `azurerm_monitor_metric_alert`) | ❌ (no hay emisor) |
| Logs de recurso | Consultas lentas de MySQL, auditoría de Key Vault, accesos a blobs, access log del gateway | Diagnostic setting por recurso → workspace. Se paga por GB ingerido | `azurerm_monitor_diagnostic_setting` | plan ✅ / apply ❌ |
| Logs del sistema operativo | syslog, `auth.log`, rendimiento, error log de Apache | Azure Monitor Agent + *data collection rule* | `azurerm_monitor_data_collection_rule`, `_association`, extensión AMA | plan ✅ / apply ❌ |
| Trazas de aplicación | Duración de cada petición PHP, llamadas a MySQL, excepciones | Application Insights + OpenTelemetry en Moodle | `azurerm_application_insights` | plan ✅ / apply ❌ |
| Activity log | Quién borró el grupo de recursos, quién cambió una regla del NSG, incidentes de servicio de Azure | Siempre activo, 90 días. Exportable al workspace | `azurerm_monitor_activity_log_alert` | plan ✅ / apply ❌ |
| Destino y consulta | Un workspace por entorno; KQL | Retención, cuota diaria, plan de tabla | `azurerm_log_analytics_workspace`, `_table` | ✅ / KQL en emulador Kusto ✅ |

---

## 2. El destino: Log Analytics workspace

Todo lo demás apunta aquí, así que se crea primero y se dimensiona con cabeza: la retención y la cuota diaria son las dos palancas de coste ([página 15](index.md#pagina-15)), y el *plan* de cada tabla decide si esos logs se consultan a menudo (*Analytics*) o solo se guardan por si acaso (*Basic*, mucho más barato de ingerir, con consultas limitadas).

```hcl
resource "azurerm_log_analytics_workspace" "moodle" {
  name                       = "law-moodle-${var.entorno}"
  resource_group_name        = azurerm_resource_group.moodle.name
  location                   = azurerm_resource_group.moodle.location
  sku                        = "PerGB2018"                       # el único que debes usar hoy
  retention_in_days          = var.entorno == "pro" ? 90 : 30    # 31 días incluidos; más, se paga
  daily_quota_gb             = var.entorno == "pro" ? -1 : 1     # -1 = sin tope; en dev, 1 GB corta la ingesta (¡también las alertas!)
  internet_ingestion_enabled = true                              # false + Private Link (AMPLS) en pro
  internet_query_enabled     = true
  tags                       = local.tags
}

# Tablas que se guardan pero casi nunca se consultan: plan Basic (ingesta ~5× más barata, retención 30 días, sin alertas)
resource "azurerm_log_analytics_workspace_table" "basic" {
  for_each                = toset(["StorageBlobLogs", "AGWAccessLogs"])
  workspace_id            = azurerm_log_analytics_workspace.moodle.id
  name                    = each.key
  plan                    = "Basic"
  total_retention_in_days = 365                                  # archivo: barato, recuperable con search jobs
}
# Las tablas de las que dependen alertas (Syslog, Perf, AZKVAuditLogs, AppRequests) se quedan en Analytics.

output "law_id" { value = azurerm_log_analytics_workspace.moodle.id }
output "law_workspace_id" { value = azurerm_log_analytics_workspace.moodle.workspace_id }   # el GUID que piden los agentes y az monitor log-analytics query
```

---

## 3. Diagnostic settings: activar los logs de cada recurso

El original apunta a la cuenta de almacenamiento y pide la categoría `StorageWrite`. No existe ahí: la cuenta solo emite métricas; los logs de acceso los emite cada servicio (`blobServices/default`, `fileServices/default`…). El error es común y la cura es no adivinar: **pregunta al recurso qué categorías tiene**. En azurerm 4.x los bloques son `enabled_log` y `enabled_metric`; lo que no quieres, no lo declaras.

```hcl
# 1. Descubrir categorías (Azure real; en Topaz usa la tabla de abajo)
data "azurerm_monitor_diagnostic_categories" "blob" {
  resource_id = "${azurerm_storage_account.moodledata.id}/blobServices/default"
}
output "categorias_blob" {
  value = { logs = data.azurerm_monitor_diagnostic_categories.blob.log_category_types, grupos = data.azurerm_monitor_diagnostic_categories.blob.log_category_groups, metricas = data.azurerm_monitor_diagnostic_categories.blob.metrics }
}
#   az monitor diagnostic-settings categories list --resource <id> -o table   ← lo mismo desde la CLI

# 2. El original, corregido: logs del servicio blob, métricas de la cuenta
resource "azurerm_monitor_diagnostic_setting" "blob" {
  name                           = "diag-blob-law"
  target_resource_id             = "${azurerm_storage_account.moodledata.id}/blobServices/default"
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.moodle.id
  log_analytics_destination_type = "Dedicated"                   # tabla propia (StorageBlobLogs), no el cajón AzureDiagnostics
  enabled_log { category = "StorageWrite" }
  enabled_log { category = "StorageDelete" }                     # StorageRead se omite: es el 90 % del volumen y rara vez se consulta
  enabled_metric { category = "Transaction" }                    # azurerm < 4.16: metric { category = "Transaction" enabled = true }
}
resource "azurerm_monitor_diagnostic_setting" "cuenta" {
  name                       = "diag-cuenta-law"
  target_resource_id         = azurerm_storage_account.moodledata.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.moodle.id
  enabled_metric { category = "Transaction" }
  enabled_metric { category = "Capacity" }
}

# 3. Patrón para toda la plataforma: un mapa, un for_each
locals {
  diagnosticos = {
    mysql = { id = azurerm_mysql_flexible_server.moodle.id, logs = ["MySqlSlowLogs", "MySqlAuditLogs"], grupo = null }
    kv    = { id = azurerm_key_vault.moodle.id,             logs = ["AuditEvent"],                        grupo = null }
    agw   = { id = azurerm_application_gateway.moodle.id,   logs = [],                                    grupo = "allLogs" }   # access, performance, firewall
    vmss  = { id = azurerm_linux_virtual_machine_scale_set.web.id, logs = [],                             grupo = null }        # solo métricas: los logs del SO van por AMA (14.4)
  }
}
resource "azurerm_monitor_diagnostic_setting" "plataforma" {
  for_each                       = local.diagnosticos
  name                           = "diag-${each.key}-law"
  target_resource_id             = each.value.id
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.moodle.id
  log_analytics_destination_type = "Dedicated"
  dynamic "enabled_log" {
    for_each = each.value.logs
    content { category = enabled_log.value }
  }
  dynamic "enabled_log" {
    for_each = each.value.grupo == null ? [] : [each.value.grupo]
    content { category_group = enabled_log.value }             # "allLogs" o "audit": cómodo, pero revisa el volumen (14.9)
  }
  enabled_metric { category = "AllMetrics" }
}

# 4. Activity log de la suscripción al workspace: quién hizo qué (90 días en Azure; aquí, lo que retenga el workspace)
resource "azurerm_monitor_diagnostic_setting" "activity" {
  name                       = "diag-activity-law"
  target_resource_id         = data.azurerm_subscription.actual.id
  log_analytics_workspace_id = azurerm_log_analytics_workspace.moodle.id
  dynamic "enabled_log" {
    for_each = ["Administrative", "Security", "ServiceHealth", "Alert", "Policy", "Autoscale"]
    content { category = enabled_log.value }
  }
}
```

| **Recurso** | **Categorías de log útiles** | **Tabla en el workspace (modo *Dedicated*)** |
|---|---|---|
| `…/blobServices/default` | `StorageRead`, `StorageWrite`, `StorageDelete` | `StorageBlobLogs` |
| MySQL Flexible Server | `MySqlSlowLogs`, `MySqlAuditLogs` (requiere `slow_query_log=ON`, `audit_log_enabled=ON` en parámetros del servidor) | `AzureDiagnostics` (MySQL aún no tiene tabla dedicada) |
| Key Vault | `AuditEvent`, `AzurePolicyEvaluationDetails` | `AZKVAuditLogs`, `AZKVPolicyEvaluationDetailsLogs` |
| Application Gateway | `ApplicationGatewayAccessLog`, `ApplicationGatewayPerformanceLog`, `ApplicationGatewayFirewallLog` | `AGWAccessLogs`, `AGWPerformanceLogs`, `AGWFirewallLogs` |
| VM / VMSS | Ninguna: el recurso solo emite métricas. Los logs del SO (syslog, auth, Apache) van por Azure Monitor Agent (14.4) | `Syslog`, `Perf`, `Heartbeat`, tablas `_CL` propias |
| Suscripción (activity log) | `Administrative`, `Security`, `ServiceHealth`, `Alert`, `Policy`, `Autoscale` | `AzureActivity` |

> **🔷 *Dedicated* frente a *AzureDiagnostics*.** Sin `log_analytics_destination_type = "Dedicated"`, muchos recursos vuelcan todo en la tabla común `AzureDiagnostics`: un cajón con un límite de 500 columnas que se agota cuando conviven Key Vault, Application Gateway y MySQL, y en el que cada consulta tiene que filtrar por `ResourceType`. Usa siempre *Dedicated*; los recursos que aún no tienen tabla propia (MySQL Flexible) caerán en `AzureDiagnostics` de todos modos, y lo sabrás porque la documentación de cada categoría indica su tabla de destino.

---

## 4. Dentro de la VM: Azure Monitor Agent y reglas de recolección

La plataforma ve la VM desde fuera (CPU, disco, red). Lo que pasa dentro (que Apache devuelve 500, que `sshd` rechaza logins, que el disco de `moodledata` está al 95 %) lo cuenta el **Azure Monitor Agent** (AMA), que sustituye al antiguo *Log Analytics agent* retirado en 2024. AMA no lleva configuración: la recibe de una **data collection rule** (DCR) que dice qué recoger, cómo transformarlo y a qué workspace enviarlo. Una DCR sirve para todo el VMSS; la asociación la aplica a cada recurso.

```hcl
# 1. La regla: qué recoger y a dónde
resource "azurerm_monitor_data_collection_rule" "linux" {
  name                = "dcr-moodle-linux-${var.entorno}"
  resource_group_name = azurerm_resource_group.moodle.name
  location            = azurerm_resource_group.moodle.location
  kind                = "Linux"
  description         = "Syslog + rendimiento de las VMs de Moodle"

  destinations {
    log_analytics {
      workspace_resource_id = azurerm_log_analytics_workspace.moodle.id
      name                  = "law"
    }
  }
  data_sources {
    syslog {
      name           = "syslog"
      streams        = ["Microsoft-Syslog"]
      facility_names = ["auth", "authpriv", "daemon", "cron", "syslog", "user"]     # no "*": kern y mail son ruido caro
      log_levels     = ["Warning", "Error", "Critical", "Alert", "Emergency"]         # Info y Debug se quedan en la VM
    }
    performance_counter {
      name                          = "perf"
      streams                       = ["Microsoft-Perf"]
      sampling_frequency_in_seconds = 60
      counter_specifiers = [
        "Processor(*)\\% Processor Time",
        "Memory(*)\\% Used Memory",
        "Logical Disk(*)\\% Used Space",                                              # /var/moodledata al 95 % antes de que Moodle deje de subir ficheros
        "Logical Disk(*)\\Disk Reads/sec",
        "Network(*)\\Total Bytes Transmitted",
      ]
    }
  }
  data_flow {
    streams      = ["Microsoft-Syslog", "Microsoft-Perf"]
    destinations = ["law"]
  }
  tags = local.tags
}

# 2. El agente en el VMSS: extensión + identidad gestionada (sin identidad, AMA no arranca)
resource "azurerm_linux_virtual_machine_scale_set" "web" {
  # … (página 15)
  identity { type = "SystemAssigned" }
  extension {
    name                       = "AzureMonitorLinuxAgent"
    publisher                  = "Microsoft.Azure.Monitor"
    type                       = "AzureMonitorLinuxAgent"
    type_handler_version       = "1.30"
    auto_upgrade_minor_version = true
    automatic_upgrade_enabled  = true
  }
}

# 3. La asociación: esta regla, para este recurso
resource "azurerm_monitor_data_collection_rule_association" "web" {
  name                    = "dcra-moodle-web"
  target_resource_id      = azurerm_linux_virtual_machine_scale_set.web.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.linux.id
}

# 4. Un fichero de log propio (error log de Apache) → tabla personalizada. Requiere endpoint, tabla con esquema y stream declarado.
resource "azurerm_monitor_data_collection_endpoint" "moodle" {
  name                = "dce-moodle-${var.entorno}"
  resource_group_name = azurerm_resource_group.moodle.name
  location            = azurerm_resource_group.moodle.location
  kind                = "Linux"
}
resource "azapi_resource" "tabla_apache" {                        # azurerm_log_analytics_workspace_table no crea tablas con esquema
  type      = "Microsoft.OperationalInsights/workspaces/tables@2022-10-01"
  name      = "ApacheError_CL"
  parent_id = azurerm_log_analytics_workspace.moodle.id
  body = {
    properties = {
      plan = "Analytics"
      schema = { name = "ApacheError_CL", columns = [
        { name = "TimeGenerated", type = "datetime" },
        { name = "RawData",       type = "string" },
        { name = "Computer",      type = "string" },
      ] }
      retentionInDays = 30
    }
  }
}
resource "azurerm_monitor_data_collection_rule" "apache" {
  name                        = "dcr-moodle-apache-${var.entorno}"
  resource_group_name         = azurerm_resource_group.moodle.name
  location                    = azurerm_resource_group.moodle.location
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.moodle.id
  kind                        = "Linux"
  destinations { log_analytics { workspace_resource_id = azurerm_log_analytics_workspace.moodle.id, name = "law" } }
  stream_declaration {
    stream_name = "Custom-ApacheError_CL"
    column { name = "TimeGenerated", type = "datetime" }
    column { name = "RawData",       type = "string" }
    column { name = "Computer",      type = "string" }
  }
  data_sources {
    log_file {
      name          = "apache-error"
      format        = "text"
      streams       = ["Custom-ApacheError_CL"]
      file_patterns = ["/var/log/apache2/error.log"]
      settings { text { record_start_timestamp_format = "ISO 8601" } }
    }
  }
  data_flow {
    streams       = ["Custom-ApacheError_CL"]
    destinations  = ["law"]
    output_stream = "Custom-ApacheError_CL"
    transform_kql = "source | where RawData !has 'AH00558'"       # descarta el aviso de ServerName que Apache repite en cada arranque
  }
  depends_on = [azapi_resource.tabla_apache]
}
resource "azurerm_monitor_data_collection_rule_association" "apache" {
  name                    = "dcra-moodle-apache"
  target_resource_id      = azurerm_linux_virtual_machine_scale_set.web.id
  data_collection_rule_id = azurerm_monitor_data_collection_rule.apache.id
}
resource "azurerm_monitor_data_collection_rule_association" "endpoint" {   # la asociación al endpoint no lleva nombre: es "configurationAccessEndpoint"
  target_resource_id          = azurerm_linux_virtual_machine_scale_set.web.id
  data_collection_endpoint_id = azurerm_monitor_data_collection_endpoint.moodle.id
}
```

> **🔷 `transform_kql` es la palanca de coste.** La transformación se ejecuta en la ingesta, antes de facturar: filtrar filas (`where`), quitar columnas (`project-away`) o recortar mensajes ahí es dinero que no se paga. Un access log de Apache en pro con 2 000 peticiones/minuto son ~5 GB/día sin filtrar; con `where StatusCode >= 400` baja a menos de 100 MB.

---

## 5. KQL: preguntar a los datos

La consulta del original no devuelve nada: `OperationName` no vale `"Write"` sino `PutBlob`, `PutBlock` o `PutBlockList` (la agrupación por tipo está en `Category`), y `StorageAccountName`, `BlobName` y `ContentType` no son columnas de la tabla. KQL es un *pipeline*: cada `|` recibe una tabla y devuelve otra. Se aprende con seis operadores (`where`, `summarize`, `project`, `extend`, `join`, `render`) y se domina leyendo el esquema antes de escribir: `StorageBlobLogs | getschema`.

```kql
// El original, corregido: escrituras en blobs en el último día
StorageBlobLogs
| where TimeGenerated > ago(1d)
| where Category == "StorageWrite"                  // o: OperationName in ("PutBlob", "PutBlock", "PutBlockList")
| project TimeGenerated, AccountName, OperationName, ObjectKey, StatusCode, CallerIpAddress, DurationMs
| take 100

// Accesos denegados a moodledata: ¿quién intenta y desde dónde?
StorageBlobLogs
| where TimeGenerated > ago(1h) and StatusCode in (401, 403)
| summarize Intentos = count(), Operaciones = make_set(OperationName), Ultimo = max(TimeGenerated) by CallerIpAddress, AuthenticationType
| order by Intentos desc

// Consultas lentas de MySQL: qué SQL castiga al servidor (la tabla es AzureDiagnostics; las columnas llevan sufijo de tipo)
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.DBFORMYSQL" and Category == "MySqlSlowLogs"
| where TimeGenerated > ago(6h)
| extend Consulta = substring(sql_text_s, 0, 120)
| summarize Veces = count(), SegMedia = round(avg(query_time_d), 2), FilasExaminadas = avg(rows_examined_d) by Consulta
| top 10 by SegMedia

// Key Vault: 403 a secretos. Un pico aquí tras un despliegue = identidad sin rol (página 13)
AZKVAuditLogs
| where TimeGenerated > ago(24h) and ResultSignature == "Forbidden"
| extend Quien = tostring(Identity.claim_appid), Recurso = tostring(split(RequestUri, "?")[0])
| summarize Denegados = count() by Quien, OperationName, Recurso, CallerIPAddress
| order by Denegados desc

// Application Gateway: errores 5xx por backend, en ventanas de 5 minutos
AGWAccessLogs
| where TimeGenerated > ago(2h) and HttpStatus >= 500
| summarize Errores = count() by bin(TimeGenerated, 5m), ServerRouted, ServerStatus
| render timechart

// Disco de moodledata: % usado por instancia, y proyección
Perf
| where ObjectName == "Logical Disk" and CounterName == "% Used Space" and InstanceName == "/var/moodledata"
| where TimeGenerated > ago(7d)
| summarize Uso = avg(CounterValue) by bin(TimeGenerated, 1h), Computer
| render timechart
// … y con series_fit_line() puedes estimar cuándo llega al 100 %

// Servidores que han dejado de reportar (base de la alerta de 14.7)
Heartbeat
| summarize UltimoLatido = max(TimeGenerated) by Computer, _ResourceId
| where UltimoLatido < ago(10m)

// Logins SSH fallidos por IP
Syslog
| where Facility in ("auth", "authpriv") and SyslogMessage has "Failed password"
| extend IP = extract(@"from (\d+\.\d+\.\d+\.\d+)", 1, SyslogMessage)
| summarize Intentos = count() by IP, Computer, bin(TimeGenerated, 1h)
| where Intentos > 20

// Cuánto ingiere cada tabla (GB, últimas 24 h): la factura del workspace, tabla a tabla
Usage
| where TimeGenerated > ago(24h) and IsBillable == true
| summarize GB = round(sum(Quantity) / 1024, 2) by DataType
| order by GB desc
```

> **✅ KQL sin Azure: el emulador de Kusto.** Log Analytics es una base de datos Kusto (Azure Data Explorer) con tablas predefinidas. Microsoft publica el motor como contenedor Docker (`mcr.microsoft.com/azuredataexplorer/kustainer-linux`), gratis para desarrollo. No trae las tablas de Azure Monitor, pero se crean con el mismo esquema y se rellenan con datos sintéticos; a partir de ahí cada consulta de esta página se ejecuta igual. Lo que no existe en el emulador: las columnas mágicas `_ResourceId` y `_IsBillable`, la función `workspace()` y los *plans* de tabla. El laboratorio de 14.8 lo monta en tres comandos.

---

## 6. Application Insights: la aplicación, no la máquina

Todo lo anterior dice que la CPU está al 80 % y que MySQL tarda; no dice *qué página* de Moodle es lenta ni qué consulta lanza. Eso lo cuenta Application Insights: peticiones, dependencias (cada llamada a MySQL, a Storage, a Redis), excepciones y disponibilidad. El recurso del original falta `workspace_id`: el modo clásico (con almacenamiento propio) se retiró en 2024 y hoy el recurso es obligatoriamente *workspace-based*, con lo que las trazas acaban en el mismo workspace que el resto (`AppRequests`, `AppDependencies`, `AppExceptions`) y se pueden cruzar con `Syslog` o `AGWAccessLogs` en una misma consulta.

```hcl
resource "azurerm_application_insights" "moodle" {
  name                          = "appi-moodle-${var.entorno}"
  resource_group_name           = azurerm_resource_group.moodle.name
  location                      = azurerm_resource_group.moodle.location
  application_type              = "web"
  workspace_id                  = azurerm_log_analytics_workspace.moodle.id   # obligatorio: sin él, el plan es válido y el apply falla
  sampling_percentage           = var.entorno == "pro" ? 20 : 100             # pro: 1 de cada 5 peticiones basta para estadística; las excepciones no se muestrean
  daily_data_cap_in_gb          = var.entorno == "pro" ? 5 : 0.5
  retention_in_days             = 90
  local_authentication_disabled = var.entorno == "pro"                        # pro: solo Entra ID para ingerir; la connection string ya no basta sola
  internet_ingestion_enabled    = true
  tags                          = local.tags
}

# La connection string va a Key Vault (página 13), no al estado en claro ni a cloud-init
resource "azurerm_key_vault_secret" "appi" {
  name         = "appinsights-connection-string"
  value        = azurerm_application_insights.moodle.connection_string
  key_vault_id = azurerm_key_vault.moodle.id
}

# Disponibilidad: ¿responde Moodle desde fuera, cada 5 minutos, desde tres regiones?
resource "azurerm_application_insights_standard_web_test" "moodle" {
  name                    = "avail-moodle-${var.entorno}"
  resource_group_name     = azurerm_resource_group.moodle.name
  location                = azurerm_resource_group.moodle.location
  application_insights_id = azurerm_application_insights.moodle.id
  geo_locations           = ["emea-nl-ams-azr", "emea-gb-db3-azr", "emea-fr-pra-edge"]
  frequency               = 300
  timeout                 = 30
  enabled                 = true
  retry_enabled           = true
  request {
    url = "https://${var.dominio_moodle}/login/index.php"
  }
  validation_rules {
    expected_status_code        = 200
    ssl_check_enabled           = true
    ssl_cert_remaining_lifetime = 14                                           # avisa dos semanas antes de que caduque el certificado
    content { content_match = "loginform" }                                    # que sea Moodle, no una página de error del gateway con 200
  }
  tags = local.tags
}
```

> **🔷 ¿Y cómo envía Moodle la telemetría?** No hay SDK oficial de Application Insights para PHP. El camino soportado es **OpenTelemetry**: la extensión `opentelemetry` de PHP con instrumentación automática de PDO/MySQL y HTTP, exportando por OTLP a un *OpenTelemetry Collector* que corre como servicio en la misma VM (o como sidecar) y que usa el exporter `azuremonitor` del repositorio *contrib* con la connection string leída de Key Vault. Es exactamente el patrón de la [página 13](index.md#pagina-13): la aplicación nunca ve el secreto; lo ve un proceso local con identidad gestionada. El `cloud-init` de la [página 15](index.md#pagina-15) instala el collector y su configuración.

---

## 7. Alertas: de la señal a la persona

La alerta del original tiene tres errores que el `plan` no detecta todos: `location` no es un argumento del recurso (falla en `validate`), `metric_aggregation` no existe (es `aggregation`), y faltan `severity`, `frequency` y `window_size`, con lo que hereda valores por defecto que nadie ha decidido. Antes de escribir alertas, tres reglas de diseño: cada alerta tiene un **dueño** y una **acción** posible (si al recibirla no harías nada, es un panel, no una alerta); la **severidad** decide el canal (Sev0 y Sev1 despiertan a alguien, Sev3 es un correo por la mañana); y las ventanas de **mantenimiento se silencian** en código, no desactivando reglas a mano.

```hcl
# 1. A quién: grupos de acción por severidad
resource "azurerm_monitor_action_group" "critico" {
  name                = "ag-moodle-critico-${var.entorno}"
  resource_group_name = azurerm_resource_group.moodle.name
  short_name          = "moodle-crit"                                          # máximo 12 caracteres: es lo que aparece en el SMS
  email_receiver { name = "guardia", email_address = var.email_guardia, use_common_alert_schema = true }
  sms_receiver   { name = "guardia-sms", country_code = "34", phone_number = var.telefono_guardia }
  webhook_receiver { name = "teams", service_uri = var.webhook_teams, use_common_alert_schema = true }
  arm_role_receiver { name = "owners", role_id = "8e3af657-a8ff-443c-a75c-2fe8c4bcb635", use_common_alert_schema = true }   # Owner de la suscripción
  tags = local.tags
}
resource "azurerm_monitor_action_group" "aviso" {
  name                = "ag-moodle-aviso-${var.entorno}"
  resource_group_name = azurerm_resource_group.moodle.name
  short_name          = "moodle-info"
  email_receiver { name = "plataforma", email_address = var.email_plataforma, use_common_alert_schema = true }
  tags = local.tags
}

# 2. Métrica: el original, corregido y sobre el VMSS (una VM sola no escala; si la tienes, el namespace es Microsoft.Compute/virtualMachines)
resource "azurerm_monitor_metric_alert" "cpu" {
  name                = "alert-moodle-cpu-alta"
  resource_group_name = azurerm_resource_group.moodle.name
  scopes              = [azurerm_linux_virtual_machine_scale_set.web.id]
  description         = "CPU media del VMSS > 90 % durante 15 min: el autoescalado no da abasto o está en el máximo"
  severity            = 2                                                      # 0 crítico … 4 verbose
  frequency           = "PT5M"                                                 # cada cuánto
  window_size         = "PT15M"                                                # sobre qué ventana se evalúa (≥ frequency)
  auto_mitigate       = true                                                   # se resuelve sola cuando la condición deja de cumplirse
  criteria {
    metric_namespace = "Microsoft.Compute/virtualMachineScaleSets"
    metric_name      = "Percentage CPU"
    aggregation      = "Average"                                               # el original decía metric_aggregation: no existe
    operator         = "GreaterThan"
    threshold        = 90
  }
  action { action_group_id = azurerm_monitor_action_group.critico.id }
  tags = local.tags
}

# Métrica con dimensión: backend caído en el Application Gateway (la métrica trae una fila por pool)
resource "azurerm_monitor_metric_alert" "backend_caido" {
  name                = "alert-moodle-backend-caido"
  resource_group_name = azurerm_resource_group.moodle.name
  scopes              = [azurerm_application_gateway.moodle.id]
  description         = "Al menos un backend del pool de Moodle no pasa el health probe"
  severity            = 1
  frequency           = "PT1M"
  window_size         = "PT5M"
  criteria {
    metric_namespace = "Microsoft.Network/applicationGateways"
    metric_name      = "UnhealthyHostCount"
    aggregation      = "Average"
    operator         = "GreaterThan"
    threshold        = 0
    dimension { name = "BackendSettingsPool", operator = "Include", values = ["*"] }   # una alerta por pool, no una global
  }
  action { action_group_id = azurerm_monitor_action_group.critico.id }
  tags = local.tags
}

# Métrica de MySQL: disco al 85 %. Cuando llega al 100 % el servidor pasa a solo lectura y Moodle deja de funcionar.
resource "azurerm_monitor_metric_alert" "mysql_disco" {
  name                = "alert-moodle-mysql-disco"
  resource_group_name = azurerm_resource_group.moodle.name
  scopes              = [azurerm_mysql_flexible_server.moodle.id]
  severity            = 2
  frequency           = "PT15M"
  window_size         = "PT1H"
  criteria {
    metric_namespace = "Microsoft.DBforMySQL/flexibleServers"
    metric_name      = "storage_percent"
    aggregation      = "Maximum"
    operator         = "GreaterThan"
    threshold        = 85
  }
  action { action_group_id = azurerm_monitor_action_group.aviso.id }
  tags = local.tags
}

# 3. Logs: lo que las métricas no ven. La consulta se evalúa en el workspace cada N minutos.
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "sin_latido" {
  name                 = "alert-moodle-sin-latido"
  resource_group_name  = azurerm_resource_group.moodle.name
  location             = azurerm_resource_group.moodle.location
  description          = "Una instancia lleva 10 min sin Heartbeat: agente caído, VM colgada o red cortada"
  severity             = 1
  evaluation_frequency = "PT5M"
  window_duration      = "PT30M"
  scopes               = [azurerm_log_analytics_workspace.moodle.id]
  criteria {
    query = <<-KQL
      Heartbeat
      | summarize UltimoLatido = max(TimeGenerated) by Computer, _ResourceId
      | where UltimoLatido < ago(10m)
    KQL
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0
    resource_id_column      = "_ResourceId"                                    # la alerta se asocia a la VM concreta, no al workspace
    dimension { name = "Computer", operator = "Include", values = ["*"] }      # una alerta por máquina
    failing_periods { minimum_failing_periods_to_trigger_alert = 1, number_of_evaluation_periods = 1 }
  }
  auto_mitigation_enabled = true
  identity { type = "SystemAssigned" }                                         # la regla consulta con su propia identidad
  action { action_groups = [azurerm_monitor_action_group.critico.id] }
  tags = local.tags
}
resource "azurerm_role_assignment" "alerta_lee_law" {                          # sin esto, la regla existe pero no puede consultar
  scope                = azurerm_log_analytics_workspace.moodle.id
  role_definition_name = "Log Analytics Reader"
  principal_id         = azurerm_monitor_scheduled_query_rules_alert_v2.sin_latido.identity[0].principal_id
}

resource "azurerm_monitor_scheduled_query_rules_alert_v2" "kv_denegados" {
  name                 = "alert-moodle-kv-403"
  resource_group_name  = azurerm_resource_group.moodle.name
  location             = azurerm_resource_group.moodle.location
  description          = "Más de 10 accesos denegados a Key Vault en 15 min: identidad sin rol tras un despliegue, o alguien probando"
  severity             = 2
  evaluation_frequency = "PT15M"
  window_duration      = "PT15M"
  scopes               = [azurerm_log_analytics_workspace.moodle.id]
  criteria {
    query = <<-KQL
      AZKVAuditLogs
      | where ResultSignature == "Forbidden"
      | summarize Denegados = count() by Quien = tostring(Identity.claim_appid), CallerIPAddress
    KQL
    time_aggregation_method = "Total"
    metric_measure_column   = "Denegados"
    operator                = "GreaterThan"
    threshold               = 10
    dimension { name = "Quien", operator = "Include", values = ["*"] }
    failing_periods { minimum_failing_periods_to_trigger_alert = 1, number_of_evaluation_periods = 1 }
  }
  identity { type = "SystemAssigned" }
  action { action_groups = [azurerm_monitor_action_group.aviso.id] }
  tags = local.tags
}

# 4. Activity log: cambios de plataforma e incidentes de Azure. Siempre location = "global".
resource "azurerm_monitor_activity_log_alert" "borrado_rg" {
  name                = "alert-moodle-borrado-rg"
  resource_group_name = azurerm_resource_group.moodle.name
  location            = "global"
  scopes              = [data.azurerm_subscription.actual.id]
  description         = "Alguien ha borrado un grupo de recursos en la suscripción (o lo ha intentado)"
  criteria {
    category       = "Administrative"
    operation_name = "Microsoft.Resources/subscriptions/resourceGroups/delete"
  }
  action { action_group_id = azurerm_monitor_action_group.critico.id }
  tags = local.tags
}
resource "azurerm_monitor_activity_log_alert" "service_health" {
  name                = "alert-service-health-${var.entorno}"
  resource_group_name = azurerm_resource_group.moodle.name
  location            = "global"
  scopes              = [data.azurerm_subscription.actual.id]
  description         = "Incidentes y mantenimientos de Azure que afectan a los servicios de Moodle en nuestra región"
  criteria {
    category = "ServiceHealth"
    service_health {
      events    = ["Incident", "Maintenance"]
      locations = [var.location]
      services  = ["Virtual Machine Scale Sets", "Azure Database for MySQL", "Storage", "Application Gateway", "Key Vault"]
    }
  }
  action { action_group_id = azurerm_monitor_action_group.aviso.id }
  tags = local.tags
}

# 5. Silencio programado: la ventana de parches del domingo no debe despertar a nadie
resource "azurerm_monitor_alert_processing_rule_suppression" "mantenimiento" {
  name                = "apr-moodle-mantenimiento"
  resource_group_name = azurerm_resource_group.moodle.name
  scopes              = [azurerm_resource_group.moodle.id]
  description         = "Domingos 03:00-05:00: sin notificaciones de Sev2 a Sev4. Sev0 y Sev1 siguen llegando."
  schedule {
    time_zone = "Romance Standard Time"
    recurrence {
      weekly { days_of_week = ["Sunday"], start_time = "03:00:00", end_time = "05:00:00" }
    }
  }
  condition {
    severity { operator = "Equals", values = ["Sev2", "Sev3", "Sev4"] }
  }
  tags = local.tags
}
# Para un mantenimiento puntual: schedule { effective_from = "2026-10-04T02:00:00", effective_until = "2026-10-04T06:00:00" } sin recurrence.
# Las alertas se siguen disparando y quedan en el historial; lo que se suprime es la notificación.
```

> **🔷 Cuánto cuesta cada tipo de alerta.** Las de métrica y de activity log se cobran por regla y mes (céntimos, y las primeras son gratis). Las de logs se cobran por *frecuencia de evaluación*: una regla cada minuto cuesta 15 veces más que una cada 15 minutos, y además ejecuta la consulta sobre el workspace. Regla práctica: métrica siempre que exista una métrica que lo exprese; logs solo cuando no (Heartbeat, 403 de Key Vault, patrones en syslog); y frecuencia de 5 a 15 minutos salvo que de verdad respondas antes.

---

## 8. Laboratorio en Topaz (y en el emulador de Kusto)

El laboratorio tiene tres partes. La primera aplica en Topaz lo que el emulador implementa: el workspace y sus tablas. La segunda valida con `validate` y `plan` todo lo que depende de `Microsoft.Insights`, incluyendo los errores del original para que veas cuáles detecta Terraform y cuáles no. La tercera levanta el emulador de Kusto, crea las tablas con el esquema real, las rellena con datos sintéticos y ejecuta las consultas de 14.5.

```bash
mkdir -p ~/tf-mon && cd ~/tf-mon && cp ~/tf-st/providers.tf .

# ─── 1. El destino: workspace y tablas (aplica en Topaz) ────────────────────────
cat > main.tf <<'EOF'
variable "entorno"          { type = string, default = "dev" }
variable "location"         { type = string, default = "eastus" }
variable "validar_insights" { type = bool,   default = false }
locals { tags = { proyecto = "moodle", entorno = var.entorno, gestion = "terraform" } }
data "azurerm_subscription" "actual" {}

resource "azurerm_resource_group" "mon" {
  name     = "rg-mon-lab-${var.entorno}"
  location = var.location
  tags     = local.tags
}
resource "azurerm_log_analytics_workspace" "moodle" {
  name                = "law-mon-lab-${var.entorno}"
  resource_group_name = azurerm_resource_group.mon.name
  location            = azurerm_resource_group.mon.location
  sku                 = "PerGB2018"
  retention_in_days   = var.entorno == "pro" ? 90 : 30
  daily_quota_gb      = var.entorno == "pro" ? -1 : 1
  tags                = local.tags
}
resource "azurerm_log_analytics_workspace_table" "basic" {
  for_each                = toset(["StorageBlobLogs", "AGWAccessLogs"])
  workspace_id            = azurerm_log_analytics_workspace.moodle.id
  name                    = each.key
  plan                    = "Basic"
  total_retention_in_days = 365
}
resource "azurerm_storage_account" "moodledata" {
  name                     = "stmon${var.entorno}${substr(md5(azurerm_resource_group.mon.id), 0, 6)}"
  resource_group_name      = azurerm_resource_group.mon.name
  location                 = azurerm_resource_group.mon.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  tags                     = local.tags
}
output "law_workspace_id" { value = azurerm_log_analytics_workspace.moodle.workspace_id }
EOF
terraform init && terraform apply -auto-approve
az monitor log-analytics workspace show -g rg-mon-lab-dev -n law-mon-lab-dev --query "{sku:sku.name, retencion:retentionInDays, cuota:workspaceCapping.dailyQuotaGb}" -o table
az monitor log-analytics workspace table show -g rg-mon-lab-dev --workspace-name law-mon-lab-dev -n StorageBlobLogs --query "{plan:plan, retencionTotal:totalRetentionInDays}" -o table
#   Si Topaz no implementa "tables", el apply lo indica en ese recurso: coméntalo y sigue; el resto no depende de él.

# ─── 2. Lo que Topaz no implementa: validate + plan ─────────────────────────────
cat > insights.tf <<'EOF'
resource "azurerm_monitor_action_group" "aviso" {
  count               = var.validar_insights ? 1 : 0
  name                = "ag-mon-lab-aviso"
  resource_group_name = azurerm_resource_group.mon.name
  short_name          = "mon-aviso"
  email_receiver { name = "plataforma", email_address = "plataforma@ejemplo.edu", use_common_alert_schema = true }
}
resource "azurerm_monitor_diagnostic_setting" "blob" {
  count                          = var.validar_insights ? 1 : 0
  name                           = "diag-blob-law"
  target_resource_id             = "${azurerm_storage_account.moodledata.id}/blobServices/default"
  log_analytics_workspace_id     = azurerm_log_analytics_workspace.moodle.id
  log_analytics_destination_type = "Dedicated"
  enabled_log { category = "StorageWrite" }
  enabled_log { category = "StorageDelete" }
  enabled_metric { category = "Transaction" }
}
resource "azurerm_application_insights" "moodle" {
  count               = var.validar_insights ? 1 : 0
  name                = "appi-mon-lab"
  resource_group_name = azurerm_resource_group.mon.name
  location            = azurerm_resource_group.mon.location
  application_type    = "web"
  workspace_id        = azurerm_log_analytics_workspace.moodle.id
  sampling_percentage = 100
  daily_data_cap_in_gb = 0.5
}
resource "azurerm_monitor_scheduled_query_rules_alert_v2" "sin_latido" {
  count                = var.validar_insights ? 1 : 0
  name                 = "alert-mon-lab-sin-latido"
  resource_group_name  = azurerm_resource_group.mon.name
  location             = azurerm_resource_group.mon.location
  severity             = 1
  evaluation_frequency = "PT5M"
  window_duration      = "PT30M"
  scopes               = [azurerm_log_analytics_workspace.moodle.id]
  criteria {
    query                   = "Heartbeat | summarize UltimoLatido = max(TimeGenerated) by Computer, _ResourceId | where UltimoLatido < ago(10m)"
    time_aggregation_method = "Count"
    operator                = "GreaterThan"
    threshold               = 0
    resource_id_column      = "_ResourceId"
    dimension { name = "Computer", operator = "Include", values = ["*"] }
    failing_periods { minimum_failing_periods_to_trigger_alert = 1, number_of_evaluation_periods = 1 }
  }
  identity { type = "SystemAssigned" }
  action { action_groups = [azurerm_monitor_action_group.aviso[0].id] }
}
resource "azurerm_monitor_activity_log_alert" "borrado_rg" {
  count               = var.validar_insights ? 1 : 0
  name                = "alert-mon-lab-borrado-rg"
  resource_group_name = azurerm_resource_group.mon.name
  location            = "global"
  scopes              = [data.azurerm_subscription.actual.id]
  criteria { category = "Administrative", operation_name = "Microsoft.Resources/subscriptions/resourceGroups/delete" }
  action { action_group_id = azurerm_monitor_action_group.aviso[0].id }
}
EOF
terraform validate && terraform plan -var validar_insights=true -no-color | grep -E "Plan:|will be created"
#   Plan: 5 to add. Sintaxis, tipos y referencias correctas. El apply se detendría en Microsoft.Insights: no lo intentes aquí.

# Los errores del original, uno a uno: ¿cuáles detecta Terraform?
cat > /tmp/original.tf <<'EOF'
resource "azurerm_monitor_metric_alert" "original" {
  name                = "high-cpu-alert"
  location            = "eastus"                                 # (a) argumento inexistente
  resource_group_name = "rg"
  scopes              = ["/subscriptions/x/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm"]
  criteria {
    metric_name        = "Percentage CPU"
    metric_namespace   = "Microsoft.Compute/virtualMachines"
    metric_aggregation = "Average"                               # (b) se llama aggregation
    time_aggregation   = "Average"                               # (c) tampoco existe
    operator           = "GreaterThan"
    threshold          = 90
  }
  action { action_group_id = "/subscriptions/x/resourceGroups/rg/providers/Microsoft.Insights/actionGroups/ag" }
}
resource "azurerm_monitor_diagnostic_setting" "original" {
  name                       = "example-diagnostic-setting"
  target_resource_id         = "/subscriptions/x/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/st"
  log_analytics_workspace_id = "/subscriptions/x/resourceGroups/rg/providers/Microsoft.OperationalInsights/workspaces/law"
  log { category = "StorageWrite", enabled = false }             # (d) bloque retirado en 4.x; (e) categoría del sub-recurso blob
  metric { category = "AllMetrics", enabled = true }
}
EOF
mkdir -p /tmp/orig && cp /tmp/original.tf providers.tf /tmp/orig/ && (cd /tmp/orig && terraform init -backend=false >/dev/null && terraform validate)
#   validate detecta (a), (b), (c) y (d): "Unsupported argument" / "Unsupported block type".
#   (e) no lo detecta nadie hasta el apply: "Category 'StorageWrite' is not supported for resource type storageAccounts".
#   Y hay un sexto error que ni el apply ve: sin severity, frequency ni window_size la alerta hereda Sev3 / PT1M / PT5M sin que nadie lo decidiera.

# ─── 3. KQL de verdad: el emulador de Kusto ─────────────────────────────────────
docker run -d --name kusto -e ACCEPT_EULA=Y -m 4G -p 8080:8080 mcr.microsoft.com/azuredataexplorer/kustainer-linux
sleep 20 && curl -s http://localhost:8080/v1/rest/mgmt -H 'Content-Type: application/json' -d '{"csl":".show version"}' | jq -r '.Tables[0].Rows[0][0]'

# Dos funciones: kql (consulta) y kmgmt (comando de gestión), ambas contra la base Moodle
kmgmt() { curl -s http://localhost:8080/v1/rest/mgmt  -H 'Content-Type: application/json' -d "$(jq -n --arg q "$1" '{db:"Moodle",csl:$q}')" | jq -r '.Tables[0].Rows[]? | @tsv' ; }
kql()   { curl -s http://localhost:8080/v1/rest/query -H 'Content-Type: application/json' -d "$(jq -n --arg q "$1" '{db:"Moodle",csl:$q}')" | jq -r '.Tables[0] | (.Columns | map(.ColumnName) | @tsv), (.Rows[] | @tsv)' ; }

curl -s http://localhost:8080/v1/rest/mgmt -H 'Content-Type: application/json' \
  -d '{"csl":".create database Moodle persist (@\"/kustodata/dbs/Moodle/md\", @\"/kustodata/dbs/Moodle/data\")"}' >/dev/null

# Tablas con el esquema real de Log Analytics (las columnas que usan las consultas de 14.5)
kmgmt '.create table StorageBlobLogs (TimeGenerated:datetime, Category:string, OperationName:string, AccountName:string, ObjectKey:string, StatusCode:int, CallerIpAddress:string, AuthenticationType:string, DurationMs:long)'
kmgmt '.create table AZKVAuditLogs (TimeGenerated:datetime, OperationName:string, ResultSignature:string, RequestUri:string, CallerIPAddress:string, Identity:dynamic)'
kmgmt '.create table Heartbeat (TimeGenerated:datetime, Computer:string, ResourceId:string)'
kmgmt '.create table Perf (TimeGenerated:datetime, Computer:string, ObjectName:string, CounterName:string, InstanceName:string, CounterValue:real)'

# Datos sintéticos generados con el propio KQL: 5 000 operaciones de blob en 24 h, con un atacante que acumula 403
kmgmt '.set-or-append StorageBlobLogs <| range i from 1 to 5000 step 1
  | extend TimeGenerated = ago(1d) + i * 17s
  | extend OperationName = case(i % 10 == 0, "DeleteBlob", i % 3 == 0, "PutBlob", "GetBlob")
  | extend Category = case(OperationName == "GetBlob", "StorageRead", OperationName == "DeleteBlob", "StorageDelete", "StorageWrite")
  | extend AccountName = "stmoodledata", ObjectKey = strcat("/stmoodledata/moodledata/filedir/", hash_md5(tostring(i)))
  | extend CallerIpAddress = case(i % 7 == 0, "203.0.113.66:443", strcat("10.10.1.", tostring(i % 4 + 4), ":51000"))
  | extend StatusCode = case(CallerIpAddress startswith "203.0.113", 403, i % 97 == 0, 500, 200)
  | extend AuthenticationType = case(StatusCode == 403, "Anonymous", "OAuth"), DurationMs = tolong(rand(120) + 5)
  | project-away i'
kmgmt '.set-or-append AZKVAuditLogs <| range i from 1 to 300 step 1
  | extend TimeGenerated = ago(1d) + i * 4m, OperationName = "SecretGet"
  | extend ResultSignature = iff(i % 5 == 0, "Forbidden", "OK"), RequestUri = "https://kv-moodle.vault.azure.net/secrets/mysql-password?api-version=7.4"
  | extend CallerIPAddress = iff(i % 5 == 0, "10.10.1.99", "10.10.1.4")
  | extend Identity = iff(i % 5 == 0, dynamic({"claim_appid":"aaaa-runner-viejo"}), dynamic({"claim_appid":"bbbb-vmss-web"}))
  | project-away i'
kmgmt '.set-or-append Heartbeat <| range i from 1 to 1440 step 1
  | extend TimeGenerated = ago(1d) + i * 1m
  | mv-expand Computer = dynamic(["vmss-web_0", "vmss-web_1", "vmss-web_2"]) to typeof(string)
  | where not(Computer == "vmss-web_2" and TimeGenerated > ago(25m))          // la instancia 2 dejó de reportar hace 25 min
  | extend ResourceId = strcat("/subscriptions/x/resourceGroups/rg-moodle/providers/Microsoft.Compute/virtualMachineScaleSets/vmss-web/virtualMachines/", substring(Computer, 9))
  | project-away i'
kmgmt '.set-or-append Perf <| range i from 1 to 168 step 1
  | extend TimeGenerated = ago(7d) + i * 1h, Computer = "vmss-web_0", ObjectName = "Logical Disk", CounterName = "% Used Space", InstanceName = "/var/moodledata"
  | extend CounterValue = 60.0 + i * 0.2 + rand(2)                              // crece 0,2 puntos/hora: en ~200 h llega al 100 %
  | project-away i'

# Las consultas de 14.5, tal cual (Heartbeat usa ResourceId en vez de la columna mágica _ResourceId)
kql 'StorageBlobLogs | where TimeGenerated > ago(1d) | where OperationName == "Write" | count'                # el original: 0 filas
kql 'StorageBlobLogs | where TimeGenerated > ago(1d) | where Category == "StorageWrite" | count'             # corregido: ~1 500
kql 'StorageBlobLogs | where TimeGenerated > ago(1d) | where Category == "StorageWrite" | project TimeGenerated, AccountName, OperationName, ObjectKey, StatusCode, CallerIpAddress, DurationMs | take 5'
kql 'StorageBlobLogs | where StatusCode in (401, 403) | summarize Intentos = count(), Operaciones = make_set(OperationName) by CallerIpAddress, AuthenticationType | order by Intentos desc'
kql 'AZKVAuditLogs | where ResultSignature == "Forbidden" | extend Quien = tostring(Identity.claim_appid) | summarize Denegados = count() by Quien, OperationName, CallerIPAddress'
kql 'Heartbeat | summarize UltimoLatido = max(TimeGenerated) by Computer, ResourceId | where UltimoLatido < ago(10m)'   # vmss-web_2: la alerta de 14.7 dispararía
kql 'Perf | where CounterName == "% Used Space" | make-series Uso = avg(CounterValue) on TimeGenerated step 1h | extend (_, Pendiente) = series_fit_line(Uso) | project HorasHasta100 = (100 - toreal(Uso[-1])) / Pendiente'
kql 'StorageBlobLogs | getschema | project ColumnName, ColumnType'              # lee el esquema antes de escribir: evita el error del original

# ─── 4. Limpiar ────────────────────────────────────────────────────────────────
terraform destroy -auto-approve
docker rm -f kusto
```

```bash
# ─── Solo Azure real: el ciclo completo ─────────────────────────────────────────
terraform apply -auto-approve -var validar_insights=true
az monitor diagnostic-settings categories list --resource "$(terraform output -raw storage_id)/blobServices/default" --query "value[].{cat:name, tipo:categoryType}" -o table
# Los logs tardan 5-15 min en aparecer. Genera actividad y consulta:
az storage blob upload --account-name <cuenta> -c moodledata -n prueba.txt -f /etc/hostname --auth-mode login
az monitor log-analytics query -w $(terraform output -raw law_workspace_id) --analytics-query 'StorageBlobLogs | where TimeGenerated > ago(1h) | summarize count() by Category, StatusCode' -o table
az monitor log-analytics query -w $(terraform output -raw law_workspace_id) --analytics-query 'Usage | where TimeGenerated > ago(24h) and IsBillable | summarize GB = round(sum(Quantity)/1024, 3) by DataType | order by GB desc' -o table
# Métricas sin workspace (gratis, siempre disponibles):
az monitor metrics list --resource <id-vmss> --metric "Percentage CPU" --interval PT5M --aggregation Average -o table
# Probar la cadena de notificación sin esperar a un incidente:
az monitor action-group test-notifications create -g rg-mon-lab-dev --action-group-name ag-mon-lab-aviso --alert-type metricstaticthresholdcriteria --notification-type Email
# Historial de alertas disparadas y su estado:
az monitor alert-processing-rule list -g rg-mon-lab-dev -o table
az rest --method get --url "https://management.azure.com$(az group show -n rg-mon-lab-dev --query id -o tsv)/providers/Microsoft.AlertsManagement/alerts?api-version=2019-05-05-preview" --query "value[].{n:name, sev:properties.essentials.severity, estado:properties.essentials.monitorCondition, cuando:properties.essentials.startDateTime}" -o table
```

---

## 9. Errores comunes

> ⚠️ **Solución de problemas**
>
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | *Unsupported block type "log"* en el diagnostic setting (original) | Retirado en azurerm 4.x. Usa `enabled_log` y `enabled_metric`; lo que no quieres, no lo declaras (`enabled = false` ya no existe) |
> | *Category 'StorageWrite' is not supported for resource type storageAccounts* | La categoría pertenece al servicio, no a la cuenta. `target_resource_id = "${cuenta.id}/blobServices/default"`. Descubre las categorías con `data "azurerm_monitor_diagnostic_categories"` o `az monitor diagnostic-settings categories list` |
> | Cada `plan` quiere recrear el diagnostic setting o añade categorías que no pediste | Azure devuelve todas las categorías, también las desactivadas, y el provider las compara. Declara explícitamente `log_analytics_destination_type` y, si persiste, fija `enabled_metric` para todas las métricas del recurso o ignora el atributo con `lifecycle` |
> | Los logs llegan a `AzureDiagnostics` y la consulta a `AZKVAuditLogs` no devuelve nada | Falta `log_analytics_destination_type = "Dedicated"`. Cambiarlo no migra lo ya ingerido: durante la retención convivirán ambas tablas |
> | *Query returned no results* con la consulta del original | `OperationName == "Write"` no coincide con ningún valor; las columnas `StorageAccountName`, `BlobName` y `ContentType` no existen. `Category == "StorageWrite"`, `AccountName`, `ObjectKey`. Siempre: `Tabla | getschema` antes de escribir |
> | Consultas de MySQL vacías aunque el diagnostic setting existe | El servidor no genera los logs: faltan los parámetros `slow_query_log = ON`, `long_query_time` y `audit_log_enabled = ON` (`azurerm_mysql_flexible_server_configuration`). El diagnostic setting solo transporta lo que el servidor emite |
> | *Application Insights component requires a workspace* / el recurso no se crea | Modo clásico retirado en 2024. `workspace_id` es obligatorio en la práctica aunque el esquema del provider lo marque opcional |
> | AMA instalado pero ni `Heartbeat` ni `Syslog` reciben datos | Tres causas por orden: la VM no tiene identidad gestionada (AMA no arranca sin ella); no hay `azurerm_monitor_data_collection_rule_association`; o el NSG/firewall bloquea la salida a `*.handler.control.monitor.azure.com` y `*.ods.opinsights.azure.com` (en pro, AMPLS). Diagnóstico en la VM: `/var/opt/microsoft/azuremonitoragent/log/mdsd.err` |
> | El fichero de log personalizado no aparece en `ApacheError_CL` | Una DCR con `log_file` exige `data_collection_endpoint_id`, la asociación al endpoint, la tabla creada con esquema y un `stream_declaration` cuyas columnas coincidan. Y AMA solo lee ficheros nuevos desde que se asocia la regla: genera líneas después |
> | La cuota diaria se agota a media tarde y las alertas dejan de disparar | Al alcanzar `daily_quota_gb` el workspace deja de ingerir *todo*, incluidas `Heartbeat` y las tablas de las que dependen las alertas. Mira `Usage` por `DataType`, filtra en `transform_kql` o mueve la tabla ruidosa a *Basic*. Azure además emite el evento *Data collection stopped*: alerta sobre él |
> | *Unsupported argument "location"* / *"metric_aggregation"* en la alerta de métrica (original) | `azurerm_monitor_metric_alert` no lleva `location` (es un recurso global); el argumento es `aggregation`; `time_aggregation` tampoco existe. `terraform validate` lo detecta |
> | La alerta de métrica se dispara y se resuelve continuamente | `window_size` igual a `frequency` sobre una métrica ruidosa. Ventana ≥ 3× frecuencia (`PT5M`/`PT15M`), o `dynamic_criteria` con `alert_sensitivity = "Medium"` para umbrales que aprenden la estacionalidad |
> | La alerta de logs existe pero nunca dispara; en el portal, *Failed to run query: Forbidden* | La regla consulta con su identidad y no tiene *Log Analytics Reader* sobre el workspace. `azurerm_role_assignment` sobre `identity[0].principal_id`; tarda unos minutos en propagarse |
> | Una sola alerta de *sin latido* aunque han caído tres instancias | Sin `dimension` ni `resource_id_column` la regla agrega todo en una alerta contra el workspace. Con ambas, una alerta por máquina, asociada a su recurso |
> | *Location must be 'global'* en `azurerm_monitor_activity_log_alert` | Las alertas de activity log son globales por definición. `location = "global"`, no la del grupo de recursos |
> | Nadie recibe el SMS / *short_name too long* | `short_name` tiene 12 caracteres máximo. Y el SMS exige que el número confirme la suscripción la primera vez: prueba con `az monitor action-group test-notifications create` antes del primer incidente |
> | El mantenimiento del domingo despertó a la guardia | Sin *alert processing rule* o con `time_zone` UTC en lugar de `Romance Standard Time`. La supresión no bloquea la alerta, solo la notificación; comprueba el ámbito (`scopes`) y la severidad incluida |
> | Availability test en rojo aunque Moodle responde | El WAF o el NSG bloquean las IPs de los probes de Azure (etiqueta de servicio `ApplicationInsightsAvailability`); o `content_match` busca texto que la página de login no contiene en tu idioma. Permite la etiqueta y valida el texto con `curl` |
> | En el emulador de Kusto: *Semantic error: '_ResourceId' could not be resolved* | Las columnas con guion bajo inicial (`_ResourceId`, `_IsBillable`) las añade Log Analytics en la ingesta; el emulador no las tiene. Créalas como columnas normales en el esquema o usa un alias (`ResourceId`) como en 14.8 |
> | En Topaz: *No registered resource provider found for Microsoft.Insights* | Esperado. Diagnostic settings, DCR, alertas y Application Insights no están implementados en el emulador. Se validan con `plan` y se aplican en Azure real; el workspace y sus tablas sí aplican |

---

## 10. Autoevaluación

1. **¿Qué diferencia una métrica de un log, y qué cuesta cada una?**
   La métrica es numérica, cada minuto, la emite la plataforma sin configurar y es gratis 93 días. El log es un evento con texto, hay que activarlo con un diagnostic setting y se paga por GB ingerido y por retención.
2. **¿Por qué el diagnostic setting del original no puede crearse?**
   Apunta a la cuenta de almacenamiento, que solo emite métricas; `StorageWrite` pertenece a `blobServices/default`. Además usa el bloque `log` retirado en azurerm 4.x.
3. **¿Cómo evitas adivinar las categorías de un recurso?**
   `data "azurerm_monitor_diagnostic_categories"` o `az monitor diagnostic-settings categories list`. Devuelven logs, grupos (`allLogs`, `audit`) y métricas exactas.
4. **¿Qué hace `log_analytics_destination_type = "Dedicated"`?**
   Envía cada categoría a su tabla propia (`AZKVAuditLogs`, `AGWAccessLogs`) en lugar del cajón común `AzureDiagnostics`, con su límite de 500 columnas y consultas que deben filtrar por tipo.
5. **¿Por qué la consulta KQL del original devuelve cero filas?**
   `OperationName` vale `PutBlob` o `PutBlock`, nunca `"Write"`; el filtro correcto es `Category == "StorageWrite"`. Y proyecta columnas inexistentes.
6. **¿Qué necesita una VM para que sus logs de sistema lleguen al workspace?**
   Identidad gestionada, la extensión Azure Monitor Agent, una *data collection rule* que diga qué recoger y una asociación entre ambas. Sin DCR, el agente arranca y no envía nada.
7. **¿Dónde está la palanca de coste en una DCR?**
   En `transform_kql`: filtrar filas y quitar columnas ocurre antes de la facturación. También en `facility_names` y `log_levels` del syslog: no recoger `Info` ni `kern`.
8. **¿Por qué el Application Insights del original falla en el `apply` aunque el `plan` sea válido?**
   Sin `workspace_id` intenta crear un recurso clásico, retirado en 2024. El provider lo marca opcional; Azure lo exige.
9. **¿Cómo envía Moodle (PHP) telemetría a Application Insights si no hay SDK?**
   OpenTelemetry: extensión PHP con auto-instrumentación de PDO y HTTP, exportando por OTLP a un collector local que usa el exporter `azuremonitor` con la connection string leída de Key Vault mediante identidad gestionada.
10. **Enumera los errores de la alerta de métrica del original.**
    `location` no es argumento del recurso; `metric_aggregation` se llama `aggregation`; `time_aggregation` no existe; y faltan `severity`, `frequency` y `window_size`, con lo que hereda Sev3/PT1M/PT5M sin decisión.
11. **¿Cuándo eliges una alerta de logs en lugar de una de métrica?**
    Solo cuando no existe métrica que exprese la condición: ausencia de `Heartbeat`, 403 en Key Vault, patrones en syslog. Las de logs cuestan por frecuencia de evaluación y ejecutan consultas; las de métrica son casi gratis.
12. **¿Para qué sirven `dimension` y `resource_id_column` en una alerta de logs?**
    Para obtener una alerta por máquina (o por identidad, por pool) asociada a su recurso concreto, en lugar de una única alerta agregada contra el workspace.
13. **¿Qué hace una *alert processing rule* de supresión y qué no hace?**
    Bloquea las notificaciones de las alertas que cumplen la condición (ámbito, severidad, horario). Las alertas se siguen disparando y quedan en el historial; nada se desactiva.
14. **¿Qué pasa cuando el workspace alcanza `daily_quota_gb`?**
    Deja de ingerir todo hasta el reinicio diario, incluidas las tablas de las que dependen las alertas. En dev es un ahorro aceptable; en pro no se pone tope y se controla el volumen en origen.
15. **¿Qué puedes probar de esta página en Topaz y qué en el emulador de Kusto?**
    Topaz: workspace, retención, cuota y tablas (plano de gestión de Log Analytics), más `validate`/`plan` de todo lo demás. Kusto: cualquier consulta KQL sobre tablas con el esquema real y datos sintéticos, salvo las columnas `_ResourceId`/`_IsBillable` y la función `workspace()`.

---

## 11. Referencias

- [Azure Monitor: visión general](https://learn.microsoft.com/es-es/azure/azure-monitor/overview) y [fuentes de datos](https://learn.microsoft.com/es-es/azure/azure-monitor/data-sources) (métricas, logs, trazas, activity log)
- [`azurerm_log_analytics_workspace`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/log_analytics_workspace), [`azurerm_log_analytics_workspace_table`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/log_analytics_workspace_table) y [planes de tabla Analytics, Basic y Auxiliary](https://learn.microsoft.com/es-es/azure/azure-monitor/logs/basic-logs-configure)
- [`azurerm_monitor_diagnostic_setting`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_diagnostic_setting), [`data "azurerm_monitor_diagnostic_categories"`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/data-sources/monitor_diagnostic_categories) y [índice de tablas y categorías por recurso](https://learn.microsoft.com/es-es/azure/azure-monitor/reference/logs-index)
- [Azure Monitor Agent](https://learn.microsoft.com/es-es/azure/azure-monitor/agents/azure-monitor-agent-overview), [`azurerm_monitor_data_collection_rule`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_data_collection_rule), [logs de texto con DCR](https://learn.microsoft.com/es-es/azure/azure-monitor/agents/data-collection-log-text) y [transformaciones en la ingesta](https://learn.microsoft.com/es-es/azure/azure-monitor/essentials/data-collection-transformations)
- [Referencia de KQL](https://learn.microsoft.com/es-es/kusto/query/), [esquema de `StorageBlobLogs`](https://learn.microsoft.com/es-es/azure/azure-monitor/reference/tables/storagebloblogs), [primeras consultas en Log Analytics](https://learn.microsoft.com/es-es/azure/azure-monitor/logs/get-started-queries) y [API REST de Kusto](https://learn.microsoft.com/es-es/kusto/api/rest/index) (la que usan `kql` y `kmgmt` en 14.8)
- [Emulador de Kusto](https://learn.microsoft.com/es-es/kusto/emulator/kusto-emulator-overview) (`kustainer-linux`): instalación, límites y licencia
- [`azurerm_application_insights`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_insights), [`azurerm_application_insights_standard_web_test`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/application_insights_standard_web_test), [OpenTelemetry con Azure Monitor](https://learn.microsoft.com/es-es/azure/azure-monitor/app/opentelemetry-enable) y [exporter `azuremonitor` del Collector](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/azuremonitorexporter)
- [`azurerm_monitor_metric_alert`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_metric_alert), [`azurerm_monitor_scheduled_query_rules_alert_v2`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_scheduled_query_rules_alert_v2), [`azurerm_monitor_activity_log_alert`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_activity_log_alert) y [`azurerm_monitor_alert_processing_rule_suppression`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/monitor_alert_processing_rule_suppression)
- [Alertas en Azure Monitor](https://learn.microsoft.com/es-es/azure/azure-monitor/alerts/alerts-overview), [esquema común de alertas](https://learn.microsoft.com/es-es/azure/azure-monitor/alerts/alerts-common-schema) y [Well-Architected Framework: observabilidad](https://learn.microsoft.com/es-es/azure/well-architected/operational-excellence/observability)
- [Coste y uso de Azure Monitor](https://learn.microsoft.com/es-es/azure/azure-monitor/cost-usage) (qué se factura en logs, métricas y alertas)
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)