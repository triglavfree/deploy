#!/bin/bash
set -e

# =============== ЦВЕТА ===============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# =============== ФУНКЦИИ ===============
print_step()   { echo -e "\n${PURPLE}=== ${CYAN}$1${PURPLE} ===${NC}"; }
print_success(){ echo -e "${GREEN}✓ $1${NC}"; }
print_warning(){ echo -e "${YELLOW}⚠ $1${NC}"; }
print_error()  { echo -e "${RED}✗ $1${NC}" >&2; exit 1; }
print_info()   { echo -e "${BLUE}ℹ $1${NC}"; }

# =============== ПРОВЕРКА ===============
print_step "Проверка прав и ОС"
if [ "$(id -u)" != "0" ]; then
    print_error "Запускайте от root!"
fi
if [ ! -f /etc/os-release ]; then
    print_error "Неизвестная ОС"
fi
source /etc/os-release
if [ "$ID" != "ubuntu" ]; then
    print_warning "Скрипт для Ubuntu. Ваша ОС: $ID"
    read -rp "${YELLOW}Продолжить? (y/n): ${NC}" r
    [[ ! "$r" =~ ^[yY]$ ]] && exit 1
fi

# =============== ШАГ 0: ОБНОВЛЕНИЕ ===============
print_step "Обновление системы"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y
apt-get clean
print_success "Система обновлена"

# =============== ШАГ 1: УСТАНОВКА ПАКЕТОВ ===============
print_step "Установка пакетов"
PACKAGES=("curl" "net-tools" "ufw" "fail2ban" "unzip" "hdparm" "nvme-cli")
for pkg in "${PACKAGES[@]}"; do
    print_info "→ $pkg"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
done
print_success "Пакеты установлены"

# =============== ШАГ 2: ОПТИМИЗАЦИЯ BBR ===============
print_step "Включение TCP BBR"
if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
    echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
    echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
    sysctl -p >/dev/null
    print_success "BBR включён"
else
    print_warning "BBR уже активен"
fi

# =============== ШАГ 3: ОПТИМИЗАЦИЯ NVMe/SSD ===============
print_step "Оптимизация NVMe/SSD диска"

# Определение корневого устройства
ROOT_DEVICE=$(df / --output=source | tail -1 | sed 's/\/dev\///' | sed 's/[0-9]*$//')
print_info "Корневое устройство: $ROOT_DEVICE"

# 1. Настройка планировщика ввода-вывода
if [ -f /sys/block/"$ROOT_DEVICE"/queue/scheduler ]; then
    CURRENT_SCHEDULER=$(cat /sys/block/"$ROOT_DEVICE"/queue/scheduler | grep -o '\[.*\]' | tr -d '[]' || true)
    print_info "Текущий планировщик: $CURRENT_SCHEDULER"
    
    if [[ "$ROOT_DEVICE" == nvme* ]]; then
        # Для NVMe используем 'none'
        if [ "$CURRENT_SCHEDULER" != "none" ]; then
            echo 'none' > /sys/block/"$ROOT_DEVICE"/queue/scheduler 2>/dev/null || true
            print_success "Планировщик NVMe установлен в 'none'"
        else
            print_warning "Планировщик NVMe уже оптимизирован"
        fi
    else
        # Для SATA SSD используем 'mq-deadline'
        if [ "$CURRENT_SCHEDULER" != "mq-deadline" ]; then
            echo 'mq-deadline' > /sys/block/"$ROOT_DEVICE"/queue/scheduler 2>/dev/null || true
            print_success "Планировщик SSD установлен в 'mq-deadline'"
        else
            print_warning "Планировщик SSD уже оптимизирован"
        fi
    fi
else
    print_warning "Не удалось оптимизировать планировщик (устройство не найдено)"
fi

# 2. Включение TRIM в /etc/fstab
if ! grep -q 'discard' /etc/fstab; then
    sed -i 's/defaults/defaults,discard/' /etc/fstab
    print_success "TRIM для SSD включен в /etc/fstab"
else
    print_warning "TRIM уже включен в /etc/fstab"
fi

# 3. Оптимизация параметров ядра для SSD
SSD_OPTS=(
    "vm.swappiness=10"
    "vm.vfs_cache_pressure=50"
    "vm.dirty_background_ratio=5"
    "vm.dirty_ratio=10"
    "vm.dirty_expire_centisecs=500"
    "vm.dirty_writeback_centisecs=100"
)

for opt in "${SSD_OPTS[@]}"; do
    key="${opt%%=*}"
    grep -q "^$key=" /etc/sysctl.conf || echo "$opt" >> /etc/sysctl.conf
done
sysctl -p >/dev/null
print_success "Параметры SSD оптимизации применены"

# 4. Проверка состояния NVMe (если применимо)
if command -v nvme &> /dev/null && [[ "$ROOT_DEVICE" == nvme* ]]; then
    print_info "Проверка состояния NVMe:"
    nvme smart-log "/dev/$ROOT_DEVICE" 2>/dev/null | grep -E "(critical|temperature|media|wear)" || true
fi

print_success "NVMe/SSD оптимизация завершена"

# =============== ШАГ 4: SWAP 2GB ===============
print_step "Создание swap-файла 2 GB (если отсутствует)"
if ! swapon --show | grep -q '/swapfile'; then
    if [ ! -f /swapfile ]; then
        fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        print_success "Swap 2 GB создан"
    else
        swapon /swapfile
        print_success "Swap активирован из существующего файла"
    fi
else
    print_warning "Swap уже активен"
fi

# =============== ШАГ 5: СЕТЕВАЯ ОПТИМИЗАЦИЯ ===============
print_step "Сетевая оптимизация IPv4"
OPTS=(
    "net.core.rmem_max=16777216"
    "net.core.wmem_max=16777216"
    "net.ipv4.tcp_rmem=4096 87380 16777216"
    "net.ipv4.tcp_wmem=4096 65536 16777216"
    "net.core.netdev_max_backlog=30000"
    "net.ipv4.tcp_slow_start_after_idle=0"
    "net.ipv4.tcp_notsent_lowat=16384"
    "net.ipv4.tcp_fastopen=3"
    "net.ipv4.ip_forward=1"
    "net.ipv4.conf.all.forwarding=1"
    "net.ipv4.conf.default.forwarding=1"
    "net.ipv4.conf.all.src_valid_mark=1"
)

for opt in "${OPTS[@]}"; do
    key="${opt%%=*}"
    grep -q "^$key=" /etc/sysctl.conf || echo "$opt" >> /etc/sysctl.conf
done
sysctl -p >/dev/null
print_success "Сетевые параметры применены"

# =============== ШАГ 6: SSH — ПРОВЕРКА И ГЕНЕРАЦИЯ КЛЮЧА ===============
print_step "Проверка и настройка SSH-ключа root"

SSH_DIR="/root/.ssh"
SSH_KEY="$SSH_DIR/id_ed25519"

if [ ! -d "$SSH_DIR" ]; then
    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"
fi

if [ ! -f "$SSH_KEY" ]; then
    print_info "SSH-ключ не найден. Генерация нового ключа..."
    ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "root@$(hostname)"
    chmod 600 "$SSH_KEY"
    chmod 644 "${SSH_KEY}.pub"
    cat "${SSH_KEY}.pub" >> "$SSH_DIR/authorized_keys"
    chmod 600 "$SSH_DIR/authorized_keys"
    print_success "SSH-ключ создан: $SSH_KEY"
else
    if ! grep -q "$(cat ${SSH_KEY}.pub)" "$SSH_DIR/authorized_keys" 2>/dev/null; then
        cat "${SSH_KEY}.pub" >> "$SSH_DIR/authorized_keys"
        chmod 600 "$SSH_DIR/authorized_keys"
    fi
    print_success "SSH-ключ уже существует: $SSH_KEY"
fi

# =============== ШАГ 7: ОТКЛЮЧЕНИЕ ПАРОЛЕЙ В SSH ===============
print_step "Отключение парольной аутентификации SSH"
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)

sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?UsePAM.*/UsePAM no/' /etc/ssh/sshd_config

# Определение правильного имени службы SSH
SSH_SERVICE="ssh"
if ! systemctl is-active --quiet "$SSH_SERVICE" 2>/dev/null; then
    if systemctl is-active --quiet "sshd" 2>/dev/null; then
        SSH_SERVICE="sshd"
    fi
fi

print_info "Перезагрузка службы SSH ($SSH_SERVICE)..."
systemctl reload "$SSH_SERVICE" 2>/dev/null || systemctl restart "$SSH_SERVICE"
print_success "Пароли в SSH отключены. Доступ только по ключу!"

# =============== ШАГ 8: UFW ===============
print_step "Настройка UFW"
ufw --force reset >/dev/null 2>&1
ufw default deny incoming comment 'Запретить входящий трафик'
ufw default allow outgoing comment 'Разрешить исходящий трафик'
ufw allow ssh comment 'SSH'
ufw allow http comment 'HTTP'
ufw allow https comment 'HTTPS'
ufw --force enable >/dev/null 2>&1
print_success "UFW включён"

# =============== ШАГ 9: FAIL2BAN ===============
print_step "Настройка Fail2Ban"
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
maxretry = 3
bantime = 1h
findtime = 10m
backend = systemd
EOF

systemctl restart fail2ban 2>/dev/null || true
print_success "Fail2Ban активирован для защиты SSH"

# =============== ФИНАЛЬНАЯ СВОДКА ===============
print_step "ФИНАЛЬНАЯ СВОДКА"

# Внешний IP
EXTERNAL_IP=$(curl -s https://api.ipify.org || curl -s https://ipinfo.io/ip || echo "не удалось определить")
print_info "Внешний IP-адрес: ${EXTERNAL_IP}"

# Открытые порты
print_info "Открытые порты:"
ss -tuln | grep -E ':(22|80|443)\s' || print_warning "Не найдены ожидаемые порты"

# Путь к SSH-ключу
print_info "Приватный SSH-ключ: /root/.ssh/id_ed25519"
print_info "Подключайтесь командой:"
print_info "  ssh -i /путь/к/id_ed25519 root@${EXTERNAL_IP}"

# Статус Fail2Ban
if systemctl is-active --quiet fail2ban; then
    print_success "Fail2Ban: активен"
else
    print_warning "Fail2Ban: неактивен"
fi

# Swap и BBR
SWAP_SIZE=$(swapon --show --bytes | awk 'NR==2 {print $3}')
print_info "Swap: ${SWAP_SIZE:-0} байт активно"
BBR_STATUS=$(sysctl -n net.ipv4.tcp_congestion_control)
print_info "BBR: ${BBR_STATUS}"

# Статус NVMe/SSD оптимизации
SCHEDULER_STATUS=$(cat /sys/block/"$ROOT_DEVICE"/queue/scheduler 2>/dev/null || echo "неизвестно")
print_info "Планировщик диска: $SCHEDULER_STATUS"
TRIM_STATUS=$(grep 'discard' /etc/fstab 2>/dev/null && echo "включен" || echo "отключен")
print_info "TRIM для SSD: $TRIM_STATUS"

print_success "Настройка сервера завершена!"
print_warning "❗ Сохраните приватный ключ и не теряйте его — пароли отключены!"
