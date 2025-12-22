#!/bin/bash
set -e
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
print_error()  { echo -e "${RED}✗ $1${NC}" >&2; exit 1; }
print_info()   { echo -e "${BLUE}ℹ $1${NC}"; }

# =============== БЕЗОПАСНАЯ ПРОВЕРКА SSH ДОСТУПА ===============
check_ssh_access_safety() {
    print_step "Проверка безопасности SSH доступа"
    
    # Получаем текущий IP пользователя
    CURRENT_IP=$(curl -s4 https://api.ipify.org 2>/dev/null || echo "unknown")
    if [ "$CURRENT_IP" = "unknown" ]; then
        print_warning "Не удалось определить ваш внешний IP"
    else
        print_info "Ваш текущий IP: ${CURRENT_IP}"
    fi
    
    # Проверяем наличие SSH ключей
    SSH_KEYS_EXIST=0
    if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
        SSH_KEYS_EXIST=1
        print_success "SSH ключи настроены - можно безопасно отключать пароли"
    else
        print_warning "⚠ ВНИМАНИЕ: У вас нет настроенных SSH ключей!"
        print_warning "После отключения парольной аутентификации вы можете потерять доступ к серверу!"
        
        # Создаем временный аккаунт для восстановления
        TEMP_USER="recovery_user_$(date +%s)"
        TEMP_PASS="$(tr -dc 'A-HJ-NP-Za-km-z2-9' </dev/urandom | head -c 12)"
        
        # Создаем пользователя с паролем
        useradd -m -s /bin/bash "$TEMP_USER"
        echo "$TEMP_USER:$TEMP_PASS" | chpasswd
        usermod -aG sudo "$TEMP_USER"
        
        print_warning "✅ Создан аккаунт для восстановления:"
        print_warning "Пользователь: ${TEMP_USER}"
        print_warning "Пароль: ${TEMP_PASS}"
        print_warning "Этот аккаунт можно удалить после проверки доступа командой:"
        print_warning "userdel -r ${TEMP_USER}"
        
        # Сохраняем информацию в файл
        RECOVERY_FILE="/root/recovery_info.txt"
        echo "=== АККАУНТ ДЛЯ ВОССТАНОВЛЕНИЯ ===" > "$RECOVERY_FILE"
        echo "Пользователь: $TEMP_USER" >> "$RECOVERY_FILE"
        echo "Пароль: $TEMP_PASS" >> "$RECOVERY_FILE"
        echo "Создан: $(date)" >> "$RECOVERY_FILE"
        [ "$CURRENT_IP" != "unknown" ] && echo "Ваш IP: $CURRENT_IP" >> "$RECOVERY_FILE"
        chmod 600 "$RECOVERY_FILE"
        
        # Явно запрашиваем подтверждение с таймаутом
        echo ""
        print_warning "⚠ ВАЖНО: Если вы потеряете доступ, используйте этот аккаунт или консоль в панели Timeweb Cloud!"
        echo ""
        
        local confirm=""
        local attempts=0
        while [ "$attempts" -lt 3 ]; do
            read -t 60 -rp "${YELLOW}Хотите продолжить оптимизацию? (y/n) [n]: ${NC}" confirm
            confirm=${confirm:-n}
            
            if [[ "$confirm" =~ ^[yY]$ ]]; then
                print_success "Продолжаем оптимизацию..."
                return 0
            elif [[ "$confirm" =~ ^[nN]$ ]]; then
                print_warning "Оптимизация отменена пользователем. Сервер в безопасном состоянии."
                print_warning "Информация о восстановительном аккаунте сохранена в: $RECOVERY_FILE"
                echo ""
                print_info "Что можно сделать:"
                print_info "1. Настроить SSH ключи вручную:"
                print_info "   mkdir -p /root/.ssh"
                print_info "   nano /root/.ssh/authorized_keys"
                print_info "   chmod 700 /root/.ssh"
                print_info "   chmod 600 /root/.ssh/authorized_keys"
                print_info "2. Запустить этот скрипт заново после настройки ключей"
                print_info "3. Удалить временного пользователя: userdel -r ${TEMP_USER}"
                exit 0
            else
                attempts=$((attempts + 1))
                if [ "$attempts" -ge 3 ]; then
                    print_warning "Слишком много попыток. Оптимизация отменена."
                    exit 0
                fi
                print_warning "Пожалуйста, введите 'y' или 'n'"
            fi
        done
    fi
}

# =============== ФУНКЦИИ ДЛЯ SYSCTL ===============
apply_sysctl_optimization() {
    local key="$1"
    local value="$2"
    local comment="$3"
    
    # Удаляем все существующие строки с этим ключом
    sed -i "/^[[:space:]]*$key[[:space:]]*=/d" /etc/sysctl.conf 2>/dev/null
    
    # Добавляем новую строку с комментарием
    if [ -n "$comment" ]; then
        echo "# $comment" >> /etc/sysctl.conf
    fi
    echo "$key=$value" >> /etc/sysctl.conf
    
    # Применяем изменение немедленно
    sysctl -w "$key=$value" >/dev/null 2>&1 || true
}

# =============== ОПРЕДЕЛЕНИЕ КОРНЕВОГО УСТРОЙСТВА ===============
ROOT_DEVICE=$(df / --output=source | tail -1 | sed 's/\/dev\///' | sed 's/[0-9]*$//')

# =============== ПРОВЕРКА ПРАВ ===============
print_step "Проверка прав"
if [ "$(id -u)" != "0" ]; then
    print_error "Запускайте от root!"
fi
print_success "Запущено с правами root"

# =============== СОЗДАНИЕ РЕЗЕРВНЫХ КОПИЙ ===============
print_step "Создание резервных копий"
mkdir -p /root/backup_$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/root/backup_$(date +%Y%m%d_%H%M%S)"

cp /etc/ssh/sshd_config "$BACKUP_DIR/sshd_config.bak" 2>/dev/null || true
cp /etc/sysctl.conf "$BACKUP_DIR/sysctl.conf.bak" 2>/dev/null || true
cp /etc/fstab "$BACKUP_DIR/fstab.bak" 2>/dev/null || true
cp /etc/default/grub "$BACKUP_DIR/grub.bak" 2>/dev/null || true

print_success "Резервные копии созданы в: $BACKUP_DIR"

# =============== ПРОВЕРКА БЕЗОПАСНОСТИ SSH ===============
check_ssh_access_safety

# =============== ПРОВЕРКА ОС ===============
print_step "Проверка операционной системы"
if [ ! -f /etc/os-release ]; then
    print_error "Неизвестная ОС"
fi
source /etc/os-release
if [ "$ID" != "ubuntu" ]; then
    print_warning "Скрипт протестирован на Ubuntu. Ваша ОС: $ID"
    read -rp "${YELLOW}Продолжить? (y/n) [y]: ${NC}" confirm
    confirm=${confirm:-y}
    [[ ! "$confirm" =~ ^[yY]$ ]] && exit 1
fi
print_success "ОС: $PRETTY_NAME"

# =============== ОБНОВЛЕНИЕ СИСТЕМЫ ===============
print_step "Обновление системы"
DEBIAN_FRONTEND=noninteractive apt-get update -yqq >/dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get upgrade -yqq --no-install-recommends >/dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get autoremove -yqq >/dev/null 2>&1 || true
apt-get clean >/dev/null 2>&1 || true
print_success "Система обновлена"

# =============== УСТАНОВКА ПАКЕТОВ ===============
print_step "Установка необходимых пакетов"
PACKAGES=("curl" "net-tools" "ufw" "fail2ban" "unzip" "hdparm" "nvme-cli" "zram-tools" "lsof")

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
    print_success "Все необходимые пакеты уже установлены"
fi

# =============== БЕЗОПАСНАЯ НАСТРОЙКА UFW ===============
print_step "Безопасная настройка UFW (брандмауэр)"

# Определяем текущий IP
CURRENT_IP=$(curl -s4 https://api.ipify.org 2>/dev/null || echo "unknown")

# Проверяем, запущен ли UFW
UFW_STATUS=$(ufw status | grep -i "Status:" || echo "inactive")

print_info "Текущий статус UFW: ${UFW_STATUS}"

# Сбрасываем текущие правила только если UFW активен
if [[ "$UFW_STATUS" == *"active"* ]]; then
    print_warning "UFW уже активен. Сбрасываем текущие правила..."
    ufw --force reset >/dev/null 2>&1 || true
fi

# Настраиваем базовые правила
ufw default deny incoming comment 'Запретить весь входящий трафик по умолчанию'
ufw default allow outgoing comment 'Разрешить весь исходящий трафик по умолчанию'

# Разрешаем основные порты
ufw allow ssh comment 'SSH доступ'
ufw allow http comment 'HTTP веб-сервер'
ufw allow https comment 'HTTPS веб-сервер'

# Добавляем текущий IP в белый список для дополнительной безопасности
if [ "$CURRENT_IP" != "unknown" ] && [ "$CURRENT_IP" != "" ]; then
    ufw allow from "$CURRENT_IP" to any port ssh comment "Доступ SSH с вашего IP ($CURRENT_IP)"
    print_info "✅ Ваш IP $CURRENT_IP добавлен в белый список для SSH"
else
    print_warning "⚠ Не удалось определить ваш IP. Добавьте его вручную после завершения:"
    print_warning "   ufw allow from ВАШ_IP to any port ssh"
fi

# Включаем UFW с подтверждением
print_warning "⚠ ВНИМАНИЕ: UFW будет включен через 10 секунд!"
print_warning "Если вы потеряете доступ, используйте консоль в панели Timeweb Cloud."
print_warning "Нажмите Ctrl+C для отмены."

# Счетчик обратного отсчета
for i in {10..1}; do
    echo -ne "${YELLOW}Включение UFW через $i секунд...${NC}\r"
    sleep 1
done
echo ""

# Включаем UFW
ufw --force enable >/dev/null 2>&1
sleep 2

# Проверяем статус
if ufw status | grep -i "Status: active" >/dev/null 2>&1; then
    print_success "✅ UFW успешно включен"
else
    print_warning "⚠ UFW не активирован. Проверьте статус: ufw status"
fi

# =============== КОНСЕРВАТИВНАЯ ОПТИМИЗАЦИЯ ЯДРА ===============
print_step "Консервативная оптимизация ядра для VPS"

TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
print_info "Обнаружено оперативной памяти: ${TOTAL_MEM_MB} MB"

# Безопасные параметры для VPS
declare -A SAFE_KERNEL_OPTS
SAFE_KERNEL_OPTS=(
    ["net.core.default_qdisc"]="fq"                             # Планировщик для BBR
    ["net.ipv4.tcp_congestion_control"]="bbr"                  # TCP BBR congestion control
    ["net.core.somaxconn"]="1024"                               # Макс. длина очереди подключений
    ["net.core.netdev_max_backlog"]="1000"                      # Макс. пакетов в очереди NIC
    ["net.ipv4.tcp_syncookies"]="1"                             # Защита от SYN flood
    ["net.ipv4.tcp_tw_reuse"]="1"                               # Переиспользование TIME-WAIT сокетов
    ["net.ipv4.ip_forward"]="1"                                 # Включить IP forwarding (для Docker, VPN и т.д.)
    ["vm.swappiness"]="30"                                      # Баланс использования swap
    ["vm.vfs_cache_pressure"]="100"                             # Давление на кэш файловой системы
    ["vm.dirty_background_ratio"]="5"                           # Фоновая запись грязных страниц
    ["vm.dirty_ratio"]="15"                                     # Максимальный процент грязных страниц
)

for key in "${!SAFE_KERNEL_OPTS[@]}"; do
    value="${SAFE_KERNEL_OPTS[$key]}"
    apply_sysctl_optimization "$key" "$value" ""
    print_info "→ $key=$value"
done

# Применяем все изменения
sysctl -p >/dev/null 2>&1 || true
print_success "✅ Консервативные оптимизации ядра применены"

# =============== НАСТРОЙКА SWAP ===============
print_step "Настройка swap-файла"

# Проверяем, есть ли уже swap
CURRENT_SWAP=$(swapon --show | grep '/swapfile' || echo "")

if [ -z "$CURRENT_SWAP" ]; then
    # Размер swap в зависимости от объема RAM
    if [ "$TOTAL_MEM_MB" -le 1024 ]; then
        SWAP_SIZE_GB=2
    elif [ "$TOTAL_MEM_MB" -le 2048 ]; then
        SWAP_SIZE_GB=2
    elif [ "$TOTAL_MEM_MB" -le 4096 ]; then
        SWAP_SIZE_GB=2
    else
        SWAP_SIZE_GB=4
    fi
    
    print_info "Создание swap-файла размером ${SWAP_SIZE_GB}GB..."
    
    # Создаем swap-файл
    if fallocate -l ${SWAP_SIZE_GB}G /swapfile >/dev/null 2>&1; then
        print_info "→ Используем fallocate для быстрого создания"
    else
        print_warning "→ fallocate недоступен, используем dd (медленнее)..."
        dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE_GB * 1024)) status=none
    fi
    
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    swapon /swapfile >/dev/null 2>&1
    
    # Добавляем в fstab
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    
    print_success "✅ Swap ${SWAP_SIZE_GB}GB успешно создан и активирован"
else
    print_warning "⚠ Swap-файл уже существует и активен"
    swapon --show | grep '/swapfile'
fi

# =============== БЕЗОПАСНАЯ НАСТРОЙКА SSH ===============
print_step "Безопасная настройка SSH"

# Проверяем еще раз наличие ключей
if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
    print_success "✅ SSH ключи настроены. Отключаем парольную аутентификацию..."
    
    # Делаем резервную копию перед изменением
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.before_password_disable
    
    # Отключаем парольную аутентификацию
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
    
    # Проверяем конфигурацию
    if sshd -t; then
        print_info "✅ Конфигурация SSH проверена успешно"
        
        # Перезагружаем SSH сервис
        SSH_SERVICE=""
        if systemctl list-unit-files --quiet 2>/dev/null | grep -q '^ssh\.service'; then
            SSH_SERVICE="ssh"
        elif systemctl list-unit-files --quiet 2>/dev/null | grep -q '^sshd\.service'; then
            SSH_SERVICE="sshd"
        else
            # Определяем по процессу
            if pgrep -x "sshd" >/dev/null 2>&1; then
                SSH_SERVICE="sshd"
            elif pgrep -x "ssh" >/dev/null 2>&1; then
                SSH_SERVICE="ssh"
            else
                SSH_SERVICE="ssh"
            fi
        fi
        
        print_info "🔄 Перезагрузка службы SSH ($SSH_SERVICE)..."
        systemctl reload "$SSH_SERVICE" >/dev/null 2>&1 || systemctl restart "$SSH_SERVICE" >/dev/null 2>&1
        
        # Проверяем статус
        sleep 2
        if systemctl is-active --quiet "$SSH_SERVICE"; then
            print_success "✅ Пароли в SSH отключены. Доступ только по ключу!"
        else
            print_error "❌ SSH сервис не запустился! Восстанавливаем конфигурацию..."
            cp /etc/ssh/sshd_config.before_password_disable /etc/ssh/sshd_config
            systemctl restart "$SSH_SERVICE" >/dev/null 2>&1
            exit 1
        fi
    else
        print_error "❌ Ошибка в конфигурации SSH! Восстанавливаем оригинальную конфигурацию..."
        cp /etc/ssh/sshd_config.before_password_disable /etc/ssh/sshd_config
        exit 1
    fi
else
    print_warning "⚠ SSH ключи не настроены! Парольная аутентификация оставлена включенной."
    print_warning "⚠ Пожалуйста, настройте SSH ключи вручную перед отключением паролей:"
    print_warning "   mkdir -p /root/.ssh"
    print_warning "   nano /root/.ssh/authorized_keys  # вставьте ваш публичный ключ"
    print_warning "   chmod 700 /root/.ssh"
    print_warning "   chmod 600 /root/.ssh/authorized_keys"
    print_warning "   systemctl reload ssh"
fi

# =============== НАСТРОЙКА FAIL2BAN ===============
print_step "Настройка Fail2Ban для защиты от брутфорса"

# Определяем SSH порт
SSH_PORT=$(grep -Po '^Port \K\d+' /etc/ssh/sshd_config 2>/dev/null || echo 22)

# Создаем конфигурацию
mkdir -p /etc/fail2ban/jail.d
cat > /etc/fail2ban/jail.d/sshd.conf <<EOF
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

# Перезапускаем fail2ban
systemctl restart fail2ban >/dev/null 2>&1 || true

# Проверяем статус
if systemctl is-active --quiet fail2ban; then
    print_success "✅ Fail2Ban активирован для защиты SSH (порт: $SSH_PORT)"
else
    print_warning "⚠ Fail2Ban не запущен. Попробуйте: systemctl start fail2ban"
fi

# =============== ФИНАЛЬНАЯ СВОДКА ===============
print_step "📚 ФИНАЛЬНАЯ СВОДКА И РЕКОМЕНДАЦИИ"

print_success "✅ Оптимизация сервера успешно завершена!"

# Внешний IP
EXTERNAL_IP=$(curl -s4 https://api.ipify.org 2>/dev/null || echo "не удалось определить")
print_info "🌐 Внешний IP-адрес: ${EXTERNAL_IP}"

# SSH статус
if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
    print_success "🔑 SSH: пароли отключены (только ключи)"
else
    print_warning "🔑 SSH: пароли ВКЛЮЧЕНЫ (ключей не обнаружено)"
fi

# UFW статус
if ufw status | grep -i "Status: active" >/dev/null 2>&1; then
    print_success "🛡️ UFW: активен"
    print_info "   Открытые порты:"
    ufw status numbered | grep -E 'ALLOW|DENY'
else
    print_warning "🛡️ UFW: неактивен"
fi

# Fail2Ban статус
if systemctl is-active --quiet fail2ban; then
    print_success "👮 Fail2Ban: активен"
else
    print_warning "👮 Fail2Ban: неактивен"
fi

# Swap статус
SWAP_INFO=$(swapon --show --bytes | grep '/swapfile' || echo "не активен")
if [[ "$SWAP_INFO" != "не активен" ]]; then
    print_success "💾 Swap: активен"
    echo "$SWAP_INFO" | awk '{print "   "$0}'
else
    print_warning "💾 Swap: не активен"
fi

# Восстановительный аккаунт
RECOVERY_FILE="/root/recovery_info.txt"
if [ -f "$RECOVERY_FILE" ]; then
    print_warning "⚠️ ⚠️ ⚠️ ВАЖНО: СОЗДАН АККАУНТ ДЛЯ ВОССТАНОВЛЕНИЯ! ⚠️ ⚠️ ⚠️"
    cat "$RECOVERY_FILE"
    print_warning "✅ После проверки доступа удалите этого пользователя:"
    print_warning "   userdel -r $(grep 'Пользователь:' "$RECOVERY_FILE" | awk '{print $2}')"
    print_warning "   rm $RECOVERY_FILE"
fi

print_step "🔧 РЕКОМЕНДУЕМЫЕ ДЕЙСТВИЯ"

print_info "1️⃣ ПРОВЕРЬТЕ ДОСТУП ПО SSH:"
print_info "   Откройте НОВОЕ окно терминала и попробуйте подключиться:"
print_info "   ssh root@${EXTERNAL_IP}"
echo ""
print_info "2️⃣ ЕСЛИ ДОСТУП ЕСТЬ:"
print_info "   - Удалите временного пользователя (если он был создан)"
print_info "   - Настройте SSH ключи если еще не сделали"
echo ""
print_info "3️⃣ ЕСЛИ ДОСТУП ПОТЕРЯН:"
print_info "   - Используйте КОНСОЛЬ в панели Timeweb Cloud"
print_info "   - Войдите через восстановительный аккаунт"
print_info "   - Восстановите доступ: cp /root/backup_*/sshd_config.bak /etc/ssh/sshd_config"
print_info "   - systemctl restart ssh"
echo ""
print_warning "4️⃣ ВАЖНО: Для применения всех оптимизаций ядра рекомендуется перезагрузка:"
print_warning "   reboot"

print_success "🎉 Скрипт завершен! Ваш сервер оптимизирован и защищен."
