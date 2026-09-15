# 🔐 Key Vault: secretos que no pasan por el estado

> Moodle necesita una contraseña de MySQL, una clave de la cuenta de almacenamiento y, en producción, un certificado TLS. La pregunta no es dónde guardarlos (Key Vault) sino **por dónde pasan** antes de llegar allí y después de salir: el código, el `plan`, el estado, los logs del pipeline, el `cloud-init` de la VM. Cada uno de esos lugares es una copia, y una copia en claro en el estado es tan grave como una en Git. Esta página construye el vault con RBAC, genera y escribe secretos **sin que Terraform los guarde** (recursos efímeros y argumentos *write-only*, Terraform 1.11), los lee del mismo modo para configurar MySQL, y deja que la VM de Moodle los obtenga sola con identidad gestionada. Cierra con rotación real, claves y certificados. En **Topaz** funciona el plano de gestión de Key Vault y el de datos para secretos: crear, versionar, leer con la CLI, inspeccionar el estado. Lo que Topaz no hace es evaluar permisos ni emular IMDS: eso se valida con `plan` y se prueba en Azure real.

**🎯 Objetivos de aprendizaje**
- Distinguir secretos, claves y certificados, y decidir qué *no* va a Key Vault.
- Crear un vault con RBAC, soft delete y purge protection adecuados a cada entorno.
- Generar y escribir secretos con `ephemeral` y `value_wo`, y comprobar en el estado que no están.
- Leer secretos con recursos efímeros y argumentos *write-only* en lugar de `data`.
- Dar a la VM de Moodle acceso a su contraseña con identidad gestionada y ámbito por secreto.
- Rotar una contraseña de MySQL en un solo `apply` y configurar rotación automática de claves.

> **🔷 Requisitos previos.** [Páginas 1](index.md#pagina-1) a 10 completadas y destruidas, `~/tf-st/providers.tf`, Terraform `>= 1.11` (argumentos *write-only*), azurerm 4.x reciente, providers `random >= 3.7` y `time`, `jq`, `az account show --query environmentName -o tsv` → `Topaz`.

---

## 1. Qué guarda Key Vault y qué no

Key Vault gestiona tres tipos de objeto con tres APIs y tres juegos de roles distintos. Confundirlos lleva a guardar un certificado como secreto (funciona, pero pierdes la renovación) o a dar *Key Vault Administrator* a quien solo necesita leer una contraseña.

| **Objeto** | **Qué es** | **En Moodle** | **Roles RBAC** | **Topaz** |
|---|---|---|---|---|
| **Secreto** | Texto opaco ≤ 25 KB, versionado, con expiración | Contraseña de MySQL, clave de la cuenta de storage, *salt* de Moodle, connection string de App Insights | *Secrets Officer* (escribe), *Secrets User* (lee) | ✅ |
| **Clave** | Par RSA/EC que nunca sale del vault: cifra, firma, envuelve otras claves | Clave gestionada por el cliente (CMK) para cifrar `moodledata` y los discos | *Crypto Officer*, *Crypto Service Encryption User* (para el servicio que cifra) | plan ✅ / apply según versión |
| **Certificado** | X.509 + clave privada + política de renovación; expone también un secreto (PFX) y una clave | TLS del Application Gateway; en pro, emitido por CA integrada | *Certificates Officer*; el gateway lee con *Secrets User* | plan ✅ / apply ❌ |

> **🔷 Lo que no va a Key Vault.** Configuración que no es secreta (nombre del servidor, puerto, URL de Moodle): eso son variables o *outputs*, y meterlo en el vault solo añade latencia y llamadas facturables. Ficheros grandes (un `.pfx` de 25 KB es el límite). Y estados de Terraform: van al backend con cifrado y RBAC propio ([página 4](index.md#pagina-4)). Regla práctica: Key Vault guarda lo que, si se filtra, hay que rotar.

---

## 2. El vault: RBAC, borrado suave y red

El original usa `access_policy` embebido y a la vez recomienda `azurerm_key_vault_access_policy`: si haces ambas cosas, cada `plan` quiere borrar lo que la otra creó. Las políticas de acceso son el modelo antiguo: un vault-por-vault, sin herencia, sin ámbito por secreto y sin Privileged Identity Management. Con `rbac_authorization_enabled = true` el acceso se gestiona con los mismos `azurerm_role_assignment` del resto de Azure, y puede afinarse hasta un secreto concreto.

```hcl
# providers.tf: cómo se comporta el provider con el borrado suave
provider "azurerm" {
  features {
    key_vault {
      purge_soft_delete_on_destroy    = var.entorno != "pro"   # dev: destroy limpia de verdad; pro: el vault queda recuperable 90 días
      recover_soft_deleted_key_vaults = true                   # si existe uno borrado con el mismo nombre, lo recupera en vez de fallar
    }
  }
}

data "azurerm_client_config" "actual" {}

resource "azurerm_key_vault" "moodle" {
  name                = "kv-moodle-${var.entorno}-${substr(md5(azurerm_resource_group.moodle.id), 0, 6)}"   # 3-24 chars, único global, empieza por letra
  resource_group_name = azurerm_resource_group.moodle.name
  location            = azurerm_resource_group.moodle.location
  tenant_id           = data.azurerm_client_config.actual.tenant_id
  sku_name            = "standard"                             # premium solo si necesitas claves en HSM

  rbac_authorization_enabled = true                            # sin access_policy: todo por azurerm_role_assignment
  soft_delete_retention_days = var.entorno == "pro" ? 90 : 7   # siempre activo; el mínimo es 7
  purge_protection_enabled   = var.entorno == "pro"            # pro: nadie puede purgar antes del plazo, ni tú. Irreversible una vez activado.

  public_network_access_enabled = var.entorno != "pro"         # pro: solo private endpoint ([página 13](index.md#pagina-13))
  network_acls {
    default_action = var.entorno == "pro" ? "Deny" : "Allow"
    bypass         = "AzureServices"                           # el Application Gateway y el cifrado de discos entran por aquí
    ip_rules       = var.entorno == "pro" ? [] : var.ips_admin
  }
  enabled_for_deployment          = false                      # solo si una VM va a leer certificados por la vía clásica
  enabled_for_disk_encryption     = var.entorno == "pro"       # cifrado de discos con CMK
  enabled_for_template_deployment = false
  tags = local.tags
}

# Quien ejecuta Terraform escribe secretos. Nada más: no necesita Administrator.
resource "azurerm_role_assignment" "tf_escribe_secretos" {
  scope                = azurerm_key_vault.moodle.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.actual.object_id
}
# RBAC tarda hasta unos minutos en propagarse. Sin esta pausa, el primer apply falla con ForbiddenByRbac al crear el secreto.
resource "time_sleep" "rbac" {
  depends_on      = [azurerm_role_assignment.tf_escribe_secretos]
  create_duration = "60s"
}

output "vault_uri" { value = azurerm_key_vault.moodle.vault_uri }
```

| **Rol** | **Quién lo necesita en Moodle** | **Ámbito recomendado** |
|---|---|---|
| *Key Vault Secrets Officer* | La identidad que ejecuta `apply` (crea y rota secretos) | El vault |
| *Key Vault Secrets User* | La identidad gestionada del VMSS (lee la contraseña de MySQL); el Application Gateway (lee el PFX) | **El secreto concreto** (`resource_versionless_id`), no el vault |
| *Key Vault Certificates Officer* | La identidad de `apply` si Terraform gestiona el certificado | El vault |
| *Key Vault Crypto Service Encryption User* | La identidad de la cuenta de storage / Disk Encryption Set que cifra con CMK | La clave |
| *Key Vault Administrator* | Nadie de forma permanente. Con PIM, activable para incidentes | — |

---

## 3. Escribir un secreto sin que Terraform lo guarde

`value = "SuperSecretPassword123!"` tiene cuatro copias antes de llegar al vault: el fichero `.tf`, el historial de Git, la salida del `plan` y el estado, donde `sensitive` solo oculta la pantalla, no el JSON. La combinación correcta desde Terraform 1.11 es un **recurso efímero** que genera la contraseña (existe solo durante la ejecución) y un argumento **write-only** (`value_wo`) que la envía a Azure sin persistirla. Como Terraform no puede comparar lo que no guarda, un segundo campo, `value_wo_version`, le dice cuándo debe volver a escribir: es el asa de la rotación (11.6).

```hcl
# Se genera en cada ejecución y se descarta al terminar: nunca entra en el plan ni en el estado
ephemeral "random_password" "mysql" {
  length           = 32
  special          = true
  override_special = "!#%^*-_=+"          # sin comillas, $, ni & para no pelearse con config.php ni con la shell de cloud-init
}

variable "mysql_password_version" {        # súbelo para rotar (11.6 lo automatiza)
  type    = number
  default = 1
}

resource "azurerm_key_vault_secret" "mysql" {
  name             = "mysql-moodle-password"
  key_vault_id     = azurerm_key_vault.moodle.id
  value_wo         = ephemeral.random_password.mysql.result   # write-only: se envía, no se guarda
  value_wo_version = var.mysql_password_version              # Terraform solo reescribe cuando esto cambia
  content_type     = "password"                              # metadato útil para inventario y para Defender
  expiration_date  = timeadd(plantimestamp(), "2160h")       # 90 días: Key Vault avisa (Event Grid) y Defender lo señala si caduca
  tags             = merge(local.tags, { consumidor = "vmss-moodle-web", rota = "terraform" })
  lifecycle { ignore_changes = [expiration_date] }           # si no, cada plan la mueve; la rotación la fija de nuevo
  depends_on = [time_sleep.rbac]
}

# Secretos que no genera Terraform sino otro recurso: la clave de storage sí pasa por el estado (es un atributo del recurso),
# pero al menos la VM no la recibe por cloud-init sino que la lee del vault con su identidad.
resource "azurerm_key_vault_secret" "storage_key" {
  name             = "moodledata-storage-key"
  key_vault_id     = azurerm_key_vault.moodle.id
  value_wo         = azurerm_storage_account.moodledata.primary_access_key
  value_wo_version = 1
  content_type     = "storage-access-key"
  depends_on       = [time_sleep.rbac]
}
# Mejor todavía: que la VM no use clave de storage. Identidad gestionada + rol "Storage Blob Data Contributor" (página 13).
```

> **⚠️ Compruébalo, no te lo creas.** Después del `apply`: `terraform state pull | jq '.resources[] | select(.type == "azurerm_key_vault_secret") | .instances[].attributes | {name, value, value_wo}'`. Con `value` verás la contraseña en claro (y `sensitive` no cambia eso). Con `value_wo` verás `null`. El laboratorio de 11.8 hace exactamente esta comparación.

---

## 4. Leer un secreto: `data` lo guarda, `ephemeral` no

La nota del original ("usa `data` para leer secretos sin exponerlos en el estado") es el error más peligroso de la página: un `data "azurerm_key_vault_secret"` se guarda *completo* en el estado, valor incluido, en cada `refresh`. Y aunque el origen fuera efímero, el destino importa: si asignas el valor a `administrator_password`, ese atributo se guarda. Hace falta que ambos extremos sean transitorios: `ephemeral` para leer y el argumento `_wo` del consumidor para escribir.

```hcl
# ❌ El original: el valor acaba en el estado dos veces (en el data y en el atributo del servidor)
# data "azurerm_key_vault_secret" "db_password" { name = "db-password"  key_vault_id = azurerm_key_vault.example.id }
# administrator_login_password = data.azurerm_key_vault_secret.db_password.value

# ✅ Lectura efímera: existe solo durante plan/apply, no se escribe en el estado
ephemeral "azurerm_key_vault_secret" "mysql" {
  name         = azurerm_key_vault_secret.mysql.name        # la dependencia garantiza que se lee después de escribirse
  key_vault_id = azurerm_key_vault.moodle.id
}

resource "azurerm_mysql_flexible_server" "moodle" {
  name                   = "mysql-moodle-${var.entorno}-${substr(md5(azurerm_resource_group.moodle.id), 0, 6)}"
  resource_group_name    = azurerm_resource_group.moodle.name
  location               = azurerm_resource_group.moodle.location
  version                = "8.0.21"
  sku_name               = local.t.mysql                      # tallas por entorno ([página 15](index.md#pagina-15))
  administrator_login    = "moodleadmin"
  administrator_password_wo         = ephemeral.azurerm_key_vault_secret.mysql.value   # write-only: se envía, no se guarda
  administrator_password_wo_version = var.mysql_password_version                       # la misma versión que el secreto: cambian juntos
  delegated_subnet_id    = module.red.subnet_ids["datos"]
  private_dns_zone_id    = azurerm_private_dns_zone.mysql.id
  backup_retention_days  = var.entorno == "pro" ? 35 : 7
  tags                   = local.tags
}

# Un valor efímero solo puede ir a sitios efímeros: argumentos _wo, configuración de providers, provisioners/connection,
# otros recursos efímeros y locals (que se vuelven efímeros). En un output o en un atributo normal, Terraform lo rechaza:
#   "Invalid use of ephemeral value" — y eso es exactamente lo que quieres.
```

> **🔷 Y si el recurso destino no tiene argumento `_wo`.** Aún hay recursos sin variante *write-only*. Entonces el valor se guarda en el estado, hagas lo que hagas en el origen. Las defensas pasan a ser el backend (cifrado, RBAC mínimo, sin copias locales, [página 4](index.md#pagina-4)) y la rotación frecuente: un secreto que cambia cada 90 días en el estado de hace 6 meses ya no sirve a nadie. Y comprueba el *changelog* del provider antes de asumir que no existe: cada versión añade argumentos `_wo`.

---

## 5. La aplicación lee sola: identidad gestionada

El script Python del original hace `print` del secreto, y la tentación equivalente en Terraform es pasarlo a la VM por `custom_data`: `cloud-init` se guarda en claro en el estado y en el disco. La VM no debe *recibir* la contraseña; debe *pedirla* con su propia identidad. Terraform solo le pasa dos datos públicos: la URI del vault y el `client_id` de la identidad. El permiso se da **sobre el secreto**, no sobre el vault: si la VM se compromete, el atacante lee una contraseña, no todas.

```hcl
resource "azurerm_user_assigned_identity" "web" {          # user-assigned: existe antes que el VMSS, así el rol está listo al primer arranque
  name                = "id-moodle-web-${var.entorno}"
  resource_group_name = azurerm_resource_group.moodle.name
  location            = azurerm_resource_group.moodle.location
}
resource "azurerm_role_assignment" "web_lee_mysql" {
  scope                = azurerm_key_vault_secret.mysql.resource_versionless_id   # este secreto, todas sus versiones. No el vault.
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.web.principal_id
}

resource "azurerm_linux_virtual_machine_scale_set" "web" {
  # … (páginas 14 y 15)
  identity { type = "UserAssigned", identity_ids = [azurerm_user_assigned_identity.web.id] }
  custom_data = base64(templatefile("${path.module}/cloud-init.yaml", {
    vault_uri = azurerm_key_vault.moodle.vault_uri                 # público
    client_id = azurerm_user_assigned_identity.web.client_id       # público
    secreto   = azurerm_key_vault_secret.mysql.name                # público. La contraseña, jamás.
  }))
  depends_on = [azurerm_role_assignment.web_lee_mysql]
}
```

```yaml
#cloud-config   (cloud-init.yaml)
package_update: true
packages: [jq, curl]
write_files:
  - path: /usr/local/sbin/moodle-secrets.sh
    permissions: "0750"
    content: |
      #!/usr/bin/env bash
      set -euo pipefail
      # 1. Token de la identidad gestionada por IMDS. client_id es obligatorio si la VM tiene más de una identidad.
      TOKEN=$(curl -sf -H 'Metadata: true' \
        "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net&client_id=${client_id}" | jq -r .access_token)
      # 2. El secreto, por su nombre: siempre la versión actual. Tras una rotación basta re-ejecutar este script.
      PASS=$(curl -sf -H "Authorization: Bearer $TOKEN" "${vault_uri}secrets/${secreto}?api-version=7.4" | jq -r .value)
      # 3. A un fichero 0600 que solo lee el usuario de Apache. Nunca a stdout, nunca a un log.
      install -o www-data -g www-data -m 0600 /dev/null /etc/moodle/db.env
      printf 'MOODLE_DB_PASS=%s\n' "$PASS" > /etc/moodle/db.env
      unset PASS TOKEN
  - path: /etc/systemd/system/moodle-secrets.timer          # relee cada 6 h: la rotación llega sin reimage
    content: |
      [Timer]
      OnBootSec=1min
      OnUnitActiveSec=6h
      [Install]
      WantedBy=timers.target
  - path: /etc/systemd/system/moodle-secrets.service
    content: |
      [Service]
      Type=oneshot
      ExecStart=/usr/local/sbin/moodle-secrets.sh
      ExecStartPost=/bin/systemctl reload apache2
runcmd:
  - mkdir -p /etc/moodle
  - systemctl enable --now moodle-secrets.timer
# config.php lee getenv('MOODLE_DB_PASS') vía EnvironmentFile en la unidad de Apache/PHP-FPM.

# Lo mismo en otros consumidores, sin código:
#   App Service / Functions:  app_settings = { DB_PASS = "@Microsoft.KeyVault(SecretUri=${azurerm_key_vault_secret.mysql.versionless_id})" }
#   AKS:                       Secrets Store CSI Driver + Workload Identity: el secreto aparece como fichero en el pod
#   Python (el original):      DefaultAzureCredential está bien; el error era el print. En la VM usa ManagedIdentityCredential(client_id=…)
```

---

## 6. Rotación: un solo `apply`, dos extremos

El original propone una Function que "actualiza Key Vault y la base de datos": dos escrituras separadas, y si la segunda falla Moodle se queda sin acceso. Con `value_wo_version` en el secreto y `administrator_password_wo_version` en MySQL atados a la misma variable, ambos se reescriben en el mismo `apply` con el mismo valor efímero, y el *timer* de la VM recoge el cambio. La versión la puede subir una persona o el calendario.

```hcl
# Rotación programada: time_rotating se recrea al cumplirse el plazo y su fecha base cambia → la versión cambia → ambos extremos se reescriben
resource "time_rotating" "mysql" {
  rotation_days = 90
}
locals {
  mysql_password_version = tonumber(formatdate("YYYYMMDD", time_rotating.mysql.rfc3339))   # p. ej. 20260910; sube solo en cada rotación
}
# En 11.3 y 11.4: value_wo_version = local.mysql_password_version / administrator_password_wo_version = local.mysql_password_version
# El pipeline (página 12) hace un apply semanal programado: cuando toque, rota; si no, "No changes".
# Rotación de urgencia (filtración): terraform apply -replace=time_rotating.mysql

# La expiración del secreto se realinea en cada rotación
#   expiration_date = timeadd(time_rotating.mysql.rfc3339, "2400h")   # 100 días: margen sobre los 90 de rotación

# Claves: rotación nativa, sin Terraform en el bucle
resource "azurerm_role_assignment" "tf_crypto" {
  scope                = azurerm_key_vault.moodle.id
  role_definition_name = "Key Vault Crypto Officer"
  principal_id         = data.azurerm_client_config.actual.object_id
}
resource "azurerm_key_vault_key" "cmk" {
  name         = "cmk-moodledata"
  key_vault_id = azurerm_key_vault.moodle.id
  key_type     = "RSA"
  key_size     = 3072
  key_opts     = ["wrapKey", "unwrapKey"]                    # una CMK envuelve claves de datos; no firma ni cifra directamente (el original daba los seis)
  rotation_policy {
    automatic { time_before_expiry = "P30D" }                # Key Vault crea la versión nueva solo; Storage la adopta si usas versionless_id
    expire_after         = "P365D"
    notify_before_expiry = "P29D"
  }
  depends_on = [azurerm_role_assignment.tf_crypto, time_sleep.rbac]
}
```

---

## 7. Certificados: emitir en el vault, no importar un PFX

El original importa `certificate.pfx` con la contraseña en claro en el código: el fichero y su clave privada acaban en Git, y alguien tendrá que repetir la operación a mano cuando caduque. Key Vault puede **emitir** el certificado (autofirmado en dev, con CA integrada en pro), guardar la clave privada sin que salga y renovarlo solo. El Application Gateway lo lee por referencia con su identidad.

```hcl
resource "azurerm_role_assignment" "tf_certs" {
  scope                = azurerm_key_vault.moodle.id
  role_definition_name = "Key Vault Certificates Officer"
  principal_id         = data.azurerm_client_config.actual.object_id
}
resource "azurerm_key_vault_certificate" "tls" {
  name         = "tls-moodle"
  key_vault_id = azurerm_key_vault.moodle.id
  certificate_policy {
    issuer_parameters { name = var.entorno == "pro" ? "DigiCert" : "Self" }   # pro: azurerm_key_vault_certificate_issuer con la cuenta de la CA
    key_properties { exportable = true, key_type = "RSA", key_size = 2048, reuse_key = false }
    secret_properties { content_type = "application/x-pkcs12" }
    lifetime_action {
      trigger { days_before_expiry = 30 }
      action  { action_type = "AutoRenew" }                  # con "Self" o CA integrada renueva solo; con CA manual, "EmailContacts"
    }
    x509_certificate_properties {
      subject            = "CN=${var.dominio_moodle}"
      validity_in_months = 12
      key_usage          = ["digitalSignature", "keyEncipherment"]
      extended_key_usage = ["1.3.6.1.5.5.7.3.1"]              # serverAuth
      subject_alternative_names { dns_names = [var.dominio_moodle] }
    }
  }
  depends_on = [azurerm_role_assignment.tf_certs, time_sleep.rbac]
}

# El gateway lee el PFX como secreto, con identidad propia y permiso sobre ese secreto
resource "azurerm_user_assigned_identity" "agw" { name = "id-moodle-agw", resource_group_name = azurerm_resource_group.moodle.name, location = azurerm_resource_group.moodle.location }
resource "azurerm_role_assignment" "agw_lee_cert" {
  scope                = azurerm_key_vault.moodle.id          # el secreto del certificado no tiene resource_id propio en el provider: ámbito vault, solo Secrets User
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.agw.principal_id
}
resource "azurerm_application_gateway" "moodle" {
  # …
  identity { type = "UserAssigned", identity_ids = [azurerm_user_assigned_identity.agw.id] }
  ssl_certificate {
    name                = "tls-moodle"
    key_vault_secret_id = azurerm_key_vault_certificate.tls.versionless_secret_id   # sin versión: la renovación llega sola en < 4 h
  }
}
# Importar uno existente (migración): certificate { contents = filebase64(var.pfx_path)  password = var.pfx_password }
# La contraseña del PFX se guarda en el estado: úsalo una vez, rota el PFX y pasa a emisión gestionada.
```

---

## 8. Laboratorio en Topaz

El laboratorio demuestra lo esencial de la página con evidencia, no con fe: el mismo secreto escrito con `value` y con `value_wo`, y lo que aparece en el estado en cada caso; la lectura efímera; el versionado al rotar. Lo que Topaz no evalúa (RBAC, IMDS, MySQL, certificados) se valida con `plan`.

```bash
mkdir -p ~/tf-kv && cd ~/tf-kv && cp ~/tf-st/providers.tf .

# ─── 1. Vault con RBAC y dos secretos: el del original y el correcto ────────────
cat > main.tf <<'EOF'
terraform {
  required_version = ">= 1.11"
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.30" }
    random  = { source = "hashicorp/random",  version = "~> 3.7" }
    time    = { source = "hashicorp/time",    version = "~> 0.13" }
  }
}
variable "entorno"        { type = string, default = "dev" }
variable "location"       { type = string, default = "eastus" }
variable "version_secreto" { type = number, default = 1 }
variable "validar_azure"  { type = bool,   default = false }
locals { tags = { proyecto = "moodle", entorno = var.entorno, gestion = "terraform" } }
data "azurerm_client_config" "actual" {}

resource "azurerm_resource_group" "kv" { name = "rg-kv-lab-${var.entorno}", location = var.location, tags = local.tags }
resource "azurerm_key_vault" "moodle" {
  name                       = "kv-lab-${var.entorno}-${substr(md5(azurerm_resource_group.kv.id), 0, 6)}"
  resource_group_name        = azurerm_resource_group.kv.name
  location                   = azurerm_resource_group.kv.location
  tenant_id                  = data.azurerm_client_config.actual.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = true
  soft_delete_retention_days = 7
  purge_protection_enabled   = false          # dev: que destroy limpie
  tags                       = local.tags
}
resource "azurerm_role_assignment" "tf" {
  scope                = azurerm_key_vault.moodle.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.actual.object_id
}
resource "time_sleep" "rbac" { depends_on = [azurerm_role_assignment.tf], create_duration = "10s" }   # en Azure real, 60s

# (a) Como el original: el valor en el código
resource "azurerm_key_vault_secret" "mal" {
  name         = "demo-en-claro"
  key_vault_id = azurerm_key_vault.moodle.id
  value        = "SuperSecretPassword123!"
  depends_on   = [time_sleep.rbac]
}
# (b) Efímero + write-only
ephemeral "random_password" "mysql" { length = 32, special = true, override_special = "!#%^*-_=+" }
resource "azurerm_key_vault_secret" "bien" {
  name             = "mysql-moodle-password"
  key_vault_id     = azurerm_key_vault.moodle.id
  value_wo         = ephemeral.random_password.mysql.result
  value_wo_version = var.version_secreto
  content_type     = "password"
  depends_on       = [time_sleep.rbac]
}
# (c) Lectura efímera, consumida en un contexto efímero (provisioner) para poder observarla sin guardarla
ephemeral "azurerm_key_vault_secret" "leido" {
  name         = azurerm_key_vault_secret.bien.name
  key_vault_id = azurerm_key_vault.moodle.id
}
resource "terraform_data" "prueba_lectura" {
  triggers_replace = [var.version_secreto]
  provisioner "local-exec" {
    command = "echo 'leído desde el vault: ${length(ephemeral.azurerm_key_vault_secret.leido.value)} caracteres, empieza por ${substr(ephemeral.azurerm_key_vault_secret.leido.value, 0, 1)}…'"
  }
}
output "vault" { value = azurerm_key_vault.moodle.name }
EOF
terraform init && terraform apply -auto-approve
#   "leído desde el vault: 32 caracteres, empieza por …" — el valor llegó a Azure y volvió, sin pasar por el estado

# ─── 2. La prueba: qué hay en el estado ──────────────────────────────────────────
terraform state pull | jq '.resources[] | select(.type == "azurerm_key_vault_secret") | .instances[].attributes | {name, value, value_wo, value_wo_version}'
#   demo-en-claro:          "value": "SuperSecretPassword123!"   ← en claro; sensitive no cambia esto
#   mysql-moodle-password:  "value": null, "value_wo": null      ← no está
terraform state pull | jq '.resources[] | select(.type == "terraform_data")'   # nada del secreto tampoco
grep -c SuperSecret terraform.tfstate; grep -c "$(az keyvault secret show --vault-name $(terraform output -raw vault) -n mysql-moodle-password --query value -o tsv | cut -c1-8)" terraform.tfstate   # 1 y 0
terraform plan -no-color | grep -c "value_wo" || true          # el plan tampoco muestra el valor: "(write-only attribute)"

# ─── 3. Rotar: sube la versión ──────────────────────────────────────────────────
terraform apply -auto-approve -var version_secreto=2
az keyvault secret list-versions --vault-name $(terraform output -raw vault) -n mysql-moodle-password --query "[].{v:id, creado:attributes.created}" -o table   # dos versiones
terraform apply -auto-approve -var version_secreto=2 | tail -1   # "No changes": Terraform no compara valores, solo la versión

# ─── 4. Lo que Topaz no evalúa: validate + plan ─────────────────────────────────
cat > azure.tf <<'EOF'
resource "azurerm_user_assigned_identity" "web" {
  count = var.validar_azure ? 1 : 0
  name = "id-kv-lab-web", resource_group_name = azurerm_resource_group.kv.name, location = azurerm_resource_group.kv.location
}
resource "azurerm_role_assignment" "web_lee" {
  count                = var.validar_azure ? 1 : 0
  scope                = azurerm_key_vault_secret.bien.resource_versionless_id     # ámbito: el secreto
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.web[0].principal_id
}
resource "azurerm_key_vault_key" "cmk" {
  count = var.validar_azure ? 1 : 0
  name = "cmk-lab", key_vault_id = azurerm_key_vault.moodle.id, key_type = "RSA", key_size = 3072, key_opts = ["wrapKey", "unwrapKey"]
  rotation_policy { automatic { time_before_expiry = "P30D" }, expire_after = "P365D", notify_before_expiry = "P29D" }
}
resource "azurerm_key_vault_certificate" "tls" {
  count = var.validar_azure ? 1 : 0
  name = "tls-lab", key_vault_id = azurerm_key_vault.moodle.id
  certificate_policy {
    issuer_parameters { name = "Self" }
    key_properties { exportable = true, key_type = "RSA", key_size = 2048, reuse_key = false }
    secret_properties { content_type = "application/x-pkcs12" }
    lifetime_action { trigger { days_before_expiry = 30 }, action { action_type = "AutoRenew" } }
    x509_certificate_properties { subject = "CN=moodle.ejemplo.edu", validity_in_months = 12, key_usage = ["digitalSignature", "keyEncipherment"], subject_alternative_names { dns_names = ["moodle.ejemplo.edu"] } }
  }
}
EOF
terraform validate && terraform plan -var validar_azure=true -no-color | grep -E "Plan:|scope"
#   El scope del role assignment termina en /secrets/mysql-moodle-password: permiso por secreto, no por vault.

# El original, tal cual: access_policy embebido + recurso access_policy aparte → validate pasa, plan oscila
# (cada apply borra la política del otro). Y data.azurerm_key_vault_secret → mira su entrada en el estado: "value" en claro.

# ─── 5. Limpiar ────────────────────────────────────────────────────────────────
terraform destroy -auto-approve
az keyvault list-deleted --query "[].name" -o tsv    # con purge_soft_delete_on_destroy = true no debe quedar nada
```

```bash
# ─── Solo Azure real ────────────────────────────────────────────────────────────
terraform apply -auto-approve -var validar_azure=true
# RBAC de verdad: la identidad web lee su secreto y nada más
az keyvault secret show --vault-name $KV -n mysql-moodle-password --query attributes.enabled     # tú: Officer, OK
az login --identity --client-id $(terraform output -raw web_client_id) 2>/dev/null            # desde la VM con esa identidad
az keyvault secret show --vault-name $KV -n mysql-moodle-password --query attributes.enabled     # OK
az keyvault secret show --vault-name $KV -n demo-en-claro                                       # ForbiddenByRbac: ámbito por secreto
# IMDS a mano desde la VM (lo que hace cloud-init):
curl -s -H 'Metadata: true' "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net&client_id=$CID" | jq -r .access_token | cut -c1-20
# Auditoría (página 14): cada lectura queda en AZKVAuditLogs con identidad, IP y resultado
az keyvault certificate show --vault-name $KV -n tls-lab --query "{caduca:attributes.expires, renueva:policy.lifetimeActions[0].trigger.daysBeforeExpiry}"
```

---

## 9. Errores comunes

> **⚠️ Solución de problemas**
>
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | *ForbiddenByRbac* al crear el primer secreto | El rol se asignó hace segundos; RBAC tarda hasta unos minutos. `time_sleep` tras el `role_assignment`, o reintenta. Si persiste: el vault tiene RBAC activado pero tu identidad solo tiene *Contributor* (gestiona el vault, no lee su contenido) |
> | El plan alterna: crea y borra la misma `access_policy` (original) | Política embebida en el vault y recurso `azurerm_key_vault_access_policy` a la vez. Elige uno. Mejor: `rbac_authorization_enabled = true` y ningún `access_policy` |
> | *VaultAlreadyExists* / *ConflictError: a vault with this name was recently deleted* | El nombre es único global y el vault anterior está en borrado suave. `recover_soft_deleted_key_vaults = true` en el provider, o `az keyvault purge` (si no hay purge protection) |
> | `terraform destroy` falla en el vault de pro y no se puede purgar | Correcto: `purge_protection_enabled` es irreversible y bloquea la purga hasta que pase `soft_delete_retention_days`. Es lo que quieres en pro. En dev, no lo actives |
> | *"value": conflicts with value_wo* | Un secreto se escribe con `value` o con `value_wo`, no ambos. Al migrar de uno a otro, el secreto se recrea (nueva versión en Key Vault, sin pérdida) |
> | Cambié la contraseña efímera y el `plan` dice *No changes* | Esperado: Terraform no guarda el valor, así que no puede compararlo. Solo `value_wo_version` dispara la reescritura. Súbela |
> | *Invalid use of ephemeral value* | Intentas poner un efímero en un output, un atributo normal o un `data`. Solo argumentos `_wo`, providers, provisioners, otros efímeros y locals. Si el destino no tiene `_wo`, lee la nota de 11.4 |
> | "Uso `data` para no exponer el secreto" (original) | Falso: el `data` se guarda íntegro en el estado en cada refresh. `ephemeral "azurerm_key_vault_secret"` hacia un argumento `_wo` |
> | Con `network_acls default_action = "Deny"`, Terraform ya no puede escribir secretos | Te has cerrado la puerta a ti mismo. El runner necesita estar en `ip_rules`, en una subred con service endpoint, o (pro) llegar por private endpoint desde un runner autoalojado ([página 12](index.md#pagina-12)) |
> | IMDS devuelve 400 *Multiple user assigned identities exist* | La VM tiene más de una identidad y no indicas cuál. Añade `client_id=` a la petición del token (el script de 11.5 ya lo hace) |
> | La VM lee el secreto del vault pero MySQL rechaza la contraseña | Versiones desalineadas: el secreto se rotó y MySQL no (o al revés). Ambos `_wo_version` deben apuntar a la misma variable/local. Comprueba con `az keyvault secret list-versions` |
> | El Application Gateway no arranca: *KeyVaultSecretNotFound* o *SecretAccessForbidden* | Tres causas: la identidad del gateway no tiene *Secrets User* (lee el PFX como secreto, no como certificado); `network_acls` en *Deny* sin `bypass = "AzureServices"`; o usas `secret_id` con versión y el certificado se ha renovado. Usa `versionless_secret_id` |
> | El certificado autofirmado se renueva pero el navegador sigue mostrando el antiguo | El gateway sondea el vault cada 4 horas. Para forzar: `az network application-gateway stop/start`, o espera. En pro con CA integrada, planifica la renovación con > 30 días de margen |
> | *Secret exceeds maximum size* | 25 KB es el límite. Un PFX grande, un fichero de configuración o un JSON de credenciales no van como secreto: certificado gestionado, cuenta de storage privada o dividir |
> | Defender / Policy marca *Secrets should have expiration date* | Sin `expiration_date` la política de la organización lo señala. Pónsela alineada con la rotación (11.6) y `ignore_changes` para que el `plan` no la mueva a diario |
> | El secreto aparece en el log del pipeline | Alguien hizo `echo`, `terraform output` o `-var` con el valor. Con la arquitectura de esta página el pipeline nunca lo toca: Terraform lo genera y lee de forma efímera. Si aparece, rota (`-replace=time_rotating.mysql`) y borra el log |
> | En Topaz: el secreto se crea pero `az keyvault secret show` devuelve error de DNS | El plano de datos usa `<vault>.vault.azure.net`; el emulador lo resuelve a su propio endpoint solo si la CLI está configurada con el *cloud* Topaz (`az cloud show`). Revisa `~/.azure/clouds.config` y la variable `AZURE_KEYVAULT_DNS_SUFFIX` según la versión del emulador |
> | En Topaz: *role assignment* aplica pero la identidad puede leer cualquier secreto | Esperado: el emulador almacena las asignaciones pero no evalúa RBAC en el plano de datos. El ámbito por secreto solo se comprueba en Azure real (bloque final de 11.8) |

---

## 10. Autoevaluación

1. **¿Cuántas copias de la contraseña crea `value = "SuperSecretPassword123!"` antes de llegar al vault?**
   Cuatro: el fichero `.tf`, el historial de Git, la salida del `plan` y el estado. `sensitive` solo oculta la pantalla, no el JSON del estado.
2. **¿Por qué no mezclar `access_policy` embebido con `azurerm_key_vault_access_policy`?**
   Ambos gestionan la misma lista: cada `apply` borra lo que el otro creó. Y ninguno de los dos es el modelo actual: `rbac_authorization_enabled = true` con `azurerm_role_assignment`.
3. **¿Qué ventaja da RBAC sobre las políticas de acceso además de la coherencia?**
   Ámbito por secreto (`resource_versionless_id`): la VM de Moodle lee su contraseña y nada más. Herencia desde grupo de recursos y suscripción, y activación temporal con PIM.
4. **¿Qué hace `value_wo` y qué papel tiene `value_wo_version`?**
   `value_wo` envía el valor a Azure sin guardarlo en el plan ni en el estado. Como Terraform no puede comparar lo que no guarda, `value_wo_version` es lo único que dispara una reescritura.
5. **¿Por qué es falsa la nota "usa `data` para leer secretos sin exponerlos en el estado"?**
   Un `data` se guarda íntegro en el estado, valor incluido, en cada refresh. La alternativa es `ephemeral "azurerm_key_vault_secret"` hacia un argumento `_wo` del consumidor.
6. **¿Basta con que el origen sea efímero para que el secreto no toque el estado?**
   No. Si el destino es un atributo normal (`administrator_password`), ese atributo se persiste. Ambos extremos deben ser transitorios: `ephemeral` y `_wo`. Si el destino no tiene `_wo`, Terraform rechaza el efímero y hay que aceptar el estado como copia, protegiendo el backend y rotando.
7. **¿Qué tres datos pasa Terraform a la VM de Moodle, y cuál no?**
   La URI del vault, el `client_id` de la identidad y el nombre del secreto, todos públicos. La contraseña no: la VM la pide a IMDS con su identidad y la escribe en un fichero `0600`.
8. **¿Por qué *user-assigned* en lugar de *system-assigned* para el VMSS?**
   Existe antes que el VMSS, así el `role_assignment` está propagado en el primer arranque de `cloud-init`. Con system-assigned, la identidad nace con la VM y el primer intento de leer el secreto suele fallar.
9. **¿Cómo garantiza 11.6 que Key Vault y MySQL rotan juntos?**
   Los dos `_wo_version` apuntan al mismo local derivado de `time_rotating`; en el `apply` en que cambia, ambos se reescriben con el mismo valor efímero. Para urgencias: `-replace=time_rotating.mysql`.
10. **¿Qué `key_opts` necesita una CMK y por qué no los seis del original?**
    Solo `wrapKey` y `unwrapKey`: una CMK envuelve claves de datos. Dar también `sign`, `encrypt` o `decrypt` amplía lo que un permiso comprometido puede hacer.
11. **¿Por qué emitir el certificado en el vault en vez de importar un PFX?**
    La clave privada nunca sale; la renovación es automática (`AutoRenew`); y no hay contraseña de PFX en el código ni en el estado. El gateway lo lee por `versionless_secret_id` y recoge la renovación solo.
12. **¿Qué diferencia hay entre `soft_delete_retention_days` y `purge_protection_enabled`?**
    El primero define cuánto tiempo es recuperable un vault o secreto borrado (7-90 días, siempre activo). El segundo impide purgar antes del plazo, a cualquiera, y es irreversible: pro sí, dev no.
13. **¿Cómo demuestras que un secreto no está en el estado?**
    `terraform state pull | jq` sobre los atributos del recurso: `value` y `value_wo` a `null`. Y `grep` de un fragmento del valor real sobre el `tfstate`: cero coincidencias.
14. **¿Qué de esta página se prueba en Topaz y qué no?**
    Sí: vault, secretos (crear, versionar, leer con CLI), estado con y sin `_wo`, rotación por versión. No: evaluación de RBAC, IMDS, MySQL, emisión de certificados y renovación. Eso se valida con `plan` y se prueba en Azure real.
15. **¿Qué pasa si `network_acls` está en *Deny* y el runner de CI/CD no está en `ip_rules`?**
    Terraform gestiona el vault (plano de gestión, por ARM) pero no puede escribir secretos (plano de datos, bloqueado). En pro, runner autoalojado en la VNet con private endpoint ([páginas 12](index.md#pagina-12) y 13).

---

## 11. Referencias

- [Azure Key Vault: visión general](https://learn.microsoft.com/es-es/azure/key-vault/general/overview), [claves, secretos y certificados](https://learn.microsoft.com/es-es/azure/key-vault/general/about-keys-secrets-certificates) y [buenas prácticas](https://learn.microsoft.com/es-es/azure/key-vault/general/best-practices)
- [Guía de RBAC para Key Vault](https://learn.microsoft.com/es-es/azure/key-vault/general/rbac-guide) (roles integrados, ámbito por objeto) y [migración desde políticas de acceso](https://learn.microsoft.com/es-es/azure/key-vault/general/rbac-migration)
- [Borrado suave y protección de purga](https://learn.microsoft.com/es-es/azure/key-vault/general/soft-delete-overview)
- [`azurerm_key_vault`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault), [`azurerm_key_vault_secret`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault_secret) (`value_wo`), [`ephemeral azurerm_key_vault_secret`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/ephemeral-resources/key_vault_secret), [`azurerm_key_vault_key`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault_key) y [`azurerm_key_vault_certificate`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/key_vault_certificate)
- [Recursos efímeros en Terraform](https://developer.hashicorp.com/terraform/language/resources/ephemeral), [argumentos write-only](https://developer.hashicorp.com/terraform/language/resources/ephemeral/write-only) y [`ephemeral random_password`](https://registry.terraform.io/providers/hashicorp/random/latest/docs/ephemeral-resources/password)
- [`time_rotating`](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/rotating) y [`time_sleep`](https://registry.terraform.io/providers/hashicorp/time/latest/docs/resources/sleep)
- [Obtener un token con identidad gestionada desde una VM (IMDS)](https://learn.microsoft.com/es-es/entra/identity/managed-identities-azure-resources/how-to-use-vm-token) y [referencias a Key Vault en App Service](https://learn.microsoft.com/es-es/azure/app-service/app-service-key-vault-references)
- [Rotación automática de claves](https://learn.microsoft.com/es-es/azure/key-vault/keys/how-to-configure-key-rotation) y [renovación de certificados](https://learn.microsoft.com/es-es/azure/key-vault/certificates/tutorial-rotate-certificates)
- [Application Gateway con certificados de Key Vault](https://learn.microsoft.com/es-es/azure/application-gateway/key-vault-certs)
- [Registro de auditoría de Key Vault](https://learn.microsoft.com/es-es/azure/key-vault/general/logging) (la tabla `AZKVAuditLogs` de la [página 14](index.md#pagina-14))
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)