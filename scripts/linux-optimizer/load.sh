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
    # Скрыто обновляем список пакетов
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    # Проверяем наличие обновлений без реальной установки
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

# =============== РЕЗЕРВНЫЕ КОПИИ + ОПРЕДЕЛЕНИЕ IP ===============
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
    
    # === ПОЛУЧАЕМ IP КЛИЕНТА НАДЕЖНО ===
    CURRENT_IP=""
    if [ -n "$SSH_CLIENT" ]; then
        CURRENT_IP=$(echo "$SSH_CLIENT" | awk '{print $1}')
    elif [ -n "$SSH_CONNECTION" ]; then
        CURRENT_IP=$(echo "$SSH_CONNECTION" | awk '{print $1}')
    fi

    if [ -n "$CURRENT_IP" ]; then
        print_info "Ваш IP-адрес: ${CURRENT_IP}"
    else
        print_info "Не удалось определить IP автоматически (нормально при использовании консоли провайдера)."
    fi
    
    # Проверяем наличие действующих SSH-ключей для root
    if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
        # Проверим, что файл содержит хотя бы одну валидную строку ключа (игнорируем комментарии и пустые строки)
        if grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp[0-9]+)' /root/.ssh/authorized_keys; then
            print_success "Обнаружены действующие SSH-ключи для root."

            # Удаляем все временные recovery-аккаунты, если они остались
            for user in $(getent passwd | awk -F: '/^recovery_user_[0-9]+/ {print $1}'); do
                print_info "Очистка временного аккаунта: $user"
                userdel -r "$user" 2>/dev/null || true
            done
            rm -f "$RECOVERY_FILE" 2>/dev/null || true

            RECOVERY_USER=""
            return 0
        fi
    fi

    # === КЛЮЧЕЙ НЕТ ИЛИ НЕДЕЙСТВУЮЩИЕ ===
    print_warning "⚠️  SSH-ключи для пользователя 'root' не настроены или недействительны."
    echo
    print_info "🛠️  Как настроить SSH-ключи (выполняется НА ВАШЕМ КОМПЬЮТЕРЕ, не на сервере!):"
    print_info "1. У вас УЖЕ есть SSH-ключ? Отлично! Пропустите создание."
    print_info "   Обычно он находится в:"
    print_info "     • Linux / Mac:    ~/.ssh/id_rsa.pub или ~/.ssh/id_ed25519.pub"
    print_info "     • Windows:        C:\\Users\\ВАШ_ПОЛЬЗОВАТЕЛЬ\\.ssh\\id_rsa.pub"
    echo
    print_info "2. Если ключа нет — создайте его (выполняйте ТОЛЬКО если нужно):"
    print_info "     ssh-keygen -t ed25519 -C \"ваш_email@example.com\""
    print_info "   Нажмите Enter, чтобы принять значения по умолчанию."
    echo
    print_info "3. Скопируйте содержимое ПУБЛИЧНОГО файла (с расширением .pub) и вставьте его на сервер:"
    if [ -n "$CURRENT_IP" ]; then
        print_info "   • Автоматически (рекомендуется):"
        print_info "        ssh-copy-id root@${CURRENT_IP}"
    else
        print_info "   • Узнайте IP сервера, затем:"
        print_info "        ssh-copy-id root@ВАШ_IP_СЕРВЕРА"
    fi
    echo
    print_info "   • ВРУЧНУЮ (если ssh-copy-id недоступен, например, на Windows):"
    print_info "        a) На своём компьютере откройте файл .pub, например:"
    print_info "             notepad C:\\Users\\OK\\.ssh\\id_rsa.pub"
    print_info "        b) Скопируйте ВСЁ его содержимое (начинается с ssh-rsa или ssh-ed25519)"
    print_info "        c) На сервере выполните:"
    print_info "             mkdir -p /root/.ssh"
    print_info "             nano /root/.ssh/authorized_keys"
    print_info "        d) Вставьте скопированную строку, сохраните файл (Ctrl+O, Enter, Ctrl+X)"
    print_info "        e) Выполните:"
    print_info "             chmod 700 /root/.ssh"
    print_info "             chmod 600 /root/.ssh/authorized_keys"
    echo
    print_info "✅ Проверка на сервере:"
    print_info "     cat /root/.ssh/authorized_keys  # должен показать ваш ключ"
    echo
    print_info "🔁 После этого — ЗАПУСТИТЕ СКРИПТ СНОВА."
    print_success "Скрипт завершён. Повторите запуск после настройки SSH-ключей."
    exit 0  # Успешное завершение, но без выполнения опасных действий
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

# Проверяем, всё ли обновлено
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

# =============== UFW: ТОЛЬКО SSH С ВАШЕГО IP ===============
print_step "Настройка брандмауэра UFW"

# Сбросим текущие правила (тихо)
ufw --force reset >/dev/null 2>&1 || true

# Базовая политика
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1

# Разрешаем SSH
if [ -n "$CURRENT_IP" ]; then
    ufw allow from "$CURRENT_IP" to any port ssh comment "SSH с доверенного IP" >/dev/null 2>&1
else
    ufw allow ssh comment "SSH (глобально, IP не определён)" >/dev/null 2>&1
fi

# Активируем UFW
ufw --force enable >/dev/null 2>&1

# Проверяем статус
if ufw status | grep -qi "Status: active"; then
    if [ -n "$CURRENT_IP" ]; then
        print_success "Правила UFW применены: SSH разрешён только с $CURRENT_IP"
    else
        print_warning "Правила UFW применены: SSH разрешён для всех (IP не определён)"
    fi
else
    print_error "UFW не активирован — проверьте вручную"
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

# =============== SWAP: УМНАЯ НАСТРОЙКА ПОД ОБЪЁМ RAM ===============
print_step "Настройка swap-файла"

# Проверяем, есть ли уже swap
if swapon --show | grep -q '/swapfile'; then
    print_warning "Swap уже активен"
else
    # Определяем размер swap в зависимости от RAM
    if [ "$TOTAL_MEM_MB" -le 1024 ]; then
        SWAP_SIZE_MB=2048    # 2 ГБ для ≤1 ГБ RAM
    elif [ "$TOTAL_MEM_MB" -le 2048 ]; then
        SWAP_SIZE_MB=1024    # 1 ГБ для 2 ГБ RAM
    elif [ "$TOTAL_MEM_MB" -le 4096 ]; then
        SWAP_SIZE_MB=512     # 512 МБ для 4 ГБ RAM
    else
        SWAP_SIZE_MB=512     # 512 МБ для ≥8 ГБ RAM
    fi

    print_info "Создание swap-файла: ${SWAP_SIZE_MB} МБ (RAM: ${TOTAL_MEM_MB} МБ)"

    # Создаём swap-файл
    if fallocate -l ${SWAP_SIZE_MB}M /swapfile >/dev/null 2>&1; then
        :
    else
        dd if=/dev/zero of=/swapfile bs=1M count=$SWAP_SIZE_MB status=none
    fi

    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    print_success "Swap ${SWAP_SIZE_MB} МБ успешно создан"
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

print_success "ОС: $PRETTY_NAME ($SYSTEM_UPDATE_STATUS)"

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

# Планировщик диска
SCHEDULER_STATUS="неизвестно"
if [ -f "/sys/block/$ROOT_DEVICE/queue/scheduler" ]; then
    SCHEDULER_STATUS=$(cat "/sys/block/$ROOT_DEVICE/queue/scheduler" 2>/dev/null || echo "неизвестно")
fi
print_success "Планировщик диска: ${SCHEDULER_STATUS}"

# SSH статус
if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
    print_success "SSH: пароли отключены (только ключи)"
else
    print_warning "SSH: пароли ВКЛЮЧЕНЫ (ключей не обнаружено)"
fi

# оптимизации диска
TRIM_STATUS=$(grep -q 'discard' /etc/fstab 2>/dev/null && echo "включён" || echo "отключён")
print_success "TRIM для SSD: $TRIM_STATUS"

# BBR статус
BBR_STATUS=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "неизвестно")
print_success "BBR: ${BBR_STATUS}"

# === Внешний IP ===
if [ -z "$SSH_CLIENT" ]; then
    EXTERNAL_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "неизвестен")
    print_info "Внешний IP сервера: $EXTERNAL_IP"
fi

# === БРАНДМАУЭР: ЧТО РАЗРЕШЕНО ===
print_info "Брандмауэр UFW:"
print_info "  → Все входящие подключения ЗАБЛОКИРОВАНЫ"

if [ -n "$CURRENT_IP" ]; then
    print_info "  → Разрешён входящий трафик на порт: SSH ($SSH_PORT) только с вашего IP: $CURRENT_IP"
else
    print_info "  → Разрешён входящий трафик на порт: SSH ($SSH_PORT) для всех (небезопасно!)"
fi

# Виртуальная память
print_info "Статус виртуальной памяти:"

if [ -f /swapfile ] && swapon --show | grep -q '/swapfile'; then
    SWAP_BYTES=$(stat -c %s /swapfile 2>/dev/null || stat -f %z /swapfile 2>/dev/null)
    if [ -n "$SWAP_BYTES" ] && [ "$SWAP_BYTES" -gt 0 ]; then
        if [ "$SWAP_BYTES" -ge $((1024 * 1024 * 1024)) ]; then
            SWAP_HUMAN="$((SWAP_BYTES / 1024 / 1024 / 1024)) GB"
        elif [ "$SWAP_BYTES" -ge $((1024 * 1024)) ]; then
            SWAP_HUMAN="$((SWAP_BYTES / 1024 / 1024)) MB"
        else
            SWAP_HUMAN="$((SWAP_BYTES / 1024)) KB"
        fi
        print_success "Swap-файл: $SWAP_HUMAN активен"
    else
        print_warning "Swap-файл существует, но имеет нулевой размер"
    fi
elif [ -f /swapfile ]; then
    print_warning "Swap-файл существует, но не активен. Активируйте: swapon /swapfile"
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

if [ -f /var/run/reboot-required ]; then
    print_warning "Установлены обновления, требующие перезагрузки "
    print_info "   Выполните: reboot"
else
    print_success "Оптимизация и защита сервера завершены!"
fi
