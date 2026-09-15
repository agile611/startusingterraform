# Terraform con Azure

Esta carpeta contiene el recorrido completo del curso para aprender **Terraform aplicado a Azure**. El material parte de los conceptos de infraestructura como código, construye un entorno de prácticas local con el emulador **Topaz** y Docker, y avanza hasta el uso profesional del estado remoto, los módulos, la seguridad y los pipelines de CI/CD.

> **Objetivo del curso:** ser capaz de describir, validar, desplegar, operar y proteger infraestructura en Azure de manera reproducible con Terraform.

## Índice rápido

- [Alcance y resultados de aprendizaje](#alcance-y-resultados-de-aprendizaje)
- [Requisitos previos](#requisitos-previos)
- [Entorno de prácticas](#entorno-de-prácticas)
- [Itinerario del curso](#itinerario-del-curso)
- [Bloques del curso](#bloques-del-curso)
- [Guía de trabajo recomendada](#guía-de-trabajo-recomendada)
- [Comandos esenciales](#comandos-esenciales)
- [Validación antes de aplicar](#validación-antes-de-aplicar)
- [Criterios de seguridad](#criterios-de-seguridad)
- [Estructura de los materiales](#estructura-de-los-materiales)
- [Recursos oficiales](#recursos-oficiales)

## Alcance y resultados de aprendizaje

Al finalizar el recorrido habrás practicado:

- El modelo declarativo de Terraform y la sintaxis HCL.
- La relación entre Terraform, el provider `azurerm`, Azure CLI y Azure Resource Manager.
- La creación de grupos de recursos, redes, máquinas virtuales, bases de datos y cuentas de almacenamiento.
- El ciclo de vida completo: `init`, `validate`, `plan`, `apply`, `show`, `output` y `destroy`.
- La definición de entradas con variables, locals, validaciones y salidas con `output`.
- La gestión de dependencias, `count`, `for_each`, `lifecycle`, alias de providers y bloques dinámicos.
- La separación entre configuración, estado y recursos desplegados.
- El estado remoto en Azure Storage, el bloqueo, la importación y la migración de direcciones.
- La composición con módulos locales y módulos reutilizables.
- La inyección de configuración en máquinas virtuales con cloud-init, extensiones y Ansible.
- La protección de secretos con Key Vault, valores sensibles e identidades gestionadas.
- La validación estática, las pruebas de Terraform, la seguridad de configuración y los pipelines con aprobaciones.

## Requisitos previos

Antes de empezar, prepara:

- Conocimientos básicos de terminal y Git.
- Una máquina con Docker y Docker Compose.
- Terraform instalado. Se recomienda fijar la versión del proyecto y no depender de una versión accidental del `PATH`.
- Azure CLI instalada.
- Una suscripción de Azure si quieres ejecutar los ejemplos contra Azure real.
- Permisos suficientes para crear recursos en el grupo de recursos de prácticas.
- Un editor con resaltado de HCL y Markdown, como VS Code.

El curso diferencia siempre dos escenarios:

| Escenario | Uso | Credenciales y costes |
|---|---|---|
| **Topaz en Docker** | Práctica local y repetible | No requiere una suscripción real; permite experimentar con seguridad |
| **Azure real** | Validación de operaciones y servicios reales | Requiere autenticación, permisos y control de costes |

No copies secretos al repositorio. Para Azure real, utiliza Azure CLI, identidades federadas o identidades gestionadas según el contexto.

## Entorno de prácticas

Topaz es el emulador utilizado en las primeras prácticas. El flujo general es:

1. Instalar Terraform, Azure CLI, Docker y las herramientas auxiliares.
2. Arrancar Topaz con Docker.
3. Configurar el endpoint del emulador en el provider `azurerm`.
4. Inicializar el proyecto con `terraform init`.
5. Ejecutar una prueba de humo con `terraform plan` y una aplicación controlada.
6. Verificar los recursos creados con Terraform y Azure CLI.
7. Destruir el entorno de prueba cuando ya no sea necesario.

Los ejemplos indican explícitamente cuándo una configuración es específica de Topaz y cuándo es adecuada para Azure real. No asumas que todos los servicios, APIs o comportamientos del emulador son equivalentes a la plataforma real.

### Flujo mínimo de Terraform

```bash
terraform fmt -check -recursive
terraform init
terraform validate
terraform plan
terraform apply
terraform output
terraform destroy
```

En un entorno compartido, revisa siempre el plan antes de `apply` y comprueba el contexto de autenticación y la suscripción activa:

```bash
az account show
az account list --output table
```

## Itinerario del curso

## Bloques del curso

1. [Fundamentos y primer entorno](#1-fundamentos-y-primer-entorno)
2. [Recursos y verificación](#2-recursos-y-verificación)
3. [HCL y configuración del proveedor](#3-hcl-y-configuración-del-provider)
4. [Ciclo de vida y estado](#4-ciclo-de-vida-y-estado)
5. [Variables, salidas y buenas prácticas](#5-variables-outputs-y-buenas-prácticas)
6. [Servicios de Azure](#6-servicios-de-azure)
7. [Estado remoto y operaciones sobre el estado](#7-estado-remoto-y-operaciones-sobre-el-estado)
8. [Módulos, automatización y operación](#8-módulos-automatización-y-operación)
9. [Dependencias, metaargumentos y validación](#9-dependencias-metaargumentos-y-validación)
10. [Secretos e identidad](#10-secretos-e-identidad)
11. [CI/CD con controles](#11-cicd-con-controles)

### 1. Fundamentos y primer entorno

Objetivo: entender por qué se utiliza Terraform y dejar preparado un laboratorio funcional.

1. [Infraestructura como código](01-01-introduccion-iac.md)
2. [Terraform frente a otras herramientas](01-02-comparativa-herramientas.md)
3. [Modelo declarativo y modelo imperativo](01-03-declarativo-imperativo.md)
4. [Instalación de herramientas y arranque de Topaz](01-04-Instalacion-de-herramientas-y-arranque-de-Topaz.md)
5. [Entorno práctico: Terraform, Azure Emulator Topaz y Docker](01-05-Entorno-Practico-Terraform-Azure-Emulator-Topaz-en-Docker.md)
6. [Introducción a Azure y Terraform](01-06-Introduccion-a-Azure-y-Terraform.md)
7. [Configuración de Azure CLI](01-07-configuracion-azure-cli.md)
8. [Desplegar una máquina virtual con Terraform](01-08-Desplegar-una-VM-en-el-Azure-Emulator-con-Terraform.md)

### 2. Recursos y verificación

Objetivo: crear recursos relacionados y comprobar que el estado de Terraform coincide con la plataforma.

1. [Creación de grupos de recursos y recursos con Terraform](02-01-Creacion-de-grupos-de-recursos-y-recursos-con-Terraform.md)
2. [Verificación y validación de recursos en Azure](02-02-Verificacion-y-validacion-de-recursos-en-Azure.md)

### 3. HCL y configuración del provider

Objetivo: leer y escribir configuraciones Terraform mantenibles.

1. [Sintaxis del lenguaje HCL en Terraform](03-01-Sintaxis-del-lenguaje-HCL-en-Terraform.md)
2. [Bloques principales de Terraform](03-02-Bloques-principales-de-Terraform.md)
3. [Configuración del provider `azurerm`](03-03-Configuracion-del-provider-azurerm.md)
4. [Primer `Resource Group` con Terraform](03-04-Crear-tu-primer-Resource-Group-con-Terraform.md)

### 4. Ciclo de vida y estado

Objetivo: entender qué calcula Terraform y cómo conserva la relación entre configuración e infraestructura.

1. [Comandos clave de Terraform](04-01-Comandos-clave-de-Terraform.md)
2. [Almacenamiento y bloqueo del estado](04-02-Almacenamiento-y-bloqueo-del-state.md)

### 5. Variables, outputs y buenas prácticas

Objetivo: convertir configuraciones rígidas en proyectos parametrizables y reutilizables.

1. [Variables en Terraform](05-01-variables-en-terraform.md)
2. [Variables básicas](05-02-variables-basicas-en-terraform.md)
3. [Variables avanzadas](05-03-variables-avanzadas-en-terraform.md)
4. [Salidas (`outputs`)](05-04-Salidas-outputs-en-Terraform.md)
5. [Buenas prácticas en Terraform y Azure](05-05-Buenas-practicas-en-Terraform-y-Azure.md)

### 6. Servicios de Azure

Objetivo: aplicar Terraform a las piezas habituales de una plataforma Azure.

1. [Despliegue de máquinas virtuales](06-01-despliegue-de-maquinas-virtuales.md)
2. [Redes virtuales](06-02-redes-virtuales.md)
3. [Bases de datos](06-03-bases-de-datos.md)
4. [Almacenamiento](06-04-almacenamiento.md)
5. [Buenas prácticas de arquitectura](06-05-buenas-practicas.md)

### 7. Estado remoto y operaciones sobre el estado

Objetivo: operar con estado compartido sin perder trazabilidad ni consistencia.

1. [Estado remoto en Azure Storage](07-01-estado-remoto-en-azure-storage.md)
2. [Bloqueo del estado](07-02-bloqueo-de-estado.md)
3. [Comandos de estado: importar, mover, recrear y olvidar](07-03-comandos-de-estado.md)
4. [Workspaces](07-04-workspaces.md)

### 8. Módulos, automatización y operación

Objetivo: preparar configuraciones para equipos y ciclos de entrega continuos.

1. [Módulos personalizados](08-01-modulos-personalizados.md)
2. [CI/CD](08-02-ci-cd.md)
3. [Seguridad avanzada](08-03-seguridad-avanzada.md)
4. [Optimización](08-04-optimizacion.md)
5. [Monitorización y logging](08-05-monitorizacion-y-logging.md)

### 9. Dependencias, metaargumentos y validación

Objetivo: controlar el grafo de recursos y poner barreras antes de modificar Azure.

1. [Dependencias de recursos](09-01-dependencias-de-recursos.md)
2. [Metaargumentos](09-02-metaargumentos.md)
3. [Provisioners, cloud-init, extensiones y Ansible](09-03-provisioners.md)
4. [Validación y pruebas](09-04-validacion.md)

### 10. Secretos e identidad

Objetivo: evitar credenciales incrustadas y aplicar el principio de mínimo privilegio.

1. [Azure Key Vault](10-01-key-vault.md)
2. [Valores sensibles](10-02-valores-sensibles.md)
3. [Identidades gestionadas](10-03-managed-identities.md)

### 11. CI/CD con controles

Objetivo: automatizar planes y aplicaciones manteniendo revisiones, aprobaciones y puertas de calidad.

1. [Automatización y CI/CD con Terraform](11-01-automatizacion-y-ci-cd-terraform.md)
2. [Pipeline y `apply`](11-02-pipeline-y-apply.md)
3. [Aprobaciones y puertas](11-03-aprobaciones-y-puertas.md)

## Guía de trabajo recomendada

Sigue este ciclo para cada práctica:

1. **Lee el contexto.** Identifica si el ejemplo es para Topaz o Azure real.
2. **Prepara el directorio.** Separa cada ejercicio o componente de su estado y variables.
3. **Fija versiones.** Revisa `required_version` y las versiones de los providers.
4. **Formatea.** Ejecuta `terraform fmt` antes de revisar cambios.
5. **Inicializa.** Ejecuta `terraform init` y comprueba el backend y los plugins.
6. **Valida.** Ejecuta `terraform validate` y, cuando corresponda, TFLint, Trivy o pruebas de Terraform.
7. **Planifica.** Lee el plan completo; para si hay destrucciones o reemplazos inesperados.
8. **Aplica con control.** Utiliza aprobación explícita en entornos compartidos o productivos.
9. **Verifica.** Compara `terraform show`, `terraform output` y Azure CLI.
10. **Documenta.** Anota decisiones, variables necesarias y cualquier excepción de seguridad.
11. **Limpia.** Ejecuta `terraform destroy` solo cuando el entorno sea temporal y el plan esté revisado.

## Comandos esenciales

| Comando | Finalidad |
|---|---|
| `terraform fmt` | Formatear archivos `.tf` y `.tfvars` |
| `terraform init` | Instalar providers e inicializar el backend |
| `terraform validate` | Detectar errores estructurales y de tipos |
| `terraform plan` | Calcular los cambios sin aplicarlos |
| `terraform apply` | Aplicar un plan a la infraestructura |
| `terraform show` | Consultar el plan o el estado en formato legible |
| `terraform output` | Mostrar las salidas del root module |
| `terraform state list` | Enumerar direcciones presentes en el estado |
| `terraform state show <dirección>` | Inspeccionar un recurso del estado |
| `terraform import` | Adoptar un recurso existente |
| `terraform state mv` | Cambiar una dirección sin recrear el recurso |
| `terraform state rm` | Dejar de gestionar un recurso sin destruirlo |
| `terraform force-unlock <ID>` | Recuperar un bloqueo solo después de verificar que no hay ninguna ejecución activa |
| `terraform destroy` | Destruir los recursos gestionados |

Evita utilizar `-target` como flujo normal: es una herramienta de emergencia y puede dejar el plan incompleto. Igualmente, no edites manualmente el archivo del estado; utiliza los comandos `terraform state`.

## Validación antes de aplicar

La validación debe subir progresivamente de una comprobación local a una verificación de integración:

1. `terraform fmt -check -recursive`
2. `terraform init -backend=false` cuando solo sea necesario validar la configuración.
3. `terraform validate`
4. TFLint con el ruleset de Azure.
5. Trivy o una herramienta equivalente para detectar riesgos de configuración.
6. `terraform test` para comprobar el contrato de los módulos.
7. `terraform plan` contra Topaz o un entorno controlado.
8. Revisión humana del plan antes de `apply`.
9. Verificación posterior de los recursos y de las salidas.

Un `plan` sin errores no garantiza que la arquitectura sea segura, económica o adecuada. La revisión debe incluir permisos, exposición de red, cifrado, retención, costes e impacto de destrucciones o reemplazos.

## Criterios de seguridad

- No subas archivos `.tfvars` con secretos, archivos de estado ni credenciales al repositorio.
- Marca las salidas y variables sensibles con `sensitive = true`, pero recuerda que esto no cifra por sí solo el estado.
- Utiliza un backend remoto protegido, con control de acceso, bloqueo y versionado.
- Prefiere federación de identidad o identidades gestionadas a secretos de larga duración en CI/CD.
- Da permisos con el menor ámbito posible y asigna roles de datos específicos.
- Revisa los logs: no imprimas tokens, contraseñas, claves ni contenido sensible.
- Protege el pipeline con revisión de pull request, CODEOWNERS, aprobaciones y puertas automáticas.
- Trata `provisioners` como una excepción; prioriza cloud-init, extensiones o herramientas de configuración especializadas.
- Antes de un `destroy`, confirma el workspace, el backend y la suscripción activa.

## Estructura de los materiales

```text
docs/azure/
├── README.md                         # Esta guía de la sección
├── index.md                          # Página de introducción de MkDocs
├── 01-*.md                           # Fundamentos y entorno
├── 02-*.md                           # Recursos y verificación
├── 03-*.md                           # HCL y provider
├── 04-*.md                           # Comandos y estado
├── 05-*.md                           # Variables y buenas prácticas
├── 06-*.md                           # Servicios de Azure
├── 07-*.md                           # Estado remoto y workspaces
├── 08-*.md                           # Módulos y operación
├── 09-*.md                           # Dependencias y validación
├── 10-*.md                           # Secretos e identidad
└── 11-*.md                           # CI/CD y aprobaciones
```

## Recursos oficiales

- [Documentación de Terraform](https://developer.hashicorp.com/terraform/docs)
- [Lenguaje Terraform](https://developer.hashicorp.com/terraform/language)
- [Provider AzureRM](https://registry.terraform.io/providers/hashicorp/azurerm/latest/docs)
- [Documentación de Azure](https://learn.microsoft.com/azure/)
- [Azure CLI](https://learn.microsoft.com/cli/azure/)
- [Terraform best practices](https://developer.hashicorp.com/terraform/cloud-docs/recommended-practices)
- [Documentación de Docker](https://docs.docker.com/)