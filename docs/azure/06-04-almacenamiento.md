# 💾 Almacenamiento

> Una cuenta de almacenamiento es el recurso más barato y más ubicuo de Azure: guarda blobs, archivos compartidos, colas y tablas, y también el estado remoto de Terraform que usarás en la siguiente página. En este laboratorio crearás una cuenta con nombre válido y único, un contenedor privado, un compartido de Azure Files y una política de ciclo de vida que enfría y borra datos antiguos. Y aprenderás la diferencia que más importa en **Topaz**: el *plano de gestión* (crear la cuenta y sus contenedores) funciona en el emulador; el *plano de datos* (subir y leer blobs) solo existe en Azure real.

**🎯 Objetivos de aprendizaje**
- Elegir tipo de cuenta, redundancia y nivel de acceso, y estimar su coste.
- Generar un nombre de cuenta válido (3-24 caracteres, minúsculas y dígitos, único global) y validarlo antes del `apply`.
- Distinguir plano de gestión y plano de datos, y configurar el provider para un entorno sin acceso al segundo.
- Endurecer la cuenta: TLS 1.2, solo HTTPS, sin blobs públicos, soft delete y versionado.
- Escribir una política de ciclo de vida real y acceder a los datos con identidad (RBAC) en lugar de claves.

> **🔷 Requisitos previos.** [Páginas 1](index.md#pagina-1) a 4 completadas y destruidas, `~/tf-intro/providers.tf` disponible, `az account show --query environmentName -o tsv` → `Topaz`.

---

## 5.1. Anatomía de una cuenta de almacenamiento

```text
rg-st-001
└── Cuenta stlab<sufijo>  (StorageV2, Standard, LRS, Hot, TLS 1.2, solo HTTPS)
    ├── Blob    https://stlab<sufijo>.blob.core.windows.net/
    │   ├── contenedor "datos" (privado)          ◄── plano de gestión: ARM      ✅ Topaz
    │   │   └── hola.txt                          ◄── plano de datos: blob API    ❌ Topaz
    │   └── política de ciclo de vida             ◄── ARM                          ✅ Topaz
    ├── Files   https://stlab<sufijo>.file.core.windows.net/
    │   └── compartido "compartido" (5 GiB, SMB)  ◄── ARM                          ✅ Topaz
    └── (Queue, Table)                            ◄── no se usan aquí
```

| **Servicio** | **Para qué** | **Recurso Terraform** | **En Topaz** |
|---|---|---|---|
| Blob Storage | Objetos: archivos, imágenes, copias de seguridad, estado de Terraform | `azurerm_storage_container` (ARM), `azurerm_storage_blob` (datos) | ✅ contenedor / ❌ blob |
| Azure Files | Carpeta compartida SMB/NFS montable desde VMs y contenedores | `azurerm_storage_share` (ARM con `storage_account_id`) | ✅ |
| Disk Storage | Discos de VM. Es el `os_disk` de la [página 2](index.md#pagina-2); no vive en una cuenta de almacenamiento | `azurerm_managed_disk` | ❌ (Microsoft.Compute) |

### Redundancia y nivel de acceso

| **`account_replication_type`** | **Copias** | **Sobrevive a** | **Coste relativo** |
|---|---|---|---|
| `LRS` | 3 en un centro de datos | Fallo de disco o rack | 1× (~0,02 €/GB/mes) |
| `ZRS` | 3 en zonas distintas | Caída de un centro de datos | ~1,25× |
| `GRS` / `RAGRS` | 3 + 3 en región emparejada | Caída regional (RA: lectura en la secundaria) | ~2× |
| `GZRS` / `RAGZRS` | ZRS + 3 remotas | Todo lo anterior | ~2,5× |

El `access_tier` (`Hot`, `Cool`, `Cold`) fija el valor por defecto de los blobs: Hot cobra más por almacenar y menos por leer; Cool y Cold al revés, con penalización si borras antes de 30/90 días. `Archive` solo se asigna por blob (o por política) y tarda horas en rehidratarse. El original recomendaba LRS "para almacenamiento localmente redundante", que es una tautología: la recomendación real es **LRS para laboratorio y datos regenerables; ZRS o GZRS para lo que no puedas perder**.

---

## 5.2. Plano de gestión y plano de datos

Esta distinción explica casi todos los problemas de Storage con Terraform, y todos los de Topaz:

| **&nbsp;** | **Plano de gestión (ARM)** | **Plano de datos** |
|---|---|---|
| Endpoint | `management.azure.com` (en Topaz, `topaz.local.dev`) | `<cuenta>.blob.core.windows.net`, `.file.`, `.queue.`… |
| Qué hace | Crear la cuenta, contenedores, compartidos, políticas, propiedades | Subir, leer, listar, borrar blobs y archivos |
| Autenticación | Entra ID + RBAC de ARM (Contributor…) | Clave de cuenta, SAS o Entra ID + RBAC de datos (*Storage Blob Data Contributor*) |
| Recursos azurerm 4.x | `azurerm_storage_account`, `_container` y `_share` con `storage_account_id`, `_management_policy` | `azurerm_storage_blob`, `_share_file`, `_queue`, `_table`, y `_container` con el argumento antiguo `storage_account_name` |
| En Topaz | ✅ | ❌ el nombre DNS no resuelve |

> **🔷 En Topaz.** Al leer una cuenta, el provider intenta por defecto consultar propiedades por el plano de datos. El bloque `features { storage { data_plane_available = false } }` de la sección 5.3 le indica que no lo haga; sin él, cada `plan` fallaría con *no such host*. Y los recursos de datos (`azurerm_storage_blob`) van detrás de `subir_blobs`, como la VM, el peering y SQL en páginas anteriores.

---

## 5.3. Preparar el directorio, providers y variables

```bash
mkdir -p ~/tf-st && cd ~/tf-st
cp ~/tf-sql/providers.tf .           # ya incluye el provider random
printf 'terraform.tfstate*\n.terraform/\n*.tfvars\n' > .gitignore
```

```hcl
# providers.tf  (bloque provider; el bloque terraform queda como en la página 4)
provider "azurerm" {
  features {
    storage {
      data_plane_available = false     # Topaz: no hay blob.core.windows.net. En Azure real: true (o quitar)
    }
  }
  storage_use_azuread             = true   # plano de datos con Entra ID, no con la clave de cuenta
  metadata_host                   = "topaz.local.dev:8899"
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}
```

```hcl
# variables.tf
variable "prefijo" {
  type        = string
  description = "Prefijo del nombre de la cuenta; se completa con un sufijo aleatorio"
  default     = "stlab"
  validation {
    condition     = can(regex("^[a-z0-9]{3,16}$", var.prefijo))
    error_message = "Solo minúsculas y dígitos, 3-16 caracteres (el sufijo añade 8 y el total no puede pasar de 24)."
  }
}

variable "replicacion" {
  type        = string
  description = "LRS para laboratorio; ZRS o GZRS para datos que no puedas perder"
  default     = "LRS"
  validation {
    condition     = contains(["LRS", "ZRS", "GRS", "RAGRS", "GZRS", "RAGZRS"], var.replicacion)
    error_message = "Valores válidos: LRS, ZRS, GRS, RAGRS, GZRS, RAGZRS."
  }
}

variable "subir_blobs" {
  type        = bool
  description = "Crear blobs de ejemplo (plano de datos). false en Topaz"
  default     = false
}

variable "asignar_rbac" {
  type        = bool
  description = "Darte el rol Storage Blob Data Contributor sobre la cuenta (Microsoft.Authorization). false en Topaz"
  default     = false
}
```

```hcl
# terraform.tfvars  (valores de Topaz; en Azure real se cambian los dos a true)
subir_blobs  = false
asignar_rbac = false
```

---

## 5.4. La cuenta de almacenamiento

```hcl
# storage.tf
locals {
  tags = { entorno = "lab", gestion = "terraform" }   # fuente única ([página 4](index.md#pagina-4))
}

resource "azurerm_resource_group" "st" {
  name     = "rg-st-001"
  location = "eastus"
  tags     = local.tags
  lifecycle { ignore_changes = [tags] }     # Topaz no devuelve las tags del grupo
}

resource "random_string" "sufijo" {
  length  = 8
  upper   = false
  special = false                           # solo [a-z0-9]: las únicas letras válidas en el nombre
}

resource "azurerm_storage_account" "lab" {
  name                = "${var.prefijo}${random_string.sufijo.result}"   # stlab + 8 = 13 caracteres, único global
  resource_group_name = azurerm_resource_group.st.name
  location            = azurerm_resource_group.st.location

  account_kind             = "StorageV2"    # el único que conviene hoy: blobs, files, colas, tablas, niveles
  account_tier             = "Standard"     # Premium = SSD, solo para un servicio y sin niveles
  account_replication_type = var.replicacion
  access_tier              = "Hot"

  # Endurecimiento: todo esto debería ser el valor por defecto y no lo es
  min_tls_version                 = "TLS1_2"
  https_traffic_only_enabled      = true
  allow_nested_items_to_be_public = false   # ningún contenedor podrá ser público, aunque alguien lo pida
  shared_access_key_enabled       = true    # false cuando toda tu tooling use Entra ID (ver 5.8)
  public_network_access_enabled   = true    # false + private endpoint en producción

  blob_properties {
    versioning_enabled = true               # cada sobrescritura conserva la versión anterior
    delete_retention_policy { days = 7 }    # soft delete de blobs
    container_delete_retention_policy { days = 7 }
  }

  tags = local.tags
}
```

| **Regla del nombre** | **Motivo** |
|---|---|
| 3 a 24 caracteres | El original, `storageaccountterraformdemo`, tiene 27: Azure lo rechaza antes de crear nada |
| Solo minúsculas y dígitos | Forma parte de un nombre DNS (`stlab….blob.core.windows.net`); sin guiones ni mayúsculas |
| Único en todo Azure | Mismo motivo. De ahí el sufijo aleatorio, como en el servidor SQL |

> ⚠️ **No existe "un blob público en un contenedor privado".** El original creaba `public-blob.txt` con metadatos "Archivo público" dentro de un contenedor `private`: el acceso anónimo se decide a nivel de contenedor (`blob` o `container`), y aquí lo bloqueamos del todo con `allow_nested_items_to_be_public = false`. Para compartir un archivo concreto se genera una **SAS** con caducidad (`az storage blob generate-sas`, sección 5.8) o se concede un rol RBAC de datos a la identidad que lo necesite. El "público" de verdad, para una web estática, se hace con `azurerm_storage_account_static_website` o con Azure CDN delante, nunca abriendo el contenedor.

> **🔷 Soft delete y versionado.** Con `delete_retention_policy` un blob borrado se puede recuperar durante 7 días; con `versioning_enabled` cada sobrescritura conserva la versión anterior. Es la "política de retención para evitar pérdida de datos" que el original mencionaba sin implementar. Cuesta el almacenamiento de las versiones retenidas, por eso la política de ciclo de vida de la sección 5.6 las borra a los 30 días.

---

## 5.5. Contenedor, compartido de archivos y blobs opcionales

En azurerm 4.x el contenedor y el compartido admiten `storage_account_id`: el provider los crea por ARM, sin tocar el plano de datos. El argumento antiguo `storage_account_name` del original sigue existiendo, pero obliga al provider a hablar con `blob.core.windows.net`, que en Topaz no existe.

```hcl
# contenido.tf
resource "azurerm_storage_container" "datos" {
  name                  = "datos"                            # 3-63, minúsculas, dígitos y guiones
  storage_account_id    = azurerm_storage_account.lab.id     # ARM: funciona en Topaz. NO storage_account_name
  container_access_type = "private"                          # la cuenta lo forzaría igual (allow_nested_items_to_be_public = false)
}

resource "azurerm_storage_share" "compartido" {
  name               = "compartido"
  storage_account_id = azurerm_storage_account.lab.id
  quota              = 5                                     # GiB máximos; se paga lo usado, no la cuota
}

# Plano de datos: solo en Azure real (subir_blobs = true)
resource "azurerm_storage_blob" "hola" {
  count = var.subir_blobs ? 1 : 0

  name                   = "hola.txt"
  storage_account_name   = azurerm_storage_account.lab.name  # los blobs sí usan el nombre: van por el plano de datos
  storage_container_name = azurerm_storage_container.datos.name
  type                   = "Block"
  source_content         = "Hola desde Terraform\n"          # contenido inline; source = "ruta/local" para archivos
  content_type           = "text/plain; charset=utf-8"
  metadata               = { origen = "terraform" }

  depends_on = [azurerm_role_assignment.blob_contributor]    # sin el rol, el PUT del blob devuelve 403 (ver 5.8)
}
```

El `depends_on` del blob apunta a un rol RBAC que solo se crea en Azure real, pero Terraform exige que el recurso esté *declarado* aunque tenga `count = 0`; sin el archivo, `terraform validate` falla con *Reference to undeclared resource*. Por eso el archivo se crea ya, y en la sección 5.8 solo se activa:

```hcl
# rbac.tf  (count = 0 en Topaz; en Azure real da Storage Blob Data Contributor a tu usuario)
variable "rbac_object_id" {
  type        = string
  description = "Object ID de la identidad que recibirá Storage Blob Data Contributor (null en Topaz)"
  default     = null
}

resource "azurerm_role_assignment" "blob_contributor" {
  count = var.asignar_rbac && var.rbac_object_id != null ? 1 : 0

  scope                = azurerm_storage_account.lab.id       # ámbito mínimo: la cuenta, no el grupo ni la suscripción
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = var.rbac_object_id
}
```

| **Argumento** | **Qué decide** |
|---|---|
| `container_access_type` | `private` (solo autenticados), `blob` (lectura anónima de blobs conocidos), `container` (además lista el contenido). Los dos últimos requieren `allow_nested_items_to_be_public = true` en la cuenta |
| `quota` del compartido | Tope en GiB, hasta 5120 (100 TiB con *large file shares*). En Standard se factura el espacio ocupado |
| `type = "Block"` | Blob en bloques: el tipo general. `Page` es para discos y `Append` para logs que solo crecen |
| `source_content` / `source` | Terraform sube el contenido y detecta cambios por hash. Sirve para semillas y configuración; para datos de aplicación usa `azcopy` o el SDK, no Terraform |
| `depends_on` hacia un recurso con `count = 0` | Válido: la dependencia se establece sobre la *declaración*, no sobre las instancias. Con cero instancias no aporta orden; con una, garantiza que el rol exista antes del blob |

---

## 5.6. Política de ciclo de vida

El original escribía la política con una sintaxis inventada (`policy { rules = [ { … } ] }`) que `terraform validate` rechaza. La estructura real son bloques `rule`, cada uno con `filters` y `actions`. La política se aplica una vez al día y actúa sobre la fecha de última modificación.

```hcl
# ciclo_vida.tf
resource "azurerm_storage_management_policy" "lab" {
  storage_account_id = azurerm_storage_account.lab.id

  rule {
    name    = "enfriar-y-borrar-logs"
    enabled = true
    filters {
      blob_types   = ["blockBlob"]
      prefix_match = ["datos/logs/"]         # contenedor/prefijo; el original ponía solo el contenedor
    }
    actions {
      base_blob {
        tier_to_cool_after_days_since_modification_greater_than    = 30     # Hot → Cool
        tier_to_archive_after_days_since_modification_greater_than = 90     # Cool → Archive (horas para leer)
        delete_after_days_since_modification_greater_than          = 365
      }
      snapshot { delete_after_days_since_creation_greater_than = 30 }
      version  { delete_after_days_since_creation = 30 }                    # versiones del versionado de 5.4
    }
  }

  rule {
    name    = "limpiar-versiones-antiguas"
    enabled = true
    filters { blob_types = ["blockBlob"] }   # sin prefix_match: toda la cuenta
    actions {
      version { delete_after_days_since_creation = 60 }
    }
  }
}
```

| **Nivel** | **Almacenar (por GB/mes)** | **Leer** | **Permanencia mínima** |
|---|---|---|---|
| `Hot` | ~0,018 € | Barato, inmediato | Ninguna |
| `Cool` | ~0,01 € | Más caro, inmediato | 30 días (penalización si borras antes) |
| `Cold` | ~0,004 € | Caro, inmediato | 90 días |
| `Archive` | ~0,002 € | Muy caro; rehidratar tarda hasta 15 h | 180 días |

> ⚠️ **`prefix_match` incluye el contenedor.** El original ponía `prefix_match = ["container-terraform"]`, que afecta a *todos* los blobs de ese contenedor, y además una regla de borrado a 30 días sin pasar por niveles intermedios. Una política de ciclo de vida mal escrita es una herramienta de borrado masivo que se ejecuta sola cada noche: prueba siempre con `enabled = false` o con un prefijo estrecho, y recuerda que `terraform destroy` de la política no recupera nada.

---

## 5.7. Outputs y despliegue en Topaz

```hcl
# outputs.tf
output "cuenta" {
  description = "Nombre de la cuenta (único global)"
  value       = azurerm_storage_account.lab.name
}

output "blob_endpoint" {
  description = "URL base del servicio Blob; la usan los SDK con Entra ID"
  value       = azurerm_storage_account.lab.primary_blob_endpoint
}

output "contenedor" {
  value = azurerm_storage_container.datos.name
}

output "compartido" {
  value = azurerm_storage_share.compartido.name
}

output "cadena_conexion" {
  description = "Solo para herramientas sin soporte de Entra ID. Contiene la clave de cuenta"
  value       = azurerm_storage_account.lab.primary_connection_string
  sensitive   = true
}
```

```bash
ls                                                 # ciclo_vida.tf contenido.tf outputs.tf providers.tf rbac.tf storage.tf terraform.tfvars variables.tf
terraform init
terraform validate                                 # Success! Si falla con "undeclared resource", falta rbac.tf (5.5)
terraform plan
#   Plan: 6 to add, 0 to change, 0 to destroy.
#   grupo, random_string, cuenta, contenedor, compartido, política  (blob y rol: count = 0, ya declarados)
terraform apply -auto-approve
#   Apply complete! Resources: 6 added

terraform output                                   # cadena_conexion = <sensitive>

# Verificación por ARM (los subcomandos *-rm no tocan el plano de datos)
ST=$(terraform output -raw cuenta)
az storage account show -g rg-st-001 -n "$ST" \
  --query "{nombre:name, sku:sku.name, tls:minimumTlsVersion, https:enableHttpsTrafficOnly, publico:allowBlobPublicAccess}" -o table
az storage container-rm list --storage-account "$ST" -g rg-st-001 --query "[].{contenedor:name, acceso:publicAccess}" -o table
az storage share-rm list --storage-account "$ST" -g rg-st-001 --query "[].{compartido:name, cuotaGiB:shareQuota}" -o table
az storage account management-policy show --account-name "$ST" -g rg-st-001 --query "policy.rules[].{regla:name, activa:enabled}" -o table

# Lo que NO funciona en Topaz: el plano de datos
az storage blob list --account-name "$ST" -c datos --auth-mode login   # no such host / could not resolve

# Ejercicios de plan
terraform plan -var prefijo=StorageAccountDemo      # falla en la validación: mayúsculas y longitud
terraform plan -var replicacion=ZRS                 # ~ account_replication_type: cambio in-place (LRS→ZRS sí; GRS→ZRS requiere migración)
terraform plan -var subir_blobs=true                # + azurerm_storage_blob.hola[0]: se planifica aunque no pueda aplicarse aquí

terraform destroy -auto-approve
```

Si un `plan` posterior al `apply` propone cambios en `blob_properties`, `access_tier` o `min_tls_version`, el emulador no está devolviendo esas propiedades: añade las que veas a `lifecycle { ignore_changes = [...] }` en la cuenta, solo mientras trabajes en Topaz.

> **🔷 Por qué importa esta cuenta.** El backend `azurerm` de Terraform guarda el estado remoto en un contenedor de blobs exactamente como `datos`: con versionado, soft delete y sin acceso público. En la página siguiente reutilizarás esta configuración, con `use_azuread_auth = true`, para sacar el estado del disco local.

---

## 5.8. Azure real: RBAC, blobs y acceso sin claves

El original se conectaba con la clave de cuenta pegada en la cadena de conexión. Esa clave da control total sobre todos los datos, no caduca y no identifica a quién la usa. La alternativa es **RBAC de datos**: el rol *Storage Blob Data Contributor* que declaraste en `rbac.tf` (sección 5.5), ahora activado con `asignar_rbac = true` y tu Object ID, para tu usuario hoy y para la identidad gestionada de la aplicación después. Con `storage_use_azuread = true` en el provider, el propio Terraform sube el blob con tu identidad, no con la clave.

```bash
# providers.tf: quitar metadata_host y resource_provider_registrations, poner tu subscription_id,
# y cambiar data_plane_available a true (o eliminar el bloque storage). storage_use_azuread se queda.
az login && az account set -s "<tu suscripción>"
cat > terraform.tfvars <<EOF
subir_blobs    = true
asignar_rbac   = true
rbac_object_id = "$(az ad signed-in-user show --query id -o tsv)"
EOF

terraform init -reconfigure
terraform apply -auto-approve                      # Plan: 8 to add. El rol tarda 1-5 min en propagarse: si el blob
                                                   # falla con 403, espera y repite el apply

ST=$(terraform output -raw cuenta)
az storage blob list --account-name "$ST" -c datos --auth-mode login -o table     # --auth-mode login = Entra ID, no clave
az storage blob download --account-name "$ST" -c datos -n hola.txt --auth-mode login -f /dev/stdout

# Compartir un blob durante una hora sin abrir el contenedor: SAS delegada por usuario
az storage blob generate-sas --account-name "$ST" -c datos -n hola.txt \
  --permissions r --expiry "$(date -u -d '+1 hour' +%Y-%m-%dT%H:%MZ)" \
  --auth-mode login --as-user --full-uri -o tsv

# Montar el compartido desde Linux (requiere clave o Kerberos; SMB 3 cifrado)
sudo mkdir -p /mnt/compartido
sudo mount -t cifs "//$ST.file.core.windows.net/compartido" /mnt/compartido \
  -o vers=3.1.1,username=$ST,password="$(az storage account keys list -g rg-st-001 -n $ST --query '[0].value' -o tsv)",serverino

terraform destroy -auto-approve                    # ~0,05 €/mes con estos datos, pero limpia igual
```

### Acceso desde Python con identidad

```bash
export STORAGE_BLOB_ENDPOINT=$(terraform output -raw blob_endpoint)
pip install azure-identity azure-storage-blob
```

```python
# blobs.py
import os
from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient

# DefaultAzureCredential prueba en orden: variables de entorno, identidad gestionada, az login...
# El mismo código funciona en tu portátil y en una VM o App Service con identidad gestionada.
client = BlobServiceClient(os.environ["STORAGE_BLOB_ENDPOINT"], credential=DefaultAzureCredential())
contenedor = client.get_container_client("datos")

contenedor.upload_blob("desde-python.txt", b"Escrito con RBAC, sin clave de cuenta\n", overwrite=True)

for blob in contenedor.list_blobs():
    print(f"{blob.name:25} {blob.size:6} B  {blob.blob_tier}")
```

| **Método de acceso** | **Caduca** | **Identifica al llamante** | **Uso** |
|---|---|---|---|
| Clave de cuenta | No | No | ❌ Solo herramientas heredadas. Desactívala con `shared_access_key_enabled = false` cuando puedas |
| SAS | Sí | No (sí, si es delegada por usuario) | ⚠️ Compartir un objeto con alguien externo, con caducidad corta |
| Entra ID + RBAC de datos | Token de 1 h, renovado solo | Sí, en los logs | ✅ Personas y aplicaciones. Con identidad gestionada no hay ningún secreto |

---

## 5.9. Errores comunes

> ⚠️ **Solución de problemas**
> 
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | *AccountNameInvalid* / *name can only consist of lowercase letters and numbers, and must be between 3 and 24 characters* | Nombre con mayúsculas, guiones o demasiado largo (el original tenía 27). La `validation` de `prefijo` lo detecta antes; si la quitaste, vuelve a ponerla |
> | *StorageAccountAlreadyTaken* | El nombre es global y alguien lo tiene. Has quitado el sufijo aleatorio; restáuralo o cambia `prefijo` |
> | *dial tcp: lookup stlab….blob.core.windows.net: no such host* en `plan` o `apply` | El provider intenta el plano de datos. En Topaz: `data_plane_available = false` y `storage_account_id` en contenedor y compartido. En Azure real: la cuenta tiene `public_network_access_enabled = false` o reglas de red que bloquean tu IP |
> | *Unsupported argument: storage_account_id* | Provider anterior a 4.9. `terraform init -upgrade` con `version = "~> 4.0"` |
> | *"storage_account_name": conflicts with storage_account_id* | Has puesto ambos en el contenedor. Solo `storage_account_id` |
> | *Reference to undeclared resource* en el `depends_on` del blob | Falta `rbac.tf`. `depends_on` exige que el recurso esté declarado aunque tenga `count = 0`; créalo antes del primer `validate`, como indica la sección 5.5 |
> | *AuthorizationPermissionMismatch* (403) al crear el blob o en `az storage blob list` | Tienes rol de ARM (Contributor) pero no de datos. Necesitas *Storage Blob Data Contributor*; si acabas de asignarlo, espera hasta 5 minutos y repite. Con `az`, añade `--auth-mode login` |
> | *PublicAccessNotPermitted* | Contenedor con `container_access_type = "blob"` en una cuenta con `allow_nested_items_to_be_public = false`. Es la cuenta haciendo su trabajo: usa SAS o RBAC en lugar de acceso anónimo |
> | *KeyBasedAuthenticationNotPermitted* | `shared_access_key_enabled = false` y una herramienta usa la clave (o `az` sin `--auth-mode login`). Cambia la herramienta a Entra ID; Azure Files por SMB sigue necesitando clave o Kerberos |
> | *Unsupported block type: policy* / *rules* | Sintaxis del original. La política se escribe con bloques `rule` → `filters` + `actions` → `base_blob` / `snapshot` / `version` |
> | *ContainerBeingDeleted* / *The specified container is being deleted* al recrear | Soft delete de contenedores retiene el nombre unos minutos tras borrarlo. Espera o usa otro nombre; en un destroy completo no ocurre |
> | El `plan` propone *replace* de la cuenta | Has cambiado `name`, `account_kind`, `account_tier` o `location`: todos fuerzan recreación con pérdida de datos. `account_replication_type` y `access_tier` sí cambian in-place |
> | Un `plan` tras el `apply` en Topaz muestra `~ blob_properties` o `~ access_tier` | El emulador no devuelve la propiedad. `ignore_changes` solo en Topaz; quítalo antes de ir a Azure real |
> | Aparece una clave de cuenta en `git diff` | El estado se ha versionado (contiene `primary_access_key` en claro). Rota las claves: `az storage account keys renew -g rg-st-001 -n $ST --key primary`, y arregla el `.gitignore` |

---

## 5.10. Autoevaluación

1. **¿Por qué `storageaccountterraformdemo` no es un nombre válido?**
   Tiene 27 caracteres y el máximo es 24. Además debe ser único en todo Azure, por eso lleva sufijo aleatorio.
2. **¿Qué diferencia hay entre plano de gestión y plano de datos, y cuál funciona en Topaz?**
   El de gestión (ARM) crea cuenta, contenedores, compartidos y políticas; el de datos (`blob.core.windows.net`) sube y lee contenido. Topaz solo tiene el primero.
3. **¿Por qué el contenedor usa `storage_account_id` y el blob `storage_account_name`?**
   El contenedor puede crearse por ARM (id); el blob es contenido y solo existe en el plano de datos, que se dirige por nombre de cuenta.
4. **¿Por qué `depends_on = [azurerm_role_assignment.blob_contributor]` falla si el archivo `rbac.tf` no existe, aunque el rol tenga `count = 0`?**
   `count = 0` crea cero instancias de un recurso que sigue declarado; sin la declaración, la referencia no existe en el grafo. Los interruptores del curso funcionan porque el bloque siempre está presente.
5. **¿Qué garantiza `allow_nested_items_to_be_public = false`?**
   Que ningún contenedor de la cuenta pueda tener acceso anónimo, aunque alguien declare `container_access_type = "blob"`. Es un candado a nivel de cuenta.
6. **¿Qué hace `data_plane_available = false` y cuándo se quita?**
   Indica al provider que no consulte propiedades por el plano de datos al leer la cuenta. Es necesario en Topaz (el DNS no resuelve) y se quita, o se pone a `true`, en Azure real.
7. **¿Qué protege el soft delete y qué protege el versionado?**
   Soft delete recupera blobs y contenedores borrados durante N días; el versionado conserva la versión anterior en cada sobrescritura. Juntos cubren borrado y modificación accidental; la política de ciclo de vida limita su coste.
8. **¿Por qué `prefix_match = ["container-terraform"]` con borrado a 30 días era peligroso?**
   El prefijo incluye el contenedor, así que afectaba a todos sus blobs, y borraba sin pasar por Cool ni Archive. La política se ejecuta sola cada día y el borrado no se deshace.
9. **¿Qué tiene de malo la clave de cuenta en una cadena de conexión?**
   Da control total, no caduca y no identifica a quién la usa. Se sustituye por RBAC de datos (*Storage Blob Data Contributor*) con Entra ID; para compartir puntualmente, una SAS con caducidad.
10. **¿Qué campos de la cuenta fuerzan una recreación si los cambias?**
    `name`, `account_kind`, `account_tier` y `location`. `account_replication_type` y `access_tier` cambian in-place.
11. **¿Qué relación tiene esta cuenta con la siguiente página?**
    El backend `azurerm` guarda el estado remoto de Terraform en un contenedor de blobs con exactamente esta configuración: privado, versionado, con soft delete y acceso por Entra ID.

---

## 5.11. Referencias

- [`azurerm_storage_account`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_account), [`azurerm_storage_container`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_container), [`azurerm_storage_share`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_share), [`azurerm_storage_blob`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_blob)
- [`azurerm_storage_management_policy`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/storage_management_policy) y [`azurerm_role_assignment`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment)
- [Bloque `features { storage { … } }`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/features-block#storage) y [`storage_use_azuread`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs#storage_use_azuread)
- [`depends_on`](https://developer.hashicorp.com/terraform/language/meta-arguments/depends_on) y [`count`](https://developer.hashicorp.com/terraform/language/meta-arguments/count) (meta-argumentos)
- [Cuentas de almacenamiento](https://learn.microsoft.com/es-es/azure/storage/common/storage-account-overview) y [redundancia (LRS, ZRS, GRS, GZRS)](https://learn.microsoft.com/es-es/azure/storage/common/storage-redundancy)
- [Niveles de acceso Hot, Cool, Cold y Archive](https://learn.microsoft.com/es-es/azure/storage/blobs/access-tiers-overview) y [administración del ciclo de vida](https://learn.microsoft.com/es-es/azure/storage/blobs/lifecycle-management-overview)
- [Soft delete](https://learn.microsoft.com/es-es/azure/storage/blobs/soft-delete-blob-overview) y [versionado de blobs](https://learn.microsoft.com/es-es/azure/storage/blobs/versioning-overview)
- [Roles RBAC para acceso a datos](https://learn.microsoft.com/es-es/azure/storage/blobs/assign-azure-role-data-access), [impedir el acceso anónimo](https://learn.microsoft.com/es-es/azure/storage/blobs/anonymous-read-access-prevent) y [firmas de acceso compartido (SAS)](https://learn.microsoft.com/es-es/azure/storage/common/storage-sas-overview)
- [Montar Azure Files en Linux](https://learn.microsoft.com/es-es/azure/storage/files/storage-how-to-use-files-linux)
- [`DefaultAzureCredential` (azure-identity)](https://learn.microsoft.com/es-es/python/api/overview/azure/identity-readme) y [SDK azure-storage-blob](https://learn.microsoft.com/es-es/python/api/overview/azure/storage-blob-readme)
- [Backend `azurerm` para el estado remoto](https://developer.hashicorp.com/terraform/language/backend/azurerm) (siguiente página)
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)