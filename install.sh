#!/bin/bash
#=============================================================================
# Wolf Gaming Installer v2 - Proxmox LXC
# Instalador lineal con TUI, deteccion automatica y recomendaciones
#=============================================================================

set -uo pipefail

# ============== CONFIG ==============
LOG_LEVEL="${LOG_LEVEL:-minimal}"
WOLF_REPO="https://github.com/dixmer1998-commits/wolf-proxmox-installer.git"
WOLF_REPO_RAW="https://raw.githubusercontent.com/dixmer1998-commits/wolf-proxmox-installer/main"
LEGACY_DIR="/tmp/wolf-gow-setup-legacy"
WORK_DIR="/tmp/wolf-gow-setup"

# ============== COLORS ==============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# ============== GLOBAL STATE ==============
GPU_VENDOR=""
GPU_MODEL=""
GPU_RENDER_NODE=""
HOST_TOTAL_RAM=0
HOST_CPU_CORES=0
HOST_DISK_AVAIL=0
HOST_NET=""
HOST_GW=""
RECOMMENDED_RAM=0
RECOMMENDED_DISK=0
RECOMMENDED_CORES=0
RECOMMENDED_SWAP=0
CONTAINER_ID=""
CONTAINER_HOSTNAME="wolf-gaming"
CONTAINER_PASSWORD=""
CONTAINER_RAM=0
CONTAINER_DISK=0
CONTAINER_CORES=0
CONTAINER_SWAP=0
CONTAINER_IP=""
CONTAINER_GATEWAY=""
CONTAINER_STORAGE="local-lvm"
TEMPLATE_FILE=""

# ============== LOGGING ==============
log() {
    local level=$1
    shift
    case $level in
        done)  printf "  ${GREEN}[✓]${NC} %s\n" "$1" ;;
        start) printf "  ${BLUE}[●]${NC} %s\n" "$1" ;;
        warn)  printf "  ${YELLOW}[!]${NC} %s\n" "$1" ;;
        error) printf "  ${RED}[✗]${NC} %s\n" "$1" ;;
        info)  printf "    %s\n" "$1" ;;
        debug) [[ "$LOG_LEVEL" == "debug" ]] && printf "    [DEBUG] %s\n" "$1" ;;
    esac
}

log_section() {
    printf "\n${CYAN}── %s ──${NC}\n" "$1"
}

# ============== BANNER ==============
print_banner() {
    printf "${MAGENTA}\n"
    cat <<'EOF'
    ╔══════════════════════════════════════════════════════════════╗
    ║                                                              ║
    ║            ██╗    ██╗ ██████╗ ██╗     ███████╗               ║
    ║            ██║    ██║██╔═══██╗██║     ██╔════╝               ║
    ║            ██║ █╗ ██║██║   ██║██║     █████╗                 ║
    ║            ██║███╗██║██║   ██║██║     ██╔══╝                 ║
    ║            ╚███╔███╔╝╚██████╔╝███████╗██║                    ║
    ║             ╚══╝╚══╝  ╚═════╝ ╚══════╝╚═╝                    ║
    ║                                                              ║
    ║       🐺  Games On Whales - Proxmox LXC Installer v2         ║
    ║                                                              ║
    ╚══════════════════════════════════════════════════════════════╝
EOF
    printf "${NC}\n"
}

# ============== REQUIREMENTS ==============
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log error "Este script debe ejecutarse como root"
        echo "Uso: sudo bash $0"
        exit 1
    fi
    log done "Ejecutando como root"
}

check_proxmox() {
    if ! command -v pveversion &>/dev/null; then
        log error "Proxmox VE no detectado"
        log error "Este instalador es solo para hosts Proxmox"
        exit 1
    fi
    log done "Proxmox VE: $(pveversion | head -1 | cut -d'/' -f2)"
}

ensure_dependencies() {
    local missing=()
    for pkg in git whiptail lspci; do
        if ! command -v "$pkg" &>/dev/null; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log start "Instalando dependencias: ${missing[*]}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq 2>/dev/null
        apt-get install -y -qq "${missing[@]}" 2>/dev/null
        for pkg in "${missing[@]}"; do
            if ! command -v "$pkg" &>/dev/null; then
                log error "No se pudo instalar $pkg"
                exit 1
            fi
        done
    fi
    log done "Dependencias OK (git, whiptail, lspci)"
}

# ============== DETECTION ==============
detect_gpu() {
    log_section "Detectando hardware"

    local gpu_info
    gpu_info=$(lspci -nn 2>/dev/null | grep -E "VGA|3D" | head -1)

    if [[ -z "$gpu_info" ]]; then
        log error "No se detecto ninguna GPU"
        log error "Wolf requiere una GPU dedicada (AMD o NVIDIA)"
        exit 1
    fi

    if echo "$gpu_info" | grep -qi "AMD\|ATI"; then
        GPU_VENDOR="amd"
        GPU_MODEL=$(echo "$gpu_info" | sed 's/.*: //' | cut -d'[' -f1 | sed 's/ *$//')
    elif echo "$gpu_info" | grep -qi "NVIDIA"; then
        GPU_VENDOR="nvidia"
        GPU_MODEL=$(echo "$gpu_info" | sed 's/.*: //' | cut -d'[' -f1 | sed 's/ *$//')
    else
        log error "GPU no soportada: $gpu_info"
        log error "Solo se soportan GPUs AMD o NVIDIA"
        exit 1
    fi

    # Verificar render node
    if [[ -e /dev/dri/renderD128 ]]; then
        GPU_RENDER_NODE="/dev/dri/renderD128"
    elif ls /dev/dri/renderD* &>/dev/null 2>&1; then
        GPU_RENDER_NODE=$(ls /dev/dri/renderD* | head -1)
    else
        log error "No se encontro render node en /dev/dri/"
        log error "La GPU no esta siendo reconocida por el kernel"
        exit 1
    fi

    log done "GPU: $GPU_VENDOR - $GPU_MODEL"
    log done "Render node: $GPU_RENDER_NODE"

    # Verificar drivers NVIDIA
    if [[ "$GPU_VENDOR" == "nvidia" ]]; then
        if ! command -v nvidia-smi &>/dev/null; then
            log warn "nvidia-smi no encontrado. Instala nvidia-driver en el host."
        fi
        if ! lsmod 2>/dev/null | grep -q "^nvidia "; then
            log warn "Driver nvidia no cargado en el host"
        fi
    fi
}

detect_host_resources() {
    HOST_TOTAL_RAM=$(free -m | awk '/^Mem:/ {print $2}')
    HOST_CPU_CORES=$(nproc)

    # Disco disponible en local-lvm
    if command -v pvesm &>/dev/null; then
        local avail
        avail=$(pvesm status 2>/dev/null | awk '$1=="local-lvm" {print $4}')
        if [[ -n "$avail" ]]; then
            HOST_DISK_AVAIL=$avail
        else
            # Fallback: espacio en /
            HOST_DISK_AVAIL=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
        fi
    else
        HOST_DISK_AVAIL=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G')
    fi

    [[ -z "$HOST_DISK_AVAIL" || "$HOST_DISK_AVAIL" -eq 0 ]] && HOST_DISK_AVAIL=500

    log done "Recursos del host:"
    log info "RAM:   ${HOST_TOTAL_RAM} MB"
    log info "CPU:   ${HOST_CPU_CORES} cores"
    log info "Disco: ${HOST_DISK_AVAIL} GB disponibles"
}

calculate_recommendations() {
    # RAM: 80% del host, entre 8GB y 16GB
    RECOMMENDED_RAM=$((HOST_TOTAL_RAM * 80 / 100))
    [[ $RECOMMENDED_RAM -gt 16000 ]] && RECOMMENDED_RAM=16000
    [[ $RECOMMENDED_RAM -lt 8000 ]] && RECOMMENDED_RAM=8000

    # CPU: host - 1, entre 4 y 12
    RECOMMENDED_CORES=$((HOST_CPU_CORES - 1))
    [[ $RECOMMENDED_CORES -gt 12 ]] && RECOMMENDED_CORES=12
    [[ $RECOMMENDED_CORES -lt 4 ]] && RECOMMENDED_CORES=4

    # Disco: 80% del disponible, entre 100GB y 1TB
    RECOMMENDED_DISK=$((HOST_DISK_AVAIL * 80 / 100))
    [[ $RECOMMENDED_DISK -gt 1000 ]] && RECOMMENDED_DISK=1000
    [[ $RECOMMENDED_DISK -lt 100 ]] && RECOMMENDED_DISK=100

    # SWAP: 25% de RAM
    RECOMMENDED_SWAP=$((RECOMMENDED_RAM / 4))
    [[ $RECOMMENDED_SWAP -lt 2048 ]] && RECOMMENDED_SWAP=2048
    [[ $RECOMMENDED_SWAP -gt 8192 ]] && RECOMMENDED_SWAP=8192

    # IP sugerida
    local host_ip
    host_ip=$(ip -4 addr show vmbr0 2>/dev/null | grep "inet " | awk '{print $2}' | cut -d/ -f1)
    HOST_NET=$(echo "$host_ip" | cut -d. -f1-3)
    HOST_GW=$(ip route 2>/dev/null | grep default | awk '{print $3}')
    HOST_GW="${HOST_GW:-${HOST_NET}.1}"
    RECOMMENDED_IP="${HOST_NET}.100/24"

    log done "Recomendaciones para gaming:"
    log info "Disco: ${RECOMMENDED_DISK}GB | RAM: ${RECOMMENDED_RAM}MB | CPU: ${RECOMMENDED_CORES} cores | SWAP: ${RECOMMENDED_SWAP}MB"
    log info "IP sugerida: ${RECOMMENDED_IP}"
}

detect_template() {
    log start "Buscando template Ubuntu 24.04..."

    local template
    template=$(pveam list local 2>/dev/null | grep "ubuntu-24.04" | head -1 | awk '{print $1}')

    if [[ -z "$template" ]]; then
        log warn "Template no encontrado, descargando..."
        pveam update >/dev/null 2>&1
        template=$(pveam list local 2>/dev/null | grep "ubuntu-24.04" | head -1 | awk '{print $1}')
        if [[ -z "$template" ]]; then
            log error "No se encontro template Ubuntu 24.04"
            log error "Descargalo desde: pveam available | grep ubuntu"
            exit 1
        fi
    fi

    if [[ "$template" == local:* ]]; then
        TEMPLATE_FILE="$template"
    else
        TEMPLATE_FILE="local:vztmpl/${template}"
    fi
    log done "Template: $TEMPLATE_FILE"
}

# ============== VALIDATION (auto-correct) ==============
validate_disk() {
    local value=$1
    local min=100
    local max_safe=$((HOST_DISK_AVAIL * 90 / 100))

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        log warn "Disco invalido ('$value'), usando recomendado: ${RECOMMENDED_DISK}GB"
        echo "$RECOMMENDED_DISK"
        return 1
    fi

    if [[ $value -lt $min ]]; then
        log warn "Disco muy pequeno (${value}GB < ${min}GB), usando recomendado"
        echo "$RECOMMENDED_DISK"
        return 1
    fi

    if [[ $value -gt $max_safe ]]; then
        if ! whiptail --title "Disco alto" --yesno \
            "Has solicitado ${value}GB pero el maximo seguro es ${max_safe}GB.\n\nEsto puede llenar el storage.\n\nContinuar de todos modos?" 12 60; then
            echo "$RECOMMENDED_DISK"
            return 1
        fi
    fi

    echo "$value"
    return 0
}

validate_ram() {
    local value=$1
    local min=4096
    local max_safe=$((HOST_TOTAL_RAM * 85 / 100))

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        log warn "RAM invalida, usando recomendada: ${RECOMMENDED_RAM}MB"
        echo "$RECOMMENDED_RAM"
        return 1
    fi

    if [[ $value -lt $min ]]; then
        log warn "RAM muy pequena (${value}MB < ${min}MB), usando recomendada"
        echo "$RECOMMENDED_RAM"
        return 1
    fi

    if [[ $value -gt $max_safe ]]; then
        if ! whiptail --title "RAM alta" --yesno \
            "Has solicitado ${value}MB pero el maximo seguro es ${max_safe}MB.\n\nEl host puede quedar sin memoria.\n\nContinuar de todos modos?" 12 60; then
            echo "$RECOMMENDED_RAM"
            return 1
        fi
    fi

    echo "$value"
    return 0
}

validate_cpu() {
    local value=$1

    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        log warn "CPU invalido, usando recomendado: ${RECOMMENDED_CORES}"
        echo "$RECOMMENDED_CORES"
        return 1
    fi

    if [[ $value -lt 2 ]]; then
        log warn "CPU muy bajo (min 2), usando recomendado"
        echo "$RECOMMENDED_CORES"
        return 1
    fi

    if [[ $value -gt $HOST_CPU_CORES ]]; then
        log warn "CPU excede host (${HOST_CPU_CORES}), usando recomendado"
        echo "$RECOMMENDED_CORES"
        return 1
    fi

    echo "$value"
    return 0
}

validate_ip() {
    local value=$1
    if [[ "$value" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "$value"
        return 0
    fi
    log warn "IP invalida, usando sugerida: ${RECOMMENDED_IP}"
    echo "$RECOMMENDED_IP"
    return 1
}

# ============== WHIPTAIL INPUTS ==============
wt_get_password() {
    while true; do
        local pass1 pass2
        pass1=$(whiptail --title "Contrasena root del LXC" --passwordbox \
            "Ingresa la contrasena root para el contenedor LXC.\n\nMinimo 8 caracteres." \
            10 70 3>&1 1>&2 2>&3) || exit 0

        [[ ${#pass1} -lt 8 ]] && continue

        pass2=$(whiptail --title "Confirmar contrasena" --passwordbox \
            "Confirma la contrasena:" 10 70 3>&1 1>&2 2>&3) || exit 0

        if [[ "$pass1" == "$pass2" ]]; then
            CONTAINER_PASSWORD="$pass1"
            return 0
        fi
        whiptail --title "Error" --msgbox "Las contrasenas no coinciden." 8 50
    done
}

wt_get_disk() {
    while true; do
        local input
        input=$(whiptail --title "Disco del LXC" --inputbox \
            "Tamano del disco (GB).\n\nRecomendado: ${RECOMMENDED_DISK}GB\nDisponible: ${HOST_DISK_AVAIL}GB\nMin: 100 | Max seguro: $((HOST_DISK_AVAIL * 90 / 100))GB" \
            12 70 "$RECOMMENDED_DISK" 3>&1 1>&2 2>&3) || exit 0

        local result
        result=$(validate_disk "$input")
        CONTAINER_DISK="$result"
        return 0
    done
}

wt_get_ram() {
    while true; do
        local input
        input=$(whiptail --title "RAM del LXC" --inputbox \
            "Memoria RAM (MB).\n\nRecomendado: ${RECOMMENDED_RAM}MB\nHost: ${HOST_TOTAL_RAM}MB\nMin: 4096 | Max seguro: $((HOST_TOTAL_RAM * 85 / 100))MB" \
            12 70 "$RECOMMENDED_RAM" 3>&1 1>&2 2>&3) || exit 0

        local result
        result=$(validate_ram "$input")
        CONTAINER_RAM="$result"
        return 0
    done
}

wt_get_cpu() {
    while true; do
        local input
        input=$(whiptail --title "CPU del LXC" --inputbox \
            "Nucleos CPU.\n\nRecomendado: ${RECOMMENDED_CORES}\nHost: ${HOST_CPU_CORES}\nMin: 2 | Max: ${HOST_CPU_CORES}" \
            12 70 "$RECOMMENDED_CORES" 3>&1 1>&2 2>&3) || exit 0

        local result
        result=$(validate_cpu "$input")
        CONTAINER_CORES="$result"
        return 0
    done
}

wt_get_network() {
    while true; do
        local input
        input=$(whiptail --title "Red del LXC" --inputbox \
            "IP del LXC (formato CIDR).\n\nRed detectada: ${HOST_NET}.0/24\nGateway: ${HOST_GW}\nSugerida: ${RECOMMENDED_IP}" \
            12 70 "$RECOMMENDED_IP" 3>&1 1>&2 2>&3) || exit 0

        local result
        result=$(validate_ip "$input")
        CONTAINER_IP="$result"
        CONTAINER_GATEWAY="$HOST_GW"
        return 0
    done
}

wt_summary_menu() {
    while true; do
        local choice
        choice=$(whiptail --title "Confirmar instalacion" --menu \
            "RESUMEN DE INSTALACION\n\nGPU:    ${GPU_VENDOR} - ${GPU_MODEL}\nLXC:    ${CONTAINER_ID} (${CONTAINER_HOSTNAME})\nDisco:  ${CONTAINER_DISK}GB\nRAM:    ${CONTAINER_RAM}MB\nCPU:    ${CONTAINER_CORES} cores\nSWAP:   ${CONTAINER_SWAP}MB\nIP:     ${CONTAINER_IP}\nGW:     ${CONTAINER_GATEWAY}\n\nElige una opcion:" \
            22 76 6 \
            "1" "Proceder con la instalacion" \
            "2" "Cambiar disco" \
            "3" "Cambiar RAM" \
            "4" "Cambiar CPU" \
            "5" "Cambiar IP" \
            "6" "Cancelar" \
            3>&1 1>&2 2>&3) || exit 0

        case $choice in
            1) return 0 ;;
            2) wt_get_disk ;;
            3) wt_get_ram ;;
            4) wt_get_cpu ;;
            5) wt_get_network ;;
            6) exit 0 ;;
        esac
    done
}

# ============== GET USER CONFIG ==============
get_user_config() {
    # Auto-asignar lo que no se pregunta
    CONTAINER_ID=$(pct list 2>/dev/null | awk 'NR>1 {print $1}' | sort -n | tail -1)
    CONTAINER_ID=$((CONTAINER_ID + 1))
    [[ $CONTAINER_ID -lt 100 ]] && CONTAINER_ID=100

    CONTAINER_SWAP=$RECOMMENDED_SWAP

    wt_get_password
    wt_get_disk
    wt_get_ram
    wt_get_cpu
    wt_get_network
    wt_summary_menu
}

# ============== INSTALLATION: PHASE 1 HOST ==============
setup_host() {
    log_section "Fase 1/3: Configurando host"

    # Reglas udev
    log start "Configurando reglas udev"
    cat > /etc/udev/rules.d/85-wolf-virtual-inputs.rules <<'EOF'
KERNEL=="uinput", MODE="0666"
KERNEL=="uhid",   MODE="0666"
EOF
    udevadm control --reload-rules 2>/dev/null
    log done "Reglas udev instaladas"

    # Verificar GPU disponible
    if [[ ! -e "$GPU_RENDER_NODE" ]]; then
        log error "Render node $GPU_RENDER_NODE no encontrado"
        exit 1
    fi
    log done "GPU accesible en $GPU_RENDER_NODE"
}

# ============== INSTALLATION: PHASE 2 LXC ==============
create_lxc() {
    log_section "Fase 2/3: Creando contenedor LXC"

    # Verificar si ya existe
    if pct status "$CONTAINER_ID" &>/dev/null; then
        log warn "Contenedor $CONTAINER_ID ya existe"
        if whiptail --title "Contenedor existente" --yesno \
            "El contenedor $CONTAINER_ID ya existe.\n\nDeseas eliminarlo y recrearlo?" 10 60; then
            pct stop "$CONTAINER_ID" 2>/dev/null
            pct destroy "$CONTAINER_ID" --purge
            log done "Contenedor eliminado"
        else
            log done "Usando contenedor existente"
            start_lxc
            return
        fi
    fi

    log start "Creando contenedor LXC $CONTAINER_ID..."

    local net_param="name=eth0,bridge=vmbr0,ip=${CONTAINER_IP},gw=${CONTAINER_GATEWAY}"

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
        --onboot 1 2>&1 | grep -v "^$"; then
        log error "Error al crear el contenedor LXC"
        exit 1
    fi

    log done "Contenedor $CONTAINER_ID creado"

    # Configurar GPU passthrough
    log start "Configurando GPU passthrough"
    local config_file="/etc/pve/lxc/${CONTAINER_ID}.conf"
    cp "$config_file" "${config_file}.backup.$(date +%Y%m%d%H%M%S)"

    cat >> "$config_file" <<EOF

# === Wolf GPU Passthrough Configuration ===
dev0: /dev/uinput
dev1: /dev/uhid
lxc.cgroup2.devices.allow: a
lxc.cap.drop:
lxc.apparmor.profile: unconfined
lxc.cgroup2.devices.allow: c 10:200 rwm
lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir
lxc.mount.entry: /run/udev mnt/udev none bind,optional,create=dir
lxc.mount.entry: /dev mnt/dev none bind,optional,create=dir
EOF
    log done "GPU passthrough configurado"

    start_lxc
}

start_lxc() {
    log start "Iniciando contenedor $CONTAINER_ID..."
    pct start "$CONTAINER_ID" 2>/dev/null

    # Esperar ready
    local retries=30
    while [[ $retries -gt 0 ]]; do
        if pct exec "$CONTAINER_ID" -- echo "ready" &>/dev/null; then
            break
        fi
        sleep 2
        retries=$((retries - 1))
    done

    if [[ $retries -eq 0 ]]; then
        log error "El contenedor no respondio"
        exit 1
    fi

    # Esperar IP
    retries=15
    while [[ $retries -gt 0 ]]; do
        if pct exec "$CONTAINER_ID" -- hostname -I 2>/dev/null | grep -q "."; then
            break
        fi
        sleep 2
        retries=$((retries - 1))
    done

    # Configurar DNS (romper symlink systemd-resolved)
    pct exec "$CONTAINER_ID" -- bash -c "if [ -L /etc/resolv.conf ] || [ ! -f /etc/resolv.conf ]; then rm -f /etc/resolv.conf 2>/dev/null; printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n' > /etc/resolv.conf; chmod 644 /etc/resolv.conf; fi" 2>/dev/null

    log done "Contenedor iniciado y listo"
}

# ============== INSTALLATION: PHASE 3 WOLF ==============
install_wolf_in_lxc() {
    log_section "Fase 3/3: Instalando Wolf dentro del LXC"

    # Push del script
    log start "Copiando script al contenedor..."
    cat "$0" > /tmp/install-in-lxc.sh
    pct push "$CONTAINER_ID" /tmp/install-in-lxc.sh /tmp/install-in-lxc.sh
    log done "Script copiado"

    log start "Ejecutando instalacion dentro del LXC (puede tomar 5-10 min)..."

    if ! pct exec "$CONTAINER_ID" -- bash /tmp/install-in-lxc.sh --in-lxc; then
        log error "La instalacion dentro del LXC fallo"
        log error "Revisa los logs: pct exec $CONTAINER_ID -- docker logs wolf"
        exit 1
    fi

    log done "Wolf instalado y corriendo"
}

# ============== IN-LXC INSTALLER ==============
in_lxc_main() {
    set -uo pipefail

    # Verificar root
    if [[ $EUID -ne 0 ]]; then
        echo "Debe ejecutarse como root dentro del LXC"
        exit 1
    fi

    # Verificar LXC environment
    local is_lxc=0
    [[ -r /proc/1/environ ]] && tr '\0' '\n' < /proc/1/environ 2>/dev/null | grep -q "container=lxc" && is_lxc=1
    command -v systemd-detect-virt &>/dev/null && [[ "$(systemd-detect-virt 2>/dev/null)" == "lxc" ]] && is_lxc=1
    [[ -r /proc/1/cgroup ]] && grep -q "lxc" /proc/1/cgroup 2>/dev/null && is_lxc=1

    if [[ $is_lxc -eq 0 ]]; then
        echo "ADVERTENCIA: No se detecto entorno LXC. Continuando..."
    fi

    # Detectar render node
    local render_node="/dev/dri/renderD128"
    [[ ! -e "$render_node" ]] && render_node=$(ls /dev/dri/renderD* 2>/dev/null | head -1)

    # DNS
    if [[ -L /etc/resolv.conf ]] || [[ ! -f /etc/resolv.conf ]]; then
        rm -f /etc/resolv.conf 2>/dev/null
        printf "nameserver 8.8.8.8\nnameserver 8.8.4.4\n" > /etc/resolv.conf
        chmod 644 /etc/resolv.conf
    fi

    # Dependencias
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq curl wget gnupg ca-certificates lsb-release apt-transport-https software-properties-common jq

    # Docker
    if ! command -v docker &>/dev/null; then
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
    fi
    systemctl enable --now docker

    # Directorios
    mkdir -p /etc/wolf/cfg /etc/wolf/profile_data /etc/wolf/covers /etc/wolf/compatibilitytools.d /etc/wolf/wolf-den

    # nginx proxy reverso: expone el Unix socket de Wolf como HTTP
    # Wolf Den necesita HTTP para SSE (Server-Sent Events / updates en tiempo real).
    # El socket Unix sirve para llamadas sincronas, pero SSE solo habla HTTP.
    # Ver: https://games-on-whales.github.io/wolf/stable/dev/api.html
    cat > /etc/wolf/wolf-proxy.conf <<'PROXY_EOF'
server {
    listen 8081;

    location / {
        proxy_pass http://unix:/var/run/wolf/wolf.sock;
        proxy_http_version 1.0;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # Soporte SSE (Server-Sent Events) — critico para updates en vivo
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }
}
PROXY_EOF
    log "Proxy reverso nginx configurado en /etc/wolf/wolf-proxy.conf (puerto 8081)"

    # docker-compose
    cat > /etc/wolf/docker-compose.yml <<EOF
version: "3"
services:
  wolf:
    image: ghcr.io/games-on-whales/wolf:stable
    container_name: wolf
    environment:
      - WOLF_STOP_CONTAINER_ON_EXIT=TRUE
      - WOLF_RENDER_NODE=${render_node}
      - WOLF_SOCKET_PATH=/var/run/wolf/wolf.sock
      - WOLF_LOG_LEVEL=debug
    volumes:
      - /etc/wolf/:/etc/wolf:rw
      - /var/run/docker.sock:/var/run/docker.sock:rw
      - /mnt/dev:/dev:rw
      - /mnt/udev:/run/udev:rw
      - /var/run/wolf:/var/run/wolf
    device_cgroup_rules:
      - 'c 13:* rmw'
    devices:
      - /dev/dri
      - /dev/uinput
      - /dev/uhid
    network_mode: host
    restart: unless-stopped
    healthcheck:
      test: ["-S", "/var/run/wolf/wolf.sock"]
      interval: 5s
      timeout: 3s
      retries: 10
      start_period: 30s

  # Proxy reverso HTTP -> Unix socket de Wolf
  # Soluciona: Wolf Den SSE "Connection refused (localhost:80)"
  # Wolf expone API solo via Unix socket; Wolf Den (Blazor) necesita HTTP para SSE.
  wolf-proxy:
    image: nginx:alpine
    container_name: wolf-proxy
    ports:
      - 8081:8081
    volumes:
      - /var/run/wolf:/var/run/wolf:ro
      - /etc/wolf/wolf-proxy.conf:/etc/nginx/conf.d/default.conf:ro
    network_mode: host
    restart: unless-stopped
    depends_on:
      wolf:
        condition: service_healthy

  wolf-den:
    image: ghcr.io/games-on-whales/wolf-den:stable
    container_name: wolf-den
    ports:
      - 8080:8080
    environment:
      - WOLF_SOCKET_PATH=/var/run/wolf/wolf.sock
      # Apunta al proxy reverso para que SSE (HTTP) funcione
      - WOLF_WOLFAPI__BASEURL=http://localhost:8081
    volumes:
      - /etc/wolf/wolf-den:/app/wolf-den/
      - /var/run/wolf:/var/run/wolf
      - /etc/wolf/covers:/etc/wolf/covers
      - /etc/wolf/compatibilitytools.d:/etc/wolf/compatibilitytools.d
    network_mode: host
    restart: unless-stopped
    depends_on:
      wolf-proxy:
        condition: service_started
EOF

    # Helpers
    cat > /usr/local/bin/wolf-pair <<'EOF'
#!/bin/bash
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "Abre Moonlight y conecta a: $SERVER_IP"
echo "Esperando URL de pairing..."
docker logs -f wolf 2>&1 | grep --line-buffered -oP 'http://[^\s]*pin[^\s]*' | while read -r url; do
    echo "URL: $url"
done
EOF
    chmod +x /usr/local/bin/wolf-pair

    cat > /usr/local/bin/wolf-status <<'EOF'
#!/bin/bash
SERVER_IP=$(hostname -I | awk '{print $1}')
echo "=== Wolf Status ==="
echo "IP: $SERVER_IP"
docker ps -a --filter "name=wolf" --format "  {{.Names}}: {{.Status}}"
echo "Moonlight:   https://$SERVER_IP:47984"
echo "Wolf Den:    http://$SERVER_IP:8080"
echo "Wolf API:    http://$SERVER_IP:8081 (proxy HTTP -> Unix socket)"
echo ""
echo "Socket: $(ls -la /var/run/wolf/wolf.sock 2>/dev/null || echo 'NO ENCONTRADO')"
echo "Proxy:  $(curl -sf -o /dev/null -w '%{http_code}' http://localhost:8081/api/v1/apps 2>/dev/null || echo 'DOWN')"
EOF
    chmod +x /usr/local/bin/wolf-status

    # Iniciar Wolf (genera config.toml con apps default)
    cd /etc/wolf
    [[ -f cfg/config.toml ]] && rm -f cfg/config.toml cfg/key.pem cfg/cert.pem
    docker compose up -d wolf
    sleep 8

    # Verificar que Wolf tiene apps
    if [[ -f cfg/config.toml ]] && (grep -q "\[\[apps\]\]" cfg/config.toml 2>/dev/null || grep -q "moonlight-profile-id" cfg/config.toml 2>/dev/null); then
        echo "Wolf config OK con apps"
    else
        sleep 10
    fi

    # Iniciar proxy reverso (expone Unix socket de Wolf como HTTP en :8081)
    docker compose up -d wolf-proxy
    sleep 2

    # Verificar que el proxy responde
    if curl -sf http://localhost:8081/api/v1/apps -o /dev/null 2>&1; then
        echo "Wolf proxy HTTP OK en :8081"
    else
        echo "Aviso: proxy no responde aun, Wolf Den reintentara (no es fatal)"
    fi

    # Iniciar Wolf Den (SSE usara el proxy en :8081)
    docker compose up -d wolf-den
    sleep 3

    echo "INSTALACION EN LXC COMPLETADA"
}

# ============== FINAL SUMMARY ==============
print_final_summary() {
    local container_ip
    container_ip=$(echo "$CONTAINER_IP" | cut -d/ -f1)

    printf "${GREEN}\n"
    cat <<EOF
    ╔══════════════════════════════════════════════════════════════╗
    ║                                                              ║
    ║                  🎉  INSTALACION COMPLETA                     ║
    ║                                                              ║
    ╠══════════════════════════════════════════════════════════════╣
    ║                                                              ║
    ║  GPU:           ${GPU_VENDOR^^} - ${GPU_MODEL}
    ║  LXC:           ${CONTAINER_ID} (${CONTAINER_HOSTNAME})
    ║  IP:            ${container_ip}
    ║  Recursos:      ${CONTAINER_DISK}GB disco | ${CONTAINER_RAM}MB RAM | ${CONTAINER_CORES} cores
    ║                                                              ║
    ║  Moonlight:     Conectar a ${container_ip}
    ║  Wolf Den:      http://${container_ip}:8080
    ║  Wolf API:      http://${container_ip}:8081 (proxy)
    ║                                                              ║
    ║  Comandos (dentro del LXC):                                  ║
    ║    wolf-pair    Ver URL de pairing                          ║
    ║    wolf-status  Ver estado de Wolf                           ║
    ║    docker logs -f wolf   Ver logs                            ║
    ║                                                              ║
    ║  Proximos pasos:                                             ║
    ║    1. Abre Moonlight en tu dispositivo                       ║
    ║    2. Agrega host: ${container_ip}
    ║    3. Sigue el PIN de pairing                                ║
    ║    4. Disfruta Wolf UI + apps                                ║
    ║                                                              ║
    ╚══════════════════════════════════════════════════════════════╝
EOF
    printf "${NC}\n"
}

# ============== MAIN ==============
main() {
    # Si se ejecuta dentro del LXC
    if [[ "${1:-}" == "--in-lxc" ]]; then
        in_lxc_main
        exit $?
    fi

    print_banner

    check_root
    check_proxmox
    ensure_dependencies

    detect_gpu
    detect_host_resources
    calculate_recommendations
    detect_template

    get_user_config

    setup_host
    create_lxc
    install_wolf_in_lxc
    print_final_summary
}

main "$@"
