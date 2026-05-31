#!/bin/bash
set -uo pipefail

#=============================================================================
# Wolf (Games On Whales) - Creacion de Contenedor LXC
# Crea un contenedor LXC privilegiado con GPU passthrough para Wolf
#=============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║       Wolf - Creacion de Contenedor LXC                    ║"
    echo "║              Fase 2: Contenedor Privilegiado               ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "${BLUE}[PASO]${NC} $1"; }

# Valores por defecto
CONTAINER_ID=""
CONTAINER_HOSTNAME="wolf-gaming"
CONTAINER_RAM=14000
CONTAINER_SWAP=2048
CONTAINER_CORES=11
CONTAINER_DISK="500"
CONTAINER_STORAGE="local-lvm"
CONTAINER_PASSWORD=""
USE_DHCP="y"
CONTAINER_IP=""
CONTAINER_GATEWAY=""

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script debe ejecutarse como root"
        exit 1
    fi
}

check_proxmox() {
    if ! command -v pveversion &>/dev/null; then
        log_error "Este script debe ejecutarse en un host Proxmox VE"
        exit 1
    fi
}

find_next_id() {
    local max_id
    max_id=$(pct list | awk 'NR>1 {print $1}' | sort -n | tail -1)
    if [[ -z "$max_id" ]]; then
        echo "100"
    else
        echo $((max_id + 1))
    fi
}

check_template() {
    log_step "Buscando template Ubuntu 24.04..."

    local template_pattern="ubuntu-24.04"
    local template
    template=$(pveam list local | grep "$template_pattern" | head -1 | awk '{print $2}')

    if [[ -z "$template" ]]; then
        log_warn "Template Ubuntu 24.04 no encontrado. Descargando..."
        pveam update
        template=$(pveam list local | grep "$template_pattern" | head -1 | awk '{print $2}')

        if [[ -z "$template" ]]; then
            log_error "No se encontro el template Ubuntu 24.04. Descargalo manualmente desde la interfaz de Proxmox."
            exit 1
        fi
    fi

    TEMPLATE_FILE="local:vztmpl/${template}"
    log_info "Usando template: ${TEMPLATE_FILE}"
}

get_configuration() {
    echo -e "${CYAN}=== Configuracion del Contenedor LXC ===${NC}"
    echo ""

    # ID del contenedor
    local next_id
    next_id=$(find_next_id)
    read -p "ID del contenedor [${next_id}]: " input_id
    CONTAINER_ID="${input_id:-$next_id}"

    # Hostname
    read -p "Hostname [${CONTAINER_HOSTNAME}]: " input_hostname
    CONTAINER_HOSTNAME="${input_hostname:-$CONTAINER_HOSTNAME}"

    # Password
    while [[ -z "$CONTAINER_PASSWORD" ]]; do
        read -s -p "Password root: " CONTAINER_PASSWORD
        echo ""
        if [[ -z "$CONTAINER_PASSWORD" ]]; then
            log_warn "El password no puede estar vacio"
        fi
    done

    # Disco
    read -p "Tamanio del disco en GB [${CONTAINER_DISK}]: " input_disk
    CONTAINER_DISK="${input_disk:-$CONTAINER_DISK}"

    # Storage
    read -p "Pool de almacenamiento [${CONTAINER_STORAGE}]: " input_storage
    CONTAINER_STORAGE="${input_storage:-$CONTAINER_STORAGE}"

    # RAM
    read -p "RAM en MB [${CONTAINER_RAM}]: " input_ram
    CONTAINER_RAM="${input_ram:-$CONTAINER_RAM}"

    # CPU
    read -p "Nucleos CPU [${CONTAINER_CORES}]: " input_cores
    CONTAINER_CORES="${input_cores:-$CONTAINER_CORES}"

    # Red
    echo ""
    read -p "Usar DHCP? (s/n) [s]: " input_dhcp
    USE_DHCP="${input_dhcp:-y}"

    if [[ "$USE_DHCP" != "s" && "$USE_DHCP" != "S" && "$USE_DHCP" != "y" && "$USE_DHCP" != "Y" ]]; then
        read -p "Direccion IP (CIDR, ej: 192.168.1.100/24): " CONTAINER_IP
        read -p "Gateway: " CONTAINER_GATEWAY

        if [[ -z "$CONTAINER_IP" || -z "$CONTAINER_GATEWAY" ]]; then
            log_error "IP y gateway son requeridos para configuracion estatica"
            exit 1
        fi
    fi

    # Resumen
    echo ""
    echo -e "${CYAN}=== Resumen de Configuracion ===${NC}"
    echo -e "  ID Contenedor: ${YELLOW}${CONTAINER_ID}${NC}"
    echo -e "  Hostname:      ${YELLOW}${CONTAINER_HOSTNAME}${NC}"
    echo -e "  Disco:         ${YELLOW}${CONTAINER_DISK} GB en ${CONTAINER_STORAGE}${NC}"
    echo -e "  RAM:           ${YELLOW}${CONTAINER_RAM} MB${NC}"
    echo -e "  CPU:           ${YELLOW}${CONTAINER_CORES} nucleos${NC}"
    local net_display="DHCP"
    if [[ "$USE_DHCP" != "s" && "$USE_DHCP" != "S" && "$USE_DHCP" != "y" && "$USE_DHCP" != "Y" ]]; then
        net_display="${CONTAINER_IP} gw ${CONTAINER_GATEWAY}"
    fi
    echo -e "  Red:           ${YELLOW}${net_display}${NC}"
    echo -e "  Privilegiado:  ${YELLOW}SI${NC}"
    echo -e "  Template:      ${YELLOW}${TEMPLATE_FILE}${NC}"
    echo ""

    read -p "Proceder con la creacion? (s/n): " confirm
    if [[ "$confirm" != "s" && "$confirm" != "S" && "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_error "Cancelado por el usuario"
        exit 1
    fi
}

create_container() {
    log_step "Creando contenedor LXC ${CONTAINER_ID}..."

    # Construir parametro de red
    local net_param="name=eth0,bridge=vmbr0,hwaddr=auto"
    if [[ "$USE_DHCP" == "s" || "$USE_DHCP" == "S" || "$USE_DHCP" == "y" || "$USE_DHCP" == "Y" ]]; then
        net_param="${net_param},ip=dhcp"
    else
        net_param="${net_param},ip=${CONTAINER_IP},gw=${CONTAINER_GATEWAY}"
    fi

    # Crear el contenedor
    pct create "$CONTAINER_ID" "$TEMPLATE_FILE" \
        --hostname "$CONTAINER_HOSTNAME" \
        --password "$CONTAINER_PASSWORD" \
        --unprivileged 0 \
        --memory "$CONTAINER_RAM" \
        --swap "$CONTAINER_SWAP" \
        --cores "$CONTAINER_CORES" \
        --rootfs "${CONTAINER_STORAGE}:${CONTAINER_DISK}" \
        --net0 "$net_param" \
        --ostype ubuntu \
        --onboot 1

    log_info "Contenedor ${CONTAINER_ID} creado exitosamente"
}

configure_gpu_passthrough() {
    log_step "Configurando GPU passthrough en el LXC..."

    local config_file="/etc/pve/lxc/${CONTAINER_ID}.conf"

    if [[ ! -f "$config_file" ]]; then
        log_error "No se encontro la config del contenedor en ${config_file}"
        exit 1
    fi

    # Backup de la config original
    cp "$config_file" "${config_file}.backup.$(date +%Y%m%d%H%M%S)"

    # Agregar configuracion de GPU passthrough
    cat >> "$config_file" << 'EOF'

# === Wolf GPU Passthrough Configuration ===
# Dispositivos virtuales de entrada
dev0: /dev/uinput
dev1: /dev/uhid

# Acceso cgroup - acceso completo a dispositivos para Wolf
lxc.cgroup2.devices.allow: a
lxc.cap.drop:

# Mount entries para GPU y acceso a dispositivos
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /run/udev mnt/udev none bind,optional,create=dir
lxc.mount.entry: /dev mnt/dev none bind,optional,create=dir
EOF

    log_info "Configuracion de GPU passthrough agregada a ${config_file}"

    echo ""
    echo -e "${CYAN}Contenido de la config LXC:${NC}"
    cat "$config_file"
    echo ""
}

start_container() {
    log_step "Iniciando contenedor ${CONTAINER_ID}..."

    pct start "$CONTAINER_ID"

    log_info "Esperando que el contenedor se inicialice..."
    local retries=30
    while [[ $retries -gt 0 ]]; do
        if pct exec "$CONTAINER_ID" -- echo "ready" &>/dev/null; then
            log_info "Contenedor listo"
            return 0
        fi
        sleep 2
        retries=$((retries - 1))
    done

    log_warn "El contenedor puede estar iniciando. Verifica con: pct status ${CONTAINER_ID}"
}

print_next_steps() {
    local container_ip
    if [[ "$USE_DHCP" == "s" || "$USE_DHCP" == "S" || "$USE_DHCP" == "y" || "$USE_DHCP" == "Y" ]]; then
        container_ip=$(pct exec "$CONTAINER_ID" -- hostname -I 2>/dev/null | awk '{print $1}' || echo "<IP>")
    else
        container_ip=$(echo "$CONTAINER_IP" | cut -d'/' -f1)
    fi

    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              Contenedor LXC Creado!                        ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║                                                            ║"
    echo "║  ID Contenedor: ${CONTAINER_ID}                                         ║"
    echo "║  Hostname:      ${CONTAINER_HOSTNAME}                                 ║"
    echo "║  IP:            ${container_ip}                                       ║"
    echo "║                                                            ║"
    echo "║  Siguiente paso: Ejecutar install.sh y seleccionar Fase 3  ║"
    echo "║                                                            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

main() {
    print_banner
    check_root
    check_proxmox
    check_template
    get_configuration
    create_container
    configure_gpu_passthrough
    start_container
    print_next_steps
}

main "$@"
