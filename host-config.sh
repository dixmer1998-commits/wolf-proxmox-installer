#!/bin/bash
set -uo pipefail

#=============================================================================
# Wolf (Games On Whales) - Configuracion del Host Proxmox
# Prepara el host para LXC con GPU compartida (NO VFIO/blacklist)
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
    echo "║       Wolf - Configuracion del Host Proxmox                ║"
    echo "║              Fase 1: Preparacion del Host                  ║"
    echo "║                                                              ║"
    echo "║  NOTA: GPU compartida (LXC) - NO bloquea el driver del host ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "${BLUE}[PASO]${NC} $1"; }

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
    local pve_version
    pve_version=$(pveversion | head -1)
    log_info "Version de Proxmox: ${pve_version}"
}

detect_amd_gpu() {
    log_step "Detectando GPU AMD..."

    local gpu_line
    gpu_line=$(lspci | grep -i 'VGA.*AMD\|Display.*AMD\|3D.*AMD' | head -1)

    if [[ -z "$gpu_line" ]]; then
        log_error "No se detecto GPU AMD. Este script es solo para GPUs AMD dedicadas."
        log_error "Ejecuta 'lspci | grep -i vga' para verificar GPUs disponibles."
        exit 1
    fi

    GPU_PCI_ID=$(echo "$gpu_line" | awk '{print $1}')
    log_info "GPU AMD encontrada: ${gpu_line}"

    echo ""
    echo -e "${CYAN}GPU detectada:${NC}"
    echo -e "  ${YELLOW}${gpu_line}${NC}"
    echo ""

    # Verificar que el driver amdgpu este cargado
    if lsmod | grep -q amdgpu; then
        log_info "Driver amdgpu esta cargado correctamente"
    else
        log_warn "Driver amdgpu no detectado. Intentando cargar..."
        modprobe amdgpu
        if lsmod | grep -q amdgpu; then
            log_info "Driver amdgpu cargado"
        else
            log_error "No se pudo cargar amdgpu. Verifica que firmware-amd-graphics este instalado."
        fi
    fi

    # Verificar dispositivos DRI
    if [[ -d /dev/dri ]]; then
        log_info "Dispositivos DRI disponibles:"
        ls -la /dev/dri/
    else
        log_error "/dev/dri no encontrado. El driver GPU no esta funcionando."
        exit 1
    fi
}

install_firmware() {
    log_step "Instalando firmware AMD..."

    if dpkg -l | grep -q "firmware-amd-graphics"; then
        log_info "firmware-amd-graphics ya instalado"
    else
        apt-get update -qq
        apt-get install -y firmware-amd-graphics
        log_info "Firmware AMD instalado"
    fi
}

configure_udev_input() {
    log_step "Configurando reglas udev para dispositivos virtuales de Wolf..."

    local udev_file="/etc/udev/rules.d/85-wolf-virtual-inputs.rules"

    if [[ -f "$udev_file" ]]; then
        log_info "Las reglas udev ya existen en ${udev_file}"
        read -p "Sobrescribir? (s/n): " overwrite
        if [[ "$overwrite" != "s" && "$overwrite" != "S" && "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
            return
        fi
    fi

    cat > "$udev_file" << 'UDEV_EOF'
# Reglas para dispositivos virtuales de Wolf
# Permite a Wolf acceder a /dev/uinput (necesario para soporte de joypads)
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput", TAG+="uaccess"

# Permite a Wolf acceder a /dev/uhid (necesario para emulacion DualSense)
KERNEL=="uhid", GROUP="input", MODE="0660", TAG+="uaccess"

# Joypads virtuales de Wolf
KERNEL=="hidraw*",   ATTRS{name}=="Wolf PS5 (virtual) pad", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf X-Box One (virtual) pad", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf PS5 (virtual) pad", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf gamepad (virtual) motion sensors", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf Nintendo (virtual) pad", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
UDEV_EOF

    udevadm control --reload-rules
    udevadm trigger
    log_info "Reglas udev instaladas y recargadas"
}

verify_host() {
    log_step "Verificando configuracion del host..."

    echo ""
    echo -e "${CYAN}=== Resumen de Verificacion ===${NC}"

    # Verificar driver amdgpu
    if lsmod | grep -q amdgpu; then
        echo -e "  ${GREEN}✓${NC} Driver amdgpu cargado"
    else
        echo -e "  ${RED}✗${NC} Driver amdgpu NO cargado"
    fi

    # Verificar dispositivos DRI
    if [[ -d /dev/dri ]]; then
        echo -e "  ${GREEN}✓${NC} Dispositivos DRI disponibles"
        ls /dev/dri/ | sed 's/^/      /'
    else
        echo -e "  ${RED}✗${NC} Dispositivos DRI no encontrados"
    fi

    # Verificar firmware
    if dpkg -l | grep -q "firmware-amd-graphics"; then
        echo -e "  ${GREEN}✓${NC} Firmware AMD instalado"
    else
        echo -e "  ${YELLOW}!${NC} Firmware AMD no instalado"
    fi

    # Verificar udev rules
    if [[ -f /etc/udev/rules.d/85-wolf-virtual-inputs.rules ]]; then
        echo -e "  ${GREEN}✓${NC} Reglas udev de Wolf instaladas"
    else
        echo -e "  ${RED}✗${NC} Reglas udev de Wolf faltantes"
    fi

    # Verificar que NO este bloqueado
    if grep -q "blacklist amdgpu" /etc/modprobe.d/pve-blacklist.conf 2>/dev/null; then
        echo -e "  ${RED}✗${NC} amdgpu esta BLOQUEADO (esto es para VMs, no LXC)"
    else
        echo -e "  ${GREEN}✓${NC} amdgpu NO bloqueado (correcto para LXC)"
    fi

    echo ""
}

print_next_steps() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              Host listo para Wolf!                         ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║                                                            ║"
    echo "║  Tu GPU AMD sigue disponible en el host.                   ║"
    echo "║  El LXC accedera a ella via /dev/dri (compartida).         ║"
    echo "║                                                            ║"
    echo "║  Siguiente paso: Ejecutar install.sh y seleccionar         ║"
    echo "║  Fase 2 (crear contenedor LXC)                             ║"
    echo "║                                                            ║"
    echo "║  sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/dixmer1998-commits/wolf-proxmox-installer/main/install.sh)\"║"
    echo "║                                                            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

main() {
    print_banner
    check_root
    check_proxmox
    install_firmware
    detect_amd_gpu
    configure_udev_input
    verify_host
    print_next_steps
}

main "$@"
