### Как использовать скрипт:
- Для домена `vpn.duckdns.com`: [Duck DNS](https://www.duckdns.org/)
```bash
curl -s https://raw.githubusercontent.com/triglavfree/deploy/main/scripts/wireguard/wg-easy.sh | sudo bash -s vpn.duckdns.com
```
### Особенности скрипта:

✅ Цветной вывод - использует ANSI escape codes для цветного вывода в консоль

✅ Параметр DOMAIN из командной строки - не нужно редактировать скрипт

✅ Оптимизации для слабого VPS:

   - BBR для сетевой производительности
   - Swap 2GB для предотвращения OOM
   - Оптимизация NVMe/SSD
   - Сетевые настройки ядра

✅ Безопасность:

   - UFW с минимальными открытыми портами
   - Fail2Ban для защиты от брутфорса
   - Автоматические SSL-сертификаты от Let's Encrypt
   - Отдельный пользователь для wg-easy

✅ Современные технологии:

   - nftables вместо iptables
   - Caddy как reverse proxy с автоматическими SSL
   - Systemd сервисы для управления
   - Node.js 20.x LTS

✅ Ubuntu 24.04 LTS - полностью протестирован на минимальной установке

✅ Без Docker - использует возможности ядра Linux и нативные пакеты  

### Требования к VPS:
   - Ubuntu 24.04 minimal LTS
   - Root доступ по SSH ключу
   - Домен с A-записью на IP сервера
   - Минимум 1 CPU, 1GB RAM, 10GB NVMe/SSD
---
Скрипт полностью автоматизирован и требует только указания домена при запуске!
