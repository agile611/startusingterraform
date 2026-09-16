# 🚀 Entorno Práctico: Terraform + Azure Emulator + Topaz en Docker

## Contenido

1. [Preparación del Host](#host)
2. [Cómo Iniciar el Entorno](#iniciar)
3. [Descripción del Entorno](#descripcion)
4. [Ejemplos Prácticos](#ejemplos)
5. [Operaciones sobre el Contenedor](#operaciones)
6. [Desplegar con Terraform](#desplegar)
7. [Notas Importantes](#notas)

<a id="host"></a>

## 🖥️ Preparación del Host (Ubuntu 24.04 LTS)

El entorno se ejecuta sobre **Ubuntu 24.04.5 LTS (Noble Numbat)**. Antes de arrancar el contenedor es necesario instalar Docker desde el repositorio oficial, disponer de los repositorios de Azure CLI y HashiCorp, y configurar la resolución local del nombre `topaz.local.dev`.

### 1. Instalar Docker Engine

Primero, instala los prerrequisitos y añade la clave GPG oficial de Docker:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
```

A continuación, registra el repositorio de Docker en APT:

```bash
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
```

Instala Docker Engine, la CLI, containerd y los plugins de Buildx y Compose:

```bash
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

Comprueba que el servicio está activo y funciona correctamente:

```bash
sudo systemctl enable --now docker
sudo docker --version
sudo docker run --rm hello-world
```

> **Nota:** Para ejecutar Docker sin `sudo`, añade tu usuario al grupo `docker` con `sudo usermod -aG docker $USER` y vuelve a iniciar sesión. Si tenías instalados paquetes no oficiales (`docker.io`, `docker-compose`, `podman-docker`, `containerd`, `runc`), elimínalos antes con `sudo apt-get remove` para evitar conflictos.

### 2. Repositorios APT Configurados

Tras la instalación, el host `terraform00` dispone de los siguientes orígenes de paquetes en `/etc/apt/sources.list.d/azure-cli.sources`:

**Azure CLI** — `/etc/apt/sources.list.d/azure-cli.sources` (formato DEB822):

```text
Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: noble
Components: main
Architectures: amd64
Signed-by: /etc/apt/keyrings/microsoft.gpg
```

**Docker** — `/etc/apt/sources.list.d/docker.list`:

```text
deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu noble stable
```

**HashiCorp (Terraform)** — `/etc/apt/sources.list.d/hashicorp.list`:

```text
deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com noble main
```

**Ubuntu** — `/etc/apt/sources.list.d/ubuntu.sources` (formato DEB822, réplica española + seguridad):

```text
Types: deb
URIs: http://es.archive.ubuntu.com/ubuntu/
Suites: noble noble-updates noble-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://security.ubuntu.com/ubuntu/
Suites: noble-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
```

> **Nota:** Con estos repositorios registrados, Azure CLI y Terraform se instalan directamente con `sudo apt-get install azure-cli terraform`. Ubuntu 24.04 combina dos formatos: el clásico de una línea (`.list`) y el nuevo DEB822 (`.sources`); ambos son válidos y APT los procesa indistintamente.

### 3. Solución de Problemas: Error `NO_PUBKEY`

Si al ejecutar `apt-get update` aparecen errores como estos, APT está encontrando los repositorios pero **no dispone de las claves públicas** necesarias para verificar sus firmas:

```text
Err:6 https://apt.releases.hashicorp.com noble InRelease
  Las firmas siguientes no se pudieron verificar porque su clave pública no está disponible: NO_PUBKEY AA16FCBCA621E701
Err:7 https://packages.microsoft.com/repos/azure-cli noble InRelease
  Las firmas siguientes no se pudieron verificar porque su clave pública no está disponible: NO_PUBKEY EB3E94ADBE1229CF
E: El repositorio «https://apt.releases.hashicorp.com noble InRelease» no está firmado.
E: El repositorio «https://packages.microsoft.com/repos/azure-cli noble InRelease» no está firmado.
```

**Causa:** los archivos `hashicorp.list` y `azure-cli.sources` referencian mediante `signed-by` dos keyrings (`/usr/share/keyrings/hashicorp-archive-keyring.gpg` y `/etc/apt/keyrings/microsoft.gpg`) que no existen en el host o están corruptos. Es habitual cuando se copian los archivos de `sources.list.d/` de una máquina a otra sin copiar también las claves. Puedes confirmarlo así:

```bash
ls -l /usr/share/keyrings/hashicorp-archive-keyring.gpg /etc/apt/keyrings/microsoft.gpg
```

**Solución:** descarga cada clave y guárdala en la ruta exacta que espera su archivo de repositorio.

Clave de **HashiCorp** (ID `AA16FCBCA621E701`):

```bash
sudo apt-get install -y gnupg curl
curl -fsSL https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor --yes -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
sudo chmod a+r /usr/share/keyrings/hashicorp-archive-keyring.gpg
```

Clave de **Microsoft** (ID `EB3E94ADBE1229CF`):

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
  sudo gpg --dearmor --yes -o /etc/apt/keyrings/microsoft.gpg
sudo chmod a+r /etc/apt/keyrings/microsoft.gpg
```

Verifica que las claves descargadas contienen los IDs que APT reclamaba y vuelve a actualizar los índices:

```bash
gpg --show-keys /usr/share/keyrings/hashicorp-archive-keyring.gpg | grep -i AA16FCBCA621E701
gpg --show-keys /etc/apt/keyrings/microsoft.gpg | grep -i EB3E94ADBE1229CF

sudo apt-get update
```

Si todo es correcto, las líneas 6 y 7 pasarán de `Err` a `Des`/`Obj` y desaparecerán los avisos `W: Error de GPG`. Ya puedes instalar las herramientas:

```bash
sudo apt-get install -y terraform azure-cli jq
terraform version
az version
```

> **Nota:** `gpg --dearmor` convierte la clave de formato ASCII (`.asc`) a binario, que es el que espera `signed-by` cuando el archivo termina en `.gpg`. La opción `--yes` sobrescribe un keyring previo si estaba dañado. Evita el antiguo `apt-key add`: está obsoleto en Ubuntu 24.04 y añade las claves de forma global, lo que permitiría a cualquier repositorio firmar paquetes con ellas.

### 4. Resolución de Nombres: `/etc/hosts`

El emulador se publica bajo el nombre `topaz.local.dev`, que es el nombre para el que está emitido su certificado TLS. Ese nombre **debe resolver a la propia máquina**. En `terraform00` el archivo `/etc/hosts` queda así (la última línea es la que importa):

```text
127.0.0.1 localhost
127.0.1.1 curso

# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters

127.0.0.1 topaz.local.dev
```

Para añadir la entrada en cualquier host que aún no la tenga (el `grep` evita duplicarla) y comprobar la resolución:

```bash
grep -q 'topaz.local.dev' /etc/hosts || echo '127.0.0.1 topaz.local.dev' | sudo tee -a /etc/hosts

getent hosts topaz.local.dev
# Salida esperada: 127.0.0.1       topaz.local.dev
```

> **Nota:** No sustituyas `topaz.local.dev` por `localhost` en las URLs: el certificado no incluye ese nombre y la validación TLS fallaría. Si `getent` no devuelve nada o devuelve una IP distinta de `127.0.0.1`, la entrada falta o está mal escrita.

<a id="iniciar"></a>

## 📌 Cómo Iniciar el Entorno

Para arrancar el entorno en Docker, ejecuta el siguiente comando en tu terminal:

```bash
docker run -d --name azure-environment -p 8899:8899 thecloudtheory/topaz-host
```

> **Nota:** Este comando descargará la imagen (si no la tienes) y ejecutará el contenedor en segundo plano (`-d`). Todos los servicios estarán disponibles en el puerto `8899`.

### Credenciales del Emulador

El emulador incluye una identidad de administrador predefinida. Se utiliza al iniciar sesión desde la página de autenticación por código de dispositivo (`https://topaz.local.dev:8899/devicelogin`):

| Campo | Valor |
|---|---|
| Usuario | `topazadmin@topaz.local.dev` |
| Contraseña | `admin` |

> **Nota:** Estas credenciales son exclusivas del emulador local y no tienen ninguna relación con cuentas reales de Azure o Microsoft Entra ID.

<a id="descripcion"></a>

## 🔧 Descripción del Entorno

### 1. Azure Emulator (v1.10.222-preview)

Simula servicios clave de Azure en local:

| Servicio | Endpoint | Descripción |
|---|---|---|
| Azure Storage | Https: 8899 | Blobs, tablas y colas. |
| Resource Manager | Https: 8899 | Grupos de recursos y suscripciones. |
| Key Vault | Https: 443, 8898, 8899 | Secretos y claves seguras. |
| Virtual Machines | Https: 8899 | Máquinas virtuales simuladas. |
| App Service | Https: 8899 (Web), 8896 (Kudu) | Entorno para aplicaciones web. |

### 2. Topaz Services

Herramientas adicionales para observabilidad y gestión:

- **FinOps:** Monitoreo de costos y optimización (puerto 8899).
- **Chaos Engineering:** Simulación de fallos (puerto 8899).
- **Forward Proxy:** Proxy inverso para servicios internos (puerto 8900).

### 3. Servicios de Background

Tareas automáticas para mantener el entorno:

- Purga de Key Vault: cada 1 hora.
- Sincronización de Storage: cada 30 segundos.
- Expiración de mensajes en Service Bus: cada 30 segundos.

### 4. Acceder a los Servicios

Todos los endpoints están disponibles en `https://topaz.local.dev:8899` (usa el ID de suscripción genérico).

Para el **Forward Proxy de Topaz**, usa el puerto `8900`.

## 🔄 Operaciones sobre el Contenedor

Comandos para inspeccionar, respaldar, reiniciar y verificar el contenedor `azure-environment`, exportar su certificado y conectar la CLI de Azure con el emulador. **El orden de los pasos importa:** cada uno depende del anterior.

### 1. Inspeccionar el Contenedor

Muestra la imagen base, el directorio de trabajo y los volúmenes montados:

```bash
docker inspect azure-environment \
  --format 'Imagen={{.Config.Image}} Directorio={{.Config.WorkingDir}} Mounts={{json .Mounts}}'
```

### 2. Respaldar y Recrear el Contenedor

Este bloque detiene el contenedor, guarda su estado actual como una nueva imagen etiquetada con la fecha, renombra el contenedor original como respaldo y arranca uno nuevo a partir de la imagen guardada:

```bash
(
  set -e
  MARCA="$(date +%Y%m%d-%H%M%S)"
  RESPALDO="azure-environment-backup-$MARCA"
  IMAGEN="topaz-local-backup:$MARCA"

  docker stop azure-environment
  docker commit azure-environment "$IMAGEN"
  docker rename azure-environment "$RESPALDO"

  printf '\nContenedor original: %s\nImagen de respaldo: %s\n\n' "$RESPALDO" "$IMAGEN"

  docker run -d \
    --name azure-environment \
    -p 8899:8899 \
    "$IMAGEN" \
    --log-level Information \
    --default-subscription 00000000-0000-0000-0000-000000000001
)
```

> **Nota:** El bloque se ejecuta dentro de un subshell `( ... )` con `set -e`, de modo que si cualquier paso falla, el proceso se detiene y no se pierde el contenedor original. Los contenedores de respaldo quedan detenidos y pueden eliminarse con `docker rm <nombre>` cuando ya no se necesiten.

### 3. Revisar los Logs

Comprueba que el nuevo contenedor arrancó correctamente. El emulador tarda unos segundos en estar listo; espera a ver las líneas `Now listening on`:

```bash
docker logs --tail 60 azure-environment
```

### 4. Exportar el Certificado del Emulador

El emulador sirve todo por HTTPS con un certificado autofirmado que se genera al crear el contenedor. Para que `curl`, `az` y Terraform confíen en él, hay que exportarlo al host. La forma más fiable es capturarlo directamente de la conexión TLS, lo que garantiza que corresponde al contenedor *actual*:

```bash
mkdir -p "$PWD/topaz-certs"

openssl s_client -connect 127.0.0.1:8899 -servername topaz.local.dev -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform PEM > "$PWD/topaz-certs/topaz.crt"

openssl x509 -in "$PWD/topaz-certs/topaz.crt" -noout -subject -dates
```

La última línea debe mostrar el `subject` con `topaz.local.dev` y unas fechas de validez que incluyan hoy. A continuación, instala el certificado en el almacén del sistema para que lo reconozcan también las herramientas que no leen `--cacert`:

```bash
sudo cp "$PWD/topaz-certs/topaz.crt" /usr/local/share/ca-certificates/topaz.crt
sudo update-ca-certificates
# Debe indicar "1 added"
```

> **Nota:** Cada vez que se recree el contenedor (paso 2 o un `docker run` nuevo) el certificado cambia. Repite este paso después de cualquier recreación; de lo contrario aparecerán errores `SSL certificate problem` en `curl` y `az`.

### 5. Verificar el Endpoint de Metadatos

Consulta el endpoint de descubrimiento de Azure Resource Manager usando el certificado exportado:

```bash
curl --noproxy '*' \
  --cacert "$PWD/topaz-certs/topaz.crt" \
  --connect-timeout 5 --max-time 15 \
  -i \
  'https://topaz.local.dev:8899/metadata/endpoints?api-version=2022-09-01'
```

Una respuesta `HTTP/1.1 200 OK` seguida de un JSON con los endpoints confirma que el emulador está operativo y el certificado es válido.

### 6. Despliegue total de los certificados

El bloque es idempotente: puedes ejecutarlo entero aunque parte ya esté hecha.

```bash
# --- A. Exportar e instalar el certificado del contenedor ACTUAL ---
mkdir -p ~/topaz-certs
openssl s_client -connect 127.0.0.1:8899 -servername topaz.local.dev -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform PEM > ~/topaz-certs/topaz.crt
openssl x509 -in ~/topaz-certs/topaz.crt -noout -subject -dates      # debe mostrar topaz.local.dev

cp ~/topaz-certs/topaz.crt /usr/local/share/ca-certificates/topaz.crt
update-ca-certificates            # "1 added" (o "0 added" si ya estaba: también vale)

# --- B. Variables para Python (az) y Go (terraform): shell actual + .bashrc de root ---
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

grep -q REQUESTS_CA_BUNDLE /root/.bashrc || cat >> /root/.bashrc <<'EOF'
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
EOF

# --- C. Comprobar que la cadena valida ANTES de volver a la CLI ---
openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt ~/topaz-certs/topaz.crt
# Esperado: /root/topaz-certs/topaz.crt: OK
```

Repite ahora el registro de la nube. Recarga `META` primero: la variable se pierde si has abierto otra terminal.

```bash
META="$(curl -s --noproxy '*' 'https://topaz.local.dev:8899/metadata/endpoints?api-version=2022-09-01')"
echo "$META" | jq -r '.authentication.loginEndpoint'   # URL bajo topaz.local.dev, nunca vacío

az cloud register --name Topaz \
  --endpoint-resource-manager "https://topaz.local.dev:8899" \
  --endpoint-active-directory "$(echo "$META" | jq -r '.authentication.loginEndpoint')" \
  --endpoint-active-directory-resource-id "$(echo "$META" | jq -r '.authentication.audiences[0]')" \
  --endpoint-active-directory-graph-resource-id "$(echo "$META" | jq -r '.authentication.audiences[0]')" \
  --suffix-storage-endpoint "$(echo "$META" | jq -r '.suffixes.storage')" \
  --suffix-keyvault-dns "$(echo "$META" | jq -r '.suffixes.keyVaultDns')"

az cloud set --name Topaz
az config set core.instance_discovery=false
```

#### Si aún existe algun error en este punto

| Síntoma | Significado | Acción |
|---|---|---|
| `curl` da 200 pero `az` sigue fallando | La variable no llega al proceso de `az` | `env \| grep CA_BUNDLE`. No uses `sudo az ...` (limpia el entorno): trabaja como root o usa `sudo -E` |
| `openssl verify`: `unable to get local issuer certificate` | El certificado instalado es de un contenedor anterior | Repetir el bloque A entero |
| `update-ca-certificates` no añade nada | El archivo no termina en `.crt` o no está en `/usr/local/share/ca-certificates/` | Revisar ruta y nombre exactos |
| Necesitas avanzar sin más demora (solo laboratorio) | Desactivar la verificación TLS en la CLI | `export AZURE_CLI_DISABLE_CONNECTION_VERIFICATION=1`. **Solo** contra el emulador; Terraform no lo respeta, así que el bloque A sigue siendo necesario |

> **💡 La lección de fondo.** Cada herramienta trae su propia idea de "certificados de confianza": `curl` mira `/etc/ssl/certs`, Python mira `REQUESTS_CA_BUNDLE`, Go mira `SSL_CERT_FILE`. Instalar el certificado en el sistema es *necesario pero no suficiente*: hay que decirle a cada cliente dónde está. Este mismo principio explica el error `x509: certificate signed by unknown authority` que verás en Terraform si olvidas `SSL_CERT_FILE`.

### 7. Iniciar Sesión y Seleccionar la Suscripción

Con la nube `Topaz` activa, limpia sesiones previas, inicia sesión con código de dispositivo, selecciona la suscripción del emulador y verifica el contexto:

```bash
az account clear
az login --use-device-code

az account set --subscription 00000000-0000-0000-0000-000000000001

az account show \
  --query '{nombre:name,id:id,tenant:tenantId,cloud:environmentName}' \
  --output json
```

El mensaje de `az login` debe indicar la página del **emulador**, no la de Microsoft:

```text
To sign in, use a web browser to open the page https://topaz.local.dev:8899/device and enter the code XXXXXXXXX to authenticate.
```

Abre esa URL, introduce el código y autentícate con `topazadmin@topaz.local.dev` / `admin`. La salida correcta de `az account show` es similar a esta (anota el `tenant`: lo necesitarás en Terraform):

```json
{
  "cloud": "Topaz",
  "id": "00000000-0000-0000-0000-000000000001",
  "nombre": "Topaz - Default",
  "tenant": "50717675-3E5E-4A1E-8CB5-C62D8BE8CA48"
}
```

# 🛠️ Solución de problemas: `az login` redirige a `login.microsoft.com`

```text
To sign in, use a web browser to open the page https://login.microsoft.com/device and enter the code LV6E3G5BB to authenticate.
```

La CLI sigue apuntando a la nube pública. Cancela con `Ctrl+C` y comprueba:

```bash
az cloud list --query '[].{nube:name, activa:isActive}' -o table
# Debe aparecer Topaz con isActive = True
```

- **Topaz no aparece:** el registro falló (normalmente por `Unable to get endpoints`). Ejecuta 6a y repite 6b.
- **Topaz aparece pero `isActive` es `False`:** ejecuta `az cloud set --name Topaz`.
- **Topaz activa pero con endpoints incorrectos:** revisa `az cloud show --name Topaz -o json`; para corregirlos, `az cloud set --name AzureCloud && az cloud unregister --name Topaz` y repite 6b.
- **Traceback `invalid_instance ... is not known`:** ejecuta 6c y repite `az login`.

> **Nota:** Si `az login` ya muestra la URL del emulador pero falla con `CERTIFICATE_VERIFY_FAILED`, la nube está bien registrada y el problema es la confianza TLS: comprueba `echo $REQUESTS_CA_BUNDLE` y que el certificado del paso 4 corresponde al contenedor en marcha. Si el login completa sin suscripciones, usa `--allow-no-subscriptions` y fija la suscripción con `az account set`.

# 🛠️ Caso resuelto: la nube `Topaz` no está registrada o activa en este host

```text
export ARM_METADATA_HOSTNAME=topaz.local.dev:8899
export ARM_TENANT_ID=50717675-3E5E-4A1E-8CB5-C62D8BE8CA48
export ARM_SUBSCRIPTION_ID=00000000-0000-0000-0000-000000000001
az login --use-device-code
To sign in, use a web browser to open the page https://login.microsoft.com/device and enter the code L65MYKUFP to authenticate.
```

**Qué está pasando.** Las variables `ARM_*` las lee **solo Terraform**; Azure CLI las ignora y decide a qué nube hablar únicamente por `az cloud set`. Si `az login` sigue enviando a `login.microsoft.com`, es que en este host la nube `Topaz` **no está registrada** (lo habitual: el `az cloud register` anterior falló con `CERTIFICATE_VERIFY_FAILED` y nunca llegó a crearse) o está registrada pero **no activa**.

Primero, averigua en cuál de los dos casos estás:

```bash
az cloud list --query '[].{nube:name, activa:isActive}' -o table
# Topaz no aparece            → registro pendiente: ejecuta el bloque completo
# Topaz aparece con False     → solo falta activarla: salta al paso 3
```

El bloque siguiente es idempotente: puedes ejecutarlo entero sin miedo aunque parte ya esté hecha.

```bash
# --- 1. Confianza TLS para Python (sin esto, el registro vuelve a fallar) ---
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt ~/topaz-certs/topaz.crt
# Esperado: .../topaz-certs/topaz.crt: OK   (si no, repite el paso 4: exportar e instalar el certificado)

# --- 2. Registrar Topaz (solo si no aparecía en az cloud list) ---
META="$(curl -s --noproxy '*' 'https://topaz.local.dev:8899/metadata/endpoints?api-version=2022-09-01')"
echo "$META" | jq -r '.authentication.loginEndpoint'   # debe ser una URL bajo topaz.local.dev, nunca vacío

az cloud register --name Topaz \
  --endpoint-resource-manager "https://topaz.local.dev:8899" \
  --endpoint-active-directory "$(echo "$META" | jq -r '.authentication.loginEndpoint')" \
  --endpoint-active-directory-resource-id "$(echo "$META" | jq -r '.authentication.audiences[0]')" \
  --endpoint-active-directory-graph-resource-id "$(echo "$META" | jq -r '.authentication.audiences[0]')" \
  --suffix-storage-endpoint "$(echo "$META" | jq -r '.suffixes.storage')" \
  --suffix-keyvault-dns "$(echo "$META" | jq -r '.suffixes.keyVaultDns')"

# --- 3. Activar la nube, desactivar instance discovery y entrar ---
az cloud set --name Topaz
az config set core.instance_discovery=false
az account clear
az login --use-device-code
```

La salida correcta apunta al **emulador**, con la ruta `/devicelogin` y un código con formato `XXXX-XXXX`:

```text
To sign in, use a web browser to open the page https://topaz.local.dev:8899/devicelogin and enter the code EGWR-6P33 to authenticate
```

Abre esa URL, introduce el código y autentícate con `topazadmin@topaz.local.dev` / `admin`. Después, fija la suscripción y confirma el contexto:

```bash
az account set --subscription 00000000-0000-0000-0000-000000000001
az account show --query '{nombre:name,id:id,tenant:tenantId,cloud:environmentName}' -o json
# Esperado: "cloud": "Topaz"
```

> **Si `az cloud register` dice que `Topaz` ya existe** (un intento fallido dejó la entrada a medias), elimínala y repite el paso 2:
>
> ```bash
> az cloud set --name AzureCloud && az cloud unregister --name Topaz
> ```

> **💡 Las variables `ARM_*` no estorban.** Déjalas exportadas: Terraform las leerá más adelante para el provider y el backend. Simplemente no sirven para redirigir a Azure CLI. Cada herramienta tiene su propio "mando": `az cloud set` para la CLI, `metadata_host` / `ARM_METADATA_HOSTNAME` para Terraform.

# Resolución de problemas: Acceso a Topaz Azure Emulator en Firefox

## Descripción del problema
Al intentar acceder a la interfaz de autenticación del emulador Topaz mediante la URL por defecto:
`https://topaz.local.dev:8899/devicelogin`

Firefox bloquea la conexión o no permite cargar la página debido a restricciones de seguridad en los certificados SSL autofirmados y las políticas HSTS aplicadas a los dominios `.dev`.

### Causa raíz
- **Certificados autofirmados**: Firefox utiliza su propio almacén de certificados aislado y no confía automáticamente en la entidad emisora (CA) local generada por Topaz.
- **Restricciones de dominio .dev**: Los dominios con la extensión .dev fuerzan conexiones HTTPS mediante HSTS (HTTP Strict Transport Security), lo que impide a Firefox añadir excepciones manuales de seguridad para esos nombres de dominio.

## Solución
Sustituir el nombre de host `topaz.local.dev` por la dirección IP de bucle invertido (loopback) `127.0.0.1`.

### Cambio de URL:
❌ **URL original (bloqueada)**:  
`https://topaz.local.dev:8899/devicelogin`  
✅ **URL corregida**:  
`https://127.0.0.1:8899/devicelogin`

## Pasos para acceder
1. Abre Firefox e introduce en la barra de direcciones:  
   `https://127.0.0.1:8899/devicelogin`
2. Si Firefox muestra la pantalla "Advertencia: Riesgo potencial de seguridad a continuación":
   - Haz clic en **Avanzado...**
   - Haz clic en **Aceptar el riesgo y continuar**.
3. La página de inicio de sesión del emulador se cargará correctamente.
4. Debes poner el device code que te genera el az login y de usuario `topazadmin@topaz.local.dev`

## ▶️ Desplegar la Infraestructura de prueba con Terraform para probar el entorno

Con el contenedor en ejecución, el endpoint de metadatos respondiendo `200 OK` y la CLI autenticada en la nube `Topaz`, ya puedes trabajar con Terraform. Pero hay un matiz importante: **Terraform no hereda la configuración de `az cloud set`**. El provider `azurerm` y el backend `azurerm` apuntan por defecto a la nube pública (`management.azure.com`), así que hay que indicarles explícitamente dónde está el emulador.

## 🛠️ Ejemplos Prácticos

### 1. Provisionar un Grupo de Recursos

Definición de infraestructura en `main.tf`:

```hcl
terraform {
  required_providers {
    azurerm = { source = "hashicorp/azurerm", version = "~> 4.0" }
  }
}

provider "azurerm" {
  features {}
  metadata_host                   = "topaz.local.dev:8899"
  resource_provider_registrations = "none"
  subscription_id                 = "00000000-0000-0000-0000-000000000001"
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-humo"
  location = "eastus"
}

output "rg_id" {
  value = azurerm_resource_group.rg.id
}
```

> **Nota:** Esto solo *define* la infraestructura. Los comandos de despliegue (`terraform init`, `plan` y `apply`) se ejecutan más adelante, en la sección [**Desplegar la Infraestructura con Terraform**](#desplegar), una vez que el entorno esté montado, verificado y la CLI de Azure autenticada.

### 2. Desplegar

```bash
cd /home/curso/<directorio-del-proyecto>

terraform init
terraform plan
terraform apply
```

#### 🛠️ Solución de problemas: `SubscriptionNotFound` en `terraform init`

```text
Error: retrieving Storage Account (Subscription: "00000000-0000-0000-0000-000000000001"
Resource Group Name: "defaultRG"
Storage Account Name: "localstorage"): unexpected status 404 (404 Not Found) with error:
SubscriptionNotFound: The subscription '00000000-0000-0000-0000-000000000001' could not be found.
```

Aunque `az account show` muestre `"cloud": "Topaz"`, este error indica que **Terraform está hablando con la nube pública de Azure**, donde esa suscripción no existe. La causa casi siempre es que falta `metadata_host` en el backend y/o en el provider (paso 1). Confírmalo viendo a qué host se conecta Terraform:

```bash
TF_LOG=DEBUG terraform init 2>&1 | grep -oE 'https://[a-zA-Z0-9.:-]+' | sort -u
# Incorrecto: https://management.azure.com  → falta metadata_host
# Correcto:   https://topaz.local.dev:8899 (y los endpoints que devuelve)
```

Si Terraform *sí* apunta a `topaz.local.dev:8899` y el error persiste, el emulador realmente no conoce esa suscripción (por ejemplo, si el contenedor se arrancó sin `--default-subscription`). Comprueba qué suscripciones expone y usa ese ID en `main.tf` y en `az account set`:

```bash
az account list --query '[].{nombre:name, id:id}' -o table

az rest --method get \
  --url "https://topaz.local.dev:8899/subscriptions/00000000-0000-0000-0000-000000000001?api-version=2022-12-01"
```

Orden de comprobación recomendado cuando algo falla en Terraform:

| Error de Terraform | Causa probable | Corrección |
|---|---|---|
| `SubscriptionNotFound` | Terraform apunta a Azure real | `metadata_host` en backend y provider (paso 1) |
| `x509: certificate signed by unknown authority` | Go no encuentra `topaz.crt` | Paso 4 del contenedor; `SSL_CERT_FILE` |
| `StorageAccountNotFound` / `ResourceGroupNotFound` | Backend remoto sin storage previo | Crear con `az` (paso 2) o backend local (paso 3) |
| `dial tcp ... :8891: connection refused` | Puerto de Storage no publicado / sin entrada en hosts | `-p 8891:8891` y `/etc/hosts`, o backend local |
| Error al registrar resource providers | El emulador no implementa ese registro | `resource_provider_registrations = "none"` |
| `plan` se queda colgado en `Refreshing state...` | Estado con recursos de otra práctica cuyo plano de datos no es alcanzable (típico: un storage account) | `terraform state rm` de los sobrantes, o borrar `terraform.tfstate*` y empezar de cero |

#### 🛠️ Solución de problemas: `terraform plan` se queda colgado en `Refreshing state...`

Si el plan imprime varias líneas `Refreshing state...` y no avanza, el provider está reintentando una conexión que nunca responde. El caso habitual es un `azurerm_storage_account` heredado de un `apply` anterior: al refrescarlo, el provider consulta el *plano de datos* (`https://<cuenta>.storage.topaz.local.dev:8891`), un nombre que no está en `/etc/hosts` y un puerto que el contenedor no publica. Pulsa `Ctrl+C` e identifica el recurso refrescando de uno en uno:

```bash
terraform state list                 # ¿hay recursos que ya no están en main.tf?
terraform plan -parallelism=1        # el último "Refreshing" impreso es el culpable
```

Si el recurso ya no forma parte de `main.tf`, sácalo del estado y bórralo con la CLI, que sí habla correctamente con el emulador:

```bash
terraform state rm azurerm_storage_account.ejemplo
az storage account delete -g rg-declarativo-topaz -n stdeclarativo01 --yes
terraform plan
```

Para empezar de cero (el estado de una práctica no tiene valor) o para desatascar un plan puntual sin consultar el emulador:

```bash
# Borrón y cuenta nueva
az group delete -n rg-declarativo-topaz --yes --no-wait
rm -f terraform.tfstate terraform.tfstate.backup
terraform init -reconfigure

# Solo comparar código y estado, sin refrescar contra el emulador
terraform plan -refresh=false
```

> **Nota:** Si el `curl` del paso 5 o `az account show` no funcionan, Terraform tampoco lo hará: resuelve primero los pasos 4 a 7 de **Operaciones sobre el Contenedor** antes de tocar la configuración de Terraform.

<a id="caso-x509"></a>

#### 🛠️ Caso resuelto: `terraform apply` falla con `x509: certificate signed by unknown authority`

```text
Error: retrieving metadata from endpoint "https://topaz.local.dev:8899": performing request:
Get "https://topaz.local.dev:8899/metadata/endpoints?api-version=2022-09-01":
tls: failed to verify certificate: x509: certificate signed by unknown authority

  with provider["registry.terraform.io/hashicorp/azurerm"],
  on main.tf line 12, in provider "azurerm":
```

**Qué está pasando.** El `main.tf` es correcto: Terraform ya apunta al emulador gracias a `metadata_host`. Lo que falla es la **confianza TLS en Go**: recibe el certificado autofirmado del contenedor y no lo encuentra en el almacén. Tres causas, por orden de probabilidad:

- **El certificado instalado es de otro contenedor.** Si `azure-environment` se recreó después de `update-ca-certificates`, el `topaz.crt` del sistema ya no coincide con el que sirve el puerto 8899.
- **`az` funciona solo porque tiene `AZURE_CLI_DISABLE_CONNECTION_VERIFICATION=1`.** Esa variable desactiva la comprobación en la CLI, pero Terraform la ignora. Es el caso típico de "la CLI va y Terraform no".
- **`SSL_CERT_FILE` no está en esta shell** (trabajas como `root` y la variable se añadió al `.bashrc` de `curso`).

Compara la huella del certificado que sirve el contenedor *ahora* con la del instalado:

```bash
openssl s_client -connect 127.0.0.1:8899 -servername topaz.local.dev </dev/null 2>/dev/null \
  | openssl x509 -noout -fingerprint -sha256
openssl x509 -in /usr/local/share/ca-certificates/topaz.crt -noout -fingerprint -sha256
# Huellas distintas → certificado obsoleto

echo "SSL_CERT_FILE=$SSL_CERT_FILE  DISABLE_VERIFICATION=$AZURE_CLI_DISABLE_CONNECTION_VERIFICATION"
```

El arreglo es idempotente y cubre las tres causas a la vez:

```bash
# --- A. Reinstalar el certificado del contenedor ACTUAL ---
mkdir -p ~/topaz-certs
openssl s_client -connect 127.0.0.1:8899 -servername topaz.local.dev -showcerts </dev/null 2>/dev/null \
  | openssl x509 -outform PEM > ~/topaz-certs/topaz.crt
cp ~/topaz-certs/topaz.crt /usr/local/share/ca-certificates/topaz.crt
update-ca-certificates --fresh        # --fresh purga el certificado antiguo del bundle

# --- B. Bundle para Go (Terraform) y Python (az): shell actual + .bashrc de root ---
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
unset AZURE_CLI_DISABLE_CONNECTION_VERIFICATION      # enmascara problemas; ya no hace falta
grep -q SSL_CERT_FILE /root/.bashrc || cat >> /root/.bashrc <<'EOF'
export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
export REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt
EOF

# --- C. Verificar y reintentar ---
openssl verify -CAfile /etc/ssl/certs/ca-certificates.crt ~/topaz-certs/topaz.crt   # Esperado: OK
curl -s --noproxy '*' -o /dev/null -w 'HTTP %{http_code}\n' \
  'https://topaz.local.dev:8899/metadata/endpoints?api-version=2022-09-01'          # Esperado: HTTP 200

terraform apply
```

> **Nota:** si el contenedor se recreó, la sesión de `az` también ha caducado. Como el provider usa `use_cli = true`, ejecuta `az account clear && az login --use-device-code` antes del `apply`, o el siguiente error será de autenticación en lugar de TLS.

> **💡 Regla práctica.** Cada vez que hagas `docker run` o recrees `azure-environment`, repite en este orden: certificado (paso 4) → `az login` (paso 7) → `terraform apply`. Saltarse el primero produce exactamente este error; saltarse el segundo, un `401` del emulador.

<a id="notas"></a>

## ⚠️ Notas Importantes

> **Este es un entorno de práctica local.** No está diseñado para producción.
>
> Los comandos y configuraciones son ejemplos simplificados para aprendizaje.
>
> Las credenciales `topazadmin@topaz.local.dev` / `admin`, la contraseña de la VM en claro, la desactivación de la validación TLS y la de *instance discovery* solo deben usarse contra el emulador local, nunca contra Azure real.