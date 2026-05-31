#!/bin/bash
set -euo pipefail

#=============================================================================
# Wolf (Games On Whales) - Proxmox Host Configuration
# Configures IOMMU, VFIO, GPU passthrough, and udev rules for input devices
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
    echo "║       Wolf (Games On Whales) - Host Configuration          ║"
    echo "║              Phase 1: Proxmox Host Setup                   ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "${BLUE}[STEP]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_proxmox() {
    if ! command -v pveversion &>/dev/null; then
        log_error "This script must be run on a Proxmox VE host"
        exit 1
    fi
    local pve_version
    pve_version=$(pveversion | head -1)
    log_info "Proxmox version: ${pve_version}"
}

detect_amd_gpu() {
    log_step "Detecting AMD GPU..."
    
    local gpu_line
    gpu_line=$(lspci | grep -i 'VGA.*AMD\|Display.*AMD\|3D.*AMD' | head -1)
    
    if [[ -z "$gpu_line" ]]; then
        log_error "No AMD GPU detected. This script is configured for AMD dedicated GPUs only."
        log_error "Run 'lspci | grep -i vga' to check available GPUs."
        exit 1
    fi
    
    GPU_PCI_ID=$(echo "$gpu_line" | awk '{print $1}')
    log_info "AMD GPU found: ${gpu_line}"
    
    # Find the audio device associated with the GPU (usually on the next line or nearby)
    local audio_line
    audio_line=$(lspci | grep -i "Audio.*AMD\|Multimedia.*AMD" | head -1)
    
    if [[ -z "$audio_line" ]]; then
        log_warn "No AMD audio device found. GPU audio passthrough may not work."
        AUDIO_PCI_ID=""
    else
        AUDIO_PCI_ID=$(echo "$audio_line" | awk '{print $1}')
        log_info "AMD Audio found: ${audio_line}"
    fi
    
    # Verify these are on the same IOMMU group
    local gpu_iommu audio_iommu
    gpu_iommu=$(lspci -nns "$GPU_PCI_ID" | grep -oP '\[.*\]' | tail -1)
    
    echo ""
    echo -e "${CYAN}Detected GPU PCI IDs:${NC}"
    echo -e "  GPU:   ${YELLOW}${GPU_PCI_ID}${NC}"
    [[ -n "$AUDIO_PCI_ID" ]] && echo -e "  Audio: ${YELLOW}${AUDIO_PCI_ID}${NC}"
    echo ""
    
    read -p "Are these correct? (y/n): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log_error "Aborted by user. Please check your GPU PCI IDs manually with: lspci | grep -i amd"
        exit 1
    fi
}

configure_grub() {
    log_step "Configuring GRUB for IOMMU..."
    
    local grub_file="/etc/default/grub"
    local backup="${grub_file}.backup.$(date +%Y%m%d%H%M%S)"
    
    if [[ ! -f "$grub_file" ]]; then
        log_error "GRUB config not found at ${grub_file}"
        exit 1
    fi
    
    cp "$grub_file" "$backup"
    log_info "Backup created: ${backup}"
    
    # Check if IOMMU is already configured
    if grep -q "amd_iommu=on" "$grub_file"; then
        log_info "IOMMU already configured in GRUB"
    else
        # Add IOMMU parameters
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 amd_iommu=on iommu=pt"/' "$grub_file"
        log_info "IOMMU parameters added to GRUB"
    fi
    
    log_info "Current GRUB_CMDLINE_LINUX_DEFAULT:"
    grep "GRUB_CMDLINE_LINUX_DEFAULT" "$grub_file" | head -1
}

configure_vfio() {
    log_step "Configuring VFIO modules..."
    
    # Add VFIO modules to /etc/modules
    local modules_file="/etc/modules"
    local vfio_modules=("vfio" "vfio_iommu_type1" "vfio_pci" "vfio_virqfd")
    
    for module in "${vfio_modules[@]}"; do
        if grep -q "^${module}$" "$modules_file" 2>/dev/null; then
            log_info "Module '${module}' already in ${modules_file}"
        else
            echo "$module" >> "$modules_file"
            log_info "Added module '${module}' to ${modules_file}"
        fi
    done
    
    # Configure vfio-pci with GPU IDs
    local vfio_conf="/etc/modprobe.d/vfio.conf"
    local ids="${GPU_PCI_ID}"
    [[ -n "$AUDIO_PCI_ID" ]] && ids="${GPU_PCI_ID},${AUDIO_PCI_ID}"
    
    if [[ -f "$vfio_conf" ]]; then
        cp "${vfio_conf}.backup.$(date +%Y%m%d%H%M%S)" "${vfio_conf}.bak" 2>/dev/null || true
    fi
    
    cat > "$vfio_conf" << EOF
# Wolf GPU passthrough - VFIO PCI configuration
options vfio-pci ids=${ids}
softdep radeon pre: vfio-pci
softdep amdgpu pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
EOF
    
    log_info "VFIO configuration written to ${vfio_conf}"
    log_info "GPU IDs: ${ids}"
}

blacklist_gpu_drivers() {
    log_step "Blacklisting GPU drivers for host..."
    
    local blacklist_file="/etc/modprobe.d/pve-blacklist.conf"
    
    if [[ -f "$blacklist_file" ]]; then
        if grep -q "blacklist amdgpu" "$blacklist_file"; then
            log_info "amdgpu already blacklisted"
            return
        fi
    fi
    
    cat >> "$blacklist_file" << EOF

# Wolf GPU passthrough - Blacklist host GPU drivers
blacklist radeon
blacklist amdgpu
EOF
    
    log_info "GPU drivers blacklisted in ${blacklist_file}"
}

install_firmware() {
    log_step "Installing AMD firmware..."
    
    if dpkg -l | grep -q "firmware-amd-graphics"; then
        log_info "firmware-amd-graphics already installed"
    else
        apt-get update -qq
        apt-get install -y firmware-amd-graphics
        log_info "AMD firmware installed"
    fi
}

configure_udev_input() {
    log_step "Configuring udev rules for Wolf virtual input devices..."
    
    local udev_file="/etc/udev/rules.d/85-wolf-virtual-inputs.rules"
    
    if [[ -f "$udev_file" ]]; then
        log_info "Udev rules already exist at ${udev_file}"
        read -p "Overwrite? (y/n): " overwrite
        if [[ "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
            return
        fi
    fi
    
    cat > "$udev_file" << 'UDEV_EOF'
# Wolf virtual input devices rules
# Allows Wolf to access /dev/uinput (only needed for joypad support)
KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", OPTIONS+="static_node=uinput", TAG+="uaccess"

# Allows Wolf to access /dev/uhid (only needed for DualSense emulation)
KERNEL=="uhid", GROUP="input", MODE="0660", TAG+="uaccess"

# Wolf virtual joypads
KERNEL=="hidraw*",   ATTRS{name}=="Wolf PS5 (virtual) pad", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf X-Box One (virtual) pad", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf PS5 (virtual) pad", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf gamepad (virtual) motion sensors", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
SUBSYSTEMS=="input", ATTRS{name}=="Wolf Nintendo (virtual) pad", GROUP="root", MODE="0660", ENV{ID_SEAT}="seat9"
UDEV_EOF
    
    udevadm control --reload-rules
    udevadm trigger
    log_info "Udev rules installed and reloaded"
}

update_system() {
    log_step "Updating GRUB and initramfs..."
    
    update-grub
    log_info "GRUB updated"
    
    update-initramfs -u -k all
    log_info "initramfs updated"
}

verify_iommu() {
    log_step "Verifying IOMMU configuration..."
    
    echo ""
    echo -e "${CYAN}=== Verification Summary ===${NC}"
    
    # Check GRUB
    if grep -q "amd_iommu=on" /etc/default/grub; then
        echo -e "  ${GREEN}✓${NC} IOMMU enabled in GRUB"
    else
        echo -e "  ${RED}✗${NC} IOMMU NOT enabled in GRUB"
    fi
    
    # Check VFIO modules
    local missing_modules=()
    for mod in vfio vfio_iommu_type1 vfio_pci vfio_virqfd; do
        if grep -q "^${mod}$" /etc/modules 2>/dev/null; then
            echo -e "  ${GREEN}✓${NC} Module ${mod} configured"
        else
            echo -e "  ${RED}✗${NC} Module ${mod} missing"
            missing_modules+=("$mod")
        fi
    done
    
    # Check blacklist
    if grep -q "blacklist amdgpu" /etc/modprobe.d/pve-blacklist.conf 2>/dev/null; then
        echo -e "  ${GREEN}✓${NC} amdgpu blacklisted"
    else
        echo -e "  ${YELLOW}!${NC} amdgpu not blacklisted"
    fi
    
    # Check udev rules
    if [[ -f /etc/udev/rules.d/85-wolf-virtual-inputs.rules ]]; then
        echo -e "  ${GREEN}✓${NC} Wolf udev rules installed"
    else
        echo -e "  ${RED}✗${NC} Wolf udev rules missing"
    fi
    
    # Check firmware
    if dpkg -l | grep -q "firmware-amd-graphics"; then
        echo -e "  ${GREEN}✓${NC} AMD firmware installed"
    else
        echo -e "  ${YELLOW}!${NC} AMD firmware not installed"
    fi
    
    echo ""
}

print_next_steps() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║                    REBOOT REQUIRED                         ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║                                                            ║"
    echo "║  A reboot is required for VFIO to take control of the GPU. ║"
    echo "║                                                            ║"
    echo "║  After reboot, verify with:                                ║"
    echo "║    lspci -nnk | grep -A3 ${GPU_PCI_ID}                    ║"
    echo "║                                                            ║"
    echo "║  The 'Kernel driver in use' should show 'vfio-pci'         ║"
    echo "║                                                            ║"
    echo "║  Then run: ./create-lxc.sh                                 ║"
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
    read -p "Reboot now? (y/n): " do_reboot
    if [[ "$do_reboot" == "y" || "$do_reboot" == "Y" ]]; then
        log_info "Rebooting in 5 seconds..."
        sleep 5
        reboot
    else
        print_next_steps
    fi
}

main "$@"
