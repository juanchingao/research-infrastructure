# research-infrastructure

Infraestructura reproducible para estaciones de trabajo de investigación en **OpenStack**, gestionada desde **Windows + VS Code + PowerShell**.

El repositorio automatiza la creación de una workstation científica basada en Ubuntu y Docker, separando estrictamente la infraestructura de cómputo de los datos persistentes.

---

## Objetivo

Separar tres capas independientes:

1. **Infraestructura**
   Este repositorio: creación de VM, red, almacenamiento, SSH, Docker y servicios.

2. **Proyecto científico**
   Repositorios independientes con código R, documentación, análisis y configuración específica de cada proyecto.

3. **Datos persistentes**
   Volúmenes Cinder independientes de la VM, cifrados con LUKS2 y nunca almacenados en Git.

Principio operativo:

> **Las instancias son reemplazables. Los datos no.**

La VM puede destruirse y recrearse sin perder el volumen de investigación.

---

## Arquitectura actual

```text
Windows / VS Code
        |
        | PowerShell + OpenStack CLI
        v
     OpenStack
        |
        +-----------------------------+
        |                             |
        v                             v
  Nova / Neutron                   Cinder
        |                             |
        v                             |
 research-ws-01                      |
 Ubuntu 24.04                        |
 VM efímera                          |
        |                             |
        | attach                      |
        +-----------------------------+
                      |
                      v
                   /dev/vdb
                      |
                    LUKS2
                   cifrado
                      |
                      v
            /dev/mapper/research-data
                      |
                    ext4
                      |
                      v
                    /data
                      |
              +-------+---------+
              |                 |
              v                 v
       datos/proyectos    rstudio-home
                                |
                                v
                          /home/rstudio
```

Sobre la VM:

```text
Ubuntu 24.04
     |
     v
   Docker
     |
     v
rocker/rstudio:4.6.0
     |
     v
RStudio Server
2026.05.1
     |
     | 127.0.0.1:8787
     v
  túnel SSH
     |
     v
Windows
http://localhost:8787
```

RStudio **no se expone directamente a la red**. El puerto `8787` se publica únicamente sobre `127.0.0.1` dentro de la VM y se accede mediante túnel SSH.

---

# Componentes

## Compute

La workstation se ejecuta sobre una VM Ubuntu 24.04 creada mediante OpenStack.

La VM se considera **efímera**:

* puede destruirse;
* puede recrearse;
* no contiene los datos científicos persistentes;
* Docker y los servicios pueden reconstruirse automáticamente.

---

## Almacenamiento persistente

Los datos se almacenan en un volumen Cinder independiente:

```text
research-data-01
200 GB
```

El volumen:

* sobrevive a la destrucción de la VM;
* se vuelve a adjuntar automáticamente a una nueva instancia;
* no se elimina durante `destroy`;
* está cifrado mediante **LUKS2**;
* contiene un sistema de archivos `ext4`;
* se monta en `/data`.

Arquitectura:

```text
research-data-01
      |
      v
   /dev/vdb
      |
      v
    LUKS2
      |
      v
/dev/mapper/research-data
      |
      v
     ext4
      |
      v
    /data
```

La persistencia se ha validado destruyendo completamente la VM, recreándola, volviendo a adjuntar el volumen y recuperando correctamente los archivos previamente almacenados.

---

## Persistencia de RStudio

El contenedor Docker también es reemplazable.

Para evitar perder preferencias y configuración del usuario RStudio, su directorio home se almacena dentro del volumen cifrado:

```text
/data/rstudio-home
        |
        v
/home/rstudio
```

Por tanto pueden persistir entre recreaciones del contenedor:

* preferencias de RStudio;
* configuración del usuario;
* configuración de Posit Assistant;
* otros archivos almacenados bajo `/home/rstudio`.

---

## Secretos

Los secretos no se almacenan en Git.

Actualmente la contraseña de RStudio se encuentra en:

```text
/data/.secrets/rstudio.env
```

Este fichero:

* está dentro del volumen LUKS cifrado;
* tiene permisos restrictivos;
* no forma parte del repositorio.

La contraseña LUKS:

* no se almacena en Git;
* no se almacena en `infrastructure.local.yaml`;
* no se almacena en cloud-init;
* se introduce de forma interactiva cuando es necesario desbloquear el volumen.

---

# Flujo cotidiano

Una vez configurada la estación de trabajo, el comando principal es:

```powershell
.\scripts\research.ps1 start
```

`start` orquesta automáticamente:

```text
create
   |
   v
mount-data
   |
   v
deploy-rstudio
   |
   v
tunnel
```

Es decir:

1. comprueba o crea la VM;
2. comprueba o crea el volumen persistente;
3. adjunta el volumen a la VM;
4. desbloquea LUKS si es necesario;
5. monta `/data`;
6. despliega o actualiza RStudio;
7. abre el túnel SSH;
8. deja RStudio accesible en:

```text
http://localhost:8787
```

Si el volumen LUKS está cerrado se solicitará la contraseña de forma interactiva.

---

# Comandos disponibles

## Arranque completo

```powershell
.\scripts\research.ps1 start
```

Es el comando recomendado para el uso habitual.

---

## Crear o comprobar infraestructura

```powershell
.\scripts\research.ps1 create
```

Realiza de forma idempotente:

* comprobación de autenticación OpenStack;
* comprobación del security group;
* creación/reutilización de VM;
* creación/reutilización del volumen persistente;
* asociación del volumen;
* asignación/reutilización de floating IP.

---

## Consultar estado

```powershell
.\scripts\research.ps1 status
```

Muestra información sobre:

* instancia;
* ID;
* estado;
* redes;
* floating IP;
* security groups;
* volumen persistente;
* tamaño;
* estado del volumen;
* asociación con la VM.

---

## Desbloquear y montar datos

```powershell
.\scripts\research.ps1 mount-data
```

El comando:

1. comprueba la VM;
2. comprueba el volumen;
3. garantiza que está adjunto;
4. identifica el dispositivo;
5. verifica que contiene LUKS;
6. solicita contraseña si está cerrado;
7. abre el mapper;
8. monta `/data`;
9. verifica el montaje.

Es idempotente: si LUKS ya está abierto o `/data` ya está montado, no repite innecesariamente esas operaciones.

---

## Desplegar RStudio

```powershell
.\scripts\research.ps1 deploy-rstudio
```

El comando:

1. comprueba que `/data` está montado;
2. comprueba los secretos de RStudio;
3. comprueba el home persistente;
4. copia mediante SCP el `compose.yaml` del repositorio a la VM;
5. ejecuta Docker Compose;
6. comprueba el contenedor;
7. verifica que RStudio responde en `127.0.0.1:8787`.

---

## Abrir túnel RStudio

```powershell
.\scripts\research.ps1 tunnel
```

Crea:

```text
localhost:8787
      |
      | SSH
      v
VM 127.0.0.1:8787
      |
      v
RStudio Server
```

Mientras el túnel esté abierto:

```text
http://localhost:8787
```

permite acceder a RStudio.

La terminal debe permanecer abierta mientras se utilice el túnel.

Para cerrarlo:

```text
Ctrl+C
```

---

## Entrar por SSH

```powershell
.\scripts\research.ps1 ssh
```

El script obtiene automáticamente la floating IP de OpenStack.

---

## Destruir la VM

```powershell
.\scripts\research.ps1 destroy
```

Antes de eliminar la VM:

1. desmonta `/data`;
2. cierra el mapper LUKS;
3. desadjunta el volumen persistente;
4. conserva `research-data-01`;
5. desasocia la floating IP;
6. elimina la instancia.

Por diseño:

```text
VM                  → eliminada
Docker              → eliminable/recreable
RStudio             → eliminable/recreable
research-data-01    → CONSERVADO
datos LUKS          → CONSERVADOS
```

---

# Idempotencia

Los principales comandos están diseñados para ser **idempotentes**.

Esto significa que volver a ejecutar una operación no debe crear recursos duplicados si el estado deseado ya existe.

Por ejemplo:

```powershell
.\scripts\research.ps1 create
```

si la infraestructura ya está desplegada:

```text
VM existe             → reutilizar
volumen existe        → reutilizar
volumen adjunto       → no volver a adjuntar
floating IP existe    → reutilizar
```

Del mismo modo:

```powershell
.\scripts\research.ps1 mount-data
```

si el volumen ya está desbloqueado y montado:

```text
LUKS abierto          → conservar
/data montado         → conservar
```

---

# Configuración local

La configuración específica de cada equipo se almacena en:

```text
config/infrastructure.local.yaml
```

Ejemplo:

```yaml
keypair: 2026-08PortatilURJC

data_volume_name: research-data-01
data_volume_size_gb: 200
data_volume_type: __DEFAULT__
data_volume_availability_zone: nova
data_mapper_name: research-data
data_mount_point: /data
data_volume_delete_on_destroy: false
```

Este fichero está excluido de Git.

Nunca debe contener:

* contraseñas;
* tokens;
* claves SSH privadas;
* contraseña LUKS;
* credenciales científicas.

---

# Autenticación OpenStack

OpenStack CLI necesita las variables `OS_*` correspondientes al proyecto.

Entre ellas:

```text
OS_AUTH_URL
OS_PROJECT_ID
OS_PROJECT_NAME
OS_USERNAME
OS_USER_DOMAIN_NAME
OS_PROJECT_DOMAIN_ID
OS_REGION_NAME
OS_INTERFACE
OS_IDENTITY_API_VERSION
OS_PASSWORD
```

La contraseña debe mantenerse fuera del repositorio.

Puede verificarse la sesión con:

```powershell
openstack token issue
```

---

# Estructura del repositorio

```text
research-infrastructure/
|
+-- cloud/
|   `-- cloud-init
|
+-- config/
|   +-- infrastructure.example.yaml
|   +-- infrastructure.local.example.yaml
|   `-- infrastructure.local.yaml      # no Git
|
+-- scripts/
|   +-- research.ps1
|   `-- modules/
|       +-- Config.psm1
|       +-- OpenStackCli.psm1
|       +-- Compute.psm1
|       +-- Security.psm1
|       +-- Network.psm1
|       +-- Storage.psm1
|       `-- Ssh.psm1
|
+-- services/
|   `-- rstudio/
|       `-- compose.yaml
|
+-- .vscode/
|   `-- tasks.json
|
+-- INSTRUCCIONES.md
`-- README.md
```

---

# RStudio

Actualmente se utiliza:

```text
Docker image: rocker/rstudio:4.6.0
R: 4.6.0
RStudio Server: 2026.05.1
```

El contenedor publica:

```yaml
ports:
  - "127.0.0.1:8787:8787"
```

por lo que el puerto de RStudio no queda expuesto directamente.

El acceso se realiza exclusivamente mediante SSH:

```text
Windows localhost:8787
        |
        v
      SSH
        |
        v
VM localhost:8787
        |
        v
RStudio
```

---

# Seguridad

Controles actualmente implementados:

* claves SSH privadas fuera de Git;
* credenciales OpenStack fuera de Git;
* secretos RStudio fuera de Git;
* datos científicos fuera de Git;
* volumen persistente cifrado mediante LUKS2;
* contraseña LUKS no almacenada;
* RStudio no expuesto directamente en la red;
* acceso a RStudio mediante túnel SSH;
* VM reemplazable sin pérdida de datos;
* home de RStudio persistente dentro del volumen cifrado;
* desmontaje y cierre de LUKS antes del detach durante `destroy`.

## Security group

Actualmente existe un security group específico de investigación, pero la fase de bootstrap mantiene la conectividad SSH mediante la configuración de seguridad definida para el despliegue inicial.

Queda pendiente endurecer definitivamente las reglas cuando se disponga del CIDR oficial de acceso VPN/universidad.

---

# Advertencia sobre claves SSH de host

Al destruir una VM y crear otra reutilizando la misma floating IP, la nueva VM genera nuevas claves SSH.

Windows puede mostrar:

```text
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
```

Si el cambio corresponde efectivamente a una VM que acaba de ser recreada, puede eliminarse la entrada antigua:

```powershell
ssh-keygen -R <FLOATING_IP>
```

No se desactiva globalmente `StrictHostKeyChecking`, ya que constituye una protección frente a ataques man-in-the-middle.

---

# Validaciones realizadas

La infraestructura actual ha sido validada mediante pruebas reales:

* creación de VM desde PowerShell;
* cloud-init completado;
* Docker Engine operativo;
* Docker Compose operativo;
* ejecución correcta de `hello-world`;
* creación de volumen Cinder;
* asociación del volumen a la VM;
* cifrado LUKS2;
* sistema ext4;
* montaje en `/data`;
* escritura de fichero de prueba;
* desmontaje y cierre LUKS;
* destrucción completa de la VM;
* persistencia del volumen;
* recreación de una nueva VM;
* reasociación del mismo volumen;
* desbloqueo LUKS;
* recuperación íntegra del fichero de prueba;
* despliegue de RStudio en Docker;
* persistencia de `/home/rstudio`;
* acceso a RStudio mediante túnel SSH;
* funcionamiento de `start` como flujo completo.

---

# Próximos pasos

La infraestructura base está operativa.

Los siguientes desarrollos se centran ya en el entorno científico:

1. definir estructura de `/data`;
2. transferir datasets de investigación de gran tamaño;
3. establecer política `raw / derived / outputs`;
4. integrar repositorios científicos independientes;
5. configurar flujo R + Git + Posit Assistant;
6. definir estrategia de backups/snapshots del volumen;
7. endurecer definitivamente el security group;
8. mejorar la gestión local de autenticación OpenStack;
9. incorporar comprobaciones adicionales y tests de infraestructura.

El objetivo es que la infraestructura pase a ser una capa estable y que el trabajo cotidiano se concentre en los repositorios científicos y en RStudio.
