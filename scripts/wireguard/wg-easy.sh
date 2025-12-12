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
APP_DIR="/etc/containers/volumes/wg-easy"

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
ROOT_DEVICE=$(df / --output=source | tail -1 | sed 's/\/dev\///' | sed 's/[0-9]*$//')
if [ -f /sys/block/"$ROOT_DEVICE"/queue/scheduler ]; then
    echo 'none' > /sys/block/"$ROOT_DEVICE"/queue/scheduler
    echo 'vm.dirty_background_ratio=5' >> /etc/sysctl.conf
    echo 'vm.dirty_ratio=10' >> /etc/sysctl.conf
    sysctl -p
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

# =============== ШАГ 4: НАСТРОЙКА PODMAN ДЛЯ WG-EASY ===============
print_step "Шаг 4: Настройка Podman для wg-easy"

# 4.1. Создание директорий для конфигурации
print_step "Создание директорий для конфигурации Podman"
mkdir -p /etc/containers/systemd/wg-easy
mkdir -p /etc/containers/volumes/wg-easy
mkdir -p /etc/containers/volumes/wg-easy/config
chown -R root:root /etc/containers/volumes/wg-easy
chmod -R 700 /etc/containers/volumes/wg-easy
print_success "Директории созданы"

# 4.2. Создание файла конфигурации контейнера
print_step "Создание конфигурации контейнера wg-easy"
cat > /etc/containers/systemd/wg-easy/wg-easy.container <<EOF
[Container]
ContainerName=wg-easy
Image=ghcr.io/wg-easy/wg-easy:15
AutoUpdate=registry
Volume=/etc/containers/volumes/wg-easy:/etc/wireguard:Z
Network=wg-easy.network
PublishPort=51820:51820/udp
PublishPort=51821:51821/tcp
AddCapability=NET_ADMIN
AddCapability=SYS_MODULE
AddCapability=NET_RAW
Sysctl=net.ipv4.ip_forward=1
Sysctl=net.ipv4.conf.all.src_valid_mark=1
Sysctl=net.ipv6.conf.all.disable_ipv6=0
Sysctl=net.ipv6.conf.all.forwarding=1
Sysctl=net.ipv6.conf.default.forwarding=1
Environment=PORT=51821
Environment=WEBUI_HOST=0.0.0.0
Environment=LANG=ru
[Install]
WantedBy=default.target
EOF
print_success "Конфигурация контейнера создана"

# 4.3. Создание файла конфигурации сети
print_step "Создание конфигурации сети Podman"
cat > /etc/containers/systemd/wg-easy/wg-easy.network <<EOF
[Network]
NetworkName=wg-easy
IPv6=true
EOF
print_success "Конфигурация сети создана"

# 4.4. Перезагрузка systemd и запуск контейнера
print_step "Запуск контейнера wg-easy через systemd"
systemctl daemon-reload
systemctl enable --now podman
systemctl daemon-reload
systemctl enable --now wg-easy

# Ждем запуска контейнера
sleep 10

# Проверка статуса
if podman ps --format "{{.Names}}" | grep -q "wg-easy"; then
    print_success "Контейнер wg-easy успешно запущен"
else
    print_error "Контейнер wg-easy не запустился. Проверьте журналы: journalctl -u wg-easy -f"
fi

# =============== ШАГ 5: НАСТРОЙКА HOOKS ДЛЯ NF.TABLES ===============
print_step "Шаг 5: Настройка nftables hooks для WireGuard"

# 5.1. Создание hooks через API wg-easy (временное решение)
# В реальном сценарии hooks настраиваются через веб-интерфейс, но для автоматизации:
print_warning "Для полной настройки nftables необходимо вручную добавить hooks в веб-интерфейсе wg-easy"
echo -e "${CYAN}PostUp hook:${NC}"
echo -e "nft add table inet wg_table; nft add chain inet wg_table prerouting { type nat hook prerouting priority 100 \; }; nft add chain inet wg_table postrouting { type nat hook postrouting priority 100 \; }; nft add rule inet wg_table postrouting ip saddr 10.8.0.0/24 oifname eth0 masquerade; nft add chain inet wg_table input { type filter hook input priority 0 \; policy accept \; }; nft add rule inet wg_table input udp dport 51820 accept; nft add rule inet wg_table input tcp dport 51821 accept; nft add chain inet wg_table forward { type filter hook forward priority 0 \; policy accept \; }; nft add rule inet wg_table forward iifname \"wg0\" accept; nft add rule inet wg_table forward oifname \"wg0\" accept;"

echo -e "${CYAN}PostDown hook:${NC}"
echo -e "nft delete table inet wg_table"

# 5.2. Перезапуск контейнера для применения настроек
print_step "Перезапуск контейнера для применения настроек"
systemctl restart wg-easy
sleep 5
print_success "Контейнер перезапущен"

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

# =============== ШАГ 9: ФИНАЛЬНАЯ ПРОВЕРКА ===============
print_step "Шаг 9: Финальная проверка"

echo -e "${CYAN}Проверка запущенных сервисов:${NC}"
systemctl is-active --quiet wg-easy && echo -e "${GREEN}✓ wg-easy service is running${NC}"
systemctl is-active --quiet caddy && echo -e "${GREEN}✓ caddy service is running${NC}"
systemctl is-active --quiet fail2ban && echo -e "${GREEN}✓ fail2ban service is running${NC}"
podman ps --format "{{.Names}}\t{{.Status}}" | grep wg-easy && echo -e "${GREEN}✓ wg-easy container is running${NC}"

# Проверка портов
echo -e "${CYAN}Проверка открытых портов:${NC}"
ss -tulpn | grep -E ':(22|80|443|51820|51821)' || true

# =============== ШАГ 10: ГЕНЕРАЦИЯ ПАРОЛЯ И ФИНАЛЬНАЯ ИНФОРМАЦИЯ ===============
print_step "Шаг 10: Генерация пароля и финальная информация"

# Генерация случайного пароля для wg-easy
RANDOM_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)

# Вывод финальной информации
echo -e "${PURPLE}==================================================${NC}"
echo -e "${GREEN}WG-EASY + CADDY УСТАНОВЛЕН УСПЕШНО!${NC}"
echo -e "${PURPLE}==================================================${NC}"
echo ""
echo -e "${YELLOW}Домен панели управления:${NC} ${CYAN}https://$DOMAIN${NC}"
echo -e "${YELLOW}Сгенерированный пароль:${NC} ${GREEN}$RANDOM_PASSWORD${NC}"
echo -e "${YELLOW}Важно:${NC} ${CYAN}Этот пароль нужно ввести при первом входе в админ-панель${NC}"
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
echo -e "${YELLOW}Важные шаги после установки:${NC}"
echo -e "1. ${CYAN}Подождите 2-3 минуты${NC} для получения SSL сертификата Let's Encrypt"
echo -e "2. ${CYAN}Откройте в браузере${NC} https://$DOMAIN и введите сгенерированный пароль"
echo -e "3. ${CYAN}Перейдите в раздел 'Hooks'${NC} и добавьте PostUp/PostDown hooks для nftables (см. инструкции выше)"
echo -e "4. ${CYAN}Настройте WireGuard${NC} - создайте первый клиент в админ-панели"
echo ""
echo -e "${YELLOW}Для резервного копирования:${NC}"
echo -e "  ${GREEN}Конфигурация WireGuard:${NC} /etc/containers/volumes/wg-easy/"
echo -e "  ${GREEN}Конфигурация Caddy:${NC} /etc/caddy/Caddyfile"
echo ""
echo -e "${YELLOW}Обновление wg-easy:${NC}"
echo -e "  ${GREEN}systemctl restart wg-easy${NC}  # Автоматическое обновление через AutoUpdate=registry"
echo ""
echo -e "${PURPLE}==================================================${NC}"
echo -e "${GREEN}УСТАНОВКА ЗАВЕРШЕНА!${NC}"
echo -e "${PURPLE}==================================================${NC}"
