[![wg-easy](https://img.shields.io/badge/wg--easy-v15.1.0-f8f9fa?logo=wireguard&logoColor=e74c3c&labelColor=white&style=for-the-badge)](https://github.com/wg-easy/wg-easy)
[![Qwen Code](https://img.shields.io/badge/Qwen_Code-v0.5.2-f8f9fa?logo=github-copilot&logoColor=007ACC&labelColor=white&style=for-the-badge)](https://github.com/QwenLM/qwen-code)
[![Blitz Panel](https://img.shields.io/badge/Blitz_Panel-2.5.0-f8f9fa?label=⚡%20Blitz%20Panel&labelColor=white&style=for-the-badge)](https://github.com/ReturnFI/Blitz)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04_LTS-f8f9fa?logo=ubuntu&logoColor=E95420&labelColor=white&style=for-the-badge)](https://releases.ubuntu.com/24.04/)
[![n8n](https://img.shields.io/badge/n8n-v2.1.4-f8f9fa?logo=n8n&logoColor=000000&labelColor=white&style=for-the-badge)](https://github.com/n8n-io/n8n)



### Оптимизатор VPS
```bash
curl -fsSL https://raw.githubusercontent.com/triglavfree/deploy/main/scripts/vps/run.sh | sudo -E bash
```
---
### QWEN-CODE

Убедитесь, что у вас установлена ​​версия [Node.js](https://nodejs.org/en/download) или выше
```bash
curl -qL https://www.npmjs.com/install.sh | sh
```
Установите из npm
```bash
npm install -g @qwen-code/qwen-code@latest
```
<details>
<summary> добавить MCP сервер Context7</summary>
  
Откройте файл настроек Qwen Coder. Он находится в `~/.qwen/settings.json`
```bash
nano ~/.qwen/settings.json
```
Добавьте в него конфигурацию для Context7:
```json
{
  "mcpServers": {
    "context7": {
      "httpUrl": "https://mcp.context7.com/mcp",
      "headers": {
        "CONTEXT7_API_KEY": "YOUR_API_KEY",
        "Accept": "application/json, text/event-stream"
      }
    }
  }
}
```
В консоли QWEN-CODE выполните
```bash
 /mcp list
```

</details>

---
### n8n

Попробуйте n8n мгновенно с помощью [npx](https://docs.n8n.io/hosting/installation/npm/#try-n8n-with-npx) (требуется [Node.js](https://nodejs.org/en/download) ):
```bash
npx n8n
```

---
### WG-EASY + Caddy
```bash
curl -fsSL https://raw.githubusercontent.com/triglavfree/deploy/main/scripts/wireguard/install.sh | sudo -E bash
```
---
### Blitz Panel - Hysteria2

```bash
bash <(curl https://raw.githubusercontent.com/ReturnFI/Blitz/main/install.sh)
```
---
