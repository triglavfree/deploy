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

# =============== УМНЫЕ ФУНКЦИИ ДЛЯ SYSCTL ===============
apply_sysctl_optimization() {
    local key="$1"
    local value="$2"
    local comment="$3"
    
    # Удаляем все существующие строки с этим ключом (включая комментарии)
    sed -i "/^[[:space:]]*$key[[:space:]]*=/d" /etc/sysctl.conf
    
    # Добавляем новую строку с комментарием
    if [ -n "$comment" ]; then
        echo "# $comment" >> /etc/sysctl.conf
    fi
    echo "$key=$value" >> /etc/sysctl.conf
    
    # Применяем изменение немедленно
    sysctl -w "$key=$value" >/dev/null 2>&1
}

# =============== ОПРЕДЕЛЕНИЕ КОРНЕВОГО УСТРОЙСТВА ===============
ROOT_DEVICE=$(df / --output=source | tail -1 | sed 's/\/dev\///' | sed 's/[0-9]*$//')

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
DEBIAN_FRONTEND=noninteractive apt-get update -yqq >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get upgrade -yqq >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get autoremove -yqq >/dev/null 2>&1
apt-get clean >/dev/null 2>&1
print_success "Система обновлена"

# =============== ШАГ 1: УСТАНОВКА ПАКЕТОВ ===============
print_step "Установка пакетов"
PACKAGES=("curl" "net-tools" "ufw" "fail2ban" "unzip" "hdparm" "nvme-cli")

print_info "→ Установка ${#PACKAGES[@]} пакетов"
if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${PACKAGES[@]}" >/dev/null 2>&1; then
    print_error "Ошибка установки пакетов. Проверьте подключение к интернету."
fi
print_success "Пакеты установлены: ${PACKAGES[*]}"

# =============== ШАГ 2: ОПТИМИЗАЦИЯ BBR ===============
print_step "Включение TCP BBR"
CURRENT_BBR=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}' || echo "")

if [[ "$CURRENT_BBR" != "bbr" ]]; then
    apply_sysctl_optimization "net.core.default_qdisc" "fq" "Планировщик для BBR"
    apply_sysctl_optimization "net.ipv4.tcp_congestion_control" "bbr" "TCP BBR congestion control"
    print_success "BBR включён"
else
    print_warning "BBR уже активен"
fi

# =============== ШАГ 3: ОПТИМИЗАЦИЯ ДИСКА ===============
print_step "Оптимизация диска"

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
    DISK_TYPE="virtio"
else
    DISK_TYPE="hdd"
fi
print_info "Определённый тип диска: $DISK_TYPE"

# === 1. НАСТРОЙКА ПЛАНИРОВЩИКА ВВОДА-ВЫВОДА ===
if [ -f /sys/block/"$ROOT_DEVICE"/queue/scheduler ]; then
    CURRENT_SCHEDULER=$(cat /sys/block/"$ROOT_DEVICE"/queue/scheduler 2>/dev/null | grep -o '\[.*\]' | tr -d '[]' || echo "unknown")
    print_info "Текущий планировщик: ${CURRENT_SCHEDULER:-неизвестно}"

    if [[ "$DISK_TYPE" == "nvme" ]]; then
        TARGET_SCHEDULER="none"
    elif [[ "$DISK_TYPE" == "virtio" ]]; then
        TARGET_SCHEDULER="none"
    elif [[ "$DISK_TYPE" == "ssd" ]]; then
        TARGET_SCHEDULER="mq-deadline"
    else
        TARGET_SCHEDULER="mq-deadline"
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
    if grep -q 'discard' /etc/fstab; then
        sed -i 's/,discard//g; s/discard,//g; s/discard//g' /etc/fstab
        print_success "TRIM (discard) отключён — не поддерживается для $DISK_TYPE"
    else
        print_info "TRIM не применяется для $DISK_TYPE (корректно)"
    fi
fi

# === 3. ПРОВЕРКА NVMe (только если NVMe) ===
if [[ "$DISK_TYPE" == "nvme" ]] && command -v nvme &> /dev/null; then
    print_info "Проверка состояния NVMe:"
    nvme smart-log "/dev/$ROOT_DEVICE" 2>/dev/null | grep -E "(critical|temperature|media|wear)" || true
fi

print_success "Оптимизация диска завершена"

# =============== ШАГ 4: НАСТРОЙКА ВИРТУАЛЬНОЙ ПАМЯТИ (ZRAM или SWAP) ===============
print_step "Настройка виртуальной памяти (авто-определение)"

TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
print_info "Обнаружено RAM: ${TOTAL_MEM_MB} MB"

# Функция для проверки наличия модуля zram
zram_available() {
    # Проверяем, загружен ли модуль
    if grep -q zram /proc/modules 2>/dev/null; then
        return 0
    fi
    # Проверяем, доступен ли модуль для загрузки
    if modprobe -n -v zram 2>/dev/null | grep -q 'insmod' 2>/dev/null; then
        return 0
    fi
    # Проверяем наличие файла модуля
    if find /lib/modules/$(uname -r) -name 'zram.ko*' -type f 2>/dev/null | grep -q .; then
        return 0
    fi
    return 1
}

if zram_available; then
    # === ZRAM доступен - используем его для слабых VPS ===
    print_info "→ Модуль zram доступен"
    
    if [ "$TOTAL_MEM_MB" -le 2048 ]; then
        print_info "→ RAM ≤ 2GB: настройка ZRAM"
        
        # Удаляем существующий swap-файл
        if swapon --show | grep -q '/swapfile'; then
            swapoff /swapfile 2>/dev/null
            sed -i '/\/swapfile/d' /etc/fstab 2>/dev/null
            rm -f /swapfile
            print_info "  Старый swap-файл отключён"
        fi
        
        # Устанавливаем zram-tools если нужно
        if ! command -v zramctl &> /dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq zram-tools >/dev/null 2>&1
        fi
        
        # Рассчитываем размер ZRAM
        ZRAM_SIZE_MB=$(( TOTAL_MEM_MB / 2 ))
        [ "$ZRAM_SIZE_MB" -lt 256 ] && ZRAM_SIZE_MB=256
        [ "$ZRAM_SIZE_MB" -gt 2048 ] && ZRAM_SIZE_MB=2048
        
        # Проверяем поддержку zstd
        if cat /proc/crypto 2>/dev/null | grep -q 'zstd'; then
            COMP_ALGO="zstd"
        else
            COMP_ALGO="lzo"
        fi
        
        # Настраиваем ZRAM
        cat > /etc/default/zramswap <<EOF
ALLOCATION=$ZRAM_SIZE_MB
COMP_ALGO=$COMP_ALGO
ENABLED=true
EOF
        
        systemctl enable zramswap --now >/dev/null 2>&1
        
        # Проверяем, что ZRAM запустился
        if zramctl | grep -q zram; then
            print_success "ZRAM настроен: ${ZRAM_SIZE_MB}MB (алгоритм: $COMP_ALGO)"
        else
            print_warning "ZRAM не запустился, создаём резервный swap-файл"
            # Резервный вариант - swap-файл
            SWAP_SIZE_GB=$(( TOTAL_MEM_MB <= 1024 ? 1 : 2 ))
            fallocate -l ${SWAP_SIZE_GB}G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE_GB * 1024))
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null
            swapon /swapfile
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
            print_success "Резервный swap ${SWAP_SIZE_GB}GB создан"
        fi
    else
        # Для >2GB RAM используем swap-файл даже если ZRAM доступен
        print_info "→ RAM > 2GB: создаём swap-файл"
        if ! swapon --show | grep -q '/swapfile'; then
            fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null
            swapon /swapfile
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
            print_success "Swap 2 GB создан"
        else
            print_warning "Swap уже активен"
        fi
    fi
else
    # === ZRAM недоступен - используем swap-файл ===
    print_warning "→ Модуль zram недоступен (типично для VPS)"
    print_info "→ Создаём swap-файл"
    
    # Определяем размер swap-файла
    if [ "$TOTAL_MEM_MB" -le 1024 ]; then
        SWAP_SIZE_GB=1
    elif [ "$TOTAL_MEM_MB" -le 2048 ]; then
        SWAP_SIZE_GB=2
    else
        SWAP_SIZE_GB=2
    fi
    
    if ! swapon --show | grep -q '/swapfile'; then
        fallocate -l ${SWAP_SIZE_GB}G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE_GB * 1024))
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        print_success "Swap ${SWAP_SIZE_GB}GB создан (резервная опция)"
    else
        print_warning "Swap уже активен"
    fi
fi

# =============== ШАГ 5: УНИВЕРСАЛЬНАЯ ОПТИМИЗАЦИЯ ЯДРА ===============
print_step "Универсальная оптимизация ядра"

# Все параметры в одном месте с комментариями
declare -A KERNEL_OPTS
KERNEL_OPTS=(
    # Память и диск
    ["vm.swappiness"]="10"                  # Баланс использования RAM/swap
    ["vm.vfs_cache_pressure"]="100"         # Давление на кэш файловой системы
    ["vm.dirty_background_ratio"]="5"      # Фоновая запись грязных страниц
    ["vm.dirty_ratio"]="10"                 # Максимальный процент грязных страниц
    ["vm.dirty_expire_centisecs"]="500"    # Время жизни грязных страниц (5 сек)
    ["vm.dirty_writeback_centisecs"]="100" # Интервал фоновой записи (1 сек)
    ["vm.min_free_kbytes"]="65536"          # Минимум свободной памяти (64MB)
    ["vm.overcommit_memory"]="1"            # Разрешить overcommit памяти
    
    # Сеть
    ["net.core.rmem_max"]="16777216"        # Макс. размер recv буфера (16MB)
    ["net.core.wmem_max"]="16777216"        # Макс. размер send буфера (16MB)
    ["net.core.somaxconn"]="1024"           # Макс. длина очереди подключений
    ["net.core.netdev_max_backlog"]="2000"  # Макс. пакетов в очереди NIC
    ["net.ipv4.tcp_rmem"]="4096 87380 16777216"  # Мин/деф/макс размер recv буфера TCP
    ["net.ipv4.tcp_wmem"]="4096 65536 16777216"  # Мин/деф/макс размер send буфера TCP
    ["net.ipv4.tcp_max_syn_backlog"]="2048"     # Макс. SYN запросов в очереди
    ["net.ipv4.tcp_slow_start_after_idle"]="0"  # Отключить slow start после простоя
    ["net.ipv4.tcp_notsent_lowat"]="16384"      # Мин. размер unsent буфера
    ["net.ipv4.tcp_fastopen"]="3"               # Включить TCP Fast Open
    ["net.ipv4.tcp_syncookies"]="1"             # Защита от SYN flood
    ["net.ipv4.tcp_tw_reuse"]="1"               # Переиспользование TIME-WAIT сокетов
    ["net.ipv4.tcp_fin_timeout"]="15"           # Таймаут FIN пакетов (15 сек)
    
    # Маршрутизация
    ["net.ipv4.ip_forward"]="1"             # Включить IP forwarding
    ["net.ipv4.conf.all.forwarding"]="1"    # Включить forwarding для всех интерфейсов
    ["net.ipv4.conf.default.forwarding"]="1" # Включить forwarding для новых интерфейсов
    ["net.ipv4.conf.all.src_valid_mark"]="1" # Валидация source mark
)

# Применяем все оптимизации
for key in "${!KERNEL_OPTS[@]}"; do
    value="${KERNEL_OPTS[$key]}"
    comment=""
    
    # Ищем комментарий для этого параметра
    case "$key" in
        "vm.swappiness") comment="Баланс использования RAM/swap" ;;
        "vm.vfs_cache_pressure") comment="Давление на кэш файловой системы" ;;
        "vm.dirty_background_ratio") comment="Фоновая запись грязных страниц" ;;
        "vm.dirty_ratio") comment="Максимальный процент грязных страниц" ;;
        "vm.dirty_expire_centisecs") comment="Время жизни грязных страниц (5 сек)" ;;
        "vm.dirty_writeback_centisecs") comment="Интервал фоновой записи (1 сек)" ;;
        "vm.min_free_kbytes") comment="Минимум свободной памяти (64MB)" ;;
        "vm.overcommit_memory") comment="Разрешить overcommit памяти" ;;
        "net.core.rmem_max") comment="Макс. размер recv буфера (16MB)" ;;
        "net.core.wmem_max") comment="Макс. размер send буфера (16MB)" ;;
        "net.core.somaxconn") comment="Макс. длина очереди подключений" ;;
        "net.core.netdev_max_backlog") comment="Макс. пакетов в очереди NIC" ;;
        "net.ipv4.tcp_rmem") comment="TCP recv буфер: мин/деф/макс" ;;
        "net.ipv4.tcp_wmem") comment="TCP send буфер: мин/деф/макс" ;;
        "net.ipv4.tcp_max_syn_backlog") comment="Макс. SYN запросов в очереди" ;;
        "net.ipv4.tcp_slow_start_after_idle") comment="Отключить slow start после простоя" ;;
        "net.ipv4.tcp_notsent_lowat") comment="Мин. размер unsent буфера" ;;
        "net.ipv4.tcp_fastopen") comment="Включить TCP Fast Open" ;;
        "net.ipv4.tcp_syncookies") comment="Защита от SYN flood" ;;
        "net.ipv4.tcp_tw_reuse") comment="Переиспользование TIME-WAIT сокетов" ;;
        "net.ipv4.tcp_fin_timeout") comment="Таймаут FIN пакетов (15 сек)" ;;
        "net.ipv4.ip_forward") comment="Включить IP forwarding" ;;
        "net.ipv4.conf.all.forwarding") comment="Включить forwarding для всех интерфейсов" ;;
        "net.ipv4.conf.default.forwarding") comment="Включить forwarding для новых интерфейсов" ;;
        "net.ipv4.conf.all.src_valid_mark") comment="Валидация source mark" ;;
    esac
    
    apply_sysctl_optimization "$key" "$value" "$comment"
    print_info "→ $key=$value"
done

# Специальные обработки для разных типов серверов
if [ "$TOTAL_MEM_MB" -le 1024 ]; then
    # Для слабых VPS (≤1GB RAM)
    apply_sysctl_optimization "vm.swappiness" "60" "Экстремальная экономия RAM для ≤1GB"
    apply_sysctl_optimization "vm.vfs_cache_pressure" "150" "Агрессивное освобождение кэша"
    print_info "→ Применены специальные настройки для слабого VPS (≤1GB RAM)"
elif [ "$TOTAL_MEM_MB" -le 2048 ]; then
    # Для средних VPS (1-2GB RAM)
    apply_sysctl_optimization "vm.swappiness" "30" "Оптимизация для 1-2GB RAM"
    print_info "→ Применены специальные настройки для среднего VPS (1-2GB RAM)"
fi

print_success "Все оптимизации ядра применены"

# =============== ШАГ 6: ОТКЛЮЧЕНИЕ НЕНУЖНЫХ СЕРВИСОВ ===============
print_step "Отключение ненужных сервисов для экономии ресурсов"
systemctl mask systemd-resolved systemd-networkd NetworkManager \
           snapd apt-daily.service apt-daily-upgrade.service 2>/dev/null
print_success "Ненужные сервисы отключены"

# =============== ШАГ 7: НАСТРОЙКА SSH ===============
print_step "Отключение парольной аутентификации SSH"
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)

sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?UsePAM.*/UsePAM no/' /etc/ssh/sshd_config

# Определение службы SSH
SSH_SERVICE=""
if systemctl list-unit-files --quiet 2>/dev/null | grep -q '^ssh\.service'; then
    SSH_SERVICE="ssh"
elif systemctl list-unit-files --quiet 2>/dev/null | grep -q '^sshd\.service'; then
    SSH_SERVICE="sshd"
else
    if pgrep -x "sshd" >/dev/null 2>&1; then SSH_SERVICE="sshd"
    elif pgrep -x "ssh" >/dev/null 2>&1; then SSH_SERVICE="ssh"
    else SSH_SERVICE="ssh"; fi
fi

print_info "Перезагрузка службы SSH ($SSH_SERVICE)..."
if ! systemctl reload "$SSH_SERVICE" 2>/dev/null; then
    systemctl restart "$SSH_SERVICE"
fi

if systemctl is-active --quiet "$SSH_SERVICE"; then
    print_success "Пароли в SSH отключены. Доступ только по ключу!"
else
    print_warning "Служба SSH перезагружена, но статус неактивен. Проверьте конфигурацию."
fi

# =============== ШАГ 8: НАСТРОЙКА UFW ===============
print_step "Настройка UFW"
ufw --force reset >/dev/null 2>&1
ufw default deny incoming comment 'Запретить входящий трафик'
ufw default allow outgoing comment 'Разрешить исходящий трафик'
ufw allow ssh comment 'SSH'
ufw allow http comment 'HTTP'
ufw allow https comment 'HTTPS'
ufw --force enable >/dev/null 2>&1
print_success "UFW включён"

# =============== ШАГ 9: НАСТРОЙКА FAIL2BAN ===============
print_step "Настройка Fail2Ban"
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

printf '\033c'

# =============== ФИНАЛЬНАЯ СВОДКА ===============
print_step "ФИНАЛЬНАЯ СВОДКА"
print_success "Настройка сервера завершена!"
print_success "Ядро оптимизировано!"

# Основная информация
EXTERNAL_IP=$(curl -s4 https://api.ipify.org 2>/dev/null || \
              curl -s4 https://ipinfo.io/ip 2>/dev/null || \
              curl -s4 https://icanhazip.com 2>/dev/null || \
              curl -s4 https://ifconfig.me/ip 2>/dev/null || \
              echo "не удалось определить")
print_info "Внешний IP-адрес: ${EXTERNAL_IP}"

# Сетевые оптимизации
BBR_STATUS=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "неизвестно")
print_info "BBR: ${BBR_STATUS}"

# Виртуальная память
print_info "Статус виртуальной памяти:"
if command -v zramctl &> /dev/null && zramctl | grep -q zram; then
    print_success "ZRAM: активен (сжатый swap в RAM)"
    while IFS= read -r line; do
        if [[ "$line" == *"NAME"* ]]; then continue; fi
        name=$(echo "$line" | awk '{print $1}')
        algo=$(echo "$line" | awk '{print $2}')
        compr=$(echo "$line" | awk '{print $3}')
        total=$(echo "$line" | awk '{print $4}')
        print_info "  → $name: $compr → $total ($algo)"
    done < <(zramctl)
else
    # Проверяем, почему ZRAM недоступен
    ZRAM_REASON=""
    if ! grep -q zram /proc/modules 2>/dev/null && ! modprobe -n -v zram 2>/dev/null | grep -q 'insmod' 2>/dev/null; then
        ZRAM_REASON=" (модуль ядра zram недоступен)"
    elif ! command -v zramctl &> /dev/null; then
        ZRAM_REASON=" (пакет zram-tools не установлен)"
    else
        ZRAM_REASON=" (ZRAM не активирован)"
    fi
    
    SWAP_SIZE=$(swapon --show --bytes | awk 'NR==2 {print $3}' 2>/dev/null || echo "неизвестно")
    if [[ "$SWAP_SIZE" != "неизвестно" ]] && [[ "$SWAP_SIZE" -gt 0 ]]; then
        print_success "Swap-файл: ${SWAP_SIZE} байт активно${ZRAM_REASON}"
    else
        print_warning "Виртуальная память не настроена!${ZRAM_REASON}"
    fi
fi

# Диск
TRIM_STATUS=$(grep -q 'discard' /etc/fstab 2>/dev/null && echo "включен" || echo "отключен")
print_info "TRIM для SSD: $TRIM_STATUS"
SCHEDULER_STATUS=$(cat /sys/block/"$ROOT_DEVICE"/queue/scheduler 2>/dev/null || echo "неизвестно")
print_info "Планировщик диска: ${SCHEDULER_STATUS:-неизвестно}"

# Безопасность
print_info "Открытые порты:"
ss -tuln | grep -E ':(22|80|443)\s' || print_warning "Не найдены ожидаемые порты (22, 80, 443)"

SSH_ACCESS=$(ss -tuln | grep ":$SSH_PORT" | grep LISTEN 2>/dev/null || echo "не слушается")
if [[ "$SSH_ACCESS" != "не слушается" ]]; then
    print_success "SSH сервер слушает порт $SSH_PORT"
else
    print_error "SSH сервер не слушает порт $SSH_PORT! Проверьте конфигурацию!"
fi

if systemctl is-active --quiet "fail2ban"; then
    print_success "Fail2Ban: активен (порт: $SSH_PORT)"
else
    print_warning "Fail2Ban: неактивен"
fi

UFW_STATUS=$(ufw status | grep -i "Status: active" 2>/dev/null || echo "inactive")
if [[ "$UFW_STATUS" == *"active"* ]]; then
    print_success "UFW: активен (защита сети включена)"
else
    print_warning "UFW: неактивен (защита сети отключена!)"
fi

print_warning "❗ ВАЖНО: Сохраните приватный ключ /root/.ssh/id_ed25519 и не теряйте его — пароли отключены!"
print_info "Рекомендуется перезагрузить сервер для применения всех оптимизаций: reboot"
