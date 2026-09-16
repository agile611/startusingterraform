# 🗃️ Bases de datos

## 1. Anatomía de Azure SQL Database

```text
rg-sql-001
├── random_string  sufijo ─────────────┐   (provider random: sin llamadas a Azure)
├── random_password admin ─────────────┤
├── Servidor lógico sql-lab-<sufijo> ◄─┘   sql-lab-xxxx.database.windows.net, TLS 1.2, login SQL (+ Entra ID opcional)
│   ├── Firewall: Allow-Admin (tu IP)       nivel servidor: quién llega al puerto 1433
│   └── Base de datos db-lab (Basic)        nivel de servicio, intercalación, copias de seguridad
└── (producción) private endpoint en snet-backend → sin IP pública
```

| **Servicio** | **Cuándo** | **Recursos Terraform** | **En Topaz** |
|---|---|---|---|
| Azure SQL Database | Motor SQL Server gestionado; aplicaciones .NET, migraciones desde SQL Server | `azurerm_mssql_server`, `azurerm_mssql_database`, `azurerm_mssql_firewall_rule` | ⚠️ según versión: interruptor `desplegar_sql` |
| Azure Database for PostgreSQL / MySQL (Flexible Server) | Aplicaciones open source; PostgreSQL es hoy la opción por defecto para proyectos nuevos | `azurerm_postgresql_flexible_server`, `azurerm_mysql_flexible_server` | ❌ solo Azure real |
| Azure Cosmos DB | NoSQL distribuido, latencia de milisegundos, escalado global | `azurerm_cosmosdb_account` | ❌ solo Azure real (existe un emulador propio de Cosmos DB) |

### Modelos de compra

| **`sku_name`** | **Modelo** | **Coste aproximado** | **Uso** |
|---|---|---|---|
| `Basic` | DTU (5 DTU, 2 GB) | ~5 €/mes | Laboratorio, este curso |
| `S0`…`S12`, `P1`… | DTU Standard / Premium | desde ~14 €/mes | Cargas predecibles sin ajuste fino |
| `GP_S_Gen5_1` | vCore serverless con pausa automática | solo almacenamiento si está pausada | Desarrollo con uso intermitente; la primera conexión tras la pausa tarda ~1 min |
| `GP_Gen5_2`, `BC_Gen5_2`… | vCore aprovisionado | desde ~350 €/mes | Producción. Aquí sí aplica `license_type`: `BasePrice` si tienes Azure Hybrid Benefit |

> ⚠️ **`LicenseIncluded` no significa gratis.** Significa que el precio del vCore *incluye* la licencia de SQL Server; la alternativa `BasePrice` la descuenta si ya la tienes. En el modelo DTU (`Basic`, `S0`…) el argumento se ignora. Lo que sí existe es la **oferta gratuita de Azure SQL** (100 000 vCore-segundos al mes en serverless), que se activa desde el portal y no desde Terraform.

---

## 2. Preparar el directorio, providers y variables

Este laboratorio añade un segundo provider, `random`, que genera valores localmente sin llamar a Azure. Copia `providers.tf` como siempre y añade el bloque.

```bash
mkdir -p ~/tf-sql && cd ~/tf-sql
cp ~/tf-intro/providers.tf .
printf 'terraform.tfstate*\n.terraform/\n*.tfvars\n' > .gitignore    # el estado contendrá la contraseña
```

```hcl
# providers.tf  (el bloque azurerm queda como en la página 1; se añade random)
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "azurerm" {
  features {}
  metadata_host                   = "topaz.local.dev:8899"
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}
```

```hcl
# variables.tf
variable "desplegar_sql" {
  type        = bool
  description = "Crear servidor, base de datos y firewall (ponlo a false si tu Topaz no implementa Microsoft.Sql)"
  default     = true
}

variable "ip_admin" {
  type        = string
  description = "IP pública desde la que te conectarás (sin máscara: 203.0.113.7). curl -s ifconfig.me"
  validation {
    condition     = can(cidrhost("${var.ip_admin}/32", 0))
    error_message = "Debe ser una IPv4 sin máscara, como 203.0.113.7."
  }
}

variable "admin_login" {
  type        = string
  description = "Login SQL del administrador"
  default     = "sqladmin"
  validation {
    condition     = !contains(["admin", "administrator", "sa", "root", "dbmanager", "loginmanager", "guest", "public"], lower(var.admin_login))
    error_message = "Azure SQL rechaza los nombres reservados admin, administrator, sa, root, dbmanager, loginmanager, guest y public."
  }
}

variable "sku_bd" {
  type        = string
  description = "Nivel de servicio de la base de datos"
  default     = "Basic"
}

variable "entra_admin_object_id" {
  type        = string
  description = "Object ID de tu usuario de Entra ID para administrar sin contraseña (null en Topaz)"
  default     = null
}

variable "permitir_servicios_azure" {
  type        = bool
  description = "Añadir la regla 0.0.0.0-0.0.0.0 (cualquier recurso de Azure, de cualquier cliente). Desactivada por defecto"
  default     = false
}
```

```hcl
# terraform.tfvars
ip_admin = "203.0.113.7"
```

---

## 3. Secretos: la contraseña nunca va en el código

El original tenía `administrator_login_password = "P@$$w0rd1234!"`. Una contraseña en un `.tf` acaba en Git, en el historial y en cada clon del repositorio. La alternativa mínima es generarla con `random_password`: Terraform la crea una vez, la guarda en el estado y no la vuelve a cambiar mientras no cambien sus argumentos.

```hcl
# secretos.tf
resource "random_string" "sufijo" {
  length  = 6
  upper   = false                           # el nombre del servidor debe ser minúsculas + dígitos + guiones
  special = false
}

resource "random_password" "admin" {
  length           = 24
  min_upper        = 2                      # Azure SQL exige 3 de 4 categorías; así cumplimos las 4
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#%*()-_=+[]{}:?"     # sin comillas, @, $ ni ; que rompen cadenas de conexión
}
```

| **Dónde vive el secreto** | **Protección** | **Nivel** |
|---|---|---|
| En el código | Ninguna | ❌ Nunca |
| `random_password` + estado local con `.gitignore` | El estado la contiene en claro; el output es `sensitive` | ✅ Laboratorio (este curso) |
| Estado remoto cifrado + Key Vault | `azurerm_key_vault_secret` con el valor generado; las aplicaciones lo leen con identidad gestionada | ✅ Producción |
| Sin contraseña: solo Entra ID | `azuread_authentication_only = true`; ni Terraform ni el estado conocen ningún secreto | ✅ Objetivo final |

---

## 4. Servidor lógico y base de datos

```hcl
# sql.tf
locals {
  tags = { entorno = "lab", gestion = "terraform" }   # fuente única; ningún recurso lee las tags de otro
}

resource "azurerm_resource_group" "sql" {
  name     = "rg-sql-001"
  location = "eastus"
  tags     = local.tags
  lifecycle { ignore_changes = [tags] }     # Topaz no devuelve las tags del grupo
}

resource "azurerm_mssql_server" "lab" {
  count = var.desplegar_sql ? 1 : 0

  name                          = "sql-lab-${random_string.sufijo.result}"   # único en todo Azure
  resource_group_name           = azurerm_resource_group.sql.name
  location                      = azurerm_resource_group.sql.location
  version                       = "12.0"                                     # el único valor válido para Azure SQL Database
  administrator_login           = var.admin_login
  administrator_login_password  = random_password.admin.result
  minimum_tls_version           = "1.2"
  public_network_access_enabled = true                                       # false en producción con private endpoint

  dynamic "azuread_administrator" {          # solo si se pasa entra_admin_object_id
    for_each = var.entra_admin_object_id == null ? [] : [1]
    content {
      login_username = "entra-admin"
      object_id      = var.entra_admin_object_id
    }
  }

  tags = local.tags                          # NO azurerm_resource_group.sql.tags (ver cuadro)
}

resource "azurerm_mssql_database" "lab" {
  count = var.desplegar_sql ? 1 : 0

  name           = "db-lab"
  server_id      = azurerm_mssql_server.lab[0].id
  sku_name       = var.sku_bd
  collation      = "SQL_Latin1_General_CP1_CI_AS"    # CI = no distingue mayúsculas; AS = distingue acentos
  max_size_gb    = 2                                 # máximo para Basic
  zone_redundant = false                             # solo Premium / Business Critical

  tags = local.tags
}
```

> **🔷 Por qué `local.tags` y no `azurerm_resource_group.sql.tags`.** Leer un atributo de otro recurso significa usar el valor que la API *devuelve*, no el que escribiste. Topaz no devuelve las tags del grupo, así que ese valor es `null` tras el `apply` y Terraform aborta con *Provider produced inconsistent final plan … .tags: was cty.MapVal(…), but now null* antes de llegar a crear el servidor. Un `locals` es conocido desde el `plan` y no depende de ninguna respuesta. En Azure real ambas formas funcionan, pero la del `locals` es más clara y es la habitual en módulos.

| **Argumento** | **Qué decide** |
|---|---|
| `name` del servidor | Forma el FQDN `<name>.database.windows.net`, por eso debe ser único globalmente: minúsculas, dígitos y guiones, 1-63 caracteres |
| `minimum_tls_version` | `"1.2"` es el mínimo aceptado hoy; `"1.0"` y `"1.1"` están retirados |
| `dynamic "azuread_administrator"` | Bloque que solo existe si la variable tiene valor. Es el equivalente de `count` para bloques anidados |
| `collation` | Reglas de ordenación y comparación de texto. Cambiarla después obliga a recrear la base de datos |
| `max_size_gb` | Límite de almacenamiento; Basic admite hasta 2 GB. Sin él Terraform usa el máximo del nivel |

---

## 5. Firewall del servidor

El servidor lógico tiene IP pública y escucha en el puerto 1433. Sin reglas de firewall, nadie entra (ni tú). Cada regla es un rango de IPs públicas de origen; los rangos privados como `192.168.x` del original no sirven porque el servidor nunca ve esas direcciones.

```hcl
# firewall.tf
resource "azurerm_mssql_firewall_rule" "admin" {
  count = var.desplegar_sql ? 1 : 0

  name             = "Allow-Admin"
  server_id        = azurerm_mssql_server.lab[0].id
  start_ip_address = var.ip_admin           # una sola IP: inicio = fin
  end_ip_address   = var.ip_admin
}

# 0.0.0.0-0.0.0.0 es una regla especial: NO es "ninguna IP", es "cualquier servicio
# hospedado en Azure", incluidos los de otros clientes. Desactivada por defecto.
resource "azurerm_mssql_firewall_rule" "servicios_azure" {
  count = var.desplegar_sql && var.permitir_servicios_azure ? 1 : 0

  name             = "AllowAllWindowsAzureIps"   # nombre que usa el portal para esta regla
  server_id        = azurerm_mssql_server.lab[0].id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}
```

> ⚠️ **El original abría `0.0.0.0`–`255.255.255.255`.** Eso es todo Internet: bots de fuerza bruta contra el puerto 1433 en minutos, y Microsoft Defender for SQL lo marca como alerta de severidad alta. Y llamarlo "AllowAzureServices" es doblemente engañoso, porque esa regla real es `0.0.0.0–0.0.0.0`. Incluso esta última conviene evitarla: permite conexiones desde cualquier VM o App Service de cualquier suscripción de Azure. Para que tu aplicación llegue al servidor usa reglas de red virtual (`azurerm_mssql_virtual_network_rule`) o, mejor, un **private endpoint** en la subred `snet-backend` de la [página 3](index.md#pagina-3) y `public_network_access_enabled = false`.

---

## 6. Outputs

```hcl
# outputs.tf
output "servidor_fqdn" {
  description = "Nombre DNS del servidor, o null si desplegar_sql = false"
  value       = one(azurerm_mssql_server.lab[*].fully_qualified_domain_name)
}

output "base_datos" {
  description = "Nombre de la base de datos"
  value       = one(azurerm_mssql_database.lab[*].name)
}

output "admin_login" {
  value = var.admin_login
}

output "admin_password" {
  description = "Contraseña generada. Solo visible con: terraform output -raw admin_password"
  value       = random_password.admin.result
  sensitive   = true                        # Terraform la oculta en plan, apply y output
}

output "cadena_sqlcmd" {
  description = "Comando de conexión (la contraseña se pide de forma interactiva)"
  value = var.desplegar_sql ? "sqlcmd -S ${azurerm_mssql_server.lab[0].fully_qualified_domain_name} -d ${azurerm_mssql_database.lab[0].name} -U ${var.admin_login} -N -C" : "SQL no desplegado (desplegar_sql = false)"
}
```

`sensitive = true` evita que el valor aparezca en la consola, pero **no lo cifra en el estado**: `terraform.tfstate` lo contiene en claro. De ahí el `.gitignore` del principio y, en cuanto trabajes en equipo, un backend remoto con cifrado (página de estado remoto).

---

## 7. Despliegue en Topaz

```bash
ls                                                 # firewall.tf outputs.tf providers.tf secretos.tf sql.tf terraform.tfvars variables.tf
terraform init
#   - Installing hashicorp/azurerm v4.x.x...
#   - Installing hashicorp/random v3.x.x...       ← dos providers
terraform validate
terraform plan
#   Plan: 6 to add, 0 to change, 0 to destroy.
#   grupo, random_string, random_password, servidor, base de datos, firewall Allow-Admin
#   administrator_login_password = (sensitive value)   ← nunca aparece en claro
terraform apply -auto-approve
```

Aquí hay dos resultados posibles, y ambos son un éxito del laboratorio:

| **Resultado** | **Qué significa** | **Siguiente paso** |
|---|---|---|
| *Apply complete! Resources: 6 added* | Tu versión de Topaz implementa `Microsoft.Sql` (metadatos; no hay motor SQL real detrás, no podrás conectarte) | Verifica con la CLI (abajo). Si el `plan` posterior propone cambios (por ejemplo `~ tags` en el servidor), añade el atributo a un `ignore_changes` de ese recurso |
| *NoRegisteredProviderFound: Microsoft.Sql* o *EndpointNotFound* en `PUT .../servers/sql-lab-…` | El emulador no incluye Azure SQL. Los dos recursos `random` y el grupo se han creado bien | `echo 'desplegar_sql = false' >> terraform.tfvars`, `apply` de nuevo (limpia el estado), y sigue con el `plan -var desplegar_sql=true` |

```bash
# Lo que funciona en cualquier caso: los secretos existen y están protegidos
terraform output                                   # admin_password = <sensitive>
terraform output -raw admin_password; echo         # se muestra solo si lo pides explícitamente
grep -o '"result": *"[^"]*"' terraform.tfstate     # dos líneas: sufijo y contraseña, en claro

# Si Microsoft.Sql está disponible en tu Topaz (el nombre se toma de la CLI, no del estado)
SRV=$(az sql server list -g rg-sql-001 --query "[0].name" -o tsv)
echo "Servidor: ${SRV:-ninguno}"
az sql server list -g rg-sql-001 --query "[].{servidor:name, fqdn:fullyQualifiedDomainName, tls:minimalTlsVersion}" -o table
az sql db list -g rg-sql-001 -s "$SRV" --query "[].{bd:name, sku:currentServiceObjectiveName}" -o table
az sql server firewall-rule list -g rg-sql-001 -s "$SRV" -o table

# Ejercicios de plan (válidos aunque Microsoft.Sql no exista):
terraform plan -var desplegar_sql=true -var permitir_servicios_azure=true    # + 1 regla 0.0.0.0-0.0.0.0
terraform plan -var admin_login=sa                 # falla en la validación: nombre reservado
terraform plan -var ip_admin=203.0.113.7/32        # falla: aquí va sin máscara
terraform plan -var sku_bd=GP_S_Gen5_1             # ~ sku_name: cambio in-place a serverless

terraform destroy -auto-approve                    # limpieza
```

> **🔷 En Topaz.** Aunque el emulador acepte los recursos, no hay motor de base de datos: `sqlcmd` contra el FQDN no resolverá. El valor de este laboratorio en Topaz está en el flujo de secretos, la validación, el patrón `dynamic` y un `plan` revisable antes de gastar dinero. La conexión real se prueba en la siguiente sección.

---

## 8. Despliegue y conexión en Azure real

Ajustes en `providers.tf` como en páginas anteriores (quitar `metadata_host` y `resource_provider_registrations`, poner tu `subscription_id`), quitar el `ignore_changes` del grupo y asegurar `desplegar_sql = true`. Opcionalmente, añade tu usuario como administrador de Entra ID:

```bash
az login && az account set -s "<tu suscripción>"
echo "entra_admin_object_id = \"$(az ad signed-in-user show --query id -o tsv)\"" >> terraform.tfvars
echo "ip_admin = \"$(curl -s ifconfig.me)\"" >> terraform.tfvars      # sustituye la línea anterior de ip_admin

terraform init -reconfigure
terraform apply -auto-approve                      # Plan: 6 to add; el servidor tarda 1-3 minutos

# Conexión con login SQL (pide la contraseña; pégala desde terraform output -raw admin_password)
$(terraform output -raw cadena_sqlcmd)
#   1> SELECT @@VERSION, DB_NAME();
#   2> GO

# Conexión sin contraseña, con tu identidad de Entra ID
sqlcmd -S $(terraform output -raw servidor_fqdn) -d db-lab -G -N
#   Requiere que tu usuario sea el azuread_administrator del servidor y az login activo

# Crear un usuario de aplicación con permisos mínimos (dentro de sqlcmd, conectado a db-lab)
#   1> CREATE USER app_lab WITH PASSWORD = '<otra contraseña>';
#   2> ALTER ROLE db_datareader ADD MEMBER app_lab;
#   3> ALTER ROLE db_datawriter ADD MEMBER app_lab;
#   4> GO
#   La aplicación nunca debe usar el login de administrador del servidor

terraform destroy -auto-approve                    # Basic cuesta ~5 €/mes; no lo dejes encendido
```

### Conexión desde Python sin credenciales en el código

El original ponía usuario y contraseña dentro de la cadena de conexión y usaba ODBC Driver 17. La versión actual es la 18, que cifra por defecto y exige `Encrypt=yes` explícito o falla con certificados. Las credenciales se leen del entorno; en producción, de Key Vault o mediante identidad gestionada.

```bash
# Terminal: exporta las variables desde los outputs (no las escribas a mano)
export SQL_SERVER=$(terraform output -raw servidor_fqdn)
export SQL_DB=$(terraform output -raw base_datos)
export SQL_USER=$(terraform output -raw admin_login)
export SQL_PASSWORD=$(terraform output -raw admin_password)
pip install "sqlalchemy>=2" pyodbc
```

```python
# conexion.py
import os
from urllib.parse import quote_plus
from sqlalchemy import create_engine, text

# quote_plus escapa caracteres como # o + que romperían la URL
password = quote_plus(os.environ["SQL_PASSWORD"])

url = (
    f"mssql+pyodbc://{os.environ['SQL_USER']}:{password}"
    f"@{os.environ['SQL_SERVER']}:1433/{os.environ['SQL_DB']}"
    "?driver=ODBC+Driver+18+for+SQL+Server&Encrypt=yes&TrustServerCertificate=no"
)

engine = create_engine(url, pool_pre_ping=True)   # reconecta si la BD serverless estaba pausada
with engine.connect() as conn:
    version = conn.execute(text("SELECT @@VERSION")).scalar()
    print(version.splitlines()[0])
```

| **Parámetro** | **Por qué** |
|---|---|
| `ODBC Driver 18` | El 17 está en mantenimiento; el 18 cifra por defecto y valida el certificado |
| `Encrypt=yes` + `TrustServerCertificate=no` | Azure SQL usa certificados válidos: no hay motivo para confiar a ciegas. Es la combinación que `sqlcmd -N -C` relaja solo para pruebas |
| `pool_pre_ping=True` | Comprueba la conexión antes de usarla; imprescindible con serverless, que cierra sesiones al pausarse |
| Variables de entorno | El código no cambia entre laboratorio, CI y producción; solo cambia de dónde salen las variables |

> **🔷 Un paso más allá.** Si la aplicación corre en Azure (App Service, Container Apps, la VM de la [página 2](index.md#pagina-2)), activa su identidad gestionada, créala como usuario en la base de datos (`CREATE USER [nombre-app] FROM EXTERNAL PROVIDER`) y conecta con `Authentication=ActiveDirectoryMsi` en la cadena. No hay contraseña que rotar ni filtrar.

---

## 9. Errores comunes

> ⚠️ **Solución de problemas**
> 
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | *Failed to query available provider packages* para `random` | Añadiste el bloque `random` a `required_providers` después del `init`. Repite `terraform init` |
> | *Provider produced inconsistent final plan* … *.tags: was cty.MapVal(…), but now null* | Un recurso copia `tags = azurerm_resource_group.X.tags` y Topaz no devuelve las tags del grupo, así que el valor derivado pasa a `null` tras crearlo. Declara las tags en un `locals` y referencia `local.tags` en todos los recursos; nunca leas las tags de otro recurso. No es un fallo de `Microsoft.Sql`: el error ocurre antes de llamar a esa API. El grupo y los `random` ya están en el estado; tras corregir, el `apply` muestra *3 to add* |
> | *NoRegisteredProviderFound: Microsoft.Sql* / *EndpointNotFound* en `.../servers/` | Tu Topaz no implementa Azure SQL: `desplegar_sql = false`, vuelve a aplicar y continúa con `plan` |
> | *Output "servidor_fqdn" not found* al encadenar con la CLI | El `apply` falló antes de escribir los outputs, o `desplegar_sql = false`. Toma el nombre del servidor de la CLI (`SRV=$(az sql server list … -o tsv)`) en lugar del estado, como en la sección 4.7 |
> | *NameAlreadyExists* / *server name is already in use* | El nombre del servidor es global. Has quitado el sufijo aleatorio o alguien usó el mismo. Restaura `random_string.sufijo` |
> | *InvalidLoginName* / *login name is reserved* | Nombres como `sa` o `admin` están prohibidos. La `validation` de `admin_login` lo detecta antes del `apply`; si la quitaste, vuelve a ponerla |
> | *PasswordNotComplex* | Has bajado `length` o quitado los `min_*` de `random_password`. Mínimo 8 caracteres y 3 de 4 categorías; el laboratorio usa 24 y las 4 |
> | *Unsupported attribute* en `azurerm_mssql_server.lab.id` | Con `count` es una lista: `lab[0].id` o `one(lab[*].id)` |
> | *Client with IP address 'x.x.x.x' is not allowed to access* (error 40615) | Tu IP pública cambió: `curl -s ifconfig.me`, actualiza `ip_admin` y `apply`. El mensaje incluye la IP que ve el servidor: úsala |
> | *Login failed for user* (18456) | Contraseña mal pegada (los caracteres `#` o `%` se pierden en algunos terminales) o login distinto de `admin_login`. Usa `terraform output -raw` y variables de entorno |
> | *SSL Provider: certificate verify failed* / *Encryption not supported* | ODBC Driver 17 o `Encrypt` ausente. Instala el 18 y usa `Encrypt=yes`. En `sqlcmd`, `-N -C` solo para pruebas |
> | *Database is currently unavailable* / primera conexión tarda >30 s | Serverless en pausa reanudándose. Reintenta o usa `pool_pre_ping`. No es un fallo |
> | *Defender for SQL: acceso desde una IP inusual / regla de firewall demasiado permisiva* | Alguien puso `0.0.0.0-255.255.255.255`. Bórrala; nunca hay un motivo legítimo |
> | El `plan` propone recrear la base de datos (*must be replaced*) | Has cambiado `collation` o el nombre. Ambos fuerzan destroy/create con pérdida de datos. Si es intencionado, exporta antes con `az sql db export` |
> | La contraseña aparece en un `git diff` | El estado se ha versionado. Añade `.gitignore`, elimina el archivo del historial (`git filter-repo`) y **rota la contraseña**: `terraform apply -replace random_password.admin` |

---

## 10. Autoevaluación

1. **¿Qué diferencia hay entre el servidor lógico y la base de datos, y qué se paga?**
   El servidor es un contenedor administrativo gratuito (login, firewall, FQDN); cada base de datos tiene su propio nivel de servicio y es lo que se factura.
2. **¿Por qué el nombre del servidor lleva un sufijo aleatorio?**
   Forma parte de un FQDN público (`.database.windows.net`) y debe ser único en todo Azure.
3. **¿Qué protege `sensitive = true` y qué no?**
   Oculta el valor en la salida de plan, apply y output. No cifra el estado: ahí sigue en claro, por eso el estado no se versiona y se cifra en remoto.
4. **¿Por qué las tags se declaran en un `locals` en lugar de copiarlas del grupo de recursos?**
   Leer `azurerm_resource_group.X.tags` usa el valor que devuelve la API, no el escrito. Si la API no lo devuelve (Topaz), pasa a `null` tras el `apply` y Terraform aborta con *inconsistent final plan*. Un `locals` es conocido desde el `plan`.
5. **¿Qué significa la regla de firewall `0.0.0.0–0.0.0.0`?**
   No es "ninguna IP": permite conexiones desde cualquier servicio hospedado en Azure, de cualquier cliente. Se sustituye por reglas de vnet o private endpoint.
6. **¿Por qué no funciona una regla de firewall con `192.168.0.0–192.168.0.255`?**
   El servidor solo ve IPs públicas de origen; los rangos privados nunca llegan a él.
7. **¿Qué hace `LicenseIncluded` y cuándo importa?**
   Indica que el precio del vCore incluye la licencia; `BasePrice` la descuenta con Azure Hybrid Benefit. En el modelo DTU (Basic, S0…) se ignora. No tiene nada que ver con "gratis".
8. **¿Para qué sirve `dynamic "azuread_administrator"` con `for_each` sobre `[]` o `[1]`?**
   Hace opcional un bloque anidado: con la lista vacía no se genera, con un elemento se genera una vez. Es el `count` de los bloques.
9. **¿Por qué la aplicación no debe conectarse con el login de administrador?**
   Tiene control total sobre todas las bases del servidor. Se crea un usuario con `db_datareader`/`db_datawriter`, o mejor una identidad gestionada sin contraseña.

---

## 11. Referencias

- [`azurerm_mssql_server`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/mssql_server), [`azurerm_mssql_database`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/mssql_database), [`azurerm_mssql_firewall_rule`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/mssql_firewall_rule), [`azurerm_mssql_virtual_network_rule`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/mssql_virtual_network_rule)
- [`random_password`](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) y [outputs `sensitive`](https://developer.hashicorp.com/terraform/language/values/outputs#sensitive-suppressing-values-in-cli-output)
- [Valores `locals`](https://developer.hashicorp.com/terraform/language/values/locals) y [bloques `dynamic`](https://developer.hashicorp.com/terraform/language/expressions/dynamic-blocks)
- [Modelos de compra DTU y vCore](https://learn.microsoft.com/es-es/azure/azure-sql/database/purchasing-models) y [nivel serverless](https://learn.microsoft.com/es-es/azure/azure-sql/database/serverless-tier-overview)
- [Reglas de firewall de Azure SQL](https://learn.microsoft.com/es-es/azure/azure-sql/database/firewall-configure) y [private endpoints](https://learn.microsoft.com/es-es/azure/azure-sql/database/private-endpoint-overview)
- [Autenticación con Microsoft Entra ID](https://learn.microsoft.com/es-es/azure/azure-sql/database/authentication-aad-configure) e [identidades gestionadas para conectarse a SQL](https://learn.microsoft.com/es-es/azure/app-service/tutorial-connect-msi-sql-database)
- [ODBC Driver 18](https://learn.microsoft.com/es-es/sql/connect/odbc/download-odbc-driver-for-sql-server) y [`sqlcmd`](https://learn.microsoft.com/es-es/sql/tools/sqlcmd/sqlcmd-utility)
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)