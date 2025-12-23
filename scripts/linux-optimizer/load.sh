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

# Проверка, остались ли пакеты для обновления после upgrade
check_if_fully_updated() {
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    if apt-get --just-print upgrade 2>/dev/null | grep -q "^Inst"; then
        echo "доступны обновления"
    else
        echo "актуальна"
    fi
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

# =============== РЕЗЕРВНЫЕ КОПИИ ===============
print_step "Создание резервных копий"
BACKUP_DIR="/root/backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp /etc/ssh/sshd_config "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/sysctl.conf "$BACKUP_DIR/" 2>/dev/null || true
cp /etc/fstab "$BACKUP_DIR/" 2>/dev/null || true
print_success "Резервные копии: $BACKUP_DIR"

# =============== ПРОВЕРКА SSH ДОСТУПА ===============
check_ssh_access_safety() {
    print_step "Проверка безопасности SSH доступа"
    
    # === НАДЁЖНОЕ ОПРЕДЕЛЕНИЕ IP КЛИЕНТА ===
    CURRENT_IP=""
    if [ -n "$SSH_CLIENT" ]; then
        CURRENT_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
    elif [ -n "$SSH_CONNECTION" ]; then
        CURRENT_IP=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    fi

    if [ -n "$CURRENT_IP" ]; then
        print_info "Ваш IP-адрес: ${CURRENT_IP}"
    else
        print_info "IP не определён (нормально при использовании консоли провайдера)."
    fi
    
    # === ПРОВЕРКА НАЛИЧИЯ ВАЛИДНЫХ КЛЮЧЕЙ ===
    if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
        if grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp[0-9]+)' /root/.ssh/authorized_keys; then
            print_success "Действующие SSH-ключи для root обнаружены."
            return 0
        fi
    fi

    # === КЛЮЧЕЙ НЕТ ===
    print_warning "SSH-ключи для root не настроены."
    echo
    print_info "Настройте SSH-ключи НА СВОЁМ КОМПЬЮТЕРЕ:"
    print_info "1. У вас уже есть ключ? Отлично! Пропустите генерацию."
    print_info "   Путь: ~/.ssh/id_rsa.pub или ~/.ssh/id_ed25519.pub"
    echo
    print_info "2. Нет ключа? Создайте:"
    print_info "     ssh-keygen -t ed25519 -C \"ваш_email@example.com\""
    echo
    print_info "3. Скопируйте ключ на сервер:"
    if [ -n "$CURRENT_IP" ]; then
        print_info "     ssh-copy-id root@${CURRENT_IP}"
    else
        print_info "     # Узнайте IP сервера и выполните:"
        print_info "     ssh-copy-id root@ВАШ_IP"
    fi
    echo
    print_info "4. Или вручную: добавьте содержимое .pub в /root/.ssh/authorized_keys"
    print_info "   и выполните: chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys"
    echo
    print_info "🔄 После этого — запустите скрипт снова."
    print_success "Скрипт завершён. Повторите запуск после настройки SSH-ключей."
    exit 0
}

# =============== БЕЗОПАСНАЯ ПРОВЕРКА SSH ===============
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

SYSTEM_UPDATE_STATUS=$(check_if_fully_updated)
print_success "Система обновлена: $SYSTEM_UPDATE_STATUS"

# =============== УСТАНОВКА ПАКЕТОВ ===============
print_step "Установка пакетов"
PACKAGES=("curl" "net-tools" "ufw" "fail2ban" "unzip" "hdparm" "nvme-cli")

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

# =============== UFW: SSH ТОЛЬКО С ВАШЕГО IP ===============
print_step "Настройка брандмауэра UFW"
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1

if [ -n "$CURRENT_IP" ]; then
    ufw allow from "$CURRENT_IP" to any port ssh comment "SSH с доверенного IP" >/dev/null 2>&1
    print_success "Правила UFW применены: SSH разрешён только с $CURRENT_IP"
else
    ufw allow ssh comment "SSH (глобально)" >/dev/null 2>&1
    print_warning "SSH разрешён для всех (IP не определён)"
fi

ufw --force enable >/dev/null 2>&1
if ! ufw status | grep -qi "Status: active"; then
    print_error "UFW не активирован"
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
    if [ "$TOTAL_MEM_MB" -le 1024 ]; then SWAP_SIZE_MB=2048
    elif [ "$TOTAL_MEM_MB" -le 2048 ]; then SWAP_SIZE_MB=1024
    elif [ "$TOTAL_MEM_MB" -le 4096 ]; then SWAP_SIZE_MB=512
    else SWAP_SIZE_MB=512; fi

    print_info "Создание swap-файла: ${SWAP_SIZE_MB} МБ"
    if ! fallocate -l ${SWAP_SIZE_MB}M /swapfile >/dev/null 2>&1; then
        dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE_MB status=none
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    print_success "Swap ${SWAP_SIZE_MB} МБ успешно создан"
else
    print_success "Swap уже активен"
fi

# =============== ОТКЛЮЧЕНИЕ ПАРОЛЕЙ В SSH ===============
print_step "Отключение парольной аутентификации"
SSH_CONFIG_BACKUP="/etc/ssh/sshd_config.before_disable_passwords"
cp /etc/ssh/sshd_config "$SSH_CONFIG_BACKUP"

# Мы точно знаем: ключи есть (иначе скрипт бы вышел ранее)
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config

if sshd -t; then
    SSH_SERVICE="ssh"
    systemctl list-unit-files --quiet | grep -q '^sshd\.service' && SSH_SERVICE="sshd"
    systemctl reload "$SSH_SERVICE" || systemctl restart "$SSH_SERVICE"
    sleep 2
    if systemctl is-active --quiet "$SSH_SERVICE"; then
        print_success "Пароли в SSH отключены. Доступ — только по ключу!"
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

# =============== FAIL2BAN ===============
print_step "Настройка Fail2Ban"
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
print_success "Fail2Ban настроен: защищает SSH (порт $SSH_PORT)"

# =============== ФИНАЛЬНАЯ СВОДКА ===============
printf '\033c'
print_step "ФИНАЛЬНАЯ СВОДКА"
print_success "ОС: $PRETTY_NAME ($SYSTEM_UPDATE_STATUS)"
print_success "Планировщик диска: $(cat "/sys/block/$ROOT_DEVICE/queue/scheduler" 2>/dev/null || echo "неизвестно")"
print_success "SSH: пароли отключены (только ключи)"
print_success "TRIM для SSD: $(grep -q 'discard' /etc/fstab && echo "включён" || echo "отключён")"
print_success "BBR: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "неизвестно")"

if [ -z "$SSH_CLIENT" ]; then
    EXTERNAL_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "неизвестен")
    print_info "Внешний IP сервера: $EXTERNAL_IP"
fi

print_info "Брандмауэр UFW:"
print_info "  → Все входящие подключения ЗАБЛОКИРОВАНЫ"
if [ -n "$CURRENT_IP" ]; then
    print_info "  → SSH ($SSH_PORT) разрешён только с: $CURRENT_IP"
else
    print_info "  → SSH ($SSH_PORT) разрешён для всех"
fi

# Swap
if [ -f /swapfile ] && swapon --show | grep -q '/swapfile'; then
    SWAP_BYTES=$(stat -c %s /swapfile 2>/dev/null || stat -f %z /swapfile 2>/dev/null)
    if [ -n "$SWAP_BYTES" ] && [ "$SWAP_BYTES" -gt 0 ]; then
        if [ "$SWAP_BYTES" -ge $((1024**3)) ]; then
            SWAP_HUMAN="$((SWAP_BYTES / 1024**3)) GB"
        elif [ "$SWAP_BYTES" -ge $((1024**2)) ]; then
            SWAP_HUMAN="$((SWAP_BYTES / 1024**2)) MB"
        else
            SWAP_HUMAN="$((SWAP_BYTES / 1024)) KB"
        fi
        print_success "Swap-файл: $SWAP_HUMAN активен"
    fi
fi

# SSH слушает порт?
if ss -ltn | grep -q ":$SSH_PORT\s"; then
    print_success "SSH сервер активен на порту $SSH_PORT"
else
    print_error "SSH не слушает порт $SSH_PORT!"
fi

# Состояние служб
if systemctl is-active --quiet "fail2ban"; then
    print_success "Fail2Ban: активен"
else
    print_warning "Fail2Ban: неактивен"
fi

if ufw status | grep -qi "Status: active"; then
    print_success "UFW: активен"
else
    print_error "UFW: НЕ АКТИВЕН"
fi

# Очистка резервных копий
rm -rf /root/backup_2025* 2>/dev/null || true
print_info "Резервные копии скрипта удалены."

# Перезагрузка?
if [ -f /var/run/reboot-required ]; then
    print_warning "Установлены обновления, требующие перезагрузки"
    print_info "   Выполните: reboot"
else
    print_success "Оптимизация и защита сервера завершены!"
fi
