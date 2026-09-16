# 🧰 Instalación de herramientas y arranque de Topaz

## 1. Qué se instala y para qué

| Herramienta | Versión del curso | Para qué |
|---|---|---|
| **Terraform** | `1.11.x`, fijada con `tenv` | Todo el curso. La versión fijada garantiza que tu plan y el del pipeline coinciden |
| **Azure CLI** | `2.7x` o superior | Autenticación (el provider la reutiliza), comprobaciones fuera de Terraform, provocar derivas en los laboratorios |
| **Docker** | Engine o Desktop | Ejecutar Topaz |
| **Git** | 2.4x | Versionado desde la [página 1](index.md#pagina-1); pipelines desde la 13 |
| **jq** | 1.7 | Leer `terraform show -json` y salidas de `az`: aparece en casi todos los laboratorios |
| **Editor** | VS Code + extensión HashiCorp Terraform | Formato, validación y autocompletado del provider. Opcional pero muy recomendable |
| **tflint, trivy, gitleaks** | Se instalan en la [página 13](index.md#pagina-13) | Comprobaciones del pipeline; no hacen falta todavía |
| **Azure PowerShell** | No se usa | El original lo lista como opcional. El curso es `bash` + `az`; dos CLIs para lo mismo es una fuente de confusión |

## 2. Instalación por sistema

La ruta canónica del curso es Ubuntu (nativo o en WSL2). macOS va con Homebrew. En Windows sin WSL2 se puede seguir con `winget`, pero los scripts de los laboratorios son `bash` y habría que traducirlos.

```bash
# ─── Ubuntu 22.04 / 24.04 (también WSL2) ─────────────────────────────────────────
sudo apt-get update && sudo apt-get install -y ca-certificates curl gnupg lsb-release git jq unzip

# Azure CLI desde el repositorio de Microsoft (no "curl | sudo bash": un fichero remoto ejecutado como root sin leerlo)
sudo mkdir -p /etc/apt/keyrings
curl -sLS https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /etc/apt/keyrings/microsoft.gpg >/dev/null
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $(lsb_release -cs) main" \
  | sudo tee /etc/apt/sources.list.d/azure-cli.list
sudo apt-get update && sudo apt-get install -y azure-cli

# Terraform con tenv: gestor de versiones (lee .terraform-version y required_version)
curl -sLO https://github.com/tofuutils/tenv/releases/latest/download/tenv_$(curl -s https://api.github.com/repos/tofuutils/tenv/releases/latest | jq -r .tag_name)_amd64.deb
sudo dpkg -i tenv_*_amd64.deb && rm tenv_*_amd64.deb
tenv tf install 1.11.4 && tenv tf use 1.11.4                  # ajusta al último parche 1.11.x
#   Alternativa sin gestor: repositorio apt de HashiCorp (ver referencias); o binario + comprobación de SHA256SUMS. Nunca "el que haya en PATH".

# Docker Engine (en WSL2 también vale Docker Desktop con integración WSL activada)
curl -fsSL https://get.docker.com -o get-docker.sh && less get-docker.sh   # léelo antes: es lo que no hacíamos con la CLI
sudo sh get-docker.sh && sudo usermod -aG docker "$USER" && newgrp docker

# ─── macOS ───────────────────────────────────────────────────────────────────────
brew install azure-cli git jq tenv && brew install --cask docker
tenv tf install 1.11.4 && tenv tf use 1.11.4

# ─── Windows sin WSL2 (no recomendado para el curso) ─────────────────────────────
winget install Microsoft.AzureCLI Git.Git jqlang.jq Docker.DockerDesktop Hashicorp.Terraform

# ─── Comprobar versiones (esto NO es la verificación; la verificación es 3.6) ────
terraform version -json | jq -r .terraform_version     # 1.11.x
az version --query '"azure-cli"' -o tsv                # 2.7x
docker --version && git --version && jq --version
```

## 3. Por qué la versión va fijada, en dos sitios

Terraform cambia el formato del estado y el comportamiento del plan entre versiones menores. Si tú planificas con 1.11 y el pipeline aplica con 1.9, el plan no coincide, o el estado escrito por uno no lo lee el otro. La versión se fija en dos sitios que se refuerzan:

- **`.terraform-version`** en la raíz del repositorio: `tenv` (y su antecesor `tfenv`) lo leen y cambian de binario al entrar en el directorio. Es para las personas.
- **`required_version`** en el bloque `terraform {}`: si el binario no cumple, `init` falla. Es para el pipeline y para quien no usa gestor.

Lo mismo aplica al provider: `version = "~> 4.20"` acepta parches y menores de la 4, no la 5. Y `.terraform.lock.hcl`, que `init` genera, fija el parche exacto y sus sumas; va al repositorio ([página 4](index.md#pagina-4)).

## 4. Topaz: arrancar, registrar, autenticarse

Topaz es un contenedor que implementa la API de Azure Resource Manager. Para que `az` y Terraform hablen con él en lugar de con Azure hacen falta tres cosas: que `az` lo conozca como una nube más (`az cloud register`), que confíe en su certificado, y que la sesión contra él no se mezcle con la de Azure real. Esto último se consigue con un directorio de configuración separado (`AZURE_CONFIG_DIR`): dos "perfiles" de `az` que no se ven entre sí.

> **⚠️ Valores que dependen de la versión de Topaz.** Imagen, puerto, ruta de metadatos y certificado cambian entre versiones del emulador. Están en las variables del principio del laboratorio; contrástalas con el README del repositorio antes de ejecutar. El resto (cómo se registra una nube, cómo confía cada herramienta en un certificado, cómo se configura el provider) es estable.

## 5. El `providers.tf` del curso

Este fichero se copia desde `~/tf-st` en todos los laboratorios. Cada línea tiene un motivo.

```hcl
terraform {
  required_version = "~> 1.11"                       # 3.3: falla el init si el binario no cumple
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.20" }
  }
}

provider "azurerm" {
  features {}

  # Nube: si metadata_host está vacío, el provider habla con Azure público. Si apunta al emulador,
  # descarga de ahí los endpoints (ARM, autenticación, storage…) y no toca Azure. Es el interruptor.
  metadata_host = var.metadata_host

  # azurerm 4.x exige subscription_id explícito: ya no lo toma del contexto de az. Es una protección:
  # obliga a decir a qué suscripción se aplica. En Topaz, la que el emulador expone; en real, la tuya.
  subscription_id = var.subscription_id
  tenant_id       = var.tenant_id

  # Autenticación: la sesión de az. Ni client_secret ni contraseñas aquí, nunca (página 12: OIDC en el pipeline).
  use_cli = true

  # El emulador no registra proveedores de recursos; en Azure real, el registro lo hace la plataforma (página 12)
  resource_provider_registrations = "none"

  # Hablar con storage con Entra ID, no con claves: coherente con shared_access_key_enabled = false en todo el curso
  storage_use_azuread = true
}

variable "metadata_host"   { type = string, default = "" }   # vacío = Azure público. El valor de Topaz llega por TF_VAR_metadata_host
variable "subscription_id" { type = string }
variable "tenant_id"       { type = string }
```

Las tres variables no tienen valor en el código: llegan por entorno (`TF_VAR_*`) desde el script `topaz.env` del laboratorio. Así el mismo `providers.tf` sirve para el emulador y para Azure real, y el cambio entre ambos es cambiar de entorno, no editar código.

## 6. Laboratorio: arrancar Topaz y verificar con un apply

```bash
# ─── 0. Valores de tu versión de Topaz: contrástalos con el README ──────────────
TOPAZ_IMAGE=ghcr.io/azure/azure-local-emulator:latest   # o el nombre que indique el README
TOPAZ_PORT=8899
TOPAZ_HOST=localhost
TOPAZ_META=https://$TOPAZ_HOST:$TOPAZ_PORT               # host de metadatos: debe responder en /metadata/endpoints?api-version=2022-09-01

# ─── 1. Arrancar el emulador ─────────────────────────────────────────────────────
docker volume create topaz-datos                          # los recursos sobreviven a reinicios del contenedor
docker run -d --name topaz --restart unless-stopped -p $TOPAZ_PORT:$TOPAZ_PORT -v topaz-datos:/data "$TOPAZ_IMAGE"
sleep 5 && docker logs topaz --tail 5
curl -sk "$TOPAZ_META/metadata/endpoints?api-version=2022-09-01" | jq '{arm: .resourceManager, login: .authentication.loginEndpoint}'
#   Si esto responde con JSON, el emulador está vivo y expone lo que az y Terraform necesitan.

# ─── 2. Certificado: que az (Python) y Terraform (Go) confíen en él ──────────────
mkdir -p ~/.topaz && docker cp topaz:/certs/topaz.crt ~/.topaz/topaz.crt 2>/dev/null \
  || openssl s_client -connect $TOPAZ_HOST:$TOPAZ_PORT -showcerts </dev/null 2>/dev/null | openssl x509 > ~/.topaz/topaz.crt
#   Opción limpia: añadirlo al almacén del sistema (Ubuntu): sudo cp ~/.topaz/topaz.crt /usr/local/share/ca-certificates/ && sudo update-ca-certificates
#   Opción por proceso (la que usa topaz.env): REQUESTS_CA_BUNDLE para az, SSL_CERT_FILE para Terraform.

# ─── 3. Perfil de az separado para Topaz, y la nube registrada ──────────────────
cat > ~/.topaz/topaz.env <<EOF
# source ~/.topaz/topaz.env  → esta terminal habla con el emulador
export AZURE_CONFIG_DIR=~/.azure-topaz                    # sesión y nube propias: no toca ~/.azure (Azure real)
export REQUESTS_CA_BUNDLE=~/.topaz/topaz.crt
export SSL_CERT_FILE=~/.topaz/topaz.crt
export ARM_METADATA_HOSTNAME=$TOPAZ_HOST:$TOPAZ_PORT       # el provider también lo lee de aquí
export TF_VAR_metadata_host=$TOPAZ_HOST:$TOPAZ_PORT
export TF_VAR_subscription_id=\$(az account show --query id -o tsv 2>/dev/null)
export TF_VAR_tenant_id=\$(az account show --query tenantId -o tsv 2>/dev/null)
export PS1="(topaz) \$PS1"                                # que se vea en el prompt
EOF
source ~/.topaz/topaz.env
az cloud register -n Topaz --endpoint-resource-manager "$TOPAZ_META" \
  --endpoint-active-directory "$(curl -sk "$TOPAZ_META/metadata/endpoints?api-version=2022-09-01" | jq -r .authentication.loginEndpoint)" \
  --endpoint-active-directory-resource-id "$TOPAZ_META" --suffix-storage-endpoint "$TOPAZ_HOST:$TOPAZ_PORT"
#   Si tu versión trae un script de registro (topaz-cli o similar), úsalo: hace exactamente esto con los sufijos correctos.
az cloud set -n Topaz
az login                                                  # el emulador acepta cualquier identidad; en Azure real abriría el navegador
az account show --query "{nube:environmentName, sub:id, tenant:tenantId}" -o table   # environmentName = Topaz
source ~/.topaz/topaz.env                                 # ahora TF_VAR_subscription_id y tenant_id tienen valor

# ─── 4. El providers.tf del curso ────────────────────────────────────────────────
mkdir -p ~/tf-st && cd ~/tf-st && git init -q
# guarda aquí el providers.tf de 3.5
echo "1.11.4" > .terraform-version
terraform init                                            # descarga azurerm ~> 4.20 y escribe .terraform.lock.hcl
git add . && git commit -qm "providers.tf del curso"

# ─── 5. La verificación de verdad: un recurso creado y borrado ───────────────────
cat > verificacion.tf <<'EOF'
resource "azurerm_resource_group" "verificacion" { name = "rg-verificacion", location = "eastus" }
EOF
az account show --query environmentName -o tsv            # Topaz  ← siempre, antes de aplicar
terraform plan                                            # Plan: 1 to add
terraform apply -auto-approve
az group show -n rg-verificacion --query name -o tsv      # az y Terraform ven el mismo recurso en el mismo emulador
terraform destroy -auto-approve && rm verificacion.tf
#   Si esto funciona, funciona todo lo que el curso necesita: autenticación, provider, ARM emulado, estado local.

# ─── 6. El interruptor: volver a Azure real (solo si tienes suscripción) ─────────
# Abre OTRA terminal sin hacer source de topaz.env: AZURE_CONFIG_DIR apunta a ~/.azure, la nube es AzureCloud, TF_VAR_metadata_host está vacío.
az cloud set -n AzureCloud && az login && az account set --subscription "<tu suscripción>"
az account show --query environmentName -o tsv            # AzureCloud
export TF_VAR_subscription_id=$(az account show --query id -o tsv) TF_VAR_tenant_id=$(az account show --query tenantId -o tsv)
#   Regla del curso: una terminal por nube. El prompt "(topaz)" dice en cuál estás. Y antes de cada apply, az account show.
```

## 7. Errores comunes

| Mensaje o síntoma | Causa y solución |
|---|---|
| `curl … \| sudo bash` para instalar la CLI (el original) | Ejecuta como root un fichero que no has leído y que puede cambiar mañana. Repositorio apt con clave, o al menos descargar, leer y ejecutar. En un curso de IaC, la instalación también es código revisable |
| `Error: Unsupported Terraform Core version` | `required_version` hace su trabajo: el binario no es 1.11.x. `tenv tf use 1.11.4`, o entra en el directorio con `.terraform-version` |
| `Error: "subscription_id" is required` al hacer plan | azurerm 4.x lo exige. `TF_VAR_subscription_id` está vacío: haz `az login` primero y vuelve a hacer `source topaz.env` |
| `x509: certificate signed by unknown authority` (Terraform) o `SSLError … CERTIFICATE_VERIFY_FAILED` (az) | Cada herramienta tiene su cadena de confianza: `SSL_CERT_FILE` para Go, `REQUESTS_CA_BUNDLE` para Python. Las dos van en `topaz.env`; o añade el certificado al sistema |
| El apply de verificación crea el grupo en Azure real | Terminal sin `source topaz.env`, o `TF_VAR_metadata_host` vacío. Por eso el paso 5 empieza con `az account show`. Borra el grupo (`az group delete`) y revisa el prompt |
| `connection refused` en `localhost:8899` | El contenedor no está o el puerto es otro: `docker ps`, `docker logs topaz`. En Docker Desktop con WSL2, comprueba que la integración con tu distro está activada |
| `az cloud register` falla por sufijos o endpoints | Cada versión de Topaz expone endpoints distintos. Lee `/metadata/endpoints` con `curl` y usa esos valores; si el README trae un script de registro, es la fuente de verdad |
| Los recursos desaparecen al reiniciar el contenedor | Sin volumen, el emulador arranca vacío y el estado de Terraform apunta a recursos que ya no existen. `-v topaz-datos:/data` (ruta según README); si ya pasó, `terraform state rm` o borrar el estado local del laboratorio |
| Un tipo de recurso devuelve *not supported* en Topaz | Esperado: el emulador cubre una lista de proveedores. Cada página marca qué va a Azure real. Consulta la lista de tu versión |
| `az login` en Topaz abre el navegador o pide credenciales reales | La nube activa es AzureCloud: `AZURE_CONFIG_DIR` no está exportado. `source topaz.env` y `az cloud set -n Topaz` |
| "Instalo Azure PowerShell también, por si acaso" (el original) | Dos CLIs con sesiones y nubes propias duplican los sitios donde equivocarse de destino. El curso usa solo `az` |

## 8. Autoevaluación

1. **¿Por qué la verificación es un apply y no `--version`?**  
   Porque una versión impresa no prueba autenticación, provider, certificado ni emulador. Crear y borrar un recurso prueba los cuatro.

2. **¿En qué dos sitios se fija la versión de Terraform y para quién es cada uno?**  
   `.terraform-version` para las personas (el gestor cambia de binario); `required_version` para el pipeline (el init falla si no cumple).

3. **¿Qué hace `metadata_host`?**  
   Indica al provider de dónde descargar los endpoints de la nube. Vacío: Azure público. Apuntando a Topaz: el emulador. Es el interruptor.

4. **¿Por qué azurerm 4.x exige `subscription_id`?**  
   Para que el destino sea explícito y no dependa del contexto de `az`: una protección contra aplicar en la suscripción equivocada.

5. **¿Para qué sirve `AZURE_CONFIG_DIR` en el curso?**  
   Separa la sesión y la nube de Topaz de las de Azure real; dos perfiles que no se ven entre sí. Una terminal por nube.

6. **¿Por qué hay dos variables de certificado en `topaz.env`?**  
   Terraform (Go) lee `SSL_CERT_FILE`; `az` (Python) lee `REQUESTS_CA_BUNDLE`. Cadenas de confianza distintas.

7. **¿Qué credenciales hay en `providers.tf`?**  
   Ninguna. `use_cli = true` reutiliza la sesión de `az`; en el pipeline será OIDC. Un secreto en `provider` acaba en Git.

8. **¿Qué pasa si el contenedor arranca sin volumen?**  
   El emulador olvida los recursos y el estado de Terraform queda apuntando a nada. Volumen siempre; si pasa, limpiar el estado.

9. **¿Qué comprobación va antes de cada apply, y qué debe devolver?**  
   `az account show --query environmentName`: `Topaz` en los laboratorios, `AzureCloud` solo en los bloques marcados.

10. **¿Por qué el curso no instala Azure PowerShell?**  
    Es una segunda CLI con su propia sesión y nube: duplica los sitios donde equivocarse de destino sin aportar nada que `az` no haga.

## 9. Referencias

- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md): README con imagen, puerto, certificado y proveedores emulados por versión
- [Instalar Azure CLI en Linux (apt)](https://learn.microsoft.com/es-es/cli/azure/install-azure-cli-linux?pivots=apt) y [nubes en Azure CLI](https://learn.microsoft.com/es-es/cli/azure/manage-clouds-azure-cli) (`az cloud register`)
- [Configuración de Azure CLI](https://learn.microsoft.com/es-es/cli/azure/azure-cli-configuration) (`AZURE_CONFIG_DIR`, `REQUESTS_CA_BUNDLE`)
- [Instalar Terraform](https://developer.hashicorp.com/terraform/install) (repositorio apt, Homebrew, binarios con sumas) y [tenv](https://github.com/tofuutils/tenv)
- [`required_version`](https://developer.hashicorp.com/terraform/language/terraform#terraform-required_version) y [fichero de bloqueo de dependencias](https://developer.hashicorp.com/terraform/language/files/dependency-lock)
- [Argumentos del provider azurerm](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs#argument-reference) (`metadata_host`, `use_cli`, `resource_provider_registrations`, `storage_use_azuread`) y [guía de migración a 4.0](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/4.0-upgrade-guide) (`subscription_id` obligatorio)
- [Instalar Docker Engine en Ubuntu](https://docs.docker.com/engine/install/ubuntu/) y [Docker Desktop con WSL2](https://docs.docker.com/desktop/features/wsl/)
- [Instalar WSL2](https://learn.microsoft.com/es-es/windows/wsl/install) (Microsoft Learn)
- [Extensión HashiCorp Terraform para VS Code](https://marketplace.visualstudio.com/items?itemName=HashiCorp.terraform)
- [Manual de jq](https://jqlang.github.io/jq/manual/)