# ⚙️ Configuración de Azure CLI: sesiones, suscripciones y valores por defecto, en Topaz y en Azure real

## 1. Para qué sirve `az` cuando Terraform gestiona la infraestructura

| Uso | Ejemplo en el curso | Regla |
|---|---|---|
| **Prestar la sesión** | `use_cli = true` en `providers.tf`: el provider pide el token a `az` | La nube y la suscripción de `az` son las de Terraform. Comprobarlas antes de cada apply |
| **Comprobar desde fuera** | `az storage account show … --query minimumTlsVersion` después de un apply | Lectura siempre permitida; es la segunda opinión sobre el estado |
| **Provocar deriva** | `az network nic delete` en la práctica 1; `az storage account update` en la [página 5](index.md#pagina-5) | Solo en laboratorios y sabiendo que el siguiente plan lo va a corregir |
| **Lo que Terraform no debe gestionar** | Registrar proveedores, ver roles, obtener ids de objetos de Entra ID para pasarlos como variables | Operaciones de plataforma o de lectura, no recursos del grafo |
| **Crear recursos** | El storage del estado remoto, una sola vez ([página 5](index.md#pagina-5)), y después `terraform import` | La excepción del huevo y la gallina. Cualquier otro recurso creado con `az` es deriva o es algo que Terraform no sabe que existe |

## 2. Dónde vive la configuración: el perfil

Todo lo que `az` recuerda está en un directorio, por defecto `~/.azure`. La variable `AZURE_CONFIG_DIR` lo cambia, y eso es lo que hace `topaz.env`: el emulador tiene su propio directorio (`~/.azure-topaz`) y Azure real el suyo. Dos perfiles que no se ven entre sí, así que no hay forma de "estar en Topaz" y aplicar en Azure real por accidente desde la misma terminal.

| Fichero | Contenido | Lo escribe |
|---|---|---|
| `azureProfile.json` | Suscripciones visibles, cuál es la activa, tenant, usuario, nube de cada una | `az login`, `az account set` |
| `msal_token_cache.json` (o `.bin`) | Tokens de acceso y de refresco. **Es la credencial**: en Windows y macOS va cifrado; en Linux es texto plano con permisos 600 | `az login`; lo lee el provider con `use_cli` |
| `config` | Valores por defecto y opciones: `[defaults]`, `[core]`, `[logging]` | `az config set` |
| `clouds.config` | Nubes registradas y cuál está activa: aquí está Topaz | `az cloud register/set` |
| `commands/*.log`, `logs/` | Registro de comandos si se activa; telemetría | `az config set logging.enable_log_file=yes` |

> **⚠️ El directorio del perfil es un secreto.** Quien copie `msal_token_cache.json` es tú hasta que el token de refresco expire. No va a repositorios, no va a imágenes de contenedor, no se comparte "para que funcione". En equipos compartidos, `az logout` o `az account clear` al terminar.

## 3. Autenticación: qué método en qué contexto

El original presenta tres métodos como equivalentes. No lo son: cada uno responde a un contexto, y uno de ellos (service principal con secreto) es el que este curso enseña a *no* usar.

| Contexto | Método | Comando | Notas |
|---|---|---|---|
| Tu portátil, con navegador | Interactivo | `az login` | MFA incluido. Desde CLI 2.61 muestra un selector de suscripción; en Windows usa WAM (la sesión del sistema) |
| WSL sin navegador, SSH a un servidor, Cloud Shell ajeno | Código de dispositivo | `az login --use-device-code` | El navegador va en otro dispositivo. Algunas políticas de acceso condicional lo bloquean |
| Varios directorios | Interactivo con tenant | `az login --tenant <id o dominio>` | Una cuenta invitada en otro tenant solo ve sus suscripciones si se autentica contra ese tenant |
| Pipeline (GitHub Actions, Azure DevOps) | **Federación OIDC** | `az login --service-principal -u <app> --tenant <t> --federated-token "$TOKEN"` | Sin secreto que guardar ni rotar: el pipeline demuestra quién es con un token del propio GitHub. Es el método del curso ([página 12](index.md#pagina-12)) |
| Dentro de una VM, App Service, contenedor en Azure | Identidad administrada | `az login --identity` (`--client-id` si hay varias) | La plataforma da el token; no hay credencial en ningún sitio. Es lo que usa la VM de Moodle para leer Key Vault |
| Automatización fuera de Azure sin OIDC posible | Service principal con certificado | `az login --service-principal -u <app> --tenant <t> -p cert.pem` | El certificado no viaja en la línea de comandos ni en logs como lo haría un secreto |
| *El original* | Service principal con secreto | `-p <PASSWORD>` | El secreto queda en el historial de la shell, en logs del pipeline y en el fichero de donde se copió. Caduca (máximo 2 años) y alguien tiene que rotarlo. Solo si no hay alternativa, y entonces desde un gestor de secretos, nunca como argumento |
| Topaz | Cualquiera | `az login` con la nube Topaz activa | El emulador no valida identidades: acepta lo que le den y expone su suscripción. Sirve para practicar todo menos la autenticación misma |

Con cualquiera de ellos, el provider azurerm con `use_cli = true` reutiliza la sesión: pide a `az` un token para ARM cada vez que lo necesita. Se puede ver el mismo token con `az account get-access-token`; es lo que viaja en cada petición de Terraform.

## 4. Qué variable lee quién

Este es el error más caro del original: "exporta `ARM_CLIENT_ID` y cualquier comando de Azure CLI las usará". No. `az` no lee ninguna variable `ARM_*`; esas son del provider de Terraform. Y el provider no lee `AZURE_DEFAULTS_*`. Dos herramientas, dos familias de variables, y algunas compartidas.

| Variable | La lee | Efecto |
|---|---|---|
| `AZURE_CONFIG_DIR` | `az` (y el provider, para encontrar la sesión) | Qué perfil: sesión, nube, defaults. La base de la separación Topaz / real |
| `AZURE_DEFAULTS_GROUP`, `AZURE_DEFAULTS_LOCATION` | Solo `az` | Rellenan `-g` y `-l` si faltan. Terraform los ignora por completo |
| `AZURE_CORE_OUTPUT`, `AZURE_CORE_ONLY_SHOW_ERRORS`, `AZURE_CORE_NO_COLOR` | Solo `az` | Formato y verbosidad. Patrón general: `AZURE_<SECCIÓN>_<CLAVE>` equivale a `az config set sección.clave` |
| `REQUESTS_CA_BUNDLE` | `az` (Python) | Certificado de Topaz o del proxy corporativo |
| `SSL_CERT_FILE` | Terraform (Go) | Lo mismo, para la otra herramienta. Por eso `topaz.env` exporta ambas |
| `ARM_SUBSCRIPTION_ID`, `ARM_TENANT_ID`, `ARM_CLIENT_ID`, `ARM_USE_OIDC`, `ARM_USE_CLI`, `ARM_ENVIRONMENT`, `ARM_METADATA_HOSTNAME` | Solo el provider azurerm | Equivalen a los argumentos del bloque `provider`. El argumento explícito gana a la variable. `az` no las ve |
| `ARM_CLIENT_SECRET` | Solo el provider | No se usa en el curso. Si aparece en un pipeline, es un secreto que alguien tendrá que rotar |
| `TF_VAR_*` | Terraform (variables de entrada) | Así llegan `subscription_id`, `tenant_id` y `metadata_host` al `providers.tf` del curso |
| `HTTPS_PROXY`, `NO_PROXY` | Ambas | Proxy corporativo. `NO_PROXY=localhost` para que Topaz no pase por él |

## 5. Valores por defecto y precedencia

`az config set defaults.location=eastus` escribe en el fichero `config` del perfil y **persiste** entre terminales (el original dice lo contrario). Cuando un comando necesita un valor, lo busca en este orden, y el primero que encuentra gana:

1. **El parámetro en la línea de comandos** (`-l northeurope`).
2. **La variable de entorno** (`AZURE_DEFAULTS_LOCATION`): vive lo que vive la terminal.
3. **El fichero `config`** (`az config set defaults.location`): vive hasta que se cambie.

| Valor por defecto | En este curso | Por qué |
|---|---|---|
| `core.output=table` | Sí, cómodo | Solo afecta a lo que ves. Los scripts fuerzan `-o tsv` o `-o json` y no dependen de él |
| `core.only_show_errors=yes` | En scripts, como parámetro | Silencia avisos de versiones preliminares. Global oculta cosas que conviene ver mientras se aprende |
| `defaults.location` | Aceptable | Ahorra un `-l` en comprobaciones. Terraform no lo lee: la región va en HCL siempre |
| `defaults.group` | **No** | Terraform no lo lee, así que no ahorra nada en el flujo principal. Y hace que `az group delete --yes` borre un grupo que nadie ha escrito en el comando (bloque 3 del laboratorio). El original lo recomienda como "una de las configuraciones más útiles"; en este curso es la más peligrosa |
| `defaults.subscription` | No existe como tal | La suscripción activa la guarda `az account set` en `azureProfile.json`, y ya persiste. El original lo confunde con un *default* |
| `logging.enable_log_file=yes` | Sí, en el perfil de Topaz | Registra cada comando en `commands/`: útil para reconstruir qué deriva se provocó y cuándo |
| `core.collect_telemetry=no` | A tu criterio | Sin efecto funcional |

La regla del curso: **lo que Terraform necesita va en HCL o en `TF_VAR_*`; lo que `az` necesita para comprobar va como parámetro explícito.** Los valores por defecto son comodidad para la terminal interactiva, nunca una dependencia de un script.

## 6. Azure puro: tenants, suscripciones, permisos y proveedores

Todo lo de esta sección es lo que Topaz no emula: el emulador tiene un tenant, una suscripción, ningún rol y todos los proveedores. En Azure real hay que resolver cuatro preguntas antes del primer `apply`, y `az` es la herramienta para las cuatro.

### ¿En qué tenant estoy?

Un tenant es un directorio de Entra ID; una cuenta puede ser miembro de uno e invitada en varios. `az login` sin más entra en el tenant de origen de la cuenta y solo ve sus suscripciones. Para ver las de otro tenant hay que autenticarse contra él: `az login --tenant <id o dominio>`. Las suscripciones de todos los tenants en los que has entrado quedan en `azureProfile.json`, y `az account list` las muestra con su `tenantId`.

### ¿En qué suscripción?

Desde CLI 2.61, `az login` muestra un selector si hay más de una. `az account set --subscription` cambia la activa y la persiste. Y desde azurerm 4.x, **el provider no hereda la suscripción de `az`**: exige `subscription_id` explícito. Es una protección deliberada: la sesión puede estar en la suscripción equivocada, pero el código dice a cuál aplica. En el curso el valor llega por `TF_VAR_subscription_id` desde `az account show`, así que conviene que coincidan: el laboratorio lo comprueba.

### ¿Qué permisos tengo?

RBAC de Azure: roles asignados a una identidad en un ámbito (grupo de administración, suscripción, grupo de recursos, recurso). Para el curso hace falta **Colaborador** en el grupo de recursos o la suscripción para crear recursos, y además **Administrador de acceso de usuario** (o *Role Based Access Control Administrator*) si Terraform va a crear asignaciones de rol, como la de la identidad administrada de la VM sobre Key Vault ([página 10](index.md#pagina-10)). Colaborador *no* puede asignar roles: es el error de permisos más habitual del curso y el original no lo menciona.

### ¿Qué proveedores están registrados?

Cada familia de recursos (`Microsoft.Storage`, `Microsoft.KeyVault`…) hay que registrarla una vez por suscripción. El provider azurerm lo hacía automáticamente en versiones anteriores; el `providers.tf` del curso lo desactiva (`resource_provider_registrations = "none"`) porque el emulador no lo soporta y porque registrar proveedores es una operación de plataforma, no un recurso del grafo. En Azure real se hace con `az provider register` antes del primer apply; el laboratorio incluye la lista del curso.

## 4.7. Laboratorio en Topaz

Cuatro bloques: el perfil y lo que contiene; la precedencia demostrada con tres grupos; el peligro de `defaults.group`; y ver la misma petición HTTP desde `az` y desde Terraform. Todo contra el emulador.

```bash
source ~/.topaz/topaz.env
az account show --query environmentName -o tsv                      # Topaz. Si dice AzureCloud, para.
mkdir -p ~/tf-cli && cd ~/tf-cli && cp ~/tf-st/providers.tf .

# ─── 1. El perfil: dónde está y qué contiene ─────────────────────────────────────
echo "$AZURE_CONFIG_DIR" && ls -la "$AZURE_CONFIG_DIR"                # ~/.azure-topaz: el perfil del emulador
jq '.subscriptions[] | {name, id, tenantId, isDefault, environmentName}' "$AZURE_CONFIG_DIR/azureProfile.json"
ls -l "$AZURE_CONFIG_DIR"/msal_token_cache.*                        # -rw------- : la credencial. Nunca sale de aquí.
az cloud list --query "[].{nube:name, activa:isActive}" -o table    # Topaz activa; AzureCloud existe pero no
az config get 2>/dev/null || echo "(sin configuración todavía)"
az config set core.output=table logging.enable_log_file=yes         # persiste: está en el fichero, no en la terminal
cat "$AZURE_CONFIG_DIR/config"
#   Abre otra terminal, haz source de topaz.env y ejecuta "az config get core.output": sigue siendo table. El original decía que se perdía.

# ─── 2. Precedencia: parámetro > variable de entorno > fichero ───────────────────
az config set defaults.location=eastus
az group create -n rg-cfg-fichero -o none                            # sin -l: usa eastus del fichero
AZURE_DEFAULTS_LOCATION=westus az group create -n rg-cfg-entorno -o none   # la variable gana al fichero
AZURE_DEFAULTS_LOCATION=westus az group create -n rg-cfg-parametro -l northeurope -o none   # el parámetro gana a todo
az group list --query "[?starts_with(name,'rg-cfg')].{grupo:name, region:location}" -o table
#   rg-cfg-fichero eastus | rg-cfg-entorno westus | rg-cfg-parametro northeurope

# Terraform no ve nada de esto: la región va en HCL
cat > main.tf <<'EOF'
resource "azurerm_resource_group" "cfg" { name = "rg-cfg-terraform", location = "westeurope" }
EOF
terraform init >/dev/null && terraform apply -auto-approve
az group show -n rg-cfg-terraform --query location -o tsv           # westeurope: ni eastus del fichero ni nada de az
sed -i '/location/d' main.tf && terraform validate                  # Error: "location" is required. No hay default que rescate.
git checkout main.tf 2>/dev/null || sed -i 's/}$/, location = "westeurope" }/' main.tf

# ─── 3. Por qué defaults.group no va en este curso ──────────────────────────────
az config set defaults.group=rg-cfg-fichero
az group show --query name -o tsv                                   # rg-cfg-fichero, sin haber escrito -n: el default rellena el nombre
az group delete --yes                                               # ← este comando no nombra NADA y acaba de borrar un grupo
az group list --query "[?starts_with(name,'rg-cfg')].name" -o tsv   # rg-cfg-fichero ya no está
#   Con Terraform, el destroy siempre nombra: terraform destroy muestra la lista de direcciones y pide confirmación.
#   Un default de grupo en la terminal de alguien que también gestiona producción es un incidente esperando fecha.
az config unset defaults.group

# ─── 4. La misma petición, desde az y desde Terraform ────────────────────────────
az account get-access-token --query "{expira: expiresOn, tipo: tokenType}" -o table   # el token que el provider pide a az con use_cli = true
az group show -n rg-cfg-terraform --debug 2>&1 | grep -E "Request URL|Response status" | head -2
#   GET .../subscriptions/<sub>/resourcegroups/rg-cfg-terraform?api-version=...   200
TF_LOG=DEBUG terraform plan -refresh-only 2>&1 | grep -E "GET|PUT" | grep resourcegroups | head -2
#   La misma URL, la misma API: Terraform y az son dos clientes del mismo ARM. El estado es solo la memoria de uno de ellos.
tail -3 "$AZURE_CONFIG_DIR"/commands/*.log                          # el registro de comandos: aquí queda constancia del delete del bloque 3

# ─── 5. Comprobación de coherencia sesión ↔ provider (el hábito) ────────────────
[ "$(az account show --query id -o tsv)" = "$TF_VAR_subscription_id" ] && echo "sesión y provider apuntan a la misma suscripción" || echo "AVISO: no coinciden; vuelve a hacer source topaz.env"

# ─── 6. Limpiar ──────────────────────────────────────────────────────────────────
terraform destroy -auto-approve
az group delete -n rg-cfg-entorno --yes --no-wait && az group delete -n rg-cfg-parametro --yes --no-wait
az config unset defaults.location
cd ~ && rm -rf ~/tf-cli
```

```bash
# ─── Solo Azure real (terminal NUEVA, sin source de topaz.env) ──────────────────
echo "${AZURE_CONFIG_DIR:-~/.azure}"                                # el perfil por defecto: el de Azure real
az cloud set -n AzureCloud

# A. Tenants y suscripciones
az login                                                            # selector de suscripción (CLI ≥ 2.61); --use-device-code si no hay navegador
az account list --query "[].{nombre:name, id:id, tenant:tenantId, estado:state, activa:isDefault}" -o table
az account tenant list --query "[].{tenant:tenantId, dominio:defaultDomain}" -o table   # todos los tenants donde tienes acceso
az login --tenant <otro-tenant> --allow-no-subscriptions           # entrar en un tenant invitado aunque no tenga suscripciones (p. ej. para leer Entra ID)
az account set --subscription "<nombre o id>"
az account show --query "{nube:environmentName, sub:name, id:id, tenant:tenantId, usuario:user.name}" -o table
export TF_VAR_subscription_id=$(az account show --query id -o tsv) TF_VAR_tenant_id=$(az account show --query tenantId -o tsv)

# B. Quién soy y qué puedo hacer (RBAC)
YO=$(az ad signed-in-user show --query id -o tsv)                   # object id: lo que Key Vault y las asignaciones de rol necesitan ([página 10](index.md#pagina-10))
az role assignment list --assignee "$YO" --all --query "[].{rol:roleDefinitionName, ambito:scope}" -o table
#   Necesario para el curso: Contributor en el grupo o la suscripción. Para que Terraform asigne roles: además User Access Administrator
#   o "Role Based Access Control Administrator" en ese ámbito. Contributor solo NO puede asignar roles.
az role definition list --name "Role Based Access Control Administrator" --query "[].description" -o tsv

# C. Proveedores de recursos: una vez por suscripción, antes del primer apply
for p in Microsoft.Storage Microsoft.KeyVault Microsoft.Network Microsoft.Compute Microsoft.DBforMySQL Microsoft.ManagedIdentity Microsoft.Insights; do
  echo -n "$p: "; az provider show -n $p --query registrationState -o tsv
done
az provider register -n Microsoft.DBforMySQL --wait                 # el que suele faltar en suscripciones nuevas
#   Sin esto, el primer apply falla con MissingSubscriptionRegistration porque providers.tf no registra nada (resource_provider_registrations = "none").

# D. El token, y su caducidad
az account get-access-token --query "{expira: expiresOn}" -o table  # ~1 h; az lo renueva con el token de refresco sin preguntar
az account get-access-token --resource https://vault.azure.net --query "expiresOn" -o tsv   # otro recurso, otro token: el provider pide el que toca

# E. Sin secretos: los dos métodos que el curso usa fuera del portátil
# Pipeline (página 12): GitHub entrega un token OIDC y az lo cambia por uno de Azure. Ningún secreto en ningún sitio.
#   az login --service-principal -u "$AZURE_CLIENT_ID" --tenant "$AZURE_TENANT_ID" --federated-token "$ACTIONS_ID_TOKEN"
# Dentro de la VM de Moodle: la plataforma da el token de la identidad administrada.
#   az login --identity && az keyvault secret show --vault-name kv-moodle -n db-password --query value -o tsv

# F. Cerrar sesión en equipos compartidos
az logout                                                           # borra tokens de esta cuenta
az account clear                                                    # borra todas las cuentas del perfil
```

## 8. Errores comunes

| Mensaje o síntoma | Causa y solución |
|---|---|
| Exportar `ARM_CLIENT_ID` y esperar que `az` lo use (el original) | `az` no lee `ARM_*`: son del provider. Para `az` sin interacción: `--federated-token`, `--identity` o certificado (4.3) |
| `AZURE_CORE_LOGGING_ENABLED`, `AZURE_CORE_ENABLE_HTTP1` (el original) | No existen. Depuración con `--debug` (peticiones HTTP) o `--verbose`; registro persistente con `az config set logging.enable_log_file=yes` |
| "La configuración es por sesión; en una terminal nueva hay que rehacerla" (el original) | Al revés: `az config set` escribe en el fichero y persiste. Lo que muere con la terminal son las variables `AZURE_*` y `TF_VAR_*` (por eso `topaz.env` se hace `source` en cada terminal) |
| "Revisa los inicios de sesión con `az account list`" (el original) | Lista suscripciones, no inicios de sesión. Los inicios de sesión se auditan en Entra ID (registros de inicio de sesión), no desde la CLI local |
| `Please run 'az login' to setup account` | Sin sesión en *este* perfil. Si acabas de cambiar de terminal, comprueba `AZURE_CONFIG_DIR`: quizá la sesión está en el otro perfil |
| `AADSTS700082: The refresh token has expired` | Inactividad prolongada o política del tenant. `az login` de nuevo. En pipelines no ocurre: cada ejecución obtiene su token por OIDC |
| `SubscriptionNotFound` tras `az account set` | La suscripción está en otro tenant en el que no has entrado: `az login --tenant`. O se ha creado hace poco: `az account list --refresh` |
| `AuthorizationFailed` al crear un `azurerm_role_assignment` | Colaborador no asigna roles. Hace falta User Access Administrator o Role Based Access Control Administrator en el ámbito (bloque B) |
| `MissingSubscriptionRegistration` en el primer apply real | Proveedor sin registrar y `providers.tf` no registra nada. `az provider register -n <proveedor> --wait` (bloque C) |
| Terraform aplica en una suscripción distinta de la que muestra `az account show` | azurerm 4.x usa `subscription_id` explícito, no la sesión. `TF_VAR_subscription_id` está desactualizado: vuelve a exportarlo (bloque 5 del laboratorio) |
| `az group delete --yes` borra un grupo que no escribiste | `defaults.group` rellenó el nombre. `az config unset defaults.group`, y no volver a ponerlo en un perfil que toque nada real |
| Un script falla al leer la salida de `az` | Depende de `core.output` del perfil de quien lo ejecuta. Los scripts fuerzan siempre `-o tsv` o `-o json` |
| Certificado no válido al ejecutar `az` contra Topaz en una terminal nueva | Falta `source topaz.env`: sin `REQUESTS_CA_BUNDLE` el perfil de Topaz no confía en el emulador. El prompt `(topaz)` es la pista |
| `az login` en WSL no abre el navegador | `az login --use-device-code`, o instalar `wslu` para que WSL abra el navegador de Windows |
| Secreto de service principal en `-p` o en `ARM_CLIENT_SECRET` | Queda en el historial, en los logs del pipeline y caduca. OIDC en pipelines, identidad administrada dentro de Azure, certificado como último recurso |

## 9. Autoevaluación

1. **¿Qué tres papeles tiene `az` en un flujo con Terraform?**  
   Prestar la sesión al provider, comprobar desde fuera lo que Terraform dice haber hecho, y provocar derivas en los laboratorios. Crear recursos es la excepción (el storage del estado).

2. **¿Qué es `AZURE_CONFIG_DIR` y por qué el curso tiene dos?**  
   El directorio del perfil: sesión, nube, configuración. Uno para Topaz y otro para Azure real, para que no puedan mezclarse en la misma terminal.

3. **¿Quién lee `ARM_CLIENT_ID`? ¿Y `AZURE_DEFAULTS_GROUP`?**  
   Solo el provider azurerm; solo `az`. Ninguna de las dos herramientas lee las variables de la otra.

4. **¿Cuál es la precedencia de valores en `az`?**  
   Parámetro, luego variable de entorno, luego fichero `config`. El primero que aparece gana.

5. **¿Persiste `az config set` entre terminales?**  
   Sí: escribe en el fichero del perfil. Lo que no persiste son las variables de entorno.

6. **¿Por qué el curso desaconseja `defaults.group`?**  
   Terraform no lo lee, así que no ahorra nada; y permite que `az group delete --yes` borre sin nombrar el grupo.

7. **¿Hereda el provider azurerm 4.x la suscripción de `az`?**  
   No: exige `subscription_id` explícito. La sesión da el token; el código dice el destino. Conviene comprobar que coinciden.

8. **¿Qué método de autenticación usa el pipeline del curso y por qué?**  
   Federación OIDC: GitHub demuestra su identidad con un token propio y no hay secreto que guardar ni rotar.

9. **¿Puede Colaborador crear un `azurerm_role_assignment`?**  
   No. Hace falta User Access Administrator o Role Based Access Control Administrator en el ámbito.

10. **¿Por qué el primer apply en Azure real puede fallar con `MissingSubscriptionRegistration`?**  
    El `providers.tf` del curso no registra proveedores. Hay que hacerlo una vez por suscripción con `az provider register`.

11. **¿Qué fichero del perfil es la credencial?**  
    `msal_token_cache.json`: tokens de acceso y refresco. No se copia, no se comparte, no va a imágenes ni repositorios.

12. **¿Cómo se ve que `az` y Terraform hablan con la misma API?**  
    `az … --debug` y `TF_LOG=DEBUG terraform plan` muestran la misma URL de ARM. Son dos clientes; el estado es la memoria de uno.

## 10. Referencias

- [Autenticación en Azure CLI](https://learn.microsoft.com/es-es/cli/azure/authenticate-azure-cli): interactiva, código de dispositivo, service principal (certificado y federación), identidad administrada
- [Configuración de Azure CLI](https://learn.microsoft.com/es-es/cli/azure/azure-cli-configuration): `az config`, variables `AZURE_*`, precedencia y `AZURE_CONFIG_DIR`
- [Gestionar suscripciones y tenants con Azure CLI](https://learn.microsoft.com/es-es/cli/azure/manage-azure-subscriptions-azure-cli)
- [Service principals con Azure CLI](https://learn.microsoft.com/es-es/cli/azure/azure-cli-sp-tutorial-1) y [federación de identidades de carga de trabajo (OIDC)](https://learn.microsoft.com/es-es/entra/workload-id/workload-identity-federation)
- [Identidades administradas](https://learn.microsoft.com/es-es/entra/identity/managed-identities-azure-resources/overview)
- [Roles integrados de Azure RBAC](https://learn.microsoft.com/es-es/azure/role-based-access-control/built-in-roles) (Colaborador, User Access Administrator, Role Based Access Control Administrator)
- [Proveedores de recursos y registro](https://learn.microsoft.com/es-es/azure/azure-resource-manager/management/resource-providers-and-types)
- [Provider azurerm: autenticación con Azure CLI](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/azure_cli), [con OIDC](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/service_principal_oidc) y [variables `ARM_*`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs#argument-reference)
- [Depuración de Terraform (`TF_LOG`)](https://developer.hashicorp.com/terraform/internals/debugging)
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)