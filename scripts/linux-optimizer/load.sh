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

# =============== ФУНКЦИЯ ПРОГРЕСС-БАРА ===============
show_progress() {
    local progress=$1
    local message=$2
    local width=40  # ширина прогресс-бара
    local fill=$((progress * width / 100))
    local empty=$((width - fill))

    # Цвета
    local color_reset="\e[0m"
    local color_fill="\e[42m"  # зеленый фон
    local color_empty="\e[44m"  # синий фон

    # Построение строки прогресс-бара
    printf "\r[${PURPLE}%-40s${NC}] %3d%% ${CYAN}%s${NC}" \
        "$(printf "${color_fill}%*s${color_empty}%*s${color_reset}" "$fill" "" "$empty" "")" \
        "$progress" \
        "$message"
}

# =============== ФУНКЦИИ ВЫВОДА ===============
function print_step() {
    echo -e "\n${PURPLE}=== ${CYAN}$1${PURPLE} ===${NC}"
}

function print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

function print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

function print_error() {
    echo -e "${RED}✗ $1${NC}" >&2
    exit 1
}

function print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# =============== ПРОВЕРКА ПРАВ И СИСТЕМЫ ===============
print_step "Проверка прав и системы"

if [ "$(id -u)" != "0" ]; then
    print_error "Этот скрипт должен запускаться с правами root!"
fi

if [ ! -f /etc/os-release ]; then
    print_error "Не удалось определить операционную систему!"
fi

source /etc/os-release
if [ "$ID" != "ubuntu" ] || [ "$(echo $VERSION_ID | cut -d. -f1)" != "24" ]; then
    print_warning "Скрипт протестирован на Ubuntu 24.04 LTS"
    print_info "Ваша система: ${ID^} ${VERSION_ID}"
    read -rp "${YELLOW}Продолжить установку? (y/n)${NC} " response
    if [[ ! "$response" =~ [yY] ]]; then
        exit 1
    fi
fi

# =============== УСТАНОВКА SUDO (ДЛЯ MINIMAL) ===============
if ! command -v sudo &> /dev/null; then
    print_step "Установка sudo для Ubuntu minimal"
    apt-get update -y >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y sudo >/dev/null 2>&1
    print_success "sudo установлен"
fi

# =============== БАЗОВЫЕ НАСТРОЙКИ ===============
print_step "Базовые настройки системы"

# Установка локали
print_info "Настройка локали"
locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
update-locale LANG=en_US.UTF-8 >/dev/null 2>&1 || true

# Настройка временной зоны (автоопределение)
print_info "Настройка временной зоны"
timedatectl set-timezone "$(curl -s https://ipapi.co/timezone)" >/dev/null 2>&1 || \
timedatectl set-timezone UTC >/dev/null 2>&1
print_success "Временная зона настроена: $(timedatectl status | grep 'Time zone')"

# Обновление списка пакетов
show_progress 0 "Обновление пакетов"
apt-get update -y >/dev/null 2>&1
show_progress 20 "Установка зависимостей"

# =============== ШАГ 1: УСТАНОВКА НЕОБХОДИМЫХ ПАКЕТОВ ===============
print_step "Шаг 1: Установка базовых пакетов"

PACKAGES=(
    "curl" "wget" "gnupg" "lsb-release" "ca-certificates"
    "net-tools" "ufw" "fail2ban" "unzip" "git"
    "htop" "iotop" "iftop" "nmon" "tmux" "ncdu"
    "rsyslog" "logrotate" "unattended-upgrades"
    "zram-config" "systemd-zram-setup"
)

# Установка пакетов с прогрессом
for i in "${!PACKAGES[@]}"; do
    pkg="${PACKAGES[$i]}"
    progress=$(( (i + 1) * 100 / ${#PACKAGES[@]} ))
    show_progress "$progress" "Установка $pkg"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg" >/dev/null 2>&1
done

# Включение автоматических обновлений безопасности
cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

print_success "Базовые пакеты установлены"
show_progress 100 "Завершено"

# =============== ШАГ 2: СИСТЕМНЫЕ ОПТИМИЗАЦИИ ===============
print_step "Шаг 2: Системные оптимизации для VPS (1GB RAM)"

# 2.1. Настройка zram вместо swap файла (для 1GB RAM)
print_step "Настройка zram для экономии места на диске"
if [ -d /sys/block/zram0 ]; then
    systemctl stop /dev/zram0 >/dev/null 2>&1 || true
    echo 512M > /sys/block/zram0/disksize
    mkswap /dev/zram0 >/dev/null 2>&1
    swapon /dev/zram0 >/dev/null 2>&1
    sysctl vm.swappiness=100 >/dev/null 2>&1
    print_success "zram настроен на 512MB"
else
    print_warning "zram не поддерживается, создаю swap файл 1GB"
    if [ ! -f /swapfile ]; then
        fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    sysctl vm.swappiness=60
    sysctl vm.vfs_cache_pressure=50
    print_success "Swap файл 1GB создан"
fi

# 2.2. Включение BBR (TCP BBR congestion control)
print_step "Включение BBR для улучшения сетевой производительности"
BBR_SETTINGS=(
    "net.core.default_qdisc=fq"
    "net.ipv4.tcp_congestion_control=bbr"
    "net.ipv4.tcp_notsent_lowat=16384"
    "net.ipv4.tcp_fastopen=3"
)

for setting in "${BBR_SETTINGS[@]}"; do
    key=$(echo "$setting" | cut -d= -f1)
    if ! grep -q "^$key=" /etc/sysctl.conf; then
        echo "$setting" >> /etc/sysctl.conf
    fi
done
sysctl -p >/dev/null 2>&1
print_success "BBR включен"

# 2.3. Оптимизация NVMe/SSD
print_step "Оптимизация NVMe/SSD диска"
ROOT_DEVICE=$(df / --output=source | tail -1 | sed 's/\/dev\///' | sed 's/[0-9]*$//')

if [ -f /sys/block/"$ROOT_DEVICE"/queue/scheduler ]; then
    CURRENT_SCHEDULER=$(cat /sys/block/"$ROOT_DEVICE"/queue/scheduler | grep -o '\[.*\]' | tr -d '[]' || true)
    if [ "$CURRENT_SCHEDULER" != "none" ] && [ "$CURRENT_SCHEDULER" != "mq-deadline" ]; then
        echo 'none' > /sys/block/"$ROOT_DEVICE"/queue/scheduler 2>/dev/null || true
        print_success "Планировщик ввода-вывода установлен в 'none'"
    else
        print_warning "Планировщик уже оптимизирован: $CURRENT_SCHEDULER"
    fi
    
    # Настройка TRIM для SSD
    if ! grep -q 'discard' /etc/fstab; then
        sed -i 's/defaults/defaults,discard/' /etc/fstab
        print_success "TRIM для SSD включен"
    fi
else
    print_warning "Не удалось оптимизировать NVMe/SSD (устройство: $ROOT_DEVICE)"
fi

# 2.4. Сетевая оптимизация IPv4
print_step "Сетевая оптимизация для VPS"
NETWORK_OPTIMIZATIONS=(
    "net.core.rmem_max=16777216"
    "net.core.wmem_max=16777216"
    "net.ipv4.tcp_rmem=4096 87380 16777216"
    "net.ipv4.tcp_wmem=4096 65536 16777216"
    "net.core.netdev_max_backlog=30000"
    "net.ipv4.tcp_slow_start_after_idle=0"
    "net.ipv4.ip_forward=1"
    "net.ipv4.conf.all.forwarding=1"
    "net.ipv4.conf.default.forwarding=1"
    "net.ipv6.conf.all.forwarding=1"
    "net.ipv6.conf.default.forwarding=1"
    "net.ipv4.conf.all.src_valid_mark=1"
    "vm.dirty_background_ratio=5"
    "vm.dirty_ratio=10"
)

for opt in "${NETWORK_OPTIMIZATIONS[@]}"; do
    key=$(echo "$opt" | cut -d= -f1)
    if ! grep -q "^$key=" /etc/sysctl.conf; then
        echo "$opt" >> /etc/sysctl.conf
    fi
done

sysctl -p >/dev/null 2>&1
print_success "Сетевая оптимизация применена"

# =============== ШАГ 3: БЕЗОПАСНОСТЬ ===============
print_step "Шаг 3: Настройка безопасности"

# 3.1. Создание нового пользователя (опционально)
print_info "Создание нового пользователя для безопасности"
read -rp "${YELLOW}Хотите создать нового пользователя вместо root? (y/n)${NC} " create_user
create_user=$(echo "$create_user" | tr '[:upper:]' '[:lower:]')

if [[ "$create_user" =~ ^(y|yes|да)$ ]]; then
    while true; do
        read -rp "${CYAN}Введите имя пользователя (только буквы, цифры, подчеркивания): ${NC}" username
        if [[ "$username" =~ ^[a-zA-Z0-9_]+$ ]] && [ -n "$username" ]; then
            if id "$username" &>/dev/null; then
                print_warning "Пользователь '$username' уже существует!"
            else
                break
            fi
        else
            print_warning "Недопустимое имя пользователя!"
        fi
    done

    while true; do
        read -rsp "${CYAN}Введите пароль для пользователя $username: ${NC}" password
        echo
        read -rsp "${CYAN}Подтвердите пароль: ${NC}" password_confirm
        echo
        if [ "$password" = "$password_confirm" ] && [ ${#password} -ge 8 ]; then
            break
        else
            print_warning "Пароли не совпадают или короче 8 символов!"
        fi
    done

    # Создание пользователя
    useradd -m -s /bin/bash "$username"
    echo "$username:$password" | chpasswd
    usermod -aG sudo "$username"
    
    # Копирование SSH ключей root для нового пользователя
    if [ -d /root/.ssh ]; then
        mkdir -p "/home/$username/.ssh"
        cp -r /root/.ssh/* "/home/$username/.ssh/" 2>/dev/null || true
        chown -R "$username:$username" "/home/$username/.ssh"
        chmod 700 "/home/$username/.ssh"
        chmod 600 "/home/$username/.ssh/"*
    fi

    print_success "Пользователь '$username' создан с правами sudo"
    CURRENT_USER="$username"
else
    print_info "Использование root пользователя"
    CURRENT_USER="root"
fi

# 3.2. Настройка SSH
print_step "Настройка SSH сервера"

# Генерация новых SSH ключей (если их нет)
if [ ! -f /etc/ssh/ssh_host_ed25519_key ]; then
    print_info "Генерация новых SSH ключей"
    rm -f /etc/ssh/ssh_host_*
    dpkg-reconfigure openssh-server >/dev/null 2>&1
    print_success "SSH ключи пересозданы"
fi

# Выбор порта SSH
while true; do
    read -rp "${CYAN}Введите порт SSH (1024-65535, по умолчанию 22222): ${NC}" ssh_port
    ssh_port=${ssh_port:-22222}
    if [[ "$ssh_port" =~ ^[0-9]+$ ]] && ((ssh_port >= 1024 && ssh_port <= 65535)); then
        break
    else
        print_warning "Недопустимый порт! Должен быть в диапазоне 1024-65535."
    fi
done

# Резервное копирование оригинального конфига
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Применение настроек SSH
SSH_CONFIG=(
    "Port $ssh_port"
    "PermitRootLogin no"
    "PasswordAuthentication no"
    "ChallengeResponseAuthentication no"
    "UsePAM no"
    "X11Forwarding no"
    "AllowTcpForwarding no"
    "ClientAliveInterval 300"
    "ClientAliveCountMax 2"
    "MaxAuthTries 2"
    "LoginGraceTime 30"
    "AllowAgentForwarding no"
    "PermitTunnel no"
    "PermitUserEnvironment no"
    "Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com,aes256-ctr,aes192-ctr,aes128-ctr"
    "MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com,umac-128-etm@openssh.com"
    "KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group18-sha512,diffie-hellman-group16-sha512,diffie-hellman-group14-sha256"
)

for config in "${SSH_CONFIG[@]}"; do
    key=$(echo "$config" | cut -d' ' -f1)
    if grep -q "^$key" /etc/ssh/sshd_config; then
        sed -i "s/^$key.*/$config/" /etc/ssh/sshd_config
    else
        echo "$config" >> /etc/ssh/sshd_config
    fi
done

# Проверка наличия SSH ключей для пользователя
if [ "$CURRENT_USER" != "root" ]; then
    if [ ! -f "/home/$CURRENT_USER/.ssh/authorized_keys" ] || [ ! -s "/home/$CURRENT_USER/.ssh/authorized_keys" ]; then
        print_warning "SSH ключи не найдены для пользователя $CURRENT_USER!"
        print_info "Необходимо добавить SSH ключ вручную:"
        print_info "ssh-copy-id -p $ssh_port $CURRENT_USER@$(hostname -I | awk '{print $1}')"
    fi
fi

systemctl restart sshd
print_success "SSH настроен на порт $ssh_port (root login запрещен)"

# 3.3. Настройка UFW (брандмауэр)
print_step "Настройка брандмауэра UFW"

# Базовые правила
ufw --force reset >/dev/null 2>&1
ufw default deny incoming comment "Запретить весь входящий трафик по умолчанию"
ufw default allow outgoing comment "Разрешить весь исходящий трафик"

# Разрешить SSH на настроенном порту
ufw allow "$ssh_port"/tcp comment "SSH доступ"

# Разрешить HTTP/HTTPS для Let's Encrypt и веб-серверов
ufw allow http comment "HTTP для Let's Encrypt"
ufw allow https comment "HTTPS для веб-приложений"

# Включение UFW
ufw --force enable >/dev/null 2>&1
print_success "Брандмауэр UFW настроен и включен"

# 3.4. Настройка Fail2Ban
print_step "Настройка Fail2Ban для защиты от брутфорса"

# Создание конфигурации для SSH
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = $ssh_port
logpath = /var/log/auth.log
maxretry = 3
bantime = 1h
findtime = 10m
backend = systemd
action = %(action_)s
EOF

# Перезапуск Fail2Ban
systemctl restart fail2ban >/dev/null 2>&1
print_success "Fail2Ban настроен для защиты SSH"

# =============== ШАГ 4: МОНИТОРИНГ И ЛОГИРОВАНИЕ ===============
print_step "Шаг 4: Настройка мониторинга и логирования"

# Настройка logrotate для экономии места
cat > /etc/logrotate.d/custom <<EOF
/var/log/*.log /var/log/*/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 640 root adm
    sharedscripts
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate
    endscript
}
EOF

# Установка базовых инструментов мониторинга
print_info "Создание скриптов мониторинга"
mkdir -p /opt/scripts

cat > /opt/scripts/system-status.sh <<'EOF'
#!/bin/bash
echo "=== СИСТЕМНЫЙ СТАТУС $(date) ==="
echo "Загрузка CPU: $(uptime | awk -F'[a-z]:' '{print $2}' | sed 's/,/ /g' | awk '{print $1}')"
echo "Использование памяти:"
free -h | grep -v + | awk 'NR==2{printf "  Всего: %s, Использовано: %s, Свободно: %s\n", $2, $3, $4}'
echo "Использование диска:"
df -h / | awk 'NR==2{printf "  %s из %s (%s использовано)\n", $3, $2, $5}'
echo "Активные соединения:"
ss -tulpn | grep LISTEN | wc -l | xargs echo "  TCP слушающих портов:"
echo "ZRAM/Swap:"
swapon --show | awk 'NR>1{printf "  %s %s %s\n", $1, $3, $4}'
EOF

chmod +x /opt/scripts/system-status.sh
print_success "Скрипт мониторинга создан: /opt/scripts/system-status.sh"

# =============== ФИНАЛЬНАЯ ПРОВЕРКА ===============
print_step "Финальная проверка и информация"

# Проверка служб
SERVICES=("ssh" "ufw" "fail2ban" "rsyslog")
for service in "${SERVICES[@]}"; do
    if systemctl is-active --quiet "$service"; then
        print_success "Служба $service активна"
    else
        print_warning "Служба $service неактивна"
    fi
done

# Информация о системе
echo -e "\n${CYAN}=== ИНФОРМАЦИОННЫЙ БЛОК ===${NC}"
print_info "ОС: ${ID^} ${VERSION_ID}"
print_info "Ядро: $(uname -r)"
print_info "Архитектура: $(uname -m)"
print_info "CPU: $(grep 'model name' /proc/cpuinfo | uniq | sed 's/model name\s*:\s*//')"
print_info "Память: $(free -h | awk '/Mem:/ {print $2}')"
print_info "Диск: $(df -h / | awk 'NR==2 {print $2}') на $(df -h / | awk 'NR==2 {print $1}')"

echo -e "\n${CYAN}=== ВАЖНАЯ ИНФОРМАЦИЯ ===${NC}"
print_info "1. Подключайтесь к серверу командой:"
print_info "   ssh -p $ssh_port $CURRENT_USER@$(hostname -I | awk '{print $1}')"

if [ "$CURRENT_USER" != "root" ]; then
    print_info "2. Для получения прав root используйте:"
    print_info "   sudo -i"
fi

print_info "3. Статус системы:"
print_info "   /opt/scripts/system-status.sh"

print_info "4. Порт SSH: $ssh_port"
print_info "5. Брандмауэр: UFW активен"
print_info "6. Защита от брутфорса: Fail2Ban активен"

echo -e "\n${GREEN}✅ Настройка сервера завершена успешно!${NC}"
print_info "Рекомендуется перезагрузить сервер: sudo reboot"

# Создание файла с информацией о настройках
cat > /root/server-setup-info.txt <<EOF
=== ИНФОРМАЦИЯ О НАСТРОЙКЕ СЕРВЕРА ===
Дата настройки: $(date)
ОС: ${ID^} ${VERSION_ID}
Пользователь: $CURRENT_USER
Порт SSH: $ssh_port
Swap: $(swapon --show | awk 'NR==2 {print $1 " " $3}')
BBR: $(sysctl net.ipv4.tcp_congestion_control | cut -d= -f2)
Дополнительные порты: HTTP(80), HTTPS(443)

ВАЖНО:
- Для подключения используйте: ssh -p $ssh_port $CURRENT_USER@$(hostname -I | awk '{print $1}')
- Если вы используете root пользователя, смените пароль: passwd root
- Регулярно обновляйте систему: sudo apt update && sudo apt upgrade -y
- Мониторьте использование ресурсов: /opt/scripts/system-status.sh

Полезные команды:
- Статус служб: sudo systemctl status ssh ufw fail2ban
- Проверка открытых портов: sudo ss -tulpn
- Логи аутентификации: sudo tail -f /var/log/auth.log
EOF

chmod 600 /root/server-setup-info.txt
print_success "Информация о настройке сохранена в /root/server-setup-info.txt"
