# INSTRUCCIONES (primera iteración)

Esta guía está pensada para ejecutar la infraestructura desde Windows + VS Code + PowerShell.

## 1) Preparación inicial (una sola vez)

1. Verifica OpenStack CLI:
   ```powershell
   openstack --version
   ```
2. Verifica autenticación activa:
   ```powershell
   openstack token issue
   ```
3. Copia la configuración local:
   - de [config/infrastructure.local.example.yaml](/C:/GitProjects/research-infrastructure/config/infrastructure.local.example.yaml)
   - a `config/infrastructure.local.yaml` (este archivo queda fuera de Git).
4. Edita `config/infrastructure.local.yaml` y cambia `keypair` por uno real de OpenStack.

## 2) Crear la VM

Desde la raíz del repo:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\research.ps1 create
```

Qué hace:

1. Comprueba autenticación OpenStack.
2. Garantiza `research-workstation` (sin reglas avanzadas aún).
3. Crea la VM Ubuntu2404 si no existe.
4. Asigna floating IP.
5. Muestra comandos de verificación de cloud-init y Docker.

En esta primera iteración, la VM se crea con `bootstrap_security_group: default`
para asegurar conectividad SSH mientras se define el CIDR oficial de acceso.

## 3) Ver estado

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\research.ps1 status
```

Muestra: nombre, ID, estado, redes y floating IP.

## 4) Conectar por SSH

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\research.ps1 ssh
```

Requiere que tu clave privada esté en tu equipo (nunca en Git).

## 5) Destruir VM (sin borrar datos externos)

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\research.ps1 destroy
```

- Solicita confirmación (`YES`).
- Desasocia floating IP.
- Elimina solo la instancia.
- No gestiona todavía volumen de datos persistente (se implementará en iteración siguiente).

## 6) Usar tareas de VS Code

En VS Code: `Terminal -> Run Task` y ejecuta:

- `Research: Create`
- `Research: Status`
- `Research: SSH`
- `Research: Destroy`

## 7) Problemas comunes

1. **Error de autenticación OpenStack**  
   Reexporta variables `OS_*` o revisa tu contexto de login.
2. **`keypair` no válido**  
   Ajusta `config/infrastructure.local.yaml` con un keypair existente en tu proyecto OpenStack.
3. **Sin SSH**  
   Espera a que cloud-init termine:
   ```bash
   cloud-init status --wait
   ```
4. **No hay floating IP disponible**  
   El script intentará crear una nueva en la red externa configurada.

## 8) Seguridad en esta iteración

- No hay secretos en Git.
- No se exponen servicios científicos.
- El acceso operativo se basa en SSH.
- El endurecimiento final del security group depende del CIDR oficial de VPN/universidad.
