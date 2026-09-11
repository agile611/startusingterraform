# 🌐 Redes virtuales

> En la página anterior la red era un medio para llegar a la VM. Aquí es el protagonista: diseñarás un espacio de direcciones, lo dividirás en subredes con `for_each`, aislarás un nivel *backend* del nivel *web* con grupos de seguridad a nivel de subred y conectarás dos redes virtuales mediante *peering*. Todo el plano de red se despliega en **Topaz**; el peering lleva un interruptor por si tu versión del emulador aún no lo implementa.

**🎯 Objetivos de aprendizaje**
- Planificar un espacio de direcciones CIDR y dividirlo en subredes sin solapamientos.
- Crear varias subredes desde un `map` con `for_each` y entender por qué es preferible a `count`.
- Distinguir NSG asociado a subred de NSG asociado a NIC, y usar *service tags* y reglas `Deny` para aislar niveles.
- Conectar dos redes virtuales con peering bidireccional y saber qué requisitos tiene.
- Verificar la topología con Azure CLI y exponerla con outputs derivados de `for_each`.

> **🔷 Requisitos previos.** Páginas 1 y 2 completadas, `~/tf-intro/providers.tf` configurado para Topaz y `az account show --query environmentName -o tsv` → `Topaz`. Si dejaste recursos de la página 2, ejecuta allí `terraform destroy`: este laboratorio usa otro grupo de recursos, pero conviene empezar limpio.

---

## 3.1. Anatomía de una red virtual

```text
rg-red-001
├── vnet-app 10.0.0.0/16 ─────────────────────── peering ──────┐
│   ├── snet-web      10.0.1.0/24  ◄── nsg-web (80/443 desde Internet)
│   └── snet-backend  10.0.2.0/24  ◄── nsg-backend (8080 solo desde snet-web; resto de la vnet denegado)
│                                                              │
└── vnet-hub 10.1.0.0/16 ◄────────────────────── peering ──────┘
    └── snet-shared   10.1.1.0/24
```

| **Concepto** | **Qué es** | **Recurso Terraform** | **En Topaz** |
|---|---|---|---|
| Red virtual (VNet) | Espacio de direcciones privado y aislado. Puede tener varios rangos (`address_space` es una lista) | `azurerm_virtual_network` | ✅ |
| Subred | División del espacio de la vnet. Es la unidad a la que se asocian NSG, tablas de rutas y *service endpoints* | `azurerm_subnet` | ✅ |
| NSG | Lista de reglas permitir/denegar por prioridad, en capa 4. Se asocia a subredes o a NIC | `azurerm_network_security_group` + `azurerm_subnet_network_security_group_association` | ✅ solo reglas inline |
| Peering | Enlace privado entre dos vnets por la red troncal de Azure, sin gateways ni cifrado adicional. Siempre se declara en los dos sentidos | `azurerm_virtual_network_peering` ×2 | ⚠️ depende de la versión: interruptor `desplegar_peering` |

### Planificar las direcciones

Tres reglas que ahorran rediseños:
- **Azure reserva 5 direcciones por subred**: las cuatro primeras (red, gateway, dos de DNS) y la última (broadcast). Un `/24` da 251 IPs útiles; el mínimo permitido es `/29` (3 útiles).
- **Las vnets que vayan a conectarse por peering no pueden solaparse.** Por eso aquí `vnet-app` usa `10.0.0.0/16` y `vnet-hub` usa `10.1.0.0/16`. Reserva rangos por entorno o región desde el principio.
- **Deja hueco.** Con un `/16` caben 256 subredes `/24`; usar solo dos hoy no es desperdicio, es margen.

Terraform tiene una función para calcular subredes sin errores de aritmética: `cidrsubnet("10.0.0.0/16", 8, 1)` devuelve `10.0.1.0/24` (añade 8 bits a la máscara y toma la subred número 1). Pruébala con `terraform console`.

---

## 3.2. Preparar el directorio y las variables

```bash
mkdir -p ~/tf-red && cd ~/tf-red
cp ~/tf-intro/providers.tf .        # solo este archivo: fija azurerm ~> 4.0 y apunta a Topaz
ls                                  # providers.tf
```

```hcl
# variables.tf
variable "subredes" {
  type        = map(string)
  description = "Subredes de vnet-app: nombre lógico => prefijo CIDR"
  default = {
    web     = "10.0.1.0/24"
    backend = "10.0.2.0/24"
  }
  validation {
    condition     = alltrue([for p in values(var.subredes) : can(cidrhost(p, 0))])
    error_message = "Todos los valores deben ser CIDR válidos, como 10.0.1.0/24."
  }
}

variable "desplegar_peering" {
  type        = bool
  description = "Crear el peering entre vnet-app y vnet-hub (ponlo a false si tu Topaz no implementa virtualNetworkPeerings)"
  default     = true
}
```

Fíjate en que la clave del `map` (`web`, `backend`) es un nombre lógico, no el nombre del recurso en Azure. Ese nombre lo construiremos con `"snet-${each.key}"`. La diferencia importa cuando llegue el momento de renombrar o borrar una subred sin tocar las demás.

---

## 3.3. Red virtual y subredes con `for_each`

```hcl
# red.tf
resource "azurerm_resource_group" "red" {
  name     = "rg-red-001"
  location = "eastus"
  tags     = { entorno = "lab", gestion = "terraform" }
  lifecycle { ignore_changes = [tags] }     # Topaz no devuelve las tags del grupo
}

resource "azurerm_virtual_network" "app" {
  name                = "vnet-app"
  location            = azurerm_resource_group.red.location
  resource_group_name = azurerm_resource_group.red.name
  address_space       = ["10.0.0.0/16"]

  lifecycle {
    ignore_changes = [private_endpoint_vnet_policies]   # Topaz no devuelve este atributo
  }
}

resource "azurerm_subnet" "app" {
  for_each = var.subredes                   # una instancia por clave del map

  name                 = "snet-${each.key}"
  resource_group_name  = azurerm_resource_group.red.name
  virtual_network_name = azurerm_virtual_network.app.name
  address_prefixes     = [each.value]
}
```

| **&nbsp;** | **`count`** | **`for_each`** |
|---|---|---|
| Dirección de la instancia | `azurerm_subnet.app[0]`, `[1]`… | `azurerm_subnet.app["web"]`, `["backend"]` |
| Si borras el primer elemento | Todos los demás cambian de índice: Terraform los **destruye y recrea** | Solo desaparece esa clave; el resto no se toca |
| Cuándo usarlo | Interruptor 0/1 (como la VM de la página 2) o N copias idénticas | Colecciones con identidad propia: subredes, reglas, usuarios… |

---

## 3.4. Grupos de seguridad a nivel de subred

En la página 2 el NSG se asoció a la NIC: filtra una máquina. Asociado a la subred filtra **todo lo que haya dentro**, presente y futuro, y es la forma habitual de expresar "el nivel web acepta 80/443 de Internet; el nivel backend solo acepta 8080 desde el nivel web". Si hay NSG en ambos sitios, el tráfico entrante debe pasar los dos.

```hcl
# nsg.tf
resource "azurerm_network_security_group" "web" {
  name                = "nsg-web"
  location            = azurerm_resource_group.red.location
  resource_group_name = azurerm_resource_group.red.name

  security_rule {
    name                       = "Allow-Web-Inbound"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]       # varios puertos en una regla
    source_address_prefix      = "Internet"          # service tag: cualquier origen público
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "backend" {
  name                = "nsg-backend"
  location            = azurerm_resource_group.red.location
  resource_group_name = azurerm_resource_group.red.name

  security_rule {
    name                       = "Allow-App-From-Web"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "8080"
    source_address_prefix      = var.subredes["web"]  # solo desde 10.0.1.0/24
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Deny-VNet-Other"
    priority                   = 4000                 # después de los Allow, antes de las reglas por defecto (65000+)
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "VirtualNetwork"     # service tag: toda la vnet y las vnets con peering
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "web" {
  subnet_id                 = azurerm_subnet.app["web"].id
  network_security_group_id = azurerm_network_security_group.web.id
}

resource "azurerm_subnet_network_security_group_association" "backend" {
  subnet_id                 = azurerm_subnet.app["backend"].id
  network_security_group_id = azurerm_network_security_group.backend.id
}
```

> ⚠️ **Sin la regla `Deny`, el backend no está aislado.** Todo NSG trae tres reglas por defecto de entrada: *AllowVnetInBound* (65000), *AllowAzureLoadBalancerInBound* (65001) y *DenyAllInBound* (65500). La primera permite cualquier tráfico desde la vnet, así que una regla que solo *permite* 8080 desde web no impide que web (o cualquier otra subred) llegue al 22 del backend. La regla `Deny-VNet-Other` a prioridad 4000 es la que cierra realmente la puerta. Compruébalo en Azure real con `az network nic list-effective-nsg`.

| **Service tag** | **Significa** |
|---|---|
| `Internet` | Todo lo que no es espacio privado de Azure. Preferible a `"*"` porque documenta la intención |
| `VirtualNetwork` | El espacio de la vnet, las vnets con peering y las redes locales conectadas |
| `AzureLoadBalancer` | Sondas de estado del balanceador (168.63.129.16). No lo bloquees |
| `Storage`, `Sql`, `AzureCloud`… | Rangos públicos de servicios de Azure, mantenidos por Microsoft. Lista completa: `az network list-service-tags -l eastus` |

> **🔷 En Topaz.** Las reglas van inline porque el emulador no implementa `azurerm_network_security_rule` (página 2). La asociación subred-NSG es un `PUT` sobre la propia subred, el mismo endpoint que la crea, así que funciona. El emulador guarda las reglas y las devuelve con `az network nsg show`, pero **no evalúa tráfico**: la comprobación de que el backend está aislado solo puede hacerse en Azure real.

---

## 3.5. Peering entre redes virtuales

El original declaraba un peering hacia una `vnet2` que no existía y en un solo sentido. Un peering es un acuerdo **entre dos vnets**: hasta que ambos lados están creados, su estado es *Initiated* y no pasa tráfico. Aquí se declara la segunda vnet y las dos direcciones.

```hcl
# peering.tf
resource "azurerm_virtual_network" "hub" {
  name                = "vnet-hub"
  location            = azurerm_resource_group.red.location
  resource_group_name = azurerm_resource_group.red.name
  address_space       = ["10.1.0.0/16"]     # NO puede solaparse con 10.0.0.0/16

  lifecycle {
    ignore_changes = [private_endpoint_vnet_policies]
  }
}

resource "azurerm_subnet" "shared" {
  name                 = "snet-shared"
  resource_group_name  = azurerm_resource_group.red.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.1.1.0/24"]
}

resource "azurerm_virtual_network_peering" "app_to_hub" {
  count = var.desplegar_peering ? 1 : 0

  name                         = "peer-app-to-hub"
  resource_group_name          = azurerm_resource_group.red.name
  virtual_network_name         = azurerm_virtual_network.app.name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_virtual_network_access = true       # las VMs de una vnet ven las de la otra
  allow_forwarded_traffic      = false      # true solo si hay un NVA/firewall que reenvía
  allow_gateway_transit        = false      # true en el hub si tiene VPN/ExpressRoute gateway
  use_remote_gateways          = false      # true en los spokes que usan el gateway del hub
}

resource "azurerm_virtual_network_peering" "hub_to_app" {
  count = var.desplegar_peering ? 1 : 0

  name                         = "peer-hub-to-app"
  resource_group_name          = azurerm_resource_group.red.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.app.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = false
  allow_gateway_transit        = false
  use_remote_gateways          = false
}
```

| **Propiedad del peering** | **Consecuencia práctica** |
|---|---|
| No es transitivo | Si A↔B y B↔C, A no ve a C. Por eso la topología *hub-and-spoke* pone un firewall o router en el hub y activa `allow_forwarded_traffic` |
| Sin solapamiento | Dos vnets con rangos que se cruzan no pueden emparejarse: *VnetAddressSpaceOverlaps* |
| Funciona entre regiones y suscripciones | *Global peering* entre regiones; entre suscripciones necesitas permisos en ambas |
| Tiene coste por GB | Pequeño en la misma región, mayor entre regiones. Crear el peering no cuesta; el tráfico sí |

> **🔷 En Topaz.** La cobertura de `virtualNetworkPeerings` varía según la versión del emulador. Si el `apply` devuelve *EndpointNotFound* en `PUT .../virtualNetworkPeerings/peer-app-to-hub`, no es un error tuyo: pon `desplegar_peering = false` en `terraform.tfvars`, vuelve a aplicar y anota la limitación. El `plan` con `true` sigue siendo válido para revisar el código, igual que hicimos con la VM. Si el peering se crea pero cada `plan` propone cambios en él, añade el atributo señalado a un `ignore_changes`.

---

## 3.6. Outputs

```hcl
# outputs.tf
output "vnet_app_id" {
  description = "ID de vnet-app (lo usarán otras páginas para desplegar dentro)"
  value       = azurerm_virtual_network.app.id
}

output "subredes" {
  description = "Nombre en Azure y prefijo de cada subred de vnet-app"
  value = {
    for clave, s in azurerm_subnet.app : clave => {
      nombre  = s.name
      prefijo = s.address_prefixes[0]
      id      = s.id
    }
  }
}

output "peerings" {
  description = "IDs de los peerings, lista vacía si desplegar_peering = false"
  value = concat(
    azurerm_virtual_network_peering.app_to_hub[*].id,
    azurerm_virtual_network_peering.hub_to_app[*].id
  )
}
```

El output `subredes` recorre el recurso con `for_each` y construye un `map` nuevo: es el patrón para exponer colecciones sin enumerar cada elemento a mano. Cuando añadas una tercera subred (sección 3.7) aparecerá en el output sin tocar este archivo.

---

## 3.7. Despliegue en Topaz

```bash
ls                                                 # nsg.tf outputs.tf peering.tf providers.tf red.tf variables.tf
terraform init                                     # debe instalar azurerm v4.x; si instala 5.x falta providers.tf
terraform validate
terraform plan
#   Plan: 12 to add, 0 to change, 0 to destroy.
#   grupo, vnet-app, 2 subredes, 2 NSG, 2 asociaciones, vnet-hub, snet-shared, 2 peerings
terraform apply -auto-approve

terraform output subredes
#   {
#     "backend" = { "id" = ".../snet-backend", "nombre" = "snet-backend", "prefijo" = "10.0.2.0/24" }
#     "web"     = { "id" = ".../snet-web",     "nombre" = "snet-web",     "prefijo" = "10.0.1.0/24" }
#   }

# Verificar con la CLI
az network vnet list -g rg-red-001 --query "[].{vnet:name, espacio:addressSpace.addressPrefixes[0]}" -o table
az network vnet subnet list -g rg-red-001 --vnet-name vnet-app \
  --query "[].{subred:name, prefijo:addressPrefix, nsg:networkSecurityGroup.id}" -o table
az network nsg show -g rg-red-001 -n nsg-backend \
  --query "securityRules[].{regla:name, prio:priority, accion:access, origen:sourceAddressPrefix, puerto:destinationPortRange}" -o table
az network vnet peering list -g rg-red-001 --vnet-name vnet-app \
  --query "[].{peering:name, estado:peeringState, remota:remoteVirtualNetwork.id}" -o table

terraform plan                                     # No changes.
```

Si el último `plan` propone algún cambio, mira el atributo marcado con `~` o `+`. Con azurerm 4.x el candidato habitual en subredes es `default_outbound_access_enabled`: añádelo a un `lifecycle { ignore_changes }` del recurso `azurerm_subnet.app` y anótalo como diferencia del emulador.

### Ejercicio: añadir una subred sin tocar las existentes

```hcl
# terraform.tfvars
subredes = {
  web     = "10.0.1.0/24"
  backend = "10.0.2.0/24"
  datos   = "10.0.3.0/24"                            # nueva
}
```

```bash
terraform plan
#   + azurerm_subnet.app["datos"]
#   Plan: 1 to add, 0 to change, 0 to destroy.      ← web y backend intactas: esto es lo que aporta for_each
terraform apply -auto-approve
terraform output subredes                          # ya incluye "datos"
```

Ahora prueba la validación: cambia `"10.0.3.0/24"` por `"10.0.3.0"` y ejecuta `plan`. Falla antes de tocar el emulador con tu mensaje. Restaura el valor. Por último, quita la subred `datos` del `tfvars`: el `plan` mostrará *1 to destroy* y nada más.

```bash
terraform destroy -auto-approve                    # limpieza
az group list -o table                             # vacío
```

---

## 3.8. Qué cambia en Azure real

- `providers.tf`: quitar `metadata_host` y `resource_provider_registrations`, poner tu `subscription_id`.
- Quitar los `lifecycle { ignore_changes }` del grupo y de las dos vnets: en Azure real esos atributos se devuelven y conviene vigilarlos.
- El resto del código no cambia: reglas inline, asociaciones y peering funcionan igual. Si prefieres reglas como recursos independientes (`azurerm_network_security_rule`), es una decisión de organización, no de compatibilidad; recuerda no mezclar las dos formas sobre el mismo NSG.

```bash
az login && az account set -s "<tu suscripción>"
terraform init -reconfigure
terraform apply -auto-approve                      # Plan: 12 to add; el peering pasa a "Connected" en segundos

az network vnet peering list -g rg-red-001 --vnet-name vnet-app --query "[].peeringState" -o tsv
#   Connected

# Comprobar el aislamiento del backend (necesita una NIC dentro de snet-backend, p. ej. la VM de la página 2)
az network nic list-effective-nsg -g rg-red-001 -n <nic-en-backend> -o table

terraform destroy -auto-approve                    # las vnets no cuestan; el tráfico de peering sí
```

> ⚠️ **No cambies `address_space` a la ligera.** Ampliar el espacio de una vnet con peering activo obliga a resincronizar el peering (`az network vnet peering sync`), y reducirlo falla si alguna subred queda fuera. Terraform lo mostrará como actualización *in-place*, pero el cambio puede cortar conectividad unos segundos. Planifica los rangos con margen desde el principio (sección 3.1).

---

## 3.9. Errores comunes

> ⚠️ **Solución de problemas**
>
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | *Finding latest version of hashicorp/azurerm* e instala `v5.x` | Falta `providers.tf`. Cópialo de `~/tf-intro`, borra `.terraform/` y `.terraform.lock.hcl`, repite `init` |
> | *NetcfgInvalidSubnet* / *subnet is not within the address space* | El prefijo de la subred cae fuera del `address_space` de la vnet (p. ej. `10.1.x` en `10.0.0.0/16`). Revisa el `map` `subredes` |
> | *NetcfgSubnetRangesOverlap* | Dos subredes con rangos que se cruzan. Usa `cidrsubnet()` en `terraform console` para comprobarlos |
> | *Unsupported attribute* en `azurerm_subnet.app.id` | Con `for_each` se indexa por clave: `azurerm_subnet.app["web"].id` |
> | *The given key does not identify an element in this collection* | Referencias `app["web"]` pero la clave del `map` se llama distinto (o la has borrado del `tfvars`). El nombre lógico debe coincidir exactamente |
> | *EndpointNotFound* en `PUT .../securityRules/<nombre>` | Has usado `azurerm_network_security_rule`. En Topaz las reglas van inline en el bloque `security_rule` |
> | *EndpointNotFound* en `PUT .../virtualNetworkPeerings/<nombre>` | Tu versión de Topaz no implementa el peering: `desplegar_peering = false` en `tfvars`, vuelve a aplicar y anota la limitación |
> | *SecurityRuleConflict* / *priority already exists* | Dos reglas del mismo NSG con la misma `priority` y `direction`. Cada una debe ser única |
> | *VnetAddressSpaceOverlaps* al crear el peering | Las dos vnets comparten rango. Cambia el `address_space` de una de ellas **antes** de crear subredes |
> | Peering en estado *Initiated* y no *Connected* | Falta el peering en el sentido contrario. Siempre son dos recursos |
> | El backend acepta SSH desde web aunque solo permitiste 8080 | La regla por defecto *AllowVnetInBound* (65000) lo permite. Falta la regla `Deny` explícita a prioridad menor que 65000 |
> | *Modifying…* en vnet o subred en cada `apply`; el `plan` nunca dice *No changes* | Atributo que el emulador no devuelve (`private_endpoint_vnet_policies`, `default_outbound_access_enabled`…). Añádelo al `ignore_changes` del recurso |
> | *InUseSubnetCannotBeDeleted* en `destroy` | Hay una NIC u otro recurso dentro de la subred creado fuera de este estado. Bórralo primero (o destruye el directorio que lo creó) |

---

## 3.10. Autoevaluación

1. **¿Cuántas direcciones útiles tiene una subred `/24` en Azure y por qué?**
   251: de las 256, Azure reserva las cuatro primeras (red, gateway, dos DNS) y la última (broadcast).
2. **¿Por qué se usa `for_each` y no `count` para las subredes?**
   Con `for_each` cada subred se identifica por su clave; borrar o añadir una no altera las demás. Con `count`, eliminar el índice 0 desplaza el resto y Terraform las recrea.
3. **¿Qué diferencia hay entre asociar un NSG a una subred y a una NIC?**
   A la subred filtra todo lo que contenga, presente y futuro; a la NIC filtra una sola máquina. Si hay ambos, el tráfico entrante debe pasar los dos.
4. **¿Por qué el backend necesita una regla `Deny` explícita si solo has permitido 8080?**
   La regla por defecto *AllowVnetInBound* (65000) permite todo el tráfico de la vnet. Sin un `Deny` a prioridad menor, cualquier subred llega a cualquier puerto del backend.
5. **¿Qué es un *service tag* y qué ventaja tiene sobre un rango CIDR?**
   Un alias de rangos mantenido por Microsoft (`Internet`, `VirtualNetwork`, `Storage`…). Se actualiza solo y documenta la intención de la regla.
6. **¿Por qué el peering se declara con dos recursos?**
   Es un acuerdo entre dos vnets: cada lado declara el suyo. Con uno solo el estado queda en *Initiated* y no pasa tráfico.
7. **Si vnet-A tiene peering con vnet-B y vnet-B con vnet-C, ¿ve A a C?**
   No: el peering no es transitivo. Para ello se pone un dispositivo de red en B y se activa `allow_forwarded_traffic` (topología hub-and-spoke).
8. **¿Para qué sirve `desplegar_peering`?**
   Mismo patrón que `desplegar_vm`: hace opcional un recurso que el emulador puede no implementar, sin tocar el resto del código.

---

## 3.11. Referencias

- [`azurerm_virtual_network`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network), [`azurerm_subnet`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet), [`azurerm_network_security_group`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_security_group), [`azurerm_subnet_network_security_group_association`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet_network_security_group_association), [`azurerm_virtual_network_peering`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_network_peering)
- [Meta-argumento `for_each`](https://developer.hashicorp.com/terraform/language/meta-arguments/for_each) y [función `cidrsubnet()`](https://developer.hashicorp.com/terraform/language/functions/cidrsubnet)
- [Redes virtuales de Azure](https://learn.microsoft.com/es-es/azure/virtual-network/virtual-networks-overview) y [preguntas frecuentes (direcciones reservadas, límites)](https://learn.microsoft.com/es-es/azure/virtual-network/virtual-networks-faq)
- [Grupos de seguridad de red: reglas por defecto y evaluación](https://learn.microsoft.com/es-es/azure/virtual-network/network-security-groups-overview) y [service tags](https://learn.microsoft.com/es-es/azure/virtual-network/service-tags-overview)
- [Peering de redes virtuales](https://learn.microsoft.com/es-es/azure/virtual-network/virtual-network-peering-overview) y [topología hub-and-spoke](https://learn.microsoft.com/es-es/azure/architecture/networking/architecture/hub-spoke)
- [Azure Local Emulator (Topaz)](https://github.com/Azure/azure-local-emulator)