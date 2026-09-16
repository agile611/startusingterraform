# 🖥️ El interior de la VM: cloud-init, extensiones y Ansible (y por qué no provisioners)

## 1. Cinco formas de meter configuración en una VM

| **Mecanismo** | **Quién ejecuta / cuándo** | **Si cambia el script** | **En Topaz** |
|---|---|---|---|
| **cloud-init** (`custom_data`) | El agente de la imagen, en el primer arranque. Sin red desde fuera | **Reemplaza la VM**: `custom_data` fuerza recreación | Se envía y se planifica; no se ejecuta (no hay SO) |
| **Extensión CustomScript** | El agente de Azure, tras el arranque, cuando la extensión se crea o cambia | `update in-place`: se re-ejecuta en la misma VM | El recurso se crea; el script no corre |
| **Ansible** | El pipeline, en un paso *después* de `terraform apply`, por SSH desde el bastion | Se vuelve a ejecutar el playbook: idempotente por diseño | Solo el inventario |
| **Imagen con Packer** | Antes de Terraform: nginx ya va en la imagen | Nueva imagen → nueva VM (inmutable) | No |
| *Provisioner `remote-exec`* | Terraform, por SSH, desde la máquina que aplica, solo al crear | Nada: no se re-ejecuta ni se detecta | Falla y deja la VM *tainted* |

---

## 2. cloud-init: el primer arranque

cloud-init es un estándar que las imágenes de Ubuntu, Debian, RHEL y otras traen instalado: al arrancar por primera vez leen un documento `cloud-config` (YAML declarativo: paquetes, ficheros, usuarios, comandos) que la plataforma les entrega. En Azure ese documento viaja en `custom_data`, en base64. Terraform lo renderiza con `templatefile`, así que puede llevar variables del propio despliegue. Lo que el original llamaba cloud-init no era esto.

```yaml
# cloud-init.yaml  (la primera línea es obligatoria)
#cloud-config
package_update: true
packages: [nginx]
write_files:                                   # nada de "sudo echo > fichero": aquí se declara el fichero
  - path: /var/www/html/index.html
    permissions: "0644"
    content: |
      <h1>${titulo}</h1><p>Entorno ${entorno}</p>
runcmd:
  - systemctl enable --now nginx
```

```hcl
# vm.tf
variable "titulo"         { type = string, default = "Moodle en construcción" }
variable "ssh_public_key" { type = string }                          # TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"

resource "azurerm_network_interface" "moodle" {
  name                = "nic-moodle"
  resource_group_name = azurerm_resource_group.lab.name
  location            = azurerm_resource_group.lab.location
  ip_configuration {
    name                          = "interna"
    subnet_id                     = azurerm_subnet.s["web"].id
    private_ip_address_allocation = "Dynamic"                        # sin IP pública: se entra por el bastion o por run-command
  }
  depends_on = [azurerm_subnet_network_security_group_association.s]
}

resource "azurerm_linux_virtual_machine" "moodle" {
  name                  = "vm-moodle"
  resource_group_name   = azurerm_resource_group.lab.name
  location              = azurerm_resource_group.lab.location
  size                  = "Standard_B2s"
  admin_username        = "azureuser"
  network_interface_ids = [azurerm_network_interface.moodle.id]
  admin_ssh_key { username = "azureuser", public_key = var.ssh_public_key }
  os_disk { caching = "ReadWrite", storage_account_type = "Standard_LRS" }
  source_image_reference {                                           # 18.04 (el original) acabó soporte en 2023
    publisher = "Canonical", offer = "ubuntu-24_04-lts", sku = "server", version = "latest"
  }
  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml", {
    titulo = var.titulo, entorno = terraform.workspace
  }))                                                                # cambiarlo FUERZA REEMPLAZO: cloud-init es solo del primer arranque
  identity { type = "SystemAssigned" }                               # para leer Key Vault sin credenciales ([página 10](index.md#pagina-10))
  tags = { Role = "web" }
}
output "vm_ip_privada" { value = azurerm_linux_virtual_machine.moodle.private_ip_address }
```

La consecuencia de "solo el primer arranque" es que **cambiar el cloud-init es cambiar la VM**. Eso es correcto si la VM no guarda nada: los datos de Moodle van en MySQL flexible y los ficheros en un disco de datos o en Azure Files, y entonces reemplazar la VM cuesta minutos, no datos. Si algo vive en el disco del SO, cloud-init no es tu mecanismo para cambios posteriores; lo es la extensión o Ansible.

---

## 3. Extensión CustomScript: después del arranque, y repetible

La extensión es un recurso propio (`azurerm_virtual_machine_extension`; el `azurerm_linux_virtual_machine_extension` del original no existe) que el agente de Azure ejecuta dentro de la VM cuando se crea o cuando cambian sus settings. Sirve para lo que cloud-init no cubre: volver a ejecutar algo en una VM viva. El script va en `protected_settings` para que no aparezca en el portal ni en `az vm extension show`.

```hcl
resource "azurerm_virtual_machine_extension" "comprobar" {
  name                 = "comprobar-nginx"
  virtual_machine_id   = azurerm_linux_virtual_machine.moodle.id
  publisher            = "Microsoft.Azure.Extensions"
  type                 = "CustomScript"
  type_handler_version = "2.1"                                       # 1.10 (el original) es la versión antigua
  protected_settings = jsonencode({
    script = base64encode(file("${path.module}/comprobar.sh"))       # cambiar el fichero → update in-place → se re-ejecuta
  })
}
# comprobar.sh:  #!/bin/bash ; cloud-init status --wait ; systemctl is-active nginx || exit 1
```

---

## 4. Ansible: después de Terraform, no dentro

El original envuelve `ansible-playbook` en un `null_resource` con `local-exec`. Eso sigue siendo un provisioner: corre una vez, fuera del plan, y si el playbook cambia nadie lo nota. La integración correcta es secuencial: Terraform aplica y publica outputs; el pipeline ([página 14](index.md#pagina-14)) construye el inventario a partir de ellos y ejecuta Ansible como paso propio. Cada herramienta con su estado y su idempotencia.

```bash
# Paso del pipeline, después de terraform apply
terraform output -json | jq -r '"[web]\n" + .vm_ip_privada.value + " ansible_user=azureuser"' > inventario.ini
ansible-playbook -i inventario.ini moodle.yml \
  --ssh-common-args="-o ProxyJump=azureuser@$(terraform output -raw bastion_ip)"   # por el bastion: la VM no tiene IP pública
# Alternativa sin fichero: el plugin de inventario azure.azcollection.azure_rm filtra por tags (Role=web)
```

---

## 5. Provisioners: los problemas reales

| **El original decía** | **Lo que pasa de verdad** |
|---|---|
| "No son idempotentes; usa `|| true`" | No se re-ejecutan nunca, así que la idempotencia ni se plantea. `|| true` solo oculta el fallo: la VM queda sin nginx y Terraform la da por buena. `apt-get install -y` ya es idempotente |
| "Terraform no garantiza el orden entre provisioners" | Falso: siguen el grafo como todo lo demás. El problema es otro: lo que hacen **no está en el plan ni en el estado**. Si el resultado desaparece, ningún `plan` lo detecta |
| "Difíciles de depurar" | Cierto, y además: si fallan, el recurso queda *tainted* y el siguiente apply lo destruye y recrea. Un error de tipografía en el script cuesta una VM |
| "Riesgo de credenciales en logs" | Cierto, y el diseño lo exige: la máquina que aplica necesita una clave privada en disco y ruta de red hasta la VM (IP pública o VPN). Con cloud-init nada de eso existe |
| Alternativa: `null_resource` + Ansible/Chef | Es un provisioner con otro recurso debajo. Hereda todos los problemas anteriores |

---

## 6. Laboratorio en Topaz

Seis bloques. Reutiliza la red de la [página 6](index.md#pagina-6) (`red.tf`) y añade `vm.tf`, `cloud-init.yaml`, `comprobar.sh` y la extensión de 9.3 en `ext.tf`.

```bash
source ~/.topaz/topaz.env && az account show --query environmentName -o tsv   # Topaz
mkdir -p ~/tf-vm && cd ~/tf-vm && cp ~/tf-st/providers.tf ~/tf-deps-src/{base,red}.tf . && git init -q
[ -f ~/.ssh/id_ed25519.pub ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519 -q
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"

# ─── 1. Validar cloud-init SIN ninguna VM ───────────────────────────────────────
terraform init >/dev/null
echo 'templatefile("cloud-init.yaml", { titulo = "Prueba", entorno = "lab" })' | terraform console   # el YAML renderizado, variables sustituidas
echo 'templatefile("cloud-init.yaml", { titulo = "Prueba", entorno = "lab" })' | terraform console | sed 's/^"//;s/"$//' | sed 's/\\n/\n/g' > /tmp/ci.yaml
cloud-init schema --config-file /tmp/ci.yaml                        # Valid schema /tmp/ci.yaml
sed -i 's/packages: \[nginx\]/package: [nginx]/' cloud-init.yaml     # un error típico: clave mal escrita
echo 'templatefile("cloud-init.yaml", { titulo = "x", entorno = "x" })' | terraform console | sed 's/^"//;s/"$//;s/\\n/\n/g' > /tmp/ci.yaml
cloud-init schema --config-file /tmp/ci.yaml                        # Error: … Additional properties are not allowed ('package' was unexpected)
#   Sin este paso, el error solo aparece en /var/log/cloud-init.log de una VM que ya arrancó sin nginx. Aquí cuesta un segundo.
git checkout cloud-init.yaml 2>/dev/null || sed -i 's/package: \[nginx\]/packages: [nginx]/' cloud-init.yaml

# ─── 2. Crear la VM: el plano de control ────────────────────────────────────────
terraform apply -auto-approve
az vm show -g rg-deps -n vm-moodle --query "{imagen:storageProfile.imageReference.sku, identidad:identity.type, ip:networkProfile.networkInterfaces[0].id}" -o table
terraform state show azurerm_linux_virtual_machine.moodle | grep -E "custom_data|private_ip"
#   custom_data = (sensitive value): está en el estado (base64), pero la API no lo devuelve. Otra razón para no meter secretos ahí.
git add . && git commit -qm "vm con cloud-init"

# ─── 3. Cambiar el cloud-init: reemplazo ────────────────────────────────────────
terraform plan -var titulo="Moodle v2" | grep -E "forces replacement|Plan:"
#   ~ custom_data = (sensitive value) # forces replacement
#   Plan: 1 to add, 0 to change, 1 to destroy.   ← cloud-init es del primer arranque: cambiarlo es otra VM
#   Con create_before_destroy (página 7) y un nombre con sufijo, la nueva existiría antes de destruir la vieja.

# ─── 4. Cambiar la extensión: in-place ──────────────────────────────────────────
terraform apply -auto-approve                                        # crea la extensión (ext.tf); en Topaz no ejecuta nada
echo 'echo "comprobación ampliada"' >> comprobar.sh
terraform plan | grep -E "update in-place|forces replacement|Plan:"
#   ~ azurerm_virtual_machine_extension.comprobar: update in-place. Plan: 0 add, 1 change, 0 destroy.
#   La misma VM; en Azure real el agente volvería a ejecutar el script. Ese es el reparto: cloud-init nace con la VM, la extensión vive con ella.
terraform apply -auto-approve

# ─── 5. El provisioner, contra nadie ────────────────────────────────────────────
cat > prov.tf <<'EOF'
resource "terraform_data" "nginx_ssh" {
  triggers_replace = [azurerm_linux_virtual_machine.moodle.id]
  provisioner "remote-exec" {
    inline = ["sudo apt-get install -y nginx"]
    connection {
      type = "ssh", user = "azureuser", private_key = file("~/.ssh/id_ed25519")
      host = azurerm_linux_virtual_machine.moodle.private_ip_address, timeout = "20s"
    }
  }
}
EOF
terraform plan | grep -E "nginx_ssh|Plan:"                           # + terraform_data.nginx_ssh. Del apt-get, ni rastro: el plan no lo conoce
terraform apply -auto-approve 2>&1 | tail -4
#   Error: remote-exec provisioner error … timeout - last error: dial tcp 10.20.1.x:22: connect: … 
#   Terraform necesitaba LLEGAR a la VM. En Topaz no hay VM; en Azure real no hay IP pública. Ninguno de los cuatro mecanismos de 9.1 lo necesita.
terraform state show terraform_data.nginx_ssh | head -2              # (tainted): se destruirá y recreará en el siguiente apply
rm prov.tf && terraform apply -auto-approve

# ─── 6. El inventario de Ansible sale de los outputs ────────────────────────────
terraform output -json | jq -r '"[web]\n" + .vm_ip_privada.value + " ansible_user=azureuser"'
#   [web]
#   10.20.1.4 ansible_user=azureuser       ← lo que el pipeline pasa a ansible-playbook. Aquí acaba Terraform y empieza otra herramienta.

terraform destroy -auto-approve && cd ~ && rm -rf ~/tf-vm
```

```bash
# ─── Solo Azure real ────────────────────────────────────────────────────────────
terraform apply -auto-approve                                        # ~2 min: la VM arranca y cloud-init trabaja

# A. Comprobar el interior SIN SSH ni IP pública: run-command va por el agente de Azure
az vm run-command invoke -g rg-deps -n vm-moodle --command-id RunShellScript \
  --scripts "cloud-init status --wait; systemctl is-active nginx; curl -s localhost | head -1" \
  --query "value[0].message" -o tsv
#   status: done / active / <h1>Moodle en construcción</h1>
az vm run-command invoke -g rg-deps -n vm-moodle --command-id RunShellScript \
  --scripts "sudo tail -5 /var/log/cloud-init-output.log" --query "value[0].message" -o tsv   # dónde mirar si algo falló

# B. La extensión: sus logs y su re-ejecución
az vm extension list -g rg-deps --vm-name vm-moodle --query "[].{ext:name, estado:provisioningState}" -o table
az vm run-command invoke -g rg-deps -n vm-moodle --command-id RunShellScript \
  --scripts "sudo cat /var/lib/waagent/custom-script/download/*/stdout" --query "value[0].message" -o tsv
echo 'echo "otra vez"' >> comprobar.sh && terraform apply -auto-approve   # update in-place: el agente ejecuta el nuevo script en la misma VM

# C. Cambiar el título: reemplazo observado
terraform apply -auto-approve -var titulo="Moodle v2"                # -/+ : destruye y crea; ~3 min de corte. Con create_before_destroy + random_id: segundos.
az vm run-command invoke -g rg-deps -n vm-moodle --command-id RunShellScript --scripts "curl -s localhost" --query "value[0].message" -o tsv

# D. Ansible desde fuera, por el bastion (requiere el bastion condicional de la página 6 con crear_bastion=true)
terraform output -json | jq -r '"[web]\n" + .vm_ip_privada.value + " ansible_user=azureuser"' > inventario.ini
ansible -i inventario.ini web -m ping --ssh-common-args="-o ProxyJump=azureuser@$(terraform output -raw bastion_ip)"
ansible-playbook -i inventario.ini moodle.yml --ssh-common-args="-o ProxyJump=azureuser@$(terraform output -raw bastion_ip)"
ansible-playbook … 2>&1 | grep -E "changed=0"                        # segunda pasada: changed=0. Eso es idempotencia, no "|| true".

# E. Imagen con Packer (mención): packer build moodle.pkr.hcl → Azure Compute Gallery → source_image_id en la VM.
#    Arranque en segundos, sin apt-get en producción. Se ve en la página 13.

terraform destroy -auto-approve
```

---

## 7. Errores comunes

> ⚠️ **Solución de problemas**
>
> | **Mensaje o síntoma** | **Causa y solución** |
> |---|---|
> | `azurerm_linux_virtual_machine_extension` (el original) | No existe. `azurerm_virtual_machine_extension`, y no es cloud-init: cloud-init va en `custom_data` |
> | "cloud-init" con `commandToExecute` (el original) | Eso es CustomScript: otro ejecutor (el agente de Azure), otro momento (tras el arranque) y otro comportamiento (se re-ejecuta al cambiar). cloud-init es un documento `cloud-config` en `custom_data` que la imagen procesa en el primer arranque (9.1) |
> | cloud-init "no hizo nada" y no hay error | Falta la primera línea `#cloud-config`: sin ella el contenido se ignora. O `custom_data` no está en base64. Valida antes con `cloud-init schema` (bloque 1) y mira `/var/log/cloud-init-output.log` (bloque A) |
> | `Additional properties are not allowed` en `cloud-init schema` | Clave mal escrita (`package` por `packages`, `run_cmd` por `runcmd`). El validador local lo dice en un segundo; la VM lo callaría |
> | "Cambié el cloud-init y Terraform quiere destruir la VM" | Es lo esperado: `custom_data` fuerza reemplazo (bloque 3). Si la VM no guarda datos, acéptalo y añade `create_before_destroy`; si los guarda, el cambio posterior va en la extensión o en Ansible, no en cloud-init |
> | Datos perdidos al reemplazar la VM | Algo vivía en el disco del SO. Los datos de Moodle van en MySQL flexible y `moodledata` en Azure Files o un disco de datos con `azurerm_virtual_machine_data_disk_attachment`: sobreviven al reemplazo |
> | Secreto en `custom_data` o en `settings` de la extensión | Queda en el estado y (en la extensión) visible en el portal. Secretos en Key Vault, leídos desde la VM con su identidad administrada ([página 10](index.md#pagina-10)); si hay que pasar algo a la extensión, `protected_settings` |
> | `sudo echo "…" > /var/www/html/index.html` (el original) | El `sudo` aplica al `echo`; la redirección la hace la shell sin privilegios y falla. En cloud-init, `write_files`; en un script, `echo … | sudo tee fichero` |
> | `UbuntuServer / 18.04-LTS` (el original) | Fin de soporte en 2023: la imagen puede no existir y no recibe parches. `ubuntu-24_04-lts / server`. `az vm image list -p Canonical --all` para ver las vigentes |
> | `type_handler_version = "1.10"` (el original) | Versión antigua de CustomScript para Linux. `2.1` con `Microsoft.Azure.Extensions` |
> | `host = azurerm_linux_virtual_machine.example.public_ip_address` dentro de la propia VM (el original) | Autorreferencia: ciclo en el grafo. Dentro de un provisioner se usa `self.`. Y la VM del curso no tiene IP pública: nada que referenciar |
> | `|| true` para "hacer idempotente" un provisioner (el original) | Oculta el fallo: Terraform da la VM por buena sin nginx. `apt-get install -y` ya es idempotente. Si un comando puede fallar legítimamente, que falle y se vea |
> | `remote-exec provisioner error … timeout … dial tcp` | Terraform no llega a la VM: no hay IP pública, el NSG no abre el 22, o (en Topaz) no hay VM. Es el motivo de fondo para no usarlo: ninguno de los cuatro mecanismos de 9.1 necesita llegar (bloque 5) |
> | VM *tainted* tras un apply | Un provisioner falló; el siguiente apply destruye y recrea la VM entera. Quita el provisioner, aplica, y mueve la lógica a cloud-init o a la extensión |
> | `null_resource` + `local-exec` con `ansible-playbook` (el original) | Provisioner disfrazado: corre una vez, fuera del plan. Ansible como paso del pipeline después del apply, con inventario de `terraform output` (9.4) |
> | Ansible no llega a la VM | Sin IP pública hace falta salto: `--ssh-common-args="-o ProxyJump=azureuser@<bastion>"`, o el plugin de inventario `azure_rm` con Azure Bastion y túnel |
> | `az vm run-command invoke` tarda o devuelve vacío | Va por el agente: puede tardar un minuto y se cola detrás de la extensión. Si la VM acaba de arrancar, `cloud-init status --wait` al principio del script |
> | `terraform-aws-modules/terraform-aws-nginx` (el original) | No existe, y sería de AWS. Los módulos empaquetan recursos ([página 8](index.md#pagina-8)), no instalan software: eso lo hace lo que el módulo ponga en `custom_data` |
> | "Run commands de Terraform Cloud" como alternativa (el original) | No existen como tal. HCP Terraform ejecuta plan/apply; el interior de la VM lo hacen cloud-init, extensiones, Ansible o Packer, igual que en local |
> | Intentar ver el resultado de cloud-init en Topaz | El emulador crea el recurso VM pero no arranca un SO: nada se ejecuta. Lo que sí se comprueba en Topaz es la plantilla renderizada, el esquema y qué cambio fuerza reemplazo (bloques 1–4); el resto en Azure real |

---

## 8. Autoevaluación

1. **¿Qué diferencia a cloud-init de la extensión CustomScript?**
   cloud-init lo ejecuta la imagen en el primer arranque desde `custom_data`; la extensión la ejecuta el agente de Azure después, y se repite si cambia. Cambiar el primero reemplaza la VM; cambiar la segunda es un `update in-place`.
2. **¿Por qué cambiar `custom_data` fuerza reemplazo, y cuándo es aceptable?**
   Porque solo se procesa una vez, al nacer la VM. Es aceptable si la VM no guarda datos: MySQL y `moodledata` fuera del disco del SO.
3. **¿Cómo se valida un cloud-init sin arrancar ninguna VM?**
   `terraform console` con `templatefile` para renderizarlo, y `cloud-init schema --config-file` para comprobar el esquema.
4. **¿Qué hace la primera línea `#cloud-config`?**
   Identifica el documento. Sin ella, cloud-init ignora el contenido en silencio.
5. **¿Por qué `sudo echo "x" > fichero` no funciona?**
   La redirección la hace la shell del usuario sin privilegios. En cloud-init, `write_files`; en scripts, `tee`.
6. **¿Dónde va un script que la extensión debe ejecutar si contiene algo sensible?**
   En `protected_settings`: no aparece en el portal ni en `az vm extension show`. Y mejor aún, sin secretos: Key Vault con identidad administrada.
7. **¿Cómo se integra Ansible con Terraform en este curso?**
   Secuencialmente: Terraform aplica y publica outputs; el pipeline construye el inventario y ejecuta el playbook como paso propio. Nunca dentro de un `null_resource`.
8. **¿Cómo se comprueba el interior de una VM sin IP pública ni SSH?**
   `az vm run-command invoke --command-id RunShellScript`: va por el agente de Azure, no por la red.
9. **¿Por qué `|| true` no hace idempotente un provisioner?**
   Los provisioners no se re-ejecutan, así que la idempotencia no aplica; `|| true` solo oculta el fallo y deja la VM mal configurada y "correcta" para Terraform.
10. **¿Es cierto que Terraform no garantiza el orden entre provisioners?**
    No: siguen el grafo. El problema real es que lo que hacen no está en el plan ni en el estado, y que si fallan dejan el recurso tainted.
11. **¿Qué necesita un `remote-exec` que ningún otro mecanismo necesita?**
    Que la máquina que aplica llegue por SSH a la VM: IP pública o VPN, puerto 22 abierto y clave privada en disco.
12. **¿Qué se puede observar de esta página en Topaz y qué no?**
    Sí: la plantilla renderizada, la validación del esquema, qué cambio fuerza reemplazo y cuál es in-place, y un provisioner fallando. No: nada que requiera un sistema operativo arrancado.

---

## 9. Referencias

- [cloud-init en máquinas virtuales Linux de Azure](https://learn.microsoft.com/es-es/azure/virtual-machines/linux/using-cloud-init) y [solución de problemas de cloud-init](https://learn.microsoft.com/es-es/azure/virtual-machines/linux/cloud-init-troubleshooting) (Microsoft Learn)
- [Referencia de módulos `cloud-config`](https://cloudinit.readthedocs.io/en/latest/reference/modules.html) (`packages`, `write_files`, `runcmd`) y [validar user-data con `cloud-init schema`](https://cloudinit.readthedocs.io/en/latest/howto/debug_user_data.html)
- [`azurerm_linux_virtual_machine`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/linux_virtual_machine): `custom_data`, `admin_ssh_key`, `identity`
- [`azurerm_virtual_machine_extension`](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs/resources/virtual_machine_extension) y [Custom Script Extension para Linux (v2)](https://learn.microsoft.com/es-es/azure/virtual-machines/extensions/custom-script-linux)
- [`templatefile`](https://developer.hashicorp.com/terraform/language/functions/templatefile) y [`terraform console`](https://developer.hashicorp.com/terraform/cli/commands/console) (HashiCorp)
- [Provisioners: un último recurso](https://developer.hashicorp.com/terraform/language/resources/provisioners/syntax) y [`remote-exec`](https://developer.hashicorp.com/terraform/language/resources/provisioners/remote-exec)
- [Run Command en VMs Linux](https://learn.microsoft.com/es-es/azure/virtual-machines/linux/run-command) (`az vm run-command invoke`)
- [Plugin de inventario `azure_rm`](https://docs.ansible.com/ansible/latest/collections/azure/azcollection/azure_rm_inventory.html) y [conexión SSH y `ProxyJump`](https://docs.ansible.com/ansible/latest/inventory_guide/connection_details.html) (Ansible)
- [Packer: builder de Azure](https://developer.hashicorp.com/packer/integrations/hashicorp/azure) y [Azure Compute Gallery](https://learn.microsoft.com/es-es/azure/virtual-machines/azure-compute-gallery)
- [Buscar imágenes de VM (`az vm image list`)](https://learn.microsoft.com/es-es/azure/virtual-machines/linux/cli-ps-findimage)
- [Azure Local Emulator (Topaz)](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)