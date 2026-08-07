#!/usr/bin/env bash
# =============================================================================
#  Скрипт установки панели 3x-ui на VPS
#
#  Возможности:
#   - установка 3x-ui официальным установщиком;
#   - выбор и настройка прокси-сервера: nginx / caddy / без прокси;
#   - настройка firewall.
#
#  Запуск с GitHub:
#   bash <(curl -fsSL https://raw.githubusercontent.com/<пользователь>/<репозиторий>/main/install.sh)
# =============================================================================

set -u

# -----------------------------------------------------------------------------
#  Переменные
# -----------------------------------------------------------------------------
PANEL_PORT=""                        # порт веб-панели 3x-ui (определяется автоматически)
PANEL_PROTO="http"                    # протокол панели (http/https), определяется автоматически
PANEL_CERT=""                        # путь к fullchain.pem панели (для TLS на прокси)
PANEL_KEY=""                         # путь к privkey.pem панели
PANEL_HOST=""                        # домен из сертификата панели (если сертификат на домен); пусто — использовать IP
PROXY_PORT="443"                      # порт прокси
PROXY_SCHEME="http"                   # внешний протокол прокси (http/https)
PROXY="none"                          # выбранный прокси: nginx / caddy / none
IP=""                                 # публичный IP сервера
PKG_MANAGER="apt-get"                 # менеджер пакетов
OS_FAMILY="debian"                    # семейство ОС: debian / rhel
XUI_INSTALL_LOG="/var/log/3x-ui-install.log"   # лог вывода официального установщика

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
    ok "Его вывод сохраняется в ${XUI_INSTALL_LOG}."
    bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) 2>&1 | tee "$XUI_INSTALL_LOG"
    if ! command -v x-ui >/dev/null 2>&1; then
        err "3x-ui не установился. Проверьте вывод установщика выше."
        exit 1
    fi
    ok "3x-ui установлен."
}

# -----------------------------------------------------------------------------
#  Чтение лога выпуска сертификата и обработка ошибок
# -----------------------------------------------------------------------------
# Применение сертификата к панели (путь к fullchain и ключу)
apply_cert_to_panel() {
    local CERT_FULL="$1"
    local CERT_KEY="$2"
    if [ -f "$CERT_FULL" ] && [ -f "$CERT_KEY" ]; then
        /usr/local/x-ui/x-ui cert -webCert "$CERT_FULL" -webCertKey "$CERT_KEY" >/dev/null 2>&1
        systemctl restart x-ui >/dev/null 2>&1 || true
        ok "Сертификат применён к панели: ${CERT_FULL}"
    else
        warn "Файлы сертификата не найдены (${CERT_FULL})."
    fi
}

# Выпуск self-signed сертификата с SAN=IP
issue_selfsigned_cert() {
    local CERT_DIR="/root/cert/selfsigned"
    if ! command -v openssl >/dev/null 2>&1; then
        log "Устанавливаем openssl..."
        install_pkg openssl
    fi
    mkdir -p "$CERT_DIR"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -subj "/CN=${IP}" \
        -addext "subjectAltName=IP:${IP}" \
        -keyout "$CERT_DIR/privkey.pem" \
        -out "$CERT_DIR/fullchain.pem" >/dev/null 2>&1
    chmod 600 "$CERT_DIR/privkey.pem"
    chmod 644 "$CERT_DIR/fullchain.pem"
    ok "Self-signed сертификат выпущен (SAN=IP)."
    apply_cert_to_panel "$CERT_DIR/fullchain.pem" "$CERT_DIR/privkey.pem"
}

# Выпуск ZeroSSL сертификата через acme.sh (HTTP-01, нужен открытый порт 80)
issue_zerossl_cert() {
    local ACME_SH="${HOME}/.acme.sh/acme.sh"
    local CERT_DIR="/root/cert/zerossl"
    local EMAIL
    local ADDR="$IP"

    if [ ! -x "$ACME_SH" ]; then
        log "Устанавливаем acme.sh..."
        curl -s https://get.acme.sh | sh >/dev/null 2>&1 || true
        if [ ! -x "$ACME_SH" ]; then
            err "Не удалось установить acme.sh. Self-signed сертификат останется вариантом."
            return 1
        fi
    fi

    read -rp "E-mail для регистрации в ZeroSSL: " EMAIL
    EMAIL="${EMAIL:-}"
    if [ -z "$EMAIL" ]; then
        warn "E-mail не указан — ZeroSSL недоступен."
        return 1
    fi

    warn "ZeroSSL использует HTTP-01 проверку — нужен открытый порт 80."
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 80/tcp >/dev/null 2>&1 && ok "Порт 80 временно открыт в ufw."
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port=80/tcp >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1 && ok "Порт 80 временно открыт в firewalld."
    fi

    mkdir -p "$CERT_DIR"
    "$ACME_SH" --set-default-ca --server zerossl >/dev/null 2>&1
    "$ACME_SH" --register-account -m "$EMAIL" >/dev/null 2>&1 || true
    ok "Выпускаем ZeroSSL сертификат для ${ADDR}..."
    if "$ACME_SH" --issue -d "$ADDR" --standalone --httpport 80 --server zerossl --force; then
        "$ACME_SH" --installcert --force -d "$ADDR" \
            --key-file "$CERT_DIR/privkey.pem" \
            --fullchain-file "$CERT_DIR/fullchain.pem" >/dev/null 2>&1 || true
        if [ -f "$CERT_DIR/fullchain.pem" ] && [ -f "$CERT_DIR/privkey.pem" ]; then
            chmod 600 "$CERT_DIR/privkey.pem"
            chmod 644 "$CERT_DIR/fullchain.pem"
            ok "ZeroSSL сертификат выпущен."
            apply_cert_to_panel "$CERT_DIR/fullchain.pem" "$CERT_DIR/privkey.pem"
        else
            err "Файлы сертификата ZeroSSL не найдены после установки."
            return 1
        fi
    else
        err "Не удалось выпустить ZeroSSL сертификат (возможно, лимит или закрытый порт 80)."
        return 1
    fi
}

# Меню выбора альтернативного сертификата (при ошибке у официального установщика)
offer_alt_cert() {
    echo
    echo "═══════════════════════════════════════════════"
    echo "  Выпуск альтернативного сертификата"
    echo "═══════════════════════════════════════════════"
    echo "  1) ZeroSSL — валидный бесплатный сертификат (нужен e-mail, порт 80)"
    echo "  2) Self-signed — openssl SAN=IP, работает всегда"
    echo "  3) Пропустить — оставить как есть"
    read -rp "Ваш выбор [1-3] (по умолчанию 2): " C
    case "${C:-2}" in
        1)
            if issue_zerossl_cert; then
                ok "Альтернативный сертификат установлен."
            else
                warn "ZeroSSL не удался. Попробуем self-signed."
                issue_selfsigned_cert
            fi
            ;;
        2)
            issue_selfsigned_cert
            ;;
        3)
            warn "Пропускаем. Повторить попытку выпуска позже можно через меню: x-ui"
            ;;
        *)
            warn "Неверный выбор, используем self-signed."
            issue_selfsigned_cert
            ;;
    esac
}

# Проверка лога установщика на ошибку выпуска сертификата
check_cert_issue() {
    local CLEAN

    if [ ! -s "$XUI_INSTALL_LOG" ]; then
        warn "Лог установщика (${XUI_INSTALL_LOG}) отсутствует — проверка сертификата пропущена."
        return 0
    fi

    CLEAN=$(sed -r 's/\x1b\[[0-9;]*m//g' "$XUI_INSTALL_LOG")
    if printf '%s\n' "$CLEAN" | grep -Eqi \
        'Failed to issue (IP )?certificate|too many certificates|too many failed authorizations|rate.?limited|rateLimit|urn:ietf:params:acme:error|Error creating new order|Register account Error'; then
        warn "Обнаружена ошибка при выпуске сертификата официальным установщиком."
        warn "Скорее всего превышен лимит выпуска Let's Encrypt (или закрыт порт 80)."
        offer_alt_cert
    else
        ok "Сертификат выпущен без ошибок (или выпуск не запрашивался)."
    fi
}

# -----------------------------------------------------------------------------
#  Резервная копия сертификатов в ~/cer-backup
# -----------------------------------------------------------------------------
backup_certs() {
    local SRC="/root/cert"
    local DST="${HOME}/cer-backup"

    if [ -d "$SRC" ] && [ -n "$(ls -A "$SRC" 2>/dev/null)" ]; then
        mkdir -p "$DST"
        cp -r "$SRC/." "$DST/"
        ok "Сертификаты скопированы в ${DST}"
    else
        warn "Каталог сертификатов (${SRC}) пуст или отсутствует — копировать нечего."
    fi
}

# -----------------------------------------------------------------------------
#  Загрузка реальной конфигурации панели (порт, путь, токен, учётные данные)
# -----------------------------------------------------------------------------
load_panel_config() {
    local XUI_BIN="/usr/local/x-ui/x-ui"
    local CLEAN
    local V

    log "Определяем конфигурацию панели 3x-ui..."

    # Очищаем лог установщика от ANSI-кодов (для парсинга текстовых полей)
    CLEAN=""
    if [ -s "$XUI_INSTALL_LOG" ]; then
        CLEAN=$(sed -r 's/\x1b\[[0-9;]*m//g' "$XUI_INSTALL_LOG")
    fi

    # Порт панели: из настроек x-ui, fallback — из лога установщика
    V=""
    if [ -x "$XUI_BIN" ]; then
        V=$("$XUI_BIN" setting -show true 2>/dev/null | grep -Eo 'port: [0-9]+' | awk '{print $2}' | head -1)
    fi
    if [ -z "$V" ] && [ -n "$CLEAN" ]; then
        V=$(printf '%s\n' "$CLEAN" | grep -Eo 'Port:[[:space:]]*[0-9]+' | grep -Eo '[0-9]+' | head -1)
    fi
    if [ -n "$V" ] && [[ "$V" =~ ^[0-9]+$ ]] && [ "$V" -ge 1 ] && [ "$V" -le 65535 ]; then
        PANEL_PORT="$V"
    else
        err "Не удалось определить порт панели 3x-ui."
        err "Укажите порт вручную: x-ui setting -port <порт>."
        exit 1
    fi
    ok "Порт панели 3x-ui: ${PANEL_PORT}"

    # Базовый путь панели
    V=""
    if [ -x "$XUI_BIN" ]; then
        V=$("$XUI_BIN" setting -show true 2>/dev/null | grep -Eo 'webBasePath: .+' | awk '{print $2}' | head -1)
    fi
    if [ -z "$V" ] && [ -n "$CLEAN" ]; then
        V=$(printf '%s\n' "$CLEAN" | grep -Eo 'WebBasePath:[[:space:]]*[^[:space:]]+' | awk '{print $2}' | head -1)
    fi
    PANEL_PATH="${V:-}"

    # API-токен
    V=""
    if [ -x "$XUI_BIN" ]; then
        V=$("$XUI_BIN" setting -getApiToken true 2>/dev/null | grep -Eo 'apiToken: .+' | awk '{print $2}' | head -1)
    fi
    if [ -z "$V" ] && [ -n "$CLEAN" ]; then
        V=$(printf '%s\n' "$CLEAN" | grep -Eo 'API Token:[[:space:]]*[^[:space:]]+' | sed -E 's/^API Token:[[:space:]]*//' | head -1)
    fi
    PANEL_TOKEN="${V:-}"

    # Имя пользователя и пароль — только из лога установщика
    if [ -n "$CLEAN" ]; then
        PANEL_USERNAME=$(printf '%s\n' "$CLEAN" | grep -Eo 'Username:[[:space:]]*[^[:space:]]+' | awk '{print $2}' | head -1)
        PANEL_PASSWORD=$(printf '%s\n' "$CLEAN" | grep -Eo 'Password:[[:space:]]*[^[:space:]]+' | awk '{print $2}' | head -1)
    fi

    if [ -z "$PANEL_USERNAME" ] || [ -z "$PANEL_PASSWORD" ]; then
        warn "Имя пользователя/пароль не найдены в логе установщика (${XUI_INSTALL_LOG})."
        warn "Сменить учётные данные: x-ui setting -username <логин> -password <пароль>."
    fi
}

# -----------------------------------------------------------------------------
#  Загрузка реальной конфигурации панели (порт, путь, токен, учётные данные)
# -----------------------------------------------------------------------------
PANEL_USERNAME=""                      # имя пользователя панели (из лога установщика)
PANEL_PASSWORD=""                      # пароль панели (из лога установщика)
PANEL_PATH=""                          # базовый путь панели (webBasePath)
PANEL_TOKEN=""                         # API-токен панели

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
#  Поиск сертификата панели (fullchain.pem + privkey.pem) в /root/cert
# -----------------------------------------------------------------------------
detect_panel_cert() {
    PANEL_CERT=""
    PANEL_KEY=""
    PANEL_HOST=""
    local d san dns

    # Каталоги сертификатов официального установщика 3x-ui:
    #   /root/cert/ip        — сертификат по IP (Let's Encrypt shortlived / self-signed);
    #   /root/cert/<домен>   — сертификат для домена (Let's Encrypt).
    for d in /root/cert/ip /root/cert/*; do
        [ -d "$d" ] || continue
        if [ -f "$d/fullchain.pem" ] && [ -f "$d/privkey.pem" ]; then
            PANEL_CERT="$d/fullchain.pem"
            PANEL_KEY="$d/privkey.pem"
            ok "Сертификат панели найден: ${PANEL_CERT}"

            # Определяем, на что выпущен сертификат: домен или IP.
            # Приоритет — SAN сертификата (надёжнее имени каталога).
            san="$(openssl x509 -in "$PANEL_CERT" -noout -ext subjectAltName 2>/dev/null)"
            dns="$(printf '%s\n' "$san" | sed -n 's/.*[Dd][Nn][Ss]:\([^ ,]*\).*/\1/p' | head -n1)"
            if [ -n "$dns" ]; then
                PANEL_HOST="$dns"
            elif [ "$(basename "$d")" != "ip" ]; then
                PANEL_HOST="$(basename "$d")"
            fi
            if [ -n "$PANEL_HOST" ]; then
                ok "Сертификат выпущен на домен: ${PANEL_HOST}"
            fi
            return 0
        fi
    done
    warn "Сертификат панели не найден в /root/cert."
    warn "Без него панель останется без TLS, а TLS на прокси будет недоступен."
}

# -----------------------------------------------------------------------------
#  Обеспечение наличия сертификата панели
#
#  Если сертификат уже есть в /root/cert (домен или IP) — новый не выпускаем,
#  а просто прописываем существующий в панель. Если сертификата нет —
#  проверяем лог установщика на ошибку выпуска (и при ошибке предлагаем
#  выпустить альтернативный сертификат).
# -----------------------------------------------------------------------------
ensure_panel_cert() {
    detect_panel_cert
    if [ -n "$PANEL_CERT" ]; then
        detect_panel_proto
        if [ "$PANEL_PROTO" = "http" ]; then
            apply_cert_to_panel "$PANEL_CERT" "$PANEL_KEY"
        else
            ok "Сертификат уже применён к панели."
        fi
    else
        check_cert_issue
    fi
}

# -----------------------------------------------------------------------------
#  Интерактивный выбор прокси-сервера
# -----------------------------------------------------------------------------
# Проверка, что порт прокси не занят (например, xray-inbound на 443)
check_proxy_port() {
    if command -v ss >/dev/null 2>&1 && ss -ltnH "sport = :${PROXY_PORT}" 2>/dev/null | grep -q .; then
        warn "Порт ${PROXY_PORT} уже занят (возможно, xray-inbound на 443)."
        read -rp "Указать другой порт (Enter — оставить ${PROXY_PORT}): " P
        if [ -n "$P" ]; then
            PROXY_PORT="$P"
        fi
    fi
}

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
        read -rp "Порт прокси (по умолчанию ${PROXY_PORT}): " P
        PROXY_PORT="${P:-${PROXY_PORT}}"
        check_proxy_port
    fi

    ok "Выбран прокси: ${PROXY_NAME}"
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
    local LISTEN_DIRECTIVES="    listen ${PROXY_PORT};"
    if [ "$PANEL_PROTO" = "https" ]; then
        SSL_UPSTREAM="        proxy_ssl_verify off;
        proxy_ssl_server_name off;"
        # TLS на прокси: внешний доступ по https, чтобы браузер сохранял
        # Secure-cookie панели (иначе вход даёт 403 из-за CSRF)
        if [ -n "$PANEL_CERT" ] && [ -n "$PANEL_KEY" ]; then
            PROXY_SCHEME="https"
            LISTEN_DIRECTIVES="    listen ${PROXY_PORT} ssl;
    ssl_certificate     ${PANEL_CERT};
    ssl_certificate_key ${PANEL_KEY};"
        else
            warn "Панель на HTTPS, сертификат не найден — прокси работает без TLS, вход в панель может давать 403."
        fi
    fi

    cat > /etc/nginx/conf.d/x-ui.conf <<EOF
server {
${LISTEN_DIRECTIVES}
    server_name _;

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
    ok "nginx настроен: $(build_url "$PROXY_SCHEME" "${PANEL_HOST:-$IP}" "$PROXY_PORT")"
}

# -----------------------------------------------------------------------------
#  Подготовка сертификатов для caddy
#
#  caddy запускается от пользователя caddy и не может читать каталог /root
#  (права 700), поэтому сертификаты из /root/cert копируются в /etc/caddy/certs
#  с владельцем caddy:caddy.
# -----------------------------------------------------------------------------
prepare_caddy_certs() {
    if [ -z "$PANEL_CERT" ] || [ -z "$PANEL_KEY" ]; then
        return
    fi
    local CERTS_DIR="/etc/caddy/certs"
    mkdir -p "$CERTS_DIR"
    cp "$PANEL_CERT" "$CERTS_DIR/fullchain.pem"
    cp "$PANEL_KEY" "$CERTS_DIR/privkey.pem"
    chown -R caddy:caddy "$CERTS_DIR"
    chmod 644 "$CERTS_DIR/fullchain.pem"
    chmod 600 "$CERTS_DIR/privkey.pem"
    PANEL_CERT="$CERTS_DIR/fullchain.pem"
    PANEL_KEY="$CERTS_DIR/privkey.pem"
    ok "Сертификаты скопированы для caddy: ${CERTS_DIR}/"
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
        # TLS на прокси, если найден сертификат панели (Secure-cookie при https)
        if [ -n "$PANEL_CERT" ] && [ -n "$PANEL_KEY" ]; then
            PROXY_SCHEME="https"
            prepare_caddy_certs
            cat > /etc/caddy/Caddyfile <<EOF
:${PROXY_PORT} {
    tls ${PANEL_CERT} ${PANEL_KEY}
    reverse_proxy https://127.0.0.1:${PANEL_PORT} {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
EOF
        else
            warn "Панель на HTTPS, сертификат не найден — прокси работает без TLS, вход в панель может давать 403."
            cat > /etc/caddy/Caddyfile <<EOF
:${PROXY_PORT} {
    reverse_proxy https://127.0.0.1:${PANEL_PORT} {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
EOF
        fi
    else
        cat > /etc/caddy/Caddyfile <<EOF
:${PROXY_PORT} {
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
    ok "caddy настроен: $(build_url "$PROXY_SCHEME" "${PANEL_HOST:-$IP}" "$PROXY_PORT")"
}

# -----------------------------------------------------------------------------
#  Настройка firewall (ufw / firewalld)
# -----------------------------------------------------------------------------
setup_firewall() {
    # Без прокси наружу открыт порт панели.
    # С прокси наружу открыт ТОЛЬКО порт прокси, а порт панели закрывается —
    # доступ к панели возможен только через прокси.
    local PORTS=""
    local CLOSE=""
    if [ "$PROXY" = "none" ]; then
        PORTS="${PANEL_PORT}"
    else
        PORTS="${PROXY_PORT}"
        CLOSE="${PANEL_PORT}"
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        for p in $PORTS; do
            ufw allow "${p}"/tcp >/dev/null
        done
        # закрываем порт панели, если правило осталось от прошлой установки
        if [ -n "$CLOSE" ]; then
            # ufw может хранить правило и с протоколом, и без него
            ufw delete allow "${CLOSE}"/tcp >/dev/null 2>&1 || true
            ufw delete allow "${CLOSE}" >/dev/null 2>&1 || true
        fi
        ok "ufw: открыт порт ${PORTS}/tcp; прямой доступ к панели (${CLOSE:-—}/tcp) закрыт."
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        for p in $PORTS; do
            firewall-cmd --permanent --add-port="${p}"/tcp >/dev/null
        done
        if [ -n "$CLOSE" ]; then
            firewall-cmd --permanent --remove-port="${CLOSE}"/tcp >/dev/null 2>&1 || true
        fi
        firewall-cmd --reload >/dev/null
        ok "firewalld: открыт порт ${PORTS}/tcp; прямой доступ к панели (${CLOSE:-—}/tcp) закрыт."
    else
        warn "Активный firewall (ufw/firewalld) не обнаружен."
        warn "При необходимости откройте вручную порт: ${PORTS}/tcp."
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
#  Формирование внешнего URL
#
#  Порт опускается, если он стандартный для схемы (https+443, http+80) —
#  браузер подставит его сам.
# -----------------------------------------------------------------------------
build_url() {
    local SCHEME="$1"
    local HOST="$2"
    local PORT="$3"
    local PATH_TAIL="${4:-}"
    local URL="${SCHEME}://${HOST}"
    PATH_TAIL="${PATH_TAIL#/}"

    if ! { [ "$SCHEME" = "https" ] && [ "$PORT" = "443" ]; } && \
       ! { [ "$SCHEME" = "http" ] && [ "$PORT" = "80" ]; }; then
        URL="${URL}:${PORT}"
    fi

    if [ -n "$PATH_TAIL" ]; then
        URL="${URL}/${PATH_TAIL}"
    fi
    echo "$URL"
}

# -----------------------------------------------------------------------------
#  Итоговая сводка
# -----------------------------------------------------------------------------
print_summary() {
    # Нормализуем путь: убираем ведущий слэш, чтобы URL был http://IP:PORT/path
    local PANEL_PATH_NORM="${PANEL_PATH#/}"
    # Внешний адрес: домен из сертификата панели (если сертификат на домен), иначе IP
    local HOST="${PANEL_HOST:-$IP}"
    # Рабочий адрес доступа: через прокси или напрямую к панели
    local ACCESS_URL
    if [ "$PROXY" = "none" ]; then
        ACCESS_URL="$(build_url "$PANEL_PROTO" "$HOST" "$PANEL_PORT" "$PANEL_PATH_NORM")"
    else
        ACCESS_URL="$(build_url "$PROXY_SCHEME" "$HOST" "$PROXY_PORT" "$PANEL_PATH_NORM")"
    fi

    echo
    echo "═══════════════════════════════════════════════"
    echo "   Установка завершена"
    echo "═══════════════════════════════════════════════"
    if [ "$PROXY" = "none" ]; then
        echo "   Прокси не выбран — панель работает напрямую."
    else
        echo "   Прокси:      ${PROXY}"
        echo "   Панель:      $(build_url "$PROXY_SCHEME" "$HOST" "$PROXY_PORT" "$PANEL_PATH_NORM")"
        echo "   Внутренний:  ${PANEL_PROTO}://127.0.0.1:${PANEL_PORT}/${PANEL_PATH_NORM}"
        echo "   Прямой доступ к панели закрыт — только порт прокси."
    fi
    echo
    echo "   Управление панелью из терминала:  x-ui"
    echo "   Статус службы:                    systemctl status x-ui"
    if [ "$PROXY" = "nginx" ]; then
        echo "   Статус nginx:                     systemctl status nginx"
    elif [ "$PROXY" = "caddy" ]; then
        echo "   Статус caddy:                     systemctl status caddy"
    fi
    echo "═══════════════════════════════════════════════"
    echo
    echo "═══════════════════════════════════════════════"
    echo "   Данные панели 3x-ui (из вывода установщика):"
    echo "═══════════════════════════════════════════════"
    echo "   Username:    ${PANEL_USERNAME:-не определено}"
    echo "   Password:    ${PANEL_PASSWORD:-не определено}"
    echo "   Port:        ${PANEL_PORT}"
    echo "   WebBasePath: ${PANEL_PATH_NORM:-/}"
    echo "   Access URL:  ${ACCESS_URL}"
    echo "   API Token:   ${PANEL_TOKEN:-не определено}"
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
    echo "═══════════════════════════════════════════════"

    detect_os

    log "Проверяем зависимости..."
    if ! command -v curl >/dev/null 2>&1; then install_pkg curl; fi

    detect_ip
    install_3xui
    load_panel_config
    ensure_panel_cert
    choose_proxy

    # Настройка в зависимости от выбранного прокси
    case "$PROXY" in
        nginx)
            detect_panel_proto
            setup_nginx
            ;;
        caddy)
            detect_panel_proto
            setup_caddy
            ;;
        none)
            detect_panel_proto
            ok "Прокси не выбран — панель работает напрямую."
            ;;
    esac

    setup_firewall
    backup_certs
    setup_selinux
    print_summary
}

main "$@"
