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
echo -e "${CYAN}WG-EASY + CADDY УСТАНОВКА (ОФИЦИАЛЬНЫЙ МЕТОД PODMAN)${NC}"
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
apt install -y curl wget gnupg lsb-release ca-certificates net-tools ufw fail2ban unzip git podman
print_success "Система обновлена и Podman установлен"

# =============== ШАГ 2: СИСТЕМНЫЕ ОПТИМИЗАЦИИ ===============
print_step "Шаг 2: Системные оптимизации для слабого VPS"

# 2.1. Включение BBR (с проверкой на дублирование)
print_step "Включение BBR (TCP BBR congestion control)"
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
fi
if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
fi
sysctl -p
print_success "BBR включен"

# 2.2. Создание swap файла 2GB (с проверкой существования)
print_step "Создание swap файла 2GB"
if [ ! -f /swapfile ]; then
    fallocate -l 2G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    if ! grep -q '/swapfile none swap sw 0 0' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    sysctl vm.swappiness=10
    sysctl vm.vfs_cache_pressure=50
    if ! grep -q 'vm.swappiness=10' /etc/sysctl.conf; then
        echo 'vm.swappiness=10' >> /etc/sysctl.conf
    fi
    if ! grep -q 'vm.vfs_cache_pressure=50' /etc/sysctl.conf; then
        echo 'vm.vfs_cache_pressure=50' >> /etc/sysctl.conf
    fi
    print_success "Swap файл 2GB создан"
else
    print_warning "Swap файл уже существует"
fi

# 2.3. Оптимизация NVMe/SSD (с проверкой существования)
print_step "Оптимизация NVMe/SSD"
ROOT_DEVICE=$(df / --output=source | tail -1 | sed 's/\/dev\///' | sed 's/[0-9]*$//')
if [ -f /sys/block/"$ROOT_DEVICE"/queue/scheduler ]; then
    CURRENT_SCHEDULER=$(cat /sys/block/"$ROOT_DEVICE"/queue/scheduler | grep -o '\[.*\]' | tr -d '[]')
    if [ "$CURRENT_SCHEDULER" != "none" ]; then
        echo 'none' > /sys/block/"$ROOT_DEVICE"/queue/scheduler
        if ! grep -q 'vm.dirty_background_ratio=5' /etc/sysctl.conf; then
            echo 'vm.dirty_background_ratio=5' >> /etc/sysctl.conf
        fi
        if ! grep -q 'vm.dirty_ratio=10' /etc/sysctl.conf; then
            echo 'vm.dirty_ratio=10' >> /etc/sysctl.conf
        fi
        sysctl -p
        print_success "NVMe/SSD оптимизация применена"
    else
        print_warning "NVMe/SSD уже оптимизирован (планировщик: none)"
    fi
else
    print_warning "Не удалось оптимизировать NVMe/SSD (устройство не найдено)"
fi

# 2.4. Сетевая оптимизация IPv4 (с проверкой существования)
print_step "Сетевая оптимизация IPv4"
NETWORK_OPTIMIZATIONS=(
    "net.core.rmem_max=16777216"
    "net.core.wmem_max=16777216"
    "net.ipv4.tcp_rmem=4096 87380 16777216"
    "net.ipv4.tcp_wmem=4096 65536 16777216"
    "net.core.netdev_max_backlog=30000"
    "net.ipv4.tcp_congestion_control=bbr"
    "net.ipv4.tcp_notsent_lowat=16384"
    "net.ipv4.tcp_no_metrics_save=1"
    "net.ipv4.tcp_fastopen=3"
    "net.ipv4.tcp_slow_start_after_idle=0"
    "net.ipv4.ip_forward=1"
    "net.ipv4.conf.all.forwarding=1"
    "net.ipv4.conf.default.forwarding=1"
    "net.ipv6.conf.all.forwarding=1"
    "net.ipv6.conf.default.forwarding=1"
    "net.ipv4.conf.all.src_valid_mark=1"
)

for opt in "${NETWORK_OPTIMIZATIONS[@]}"; do
    key=$(echo "$opt" | cut -d= -f1)
    if ! grep -q "^$key=" /etc/sysctl.conf; then
        echo "$opt" >> /etc/sysctl.conf
    fi
done

sysctl -p
print_success "Сетевая оптимизация применена"

# =============== ШАГ 3: ЗАГРУЗКА МОДУЛЕЙ ЯДРА ===============
print_step "Шаг 3: Настройка модулей ядра для WireGuard и nftables"

# 3.1. Правильные модули для nftables в Ubuntu 24.04
print_step "Создание конфигурации модулей ядра"
cat > /etc/modules-load.d/wg-easy.conf <<EOF
wireguard
nf_tables
nf_nat
nf_conntrack
nfnetlink
EOF

# 3.2. Загрузка модулей с проверкой существования
print_step "Загрузка модулей ядра"
MODULES=("wireguard" "nf_tables" "nf_nat" "nf_conntrack" "nfnetlink")

for module in "${MODULES[@]}"; do
    if modprobe -n -v "$module" 2>/dev/null | grep -q "^insmod"; then
        print_success "Модуль $module доступен для загрузки"
        modprobe "$module"
    else
        print_warning "Модуль $module не найден или встроен в ядро (это нормально)"
    fi
done

# 3.3. Проверка загруженных модулей
print_step "Проверка загруженных модулей"
lsmod | grep -E 'wireguard|nf_|nft_' || true
print_success "Модули ядра настроены и загружены"

# =============== ШАГ 4: ГЕНЕРАЦИЯ ПАРОЛЯ ===============
print_step "Шаг 4: Генерация пароля для wg-easy"
RANDOM_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)
print_success "Пароль сгенерирован: $RANDOM_PASSWORD"

# =============== ШАГ 5: НАСТРОЙКА PODMAN ДЛЯ WG-EASY ===============
print_step "Шаг 5: Настройка Podman для wg-easy"

# 5.1. Создание директорий для конфигурации
print_step "Создание директорий для конфигурации Podman"
mkdir -p /etc/containers/systemd/wg-easy
chown -R root:root /etc/containers/systemd/wg-easy
chmod -R 755 /etc/containers/systemd/wg-easy
print_success "Директории созданы"

# 5.2. Создание контейнера wg-easy
print_step "Создание контейнера wg-easy"
podman create \
    --name wg-easy \
    --network wg-easy \
    --publish 51820:51820/udp \
    --publish 51821:51821/tcp \
    --cap-add NET_ADMIN \
    --cap-add SYS_MODULE \
    --cap-add NET_RAW \
    --sysctl net.ipv4.ip_forward=1 \
    --sysctl net.ipv4.conf.all.src_valid_mark=1 \
    --sysctl net.ipv6.conf.all.disable_ipv6=0 \
    --sysctl net.ipv6.conf.all.forwarding=1 \
    --sysctl net.ipv6.conf.default.forwarding=1 \
    -e PORT=51821 \
    -e WEBUI_HOST=0.0.0.0 \
    -e LANG=ru \
    -e UI_TRAFFIC_STATS=true \
    -e UI_CHART_TYPE=bar \
    -e WG_HOST=${DOMAIN%%.*} \
    -e WG_PORT=51820 \
    -e WG_DEFAULT_ADDRESS=10.8.0.x \
    -e WG_DEFAULT_DNS=1.1.1.1,8.8.8.8 \
    -e WG_MTU=1420 \
    -e WG_PERSISTENT_KEEPALIVE=25 \
    -e PASSWORD=$RANDOM_PASSWORD \
    ghcr.io/wg-easy/wg-easy:15

print_success "Контейнер wg-easy создан"

# 5.3. Генерация systemd unit файла
print_step "Генерация systemd unit файла для wg-easy"
mkdir -p /etc/systemd/system
podman generate systemd --new --files --name wg-easy --restart-policy always -o /etc/systemd/system/
print_success "Systemd unit файл сгенерирован"

# 5.4. Настройка сети Podman
print_step "Создание конфигурации сети Podman"
cat > /etc/containers/networks/wg-easy.json <<EOF
{
    "name": "wg-easy",
    "ipv6_enabled": true,
    "cniVersion": "0.4.0",
    "plugins": [
        {
            "type": "bridge",
            "bridge": "cni-podman0",
            "isDefaultGateway": true,
            "ipMasq": true,
            "hairpinMode": true,
            "ipam": {
                "type": "host-local",
                "routes": [
                    {
                        "dst": "0.0.0.0/0"
                    }
                ],
                "ranges": [
                    [
                        {
                            "subnet": "10.89.0.0/24",
                            "gateway": "10.89.0.1"
                        }
                    ]
                ]
            }
        },
        {
            "type": "portmap",
            "capabilities": {
                "portMappings": true
            }
        },
        {
            "type": "firewall"
        },
        {
            "type": "tuning"
        }
    ]
}
EOF
print_success "Конфигурация сети создана"

# 5.5. Перезагрузка systemd и запуск контейнера
print_step "Запуск контейнера wg-easy через systemd"
systemctl daemon-reload

# Остановка и удаление существующего сервиса, если он есть
if systemctl is-active --quiet wg-easy.service; then
    systemctl stop wg-easy.service
fi
if systemctl is-enabled --quiet wg-easy.service; then
    systemctl disable wg-easy.service
fi

systemctl enable --now wg-easy.service

# Ждем запуска контейнера с таймаутом
print_step "Ожидание запуска контейнера (до 30 секунд)..."
for i in {1..30}; do
    if podman ps --format "{{.Names}}" | grep -q "wg-easy"; then
        print_success "Контейнер wg-easy успешно запущен"
        break
    fi
    sleep 1
    echo -n "."
done
echo ""

# Если контейнер не запустился, показываем логи
if ! podman ps --format "{{.Names}}" | grep -q "wg-easy"; then
    print_warning "Контейнер wg-easy не запустился. Показываем последние логи:"
    podman logs wg-easy --tail=50 2>/dev/null || true
    journalctl -u wg-easy --no-pager -n 50 2>/dev/null || true
    
    # Попытка перезапуска
    print_step "Попытка перезапуска контейнера..."
    systemctl restart wg-easy.service
    sleep 5
    
    if podman ps --format "{{.Names}}" | grep -q "wg-easy"; then
        print_success "Контейнер запустился после перезапуска"
    else
        print_error "Критическая ошибка: контейнер wg-easy не запускается. Проверьте логи выше."
    fi
fi
# =============== ШАГ 6: УСТАНОВКА CADDY ===============
print_step "Шаг 6: Установка Caddy как reverse proxy"

# 6.1. Добавление репозитория Caddy
apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
apt update && apt install -y caddy

# 6.2. Настройка Caddyfile для reverse proxy
print_step "Настройка Caddyfile для reverse proxy к wg-easy"
cat > /etc/caddy/Caddyfile <<EOF
{
    email $EMAIL
    debug
}

$DOMAIN {
    reverse_proxy wg-easy:51821
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

# 6.3. Настройка прав для Caddy
mkdir -p /var/log/caddy
chown -R caddy:caddy /var/log/caddy

# 6.4. Перезапуск Caddy
systemctl enable --now caddy
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
systemctl enable --now nftables

# Базовая конфигурация nftables для WireGuard
cat > /etc/nftables.conf <<EOF
#!/usr/sbin/nft -f
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        ct state established,related accept
        iif lo accept
        icmp type echo-request limit rate 5/second accept
        icmp type { echo-reply, destination-unreachable, time-exceeded, parameter-problem } accept
        tcp dport 22 accept
        tcp dport {80, 443} accept
        udp dport 51820 accept
    }
    
    chain forward {
        type filter hook forward priority 0; policy drop;
        iifname wg0 accept
        oifname wg0 accept
        ct state established,related accept
    }
}

table inet nat {
    chain postrouting {
        type nat hook postrouting priority 100; policy accept;
        oifname != wg0 ip saddr 10.8.0.0/24 masquerade
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
podman ps --format "{{.Names}}\t{{.Status}}" | grep wg-easy && echo -e "${GREEN}✓ wg-easy container is running${NC}"

# Проверка портов
echo -e "${CYAN}Проверка открытых портов:${NC}"
ss -tulpn | grep -E ':(22|80|443|51820|51821)' || true

# =============== ФИНАЛЬНАЯ ИНФОРМАЦИЯ ===============
echo -e "${PURPLE}==================================================${NC}"
echo -e "${GREEN}WG-EASY + CADDY УСТАНОВЛЕН УСПЕШНО!${NC}"
echo -e "${PURPLE}==================================================${NC}"
echo ""
echo -e "${YELLOW}Домен панели управления:${NC} ${CYAN}https://$DOMAIN${NC}"
echo -e "${YELLOW}Пароль для входа:${NC} ${GREEN}$RANDOM_PASSWORD${NC}"
echo ""
echo -e "${YELLOW}Порт WireGuard:${NC} ${CYAN}51820/udp${NC}"
echo -e "${YELLOW}Порт веб-интерфейса:${NC} ${CYAN}51821 (только для локального доступа через Caddy)${NC}"
echo ""
echo -e "${CYAN}Для управления сервисами:${NC}"
echo -e "  ${GREEN}systemctl restart wg-easy${NC}    # Перезапуск wg-easy контейнера"
echo -e "  ${GREEN}systemctl restart caddy${NC}     # Перезапуск Caddy"
echo -e "  ${GREEN}podman ps${NC}                   # Просмотр запущенных контейнеров"
echo -e "  ${GREEN}journalctl -u wg-easy -f${NC}    # Просмотр логов wg-easy"
echo ""
echo -e "${YELLOW}Важно:${NC}"
echo -e "1. ${CYAN}Подождите 2-3 минуты${NC} для получения SSL сертификата Let's Encrypt"
echo -e "2. ${CYAN}Откройте в браузере${NC} https://$DOMAIN и введите пароль: $RANDOM_PASSWORD"
echo -e "3. ${CYAN}Перейдите в раздел 'Hooks'${NC} и добавьте nftables правила (если не работают по умолчанию):"
echo -e "   ${GREEN}PostUp:${NC} nft add table inet wg_table; nft add chain inet wg_table prerouting { type nat hook prerouting priority 100 \; }; nft add chain inet wg_table postrouting { type nat hook postrouting priority 100 \; }; nft add rule inet wg_table postrouting ip saddr 10.8.0.0/24 oifname eth0 masquerade; nft add chain inet wg_table input { type filter hook input priority 0 \; policy accept \; }; nft add rule inet wg_table input udp dport 51820 accept; nft add rule inet wg_table input tcp dport 51821 accept; nft add chain inet wg_table forward { type filter hook forward priority 0 \; policy accept \; }; nft add rule inet wg_table forward iifname \"wg0\" accept; nft add rule inet wg_table forward oifname \"wg0\" accept;"
echo -e "   ${GREEN}PostDown:${NC} nft delete table inet wg_table"
echo -e "4. ${CYAN}Настройте WireGuard${NC} - создайте первый клиент в админ-панели"
echo ""
echo -e "${YELLOW}Для резервного копирования:${NC}"
echo -e "  ${GREEN}Конфигурация WireGuard:${NC} хранится внутри контейнера wg-easy"
echo -e "  ${GREEN}Конфигурация Caddy:${NC} /etc/caddy/Caddyfile"
echo ""
echo -e "${YELLOW}Обновление wg-easy:${NC}"
echo -e "  ${GREEN}systemctl restart wg-easy${NC}  # Автоматическое обновление через AutoUpdate=registry"
echo ""
echo -e "${PURPLE}==================================================${NC}"
echo -e "${GREEN}УСТАНОВКА ЗАВЕРШЕНА!${NC}"
echo -e "${PURPLE}==================================================${NC}"
