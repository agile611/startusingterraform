# 🔒 Valores sensibles: por dónde pasan y dónde se quedan

> Un secreto no se filtra porque esté en el sitio equivocado; se filtra porque tiene **copias** en sitios que nadie contó. Terraform es especialmente bueno haciendo copias: la contraseña de MySQL de Moodle que escribes una vez acaba en el fichero `.tf`, en el historial de Git, en el `plan` guardado, en el estado, en un output, en el log de depuración y en el `cloud-init` de la VM. Esta página recorre ese camino copia a copia y explica qué hace de verdad cada mecanismo del lenguaje: `sensitive` oculta la pantalla y nada más; `ephemeral` impide que el valor se persista; el estado y el plan guardan todo lo que no sea efímero, incluidas claves que tú no escribiste. Termina con cómo se autentica Terraform sin secretos en el código, cómo detectar una fuga antes del `push` y qué hacer cuando ya ha ocurrido. Todo el laboratorio funciona en **Topaz**: no necesita permisos ni red, solo mirar dentro de los ficheros que Terraform produce.

**🎯 Objetivos de aprendizaje**
- Enumerar las copias que Terraform hace de un valor sensible y quién puede leer cada una.
- Distinguir `sensitive` de `ephemeral` y elegir el correcto en variables, outputs y recursos.
- Decidir cómo entra un secreto (tfvars, entorno, gestor) y qué va y qué no va al repositorio.
- Localizar en el estado y en el plan los secretos que Azure genera aunque tú no los escribas.
- Autenticar Terraform y su backend sin credenciales en el código.
- Montar un escáner de secretos en *pre-commit* y ejecutar un plan de respuesta a una fuga.

> **🔷 Requisitos previos.** Páginas 1 a 9 completadas y destruidas, `~/tf-st/providers.tf`, Terraform `>= 1.11`, `jq`, `git`, `gitleaks` y `trivy` instalados (o Docker para ejecutarlos), `az account show --query environmentName -o tsv` → `Topaz`.

---

## 1. El mapa de copias

Antes de elegir herramienta conviene saber contra qué se defiende uno. Sigue la contraseña de MySQL desde que alguien la teclea hasta que Moodle la usa: cada fila es un lugar donde queda una copia, y cada copia tiene un público distinto.

| **Copia** | **Cómo llega** | **Quién la lee** | **Defensa** |
|---|---|---|---|
| Fichero `.tf` (`default`, literal) | Escribiéndola | Todo el repositorio, para siempre (Git no olvida) | Variables sin `default`; escáner en *pre-commit* (10.7) |
| `*.tfvars` | Valor en claro en disco | Quien tenga el portátil o el repo si falla el `.gitignore` | Solo no-secretos en tfvars; secretos por variable efímera (10.4) |
| Entorno (`TF_VAR_*`, `ARM_*`) | `export`, CI | `~/.bash_history`, `/proc/<pid>/environ`, procesos hijos | Leerlo del gestor justo antes; no en el historial (10.4) |
| Plan guardado (`-out`) | Toda variable no efímera y todo atributo | Quien descargue el artefacto del pipeline | Tratarlo como secreto; `ephemeral` no entra en él (10.5) |
| Estado | Todo atributo de todo recurso y `data` | Quien lea el backend; `tfstate.backup` local | Backend cifrado y con RBAC (página 4); argumentos `_wo`; identidades en lugar de claves (10.5) |
| Outputs | `output` con el valor | `terraform output -raw/-json`, estados remotos que los leen, logs del CI | No exportar secretos; si es inevitable, `sensitive` (10.2) |
| Logs | `TF_LOG=DEBUG`, `crash.log` | Cuerpos HTTP completos con el secreto dentro | Nunca DEBUG en CI; borrar tras depurar (10.7) |
| `custom_data`, provisioners | Plantilla con el secreto | Estado, disco de la VM, IMDS de la VM | La VM lo pide con identidad gestionada (página 11) |

> **🔷 El almacén es intercambiable; el problema no.** El original dedica la mitad de la página a comparar Azure Key Vault, AWS Secrets Manager, HashiCorp Vault, GitHub Secrets y Docker Secrets. Son respuestas a la pregunta fácil (dónde guardar). Todas las filas de la tabla anterior siguen existiendo con cualquiera de ellos, porque las copias las hace Terraform, no el almacén. Este curso usa Key Vault (página 11); lo que aprendes aquí vale igual con los otros cuatro.

---

## 2. `sensitive`: la pantalla, no el disco

`sensitive = true` hace una sola cosa: sustituye el valor por `(sensitive value)` en la salida de `plan`, `apply` y `output`. La marca se propaga a todo lo que derive del valor (locals, atributos, plantillas). No cifra nada, no cambia lo que se envía a Azure y **no altera el estado**, que guarda el valor en claro. Sirve para que un vídeo de la terminal o el log de un pipeline no muestren la contraseña; no sirve para nada más.

```hcl
variable "api_key_sms" {                    # una clave de un SaaS externo que sí tiene que teclear alguien
  type        = string
  sensitive   = true                        # el plan muestra (sensitive value); el estado guarda la clave
  description = "Clave del proveedor de SMS para notificaciones de Moodle"
  validation {
    condition     = length(var.api_key_sms) >= 32
    error_message = "La clave tiene al menos 32 caracteres."   # el mensaje no debe incluir var.api_key_sms
  }
}

# La marca se propaga: este local es sensible entero, aunque casi todo sea público
locals {
  config_php = templatefile("${path.module}/config.php.tftpl", { dbhost = azurerm_mysql_flexible_server.moodle.fqdn, smskey = var.api_key_sms })
}

# Outputs: si deriva de algo sensible, sensitive = true es obligatorio (si no, error). Pero -raw y -json lo muestran en claro.
output "api_key_sms" { value = var.api_key_sms, sensitive = true }   # ¿de verdad hace falta exportarla? Casi nunca.

# nonsensitive() quita la marca: solo para lo que de verdad no es secreto y con un comentario que lo justifique
output "mysql_fqdn" { value = nonsensitive(azurerm_mysql_flexible_server.moodle.fqdn) }   # el FQDN es público; heredó la marca por la plantilla

# ❌ El ejercicio del original: sensitive dentro de un resource. No existe: "Unsupported argument".
# resource "azurerm_mssql_server" "x" { administrator_login_password = ...  sensitive = true }
```

> **⚠️ Tres comandos que destapan un output sensible.** `terraform output api_key_sms` muestra `<sensitive>`. Pero `terraform output -raw api_key_sms`, `terraform output -json` y `terraform show -json` lo imprimen en claro, sin aviso. En un pipeline que hace `terraform output -json > outputs.json` para el siguiente paso, todos los outputs sensibles acaban en un artefacto. El laboratorio de 10.8 lo comprueba.

---

## 3. `ephemeral`: lo que no se guarda

Desde Terraform 1.10 un valor puede ser **efímero**: existe durante la ejecución y se descarta. Una variable `ephemeral` no entra en el plan ni en el estado; un recurso `ephemeral` (una lectura de Key Vault, una contraseña aleatoria) tampoco. A cambio, Terraform solo permite usar esos valores en destinos que tampoco persisten: argumentos *write-only* (`_wo`, 1.11), configuración de providers, `connection` y provisioners, otros efímeros, locals (que se vuelven efímeros) y outputs de módulos hijos marcados `ephemeral`. Si intentas ponerlo en un atributo normal o un output raíz, el error es inmediato: es la garantía, no una molestia.

```hcl
variable "api_key_sms" {
  type      = string
  ephemeral = true                          # no va al plan ni al estado. Se pasa por -var, TF_VAR_ o tfvars igual que cualquier otra
}

# Destino write-only: Key Vault la recibe, Terraform no la recuerda. La versión es lo único que dispara una reescritura.
resource "azurerm_key_vault_secret" "sms" {
  name             = "sms-api-key"
  key_vault_id     = azurerm_key_vault.moodle.id
  value_wo         = var.api_key_sms
  value_wo_version = var.api_key_sms_version
}

# En un módulo hijo, un output puede ser efímero (para encadenar a otro _wo). En el raíz, no.
output "clave" { value = var.api_key_sms, ephemeral = true }

# Consecuencia práctica: al aplicar un plan guardado hay que volver a pasar la variable, porque el plan no la contiene:
#   terraform plan -out plan.tfplan          (con TF_VAR_api_key_sms en el entorno)
#   terraform apply plan.tfplan              → error: la variable efímera no está definida. Vuelve a exportarla y repite.
```

| | **`sensitive`** | **`ephemeral`** |
|---|---|---|
| Pantalla de plan/apply | Oculto | Oculto |
| Fichero de plan | En claro | Ausente |
| Estado | En claro | Ausente |
| Destinos permitidos | Cualquiera | Solo `_wo`, providers, provisioners, efímeros, locals |
| Úsalo para | Valores que *tienen* que persistir y no quieres en pantalla | Cualquier secreto cuyo destino tenga argumento `_wo` |

---

## 4. Cómo entra un valor y qué va al repositorio

La mayoría de los secretos de Moodle no debería teclearlos nadie: la contraseña de MySQL la genera `ephemeral "random_password"` y nunca la ve un humano (página 11). Quedan los que vienen de fuera, como la clave del proveedor de SMS. Para esos hay cuatro vías de entrada, y el orden importa.

```bash
# 1. Recomendado: del gestor al entorno, en el mismo comando, sin tocar el historial de la shell
TF_VAR_api_key_sms="$(az keyvault secret show --vault-name kv-ops -n sms-api-key --query value -o tsv)" terraform apply
#    (asignación en la misma línea: el valor no queda exportado en la sesión ni en ~/.bash_history)

# 2. Interactivo, para una prueba puntual: la variable sin default y Terraform la pide sin eco
terraform apply                           # var.api_key_sms: Enter a value: ▮   (ephemeral = true hace que no quede en ningún sitio)

# 3. tfvars: solo para valores que no son secretos. El "terraform.tfvars en .gitignore" del original es una falsa seguridad:
#    el fichero sigue en claro en el disco, en las copias de seguridad del portátil y en el plan.
cat dev.tfvars
entorno          = "dev"
location         = "eastus"
api_key_sms_version = 3                   # la versión sí; la clave no

# 4. -var en la línea de comandos: acaba en el historial y en `ps`. Solo en CI, y solo con valores no secretos.
#    ❌ terraform apply -var="db_password=$DB_PASSWORD"   (el original, tres veces)
```

```text
# .gitignore para un repositorio de Terraform
# (el del original tenía dos líneas fusionadas, ".terraform/credentials.tfstate", y por tanto no ignoraba ni el directorio ni el estado)
.terraform/                 # providers descargados y, con backend local, copias del estado
*.tfstate
*.tfstate.*                 # terraform.tfstate.backup: la copia anterior, con todos los valores
*.tfplan                    # planes guardados: contienen toda variable no efímera
crash.log
crash.*.log
*.auto.tfvars               # se cargan solos: nadie recuerda que están
secret*.tfvars
override.tf
override.tf.json
*_override.tf
*_override.tf.json
.terraformrc
terraform.rc                # credenciales de registries privados
!dev.tfvars                 # los tfvars sin secretos SÍ se versionan: son la definición del entorno
!pro.tfvars
```

> **🔷 La regla de los tfvars.** Un fichero `.tfvars` versionado es documentación viva del entorno: tallas, regiones, versiones, flags. En cuanto contiene un secreto deja de poder versionarse, y entonces pierdes también todo lo demás que había en él. Separa: lo público en `dev.tfvars` en Git; lo secreto por variable efímera desde el gestor. Si hoy tienes un `terraform.tfvars` con contraseñas, saca las contraseñas, no el fichero.

---

## 5. Plan y estado: los secretos que no escribiste

El estado no solo guarda lo que tú pones; guarda **todo lo que Azure devuelve**. Una `azurerm_storage_account` trae sus dos claves de acceso y cuatro connection strings; un `azurerm_mysql_flexible_server` guarda la contraseña de administrador si la pasaste por el atributo normal; un `azurerm_kubernetes_cluster` trae el `kube_config` completo; un `data "azurerm_client_config"` no trae secretos, pero un `data "azurerm_storage_account"` sí. Nada de esto pasa por tu código, pero todo está en el `tfstate` y en cualquier plan guardado que los toque.

```bash
# Inventario de lo sensible en tu estado: qué atributos están marcados y en qué recursos
terraform show -json | jq -r '
  .values.root_module.resources[]
  | .address as $a
  | (.sensitive_values | paths(. == true)) as $p
  | "\($a): \($p | join("."))"' | sort -u
#   azurerm_storage_account.moodledata: primary_access_key
#   azurerm_storage_account.moodledata: primary_blob_connection_string
#   azurerm_storage_account.moodledata: secondary_access_key
#   …
# Y su valor está ahí, en claro:
terraform state pull | jq -r '.resources[] | select(.type == "azurerm_storage_account") | .instances[0].attributes.primary_access_key' | cut -c1-12

# El plan guardado, igual:
terraform plan -out plan.tfplan >/dev/null && terraform show -json plan.tfplan | jq '.variables | keys'   # las variables no efímeras, con valor
terraform show -json plan.tfplan | jq '.planned_values.root_module.resources[].values | keys' | head           # y los atributos conocidos
```

Tres defensas, por orden de eficacia. Primero, **que el secreto no exista**: la VM de Moodle accede a `moodledata` con identidad gestionada y rol, y la cuenta desactiva las claves; sin clave no hay nada que guardar. Segundo, **argumentos *write-only*** para lo que tú aportas (`administrator_password_wo`). Tercero, para lo que inevitablemente queda, **el backend**: cifrado en reposo, versionado, RBAC mínimo, sin `terraform state pull` a discos locales, y el plan tratado como el secreto que es.

```hcl
resource "azurerm_storage_account" "moodledata" {
  # …
  shared_access_key_enabled       = false     # no hay claves que filtrar: el estado guarda primary_access_key = "" 
  default_to_oauth_authentication = true
  allow_nested_items_to_be_public = false
}
resource "azurerm_role_assignment" "web_blob" {                 # la VM accede con su identidad (página 11)
  scope                = azurerm_storage_account.moodledata.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.web.principal_id
}
# El propio provider tiene que hablar con Storage por Entra ID, si no falla al crear contenedores:
provider "azurerm" { storage_use_azuread = true  features {} }

# Backend: sin access_key en el bloque, autenticación por Entra ID
terraform {
  backend "azurerm" {
    resource_group_name  = "rg-tfstate"
    storage_account_name = "sttfstate…"
    container_name       = "tfstate"
    key                  = "moodle/dev.tfstate"
    use_azuread_auth     = true                # el runner necesita "Storage Blob Data Contributor" sobre el contenedor
  }
}
```

---

## 6. Cómo se autentica Terraform sin secretos

El secreto más peligroso de un proyecto Terraform no es la contraseña de MySQL: es la credencial con la que Terraform crea y destruye todo lo demás. El original la mete en el pipeline como `AZURE_CREDENTIALS`, un JSON con `clientSecret` de larga duración. Hay tres formas de no tener ese secreto, y el bloque `provider "azurerm"` no lleva ninguna credencial en ninguna de ellas.

| **Dónde corre** | **Método** | **Configuración** | **Secreto de larga duración** |
|---|---|---|---|
| Tu portátil | Azure CLI | `az login`; el provider reutiliza el token. `ARM_SUBSCRIPTION_ID` obligatorio en 4.x | Ninguno (tokens de horas, MFA) |
| GitHub Actions / GitLab / Azure DevOps | OIDC (*workload identity federation*) | `ARM_USE_OIDC=true`, `ARM_CLIENT_ID`, `ARM_TENANT_ID`; credencial federada en la app registration que confía en el repo y la rama (página 12) | Ninguno (token por job, 1 h) |
| Runner autoalojado en Azure | Identidad gestionada | `ARM_USE_MSI=true` (+ `ARM_CLIENT_ID` si es user-assigned) | Ninguno |
| Legado | Service principal + secreto | `ARM_CLIENT_SECRET` (nunca `client_secret =` en el bloque provider) | Sí: rótalo cada 90 días y planifica su eliminación |
| Topaz | Emulador | Lo que fija `~/tf-st/providers.tf` (endpoints del emulador); acepta cualquier identidad | Ninguno real: por eso no valida RBAC |

> **⚠️ Mínimo privilegio para la identidad de Terraform.** *Owner* sobre la suscripción es lo habitual y lo peor: quien controle el pipeline controla todo. *Contributor* sobre el grupo de recursos de Moodle más *Role Based Access Control Administrator* limitado a los roles que el código asigna (con `condition`), más los roles de plano de datos concretos (Key Vault Secrets Officer, Storage Blob Data Contributor). Y una identidad por entorno: la de dev no puede tocar pro.

---

## 7. Detectar antes del `push`, responder después

Los secretos llegan a Git por descuido, no por decisión: una prueba rápida con la clave en el `default`, un `tfvars` con nombre no cubierto por el `.gitignore`, un `crash.log`. Un escáner en *pre-commit* lo detiene en el portátil, y el mismo escáner en el pipeline detiene lo que se coló. Y cuando falla todo, el orden de la respuesta importa más que la velocidad.

```bash
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.24.0
    hooks: [{ id: gitleaks }]                              # secretos: claves, tokens, contraseñas por patrón y entropía
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.99.0
    hooks:
      - id: terraform_fmt
      - id: terraform_validate
      - id: terraform_trivy                                # mala configuración: contraseña en claro, storage sin TLS, KV sin purge protection
        args: ["--args=--severity HIGH,CRITICAL"]
pre-commit install && pre-commit run --all-files

# Logs de depuración: TF_LOG=DEBUG vuelca cuerpos HTTP completos, con el secreto dentro
TF_LOG=DEBUG TF_LOG_PATH=/tmp/tf.log terraform apply     # solo en local, solo para depurar…
grep -c '"value"' /tmp/tf.log; shred -u /tmp/tf.log      # …y bórralo después. En CI, TF_LOG nunca pasa de INFO.

# ─── Respuesta a una fuga, en este orden ─────────────────────────────────────────
# 1. Rotar. El secreto está comprometido desde el primer segundo; borrar el commit no lo descomprometer.
#    Key Vault: terraform apply -replace=time_rotating.mysql (página 11). Clave de storage: az storage account keys renew.
#    Service principal: az ad app credential delete. Token de GitHub/GitLab: revocar en la plataforma.
# 2. Revisar el uso: AZKVAuditLogs, StorageBlobLogs, AzureActivity, sign-in logs de la identidad (página 14) desde la fecha del commit.
# 3. Limpiar el historial (solo después de 1 y 2; sabiendo que los forks y clones lo conservan):
git filter-repo --invert-paths --path secret.tfvars      # o --replace-text con el valor
git push --force --all && git push --force --tags        # y avisar a todo el equipo: tienen que re-clonar
# 4. Cerrar la puerta: la regla de gitleaks o el patrón de .gitignore que lo habría evitado, y el escáner en el pipeline.
```

---

## 8. Laboratorio en Topaz

Este laboratorio no crea nada complejo: una cuenta de almacenamiento y dos variables. Su objetivo es que veas con tus ojos dónde está cada copia. Todo funciona en el emulador porque solo mira ficheros que Terraform produce en tu disco.

```bash
mkdir -p ~/tf-sec && cd ~/tf-sec && cp ~/tf-st/providers.tf . && git init -q

# ─── 1. Dos variables, misma pinta, destino distinto ─────────────────────────────
cat > main.tf <<'EOF'
variable "clave_sensible" { type = string, sensitive = true }
variable "clave_efimera"  { type = string, ephemeral = true }
variable "entorno"        { type = string, default = "dev" }
locals { tags = { proyecto = "moodle", entorno = var.entorno, gestion = "terraform" } }

resource "azurerm_resource_group" "sec" { name = "rg-sec-lab-${var.entorno}", location = "eastus", tags = local.tags }

# (a) Con claves: el estado guarda primary_access_key aunque nadie la haya escrito
resource "azurerm_storage_account" "con_claves" {
  name = "stsecclaves${substr(md5(azurerm_resource_group.sec.id), 0, 8)}"
  resource_group_name = azurerm_resource_group.sec.name, location = azurerm_resource_group.sec.location
  account_tier = "Standard", account_replication_type = "LRS", min_tls_version = "TLS1_2"
  tags = merge(local.tags, { nota = var.clave_sensible })   # una etiqueta con la variable sensible: atributo normal → estado
}
# (b) Sin claves: no hay nada que guardar
resource "azurerm_storage_account" "sin_claves" {
  name = "stsecsin${substr(md5(azurerm_resource_group.sec.id), 0, 8)}"
  resource_group_name = azurerm_resource_group.sec.name, location = azurerm_resource_group.sec.location
  account_tier = "Standard", account_replication_type = "LRS", min_tls_version = "TLS1_2"
  shared_access_key_enabled = false
  tags = local.tags
}
# La efímera solo puede ir a un contexto efímero: aquí, un provisioner que la usa sin guardarla
resource "terraform_data" "usa_efimera" {
  provisioner "local-exec" { command = "echo 'efímera recibida: ${length(var.clave_efimera)} caracteres'" }
}
output "clave_sensible" { value = var.clave_sensible, sensitive = true }
output "clave_efimera"  { value = var.clave_efimera }          # ← error deliberado: se corrige en el paso 2
EOF
terraform init >/dev/null
TF_VAR_clave_sensible="SENSIBLE-abcdef123456" TF_VAR_clave_efimera="EFIMERA-uvwxyz987654" terraform validate
#   Error: Output value is not ephemeral… "clave_efimera" — Terraform no permite persistir un efímero. Es la garantía.

# ─── 2. Corrige y aplica ─────────────────────────────────────────────────────────
sed -i '/output "clave_efimera"/d' main.tf
export TF_VAR_clave_sensible="SENSIBLE-abcdef123456" TF_VAR_clave_efimera="EFIMERA-uvwxyz987654"   # solo para el laboratorio; ver 10.4
terraform plan -out plan.tfplan | grep -E "nota|sensitive"       # tags.nota = (sensitive value): la pantalla no lo muestra
terraform apply plan.tfplan
#   Error: la variable efímera no está en el plan guardado → Terraform pide volver a pasarla. Repite:
terraform apply plan.tfplan -var "clave_efimera=$TF_VAR_clave_efimera" 2>/dev/null || terraform apply -auto-approve

# ─── 3. Dónde está cada copia ────────────────────────────────────────────────────
echo "── plan guardado:";  terraform show -json plan.tfplan | jq -c '.variables'
#   {"clave_sensible":{"value":"SENSIBLE-abcdef123456"},"entorno":{"value":"dev"}}   ← la sensible está en claro; la efímera no existe
echo "── estado:";  terraform state pull | grep -o 'SENSIBLE-[a-z0-9]*' | sort -u          # en claro, dentro de tags.nota
terraform state pull | grep -c EFIMERA                                                      # 0: nunca se guardó
echo "── claves que nadie escribió:"
terraform state pull | jq -r '.resources[] | select(.type == "azurerm_storage_account") | "\(.name): \(.instances[0].attributes.primary_access_key | length) caracteres"'
#   con_claves: 88 caracteres   ← Azure (y Topaz) generan la clave y el estado la guarda
#   sin_claves: 0 caracteres    ← no hay nada que filtrar
echo "── outputs:";  terraform output clave_sensible; terraform output -raw clave_sensible; echo; terraform output -json | jq -c .
#   <sensitive>   /   SENSIBLE-abcdef123456   /   {"clave_sensible":{"sensitive":true,"type":"string","value":"SENSIBLE-…"}}
echo "── inventario de sensibles:"
terraform show -json | jq -r '.values.root_module.resources[] | .address as $a | (.sensitive_values | paths(. == true)) as $p | "\($a): \($p | join("."))"' | sort -u
echo "── log de depuración:"
TF_LOG=DEBUG TF_LOG_PATH=/tmp/tf.log terraform plan >/dev/null 2>&1; grep -c SENSIBLE /tmp/tf.log; shred -u /tmp/tf.log   # > 0: el cuerpo HTTP lleva las tags

# ─── 4. El escáner atrapa lo que el .gitignore no ───────────────────────────────
curl -sO https://raw.githubusercontent.com/github/gitignore/main/Terraform.gitignore && mv Terraform.gitignore .gitignore && printf '*.tfplan\n!dev.tfvars\n' >> .gitignore
echo 'clave_sensible = "SENSIBLE-abcdef123456"' > secreto.auto.tfvars    # ignorado por *.auto.tfvars
echo 'clave_sensible = "SENSIBLE-abcdef123456"' > valores.tfvars          # no lo cubre ningún patrón
git add -A && git status --short                                          # valores.tfvars aparece; plan.tfplan y tfstate no
gitleaks git --pre-commit --staged -v                                     # o: docker run --rm -v "$PWD:/repo" -w /repo ghcr.io/gitleaks/gitleaks:latest git --pre-commit --staged
#   Finding: valores.tfvars:1 (generic-api-key) … leaks found: 1 → con pre-commit, el commit se bloquea aquí
trivy config . --severity HIGH,CRITICAL                                   # además: con_claves sin shared_access_key_enabled = false, etc.
rm valores.tfvars secreto.auto.tfvars

# ─── 5. Limpiar ────────────────────────────────────────────────────────────────
unset TF_VAR_clave_sensible TF_VAR_clave_efimera
terraform destroy -auto-approve -var clave_sensible=x -var clave_efimera=x   # destroy también evalúa la configuración: pide las variables
rm -f plan.tfplan terraform.tfstate*
```

```bash
# ─── Solo Azure real ────────────────────────────────────────────────────────────
az storage account keys list -n <sin_claves> -g rg-sec-lab-dev            # las claves existen pero están deshabilitadas: cualquier uso devuelve KeyBasedAuthenticationNotPermitted
az storage container create --account-name <sin_claves> -n prueba --auth-mode login   # por Entra ID sí (con Storage Blob Data Contributor)
# Backend sin clave: en providers.tf, use_azuread_auth = true; y en la identidad del runner, el rol sobre el contenedor de estado (página 12)
az role assignment list --scope $(az storage account show -n <sttfstate> --query id -o tsv) --query "[].{quien:principalName, rol:roleDefinitionName}" -o table
```

---

## 9. Errores comunes

> ⚠️ **Solución de problemas**
>
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | *Unsupported argument: sensitive* dentro de un `resource` (ejercicio del original) | `sensitive` solo existe en `variable` y `output`. Los atributos de recurso heredan la marca del valor que reciben; si quieres que no persistan, usa el argumento `_wo` |
> | *Output refers to sensitive values* | El valor deriva de algo sensible. O añades `sensitive = true` al output, o te preguntas por qué exportas un secreto. Si de verdad no lo es (un FQDN que heredó la marca por una plantilla), `nonsensitive()` con comentario |
> | "He puesto `sensitive = true` y sigue en el estado" | Correcto: `sensitive` solo oculta la pantalla. Para no persistir: `ephemeral` en el origen y `_wo` en el destino (10.3, página 11). Para lo que no admite `_wo`: backend cifrado y rotación |
> | *Output value is not ephemeral* / *Invalid use of ephemeral value* | Intentas persistir un efímero (output raíz, atributo normal, `data`). Destinos válidos: `_wo`, providers, provisioners, otros efímeros, locals, outputs `ephemeral` de módulos hijos |
> | `terraform apply plan.tfplan` exige una variable que ya pasé en el `plan` | Es efímera: no está en el fichero de plan. Vuelve a pasarla por `TF_VAR_` en el `apply`. En CI, el paso de apply lee del gestor igual que el de plan |
> | El secreto aparece en el log del pipeline con asteriscos… y una línea más abajo en claro | El *masking* solo cubre el valor exacto: `terraform output -json`, `-raw`, un `base64` o un JSON lo destapan. La solución no es enmascarar mejor sino que el pipeline nunca tenga el secreto (página 12) |
> | El `.gitignore` del original no ignora nada | Dos patrones fusionados en una línea (`.terraform/credentials.tfstate`). Usa la plantilla oficial `Terraform.gitignore` y añade `*.tfplan`; permite explícitamente los tfvars sin secretos con `!dev.tfvars` |
> | "Está en `.gitignore`, así que es seguro" | `.gitignore` no protege ficheros ya versionados (`git rm --cached`) ni copias de seguridad ni el plan. Un `tfvars` con secretos sigue en claro en disco: saca los secretos, no el fichero |
> | He borrado el commit con la contraseña y ya no aparece en GitHub | Sigue en los clones, forks, cachés y en el *reflog* del servidor durante semanas. Primero rotar, después revisar el uso, y solo entonces `git filter-repo` (10.7) |
> | Claves de storage en el estado sin haberlas escrito | Azure las devuelve como atributos. `shared_access_key_enabled = false` y acceso por identidad; el estado guarda cadenas vacías. Igual con `kube_config`, connection strings de Service Bus, etc.: inventario con `sensitive_values` (10.5) |
> | *KeyBasedAuthenticationNotPermitted* al crear un contenedor tras desactivar las claves | El provider sigue hablando con Storage por clave. `storage_use_azuread = true` en el bloque `provider` y el rol *Storage Blob Data Contributor* para la identidad de Terraform |
> | `client_secret = "…"` en el bloque `provider "azurerm"` | Nunca. Todo lo del provider va por `ARM_*`, y lo ideal es que no haya secreto: CLI en local, OIDC en CI, identidad gestionada en runners de Azure (10.6) |
> | *Error: building account: … subscription ID could not be determined* | azurerm 4.x exige `ARM_SUBSCRIPTION_ID` (o `subscription_id` en el provider, que no es secreto) incluso con `az login` |
> | El `error_message` de una `validation` muestra la contraseña | Interpolaste la variable en el mensaje; los mensajes no heredan la marca. Describe la regla, no el valor |
> | `TF_LOG=DEBUG` dejado en el CI | Cuerpos HTTP completos con cada secreto que Terraform envía o recibe, en un log que se conserva meses. `TF_LOG` nunca por encima de `INFO` en CI; en local, `TF_LOG_PATH` y `shred` |
> | `terraform.tfstate.backup` en el portátil con backend remoto | Queda de una migración de backend o de un `state pull >`. Bórralo; el `.gitignore` lo cubre pero el disco no. Con backend remoto no debe existir estado local |
> | En Topaz: cualquier identidad puede hacer cualquier cosa | Esperado: el emulador no evalúa RBAC ni valida credenciales. Todo lo de esta página que ocurre en tu disco (plan, estado, outputs, logs, Git) es idéntico a Azure real; lo que depende de permisos se prueba allí |

---

## 10. Autoevaluación

1. **Enumera las copias que Terraform puede hacer de una contraseña que solo escribiste una vez.**
   Fichero `.tf`, historial de Git, `tfvars`, entorno e historial de la shell, plan guardado, estado (y su `.backup`), outputs, logs de depuración y `custom_data` de la VM.
2. **¿Qué hace exactamente `sensitive = true`?**
   Sustituye el valor por `(sensitive value)` en la salida de plan, apply y output, y propaga esa marca a todo lo derivado. No cifra, no cambia lo que se envía y no altera el estado.
3. **¿Qué diferencia práctica hay entre `sensitive` y `ephemeral`?**
   `sensitive` oculta la pantalla pero el valor va al plan y al estado; `ephemeral` no lo persiste en ninguno de los dos, a cambio de admitir solo destinos que tampoco persisten.
4. **¿Por qué `terraform output db_password` mostrando `<sensitive>` no basta?**
   `-raw`, `-json` y `terraform show -json` lo imprimen en claro. Un pipeline que exporta outputs a JSON expone todos los sensibles.
5. **¿Por qué "`terraform.tfvars` en `.gitignore`" es una falsa seguridad?**
   El fichero sigue en claro en disco, en copias de seguridad y en el plan; y en cuanto contiene un secreto pierdes la posibilidad de versionar el resto de la configuración del entorno.
6. **¿Cuál es la vía de entrada recomendada para un secreto externo?**
   Variable `ephemeral` alimentada del gestor en el mismo comando (`TF_VAR_x="$(az keyvault secret show …)" terraform apply`), sin `export` ni `-var`.
7. **¿Qué secretos guarda el estado aunque no los hayas escrito?**
   Los que Azure devuelve como atributos: claves y connection strings de Storage, `kube_config`, claves de Service Bus… Se inventarían con `sensitive_values` en `terraform show -json`.
8. **¿Cuál es la defensa más eficaz contra las claves de storage en el estado?**
   Que no existan: `shared_access_key_enabled = false` y acceso por identidad con rol. Después, argumentos `_wo`; por último, un backend cifrado con RBAC mínimo.
9. **¿Cómo se autentica Terraform en un pipeline sin un secreto de larga duración?**
   OIDC: `ARM_USE_OIDC=true`, `ARM_CLIENT_ID`, `ARM_TENANT_ID`, y una credencial federada que confía en el repositorio y la rama. Token de una hora por job.
10. **¿Qué está mal en `azure/login@v1` con `creds: ${{ secrets.AZURE_CREDENTIALS }}`?**
    Es un JSON con `clientSecret` de larga duración guardado en la plataforma de CI: el secreto más valioso del proyecto, sin rotación y con permisos amplios.
11. **Orden correcto tras descubrir una contraseña en un commit.**
    Rotar, revisar el uso desde la fecha del commit (auditoría), limpiar el historial avisando al equipo, y añadir la regla o patrón que lo habría evitado.
12. **¿Qué parte de esta página funciona igual en Topaz y en Azure real?**
    Todo lo que ocurre en tu disco: plan, estado, outputs, logs, Git y escáneres. Lo que Topaz no hace es evaluar permisos ni credenciales.

---

## 11. Referencias

- [Variables sensibles](https://developer.hashicorp.com/terraform/language/values/variables#suppressing-values-in-cli-output), [variables efímeras](https://developer.hashicorp.com/terraform/language/values/variables#exclude-values-from-state) y [`nonsensitive()`](https://developer.hashicorp.com/terraform/language/functions/nonsensitive)
- [Recursos efímeros](https://developer.hashicorp.com/terraform/language/resources/ephemeral) y [argumentos write-only](https://developer.hashicorp.com/terraform/language/resources/ephemeral/write-only)
- [Datos sensibles en el estado](https://developer.hashicorp.com/terraform/language/state/sensitive-data) y [formato JSON de `terraform show`](https://developer.hashicorp.com/terraform/cli/commands/show) (`sensitive_values`)
- [Autenticación del provider azurerm con OIDC](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/service_principal_oidc), [con identidad gestionada](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/managed_service_identity) y [con Azure CLI](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/azure_cli)
- [Backend azurerm](https://developer.hashicorp.com/terraform/language/backend/azurerm) (`use_azuread_auth`)
- [Desactivar la autorización por clave compartida en Storage](https://learn.microsoft.com/es-es/azure/storage/common/shared-key-authorization-prevent)
- [Federación de identidades de carga de trabajo (OIDC)](https://learn.microsoft.com/es-es/entra/workload-id/workload-identity-federation)
- [gitleaks](https://github.com/gitleaks/gitleaks), [pre-commit-terraform](https://github.com/antonbabenko/pre-commit-terraform) y [Trivy para configuración IaC](https://trivy.dev/latest/docs/scanner/misconfiguration/)
- [Plantilla oficial `Terraform.gitignore`](https://github.com/github/gitignore/blob/main/Terraform.gitignore) y [git-filter-repo](https://github.com/newren/git-filter-repo)
- [OWASP Secrets Management Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Secrets_Management_Cheat_Sheet.html)
- [Azure Local Emulator (Topaz)](https://github.com/Azure/azure-local-emulator)