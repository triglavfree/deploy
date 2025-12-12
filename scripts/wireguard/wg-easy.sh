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
APP_DIR="/opt/wg-easy"
WG_USER="wg-easy"

echo -e "${PURPLE}==================================================${NC}"
echo -e "${CYAN}WG-EASY + CADDY УСТАНОВКА (ОФИЦИАЛЬНЫЙ МЕТОД)${NC}"
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
apt install -y curl wget gnupg lsb-release ca-certificates net-tools ufw fail2ban unzip git
print_success "Система обновлена"

# =============== ШАГ 2: СИСТЕМНЫЕ ОПТИМИЗАЦИИ ===============
print_step "Шаг 2: Системные оптимизации для слабого VPS"

# 2.1. Настройка ядра для WireGuard (официальный метод)
print_step "Настройка ядра для WireGuard"
cat >> /etc/sysctl.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
net.ipv6.conf.all.disable_ipv6=0
net.ipv6.conf.all.forwarding=1
net.ipv6.conf.default.forwarding=1
EOF

# 2.2. Включение BBR
echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf

# 2.3. Сетевая оптимизация
cat >> /etc/sysctl.conf <<EOF
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
net.core.netdev_max_backlog=30000
net.ipv4.tcp_notsent_lowat=16384
net.ipv4.tcp_no_metrics_save=1
net.ipv4.tcp_fastopen=3
net.ipv4.tcp_slow_start_after_idle=0
EOF

sysctl -p
print_success "Ядро настроено для WireGuard и оптимизировано"

# 2.4. Создание swap файла 2GB
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

# 2.5. Оптимизация NVMe/SSD
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

# =============== ШАГ 5: УСТАНОВКА WG-EASY (ОФИЦИАЛЬНЫЙ МЕТОД) ===============
print_step "Шаг 5: Установка wg-easy (официальный метод)"

# Создание пользователя для wg-easy с домашней директорией
if ! id -u "$WG_USER" &>/dev/null; then
    useradd -r -m -d "/var/lib/$WG_USER" -s /bin/false "$WG_USER"
    print_success "Пользователь $WG_USER создан с домашней директорией"
else
    if [ ! -d "/var/lib/$WG_USER" ]; then
        mkdir -p "/var/lib/$WG_USER"
        chown "$WG_USER:$WG_USER" "/var/lib/$WG_USER"
        usermod -d "/var/lib/$WG_USER" "$WG_USER"
        print_success "Создана домашняя директория для существующего пользователя $WG_USER"
    fi
fi

chown "$WG_USER:$WG_USER" "/var/lib/$WG_USER"
chmod 700 "/var/lib/$WG_USER"

# Создание директории и установка с правами пользователя
mkdir -p "$APP_DIR"
chown "$WG_USER:$WG_USER" "$APP_DIR"

# Очистка существующих директорий перед клонированием
if [ -d "$APP_DIR/repo" ]; then
    print_warning "Директория $APP_DIR/repo уже существует. Очищаем..."
    rm -rf "$APP_DIR/repo"
fi

if [ -d "$APP_DIR/app" ]; then
    print_warning "Директория $APP_DIR/app уже существует. Очищаем..."
    rm -rf "$APP_DIR/app"
fi

if [ -d "$APP_DIR/node_modules" ]; then
    print_warning "Директория $APP_DIR/node_modules уже существует. Очищаем..."
    rm -rf "$APP_DIR/node_modules"
fi

# Установка Node.js 18.x LTS (требуется для wg-easy)
print_step "Установка Node.js 18.x LTS (требуется для wg-easy)"
apt remove -y nodejs npm
curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_18.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list
apt update && apt install -y nodejs
npm install -g npm@9.6.7  # Совместимая версия npm
print_success "Node.js 18.x LTS установлен"

# Клонирование репозитория
print_step "Клонирование репозитория wg-easy..."
sudo -u "$WG_USER" env HOME="/var/lib/$WG_USER" git clone https://github.com/wg-easy/wg-easy "$APP_DIR/repo"
cd "$APP_DIR/repo"

# Добавление директории в safe.directory
sudo -u "$WG_USER" env HOME="/var/lib/$WG_USER" git config --global --add safe.directory "$APP_DIR/repo"

# Проверка доступных веток и тегов
print_step "Проверка доступных веток и тегов..."
AVAILABLE_BRANCHES=$(sudo -u "$WG_USER" env HOME="/var/lib/$WG_USER" git branch -a 2>/dev/null | grep -v 'HEAD' || true)
AVAILABLE_TAGS=$(sudo -u "$WG_USER" env HOME="/var/lib/$WG_USER" git tag -l 2>/dev/null || true)

echo -e "${CYAN}Доступные ветки:${NC} $AVAILABLE_BRANCHES"
echo -e "${CYAN}Доступные теги:${NC} $AVAILABLE_TAGS"

# Выбор версии v14.0.0 (стабильная версия)
if sudo -u "$WG_USER" env HOME="/var/lib/$WG_USER" git show-ref --tags v14.0.0 &>/dev/null; then
    print_success "Стабильный тег v14.0.0 найден"
    sudo -u "$WG_USER" env HOME="/var/lib/$WG_USER" git checkout v14.0.0
else
    print_error "Тег v14.0.0 не найден. Проверьте доступные теги."
fi

# Проверка структуры репозитория
print_step "Проверка структуры репозитория..."
if [ -d "src" ]; then
    print_success "Обнаружена классическая структура (директория src)"
    
    # Создание app директории
    sudo -u "$WG_USER" mkdir -p "$APP_DIR/app"
    
    # Копирование файлов из src
    sudo -u "$WG_USER" cp -r src/* "$APP_DIR/app/"
    
    # Копирование package.json и package-lock.json из корня репозитория
    sudo -u "$WG_USER" cp package.json package-lock.json "$APP_DIR/app/" 2>/dev/null || true
    
    # Установка зависимостей
    cd "$APP_DIR/app"
    print_step "Установка зависимостей для классической структуры..."
    
    # Установка всех зависимостей
    sudo -u "$WG_USER" env HOME="/var/lib/$WG_USER" npm install --omit=dev
    
    print_success "Зависимости установлены для классической структуры"
    
    # Проверка, где находится node_modules
    print_step "Проверка расположения node_modules..."
    if [ -d "node_modules" ]; then
        print_success "node_modules найдены в $APP_DIR/app/node_modules"
        
        # Создание директории node_modules в родительской папке (официальный метод)
        sudo -u "$WG_USER" mkdir -p "$APP_DIR/node_modules"
        
        # Копирование node_modules в родительскую директорию
        sudo -u "$WG_USER" cp -r node_modules/* "$APP_DIR/node_modules/"
        print_success "node_modules успешно скопированы в $APP_DIR/node_modules/"
    else
        print_warning "node_modules не найдены в $APP_DIR/app. Ищем в других местах..."
        
        # Поиск node_modules в других возможных местах
        if [ -d "$APP_DIR/repo/node_modules" ]; then
            sudo -u "$WG_USER" mkdir -p "$APP_DIR/node_modules"
            sudo -u "$WG_USER" cp -r "$APP_DIR/repo/node_modules"/* "$APP_DIR/node_modules/"
            print_success "node_modules скопированы из $APP_DIR/repo/node_modules"
        elif [ -d "$APP_DIR/repo/src/node_modules" ]; then
            sudo -u "$WG_USER" mkdir -p "$APP_DIR/node_modules"
            sudo -u "$WG_USER" cp -r "$APP_DIR/repo/src/node_modules"/* "$APP_DIR/node_modules/"
            print_success "node_modules скопированы из $APP_DIR/repo/src/node_modules"
        else
            print_error "node_modules не найдены ни в одном месте. Установка зависимостей не удалась."
        fi
    fi
else
    print_error "Не удалось определить структуру репозитория. Ожидалась директория 'src'"
fi

# Генерация случайного пароля
RANDOM_PASSWORD=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 16)

# Создание .env файла
cat > "$APP_DIR/app/.env" <<EOF
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

chown "$WG_USER:$WG_USER" "$APP_DIR/app/.env"
print_success ".env файл создан с русским языком"

# Проверка наличия node_modules
if [ ! -d "$APP_DIR/node_modules" ] || [ -z "$(ls -A "$APP_DIR/node_modules" 2>/dev/null)" ]; then
    print_warning "node_modules директория пуста или отсутствует. Выполняем повторную установку..."
    cd "$APP_DIR/app"
    
    # Полная переустановка зависимостей
    sudo -u "$WG_USER" env HOME="/var/lib/$WG_USER" npm install --force
    
    # Повторное копирование node_modules
    if [ -d "node_modules" ]; then
        sudo -u "$WG_USER" mkdir -p "$APP_DIR/node_modules"
        sudo -u "$WG_USER" cp -r node_modules/* "$APP_DIR/node_modules/"
        print_success "node_modules успешно установлены и скопированы при повторной попытке"
    else
        print_error "Не удалось установить node_modules даже при повторной попытке. Проверьте логи npm."
    fi
fi

# =============== ШАГ 6: SYSTEMD СЕРВИС (ОФИЦИАЛЬНЫЙ ШАБЛОН) ===============
print_step "Шаг 6: Настройка systemd сервиса (официальный шаблон)"

# Загрузка официального шаблона сервиса
curl -sLo /etc/systemd/system/wg-easy.service https://raw.githubusercontent.com/wg-easy/wg-easy/main/wg-easy.service

# Модификация шаблона под нашу конфигурацию
sed -i "s|/path/to/wireguard-easy|$APP_DIR/app|g" /etc/systemd/system/wg-easy.service
sed -i "s|user = .*|user = $WG_USER|g" /etc/systemd/system/wg-easy.service
sed -i "s|group = .*|group = $WG_USER|g" /etc/systemd/system/wg-easy.service
sed -i "s|Environment=PORT=.*|Environment=PORT=51821|g" /etc/systemd/system/wg-easy.service
sed -i "s|Environment=WEBUI_HOST=.*|Environment=WEBUI_HOST=0.0.0.0|g" /etc/systemd/system/wg-easy.service
sed -i "s|EnvironmentFile=.*|EnvironmentFile=$APP_DIR/app/.env|g" /etc/systemd/system/wg-easy.service

# Замена всех оставшихся 'REPLACEME' на реальные пути
sed -i "s|REPLACEME|$APP_DIR|g" /etc/systemd/system/wg-easy.service

# Перезагрузка systemd и запуск сервиса
systemctl daemon-reload
systemctl enable wg-easy
systemctl start wg-easy

# Проверка статуса
sleep 5
if systemctl is-active --quiet wg-easy; then
    print_success "wg-easy сервис запущен успешно"
else
    print_error "wg-easy сервис не запустился. Проверьте журналы: journalctl -u wg-easy -f"
fi

# =============== ШАГ 7: УСТАНОВКА CADDY ===============
print_step "Шаг 7: Установка Caddy как reverse proxy"

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

# =============== ШАГ 8: НАСТРОЙКА БЕЗОПАСНОСТИ ===============
print_step "Шаг 8: Настройка безопасности (UFW + Fail2Ban)"

# 8.1. Настройка UFW
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh comment "SSH Access"
ufw allow http comment "HTTP for Let's Encrypt"
ufw allow https comment "HTTPS for wg-easy"
ufw allow 51820/udp comment "WireGuard VPN"
ufw --force enable
print_success "UFW настроен"

# 8.2. Настройка Fail2Ban
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

# =============== ШАГ 9: NF.TABLES ДЛЯ NAT ===============
print_step "Шаг 9: Настройка nftables для NAT"

apt install -y nftables
systemctl enable nftables

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

# Проверка портов
echo -e "${CYAN}Проверка открытых портов:${NC}"
ss -tulpn | grep -E ':(22|80|443|51820|51821)' || true

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
echo -e "  ${GREEN}journalctl -u wg-easy -f${NC}    # Просмотр логов wg-easy"
echo ""
echo -e "${YELLOW}Важно:${NC}"
echo -e "1. ${CYAN}Подождите 2-3 минуты${NC} для получения SSL сертификата Let's Encrypt"
echo -e "2. ${CYAN}Проверьте DNS запись${NC} для $DOMAIN - она должна указывать на IP этого сервера"
echo -e "3. ${CYAN}Для добавления клиентов${NC} используйте веб-интерфейс по адресу https://$DOMAIN"
echo -e "4. ${CYAN}Для резервного копирования${NC} сохраните содержимое $APP_DIR/app и $APP_DIR/node_modules"
echo ""
echo -e "${YELLOW}Обновление wg-easy (официальный метод):${NC}"
echo -e "  ${GREEN}cd $APP_DIR/repo${NC}"
echo -e "  ${GREEN}sudo -u $WG_USER git pull${NC}"
echo -e "  ${GREEN}sudo -u $WG_USER git checkout production 2>/dev/null || sudo -u $WG_USER git checkout main${NC}"
echo -e "  ${GREEN}rm -rf $APP_DIR/app $APP_DIR/node_modules${NC}"
echo -e "  ${GREEN}sudo -u $WG_USER mkdir -p $APP_DIR/app${NC}"
echo -e "  ${GREEN}sudo -u $WG_USER cp -r src/* $APP_DIR/app/${NC}"
echo -e "  ${GREEN}cd $APP_DIR/app${NC}"
echo -e "  ${GREEN}sudo -u $WG_USER npm ci --omit=dev${NC}"
echo -e "  ${GREEN}sudo -u $WG_USER cp -r node_modules $APP_DIR/${NC}"
echo -e "  ${GREEN}chown -R $WG_USER:$WG_USER $APP_DIR/app $APP_DIR/node_modules${NC}"
echo -e "  ${GREEN}systemctl restart wg-easy${NC}"
echo ""
echo -e "${PURPLE}==================================================${NC}"
echo -e "${GREEN}УСТАНОВКА ЗАВЕРШЕНА!${NC}"
echo -e "${PURPLE}==================================================${NC}"
