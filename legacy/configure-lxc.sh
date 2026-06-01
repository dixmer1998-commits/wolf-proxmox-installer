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

configure_dns() {
    log_step "Configurando DNS..."

    # systemd-resolved crea symlink a /run/systemd/resolve/stub-resolv.conf
    # dentro del LXC eso no funciona, reemplazar por archivo estatico
    if [[ -L /etc/resolv.conf ]] || [[ ! -f /etc/resolv.conf ]] || ! grep -q "8.8.8.8" /etc/resolv.conf 2>/dev/null; then
        rm -f /etc/resolv.conf 2>/dev/null || true
        printf "nameserver 8.8.8.8\nnameserver 8.8.4.4\n" > /etc/resolv.conf
        chmod 644 /etc/resolv.conf
        log_info "DNS configurado: 8.8.8.8, 8.8.4.4"
    fi

    if ping -c 1 archive.ubuntu.com &>/dev/null; then
        log_info "DNS funciona correctamente"
    else
        log_warn "DNS no funciona. Verifica la red del contenedor."
    fi
}

install_dependencies() {
    log_step "Instalando dependencias del sistema..."

    # Configurar DNS primero
    configure_dns

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
services:
  wolf:
    image: ghcr.io/games-on-whales/wolf:stable
    container_name: wolf
    environment:
      - WOLF_STOP_CONTAINER_ON_EXIT=TRUE
      - WOLF_RENDER_NODE=__WOLF_RENDER_NODE__
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
      test: ["CMD-SHELL", "test -S /var/run/wolf/wolf.sock || exit 1"]
      interval: 5s
      timeout: 3s
      retries: 10
      start_period: 30s

  # Proxy reverso HTTP -> Unix socket (soluciona SSE de Wolf Den)
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
COMPOSE_EOF

    sed -i "s|__WOLF_RENDER_NODE__|${WOLF_RENDER_NODE}|g" "$compose_file"

    # Configuracion del proxy reverso
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

        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }
}
PROXY_EOF

    log_info "docker-compose.yml creado en ${compose_file}"
    log_info "Proxy reverso configurado en /etc/wolf/wolf-proxy.conf"
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
echo -e "${YELLOW}Wolf API (proxy):${NC} http://${SERVER_IP}:8081"
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
    log_step "Iniciando Wolf..."

    cd /etc/wolf

    # Eliminar config previa para que Wolf genere defaults
    if [[ -f cfg/config.toml ]]; then
        log_info "Eliminando config previa para que Wolf genere defaults..."
        rm -f cfg/config.toml cfg/key.pem cfg/cert.pem 2>/dev/null || true
    fi

    # Iniciar solo Wolf primero
    docker compose up -d wolf
    log_info "Esperando que Wolf genere configuracion..."

    sleep 5

    # Verificar que Wolf genero config.toml con apps
    if [[ -f cfg/config.toml ]]; then
        if grep -q "\[\[apps\]\]" cfg/config.toml 2>/dev/null || grep -q "moonlight-profile-id" cfg/config.toml 2>/dev/null; then
            log_info "Wolf genero config con apps correctamente"
        else
            log_warn "Wolf genero config pero sin apps. Esperando 10s mas..."
            sleep 10
        fi
    else
        log_warn "Wolf aun no genero config.toml. Esperando 10s mas..."
        sleep 10
    fi

    # Verificar config final
    if [[ -f cfg/config.toml ]]; then
        log_info "Config de Wolf:"
        head -30 cfg/config.toml
    fi

    # Iniciar proxy reverso (expone socket Unix como HTTP en :8081)
    log_step "Iniciando proxy reverso nginx..."
    docker compose up -d wolf-proxy
    sleep 2

    if curl -sf http://localhost:8081/api/v1/apps -o /dev/null 2>&1; then
        log_info "Proxy HTTP en :8081 respondiendo OK"
    else
        log_warn "Proxy no responde aun, Wolf Den reintentara"
    fi

    # Iniciar Wolf Den
    log_step "Iniciando Wolf Den..."
    docker compose up -d wolf-den

    log_info "Servicios Wolf iniciados"

    sleep 3
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
    create_docker_compose
    create_pairing_helper
    create_status_helper
    start_wolf
    print_final_info
}

main "$@"
