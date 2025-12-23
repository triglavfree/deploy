#!/bin/bash
set -e

# =============== ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ===============
WG_DIR="/opt/wg-easy"
CURRENT_IP="unknown"

# =============== ЦВЕТА ===============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

# =============== ФУНКЦИИ ===============
print_step()   { echo -e "\n${PURPLE}=== ${CYAN}$1${PURPLE} ===${NC}"; }
print_success(){ echo -e "${GREEN}✓ $1${NC}"; }
print_warning(){ echo -e "${YELLOW}⚠ $1${NC}"; }
print_error()  { echo -e "${RED}✗ $1${NC}" >&2; }
print_info()   { echo -e "${BLUE}ℹ $1${NC}"; }

# =============== ПРОВЕРКА ПРАВ ===============
print_step "Проверка прав"
if [ "$(id -u)" != "0" ]; then
    print_error "Запускайте от root!"
    exit 1
fi
print_success "Запущено с правами root"

# =============== ПРОВЕРКА IP ===============
if [ -n "$SSH_CLIENT" ]; then
    CURRENT_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
elif [ -n "$SSH_CONNECTION" ]; then
    CURRENT_IP=$(echo "$SSH_CONNECTION" | awk '{print $1}')
fi

# =============== ЗАПРОС ДОМЕНА ===============
print_step "Настройка домена для панели wg-easy"
read -rp "${CYAN}Введите домен для панели wg-easy (например: vpn.example.com): ${NC}" DOMAIN
if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9](\.[a-zA-Z]{2,})+$ ]]; then
    print_error "Неверный формат домена!"
    exit 1
fi
print_success "Домен: $DOMAIN"

# =============== ГЕНЕРАЦИЯ УЧЕТНЫХ ДАННЫХ ===============
print_step "Генерация учетных данных"
WG_USER="admin"
WG_PASS=$(tr -dc 'A-Za-z0-9!@#$%^&*_-' </dev/urandom | head -c 16)
WG_SECRET=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)
WG_PORT=51820
WG_WEB_PORT=51821

# =============== ПРОВЕРКА И УСТАНОВКА DOCKER ===============
print_step "Проверка и установка Docker"
if ! command -v docker &> /dev/null; then
    print_info "Docker не установлен. Выполняется установка..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh >/dev/null 2>&1
    rm get-docker.sh
    usermod -aG docker $USER >/dev/null 2>&1 || true
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
    print_success "Docker успешно установлен"
else
    print_success "Docker уже установлен"
fi

# =============== ПРОВЕРКА И УСТАНОВКА DOCKER COMPOSE ===============
print_step "Проверка и установка Docker Compose"
if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    print_info "Docker Compose не установлен. Выполняется установка..."
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1
    print_success "Docker Compose успешно установлен"
else
    print_success "Docker Compose уже установлен"
fi

# =============== НАСТРОЙКА WG-EASY ===============
print_step "Настройка wg-easy"
mkdir -p "$WG_DIR"
cd "$WG_DIR"

# Создание docker-compose.yml для wg-easy
cat > docker-compose.yml <<EOF
version: "3.8"
services:
  wg-easy:
    image: weejewel/wg-easy
    container_name: wg-easy
    volumes:
      - .:/etc/wireguard
    ports:
      - "$WG_PORT:$WG_PORT/udp"
      - "127.0.0.1:$WG_WEB_PORT:51821"
    environment:
      WG_HOST: ${DOMAIN}
      WG_PORT: $WG_PORT
      WG_DEFAULT_ADDRESS: 10.8.0.x
      WG_DEFAULT_DNS: 1.1.1.1
      WG_ALLOWED_IPS: 0.0.0.0/0, ::/0
      WG_PERSISTENT_KEEPALIVE: 25
      WEBUI_HOST: 0.0.0.0
      WEBUI_PORT: 51821
      PASSWORD: $WG_PASS
      USERNAME: $WG_USER
      SECRET: $WG_SECRET
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.rp_filter=0
    restart: unless-stopped
EOF

print_success "Конфигурация wg-easy создана"

# =============== ЗАПУСК WG-EASY ===============
print_step "Запуск wg-easy"
docker compose up -d --force-recreate >/dev/null 2>&1
print_success "wg-easy успешно запущен"

# =============== УСТАНОВКА CADDY ===============
print_step "Установка Caddy reverse proxy"
if ! command -v caddy &> /dev/null; then
    print_info "Caddy не установлен. Выполняется установка..."
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl >/dev/null 2>&1
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq caddy >/dev/null 2>&1
    print_success "Caddy успешно установлен"
else
    print_success "Caddy уже установлен"
fi

# =============== НАСТРОЙКА CADDY ===============
print_step "Настройка Caddy"
mkdir -p /etc/caddy
cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
    reverse_proxy localhost:$WG_WEB_PORT
    encode gzip zstd
    log {
        output file /var/log/caddy/wg-easy.log
    }
}
EOF

# Перезапуск Caddy
systemctl restart caddy >/dev/null 2>&1
print_success "Caddy настроен для $DOMAIN"

# =============== НАСТРОЙКА ФАЙРЕВОЛА ===============
print_step "Настройка файрвола UFW"
if [ -n "$CURRENT_IP" ]; then
    ufw allow from "$CURRENT_IP" to any port $WG_PORT proto udp comment "WireGuard" >/dev/null 2>&1 || true
else
    ufw allow $WG_PORT/udp comment "WireGuard" >/dev/null 2>&1 || true
fi
ufw allow http comment "Caddy HTTP" >/dev/null 2>&1 || true
ufw allow https comment "Caddy HTTPS" >/dev/null 2>&1 || true
ufw reload >/dev/null 2>&1 || true
print_success "Порты открыты в файрволе"

# =============== ПРОВЕРКА СОСТОЯНИЯ ===============
print_step "Проверка состояния сервисов"
sleep 5
if docker inspect wg-easy --format='{{.State.Running}}' 2>/dev/null | grep -q "true"; then
    print_success "wg-easy работает"
else
    print_error "wg-easy не запущен!"
fi

if systemctl is-active --quiet caddy; then
    print_success "Caddy работает"
else
    print_error "Caddy не запущен!"
fi

# =============== ФИНАЛЬНАЯ ИНФОРМАЦИЯ ===============
print_step "ФИНАЛЬНАЯ ИНФОРМАЦИЯ"
EXTERNAL_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "неизвестен")

echo -e "\n${GREEN}Установка завершена успешно!${NC}\n"

print_info "📌 WireGuard сервер: ${EXTERNAL_IP}:${WG_PORT}"
print_info "🌐 Панель управления: https://${DOMAIN}"
print_info "👤 Пользователь: ${WG_USER}"
print_info "🔑 Пароль: ${WG_PASS}"

echo -e "\n${YELLOW}Важно:${NC}"
print_info "1. Убедитесь, что DNS запись ${DOMAIN} указывает на ${EXTERNAL_IP}"
print_info "2. Дождитесь получения SSL сертификата (1-2 минуты после настройки DNS)"
print_info "3. Для доступа к панели откройте: https://${DOMAIN}"

print_info "\n${CYAN}Команды для управления:${NC}"
print_info "  Перезапустить wg-easy: cd ${WG_DIR} && docker compose restart"
print_info "  Посмотреть логи wg-easy: docker logs wg-easy"
print_info "  Перезапустить Caddy: systemctl restart caddy"

print_success "\n✅ Готово! Войдите в панель управления для создания клиентов."
