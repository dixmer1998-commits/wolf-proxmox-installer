#!/bin/bash
set -uo pipefail

#=============================================================================
# Wolf (Games On Whales) - Configuracion del Host Proxmox
# Configura IOMMU, VFIO, GPU passthrough y reglas udev para dispositivos de entrada
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

    # Buscar dispositivo de audio asociado a la GPU
    local audio_line
    audio_line=$(lspci | grep -i "Audio.*AMD\|Multimedia.*AMD" | head -1)

    if [[ -z "$audio_line" ]]; then
        log_warn "No se encontro dispositivo de audio AMD. El passthrough de audio puede no funcionar."
        AUDIO_PCI_ID=""
    else
        AUDIO_PCI_ID=$(echo "$audio_line" | awk '{print $1}')
        log_info "Audio AMD encontrado: ${audio_line}"
    fi

    echo ""
    echo -e "${CYAN}IDs PCI de la GPU detectados:${NC}"
    echo -e "  GPU:   ${YELLOW}${GPU_PCI_ID}${NC}"
    [[ -n "$AUDIO_PCI_ID" ]] && echo -e "  Audio: ${YELLOW}${AUDIO_PCI_ID}${NC}"
    echo ""

    read -p "Son correctos? (s/n): " confirm
    if [[ "$confirm" != "s" && "$confirm" != "S" && "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_error "Cancelado por el usuario. Verifica los IDs PCI con: lspci | grep -i amd"
        exit 1
    fi
}

configure_grub() {
    log_step "Configurando GRUB para IOMMU..."

    local grub_file="/etc/default/grub"
    local backup="${grub_file}.backup.$(date +%Y%m%d%H%M%S)"

    if [[ ! -f "$grub_file" ]]; then
        log_error "No se encontro la configuracion de GRUB en ${grub_file}"
        exit 1
    fi

    cp "$grub_file" "$backup"
    log_info "Backup creado: ${backup}"

    if grep -q "amd_iommu=on" "$grub_file"; then
        log_info "IOMMU ya esta configurado en GRUB"
    else
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 amd_iommu=on iommu=pt"/' "$grub_file"
        log_info "Parametros IOMMU agregados a GRUB"
    fi

    log_info "GRUB_CMDLINE_LINUX_DEFAULT actual:"
    grep "GRUB_CMDLINE_LINUX_DEFAULT" "$grub_file" | head -1
}

configure_vfio() {
    log_step "Configurando modulos VFIO..."

    local modules_file="/etc/modules"
    local vfio_modules=("vfio" "vfio_iommu_type1" "vfio_pci" "vfio_virqfd")

    for module in "${vfio_modules[@]}"; do
        if grep -q "^${module}$" "$modules_file" 2>/dev/null; then
            log_info "Modulo '${module}' ya existe en ${modules_file}"
        else
            echo "$module" >> "$modules_file"
            log_info "Modulo '${module}' agregado a ${modules_file}"
        fi
    done

    local vfio_conf="/etc/modprobe.d/vfio.conf"
    local ids="${GPU_PCI_ID}"
    [[ -n "$AUDIO_PCI_ID" ]] && ids="${GPU_PCI_ID},${AUDIO_PCI_ID}"

    cat > "$vfio_conf" << EOF
# Wolf GPU passthrough - Configuracion VFIO PCI
options vfio-pci ids=${ids}
softdep radeon pre: vfio-pci
softdep amdgpu pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
EOF

    log_info "Configuracion VFIO escrita en ${vfio_conf}"
    log_info "IDs de GPU: ${ids}"
}

blacklist_gpu_drivers() {
    log_step "Bloqueando drivers GPU del host..."

    local blacklist_file="/etc/modprobe.d/pve-blacklist.conf"

    if [[ -f "$blacklist_file" ]]; then
        if grep -q "blacklist amdgpu" "$blacklist_file"; then
            log_info "amdgpu ya esta bloqueado"
            return
        fi
    fi

    cat >> "$blacklist_file" << EOF

# Wolf GPU passthrough - Bloqueo de drivers GPU del host
blacklist radeon
blacklist amdgpu
EOF

    log_info "Drivers GPU bloqueados en ${blacklist_file}"
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

update_system() {
    log_step "Actualizando GRUB e initramfs..."

    update-grub
    log_info "GRUB actualizado"

    update-initramfs -u -k all
    log_info "initramfs actualizado"
}

verify_iommu() {
    log_step "Verificando configuracion IOMMU..."

    echo ""
    echo -e "${CYAN}=== Resumen de Verificacion ===${NC}"

    if grep -q "amd_iommu=on" /etc/default/grub; then
        echo -e "  ${GREEN}✓${NC} IOMMU habilitado en GRUB"
    else
        echo -e "  ${RED}✗${NC} IOMMU NO habilitado en GRUB"
    fi

    for mod in vfio vfio_iommu_type1 vfio_pci vfio_virqfd; do
        if grep -q "^${mod}$" /etc/modules 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} Modulo ${mod} configurado"
        else
            echo -e "  ${RED}✗${NC} Modulo ${mod} faltante"
        fi
    done

    if grep -q "blacklist amdgpu" /etc/modprobe.d/pve-blacklist.conf 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} amdgpu bloqueado"
    else
        echo -e "  ${YELLOW}!${NC} amdgpu no bloqueado"
    fi

    if [[ -f /etc/udev/rules.d/85-wolf-virtual-inputs.rules ]]; then
        echo -e "  ${GREEN}✓${NC} Reglas udev de Wolf instaladas"
    else
        echo -e "  ${RED}✗${NC} Reglas udev de Wolf faltantes"
    fi

    if dpkg -l | grep -q "firmware-amd-graphics"; then
        echo -e "  ${GREEN}✓${NC} Firmware AMD instalado"
    else
        echo -e "  ${YELLOW}!${NC} Firmware AMD no instalado"
    fi

    echo ""
}

print_next_steps() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    REINICIO REQUERIDO                      ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║                                                            ║"
    echo "║  Se necesita reiniciar para que VFIO tome control de GPU.  ║"
    echo "║                                                            ║"
    echo "║  Despues del reboot, verifica con:                         ║"
    echo "║    lspci -nnk | grep -A3 ${GPU_PCI_ID}                    ║"
    echo "║                                                            ║"
    echo "║  'Kernel driver in use' debe mostrar 'vfio-pci'            ║"
    echo "║                                                            ║"
    echo "║  Luego ejecuta: sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/dixmer1998-commits/wolf-proxmox-installer/main/install.sh)\"║"
    echo "║  y selecciona la opcion 2 o 3                              ║"
    echo "║                                                            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

main() {
    print_banner
    check_root
    check_proxmox
    detect_amd_gpu
    configure_grub
    configure_vfio
    blacklist_gpu_drivers
    install_firmware
    configure_udev_input
    update_system
    verify_iommu

    echo ""
    read -p "Reiniciar ahora? (s/n): " do_reboot
    if [[ "$do_reboot" == "s" || "$do_reboot" == "S" || "$do_reboot" == "y" || "$do_reboot" == "Y" ]]; then
        log_info "Reiniciando en 5 segundos..."
        sleep 5
        reboot
    else
        print_next_steps
    fi
}

main "$@"
