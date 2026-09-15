# 🔧 Declarativo frente a imperativo con una máquina virtual, y qué pasa cuando algo falla

## 1. Qué es Topaz y qué no es

Azure Local Emulator —nombre en clave Topaz— es un contenedor que implementa la
API de Azure Resource Manager y el plano de datos de algunos servicios. Cuando
Terraform o `az` le envían un *PUT* de una máquina virtual, Topaz valida la
petición, guarda el recurso y responde como respondería Azure.

Eso es todo, y es mucho: es exactamente lo que Terraform necesita para
planificar, aplicar, guardar estado y detectar deriva.

| Sí hace | No hace | Dónde se hace de verdad |
|---|---|---|
| Aceptar, guardar y devolver recursos ARM: grupos, redes, storage, Key Vault y otros según versión. | Arrancar una máquina: no hay CPU, ni disco, ni SSH al que conectarse. | Azure real —bloque final de cada laboratorio—. |
| Plano de datos de storage —blobs, tablas, colas— y de Key Vault —secretos—. | Métricas, logs, costes: no hay Azure Monitor ni Cost Management. | Azure Monitor —[página 17](index.md#pagina-17)—; Infracost sobre el plan para estimar coste sin desplegar —[página 18](index.md#pagina-18)—. |
| Lo que este curso necesita: plan, apply, estado, deriva, módulos, import, pipelines. | Inyección de fallos: no hay "Chaos Engineering". | Azure Chaos Studio, sobre recursos reales. |
| Responder sin coste, sin suscripción y sin riesgo de borrar algo real. | Evaluar RBAC, Azure Policy ni bloqueos en las peticiones. | Azure real —[páginas 12](index.md#pagina-12) y 15—. |

Lo que sí se puede "romper" en Topaz es la plataforma misma: parar el contenedor
en mitad de un despliegue equivale a un corte de red o una caída de ARM. Es el
fallo que interesa en esta práctica.

## 2. La misma máquina, imperativa

Cinco comandos en el orden correcto. Fíjate en tres cosas: el orden lo sabes
tú; cada comando necesita el nombre exacto de lo que creó el anterior; y si el
tercero falla, el script se detiene con dos recursos creados y ninguna memoria
de ello.

```bash
#!/usr/bin/env bash

# crear-vm.sh: una VM y su red, paso a paso.
# El orden es responsabilidad de quien escribe el script.

set -euo pipefail

RG=rg-practica-script
LOC=eastus

az group create \
  -n $RG \
  -l $LOC \
  -o none

az network vnet create \
  -g $RG \
  -n vnet-moodle \
  --address-prefix 10.10.0.0/16 \
  --subnet-name snet-web \
  --subnet-prefix 10.10.1.0/24 \
  -o none

az network nsg create \
  -g $RG \
  -n nsg-web \
  -o none

az network nsg rule create \
  -g $RG \
  --nsg-name nsg-web \
  -n permitir-https \
  --priority 100 \
  --destination-port-ranges 443 \
  --access Allow \
  --protocol Tcp \
  -o none

az network nic create \
  -g $RG \
  -n nic-moodle \
  --vnet-name vnet-moodle \
  --subnet snet-web \
  --network-security-group nsg-web \
  -o none

az vm create \
  -g $RG \
  -n vm-moodle \
  --nics nic-moodle \
  --image Ubuntu2404 \
  --size Standard_B2s \
  --admin-username moodle \
  --ssh-key-values ~/.ssh/moodle-lab.pub \
  --authentication-type ssh \
  -o none

echo "hecho"

# Segunda ejecución: los "create" de red son PUT idempotentes y pasan;
# az vm create devuelve error porque ya existe.
# El script muere en la última línea.
#
# Cambiar el tamaño de la VM: otro comando (az vm resize), y saber que existe.
# Quitar el NSG: otro comando, y acordarse de desasociarlo antes.
```

## 3. La misma máquina, declarativa

Los mismos cinco recursos. No hay orden escrito: cada referencia
—`azurerm_subnet.web.id`— es una arista del grafo, y Terraform deduce que la
interfaz va después de la subred y la máquina después de la interfaz. Puedes
desordenar los bloques y el plan es idéntico.

```hcl
# main.tf: el provider está en providers.tf (página 3).
# Nunca credenciales aquí.

resource "azurerm_resource_group" "lab" {
  name     = "rg-practica-tf"
  location = "eastus"
}

resource "azurerm_virtual_network" "moodle" {
  name                = "vnet-moodle"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  address_space       = ["10.10.0.0/16"]
}

resource "azurerm_subnet" "web" {
  name                 = "snet-web"
  resource_group_name  = azurerm_resource_group.lab.name
  virtual_network_name = azurerm_virtual_network.moodle.name
  address_prefixes     = ["10.10.1.0/24"]
}

resource "azurerm_network_security_group" "web" {
  name                = "nsg-web"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location

  security_rule {
    name                       = "permitir-https"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "web" {
  subnet_id                 = azurerm_subnet.web.id
  network_security_group_id = azurerm_network_security_group.web.id
}

resource "azurerm_network_interface" "moodle" {
  name                = "nic-moodle"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location

  ip_configuration {
    name                          = "interna"
    subnet_id                     = azurerm_subnet.web.id # esta línea es el orden
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "moodle" {
  name                            = "vm-moodle"
  resource_group_name             = azurerm_resource_group.lab.name
  location                        = azurerm_resource_group.lab.location
  size                            = "Standard_B2s"
  admin_username                  = "moodle"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.moodle.id]

  admin_ssh_key {
    username   = "moodle"
    public_key = file("~/.ssh/moodle-lab.pub")
    # La clave privada no toca el código ni el estado.
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}
```

!!! danger "⚠️ Sobre el código original"
    `azurerm_virtual_machine` es el recurso antiguo —2019—; el actual es
    `azurerm_linux_virtual_machine`, con otra estructura. Ubuntu 18.04 dejó de
    recibir soporte en 2023.

    Y una contraseña escrita en `os_profile` acaba en Git y en el estado: la
    [página 10](index.md#pagina-10) explica por qué eso es un incidente, no un descuido. Aquí la
    máquina solo admite clave SSH.

## 4. Comparación: dónde vive cada cosa

| Aspecto | Script —imperativo— | Terraform —declarativo— |
|---|---|---|
| **Orden de creación** | En la cabeza de quien escribe; en el fichero, como secuencia. | Deducido de las referencias; los bloques pueden ir en cualquier orden. |
| **Segunda ejecución** | Depende de cada comando: los PUT pasan, los create estrictos fallan. | *No changes*. |
| **Fallo en el tercer recurso** | Dos recursos creados, sin registro. Reanudar exige saber cuáles y editar el script o borrarlos a mano. | Dos recursos en el estado; el siguiente `apply` planifica solo los tres que faltan. |
| **Cambio de tamaño** | Otro comando —`az vm resize`— que hay que escribir y ejecutar. | Editar `size`; el plan dice `~ update in-place`. |
| **Alguien borra la interfaz a mano** | Nadie lo sabe hasta que algo falla. | El plan la muestra como `+ create`, y la VM como cambio, porque su referencia cambió. |
| **Borrar todo** | Otro script, en orden inverso, o `az group delete` con todo lo que hubiera dentro. | `terraform destroy`: solo lo suyo, en orden inverso al grafo. |
| **Cuándo es la herramienta correcta** | Procesos: comprobaciones, puertas, instalación dentro de la VM. | Estado: lo que debe existir de una forma concreta y seguir así. |

## 5. Laboratorio en Topaz

Cuatro bloques: el script dos veces; la declaración dos veces; el fallo a medias
en ambos —parando el contenedor de Topaz desde otra terminal o con un
temporizador—; y la deriva sobre la interfaz.

Si tu versión de Topaz no acepta `Microsoft.Compute`, comenta el bloque de la
VM y la última línea del script: todo lo demás funciona igual, y la máquina se
prueba en el bloque de Azure real.

```bash
# Topaz. Si dice AzureCloud, para.
az account show --query environmentName -o tsv

TOPAZ=$(docker ps --format '{{.Names}}' | grep -i topaz | head -1)
echo "contenedor: $TOPAZ"

[ -f ~/.ssh/moodle-lab ] ||
  ssh-keygen \
    -t ed25519 \
    -f ~/.ssh/moodle-lab \
    -N "" \
    -C moodle-lab

mkdir -p ~/tf-practica1 &&
  cd ~/tf-practica1 &&
  cp ~/tf-st/providers.tf .

# Guarda aquí el crear-vm.sh de P.2 y el main.tf de P.3.

# ─── 1. Script, dos veces ────────────────────────────────────────────────────────
chmod +x crear-vm.sh &&
  time ./crear-vm.sh

# Hecho.
./crear-vm.sh
echo "salida: $?"

# Los create de red pasan (PUT);
# az vm create: "already exists" (o pasa, según versión).
# Anota qué ocurre.
az resource list \
  -g rg-practica-script \
  --query "[].{tipo:type, nombre:name}" \
  -o table

# ─── 2. Declaración, dos veces ───────────────────────────────────────────────────
terraform init >/dev/null &&
  terraform validate

# Plan: 7 to add —incluye la asociación NSG-subred—.
terraform plan -out=plan.tfplan
terraform apply plan.tfplan

# No changes.
terraform plan

# Número de aristas: el orden que el script llevaba escrito,
# aquí deducido.
terraform graph |
  grep -c -- '->'

# La declaración es más larga.
# La longitud no era la ventaja.
wc -l crear-vm.sh main.tf

# ─── 3. Fallo a medias: parar la plataforma durante el despliegue ────────────────

# 3a. Script.
# Se borra todo y se relanza con Topaz cayendo a los pocos segundos.
az group delete \
  -n rg-practica-script \
  --yes \
  2>/dev/null

# El "corte de red" llega en 4 segundos.
# Ajusta el tiempo al ritmo de tu máquina.
(
  sleep 4
  docker stop "$TOPAZ"
) &

./crear-vm.sh
echo "salida: $?"

# Muere en el comando que estuviera en curso:
# connection refused.
docker start "$TOPAZ" &&
  sleep 5

# Lo que llegó a crearse.
# El script no lo sabe: no tiene memoria.
az resource list \
  -g rg-practica-script \
  --query "[].name" \
  -o tsv

./crear-vm.sh
echo "salida: $?"

# Al relanzar, los PUT pasan.
# Si la VM llegó a crearse, falla.
# Hay que leer el error y decidir a mano.

# 3b. Terraform. Mismo corte.
terraform destroy -auto-approve >/dev/null

(
  sleep 4
  docker stop "$TOPAZ"
) &

terraform apply -auto-approve
echo "salida: $?"

# Error: … connection refused.
# Apply parcial.
docker start "$TOPAZ" &&
  sleep 5

# Lo que llegó a crearse ESTÁ EN EL ESTADO:
# Terraform sí tiene memoria.
terraform state list

# Plan: N to add —solo lo que falta.
# Ninguna decisión manual.
terraform plan

terraform apply -auto-approve &&
  terraform plan

# Completo; No changes.
#
# Si algún recurso quedó "tainted" —creado pero sin confirmar—,
# el plan lo marca para reemplazo: es Terraform siendo prudente
# con lo que no pudo verificar.

# ─── 4. Deriva sobre un recurso intermedio ───────────────────────────────────────
# "Alguien" borra la interfaz desde fuera.
# En Topaz no hay VM que lo impida.
az network nic delete \
  -g rg-practica-tf \
  -n nic-moodle

# + azurerm_network_interface.moodle (create)
# y ~ o -/+ en la VM: su referencia cambió.
terraform plan

# El plan no solo detecta el hueco: sabe qué depende de él.
# El script no habría sabido ni que faltaba.
terraform apply -auto-approve &&
  terraform plan

# No changes.

# ─── 5. Limpiar ──────────────────────────────────────────────────────────────────
# En orden inverso al grafo:
# VM, NIC, asociación, NSG, subred, VNet, grupo.
terraform destroy -auto-approve

az group delete \
  -n rg-practica-script \
  --yes \
  --no-wait

cd ~ &&
  rm -rf ~/tf-practica1
```

### Solo Azure real

```bash
# ─── Solo Azure real ─────────────────────────────────────────────────────────────

# A. La máquina existe de verdad: arranca, tiene IP, acepta SSH.
# Añade una IP pública al main.tf o usa Bastion; página 8.
terraform apply &&
  az vm get-instance-view \
    -g rg-practica-tf \
    -n vm-moodle \
    --query "instanceView.statuses[].displayStatus" \
    -o tsv

# Provisioning succeeded, VM running.
ssh -i ~/.ssh/moodle-lab moodle@<ip> uptime

# B. Lo que el original llamaba "FinOps":
# coste estimado ANTES de desplegar, sobre el plan.
infracost breakdown \
  --path . \
  --terraform-plan-flags "-var-file=envs/dev.tfvars"

# Standard_B2s + disco: euros/mes, sin tocar Azure —página 18—.
az consumption usage list \
  --start-date $(date -d '-7 days' +%F) \
  --end-date $(date +%F) \
  --query "[?contains(instanceName,'vm-moodle')].{recurso:instanceName, coste:pretaxCost}" \
  -o table

# Lo real, con retraso de horas.

# C. Lo que el original llamaba "Chaos":
# Azure Chaos Studio, sobre la VM real.
az extension add -n chaos 2>/dev/null

az rest \
  -m put \
  -u "$(terraform output -raw vm_id)/providers/Microsoft.Chaos/targets/Microsoft-VirtualMachine?api-version=2024-01-01" \
  -b '{"properties":{}}'

# Registrar la VM como objetivo.
az rest \
  -m put \
  -u "$(terraform output -raw vm_id)/providers/Microsoft.Chaos/targets/Microsoft-VirtualMachine/capabilities/Shutdown-1.0?api-version=2024-01-01" \
  -b '{"properties":{}}'

# El experimento —apagar la VM 5 minutos— se define como recurso
# azurerm_chaos_studio_experiment y se lanza con:
#
# az chaos experiment start
#
# Lo que se aprende: una VM sola no es resiliente por mucho IaC que la cree.
# La resiliencia es arquitectura —zonas, VMSS, count = 2 detrás de un
# balanceador—, y IaC hace que esa arquitectura sea reproducible.

# D. Observabilidad real: métricas de la VM.
az monitor metrics list \
  --resource "$(terraform output -raw vm_id)" \
  --metric "Percentage CPU" \
  --interval PT5M \
  -o table

# Esto es lo que Topaz no tiene ni puede tener.
```

## 6. Actividad para entregar

1. **Los dos ficheros.** `crear-vm.sh` y `main.tf`, con los cambios que hayas
   necesitado para tu versión de Topaz, comentados.

2. **El registro del bloque 3.** Salida de `az resource list` tras el corte en
   el script, y de `terraform state list` y `terraform plan` tras el corte en
   Terraform. Una frase: qué sabía cada herramienta al reanudar.

3. **El plan del bloque 4.** Pega las líneas `+`, `~` o `-/+` y explica por qué
   la VM aparece en el plan si solo se borró la interfaz.

4. **Reordena `main.tf`** poniendo la VM como primer bloque y el grupo de
   recursos como último. Ejecuta `terraform plan` y explica el resultado en una
   línea.

5. **Dos mejoras de resiliencia** para esta infraestructura, expresadas como
   cambios de HCL —no como texto—: por ejemplo, zona de disponibilidad, o
   `count = 2` con lo que eso arrastra. No hace falta aplicarlas; sí que
   `terraform validate` pase.

6. **Informe de una página** con la tabla de P.4 rellena con tus observaciones
   reales, no con las de la página.

## 7. Errores comunes

!!! danger
    | Mensaje o síntoma | Causa y solución |
    |---|---|
    | Buscar el dashboard "FinOps" o "Chaos" de Topaz —el original—. | No existen. Topaz emula el plano de control; coste con Infracost sobre el plan, caos con Chaos Studio en Azure real —bloques B y C—. |
    | `azurerm_virtual_machine` con `storage_image_reference` —el original—. | Recurso antiguo. `azurerm_linux_virtual_machine` con `source_image_reference`, `os_disk` y `admin_ssh_key`. |
    | `admin_password` en el código —el original—. | Queda en Git y en el estado. Clave SSH con `disable_password_authentication = true`; si hace falta contraseña, `random_password` a Key Vault —[página 10](index.md#pagina-10)—. |
    | `Error: Missing required argument "ip_configuration"` en la NIC —el original—. | Una interfaz sin configuración IP ni subred no es válida; y sin VNet no hay dónde ponerla. El `main.tf` de P.3 tiene la red completa. |
    | `client_secret` en el bloque `provider` —FAQ del original—. | Nunca. En local, `az login` y el provider lo usa; en el pipeline, OIDC sin secretos —[página 12](index.md#pagina-12)—. Un secreto en `provider` acaba en Git. |
    | El corte del bloque 3 llega demasiado tarde o demasiado pronto. | El `sleep 4` depende de la máquina. Ajusta el valor hasta que el corte caiga entre el segundo y el cuarto recurso; o usa dos terminales y para el contenedor a mano al ver el segundo "Creating…". |
    | `Error acquiring the state lock` tras el corte. | Con estado local no ocurre; con backend remoto —[página 4](index.md#pagina-4)—, el bloqueo quedó huérfano. `terraform force-unlock <id>` tras comprobar que no hay otro apply en marcha. |
    | Un recurso aparece como *tainted* tras el corte. | Terraform lo creó pero no pudo confirmar la respuesta. Lo reemplaza en el siguiente apply; si sabes que quedó bien, `terraform untaint <dirección>`. |
    | En Topaz: la VM devuelve un error de tipo o proveedor no soportado. | Tu versión no emula `Microsoft.Compute`. Comenta el bloque de la VM y la línea de `az vm create`; los bloques 1 a 4 funcionan con la red; la máquina va al bloque A de Azure real. |
    | "La declaración tiene más líneas: el script es mejor". | La longitud no era la comparación. Compara qué pasa la segunda vez, tras un fallo a medias y tras una deriva —bloques 2 a 4—. |
    | "Terraform hace la infraestructura resiliente". | Hace resiliente el *proceso* de crearla —reanudación, deriva—. La resiliencia de la máquina es arquitectura: zonas, réplicas, balanceador; IaC la hace reproducible, no la inventa. |

## 8. Autoevaluación

1. **¿Qué emula Topaz y qué no?**

    El plano de control de ARM y algunos planos de datos: acepta y guarda
    recursos. No ejecuta máquinas, no mide, no factura, no inyecta fallos, no
    evalúa RBAC ni políticas.

2. **¿Dónde está el orden de creación en cada enfoque?**

    En el script, en la secuencia escrita por una persona. En Terraform, en las
    referencias entre recursos, de las que se deduce el grafo.

3. **Tras un fallo a medias, ¿qué sabe cada herramienta?**

    El script, nada: no tiene memoria. Terraform tiene en el estado lo que llegó
    a crear y planifica solo lo que falta; lo que no pudo confirmar lo marca
    como *tainted* y lo reemplaza.

4. **¿Por qué la VM aparece en el plan si solo se borró la interfaz?**

    Porque `network_interface_ids` referencia la interfaz: al recrearla, su ID
    cambia y la VM tiene que actualizarse. El plan conoce las dependencias, no
    solo los huecos.

5. **¿Qué pasa al ejecutar el script dos veces?**

    Depende de cada comando: los `create` de red son PUT y pasan;
    `az vm create` falla porque ya existe. La idempotencia hay que construirla
    comando a comando.

6. **¿Qué pasa al reordenar los bloques de `main.tf`?**

    Nada: el plan es idéntico. El orden lo dan las referencias, no la posición
    en el fichero.

7. **¿Por qué no hay contraseña en el código?**

    Acabaría en Git y en el estado. La VM admite solo clave SSH; la privada
    nunca toca ni el código ni el estado.

8. **¿Qué diferencia hay entre `azurerm_virtual_machine` y
   `azurerm_linux_virtual_machine`?**

    El primero es el recurso antiguo, genérico; el segundo es el actual, con
    estructura propia —`admin_ssh_key`, `os_disk`, `source_image_reference`— y
    sin contraseña obligatoria.

9. **¿Cómo se estima el coste sin desplegar?**

    Infracost sobre el plan: convierte tamaños y SKUs en euros/mes. Lo real lo
    da Cost Management con horas de retraso, solo en Azure real.

10. **¿Dónde se prueba de verdad la resiliencia de la máquina?**

    En Azure real con Chaos Studio. Y lo que se aprende es que una VM sola no
    es resiliente: la resiliencia es arquitectura, e IaC la hace reproducible.

11. **¿Qué tipo de resiliencia sí demuestra el laboratorio en Topaz?**

    La del proceso: reanudar un despliegue interrumpido sin decisiones manuales
    y corregir una deriva conociendo sus dependencias.

12. **¿Por qué el destroy borra en un orden concreto?**

    Recorre el grafo al revés: VM, interfaz, asociación, NSG, subred, VNet,
    grupo. Es el orden inverso que el script tendría que escribir a mano.

## 9. Referencias

- [Azure Local Emulator —Topaz—](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md):
  lista de proveedores emulados por versión.
- [`azurerm_linux_virtual_machine`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/linux_virtual_machine),
  [`azurerm_network_interface`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/network_interface)
  y
  [`azurerm_subnet_network_security_group_association`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/subnet_network_security_group_association).
- [Dependencias entre recursos](https://developer.hashicorp.com/terraform/language/resources/behavior#resource-dependencies)
  y
  [`terraform graph`](https://developer.hashicorp.com/terraform/cli/commands/graph)
  —HashiCorp—.
- [Recursos *tainted*](https://developer.hashicorp.com/terraform/cli/commands/taint)
  y
  [`force-unlock`](https://developer.hashicorp.com/terraform/cli/commands/force-unlock).
- [`az vm create`](https://learn.microsoft.com/es-es/cli/azure/vm#az-vm-create)
  e
  [imágenes de Ubuntu en Azure](https://learn.microsoft.com/es-es/azure/virtual-machines/linux/cli-ps-findimage)
  —Microsoft Learn—.
- [Infracost](https://www.infracost.io/docs/)
  —coste estimado sobre el plan—.
- [Azure Chaos Studio](https://learn.microsoft.com/es-es/azure/chaos-studio/chaos-studio-overview)
  y
  [`azurerm_chaos_studio_experiment`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/chaos_studio_experiment).
- [Métricas de máquinas virtuales en Azure Monitor](https://learn.microsoft.com/es-es/azure/azure-monitor/essentials/metrics-supported#microsoftcomputevirtualmachines).