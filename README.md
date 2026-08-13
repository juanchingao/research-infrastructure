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
2026.07.1+147
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

`start` orquesta automáticamente. Si la instancia ya existe, mantiene una
instancia `ACTIVE`, arranca una `SHUTOFF` y recupera una instancia
`SHELVED`, `PAUSED` o `SUSPENDED`. Espera hasta que OpenStack informa
`ACTIVE` antes de preparar el volumen e intentar SSH:

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

Requiere que el volumen ya haya sido inicializado con `init-data` y que el secreto de RStudio exista. Por seguridad, `start` nunca formatea un volumen ni crea contraseñas automáticamente.

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

Al terminar el trabajo, cierre el túnel con `Ctrl+C` y apague la estación de
forma segura para dejar de consumir cómputo:

```powershell
.\scripts\research.ps1 stop
```

`stop` detiene RStudio, aborta si `/data` sigue en uso, desmonta el filesystem,
cierra LUKS, solicita el apagado de OpenStack y espera a `SHUTOFF`. Conserva la
VM, el volumen Cinder y la floating IP. Es idempotente: si la VM ya está apagada
no intenta conectar por SSH ni repite el apagado.

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

## Inicializar un volumen nuevo

```powershell
.\scripts\research.ps1 init-data
```

Esta operación se ejecuta una sola vez y destruye cualquier contenido previo. Solo acepta un dispositivo inequívoco y vacío, exige confirmar `INITIALIZE <nombre-del-volumen>`, crea LUKS2 y ext4 y prepara los directorios persistentes.

Después se crea el secreto de RStudio de forma interactiva:

```powershell
.\scripts\research.ps1 configure-rstudio
```

La contraseña no se muestra y el fichero queda con permisos `0600` dentro del volumen cifrado.

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

Cerrar el túnel no apaga la VM. Para detener el consumo de cómputo ejecute a
continuación:

```powershell
.\scripts\research.ps1 stop
```

---

## Apagar la estación conservando la VM

```powershell
.\scripts\research.ps1 stop
```

Este es el cierre cotidiano recomendado. Detiene servicios y cierra `/data` y
LUKS antes de llevar la instancia a `SHUTOFF`. El siguiente `start` volverá a
arrancarla automáticamente.

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

1. detiene RStudio;
2. comprueba que no quedan procesos utilizando `/data`;
3. desmonta `/data`;
4. cierra el mapper LUKS;
5. desadjunta y conserva el volumen persistente;
6. desasocia la floating IP;
7. elimina la instancia.

## Snapshots offline

```powershell
.\scripts\research.ps1 snapshot-data
```

Detiene los servicios, desmonta y cierra LUKS antes de crear un snapshot Cinder. Finalmente vuelve a adjuntar el volumen, que permanece cerrado hasta ejecutar `mount-data`. Los snapshots del mismo backend no sustituyen un backup independiente.

Si el proveedor dispone de Cinder Backup puede crearse una copia offline:

```powershell
.\scripts\research.ps1 backup-data
```

La política debe incluir restauraciones de prueba sobre volúmenes nuevos y confirmar que el backend de backup es independiente del almacenamiento primario.

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
+-- .gitignore
+-- cloud/
|   `-- cloud-init.base.yaml
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
|       +-- compose.yaml
|       `-- Dockerfile
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
Base image: rocker/rstudio:4.6.0
R: 4.6.0
RStudio Server: 2026.07.1+147
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

## Paquetes R: binarios, `renv` y caché persistente

La imagen base contiene únicamente herramientas transversales: `renv`, Git, certificados, una cadena de compilación razonable y cabeceras habituales de red, XML, ICU, fuentes y compresión. No contiene paquetes científicos como `dplyr`, `ggplot2`, `gt` o `survival`.

Cada repositorio científico conserva su propio `renv.lock` y su biblioteca local de proyecto. El flujo normal, sin Posit Assistant, es:

```r
renv::status()
renv::restore()
```

R usa el repositorio binario público de Posit para Ubuntu 24.04 Noble, x86_64 y R 4.6:

```text
https://packagemanager.posit.co/cran/latest/bin/linux/noble-x86_64/4.6
```

La URL declara explícitamente el entorno y no depende de que Rocker construya un `User-Agent` especial. `renv.lock` fija las versiones; `latest` solo indica el catálogo desde el que se resuelven y descargan esas versiones. Cuando Posit dispone del binario, la instalación muestra `installing *binary* package`. Para paquetes sin binario se conserva la cadena de compilación de la imagen.

La imagen define además `RENV_CONFIG_PPM_ENABLED=false`. La integración automática de Posit Package Manager en `renv` transforma las URL de fuentes en URL binarias; aquí debe permanecer desactivada porque `RSPM` ya es una URL binaria completa. De otro modo, `renv` puede añadir una segunda ruta `__linux__/noble/4.6` y consultar un índice inexistente.

El contenedor usa una red bridge dedicada con MTU 1400. Las redes tenant de OpenStack encapsulan el tráfico y pueden ofrecer un MTU menor que los 1500 bytes predeterminados de Docker. Sin este ajuste, DNS y la conexión TCP pueden funcionar mientras la respuesta al saludo TLS queda bloqueada, impidiendo acceder a determinados repositorios HTTPS.

El caché compartido vive en `/data/.cache/renv` y llega al contenedor mediante `RENV_PATHS_CACHE`. El despliegue crea el directorio si falta, conserva el existente y le asigna al usuario `rstudio` permisos de escritura. Como está en el volumen cifrado `/data`, sobrevive a recreaciones del contenedor y de la VM y puede reutilizar paquetes entre proyectos. No sustituye ni el `renv.lock` ni la biblioteca aislada de cada proyecto.

La comprobación ligera no instala ninguna colección científica grande:

```powershell
.\scripts\research.ps1 check-r
```

Valida R, libcurl, CRAN, el índice binario de Posit, el caché y `renv`, e instala `digest` en una biblioteca temporal para exigir que Posit lo sirva como binario. Si un paquete común empieza a compilarse, ejecute primero `check-r`, confirme `getOption("repos")` y no fuerce `type = "source"` ni `type = "binary"`; Package Manager selecciona el artefacto adecuado. Un paquete poco común puede carecer legítimamente de binario.

## Ollama en instancia independiente

Ollama se ejecuta en `research-ollama-01`, separada de RStudio para no competir por CPU, RAM ni disco. El piloto usa `16cpu+30ram+8vol` y conserva Docker, la imagen y los modelos en el volumen Cinder `research-ollama-01-data` de 100 GB. El puerto 11434 solo admite conexiones desde la IP privada configurada de RStudio.

El ciclo completo es idempotente:

```powershell
.\scripts\ollama.ps1 start
.\scripts\ollama.ps1 validate
.\scripts\ollama.ps1 status
.\scripts\ollama.ps1 check-rstudio
.\scripts\ollama.ps1 stop
```

`start` crea o arranca la VM, asocia y monta el volumen en `/srv/ollama`, configura Docker en `/srv/ollama/docker` y containerd en `/srv/ollama/containerd`, despliega Ollama y garantiza que el modelo configurado esté descargado. `stop` detiene el contenedor y apaga la VM, conservando el volumen y la floating IP. `destroy` elimina la VM pero conserva el volumen para una reconstrucción posterior. Las acciones `research.ps1 start` y `research.ps1 stop` incluyen este ciclo automáticamente.

Para comparar de forma reproducible los modelos de codigo instalados, se puede ejecutar:

```powershell
. .\config\openstack-auth.local.ps1
.\scripts\benchmark-ollama.ps1
```

El benchmark realiza un calentamiento y tres repeticiones de tres tareas de R con `temperature: 0`. Compara por defecto `qwen2.5-coder:3b` y `qwen2.5-coder:7b`, muestra el resumen y guarda las metricas y respuestas completas bajo `artifacts/`. No ejecuta el codigo generado; las respuestas quedan disponibles para revisar su calidad de forma segura.

Se puede descargar un modelo adicional sin cambiar el modelo principal configurado:

```powershell
.\scripts\ollama.ps1 pull-model -Model gpt-oss:20b
```

Si se aumenta `data_volume_size_gb` en la configuracion local, la ampliacion de Cinder y del filesystem ext4 se aplica explicitamente con:

```powershell
.\scripts\ollama.ps1 resize-data
```

La accion es idempotente y nunca reduce el volumen.

Cuando OpenStack crea una VM nueva y reutiliza una floating IP, su clave SSH cambia legítimamente. El flujo elimina en ese caso solo la entrada anterior de esa IP en `known_hosts`; la primera conexión debe confirmar la nueva huella mostrada por SSH. Un mero apagado y encendido conserva la clave y no modifica `known_hosts`.

La configuración versionada vive en `config/ollama.example.yaml`; los valores locales se guardan en `config/ollama.local.yaml`, excluido de Git. `ollama.ps1 status` muestra el endpoint privado que debe configurarse en `/home/rstudio/.posit/ai/providers.json`.

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

`research_ssh_cidr` define el único origen IPv4 autorizado para SSH. El flujo crea una regla TCP/22 para ese CIDR, adjunta el security group de investigación y retira de la VM el grupo de bootstrap cuando ambos son distintos.

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
6. configurar backups independientes del backend de Cinder y probar su restauración;
7. mejorar la gestión local de autenticación OpenStack;
8. incorporar comprobaciones adicionales y tests de infraestructura.

El objetivo es que la infraestructura pase a ser una capa estable y que el trabajo cotidiano se concentre en los repositorios científicos y en RStudio.
