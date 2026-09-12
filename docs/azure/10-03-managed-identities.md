Aquí tienes la versión estructurada y limpia en Markdown de tu guía sobre identidades gestionadas en Azure. He mantenido la coherencia visual con los módulos anteriores, transformando las cajas de HTML en bloques de notas y asegurando que las tablas y el código queden perfectamente formateados. 👇

---

# 🔑 Identidades gestionadas: acceso sin credenciales

> En la página 11 la VM de Moodle leyó su contraseña de Key Vault sin que nadie le diera una credencial. Lo hizo con una **identidad gestionada**: una cuenta en Entra ID cuyo secreto nunca existe fuera de Azure, que la plataforma rota sola y que la VM usa pidiendo un token a una dirección local. Esta página explica ese mecanismo y lo lleva a todos los puntos de la arquitectura de Moodle donde hoy habría una clave: el VMSS que monta `moodledata`, el Application Gateway que lee el certificado, el servidor MySQL que autentica a su administrador, el propio Terraform cuando se ejecuta dentro de Azure y, mediante federación, el pipeline que se ejecuta fuera. El hilo conductor es la **asignación de roles**: qué rol, sobre qué ámbito, y cómo evitar que la identidad de una VM web pueda borrar la base de datos. En **Topaz** funcionan las identidades de usuario y las asignaciones de rol como recursos; lo que el emulador no hace es emitir tokens ni evaluar permisos, así que la prueba real de "esta identidad puede leer este contenedor y ningún otro" se hace en Azure.

**🎯 Objetivos de aprendizaje**
- Explicar qué es una identidad gestionada, cómo obtiene tokens y qué significan `id`, `principal_id` y `client_id`.
- Elegir entre identidad de sistema y de usuario según el ciclo de vida y el orden de creación.
- Asignar roles de plano de datos con el ámbito mínimo, evitando los errores de propagación y replicación.
- Configurar los consumidores de Moodle (blobfuse, Application Gateway, MySQL, Functions, AKS) para autenticarse con identidad.
- Ejecutar Terraform bajo una identidad gestionada con permisos acotados, incluida la capacidad de asignar roles.
- Federar una identidad gestionada con GitHub Actions o AKS sin ningún secreto de larga duración.

> **🔷 Requisitos previos.** Páginas 1 a 11 completadas y destruidas, `~/tf-st/providers.tf`, Terraform `>= 1.11`, azurerm 4.x, `jq`, `az account show --query environmentName -o tsv` → `Topaz`.

---

## 1. Qué es y cómo consigue un token

Una identidad gestionada es un *service principal* de Entra ID que Azure crea, protege y rota por ti. Lo que la distingue de un service principal normal no es la identidad sino el **canal**: el recurso que la posee (VM, App Service, Function, clúster) pide tokens al *Instance Metadata Service*, una dirección solo accesible desde dentro del recurso (`169.254.169.254`), y Azure responde con un token firmado sin que ninguna clave haya viajado. Ese token dura 24 horas, IMDS lo cachea y las bibliotecas lo renuevan solas. El código de la aplicación nunca ve una contraseña porque nunca la hay.

| **Atributo** | **Qué es** | **Dónde se usa** |
|---|---|---|
| `id` | Ruta ARM del recurso identidad (`/subscriptions/…/userAssignedIdentities/id-moodle-web`) | `identity_ids` del recurso que la posee; `parent_id` de la credencial federada |
| `principal_id` (*object id*) | Identificador del service principal en Entra ID. Claim `oid` del token | `principal_id` de `azurerm_role_assignment`; administrador Entra de MySQL |
| `client_id` (*app id*) | Identificador de la aplicación. Claim `appid` del token | Petición a IMDS cuando hay varias identidades; `ARM_CLIENT_ID`; anotación del ServiceAccount en AKS; `client-id` en `azure/login` |
| `tenant_id` | Inquilino de Entra ID | `ARM_TENANT_ID`; `tenant-id` en el pipeline |

> **⚠️ Ninguno de los cuatro es secreto.** El original los guarda como `secrets.AZURE_CLIENT_ID` en GitHub. Son identificadores públicos: aparecen en cada token, en cada log de auditoría y en el portal. Guardarlos como secretos no protege nada y enmascara en los logs cadenas que necesitas ver para depurar. Lo que hace segura a la identidad es que *solo* quien controla el recurso (o quien la federación reconoce) puede obtener un token con ellos.

---

## 2. De sistema o de usuario: una cuestión de orden

La diferencia no es de seguridad sino de **ciclo de vida**. La identidad de sistema nace y muere con el recurso: eso obliga a crear el recurso antes de poder asignarle roles, y en el primer arranque la VM intenta leer Key Vault antes de que el rol exista. La identidad de usuario es un recurso independiente: se crea primero, se le dan roles, y el VMSS nace ya autorizado. Además una misma identidad sirve a todas las instancias del VMSS (y a la siguiente generación cuando lo recrees), y puede federarse (12.6). Para Moodle, *user-assigned* por defecto; *system-assigned* solo donde el servicio la exige (el Application Gateway con Key Vault admite ambas; Azure Policy y algunos servicios solo la de sistema).

```hcl
# Una identidad por papel, no por recurso: "lo que hace la capa web", "lo que hace el gateway", "lo que hace Terraform"
resource "azurerm_user_assigned_identity" "web" {
  name                = "id-moodle-web-${var.entorno}"
  resource_group_name = azurerm_resource_group.moodle.name
  location            = azurerm_resource_group.moodle.location
  tags                = local.tags
}
resource "azurerm_user_assigned_identity" "agw" {
  name                = "id-moodle-agw-${var.entorno}"
  resource_group_name = azurerm_resource_group.moodle.name
  location            = azurerm_resource_group.moodle.location
  tags                = local.tags
}

resource "azurerm_linux_virtual_machine_scale_set" "web" {      # el original usa azurerm_virtual_machine: retirado en 3.x
  # … (página 15)
  identity {
    type         = "UserAssigned"                                # o "SystemAssigned, UserAssigned" si un servicio exige la de sistema
    identity_ids = [azurerm_user_assigned_identity.web.id]
  }
  depends_on = [azurerm_role_assignment.web_blob, azurerm_role_assignment.web_kv]   # el rol existe antes del primer cloud-init
}

# Si necesitas la de sistema, el principal_id sale del propio recurso: el data del original es innecesario
# principal_id = azurerm_linux_virtual_machine_scale_set.web.identity[0].principal_id

output "web_client_id"    { value = azurerm_user_assigned_identity.web.client_id }      # público: va a cloud-init
output "web_principal_id" { value = azurerm_user_assigned_identity.web.principal_id }   # público: va a role assignments
```

| | **Sistema** | **Usuario** |
|---|---|---|
| Ciclo de vida | El del recurso; al recrearlo, nuevo `principal_id` y roles huérfanos | Propio; sobrevive al recurso |
| Roles antes del primer arranque | Imposible | Sí, con `depends_on` |
| Compartida entre recursos | No | Sí (todas las instancias del VMSS, varios App Services) |
| Federable (12.6) | No | Sí |
| Petición a IMDS | Sin parámetros | `client_id=` obligatorio si hay más de una |
| Úsala para | Servicios que la exigen; recursos únicos y estables | Todo lo demás |

---

## 3. Roles: plano de datos, ámbito mínimo, sin sorpresas

El original da `Contributor` sobre el grupo de recursos a la identidad de la VM "para que pueda gestionar recursos". La VM web de Moodle no gestiona recursos: lee blobs y un secreto. `Contributor` le permitiría borrar MySQL y, curiosamente, *no* le permitiría leer un blob, porque es un rol de **plano de control** (ARM: crear, configurar, borrar) y el acceso a datos lo dan roles de **plano de datos** (*Storage Blob Data Contributor*, *Key Vault Secrets User*). Cada identidad de Moodle necesita dos o tres roles de datos, cada uno sobre el recurso concreto, y ninguno de control.

```hcl
# Capa web: moodledata (blobs) + su contraseña de MySQL (un secreto). Nada más.
resource "azurerm_role_assignment" "web_blob" {
  scope                = azurerm_storage_account.moodledata.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.web.principal_id
  principal_type       = "ServicePrincipal"        # evita el error PrincipalNotFound por la replicación de Entra tras crear la identidad
  description          = "Moodle web: lectura/escritura de moodledata"
  # ABAC: solo el contenedor moodledata, aunque la cuenta tenga otros (backups, exports)
  condition_version = "2.0"
  condition         = <<-EOT
    (
      !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'})
      AND !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write'})
      AND !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete'})
    )
    OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringEquals 'moodledata')
  EOT
}
resource "azurerm_role_assignment" "web_kv" {
  scope                = azurerm_key_vault_secret.mysql.resource_versionless_id   # el secreto, no el vault (página 11)
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.web.principal_id
  principal_type       = "ServicePrincipal"
}

# Gateway: el PFX del certificado, como secreto
resource "azurerm_role_assignment" "agw_kv" {
  scope                = azurerm_key_vault.moodle.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_user_assigned_identity.agw.principal_id
  principal_type       = "ServicePrincipal"
}

# Rol personalizado cuando ninguno integrado encaja: el operador de guardia puede reiniciar y reimaginar el VMSS, y nada más
resource "azurerm_role_definition" "operador_moodle" {
  name        = "Moodle Operador ${var.entorno}"
  scope       = azurerm_resource_group.moodle.id
  description = "Reiniciar, reimaginar y ver el VMSS de Moodle"
  permissions {
    actions = [
      "Microsoft.Compute/virtualMachineScaleSets/read",
      "Microsoft.Compute/virtualMachineScaleSets/restart/action",
      "Microsoft.Compute/virtualMachineScaleSets/reimage/action",
      "Microsoft.Compute/virtualMachineScaleSets/virtualMachines/*/read",
    ]
    not_actions = []
  }
  assignable_scopes = [azurerm_resource_group.moodle.id]
}
```

| **Identidad** | **Rol** | **Ámbito** | **Para** |
|---|---|---|---|
| `id-moodle-web` | Storage Blob Data Contributor | Cuenta `moodledata`, con condición al contenedor | blobfuse monta `/var/moodledata` |
| `id-moodle-web` | Key Vault Secrets User | Secreto `mysql-moodle-password` | `config.php` (página 11) |
| `id-moodle-agw` | Key Vault Secrets User | Vault | PFX del certificado TLS |
| `id-moodle-mysql` | Permisos Graph *User.Read.All*, *GroupMember.Read.All*, *Application.Read.All* | Entra ID | El servidor valida logins de Entra (12.4) |
| `id-moodle-tf` | Contributor + RBAC Administrator (condicionado) + Secrets Officer + Blob Data Contributor | Grupo de recursos; vault; contenedor `tfstate` | Terraform (12.5) |
| Guardia (grupo de Entra) | *Moodle Operador* (personalizado) | Grupo de recursos | Reiniciar y reimaginar, sin borrar |

> **🔷 Dos retardos que parecen errores.** Al crear una identidad, Entra ID tarda unos segundos en replicarla: un `role_assignment` inmediato falla con *PrincipalNotFound*, y `principal_type = "ServicePrincipal"` le dice a ARM que no la busque y confíe. Al crear la asignación, la evaluación tarda hasta cinco minutos en llegar a todos los servicios: la primera petición de la VM devuelve 403 aunque el rol ya exista. Por eso la identidad de usuario nace antes que el VMSS y `time_sleep` es un recurso legítimo, no un parche.

---

## 4. Los consumidores de Moodle, uno a uno

Cada servicio tiene su manera de decir "usa la identidad en vez de la clave". Estas son las cuatro que aparecen en la arquitectura de Moodle, con lo que sustituyen.

```hcl
# 1. moodledata por blobfuse2 con identidad: sustituye a la clave de storage en cloud-init
#    /etc/blobfuse2/moodledata.yaml  (plantilla; Terraform solo rellena valores públicos)
allow-other: true
logging: { type: syslog, level: log_warning }
components: [libfuse, file_cache, attr_cache, azstorage]
file_cache: { path: /var/cache/blobfuse2, timeout-sec: 120, max-size-mb: 4096 }
azstorage:
  type: block
  account-name: ${storage_account}
  container: moodledata
  mode: msi                          # identidad gestionada por IMDS
  appid: ${client_id}                # imprescindible con identidad de usuario
#    /etc/fstab:  /var/moodledata  fuse3  blobfuse2  defaults,_netdev,--config-file=/etc/blobfuse2/moodledata.yaml  0 0
#    La cuenta puede tener shared_access_key_enabled = false: no hay clave que filtrar (página 10)

# 2. Application Gateway: ya visto en la página 11
#    identity { type = "UserAssigned", identity_ids = [azurerm_user_assigned_identity.agw.id] }
#    ssl_certificate { key_vault_secret_id = azurerm_key_vault_certificate.tls.versionless_secret_id }

# 3. MySQL Flexible: administración por Entra ID (el servidor necesita su propia identidad para consultar el directorio)
resource "azurerm_user_assigned_identity" "mysql" {
  name                = "id-moodle-mysql-${var.entorno}"
  resource_group_name = azurerm_resource_group.moodle.name
  location            = azurerm_resource_group.moodle.location
}
resource "azurerm_mysql_flexible_server" "moodle" {
  # … (página 11)
  identity { type = "UserAssigned", identity_ids = [azurerm_user_assigned_identity.mysql.id] }
}
resource "azurerm_mysql_flexible_server_active_directory_administrator" "dba" {
  server_id   = azurerm_mysql_flexible_server.moodle.id
  identity_id = azurerm_user_assigned_identity.mysql.id
  login       = "grp-moodle-dba"                                   # un grupo de Entra, no una persona
  object_id   = var.grupo_dba_object_id
  tenant_id   = data.azurerm_client_config.actual.tenant_id
}
# Los permisos Graph de id-moodle-mysql (User.Read.All, GroupMember.Read.All, Application.Read.All) los concede
# un administrador de Entra una vez; Terraform no puede con azurerm. Con el provider azuread: azuread_app_role_assignment.
# Conexión del DBA:  mysql -h <fqdn> -u grp-moodle-dba --enable-cleartext-plugin -p"$(az account get-access-token --resource-type oss-rdbms --query accessToken -o tsv)"
# Y Moodle? Su usuario de aplicación sigue con contraseña (Key Vault, página 11): el token de Entra dura una hora y
# el conector de PHP no lo renueva. Entra para personas y operaciones; contraseña rotada para la aplicación.

# 4. Function App (tareas de mantenimiento fuera de la VM): identidad para el storage de la propia Function
resource "azurerm_linux_function_app" "mantenimiento" {            # el original usa azurerm_function_app: retirado
  name                          = "func-moodle-mant-${var.entorno}"
  resource_group_name           = azurerm_resource_group.moodle.name
  location                      = azurerm_resource_group.moodle.location
  service_plan_id               = azurerm_service_plan.func.id
  storage_account_name          = azurerm_storage_account.func.name
  storage_uses_managed_identity = true                             # en lugar de storage_account_access_key: la clave del original anula la identidad
  identity { type = "UserAssigned", identity_ids = [azurerm_user_assigned_identity.func.id] }
  key_vault_reference_identity_id = azurerm_user_assigned_identity.func.id
  site_config { application_stack { python_version = "3.12" } }
  app_settings = {
    AzureWebJobsStorage__clientId = azurerm_user_assigned_identity.func.client_id
    MOODLEDATA_URL                = azurerm_storage_account.moodledata.primary_blob_endpoint
    AZURE_CLIENT_ID               = azurerm_user_assigned_identity.func.client_id   # DefaultAzureCredential la elige sin código
  }
}
resource "azurerm_role_assignment" "func_storage_propio" {
  for_each             = toset(["Storage Blob Data Owner", "Storage Queue Data Contributor", "Storage Table Data Contributor"])
  scope                = azurerm_storage_account.func.id
  role_definition_name = each.key
  principal_id         = azurerm_user_assigned_identity.func.principal_id
  principal_type       = "ServicePrincipal"
}
resource "azurerm_role_assignment" "func_moodledata" {
  scope                = azurerm_storage_account.moodledata.id
  role_definition_name = "Storage Blob Data Reader"                # purga informes antiguos: leer y listar; borrar lo hace otra identidad con más ámbito
  principal_id         = azurerm_user_assigned_identity.func.principal_id
  principal_type       = "ServicePrincipal"
}
```

> **🔷 El código de la aplicación no cambia.** El Python del original está bien en lo esencial: `DefaultAzureCredential()` recorre una cadena (variables de entorno, identidad de carga de trabajo, identidad gestionada, CLI…) y usa la primera que responde. Lo que le faltaba es `AZURE_CLIENT_ID` en el entorno cuando la identidad es de usuario, o `ManagedIdentityCredential(client_id=…)` explícito. En local la misma línea usa tu `az login`; en la VM, IMDS; en AKS, el token del ServiceAccount. Ese es el punto: el binario es el mismo en los tres sitios.

---

## 5. Terraform bajo una identidad gestionada

La identidad más poderosa del proyecto es la que ejecuta `apply`. Si Terraform corre dentro de Azure (un runner autoalojado, una VM de operaciones, un contenedor en Container Apps Jobs), también puede ser una identidad gestionada: sin `ARM_CLIENT_SECRET`, sin rotación, sin nada que robar del runner. Lo delicado es su conjunto de roles, porque este código *asigna roles*: necesita permiso para ello, pero acotado a los roles que legítimamente reparte. Sin la condición, quien controle el pipeline puede darse *Owner*.

```hcl
resource "azurerm_user_assigned_identity" "tf" {
  name                = "id-moodle-tf-${var.entorno}"              # una por entorno: la de dev no toca pro
  resource_group_name = azurerm_resource_group.plataforma.name       # vive fuera del RG que gestiona
  location            = var.location
}
locals {
  roles_que_tf_puede_asignar = [                                    # GUIDs de los roles integrados
    "ba92f5b4-2d11-453d-a403-e96b0029c9fe",   # Storage Blob Data Contributor
    "2a2b9908-6ea1-4ae2-8e65-a410df84e7d1",   # Storage Blob Data Reader
    "4633458b-17de-408a-b874-0445c86b69e6",   # Key Vault Secrets User
    "b86a8fe4-44ce-4948-aee5-eccb2c155cd7",   # Key Vault Secrets Officer
    "a4417e6f-fecd-4de8-b567-7b0420556985",   # Key Vault Certificates Officer
    "14b46e9e-c2b7-41b4-b07b-48a6ebf60603",   # Key Vault Crypto Officer
    "e147488a-f6f5-4113-8e2d-b22465e65bf6",   # Key Vault Crypto Service Encryption User
  ]
}
resource "azurerm_role_assignment" "tf_contributor" {                # plano de control del RG de Moodle
  scope                = azurerm_resource_group.moodle.id
  role_definition_name = "Contributor"
  principal_id         = azurerm_user_assigned_identity.tf.principal_id
  principal_type       = "ServicePrincipal"
}
resource "azurerm_role_assignment" "tf_rbac_admin" {                 # puede asignar roles… solo estos, solo aquí
  scope                = azurerm_resource_group.moodle.id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = azurerm_user_assigned_identity.tf.principal_id
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = <<-EOT
    (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})
      OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${join(", ", local.roles_que_tf_puede_asignar)}})
    )
    AND
    (
      !(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})
      OR (@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {${join(", ", local.roles_que_tf_puede_asignar)}})
    )
  EOT
}
resource "azurerm_role_assignment" "tf_kv" {                         # plano de datos del vault (escribe secretos, página 11)
  scope                = azurerm_key_vault.moodle.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = azurerm_user_assigned_identity.tf.principal_id
  principal_type       = "ServicePrincipal"
}
resource "azurerm_role_assignment" "tf_estado" {                     # el estado, por Entra ID (página 10)
  scope                = "${azurerm_storage_account.tfstate.id}/blobServices/default/containers/tfstate"
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.tf.principal_id
  principal_type       = "ServicePrincipal"
}

# En el runner (VM/VMSS/Container Apps Job con identity_ids = [id-moodle-tf]) no hay ningún secreto:
#   export ARM_USE_MSI=true ARM_CLIENT_ID=<client_id de id-moodle-tf> ARM_TENANT_ID=… ARM_SUBSCRIPTION_ID=…
#   backend "azurerm" { …  use_msi = true  use_azuread_auth = true  client_id = "<client_id>" }
#   terraform init && terraform apply
# El rol personalizado de 12.3 lo crea Terraform con Contributor? No: roleDefinitions/write exige "User Access Administrator" o Owner.
# Los roles personalizados los crea la plataforma una vez; el código de Moodle solo los asigna.
```

---

## 6. Federación: ser una identidad gestionada desde fuera de Azure

El original dice "configura un Service Principal con una Managed Identity" para GitHub Actions: no existe tal cosa, y la recomendación posterior ("mejor una User-Assigned Identity asignada al pipeline") tampoco es posible tal cual, porque un runner de GitHub no es un recurso de Azure y no tiene IMDS. Lo que sí existe es la **federación de identidad de carga de trabajo**: la identidad de usuario declara que confía en los tokens que emite otro proveedor (GitHub, el emisor OIDC de un clúster AKS, Azure DevOps) para un sujeto concreto (este repositorio, esta rama; este namespace, este ServiceAccount). El pipeline presenta ese token, Entra lo cambia por uno de Azure, y nunca hubo secreto.

```hcl
# A. GitHub Actions → id-moodle-tf. Un sujeto por entorno; el de pro exige el environment "pro" (con aprobadores, página 13)
resource "azurerm_federated_identity_credential" "github" {
  for_each  = { dev = "repo:${var.github_repo}:ref:refs/heads/main", pro = "repo:${var.github_repo}:environment:pro" }
  name      = "github-${each.key}"
  resource_group_name = azurerm_user_assigned_identity.tf.resource_group_name
  parent_id = azurerm_user_assigned_identity.tf.id
  issuer    = "https://token.actions.githubusercontent.com"
  subject   = each.value                    # debe coincidir exactamente con el claim "sub" del token de GitHub
  audience  = ["api://AzureADTokenExchange"]
}
# En el workflow (página 13): permissions: { id-token: write, contents: read }
#   - uses: azure/login@v2
#     with: { client-id: ${{ vars.AZURE_CLIENT_ID }}, tenant-id: ${{ vars.AZURE_TENANT_ID }}, subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }} }   # vars, no secrets
#   env: { ARM_USE_OIDC: "true", ARM_CLIENT_ID: ${{ vars.AZURE_CLIENT_ID }}, ARM_TENANT_ID: …, ARM_SUBSCRIPTION_ID: … }
#   El provider lee ACTIONS_ID_TOKEN_REQUEST_URL/TOKEN por sí mismo: ni az login hace falta para Terraform.

# B. Azure DevOps: la conexión de servicio con "Workload identity federation" crea la credencial; si la gestionas en código:
#   issuer  = "https://vstoken.dev.azure.com/${var.ado_org_id}"
#   subject = "sc://${var.ado_org}/${var.ado_project}/${var.ado_service_connection}"
#   La tarea del original (AzureCLI@2 con scriptType 'ps') fallaría en ubuntu: scriptType 'bash'.

# C. AKS: cada pod obtiene un token de su ServiceAccount; la identidad confía en el emisor del clúster
resource "azurerm_kubernetes_cluster" "moodle" {
  # …
  identity { type = "SystemAssigned" }      # la del plano de control (crea LBs, discos). Los pods NO la usan.
  oidc_issuer_enabled       = true
  workload_identity_enabled = true
}
resource "azurerm_federated_identity_credential" "aks_web" {
  name                = "aks-moodle-web"
  resource_group_name = azurerm_user_assigned_identity.web.resource_group_name
  parent_id           = azurerm_user_assigned_identity.web.id
  issuer              = azurerm_kubernetes_cluster.moodle.oidc_issuer_url
  subject             = "system:serviceaccount:moodle:moodle-web"       # namespace:serviceaccount
  audience            = ["api://AzureADTokenExchange"]
}
# El manifiesto del original (identity: type: WorkloadIdentity) no existe. Lo real:
#   apiVersion: v1
#   kind: ServiceAccount
#   metadata: { name: moodle-web, namespace: moodle, annotations: { azure.workload.identity/client-id: "<client_id de id-moodle-web>" } }
#   ---
#   kind: Deployment … spec.template.metadata.labels: { azure.workload.identity/use: "true" }
#              spec.template.spec.serviceAccountName: moodle-web
#   El webhook inyecta AZURE_CLIENT_ID, AZURE_TENANT_ID, AZURE_FEDERATED_TOKEN_FILE; DefaultAzureCredential los usa sin cambios.
```

| **Dónde corre** | **Cómo obtiene el token de Azure** | **Qué hay que configurar** |
|---|---|---|
| VM / VMSS / App Service / Functions | IMDS (169.254.169.254) | Bloque `identity` + roles |
| Pod en AKS | Token del ServiceAccount → federación | OIDC issuer, credencial federada, ServiceAccount anotado, etiqueta en el pod |
| GitHub Actions / GitLab / Azure DevOps | Token OIDC del proveedor → federación | Credencial federada con issuer y subject exactos; `id-token: write` |
| Runner autoalojado en Azure | IMDS | `ARM_USE_MSI`; ninguna credencial en la plataforma de CI |
| Tu portátil | No hay identidad gestionada | `az login` con tu usuario; `DefaultAzureCredential` lo recoge |

---

## 7. Laboratorio en Topaz

El laboratorio construye el mapa de identidades y roles de Moodle como recursos y lo inspecciona: identificadores, ámbitos, condiciones, credencial federada. Lo que depende de tokens reales (IMDS, la evaluación de la condición ABAC, la federación) se valida con `plan` y se prueba en el bloque de Azure real, que incluye la rutina de depuración de una identidad que "no funciona".

```bash
mkdir -p ~/tf-id && cd ~/tf-id && cp ~/tf-st/providers.tf .

# ─── 1. Identidades, storage, roles con ámbito y condición, credencial federada ─────
cat > main.tf <<'EOF'
variable "entorno"      { type = string, default = "dev" }
variable "location"     { type = string, default = "eastus" }
variable "github_repo"  { type = string, default = "mi-org/moodle-infra" }
variable "validar_azure" { type = bool, default = false }
locals { tags = { proyecto = "moodle", entorno = var.entorno, gestion = "terraform" } }
data "azurerm_client_config" "actual" {}

resource "azurerm_resource_group" "id" { name = "rg-id-lab-${var.entorno}", location = var.location, tags = local.tags }
resource "azurerm_user_assigned_identity" "web" { name = "id-lab-web", resource_group_name = azurerm_resource_group.id.name, location = azurerm_resource_group.id.location, tags = local.tags }
resource "azurerm_user_assigned_identity" "tf"  { name = "id-lab-tf",  resource_group_name = azurerm_resource_group.id.name, location = azurerm_resource_group.id.location, tags = local.tags }

resource "azurerm_storage_account" "moodledata" {
  name = "stidlab${substr(md5(azurerm_resource_group.id.id), 0, 8)}"
  resource_group_name = azurerm_resource_group.id.name, location = azurerm_resource_group.id.location
  account_tier = "Standard", account_replication_type = "LRS", min_tls_version = "TLS1_2"
  shared_access_key_enabled = false
  tags = local.tags
}
resource "azurerm_storage_container" "c" { for_each = toset(["moodledata", "backups"]), name = each.key, storage_account_id = azurerm_storage_account.moodledata.id }

resource "azurerm_role_assignment" "web_blob" {
  scope                = azurerm_storage_account.moodledata.id
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.web.principal_id
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = <<-EOT
    (
      !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'})
      AND !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write'})
      AND !(ActionMatches{'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete'})
    )
    OR (@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringEquals 'moodledata')
  EOT
}
resource "azurerm_role_assignment" "tf_contributor" {
  scope = azurerm_resource_group.id.id, role_definition_name = "Contributor"
  principal_id = azurerm_user_assigned_identity.tf.principal_id, principal_type = "ServicePrincipal"
}
resource "azurerm_role_assignment" "tf_rbac_admin" {
  scope = azurerm_resource_group.id.id, role_definition_name = "Role Based Access Control Administrator"
  principal_id = azurerm_user_assigned_identity.tf.principal_id, principal_type = "ServicePrincipal"
  condition_version = "2.0"
  condition = "(!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'}) OR (@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {ba92f5b4-2d11-453d-a403-e96b0029c9fe, 4633458b-17de-408a-b874-0445c86b69e6}))"
}
resource "azurerm_role_definition" "operador" {
  name = "Moodle Operador Lab ${var.entorno}", scope = azurerm_resource_group.id.id
  permissions { actions = ["Microsoft.Compute/virtualMachineScaleSets/read", "Microsoft.Compute/virtualMachineScaleSets/restart/action", "Microsoft.Compute/virtualMachineScaleSets/reimage/action"], not_actions = [] }
  assignable_scopes = [azurerm_resource_group.id.id]
}
resource "azurerm_federated_identity_credential" "github" {
  name = "github-main", resource_group_name = azurerm_resource_group.id.name, parent_id = azurerm_user_assigned_identity.tf.id
  issuer = "https://token.actions.githubusercontent.com", subject = "repo:${var.github_repo}:ref:refs/heads/main", audience = ["api://AzureADTokenExchange"]
}
output "web" { value = { id = azurerm_user_assigned_identity.web.id, principal_id = azurerm_user_assigned_identity.web.principal_id, client_id = azurerm_user_assigned_identity.web.client_id } }
output "storage" { value = azurerm_storage_account.moodledata.name }
EOF
terraform init && terraform apply -auto-approve

# ─── 2. Los tres identificadores y dónde va cada uno ──────────────────────────────
terraform output -json web | jq .
az identity show -g rg-id-lab-dev -n id-lab-web --query "{principalId:principalId, clientId:clientId}" -o table   # coinciden con el output
terraform state show azurerm_role_assignment.web_blob | grep -E "principal_id|scope|condition_version"            # principal_id = principalId; scope = la cuenta
az role assignment list --assignee $(terraform output -json web | jq -r .principal_id) --query "[].{rol:roleDefinitionName, ambito:scope, condicion:condition!=null}" -o table
az role assignment list --scope $(az group show -n rg-id-lab-dev --query id -o tsv) --query "[?principalName=='id-lab-tf'].roleDefinitionName" -o tsv
az role definition list --custom-role-only true --query "[].{nombre:roleName, acciones:permissions[0].actions}" -o json
az identity federated-credential list -g rg-id-lab-dev --identity-name id-lab-tf --query "[].{issuer:issuer, subject:subject}" -o table

# ─── 3. Lo que Topaz no evalúa: validate + plan de los consumidores ──────────────
cat > consumidores.tf <<'EOF'
resource "azurerm_service_plan" "func" { count = var.validar_azure ? 1 : 0, name = "asp-id-lab", resource_group_name = azurerm_resource_group.id.name, location = azurerm_resource_group.id.location, os_type = "Linux", sku_name = "Y1" }
resource "azurerm_storage_account" "func" { count = var.validar_azure ? 1 : 0, name = "stidfunc${substr(md5(azurerm_resource_group.id.id), 0, 8)}", resource_group_name = azurerm_resource_group.id.name, location = azurerm_resource_group.id.location, account_tier = "Standard", account_replication_type = "LRS", shared_access_key_enabled = false }
resource "azurerm_linux_function_app" "mant" {
  count = var.validar_azure ? 1 : 0
  name = "func-id-lab", resource_group_name = azurerm_resource_group.id.name, location = azurerm_resource_group.id.location
  service_plan_id = azurerm_service_plan.func[0].id, storage_account_name = azurerm_storage_account.func[0].name, storage_uses_managed_identity = true
  identity { type = "UserAssigned", identity_ids = [azurerm_user_assigned_identity.web.id] }
  site_config { application_stack { python_version = "3.12" } }
  app_settings = { AzureWebJobsStorage__clientId = azurerm_user_assigned_identity.web.client_id, AZURE_CLIENT_ID = azurerm_user_assigned_identity.web.client_id }
}
EOF
terraform validate && terraform plan -var validar_azure=true -no-color | grep -E "Plan:|storage_uses_managed_identity|identity_ids"

# El original, tal cual: azurerm_virtual_machine y azurerm_function_app → "The provider hashicorp/azurerm does not support resource type" (retirados)
# y data.azurerm_virtual_machine sobre el recurso recién creado → ciclo o lectura vacía en el primer plan: usa identity[0].principal_id directamente.
# ─── 4. Limpiar ────────────────────────────────────────────────────────────────
terraform destroy -auto-approve      # las asignaciones se borran antes que el rol personalizado: la dependencia implícita lo ordena
```

```bash
# ─── Solo Azure real ────────────────────────────────────────────────────────────
# A. Desde una instancia del VMSS (identity_ids = [id-lab-web]): la rutina de depuración de una identidad que "no funciona"
#    1) ¿Responde IMDS y con qué identidad?
curl -s -H Metadata:true "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https://storage.azure.com/&client_id=$CLIENT_ID" \
  | jq -r .access_token | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq '{oid, appid, aud, exp}'
#    oid = principal_id, appid = client_id, aud = el servicio destino. Si falta client_id y hay varias identidades: "Multiple user assigned identities exist"
#    2) ¿Tiene el rol y ya se ha propagado? (hasta 5 min tras crearlo)
az login --identity --client-id $CLIENT_ID -o none
az role assignment list --assignee $(az account show --query user.name -o tsv) --all --query "[].{rol:roleDefinitionName, ambito:scope}" -o table
#    3) ¿Alcanza al recurso concreto? La condición ABAC deja moodledata y niega backups:
az storage blob list --account-name $ST -c moodledata --auth-mode login -o table            # OK
az storage blob list --account-name $ST -c backups    --auth-mode login                     # AuthorizationPermissionMismatch: la condición funciona
az storage blob list --account-name $ST -c moodledata --account-key x                       # KeyBasedAuthenticationNotPermitted: sin claves (página 10)
#    4) blobfuse2 con la misma identidad:
sudo blobfuse2 mount /var/moodledata --config-file=/etc/blobfuse2/moodledata.yaml && touch /var/moodledata/prueba && ls -la /var/moodledata

# B. Terraform bajo id-lab-tf, desde un runner con esa identidad: puede asignar Blob Data Contributor, no puede darse Owner
export ARM_USE_MSI=true ARM_CLIENT_ID=$TF_CLIENT_ID ARM_TENANT_ID=$(az account show --query tenantId -o tsv) ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform apply -auto-approve                                                               # web_blob se crea: rol permitido por la condición
az login --identity --client-id $TF_CLIENT_ID -o none
az role assignment create --assignee $WEB_PRINCIPAL --role Owner --scope $(az group show -n rg-id-lab-dev --query id -o tsv)
#    → AuthorizationFailed … does not have authorization … or the condition is not met. Quien controle el pipeline no puede escalar.

# C. Federación con GitHub: cuando falla, casi siempre es el subject. Decodifica el token que GitHub emite dentro del job:
#    - run: curl -s -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=api://AzureADTokenExchange" | jq -r .value | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq '{iss, sub, aud}'
#    y compáralo carácter a carácter con:
az identity federated-credential list -g rg-id-lab-dev --identity-name id-lab-tf --query "[].subject" -o tsv
#    "repo:org/repo:ref:refs/heads/main" ≠ "repo:org/repo:pull_request" ≠ "repo:org/repo:environment:pro": una credencial por cada sujeto que uses.

# D. Quién ha usado la identidad (página 14): la actividad ARM se atribuye al client_id; los tokens, al sign-in log de service principals
az monitor activity-log list --caller $TF_CLIENT_ID --offset 1d --query "[].{cuando:eventTimestamp, que:operationName.localizedValue, sobre:resourceId}" -o table
#    KQL: AADManagedIdentitySignInLogs | where ServicePrincipalId == "<principal_id>" | summarize count() by ResourceDisplayName, bin(TimeGenerated, 1h)
```

---

## 8. Errores comunes

> ⚠️ **Solución de problemas**
>
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | *PrincipalNotFound: Principal … does not exist in the directory* | Replicación de Entra ID tras crear la identidad. `principal_type = "ServicePrincipal"` en la asignación: ARM deja de buscar el principal y acepta |
> | 403 / *AuthorizationPermissionMismatch* justo después del `apply`, y a los minutos funciona | La asignación tarda hasta 5 min en propagarse. Identidad de usuario creada antes del VMSS con `depends_on` en los roles, y `time_sleep` (60-120 s) entre la asignación y lo que la use en el primer arranque |
> | *Contributor* sobre el RG y la VM no puede leer un blob | Plano de control frente a plano de datos. *Contributor* configura y borra recursos; leer blobs o secretos exige *Storage Blob Data …* o *Key Vault Secrets User*. Quita el Contributor: la VM no lo necesita para nada |
> | *Multiple user assigned identities exist, please specify the clientId / resourceId* | El recurso tiene varias identidades y la petición a IMDS no dice cuál. `client_id=` en la URL, `AZURE_CLIENT_ID` en el entorno, `appid` en blobfuse2, `ManagedIdentityCredential(client_id=…)` en el SDK |
> | *AADSTS70021: No matching federated identity record found for presented assertion* | El `subject` no coincide exactamente. `ref:refs/heads/main`, `pull_request` y `environment:pro` son sujetos distintos: una credencial federada por cada uno. Decodifica el token del job (laboratorio C) y compara |
> | *Unable to get ACTIONS_ID_TOKEN_REQUEST_URL* | Falta `permissions: { id-token: write }` en el workflow. Y `azure/login@v1` está retirado: `@v2` |
> | `client_id`, `tenant_id` y `subscription_id` guardados como `secrets` | No son secretos; enmascararlos oculta en los logs lo que necesitas para depurar. Van en `vars` (GitHub) o variables normales del pipeline |
> | Recreo un recurso con identidad de sistema y aparecen asignaciones a *Identity not found* | Nuevo `principal_id`; las asignaciones viejas quedan huérfanas. Limpia con `az role assignment list --query "[?principalName=='']"` y pásate a identidad de usuario, que sobrevive al recurso |
> | *identity_ids is required when type is UserAssigned* | El bloque `identity` con tipo de usuario necesita la lista de `id` (rutas ARM), no de `principal_id` ni `client_id` |
> | *The client … does not have authorization to perform action Microsoft.Authorization/roleDefinitions/write* | Crear roles personalizados exige *User Access Administrator* u *Owner*; *Contributor* + *RBAC Administrator* no bastan. Los roles personalizados los crea la plataforma; el código de Moodle los asigna |
> | *The given role assignment condition is invalid* | Sintaxis ABAC: `condition_version = "2.0"`, comillas simples dentro de `ActionMatches{}`, atributos entre `@Resource[…]` / `@Request[…]`. Las condiciones solo existen para roles con acciones de datos de Storage y para asignar roles (`roleAssignments/write`) |
> | La identidad tiene *Key Vault Secrets User* y el vault devuelve *Forbidden* | El vault está en modo *access policy*, que ignora RBAC. `rbac_authorization_enabled = true` (página 11). O al revés: política de acceso en un vault RBAC, que no hace nada |
> | Function App: `storage_uses_managed_identity` y sigue fallando al arrancar con `shared_access_key_enabled = false` | Los planes Consumption (`Y1`) y Elastic Premium guardan el contenido en Azure Files, que exige clave (`WEBSITE_CONTENTAZUREFILECONNECTIONSTRING`). Para una Function sin claves: plan Flex Consumption (`azurerm_function_app_flex_consumption`) o Dedicated con `WEBSITE_RUN_FROM_PACKAGE` por URL. El `Y1` del laboratorio sirve para el `plan`, no para producción sin claves |
> | Function App con `storage_account_access_key` *e* `identity` (el original) | La clave gana: la identidad no se usa para el storage y la clave está en el estado. Quita la clave y añade `storage_uses_managed_identity` más los tres roles de datos (Blob Owner, Queue Contributor, Table Contributor) |
> | MySQL: *The identity doesn't have permission to read directory* al crear el administrador Entra | La identidad del servidor necesita permisos Graph (*User.Read.All*, *GroupMember.Read.All*, *Application.Read.All*) concedidos por un administrador de Entra. Con azurerm no se puede; con el provider azuread, `azuread_app_role_assignment` |
> | El manifiesto `identity: type: WorkloadIdentity` del original | No existe. Workload Identity es: `oidc_issuer_enabled` + `workload_identity_enabled` en el clúster, credencial federada con el `oidc_issuer_url`, ServiceAccount anotado con el `client_id` y etiqueta `azure.workload.identity/use: "true"` en el pod |
> | Los pods usan la identidad del clúster (`SystemAssigned` de AKS) y tienen más permisos de los previstos | Esa identidad (o la del kubelet) es para el plano de control: discos, balanceadores. Los pods deben tener la suya por federación; bloquea IMDS desde los pods con una NetworkPolicy a 169.254.169.254 |
> | `DefaultAzureCredential` tarda 20 s o elige la identidad equivocada | Recorre toda la cadena. En producción, `ManagedIdentityCredential(client_id=…)` o `WorkloadIdentityCredential` explícitos; en local, `AZURE_CLIENT_ID` vacío y `az login` |
> | `terraform destroy`: *role definition has existing role assignments* | Alguien asignó el rol personalizado fuera de Terraform (portal). Bórralo con `az role assignment delete --role "Moodle Operador …"` y repite; la dependencia solo ordena lo que Terraform conoce |
> | En Topaz: la condición ABAC no niega nada, `curl 169.254.169.254`

---

## 9. Autoevaluación

1. **¿Qué distingue a una identidad gestionada de un service principal con secreto?**
   La identidad es un service principal igual; lo distinto es el canal: el recurso pide tokens a IMDS (169.254.169.254), accesible solo desde dentro, y Azure rota la credencial sin que exista fuera de la plataforma.
2. **`id`, `principal_id`, `client_id`: ¿dónde va cada uno?**
   `id` (ruta ARM) en `identity_ids` y `parent_id`; `principal_id` en `azurerm_role_assignment`; `client_id` en IMDS, `ARM_CLIENT_ID`, la anotación del ServiceAccount y `azure/login`.
3. **¿Por qué ninguno de ellos es secreto?**
   Aparecen en cada token y en cada log de auditoría. La seguridad está en que solo quien controla el recurso, o quien la federación reconoce, puede obtener un token con ellos.
4. **¿Cuándo prefieres identidad de usuario y cuándo de sistema?**
   Usuario por defecto: existe antes que el recurso (roles antes del primer arranque), se comparte entre instancias, sobrevive a recreaciones y se puede federar. Sistema solo donde el servicio la exige.
5. **¿Por qué *Contributor* sobre el RG es a la vez excesivo e insuficiente para la VM web?**
   Excesivo porque permite borrar MySQL; insuficiente porque es plano de control y no da acceso a datos: leer blobs exige *Storage Blob Data Contributor*.
6. **¿Qué hace `principal_type = "ServicePrincipal"` en una asignación?**
   Evita *PrincipalNotFound* por la replicación de Entra: ARM no busca el principal y confía en el tipo declarado.
7. **¿Para qué sirve la condición ABAC en `web_blob`?**
   Limita el rol, asignado sobre toda la cuenta, a las operaciones de datos del contenedor `moodledata`; `backups` queda fuera aunque viva en la misma cuenta.
8. **¿Qué riesgo cubre la condición en *RBAC Administrator* para la identidad de Terraform?**
   Sin ella, quien controle el pipeline puede asignarse *Owner*. Con ella, Terraform solo puede crear o borrar asignaciones de la lista de roles de datos que legítimamente reparte.
9. **¿Por qué "una User-Assigned Identity asignada al pipeline de GitHub" no es posible tal cual y qué se hace en su lugar?**
   Un runner de GitHub no es un recurso de Azure: no tiene IMDS. Se federa la identidad de usuario con el emisor OIDC de GitHub para un sujeto exacto (repo, rama o environment), y el provider intercambia el token del job por uno de Azure.
10. **¿Qué tres piezas hacen funcionar Workload Identity en AKS?**
    El clúster con `oidc_issuer_enabled` y `workload_identity_enabled`; la credencial federada con el `oidc_issuer_url` y el sujeto `system:serviceaccount:ns:sa`; el ServiceAccount anotado con el `client_id` más la etiqueta `azure.workload.identity/use` en el pod.
11. **¿Por qué el usuario de aplicación de Moodle en MySQL sigue con contraseña?**
    El token de Entra dura una hora y el conector PHP no lo renueva. Entra ID para personas y operaciones (grupo DBA); contraseña rotada en Key Vault para la aplicación.
12. **Una identidad "no funciona": ¿en qué orden lo depuras?**
    IMDS responde y con qué `oid`/`appid`; la asignación existe y se ha propagado; el ámbito y la condición alcanzan al recurso concreto; el servicio destino está en modo RBAC y sin claves que compitan.

---

## 10. Referencias

- [Identidades administradas para recursos de Azure](https://learn.microsoft.com/es-es/entra/identity/managed-identities-azure-resources/overview) y [obtención de tokens desde IMDS](https://learn.microsoft.com/es-es/entra/identity/managed-identities-azure-resources/how-to-use-vm-token)
- [`azurerm_user_assigned_identity`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/user_assigned_identity), [`azurerm_role_assignment`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_assignment), [`azurerm_role_definition`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/role_definition) y [`azurerm_federated_identity_credential`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/federated_identity_credential)
- [Roles integrados de Azure](https://learn.microsoft.com/es-es/azure/role-based-access-control/built-in-roles) (GUIDs) y [formato de las condiciones ABAC](https://learn.microsoft.com/es-es/azure/role-based-access-control/conditions-format)
- [Delegar la gestión de asignaciones con condiciones](https://learn.microsoft.com/es-es/azure/role-based-access-control/delegate-role-assignments-overview) (RBAC Administrator acotado)
- [Configuración de blobfuse2](https://learn.microsoft.com/es-es/azure/storage/blobs/blobfuse2-configuration) (modo `msi`)
- [Autenticación de Entra ID en MySQL Flexible Server](https://learn.microsoft.com/es-es/azure/mysql/flexible-server/how-to-azure-ad)
- [Functions: storage del host con identidad](https://learn.microsoft.com/es-es/azure/azure-functions/functions-reference#connecting-to-host-storage-with-an-identity) y [plan Flex Consumption](https://learn.microsoft.com/es-es/azure/azure-functions/flex-consumption-plan)
- [Workload Identity en AKS](https://learn.microsoft.com/es-es/azure/aks/workload-identity-overview)
- [Federación de una identidad de usuario con GitHub y otros emisores](https://learn.microsoft.com/es-es/entra/workload-id/workload-identity-federation-create-trust-user-assigned-managed-identity) y [OIDC en GitHub Actions](https://docs.github.com/es/actions/security-for-github-actions/security-hardening-your-deployments/about-security-hardening-with-openid-connect) (formato del `sub`)
- [Provider azurerm con identidad gestionada](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/managed_service_identity) y [con OIDC](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/guides/service_principal_oidc)
- [`DefaultAzureCredential`: orden de la cadena](https://learn.microsoft.com/es-es/python/api/overview/azure/identity-readme#defaultazurecredential)
- [Azure Local Emulator (Topaz)](https://github.com/Azure/azure-local-emulator)