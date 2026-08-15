#!/usr/bin/env bash
# =============================================================================
# inbound-xray.sh — настройка Xray-инбаундов поверх установленной панели 3x-ui.
#
# Возможности:
#   * создание inbound для двух протоколов: VLESS+XHTTP+REALITY и Hysteria2;
#   * создание клиентов панели и генерация share-ссылок (vless://, hy2://);
#   * XHTTP+REALITY слушает прямой TCP-порт (без nginx): REALITY-target — сайт
#     прикрытия по домену SNI, клиент в режиме mode=stream-one;
#   * Hysteria2 — UDP, сертификат панели (или self-signed);
#   * nginx-инфраструктура панели: «всё через 443» (stream-мастер с ssl_preread),
#     конфиг панели с proxy_protocol, заглушка-сайт на корневом адресе;
#   * подписка пользователя (/sub/) через внешний адрес с корректными ссылками;
#   * открытие прямых портов инбаундов в firewall;
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
SCRIPT_VERSION="2.1.0"
XUI_BIN="/usr/local/x-ui/x-ui"
PANEL_INSTALL_LOG="/var/log/3x-ui-install.log"   # лог официального установщика
NGINX_SNIPPET="/etc/nginx/snippets/includes.conf"
NGINX_STREAM="/etc/nginx/stream-enabled/stream.conf"
PANEL_STATE="/etc/nginx/inbound-xray.state"
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
CHANNEL_PROTO="tcp"
ENABLE_LANDING=""

# REALITY-параметры (генерируются один раз и переиспользуются)
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
REALITY_SHORT_ID=""
REALITY_SNI=""
REALITY_TARGET=""
REALITY_SETTINGS_JSON=""

# Параметры REALITY-домена и переиспользуемого клиента
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

# panel_domain_from_cert <fullchain> — домен из SAN сертификата (fallback — имя каталога).
panel_domain_from_cert() {
    local cert="$1" san=""
    san="$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null || true)"
    if [[ "$san" =~ DNS:([^,]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "$(basename "$(dirname "$cert")")"
    fi
}

# save_panel_state — запоминает выбранный домен/каталог панели в файл состояния,
# чтобы перезапуски скрипта не теряли его при нескольких сертификатах на сервере.
save_panel_state() {
    [[ -z "$PANEL_HOST" ]] && return 0
    mkdir -p "$(dirname "$PANEL_STATE")" 2>/dev/null || return 0
    cat > "$PANEL_STATE" <<EOF
PANEL_HOST="$PANEL_HOST"
PANEL_CERT_DIR="$PANEL_CERT_DIR"
EOF
    chmod 600 "$PANEL_STATE" 2>/dev/null || true
}

# detect_panel_cert — ищет сертификат панели. Источники по приоритету:
#  1. /root/cert/ip            — IP-сертификат (панель по IP, PANEL_HOST пустой);
#  2. server_name из конфига панели (реальный домен, не "_") + LE live/<домен>;
#  3. ssl_certificate из конфига панели, если путь ведёт в /etc/letsencrypt/live/;
#  4. файл состояния (PANEL_STATE) — домен, выбранный ранее;
#  5. обход /etc/letsencrypt/live/* (один каталог → он; несколько → вопрос);
#     без LE — обход доменных каталогов /root/cert/* (кроме "ip").
# Доменные каталоги /root/cert/<домен> НЕ выбираются, если есть LE live:
# они могут содержать сертификаты других сайтов (например основного домена).
# Устанавливает PANEL_CERT, PANEL_CERT_KEY, PANEL_CERT_DIR и PANEL_HOST (домен из SAN).
detect_panel_cert() {
    PANEL_CERT=""; PANEL_CERT_KEY=""; PANEL_CERT_DIR=""; PANEL_HOST=""
    local base="/root/cert"

    # 1. IP-сертификат: панель по IP, домена нет
    local ip_cert="$base/ip"
    if [[ -f "$ip_cert/fullchain.pem" && -f "$ip_cert/privkey.pem" ]]; then
        PANEL_CERT="$ip_cert/fullchain.pem"
        PANEL_CERT_KEY="$ip_cert/privkey.pem"
        PANEL_CERT_DIR="$ip_cert"
        return 0
    fi

    local pconf="${NGINX_CONF:-/etc/nginx/conf.d/x-ui.conf}"
    local live_dir="/etc/letsencrypt/live"

    # 2. Панель из server_name конфига: реальный домен + сертификат в LE live
    if [[ -f "$pconf" ]]; then
        local sname=""
        sname="$(sed -n 's/.*server_name[[:space:]]*\([^;]*\);.*/\1/p' "$pconf" | tr -d ' ' | head -1 || true)"
        local sname_first="${sname%% *}"
        if [[ -n "$sname_first" && "$sname_first" != "_" && -f "$live_dir/${sname_first}/fullchain.pem" ]]; then
            PANEL_CERT="$live_dir/${sname_first}/fullchain.pem"
            PANEL_CERT_KEY="$live_dir/${sname_first}/privkey.pem"
            PANEL_CERT_DIR="$live_dir/${sname_first}"
            PANEL_HOST="$sname_first"
            save_panel_state
            return 0
        fi

        # 3. Панель из ssl_certificate конфига (путь → LE live/<домен>)
        local scrt=""
        scrt="$(sed -n 's/.*ssl_certificate[[:space:]]*\([^;]*\);.*/\1/p' "$pconf" | tr -d ' ' | head -1 || true)"
        if [[ "$scrt" =~ ^/etc/letsencrypt/live/([^/]+)/ ]]; then
            local sn="${BASH_REMATCH[1]}"
            if [[ -n "$sn" && -f "$live_dir/${sn}/fullchain.pem" ]]; then
                PANEL_CERT="$live_dir/${sn}/fullchain.pem"
                PANEL_CERT_KEY="$live_dir/${sn}/privkey.pem"
                PANEL_CERT_DIR="$live_dir/${sn}"
                PANEL_HOST="$sn"
                save_panel_state
                return 0
            fi
        fi
    fi

    # 4. Файл состояния: ранее выбранный домен панели
    if [[ -f "$PANEL_STATE" ]]; then
        local st_host=""
        st_host="$(sed -n 's/^PANEL_HOST="\([^"]*\)"/\1/p' "$PANEL_STATE" | head -1 || true)"
        if [[ -n "$st_host" && -f "$live_dir/${st_host}/fullchain.pem" ]]; then
            PANEL_CERT="$live_dir/${st_host}/fullchain.pem"
            PANEL_CERT_KEY="$live_dir/${st_host}/privkey.pem"
            PANEL_CERT_DIR="$live_dir/${st_host}"
            PANEL_HOST="$st_host"
            return 0
        fi
    fi

    # 5. Обход каталогов с сертификатами
    local pick_dir=""
    local pick_dirs=()
    local crt key sub
    for sub in "$live_dir"/*/; do
        [[ -d "$sub" ]] || continue
        crt="$sub/fullchain.pem"; key="$sub/privkey.pem"
        [[ -f "$crt" && -f "$key" ]] || continue
        pick_dirs+=("$sub")
    done
    # Без LE — доменные каталоги /root/cert (панель могла быть настроена вручную)
    if ((${#pick_dirs[@]} == 0)); then
        for sub in "$base"/*/; do
            [[ -d "$sub" ]] || continue
            [[ "$(basename "$sub")" == "ip" ]] && continue
            crt="$sub/fullchain.pem"; key="$sub/privkey.pem"
            [[ -f "$crt" && -f "$key" ]] || continue
            pick_dirs+=("$sub")
        done
    fi
    if ((${#pick_dirs[@]} == 0)); then
        return 0   # сертификата панели нет — панель доступна по IP/HTTP
    fi
    pick_dir="${pick_dirs[0]}"
    if ((${#pick_dirs[@]} > 1)); then
        local i dom pick="" def_idx=1
        info "Найдено несколько сертификатов — укажите, какой из них для панели."
        for i in "${!pick_dirs[@]}"; do
            dom="$(panel_domain_from_cert "${pick_dirs[$i]}/fullchain.pem")"
            printf '  %d) %s\n' "$((i+1))" "$dom"
        done
        ask "Номер сертификата панели" "$def_idx" pick
        pick="${pick:-$def_idx}"
        if [[ "$pick" =~ ^[0-9]+$ ]] && ((pick >= 1 && pick <= ${#pick_dirs[@]})); then
            pick_dir="${pick_dirs[$((pick-1))]}"
        else
            warn "Неверный номер — беру первый."
        fi
    fi
    PANEL_CERT="$pick_dir/fullchain.pem"
    PANEL_CERT_KEY="$pick_dir/privkey.pem"
    PANEL_CERT_DIR="${pick_dir%/}"
    PANEL_HOST="$(panel_domain_from_cert "$PANEL_CERT")"
    [[ "$PANEL_HOST" == "ip" ]] && PANEL_HOST=""
    save_panel_state
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

# domain_root <домен> — корневой домен без поддомена (p.plesav.ru → plesav.ru).
domain_root() {
    local h="${1:-}"
    if [[ "$h" == *.*.* ]]; then
        printf '%s' "${h#*.}"
    else
        printf '%s' "$h"
    fi
}

# detect_panel_proto <port> — фактический протокол панели 3x-ui (http/https).
# x-ui выводит «Panel is secure with SSL», даже когда webCertFile/webKeyFile
# заданы, но файлов на диске нет и панель реально слушает HTTP — доверять этой
# строке нельзя (nginx шлёт TLS в HTTP-порт → панель отдаёт 502). https считаем
# только если оба файла сертификата существуют И панель отвечает на https-пробу.
# Печатает "http" или "https".
detect_panel_proto() {
    local port="${1:-}" web_cert="" web_key="" probe=""
    if [[ -z "$port" ]]; then
        printf 'http'
        return 0
    fi
    web_cert="$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webCertFile' LIMIT 1;" 2>/dev/null || true)"
    web_key="$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webKeyFile' LIMIT 1;" 2>/dev/null || true)"
    if [[ -n "$web_cert" && -n "$web_key" && -f "$web_cert" && -f "$web_key" ]]; then
        if command -v curl >/dev/null 2>&1; then
            probe="$(curl -sk --max-time 5 -o /dev/null -w '%{http_code}' "https://127.0.0.1:${port}/" 2>/dev/null || true)"
            [[ -n "$probe" && "$probe" != "000" ]] && { printf 'https'; return 0; }
        else
            printf 'https'
            return 0
        fi
    fi
    printf 'http'
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

    # Протокол панели — по факту (файлы серта + https-проба), а не по строке
    # «Panel is secure with SSL»: см. detect_panel_proto.
    PANEL_PROTO="$(detect_panel_proto "$PANEL_PORT")"

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
    CLIENT_SECRET=""
    case "$proto" in
        vless)  CLIENT_ID="$(gen_uuid)" ;;
        hysteria) CLIENT_AUTH="$(gen_password 24)" ;;
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
        hysteria)
            printf '{\n    "auth": "%s",\n    "email": "%s",\n    "limitIp": 0,\n    "totalGB": 0,\n    "expiryTime": 0,\n    "enable": true,\n    "tgId": 0,\n    "subId": "%s",\n    "comment": "",\n    "reset": 0\n  }' "$CLIENT_AUTH" "$CLIENT_EMAIL" "$CLIENT_SUBID"
            ;;
        *)
            die "Неизвестный протокол клиента: $proto"
            ;;
    esac
}

# build_settings <protocol> <client_json> <доп.аргументы...>
# Печатает JSON "settings" для inbound.
build_settings() {
    local proto="$1" client="$2"
    case "$proto" in
        vless)
            printf '{\n  "clients": [\n%s\n  ],\n  "decryption": "none",\n  "encryption": "none",\n  "fallbacks": []\n}' "$client"
            ;;
        hysteria)
            printf '{\n  "version": 2,\n  "clients": [\n%s\n  ]\n}' "$client"
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
# Оставлены два транспорта:
#   xhttp+reality — прямой TCP-порт (REALITY сам маскирует зондирование и
#     поведенческий анализ), клиент использует mode=stream-one;
#   hysteria — UDP/QUIC (TLS), TLS терминирует сам xray.
build_stream() {
    local network="$1" path="${2:-/}" host="${3:-}" sni="${4:-}"
    [[ "$path" == / ]] && path="/"
    case "$network" in
        xhttp)
            # XHTTP+REALITY: инбаунд слушает прямой TCP-порт (nginx не участвует),
            # serverNames приходят из REALITY_SETTINGS_JSON.
            printf '{\n  "network": "xhttp",\n  "xhttpSettings": {\n    "path": "%s",\n    "host": "%s",\n    "headers": {}\n  },\n  "sockopt": {\n    "acceptProxyProtocol": false,\n    "tcpFastOpen": true,\n    "tcpMptcp": true,\n    "tcpNoDelay": true,\n    "domainStrategy": "UseIP",\n    "tcpMaxSeg": 1440,\n    "tcpcongestion": "bbr"\n  },\n  "security": "reality",\n  "realitySettings": %s\n}' "$path" "$host" "$REALITY_SETTINGS_JSON"
            ;;
        hysteria)
            printf '{\n  "network": "hysteria",\n  "hysteriaSettings": {\n    "version": 2,\n    "udpIdleTimeout": 60\n  },\n  "security": "tls",\n  "tlsSettings": %s\n}' "$(tls_settings "$sni")"
            ;;
        *)
            die "Неизвестный транспорт: $network"
            ;;
    esac
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
            hysteria)
                CLIENT_AUTH="$(json_extract "$block" auth)"
                ;;
        esac
    else
        # Сирота — инбаундов нет, берём поля из clients
        local row=""
        row="$(sqlite3 "$XUI_DB" "SELECT uuid, auth, flow, sub_id FROM clients WHERE id = $cid;" 2>/dev/null || true)"
        local uu="" au="" fl=""
        IFS='|' read -r uu au fl _ <<< "$row" || true
        case "$PROTOCOL" in
            vless)      CLIENT_ID="$uu"; CLIENT_FLOW="$fl" ;;
            hysteria)   CLIENT_AUTH="$au" ;;
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
    now="$(date +%s000)"
    local cl_pw="$CLIENT_PW"
    # email уже есть в clients? (уникальность) — обновить, иначе вставить
    local existing
    existing="$(sqlite3 "$XUI_DB" "SELECT id FROM clients WHERE email = '$(sql_escape "$CLIENT_EMAIL")' LIMIT 1;" 2>/dev/null || true)"
    if [[ -n "$existing" ]]; then
        cid="$existing"
        if [[ "$REUSE_CLIENT" == "1" ]]; then
            # Переиспользуемый клиент: протокол-поля (uuid/password/auth/flow)
            # НЕ перезаписываем — иначе сломаются старые инбаунды, где в settings
            # сохранены прежние значения.
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

# sync_panel_webcert — приводит webCertFile/webKeyFile панели к фактическому
# сертификату панели (PANEL_CERT/PANEL_CERT_KEY), если они расходятся.
# Мёртвые пути (файлов нет на диске) заставляют панель отвечать по HTTP, хотя
# она выводит «Panel is secure with SSL»: nginx шлёт TLS в HTTP-порт → 502.
# Кроме того, меню установщика x-ui (check_config) берёт домен из имени
# каталога webCertFile — отсюда «адрес панели на основном домене». Если
# PANEL_CERT не найден — пути очищаются (панель честно работает по HTTP).
# subCertFile/subKeyFile не трогаются: подписка отдаётся через nginx по HTTP.
sync_panel_webcert() {
    [[ -x "$XUI_BIN" ]] || return 0
    [[ -n "$XUI_DB" && -f "$XUI_DB" ]] || return 0
    local cur_cert="" cur_key="" want_cert="" want_key=""
    cur_cert="$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webCertFile' LIMIT 1;" 2>/dev/null || true)"
    cur_key="$(sqlite3 "$XUI_DB" "SELECT value FROM settings WHERE key='webKeyFile' LIMIT 1;" 2>/dev/null || true)"
    if [[ -n "$PANEL_CERT" && -n "$PANEL_CERT_KEY" && -f "$PANEL_CERT" && -f "$PANEL_CERT_KEY" ]]; then
        want_cert="$PANEL_CERT"
        want_key="$PANEL_CERT_KEY"
    fi
    if [[ "$cur_cert" == "$want_cert" && "$cur_key" == "$want_key" ]]; then
        return 0
    fi
    warn "Настройки сертификата панели расходятся с найденным сертификатом:"
    warn "  webCertFile: ${cur_cert:-<пусто>} → ${want_cert:-<пусто>}"
    warn "  webKeyFile:  ${cur_key:-<пусто>} → ${want_key:-<пусто>}"
    confirm "Применить и перезапустить панель x-ui?" || return 0
    sqlite3 "$XUI_DB" "UPDATE settings SET value='$(sql_escape "$want_cert")' WHERE key='webCertFile';" \
        || warn "Не удалось обновить webCertFile."
    sqlite3 "$XUI_DB" "UPDATE settings SET value='$(sql_escape "$want_key")' WHERE key='webKeyFile';" \
        || warn "Не удалось обновить webKeyFile."
    restart_xui
    info "Сертификат панели применён: ${want_cert:-<очищено>}"
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


# gen_link_vless — vless:// ссылка.
# link_external — адрес:порт для share-ссылки. Инбаунды (xhttp+reality, hysteria)
# слушают прямые порты (без прокси) — внешний адрес:PORT.
link_external() {
    printf '%s:%s' "$(external_addr)" "$PORT"
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
        [[ -n "$CLIENT_FLOW" ]] && q+=("flow=${CLIENT_FLOW}")
    else
        q+=("security=none")
    fi
    case "$TRANSPORT" in
        xhttp)
            # mode=stream-one: обязателен для XHTTP+REALITY (mode=auto ломается
            # на Xray 26.1.31+; stream-one закрывает поведенческий анализ).
            q+=("path=${WS_PATH}")
            [[ -n "$WS_HOST" ]] && q+=("host=${WS_HOST}")
            q+=("mode=stream-one")
            ;;
    esac
    q+=("encryption=none")
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
    banner "  Оставлены протоколы, устойчивые к блокировкам ТСПУ:"
    banner "  VLESS+XHTTP+REALITY (закрывает зондирование и поведенческий анализ),"
    banner "  Hysteria2 (UDP/QUIC)."
    banner ""
    cat <<'MENU'
   1)  VLESS + XHTTP + REALITY (TCP, mode stream-one)
   2)  Hysteria2 (UDP, TLS)
   q)   Выход
MENU
    local ans=""
    read -r -p "Ваш выбор [1-2, q]: " ans || exit 0
    case "$ans" in
        1) PROTOCOL=vless; TRANSPORT=xhttp; SECURITY=reality; CLIENT_FLOW="" ;;
        2) PROTOCOL=hysteria; TRANSPORT=hysteria; SECURITY=tls ;;
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
# stream_sni_in_map <map_lines> <sni> — занят ли ключ SNI в уже собранных
# строках map stream-мастера (любым бэкендом). Печатает порт занявшего
# инбаунда; пусто — SNI свободен. Предотвращает дубликаты ключей в map,
# которые валят nginx -t (conflicting parameter).
stream_sni_in_map() {
    local ml="$1" sni="$2" esc
    esc="$(printf '%s' "$sni" | sed 's/[.[\*^$(){}?+|]/\\./g')"
    [[ -n "$esc" ]] || return 0
    printf '%s' "$ml" | sed -n "s#^    ${esc}[[:space:]]\+127\.0\.0\.1:\([0-9]\+\);#\1#p" | head -1
}

nginx_stream_master_rebuild() {
    [[ -f "$NGINX_STREAM" ]] || return 0
    local map_lines="" pass_lines="" row="" id="" port="" listen="" ss="" sni=""
    local rows=""
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
            if [[ -z "$(stream_sni_in_map "$map_lines" "$sni")" ]]; then
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
    # Строка не добавляется, если SNI панели уже занят каким-то инбаундом
    # (иначе дубликат ключа в map валит nginx -t).
    local panel_line=""
    local busy_port=""
    if [[ -n "$PANEL_HOST" && -n "$PANEL_SSL_PORT" ]]; then
        busy_port="$(stream_sni_in_map "$map_lines" "$PANEL_HOST")"
        if [[ -n "$busy_port" ]]; then
            warn "SNI панели ${PANEL_HOST} занят инбаундом (порт ${busy_port}) — панель по домену недоступна, строка в map не добавлена."
        else
            panel_line="    ${PANEL_HOST}  127.0.0.1:${PANEL_SSL_PORT};
"
        fi
    fi
    # Корневой домен (заглушка) → тоже на http-модуль nginx, чтобы не уходил
    # в default (REALITY) и получал свой сертификат в отдельном server-блоке.
    # Если корневой SNI занят REALITY/TLS-инбаундом — строка не добавляется:
    # заглушку корня уже отдаёт target-заглушка REALITY с валидным LE-сертом.
    local root_line=""
    local root_dom=""
    root_dom="$(domain_root "$PANEL_HOST")"
    if [[ -n "$root_dom" && "$root_dom" != "$PANEL_HOST" && -n "$PANEL_SSL_PORT" \
        && -f "/etc/letsencrypt/live/${root_dom}/fullchain.pem" ]]; then
        busy_port="$(stream_sni_in_map "$map_lines" "$root_dom")"
        if [[ -n "$busy_port" ]]; then
            warn "SNI корневого домена ${root_dom} занят инбаундом (порт ${busy_port}) — заглушку корня отдаёт REALITY (target), строка в map не добавлена."
        else
            root_line="    ${root_dom}  127.0.0.1:${PANEL_SSL_PORT};
"
        fi
    fi
    cat > "$tmp" <<EOF
# inbound-xray.sh: stream-443 master (все внешние TLS-потоки идут на ${STREAM_MASTER_PORT:-443})
map \$ssl_preread_server_name \$xui_backend {
${map_lines}${panel_line}${root_line}    default  127.0.0.1:${real_def};
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
# краткая метка инбаунда: VLESS-XHTTP-REALITY-443, HYSTERIA-443 и т.п.
# Внешний порт 443 означает, что инбаунд за прокси (старые конфигурации).
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

# delete_channel — меню удаления инбаунда из панели (БД + nginx + firewall).
delete_channel() {
    local rows=""
    rows="$(sqlite3 "$XUI_DB" "SELECT id, remark, port, protocol, replace(COALESCE(stream_settings,''),char(10),char(32)), COALESCE(listen,'') FROM inbounds ORDER BY id;" 2>/dev/null || true)"
    if [[ -z "$rows" ]]; then
        info "Инбаундов в панели нет."
        return 0
    fi
    banner "  ========== Инбаунды панели =========="
    local list=() i=1 id="" remark="" port="" proto="" stream="" tran="" sec="" extp="" rest="" sel=""
    while IFS= read -r line; do
        id="${line%%|*}"; rest="${line#*|}"
        remark="${rest%%|*}"; rest="${rest#*|}"
        port="${rest%%|*}"; rest="${rest#*|}"
        proto="${rest%%|*}"; rest="${rest#*|}"
        stream="${rest%%|*}"; rest="${rest#*|}"
        tran="$(json_extract "$stream" network)"
        sec="$(json_extract "$stream" security)"
        extp="$port"
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
    local fw_rules=() del_id="" del_port="" del_proto=""
    local del_listen="" del_cproto="tcp" del_remove=0 fw="" fdup=0 f2=""
    for r in "${del_records[@]}"; do
        IFS='|' read -r del_id _ del_port del_proto <<< "$r"
        del_cproto="tcp"; del_remove=0
        del_listen="$(sqlite3 "$XUI_DB" "SELECT COALESCE(listen,'') FROM inbounds WHERE id=$del_id;" 2>/dev/null || true)"
        case "$del_proto" in
            hysteria*) del_cproto="udp" ;;
        esac
        # Через 443 (listen=127.0.0.1) выходили только старые инбаунды за nginx —
        # для них правило firewall не создавалось, удалять нечего.
        if [[ "$del_listen" != "127.0.0.1" ]]; then
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
    banner "  Метка: $(channel_name_label "$PROTOCOL" "$TRANSPORT" "$SECURITY" "$PORT")"
    banner "  Протокол: ${PROTOCOL}  Транспорт: ${TRANSPORT}  Безопасность: ${SECURITY}"
    banner "  Порт: ${PORT}   Слушает: ${LISTEN:-0.0.0.0}"
    [[ -n "$INBOUND_ID" ]] && banner "  ID inbound в панели: ${INBOUND_ID}"
    banner ""

    local link=""
    case "$PROTOCOL" in
        vless)       link="$(gen_link_vless)" ;;
        hysteria)    link="$(gen_link_hysteria2)" ;;
    esac
    if [[ -n "$link" ]]; then
        printf '%s\n' "  ${C_GREEN}Ссылка для клиента:${C_RESET}"
        printf '%s\n' "  $link"
        printf '%s\n' "  (дублируется в $LOG_FILE)"
        printf '%s\n' "$link" >> "$LOG_FILE"
    fi

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

    # server_name панели — реальный домен (не "_"), чтобы повторный запуск
    # скрипта находил панель по нему, а не по случайному каталогу сертификата.
    local sname="_"
    [[ -n "$PANEL_HOST" ]] && sname="$PANEL_HOST"

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
    # Панель на скрытом пути — в любом режиме (landing и panel) не переезжает
    # на корень: включение/выключение заглушки не меняет адрес панели.
    if [[ -n "$PANEL_PATH" && "$PANEL_PATH" != "/" && "$PANEL_PATH" != "./" ]]; then
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
    if [[ -n "$panel_loc" ]]; then
        # Панель на скрытом пути → корень всегда заглушка (адрес панели фиксирован)
        root_loc="    location / {
        root ${LANDING_DIR};
        index index.html;
    }"
    elif [[ "$mode" == "landing" ]]; then
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
    # Второй server-блок для корневого домена (заглушка со своим сертификатом):
    # при панели на поддомене (p.plesav.ru) корень (plesav.ru) тоже должен
    # отвечать правильно, иначе браузер видит чужой сертификат (name error).
    # Включается только в режиме stream-мастера, где оба домена слушает nginx,
    # и только если корневой SNI не занят REALITY/TLS-инбаундом (иначе трафик
    # корня идёт на passthrough, а заглушку отдаёт target-заглушка REALITY).
    local extra_block=""
    local root_dom=""
    root_dom="$(domain_root "$PANEL_HOST")"
    local root_taken=""
    if [[ "$STREAM_443_MASTER" == "1" && -n "$root_dom" && "$root_dom" != "$PANEL_HOST" \
        && -f "/etc/letsencrypt/live/${root_dom}/fullchain.pem" ]]; then
        root_taken="$(sqlite3 "$XUI_DB" "SELECT port FROM inbounds WHERE protocol IN ('vless','vmess','trojan') AND port != ${STREAM_MASTER_PORT:-443} AND listen = '127.0.0.1' AND stream_settings LIKE '%\"network\": \"tcp\"%' AND (stream_settings LIKE '%\"serverNames\": [\"$(sql_escape "$root_dom")\"]%' OR stream_settings LIKE '%\"serverName\": \"$(sql_escape "$root_dom")\"%') LIMIT 1;" 2>/dev/null || true)"
        [[ -z "$root_taken" ]] || warn "SNI корневого домена ${root_dom} занят инбаундом (порт ${root_taken}) — отдельный server-блок заглушки не нужен (заглушку отдаёт REALITY)."
    fi
    if [[ -z "$root_taken" && "$STREAM_443_MASTER" == "1" && -n "$root_dom" \
        && "$root_dom" != "$PANEL_HOST" \
        && -f "/etc/letsencrypt/live/${root_dom}/fullchain.pem" ]]; then
        extra_block="
server {
${listen_dir}
    ssl_certificate     /etc/letsencrypt/live/${root_dom}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${root_dom}/privkey.pem;
    server_name ${root_dom};
${snippet_line}

${root_loc}
}
"
    fi
    cat > "$file" <<EOF
server {
${listen_dir}
${ssl_lines}
    server_name ${sname};
${snippet_line}

${panel_loc}${sub_loc}${root_loc}
}
${extra_block}
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
    local site_default="" site_title=""
    site_default="$(domain_root "$PANEL_HOST")"
    [[ -n "$site_default" ]] || site_default="$(external_addr)"
    ask "Название сайта для заглушки" "$site_default" site_title
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

# disable_landing — выключает заглушку на корне.
# Адрес панели при этом НЕ меняется: если у панели скрытый путь (webBasePath),
# она остаётся на /<путь>/, а корень — заглушка (панель никогда не переезжает
# на корень; раньше panel-режим писал location / → панель, теряя путь).
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
    CLIENT_SECRET=""
    INBOUND_ID=""; WS_PATH=""; WS_HOST=""; SNI=""; LISTEN=""
    REALITY_PRIVATE_KEY=""; REALITY_PUBLIC_KEY=""; REALITY_SHORT_ID=""; REALITY_SNI=""
    CHANNEL_SNI=""; CHANNEL_CERT_DIR=""; REUSE_CLIENT=""; EXISTING_CLIENT_ID=""; CLIENT_SELECT=""

    menu_protocol

    # Протокол порта (UDP для hysteria)
    if [[ "$PROTOCOL" == "hysteria"* ]]; then
        CHANNEL_PROTO="udp"
    else
        CHANNEL_PROTO="tcp"
    fi
    pick_port PORT "$CHANNEL_PROTO"

    # Remark и клиент
    local def_remark def_email def_subid
    def_remark="$(channel_name_label "$PROTOCOL" "$TRANSPORT" "$SECURITY" "$PORT")"
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
    # XTLS Vision несовместим с xhttp (flow принудительно сбрасывается — иначе
    # сервер молча рвёт соединение), в т.ч. при переиспользовании клиента.
    if [[ "$TRANSPORT" == "xhttp" && -n "$CLIENT_FLOW" ]]; then
        info "flow сброшен для $TRANSPORT (Vision несовместим)."
        CLIENT_FLOW=""
    fi
    CLIENT_JSON="$(gen_client "$PROTOCOL")"

    # Параметры пути и REALITY
    case "$TRANSPORT" in
        xhttp)
            # Путь XHTTP — уникальный location прямого TCP-порта, формат /x<hex>.
            while true; do
                ask "Путь XHTTP (уникальный, формат /x<name>)" "/x$(gen_hex 5)" WS_PATH
                if db_path_in_use "$WS_PATH"; then
                    warn "Путь $WS_PATH уже используется другим инбаундом."
                    confirm "Продолжить с тем же путём?" || continue
                fi
                break
            done
            ;;
    esac
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
                warn "При одинаковом SNI инбаунды на одном порту не различить."
                continue
            fi
            break
        done
        REALITY_SNI="$CHANNEL_SNI"
        SNI="$REALITY_SNI"
        # XHTTP+REALITY слушает прямой TCP-порт без nginx: target — внешний
        # домен поддомена:443 (сайт-прикрытие для REALITY-хендшейка).
        REALITY_TARGET="${REALITY_SNI}:443"
        gen_reality_keys
        REALITY_SETTINGS_JSON="$(reality_settings "$REALITY_TARGET" "$REALITY_SNI")"
        info "REALITY: домен=${REALITY_SNI}, target=${REALITY_TARGET}, ключи сгенерированы."
    fi

    local settings_json stream_json snf_json
    settings_json="$(build_settings "$PROTOCOL" "$CLIENT_JSON")"
    stream_json="$(build_stream "$TRANSPORT" "$WS_PATH" "$WS_HOST" "$SNI")"

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

    # Прямые порты инбаундов (без прокси) открываем в firewall.
    firewall_port_open "$PORT" "$CHANNEL_PROTO"

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
    sync_panel_webcert
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
