#!/bin/bash
set -e

# =============== ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ ===============
RECOVERY_USER=""
RECOVERY_FILE="/root/recovery_info.txt"
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

apply_sysctl_optimization() {
    local key="$1"
    local value="$2"
    sed -i "/^[[:space:]]*$key[[:space:]]*=/d" /etc/sysctl.conf 2>/dev/null
    echo "$key=$value" >> /etc/sysctl.conf
    sysctl -w "$key=$value" >/dev/null 2>&1 || true
}

# =============== ОПРЕДЕЛЕНИЕ КОРНЕВОГО УСТРОЙСТВА ===============
ROOT_DEVICE=$(df / --output=source | tail -1 | sed 's/\/dev\///' | sed 's/[0-9]*$//')

# =============== ПРОВЕРКА ПРАВ ===============
print_step "Проверка прав"
if [ "$(id -u)" != "0" ]; then
    print_error "Запускайте от root!"
    exit 1
fi
print_success "Запущено с правами root"

# =============== РЕЗЕРВНЫЕ КОПИИ + ОПРЕДЕЛЕНИЕ IP ===============
print_step "Создание резервных копий"
BACKUP_DIR="/root/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp /etc/ssh/sshd_config "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/sysctl.conf "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/fstab "$BACKUP_DIR/" 2>/dev/null || true
print_success "Резервные копии: $BACKUP_DIR"

# Получаем текущий IP один раз для всего скрипта
CURRENT_IP=$(curl -s4 https://api.ipify.org 2>/dev/null || echo "unknown")

# =============== ПРОВЕРКА SSH ДОСТУПА ===============
check_ssh_access_safety() {
    print_step "Проверка безопасности SSH доступа"
    
    if [ "$CURRENT_IP" != "unknown" ]; then
        print_info "Ваш текущий IP: ${CURRENT_IP}"
    fi
    
    if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
        print_success "SSH ключи настроены — пароли можно безопасно отключать"
        RECOVERY_USER=""
        return 0
    fi
    
    RECOVERY_USER="recovery_user_$(date +%s)"
    TEMP_PASS="$(tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c 12)"
    
    useradd -m -s /bin/bash "$RECOVERY_USER"
    echo "$RECOVERY_USER:$TEMP_PASS" | chpasswd
    usermod -aG sudo "$RECOVERY_USER"
    
    {
        echo "=== АККАУНТ ДЛЯ ВОССТАНОВЛЕНИЯ ==="
        echo "Пользователь: $RECOVERY_USER"
        echo "Пароль: $TEMP_PASS"
        echo "Создан: $(date)"
        [ "$CURRENT_IP" != "unknown" ] && echo "Ваш IP: $CURRENT_IP"
    } > "$RECOVERY_FILE"
    chmod 600 "$RECOVERY_FILE"
    
    print_warning "ВНИМАНИЕ: SSH ключи не настроены!"
    print_warning "Создан аккаунт для восстановления:"
    print_warning "  Пользователь: ${RECOVERY_USER}"
    print_warning "  Пароль: ${TEMP_PASS}"
    
    echo
    read -t 60 -rp "${YELLOW}Продолжить оптимизацию? (y/n) [n]: ${NC}" confirm
    confirm=${confirm:-n}
    
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        print_warning "Оптимизация отменена."
        exit 0
    fi
    
    print_success "Продолжаем оптимизацию..."
}

check_ssh_access_safety

# =============== ПРОВЕРКА ОС ===============
print_step "Проверка операционной системы"
if [ ! -f /etc/os-release ]; then
    print_error "Неизвестная ОС"
    exit 1
fi
source /etc/os-release
if [ "$ID" != "ubuntu" ]; then
    print_warning "Скрипт для Ubuntu. Ваша ОС: $ID"
    read -rp "${YELLOW}Продолжить? (y/n) [y]: ${NC}" r
    r=${r:-y}
    [[ ! "$r" =~ ^[yY]$ ]] && exit 1
fi
print_success "ОС: $PRETTY_NAME"

# =============== ОБНОВЛЕНИЕ ===============
print_step "Обновление системы"
DEBIAN_FRONTEND=noninteractive apt-get update -yqq >/dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get upgrade -yqq --no-install-recommends >/dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get autoremove -yqq >/dev/null 2>&1 || true
apt-get clean >/dev/null 2>&1 || true
print_success "Система обновлена"

# =============== УСТАНОВКА ПАКЕТОВ ===============
print_step "Установка пакетов"
PACKAGES=("curl" "net-tools" "ufw" "fail2ban" "unzip" "hdparm" "nvme-cli" "zram-tools")

INSTALLED_PACKAGES=()
for pkg in "${PACKAGES[@]}"; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" >/dev/null 2>&1; then
            INSTALLED_PACKAGES+=("$pkg")
        fi
    fi
done

if [ ${#INSTALLED_PACKAGES[@]} -gt 0 ]; then
    print_success "Установлено пакетов: ${#INSTALLED_PACKAGES[@]}"
    for pkg in "${INSTALLED_PACKAGES[@]}"; do
        print_info "  → $pkg"
    done
else
    print_success "Все пакеты уже установлены"
fi

# =============== UFW: ТОЛЬКО SSH ===============
print_step "Настройка брандмауэра UFW"

ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh  # Только порт 22

# Дополнительное правило для вашего IP
if [ "$CURRENT_IP" != "unknown" ]; then
    ufw allow from "$CURRENT_IP" to any port ssh
fi

print_warning "UFW будет включён через 5 секунд (весь входящий трафик, кроме SSH, будет заблокирован)..."
sleep 5
ufw --force enable >/dev/null 2>&1 || true

if ufw status | grep -qi "Status: active"; then
    print_success "UFW активирован: всё закрыто, кроме SSH"
else
    print_warning "UFW не активирован"
fi

# =============== ОПТИМИЗАЦИЯ ЯДРА ===============
print_step "Оптимизация ядра"

TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
print_info "Обнаружено RAM: ${TOTAL_MEM_MB} MB"

declare -A KERNEL_OPTS
KERNEL_OPTS=(
    ["net.core.default_qdisc"]="fq"
    ["net.ipv4.tcp_congestion_control"]="bbr"
    ["net.core.somaxconn"]="1024"
    ["net.core.netdev_max_backlog"]="1000"
    ["net.ipv4.tcp_syncookies"]="1"
    ["net.ipv4.tcp_tw_reuse"]="1"
    ["net.ipv4.ip_forward"]="1"
    ["vm.swappiness"]="30"
    ["vm.vfs_cache_pressure"]="100"
    ["vm.dirty_background_ratio"]="5"
    ["vm.dirty_ratio"]="15"
)

for key in "${!KERNEL_OPTS[@]}"; do
    apply_sysctl_optimization "$key" "${KERNEL_OPTS[$key]}"
done

sysctl -p >/dev/null 2>&1 || true
print_success "Оптимизации ядра применены"

# =============== SWAP ===============
print_step "Настройка swap-файла"

if ! swapon --show | grep -q '/swapfile'; then
    SWAP_SIZE_GB=2
    fallocate -l ${SWAP_SIZE_GB}G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE_GB * 1024))
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    print_success "Swap ${SWAP_SIZE_GB}GB создан"
else
    print_warning "Swap уже активен"
fi

# =============== SSH ===============
print_step "Настройка SSH"

SSH_CONFIG_BACKUP="/etc/ssh/sshd_config.before_disable_passwords"
cp /etc/ssh/sshd_config "$SSH_CONFIG_BACKUP"

if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    
    if sshd -t; then
        SSH_SERVICE=""
        if systemctl list-unit-files --quiet 2>/dev/null | grep -q '^ssh\.service'; then
            SSH_SERVICE="ssh"
        elif systemctl list-unit-files --quiet 2>/dev/null | grep -q '^sshd\.service'; then
            SSH_SERVICE="sshd"
        else
            if pgrep -x "sshd" >/dev/null 2>&1; then SSH_SERVICE="sshd"
            else SSH_SERVICE="ssh"; fi
        fi
        
        systemctl reload "$SSH_SERVICE" || systemctl restart "$SSH_SERVICE"
        sleep 2
        
        if systemctl is-active --quiet "$SSH_SERVICE"; then
            print_success "Пароли в SSH отключены. Доступ только по ключу!"
        else
            cp "$SSH_CONFIG_BACKUP" /etc/ssh/sshd_config
            systemctl restart "$SSH_SERVICE"
            print_error "SSH не запустился! Конфигурация восстановлена."
            exit 1
        fi
    else
        cp "$SSH_CONFIG_BACKUP" /etc/ssh/sshd_config
        print_error "Ошибка в конфигурации SSH! Восстановлено."
        exit 1
    fi
else
    print_warning "SSH ключи не настроены! Парольная аутентификация оставлена включённой."
fi

# =============== FAIL2BAN ===============
print_step "Настройка Fail2Ban для защиты SSH"

SSH_PORT=$(grep -Po '^Port \K\d+' /etc/ssh/sshd_config 2>/dev/null || echo 22)

mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
port = $SSH_PORT
logpath = /var/log/auth.log
maxretry = 5
bantime = 1h
findtime = 10m
backend = systemd
action = %(action_)s
EOF

systemctl restart fail2ban 2>/dev/null || true
print_success "Fail2Ban настроен: защищает SSH (порт $SSH_PORT) от брутфорса"

# =============== ФИНАЛЬНАЯ СВОДКА ===============
printf '\033c'

print_step "ФИНАЛЬНАЯ СВОДКА"

# Восстановительный аккаунт (только если существует)
if [ -n "$RECOVERY_USER" ] && id "$RECOVERY_USER" >/dev/null 2>&1; then
    print_error "ВАЖНО: СОЗДАН АККАУНТ ДЛЯ ВОССТАНОВЛЕНИЯ!"
    if [ -f "$RECOVERY_FILE" ]; then
        while IFS= read -r line; do
            print_error "  $line"
        done < "$RECOVERY_FILE"
    else
        print_error "  Пользователь: $RECOVERY_USER"
    fi
    echo
fi

# SSH статус
if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
    print_success "SSH: пароли отключены (только ключи)"
else
    print_warning "SSH: пароли ВКЛЮЧЕНЫ (ключей не обнаружено)"
fi

# Сетевые оптимизации
BBR_STATUS=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "неизвестно")
print_info "BBR: ${BBR_STATUS}"

TRIM_STATUS=$(grep -q 'discard' /etc/fstab 2>/dev/null && echo "включён" || echo "отключён")
print_info "TRIM для SSD: $TRIM_STATUS"

SCHEDULER_STATUS="неизвестно"
if [ -f "/sys/block/$ROOT_DEVICE/queue/scheduler" ]; then
    SCHEDULER_STATUS=$(cat "/sys/block/$ROOT_DEVICE/queue/scheduler" 2>/dev/null || echo "неизвестно")
fi
print_info "Планировщик диска: ${SCHEDULER_STATUS}"

EXTERNAL_IP=$(curl -s4 https://api.ipify.org 2>/dev/null || echo "не удалось определить")
print_info "Внешний IP-адрес: ${EXTERNAL_IP}"

# === ЧТО МЫ СДЕЛАЛИ С БРАНДМАУЭРОМ ===
print_info "Брандмауэр UFW:"
print_info "  → Все входящие подключения ЗАБЛОКИРОВАНЫ по умолчанию"
print_info "  → Разрешён только входящий трафик на порт SSH ($SSH_PORT)"
if [ "$CURRENT_IP" != "unknown" ]; then
    print_info "  → Дополнительно разрешён SSH с вашего IP: $CURRENT_IP"
fi

# Виртуальная память
print_info "Статус виртуальной памяти:"
SWAP_SIZE_BYTES=$(swapon --show --bytes | awk 'NR==2 {print $3}' 2>/dev/null)
if [[ -n "$SWAP_SIZE_BYTES" ]] && [[ "$SWAP_SIZE_BYTES" -gt 0 ]]; then
    SWAP_SIZE_GB=$((SWAP_SIZE_BYTES / 1024 / 1024 / 1024))
    print_success "Swap-файл: ${SWAP_SIZE_GB} GB активен"
else
    print_warning "Виртуальная память не настроена!"
fi

# Проверка SSH (точная)
if ss -ltn | grep -q ":$SSH_PORT\s"; then
    print_success "SSH сервер активен и слушает порт $SSH_PORT"
else
    print_error "SSH сервер не слушает порт $SSH_PORT!"
fi

# Защита
if systemctl is-active --quiet "fail2ban"; then
    print_success "Fail2Ban: активен — защищает SSH от брутфорса"
else
    print_warning "Fail2Ban: неактивен"
fi

if ufw status | grep -qi "Status: active"; then
    print_success "UFW: активен — весь входящий трафик заблокирован, кроме SSH"
else
    print_error "UFW: НЕ АКТИВЕН — сервер НЕ защищён брандмауэром!"
fi

print_success "Оптимизация и защита сервера завершены!"

print_warning ""
print_warning "Рекомендуется перезагрузить сервер для полного применения настроек:"
print_warning "   reboot"
