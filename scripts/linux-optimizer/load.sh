#!/bin/bash
set -e

# =============== ЦВЕТА ===============
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;36m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'  # ИСПРАВЛЕНО: добавлено определение CYAN
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

# =============== ШАГ 3: ОПТИМИЗАЦИЯ ДИСКА (NVMe/SSD/VirtIO) ===============
print_step "Оптимизация диска"

# Определение корневого устройства
ROOT_DEVICE=$(df / --output=source | tail -1 | sed 's/\/dev\///' | sed 's/[0-9]*$//')
print_info "Корневое устройство: $ROOT_DEVICE"

# === ОПРЕДЕЛЕНИЕ ТИПА ДИСКА ===
DISK_TYPE="hdd"
if [[ "$ROOT_DEVICE" == nvme* ]]; then
    DISK_TYPE="nvme"
elif [ -f "/sys/block/$ROOT_DEVICE/device/model" ] && grep -qi "nvme" "/sys/block/$ROOT_DEVICE/device/model" 2>/dev/null; then
    DISK_TYPE="nvme"
elif [ -f "/sys/block/$ROOT_DEVICE/queue/rotational" ] && [ "$(cat /sys/block/$ROOT_DEVICE/queue/rotational 2>/dev/null)" = "0" ]; then
    DISK_TYPE="ssd"
elif [[ "$ROOT_DEVICE" == vda || "$ROOT_DEVICE" == vdb || "$ROOT_DEVICE" == sda || "$ROOT_DEVICE" == sdb ]]; then
    # Эвристика: vda/sda на VPS — часто SSD-хранилище, но без TRIM
    DISK_TYPE="virtio"
else
    DISK_TYPE="hdd"
fi
print_info "Определённый тип диска: $DISK_TYPE"

# === 1. НАСТРОЙКА ПЛАНИРОВЩИКА ВВОДА-ВЫВОДА ===
if [ -f /sys/block/"$ROOT_DEVICE"/queue/scheduler ]; then
    CURRENT_SCHEDULER=$(cat /sys/block/"$ROOT_DEVICE"/queue/scheduler 2>/dev/null | grep -o '\[.*\]' | tr -d '[]' || echo "unknown")
    print_info "Текущий планировщик: ${CURRENT_SCHEDULER:-неизвестно}"

    # Выбор целевого планировщика
    if [[ "$DISK_TYPE" == "nvme" ]]; then
        TARGET_SCHEDULER="none"
    elif [[ "$DISK_TYPE" == "virtio" ]]; then
        TARGET_SCHEDULER="none"   # Лучше всего для VPS
    elif [[ "$DISK_TYPE" == "ssd" ]]; then
        TARGET_SCHEDULER="mq-deadline"
    else
        TARGET_SCHEDULER="mq-deadline"  # HDD: mq-deadline или bfq, но mq-deadline стабильнее
    fi

    if [[ "$CURRENT_SCHEDULER" != "$TARGET_SCHEDULER" ]]; then
        if echo "$TARGET_SCHEDULER" > /sys/block/"$ROOT_DEVICE"/queue/scheduler 2>/dev/null; then
            print_success "Планировщик установлен в '$TARGET_SCHEDULER'"
        else
            print_warning "Не удалось установить планировщик '$TARGET_SCHEDULER'"
        fi
    else
        print_warning "Планировщик уже оптимизирован: $CURRENT_SCHEDULER"
    fi
else
    if [[ "$DISK_TYPE" == "nvme" ]]; then
        print_success "NVMe: планировщик не используется (аппаратное управление)"
    else
        print_warning "Файл scheduler недоступен (возможно, NVMe или нестандартное устройство)"
    fi
fi

# === 2. УПРАВЛЕНИЕ TRIM (discard) ===
if [[ "$DISK_TYPE" == "nvme" || "$DISK_TYPE" == "ssd" ]]; then
    # TRIM имеет смысл только для настоящих SSD/NVMe
    if ! grep -q 'discard' /etc/fstab; then
        if grep -q " / " /etc/fstab; then
            sed -i '/\/ /s/\(defaults[^,]*\)/\1,discard/' /etc/fstab
            print_success "TRIM (discard) включён — актуально для SSD/NVMe"
        else
            print_warning "Не удалось включить TRIM (корневой раздел не найден в fstab)"
        fi
    else
        print_warning "TRIM (discard) уже включён"
    fi
else
    # Для virtio/HDD — отключаем discard, если есть
    if grep -q 'discard' /etc/fstab; then
        sed -i 's/,discard//g; s/discard,//g; s/discard//g' /etc/fstab
        print_success "TRIM (discard) отключён — не поддерживается для $DISK_TYPE"
    else
        print_info "TRIM не применяется для $DISK_TYPE (корректно)"
    fi
fi

# === 3. ОПТИМИЗАЦИЯ ПАРАМЕТРОВ ЯДРА ===
# Применяем SSD-оптимизации даже для virtio (часто SSD под капотом)
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
print_success "Параметры ядра для SSD/VPS применены"

# === 4. ПРОВЕРКА NVMe (только если NVMe) ===
if [[ "$DISK_TYPE" == "nvme" ]] && command -v nvme &> /dev/null; then
    print_info "Проверка состояния NVMe:"
    nvme smart-log "/dev/$ROOT_DEVICE" 2>/dev/null | grep -E "(critical|temperature|media|wear)" || true
fi

print_success "Оптимизация диска завершена"

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

# =============== ШАГ 6: ОТКЛЮЧЕНИЕ ПАРОЛЕЙ В SSH ===============
print_step "Отключение парольной аутентификации SSH"
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)

sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?UsePAM.*/UsePAM no/' /etc/ssh/sshd_config

# ИСПРАВЛЕНО: НАДЕЖНОЕ ОПРЕДЕЛЕНИЕ ИМЕНИ СЛУЖБЫ SSH
SSH_SERVICE=""
# Проверяем наличие служб через systemctl
if systemctl list-unit-files --quiet 2>/dev/null | grep -q '^ssh\.service'; then
    SSH_SERVICE="ssh"
elif systemctl list-unit-files --quiet 2>/dev/null | grep -q '^sshd\.service'; then
    SSH_SERVICE="sshd"
else
    # Резервный метод: проверка запущенных процессов
    if pgrep -x "sshd" >/dev/null 2>&1; then
        SSH_SERVICE="sshd"
    elif pgrep -x "ssh" >/dev/null 2>&1; then
        SSH_SERVICE="ssh"
    else
        print_warning "Не удалось точно определить имя службы SSH. Используем 'ssh' по умолчанию."
        SSH_SERVICE="ssh"
    fi
fi

# ИСПРАВЛЕНО: Безопасная перезагрузка без разрыва текущего соединения
print_info "Перезагрузка службы SSH ($SSH_SERVICE)..."
if ! systemctl reload "$SSH_SERVICE" 2>/dev/null; then
    systemctl restart "$SSH_SERVICE"
fi

# Проверка статуса службы
if systemctl is-active --quiet "$SSH_SERVICE"; then
    print_success "Пароли в SSH отключены. Доступ только по ключу!"
else
    print_warning "Служба SSH перезагружена, но статус неактивен. Проверьте конфигурацию."
fi

# =============== ШАГ 7: UFW ===============
print_step "Настройка UFW"
ufw --force reset >/dev/null 2>&1
ufw default deny incoming comment 'Запретить входящий трафик'
ufw default allow outgoing comment 'Разрешить исходящий трафик'
ufw allow ssh comment 'SSH'
ufw allow http comment 'HTTP'
ufw allow https comment 'HTTPS'
ufw --force enable >/dev/null 2>&1
print_success "UFW включён"

# =============== ШАГ 8: FAIL2BAN ===============
print_step "Настройка Fail2Ban"

# Определяем текущий порт SSH
SSH_PORT=$(grep -Po '^Port \K\d+' /etc/ssh/sshd_config 2>/dev/null || echo 22)

cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT
logpath = /var/log/auth.log
maxretry = 3
bantime = 1h
findtime = 10m
backend = systemd
action = %(action_)s
EOF

systemctl restart fail2ban 2>/dev/null || true
print_success "Fail2Ban активирован для защиты SSH (порт: $SSH_PORT)"
printf '\033c'  # Самый надежный способ очистки экрана
# =============== ФИНАЛЬНАЯ СВОДКА ===============
print_step "ФИНАЛЬНАЯ СВОДКА"
print_success "Настройка сервера завершена!"

# Swap и BBR
BBR_STATUS=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "неизвестно")
print_info "BBR: ${BBR_STATUS}"
SWAP_SIZE=$(swapon --show --bytes | awk 'NR==2 {print $3}' 2>/dev/null || echo "неизвестно")
print_info "Swap: ${SWAP_SIZE:-0} байт активно"

# Статус NVMe/SSD оптимизации
TRIM_STATUS=$(grep -q 'discard' /etc/fstab 2>/dev/null && echo "включен" || echo "отключен")
print_info "TRIM для SSD: $TRIM_STATUS"
SCHEDULER_STATUS=$(cat /sys/block/"$ROOT_DEVICE"/queue/scheduler 2>/dev/null || echo "неизвестно")
print_info "Планировщик диска: ${SCHEDULER_STATUS:-неизвестно}"

# Внешний IP - улучшенная версия с резервными вариантами
EXTERNAL_IP=$(curl -s4 https://api.ipify.org 2>/dev/null || \
              curl -s4 https://ipinfo.io/ip 2>/dev/null || \
              curl -s4 https://icanhazip.com 2>/dev/null || \
              curl -s4 https://ifconfig.me/ip 2>/dev/null || \
              echo "не удалось определить")
print_info "Внешний IP-адрес: ${EXTERNAL_IP}"

# Открытые порты
print_info "Открытые порты:"
ss -tuln | grep -E ':(22|80|443)\s' || print_warning "Не найдены ожидаемые порты (22, 80, 443)"

# Проверка доступа по SSH после отключения паролей
SSH_ACCESS=$(ss -tuln | grep ":$SSH_PORT" | grep LISTEN 2>/dev/null || echo "не слушается")
if [[ "$SSH_ACCESS" != "не слушается" ]]; then
    print_success "SSH сервер слушает порт $SSH_PORT"
else
    print_error "SSH сервер не слушает порт $SSH_PORT! Проверьте конфигурацию!"
fi

# Статус Fail2Ban
FAIL2BAN_SERVICE="fail2ban"
if systemctl is-active --quiet "$FAIL2BAN_SERVICE"; then
    print_success "Fail2Ban: активен (порт SSH: $SSH_PORT)"
else
    print_warning "Fail2Ban: неактивен"
fi

# Статус UFW
UFW_STATUS=$(ufw status | grep -i "Status: active" 2>/dev/null || echo "inactive")
if [[ "$UFW_STATUS" == *"active"* ]]; then
    print_success "UFW: активен (защита сети включена)"
else
    print_warning "UFW: неактивен (защита сети отключена!)"
fi
