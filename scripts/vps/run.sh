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

# Проверка, остались ли пакеты для обновления после upgrade
check_if_fully_updated() {
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 || true
    if apt-get --just-print upgrade 2>/dev/null | grep -q "^Inst"; then
        echo "доступны обновления"
    else
        echo "актуальна"
    fi
}

# Проверка и применение оптимизаций ядра только один раз
apply_max_performance_optimizations() {
    local config_file="/etc/sysctl.d/99-max-performance.conf"
    local needs_update=false
    
    # Проверяем, существует ли файл и содержит ли он BBR-настройку
    if [ ! -f "$config_file" ]; then
        needs_update=true
    else
        if ! grep -q "net.ipv4.tcp_congestion_control = bbr" "$config_file"; then
            needs_update=true
        fi
    fi
    
    if [ "$needs_update" = true ]; then
        print_info "Применение максимальных оптимизаций ядра..."
        mkdir -p /etc/sysctl.d
        
        # === КРИТИЧЕСКИ ВАЖНО: загружаем модуль tcp_bbr ===
        if ! lsmod | grep -q "tcp_bbr"; then
            if modprobe tcp_bbr 2>/dev/null; then
                print_info "Модуль ядра tcp_bbr загружен."
                # Сохраняем для автозагрузки после перезагрузки
                echo "tcp_bbr" > /etc/modules-load.d/tcp-bbr.conf
            else
                print_warning "Не удалось загрузить модуль tcp_bbr. BBR может не активироваться."
            fi
        else
            print_info "Модуль tcp_bbr уже загружен."
        fi

        # Записываем полный конфиг
        cat > "$config_file" << 'EOF'
# BBR congestion control
net.core.default_qdisc = fq               # Контроллер очереди для BBR
net.ipv4.tcp_congestion_control = bbr     # Современный алгоритм контроля перегрузки
net.ipv4.tcp_fastopen = 3                 # Ускорение установки соединений

# Сетевые буферы
net.core.rmem_max = 67108864              # Макс. размер буфера приема (64MB)
net.core.wmem_max = 67108864              # Макс. размер буфера передачи (64MB)
net.core.rmem_default = 131072            # Стандартный размер буфера приема
net.core.wmem_default = 131072            # Стандартный размер буфера передачи
net.ipv4.tcp_rmem = 4096 87380 67108864   # Динамические буферы приема TCP
net.ipv4.tcp_wmem = 4096 65536 67108864   # Динамические буферы передачи TCP
net.ipv4.tcp_mem = 786432 1048576 1572864 # Память для TCP соединений

# Лимиты подключений
net.core.somaxconn = 65535                # Макс. длина очереди accept() (65K)
net.core.netdev_max_backlog = 65536       # Макс. очередь для сетевых устройств
net.ipv4.tcp_max_syn_backlog = 65536      # Макс. очередь SYN-запросов
net.ipv4.tcp_max_tw_buckets = 1440000     # Макс. TIME-WAIT бакетов

# Оптимизация TCP
net.ipv4.tcp_slow_start_after_idle = 0    # Отключить медленный старт после простоя
net.ipv4.tcp_synack_retries = 2           # Повторы SYN-ACK (быстрый отказ)
net.ipv4.tcp_syn_retries = 3              # Повторы SYN (быстрый отказ)
net.ipv4.tcp_retries2 = 8                 # Повторы для установившихся соединений
net.ipv4.tcp_tw_reuse = 1                 # Reuse TIME-WAIT сокетов
net.ipv4.tcp_fin_timeout = 30             # Таймаут FIN пакетов

# Keepalive настройки
net.ipv4.tcp_keepalive_time = 300         # Интервал проверки живости (5 мин)
net.ipv4.tcp_keepalive_probes = 5         # Количество проверок перед разрывом
net.ipv4.tcp_keepalive_intvl = 15         # Интервал между проверками (15 сек)

# Безопасность и стабильность
net.ipv4.tcp_syncookies = 1               # Защита от SYN-флуд атак
net.ipv4.ip_forward = 1                   # Важно для роутеров/шлюзов

# VM параметры оптимизации памяти
vm.swappiness = 30                        # Контроль использования swap
vm.vfs_cache_pressure = 100               # Баланс кэширования
vm.dirty_background_ratio = 5             # Начинать фоновую запись при 5% dirty
vm.dirty_ratio = 15                       # Макс. dirty pages перед блокировкой
vm.overcommit_memory = 1                  # Агрессивный overcommit памяти

# Дополнительные оптимизации
fs.file-max = 2097152                     # Макс. количество файловых дескрипторов
fs.inotify.max_user_watches = 524288      # Макс. наблюдений за файлами
fs.inotify.max_user_instances = 512       # Макс. экземпляров inotify
EOF

        # Применяем настройки
        sysctl -p "$config_file" >/dev/null 2>&1 || true
        
        # Проверяем, что BBR действительно активен
        if sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "^bbr$"; then
            print_success "Максимальные оптимизации ядра применены (BBR активен)"
        else
            print_warning "Оптимизации применены, но BBR не активен. Проверьте: modprobe tcp_bbr"
        fi
    else
    print_info "Максимальные оптимизации ядра уже настроены"
    if ! lsmod | grep -q "tcp_bbr"; then
        if modprobe tcp_bbr 2>/dev/null; then
            echo "tcp_bbr" > /etc/modules-load.d/tcp-bbr.conf
            # Важно: повторно применить sysctl, чтобы bbr заработал
            sysctl -p "$config_file" >/dev/null 2>&1
            print_info "Модуль tcp_bbr загружен и настройки применены"
        fi
    else
        # Убедимся, что bbr активен (на случай, если sysctl не сработал ранее)
        if ! sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "^bbr$"; then
            sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
        fi
    fi
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
    print_info "3. Вручную: добавьте содержимое .pub в /root/.ssh/authorized_keys"
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

# =============== ОПТИМИЗАЦИЯ ЯДРА (МАКСИМАЛЬНАЯ ПРОИЗВОДИТЕЛЬНОСТЬ) ===============
print_step "Оптимизация ядра для МАКСИМАЛЬНОЙ производительности"
TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
print_info "Обнаружено RAM: ${TOTAL_MEM_MB} MB"

# Применяем максимальные оптимизации (только если еще не применены)
apply_max_performance_optimizations

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
    
    # Добавляем в fstab только если еще не добавлен
    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    
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

# Создаем конфиг только если его нет или он не содержит наших настроек
if [ ! -f /etc/fail2ban/jail.d/sshd.local ] || ! grep -q "maxretry = 5" /etc/fail2ban/jail.d/sshd.local; then
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
else
    print_info "Fail2Ban уже настроен"
fi

# =============== ФИНАЛЬНАЯ СВОДКА ===============
printf '\033c'
print_step "ФИНАЛЬНАЯ СВОДКА"
print_success "ОС: $PRETTY_NAME ($SYSTEM_UPDATE_STATUS)"
print_success "Планировщик диска: $(cat "/sys/block/$ROOT_DEVICE/queue/scheduler" 2>/dev/null || echo "неизвестно")"
print_success "SSH: пароли отключены (только ключи)"
print_success "TRIM для SSD: $(grep -q 'discard' /etc/fstab && echo "включён" || echo "отключён")"

# BBR
QDISC=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "неизвестно")
BBR=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "неизвестно")
print_success "Сетевой стек: qdisc=$QDISC, BBR=$BBR"

if [ -z "$SSH_CLIENT" ]; then
    EXTERNAL_IP=$(curl -s https://api.ipify.org   2>/dev/null || echo "неизвестен")
    print_info "Внешний IP сервера: $EXTERNAL_IP"
fi

print_info "Брандмауэр UFW:"
print_info "  → Все входящие подключения ЗАБЛОКИРОВАНЫ"
if [ -n "$CURRENT_IP" ]; then
    print_info "  → SSH ($SSH_PORT) разрешён только с: $CURRENT_IP"
else
    print_info "  → SSH ($SSH_PORT) разрешён для всех"
fi

# Очистка старых резервных копий (оставляем только последнюю)
find /root -maxdepth 1 -name "backup_20*" -type d | sort -r | tail -n +2 | xargs rm -rf 2>/dev/null || true
print_info "Старые резервные копии удалены. Последняя копия сохранена."

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

# Перезагрузка?
if [ -f /var/run/reboot-required ]; then
    print_warning "Установлены обновления, требующие перезагрузки"
    print_info "   Выполните: reboot"
else
    print_success "Оптимизация и защита сервера завершены!"
fi
