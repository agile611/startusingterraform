## 🚀 Práctica: Desplegar una VM en el emulador de Azure (Topaz) con Terraform

En esta práctica desplegarás, **desde cero**, una infraestructura declarativa (grupo de recursos, red virtual, subred, interfaz de red y máquina virtual) sobre el emulador local de Azure **Topaz**, usando **Terraform** y el proveedor `azurerm 4.x`. Todo se ejecuta en tu máquina; no se toca ninguna cuenta real de Azure.

> **Requisitos previos** (ya instalados en `terraform01`): Ubuntu 24.04, Docker Engine, Azure CLI, Terraform ≥ 1.5, `jq`, `openssl`, `curl`. Compruébalos:
> ```bash
> docker --version && az version --query '"azure-cli"' -o tsv && terraform version && jq --version
> ```

> 💡 **Convención:** todos los comandos se ejecutan como superusuario (o con `sudo`) en el directorio `/home/curso`. Cada paso depende del anterior: **no saltes ninguno**.

---

## 1️⃣ Arrancar el emulador

Si ya existe un contenedor de una práctica anterior, elimínalo para partir de un estado limpio. Después arranca el emulador indicando la suscripción por defecto:

```bash
docker rm -f azure-environment 2>/dev/null

docker run -d --name azure-environment -p 8899:8899 thecloudtheory/topaz-host \
  --log-level Information \
  --default-subscription 00000000-0000-0000-0000-000000000001

# Espera a ver las líneas "Now listening on"
sleep 10 && docker logs --tail 20 azure-environment
```

El emulador se publica con el nombre `topaz.local.dev`, que debe resolver a tu propia máquina:

```bash
grep -q 'topaz.local.dev' /etc/hosts || echo '127.0.0.1 topaz.local.dev' | sudo tee -a /etc/hosts
getent hosts topaz.local.dev
# Esperado: 127.0.0.1       topaz.local.dev
```

---

## 2️⃣ Confiar en el certificado del emulador

Topaz sirve todo por HTTPS con un certificado autofirmado que se genera al crear el contenedor. Hay que exportarlo e instalarlo en el almacén del sistema para que `curl`, `az` (Python) y `terraform` (Go) lo acepten:

```bash
mkdir -p ~/topaz-certs

openssl s_client -connect 127.0.0.1:8899 -servername topaz.local.dev -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform PEM > ~/topaz-certs/topaz.crt

openssl x509 -in ~/topaz-certs/topaz.crt -noout -subject -dates   # subject con topaz.local.dev y fechas vigentes

sudo cp ~/topaz-certs/topaz.crt /usr/local/share/ca-certificates/topaz.crt
sudo update-ca-certificates                                        # "1 added"

# Variables que usan Azure CLI (Python) y Terraform (Go). Persisten en .bashrc
cat >> ~/.bashrc <<'EOF'
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
EOF
source ~/.bashrc
```

Verifica que el punto de conexión de metadatos responde con el certificado validado. Este punto de conexión es exactamente el que Terraform consultará después a través de `metadata_host`:

```bash
curl --noproxy '*' --connect-timeout 5 -s -o /dev/null -w 'HTTP %{http_code}\n' \
  'https://topaz.local.dev:8899/metadata/endpoints?api-version=2022-09-01'
# Esperado: HTTP 200
```

> ⚠️ **Importante:** cada vez que recrees el contenedor (`docker rm` + `docker run`) el certificado cambia y debes repetir este paso completo.

---

## 3️⃣ Conectar Azure CLI con el emulador

Azure CLI apunta por defecto a la nube pública. Hay que registrar Topaz como nube personalizada, desactivar la comprobación del descubrimiento de instancias de MSAL (que rechaza cualquier servidor de identidad que no sea de Microsoft) y autenticarse:

```bash
META="$(curl -s --noproxy '*' 'https://topaz.local.dev:8899/metadata/endpoints?api-version=2022-09-01')"

az cloud register --name Topaz \
  --endpoint-resource-manager "https://topaz.local.dev:8899" \
  --endpoint-active-directory "$(echo "$META" | jq -r '.authentication.loginEndpoint')" \
  --endpoint-active-directory-resource-id "$(echo "$META" | jq -r '.authentication.audiences[0]')" \
  --endpoint-active-directory-graph-resource-id "$(echo "$META" | jq -r '.authentication.audiences[0]')" \
  --suffix-storage-endpoint "$(echo "$META" | jq -r '.suffixes.storage')" \
  --suffix-keyvault-dns "$(echo "$META" | jq -r '.suffixes.keyVaultDns')"

az cloud set --name Topaz
az config set core.instance_discovery=false

az account clear
az login --use-device-code
# El mensaje DEBE indicar https://topaz.local.dev:8899/device (no login.microsoft.com)
```

Abre la URL que muestra la terminal, introduce el código e inicia sesión con las credenciales del emulador.

A continuación tienes las credenciales para autorizar la CLI:

| **Campo** | **Valor** |
|---|---|
| **Usuario** | `topazadmin@topaz.local.dev` |
| **Contraseña** | `admin` |

*Asegúrate de introducir estas credenciales exactas para vincular correctamente tu sesión local.*

Selecciona la suscripción y **anota el identificador del inquilino (`tenant`)**: lo necesitarás en `main.tf`.

```bash
az account set --subscription 00000000-0000-0000-0000-000000000001
az account show --query '{cloud:environmentName,id:id,tenant:tenantId}' -o json
# {
#   "cloud": "Topaz",
#   "id": "00000000-0000-0000-0000-000000000001",
#   "tenant": "50717675-3E5E-4A1E-8CB5-C62D8BE8CA48"
# }
```

---

## 4️⃣ Crear el proyecto y el archivo `main.tf`

Crea un directorio de trabajo vacío y dentro de él el archivo `main.tf` con el contenido siguiente. Fíjate en el bloque `provider`: **Terraform no hereda la nube activa de Azure CLI**, así que hay que indicarle explícitamente el emulador con `metadata_host` y desactivar el registro de proveedores de recursos, que Topaz no implementa.

```bash
mkdir -p /home/curso/nemo && cd /home/curso/nemo
nano main.tf     # pega el contenido de abajo
```

```hcl
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}

  # Apuntar al emulador Topaz (descubre endpoints en /metadata/endpoints)
  metadata_host = "topaz.local.dev:8899"

  # Sustituye a skip_provider_registration (eliminado en azurerm 4.x)
  resource_provider_registrations = "none"

  use_cli  = true
  use_msi  = false
  use_oidc = false

  subscription_id = "00000000-0000-0000-0000-000000000001"
  tenant_id       = "50717675-3E5E-4A1E-8CB5-C62D8BE8CA48" # valor del inquilino de: az account show
}

# 1. Grupo de recursos
resource "azurerm_resource_group" "ejemplo" {
  name     = "rg-declarativo-topaz"
  location = "eastus"
}

# 2. Red virtual
resource "azurerm_virtual_network" "ejemplo" {
  name                = "vnet-topaz"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.ejemplo.location
  resource_group_name = azurerm_resource_group.ejemplo.name
}

# 3. Subred
resource "azurerm_subnet" "ejemplo" {
  name                 = "subnet-topaz"
  resource_group_name  = azurerm_resource_group.ejemplo.name
  virtual_network_name = azurerm_virtual_network.ejemplo.name
  address_prefixes     = ["10.0.1.0/24"]
}

# 4. Interfaz de red
resource "azurerm_network_interface" "ejemplo" {
  name                = "nic-resiliente"
  location            = azurerm_resource_group.ejemplo.location
  resource_group_name = azurerm_resource_group.ejemplo.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.ejemplo.id
    private_ip_address_allocation = "Dynamic"
  }
}

# 5. Máquina virtual
resource "azurerm_virtual_machine" "ejemplo" {
  name                  = "vm-resiliente"
  location              = azurerm_resource_group.ejemplo.location
  resource_group_name   = azurerm_resource_group.ejemplo.name
  vm_size               = "Standard_B1s"
  network_interface_ids = [azurerm_network_interface.ejemplo.id]

  delete_os_disk_on_termination = true

  storage_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }

  storage_os_disk {
    name              = "disk-resiliente"
    caching           = "ReadWrite"
    create_option     = "FromImage"
    managed_disk_type = "Standard_LRS" # obligatorio (o vhd_uri)
  }

  os_profile {
    computer_name  = "vm-resiliente"
    admin_username = "adminuser"
    admin_password = "P@ssw0rd1234!"
  }

  os_profile_linux_config {
    disable_password_authentication = false
  }
}

output "vm_id" {
  value = azurerm_virtual_machine.ejemplo.id
}
```

Si el `tenant` que devolvió `az account show` es distinto del que aparece en el archivo, sustitúyelo con una sola orden:

```bash
TENANT="$(az account show --query tenantId -o tsv)"
sed -i "s/tenant_id       = \"[^\"]*\"/tenant_id       = \"$TENANT\"/" main.tf
grep tenant_id main.tf
```

> 💡 **¿Por qué no hay bloque `backend`?** El estado se guarda en local (`terraform.tfstate`, en el directorio del proyecto). Un backend remoto `azurerm` exigiría una cuenta de almacenamiento previa y publicar el puerto 8891 del emulador; para esta práctica no aporta nada y es la principal fuente de bloqueos.

---

## 5️⃣ Inicializar, validar y planificar

```bash
cd /home/curso/nemo

terraform fmt          # normaliza el formato; avisa si hay llaves descuadradas
terraform init         # descarga el proveedor azurerm 4.x
terraform validate     # "Success! The configuration is valid."
terraform plan         # "Plan: 5 to add, 0 to change, 0 to destroy."
```

Lee el plan: debe listar exactamente los cinco recursos del archivo (grupo, VNet, subred, NIC y VM) marcados con `+`. Si en lugar de eso aparece un error, consulta la tabla de la sección 8 antes de continuar.

---

## 6️⃣ Desplegar y verificar

```bash
terraform apply        # escribe "yes" cuando lo pida
# Apply complete! Resources: 5 added, 0 changed, 0 destroyed.
# Outputs:
# vm_id = "/subscriptions/00000000-.../virtualMachines/vm-resiliente"
```

Comprueba el resultado desde dos puntos de vista: lo que Terraform cree que existe (estado) y lo que el emulador realmente tiene (Azure CLI). Ambos deben coincidir:

```bash
# Estado de Terraform
terraform state list
terraform output vm_id

# Realidad en el emulador
az group show -n rg-declarativo-topaz -o table
az network vnet list -g rg-declarativo-topaz -o table
az network nic show -g rg-declarativo-topaz -n nic-resiliente --query 'ipConfigurations[0].privateIPAddress' -o tsv
az vm list -g rg-declarativo-topaz -o table

# Idempotencia: un segundo plan no debe proponer cambios
terraform plan
# "No changes. Your infrastructure matches the configuration."
```

---

## 7️⃣ Limpieza

Al terminar, destruye la infraestructura con Terraform (así practicas el ciclo completo) y, si quieres dejar la máquina limpia, elimina el contenedor:

```bash
terraform destroy      # "Destroy complete! Resources: 5 destroyed."
az group list -o table # el grupo ya no debe aparecer

# Opcional: eliminar el emulador y volver a la nube pública en la CLI
docker rm -f azure-environment
az cloud set --name AzureCloud
```

---

## 8️⃣ Solución de problemas

La cadena de dependencias es estricta: certificado → CLI → Terraform. Localiza el mensaje y vuelve al paso indicado.

Aquí tienes un resumen estructurado para diagnosticar y resolver los errores más comunes:

| **Síntoma** | **Causa** | **Corrección** |
|---|---|---|
| `curl: (28) Timeout` | `topaz.local.dev` no resuelve o el contenedor no está en marcha | Paso 1: `getent hosts`, `docker ps` |
| `curl: (60) SSL certificate problem` | Certificado de otro contenedor | Repetir el paso 2 |
| `Unable to get endpoints from the cloud ... CERTIFICATE_VERIFY_FAILED` | `REQUESTS_CA_BUNDLE` no exportada al registrar la nube | `source ~/.bashrc` y repetir `az cloud register` |
| `az login` muestra `login.microsoft.com` | Nube Topaz no registrada o no activa | `az cloud list -o table` → `az cloud set --name Topaz` |
| `invalid_instance: The authority ... is not known` | MSAL rechaza el emulador como *authority* | `az config set core.instance_discovery=false` |
| `Unsupported block type "provider"` / `Unclosed configuration block` | Falta la `}` que cierra `terraform { }` | `terraform fmt` señala la línea |
| `Unsupported argument: skip_provider_registration` | Argumento eliminado en azurerm 4.x | Usar `resource_provider_registrations = "none"` |
| `SubscriptionNotFound` en `init`/`plan` | Terraform habla con Azure público (falta `metadata_host`) | Revisar el bloque `provider` del paso 4 |
| `x509: certificate signed by unknown authority` | Go no encuentra el certificado | `echo $SSL_CERT_FILE`; repetir paso 2 |
| `plan` se queda colgado en `Refreshing state...` | Estado con recursos de otra práctica (p. ej. una cuenta de almacenamiento cuyo plano de datos no es alcanzable) | `terraform state list`; quitar los sobrantes con `terraform state rm`, o borrar `terraform.tfstate*` y el grupo con `az group delete` |
| `apply` falla solo en la VM (HTTP 4xx/5xx del emulador) | Operación no implementada en esta *versión preliminar* de Topaz | `docker logs --tail 40 azure-environment`; desplegar el resto con `terraform apply -target=...` |

*Utiliza esta tabla como tu primera línea de defensa si el despliegue se interrumpe.*

Para ver exactamente qué peticiones envía Terraform y a qué host:

```bash
TF_LOG=DEBUG terraform plan -parallelism=1 2>&1 | grep -oE 'https://[a-zA-Z0-9.:-]+' | sort -u
# Correcto: solo hosts bajo topaz.local.dev. Si aparece management.azure.com, falta metadata_host.
```

---

## 📝 Entrega

1. Captura de `az account show` mostrando `"cloud": "Topaz"`.
2. Captura de `terraform plan` con `5 to add`.
3. Captura de `terraform apply` con `Apply complete!` y el output `vm_id`.
4. Captura de `az vm list -g rg-declarativo-topaz -o table`.
5. Captura del segundo `terraform plan` con `No changes` (idempotencia).
6. Captura de `terraform destroy`.
7. Respuesta breve (3–5 líneas): ¿por qué Terraform necesita `metadata_host` si Azure CLI ya está configurada con `az cloud set`?

> 🚨 **⚠️ Entorno de prácticas.** Las credenciales `topazadmin@topaz.local.dev` / `admin`, la contraseña de la VM en claro y la desactivación del descubrimiento de instancias solo son aceptables contra el emulador local. Nunca las uses contra Azure real.