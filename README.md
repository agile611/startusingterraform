# Start Using Terraform

Bienvenido a la documentación del proyecto **Start Using Terraform**, un recorrido práctico para aprender a definir y gestionar infraestructura como código con Terraform.

## Objetivo

El proyecto explica los conceptos esenciales de Terraform y muestra cómo aplicarlos a Azure, desde la configuración inicial hasta la automatización con CI/CD. Los ejemplos combinan teoría, configuraciones HCL y procedimientos verificables.

## Contenido

La documentación se organiza en los siguientes bloques:

- **Fundamentos:** infraestructura como código, Terraform, herramientas alternativas y modelos declarativos.
- **Entorno práctico:** instalación, Azure CLI, Docker y Azure Emulator Topaz.
- **Terraform y Azure:** providers, recursos, grupos de recursos y máquinas virtuales.
- **HCL y configuración:** sintaxis, bloques principales, variables, locals y outputs.
- **Estado y operaciones:** comandos, estado remoto, bloqueo, workspaces y migraciones.
- **Servicios de Azure:** redes, máquinas virtuales, bases de datos y almacenamiento.
- **Reutilización:** módulos personalizados y buenas prácticas de organización.
- **Operación y calidad:** dependencias, metaargumentos, provisioners, validación y monitorización.
- **Seguridad:** Key Vault, valores sensibles e identidades gestionadas.
- **Automatización:** pipelines, aplicaciones controladas, aprobaciones y puertas de calidad.

## Cómo empezar

Para seguir el recorrido, entra en la sección [Terraform con Azure](docs/azure/index.md) y avanza las lecciones en orden. Para las primeras prácticas se recomienda utilizar Topaz en Docker; los capítulos indican cuándo una configuración está pensada para Azure real.

Antes de aplicar cambios, revisa siempre el plan de Terraform, protege las credenciales y comprueba la cuenta o la suscripción de Azure activa.