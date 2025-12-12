#!/bin/bash
set -e

# =============== ЦВЕТА ДЛЯ ВЫВОДА ===============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# =============== ПРОВЕРКА ПАРАМЕТРОВ ===============
if [ $# -ne 1 ]; then
    echo -e "${RED}Ошибка: Требуется доменное имя${NC}"
    echo -e "Использование: ${CYAN}curl -s https://raw.githubusercontent.com/yourusername/yourrepo/main/install-wg-easy.sh | sudo bash -s your-domain.com${NC}"
    echo -e "Пример: ${CYAN}curl -s https://raw.githubusercontent.com/yourusername/yourrepo/main/install-wg-easy.sh | sudo bash -s wg-easy.example.com${NC}"
    exit 1
fi

DOMAIN="$1"
EMAIL="admin@$DOMAIN"

echo -e "${PURPLE}==================================================${NC}"
echo -e "${CYAN}WG-EASY + CADDY УСТАНОВКА${NC}"
echo -e "${YELLOW}Домен: ${GREEN}$DOMAIN${NC}"
echo -e "${YELLOW}Email для Let's Encrypt: ${GREEN}$EMAIL${NC}"
echo -e "${PURPLE}==================================================${NC}"

# =============== ПРОВЕРКА ПРАВ И СИСТЕМЫ ===============
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}Этот скрипт должен запускаться с правами root!${NC}"
    exit 1
fi

if [ ! -f /etc/os-release ]; then
    echo -e "${RED}Не удалось определить операционную систему!${NC}"
    exit 1
fi

source /etc/os-release
if [ "$ID" != "ubuntu" ] || [ "$VERSION_ID" != "24.04" ]; then
    echo -e "${YELLOW}Внимание: Скрипт протестирован на Ubuntu 24.04 LTS${NC}"
    echo -e "${YELLOW}Ваша система: ${ID} ${VERSION_ID}${NC}"
    echo -e "${YELLOW}Продолжить установку? (y/n)${NC}"
    read -r response
    if [[ "$response" != "y" && "$response" != "Y" ]]; then
        exit 1
    fi
fi

# =============== ФУНКЦИИ ВЫВОДА С ЦВЕТАМИ ===============
function print_step() {
    echo -e "${PURPLE}=== ${CYAN}$1${PURPLE} ===${NC}"
}

function print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

function print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

function print_error() {
    echo -e "${RED}✗ $1${NC}"
    exit 1
}

# =============== ШАГ 1: ОБНОВЛЕНИЕ СИСТЕМЫ ===============
print_step "Шаг 1: Обновление системы и установка базовых пакетов"
apt update && apt upgrade -y
apt install -y curl wget gnupg lsb-release ca-certificates git net-tools ufw fail2ban unzip

print_success "Система обновлена"

# =============== ШАГ 2: ОПТИМИЗАЦИИ ДЛЯ СЛАБОГО VPS ===============
print_step "Шаг 2: Настройка оптимизаций системы"

# 2.1. Включение BBR
print_step "Включение BBR (TCP BBR congestion control)"
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
sysctl -p
print_success "BBR включен"

# 2.2. Создание swap файла 2GB
print_step "Создание swap файла 2GB"
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sysctl vm.swappiness=10
    sysctl vm.vfs_cache_pressure=50
    echo 'vm.swappiness=10' >> /etc/sysctl.conf
    echo 'vm.vfs_cache_pressure=50' >> /etc/sysctl.conf
    print_success "Swap файл 2GB создан"
else
    print_warning "Swap файл уже существует"
fi

# 2.3. Оптимизация NVMe/SSD
print_step "Оптимизация NVMe/SSD"
ROOT_DEVICE=$(df / --output=source | tail -1 | sed 's/\/dev\///')
if [ -f /sys/block/"$ROOT_DEVICE"/queue/scheduler ]; then
    echo 'none' > /sys/block/"$ROOT_DEVICE"/queue/scheduler
    echo 'vm.dirty_background_ratio=5' >> /etc/sysctl.conf
    echo 'vm.dirty_ratio=10' >> /etc/sysctl.conf
    print_success "NVMe/SSD оптимизация применена"
else
    print_warning "Не удалось оптимизировать NVMe/SSD (устройство не найдено)"
fi

# 2.4. Сетевая оптимизация IPv4
print_step "Сетевая оптимизация IPv4"
cat >> /etc/sysctl.conf <<EOF
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.netdev_max_backlog=30000
net.ipv4.tcp_congestion_control=bbr
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
net.ipv4.ip_forward=1
net.ipv4.conf.all.forwarding=1
net.ipv4.conf.default.forwarding=1
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
net.ipv4.conf.all.src_valid_mark=1
EOF
sysctl -p
print_success "Сетевая оптимизация применена"

# =============== ШАГ 3: УСТАНОВКА WIREGUARD ===============
print_step "Шаг 3: Установка WireGuard"
apt install -y wireguard qrencode

# Загрузка модулей ядра
modprobe wireguard
modprobe nf_nat
modprobe nf_conntrack

# Автозагрузка модулей при старте
cat > /etc/modules-load.d/wireguard.conf <<EOF
wireguard
nf_nat
nf_conntrack
EOF

print_success "WireGuard установлен"

# =============== ШАГ 4: УСТАНОВКА NODE.JS ===============
print_step "Шаг 4: Установка Node.js 20.x"
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
apt update && apt install -y nodejs
npm install -g npm@latest
print_success "Node.js 20.x установлен"

# =============== ШАГ 5: УСТАНОВКА WG-EASY ===============
print_step "Шаг 5: Установка wg-easy"

# Создание пользователя для wg-easy
if ! id -u wg-easy &>/dev/null; then
    useradd -r -s /bin/false wg-easy
    print_success "Пользователь wg-easy создан"
fi

mkdir -p /opt/wg-easy
chown wg-easy:wg-easy /opt/wg-easy
cd /opt/wg-easy

# Установка wg-easy от имени пользователя wg-easy
sudo -u wg-easy npm init -y
sudo -u wg-easy npm install wg-easy@latest

# Генерация случайного пароля
RANDOM_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)

# Создание конфигурации
cat > /opt/wg-easy/.env <<EOF
PORT=51821
WEBUI_HOST=0.0.0.0
PASSWORD=$RANDOM_PASSWORD
WG_HOST=${DOMAIN%%.*}
WG_PORT=51820
WG_DEFAULT_ADDRESS=10.8.0.x
WG_DEFAULT_DNS=1.1.1.1,8.8.8.8
WG_MTU=1420
WG_PERSISTENT_KEEPALIVE=25
LANG=ru
UI_TRAFFIC_STATS=true
UI_CHART_TYPE=bar
EOF

chown wg-easy:wg-easy /opt/wg-easy/.env

# Создание systemd сервиса
cat > /etc/systemd/system/wg-easy.service <<EOF
[Unit]
Description=WG-Easy Service
After=network.target

[Service]
Type=simple
User=wg-easy
Group=wg-easy
WorkingDirectory=/opt/wg-easy
EnvironmentFile=/opt/wg-easy/.env
ExecStart=/usr/bin/node /opt/wg-easy/node_modules/wg-easy/server.js
Restart=always
RestartSec=5
CapabilityBoundingSet=NET_ADMIN NET_RAW SYS_MODULE
AmbientCapabilities=NET_ADMIN NET_RAW SYS_MODULE

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable wg-easy
systemctl start wg-easy

print_success "wg-easy установлен и запущен"
echo -e "${YELLOW}Пароль для панели управления: ${GREEN}$RANDOM_PASSWORD${NC}"

# =============== ШАГ 6: УСТАНОВКА CADDY ===============
print_step "Шаг 6: Установка Caddy"

apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update && apt install -y caddy

# Настройка Caddyfile
cat > /etc/caddy/Caddyfile <<EOF
{
    email $EMAIL
    debug
}

$DOMAIN {
    reverse_proxy localhost:51821
    tls {
        protocols tls1.2 tls1.3
    }
    log {
        output file /var/log/caddy/wg-easy.log {
            roll_size 100MiB
            roll_keep 10
            roll_keep_for 720h
        }
        format json
    }
}
EOF

# Создание директории для логов
mkdir -p /var/log/caddy
chown -R caddy:caddy /var/log/caddy

systemctl enable caddy
systemctl restart caddy

print_success "Caddy установлен и настроен как reverse proxy"

# =============== ШАГ 7: НАСТРОЙКА БРАНДМАУЭРА UFW ===============
print_step "Шаг 7: Настройка брандмауэра UFW"

ufw default deny incoming
ufw default allow outgoing
ufw allow ssh comment "SSH Access"
ufw allow http comment "HTTP for Let's Encrypt"
ufw allow https comment "HTTPS for wg-easy"
ufw allow 51820/udp comment "WireGuard VPN"
ufw --force enable

print_success "UFW настроен"

# =============== ШАГ 8: НАСТРОЙКА FAIL2BAN ===============
print_step "Шаг 8: Настройка Fail2Ban"

# Основная конфигурация
cat > /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 86400
findtime = 3600

[caddy-auth]
enabled = true
port = http,https
filter = caddy-auth
logpath = /var/log/caddy/*.log
maxretry = 5
bantime = 3600
findtime = 600
EOF

# Фильтр для Caddy
cat > /etc/fail2ban/filter.d/caddy-auth.conf <<EOF
[Definition]
failregex = ^.*\"(GET|POST|HEAD) .*\" (401|403|429) .*\$
ignoreregex =
EOF

systemctl restart fail2ban

print_success "Fail2Ban настроен"

# =============== ШАГ 9: НАСТРОЙКА NF.TABLES ===============
print_step "Шаг 9: Настройка nftables для NAT"

apt install -y nftables
systemctl enable nftables

# Базовая конфигурация nftables
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        
        # Разрешить established/related соединения
        ct state established,related accept
        
        # Разрешить loopback
        iif lo accept
        
        # Разрешить ICMP
        icmp type echo-request limit rate 5/second accept
        icmp type { echo-reply, destination-unreachable, time-exceeded, parameter-problem } accept
        
        # Разрешить SSH
        tcp dport 22 accept
        
        # Разрешить HTTP/HTTPS для Let's Encrypt и Caddy
        tcp dport {80, 443} accept
        
        # Разрешить WireGuard
        udp dport 51820 accept
        
        # Логгирование отклоненных пакетов (опционально)
        # log prefix "DROPPED: " counter drop
    }
    
    chain forward {
        type filter hook forward priority 0; policy drop;
        
        # Разрешить forward для WireGuard
        iifname "wg0" accept
        oifname "wg0" accept
        
        # Разрешить established/related соединения
        ct state established,related accept
    }
}

table inet nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        
        # Masquerade для WireGuard
        oifname != "wg0" ip saddr 10.8.0.0/24 masquerade
    }
}
EOF

systemctl restart nftables

print_success "nftables настроен для WireGuard NAT"

# =============== ШАГ 10: ФИНАЛЬНАЯ ПРОВЕРКА ===============
print_step "Шаг 10: Финальная проверка"

echo -e "${CYAN}Проверка запущенных сервисов:${NC}"
systemctl is-active --quiet wg-easy && echo -e "${GREEN}✓ wg-easy service is running${NC}"
systemctl is-active --quiet caddy && echo -e "${GREEN}✓ caddy service is running${NC}"
systemctl is-active --quiet fail2ban && echo -e "${GREEN}✓ fail2ban service is running${NC}"
systemctl is-active --quiet nftables && echo -e "${GREEN}✓ nftables service is running${NC}"

# Проверка портов
echo -e "${CYAN}Проверка открытых портов:${NC}"
ss -tulpn | grep -E ':(22|80|443|51820|51821)'

# =============== ФИНАЛЬНАЯ ИНФОРМАЦИЯ ===============
echo -e "${PURPLE}==================================================${NC}"
echo -e "${GREEN}WG-EASY УСТАНОВЛЕН УСПЕШНО!${NC}"
echo -e "${PURPLE}==================================================${NC}"
echo ""
echo -e "${YELLOW}Домен панели управления:${NC} ${CYAN}https://$DOMAIN${NC}"
echo -e "${YELLOW}Пароль для входа:${NC} ${GREEN}$RANDOM_PASSWORD${NC}"
echo ""
echo -e "${YELLOW}Порт WireGuard:${NC} ${CYAN}51820/udp${NC}"
echo -e "${YELLOW}Порт веб-интерфейса:${NC} ${CYAN}51821 (только для локального доступа)${NC}"
echo ""
echo -e "${CYAN}Для управления сервисами:${NC}"
echo -e "  ${GREEN}systemctl restart wg-easy${NC}    # Перезапуск wg-easy"
echo -e "  ${GREEN}systemctl restart caddy${NC}     # Перезапуск Caddy"
echo -e "  ${GREEN}systemctl status wg-easy${NC}    # Проверка статуса wg-easy"
echo ""
echo -e "${YELLOW}Важно:${NC}"
echo -e "1. ${CYAN}Для первого входа подождите 1-2 минуты${NC} после завершения скрипта (Caddy получает SSL сертификат)"
echo -e "2. ${CYAN}Проверьте DNS запись${NC} для $DOMAIN - она должна указывать на IP этого сервера"
echo -e "3. ${CYAN}Если возникают проблемы${NC}, проверьте логи:"
echo -e "   ${GREEN}journalctl -u wg-easy -f${NC}    # Логи wg-easy"
echo -e "   ${GREEN}journalctl -u caddy -f${NC}      # Логи Caddy"
echo -e "   ${GREEN}tail -f /var/log/caddy/wg-easy.log${NC}  # Логи доступа"
echo ""
echo -e "${PURPLE}==================================================${NC}"
echo -e "${GREEN}УСТАНОВКА ЗАВЕРШЕНА!${NC}"
echo -e "${PURPLE}==================================================${NC}"
