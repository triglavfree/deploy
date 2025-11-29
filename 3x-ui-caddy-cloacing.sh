#!/bin/bash

# Убедитесь, что вы выполняете скрипт с правами суперпользователя
if [ "$EUID" -ne 0 ]; then
  echo "Пожалуйста, выполните скрипт как суперпользователь (sudo)."
  exit
fi

# Обновление пакетов
apt update && apt upgrade -y

# Установка необходимых зависимостей
apt install curl wget unzip uuid-runtime -y

# Оптимизация VPS
echo "Оптимизация VPS..."

# Установка и активация Swap
SWAP_SIZE=2G
fallocate -l $SWAP_SIZE /swapfile
chmod 600 /swapfile
mkswap /swapfile
swapon /swapfile

# Добавление Swap в fstab для автозагрузки
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# Оптимизация системы
echo "Применение оптимизаций..."
cat > /etc/sysctl.d/99-optimization.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 131072
net.core.wmem_default = 131072
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mem = 786432 1048576 1572864
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_retries2 = 8
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_keepalive_intvl = 15
net.core.netdev_max_backlog = 65536
net.core.somaxconn = 65535
net.ipv4.tcp_max_tw_buckets = 1440000
net.ipv4.tcp_tw_reuse = 1
EOF

sysctl -p /etc/sysctl.d/99-optimization.conf

# Установка Caddy
if ! command -v caddy &> /dev/null; then
    wget -qO - https://getcaddy.com | bash -s personal
fi

# Запрос домена у пользователя
read -p "Введите ваш домен (например, example.com): " DOMAIN

# Скачивание и установка 3X-UI
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

# Генерация UUID
UUID=$(uuidgen)

# Настройка Caddy
CADDYFILE="/etc/caddy/Caddyfile"

# Создание конфигурации Caddy для сайта маскировки и панели
sudo bash -c "cat > $CADDYFILE << EOF
$DOMAIN {
    reverse_proxy /$UUID/* localhost:8080  # Панель управления 3X-UI в подпапке с сгенерированным UUID
    reverse_proxy localhost:8080  # Сайт маскировки
    header {
        Referrer-Policy no-referrer
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
    }

    log {
        output file /var/log/caddy/$DOMAIN.log
    }

    tls {
        on_demand
    }
}
EOF"

# Скачивание шаблонного сайта маскировки
TEMPLATE_URL='https://example.com/template.zip'  # Замените на URL вашего шаблона
wget $TEMPLATE_URL -O template.zip
unzip template.zip -d /var/www/html/  # Путь к веб-директории Caddy

# Перемещение шаблона в корень сайта
mv /var/www/html/template/* /var/www/html/  # Переместите файлы шаблона в корень

# Перезагрузка Caddy
sudo systemctl restart caddy

echo "3X-UI успешно установлен. Доступ по домену https://$DOMAIN, панель управления доступна по https://$DOMAIN/$UUID/"

# Путь к сертификатам
SSL_CERT_PATH="/etc/caddy/data/certificates
