#!/usr/bin/env bash
# =============================================================================
#  Скрипт установки панели 3x-ui на VPS
#
#  Возможности:
#   - установка 3x-ui официальным установщиком;
#   - выбор прокси-сервера: nginx / caddy / без прокси;
#   - выдача сертификата по IP-адресу сервера: self-signed или ZeroSSL;
#   - настройка TLS и reverse proxy;
#   - настройка firewall.
#
#  Запуск с GitHub:
#   bash <(curl -fsSL https://raw.githubusercontent.com/<пользователь>/<репозиторий>/main/install.sh)
# =============================================================================

set -u

# -----------------------------------------------------------------------------
#  Переменные
# -----------------------------------------------------------------------------
PANEL_PORT="2053"                     # порт веб-панели 3x-ui
PANEL_PROTO="http"                    # протокол панели (http/https), определяется автоматически
PROXY_PORT="8443"                     # HTTPS-порт прокси
PROXY="none"                          # выбранный прокси: nginx / caddy / none
CERT_MODE="selfsigned"                # способ выдачи сертификата
CERT_DIR="/etc/ssl/x-ui"              # каталог сертификатов
CERT_PATH="${CERT_DIR}/cert.pem"      # путь к сертификату
KEY_PATH="${CERT_DIR}/key.pem"        # путь к ключу
IP=""                                 # публичный IP сервера
PKG_MANAGER="apt-get"                 # менеджер пакетов
OS_FAMILY="debian"                    # семейство ОС: debian / rhel
RELOAD_CMD="systemctl restart x-ui"   # команда перезагрузки после обновления сертификата

# Цвета для вывода
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'

# -----------------------------------------------------------------------------
#  Служебные функции вывода
# -----------------------------------------------------------------------------
log()  { echo -e "${CYAN}[*]${NC} $*"; }
ok()   { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*"; }

# -----------------------------------------------------------------------------
#  Проверка прав root
# -----------------------------------------------------------------------------
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        err "Скрипт должен запускаться от root (sudo)."
        exit 1
    fi
}

# -----------------------------------------------------------------------------
#  Определение ОС и менеджера пакетов
# -----------------------------------------------------------------------------
detect_os() {
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|linuxmint)
                PKG_MANAGER="apt-get"
                OS_FAMILY="debian"
                ;;
            centos|rocky|almalinux|rhel|fedora|ol)
                PKG_MANAGER="dnf"
                OS_FAMILY="rhel"
                if [ "$ID" = "centos" ] && [ "${VERSION_ID%%.*}" -lt 8 ]; then
                    PKG_MANAGER="yum"
                fi
                ;;
            *)
                err "Неподдерживаемая ОС: ${ID} (${PRETTY_NAME:-?})."
                exit 1
                ;;
        esac
    else
        err "Не удалось определить операционную систему."
        exit 1
    fi
    ok "Операционная система: ${PRETTY_NAME:-${ID}}"
}

# -----------------------------------------------------------------------------
#  Установка пакетов через системный менеджер
# -----------------------------------------------------------------------------
install_pkg() {
    case "$PKG_MANAGER" in
        apt-get)
            apt-get update -qq >/dev/null 2>&1
            apt-get install -y -qq "$@" >/dev/null 2>&1 || apt-get install -y "$@"
            ;;
        dnf)
            dnf install -y -q "$@" >/dev/null 2>&1 || dnf install -y "$@"
            ;;
        yum)
            yum install -y -q "$@" >/dev/null 2>&1 || yum install -y "$@"
            ;;
    esac
}

# -----------------------------------------------------------------------------
#  Определение публичного IP сервера
# -----------------------------------------------------------------------------
detect_ip() {
    log "Определяем публичный IP сервера..."
    IP=$(curl -fsS -m 10 https://api.ipify.org 2>/dev/null \
        || curl -fsS -m 10 https://ipinfo.io/ip 2>/dev/null \
        || hostname -I 2>/dev/null | awk '{print $1}')
    if [ -z "$IP" ]; then
        err "Не удалось определить IP сервера."
        exit 1
    fi
    case "$IP" in
        *:*) warn "Обнаружен IPv6-адрес (${IP}); сертификаты лучше выписывать для IPv4." ;;
    esac
    ok "IP сервера: ${IP}"
}

# -----------------------------------------------------------------------------
#  Установка 3x-ui официальным установщиком
# -----------------------------------------------------------------------------
install_3xui() {
    if command -v x-ui >/dev/null 2>&1; then
        warn "3x-ui уже установлен."
        read -rp "Переустановить 3x-ui? [y/N]: " REINSTALL
        case "${REINSTALL:-n}" in
            y|Y|д|Д) ;;
            *) ok "Продолжаем настройку без переустановки 3x-ui."; return 0 ;;
        esac
    fi
    if ! command -v curl >/dev/null 2>&1; then
        log "Устанавливаем curl..."
        install_pkg curl
    fi
    ok "Запускаем официальный установщик 3x-ui (следуйте подсказкам установщика)..."
    ok "Подсказка: на вопрос про выдачу SSL-сертификата ответьте 'нет' — сертификат мы выдадим сами."
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
    if ! command -v x-ui >/dev/null 2>&1; then
        err "3x-ui не установился. Проверьте вывод установщика выше."
        exit 1
    fi
    ok "3x-ui установлен."
}

# -----------------------------------------------------------------------------
#  Запрос порта панели и определение её протокола
# -----------------------------------------------------------------------------
ask_panel_port() {
    read -rp "Порт веб-панели 3x-ui (по умолчанию ${PANEL_PORT}): " P
    PANEL_PORT="${P:-${PANEL_PORT}}"
}

detect_panel_proto() {
    log "Проверяем протокол веб-панели на 127.0.0.1:${PANEL_PORT}..."
    if curl -ksS -o /dev/null -m 5 "https://127.0.0.1:${PANEL_PORT}/" 2>/dev/null; then
        PANEL_PROTO="https"
    else
        PANEL_PROTO="http"
    fi
    ok "Панель работает по протоколу: ${PANEL_PROTO}://127.0.0.1:${PANEL_PORT}"
}

# -----------------------------------------------------------------------------
#  Интерактивный выбор прокси-сервера
# -----------------------------------------------------------------------------
choose_proxy() {
    echo
    echo "═══════════════════════════════════════════════"
    echo "  Выбор прокси-сервера"
    echo "═══════════════════════════════════════════════"
    echo "  1) nginx"
    echo "  2) caddy"
    echo "  3) без прокси (панель напрямую)"
    read -rp "Ваш выбор [1-3] (по умолчанию 1): " C
    case "${C:-1}" in
        1) PROXY="nginx" ;;
        2) PROXY="caddy" ;;
        3) PROXY="none" ;;
        *) warn "Неверный выбор, используем nginx."; PROXY="nginx" ;;
    esac

    if [ "$PROXY" = "none" ]; then
        PROXY_NAME="без прокси"
    else
        PROXY_NAME="$PROXY"
        read -rp "HTTPS-порт прокси (по умолчанию ${PROXY_PORT}): " P
        PROXY_PORT="${P:-${PROXY_PORT}}"
    fi

    case "$PROXY" in
        nginx) RELOAD_CMD="systemctl reload nginx || systemctl restart nginx" ;;
        caddy) RELOAD_CMD="systemctl reload caddy || systemctl restart caddy" ;;
        none)  RELOAD_CMD="systemctl restart x-ui" ;;
    esac
    ok "Выбран прокси: ${PROXY_NAME}"
}

# -----------------------------------------------------------------------------
#  Интерактивный выбор способа выдачи сертификата по IP
# -----------------------------------------------------------------------------
choose_cert() {
    echo
    echo "═══════════════════════════════════════════════"
    echo "  Выдача сертификата по IP: ${IP}"
    echo "═══════════════════════════════════════════════"
    echo "  1) Self-signed (openssl) — работает сразу, срок 365 дней"
    echo "  2) ZeroSSL — валидный сертификат по IP, нужен свободный порт 80"
    read -rp "Ваш выбор [1-2] (по умолчанию 1): " C
    case "${C:-1}" in
        1) CERT_MODE="selfsigned" ;;
        2) CERT_MODE="zerossl" ;;
        *) warn "Неверный выбор, используем self-signed."; CERT_MODE="selfsigned" ;;
    esac
    mkdir -p "$CERT_DIR"
    CERT_PATH="${CERT_DIR}/cert.pem"
    KEY_PATH="${CERT_DIR}/key.pem"
}

# -----------------------------------------------------------------------------
#  Self-signed сертификат через openssl (SAN = IP сервера)
# -----------------------------------------------------------------------------
issue_selfsigned() {
    log "Генерируем self-signed сертификат для IP ${IP} (срок 365 дней)..."
    openssl req -x509 -newkey rsa:2048 -sha256 -nodes \
        -keyout "$KEY_PATH" -out "$CERT_PATH" -days 365 \
        -subj "/CN=${IP}" \
        -addext "subjectAltName=IP:${IP}" >/dev/null 2>&1
    chmod 644 "$CERT_PATH"
    chmod 600 "$KEY_PATH"
    ok "Сертификат создан: ${CERT_PATH}"
}

# -----------------------------------------------------------------------------
#  Валидный сертификат по IP через acme.sh + ZeroSSL (HTTP-01, порт 80)
# -----------------------------------------------------------------------------
issue_zerossl() {
    if ! command -v socat >/dev/null 2>&1; then
        log "Устанавливаем socat..."
        install_pkg socat
    fi
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ':80$'; then
        err "Порт 80 занят, а он необходим для проверки ZeroSSL (HTTP-01)."
        err "Остановите сервис на порту 80 или выберите self-signed."
        exit 1
    fi
    read -rp "Ваш email для регистрации на ZeroSSL: " ZEROSSL_EMAIL
    if [ -z "$ZEROSSL_EMAIL" ]; then
        err "Email обязателен для ZeroSSL."
        exit 1
    fi
    if [ ! -f "$HOME/.acme.sh/acme.sh" ]; then
        log "Устанавливаем acme.sh..."
        curl -fsSL https://get.acme.sh | sh -s email="$ZEROSSL_EMAIL"
    fi
    log "Запрашиваем сертификат ZeroSSL для IP ${IP}..."
    "$HOME/.acme.sh/acme.sh" --issue --server zerossl -d "$IP" \
        --standalone --force --accountemail "$ZEROSSL_EMAIL"
    log "Устанавливаем сертификат в ${CERT_DIR}..."
    "$HOME/.acme.sh/acme.sh" --install-cert -d "$IP" \
        --fullchain-file "$CERT_PATH" \
        --key-file "$KEY_PATH" \
        --reloadcmd "$RELOAD_CMD"
    chmod 644 "$CERT_PATH"
    chmod 600 "$KEY_PATH"
    ok "Сертификат ZeroSSL установлен (автопродление через acme.sh)."
}

# -----------------------------------------------------------------------------
#  Применение сертификата к самой панели (режим "без прокси")
# -----------------------------------------------------------------------------
setup_panel_tls() {
    log "Применяем сертификат к панели 3x-ui..."
    x-ui settings -webCertPath "$CERT_PATH"
    x-ui settings -webKeyPath "$KEY_PATH"
    systemctl restart x-ui
    ok "Панель переведена на HTTPS."
}

# -----------------------------------------------------------------------------
#  Настройка nginx как reverse proxy
# -----------------------------------------------------------------------------
setup_nginx() {
    log "Устанавливаем nginx..."
    install_pkg nginx

    # Поддержка WebSocket-апгрейдов для панели
    cat > /etc/nginx/conf.d/websocket-upgrade.conf <<'EOF'
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}
EOF

    # Дополнительные директивы, если панель сама на HTTPS
    local SSL_UPSTREAM=""
    if [ "$PANEL_PROTO" = "https" ]; then
        SSL_UPSTREAM="        proxy_ssl_verify off;
        proxy_ssl_server_name off;"
    fi

    cat > /etc/nginx/conf.d/x-ui.conf <<EOF
server {
    listen ${PROXY_PORT} ssl;
    server_name _;

    ssl_certificate ${CERT_PATH};
    ssl_certificate_key ${KEY_PATH};
    ssl_protocols TLSv1.2 TLSv1.3;

    location / {
        proxy_pass ${PANEL_PROTO}://127.0.0.1:${PANEL_PORT};
${SSL_UPSTREAM}
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_http_version 1.1;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }
}
EOF

    if ! nginx -t >/dev/null 2>&1; then
        err "Ошибка конфигурации nginx:"
        nginx -t
        exit 1
    fi
    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx
    ok "nginx настроен: https://${IP}:${PROXY_PORT}"
}

# -----------------------------------------------------------------------------
#  Настройка caddy как reverse proxy
# -----------------------------------------------------------------------------
setup_caddy() {
    log "Устанавливаем caddy..."
    if [ "$OS_FAMILY" = "debian" ]; then
        install_pkg debian-keyring debian-archive-keyring apt-transport-https curl
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg 2>/dev/null
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq caddy >/dev/null 2>&1 || apt-get install -y caddy
    else
        curl -fsSL -o /etc/yum.repos.d/caddy.repo \
            'https://dl.cloudsmith.io/public/caddy/stable/cfg/rpm.repo.txt'
        dnf install -y -q caddy >/dev/null 2>&1 || dnf install -y caddy
    fi

    if [ "$PANEL_PROTO" = "https" ]; then
        cat > /etc/caddy/Caddyfile <<EOF
:${PROXY_PORT} {
    tls ${CERT_PATH} ${KEY_PATH}
    reverse_proxy https://127.0.0.1:${PANEL_PORT} {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
EOF
    else
        cat > /etc/caddy/Caddyfile <<EOF
:${PROXY_PORT} {
    tls ${CERT_PATH} ${KEY_PATH}
    reverse_proxy http://127.0.0.1:${PANEL_PORT}
}
EOF
    fi

    systemctl enable caddy >/dev/null 2>&1 || true
    if ! systemctl restart caddy; then
        err "Не удалось запустить caddy. Последние строки лога:"
        journalctl -u caddy -n 20 --no-pager 2>/dev/null || true
        exit 1
    fi
    ok "caddy настроен: https://${IP}:${PROXY_PORT}"
}

# -----------------------------------------------------------------------------
#  Настройка firewall (ufw / firewalld)
# -----------------------------------------------------------------------------
setup_firewall() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 80/tcp >/dev/null
        ufw allow "${PROXY_PORT}"/tcp >/dev/null
        ufw allow "${PANEL_PORT}"/tcp >/dev/null
        ok "Правила ufw добавлены (порты 80, ${PROXY_PORT}, ${PANEL_PORT})."
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=80/tcp >/dev/null
        firewall-cmd --permanent --add-port="${PROXY_PORT}"/tcp >/dev/null
        firewall-cmd --permanent --add-port="${PANEL_PORT}"/tcp >/dev/null
        firewall-cmd --reload >/dev/null
        ok "Правила firewalld добавлены (порты 80, ${PROXY_PORT}, ${PANEL_PORT})."
    else
        warn "Активный firewall (ufw/firewalld) не обнаружен."
        warn "При необходимости откройте вручную порты: 80/tcp, ${PROXY_PORT}/tcp, ${PANEL_PORT}/tcp."
    fi
}

# -----------------------------------------------------------------------------
#  Настройка SELinux для RHEL-семейства
# -----------------------------------------------------------------------------
setup_selinux() {
    if command -v getenforce >/dev/null 2>&1 && [ "$(getenforce)" = "Enforcing" ]; then
        log "Настраиваем SELinux..."
        setsebool -P httpd_can_network_connect 1 2>/dev/null || true
        if command -v semanage >/dev/null 2>&1 && [ "$PROXY" != "none" ]; then
            semanage port -a -t http_port_t -p tcp "$PROXY_PORT" 2>/dev/null || true
        fi
        ok "SELinux настроен (httpd_can_network_connect)."
    fi
}

# -----------------------------------------------------------------------------
#  Итоговая сводка
# -----------------------------------------------------------------------------
print_summary() {
    echo
    echo "═══════════════════════════════════════════════"
    echo "   Установка завершена"
    echo "═══════════════════════════════════════════════"
    if [ "$PROXY" = "none" ]; then
        echo "   Панель:      https://${IP}:${PANEL_PORT}"
    else
        echo "   Прокси:      ${PROXY}"
        echo "   Панель:      https://${IP}:${PROXY_PORT}"
        echo "   Внутренний:  ${PANEL_PROTO}://127.0.0.1:${PANEL_PORT}"
    fi
    echo "   Сертификат:  ${CERT_PATH}"
    echo "   Ключ:        ${KEY_PATH}"
    echo
    echo "   Учётные данные панели — те, что были выведены при установке 3x-ui."
    echo "   Управление панелью из терминала:  x-ui"
    echo "   Статус службы:                    systemctl status x-ui"
    if [ "$PROXY" = "nginx" ]; then
        echo "   Статус nginx:                     systemctl status nginx"
    elif [ "$PROXY" = "caddy" ]; then
        echo "   Статус caddy:                     systemctl status caddy"
    fi
    echo "═══════════════════════════════════════════════"
}

# -----------------------------------------------------------------------------
#  Главный блок
# -----------------------------------------------------------------------------
main() {
    check_root

    echo "═══════════════════════════════════════════════"
    echo "  Установка панели 3x-ui"
    echo "  Выбор прокси: nginx / caddy / без прокси"
    echo "  Сертификат по IP: self-signed / ZeroSSL"
    echo "═══════════════════════════════════════════════"

    detect_os

    log "Проверяем зависимости..."
    if ! command -v curl >/dev/null 2>&1; then install_pkg curl; fi
    if ! command -v openssl >/dev/null 2>&1; then install_pkg openssl; fi

    detect_ip
    install_3xui
    ask_panel_port
    detect_panel_proto
    choose_proxy
    choose_cert

    # Выдача сертификата по IP
    if [ "$CERT_MODE" = "selfsigned" ]; then
        issue_selfsigned
    else
        issue_zerossl
    fi

    # Настройка в зависимости от выбранного прокси
    case "$PROXY" in
        nginx) setup_nginx ;;
        caddy) setup_caddy ;;
        none)  setup_panel_tls ;;
    esac

    setup_firewall
    setup_selinux
    print_summary
}

main "$@"
