# 🖥️ Despliegue de máquinas virtuales

> Una máquina virtual en Azure no es un recurso, son seis: la subred donde vive, un grupo de seguridad que filtra el tráfico, una IP pública, una interfaz de red que lo une todo y, al final, la VM con su disco e imagen. En esta página construirás esa cadena completa. El plano de red se despliega y verifica en **Topaz**; la máquina virtual, que necesita `Microsoft.Compute`, se declara con un interruptor que la deja apagada en el emulador y la enciende en una suscripción real sin tocar el resto del código.

**🎯 Objetivos de aprendizaje**
- Explicar la cadena de dependencias subred → NSG → IP pública → NIC → VM.
- Crear un grupo de seguridad de red con una regla SSH restringida a una IP de origen.
- Configurar IP pública estática y IP privada estática en una NIC.
- Declarar una VM Linux con clave SSH e imagen actual de Ubuntu, activable por variable.
- Reconocer y documentar las diferencias entre el emulador y Azure real mediante `lifecycle { ignore_changes }`.
- Verificar el despliegue con Azure CLI y conectarse por SSH (Azure real).

> **🔷 Requisitos previos.** Página 1 completada (provider configurado para Topaz en `~/tf-intro/providers.tf`), `az account show --query environmentName -o tsv` → `Topaz`, y una clave SSH: si no tienes, `ssh-keygen -t ed25519 -f ~/.ssh/tf-lab -N ""`.

---

## 2.1. Anatomía de una VM en Azure

```text
Grupo de recursos
├── Red virtual 10.0.0.0/16
│   └── Subred snet-vm 10.0.1.0/24 ─────────────┐
├── NSG nsg-vm (regla inline: SSH desde mi IP) ─┤ asociación
├── IP pública pip-vm (Standard, estática)      │
├── NIC nic-vm ◄─── subred + NSG + IP pública ──┘
│     ip privada 10.0.1.10
└── VM vm-lab ◄─── NIC + disco SO + imagen Ubuntu 22.04 + clave SSH
```

| **Recurso Terraform** | **Resource provider** | **Función** | **En Topaz** |
|---|---|---|---|
| `azurerm_virtual_network` | Microsoft.Network | Espacio de direcciones privado | ✅ (no devuelve `private_endpoint_vnet_policies`) |
| `azurerm_subnet` | Microsoft.Network | Rango donde la NIC toma su IP privada | ✅ |
| `azurerm_network_security_group` con bloque `security_rule` | Microsoft.Network | Cortafuegos de capa 4: qué puertos, desde dónde | ✅ solo reglas inline; `azurerm_network_security_rule` ❌ |
| `azurerm_public_ip` | Microsoft.Network | Dirección alcanzable desde Internet | ✅ recurso; la dirección asignada es simulada |
| `azurerm_network_interface` + `_security_group_association` | Microsoft.Network | Tarjeta de red: une subred, IP pública y NSG | ✅ (no devuelve `public_ip_address_id`) |
| `azurerm_linux_virtual_machine` | Microsoft.Compute | Cómputo, disco e imagen | ❌ solo Azure real |

La cadena de referencias (`subnet_id = azurerm_subnet.vm.id`, `network_interface_ids = [azurerm_network_interface.vm.id]`…) es lo que permite a Terraform ordenar la creación sin que escribas ningún `depends_on`.

---

## 2.2. Preparar el directorio y las variables

```bash
mkdir -p ~/tf-vm && cd ~/tf-vm
cp ~/tf-intro/providers.tf .        # imprescindible: fija azurerm ~> 4.0 y apunta el provider a Topaz
ls                                  # providers.tf   ← y nada más, de momento
```

> ⚠️ **Copia solo `providers.tf`.** Si copias también el `main.tf` de la página 1, tendrás el grupo de recursos y la red virtual declarados dos veces (allí y en `red.tf`) y `validate` fallará con *Duplicate resource*. En este laboratorio cada recurso vive en su archivo: `red.tf`, `nic.tf`, `vm.tf`, `variables.tf` y `outputs.tf`. Y si al hacer `init` ves *Finding latest version of hashicorp/azurerm* e instala una 5.x, es que falta `providers.tf`: sin la versión fijada, el `plan` fallará.

```hcl
# variables.tf
variable "desplegar_vm" {
  type        = bool
  description = "Crear la máquina virtual (requiere Microsoft.Compute: false en Topaz, true en Azure real)"
  default     = false
}

variable "ip_admin" {
  type        = string
  description = "IP pública desde la que se permite SSH, en formato CIDR (p. ej. 203.0.113.7/32)"
  validation {
    condition     = can(cidrhost(var.ip_admin, 0))
    error_message = "Debe ser un CIDR válido, como 203.0.113.7/32."
  }
}

variable "admin_username" {
  type        = string
  description = "Usuario administrador de la VM"
  default     = "azureuser"
}

variable "ruta_clave_publica" {
  type        = string
  description = "Ruta a la clave pública SSH"
  default     = "~/.ssh/tf-lab.pub"
}

variable "tamano_vm" {
  type        = string
  description = "SKU de la VM"
  default     = "Standard_B2ats_v2"          # serie B v2: barata, apta para laboratorio
}
```

```hcl
# terraform.tfvars  (ajusta ip_admin a la tuya: curl -s ifconfig.me)
ip_admin = "203.0.113.7/32"
```

---

## 2.3. Plano de red: red, subred y NSG

```hcl
# red.tf
resource "azurerm_resource_group" "lab" {
  name     = "rg-vm-001"
  location = "eastus"
  tags     = { entorno = "lab", gestion = "terraform" }
  lifecycle { ignore_changes = [tags] }     # Topaz no devuelve las tags del grupo
}

resource "azurerm_virtual_network" "lab" {
  name                = "vnet-vm"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  address_space       = ["10.0.0.0/16"]

  lifecycle {
    ignore_changes = [private_endpoint_vnet_policies]   # Topaz no devuelve este atributo
  }
}

resource "azurerm_subnet" "vm" {
  name                 = "snet-vm"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.lab.name
  address_prefixes     = ["10.0.1.0/24"]
}

resource "azurerm_network_security_group" "vm" {
  name                = "nsg-vm"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  # Regla inline: viaja en el mismo PUT que el NSG (Topaz no implementa securityRules/<nombre>)
  security_rule {
    name                       = "Allow-SSH-Admin"
    priority                   = 1001                 # 100-4096; menor = se evalúa antes
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.ip_admin         # NUNCA "*": eso es SSH abierto al mundo
    destination_address_prefix = "*"
  }
}
```

Las reglas de un NSG se pueden declarar de **dos formas**, y el resultado en Azure es idéntico:

| **Forma** | **Cuándo conviene** | **En Topaz** |
|---|---|---|
| Bloque `security_rule { }` dentro del NSG (*inline*) | Pocas reglas, gestionadas desde el mismo módulo que el NSG. No lleva `resource_group_name` ni `network_security_group_name`: los hereda | ✅ |
| Recurso independiente `azurerm_network_security_rule` | Muchas reglas, o añadidas desde módulos distintos al que crea el NSG. Recomendado en Azure real para equipos grandes | ❌ *EndpointNotFound* en `PUT .../securityRules/<nombre>` |

No mezcles las dos formas sobre el mismo NSG: Terraform eliminaría en cada `apply` las reglas independientes que no aparezcan en el bloque inline, y viceversa. Para referencia, la misma regla como recurso independiente (válida en Azure real):

```hcl
# Alternativa para Azure real (NO en Topaz): regla como recurso independiente
resource "azurerm_network_security_rule" "ssh" {
  name                        = "Allow-SSH-Admin"
  priority                    = 1001
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefix       = var.ip_admin
  destination_address_prefix  = "*"
  resource_group_name         = azurerm_resource_group.lab.name
  network_security_group_name = azurerm_network_security_group.vm.name
}
```

> ⚠️ **Sobre la regla SSH.** El original usaba `source_address_prefix = "*"`. Una VM con el 22 abierto a Internet recibe miles de intentos de acceso por hora desde el primer minuto; Microsoft Defender lo marca como alerta de severidad alta. Restringe siempre a tu IP, y en producción elimina la IP pública y entra por **Azure Bastion** o una VPN.

> **🔷 En Topaz: el patrón `ignore_changes`.** El emulador acepta todos los argumentos que le envías, pero al leer el recurso no devuelve algunos (`tags` del grupo, `private_endpoint_vnet_policies` de la vnet, `public_ip_address_id` de la NIC). Terraform interpreta la ausencia como una desviación y propone "corregirla" en cada `apply`: verás *Modifying…* sobre recursos que no has tocado y el `plan` nunca llegará a *No changes*. `lifecycle { ignore_changes = [...] }` le dice que no compare ese atributo. Ninguno de los tres es necesario en Azure real.

---

## 2.4. IP pública e interfaz de red

```hcl
# nic.tf
resource "azurerm_public_ip" "vm" {
  name                = "pip-vm"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name
  sku                 = "Standard"          # Basic está retirado; Standard exige Static
  allocation_method   = "Static"
}

resource "azurerm_network_interface" "vm" {
  name                = "nic-vm"
  location            = azurerm_resource_group.lab.location
  resource_group_name = azurerm_resource_group.lab.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Static"
    private_ip_address            = "10.0.1.10"        # las 4 primeras y la última IP de cada subred están reservadas
    public_ip_address_id          = azurerm_public_ip.vm.id
  }

  lifecycle {
    ignore_changes = [ip_configuration[0].public_ip_address_id]   # Topaz no devuelve este atributo
  }
}

resource "azurerm_network_interface_security_group_association" "vm" {
  network_interface_id      = azurerm_network_interface.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}
```

Dos cambios respecto al original. La IP pública `Dynamic` con SKU Basic dejó de poder crearse en 2025; con `Standard` la dirección es estática y se conoce en el `apply`. Y la IP privada se fija a `10.0.1.10`: en una VM de laboratorio da igual, pero en cuanto algo (un DNS, una regla de cortafuegos) apunte a esa dirección, querrás que sobreviva a un reemplazo de la máquina.

> **🔷 En Topaz.** Los tres recursos de este archivo se crean en el emulador, incluida la IP pública con `sku = "Standard"`. La dirección asignada es simulada (no enrutable) y la NIC muestra la privada que fijaste. La asociación con la IP pública se guarda pero no se devuelve al leer la NIC: de ahí el `ignore_changes`. Sin él, cada `apply` mostraría `+ public_ip_address_id` en la NIC aunque nada haya cambiado.

---

## 2.5. La máquina virtual (activable)

```hcl
# vm.tf
resource "azurerm_linux_virtual_machine" "lab" {
  count = var.desplegar_vm ? 1 : 0          # 0 en Topaz, 1 en Azure real

  name                  = "vm-lab"
  resource_group_name   = azurerm_resource_group.lab.name
  location              = azurerm_resource_group.lab.location
  size                  = var.tamano_vm
  admin_username        = var.admin_username
  network_interface_ids = [azurerm_network_interface.vm.id]

  disable_password_authentication = true    # solo clave SSH
  admin_ssh_key {
    username   = var.admin_username
    public_key = file(pathexpand(var.ruta_clave_publica))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {                  # Ubuntu 22.04 LTS Gen2 (el offer "UbuntuServer" ya no existe)
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  tags = azurerm_resource_group.lab.tags
}
```

| **Argumento** | **Qué decide** |
|---|---|
| `size` | CPU/RAM y precio. Consulta disponibilidad: `az vm list-skus -l eastus --size Standard_B -o table` |
| `source_image_reference` | Imagen del marketplace. Lista actual: `az vm image list -p Canonical --all -o table`. Para 24.04: offer `ubuntu-24_04-lts`, sku `server` |
| `os_disk.storage_account_type` | `Standard_LRS` (HDD) para laboratorio; `Premium_LRS` en producción |
| `pathexpand()` | Resuelve `~`; `file()` a secas no lo hace en todos los sistemas |

Con `count`, la VM pasa a ser una lista: se referencia como `azurerm_linux_virtual_machine.lab[0]`, y los outputs que dependen de ella deben tolerar que la lista esté vacía (siguiente sección).

---

## 2.6. Outputs

```hcl
# outputs.tf
output "ip_publica" {
  description = "IP pública asociada a la NIC"
  value       = azurerm_public_ip.vm.ip_address
}

output "ip_privada" {
  description = "IP privada de la NIC"
  value       = azurerm_network_interface.vm.private_ip_address
}

output "vm_id" {
  description = "ID de la VM, o null si no se ha desplegado"
  value       = one(azurerm_linux_virtual_machine.lab[*].id)
}

output "comando_ssh" {
  description = "Comando de conexión (solo útil con la VM desplegada)"
  value       = var.desplegar_vm ? "ssh -i ${trimsuffix(var.ruta_clave_publica, ".pub")} ${var.admin_username}@${azurerm_public_ip.vm.ip_address}" : "VM no desplegada (desplegar_vm = false)"
}
```

`one()` devuelve el único elemento de una lista, o `null` si está vacía: es la forma idiomática de exponer un recurso con `count` condicional sin que el output falle. El original construía el comando SSH sin la IP; aquí sale completo, con la clave privada deducida de la pública.

---

## 2.7. Despliegue en Topaz

```bash
ls                                                 # nic.tf outputs.tf providers.tf red.tf terraform.tfvars variables.tf vm.tf
terraform init
#   - Installing hashicorp/azurerm v4.x.x...      ← si dice "Finding latest version" o instala 5.x, falta providers.tf
terraform validate
terraform plan
#   Plan: 7 to add, 0 to change, 0 to destroy.     ← grupo, vnet, subred, NSG (con su regla), pip, nic, asociación; sin VM
terraform apply -auto-approve

terraform output
#   comando_ssh = "VM no desplegada (desplegar_vm = false)"
#   ip_privada  = "10.0.1.10"
#   ip_publica  = "<dirección simulada>"
#   vm_id       = null

# Verificar la cadena con la CLI
az network nsg show -g rg-vm-001 -n nsg-vm \
  --query "securityRules[].{regla:name, prio:priority, puerto:destinationPortRange, origen:sourceAddressPrefix}" -o table
az network nic show -g rg-vm-001 -n nic-vm \
  --query "{privada:ipConfigurations[0].privateIPAddress, subred:ipConfigurations[0].subnet.id, nsg:networkSecurityGroup.id}" -o json

terraform plan                                     # No changes.  ← gracias a los tres ignore_changes
```

Si ese último `plan` sigue proponiendo algún cambio, mira qué atributo marca con `~` o `+`: es un atributo más que tu versión del emulador no devuelve. Añádelo al `ignore_changes` del recurso y anótalo como diferencia.

| **Limitación de Topaz en este laboratorio** | **Síntoma** | **Solución aplicada** |
|---|---|---|
| No implementa el endpoint `securityRules/<nombre>` | *EndpointNotFound* (404) al crear `azurerm_network_security_rule` | Bloque `security_rule` inline en el NSG |
| No devuelve `tags` del grupo de recursos | `~ tags` en cada `plan` | `ignore_changes = [tags]` |
| No devuelve `private_endpoint_vnet_policies` de la vnet | *Modifying…* sobre la vnet en cada `apply` | `ignore_changes = [private_endpoint_vnet_policies]` |
| No devuelve `public_ip_address_id` de la NIC | *Modifying…* sobre la NIC en cada `apply` | `ignore_changes = [ip_configuration[0].public_ip_address_id]` |
| No incluye `Microsoft.Compute` | *NoRegisteredProviderFound* al aplicar la VM | `count = var.desplegar_vm ? 1 : 0` |

Prueba ahora la validación: cambia `ip_admin` a `"203.0.113.7"` (sin `/32`) y ejecuta `plan`. Debe fallar antes de tocar el emulador con el mensaje que escribiste. Restaura el valor.

```bash
# Ver qué pasaría con la VM activada, sin aplicarlo
terraform plan -var desplegar_vm=true
#   + azurerm_linux_virtual_machine.lab[0]
#   Plan: 1 to add, 0 to change, 0 to destroy.

terraform destroy -auto-approve                    # limpieza
az group list -o table                             # vacío
```

> **🔷 En Topaz.** El `plan` con `desplegar_vm=true` funciona porque planificar no llama a `Microsoft.Compute`. Un `apply` con ese valor fallaría en el emulador con un error de *resource provider* no encontrado: es la señal de que has llegado al límite de Topaz, no un error tuyo.

---

## 2.8. Despliegue y conexión en Azure real

Mismo directorio, con estos ajustes:

- En `providers.tf`: quitar `metadata_host` y `resource_provider_registrations`, poner tu `subscription_id`.
- Quitar los tres `lifecycle { ignore_changes }` de Topaz (grupo, vnet y NIC). En Azure real esos atributos sí se devuelven y conviene que Terraform los vigile.
- La regla inline del NSG se queda tal cual: funciona igual en Azure real.

```bash
az login && az account set -s "<tu suscripción>"
terraform init -reconfigure
terraform apply -var desplegar_vm=true             # Plan: 8 to add (7 de red + VM); la VM tarda 1-2 minutos

$(terraform output -raw comando_ssh)               # ejecuta el comando SSH generado
#   azureuser@vm-lab:~$ uname -a
#   Linux vm-lab 6.x ... Ubuntu

# Comprobaciones y coste
az vm show -g rg-vm-001 -n vm-lab -d --query "{estado:powerState, ip:publicIps, tamano:hardwareProfile.vmSize}" -o table
az vm deallocate -g rg-vm-001 -n vm-lab            # parada sin coste de cómputo (el disco sigue cobrándose)
terraform destroy -var desplegar_vm=true -auto-approve   # cuando termines: una B2ats_v2 cuesta ~8 €/mes encendida
```

> ⚠️ **`az vm stop` no es gratis.** Deja la VM en estado *Stopped*, que sigue facturando cómputo. Solo `deallocate` (o `destroy`) detiene el cargo. Y si haces `deallocate` con IP pública Basic dinámica, la dirección cambia; con Standard estática, como aquí, se conserva.

---

## 2.9. Errores comunes

> ⚠️ **Solución de problemas**
> 
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | *Duplicate resource "azurerm_resource_group" configuration* | Has copiado `main.tf` de `~/tf-intro` y el grupo o la vnet están declarados dos veces. Borra `main.tf`: en este laboratorio ambos viven en `red.tf` |
> | *Reference to undeclared resource* `azurerm_subnet.vm` en `nic.tf` | Al resolver los duplicados has borrado `red.tf` en lugar de `main.tf`. Recréalo completo (sección 2.3): contiene también la subred y el NSG |
> | *Finding latest version of hashicorp/azurerm* e instala `v5.x` | Falta `providers.tf` con `version = "~> 4.0"`. Cópialo de `~/tf-intro`, borra `.terraform/` y `.terraform.lock.hcl`, y repite `init` |
> | *EndpointNotFound* (404) en `PUT .../securityRules/Allow-SSH-Admin` | Topaz no implementa `azurerm_network_security_rule`. Define la regla como bloque `security_rule` dentro del NSG y elimina el recurso independiente (no llegó al estado, no hace falta `state rm`) |
> | *Modifying…* en vnet o NIC en cada `apply`; el `plan` nunca dice *No changes* | El emulador no devuelve `private_endpoint_vnet_policies` ni `public_ip_address_id`. Añade los `ignore_changes` de las secciones 2.3 y 2.4 |
> | *NoRegisteredProviderFound: Microsoft.Compute* en Topaz | Has aplicado con `desplegar_vm=true` en el emulador: solo `plan`; el `apply` de la VM es para Azure real |
> | *No value for required variable "ip_admin"* | Falta `terraform.tfvars` o la clave está mal escrita: `echo 'ip_admin = "203.0.113.7/32"' > terraform.tfvars` |
> | *PublicIPAllocationMethodMustBeStatic* / SKU Basic no disponible | Usa `sku = "Standard"` + `allocation_method = "Static"` |
> | *PlatformImageNotFound* / *offer UbuntuServer* | Imagen retirada: `0001-com-ubuntu-server-jammy` / `22_04-lts-gen2` |
> | *SkuNotAvailable* / *QuotaExceeded* | Tamaño no disponible en la región o cuota de suscripción gratuita: cambia `tamano_vm` o región |
> | *PrivateIPAddressInReservedRange* | Las IPs .0-.3 y la última de cada subred son de Azure: usa .4 en adelante |
> | *Invalid function argument: no file exists at ~/.ssh/...* | Genera la clave (`ssh-keygen`) o corrige `ruta_clave_publica` |
> | *Connection timed out* al hacer SSH | Tu IP pública cambió respecto a `ip_admin`: `curl -s ifconfig.me`, actualiza y `apply` |
> | *Permission denied (publickey)* | Clave privada equivocada o usuario distinto de `admin_username` |
> | *Unsupported attribute* en `azurerm_linux_virtual_machine.lab.id` | Con `count` es una lista: `lab[0].id` o `one(lab[*].id)` |

---

## 2.10. Autoevaluación

1. **¿Cuántos recursos de red necesita una VM con acceso SSH desde Internet y en qué orden se crean?**
   Red virtual, subred, NSG con su regla, IP pública, NIC y asociación NIC-NSG (siete con el grupo de recursos); el orden lo deduce Terraform de las referencias.
2. **¿Por qué el NSG se asocia a la NIC y no a la VM?**
   El filtrado ocurre en la tarjeta de red (o en la subred); la VM no tiene reglas propias.
3. **¿Qué diferencia hay entre una regla `security_rule` inline y un recurso `azurerm_network_security_rule`?**
   El resultado en Azure es el mismo. La inline viaja en el mismo PUT que el NSG (la única que Topaz acepta); la independiente permite añadir reglas desde otros módulos. No se deben mezclar sobre el mismo NSG.
4. **¿Qué problema tiene `source_address_prefix = "*"` en la regla SSH?**
   Expone el puerto 22 a todo Internet; se restringe a la IP del administrador o se elimina la IP pública y se usa Bastion.
5. **¿Por qué el `plan` proponía cambios en la vnet y la NIC en cada ejecución, y cómo se resuelve?**
   Topaz no devuelve algunos atributos al leer el recurso y Terraform lo interpreta como desviación. `lifecycle { ignore_changes = [...] }` excluye ese atributo de la comparación; en Azure real no hace falta.
6. **¿Para qué sirve `count = var.desplegar_vm ? 1 : 0`?**
   Hace la VM opcional: el mismo código despliega solo red en Topaz y red + VM en Azure real.
7. **¿Por qué `plan -var desplegar_vm=true` funciona en Topaz y `apply` no?**
   Planificar no llama a Microsoft.Compute; crear sí, y el emulador no lo implementa.
8. **¿Qué diferencia hay entre `az vm stop` y `az vm deallocate`?**
   Stop apaga el SO pero sigue facturando cómputo; deallocate libera el hardware y solo se paga el disco.

---

## 2.11. Referencias

- [`azurerm_linux_virtual_machine`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/linux_virtual_machine), [`azurerm_network_interface`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_interface), [`azurerm_public_ip`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/public_ip), [`azurerm_network_security_group`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_group) (bloque `security_rule`), [`azurerm_network_security_rule`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_rule)
- [Meta-argumento `lifecycle`: `ignore_changes`](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle#ignore_changes)
- [Grupos de seguridad de red](https://learn.microsoft.com/es-es/azure/virtual-network/network-security-groups-overview) y [Azure Bastion](https://learn.microsoft.com/es-es/azure/bastion/bastion-overview)
- [IP públicas: SKU Standard y retirada de Basic](https://learn.microsoft.com/es-es/azure/virtual-network/ip-services/public-ip-addresses)
- [Buscar imágenes de VM con Azure CLI](https://learn.microsoft.com/es-es/azure/virtual-machines/linux/cli-ps-findimage)
- [Estados de una VM y facturación](https://learn.microsoft.com/es-es/azure/virtual-machines/states-billing)
- [Función `one()`](https://developer.hashicorp.com/terraform/language/functions/one) y [meta-argumento `count`](https://developer.hashicorp.com/terraform/language/meta-arguments/count)
- [Azure Local Emulator (Topaz)](https://github.com/Azure/azure-local-emulator)