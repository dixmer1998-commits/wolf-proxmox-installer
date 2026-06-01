# 🐺 Wolf (Games On Whales) - Proxmox LXC Installer

Instalador automatizado de Wolf (Games On Whales) en un contenedor LXC privilegiado de Proxmox con GPU compartida.

## Características

- **Detección automática de GPU** (AMD o NVIDIA)
- **TUI amigable** con whiptail para inputs
- **Recomendaciones automáticas** basadas en recursos del host
- **Validación de entrada** con auto-corrección
- **Instalación lineal** sin selección de fases
- **Wolf UI** + **Test ball** + **Firefox** como apps default
- **Wolf Den** opcional para gestión de perfiles vía web

## Requisitos

- Proxmox VE 8.x o 9.x
- GPU dedicada (AMD Radeon o NVIDIA)
- 8 GB RAM mínimo (16 GB recomendado)
- 50 GB disco libre mínimo
- Conexión a internet

## Uso rápido

```bash
rm -rf /tmp/wolf-gow-setup
git clone --depth 1 https://github.com/dixmer1998-commits/wolf-proxmox-installer.git /tmp/wolf-gow-setup
bash /tmp/wolf-gow-setup/install.sh
```

## Flujo de instalación

1. **Detección automática**
   - Proxmox VE
   - GPU (AMD/NVIDIA) y render node
   - Recursos del host (RAM, CPU, disco)
   - Template Ubuntu 24.04
   - Red del host (subnet, gateway)

2. **Inputs del usuario** (whiptail)
   - Contraseña root del LXC
   - Disco (default: 80% del disponible, con validación)
   - RAM (default: 80% del host, con warning si >85%)
   - CPU (default: host - 1)
   - IP (default: 192.168.x.100/24 auto-detectada)
   - Resumen con menú para cambiar valores

3. **Instalación automática**
   - Reglas udev (uinput, uhid)
   - Creación de LXC privilegiado
   - Configuración de GPU passthrough (bind mount /dev/dri)
   - Instalación de Docker
   - Creación de directorios Wolf
   - Generación de docker-compose.yml
   - Inicio de Wolf (genera apps default)
   - Inicio de Wolf Den

4. **Resumen final**
   - IPs y URLs
   - Comandos útiles (wolf-pair, wolf-status)
   - Próximos pasos

## Configuración post-instalación

Después de la instalación, dentro del LXC:

```bash
pct enter 100
wolf-pair    # Ver URL de pairing
wolf-status  # Ver estado de Wolf
```

En tu cliente Moonlight:
1. Agrega host: `IP_DEL_LXC` (mostrada al final)
2. Sigue el PIN de pairing
3. Lanza **Wolf UI** o **Test ball**

## Personalización

### Variables de entorno

| Variable | Default | Descripción |
|----------|---------|-------------|
| `LOG_LEVEL` | `minimal` | `debug` para ver todo el output |
| `WOLF_REPO` | (repo actual) | Repositorio del instalador |

### Logs

Por defecto se muestra solo lo esencial. Para depuración:

```bash
LOG_LEVEL=debug bash /tmp/wolf-gow-setup/install.sh
```

## Estructura del proyecto

```
wolf-proxmox-installer/
├── install.sh          # Script único de instalación (v2)
├── legacy/             # Scripts antiguos (backup)
│   ├── host-config.sh
│   ├── create-lxc.sh
│   └── configure-lxc.sh
└── README.md
```

## Versión Legacy (rollback)

Si la nueva versión tiene problemas, puedes usar los scripts antiguos:

```bash
# Restaurar scripts legacy
cp -r /tmp/wolf-gow-setup/legacy/* /tmp/wolf-gow-setup/
cd /tmp/wolf-gow-setup
bash install.sh
```

O desde cero:

```bash
# Clonar version anterior al refactor
git clone --depth 1 --branch legacy https://github.com/dixmer1998-commits/wolf-proxmox-installer.git /tmp/wolf-legacy
cd /tmp/wolf-legacy
bash install.sh
```

## Compatibilidad

- **Proxmox VE 8.x** ✅
- **Proxmox VE 9.x** ✅
- **Ubuntu 24.04** (template) ✅
- **AMD GPU** (Ellesmere, Navi, RDNA) ✅
- **NVIDIA GPU** (requiere nvidia-driver + nvidia-container-toolkit) ✅

## Troubleshooting

### El contenedor no obtiene IP

Si DHCP falla, el script configura automáticamente una IP estática basada en la red del host (X.X.X.100/24).

### DNS no funciona dentro del LXC

El script rompe el symlink de systemd-resolved y crea un `/etc/resolv.conf` plano con 8.8.8.8.

### Wolf no muestra apps en Moonlight

Verifica que Wolf haya generado el config:

```bash
pct exec 100 -- cat /etc/wolf/cfg/config.toml | head -30
```

Si está vacío, reinicia Wolf:

```bash
pct exec 100 -- bash -c "cd /etc/wolf && rm -f cfg/config.toml && docker compose restart wolf"
```

### Wolf Den no carga

```bash
pct exec 100 -- docker logs wolf-den
```

Si hay error de DB, elimínala y reinicia:

```bash
pct exec 100 -- bash -c "rm -f /etc/wolf/wolf-den/wolf_leash.db && docker compose restart wolf-den"
```

## Comandos útiles

Dentro del LXC:

```bash
# Ver logs de Wolf en tiempo real
docker logs -f wolf

# Reiniciar todo
cd /etc/wolf && docker compose restart

# Ver estado
wolf-status

# Obtener URL de pairing
wolf-pair

# Ver configuración
cat /etc/wolf/cfg/config.toml
```

## Licencia

MIT
