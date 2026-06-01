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
    # Buscar template - el output de pveam es: STORAGE:TYPE/FILENAME
    template=$(pveam list local 2>/dev/null | grep "$template_pattern" | head -1 | awk '{print $1}')

    if [[ -z "$template" ]]; then
        log_warn "Template Ubuntu 24.04 no encontrado. Descargando..."
        pveam update
        template=$(pveam list local 2>/dev/null | grep "$template_pattern" | head -1 | awk '{print $1}')

        if [[ -z "$template" ]]; then
            log_error "No se encontro el template Ubuntu 24.04."
            log_error "Descargalo manualmente desde la interfaz de Proxmox: CT > Templates"
            log_error "O ejecuta: pveam update && pveam list local | grep ubuntu"
            exit 1
        fi
    fi

    # Si ya empieza con "local:" usarlo directo, sino agregar prefijo
    if [[ "$template" == local:* ]]; then
        TEMPLATE_FILE="$template"
    else
        TEMPLATE_FILE="local:vztmpl/${template}"
    fi
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

    # Disco (validar que sea numero)
    while true; do
        read -p "Tamanio del disco en GB [${CONTAINER_DISK}]: " input_disk
        DISK_INPUT="${input_disk:-$CONTAINER_DISK}"
        if [[ "$DISK_INPUT" =~ ^[0-9]+$ ]] && [[ "$DISK_INPUT" -gt 0 ]]; then
            CONTAINER_DISK="$DISK_INPUT"
            break
        fi
        log_warn "El tamanio debe ser un numero entero positivo"
    done

    # Storage (validar que no sea numero)
    while true; do
        read -p "Pool de almacenamiento [${CONTAINER_STORAGE}]: " input_storage
        STORAGE_INPUT="${input_storage:-$CONTAINER_STORAGE}"
        if [[ ! "$STORAGE_INPUT" =~ ^[0-9]+$ ]]; then
            CONTAINER_STORAGE="$STORAGE_INPUT"
            break
        fi
        log_warn "El pool debe ser un nombre (ej: local-lvm), no un numero"
    done

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
        # Auto-detectar red del host para sugerir defaults
        local host_ip
        host_ip=$(ip -4 addr show vmbr0 2>/dev/null | grep inet | awk '{print $2}' | head -1)
        local host_net
        host_net=$(echo "$host_ip" | cut -d. -f1-3)
        local host_gw
        host_gw=$(ip route 2>/dev/null | grep default | awk '{print $3}')
        host_gw="${host_gw:-${host_net}.1}"
        local suggested_ip="${host_net}.100/24"

        read -p "Direccion IP (CIDR) [${suggested_ip}]: " input_ip
        CONTAINER_IP="${input_ip:-$suggested_ip}"
        read -p "Gateway [${host_gw}]: " input_gateway
        CONTAINER_GATEWAY="${input_gateway:-$host_gw}"
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

    # Verificar si ya existe
    if pct status "$CONTAINER_ID" &>/dev/null; then
        log_warn "El contenedor ${CONTAINER_ID} ya existe"
        read -p "Eliminar contenedor existente y recrear? (s/n): " input_delete
        if [[ "$input_delete" == "s" || "$input_delete" == "S" ]]; then
            pct stop "$CONTAINER_ID" 2>/dev/null
            pct destroy "$CONTAINER_ID" --purge
            log_info "Contenedor ${CONTAINER_ID} eliminado"
        else
            log_info "Usando contenedor existente"
            return 0
        fi
    fi

    # Construir parametro de red
    local net_param="name=eth0,bridge=vmbr0"
    if [[ "$USE_DHCP" == "s" || "$USE_DHCP" == "S" || "$USE_DHCP" == "y" || "$USE_DHCP" == "Y" ]]; then
        net_param="${net_param},ip=dhcp"
    else
        net_param="${net_param},ip=${CONTAINER_IP},gw=${CONTAINER_GATEWAY}"
    fi

    # Crear el contenedor
    if ! pct create "$CONTAINER_ID" "$TEMPLATE_FILE" \
        --hostname "$CONTAINER_HOSTNAME" \
        --password "$CONTAINER_PASSWORD" \
        --unprivileged 0 \
        --memory "$CONTAINER_RAM" \
        --swap "$CONTAINER_SWAP" \
        --cores "$CONTAINER_CORES" \
        --rootfs "${CONTAINER_STORAGE}:${CONTAINER_DISK}" \
        --net0 "$net_param" \
        --ostype ubuntu \
        --onboot 1; then
        log_error "Error al crear el contenedor LXC"
        exit 1
    fi

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

# Nesting para systemd 255+ y Docker
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: c 10:200 rwm

# Mount entries para GPU y acceso a dispositivos
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /run/udev mnt/udev none bind,optional,create=dir
lxc.mount.entry: /dev mnt/dev none bind,optional,create=dir
EOF

    # Configurar DNS dentro del contenedor antes de iniciarlo
    pct exec "$CONTAINER_ID" -- bash -c "if [ -L /etc/resolv.conf ] || [ ! -f /etc/resolv.conf ]; then rm -f /etc/resolv.conf 2>/dev/null || true; printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n' > /etc/resolv.conf; chmod 644 /etc/resolv.conf; fi" 2>/dev/null || true

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
    local started=0
    while [[ $retries -gt 0 ]]; do
        if pct exec "$CONTAINER_ID" -- echo "ready" &>/dev/null; then
            log_info "Contenedor listo"
            started=1
            break
        fi
        sleep 2
        retries=$((retries - 1))
    done

    if [[ $started -eq 0 ]]; then
        log_warn "El contenedor puede estar iniciando. Verifica con: pct status ${CONTAINER_ID}"
        return 1
    fi

    # Esperar IP del contenedor
    log_info "Obteniendo direccion IP..."
    local container_ip=""
    for i in $(seq 1 15); do
        container_ip=$(pct exec "$CONTAINER_ID" -- hostname -I 2>/dev/null | awk '{print $1}')
        if [[ -n "$container_ip" ]]; then
            log_info "IP obtenida via DHCP: ${container_ip}"
            CONTAINER_IP="${container_ip}"
            USE_DHCP="s"
            return 0
        fi
        sleep 2
    done

    # DHCP fallo, configurar IP estatica automaticamente
    log_warn "DHCP no asigno IP al contenedor. Configurando IP estatica..."

    local host_net
    host_net=$(ip -4 addr show vmbr0 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | cut -d. -f1-3)
    local host_gw
    host_gw=$(ip route 2>/dev/null | grep default | awk '{print $3}')

    if [[ -z "$host_net" ]]; then
        log_error "No se pudo detectar la red del host"
        return 1
    fi

    local suggested_ip="${host_net}.100"
    local suggested_gw="${host_gw:-${host_net}.1}"

    pct exec "$CONTAINER_ID" -- ip addr add "${suggested_ip}/24" dev eth0 2>/dev/null
    pct exec "$CONTAINER_ID" -- ip link set eth0 up 2>/dev/null
    pct exec "$CONTAINER_ID" -- ip route add default via "$suggested_gw" 2>/dev/null

    # Re-configurar DNS
    pct exec "$CONTAINER_ID" -- bash -c "rm -f /etc/resolv.conf 2>/dev/null; printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n' > /etc/resolv.conf; chmod 644 /etc/resolv.conf" 2>/dev/null || true

    USE_DHCP="n"
    CONTAINER_IP="${suggested_ip}/24"
    CONTAINER_GATEWAY="$suggested_gw"
    log_info "IP estatica configurada: ${CONTAINER_IP}"
}

print_next_steps() {
    local container_ip
    container_ip=$(echo "$CONTAINER_IP" | cut -d'/' -f1)

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
