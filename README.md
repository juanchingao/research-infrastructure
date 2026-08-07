# research-infrastructure

Infraestructura reproducible para estaciones de investigación en OpenStack, gestionada desde Windows + VS Code + PowerShell.

## Objetivo

Separar estrictamente:

1. **Infraestructura** (este repositorio)
2. **Proyecto científico** (repositorios independientes)
3. **Datos persistentes** (volúmenes Cinder fuera de Git)

Principio operativo:

- **Instancias reemplazables**
- **Datos persistentes**

## Flujo de arquitectura

```text
Windows / VS Code
        |
        | OpenStack CLI
        v
     Keystone
        |
        v
     OpenStack
        |
        +-- Nova
        +-- Neutron
        +-- Cinder
        |
        v
     Ubuntu VM
        |
     cloud-init
        |
      Docker
        |
  research environment
```

Persistencia de datos (separada de la VM):

```text
persistent data volume
        |
        v
       /data
```

## Primera iteración incluida

Esta primera iteración implementa el mínimo funcional para:

1. Crear VM Ubuntu2404 con OpenStack CLI.
2. Aplicar cloud-init base.
3. Dejar Docker Engine + Docker Compose plugin operativos.
4. Asignar floating IP y habilitar acceso SSH.
5. Gestionar ciclo básico con PowerShell.

Nota de seguridad en transición:

- En esta iteración la VM usa `bootstrap_security_group: default` para asegurar SSH operativo inmediato.
- Se crea también `research-workstation` para migrar en la siguiente iteración cuando se defina CIDR VPN/universidad y reglas mínimas.

No incluye todavía:

- Terraform/OpenTofu
- servicios científicos (RStudio/Ollama/VS Code Server)
- destrucción/creación desde CI
- gestión automática del volumen de datos persistente

## Estructura

- [config/](/C:/GitProjects/research-infrastructure/config): configuración versionable y plantillas.
- [cloud/](/C:/GitProjects/research-infrastructure/cloud): cloud-init.
- [docker/](/C:/GitProjects/research-infrastructure/docker): base Docker.
- [scripts/](/C:/GitProjects/research-infrastructure/scripts): CLI PowerShell y módulos.
- [.vscode/tasks.json](/C:/GitProjects/research-infrastructure/.vscode/tasks.json): tareas VS Code como interfaz.
- [INSTRUCCIONES.md](/C:/GitProjects/research-infrastructure/INSTRUCCIONES.md): guía operativa paso a paso.

## Comandos principales

Desde la raíz del repositorio:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\research.ps1 create
powershell -ExecutionPolicy Bypass -File .\scripts\research.ps1 status
powershell -ExecutionPolicy Bypass -File .\scripts\research.ps1 ssh
powershell -ExecutionPolicy Bypass -File .\scripts\research.ps1 destroy
```

## Seguridad y secretos

- No se versionan credenciales, tokens ni claves privadas.
- [config/infrastructure.local.yaml](/C:/GitProjects/research-infrastructure/config/infrastructure.local.yaml) está ignorado por Git.
- Se versionan plantillas de ejemplo para configurar cada entorno local.

## Siguiente paso recomendado

Implementar en segunda iteración:

- attach/detach de volumen de datos
- política de montaje seguro en `/data` sin formateo implícito
- endurecimiento de security group por CIDR VPN/universidad