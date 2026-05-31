#!/bin/bash
set -uo pipefail

#=============================================================================
# Wolf (Games On Whales) - Configuracion del Contenedor LXC
# Instala Docker, Wolf, Wolf Den y helper de pairing dentro del LXC
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
    echo "║       Wolf - Configuracion del Contenedor LXC              ║"
    echo "║         Fase 3: Docker, Wolf y Wolf Den                    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[AVISO]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()    { echo -e "${BLUE}[PASO]${NC} $1"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script debe ejecutarse como root dentro del contenedor LXC"
        exit 1
    fi
}

check_lxc_environment() {
    log_step "Verificando entorno LXC..."

    if [[ ! -f /.dockerenv ]] && ! grep -q "lxc" /proc/1/cgroup 2>/dev/null; then
        log_warn "Este no parece ser un entorno de contenedor"
        read -p "Continuar de todos modos? (s/n): " confirm
        if [[ "$confirm" != "s" && "$confirm" != "S" && "$confirm" != "y" && "$confirm" != "Y" ]]; then
            exit 1
        fi
    fi

    if [[ ! -d /dev/dri ]]; then
        log_error "/dev/dri no encontrado. El GPU passthrough puede no estar configurado."
        log_error "Asegurate de que la config LXC tenga: lxc.mount.entry: /dev/dri dev/dri none bind,optional,create=dir"
        exit 1
    fi

    log_info "Dispositivos GPU encontrados:"
    ls -la /dev/dri/

    if [[ ! -c /dev/uinput ]]; then
        log_warn "/dev/uinput no encontrado. El soporte de gamepads puede no funcionar."
    else
        log_info "/dev/uinput encontrado"
    fi

    if [[ ! -c /dev/uhid ]]; then
        log_warn "/dev/uhid no encontrado. La emulacion DualSense puede no funcionar."
    else
        log_info "/dev/uhid encontrado"
    fi
}

install_dependencies() {
    log_step "Instalando dependencias del sistema..."

    apt-get update -qq
    apt-get install -y \
        curl \
        wget \
        gnupg \
        ca-certificates \
        lsb-release \
        apt-transport-https \
        software-properties-common \
        jq

    log_info "Dependencias instaladas"
}

install_docker() {
    log_step "Instalando Docker..."

    if command -v docker &>/dev/null; then
        log_info "Docker ya instalado: $(docker --version)"
    else
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
          tee /etc/apt/sources.list.d/docker.list > /dev/null

        apt-get update -qq
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin

        log_info "Docker instalado: $(docker --version)"
    fi

    systemctl enable --now docker
    log_info "Servicio Docker habilitado"
}

detect_render_node() {
    log_step "Detectando render node GPU..."

    local render_nodes=()
    for node in /dev/dri/renderD*; do
        if [[ -e "$node" ]]; then
            render_nodes+=("$node")
        fi
    done

    if [[ ${#render_nodes[@]} -eq 0 ]]; then
        log_error "No se encontraron render nodes en /dev/dri/"
        WOLF_RENDER_NODE="/dev/dri/renderD128"
    elif [[ ${#render_nodes[@]} -eq 1 ]]; then
        WOLF_RENDER_NODE="${render_nodes[0]}"
        log_info "Render node encontrado: ${WOLF_RENDER_NODE}"
    else
        log_info "Multiples render nodes encontrados:"
        for i in "${!render_nodes[@]}"; do
            local driver_link
            driver_link=$(ls -l /sys/class/drm/$(basename "${render_nodes[$i]}")/device/driver 2>/dev/null || echo "desconocido")
            echo -e "  ${i}) ${render_nodes[$i]} -> ${driver_link}"
        done

        local default_idx=0
        read -p "Seleccione render node [${default_idx}]: " node_idx
        node_idx="${node_idx:-$default_idx}"
        WOLF_RENDER_NODE="${render_nodes[$node_idx]}"
        log_info "Seleccionado: ${WOLF_RENDER_NODE}"
    fi
}

create_directories() {
    log_step "Creando directorios de Wolf..."

    mkdir -p /etc/wolf/cfg
    mkdir -p /etc/wolf/profile_data
    mkdir -p /etc/wolf/covers
    mkdir -p /etc/wolf/compatibilitytools.d
    mkdir -p /etc/wolf/wolf-den

    log_info "Directorios creados en /etc/wolf/"
}

create_wolf_config() {
    log_step "Creando configuracion de Wolf..."

    local config_file="/etc/wolf/cfg/config.toml"

    if [[ -f "$config_file" ]]; then
        log_info "La config de Wolf ya existe"
        read -p "Sobrescribir? (s/n): " overwrite
        if [[ "$overwrite" != "s" && "$overwrite" != "S" && "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
            return
        fi
    fi

    local uuid
    uuid=$(cat /proc/sys/kernel/random/uuid)

    cat > "$config_file" << EOF
hostname = "wolf"
support_hevc = true
config_version = 2
uuid = "${uuid}"

paired_clients = []
profiles = []

gstreamer = {}
EOF

    log_info "Config de Wolf creada en ${config_file}"
}

create_docker_compose() {
    log_step "Creando docker-compose.yml..."

    local compose_file="/etc/wolf/docker-compose.yml"

    if [[ -f "$compose_file" ]]; then
        log_warn "docker-compose.yml ya existe"
        read -p "Sobrescribir? (s/n): " overwrite
        if [[ "$overwrite" != "s" && "$overwrite" != "S" && "$overwrite" != "y" && "$overwrite" != "Y" ]]; then
            return
        fi
        cp "$compose_file" "${compose_file}.backup.$(date +%Y%m%d%H%M%S)"
    fi

    cat > "$compose_file" << 'COMPOSE_EOF'
version: "3"
services:
  wolf:
    image: ghcr.io/games-on-whales/wolf:stable
    container_name: wolf
    environment:
      - WOLF_STOP_CONTAINER_ON_EXIT=TRUE
      - WOLF_RENDER_NODE=__WOLF_RENDER_NODE__
      - WOLF_SOCKET_PATH=/var/run/wolf/wolf.sock
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

  wolf-den:
    image: ghcr.io/games-on-whales/wolf-den:stable
    container_name: wolf-den
    ports:
      - 8080:8080
    environment:
      - WOLF_SOCKET_PATH=/var/run/wolf/wolf.sock
    volumes:
      - /etc/wolf/wolf-den:/app/wolf-den/
      - /var/run/wolf:/var/run/wolf
      - /etc/wolf/covers:/etc/wolf/covers
      - /etc/wolf/compatibilitytools.d:/etc/wolf/compatibilitytools.d
    network_mode: host
    restart: unless-stopped
COMPOSE_EOF

    sed -i "s|__WOLF_RENDER_NODE__|${WOLF_RENDER_NODE}|g" "$compose_file"

    log_info "docker-compose.yml creado en ${compose_file}"
    echo ""
    log_info "Contenido:"
    cat "$compose_file"
    echo ""
}

create_pairing_helper() {
    log_step "Creando helper de pairing..."

    local helper_file="/usr/local/bin/wolf-pair"

    cat > "$helper_file" << 'HELPER_EOF'
#!/bin/bash
#=============================================================================
# Wolf Pairing Helper
# Muestra la URL de pairing de Moonlight en tiempo real
#=============================================================================

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              Helper de Pairing de Wolf                      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

SERVER_IP=$(hostname -I | awk '{print $1}')

echo -e "${GREEN}Pasos:${NC}"
echo -e "  1. Abre Moonlight y conecta a: ${YELLOW}${SERVER_IP}${NC}"
echo -e "  2. Moonlight mostrara un codigo PIN"
echo -e "  3. La URL de pairing aparecera abajo"
echo -e "  4. Abre la URL en tu navegador e ingresa el PIN"
echo ""
echo -e "${YELLOW}Esperando conexion de Moonlight...${NC}"
echo ""

docker logs -f wolf 2>&1 | grep --line-buffered -oP 'http://[^\s]*pin[^\s]*' | while read -r url; do
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  URL DE PAIRING:                                            ║${NC}"
    echo -e "${GREEN}║  ${url}${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
done
HELPER_EOF

    chmod +x "$helper_file"
    log_info "Helper de pairing creado en ${helper_file}"
    log_info "Uso: wolf-pair"
}

create_status_helper() {
    log_step "Creando helper de estado..."

    local helper_file="/usr/local/bin/wolf-status"

    cat > "$helper_file" << 'STATUS_EOF'
#!/bin/bash
#=============================================================================
# Wolf Status Helper
# Muestra el estado de Wolf y Wolf Den
#=============================================================================

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}=== Estado de Wolf ===${NC}"
echo ""

echo -e "${YELLOW}Contenedores Docker:${NC}"
docker ps -a --filter "name=wolf" --format "  {{.Names}}\t{{.Status}}\t{{.Ports}}"
echo ""

SERVER_IP=$(hostname -I | awk '{print $1}')
echo -e "${YELLOW}IP del Servidor:${NC} ${SERVER_IP}"
echo ""

echo -e "${YELLOW}Puertos Moonlight:${NC}"
echo "  HTTPS:   ${SERVER_IP}:47984/tcp"
echo "  HTTP:    ${SERVER_IP}:47989/tcp"
echo "  Control: ${SERVER_IP}:47999/udp"
echo "  RTSP:    ${SERVER_IP}:48010/tcp"
echo "  Video:   ${SERVER_IP}:48100/udp"
echo "  Audio:   ${SERVER_IP}:48200/udp"
echo ""

echo -e "${YELLOW}Wolf Den:${NC} http://${SERVER_IP}:8080"
echo ""

if [[ -S /var/run/wolf/wolf.sock ]]; then
    echo -e "${GREEN}Wolf socket: OK${NC}"
else
    echo -e "${RED}Wolf socket: NO ENCONTRADO (Wolf puede no estar corriendo)${NC}"
fi
STATUS_EOF

    chmod +x "$helper_file"
    log_info "Helper de estado creado en ${helper_file}"
    log_info "Uso: wolf-status"
}

start_wolf() {
    log_step "Iniciando Wolf y Wolf Den..."

    cd /etc/wolf

    docker compose pull
    docker compose up -d

    log_info "Servicios Wolf iniciados"

    sleep 5

    docker compose ps
}

print_final_info() {
    local server_ip
    server_ip=$(hostname -I | awk '{print $1}')

    echo ""
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║            Instalacion de Wolf Completada!                 ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║                                                            ║"
    echo "║  IP del Servidor: ${server_ip}                                ║"
    echo "║                                                            ║"
    echo "║  Moonlight:                                                 ║"
    echo "║    - Abre Moonlight en tu dispositivo cliente              ║"
    echo "║    - Agrega host: ${server_ip}                             ║"
    echo "║    - Ejecuta 'wolf-pair' para ver URL de pairing           ║"
    echo "║                                                            ║"
    echo "║  Wolf Den (Web UI):                                        ║"
    echo "║    http://${server_ip}:8080                                ║"
    echo "║                                                            ║"
    echo "║  Comandos utiles:                                          ║"
    echo "║    wolf-pair    - Mostrar URL de pairing para Moonlight    ║"
    echo "║    wolf-status  - Mostrar estado y puertos de Wolf         ║"
    echo "║    cd /etc/wolf && docker compose logs -f  - Ver logs      ║"
    echo "║    cd /etc/wolf && docker compose restart - Reiniciar Wolf ║"
    echo "║                                                            ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

main() {
    print_banner
    check_root
    check_lxc_environment
    install_dependencies
    install_docker
    detect_render_node
    create_directories
    create_wolf_config
    create_docker_compose
    create_pairing_helper
    create_status_helper
    start_wolf
    print_final_info
}

main "$@"
