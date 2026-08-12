#!/usr/bin/env bash
# =============================================================================
# inbound-xray.sh — настройка Xray-инбаундов поверх установленной панели 3x-ui.
#
# Возможности:
#   * создание inbound для всех поддерживаемых панелью протоколов/транспортов;
#   * создание клиентов (Xray-протоколы) и учётных записей (http/mixed);
#   * генерация share-ссылок (vless://, vmess://, trojan://, ss://, hy2://,
#     wireguard://, tg://proxy);
#   * опциональная интеграция с nginx (location для WS/gRPC/XHTTP/HTTPUpgrade,
#     stream-SNI для REALITY, TCP-passthrough для TLS-инбаундов) с бэкапом и
#     откатом при ошибке конфигурации;
#   * заглушка-сайт на корневом адресе (панель скрывается на своём пути);
#   * подписка пользователя (/sub/) через внешний адрес с корректными ссылками
#     (записи в таблице hosts для инбаундов за прокси);
#   * открытие прямых (непроксируемых) портов инбаундов в firewall;
#   * автопроверка зависимостей (sqlite3, openssl, curl; опционально nginx):
#     при отсутствии — вопрос «установить или выйти».
#
# Запись в конфигурацию панели выполняется напрямую в базу данных
# (sqlite3) с последующим перезапуском x-ui — без REST API.
#
# *** ВАЖНО: поддержка панели 3x-ui v3.6+ (формат базы данных). ***
# На более старых версиях панели схема таблиц отличается — не работает.
#
# Использование:  bash inbound-xray.sh
# Переменные окружения:
#   XUI_DB  — путь к базе панели (по умолчанию /etc/x-ui/x-ui.db)
#   XUI_XRAY — путь к бинарнику xray (по умолчанию /usr/local/x-ui/bin/xray)
# =============================================================================

set -euo pipefail

# --- Основные пути и константы -------------------------------------------------
XUI_DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
XUI_XRAY="${XUI_XRAY:-/usr/local/x-ui/bin/xray}"
LOG_FILE="${XUI_LOG:-/var/log/setup-xray.log}"
SCRIPT_VERSION="2.0.1"
XUI_BIN="/usr/local/x-ui/x-ui"
PANEL_INSTALL_LOG="/var/log/3x-ui-install.log"   # лог официального установщика
NGINX_SNIPPET="/etc/nginx/snippets/includes.conf"
NGINX_STREAM="/etc/nginx/stream-enabled/stream.conf"
NGINX_CONF="/etc/nginx/conf.d/x-ui.conf"
NGINX_MAIN="/etc/nginx/nginx.conf"
# 1 = всё внешнее трафик (http + stream) уже переведено на единый 443
STREAM_443_MASTER=""
# Внутренний https-порт nginx (панель + WS/gRPC), внешний слушает stream-мастер
PANEL_SSL_PORT="8443"
# Внешний порт stream-мастера
STREAM_MASTER_PORT="443"
LANDING_DIR="/var/www/landing"
LANDING_INDEX="$LANDING_DIR/index.html"

# Переменные окружения панели (заполняются в load_panel_env)
PANEL_HOST=""
SERVER_IP=""
PANEL_CERT=""
PANEL_CERT_KEY=""
PANEL_CERT_DIR=""
PANEL_PORT=""
PANEL_PATH=""
PANEL_PROTO="http"
PANEL_TOKEN=""
PANEL_USERNAME=""
PANEL_PASSWORD=""
SUB_PORT=""
SUB_PATH="/sub/"
SUB_ENABLE="false"

# Внешний адрес/порт прокси (nginx) — заполняются при определении окружения
PROXY_SCHEME="http"
PROXY_PORT=""

# Выбранный протокол/транспорт/параметры
PROTOCOL=""
TRANSPORT=""
SECURITY=""
PORT=""
LISTEN=""
REMARK=""
USE_NGINX=""
CHANNEL_PROTO="tcp"
ENABLE_LANDING=""

# REALITY-параметры (генерируются один раз и переиспользуются)
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
REALITY_SHORT_ID=""
REALITY_SNI=""
REALITY_TARGET=""
REALITY_SPIDERX="/"
REALITY_SETTINGS_JSON=""

# Параметры инбаунда с уникальным SNI (TCP+TLS) и переиспользуемого клиента
CHANNEL_SNI=""
CHANNEL_CERT_DIR=""
REUSE_CLIENT=""
EXISTING_CLIENT_ID=""

# --- Цвета и вывод ------------------------------------------------------------
if [[ -t 1 ]]; then
    C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'
    C_CYAN=$'\033[0;36m'; C_RESET=$'\033[0m'
else
    C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""; C_RESET=""
fi

log()  { printf '%s\n' "$*" | tee -a "$LOG_FILE"; }
info() { printf '%s\n' "$*" | tee -a "$LOG_FILE"; }
ok()   { printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '%s[ WARN ]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" | tee -a "$LOG_FILE"; }
fail() { printf '%s[ FAIL ]%s %s\n' "$C_RED" "$C_RESET" "$*" | tee -a "$LOG_FILE"; }
die()  { printf '%s[ ERROR ]%s %s\n' "$C_RED" "$C_RESET" "$*" | tee -a "$LOG_FILE" >&2; exit 1; }
banner() { printf '%s%s%s\n' "$C_CYAN" "$*" "$C_RESET"; }

# --- Утилиты ввода -------------------------------------------------------------

# ask "подсказка" "значение по умолчанию" — читает строку, при пустом вводе берёт дефолт.
ask() {
    local prompt="$1" def="${2:-}" answer=""
    if [[ -n "$def" ]]; then
        read -r -p "$prompt [$def]: " answer || answer="$def"
        printf -v "$3" '%s' "${answer:-$def}"
    else
        read -r -p "$prompt: " answer || answer=""
        printf -v "$3" '%s' "$answer"
    fi
}

# confirm "вопрос" [y|n] — возвращает 0 при "да", 1 при "нет"
confirm() {
    local def="${2:-n}" answer=""
    if [[ "$def" == "y" ]]; then
        read -r -p "$1 [Y/n]: " answer || answer="y"
        [[ -z "$answer" || "$answer" =~ ^[YyДд] ]]
    else
        read -r -p "$1 [y/N]: " answer || answer="n"
        [[ "$answer" =~ ^[YyДд] ]]
    fi
}

# --- Инициализация лога ---------------------------------------------------------
setup_log() {
    [[ -d /var/log ]] && : > "$LOG_FILE" 2>/dev/null || LOG_FILE="${TMPDIR:-/tmp}/setup-xray.log"
    {
        echo "===== $(date '+%Y-%m-%d %H:%M:%S') inbound-xray.sh v${SCRIPT_VERSION} ====="
        echo "Пользователь: $(id -un 2>/dev/null || echo unknown)"
        echo "БД панели: $XUI_DB"
        echo "Xray: $XUI_XRAY"
    } > "$LOG_FILE" 2>/dev/null || true
}

# --- Проверка окружения ---------------------------------------------------------
require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Скрипт нужно запускать от root (sudo)."
}

# detect_os — определяет пакетный менеджер системы (apt-get/dnf/yum).
detect_os() {
    PKG_MANAGER=""
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "$ID" in
            ubuntu|debian|linuxmint)                PKG_MANAGER="apt-get" ;;
            centos|rocky|almalinux|rhel|fedora|ol)
                PKG_MANAGER="dnf"
                if [[ "$ID" == "centos" && "${VERSION_ID%%.*}" -lt 8 ]]; then
                    PKG_MANAGER="yum"
                fi
                ;;
        esac
    fi
    [[ -n "$PKG_MANAGER" ]] || die "Не удалось определить менеджер пакетов — установка невозможна. Установите зависимости вручную и повторите."
    log "Менеджер пакетов: $PKG_MANAGER"
}

# install_pkg <пакеты...> — установка через системный менеджер пакетов.
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

# nginx_pkg — пакет nginx с поддержкой stream. На Debian/Ubuntu это nginx-full
# (включает динамический модуль stream и подключает его автоматически через
# /etc/nginx/modules-enabled/), на RHEL-семействе — обычный nginx.
nginx_pkg() {
    [[ "$PKG_MANAGER" == "apt-get" ]] && echo "nginx-full" || echo "nginx"
}

# nginx_install_stream_module — если nginx не распознаёт директиву stream
# (Ubuntu/Debian ставят nginx-core без stream), доустанавливает подходящий
# пакет и повторяет проверку.
nginx_install_stream_module() {
    command -v nginx >/dev/null 2>&1 || return 1
    if nginx_test_ok; then
        return 0
    fi
    [[ "$NGINX_TEST_ERR" != *'unknown directive "stream"'* ]] && return 0
    warn "nginx не поддерживает stream-контекст — устанавливаю $(nginx_pkg)..."
    if ! install_pkg "$(nginx_pkg)"; then
        warn "Не удалось установить $(nginx_pkg). Директиву stream нужно подключить вручную."
        return 1
    fi
    command -v nginx >/dev/null 2>&1 || { warn "nginx не установился после замены пакета."; return 1; }
    nginx_test_ok || { warn "nginx -t всё ещё не проходит:"; warn "$NGINX_TEST_ERR"; return 1; }
    return 0
}

# ensure_tools <пакеты...> — проверяет наличие программ; при отсутствии
# спрашивает «установить или выйти» и при согласии устанавливает.
ensure_tools() {
    local missing=() t
    for t in "$@"; do
        command -v "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    ((${#missing[@]} > 0)) || return 0
    if ! confirm "Отсутствуют программы: ${missing[*]}. Установить их?" "y"; then
        die "Отменено пользователем. Установите отсутствующие программы вручную и повторите."
    fi
    info "Устанавливаем: ${missing[*]}..."
    install_pkg "${missing[@]}"
    local still=()
    for t in "${missing[@]}"; do
        command -v "$t" >/dev/null 2>&1 || still+=("$t")
    done
    if ((${#still[@]} > 0)); then
        die "Не удалось установить: ${still[*]}. Установите их вручную и повторите."
    fi
    ok "Установлено: ${missing[*]}"
}

require_tools() {
    ensure_tools sqlite3 openssl curl
}

require_panel() {
    [[ -f "$XUI_DB" ]] || die "База панели не найдена: $XUI_DB. Сначала установите 3x-ui (install.sh)."
    sqlite3 "$XUI_DB" "SELECT 1;" >/dev/null 2>&1 || die "Не удалось открыть базу панели: $XUI_DB."
    command -v systemctl >/dev/null 2>&1 && systemctl is-active x-ui >/dev/null 2>&1 \
        || warn "Сервис x-ui не активен. Настройка продолжится, но для применения нужен запуск x-ui."
}

# --- Определение окружения панели -------------------------------------------------

# detect_panel_cert — ищет сертификат панели. Источники по приоритету:
#  1. /root/cert/ip            — IP-сертификат (панель по IP, PANEL_HOST пустой);
#  2. /root/cert/<домен>       — доменные каталоги;
#  3. /etc/letsencrypt/live/*  — сертификаты Let's Encrypt (certbot).
# Устанавливает PANEL_CERT, PANEL_CERT_KEY, PANEL_CERT_DIR и PANEL_HOST (домен из SAN).
detect_panel_cert() {
    PANEL_CERT=""; PANEL_CERT_KEY=""; PANEL_CERT_DIR=""; PANEL_HOST=""
    local base="/root/cert"
    local dirs=()
    [[ -d "$base" ]] && dirs+=("$base")
    [[ -d /etc/letsencrypt/live ]] && dirs+=(/etc/letsencrypt/live)
    ((${#dirs[@]} == 0)) && return 0

    # Приоритет: каталог по IP, затем доменные каталоги
    local ip_cert="$base/ip"
    if [[ -f "$ip_cert/fullchain.pem" && -f "$ip_cert/privkey.pem" ]]; then
        PANEL_CERT="$ip_cert/fullchain.pem"
        PANEL_CERT_KEY="$ip_cert/privkey.pem"
        PANEL_CERT_DIR="$ip_cert"
        return 0
    fi

    # Приоритет: домен панели из nginx-конфига (server_name ssl-сервера панели).
    # На него указывает A-запись, он уже терминирует TLS — это и есть панель.
    local pconf="${NGINX_CONF:-/etc/nginx/conf.d/x-ui.conf}"
    if [[ -f "$pconf" ]]; then
        local sname=""
        sname="$(sed -n 's/.*server_name[[:space:]]*\([^;]*\);.*/\1/p' "$pconf" | tr -d ' ' | head -1 || true)"
        local sname_first="${sname%% *}"
        if [[ -n "$sname_first" && -f "/etc/letsencrypt/live/${sname_first}/fullchain.pem" ]]; then
            PANEL_CERT="/etc/letsencrypt/live/${sname_first}/fullchain.pem"
            PANEL_CERT_KEY="/etc/letsencrypt/live/${sname_first}/privkey.pem"
            PANEL_CERT_DIR="/etc/letsencrypt/live/${sname_first}"
            PANEL_HOST="$sname_first"
            return 0
        fi
    fi

    local d crt key
    for d in "${dirs[@]}"; do
        local sub
        for sub in "$d"/*/; do
            [[ -d "$sub" ]] || continue
            crt="$sub/fullchain.pem"; key="$sub/privkey.pem"
            [[ -f "$crt" && -f "$key" ]] || continue
            PANEL_CERT="$crt"; PANEL_CERT_KEY="$key"; PANEL_CERT_DIR="${sub%/}"
            break 2
        done
    done
    [[ -n "$PANEL_CERT" ]] || return 0

    # Домен из SAN сертификата (fallback — имя каталога)
    local san=""
    san=$(openssl x509 -in "$PANEL_CERT" -noout -ext subjectAltName 2>/dev/null || true)
    if [[ "$san" =~ DNS:([^,]+) ]]; then
        PANEL_HOST="${BASH_REMATCH[1]}"
    else
        PANEL_HOST="$(basename "$PANEL_CERT_DIR")"
        # Если каталог называется "ip" — это IP-сертификат, домена нет
        [[ "$PANEL_HOST" == "ip" ]] && PANEL_HOST=""
    fi
}

# detect_server_ip — внешний IP-адрес сервера.
detect_server_ip() {
    SERVER_IP=""
    SERVER_IP=$(curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null) && [[ -n "$SERVER_IP" ]] && return 0
    SERVER_IP=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null) && [[ -n "$SERVER_IP" ]] && return 0
    # fallback: IP из маршрута по умолчанию
    local ip=""
    ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || true
    [[ -n "$ip" ]] && SERVER_IP="$ip"
}

# external_addr — внешний адрес для ссылок: домен из сертификата панели или IP.
external_addr() {
    if [[ -n "$PANEL_HOST" ]]; then printf '%s' "$PANEL_HOST"; else printf '%s' "$SERVER_IP"; fi
}

load_panel_env() {
    require_panel
    detect_panel_cert
    detect_server_ip
    info "Внешний адрес: $(external_addr)"
    [[ -n "$PANEL_CERT" ]] && info "Сертификат панели: $PANEL_CERT"

    # Порт панели и webBasePath — из x-ui setting -show true
    local show=""
    if [[ -x "$XUI_BIN" ]]; then
        show="$("$XUI_BIN" setting -show true 2>/dev/null || true)"
        if [[ "$show" =~ Panel[[:space:]]is[[:space:]]secure[[:space:]]with[[:space:]]SSL ]]; then
            PANEL_PROTO="https"
        fi
        if [[ "$show" =~ port:[[:space:]]*([0-9]+) ]]; then
            PANEL_PORT="${BASH_REMATCH[1]}"
        fi
        if [[ "$show" =~ webBasePath:[[:space:]]*(.*) ]]; then
            PANEL_PATH="${BASH_REMATCH[1]}"
            [[ "$PANEL_PATH" == "get webBasePath failed"* ]] && PANEL_PATH=""
        fi
        PANEL_TOKEN="$("$XUI_BIN" setting -getApiToken true 2>/dev/null | grep -Eo 'apiToken: .+' | awk '{print $2}' | head -1 || true)"
    fi
    if [[ -z "$PANEL_PORT" || "$PANEL_PORT" == "get current port failed"* ]]; then
        PANEL_PORT="$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webPort' LIMIT 1;" 2>/dev/null || true)"
    fi
    [[ -n "$PANEL_PORT" ]] || die "Не удалось определить порт панели 3x-ui."

    # Учётные данные — из лога официального установщика (fallback: не критично)
    if [[ -s "$PANEL_INSTALL_LOG" ]]; then
        local clean=""
        clean="$(sed -r 's/\x1b\[[0-9;]*m//g' "$PANEL_INSTALL_LOG" 2>/dev/null || true)"
        if [[ -z "$PANEL_USERNAME" ]]; then
            PANEL_USERNAME="$(printf '%s\n' "$clean" | grep -Eo 'Username:[[:space:]]*[^[:space:]]+' | awk '{print $2}' | head -1)"
        fi
        if [[ -z "$PANEL_PASSWORD" ]]; then
            PANEL_PASSWORD="$(printf '%s\n' "$clean" | grep -Eo 'Password:[[:space:]]*[^[:space:]]+' | awk '{print $2}' | head -1)"
        fi
    fi

    # Подписка: суб-порт, путь и включение из БД панели
    SUB_PORT="$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPort' LIMIT 1;" 2>/dev/null || true)"
    [[ -z "$SUB_PORT" ]] && SUB_PORT="2096"
    SUB_PATH="$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subPath' LIMIT 1;" 2>/dev/null || true)"
    [[ -z "$SUB_PATH" ]] && SUB_PATH="/sub/"
    local sub_enable=""
    sub_enable="$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='subEnable' LIMIT 1;" 2>/dev/null || true)"
    [[ "$sub_enable" == "true" ]] && SUB_ENABLE="true"

    # Внешний порт nginx: из listen в конфиге панели
    detect_nginx_conf
    if is_stream_443_master; then
        STREAM_443_MASTER=1
        PROXY_PORT="${STREAM_MASTER_PORT:-443}"
        PROXY_SCHEME="https"
    elif [[ -n "$NGINX_CONF" && -f "$NGINX_CONF" ]]; then
        PROXY_PORT="$(grep -Eo 'listen[[:space:]]+[0-9]+' "$NGINX_CONF" | awk '{print $2}' | head -1)"
        if grep -Eqs 'listen[[:space:]]+[0-9]+[[:space:]]+ssl' "$NGINX_CONF" \
            || grep -Eqs 'listen[[:space:]]+[0-9]+[[:space:]]+[^;]*ssl' "$NGINX_CONF"; then
            PROXY_SCHEME="https"
        fi
    fi

    info "Панель: ${PANEL_PROTO}://127.0.0.1:${PANEL_PORT}${PANEL_PATH:-/} (webBasePath: ${PANEL_PATH:-/})"
}

# detect_nginx_conf — определяет файл nginx-конфига панели по proxy_pass на её порт.
detect_nginx_conf() {
    NGINX_CONF=""
    [[ -f /etc/nginx/conf.d/x-ui.conf ]] && { NGINX_CONF="/etc/nginx/conf.d/x-ui.conf"; return 0; }
    if [[ -n "$PANEL_PORT" ]]; then
        local f=""
        for f in /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/* /etc/nginx/conf.d/*.include; do
            [[ -f "$f" ]] || continue
            if grep -Eqs "proxy_pass[[:space:]]+[a-z]*://127\.0\.0\.1:${PANEL_PORT}" "$f"; then
                NGINX_CONF="$f"
                return 0
            fi
        done
    fi
    return 0
}

# --- Генераторы случайных значений -------------------------------------------------

gen_uuid() {
    local u=""
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        u="$(cat /proc/sys/kernel/random/uuid)"
    else
        u="$(openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')"
    fi
    printf '%s' "$u"
}

gen_hex() { openssl rand -hex "${1:-4}"; }

# gen_panel_path — случайный скрытый путь панели: 18 символов из [a-z0-9]
# (строчные буквы + цифры). Используется как webBasePath (вместо /panel/).
gen_panel_path() {
    local p=""
    p="$(LC_ALL=C tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 18)" \
        && [[ -n "$p" ]] || p="$(openssl rand -hex 18 2>/dev/null | cut -c1-18)"
    [[ -n "$p" ]] || p="panel"
    printf '%s' "$p"
}

gen_password() {
    local len="${1:-16}"
    openssl rand -base64 48 2>/dev/null | tr -d '[:space:]' | tr '+/' '-_' | cut -c1-"$len"
}

# x25519_keypair — пара ключей REALITY/WireGuard.
# Устанавливает X25519_PRIV, X25519_PUB.
# ВАЖНО: вывод `xray x25519` в современных версиях (26.7.x) —
#   "PrivateKey: <base64url>" и "Password (PublicKey): <base64url>"
# (кодировка base64.RawURLEncoding, БЕЗ padding '=' и с алфавитом '-_').
# Старые версии печатали "Private key:" / "Public key:". Regex по всей строке
# не матчил современный формат → срабатывал fallback openssl со стандартным
# base64 ('='), который Xray отвергает как invalid privateKey. Поэтому парсим
# построчно, а fallback конвертируем в base64url.
x25519_keypair() {
    local out="" priv="" pub="" line="" k=""
    if [[ -x "$XUI_XRAY" ]]; then
        out="$("$XUI_XRAY" x25519 2>/dev/null)" || out=""
        if [[ -n "$out" ]]; then
            while IFS= read -r line; do
                line="${line%$'\r'}"
                case "$line" in
                    PrivateKey:*) k="${line#*:}" ;;
                    "Password (PublicKey):"*) k="${line#*:}" ;;
                    "Private key:"*) k="${line#*:}" ;;
                    "Public key:"*)  k="${line#*:}" ;;
                    "Private:"*)     k="${line#*:}" ;;
                    "Public:"*)      k="${line#*:}" ;;
                    *) continue ;;
                esac
                # трим пробелов
                k="${k#"${k%%[![:space:]]*}"}"
                k="${k%"${k##*[![:space:]]}"}"
                case "$line" in
                    PrivateKey:*|"Private key:"*|"Private:"*) priv="$k" ;;
                    "Password (PublicKey):"*|"Public key:"*|"Public:"*) pub="$k" ;;
                esac
            done <<< "$out"
            # 32 байта в base64url без padding = 43 символа
            if [[ ${#priv} -eq 43 && ${#pub} -eq 43 ]]; then
                X25519_PRIV="$priv"; X25519_PUB="$pub"
                return 0
            fi
        fi
    fi
    # Fallback: openssl X25519 (raw = последние 32 байта DER), затем base64url.
    local tmp
    tmp="$(mktemp -d)"
    if openssl genpkey -algorithm X25519 -out "$tmp/k.pem" >/dev/null 2>&1 \
        && priv="$(openssl pkey -in "$tmp/k.pem" -outform DER 2>/dev/null | tail -c 32 | base64 -w0 | tr -d '=\n\r' | tr '+/' '-_')" \
        && pub="$(openssl pkey -in "$tmp/k.pem" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 -w0 | tr -d '=\n\r' | tr '+/' '-_')" \
        && [[ ${#priv} -eq 43 && ${#pub} -eq 43 ]]; then
        X25519_PRIV="$priv"; X25519_PUB="$pub"
        rm -rf "$tmp"
        return 0
    fi
    rm -rf "$tmp"
    return 1
}

# --- Работа с портами --------------------------------------------------------------

# port_in_use <порт> [udp] — проверяет занят ли порт.
port_in_use() {
    local port="$1" proto="${2:-tcp}"
    if command -v ss >/dev/null 2>&1; then
        if [[ "$proto" == "udp" ]]; then
            ss -lun 2>/dev/null | awk '{print $5}' | grep -Eq "[:.]${port}$"
        else
            ss -ltnH 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}$"
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if [[ "$proto" == "udp" ]]; then
            netstat -lun 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
        else
            netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq ":${port}$"
        fi
    else
        return 1
    fi
}

# next_free_port [proto] [min] [max] — печатает первый свободный порт.
# Учитывает и занятость в БД панели (другой inbound на том же порту).
next_free_port() {
    local proto="${1:-tcp}" min="${2:-10000}" max="${3:-59999}" p
    for p in $(seq "$min" "$max"); do
        if ! port_in_use "$p" "$proto" && ! db_port_in_use "$p"; then
            printf '%s' "$p"
            return 0
        fi
    done
    return 1
}

# pick_port <переменная> <proto> — запрашивает порт, пусто → автоподбор свободного.
pick_port() {
    local var="$1" proto="${2:-tcp}" suggested="" answer=""
    suggested="$(next_free_port "$proto" || echo "")"
    read -r -p "Порт (${proto:-tcp}) [Enter = авто $suggested]: " answer || answer=""
    if [[ -z "$answer" ]]; then
        [[ -n "$suggested" ]] || die "Не найден свободный порт."
        printf -v "$var" '%s' "$suggested"
        info "Выбран свободный порт: $suggested"
        return 0
    fi
    [[ "$answer" =~ ^[0-9]+$ ]] && ((answer >= 1 && answer <= 65535)) || {
        fail "Некорректный порт: $answer (1–65535)."
        pick_port "$var" "$proto"
        return $?
    }
    if port_in_use "$answer" "$proto"; then
        warn "Порт $answer занят."
        if confirm "Продолжить с занятым портом?"; then
            printf -v "$var" '%s' "$answer"
        else
            pick_port "$var" "$proto"
        fi
        return $?
    fi
    if db_port_in_use "$answer"; then
        warn "Порт $answer уже используется другим инбаундом в панели."
        if confirm "Продолжить с занятым портом?"; then
            printf -v "$var" '%s' "$answer"
        else
            pick_port "$var" "$proto"
        fi
        return $?
    fi
    printf -v "$var" '%s' "$answer"
}

# db_port_in_use <порт> — занят ли порт другим inbound в БД панели.
db_port_in_use() {
    local port="$1"
    sqlite3 "$XUI_DB" "SELECT id FROM inbounds WHERE port = $port LIMIT 1;" 2>/dev/null | grep -q .
}

# db_remark_in_use <remark> — есть ли инбаунд с таким наименованием (remark).
db_remark_in_use() {
    local remark="$1"
    sqlite3 "$XUI_DB" "SELECT id FROM inbounds WHERE remark = '$(sql_escape "$remark")' LIMIT 1;" 2>/dev/null | grep -q .
}

# db_path_in_use <path> — используется ли путь другим инбаундом за прокси.
db_path_in_use() {
    local path="$1"
    [[ -z "$path" || "$path" == "/" ]] && return 1
    sqlite3 "$XUI_DB" "SELECT id FROM inbounds WHERE stream_settings LIKE '%\"path\": \"$(sql_escape "$path")\"%' LIMIT 1;" 2>/dev/null | grep -q .
}

# db_sni_in_use <sni> <tls|reality> — занят ли SNI другим инбаундом.
# Для tls ищем "serverName", для reality — "serverNames" (массив).
db_sni_in_use() {
    local sni="$1" kind="${2:-tls}"
    if [[ "$kind" == "reality" ]]; then
        sqlite3 "$XUI_DB" "SELECT id FROM inbounds WHERE stream_settings LIKE '%\"serverNames\": [\"$(sql_escape "$sni")\"]%' LIMIT 1;" 2>/dev/null | grep -q .
    else
        sqlite3 "$XUI_DB" "SELECT id FROM inbounds WHERE stream_settings LIKE '%\"serverName\": \"$(sql_escape "$sni")\"%' LIMIT 1;" 2>/dev/null | grep -q .
    fi
}

# --- Работа с firewall ------------------------------------------------------------

# firewall_port_open <порт> <tcp|udp> — открывает порт в активном firewall.
# Только фактический протокол инбаунда (tcp или udp), «both» не используется.
# Если firewall (ufw/firewalld) не активен — только предупреждение.
firewall_port_open() {
    local port="$1" proto="${2:-tcp}"
    case "$proto" in
        tcp|udp) ;;
        *) proto="tcp" ;;
    esac
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow "${port}"/"${proto}" >/dev/null
        ok "ufw: открыт порт ${port}/${proto}."
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${port}"/"${proto}" >/dev/null
        firewall-cmd --reload >/dev/null
        ok "firewalld: открыт порт ${port}/${proto}."
    else
        warn "Активный firewall (ufw/firewalld) не обнаружен — порт ${port}/${proto} наружу не открыт."
    fi
}

# firewall_port_remove <порт> <tcp|udp> — удаляет ранее созданное правило
# (allow) в активном firewall, а не добавляет deny.
firewall_port_remove() {
    local port="$1" proto="${2:-tcp}"
    case "$proto" in
        tcp|udp) ;;
        *) proto="tcp" ;;
    esac
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw delete allow "${port}"/"${proto}" >/dev/null
        ok "ufw: удалено правило ${port}/${proto}."
    elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="${port}"/"${proto}" >/dev/null
        firewall-cmd --reload >/dev/null
        ok "firewalld: удалено правило ${port}/${proto}."
    else
        warn "Активный firewall (ufw/firewalld) не обнаружен — правило ${port}/${proto} не удалено."
    fi
}

# --- Экранирование для SQL ----------------------------------------------------------
sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

# =============================================================================
# Генераторы JSON-настроек inbound (формат базы 3x-ui v3.6+)
# =============================================================================
# Значения (uuid, ключи, пароли) не содержат двойных кавычек, поэтому JSON
# собирается прямой подстановкой в heredoc-шаблоны.
# =============================================================================

# client_base <email> <subid> — общая часть клиента любого протокола.
client_base() {
    local email="$1" subid="$2"
    printf '{\n    "email": "%s",\n    "limitIp": 0,\n    "totalGB": 0,\n    "expiryTime": 0,\n    "enable": true,\n    "tgId": 0,\n    "subId": "%s",\n    "comment": "",\n    "reset": 0\n  }' "$email" "$subid"
}

# make_client_data <protocol> <email> <subid> <flow> — генерирует данные клиента
# и кладёт их в глобальные переменные CLIENT_* (используются и в JSON, и в ссылках).
make_client_data() {
    local proto="$1"
    CLIENT_EMAIL="$2"
    CLIENT_SUBID="$3"
    CLIENT_FLOW="${4:-}"
    CLIENT_ID=""; CLIENT_PW=""; CLIENT_AUTH=""
    CLIENT_PRIV=""; CLIENT_PUB=""; CLIENT_SECRET=""
    case "$proto" in
        vless)  CLIENT_ID="$(gen_uuid)" ;;
        vmess)  CLIENT_ID="$(gen_uuid)" ;;
        trojan) CLIENT_PW="$(gen_password 24)" ;;
        hysteria) CLIENT_AUTH="$(gen_password 24)" ;;
        wireguard)
            x25519_keypair || die "Не удалось сгенерировать ключи WireGuard."
            CLIENT_PRIV="$X25519_PRIV"; CLIENT_PUB="$X25519_PUB"
            ;;
        mtproto) CLIENT_SECRET="$(gen_mtproto_secret)" ;;
        http|mixed)
            ACCOUNT_USER="$(gen_password 10)"; ACCOUNT_PASS="$(gen_password 20)" ;;
        *) die "Неизвестный протокол клиента: $proto" ;;
    esac
}

# gen_client <protocol> — JSON клиента из переменных CLIENT_*.
gen_client() {
    local proto="$1"
    case "$proto" in
        vless)
            printf '{\n    "id": "%s",\n    "email": "%s",\n    "flow": "%s",\n    "limitIp": 0,\n    "totalGB": 0,\n    "expiryTime": 0,\n    "enable": true,\n    "tgId": 0,\n    "subId": "%s",\n    "comment": "",\n    "reset": 0\n  }' "$CLIENT_ID" "$CLIENT_EMAIL" "$CLIENT_FLOW" "$CLIENT_SUBID"
            ;;
        vmess)
            printf '{\n    "id": "%s",\n    "security": "auto",\n    "alterId": 0,\n    "email": "%s",\n    "limitIp": 0,\n    "totalGB": 0,\n    "expiryTime": 0,\n    "enable": true,\n    "tgId": 0,\n    "subId": "%s",\n    "comment": "",\n    "reset": 0\n  }' "$CLIENT_ID" "$CLIENT_EMAIL" "$CLIENT_SUBID"
            ;;
        trojan)
            printf '{\n    "password": "%s",\n    "email": "%s",\n    "limitIp": 0,\n    "totalGB": 0,\n    "expiryTime": 0,\n    "enable": true,\n    "tgId": 0,\n    "subId": "%s",\n    "comment": "",\n    "reset": 0\n  }' "$CLIENT_PW" "$CLIENT_EMAIL" "$CLIENT_SUBID"
            ;;
        hysteria)
            printf '{\n    "auth": "%s",\n    "email": "%s",\n    "limitIp": 0,\n    "totalGB": 0,\n    "expiryTime": 0,\n    "enable": true,\n    "tgId": 0,\n    "subId": "%s",\n    "comment": "",\n    "reset": 0\n  }' "$CLIENT_AUTH" "$CLIENT_EMAIL" "$CLIENT_SUBID"
            ;;
        wireguard)
            printf '{\n    "privateKey": "%s",\n    "publicKey": "%s",\n    "allowedIPs": ["10.0.0.2/32"],\n    "keepAlive": 25,\n    "email": "%s",\n    "limitIp": 0,\n    "totalGB": 0,\n    "expiryTime": 0,\n    "enable": true,\n    "tgId": 0,\n    "subId": "%s",\n    "comment": "",\n    "reset": 0\n  }' "$CLIENT_PRIV" "$CLIENT_PUB" "$CLIENT_EMAIL" "$CLIENT_SUBID"
            ;;
        mtproto)
            printf '{\n    "email": "%s",\n    "secret": "%s",\n    "enable": true\n  }' "$CLIENT_EMAIL" "$CLIENT_SECRET"
            ;;
        *)
            die "Неизвестный протокол клиента: $proto"
            ;;
    esac
}

# gen_mtproto_secret — FakeTLS-секрет Telegram: "ee" + 16 случайных байт (hex) + домен (hex).
gen_mtproto_secret() {
    local domain="www.cloudflare.com"
    printf 'ee%s%s' "$(openssl rand -hex 16)" "$(printf '%s' "$domain" | od -An -tx1 | tr -d ' \n')"
}

# build_settings <protocol> <client_json> <доп.аргументы...>
# Печатает JSON "settings" для inbound.
build_settings() {
    local proto="$1" client="$2"
    case "$proto" in
        vless)
            printf '{\n  "clients": [\n%s\n  ],\n  "decryption": "none",\n  "encryption": "none",\n  "fallbacks": []\n}' "$client"
            ;;
        vmess)
            printf '{\n  "clients": [\n%s\n  ]\n}' "$client"
            ;;
        trojan)
            printf '{\n  "clients": [\n%s\n  ],\n  "fallbacks": []\n}' "$client"
            ;;
        hysteria)
            printf '{\n  "version": 2,\n  "clients": [\n%s\n  ]\n}' "$client"
            ;;
        wireguard)
            local wg_secret=""
            if x25519_keypair; then wg_secret="$X25519_PRIV"; fi
            [[ -n "$wg_secret" ]] || die "Не удалось сгенерировать секретный ключ WireGuard."
            printf '{\n  "mtu": 1420,\n  "secretKey": "%s",\n  "peers": [],\n  "clients": [\n%s\n  ],\n  "noKernelTun": false\n}' "$wg_secret" "$client"
            ;;
        mtproto)
            printf '{\n  "fakeTlsDomain": "www.cloudflare.com",\n  "clients": [\n%s\n  ]\n}' "$client"
            ;;
        http)
            printf '{\n  "accounts": [\n    {\n      "user": "%s",\n      "pass": "%s"\n    }\n  ],\n  "allowTransparent": false\n}' "${ACCOUNT_USER:-$(gen_password 10)}" "${ACCOUNT_PASS:-$(gen_password 20)}"
            ;;
        mixed)
            printf '{\n  "auth": "password",\n  "accounts": [\n    {\n      "user": "%s",\n      "pass": "%s"\n    }\n  ],\n  "udp": true,\n  "ip": "127.0.0.1"\n}' "${ACCOUNT_USER:-$(gen_password 10)}" "${ACCOUNT_PASS:-$(gen_password 20)}"
            ;;
        *)
            die "Неизвестный протокол: $proto"
            ;;
    esac
}

# --- Сборка stream_settings ---------------------------------------------------------

# tls_settings <serverName> — JSON tlsSettings. Для инбаунда с уникальным SNI
# (TCP+TLS) используется его собственный сертификат из CHANNEL_CERT_DIR,
# иначе — сертификат панели; при отсутствии — self-signed.
tls_settings() {
    local sni="${1:-}"
    local cert="$PANEL_CERT" key="$PANEL_CERT_KEY"
    if [[ -n "${CHANNEL_CERT_DIR:-}" ]]; then
        cert="$CHANNEL_CERT_DIR/fullchain.pem"
        key="$CHANNEL_CERT_DIR/privkey.pem"
    fi
    if [[ -n "$cert" && -n "$key" ]]; then
        printf '{\n    "serverName": "%s",\n    "minVersion": "1.2",\n    "maxVersion": "1.3",\n    "cipherSuites": "",\n    "rejectUnknownSni": false,\n    "disableSystemRoot": false,\n    "enableSessionResumption": false,\n    "certificates": [\n      {\n        "certificateFile": "%s",\n        "keyFile": "%s",\n        "oneTimeLoading": false,\n        "usage": "encipherment",\n        "buildChain": false\n      }\n    ],\n    "alpn": ["h2", "http/1.1"],\n    "echServerKeys": "",\n    "settings": {\n      "fingerprint": "chrome",\n      "echConfigList": ""\n    }\n  }' "$sni" "$cert" "$key"
    else
        printf '%s[ WARN ]%s %s\n' "$C_YELLOW" "$C_RESET" "Сертификат не найден — будет выпущен self-signed для инбаунда." >&2
        gen_selfsigned_inbound_cert
        printf '{\n    "serverName": "%s",\n    "minVersion": "1.2",\n    "maxVersion": "1.3",\n    "cipherSuites": "",\n    "rejectUnknownSni": false,\n    "disableSystemRoot": false,\n    "enableSessionResumption": false,\n    "certificates": [\n      {\n        "certificateFile": "%s",\n        "keyFile": "%s",\n        "oneTimeLoading": false,\n        "usage": "encipherment",\n        "buildChain": false\n      }\n    ],\n    "alpn": ["h2", "http/1.1"],\n    "echServerKeys": "",\n    "settings": {\n      "fingerprint": "chrome",\n      "echConfigList": ""\n    }\n  }' "$sni" "$PANEL_CERT" "$PANEL_CERT_KEY"
    fi
}

# gen_selfsigned_inbound_cert — выпускает self-signed сертификат для инбаунда в
# /etc/ssl/x-ui-inbound/<порт>/ (используется, когда у панели нет своего сертификата).
gen_selfsigned_inbound_cert() {
    local dir="/etc/ssl/x-ui-inbound/chan"
    mkdir -p "$dir"
    if [[ ! -f "$dir/fullchain.pem" || ! -f "$dir/privkey.pem" ]]; then
        local addr
        addr="$(external_addr)"
        openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" -days 3650 \
            -subj "/CN=${addr}" \
            -addext "subjectAltName=IP:${SERVER_IP},DNS:${addr}" >/dev/null 2>&1 \
            || openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" -days 3650 \
            -subj "/CN=${addr}" \
            -addext "subjectAltName=IP:${SERVER_IP},DNS:${addr}" >/dev/null 2>&1 \
            || die "Не удалось выпустить self-signed сертификат."
    fi
    PANEL_CERT="$dir/fullchain.pem"
    PANEL_CERT_KEY="$dir/privkey.pem"
}

# cert_covers <cert> <домен> — покрывает ли сертификат домен в SAN.
cert_covers() {
    [[ -f "$1" ]] || return 1
    openssl x509 -in "$1" -noout -text 2>/dev/null | grep -Eq "DNS:${2}(,|$| )"
}

# issue_selfsigned_channel_cert <домен> — self-signed сертификат для инбаунда
# в /root/cert/inbounds/<домен>/ (запасной вариант, когда LE недоступен).
issue_selfsigned_channel_cert() {
    local domain="$1" dir
    dir="/root/cert/inbounds/${domain}"
    mkdir -p "$dir"
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" -days 3650 \
        -subj "/CN=${domain}" \
        -addext "subjectAltName=DNS:${domain}" >/dev/null 2>&1 \
        || openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" -days 3650 \
        -subj "/CN=${domain}" \
        -addext "subjectAltName=DNS:${domain}" >/dev/null 2>&1 \
        || die "Не удалось выпустить self-signed сертификат для $domain."
    chmod 600 "$dir/privkey.pem"
    chmod 644 "$dir/fullchain.pem"
    ok "Self-signed сертификат инбаунда: $dir"
}

# issue_domain_cert <домен> — сертификат инбаунда через Let's Encrypt (certbot,
# HTTP-01). Перед выпуском проверяет, что DNS уже резолвится на IP сервера.
# Порт 80 нужен certbot --standalone: если его занимает nginx, nginx временно
# останавливается и возвращается после выпуска (сайты не должны использовать 80).
issue_domain_cert() {
    local domain="$1"
    local CERT_DIR="/root/cert/inbounds/${domain}"

    if port_in_use 80 tcp; then
        warn "Порт 80 занят — HTTP-01 Let's Encrypt требует свободный порт."
        warn "Если порт держит nginx, он будет временно остановлен на время выпуска."
        confirm "Продолжить?" || return 1
    fi

    # Проверка DNS: запись A должна указывать на этот сервер
    local resolved=""
    resolved="$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u | head -1 || true)"
    if [[ -n "$resolved" && "$resolved" != "$SERVER_IP" ]]; then
        warn "DNS: $domain → $resolved (ожидался $SERVER_IP)."
        confirm "Продолжить выпуск всё равно?" || return 1
    elif [[ -z "$resolved" ]]; then
        warn "DNS-запись для $domain не найдена — HTTP-01 не пройдёт."
        confirm "Продолжить всё равно?" || return 1
    fi

    command -v certbot >/dev/null 2>&1 || {
        info "certbot не установлен — устанавливаем..."
        if command -v apt-get >/dev/null 2>&1; then
            apt-get update >/dev/null 2>&1 && apt-get install -y certbot >/dev/null 2>&1 || true
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache certbot >/dev/null 2>&1 || true
        fi
        command -v certbot >/dev/null 2>&1 || { warn "certbot не установился."; return 1; }
    }

    local email=""
    ask "E-mail для Let's Encrypt (необязательно, для продлений)" "" email

    local nginx_stopped=0
    if port_in_use 80 tcp && systemctl is-active --quiet nginx 2>/dev/null; then
        info "Останавливаем nginx на время выпуска (освобождаем порт 80)..."
        systemctl stop nginx
        nginx_stopped=1
        sleep 1
    fi
    firewall_port_open 80 tcp 2>/dev/null || true
    mkdir -p "$CERT_DIR"
    rm -rf "/etc/letsencrypt/live/${domain}" >/dev/null 2>&1 || true

    local ok_issue=0
    if [[ -n "$email" ]]; then
        certbot certonly --standalone --preferred-challenges http -d "$domain" \
            -m "$email" --agree-tos --no-eff-email --non-interactive --force-renewal \
            >/dev/null 2>&1 && ok_issue=1
    else
        certbot certonly --standalone --preferred-challenges http -d "$domain" \
            --register-unsafely-without-email --agree-tos --no-eff-email \
            --non-interactive --force-renewal >/dev/null 2>&1 && ok_issue=1
    fi

    if [[ "$nginx_stopped" == "1" ]]; then
        systemctl start nginx
        sleep 1
    fi

    if [[ "$ok_issue" == "1" && -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
        # certbot настраивает авто-продление; в каталог инбаунда кладём
        # симлинки, чтобы обновления сертификата подхватывались автоматически.
        ln -sf "/etc/letsencrypt/live/${domain}/fullchain.pem" "$CERT_DIR/fullchain.pem"
        ln -sf "/etc/letsencrypt/live/${domain}/privkey.pem" "$CERT_DIR/privkey.pem"
        chmod 644 "$CERT_DIR/fullchain.pem"
        chmod 600 "$CERT_DIR/privkey.pem"
        ok "Выпущен сертификат Let's Encrypt для $domain."
        return 0
    fi
    warn "Не удалось выпустить сертификат Let's Encrypt для $domain."
    return 1
}

# ensure_channel_cert <домен> — гарантирует наличие сертификата для инбаунда.
# Приоритет: сертификат панели (если покрывает домен) → существующий сертификат
# инбаунда → выпуск Let's Encrypt (certbot) → self-signed.
ensure_channel_cert() {
    local domain="$1" dir
    dir="/root/cert/inbounds/${domain}"
    if cert_covers "$PANEL_CERT" "$domain"; then
        info "Сертификат панели уже покрывает $domain — используем его."
        CHANNEL_CERT_DIR=""
        return 0
    fi
    if [[ -f "$dir/fullchain.pem" && -f "$dir/privkey.pem" ]]; then
        ok "Сертификат инбаунда уже есть: $dir"
        CHANNEL_CERT_DIR="$dir"
        return 0
    fi
    CHANNEL_CERT_DIR="$dir"
    if confirm "Выпустить сертификат для $domain (Let's Encrypt, нужна DNS-запись)?" "y"; then
        issue_domain_cert "$domain" \
            && { ok "Сертификат инбаунда готов: $dir"; return 0; }
        warn "Выпуск не удался — используем self-signed (не рекомендуется для клиентов)."
    else
        warn "Сертификат инбаунда будет self-signed."
    fi
    issue_selfsigned_channel_cert "$domain"
}

# gen_reality_keys — генерирует ключи REALITY ОДИН раз в текущем шелле
# (важно: функции, вызываемые в $(...), не могут вернуть глобальные переменные).
gen_reality_keys() {
    if [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" && -n "$REALITY_SHORT_ID" ]]; then
        return 0
    fi
    x25519_keypair || die "Не удалось сгенерировать ключи REALITY (нужен xray или openssl)."
    REALITY_PRIVATE_KEY="$X25519_PRIV"
    REALITY_PUBLIC_KEY="$X25519_PUB"
    REALITY_SHORT_ID="$(gen_hex 8)"
}

# reality_settings <target> <serverNames> — JSON realitySettings + настройки клиентов.
reality_settings() {
    local target="${1:-yahoo.com:443}" sni="${2:-yahoo.com}"
    gen_reality_keys
    REALITY_SNI="$sni"
    printf '{\n    "show": false,\n    "xver": 0,\n    "target": "%s",\n    "serverNames": ["%s"],\n    "privateKey": "%s",\n    "minClientVer": "",\n    "maxClientVer": "",\n    "maxTimediff": 0,\n    "shortIds": ["%s"],\n    "mldsa65Seed": "",\n    "settings": {\n      "publicKey": "%s",\n      "fingerprint": "chrome",\n      "serverName": "%s",\n      "spiderX": "/",\n      "mldsa65Verify": ""\n    }\n  }' "$target" "$sni" "$REALITY_PRIVATE_KEY" "$REALITY_SHORT_ID" "$REALITY_PUBLIC_KEY" "$sni"
}

# build_stream <network> <security> <path> <host> <cert_sni>
# Печатает JSON "streamSettings". Доп. значения для security кладутся в глобальные
# переменные (REALITY_*).
#
# Формат перенесён из эталона x-ui-pro (GFW4Fun/mozaroc): для инбаундов за nginx
# добавляются host/authority (домен), externalProxy [{forceTls, dest: домен, port: 443}]
# и acceptProxyProtocol для tcp-инбаундов при stream-мастере (nginx шлёт PROXY-заголовок).
build_stream() {
    local network="$1" security="${2:-none}" path="${3:-/}" host="${4:-}" sni="${5:-}"
    [[ "$path" == / ]] && path="/"
    # externalProxy — как в эталоне: tls для http-транспортов, same для tcp (reality/tls)
    local ext="" accept_pp="false"
    if [[ -n "$USE_NGINX" ]]; then
        local ft="same"
        [[ "$network" != "tcp" ]] && ft="tls"
        ext=$(printf ',\n  "externalProxy": [\n    {\n      "forceTls": "%s",\n      "dest": "%s",\n      "port": %s,\n      "remark": ""\n    }\n  ]' "$ft" "${PANEL_HOST:-$(external_addr)}" "${STREAM_MASTER_PORT:-443}")
        # PROXY-заголовок шлёт только stream-мастер; в legacy-режиме (passthrough
        # без мастера) его нет — acceptProxyProtocol должен оставаться false.
        if [[ "$network" == "tcp" && "$STREAM_443_MASTER" == "1" ]]; then
            accept_pp="true"
        fi
    fi
    case "$network" in
        tcp)
            if [[ "$security" == "reality" ]]; then
                build_reality_settings_json
                printf '{\n  "network": "tcp",\n  "tcpSettings": {\n    "acceptProxyProtocol": %s,\n    "header": {\n      "type": "none"\n    }\n  },\n  "security": "reality",\n  "realitySettings": %s%b\n}' "$accept_pp" "$REALITY_SETTINGS_JSON" "$ext"
            else
                printf '{\n  "network": "tcp",\n  "tcpSettings": {\n    "acceptProxyProtocol": %s,\n    "header": {\n      "type": "none"\n    }\n  },\n  "security": "%s"' "$accept_pp" "$security"
                [[ "$security" == "tls" ]] && printf ',\n  "tlsSettings": %s' "$(tls_settings "$sni")"
                printf '%b\n}' "$ext"
            fi
            ;;
        ws)
            printf '{\n  "network": "ws",\n  "wsSettings": {\n    "acceptProxyProtocol": false,\n    "path": "%s",\n    "host": "%s",\n    "headers": {}\n  },\n  "security": "%s"' "$path" "$host" "$security"
            [[ "$security" == "tls" ]] && printf ',\n  "tlsSettings": %s' "$(tls_settings "$sni")"
            printf '%b\n}' "$ext"
            ;;
        grpc)
            printf '{\n  "network": "grpc",\n  "grpcSettings": {\n    "serviceName": "%s",\n    "authority": "%s",\n    "multiMode": false\n  },\n  "security": "%s"' "$path" "$host" "$security"
            [[ "$security" == "tls" ]] && printf ',\n  "tlsSettings": %s' "$(tls_settings "$sni")"
            printf '%b\n}' "$ext"
            ;;
        xhttp)
            # Полностью как в эталоне x-ui-pro: mode packet-up, спец-sockopt,
            # слушает на unix-сокете (port=0 в инбаунде), TLS терминирует nginx.
            printf '{\n  "network": "xhttp",\n  "xhttpSettings": {\n    "path": "%s",\n    "host": "%s",\n    "headers": {},\n    "scMaxBufferedPosts": 30,\n    "scMaxEachPostBytes": "1000000",\n    "noSSEHeader": false,\n    "xPaddingBytes": "100-1000",\n    "mode": "packet-up"\n  },\n  "sockopt": {\n    "acceptProxyProtocol": false,\n    "tcpFastOpen": true,\n    "mark": 0,\n    "tproxy": "off",\n    "tcpMptcp": true,\n    "tcpNoDelay": true,\n    "domainStrategy": "UseIP",\n    "tcpMaxSeg": 1440,\n    "dialerProxy": "",\n    "tcpKeepAliveInterval": 0,\n    "tcpKeepAliveIdle": 300,\n    "tcpUserTimeout": 10000,\n    "tcpcongestion": "bbr",\n    "V6Only": false,\n    "tcpWindowClamp": 600,\n    "interface": ""\n  },\n  "security": "%s"' "$path" "$host" "$security"
            [[ "$security" == "tls" ]] && printf ',\n  "tlsSettings": %s' "$(tls_settings "$sni")"
            printf '%b\n}' "$ext"
            ;;
        httpupgrade)
            printf '{\n  "network": "httpupgrade",\n  "httpupgradeSettings": {\n    "path": "%s",\n    "host": "%s",\n    "headers": {}\n  },\n  "security": "%s"' "$path" "$host" "$security"
            [[ "$security" == "tls" ]] && printf ',\n  "tlsSettings": %s' "$(tls_settings "$sni")"
            printf '%b\n}' "$ext"
            ;;
        kcp)
            printf '{\n  "network": "kcp",\n  "kcpSettings": {\n    "mtu": 1350,\n    "tti": 20,\n    "uplinkCapacity": 5,\n    "downlinkCapacity": 20,\n    "cwndMultiplier": 1,\n    "maxSendingWindow": 2097152,\n    "header": {\n      "type": "none"\n    }\n  },\n  "security": "none"\n}'
            ;;
        hysteria)
            printf '{\n  "network": "hysteria",\n  "hysteriaSettings": {\n    "version": 2,\n    "udpIdleTimeout": 60\n  },\n  "security": "tls",\n  "tlsSettings": %s\n}' "$(tls_settings "$sni")"
            ;;
        *)
            die "Неизвестный транспорт: $network"
            ;;
    esac
}

# build_reality_settings_json — заполняет глобальную REALITY_SETTINGS_JSON.
build_reality_settings_json() {
    REALITY_SETTINGS_JSON="$(reality_settings "${REALITY_TARGET:-yahoo.com:443}" "${REALITY_SNI:-yahoo.com}")"
}

# =============================================================================
# Работа с базой панели
# =============================================================================

# sniffing_json <on> — JSON поля sniffing (по умолчанию включено).
sniffing_json() {
    if [[ "${1:-1}" == "1" ]]; then
        printf '{\n  "enabled": true,\n  "destOverride": ["http", "tls", "quic", "fakedns"],\n  "metadataOnly": false,\n  "routeOnly": false,\n  "ipsExcluded": [],\n  "domainsExcluded": []\n}'
    else
        printf '{\n  "enabled": false,\n  "destOverride": ["http", "tls", "quic", "fakedns"],\n  "metadataOnly": false,\n  "routeOnly": false,\n  "ipsExcluded": [],\n  "domainsExcluded": []\n}'
    fi
}

# db_has_column <таблица> <колонка> — проверяет наличие колонки в таблице.
db_has_column() {
    sqlite3 "$XUI_DB" "PRAGMA table_info($1);" 2>/dev/null | awk -F'|' -v c="$2" '$2 == c { found=1 } END { exit !found }'
}

# db_has_table <таблица> — существует ли таблица.
db_has_table() {
    sqlite3 "$XUI_DB" "SELECT name FROM sqlite_master WHERE type='table' AND name='$1';" 2>/dev/null | grep -q "$1"
}

# db_list_clients — список клиентов для выбора при создании инбаунда:
# каждая строка «id|email|протоколы_инбаундов» (протоколы — через запятую,
# пусто, если у клиента нет инбаундов).
db_list_clients() {
    sqlite3 "$XUI_DB" "SELECT c.id, c.email,
        COALESCE(GROUP_CONCAT(DISTINCT i.protocol), '')
      FROM clients c
      LEFT JOIN client_inbounds ci ON ci.client_id = c.id
      LEFT JOIN inbounds i ON i.id = ci.inbound_id
      GROUP BY c.id
      ORDER BY c.email;" 2>/dev/null || true
}

# db_delete_inbound <id> — удаляет инбаунд: inbound, hosts, привязки клиентов;
# клиенты, оставшиеся без инбаундов, удаляются вместе со своей статистикой.
db_delete_inbound() {
    local id="$1"
    local orphans=""
    orphans="$(sqlite3 "$XUI_DB" "
SELECT ci.client_id FROM client_inbounds ci
WHERE ci.inbound_id = $id
  AND ci.client_id NOT IN (SELECT client_id FROM client_inbounds WHERE inbound_id != $id);" 2>/dev/null || true)"
    if sqlite3 "$XUI_DB" "BEGIN;
DELETE FROM client_inbounds WHERE inbound_id = $id;
$(db_has_table hosts && echo "DELETE FROM hosts WHERE inbound_id = $id;")
DELETE FROM inbounds WHERE id = $id;
COMMIT;" 2>/dev/null; then
        :
    else
        sqlite3 "$XUI_DB" "ROLLBACK;" 2>/dev/null || true
        die "Ошибка удаления инбаунда (id=$id)."
    fi
    # Статистика удаляемого инбаунда: client_traffics связан по inbound_id
    # (колонки client_id в этой таблице НЕТ — раньше удаление молча
    # пропускалось и записи «6 активных клиентов» оставались в базе).
    sqlite3 "$XUI_DB" "DELETE FROM client_traffics WHERE inbound_id = $id;" 2>/dev/null || true
    local cid="" email=""
    for cid in $orphans; do
        email="$(sqlite3 "$XUI_DB" "SELECT email FROM clients WHERE id = $cid;" 2>/dev/null || true)"
        if db_has_table client_traffics && [[ -n "$email" ]]; then
            sqlite3 "$XUI_DB" "DELETE FROM client_traffics WHERE email = '$(sql_escape "$email")';" 2>/dev/null || true
        fi
        sqlite3 "$XUI_DB" "DELETE FROM clients WHERE id = $cid;" 2>/dev/null || true
    done
    ok "Инбаунд (id=$id) удалён из базы панели."
}

# db_insert_inbound <settings_json> <stream_json> <sniffing_json> — вставка inbound.
# Возвращает (через переменную INBOUND_ID) новый id.
db_insert_inbound() {
    local settings="$1" stream="$2" snf="$3" tag=""
    tag="inbound-${PROTOCOL}-$(gen_hex 4)"
    local now
    now="$(date +%s000)"
    # В некоторых версиях панели таблица inbounds не имеет created_at/updated_at —
    # вставляем их только если колонки реально существуют.
    local time_cols="" time_vals=""
    if db_has_column inbounds created_at; then
        time_cols=", created_at, updated_at"
        time_vals=", $now, $now"
    fi
    INBOUND_ID="$(sqlite3 "$XUI_DB" "
INSERT INTO inbounds
  (user_id, up, down, total, remark, enable, expiry_time, traffic_reset,
   last_traffic_reset_time, listen, port, protocol, settings, stream_settings,
   tag, sniffing, sub_sort_index, node_id, share_addr_strategy, share_addr,
   origin_node_guid, traffic_reset_day${time_cols})
VALUES
  (1, 0, 0, 0, '$(sql_escape "$REMARK")', 1, 0, 'never',
   0, '$(sql_escape "$LISTEN")', $PORT, '$PROTOCOL', '$(sql_escape "$settings")', '$(sql_escape "$stream")',
   '$(sql_escape "$tag")', '$(sql_escape "$snf")', 1, NULL, 'custom', '$(sql_escape "$(external_addr)")',
   '', 1${time_vals});
SELECT last_insert_rowid();")" || die "Ошибка вставки inbound в базу."
}

# db_add_client_records <inbound_id> — таблицы clients/client_inbounds/client_traffics.
# Работает только для протоколов с клиентами (не http/mixed).
# load_existing_client <client_id> — заполняет CLIENT_* данными существующего
# клиента. Источник: settings первого инбаунда клиента с подходящим протоколом
# (истинные данные, которые видит xray); если инбаундов нет (сирота) — таблица
# clients. Сохраняет существующий subId клиента (иначе сломается подписка).
load_existing_client() {
    local cid="$1" settings="" block="" inbound_id="" esc=""
    esc="$(printf '%s' "$CLIENT_EMAIL" | sed 's/[.[\*^$(){}?+|]/\\./g')"
    inbound_id="$(sqlite3 "$XUI_DB" "SELECT ci.inbound_id FROM client_inbounds ci JOIN inbounds i ON i.id = ci.inbound_id WHERE ci.client_id = $cid AND i.protocol = '$(sql_escape "$PROTOCOL")' ORDER BY ci.inbound_id LIMIT 1;" 2>/dev/null || true)"
    if [[ -n "$inbound_id" ]]; then
        settings="$(sqlite3 "$XUI_DB" "SELECT settings FROM inbounds WHERE id = $inbound_id;" 2>/dev/null || true)"
        settings="$(printf '%s' "$settings" | tr -d '\n')"
        block="$(printf '%s' "$settings" | grep -oE '\{"email"[[:space:]]*:[[:space:]]*"'"$esc"'"[^}]*\}' | head -1 || true)"
    fi
    if [[ -n "$block" ]]; then
        case "$PROTOCOL" in
            vless)
                CLIENT_ID="$(json_extract "$block" id)"
                CLIENT_FLOW="$(json_extract "$block" flow)"
                ;;
            vmess)
                CLIENT_ID="$(json_extract "$block" id)"
                ;;
            trojan)
                CLIENT_PW="$(json_extract "$block" password)"
                ;;
            hysteria)
                CLIENT_AUTH="$(json_extract "$block" auth)"
                ;;
            wireguard)
                CLIENT_PRIV="$(json_extract "$block" privateKey)"
                CLIENT_PUB="$(json_extract "$block" publicKey)"
                ;;
            mtproto)
                CLIENT_SECRET="$(json_extract "$block" secret)"
                ;;
        esac
    else
        # Сирота — инбаундов нет, берём поля из clients
        local row=""
        row="$(sqlite3 "$XUI_DB" "SELECT uuid, password, auth, flow, sub_id, secret, wg_private_key, wg_public_key FROM clients WHERE id = $cid;" 2>/dev/null || true)"
        local uu="" pw="" au="" fl="" se="" wgpk="" wgpub=""
        IFS='|' read -r uu pw au fl _ se wgpk wgpub <<< "$row" || true
        case "$PROTOCOL" in
            vless)      CLIENT_ID="$uu"; CLIENT_FLOW="$fl" ;;
            vmess)      CLIENT_ID="$uu" ;;
            trojan)     CLIENT_PW="$pw" ;;
            hysteria)   CLIENT_AUTH="$au" ;;
            wireguard)  CLIENT_PRIV="$wgpk"; CLIENT_PUB="$wgpub" ;;
            mtproto)    CLIENT_SECRET="$se" ;;
        esac
    fi
    local subid=""
    subid="$(sqlite3 "$XUI_DB" "SELECT sub_id FROM clients WHERE id = $cid;" 2>/dev/null || true)"
    if [[ -n "$subid" && "$subid" != "$CLIENT_SUBID" ]]; then
        warn "Клиент уже имеет subId=$subid — используем его (введённый $CLIENT_SUBID игнорируется)."
        CLIENT_SUBID="$subid"
    fi
}

db_add_client_records() {
    local inbound_id="$1" now cid
    [[ "$PROTOCOL" == "http" || "$PROTOCOL" == "mixed" ]] && return 0
    now="$(date +%s000)"
    local wg_pk="" wg_pub="" wg_ips="" wg_ka="0"
    if [[ "$PROTOCOL" == "wireguard" ]]; then
        wg_pk="$CLIENT_PRIV"; wg_pub="$CLIENT_PUB"; wg_ips="10.0.0.2/32"; wg_ka="25"
    fi
    # Колонка clients.password: пароль клиента (для SS панель брала его отсюда).
    local cl_pw="$CLIENT_PW"
    # email уже есть в clients? (уникальность) — обновить, иначе вставить
    local existing
    existing="$(sqlite3 "$XUI_DB" "SELECT id FROM clients WHERE email = '$(sql_escape "$CLIENT_EMAIL")' LIMIT 1;" 2>/dev/null || true)"
    if [[ -n "$existing" ]]; then
        cid="$existing"
        if [[ "$REUSE_CLIENT" == "1" ]]; then
            # Переиспользуемый клиент: протокол-поля (uuid/password/auth/flow/
            # secret/wg_*) НЕ перезаписываем — иначе сломаются старые инбаунды,
            # где в settings сохранены прежние значения.
            :
        else
            local upd
            upd="sub_id = '$(sql_escape "$CLIENT_SUBID")',
                uuid = '$(sql_escape "$CLIENT_ID")',
                password = '$(sql_escape "$cl_pw")',
                auth = '$(sql_escape "$CLIENT_AUTH")',
                flow = '$(sql_escape "$CLIENT_FLOW")',
                security = 'auto',
                limit_ip = 0, total_gb = 0, expiry_time = 0, enable = 1, tg_id = 0,
                comment = '', reset = 0"
            if db_has_column clients updated_at; then
                upd="$upd, updated_at = $now"
            fi
            if db_has_column clients wg_private_key; then
                upd="$upd,
                wg_private_key = '$(sql_escape "$wg_pk")',
                wg_public_key = '$(sql_escape "$wg_pub")',
                wg_allowed_ips = '$(sql_escape "$wg_ips")',
                wg_pre_shared_key = '', wg_keep_alive = $wg_ka"
            fi
            if db_has_column clients secret; then
                upd="$upd, secret = '$(sql_escape "$CLIENT_SECRET")'"
            fi
            sqlite3 "$XUI_DB" "UPDATE clients SET $upd WHERE id = $cid;" || die "Ошибка обновления клиента."
        fi
    else
        local cols vals
        cols="email, sub_id, uuid, password, auth, flow, security, reverse,
             limit_ip, total_gb, expiry_time, enable, tg_id, group_name,
             comment, reset"
        vals="('$(sql_escape "$CLIENT_EMAIL")', '$(sql_escape "$CLIENT_SUBID")', '$(sql_escape "$CLIENT_ID")',
             '$(sql_escape "$cl_pw")', '$(sql_escape "$CLIENT_AUTH")', '$(sql_escape "$CLIENT_FLOW")',
             'auto', '',
             0, 0, 0, 1, 0, '',
             '', 0"
        if db_has_column clients created_at; then
            cols="$cols, created_at, updated_at"
            vals="$vals, $now, $now"
        fi
        if db_has_column clients wg_private_key; then
            cols="$cols, wg_private_key, wg_public_key, wg_allowed_ips, wg_pre_shared_key, wg_keep_alive"
            vals="$vals, '$(sql_escape "$wg_pk")', '$(sql_escape "$wg_pub")', '$(sql_escape "$wg_ips")', '', $wg_ka"
        fi
        if db_has_column clients secret; then
            cols="$cols, secret"
            vals="$vals, '$(sql_escape "$CLIENT_SECRET")'"
        fi
        if db_has_column clients ad_tag; then
            cols="$cols, ad_tag"
            vals="$vals, ''"
        fi
        cid="$(sqlite3 "$XUI_DB" "INSERT INTO clients ($cols) VALUES $vals);
            SELECT last_insert_rowid();")" || die "Ошибка вставки клиента."
    fi
    local ci_cols="client_id, inbound_id"
    local ci_vals="$cid, $inbound_id"
    if db_has_column client_inbounds flow_override; then
        ci_cols="$ci_cols, flow_override"
        ci_vals="$ci_vals, '$(sql_escape "$CLIENT_FLOW")'"
    fi
    if db_has_column client_inbounds created_at; then
        ci_cols="$ci_cols, created_at"
        ci_vals="$ci_vals, $now"
    fi
    sqlite3 "$XUI_DB" "INSERT OR IGNORE INTO client_inbounds ($ci_cols)
        VALUES ($ci_vals);" \
        || die "Ошибка привязки клиента к inbound."
    sqlite3 "$XUI_DB" "INSERT INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total, reset, last_online)
        VALUES ($inbound_id, 1, '$(sql_escape "$CLIENT_EMAIL")', 0, 0, 0, 0, 0, 0)
        ON CONFLICT(email) DO UPDATE SET inbound_id = excluded.inbound_id, enable = 1, expiry_time = 0, total = 0, reset = 0;" \
        || warn "Не удалось создать запись статистики клиента."
}

# restart_xui — перезапуск панели (применяет конфигурацию xray).
# Сбрасывает счётчик systemd start-limit: при частых операциях (несколько
# удалений/созданий подряд) systemd блокирует рестарт («start request repeated
# too quickly»); при неудачном restart — повторный запуск через start.
restart_xui() {
    if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files x-ui.service >/dev/null 2>&1; then
        info "Перезапуск панели x-ui (применение конфигурации)..."
        systemctl reset-failed x-ui.service 2>/dev/null || true
        if ! systemctl restart x-ui; then
            # Возможен start-limit-hit — сбросить счётчик и запустить напрямую.
            systemctl reset-failed x-ui.service 2>/dev/null || true
            systemctl start x-ui
        fi
        sleep 2
        if systemctl is-active x-ui >/dev/null 2>&1; then
            ok "Панель x-ui перезапущена и активна."
        else
            fail "Панель x-ui не запустилась — проверьте конфигурацию (journalctl -u x-ui)."
            return 1
        fi
    else
        warn "systemctl/x-ui недоступны — примените конфигурацию вручную (перезапуск x-ui)."
    fi
}

# =============================================================================
# Генерация share-ссылок
# =============================================================================

urlencode() {
    local s="$1" c="" out="" i
    for ((i = 0; i < ${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9._~-]) out+="$c" ;;
            *) printf -v out '%s%%%02X' "$out" "'$c" ;;
        esac
    done
    printf '%s' "$out"
}

# b64url — base64 url-safe без padding.
b64url() { printf '%s' "$1" | base64 | tr -d '=\n' | tr '+/' '-_'; }

# json_extract <json> <ключ> [num|list] — значение поля из однострочного JSON.
json_extract() {
    local json="$1" key="$2" mode="${3:-}"
    case "$mode" in
        num)  printf '%s' "$json" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1 ;;
        list) printf '%s' "$json" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' | head -1 ;;
        *)    printf '%s' "$json" | sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1 ;;
    esac
}

# sha256_first <строка> <n> — первые n hex-символов sha256.
sha256_first() {
    printf '%s' "$1" | openssl dgst -sha256 -hex 2>/dev/null | sed -n 's/^.*= //p' | cut -c1-"$2"
}

# gen_link_vless — vless:// ссылка.
# link_external — адрес:порт для share-ссылки с учётом прокси.
# WS/gRPC/xHTTP/httpupgrade за nginx: внешний домен панели на 443.
# REALITY/TLS+TCP: после перехода на stream-мастер (STREAM_443_MASTER=1) —
# домен панели на 443, иначе собственный внешний порт инбаунда.
link_external() {
    case "$TRANSPORT" in
        ws|grpc|xhttp|httpupgrade)
            if [[ "$USE_NGINX" == "1" ]]; then
                printf '%s:443' "${PANEL_HOST:-$(external_addr)}"
            else
                printf '%s:%s' "$(external_addr)" "$PORT"
            fi
            ;;
        tcp)
            if [[ "$USE_NGINX" == "1" ]]; then
                # За прокси: stream-мастер → внешний 443, иначе собственный порт
                # (legacy-режим: nginx stream слушает внешний IP:PORT).
                if [[ "$STREAM_443_MASTER" == "1" ]]; then
                    printf '%s:443' "${PANEL_HOST:-$(external_addr)}"
                else
                    printf '%s:%s' "$(external_addr)" "$PORT"
                fi
            else
                printf '%s:%s' "$(external_addr)" "$PORT"
            fi
            ;;
        *)
            printf '%s:%s' "$(external_addr)" "$PORT"
            ;;
    esac
}

gen_link_vless() {
    local ln ln_addr ln_port
    ln="$(link_external)"
    ln_addr="${ln%:*}"
    ln_port="${ln##*:}"
    local link="vless://${CLIENT_ID}@${ln_addr}:${ln_port}"
    local q=("type=${TRANSPORT}")
    if [[ "$SECURITY" == "reality" ]]; then
        q+=("security=reality" "pbk=${REALITY_PUBLIC_KEY}" "fp=chrome" "sni=${REALITY_SNI}" "sid=${REALITY_SHORT_ID}")
        q+=("spx=/$(sha256_first "${REALITY_SPIDERX:-/}|${CLIENT_SUBID:-$CLIENT_EMAIL}" 15)")
        [[ -n "$CLIENT_FLOW" ]] && q+=("flow=${CLIENT_FLOW}")
    elif [[ "$SECURITY" == "tls" ]]; then
        q+=("security=tls" "fp=chrome")
        [[ -n "$SNI" ]] && q+=("sni=${SNI}")
        q+=("alpn=h2,http/1.1")
    else
        q+=("security=none")
    fi
    case "$TRANSPORT" in
        ws)          q+=("path=${WS_PATH}" "host=${WS_HOST:-}") ;;
        grpc)        q+=("serviceName=${WS_PATH}") ;;
        xhttp)       q+=("path=${WS_PATH}" "host=${WS_HOST:-}" "mode=packet-up") ;;
        httpupgrade) q+=("path=${WS_PATH}" "host=${WS_HOST:-}") ;;
    esac
    q+=("encryption=none")
    printf '%s?%s#%s\n' "$link" "$(join_q "${q[@]}")" "$(urlencode "$REMARK")"
}

# gen_link_vmess — vmess://base64(JSON).
gen_link_vmess() {
    local ln ln_addr ln_port tls_sni="" fp="" alpn=""
    ln="$(link_external)"
    ln_addr="${ln%:*}"
    ln_port="${ln##*:}"
    local v="2" ps="$REMARK" add="$ln_addr" port="$ln_port" id="$CLIENT_ID" scy="auto"
    local net="$TRANSPORT" type="none" path="" host="" tls=""
    case "$TRANSPORT" in
        ws)          net="ws"; path="${WS_PATH}"; host="${WS_HOST:-}" ;;
        grpc)        net="grpc"; path="${WS_PATH}" ;;
        xhttp)       net="xhttp"; path="${WS_PATH}"; host="${WS_HOST:-}" ;;
        httpupgrade) net="httpupgrade"; path="${WS_PATH}"; host="${WS_HOST:-}" ;;
    esac
    if [[ "$SECURITY" == "tls" ]]; then
        tls="tls"
        tls_sni="${SNI:-$addr}"
        alpn="h2,http/1.1"
        fp="chrome"
    fi
    local json
    json=$(printf '{\n  "v": "%s",\n  "ps": "%s",\n  "add": "%s",\n  "port": "%s",\n  "id": "%s",\n  "aid": "0",\n  "scy": "%s",\n  "net": "%s",\n  "type": "%s",\n  "host": "%s",\n  "path": "%s",\n  "tls": "%s",\n  "sni": "%s",\n  "alpn": "%s",\n  "fp": "%s"\n}' \
        "$v" "$ps" "$add" "$port" "$id" "$scy" "$net" "$type" "$host" "$path" "$tls" "$tls_sni" "$alpn" "$fp")
    printf 'vmess://%s\n' "$(printf '%s' "$json" | base64 -w0)"
}

# gen_link_trojan — trojan:// ссылка.
gen_link_trojan() {
    local ln ln_addr ln_port link
    ln="$(link_external)"
    ln_addr="${ln%:*}"
    ln_port="${ln##*:}"
    link="trojan://$(urlencode "$CLIENT_PW")@${ln_addr}:${ln_port}"
    local q=("type=${TRANSPORT}")
    if [[ "$SECURITY" == "reality" ]]; then
        q+=("security=reality" "pbk=${REALITY_PUBLIC_KEY}" "fp=chrome" "sni=${REALITY_SNI}" "sid=${REALITY_SHORT_ID}")
        q+=("spx=/$(sha256_first "${REALITY_SPIDERX:-/}|${CLIENT_SUBID:-$CLIENT_EMAIL}" 15)")
    elif [[ "$SECURITY" == "tls" ]]; then
        q+=("security=tls" "fp=chrome")
        [[ -n "$SNI" ]] && q+=("sni=${SNI}")
        q+=("alpn=h2,http/1.1")
    else
        q+=("security=none")
    fi
    case "$TRANSPORT" in
        ws)          q+=("path=${WS_PATH}" "host=${WS_HOST:-}") ;;
        grpc)        q+=("serviceName=${WS_PATH}") ;;
        httpupgrade) q+=("path=${WS_PATH}" "host=${WS_HOST:-}") ;;
    esac
    printf '%s?%s#%s\n' "$link" "$(join_q "${q[@]}")" "$(urlencode "$REMARK")"
}

# gen_link_hysteria2 — hysteria2:// ссылка.
gen_link_hysteria2() {
    local addr link
    addr="$(external_addr)"
    link="hysteria2://$(urlencode "$CLIENT_AUTH")@${addr}:${PORT}"
    local q=("security=tls")
    [[ -n "${SNI:-}" ]] && q+=("sni=${SNI}")
    q+=("alpn=h3" "fp=chrome")
    printf '%s?%s#%s\n' "$link" "$(join_q "${q[@]}")" "$(urlencode "$REMARK")"
}

# gen_link_wireguard — wireguard:// ссылка.
gen_link_wireguard() {
    local addr server_pub=""
    addr="$(external_addr)"
    server_pub="$(wg_pub_from_priv "$(db_get_wg_secret_key "$INBOUND_ID")" 2>/dev/null || true)"
    local q=()
    [[ -n "$server_pub" ]] && q+=("publickey=${server_pub}")
    q+=("address=10.0.0.2/32" "mtu=1420" "keepalive=25")
    printf 'wireguard://%s@%s:%s?%s#%s\n' "$(urlencode "$CLIENT_PRIV")" "$addr" "$PORT" "$(join_q "${q[@]}")" "$(urlencode "$REMARK")"
}

# gen_link_mtproto — tg://proxy (без remark — Telegram не принимает).
gen_link_mtproto() {
    printf 'tg://proxy?server=%s&port=%s&secret=%s\n' "$(external_addr)" "$PORT" "$CLIENT_SECRET"
}

# db_get_wg_secret_key <inbound_id> — secretKey WireGuard из settings.
db_get_wg_secret_key() {
    sqlite3 "$XUI_DB" "SELECT settings FROM inbounds WHERE id = $1;" 2>/dev/null \
        | sed -n 's/.*"secretKey"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
}

# wg_pub_from_priv <priv> — публичный ключ из приватного (wireguard-формат).
wg_pub_from_priv() {
    local priv="$1" tmp hex pub=""
    if command -v wg >/dev/null 2>&1; then
        tmp="$(mktemp)"; printf '%s' "$priv" | base64 -d > "$tmp" 2>/dev/null
        pub="$(wg pubkey < "$tmp" 2>/dev/null || true)"
        rm -f "$tmp"
        [[ -n "$pub" ]] && { printf '%s' "$pub"; return 0; }
    fi
    # fallback: openssl X25519 — собираем PKCS8 из raw 32 байт
    tmp="$(mktemp -d)"
    if printf '%s' "$priv" | base64 -d > "$tmp/k.bin" 2>/dev/null \
        && hex="$(od -An -tx1 -v "$tmp/k.bin" | tr -d ' \n')" \
        && printf '302e020100300506032b656e04220420%s' "$hex" | xxd -r -p > "$tmp/k.der" 2>/dev/null; then
        pub="$(openssl pkey -in "$tmp/k.der" -inform DER -pubout -outform DER 2>/dev/null | tail -c 32 | base64 -w0 | tr -d '\n')"
    fi
    rm -rf "$tmp"
    printf '%s' "$pub"
}

# join_q — объединяет параметры "k=v" в отсортированный по ключу query-строку.
join_q() {
    local arr=("$@") out="" key="" val=""
    mapfile -t arr < <(printf '%s\n' "${arr[@]}" | sort)
    for item in "${arr[@]}"; do
        [[ -z "$item" ]] && continue
        key="${item%%=*}"
        val="${item#*=}"
        [[ -n "$key" ]] || continue
        out+="$key=$(urlencode "$val")&"
    done
    printf '%s' "${out%&}"
}

# =============================================================================
# Меню протоколов
# =============================================================================

menu_protocol() {
    banner ""
    banner "  Выбор протокола Xray-инбаунда (панель 3x-ui v3.6+)"
    banner "  Все инбаунды поддерживаются панелью; ссылки генерируются для"
    banner "  vless/vmess/trojan/hy2/wireguard/mtproto (http/mixed — без ссылок)."
    banner ""
    cat <<'MENU'
   1)  VLESS + REALITY (TCP, XTLS Vision)
   2)  VLESS + TLS (TCP)
   3)  VLESS + WebSocket (TLS)
   4)  VLESS + gRPC (TLS)
   5)  VLESS + XHTTP (TLS)
   6)  VLESS + HTTPUpgrade (TLS)
   7)  VLESS + mKCP (без шифрования)
   8)  VLESS + TCP (без TLS)
   9)  VMess + TCP (TLS)
  10)  VMess + WebSocket (TLS)
  11)  VMess + gRPC (TLS)
  12)  VMess + HTTPUpgrade (TLS)
  13)  Trojan + TCP (TLS)
  14)  Trojan + WebSocket (TLS)
  15)  Trojan + gRPC (TLS)
  16)  Hysteria2 (UDP, TLS)
  17)  WireGuard (UDP)
  18)  Mixed SOCKS+HTTP (TCP)
  19)  HTTP proxy (TCP)
  20)  MTProto (Telegram)
   q)   Выход
MENU
    local ans=""
    read -r -p "Ваш выбор [1-20, q]: " ans || exit 0
    case "$ans" in
        1) PROTOCOL=vless; TRANSPORT=tcp; SECURITY=reality; CLIENT_FLOW=xtls-rprx-vision ;;
        2) PROTOCOL=vless; TRANSPORT=tcp; SECURITY=tls;    CLIENT_FLOW=xtls-rprx-vision ;;
        3) PROTOCOL=vless; TRANSPORT=ws; SECURITY=tls ;;
        4) PROTOCOL=vless; TRANSPORT=grpc; SECURITY=tls ;;
        5) PROTOCOL=vless; TRANSPORT=xhttp; SECURITY=tls ;;
        6) PROTOCOL=vless; TRANSPORT=httpupgrade; SECURITY=tls ;;
        7) PROTOCOL=vless; TRANSPORT=kcp; SECURITY=none ;;
        8) PROTOCOL=vless; TRANSPORT=tcp; SECURITY=none ;;
        9) PROTOCOL=vmess; TRANSPORT=tcp; SECURITY=tls ;;
        10) PROTOCOL=vmess; TRANSPORT=ws; SECURITY=tls ;;
        11) PROTOCOL=vmess; TRANSPORT=grpc; SECURITY=tls ;;
        12) PROTOCOL=vmess; TRANSPORT=httpupgrade; SECURITY=tls ;;
        13) PROTOCOL=trojan; TRANSPORT=tcp; SECURITY=tls ;;
        14) PROTOCOL=trojan; TRANSPORT=ws; SECURITY=tls ;;
        15) PROTOCOL=trojan; TRANSPORT=grpc; SECURITY=tls ;;
        16) PROTOCOL=hysteria; TRANSPORT=hysteria; SECURITY=tls ;;
        17) PROTOCOL=wireguard; TRANSPORT=tcp; SECURITY=none ;;
        18) PROTOCOL=mixed; TRANSPORT=tcp; SECURITY=none ;;
        19) PROTOCOL=http; TRANSPORT=tcp; SECURITY=none ;;
        20) PROTOCOL=mtproto; TRANSPORT=tcp; SECURITY=none ;;
        q|Q|exit) exit 0 ;;
        *) warn "Неверный выбор."; menu_protocol ;;
    esac
}

# =============================================================================
# nginx-интеграция
# =============================================================================

# nginx_test_ok — проверяет конфигурацию nginx (nginx -t). При провале
# сохраняет текст ошибки в NGINX_TEST_ERR и возвращает 1.
nginx_test_ok() {
    NGINX_TEST_ERR=""
    local out=""
    out="$(nginx -t 2>&1)" || {
        NGINX_TEST_ERR="$out"
        return 1
    }
    return 0
}

# nginx_ensure_files — создаёт каталоги и пустые файлы сниппета и stream,
# если их ещё нет. Без этого скрипт молча пропускал настройку прокси.
nginx_ensure_files() {
    local dir_snip dir_stream
    dir_snip="$(dirname "$NGINX_SNIPPET")"
    dir_stream="$(dirname "$NGINX_STREAM")"
    mkdir -p "$dir_snip" "$dir_stream" || { warn "Не удалось создать каталоги nginx ($dir_snip, $dir_stream)."; return 1; }
    [[ -f "$NGINX_SNIPPET" ]] || { touch "$NGINX_SNIPPET" || return 1; }
    [[ -f "$NGINX_STREAM" ]] || { touch "$NGINX_STREAM" || return 1; }
    [[ -s "$NGINX_SNIPPET" ]] || printf '%s\n' "# inbound-xray.sh: WS/gRPC/XHTTP regex-location'ы" > "$NGINX_SNIPPET"
    [[ -s "$NGINX_STREAM" ]] || printf '%s\n' "# inbound-xray.sh: stream-правила (passthrough / stream-мастер)" > "$NGINX_STREAM"
}

# nginx_stream_context_enable — подключает stream-контекст в nginx.conf:
# блок "stream { include <NGINX_STREAM>; }" на верхнем уровне.
# Включается КОНКРЕТНЫЙ файл скрипта (не glob *.conf), чтобы посторонние
# файлы каталога не ломали nginx -t. С бэкапом и откатом при ошибке.
nginx_stream_context_enable() {
    local nf="$NGINX_MAIN"
    local inc_entry
    inc_entry="include ${NGINX_STREAM};"
    [[ -f "$nf" ]] || { warn "Не найден $nf — stream-контекст не подключён."; return 1; }
    if grep -Eqs 'stream\s*\{' "$nf"; then
        if ! grep -Fqs "$inc_entry" "$nf"; then
            warn "$nf: stream-блок уже есть, но include ${NGINX_STREAM} не найден."
        fi
        return 0
    fi
    # Базовый nginx -t ДО изменений: сломанный конфиг не трогаем.
    # Если nginx не знает директиву stream (nginx-core) — доустанавливаем
    # подходящий пакет (nginx-full/nginx-mod-stream).
    if command -v nginx >/dev/null 2>&1 && ! nginx_test_ok; then
        if [[ "$NGINX_TEST_ERR" == *'unknown directive "stream"'* ]]; then
            nginx_install_stream_module || return 1
        else
            warn "nginx -t не проходит и без наших изменений — stream-контекст не добавляю:"
            warn "$NGINX_TEST_ERR"
            return 1
        fi
    fi
    local bak
    bak="$(mktemp)"
    cp -a "$nf" "$bak" || return 1
    {
        printf '\n'
        printf '%s\n' "# inbound-xray.sh: stream-контекст (REALITY/TLS passthrough и stream-мастер)"
        printf '%s\n' 'stream {'
        printf '    %s\n' "$inc_entry"
        printf '%s\n' '}'
    } >> "$nf"
    if command -v nginx >/dev/null 2>&1 && ! nginx_test_ok; then
        warn "nginx -t не прошёл — откат nginx.conf."
        warn "$NGINX_TEST_ERR"
        cp -a "$bak" "$nf"
        rm -f "$bak"
        return 1
    fi
    rm -f "$bak"
    ok "stream-контекст подключён в $nf"
}

# nginx_add_http_location — универсальный location для WS/gRPC/XHTTP/HTTPUpgrade.
# gRPC обязательно идёт через grpc_pass (HTTP/2, иначе xray отвечает 404/разрыв),
# WS/HTTPUpgrade и обычные GET/POST/PUT — через proxy_pass HTTP/1.1.
# Схема повторяет x-ui-pro (mozaroc): buffering off нужен для потоковых транспортов.
nginx_add_http_location() {
    [[ -f "$NGINX_SNIPPET" ]] || return 0
    if grep -Fqs 'grpc_pass grpc://127.0.0.1:$fwdport;' "$NGINX_SNIPPET"; then
        info "Универсальная regex-location (grpc_pass) уже настроена."
        return 0
    fi
    local block
    block=$(cat <<'BLOCK'

    # inbound-xray.sh: универсальная regex-location WS/gRPC/XHTTP/HTTPUpgrade
    # Именованные capture (?<fwdport>...) — позиционные $1 внутри if не работают.
    location ~ ^/(?<fwdport>[0-9]+)/(?<fwdpath>.*)$ {
        client_max_body_size 0;
        client_body_timeout 1d;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_read_timeout 1d;
        grpc_read_timeout 1d;
        grpc_socket_keepalive on;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        if ($content_type ~* "grpc") {
            grpc_pass grpc://127.0.0.1:$fwdport;
            break;
        }
        if ($http_upgrade ~* "(websocket|ws)") {
            proxy_pass http://127.0.0.1:$fwdport;
            break;
        }
        if ($request_method ~* ^(PUT|POST|GET)$) {
            proxy_pass http://127.0.0.1:$fwdport;
            break;
        }
    }
BLOCK
)
    local bak
    bak="$(mktemp)"
    cp -a "$NGINX_SNIPPET" "$bak" || return 1
    # Удаляем старые (HTTP/1.1) regex-location блоки, чтобы не было дублей.
    if grep -Eqs 'location ~ \^/\(\[0-9\]' "$NGINX_SNIPPET"; then
        sed -i '/location ~ \^\/\(\[0-9\]\+\)\/\(\.\*\)\$/,/^[[:space:]]*}$/d' "$NGINX_SNIPPET"
    fi
    printf '%s\n' "$block" >> "$NGINX_SNIPPET" || { cp -a "$bak" "$NGINX_SNIPPET"; return 1; }
    if command -v nginx >/dev/null 2>&1 && ! nginx_test_ok; then
        warn "nginx -t не прошёл — откат конфигурации."
        warn "$NGINX_TEST_ERR"
        cp -a "$bak" "$NGINX_SNIPPET"
        return 1
    fi
    rm -f "$bak"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 && ok "nginx перезагружен."
    fi
    ok "Добавлена универсальная regex-location (grpc_pass + buffering off) в $NGINX_SNIPPET"
}

# nginx_add_xhttp_location — location XHTTP → unix-сокет (как в эталоне x-ui-pro).
# XHTTP-инбаунд слушает на /dev/shm/uds2023.sock, nginx grpc_pass grpc://unix:...
# доставляет трафик на сокет; TLS терминируется nginx.
nginx_add_xhttp_location() {
    [[ -f "$NGINX_SNIPPET" ]] || return 0
    local path="${XHTTP_PATH:-$WS_PATH}"
    [[ -n "$path" ]] || return 0
    if grep -Fqs "grpc_pass grpc://unix:/dev/shm/uds2023.sock;" "$NGINX_SNIPPET"; then
        info "XHTTP location (grpc_pass unix-сокет) уже настроена."
        return 0
    fi
    local block
    block=$(cat <<BLOCK

    # inbound-xray.sh: XHTTP через unix-сокет (эталон x-ui-pro)
    location ${path} {
        grpc_pass grpc://unix:/dev/shm/uds2023.sock;
        grpc_buffer_size         16k;
        grpc_socket_keepalive    on;
        grpc_read_timeout        1h;
        grpc_send_timeout        1h;
        grpc_set_header Connection         "";
        grpc_set_header X-Forwarded-For    \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto  \$scheme;
        grpc_set_header X-Forwarded-Port   \$server_port;
        grpc_set_header Host               \$host;
        grpc_set_header X-Forwarded-Host   \$host;
    }
BLOCK
)
    local bak
    bak="$(mktemp)"
    cp -a "$NGINX_SNIPPET" "$bak" || return 1
    printf '%s\n' "$block" >> "$NGINX_SNIPPET" || { cp -a "$bak" "$NGINX_SNIPPET"; return 1; }
    if command -v nginx >/dev/null 2>&1 && ! nginx_test_ok; then
        warn "nginx -t не прошёл — откат конфигурации."
        warn "$NGINX_TEST_ERR"
        cp -a "$bak" "$NGINX_SNIPPET"
        return 1
    fi
    rm -f "$bak"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 && ok "nginx перезагружен."
    fi
    ok "Добавлен XHTTP location ${path} → grpc://unix:/dev/shm/uds2023.sock в $NGINX_SNIPPET"
}

# nginx_ensure_snippet_included — подключает сниппет WS/gRPC regex-location'ов
# в server-блок NGINX_CONF, если его там ещё нет. Иначе location'ы лежат
# мёртвым грузом и WS-инбаунды за nginx возвращают 404.
nginx_ensure_snippet_included() {
    [[ -f "$NGINX_SNIPPET" ]] || return 0
    [[ -f "$NGINX_CONF" ]] || return 0
    if grep -Fqs "include ${NGINX_SNIPPET};" "$NGINX_CONF"; then
        return 0
    fi
    local bak
    bak="$(mktemp)"
    cp -a "$NGINX_CONF" "$bak" || return 1
    sed -i "/server_name _;/a\\    include ${NGINX_SNIPPET};" "$NGINX_CONF"
    if command -v nginx >/dev/null 2>&1 && ! nginx_test_ok; then
        warn "nginx -t не прошёл — откат $NGINX_CONF."
        warn "$NGINX_TEST_ERR"
        cp -a "$bak" "$NGINX_CONF"
        return 1
    fi
    rm -f "$bak"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || true
    fi
    ok "Сниппет $NGINX_SNIPPET подключён в $NGINX_CONF"
    return 0
}

# nginx_reality_target_server — внутренний https-сервер 127.0.0.1:9443
# (заглушка) для REALITY target. TLS на сертификате поддомена REALITY, как в
# эталоне x-ui-pro (mozaroc): target = фейковый сайт на своём же поддомене.
nginx_reality_target_server() {
    local sni="${1:-$CHANNEL_SNI}" port="${REALITY_TARGET_PORT:-9443}"
    [[ -n "$sni" ]] || return 0
    ensure_channel_cert "$sni"
    local dir="${CHANNEL_CERT_DIR:-/root/cert/inbounds/${sni}}"
    local cert="$dir/fullchain.pem" key="$dir/privkey.pem"
    local conf="/etc/nginx/conf.d/reality-target.conf"
    if [[ ! -f "$cert" || ! -f "$key" ]]; then
        warn "Нет сертификата $sni — target-заглушка будет без TLS."
        cert=""; key=""
    fi
    mkdir -p "$LANDING_DIR"
    if [[ ! -f "$LANDING_INDEX" ]]; then
        printf '%s\n' '<!doctype html><html><head><meta charset="utf-8"><title>It works</title></head><body><h1>It works!</h1></body></html>' > "$LANDING_INDEX"
    fi
    local bak
    bak="$(mktemp)"
    if [[ -f "$conf" ]]; then cp -a "$conf" "$bak"; fi
    {
        printf '%s\n' "# inbound-xray.sh: REALITY target-заглушка (127.0.0.1:${port}, ${sni})"
        printf '%s\n' "server {"
        printf '    listen 127.0.0.1:%s ssl;\n' "$port"
        printf '    server_name %s;\n' "$sni"
        printf '    root %s;\n' "$LANDING_DIR"
        printf '%s\n' '    index index.html;'
        if [[ -n "$cert" ]]; then
            printf '    ssl_certificate %s;\n' "$cert"
            printf '    ssl_certificate_key %s;\n' "$key"
        fi
        printf '%s\n' '    ssl_protocols TLSv1.2 TLSv1.3;'
        printf '%s\n' ''
        # Защита: target-порт — только для REALITY (SNI основного домена).
        # Прочие хосты (панель, посторонние) — закрываем 444.
        printf '%s\n' "    if (\$host != ${sni}) { return 444; }"
        printf '%s\n' "    if (\$ssl_server_name !~* ^(.+\\\\.)?${sni//./\\\\.}\$ ) { return 444; }"
        printf '%s\n' '}'
    } > "$conf"
    if command -v nginx >/dev/null 2>&1 && ! nginx_test_ok; then
        warn "nginx -t не прошёл — откат reality-target.conf."
        warn "$NGINX_TEST_ERR"
        if [[ -f "$bak" ]]; then cp -a "$bak" "$conf"; else rm -f "$conf"; fi
        return 1
    fi
    rm -f "$bak"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || true
    fi
    ok "REALITY target-заглушка: https://127.0.0.1:${port} (${sni})."
}

# nginx_stream_listen — адрес listen для stream-правила инбаунда. nginx слушает
# на ВНЕШНЕМ IP (не 0.0.0.0), иначе он занимает порт целиком и xray не может
# забиндиться на 127.0.0.1:PORT. Если IP не удалось определить — fallback на
# «порт без адреса» (0.0.0.0) с предупреждением.
nginx_stream_listen() {
    if [[ -z "$SERVER_IP" ]]; then
        detect_server_ip
    fi
    if [[ -n "$SERVER_IP" ]]; then
        printf '%s:%s' "$SERVER_IP" "$PORT"
    else
        warn "Не удалось определить внешний IP: stream-правило займёт порт целиком (0.0.0.0), xray не сможет слушать 127.0.0.1:${PORT}."
        printf '%s' "$PORT"
    fi
}

# nginx_add_stream_sni — stream-SNI правило для REALITY/TCP-passthrough.
nginx_add_stream_sni() {
    [[ -f "$NGINX_STREAM" ]] || return 0
    if [[ "$STREAM_443_MASTER" == "1" ]]; then
        info "Режим stream-мастера — обновляем map из БД."
        nginx_stream_master_rebuild
        return 0
    fi
    local sni_block stream_listen
    stream_listen="$(nginx_stream_listen)"
    sni_block=$(cat <<BLOCK

# inbound-xray.sh: инбаунд ${REMARK} (${PROTOCOL}, порт ${PORT})
map \$ssl_preread_server_name \$up_${PORT} {
    default  127.0.0.1:${PORT};
}

server {
    listen ${stream_listen};
    listen ${stream_listen} udp;
    proxy_pass \$up_${PORT};
    proxy_protocol off;
    ssl_preread on;
}
BLOCK
)
    local bak
    bak="$(mktemp)"
    cp -a "$NGINX_STREAM" "$bak" || return 1
    printf '%s\n' "$sni_block" >> "$NGINX_STREAM" || { cp -a "$bak" "$NGINX_STREAM"; return 1; }
    if command -v nginx >/dev/null 2>&1 && ! nginx_test_ok; then
        warn "nginx -t не прошёл — откат конфигурации."
        warn "$NGINX_TEST_ERR"
        cp -a "$bak" "$NGINX_STREAM"
        return 1
    fi
    rm -f "$bak"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 && ok "nginx (stream) перезагружен."
    fi
    ok "Добавлено stream-SNI правило в $NGINX_STREAM"
}

# nginx_add_stream_tcp — TCP-passthrough для TLS-инбаунда (VMess/VLESS/Trojan+TCP+TLS).
nginx_add_stream_tcp() {
    [[ -f "$NGINX_STREAM" ]] || return 0
    if [[ "$STREAM_443_MASTER" == "1" ]]; then
        info "Режим stream-мастера — обновляем map из БД."
        nginx_stream_master_rebuild
        return 0
    fi
    if grep -Eqs "listen[[:space:]]+([^:]+:)?${PORT}[[:space:]]*(;|$)" "$NGINX_STREAM" \
        && grep -Eqs "proxy_pass[[:space:]]+127\.0\.0\.1:${PORT}" "$NGINX_STREAM"; then
        info "stream-passthrough для порта ${PORT} уже настроен."
        return 0
    fi
    local block stream_listen
    stream_listen="$(nginx_stream_listen)"
    block=$(cat <<BLOCK

# inbound-xray.sh: инбаунд ${REMARK} (${PROTOCOL}+${TRANSPORT}+${SECURITY}, порт ${PORT})
server {
    listen ${stream_listen};
    proxy_pass 127.0.0.1:${PORT};
}
BLOCK
)
    local bak
    bak="$(mktemp)"
    cp -a "$NGINX_STREAM" "$bak" || return 1
    printf '%s\n' "$block" >> "$NGINX_STREAM" || { cp -a "$bak" "$NGINX_STREAM"; return 1; }
    if command -v nginx >/dev/null 2>&1 && ! nginx_test_ok; then
        warn "nginx -t не прошёл — откат конфигурации."
        warn "$NGINX_TEST_ERR"
        cp -a "$bak" "$NGINX_STREAM"
        return 1
    fi
    rm -f "$bak"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 && ok "nginx (stream) перезагружен."
    fi
    ok "Добавлено stream (TCP-passthrough) правило в $NGINX_STREAM"
}

# stream_ssl_preread_ok — есть ли модуль stream_ssl_preread в nginx.
stream_ssl_preread_ok() {
    nginx -V 2>&1 | grep -q "stream_ssl_preread"
}

# is_stream_443_master — включён ли режим stream-мастера (по маркеру в файле).
is_stream_443_master() {
    [[ -f "$NGINX_STREAM" ]] && grep -Eqs 'stream-443 master' "$NGINX_STREAM"
}

# nginx_stream_master_rebuild — пересобирает NGINX_STREAM в режиме мастера:
# один server listen 443 с ssl_preread и map SNI → 127.0.0.1:<порт>.
# default → внутренний http-модуль nginx (панель + WS/gRPC).
# Инбаунды TLS/REALITY за nginx без SNI — отдельные passthrough-блоки.
nginx_stream_master_rebuild() {
    [[ -f "$NGINX_STREAM" ]] || return 0
    local map_lines="" pass_lines="" row="" id="" port="" listen="" ss="" sni=""
    local rows="" sni_esc=""
    rows="$(sqlite3 "$XUI_DB" "SELECT id, port, listen, replace(stream_settings, char(10), char(32)) FROM inbounds WHERE protocol IN ('vless','vmess','trojan') AND port != ${STREAM_MASTER_PORT:-443};" 2>/dev/null || true)"
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        id="${row%%|*}"; row="${row#*|}"
        port="${row%%|*}"; row="${row#*|}"
        listen="${row%%|*}"; ss="${row#*|}"
        [[ "$listen" != "127.0.0.1" ]] && continue
        # Только TCP (REALITY/TLS+TCP); WS/gRPC идут через http-модуль
        printf '%s' "$ss" | grep -q '"network"[[:space:]]*:[[:space:]]*"tcp"' || continue
        sni=""
        if printf '%s' "$ss" | grep -q '"realitySettings"'; then
            sni="$(printf '%s' "$ss" | sed -n 's/.*"serverNames"[[:space:]]*:[[:space:]]*\[[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
        elif printf '%s' "$ss" | grep -q '"tlsSettings"'; then
            sni="$(printf '%s' "$ss" | sed -n 's/.*"serverName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
        fi
        if [[ -n "$sni" ]]; then
            sni_esc="$(printf '%s' "$sni" | sed 's/[.[\*^$(){}?+|]/\\./g')"
            if ! printf '%s' "$map_lines" | grep -Eq "^    ${sni_esc}[[:space:]]+127\.0\.0\.1:${port};$"; then
                map_lines="${map_lines}    ${sni}  127.0.0.1:${port};
"
            else
                warn "Дубль SNI $sni в БД — в map учтён только один инбаунд (id=$id)."
            fi
        else
            pass_lines="${pass_lines}
# inbound-xray.sh: passthrough без SNI (id=$id, порт ${port})
server {
    listen ${port};
    proxy_pass 127.0.0.1:${port};
}
"
        fi
    done <<< "$rows"

    local tmp bak
    tmp="$(mktemp)"
    bak="$(mktemp)"
    cp -a "$NGINX_STREAM" "$bak" || return 1
    # default → REALITY-инбаунд (при SNI, не совпавшем ни с одним каналом, —
    # это защита от недоверенных хостов); если REALITY-инбаундов нет, панель.
    local real_def="${REALITY_DEFAULT_PORT:-}"
    if [[ -z "$real_def" ]]; then
        real_def="$(sqlite3 "$XUI_DB" "SELECT port FROM inbounds WHERE protocol='vless' AND stream_settings LIKE '%realitySettings%' ORDER BY id LIMIT 1;" 2>/dev/null || true)"
    fi
    [[ -n "$real_def" ]] || real_def="$PANEL_SSL_PORT"
    # Домен панели → http-модуль nginx (панель + WS/gRPC). Без этой строки
    # пересборка мастера теряет панель: её SNI уходил бы в default (REALITY)
    # и браузер получал бы чужой сертификат (ERR_CERT_COMMON_NAME_INVALID).
    local panel_line=""
    if [[ -n "$PANEL_HOST" && -n "$PANEL_SSL_PORT" ]]; then
        local panel_sni_esc
        panel_sni_esc="$(printf '%s' "$PANEL_HOST" | sed 's/[.[\*^$(){}?+|]/\\./g')"
        if ! printf '%s' "$map_lines" | grep -Eq "^    ${panel_sni_esc}[[:space:]]+127\.0\.0\.1:${PANEL_SSL_PORT};$"; then
            panel_line="    ${PANEL_HOST}  127.0.0.1:${PANEL_SSL_PORT};
"
        fi
    fi
    cat > "$tmp" <<EOF
# inbound-xray.sh: stream-443 master (все внешние TLS-потоки идут на ${STREAM_MASTER_PORT:-443})
map \$ssl_preread_server_name \$xui_backend {
${map_lines}${panel_line}    default  127.0.0.1:${real_def};
}

server {
    listen ${STREAM_MASTER_PORT:-443};
    proxy_protocol on;
    set_real_ip_from unix:;
    proxy_pass \$xui_backend;
    ssl_preread on;
}
${pass_lines}
EOF
    if ! cp -a "$tmp" "$NGINX_STREAM"; then
        cp -a "$bak" "$NGINX_STREAM"
        rm -f "$tmp" "$bak"
        return 1
    fi
    if command -v nginx >/dev/null 2>&1 && ! nginx_test_ok; then
        warn "nginx -t не прошёл — откат stream-конфигурации."
        warn "$NGINX_TEST_ERR"
        cp -a "$bak" "$NGINX_STREAM"
        rm -f "$tmp" "$bak"
        return 1
    fi
    rm -f "$tmp" "$bak"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 && ok "nginx (stream-мастер) перезагружен."
    fi
}

# stream_master_apply_proxy_protocol — синхронизирует acceptProxyProtocol инбаундов
# с proxy_protocol stream-мастера. После включения proxy_protocol на 443 nginx шлёт
# PROXY-заголовок ко ВСЕМ tcp-маршрутам мастера: tcp+reality/tls инбаунды с SNI
# обязаны иметь acceptProxyProtocol=true, иначе xray рвёт соединения. Инбаунды без
# SNI (passthrough-блоки на своих портах) — остаются false.
stream_master_apply_proxy_protocol() {
    [[ -f "$NGINX_STREAM" ]] || return 0
    local rows="" row="" id="" ss="" sni="" accept="" cur="" settings="" new_settings=""
    rows="$(sqlite3 "$XUI_DB" "SELECT id, replace(stream_settings, char(10), char(32)) FROM inbounds WHERE protocol IN ('vless','vmess','trojan') AND listen = '127.0.0.1' AND port != ${STREAM_MASTER_PORT:-443};" 2>/dev/null || true)"
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        id="${row%%|*}"; ss="${row#*|}"
        printf '%s' "$ss" | grep -q '"network"[[:space:]]*:[[:space:]]*"tcp"' || continue
        printf '%s' "$ss" | grep -qE '"security"[[:space:]]*:[[:space:]]*"(reality|tls)"' || continue
        sni="$(printf '%s' "$ss" | sed -nE 's/.*"serverNames"[[:space:]]*:[[:space:]]*\[[[:space:]]*"([^"]*)".*/\1/p' | head -1)"
        if [[ -z "$sni" ]]; then
            sni="$(printf '%s' "$ss" | sed -nE 's/.*"serverName"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' | head -1)"
        fi
        if [[ -n "$sni" ]]; then
            accept="true"
        else
            accept="false"
        fi
        cur="$(printf '%s' "$ss" | grep -oE '"acceptProxyProtocol"[[:space:]]*:[[:space:]]*(true|false)' | grep -oE '(true|false)' | head -1)"
        [[ "$cur" == "$accept" ]] && continue
        settings="$(sqlite3 "$XUI_DB" "SELECT stream_settings FROM inbounds WHERE id = $id;" 2>/dev/null || true)"
        if printf '%s' "$settings" | grep -q '"acceptProxyProtocol"'; then
            new_settings="$(printf '%s' "$settings" | sed -E 's/"acceptProxyProtocol"[[:space:]]*:[[:space:]]*(true|false)/"acceptProxyProtocol": '"$accept"'/')"
        else
            new_settings="$(printf '%s' "$settings" | sed 's/"tcpSettings"[[:space:]]*:[[:space:]]*{/"tcpSettings": {\n    "acceptProxyProtocol": '"$accept"',/')"
        fi
        sqlite3 "$XUI_DB" "UPDATE inbounds SET stream_settings = '$(sql_escape "$new_settings")' WHERE id = $id;" \
            || warn "Не удалось обновить acceptProxyProtocol (id=$id)."
        info "acceptProxyProtocol=$accept проставлен для инбаунда id=$id (stream-мастер с proxy_protocol)."
    done <<< "$rows"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active x-ui >/dev/null 2>&1; then
        restart_xui
    fi
}

# nginx_stream_master_setup [auto] — включает режим stream-мастера на 443.
# В режиме auto (автозапуск при старте скрипта) не задаёт вопросов и не
# прерывает скрипт: при любом препятствии предупреждает и возвращает 1
# (скрипт продолжает работу в legacy-режиме).
nginx_stream_master_setup() {
    local auto="$1" soft=""
    [[ "$auto" == "auto" ]] && soft=1
    if ! command -v nginx >/dev/null 2>&1; then
        warn "nginx не установлен — stream-мастер невозможен."
        [[ -n "$soft" ]] && return 1
        die "nginx не установлен — stream-мастер невозможен."
    fi
    if ! nginx_ensure_files; then
        warn "Не удалось подготовить файлы nginx."
        [[ -n "$soft" ]] && return 1
        die "Не удалось подготовить файлы nginx."
    fi
    if ! nginx_stream_context_enable; then
        warn "Не удалось подключить stream-контекст."
        [[ -n "$soft" ]] && return 1
        die "Не удалось подключить stream-контекст."
    fi
    if ! stream_ssl_preread_ok; then
        warn "В nginx нет модуля stream_ssl_preread (нужен nginx-full/extra)."
        [[ -n "$soft" ]] && return 1
        die "В nginx нет модуля stream_ssl_preread (нужен nginx-full/extra)."
    fi
    if port_in_use "${STREAM_MASTER_PORT:-443}" tcp && ! is_stream_443_master; then
        warn "Порт ${STREAM_MASTER_PORT:-443} занят другим процессом."
        if [[ -n "$soft" ]]; then
            warn "Продолжаем без stream-мастера (инбаунды будут на своих портах)."
            return 1
        fi
        confirm "Продолжить (порт будет перехвачен nginx)?" || return 1
    fi
    if [[ "$PANEL_PORT" == "${STREAM_MASTER_PORT:-443}" ]]; then
        warn "Панель слушает на 443. Перенеси её на внутренний порт:"
        warn "  x-ui setting -port 2053 && systemctl restart x-ui"
        [[ -n "$soft" ]] && return 1
        die "Невозможно занять 443 для stream-мастера."
    fi
    if [[ -z "$PANEL_SSL_PORT" ]]; then
        PANEL_SSL_PORT="8443"
    fi
    if port_in_use "$PANEL_SSL_PORT" tcp; then
        local alt=""
        if ! next_free_port alt tcp 8500 8999; then
            warn "Нет свободного внутреннего порта."
            [[ -n "$soft" ]] && return 1
            die "Нет свободного внутреннего порта."
        fi
        PANEL_SSL_PORT="$alt"
    fi
    info "Внутренний https-порт nginx (панель + WS/gRPC): 127.0.0.1:${PANEL_SSL_PORT}"
    if [[ "$PROXY_SCHEME" == "https" && -n "$PANEL_CERT" ]]; then
        info "Используется сертификат панели: $PANEL_CERT"
    else
        warn "Сертификат панели не найден — внешние клиенты не смогут проверить цепочку."
    fi

    STREAM_443_MASTER=1
    nginx_stream_master_rebuild || { STREAM_443_MASTER=""; return 1; }
    stream_master_apply_proxy_protocol || true

    local conf="$NGINX_CONF"
    if [[ -z "$conf" || ! -f "$conf" ]]; then
        detect_nginx_conf
        conf="$NGINX_CONF"
    fi
    [[ -z "$conf" || ! -f "$conf" ]] && conf="/etc/nginx/conf.d/x-ui.conf"
    local mode="panel"
    [[ -n "$ENABLE_LANDING" ]] && mode="landing"
    write_panel_conf "$conf" "$mode" || { STREAM_443_MASTER=""; return 1; }

    # Порт в hosts-записях TLS/REALITY за прокси → 443
    if db_has_column hosts port; then
        sqlite3 "$XUI_DB" "UPDATE hosts SET port = ${STREAM_MASTER_PORT:-443} WHERE inbound_id IN (SELECT id FROM inbounds WHERE protocol IN ('vless','vmess','trojan') AND listen = '127.0.0.1');" 2>/dev/null || true
    fi

    PROXY_PORT="${STREAM_MASTER_PORT:-443}"
    PROXY_SCHEME="https"
    firewall_port_open "${STREAM_MASTER_PORT:-443}" tcp
    ok "Всё внешнее трафик теперь через ${STREAM_MASTER_PORT:-443} (stream-мастер)."
    ok "Панель доступна: https://${PANEL_HOST:-$(external_addr)}${PANEL_PATH:-/}"
}

# nginx_stream_rebuild_legacy — пересобирает NGINX_STREAM в классическом режиме
# (без мастера): отдельный server listen <порт> на каждый TLS/REALITY инбаунд
# за nginx. Используется при удалении инбаундов, чтобы не оставлять «хвосты».
nginx_stream_rebuild_legacy() {
    [[ -f "$NGINX_STREAM" ]] || return 0
    local blocks="" row="" port="" listen="" ss="" tmp bak
    local rows=""
    rows="$(sqlite3 "$XUI_DB" "SELECT port, listen, replace(stream_settings, char(10), char(32)) FROM inbounds WHERE protocol IN ('vless','vmess','trojan') AND listen = '127.0.0.1' AND port != ${STREAM_MASTER_PORT:-443};" 2>/dev/null || true)"
    while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        port="${row%%|*}"; row="${row#*|}"
        listen="${row%%|*}"; ss="${row#*|}"
        if ! printf '%s' "$ss" | grep -Eq '"network"[[:space:]]*:[[:space:]]*"tcp"'; then
            continue
        fi
        if ! printf '%s' "$ss" | grep -Eq '"tlsSettings"|"realitySettings"'; then
            continue
        fi
        blocks="${blocks}

# inbound-xray.sh: stream-passthrough порт ${port}
server {
    listen ${port};
    proxy_pass 127.0.0.1:${port};
}
"
    done <<< "$rows"
    tmp="$(mktemp)"; bak="$(mktemp)"
    cp -a "$NGINX_STREAM" "$bak" || return 1
    cat > "$tmp" <<EOF
# inbound-xray.sh: stream-passthrough правила (собрано из БД панели)
${blocks}
EOF
    if ! cp -a "$tmp" "$NGINX_STREAM"; then
        cp -a "$bak" "$NGINX_STREAM"
        rm -f "$tmp" "$bak"
        return 1
    fi
    if command -v nginx >/dev/null 2>&1 && ! nginx_test_ok; then
        warn "nginx -t не прошёл — откат stream-конфигурации."
        warn "$NGINX_TEST_ERR"
        cp -a "$bak" "$NGINX_STREAM"
        rm -f "$tmp" "$bak"
        return 1
    fi
    rm -f "$tmp" "$bak"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 && ok "nginx (stream) перезагружен."
    fi
}

# channel_name_label <протокол> <транспорт> <security> <внешний_порт> —
# краткая метка инбаунда: VLESS-REALITY-443, VLESS-TCP-TLS-443, TROJAN-WS-443,
# VLESS-KCP-10004 и т.п. Внешний порт 443 означает, что инбаунд за прокси.
channel_name_label() {
    local p="$1" t="$2" s="$3" port="$4" marker=""
    case "$t" in
        tcp)
            case "$s" in
                reality) marker="REALITY" ;;
                tls)     marker="TCP-TLS" ;;
                *)       marker="TCP" ;;
            esac ;;
        ws) marker="WS" ;;
        grpc) marker="GRPC" ;;
        xhttp) marker="XHTTP" ;;
        httpupgrade) marker="HTTPUPGRADE" ;;
        kcp) marker="KCP" ;;
        hysteria) marker="HYSTERIA" ;;
        quic) marker="QUIC" ;;
        *) marker="${t^^}" ;;
    esac
    printf '%s-%s-%s\n' "${p^^}" "$marker" "$port"
}

# channel_default_ext_port <транспорт> <security> — внешний порт для имени по
# умолчанию: 443 если инбаунд будет за прокси, иначе фактический PORT.
channel_default_ext_port() {
    local t="$1" s="$2"
    case "$t" in
        ws|grpc|xhttp|httpupgrade)
            command -v nginx >/dev/null 2>&1 && printf '443' || printf '%s' "$PORT" ;;
        tcp)
            if [[ "$STREAM_443_MASTER" == "1" && ( "$s" == "tls" || "$s" == "reality" ) ]]; then
                printf '443'
            else
                printf '%s' "$PORT"
            fi ;;
        *) printf '%s' "$PORT" ;;
    esac
}

# delete_channel — меню удаления инбаунда из панели (БД + nginx + firewall).
delete_channel() {
    local rows=""
    rows="$(sqlite3 "$XUI_DB" "SELECT id, remark, port, protocol, replace(COALESCE(stream_settings,''),char(10),char(32)), COALESCE(listen,'') FROM inbounds ORDER BY id;" 2>/dev/null || true)"
    if [[ -z "$rows" ]]; then
        info "Инбаундов в панели нет."
        return 0
    fi
    banner "  ========== Инбаунды панели =========="
    local list=() i=1 id="" remark="" port="" proto="" stream="" listen="" tran="" sec="" extp="" rest="" sel="" del_id="" del_remark="" del_port="" del_proto=""
    while IFS= read -r line; do
        id="${line%%|*}"; rest="${line#*|}"
        remark="${rest%%|*}"; rest="${rest#*|}"
        port="${rest%%|*}"; rest="${rest#*|}"
        proto="${rest%%|*}"; rest="${rest#*|}"
        stream="${rest%%|*}"; listen="${rest#*|}"
        tran="$(json_extract "$stream" network)"
        sec="$(json_extract "$stream" security)"
        if [[ "$listen" == "127.0.0.1" ]]; then extp="443"; else extp="$port"; fi
        list+=("$id|$remark|$port|$proto")
        echo "  $i) id=$id  $(channel_name_label "$proto" "$tran" "$sec" "$extp")  $remark"
        i=$((i + 1))
    done <<< "$rows"
    # Ввод одного или нескольких номеров через запятую и/или диапазоны
    # (2 или 2,5,7 или 2-5). Пустой ввод или 0 — отмена.
    read -r -p "Номер(а) инбаунда(ов) через запятую/диапазон, напр. 2 или 2,5,7 или 2-5 (0 — отмена): " sel || return 0
    sel="$(printf '%s' "$sel" | tr -d ' ')"
    [[ -n "$sel" && "$sel" != "0" ]] || return 0
    # Разбор токенов (число или N-M) в уникальные номера списка
    local picks=() tokens=() tok="" m="" n="" nn="" dup="" k="" r=""
    IFS=',' read -ra tokens <<< "$sel"
    for tok in "${tokens[@]}"; do
        if [[ "$tok" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            m="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[2]}"
            if (( m > n )); then
                warn "Неверный диапазон «$tok»."
                return 0
            fi
            for (( nn = m; nn <= n; nn++ )); do
                if (( nn < 1 || nn > ${#list[@]} )); then
                    warn "Номер $nn вне списка (1-${#list[@]})."
                    return 0
                fi
                dup=0
                for k in "${picks[@]}"; do [[ "$k" == "$nn" ]] && dup=1; done
                (( dup )) || picks+=("$nn")
            done
        elif [[ "$tok" =~ ^[0-9]+$ ]]; then
            if (( tok < 1 || tok > ${#list[@]} )); then
                warn "Номер $tok вне списка (1-${#list[@]})."
                return 0
            fi
            dup=0
            for k in "${picks[@]}"; do [[ "$k" == "$tok" ]] && dup=1; done
            (( dup )) || picks+=("$tok")
        else
            warn "Некорректный ввод «$tok» — ожидаются номера/диапазоны через запятую."
            return 0
        fi
    done
    (( ${#picks[@]} > 0 )) || return 0
    # Список удаляемых (id|remark|port|proto) + текст подтверждения
    local del_records=() desc="" id="" remark="" port="" proto=""
    for nn in "${picks[@]}"; do
        r="${list[$((nn - 1))]}"
        del_records+=("$r")
        IFS='|' read -r id remark port proto <<< "$r"
        if [[ -n "$desc" ]]; then desc="$desc, "; fi
        desc="$desc#$id «$remark» (${proto}:${port})"
    done
    if ! confirm "Удалить инбаунды: $desc?"; then
        info "Отменено."
        return 0
    fi
    # Удаление всех выбранных + сбор правил firewall (только существующие,
    # только по фактическому протоколу tcp/udp, без дублей).
    local fw_rules=() del_id="" del_remark="" del_port="" del_proto=""
    local del_ss="" del_listen="" del_cproto="tcp" del_remove=0 fw="" fdup=0 f2=""
    for r in "${del_records[@]}"; do
        IFS='|' read -r del_id del_remark del_port del_proto <<< "$r"
        del_cproto="tcp"; del_remove=0
        del_ss="$(sqlite3 "$XUI_DB" "SELECT replace(COALESCE(stream_settings,''),char(10),char(32)) FROM inbounds WHERE id=$del_id;" 2>/dev/null || true)"
        del_listen="$(sqlite3 "$XUI_DB" "SELECT COALESCE(listen,'') FROM inbounds WHERE id=$del_id;" 2>/dev/null || true)"
        case "$del_proto" in
            hysteria*|wireguard) del_cproto="udp" ;;
        esac
        printf '%s' "$del_ss" | grep -Eq '"network"[[:space:]]*:[[:space:]]*"kcp"' && del_cproto="udp"
        # Через 443 идут инбаунды за nginx с http-транспортом (ws/grpc/xhttp/
        # httpupgrade) — для них правило не создавалось, удалять нечего.
        if [[ "$del_listen" != "127.0.0.1" ]]; then
            del_remove=1
        elif printf '%s' "$del_ss" | grep -Eq '"network"[[:space:]]*:[[:space:]]*"tcp"'; then
            # tcp+reality/tls за nginx в legacy слушал свой passthrough-порт
            del_remove=1
        fi
        db_delete_inbound "$del_id"
        if [[ "$del_remove" == "1" ]]; then
            fw="$del_port|$del_cproto"
            fdup=0
            for f2 in "${fw_rules[@]}"; do [[ "$f2" == "$fw" ]] && fdup=1; done
            (( fdup )) || fw_rules+=("$fw")
        fi
    done
    if [[ "$STREAM_443_MASTER" == "1" ]]; then
        nginx_stream_master_rebuild
    else
        nginx_stream_rebuild_legacy
    fi
    for fw in "${fw_rules[@]}"; do
        IFS='|' read -r del_port del_cproto <<< "$fw"
        firewall_port_remove "$del_port" "$del_cproto" 2>/dev/null || true
    done
    restart_xui
    ok "Инбаунды удалены: $desc."
}

# =============================================================================
# Сводка
# =============================================================================

print_summary() {
    banner ""
    banner "  ========== Итоги: инбаунд «${REMARK}» =========="
    banner "  Метка: $(channel_name_label "$PROTOCOL" "$TRANSPORT" "$SECURITY" "$(channel_default_ext_port "$TRANSPORT" "$SECURITY")")"
    banner "  Протокол: ${PROTOCOL}  Транспорт: ${TRANSPORT}  Безопасность: ${SECURITY}"
    banner "  Порт: ${PORT}   Слушает: ${LISTEN:-0.0.0.0}"
    [[ -n "$INBOUND_ID" ]] && banner "  ID inbound в панели: ${INBOUND_ID}"
    banner ""

    local link=""
    case "$PROTOCOL" in
        vless)       link="$(gen_link_vless)" ;;
        vmess)       link="$(gen_link_vmess)" ;;
        trojan)      link="$(gen_link_trojan)" ;;
        hysteria)    link="$(gen_link_hysteria2)" ;;
        wireguard)   link="$(gen_link_wireguard)" ;;
        mtproto)     link="$(gen_link_mtproto)" ;;
    esac
    if [[ -n "$link" ]]; then
        printf '%s\n' "  ${C_GREEN}Ссылка для клиента:${C_RESET}"
        printf '%s\n' "  $link"
        printf '%s\n' "  (дублируется в $LOG_FILE)"
        printf '%s\n' "$link" >> "$LOG_FILE"
    fi

    case "$PROTOCOL" in
        http|mixed)
            printf '%s\n' "  ${C_GREEN}Учётная запись:${C_RESET} логин ${ACCOUNT_USER:-$(gen_password 10)} / пароль ${ACCOUNT_PASS:-$(gen_password 20)}"
            printf 'Логин: %s Пароль: %s\n' "${ACCOUNT_USER:-}" "${ACCOUNT_PASS:-}" >> "$LOG_FILE"
            ;;
        wireguard)
            printf '%s\n' "  PrivateKey клиента: $CLIENT_PRIV (в ссылке)"
            ;;
    esac

    [[ "$SECURITY" == "tls" ]] && printf '%s\n' "  Сертификат: ${PANEL_CERT:-self-signed}"
    [[ "$SECURITY" == "reality" ]] && {
        printf '%s\n' "  REALITY: publicKey=${REALITY_PUBLIC_KEY} shortId=${REALITY_SHORT_ID} serverName=${REALITY_SNI}"
    }
    if [[ "$SUB_ENABLE" == "true" && -n "$CLIENT_SUBID" ]]; then
        printf '%s\n' "  ${C_GREEN}Подписка (Sub URL):${C_RESET} $(sub_url "$CLIENT_SUBID")"
        printf 'Sub URL: %s\n' "$(sub_url "$CLIENT_SUBID")" >> "$LOG_FILE"
    fi
    banner ""
    info "Инбаунд создан. Панель: x-ui → «Список inbound» (id ${INBOUND_ID:-?})."
}

# =============================================================================
# Заглушка (landing) и данные панели
# =============================================================================

# external_url <путь> — внешний URL панели/подписки: через nginx-прокси, если он
# есть, иначе напрямую к панели. Порт опускается при стандартной схеме.
external_url() {
    local path="${1:-}" host=""
    host="$(external_addr)"
    local scheme="$PROXY_SCHEME" port="$PROXY_PORT"
    if [[ -z "$port" ]]; then
        scheme="$PANEL_PROTO"; port="$PANEL_PORT"
    fi
    local url="${scheme}://${host}"
    if ! { [[ "$scheme" == "https" && "$port" == "443" ]] || [[ "$scheme" == "http" && "$port" == "80" ]]; }; then
        url="${url}:${port}"
    fi
    if [[ -n "$path" ]]; then
        url="${url}/${path#/}"
        url="${url%/}"
    fi
    printf '%s' "$url"
}

# gen_landing_html <название сайта> — генерирует нейтральную заглушку.
gen_landing_html() {
    local title="$1"
    mkdir -p "$LANDING_DIR"
    cat > "$LANDING_INDEX" <<EOF
<!DOCTYPE html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<style>
  body { margin:0; font-family: -apple-system, 'Segoe UI', Roboto, Arial, sans-serif;
         background: linear-gradient(160deg, #0f172a 0%, #1e293b 100%); color:#e2e8f0;
         min-height:100vh; display:flex; align-items:center; justify-content:center; text-align:center; }
  .card { padding:40px; }
  h1 { font-size: 2.2em; margin: 0 0 12px; color:#fff; }
  p  { color:#94a3b8; font-size: 1.05em; line-height:1.6; margin: 0; }
</style>
</head>
<body>
  <div class="card">
    <h1>${title}</h1>
    <p>Соединение защищено. Сервис доступен авторизованным пользователям.</p>
  </div>
</body>
</html>
EOF
    chmod 644 "$LANDING_INDEX"
}

# set_panel_base_path <путь|""> — меняет webBasePath панели через x-ui setting.
set_panel_base_path() {
    local raw="${1#/}"
    raw="${raw%/}"
    if [[ -z "$raw" ]]; then
        PANEL_PATH=""
    else
        PANEL_PATH="/${raw}/"
    fi
    "$XUI_BIN" setting -webBasePath "$raw" >/dev/null 2>&1 \
        || die "Не удалось изменить webBasePath панели."
    restart_xui
    info "webBasePath панели установлен: ${PANEL_PATH:-/}"
}

# write_panel_conf <файл> <landing|panel> — переписывает nginx-конфиг панели
# (location /<путь>/ → proxy_pass; location / → заглушка или панель) с бэкапом
# и откатом при ошибке nginx -t.
write_panel_conf() {
    local file="$1" mode="$2"
    local listen_dir="    listen ${PROXY_PORT};"
    local ssl_lines=""
    if [[ "$STREAM_443_MASTER" == "1" ]]; then
        listen_dir="    listen 127.0.0.1:${PANEL_SSL_PORT} ssl http2 proxy_protocol;"
        if [[ -n "$PANEL_CERT" && -n "$PANEL_CERT_KEY" ]]; then
            ssl_lines="    ssl_certificate     ${PANEL_CERT};
    ssl_certificate_key ${PANEL_CERT_KEY};"
        fi
    elif [[ "$PROXY_SCHEME" == "https" && -n "$PANEL_CERT" && -n "$PANEL_CERT_KEY" ]]; then
        listen_dir="    listen ${PROXY_PORT} ssl http2;"
        ssl_lines="    ssl_certificate     ${PANEL_CERT};
    ssl_certificate_key ${PANEL_CERT_KEY};"
    fi
    local up_extra=""
    if [[ "$PANEL_PROTO" == "https" ]]; then
        up_extra="        proxy_ssl_verify off;
        proxy_ssl_server_name off;"
    fi

    local sub_loc=""
    if [[ "$SUB_ENABLE" == "true" && -n "$SUB_PORT" ]]; then
        local sub_loc_path="${SUB_PATH:-/sub/}"
        [[ "$sub_loc_path" == /* ]] || sub_loc_path="/${sub_loc_path}"
        [[ "$sub_loc_path" == */ ]] || sub_loc_path="${sub_loc_path}/"
        sub_loc="    location ${sub_loc_path} {
        proxy_pass http://127.0.0.1:${SUB_PORT};
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

"
    fi

    local panel_loc=""
    if [[ "$mode" == "landing" && -n "$PANEL_PATH" ]]; then
        panel_loc="    location ${PANEL_PATH} {
        proxy_pass ${PANEL_PROTO}://127.0.0.1:${PANEL_PORT};
${up_extra}
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

"
    fi

    local root_loc=""
    if [[ "$mode" == "landing" ]]; then
        root_loc="    location / {
        root ${LANDING_DIR};
        index index.html;
    }"
    else
        root_loc="    location / {
        proxy_pass ${PANEL_PROTO}://127.0.0.1:${PANEL_PORT};
${up_extra}
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_http_version 1.1;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }"
    fi

    local bak
    bak="$(mktemp)"
    [[ -f "$file" ]] && cp -a "$file" "$bak"
    mkdir -p "$(dirname "$file")" || { warn "Не удалось создать каталог $(dirname "$file")."; return 1; }
    # WS/gRPC regex-location'ы живут в общем сниппете — подключаем его в server
    nginx_ensure_files
    local snippet_line="    include ${NGINX_SNIPPET};"
    cat > "$file" <<EOF
server {
${listen_dir}
${ssl_lines}
    server_name _;
${snippet_line}

${panel_loc}${sub_loc}${root_loc}
}
EOF
    if command -v nginx >/dev/null 2>&1 && ! nginx -t >/dev/null 2>&1; then
        warn "nginx -t не прошёл — откат конфигурации."
        if [[ -f "$bak" ]]; then cp -a "$bak" "$file"; else rm -f "$file"; fi
        return 1
    fi
    rm -f "$bak"
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active nginx >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || true
    fi
    ok "nginx-конфиг обновлён: $file"
}

# setup_landing — включает заглушку: панель на своём пути, корень → сайт.
setup_landing() {
    # nginx обязателен
    if ! command -v nginx >/dev/null 2>&1; then
        if confirm "nginx не установлен. Установить и настроить прокси панели?"; then
            info "Устанавливаем nginx..."
            install_pkg "$(nginx_pkg)" || die "Не удалось установить nginx."
            command -v nginx >/dev/null 2>&1 || die "nginx не установился."
            systemctl enable nginx >/dev/null 2>&1 || true
        else
            warn "Заглушка требует nginx. Отмена."
            return 1
        fi
    fi

    # Путь панели: если корень — переносим на случайный /<путь>/
    info "Текущий путь панели (webBasePath): ${PANEL_PATH:-/}"
    if [[ -z "$PANEL_PATH" || "$PANEL_PATH" == "/" || "$PANEL_PATH" == "./" ]]; then
        local new_path=""
        ask "Путь панели (Enter — случайный)" "$(gen_panel_path)" new_path
        set_panel_base_path "$new_path"
    else
        info "Панель уже на пути ${PANEL_PATH} — заглушка займёт корень."
    fi

    # Внешний порт прокси
    if [[ -z "$PROXY_PORT" ]]; then
        if is_stream_443_master; then
            PROXY_PORT="${STREAM_MASTER_PORT:-443}"
            PROXY_SCHEME="https"
        elif [[ -n "$NGINX_CONF" && -f "$NGINX_CONF" ]]; then
            PROXY_PORT="$(grep -Eo 'listen[[:space:]]+[0-9]+' "$NGINX_CONF" | awk '{print $2}' | head -1)"
            grep -Eqs 'listen[[:space:]]+[0-9]+[[:space:]]+[^;]*ssl' "$NGINX_CONF" && PROXY_SCHEME="https"
        else
            PROXY_PORT="80"
            [[ "$PANEL_PROTO" == "https" ]] && PROXY_PORT="443"
            if [[ "$PROXY_PORT" == "443" && -n "$PANEL_CERT" ]]; then
                PROXY_SCHEME="https"
            fi
        fi
    fi

    # Название сайта и конфиг
    local site_title=""
    ask "Название сайта для заглушки" "$(external_addr)" site_title
    gen_landing_html "$site_title"

    local conf="$NGINX_CONF"
    if [[ -z "$conf" || ! -f "$conf" ]]; then
        conf="/etc/nginx/conf.d/x-ui.conf"
        NGINX_CONF="$conf"
    fi
    write_panel_conf "$conf" landing || return 1

    firewall_port_open "$PROXY_PORT" tcp
    ENABLE_LANDING=1
    ok "Заглушка включена. Панель теперь: $(external_url "$PANEL_PATH")"
    print_panel_data
}

# disable_landing — возвращает панель на корневой адрес.
# Путь панели (webBasePath) при этом НЕ меняется — адрес панели остаётся
# скрытым (раньше set_panel_base_path "" возвращал панель на корень, из-за
# чего при повторном включении заглушки снова спрашивался путь панели).
disable_landing() {
    local conf="$NGINX_CONF"
    if [[ -z "$conf" || ! -f "$conf" ]]; then
        detect_nginx_conf
        conf="$NGINX_CONF"
    fi
    [[ -z "$conf" || ! -f "$conf" ]] && conf="/etc/nginx/conf.d/x-ui.conf"
    write_panel_conf "$conf" panel || return 1
    ENABLE_LANDING=""
    ok "Заглушка отключена. Панель: $(external_url "$PANEL_PATH")"
}

# print_panel_data — повторный вывод данных панели (логин, пароль, адрес, токен).
print_panel_data() {
    banner ""
    banner "  ========== Данные панели 3x-ui =========="
    printf '%s\n' "  Username:    ${PANEL_USERNAME:-не определено}"
    printf '%s\n' "  Password:    ${PANEL_PASSWORD:-не определено}"
    printf '%s\n' "  Port:        ${PANEL_PORT}"
    printf '%s\n' "  WebBasePath: ${PANEL_PATH:-/}"
    printf '%s\n' "  Access URL:  $(external_url "$PANEL_PATH")"
    printf '%s\n' "  API Token:   ${PANEL_TOKEN:-не определено}"
    banner ""
}

# =============================================================================
# Подписка пользователя (/sub/)
# =============================================================================

# db_set_setting <ключ> <значение> — upsert настройки панели в таблице settings.
db_set_setting() {
    local key="$1" value="$2"
    if sqlite3 "$XUI_DB" "SELECT 1 FROM settings WHERE key = '$(sql_escape "$key")' LIMIT 1;" | grep -q 1; then
        sqlite3 "$XUI_DB" "UPDATE settings SET value = '$(sql_escape "$value")' WHERE key = '$(sql_escape "$key")';" \
            || die "Ошибка обновления настройки $key."
    else
        sqlite3 "$XUI_DB" "INSERT INTO settings (key, value) VALUES ('$(sql_escape "$key")', '$(sql_escape "$value")');" \
            || die "Ошибка вставки настройки $key."
    fi
}

# db_add_host_record <inbound_id> — запись в таблицу hosts для инбаундов за прокси.
# Внешний адрес/порт/sni/path подставляются в ссылки подписки автоматически.
db_add_host_record() {
    local inbound_id="$1"
    local hport="" sec=""
    case "$TRANSPORT" in
        ws|grpc|xhttp|httpupgrade) hport="$PROXY_PORT" ;;
        tcp)
            # Проксируются только TLS (passthrough) и REALITY (stream-SNI)
            case "$SECURITY" in
                tls|reality)
                    if [[ "$STREAM_443_MASTER" == "1" ]]; then
                        hport="${STREAM_MASTER_PORT:-443}"
                    else
                        hport="$PORT"
                    fi
                    ;;
                *) return 0 ;;
            esac
            ;;
        *) return 0 ;;
    esac
    sec="$SECURITY"
    local addr sni path
    # за nginx: адрес/SNI = домен, security=tls (как в эталоне)
    if [[ -n "$USE_NGINX" ]] && [[ "$TRANSPORT" == "ws" || "$TRANSPORT" == "grpc" || "$TRANSPORT" == "xhttp" || "$TRANSPORT" == "httpupgrade" ]]; then
        addr="${PANEL_HOST:-$(external_addr)}"
        sec="tls"
        sni="$addr"
    else
        addr="$(external_addr)"
        sni="${SNI:-$addr}"
    fi
    path=""
    [[ -n "$WS_PATH" ]] && path="$WS_PATH"
    sqlite3 "$XUI_DB" "INSERT INTO hosts
        (inbound_id, sort_order, remark, is_disabled, address, port, security, sni, path, created_at, updated_at)
      VALUES
        ($inbound_id, 0, '$(sql_escape "$REMARK")', 0, '$(sql_escape "$addr")', $hport,
         '$(sql_escape "$sec")', '$(sql_escape "$sni")', '$(sql_escape "$path")',
         $(date +%s000), $(date +%s000));" \
        || warn "Не удалось добавить запись hosts для инбаунда (подписка может давать неверные адреса)."
}

# sub_url <subId> — URL подписки: через nginx или напрямую на суб-порт.
sub_url() {
    local subid="$1"
    local sub_path="${SUB_PATH:-/sub/}"
    [[ "$sub_path" == /* ]] || sub_path="/${sub_path}"
    [[ "$sub_path" == */ ]] || sub_path="${sub_path}/"
    if [[ -n "$NGINX_CONF" && -f "$NGINX_CONF" ]]; then
        printf '%s%s%s' "$(external_url "")" "$sub_path" "$subid"
    else
        printf '%s://%s:%s%s%s' "$PANEL_PROTO" "$(external_addr)" "$SUB_PORT" "$sub_path" "$subid"
    fi
}

# setup_subscription — включает подписку: настройки панели, nginx /sub/, firewall.
setup_subscription() {
    local base ext
    if [[ -n "$NGINX_CONF" && -f "$NGINX_CONF" ]]; then
        base="$(external_url "")"
        ext="$(external_addr)"
        # TLS терминирует nginx: суб-сервер остаётся на локальном HTTP,
        # адрес слушания — только loopback.
        nginx_ensure_files
        nginx_stream_context_enable
        db_set_setting "subListen" "127.0.0.1"
        db_set_setting "subCertFile" ""
        db_set_setting "subKeyFile" ""
    else
        base="$PANEL_PROTO://$(external_addr)"
        ext="$(external_addr)"
    fi
    db_set_setting "subEnable" "true"
    db_set_setting "subDomain" "$ext"
    db_set_setting "subURI" "$base${SUB_PATH:-/sub/}"
    SUB_ENABLE="true"

    local mode="panel"
    [[ -n "$ENABLE_LANDING" ]] && mode="landing"
    if [[ -n "$NGINX_CONF" && -f "$NGINX_CONF" ]]; then
        write_panel_conf "$NGINX_CONF" "$mode" || die "Не удалось обновить nginx-конфиг."
    else
        firewall_port_open "$SUB_PORT" "tcp"
    fi

    # Панель читает настройки подписки при старте — нужен перезапуск.
    restart_xui

    banner ""
    banner "  ========== Подписка пользователя включена =========="
    printf '%s\n' "  Sub URL:     $(sub_url "${CLIENT_SUBID:-<subId>}")"
    printf '%s\n' "  Sub Domain:  $ext"
    banner ""
    if [[ -n "$CLIENT_SUBID" ]]; then
        ok "Ссылка текущего инбаунда: $(sub_url "$CLIENT_SUBID")"
    fi
}

# =============================================================================
# Создание одного инбаунда (от выбора протокола до сводки)
# =============================================================================

create_channel() {
    # Сброс данных предыдущего клиента
    CLIENT_EMAIL=""; CLIENT_SUBID=""; CLIENT_FLOW=""
    CLIENT_ID=""; CLIENT_PW=""; CLIENT_AUTH=""
    CLIENT_PRIV=""; CLIENT_PUB=""; CLIENT_SECRET=""
    ACCOUNT_USER=""; ACCOUNT_PASS=""
    INBOUND_ID=""; WS_PATH=""; WS_HOST=""; SNI=""; LISTEN=""
    REALITY_PRIVATE_KEY=""; REALITY_PUBLIC_KEY=""; REALITY_SHORT_ID=""; REALITY_SNI=""
    CHANNEL_SNI=""; CHANNEL_CERT_DIR=""; REUSE_CLIENT=""; EXISTING_CLIENT_ID=""; CLIENT_SELECT=""

    menu_protocol

    # Протокол порта (UDP для hysteria/wireguard и транспорта kcp)
    case "$PROTOCOL" in
        hysteria*|wireguard) CHANNEL_PROTO="udp" ;;
        *) CHANNEL_PROTO="tcp" ;;
    esac
    [[ "$TRANSPORT" == "kcp" ]] && CHANNEL_PROTO="udp"
    if [[ "$TRANSPORT" == "xhttp" ]]; then
        # XHTTP в эталоне слушает на unix-сокете (port=0 в БД) — nginx
        # grpc_pass grpc://unix:... проксирует на сокет.
        PORT=0
    else
        pick_port PORT "$CHANNEL_PROTO"
    fi

    # Remark и клиент
    local def_remark def_email def_subid
    def_remark="$(channel_name_label "$PROTOCOL" "$TRANSPORT" "$SECURITY" "$(channel_default_ext_port "$TRANSPORT" "$SECURITY")")"
    while true; do
        ask "Наименование инбаунда (remark)" "$def_remark" REMARK
        if db_remark_in_use "$REMARK"; then
            warn "Инбаунд с наименованием «$REMARK» уже существует."
            confirm "Продолжить с тем же именем?" || continue
        fi
        break
    done

    def_email="user-$(gen_hex 3)"
    def_subid="$(gen_hex 8)"
    EXISTING_CLIENT_ID=""
    if [[ "$PROTOCOL" != "http" && "$PROTOCOL" != "mixed" ]]; then
        # Существующие клиенты панели — предложить выбрать одного или создать нового
        local rows=() i="" row="" cid="" cemail="" cproto=""
        while true; do
            mapfile -t rows < <(db_list_clients)
            if (( ${#rows[@]} == 0 )); then
                break
            fi
            banner "Существующие клиенты панели:"
            i=1
            for row in "${rows[@]}"; do
                IFS='|' read -r cid cemail cproto <<< "$row"
                if [[ -n "$cproto" ]]; then
                    echo "  $i) $cemail ($cproto)"
                else
                    echo "  $i) $cemail"
                fi
                i=$((i + 1))
            done
            echo "  0) Создать нового клиента"
            ask "Выберите клиента (номер, 0 — новый)" "0" CLIENT_SELECT
            if [[ -z "$CLIENT_SELECT" || "$CLIENT_SELECT" == "0" ]]; then
                CLIENT_SELECT=""
                break
            fi
            if ! [[ "$CLIENT_SELECT" =~ ^[0-9]+$ ]] || (( CLIENT_SELECT > ${#rows[@]} )); then
                warn "Некорректный номер — выберите из списка."
                continue
            fi
            row="${rows[$((CLIENT_SELECT - 1))]}"
            IFS='|' read -r cid cemail cproto <<< "$row"
            if [[ -n "$cproto" && "$cproto" != "$PROTOCOL" ]]; then
                warn "Клиент «$cemail» используется в инбаундах: $cproto (нужен $PROTOCOL)."
                warn "Переиспользование возможно только при совпадении протокола."
                continue
            fi
            CLIENT_EMAIL="$cemail"
            EXISTING_CLIENT_ID="$cid"
            CLIENT_SELECT=""
            break
        done
    fi
    if [[ -z "$EXISTING_CLIENT_ID" ]]; then
        # Новый клиент: email уникален — проверить, что его ещё нет в базе
        while true; do
            ask "Email клиента" "$def_email" CLIENT_EMAIL
            [[ -n "$CLIENT_EMAIL" ]] || die "Email клиента обязателен."
            local dup=""
            dup="$(sqlite3 "$XUI_DB" "SELECT id FROM clients WHERE email = '$(sql_escape "$CLIENT_EMAIL")' LIMIT 1;" 2>/dev/null || true)"
            if [[ -n "$dup" ]]; then
                warn "Клиент «$CLIENT_EMAIL» уже есть в списке выше — выберите его номер или введите другой email."
                def_email="user-$(gen_hex 3)"
                continue
            fi
            break
        done
        ask "Идентификатор подписки (subId)" "$def_subid" CLIENT_SUBID
    fi

    # Данные клиента: при переиспользовании берём существующие (не генерируем)
    if [[ -n "$EXISTING_CLIENT_ID" ]]; then
        load_existing_client "$EXISTING_CLIENT_ID"
        REUSE_CLIENT=1
        info "Клиент «$CLIENT_EMAIL» уже существует — переиспользуем его данные."
    else
        make_client_data "$PROTOCOL" "$CLIENT_EMAIL" "$CLIENT_SUBID" "$CLIENT_FLOW"
    fi
    # XTLS Vision совместим только с tcp+reality/tls. Для всех остальных
    # комбинаций flow принудительно сбрасывается (иначе сервер молча рвёт
    # соединение), в т.ч. при переиспользовании клиента с vision-инбаундом.
    case "$TRANSPORT" in
        ws|grpc|xhttp|httpupgrade)
            [[ -n "$CLIENT_FLOW" ]] && info "flow сброшен для $TRANSPORT (Vision несовместим)."
            CLIENT_FLOW=""
            ;;
        tcp)
            if [[ "$SECURITY" != "reality" && "$SECURITY" != "tls" ]]; then
                [[ -n "$CLIENT_FLOW" ]] && info "flow сброшен для tcp+$SECURITY (Vision только на tcp+reality/tls)."
                CLIENT_FLOW=""
            fi
            ;;
    esac
    if [[ "$PROTOCOL" == "http" || "$PROTOCOL" == "mixed" ]]; then
        CLIENT_JSON=""
    else
        CLIENT_JSON="$(gen_client "$PROTOCOL")"
    fi

    # Параметры пути и REALITY
    case "$TRANSPORT" in
        xhttp)
            # XHTTP идёт через unix-сокет (эталон): путь без порта, /x<hex>.
            while true; do
                ask "Путь XHTTP (nginx location, формат /x<name>)" "/x$(gen_hex 5)" WS_PATH
                if db_path_in_use "$WS_PATH"; then
                    warn "Путь $WS_PATH уже используется другим инбаундом за прокси."
                    confirm "Продолжить с тем же путём?" || continue
                fi
                break
            done
            ;;
        ws|grpc|httpupgrade)
            while true; do
                ask "Путь (для nginx нужен формат /<порт>/<name>)" "/${PORT}/$(gen_hex 5)" WS_PATH
                if db_path_in_use "$WS_PATH"; then
                    warn "Путь $WS_PATH уже используется другим инбаундом за прокси."
                    confirm "Продолжить с тем же путём?" || continue
                fi
                break
            done
            ;;
    esac
    if [[ "$SECURITY" == "tls" ]]; then
        if [[ "$TRANSPORT" == "tcp" ]]; then
            # TCP+TLS: уникальный домен инбаунда + собственный сертификат
            local prefix="" def_sni=""
            case "$PROTOCOL" in vless) prefix="v";; vmess) prefix="m";; trojan) prefix="t";; *) prefix="x";; esac
            if [[ -n "$PANEL_HOST" ]]; then
                def_sni="${prefix}.${PANEL_HOST}"
                warn "Для TCP+TLS инбаунда нужен уникальный домен (SNI)."
                warn "Добавь у регистратора запись A: $def_sni → $SERVER_IP (или CNAME на $PANEL_HOST)."
            else
                warn "У панели нет домена (сертификат по IP). Укажи домен инбаунда вручную."
            fi
            while true; do
                ask "Домен инбаунда (SNI, TCP+TLS)" "$def_sni" CHANNEL_SNI
                [[ -n "$CHANNEL_SNI" ]] || die "Для TCP+TLS домен обязателен."
                if [[ -n "$PANEL_HOST" && "$CHANNEL_SNI" == "$PANEL_HOST" ]]; then
                    warn "SNI совпадает с доменом панели — инбаунд будет недоступен (SSL конфликт)."
                    continue
                fi
                if db_sni_in_use "$CHANNEL_SNI" tls; then
                    warn "SNI $CHANNEL_SNI уже используется другим инбаундом."
                    continue
                fi
                break
            done
            SNI="$CHANNEL_SNI"
            ensure_channel_cert "$CHANNEL_SNI"
            info "SNI инбаунда: $SNI (сертификат: ${CHANNEL_CERT_DIR:-сертификат панели})."
        else
            SNI="${PANEL_HOST:-$(external_addr)}"
            info "SNI для TLS: $SNI"
        fi
    fi
    if [[ "$SECURITY" == "reality" ]]; then
        # REALITY занимает ОСНОВНОЙ домен (например plesav.ru), а панель при
        # этом живёт на поддомене (например p.plesav.ru). По умолчанию берём
        # основной домен из домена панели, но SNI можно изменить интерактивно.
        # На SNI должна указывать A-запись — он служит SNI маскировки клиента
        # и serverNames инбаунда.
        local base_domain=""
        if [[ "$PANEL_HOST" == *.*.* ]]; then
            base_domain="${PANEL_HOST#*.}"
        elif [[ -n "$PANEL_HOST" ]]; then
            base_domain="$PANEL_HOST"
        fi
        while true; do
            ask "Домен REALITY (SNI маскировки, A-запись → сервер)" "$base_domain" CHANNEL_SNI
            [[ -n "$CHANNEL_SNI" ]] || { warn "Домен REALITY обязателен."; continue; }
            if [[ -n "$PANEL_HOST" && "$CHANNEL_SNI" == "$PANEL_HOST" ]]; then
                warn "SNI совпадает с доменом панели: панель и REALITY будут конфликтовать на 443."
                warn "Переведи панель на поддомен (напр. p.${base_domain:-<домен>}) или укажи другой SNI."
            fi
            if db_sni_in_use "$CHANNEL_SNI" reality; then
                warn "SNI $CHANNEL_SNI уже используется другим REALITY-инбаундом."
                warn "При одинаковом SNI stream-443 не сможет различить инбаунды."
                continue
            fi
            break
        done
        REALITY_SNI="$CHANNEL_SNI"
        SNI="$REALITY_SNI"
        REALITY_TARGET="127.0.0.1:9443"
        REALITY_SPIDERX="/"
        gen_reality_keys
        REALITY_SETTINGS_JSON="$(reality_settings "$REALITY_TARGET" "$REALITY_SNI")"
        info "REALITY: домен=${REALITY_SNI}, target=${REALITY_TARGET}, ключи сгенерированы."
    fi

    # nginx-интеграция: все проксируемые инбаунды ВСЕГДА за 443 (stream-мастер),
    # без вопросов. Если nginx не установлен — устанавливаем автоматически.
    USE_NGINX=""
    local can_proxy=""
    case "$TRANSPORT" in
        ws|grpc|xhttp|httpupgrade) can_proxy=1 ;;
        tcp)
            [[ "$PROTOCOL" != "mtproto" && ( "$SECURITY" == "reality" || "$SECURITY" == "tls" ) ]] && can_proxy=1
            ;;
    esac
    if [[ -n "$can_proxy" ]]; then
        if ! command -v nginx >/dev/null 2>&1; then
            info "nginx не установлен — устанавливаем для прокси инбаунда за 443..."
            install_pkg "$(nginx_pkg)" || warn "Не удалось установить nginx — инбаунд будет создан напрямую."
            command -v nginx >/dev/null 2>&1 && systemctl enable nginx >/dev/null 2>&1 || true
        fi
        if command -v nginx >/dev/null 2>&1; then
            USE_NGINX=1
            LISTEN="127.0.0.1"
            # Автоматически переводим весь трафик на 443 (stream-мастер),
            # если он ещё не включён (например, сразу после установки nginx).
            if ! is_stream_443_master; then
                nginx_stream_master_setup auto
            fi
            info "Инбаунд будет слушать 127.0.0.1:${PORT} (за nginx на 443)."
        fi
    fi

    # Сборка JSON и вставка
    if [[ "$TRANSPORT" == "xhttp" ]]; then
        # XHTTP перенесён с эталона — работает ТОЛЬКО через nginx (unix-сокет)
        if [[ -z "$USE_NGINX" ]]; then
            warn "XHTTP требует nginx (unix-сокет /dev/shm/uds2023.sock + grpc_pass)."
            warn "nginx не доступен — создание xhttp-инбаунда прервано."
            return 0
        fi
        # Уникальность unix-сокета (эталон допускает один XHTTP на сокет)
        if [[ -n "$(sqlite3 "$XUI_DB" "SELECT id FROM inbounds WHERE listen LIKE '/dev/shm/uds2023.sock%';" 2>/dev/null || true)" ]]; then
            warn "XHTTP-инбаунд на unix-сокете /dev/shm/uds2023.sock уже существует —"
            warn "эталон поддерживает один XHTTP на сокет. Пересоздание невозможно."
            return 0
        fi
        LISTEN="/dev/shm/uds2023.sock,0666"
        info "XHTTP будет слушать на unix-сокете ${LISTEN} (nginx grpc_pass)."
    fi
    # host/authority для http-транспортов за nginx — домен (как в эталоне);
    # для XHTTP host остаётся пустым (в эталоне host="").
    if [[ -n "$USE_NGINX" && "$TRANSPORT" == "ws" || -n "$USE_NGINX" && "$TRANSPORT" == "grpc" || -n "$USE_NGINX" && "$TRANSPORT" == "httpupgrade" ]]; then
        WS_HOST="${PANEL_HOST:-$(external_addr)}"
        info "host/authority инбаунда: ${WS_HOST}"
    fi
    if [[ "$SECURITY" == "reality" ]]; then
        # Target — сайт-прикрытие: за nginx это локальная заглушка 127.0.0.1:9443
        # (nginx http-сервер с сертификатом поддомена REALITY), как в эталоне
        # x-ui-pro. Без прокси — внешний домен поддомена:443.
        if [[ -n "$USE_NGINX" ]]; then
            REALITY_TARGET="127.0.0.1:9443"
        else
            REALITY_TARGET="${REALITY_SNI}:443"
        fi
        REALITY_SETTINGS_JSON="$(reality_settings "$REALITY_TARGET" "$REALITY_SNI")"
        info "REALITY target: $REALITY_TARGET"
    fi
    local settings_json stream_json snf_json
    settings_json="$(build_settings "$PROTOCOL" "$CLIENT_JSON")"
    if [[ -n "$USE_NGINX" && "$TRANSPORT" != "tcp" ]]; then
        # Инбаунд за nginx (ws/grpc/xhttp/httpupgrade): TLS терминируется на
        # nginx, поэтому xray слушает на 127.0.0.1:PORT БЕЗ TLS.
        info "Инбаунд за nginx: TLS терминируется на nginx, xray слушает без TLS."
        stream_json="$(build_stream "$TRANSPORT" "none" "$WS_PATH" "$WS_HOST" "$SNI")"
    else
        stream_json="$(build_stream "$TRANSPORT" "$SECURITY" "$WS_PATH" "$WS_HOST" "$SNI")"
    fi

    if [[ "$PROTOCOL" == "hysteria" ]]; then
        snf_json="$(sniffing_json 0)"
    else
        snf_json="$(sniffing_json 1)"
    fi

    info "Вставка инбаунда в базу панели..."
    db_insert_inbound "$settings_json" "$stream_json" "$snf_json"
    ok "Инбаунд добавлен (inbound id=${INBOUND_ID})."
    db_add_client_records "$INBOUND_ID"
    ok "Клиент «$CLIENT_EMAIL» добавлен."

    # nginx применение
    if [[ -n "$USE_NGINX" ]]; then
        nginx_ensure_files || warn "Не удалось подготовить файлы nginx."
        nginx_stream_context_enable || warn "Не удалось подключить stream-контекст."
        case "$TRANSPORT" in
            xhttp)
                nginx_add_xhttp_location
                nginx_ensure_snippet_included
                ;;
            ws|grpc|httpupgrade)
                nginx_add_http_location
                nginx_ensure_snippet_included
                ;;
        esac
        if [[ "$TRANSPORT" == "tcp" && "$SECURITY" == "reality" ]]; then
            nginx_add_stream_sni
            nginx_reality_target_server "$CHANNEL_SNI"
        elif [[ "$TRANSPORT" == "tcp" && "$SECURITY" == "tls" ]]; then
            nginx_add_stream_tcp
        fi
        # Внешний адрес/порт для подписки (запись в таблицу hosts) — всегда
        # при инбаунде за прокси, независимо от включённой подписки.
        db_add_host_record "$INBOUND_ID"
    fi

    # Порт инбаунда в firewall — только если инбаунд выходит НЕ через 443.
    # Без прокси — прямой порт инбаунда. В legacy-режиме (мастер не удалось
    # включить) tcp/reality/tls-инбаунды слушают свой passthrough-порт — тоже
    # открываем. В stream-мастере снаружи открыт только 443 (открывается при
    # включении мастера), порт инбаунда не трогаем.
    if [[ -z "$USE_NGINX" ]]; then
        firewall_port_open "$PORT" "$CHANNEL_PROTO"
    elif [[ "$STREAM_443_MASTER" != "1" && "$TRANSPORT" == "tcp" && ( "$SECURITY" == "reality" || "$SECURITY" == "tls" ) ]]; then
        firewall_port_open "$PORT" "$CHANNEL_PROTO"
    fi

    restart_xui

    print_summary
}

# =============================================================================
# Главный поток
# =============================================================================

main() {
    setup_log
    banner "inbound-xray.sh v${SCRIPT_VERSION} — настройка Xray-инбаундов для 3x-ui"
    banner "Поддержка панели 3x-ui v3.6+ (формат базы данных)."
    banner ""
    require_root
    detect_os
    require_tools
    load_panel_env
    if command -v nginx >/dev/null 2>&1; then
        nginx_ensure_files || warn "Не удалось подготовить файлы nginx."
        nginx_stream_context_enable || warn "Не удалось подключить stream-контекст."
        # «Всё через 443» включается автоматически: stream-мастер на 443,
        # все инбаунды и панель выходят наружу через единый 443.
        if is_stream_443_master; then
            # Пересобираем stream.conf из БД: держим proxy_protocol и SNI-map
            # актуальными (старые конфиги без proxy_protocol ломают инбаунды
            # с acceptProxyProtocol=true).
            nginx_stream_master_rebuild || warn "Не удалось пересобрать stream-мастер."
            # Конфиг панели тоже должен принимать PROXY-заголовок мастера:
            # без listen ... proxy_protocol все запросы через 443 (WS/gRPC/XHTTP
            # и сама панель) молча падают.
            local pconf="$NGINX_CONF"
            if [[ -z "$pconf" || ! -f "$pconf" ]]; then
                detect_nginx_conf
                pconf="$NGINX_CONF"
            fi
            [[ -z "$pconf" || ! -f "$pconf" ]] && pconf="/etc/nginx/conf.d/x-ui.conf"
            local pmode="panel"
            [[ -n "$ENABLE_LANDING" ]] && pmode="landing"
            write_panel_conf "$pconf" "$pmode" || warn "Не удалось обновить конфиг панели (proxy_protocol)."
        else
            nginx_stream_master_setup auto
        fi
    fi
    # Подписка включается автоматически при первом запуске (без пункта меню)
    if [[ "$SUB_ENABLE" != "true" ]]; then
        setup_subscription
    else
        info "Подписка пользователя уже включена: $(sub_url "${CLIENT_SUBID:-<subId>}")"
    fi

    while true; do
        banner ""
        banner "  ========== Главное меню =========="
        echo "   1) Создать Xray-инбаунд"
        echo "   2) Включить заглушку (панель скрыть на пути, корень → сайт)"
        echo "   3) Отключить заглушку (панель на корень)"
        echo "   4) Удалить инбаунд"
        echo "   0) Выход"
        echo "===================================="
        local ans=""
        read -r -p "Ваш выбор [0-4]: " ans || exit 0
        case "$ans" in
            1) create_channel ;;
            2) setup_landing ;;
            3) disable_landing ;;
            4) delete_channel ;;
            0|q|Q|exit) break ;;
            *) warn "Неверный выбор." ;;
        esac
    done
    info "Готово. Лог: $LOG_FILE"
    if [[ -n "$ENABLE_LANDING" ]]; then
        info "Внимание: панель скрыта за заглушкой."
        print_panel_data
    fi
}

# Запуск только при прямом выполнении (source — для тестов и переиспользования)
if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
    main
fi
