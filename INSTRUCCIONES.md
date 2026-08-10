# Instrucciones de operación

Esta guía describe el estado actual de la infraestructura. Los comandos se ejecutan desde Windows, en la raíz del repositorio, con PowerShell y una sesión autenticada de OpenStack.

## 1. Preparación local

1. Comprueba las herramientas:

```powershell
openstack --version
ssh -V
```

2. Carga las variables `OS_*` fuera del repositorio y valida la sesión:

```powershell
openstack token issue
```

3. Copia `config/infrastructure.local.example.yaml` a `config/infrastructure.local.yaml`.
4. Configura un `keypair` real y `research_ssh_cidr` con la IP/CIDR desde la que te conectarás. Para una sola IP utiliza `A.B.C.D/32`.

El valor `203.0.113.10/32` del ejemplo es documental y debe sustituirse.

## 2. Primer despliegue

Crea la VM, el security group restringido, la floating IP y el volumen:

```powershell
.\scripts\research.ps1 create
```

En un volumen nuevo y vacío, ejecuta una única vez:

```powershell
.\scripts\research.ps1 init-data
```

`init-data` es destructivo. Solo continúa si OpenStack identifica inequívocamente el dispositivo, este no contiene LUKS ni otro filesystem y se escribe exactamente `INITIALIZE <nombre-del-volumen>`. Después solicita interactivamente la contraseña LUKS, crea ext4 y prepara los directorios persistentes.

Crea o rota el secreto de RStudio sin mostrar la contraseña:

```powershell
.\scripts\research.ps1 configure-rstudio
```

Despliega RStudio y abre el túnel:

```powershell
.\scripts\research.ps1 deploy-rstudio
.\scripts\research.ps1 tunnel
```

RStudio queda disponible en <http://localhost:8787>.

## 3. Uso cotidiano

```powershell
.\scripts\research.ps1 start
```

`start` crea o reconcilia recursos, monta un volumen LUKS ya inicializado, despliega RStudio y mantiene abierto el túnel SSH. No inicializa discos ni crea secretos automáticamente.

Al terminar, cierra el túnel con `Ctrl+C` y ejecuta:

```powershell
.\scripts\research.ps1 stop
```

`stop` detiene RStudio, comprueba que `/data` no esté en uso, desmonta el
filesystem, cierra LUKS y espera a que OpenStack deje la VM en `SHUTOFF`. Es
idempotente y conserva la VM, el volumen y la floating IP. Cerrar solo el túnel
no detiene el consumo de cómputo.

Comandos individuales:

| Comando | Función |
|---|---|
| `stop` | Cierra servicios y LUKS y apaga la VM conservando sus recursos |
| `create` | Garantiza VM, volumen, floating IP y security group |
| `status` | Consulta VM y volumen |
| `mount-data` | Desbloquea LUKS y monta `/data` |
| `configure-rstudio` | Crea o rota `rstudio.env` con modo 0600 |
| `deploy-rstudio` | Construye y despliega RStudio |
| `tunnel` | Abre `localhost:8787` mediante SSH |
| `ssh` | Abre una sesión SSH |
| `snapshot-data` | Crea un snapshot Cinder offline |
| `backup-data` | Crea un backup Cinder offline si el proveedor lo soporta |
| `destroy` | Elimina la VM y conserva el volumen |

## 4. Snapshot y restauración

Crea un snapshot consistente con los servicios detenidos:

```powershell
.\scripts\research.ps1 snapshot-data
```

El comando detiene RStudio, ejecuta `sync`, comprueba que no queden procesos usando `/data`, desmonta, cierra LUKS, desadjunta el volumen, crea el snapshot y vuelve a adjuntar el volumen. Después hay que ejecutar `mount-data` y `deploy-rstudio`.

Lista los snapshots:

```powershell
openstack volume snapshot list --volume research-data-01
```

Para restaurar sin sobrescribir el volumen original:

```powershell
openstack volume create --snapshot <SNAPSHOT_ID> research-data-restore-YYYYMMDD
```

La restauración debe hacerse siempre en un volumen nuevo. Verifica que puede desbloquearse, montarse y que los datos son íntegros antes de retirar ningún volumen anterior.

Los snapshots del mismo backend no sustituyen una copia independiente. Si el proveedor ofrece Cinder Backup, configura además una política de backups en almacenamiento separado y realiza pruebas periódicas de restauración.

```powershell
.\scripts\research.ps1 backup-data
openstack volume backup list
openstack volume backup restore <BACKUP_ID> <VOLUME_ID_NUEVO>
```

La disponibilidad y el destino físico de Cinder Backup dependen del proveedor. Confirma que el backend es independiente y ensaya siempre la restauración sobre un volumen nuevo.

## 5. Destrucción segura

```powershell
.\scripts\research.ps1 destroy
```

El comando exige escribir `YES`, detiene RStudio, aborta si quedan procesos usando `/data`, desmonta, cierra LUKS, desadjunta el volumen, libera la floating IP según configuración y elimina la VM. El volumen y los snapshots se conservan.

## 6. Seguridad

- No almacenes contraseñas, tokens, claves privadas, `clouds.yaml` ni configuración local en Git.
- Mantén `research_ssh_cidr` tan estrecho como sea posible.
- El security group de investigación sustituye al grupo de bootstrap después de crear o reconciliar la VM.
- RStudio solo publica en `127.0.0.1` y se accede mediante túnel SSH.
- Verifica cualquier cambio de clave SSH de host después de recrear una VM antes de ejecutar `ssh-keygen -R <IP>`.
- Conserva la contraseña LUKS en un gestor de contraseñas seguro; perderla hace irrecuperables los datos.

## 7. Problemas comunes

- **Falta `research_ssh_cidr`:** añádelo a `config/infrastructure.local.yaml`.
- **El volumen ya contiene LUKS:** no uses `init-data`; usa `mount-data`.
- **Dispositivo ambiguo:** el script cancela la inicialización; revisa el attachment en OpenStack.
- **`/data` ocupado:** detén procesos o contenedores antes de repetir snapshot o destroy.
- **Cambio de host SSH:** confirma que la VM acaba de recrearse y elimina únicamente la entrada de esa IP.
- **Snapshot no soportado:** confirma que el servicio Cinder del proveedor permite snapshots y que existe cuota.
