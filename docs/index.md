# Start Using Terraform

Bienvenido a la documentación del proyecto **Start Using Terraform**, un recorrido práctico para aprender a definir y gestionar infraestructura como código con Terraform.

## Objetivo

El proyecto explica los conceptos esenciales de Terraform y muestra cómo aplicarlos a Azure, desde la configuración inicial hasta la automatización con CI/CD. Los ejemplos combinan teoría, configuraciones HCL y procedimientos verificables.

## Contenido

La documentación se organiza en los siguientes bloques:

1. [Fundamentos y primer entorno](azure/index.md#1-fundamentos-y-primer-entorno)
2. [Recursos y verificación](azure/index.md#2-recursos-y-verificación)
3. [HCL y configuración del proveedor](azure/index.md#3-hcl-y-configuración-del-provider)
4. [Ciclo de vida y estado](azure/index.md#4-ciclo-de-vida-y-estado)
5. [Variables, salidas y buenas prácticas](azure/index.md#5-variables-outputs-y-buenas-prácticas)
6. [Servicios de Azure](azure/index.md#6-servicios-de-azure)
7. [Estado remoto y operaciones sobre el estado](azure/index.md#7-estado-remoto-y-operaciones-sobre-el-estado)
8. [Módulos, automatización y operación](azure/index.md#8-módulos-automatización-y-operación)
9. [Dependencias, metaargumentos y validación](azure/index.md#9-dependencias-metaargumentos-y-validación)
10. [Secretos e identidad](azure/index.md#10-secretos-e-identidad)
11. [CI/CD con controles](azure/index.md#11-cicd-con-controles)

## Cómo empezar

Para seguir el recorrido, entra en la sección [Terraform con Azure](azure/index.md) y avanza las lecciones en orden. Para las primeras prácticas se recomienda utilizar Topaz en Docker; los capítulos indican cuándo una configuración está pensada para Azure real.

Antes de aplicar cambios, revisa siempre el plan de Terraform, protege las credenciales y comprueba la cuenta o la suscripción de Azure activa.