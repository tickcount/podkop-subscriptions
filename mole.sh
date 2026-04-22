#!/bin/sh
# OpenWRT 24.10 / BusyBox ash
# Subscription manager for Podkop
# Developer: Salvatore (GitHub: @tickcount)

set -eu

SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"
MOLE_VERSION="0.1.0"
MOLE_REPO="tickcount/podkop-subscriptions"
MOLE_RAW_URL="https://raw.githubusercontent.com/${MOLE_REPO}/refs/heads/main/mole.sh"

# ─── UCI config: /etc/config/mole ──────────────────────────────────

# ensure_mole_config — create /etc/config/mole with defaults if absent;
#                        migrate existing config (add missing settings section,
#                        bump schema where needed)
ensure_mole_config() {
    if [ -f /etc/config/mole ]; then
        uci -q get mole.settings >/dev/null 2>&1 || {
            uci set mole.settings=settings
            uci commit mole
        }
        # ── Schema v1: switch default UA from clash-verge (triggers YAML on
        #             Remnawave) to v2raytun/ios (plain base64 URI list).
        _sv="$(uci -q get mole.settings.schema_version 2>/dev/null || echo 0)"
        case "$_sv" in ''|*[!0-9]*) _sv=0 ;; esac
        if [ "$_sv" -lt 1 ]; then
            _cur_ua="$(uci -q get mole.settings.user_agent 2>/dev/null || echo "")"
            case "$_cur_ua" in
                clash-verge/*|clash-*|Clash*|Mihomo*|v2rayN/*|'')
                    uci set mole.settings.user_agent='v2raytun/ios'
                    ;;
            esac
            uci set mole.settings.schema_version='1'
            uci commit mole
        fi
        # ── Schema v2: decode stale `announce=base64:<b64>` values that
        #             the earlier decode_announce (which gated on LC_ALL=C
        #             [[:print:]]) failed to unwrap for UTF-8 Cyrillic.
        if [ "$_sv" -lt 2 ]; then
            _mig_subs="$(uci -q show mole 2>/dev/null \
                | awk -F'[.=]' '/^mole\.[^.@]+=subscription$/ {print $2}')"
            for _mig_s in $_mig_subs; do
                _mig_a="$(uci -q get "mole.${_mig_s}.announce" 2>/dev/null || echo "")"
                case "$_mig_a" in
                    "base64:"*)
                        _mig_b="${_mig_a#base64:}"
                        _mig_d="$(printf '%s' "$_mig_b" | base64 -d 2>/dev/null || true)"
                        if [ -n "$_mig_d" ]; then
                            uci set "mole.${_mig_s}.announce=${_mig_d}"
                        fi
                        ;;
                esac
            done
            uci set mole.settings.schema_version='2'
            uci commit mole
        fi
        return 0
    fi
    cat > /etc/config/mole <<'UCICFG'
config settings 'settings'
    option schema_version '2'
    option cron_schedule '0 */3 * * *'
    option cron_enabled '0'
    option download_timeout '40'
    option connect_timeout '10'
    option user_agent 'v2raytun/ios'
    option ping_count '1'
    option ping_timeout '2'
    option enrich_enabled '1'
    option enrich_source 'cymru'
    option enrich_cache_ttl '604800'
    option log_path '/tmp/mole.log'
    option pool_dir '/etc/mole/pool'
    option cache_dir '/tmp/mole'
UCICFG
    uci commit mole
}

# _scfg KEY DEFAULT — read a mole.settings option with fallback
_scfg() { uci -q get "mole.settings.$1" 2>/dev/null || echo "$2"; }

# mole_config_load — populate CFG_* variables from UCI
mole_config_load() {
    CFG_CRON_SCHEDULE="$(_scfg cron_schedule     '0 */3 * * *')"
    CFG_CRON_ENABLED="$(_scfg cron_enabled        '0')"
    CFG_DOWNLOAD_TIMEOUT="$(_scfg download_timeout '40')"
    CFG_CONNECT_TIMEOUT="$(_scfg connect_timeout   '10')"
    CFG_USER_AGENT="$(_scfg user_agent             'clash-verge/v1.5.11')"
    CFG_ENRICH_ENABLED="$(_scfg enrich_enabled     '1')"
    CFG_ENRICH_SOURCE="$(_scfg enrich_source       'cymru')"
    CFG_ENRICH_CACHE_TTL="$(_scfg enrich_cache_ttl '604800')"
    CFG_LOG_PATH="$(_scfg log_path                 '/tmp/mole.log')"
    CFG_POOL_DIR="$(_scfg pool_dir                 '/etc/mole/pool')"
    CFG_CACHE_DIR="$(_scfg cache_dir               '/tmp/mole')"
    DOWNLOAD_RETRIES=3
}

ensure_mole_config
mole_config_load

mkdir -p "$CFG_POOL_DIR" "$CFG_CACHE_DIR" 2>/dev/null || true

# ─── Package manager abstraction ─────────────────────────────────────

PKG_IS_APK=0
command -v apk >/dev/null 2>&1 && PKG_IS_APK=1

pkg_update() {
    if [ "$PKG_IS_APK" -eq 1 ]; then apk update; else opkg update; fi
}

pkg_install() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk add --allow-untrusted "$@"
    else
        opkg install "$@"
    fi
}

pkg_is_installed() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk list --installed 2>/dev/null | grep -q "$1"
    else
        opkg list-installed 2>/dev/null | grep -q "$1"
    fi
}

pkg_version() {
    if [ "$PKG_IS_APK" -eq 1 ]; then
        apk list --installed 2>/dev/null | grep "$1" | head -n1 | awk '{print $1}' | sed "s/^${1}-//"
    else
        opkg list-installed 2>/dev/null | grep "$1" | head -n1 | awk '{print $3}'
    fi
}

# ─── Colors (soft white-blue-violet palette — matches liminal) ───────

W="\033[38;5;255m"            # clean bright white
B="\033[38;5;111m"            # soft blue
V="\033[38;5;141m"            # soft violet
A="\033[38;5;146m"            # soft steel blue (labels)
DIM="\033[2m\033[38;5;240m"   # very faded — box frames only
DIM2="\033[38;5;245m"         # readable dim gray — inline content hints
OK="\033[38;5;114m"           # soft green
WARN_C="\033[38;5;180m"       # soft wheat/amber
ERR="\033[38;5;174m"          # soft rose/red
NC="\033[0m"

# ─── Icons & box-drawing ─────────────────────────────────────────────

# First 3 bytes of a UTF-8 regional-indicator symbol (U+1F1E6–U+1F1FF).
# Used to detect flag emoji at the start of a node name so we don't double
# it with the Cymru-derived flag column.
RI_PREFIX="$(printf '\xf0\x9f\x87')"

ICO_ON="${OK}●${NC}"
ICO_OFF="${ERR}●${NC}"
ICO_DIS="${DIM2}○${NC}"
ICO_OK="${OK}✓${NC}"
ICO_ERR="${ERR}✗${NC}"
ICO_WARN="${WARN_C}!${NC}"

BOX_TL="╭" BOX_TR="╮" BOX_BL="╰" BOX_BR="╯"
BOX_H="─" BOX_V="│"

# ─── Box-drawing helpers ─────────────────────────────────────────────

box_top() {
    _w="${1:-54}"
    _line=""; _i=0; while [ "$_i" -lt "$_w" ]; do _line="${_line}${BOX_H}"; _i=$((_i+1)); done
    echo -e "${DIM}${BOX_TL}${_line}${BOX_TR}${NC}"
}

box_bot() {
    _w="${1:-54}"
    _line=""; _i=0; while [ "$_i" -lt "$_w" ]; do _line="${_line}${BOX_H}"; _i=$((_i+1)); done
    echo -e "${DIM}${BOX_BL}${_line}${BOX_BR}${NC}"
}

box_sep() {
    _w="${1:-54}"
    _line=""; _i=0; while [ "$_i" -lt "$_w" ]; do _line="${_line}${BOX_H}"; _i=$((_i+1)); done
    echo -e "${DIM}├${_line}┤${NC}"
}

box_line() {
    echo -e "${DIM}${BOX_V}${NC} $1"
}

# ─── Auto-sizing box buffer ──────────────────────────────────────────

_BOX_BUF=""
_BOX_BUF_SEP="$(printf '\037')"

box_buf_reset() { _BOX_BUF=""; }
box_buf_line()  { _BOX_BUF="${_BOX_BUF}${1}${_BOX_BUF_SEP}"; }
box_buf_sep()   { _BOX_BUF="${_BOX_BUF}__BOXSEP__${_BOX_BUF_SEP}"; }

_visible_bytes() {
    _vb="$(printf '%b' "$1" 2>/dev/null | sed 's/\x1b\[[0-9;]*[mGKHJ]//g')"
    echo "${#_vb}"
}

box_buf_flush() {
    _bf_min="${1:-44}"; _bf_max="${2:-100}"
    _bf_w="$_bf_min"
    _bf_rest="$_BOX_BUF"
    while [ -n "$_bf_rest" ]; do
        _bf_line="${_bf_rest%%${_BOX_BUF_SEP}*}"
        case "$_bf_rest" in
            *"${_BOX_BUF_SEP}"*) _bf_rest="${_bf_rest#*${_BOX_BUF_SEP}}" ;;
            *) _bf_rest="" ;;
        esac
        [ -z "$_bf_line" ] && continue
        [ "$_bf_line" = "__BOXSEP__" ] && continue
        _bf_len="$(_visible_bytes "$_bf_line")"
        _bf_len=$((_bf_len + 2))
        [ "$_bf_len" -gt "$_bf_w" ] && _bf_w="$_bf_len"
    done
    [ "$_bf_w" -gt "$_bf_max" ] && _bf_w="$_bf_max"

    box_top "$_bf_w"
    _bf_rest="$_BOX_BUF"
    while [ -n "$_bf_rest" ]; do
        _bf_line="${_bf_rest%%${_BOX_BUF_SEP}*}"
        case "$_bf_rest" in
            *"${_BOX_BUF_SEP}"*) _bf_rest="${_bf_rest#*${_BOX_BUF_SEP}}" ;;
            *) _bf_rest="" ;;
        esac
        if [ "$_bf_line" = "__BOXSEP__" ]; then
            box_sep "$_bf_w"
        else
            box_line "$_bf_line"
        fi
    done
    box_bot "$_bf_w"
    box_buf_reset
    return 0
}

# ─── Breadcrumbs ─────────────────────────────────────────────────────

_CRUMBS=""
crumb_set()  { _CRUMBS="$*"; }
crumb_push() { [ -n "$_CRUMBS" ] && _CRUMBS="${_CRUMBS} > $1" || _CRUMBS="$1"; }
crumb_pop()  { _CRUMBS="$(echo "$_CRUMBS" | sed 's/ > [^>]*$//')"; }
crumb_show() {
    [ -z "$_CRUMBS" ] && return
    echo -e "${DIM2}${_CRUMBS}${NC}"
    echo ""
}

# ─── Spinner ─────────────────────────────────────────────────────────

_SPIN_PID=""
_spin_frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

spinner_start() {
    _msg="${1:-Working...}"
    (
        _idx=0
        while true; do
            _ch="$(printf '%s' "$_spin_frames" | cut -c$((_idx % 10 + 1)))"
            printf '\r  %b %b' "${V}${_ch}${NC}" "${A}${_msg}${NC}" >&2
            _idx=$((_idx + 1))
            sleep 0.1 2>/dev/null || sleep 1
        done
    ) &
    _SPIN_PID=$!
}

spinner_stop() {
    [ -n "$_SPIN_PID" ] && kill "$_SPIN_PID" 2>/dev/null; wait "$_SPIN_PID" 2>/dev/null || true
    _SPIN_PID=""
    # Clear the spinner line. `\033[2K` erases the entire line on capable
    # terminals; the trailing space-pad is a fallback for minimal TERMs
    # (some busybox-over-ssh clients ignore CSI sequences).
    printf '\r\033[2K\r                                                                                \r' >&2
}

# ─── SIGINT handling ─────────────────────────────────────────────────

_SIGINT=0

on_error() {
    _SIGINT=1
    echo ""
}

trap on_error INT

_CANCELLED=0

trap_cancel() {
    _CANCELLED=0
    trap '_CANCELLED=1; trap on_error INT' INT
}

trap_restore() {
    trap on_error INT
}

is_cancelled() { [ "$_CANCELLED" -eq 1 ]; }

sigint_caught() {
    [ "$_SIGINT" -eq 1 ] || return 1
    _SIGINT=0
    return 0
}

# ─── Common helpers ──────────────────────────────────────────────────

log()  { printf '%s\n' "$*"; }
warn() { echo -e "  ${ERR}${ICO_WARN} warning:${NC} $*" >&2; }
die()  { echo -e "  ${ERR}${ICO_ERR} error:${NC} $*" >&2; exit 1; }
cancelled() { echo -e "  ${DIM2}Cancelled${NC}"; }

PAUSE() {
    echo -ne "\n  ${DIM2}Press Enter...${NC}"
    read dummy || true
    _SIGINT=0
}

section() {
    _stitle="$1"; _slen=${#_stitle}; _spad=$((34 - _slen))
    [ "$_spad" -lt 1 ] && _spad=1
    _sline=""; _si=0; while [ "$_si" -lt "$_spad" ]; do _sline="${_sline}─"; _si=$((_si+1)); done
    echo -e "\n  ${DIM2}──${NC} ${V}${_stitle}${NC} ${DIM2}${_sline}${NC}\n"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# log_event MSG... — append a timestamped line to CFG_LOG_PATH. Never fails
# (log file not yet available, permissions, etc.). Used for every operational
# event so `v › View logs` reflects history — not just --cron output.
log_event() {
    [ -z "${CFG_LOG_PATH:-}" ] && return 0
    mkdir -p "$(dirname "$CFG_LOG_PATH")" 2>/dev/null || true
    _le_ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
    printf '[%s] %s\n' "$_le_ts" "$*" >> "$CFG_LOG_PATH" 2>/dev/null || true
}

# ─── Input helpers ───────────────────────────────────────────────────

prompt() {
    _var="$1"; _q="$2"; _def="${3:-}"
    if [ -n "$_def" ]; then
        printf "  %s [%b%s%b]: " "$_q" "$DIM2" "$_def" "$NC"
    else
        printf "  %s: " "$_q"
    fi
    read -r _ans || true
    is_cancelled && { eval "$_var="; return 1; }
    _ans="$(printf '%s' "${_ans:-}" | tr -d '\001-\037\177')"
    [ -z "${_ans:-}" ] && _ans="$_def"
    eval "$_var=\$_ans"
}

confirm() {
    _q="$1"; _def="${2:-y}"
    if [ "$_def" = "y" ]; then
        echo -ne "  ${_q} [${OK}Y${NC}/${DIM2}n${NC}] "
    else
        echo -ne "  ${_q} [${DIM2}y${NC}/${ERR}N${NC}] "
    fi
    read -r _ans || true
    _ans="$(printf '%s' "${_ans:-}" | tr -d '\001-\037\177')"
    case "${_ans:-}" in
        1|y|Y|yes) return 0 ;;
        2|n|N|no)  return 1 ;;
        "")
            [ "$_def" = "y" ] && return 0 || return 1 ;;
        *)
            [ "$_def" = "y" ] && return 0 || return 1 ;;
    esac
}

# read_choice VAR — single menu choice, ASCII alnum + '+' only.
read_choice() {
    read -r _rc_raw || true
    # Ctrl+C during read: discard any partial input and return empty so the
    # caller's "" branch triggers go-back.  Peek at _SIGINT without consuming
    # it (sigint_caught would reset it) so show_menu's double-tap exit check
    # still fires when we eventually unwind back to the main menu.
    if [ "${_SIGINT:-0}" -eq 1 ]; then
        eval "$1=''"
        return
    fi
    if [ -z "${_rc_raw:-}" ]; then
        eval "$1=''"
        return
    fi
    _rc_clean="$(printf '%s' "$_rc_raw" | LC_ALL=C tr -cd 'A-Za-z0-9+' 2>/dev/null || true)"
    [ -z "$_rc_clean" ] && _rc_clean="?"
    eval "$1=\$_rc_clean"
}

# ─── Network helpers ─────────────────────────────────────────────────

check_dns() {
    nslookup google.com >/dev/null 2>&1
}

check_internet() {
    ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && return 0
    ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && return 0
    have_cmd curl && curl -so /dev/null --connect-timeout 3 \
        http://connectivitycheck.gstatic.com/generate_204 2>/dev/null && return 0
    return 1
}

# wget_retry URL DEST [retries]
wget_retry() {
    _wr_url="$1"; _wr_dest="$2"; _wr_max="${3:-$DOWNLOAD_RETRIES}"
    _wr_attempt=0
    while [ "$_wr_attempt" -lt "$_wr_max" ]; do
        if wget -qO "$_wr_dest" "$_wr_url" 2>/dev/null; then
            [ -s "$_wr_dest" ] && return 0
        fi
        rm -f "$_wr_dest"
        _wr_attempt=$((_wr_attempt + 1))
    done
    return 1
}

# ─── Subscription & group helpers ────────────────────────────────────

# sub_count — number of `config subscription` sections
sub_count() {
    iterate_sub_names | awk 'NF' | wc -l | tr -d ' '
}

# group_count — number of `config group` sections
group_count() {
    iterate_group_names | awk 'NF' | wc -l | tr -d ' '
}

# iterate_sub_names — print UCI names of all subscription sections, one per line
iterate_sub_names() {
    uci -q show mole 2>/dev/null \
        | awk -F'[.=]' '/^mole\.[^.@]+=subscription$/ {print $2}'
}

# iterate_group_names — print UCI names of all group sections, one per line
iterate_group_names() {
    uci -q show mole 2>/dev/null \
        | awk -F'[.=]' '/^mole\.[^.@]+=group$/ {print $2}'
}

# _uci_get SECTION KEY [DEFAULT] — read mole.SECTION.KEY with fallback
_uci_get() {
    _v="$(uci -q get "mole.$1.$2" 2>/dev/null || true)"
    if [ -n "$_v" ]; then printf '%s' "$_v"; else printf '%s' "${3:-}"; fi
}

sub_get()   { _uci_get "$@"; }
group_get() { _uci_get "$@"; }

# next_cron_run SCHEDULE — best-effort human hint (stub until cron screen lands)
next_cron_run() {
    _cs="$1"
    [ -z "$_cs" ] && { echo "-"; return; }
    printf '%s' "$_cs"
}

# podkop_present — is podkop package installed (for status box)
podkop_present() {
    [ -f /etc/config/podkop ] || [ -x /etc/init.d/podkop ]
}

# ─── Podkop integration ──────────────────────────────────────────────
#
# Ownership model (liminal-style): each podkop section we manage gets a
# marker option `podkop.<name>._mole_section='<tag>'`; a mirror record lives
# under `mole.<tag>=podkop_section` with source_group list + target_list.
#
# Flush semantics: we compute sha256 over the sorted-unique planned URI list
# and the sorted-unique list currently in `podkop.<name>.<target_list>`. We
# only `uci delete + add_list + commit + podkop reload` when those hashes
# differ — reordering the same set triggers no reload.

# Protocols podkop actually accepts in urltest/selector links. vmess:// and
# tuic:// are silently dropped at flush time (podkop's validator rejects them).
PODKOP_ACCEPTED='ss://|vless://|trojan://|socks4://|socks4a://|socks5://|hysteria2://|hy2://'

# Enumerate all podkop section names (type `section`, not `settings`).
podkop_enumerate_sections() {
    [ -f /etc/config/podkop ] || return 0
    uci -q show podkop 2>/dev/null \
        | awk -F'[.=]' '/^podkop\.[^.@]+=section$/ {print $2}'
}

# podkop_section_owner NAME — print the mole tag that owns this section,
# or empty if unmanaged. Marker lives at podkop.<name>._mole_section.
podkop_section_owner() {
    uci -q get "podkop.$1._mole_section" 2>/dev/null || true
}

# mole_managed_sections — print our tag list (UCI names of `podkop_section`
# records). These are the sections we actively manage.
mole_managed_sections() {
    uci -q show mole 2>/dev/null \
        | awk -F'[.=]' '/^mole\.[^.@]+=podkop_section$/ {print $2}'
}

# ps_get TAG KEY [DEFAULT] — read mole.TAG.KEY with fallback
ps_get() { _uci_get "$@"; }

# ps_sources TAG — space-separated list of group_ids feeding this section
ps_sources() {
    uci -q get "mole.$1.source_group" 2>/dev/null || true
}

# canonical_hash — strip #fragment, sort -u, sha256sum, print first 16 hex
# chars. Fragment is a display name only — stripping it makes flush detection
# robust to server-side display-name changes between refreshes.
canonical_hash() {
    sed 's/#.*//' 2>/dev/null \
        | sort -u 2>/dev/null \
        | { sha256sum 2>/dev/null || md5sum 2>/dev/null || cksum; } \
        | awk '{print substr($1,1,16)}'
}

# gather_planned_uris TAG — collect URIs from all source groups' subs,
# applying per-sub exclusions. Output: sorted unique list, one URI per line.
#
# Perf-critical: called on every Podkop Sections render and on every flush.
# Previously called parse_uri_hostport + 3 cuts + sha256sum per URI — that's
# ~5 subshells per URI × N URIs × M subs, which hit several seconds for
# real-world pool sizes. Inlined with POSIX parameter expansion: zero
# subshells per URI on the hot path (no exclusions), one sha256sum per URI
# only when link-exclusions are active.
gather_planned_uris() {
    _gpu_tag="$1"
    _gpu_tmp="${CFG_CACHE_DIR}/planned.${_gpu_tag}.$$"
    : > "$_gpu_tmp"
    _gpu_sources="$(ps_sources "$_gpu_tag")"
    for _gpu_g in $_gpu_sources; do
        group_exists "$_gpu_g" || continue
        for _gpu_s in $(subs_in_group "$_gpu_g"); do
            _gpu_en="$(sub_get "$_gpu_s" enabled 1)"
            [ "$_gpu_en" = "0" ] && continue
            _gpu_pool="$(sub_pool_file "$_gpu_s")"
            [ -f "$_gpu_pool" ] && [ -s "$_gpu_pool" ] || continue
            _gpu_excl_p="$(compute_effective_excludes "$_gpu_s")"
            _gpu_excl_l="$(sub_link_excludes "$_gpu_s")"
            while IFS= read -r _gpu_uri; do
                [ -z "$_gpu_uri" ] && continue
                # Extract proto via parameter expansion (no subshell)
                _gpu_proto="${_gpu_uri%%://*}"
                # Drop unsupported schemes + proto-excludes in one case match
                case "$_gpu_proto" in
                    ss|vless|trojan|socks4|socks4a|socks5|hysteria2|hy2) ;;
                    *) continue ;;
                esac
                if [ -n "$_gpu_excl_p" ]; then
                    case " $_gpu_excl_p " in *" $_gpu_proto "*) continue ;; esac
                fi
                # Link-exclude path: compute link_id (URI minus fragment+query)
                # and check against the stored exclusion list.
                if [ -n "$_gpu_excl_l" ]; then
                    _gpu_nofrag="${_gpu_uri%%#*}"
                    _gpu_lid="$(printf '%s' "${_gpu_nofrag%%\?*}" | { sha256sum 2>/dev/null || md5sum 2>/dev/null || cksum; } | awk '{print substr($1,1,12)}')"
                    case " $_gpu_excl_l " in *" $_gpu_lid "*) continue ;; esac
                fi
                printf '%s\n' "$_gpu_uri" >> "$_gpu_tmp"
            done < "$_gpu_pool"
        done
    done
    sort -u < "$_gpu_tmp"
    rm -f "$_gpu_tmp"
}

# ps_link_list TAG — returns the UCI list name matching this section's proxy mode.
ps_link_list() {
    case "$(ps_get "$1" proxy_mode "urltest")" in
        selector) printf 'selector_proxy_links' ;;
        *)        printf 'urltest_proxy_links' ;;
    esac
}

# podkop_current_uris NAME TARGET_LIST — print URIs currently in
# podkop.<name>.<target_list>, one per line.
podkop_current_uris() {
    _pcu_n="$1"; _pcu_l="$2"
    [ -f /etc/config/podkop ] || return 0
    # `uci get` joins list entries with spaces; re-split via tr. URIs don't
    # contain raw spaces (they'd be URL-encoded), so this is safe.
    _pcu_raw="$(uci -q get "podkop.${_pcu_n}.${_pcu_l}" 2>/dev/null || true)"
    printf '%s' "$_pcu_raw" | tr ' ' '\n' | awk 'NF'
}

# podkop_needs_flush TAG — 0 if planned_hash differs from podkop_current_hash.
# Mode-aware: reads from the list type matching the section's proxy_mode.
podkop_needs_flush() {
    _pnf_tag="$1"
    _pnf_name="$(ps_get "$_pnf_tag" podkop_name "$_pnf_tag")"
    _pnf_list="$(ps_link_list "$_pnf_tag")"
    _pnf_planned="$(gather_planned_uris "$_pnf_tag" | canonical_hash)"
    _pnf_current="$(podkop_current_uris "$_pnf_name" "$_pnf_list" | canonical_hash)"
    [ "$_pnf_planned" != "$_pnf_current" ]
}

# podkop_flush TAG — push planned URIs to podkop's proxy list.
# Mode-aware: writes to urltest_proxy_links or selector_proxy_links based on
# the section's stored proxy_mode. Ensures connection_type=proxy.
# Returns 0 on flushed (URI set changed), 1 on no-op (already in sync).
podkop_flush() {
    _pf_tag="$1"
    _pf_name="$(ps_get "$_pf_tag" podkop_name "$_pf_tag")"
    _pf_mode="$(ps_get "$_pf_tag" proxy_mode "urltest")"
    case "$_pf_mode" in urltest|selector) ;; *) _pf_mode="urltest" ;; esac
    _pf_link_list="${_pf_mode}_proxy_links"
    _pf_planned_file="${CFG_CACHE_DIR}/flush.${_pf_tag}.$$"
    gather_planned_uris "$_pf_tag" > "$_pf_planned_file"
    _pf_planned_hash="$(canonical_hash < "$_pf_planned_file")"
    _pf_current_hash="$(podkop_current_uris "$_pf_name" "$_pf_link_list" | canonical_hash)"
    _pf_count="$(awk 'NF' "$_pf_planned_file" | wc -l | tr -d ' ')"

    if [ "$_pf_planned_hash" = "$_pf_current_hash" ]; then
        rm -f "$_pf_planned_file"
        uci set "mole.${_pf_tag}.last_flushed_hash=${_pf_planned_hash}"
        uci set "mole.${_pf_tag}.last_flush_count=${_pf_count}"
        uci commit mole
        log_event "flush ${_pf_tag} noop ${_pf_count} links"
        return 1
    fi

    # Always clear both lists so there's exactly one canonical pool.
    uci -q delete "podkop.${_pf_name}.selector_proxy_links" 2>/dev/null || true
    uci -q delete "podkop.${_pf_name}.urltest_proxy_links" 2>/dev/null || true
    while IFS= read -r _pf_u; do
        [ -z "$_pf_u" ] && continue
        uci add_list "podkop.${_pf_name}.${_pf_link_list}=${_pf_u}"
    done < "$_pf_planned_file"
    uci set "podkop.${_pf_name}.connection_type=proxy"
    uci set "podkop.${_pf_name}.proxy_config_type=${_pf_mode}"
    uci set "podkop.${_pf_name}._mole_section=${_pf_tag}"
    uci commit podkop

    uci set "mole.${_pf_tag}.last_flushed_hash=${_pf_planned_hash}"
    uci set "mole.${_pf_tag}.last_flush_count=${_pf_count}"
    uci set "mole.${_pf_tag}.last_flush_ts=$(date +%s 2>/dev/null || echo 0)"
    uci commit mole

    rm -f "$_pf_planned_file"
    # After flush, podkop's tag ordering has shifted — invalidate any cached
    # /proxies JSON so the next section-view render pulls fresh history.
    invalidate_latency_cache
    log_event "flush ${_pf_tag} ok ${_pf_count} links (hash ${_pf_planned_hash})"
    return 0
}

# podkop_restart — restart podkop service (liminal-style svc_restart).
# Podkop's init script runs `stop_main; start_main` on restart anyway, and
# reload is effectively the same call without the dnsmasq touch. Using
# restart directly matches what liminal does (`svc_restart podkop`).
podkop_restart() {
    [ -x /etc/init.d/podkop ] || return 0
    log_event "podkop restart"
    /etc/init.d/podkop restart >/dev/null 2>&1 || true
}

# flush_all_auto [silent=0] — flush every managed section whose URI set
# changed. One podkop reload at the end for all of them.
flush_all_auto() {
    _faa_silent="${1:-0}"
    _faa_changed=0
    _faa_any=0
    for _faa_tag in $(mole_managed_sections); do
        _faa_any=1
        if podkop_flush "$_faa_tag"; then
            _faa_changed=$((_faa_changed + 1))
            if [ "$_faa_silent" = "0" ]; then
                _faa_n="$(ps_get "$_faa_tag" last_flush_count 0)"
                echo -e "  ${ICO_OK} ${OK}Flushed${NC} ${W}$(ps_get "$_faa_tag" podkop_name "$_faa_tag")${NC} ${DIM2}(${_faa_n} links)${NC}"
            fi
        fi
    done
    if [ "$_faa_any" = "0" ]; then
        [ "$_faa_silent" = "0" ] && echo -e "  ${DIM2}No managed podkop sections${NC}"
        return 0
    fi
    if [ "$_faa_changed" -gt 0 ]; then
        [ "$_faa_silent" = "0" ] && printf "  %bRestarting podkop%b ... " "$W" "$NC"
        podkop_restart
        [ "$_faa_silent" = "0" ] && echo -e "${ICO_OK}"
    else
        [ "$_faa_silent" = "0" ] && echo -e "  ${DIM2}In sync — no restart needed${NC}"
    fi
}

# mole_any_dirty — 0 if any managed section needs a flush (used for the
# dirty indicator on the main menu status box).
mole_any_dirty() {
    for _sad_tag in $(mole_managed_sections); do
        podkop_needs_flush "$_sad_tag" && return 0
    done
    return 1
}

# ─── Clash API latency (via podkop shell helper) ─────────────────────
#
# Single shared cache of podkop's `/proxies` JSON — sing-box's own URLTest
# engine automatically re-probes every urltest_check_interval (3m default)
# and updates `history[0].delay`, so we just need to read it. Cache with a
# short TTL to avoid hammering on rapid re-renders.
LATENCY_CACHE_TTL=5

latency_cache_file() {
    printf '%s/latency.cache' "$CFG_CACHE_DIR"
}

# fetch_proxies_json — print /proxies JSON. Uses short-TTL cache. Empty on
# failure (no podkop, not running, API not reachable).
fetch_proxies_json() {
    _fpj_cache="$(latency_cache_file)"
    if [ -f "$_fpj_cache" ]; then
        _fpj_age=$(( $(date +%s 2>/dev/null || echo 0) - $(stat -c %Y "$_fpj_cache" 2>/dev/null || echo 0) ))
        if [ "$_fpj_age" -ge 0 ] && [ "$_fpj_age" -lt "$LATENCY_CACHE_TTL" ]; then
            cat "$_fpj_cache" 2>/dev/null
            return 0
        fi
    fi
    [ -x /usr/bin/podkop ] || return 1
    _fpj_json="$(/usr/bin/podkop clash_api get_proxies 2>/dev/null)"
    [ -z "$_fpj_json" ] && return 1
    mkdir -p "$(dirname "$_fpj_cache")" 2>/dev/null || true
    printf '%s' "$_fpj_json" > "$_fpj_cache"
    printf '%s' "$_fpj_json"
}

# invalidate_latency_cache — force next fetch to hit podkop. Call after flush
# because URI ordering (and thus tag assignment) may have shifted.
invalidate_latency_cache() {
    rm -f "$(latency_cache_file)" 2>/dev/null || true
}

# trigger_latency_test TAG — force a fresh probe for the whole URLTest group.
# Updates sing-box's internal history; our next fetch_proxies_json picks it up.
trigger_latency_test() {
    _tlt_tag="$1"
    _tlt_name="$(ps_get "$_tlt_tag" podkop_name "$_tlt_tag")"
    [ -x /usr/bin/podkop ] || return 1
    have_cmd jq || return 1
    /usr/bin/podkop clash_api get_group_latency "${_tlt_name}-urltest-out" 10000 >/dev/null 2>&1
    invalidate_latency_cache
    log_event "latency test ${_tlt_tag}"
}

# build_uri_ms_map TAG — build a TSV of URI → ms for the section. Planned
# URIs (sorted) → tag index N → lookup via `/proxies` response.
# Writes to stdout: "<uri>\t<ms>" per line. ms may be empty for un-probed.
build_uri_ms_map() {
    _bum_tag="$1"
    _bum_name="$(ps_get "$_bum_tag" podkop_name "$_bum_tag")"
    _bum_json="$(fetch_proxies_json)"
    [ -z "$_bum_json" ] && return 1
    have_cmd jq || return 1

    _bum_planned_file="${CFG_CACHE_DIR}/bum_planned.${_bum_tag}.$$"
    gather_planned_uris "$_bum_tag" > "$_bum_planned_file"

    # Extract tag → ms from /proxies, filtering to this section's members
    _bum_lat_file="${CFG_CACHE_DIR}/bum_lat.${_bum_tag}.$$"
    printf '%s' "$_bum_json" | jq -r --arg n "$_bum_name" '
        .proxies // {}
        | to_entries[]
        | select(
            (.key | startswith($n + "-"))
            and (.key | endswith("-out"))
            and (.key != ($n + "-urltest-out"))
          )
        | "\(.key)\t\(.value.history[0].delay // "")"
    ' 2>/dev/null > "$_bum_lat_file"

    # Join: for each planned URI at position N, find tag "<name>-N-out" and
    # emit "uri\tms". One awk pass over both files.
    awk -v prefix="${_bum_name}-" -v suffix="-out" -v FS='\t' '
        FNR==NR {
            # First file: planned URIs (sorted). NR = index.
            uris[FNR] = $0
            next
        }
        {
            # Second file: tag\tms. Extract N from tag.
            tag = $1; ms = $2
            # Strip prefix + suffix → should be pure integer
            n = tag
            sub("^" prefix, "", n)
            sub(suffix "$", "", n)
            if (n ~ /^[0-9]+$/ && uris[n]) {
                print uris[n] "\t" ms
            }
        }
    ' "$_bum_planned_file" "$_bum_lat_file"

    rm -f "$_bum_planned_file" "$_bum_lat_file"
}

# get_active_uri TAG — print the URI currently selected by sing-box's urltest
# outbound (the winning proxy). Uses cached /proxies JSON. Empty on failure.
get_active_uri() {
    _gau_tag="$1"
    _gau_name="$(ps_get "$_gau_tag" podkop_name "$_gau_tag")"
    _gau_json="$(fetch_proxies_json)"
    [ -z "$_gau_json" ] && return 0
    have_cmd jq || return 0

    _gau_active_tag="$(printf '%s' "$_gau_json" | jq -r \
        --arg key "${_gau_name}-urltest-out" \
        '.proxies[$key].now // ""' 2>/dev/null)"
    [ -z "$_gau_active_tag" ] || [ "$_gau_active_tag" = "null" ] && return 0

    # Extract N from "{name}-N-out"
    _gau_idx="${_gau_active_tag#${_gau_name}-}"
    _gau_idx="${_gau_idx%-out}"
    case "$_gau_idx" in ''|*[!0-9]*) return 0 ;; esac

    gather_planned_uris "$_gau_tag" | awk -v n="$_gau_idx" 'NR==n {print; exit}'
}

# ─── Adopt / unadopt / create podkop sections ────────────────────────

# adopt_podkop_section PODKOP_NAME — create mole tag record + set marker.
# Forces proxy_config_type=urltest on the podkop side. If the section was a
# selector, any URIs in selector_proxy_links are migrated to
# urltest_proxy_links so the pool isn't lost.
adopt_podkop_section() {
    _aps_n="$1"
    uci -q get "podkop.${_aps_n}" >/dev/null 2>&1 || return 1

    _aps_tag="$(slugify "$_aps_n")"
    [ -z "$_aps_tag" ] && _aps_tag="$_aps_n"
    _aps_sfx=2
    while uci -q get "mole.${_aps_tag}" >/dev/null 2>&1; do
        _aps_tag="$(slugify "$_aps_n")_${_aps_sfx}"
        _aps_sfx=$((_aps_sfx + 1))
    done

    # Preserve the existing proxy_config_type (urltest or selector) instead
    # of forcing urltest — let users keep their manually configured mode.
    _aps_cur_type="$(uci -q get "podkop.${_aps_n}.proxy_config_type" 2>/dev/null || echo "urltest")"
    case "$_aps_cur_type" in urltest|selector) ;; *) _aps_cur_type="urltest" ;; esac
    uci set "podkop.${_aps_n}.connection_type=proxy"
    uci set "podkop.${_aps_n}.proxy_config_type=${_aps_cur_type}"
    uci set "podkop.${_aps_n}._mole_section=${_aps_tag}"
    uci commit podkop

    uci set "mole.${_aps_tag}=podkop_section"
    uci set "mole.${_aps_tag}.podkop_name=${_aps_n}"
    uci set "mole.${_aps_tag}.proxy_mode=${_aps_cur_type}"
    uci set "mole.${_aps_tag}.last_flushed_hash="
    uci set "mole.${_aps_tag}.last_flush_count=0"
    uci set "mole.${_aps_tag}.last_flush_ts=0"
    uci commit mole

    log_event "adopt ${_aps_n} as ${_aps_tag}"
    echo "$_aps_tag"
}

# unadopt_podkop_section TAG — drop our record + strip marker (podkop section
# stays intact with whatever URIs it has right now)
unadopt_podkop_section() {
    _ups_tag="$1"
    _ups_n="$(ps_get "$_ups_tag" podkop_name "$_ups_tag")"
    uci -q delete "podkop.${_ups_n}._mole_section" 2>/dev/null || true
    uci commit podkop
    uci -q delete "mole.${_ups_tag}" 2>/dev/null || true
    uci commit mole
    log_event "unadopt ${_ups_tag} (${_ups_n})"
}


# ─── Formatting helpers ──────────────────────────────────────────────

# slugify STR — "Liberty VPN" → "liberty_vpn"
slugify() {
    printf '%s' "$1" \
        | LC_ALL=C tr -c 'a-zA-Z0-9' '_' \
        | tr 'A-Z' 'a-z' \
        | sed 's/__*/_/g; s/^_//; s/_$//'
}

# sanitize_uci_val VALUE — strip chars that corrupt UCI config file syntax.
# UCI wraps option values in single quotes; an embedded single quote truncates
# the value at parse time and can corrupt the entire config section.
sanitize_uci_val() {
    printf '%s' "$1" | tr -d "'\"\n\r\\"
}

# url_to_sub_id URL — deterministic UCI name (sub_XXXXXXXX) from URL hash
url_to_sub_id() {
    _h=""
    if have_cmd sha256sum; then
        _h="$(printf '%s' "$1" | sha256sum 2>/dev/null | awk '{print substr($1,1,8)}')"
    elif have_cmd md5sum; then
        _h="$(printf '%s' "$1" | md5sum 2>/dev/null | awk '{print substr($1,1,8)}')"
    fi
    [ -z "$_h" ] && _h="$(printf '%s' "$1" | cksum | awk '{printf "%08x", $1}')"
    echo "sub_${_h}"
}

# url_display URL [maxlen] — host + truncated path
url_display() {
    _ud_url="$1"; _ud_max="${2:-48}"
    _ud_short="$(printf '%s' "$_ud_url" | sed 's|^https\?://||; s|^www\.||')"
    _ud_len=${#_ud_short}
    if [ "$_ud_len" -gt "$_ud_max" ]; then
        _ud_short="$(printf '%s' "$_ud_short" | cut -c1-$((_ud_max - 3)))..."
    fi
    printf '%s' "$_ud_short"
}

# fmt_bytes BYTES — human-readable
fmt_bytes() {
    _fb="${1:-0}"
    case "$_fb" in ''|*[!0-9]*) _fb=0 ;; esac
    if [ "$_fb" -ge 1099511627776 ]; then
        awk -v b="$_fb" 'BEGIN{printf "%.1f TB", b/1099511627776}'
    elif [ "$_fb" -ge 1073741824 ]; then
        awk -v b="$_fb" 'BEGIN{printf "%.1f GB", b/1073741824}'
    elif [ "$_fb" -ge 1048576 ]; then
        awk -v b="$_fb" 'BEGIN{printf "%.1f MB", b/1048576}'
    elif [ "$_fb" -ge 1024 ]; then
        awk -v b="$_fb" 'BEGIN{printf "%.1f KB", b/1024}'
    else
        printf '%s B' "$_fb"
    fi
}

# fmt_traffic UP DN TOTAL — "1.2 GB / 5.0 GB" | "0.0 GB / ∞" | ""
fmt_traffic() {
    _ft_up="${1:-0}"; _ft_dn="${2:-0}"; _ft_tot="${3:-0}"
    case "$_ft_up"  in ''|*[!0-9]*) _ft_up=0  ;; esac
    case "$_ft_dn"  in ''|*[!0-9]*) _ft_dn=0  ;; esac
    case "$_ft_tot" in ''|*[!0-9]*) _ft_tot=0 ;; esac
    _ft_used="$(awk -v u="$_ft_up" -v d="$_ft_dn" 'BEGIN{print u+d}')"
    case "$_ft_used" in ''|*[!0-9]*) _ft_used=0 ;; esac
    if [ "$_ft_tot" != "0" ]; then
        printf '%s / %s' "$(fmt_bytes "$_ft_used")" "$(fmt_bytes "$_ft_tot")"
    else
        printf '%s / \xe2\x88\x9e' "$(awk -v b="$_ft_used" 'BEGIN{printf "%.1f GB", b/1073741824}')"
    fi
}

# fmt_days_until UNIX_TS — "18d" / "3h" / "expired" / "-"
fmt_days_until() {
    _du_ts="${1:-0}"
    case "$_du_ts" in ''|*[!0-9]*) _du_ts=0 ;; esac
    [ "$_du_ts" -le 0 ] && { printf '-'; return; }
    _du_now="$(date +%s 2>/dev/null || echo 0)"
    _du_diff=$((_du_ts - _du_now))
    if [ "$_du_diff" -le 0 ]; then
        printf 'expired'; return
    fi
    _du_d=$((_du_diff / 86400))
    if [ "$_du_d" -ge 1 ]; then
        printf '%sd' "$_du_d"
    else
        printf '%sh' $((_du_diff / 3600))
    fi
}

# fmt_age_since UNIX_TS — "12m ago" / "-"
fmt_age_since() {
    _as_ts="${1:-0}"
    case "$_as_ts" in ''|*[!0-9]*) _as_ts=0 ;; esac
    [ "$_as_ts" -le 0 ] && { printf '-'; return; }
    _as_now="$(date +%s 2>/dev/null || echo 0)"
    _as_diff=$((_as_now - _as_ts))
    [ "$_as_diff" -lt 0 ] && _as_diff=0
    if [ "$_as_diff" -lt 60 ]; then
        printf '%ss ago' "$_as_diff"
    elif [ "$_as_diff" -lt 3600 ]; then
        printf '%sm ago' $((_as_diff / 60))
    elif [ "$_as_diff" -lt 86400 ]; then
        printf '%sh ago' $((_as_diff / 3600))
    else
        printf '%sd ago' $((_as_diff / 86400))
    fi
}

# fmt_ts UNIX_TS — ISO-like "2026-04-22 14:30" / "-"
fmt_ts() {
    _ft="${1:-0}"
    case "$_ft" in ''|*[!0-9]*) _ft=0 ;; esac
    [ "$_ft" -le 0 ] && { printf '-'; return; }
    date -d "@$_ft" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$_ft"
}

# ─── HTTP helpers ────────────────────────────────────────────────────

# fetch_subscription URL HDR_DST BODY_DST — curl with metadata capture
fetch_subscription() {
    _fs_url="$1"; _fs_hdr="$2"; _fs_body="$3"
    rm -f "$_fs_hdr" "$_fs_body"
    curl -fsSL \
        --user-agent "$CFG_USER_AGENT" \
        --connect-timeout "$CFG_CONNECT_TIMEOUT" \
        --max-time "$CFG_DOWNLOAD_TIMEOUT" \
        --max-filesize 2097152 \
        --max-redirs 3 \
        --dump-header "$_fs_hdr" \
        "$_fs_url" -o "$_fs_body" 2>/dev/null
}

# hdr_get FILE NAME — extract header value (last occurrence, case-insensitive)
hdr_get() {
    _hg_file="$1"; _hg_name="$2"
    [ -f "$_hg_file" ] || return 0
    awk -v n="$_hg_name" '
        BEGIN { k = tolower(n) ":"; kl = length(k) }
        {
            lk = tolower(substr($0, 1, kl))
            if (lk == k) {
                v = substr($0, kl + 1)
                sub(/^[ \t]+/, "", v)
                sub(/\r$/, "", v)
                result = v
            }
        }
        END { print result }
    ' "$_hg_file"
}

# cd_filename HEADER_VALUE — extract filename from Content-Disposition, skip UUIDs
cd_filename() {
    _cdf_raw="$1"
    [ -z "$_cdf_raw" ] && return
    _cdf_fn="$(printf '%s' "$_cdf_raw" \
        | sed 's/.*[Ff]ilename[*]\{0,1\}="\{0,1\}\([^";]*\)"\{0,1\}.*/\1/' \
        | tr -d '\r')"
    # Discard if looks like a UUID (just the subscription ID repeated)
    case "$_cdf_fn" in
        [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-*) return ;;
    esac
    printf '%s' "$_cdf_fn"
}

# decode_profile_title VALUE — strip `base64:` prefix and decode
decode_profile_title() {
    _dpt="$1"
    case "$_dpt" in
        "base64:"*)
            _dpt_enc="${_dpt#base64:}"
            _dpt_dec="$(printf '%s' "$_dpt_enc" | base64 -d 2>/dev/null || true)"
            [ -n "$_dpt_dec" ] && printf '%s' "$_dpt_dec" || printf '%s' "$_dpt"
            ;;
        *)
            printf '%s' "$_dpt"
            ;;
    esac
}

# decode_announce VALUE — Remnawave/Happ panels send `announce: base64:<b64>`;
# strip prefix and decode. Plain text (no prefix) is returned as-is.
# Only attempt base64 decode when the `base64:` prefix is present — otherwise
# valid plain text that happens to be valid base64 would be garbled.
decode_announce() {
    _da="$1"
    [ -z "$_da" ] && return 0
    case "$_da" in
        "base64:"*)
            _da_b="${_da#base64:}"
            _dec="$(printf '%s' "$_da_b" | base64 -d 2>/dev/null || true)"
            [ -n "$_dec" ] && printf '%s' "$_dec" || printf '%s' "$_da_b"
            ;;
        *)
            printf '%s' "$_da"
            ;;
    esac
}

# decode_routing_name RAW — base64 JSON → .name or ""
decode_routing_name() {
    _drn_raw="$1"
    [ -z "$_drn_raw" ] && return
    _drn_json="$(printf '%s' "$_drn_raw" | base64 -d 2>/dev/null || true)"
    [ -z "$_drn_json" ] && { printf '%s' "$_drn_raw"; return; }
    printf '%s' "$_drn_json" \
        | awk -F'"name":"' 'NF>1{split($2,a,"\""); print a[1]; exit}'
}

# userinfo_field VALUE KEY — "upload=0; download=N; ..." → N
userinfo_field() {
    _uf_ui="$1"; _uf_key="$2"
    printf '%s' "$_uf_ui" | sed -n "s/.*${_uf_key}=\([0-9]*\).*/\1/p" | head -n1
}

# ─── Manual links (URIs added by hand, no subscription URL) ──────────
#
# Manual links live inside a dedicated pseudo-subscription:
#   - UCI section:  mole.sub_manual
#   - url:          manual://local  (refresh() short-circuits this scheme)
#   - pool file:    /etc/mole/pool/sub_manual.uris  (user-managed)
#   - group:        "manual" (auto-created)
# The user adds/removes URIs via do_manual_editor; everything downstream
# (meta, ping, link pool, exclusions) treats it exactly like a fetched sub.

SUB_MANUAL_ID="sub_manual"
SUB_MANUAL_URL="manual://local"

ensure_manual_sub() {
    if uci -q get "mole.${SUB_MANUAL_ID}" >/dev/null 2>&1; then
        return 0
    fi
    ensure_group "manual" "Manual Links" 0
    uci set "mole.${SUB_MANUAL_ID}=subscription"
    uci set "mole.${SUB_MANUAL_ID}.url=${SUB_MANUAL_URL}"
    uci set "mole.${SUB_MANUAL_ID}.group_id=manual"
    uci set "mole.${SUB_MANUAL_ID}.profile_title=Manual Links"
    uci set "mole.${SUB_MANUAL_ID}.enabled=1"
    uci set "mole.${SUB_MANUAL_ID}.last_fetch_ts=$(date +%s 2>/dev/null || echo 0)"
    uci set "mole.${SUB_MANUAL_ID}.last_http_status=200"
    uci commit mole
}

# add_link_to_sub SUB_ID URI — append to .uris (dedupe), rebuild meta + count
# Returns 0 on added, 1 if already present.
add_link_to_sub() {
    _als_id="$1"; _als_uri="$2"
    _als_pool="$(sub_pool_file "$_als_id")"
    mkdir -p "$(dirname "$_als_pool")" 2>/dev/null || true
    if [ -f "$_als_pool" ] && grep -qxF "$_als_uri" "$_als_pool" 2>/dev/null; then
        return 1
    fi
    printf '%s\n' "$_als_uri" >> "$_als_pool"
    build_pool_meta "$_als_id"
    update_sub_count "$_als_id"
    uci commit mole
    return 0
}

# remove_link_from_sub SUB_ID URI — strip exact-matching line from .uris
remove_link_from_sub() {
    _rls_id="$1"; _rls_uri="$2"
    _rls_pool="$(sub_pool_file "$_rls_id")"
    [ -f "$_rls_pool" ] || return 1
    _rls_tmp="${CFG_CACHE_DIR}/unlink.$$"
    grep -vxF "$_rls_uri" "$_rls_pool" > "$_rls_tmp" 2>/dev/null || : > "$_rls_tmp"
    mv "$_rls_tmp" "$_rls_pool"
    build_pool_meta "$_rls_id"
    update_sub_count "$_rls_id"
    uci commit mole
}

# sub_pool_file SUB_ID — canonical path for per-subscription URI pool
sub_pool_file() {
    printf '%s/%s.uris' "$CFG_POOL_DIR" "$1"
}

# _extract_singbox_uris BODY_FILE — convert sing-box JSON outbounds to proxy
# URIs, one per line. Requires jq >= 1.6. Outputs to stdout; errors silenced.
# Supports: vless (tcp/ws/grpc/reality/tls), shadowsocks, trojan, hysteria2.
_extract_singbox_uris() {
    jq -r '
        .outbounds[]? |
        select(.type as $t |
            ["vless","shadowsocks","trojan","hysteria2"] | index($t) != null) |
        . as $o |
        if .type == "vless" then
            (.transport.type // "tcp") as $tt |
            (if .tls then
                if .tls.reality then "reality"
                elif (.tls.enabled // false) then "tls"
                else "none" end
             else "none" end) as $sec |
            ([
                "type=" + $tt,
                "security=" + $sec,
                (if .flow then "flow=" + .flow else empty end),
                (if .tls and .tls.server_name then "sni=" + .tls.server_name else empty end),
                (if .tls and .tls.utls and .tls.utls.fingerprint then "fp=" + .tls.utls.fingerprint else empty end),
                (if .tls and .tls.reality then "pbk=" + .tls.reality.public_key else empty end),
                (if .tls and .tls.reality then "sid=" + (.tls.reality.short_id // "") else empty end),
                (if $tt == "ws" and .transport.path then "path=" + .transport.path else empty end),
                (if $tt == "grpc" and .transport.service_name then "serviceName=" + .transport.service_name else empty end)
            ] | join("&")) as $q |
            "vless://" + .uuid + "@" + .server + ":" + (.server_port | tostring) + "?" + $q + "#" + (.tag // "")
        elif .type == "shadowsocks" then
            ((.method + ":" + .password) | @base64 | gsub("="; "")) as $b64 |
            "ss://" + $b64 + "@" + .server + ":" + (.server_port | tostring) + "#" + (.tag // "")
        elif .type == "trojan" then
            ([
                "security=" + (if .tls and (.tls.enabled // false) then "tls" else "none" end),
                (if .tls and .tls.server_name then "sni=" + .tls.server_name else empty end)
            ] | join("&")) as $q |
            "trojan://" + .password + "@" + .server + ":" + (.server_port | tostring) + "?" + $q + "#" + (.tag // "")
        elif .type == "hysteria2" then
            ([
                (if .obfs then "obfs=" + .obfs.type else empty end),
                (if .obfs then "obfs-password=" + .obfs.password else empty end),
                (if .tls and .tls.server_name then "sni=" + .tls.server_name else empty end)
            ] | join("&")) as $q |
            "hysteria2://" + .password + "@" + .server + ":" + (.server_port | tostring) +
            (if $q != "" then "?" + $q else "" end) + "#" + (.tag // "")
        else empty end
    ' < "$1" 2>/dev/null
}

# extract_uris BODY_FILE DST_FILE [HDR_FILE] — detect format, decode, validate;
# writes cleaned URI list (one per line) to DST_FILE, prints line count.
# Returns "yaml" if YAML content-type detected (DST_FILE NOT modified).
# Returns "json-err" if JSON detected but extraction failed (DST_FILE NOT modified).
extract_uris() {
    _eu_body="$1"; _eu_out="$2"; _eu_hdr="${3:-}"
    # Guard: missing or empty body → nothing to extract
    [ -f "$_eu_body" ] && [ -s "$_eu_body" ] || { echo 0; return; }

    # Content-Type detection must happen BEFORE clearing _eu_out so that a
    # format we can't parse doesn't silently wipe the existing URI pool.
    _eu_ct=""
    [ -n "$_eu_hdr" ] && [ -f "$_eu_hdr" ] && _eu_ct="$(hdr_get "$_eu_hdr" content-type)"

    case "$_eu_ct" in
        *text/yaml*|*application/yaml*)
            # YAML (Clash/Mihomo) — can't extract URIs; pool unchanged
            echo "yaml"; return
            ;;
    esac

    mkdir -p "$(dirname "$_eu_out")" 2>/dev/null || true
    : > "$_eu_out"
    _eu_tmp="${CFG_CACHE_DIR}/extract.$$"

    case "$_eu_ct" in
        *application/json*)
            # JSON — try sing-box outbounds extraction (requires jq)
            if have_cmd jq; then
                _extract_singbox_uris "$_eu_body" > "$_eu_tmp" 2>/dev/null || true
            fi
            if ! [ -s "$_eu_tmp" ]; then
                rm -f "$_eu_tmp"
                echo "json-err"; return
            fi
            ;;
        *)
            # Default: try base64 decode first, then treat as plain URI list.
            # Only accept schemes podkop supports (vmess/tuic/etc. are ignored).
            if base64 -d < "$_eu_body" > "$_eu_tmp" 2>/dev/null && [ -s "$_eu_tmp" ]; then
                :
            else
                cp "$_eu_body" "$_eu_tmp" 2>/dev/null || { echo 0; return; }
            fi
            ;;
    esac

    # Filter valid schemes, deduplicate by fragment-stripped key, validate port.
    tr -d '\r' < "$_eu_tmp" \
        | grep -E '^(ss|vless|trojan|socks4|socks4a|socks5|hysteria2|hy2)://' 2>/dev/null \
        | awk 'NF {
            k = $0; sub(/#.*/, "", k)
            if (seen[k]++) next
            u = $0
            sub(/^[a-z0-9]*:\/\//, "", u)
            sub(/^[^@]*@/, "", u)
            sub(/[\/\?#].*/, "", u)
            n = split(u, p, ":")
            if (n < 2) next
            port = p[n]
            if (port !~ /^[0-9]+$/ || port+0 < 1 || port+0 > 65535) next
            print $0
        }' \
        > "$_eu_out" 2>/dev/null || true

    rm -f "$_eu_tmp"
    _n="$(wc -l < "$_eu_out" 2>/dev/null; true)"
    case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
    echo "$_n"
}

# url_decode STR — percent-decode (%XX → byte). `+` is NOT converted to space
# here — VLESS/Trojan fragments use literal `+` as part of names; only query
# strings use `+` as space, and we don't decode queries.
# proto_badge PROTO — short uppercase label for display
proto_badge() {
    case "$1" in
        ss)               printf 'SHADOWSOCKS' ;;
        vless)            printf 'VLESS'       ;;
        vmess)            printf 'VMESS'       ;;
        trojan)           printf 'TROJAN'      ;;
        hysteria2|hy2)    printf 'HYSTERIA2'   ;;
        socks5)           printf 'SOCKS5'      ;;
        socks4a|socks4)   printf 'SOCKS4'      ;;
        *)  printf '%s' "$1" | tr 'a-z' 'A-Z' ;;
    esac
}

url_decode() {
    _ud="$(printf '%s' "$1" | sed 's/%\([0-9a-fA-F][0-9a-fA-F]\)/\\x\1/g')"
    printf '%b' "$_ud"
}

# parse_uri_hostport URI — print tab-sep "proto\thost\tport" (best-effort)
parse_uri_hostport() {
    _uri="$1"
    _proto="${_uri%%://*}"
    case "$_uri" in
        vmess://*)
            _blob="${_uri#vmess://}"
            _blob="${_blob%%\?*}"; _blob="${_blob%%#*}"
            _dec="$(printf '%s' "$_blob" | base64 -d 2>/dev/null || true)"
            _host="$(printf '%s' "$_dec" | sed -n 's/.*"add"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
            _port="$(printf '%s' "$_dec" | sed -n 's/.*"port"[[:space:]]*:[[:space:]]*"\{0,1\}\([0-9]*\)"\{0,1\}.*/\1/p' | head -n1)"
            printf '%s\t%s\t%s' "$_proto" "$_host" "$_port"
            return
            ;;
    esac
    _rest="${_uri#*://}"
    _rest="${_rest%%#*}"
    _rest="${_rest%%\?*}"
    case "$_rest" in *@*) _rest="${_rest#*@}" ;; esac
    case "$_rest" in
        *:*) _host="${_rest%%:*}"; _port="${_rest##*:}"; _port="${_port%%[!0-9]*}" ;;
        *)   _host="$_rest"; _port="" ;;
    esac
    printf '%s\t%s\t%s' "$_proto" "$_host" "$_port"
}

# uri_param URI KEY — extract ?KEY=value from query string (case-insensitive key)
uri_param() {
    _up_qs="${1#*\?}"; _up_qs="${_up_qs%%#*}"
    printf '%s' "$_up_qs" | tr '&' '\n' \
        | awk -F= -v k="$2" 'tolower($1)==tolower(k){
            v=$2; for(i=3;i<=NF;i++) v=v"="$i; print v; exit
          }'
}

# uri_userinfo URI — portion between :// and first @
uri_userinfo() {
    _uui="${1#*://}"
    case "$_uui" in *@*) printf '%s' "${_uui%%@*}" ;; esac
}

# link_id URI — 12-char hex id. Strips fragment and query string before
# hashing so the id is stable across display-name changes AND across
# subscription refreshes that rotate query-string tokens/CDN params.
# UUID/password in the path is still included, so different credentials
# on the same host produce distinct ids (no batch-toggle collision).
# 12 chars (48-bit prefix) reduces collision probability vs 8-char (32-bit)
# at scale (1000+ nodes across multiple subscriptions).
link_id() {
    _lid="${1%%#*}"
    _lid="${_lid%%\?*}"
    printf '%s' "$_lid" \
        | { sha256sum 2>/dev/null || md5sum 2>/dev/null || cksum; } \
        | awk '{print substr($1,1,12)}'
}

# ─── Host resolution ─────────────────────────────────────────────────

# _nslookup_first HOST — resolve to first IPv4 via nslookup (BusyBox-safe)
_nslookup_first() {
    nslookup "$1" 2>/dev/null | awk '
        /^$/ { body=1; next }
        body {
            for(i=1;i<=NF;i++) if($i~/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit }
        }
    '
}

# ─── ASN/country enrichment (Team Cymru DNS) ─────────────────────────

# cymru_lookup IP — query <reversed>.origin.asn.cymru.com TXT,
# returns raw pipe-separated response or empty on failure
cymru_lookup() {
    _cl_ip="$1"
    [ -z "$_cl_ip" ] && return 1
    _cl_rev="$(printf '%s' "$_cl_ip" | awk -F. 'NF==4{print $4"."$3"."$2"."$1}')"
    [ -z "$_cl_rev" ] && return 1
    _cl_raw=""
    if have_cmd dig; then
        _cl_raw="$(dig +short +time=2 +tries=1 "${_cl_rev}.origin.asn.cymru.com" TXT 2>/dev/null | head -n1)"
    elif have_cmd drill; then
        _cl_raw="$(drill -Q "${_cl_rev}.origin.asn.cymru.com" TXT 2>/dev/null | head -n1)"
    else
        _cl_raw="$(nslookup -type=TXT "${_cl_rev}.origin.asn.cymru.com" 2>/dev/null \
            | sed -n 's/.*text = "\(.*\)"/\1/p' | head -n1)"
    fi
    _cl_raw="$(printf '%s' "$_cl_raw" | tr -d '"' | tr -d '\r')"
    [ -z "$_cl_raw" ] && return 1
    printf '%s' "$_cl_raw"
}

# enrich_ip IP — "ASN\tCC", cached per-IP under CFG_CACHE_DIR/asn/
enrich_ip() {
    _ei_ip="$1"
    [ -z "$_ei_ip" ] && return 1
    mkdir -p "${CFG_CACHE_DIR}/asn" 2>/dev/null || true
    _ei_cache="${CFG_CACHE_DIR}/asn/${_ei_ip}"
    if [ -f "$_ei_cache" ]; then
        _ei_mtime="$(stat -c %Y "$_ei_cache" 2>/dev/null || echo 0)"
        _ei_age=$(( $(date +%s 2>/dev/null || echo 0) - _ei_mtime ))
        if [ "$_ei_age" -lt "$CFG_ENRICH_CACHE_TTL" ] 2>/dev/null; then
            cat "$_ei_cache"
            return 0
        fi
    fi
    _ei_raw="$(cymru_lookup "$_ei_ip")"
    [ -z "$_ei_raw" ] && return 1
    # Format: "ASN | CIDR | CC | REGISTRY | DATE"
    _ei_asn="$(printf '%s' "$_ei_raw" | awk -F'|' '{gsub(/ /,"",$1); print $1}')"
    _ei_cc="$(printf '%s' "$_ei_raw"  | awk -F'|' '{gsub(/ /,"",$3); print $3}')"
    # ASN can be multi-value (e.g. "15169 32934") — keep first
    _ei_asn="${_ei_asn%% *}"
    printf '%s\t%s' "$_ei_asn" "$_ei_cc" > "$_ei_cache"
    printf '%s\t%s' "$_ei_asn" "$_ei_cc"
}

# cc_to_flag CC — 2-letter country code → regional-indicator flag emoji
cc_to_flag() {
    _cc="${1:-}"
    [ "${#_cc}" = "2" ] || return 0
    _c1="$(printf '%s' "$_cc" | cut -c1 | tr 'a-z' 'A-Z')"
    _c2="$(printf '%s' "$_cc" | cut -c2 | tr 'a-z' 'A-Z')"
    case "$_c1" in [A-Z]) ;; *) return 0 ;; esac
    case "$_c2" in [A-Z]) ;; *) return 0 ;; esac
    # A = 0x1F1E6, UTF-8 F0 9F 87 A6. Each subsequent letter +1 on last byte.
    _ord1="$(printf '%d' "'$_c1")"
    _ord2="$(printf '%d' "'$_c2")"
    _b1="$(printf '%02x' $((166 + _ord1 - 65)))"
    _b2="$(printf '%02x' $((166 + _ord2 - 65)))"
    printf '%b' "\\xf0\\x9f\\x87\\x${_b1}\\xf0\\x9f\\x87\\x${_b2}"
}

# ─── Pool metadata (sidecar .meta file) ──────────────────────────────
# Format per line (US-separated, 10 fields):
#   link_id US proto US host US port US ip US asn US cc US flag US ping_ms US name
#
# US = ASCII 0x1F "Unit Separator". NOT TAB, because TAB is IFS-whitespace
# in POSIX shells — consecutive TABs collapse into one separator under
# `IFS=<TAB> read`, which eats empty fields (ping_ms is often empty) and
# shifts downstream columns. US is non-whitespace, so empty fields survive.
META_FS="$(printf '\037')"
META_FIELDS=10

sub_meta_file() {
    printf '%s/%s.meta' "$CFG_POOL_DIR" "$1"
}

sub_stale_file() {
    printf '%s/%s.stale' "$CFG_POOL_DIR" "$1"
}

# Protocols we recognise + allow excluding. Kept in sync with extract_uris grep.
PROTOCOL_CHOICES="vless ss trojan hysteria2 hy2 socks5 socks4 socks4a"

# compute_effective_excludes SUB_ID — print space-separated list of protocols
# excluded for this subscription. If sub's `exclude_inherit=1` (default), uses
# the parent group's list; otherwise uses the sub's own list.
compute_effective_excludes() {
    _ce_id="$1"
    _ce_inherit="$(sub_get "$_ce_id" exclude_inherit 1)"
    if [ "$_ce_inherit" = "1" ]; then
        _ce_gid="$(sub_get "$_ce_id" group_id)"
        [ -n "$_ce_gid" ] && group_get "$_ce_gid" exclude_protocols || true
    else
        sub_get "$_ce_id" exclude_protocols
    fi
}

# toggle_proto_exclude SECTION PROTOCOL — add if absent, remove if present
toggle_proto_exclude() {
    _tp_sec="$1"; _tp_proto="$2"
    _tp_cur="$(uci -q get "mole.${_tp_sec}.exclude_protocols" 2>/dev/null || echo "")"
    _tp_new=""; _tp_found=0
    for _tp_p in $_tp_cur; do
        if [ "$_tp_p" = "$_tp_proto" ]; then
            _tp_found=1
            continue
        fi
        _tp_new="${_tp_new:+${_tp_new} }${_tp_p}"
    done
    if [ "$_tp_found" = "0" ]; then
        _tp_new="${_tp_new:+${_tp_new} }${_tp_proto}"
    fi
    if [ -z "$_tp_new" ]; then
        uci -q delete "mole.${_tp_sec}.exclude_protocols" 2>/dev/null || true
    else
        uci set "mole.${_tp_sec}.exclude_protocols=${_tp_new}"
    fi
}

# sub_link_excludes SUB_ID — space-separated list of link_ids excluded for
# this subscription. Per-sub only (no inherit from group for now — groups
# can't meaningfully own link_ids because they may appear in multiple subs
# with different IPs).
sub_link_excludes() {
    sub_get "$1" exclude_links
}

# toggle_link_exclude SUB_ID LINK_ID — add if absent, remove if present
toggle_link_exclude() {
    _tle_sid="$1"; _tle_lid="$2"
    _tle_cur="$(uci -q get "mole.${_tle_sid}.exclude_links" 2>/dev/null || echo "")"
    _tle_new=""; _tle_found=0
    for _tle_l in $_tle_cur; do
        if [ "$_tle_l" = "$_tle_lid" ]; then
            _tle_found=1
            continue
        fi
        _tle_new="${_tle_new:+${_tle_new} }${_tle_l}"
    done
    if [ "$_tle_found" = "0" ]; then
        _tle_new="${_tle_new:+${_tle_new} }${_tle_lid}"
    fi
    if [ -z "$_tle_new" ]; then
        uci -q delete "mole.${_tle_sid}.exclude_links" 2>/dev/null || true
    else
        uci set "mole.${_tle_sid}.exclude_links=${_tle_new}"
    fi
}

# compute_filtered_count SUB_ID — count rows in .meta whose protocol is NOT
# in the effective protocol-exclusion list AND whose link_id is NOT in the
# sub's link-exclusion list. Single awk pass, no DNS / no Cymru.
compute_filtered_count() {
    _cfc_id="$1"
    _cfc_m="$(sub_meta_file "$_cfc_id")"
    [ -f "$_cfc_m" ] || { echo 0; return; }
    _cfc_excl_p="$(compute_effective_excludes "$_cfc_id")"
    _cfc_excl_l="$(sub_link_excludes "$_cfc_id")"
    if [ -z "$_cfc_excl_p" ] && [ -z "$_cfc_excl_l" ]; then
        _cfc_n="$(wc -l < "$_cfc_m" 2>/dev/null)"
        case "$_cfc_n" in ''|*[!0-9]*) _cfc_n=0 ;; esac
        echo "$_cfc_n"
        return
    fi
    awk -v ep=" $_cfc_excl_p " -v el=" $_cfc_excl_l " -v FS="$META_FS" '
        {
            skip = 0
            if (ep != "  " && index(ep, " " $2 " ") > 0) skip = 1
            if (el != "  " && index(el, " " $1 " ") > 0) skip = 1
            if (!skip) n++
        }
        END { print n+0 }
    ' "$_cfc_m"
}

# update_sub_count SUB_ID — rewrite mole.SUB.last_count to the filtered total
update_sub_count() {
    _uc_id="$1"
    _uc_n="$(compute_filtered_count "$_uc_id")"
    case "$_uc_n" in ''|*[!0-9]*) _uc_n=0 ;; esac
    uci set "mole.${_uc_id}.last_count=${_uc_n}"
}

# rebuild_sub_meta SUB_ID — fast path for exclusion-toggle.
# NB: does NOT rebuild .meta — that would re-do DNS/Cymru lookups for every
# node (~hundreds of subshells, seconds per group). Meta stays canonical;
# exclusions are applied at READ time by every consumer. All we need here is
# to refresh last_count so the group header / sub rows show the right total.
rebuild_sub_meta() {
    update_sub_count "$1"
    uci commit mole
}

rebuild_group_metas() {
    for _rgm_s in $(subs_in_group "$1"); do
        update_sub_count "$_rgm_s"
    done
    uci commit mole
}

# build_pool_meta SUB_ID — regenerate .meta from .uris.
# Pure parse: proto/host/port/name from each URI. No DNS, no Cymru, no ASN.
# ip/asn/cc/flag columns are kept in the schema (blank) for forward compat —
# consumers that still read them treat empty values as "unknown".
build_pool_meta() {
    _bpm_id="$1"
    _bpm_uris="$(sub_pool_file "$_bpm_id")"
    _bpm_meta="$(sub_meta_file "$_bpm_id")"
    mkdir -p "$(dirname "$_bpm_meta")" 2>/dev/null || true
    : > "$_bpm_meta"
    [ -f "$_bpm_uris" ] && [ -s "$_bpm_uris" ] || return 0
    while IFS= read -r _uri; do
        [ -z "$_uri" ] && continue
        _parsed="$(parse_uri_hostport "$_uri")"
        _proto="$(printf '%s' "$_parsed" | cut -f1)"
        _host="$(printf '%s' "$_parsed" | cut -f2)"
        _port="$(printf '%s' "$_parsed" | cut -f3)"
        _lid="$(link_id "$_uri")"
        _name="$(uri_display_name "$_uri" | tr '\t\n\r\037' '    ')"
        [ -z "$_name" ] && _name="(unnamed)"
        # ip, asn, cc, flag, ping_ms all left blank at build time
        printf '%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n' \
            "$_lid"  "$META_FS" \
            "$_proto" "$META_FS" \
            "$_host" "$META_FS" \
            "$_port" "$META_FS" \
            ""       "$META_FS" \
            ""       "$META_FS" \
            ""       "$META_FS" \
            ""       "$META_FS" \
            ""       "$META_FS" \
            "$_name" \
            >> "$_bpm_meta"
    done < "$_bpm_uris"
}

# uri_display_name URI — best-effort human name:
#   1. decoded `#fragment` (vless/trojan/ss/hy2/tuic) — when non-empty
#   2. vmess: base64-JSON `ps` field
#   3. fallback: <proto>://<host>:<port>  (always non-empty)
uri_display_name() {
    _uri="$1"
    case "$_uri" in
        vmess://*)
            _blob="${_uri#vmess://}"
            _blob="${_blob%%\?*}"; _blob="${_blob%%#*}"
            _dec="$(printf '%s' "$_blob" | base64 -d 2>/dev/null || true)"
            if [ -n "$_dec" ]; then
                _ps="$(printf '%s' "$_dec" | sed -n 's/.*"ps"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
                [ -n "$_ps" ] && { printf '%s' "$_ps"; return; }
            fi
            printf 'vmess://%s' "$(printf '%s' "$_blob" | cksum | awk '{printf "%08x", $1}')"
            return
            ;;
    esac
    case "$_uri" in
        *'#'*)
            _frag="${_uri##*#}"
            if [ -n "$_frag" ]; then
                _dec_f="$(url_decode "$_frag")"
                if [ -n "$_dec_f" ]; then
                    printf '%s' "$_dec_f"
                    return
                fi
            fi
            ;;
    esac
    # Empty or missing fragment — synthesise from proto/authority so the link
    # is still identifiable in the pool viewer (never let rows collapse to
    # "(unnamed)").
    _proto="${_uri%%://*}"
    _rest="${_uri#*://}"
    _rest="${_rest%%#*}"
    _rest="${_rest%%\?*}"
    case "$_rest" in *@*) _rest="${_rest#*@}" ;; esac
    printf '%s://%s' "$_proto" "$_rest"
}

# interpret_interval SECONDS_OR_HOURS — return hours.
# profile-update-interval semantics vary by panel: Remnawave/v2rayN/Happ use
# hours, some Clash emitters use seconds. Heuristic: ≤168 → hours (max 1 week
# makes sense); >168 → assumed seconds, divide by 3600.
interpret_interval() {
    _iv="${1:-0}"
    case "$_iv" in ''|*[!0-9]*) echo 0; return ;; esac
    [ "$_iv" -eq 0 ] && { echo 0; return; }
    if [ "$_iv" -le 168 ]; then
        echo "$_iv"
    else
        _h=$((_iv / 3600))
        [ "$_h" -lt 1 ] && _h=1
        echo "$_h"
    fi
}

# ─── Group helpers ───────────────────────────────────────────────────

group_exists() {
    _ge_t="$(uci -q get "mole.$1" 2>/dev/null || true)"
    [ "$_ge_t" = "group" ]
}

# ensure_group ID DISPLAY_NAME [manual=0]
ensure_group() {
    _eg_id="$1"; _eg_dn="$2"; _eg_manual="${3:-0}"
    if ! group_exists "$_eg_id"; then
        uci set "mole.${_eg_id}=group"
        uci set "mole.${_eg_id}.display_name=${_eg_dn}"
        uci set "mole.${_eg_id}.manual=${_eg_manual}"
    fi
}

# find_group_by_title TITLE — print group_id of first matching group (exit 0/1)
find_group_by_title() {
    _fgt="$1"
    [ -z "$_fgt" ] && return 1
    for _g in $(iterate_group_names); do
        _dn="$(group_get "$_g" display_name)"
        if [ "$_dn" = "$_fgt" ]; then
            echo "$_g"
            return 0
        fi
    done
    return 1
}

# subs_in_group GROUP_ID — print subscription UCI names in this group (one per line)
# NB: explicit `return 0` — without it the function would inherit the exit code
# of the last `[ ... ] && echo` pair. If the last-iterated sub isn't in this
# group, `[ ]` returns 1, and under `set -e` the calling `_subs=$(...)`
# assignment kills the whole script.
subs_in_group() {
    _sig_g="$1"
    for _s in $(iterate_sub_names); do
        _sg="$(sub_get "$_s" group_id)"
        [ "$_sg" = "$_sig_g" ] && echo "$_s"
    done
    return 0
}

# ─── Subscription save ───────────────────────────────────────────────

# save_subscription SUB_ID URL GROUP_ID
# Reads META_* env vars for metadata fields. Commits are caller's job.
save_subscription() {
    _ss_id="$1"; _ss_url="$2"; _ss_gid="$3"
    uci -q get "mole.$_ss_id" >/dev/null 2>&1 || uci set "mole.${_ss_id}=subscription"
    uci set "mole.${_ss_id}.url=${_ss_url}"
    uci set "mole.${_ss_id}.group_id=${_ss_gid}"
    uci set "mole.${_ss_id}.enabled=${META_ENABLED:-1}"
    uci set "mole.${_ss_id}.profile_title=${META_PROFILE_TITLE:-}"
    uci set "mole.${_ss_id}.support_url=${META_SUPPORT_URL:-}"
    uci set "mole.${_ss_id}.web_page_url=${META_WEB_PAGE_URL:-}"
    uci set "mole.${_ss_id}.update_interval=${META_UPDATE_INTERVAL:-0}"
    uci set "mole.${_ss_id}.announce=${META_ANNOUNCE:-}"
    uci set "mole.${_ss_id}.traffic_upload=${META_TRAFFIC_UPLOAD:-0}"
    uci set "mole.${_ss_id}.traffic_download=${META_TRAFFIC_DOWNLOAD:-0}"
    uci set "mole.${_ss_id}.traffic_total=${META_TRAFFIC_TOTAL:-0}"
    uci set "mole.${_ss_id}.traffic_expire=${META_TRAFFIC_EXPIRE:-0}"
    uci set "mole.${_ss_id}.traffic_refill=${META_TRAFFIC_REFILL:-0}"
    uci set "mole.${_ss_id}.last_fetch_ts=${META_LAST_FETCH_TS:-0}"
    uci set "mole.${_ss_id}.last_http_status=${META_LAST_HTTP_STATUS:-0}"
    uci set "mole.${_ss_id}.last_count=${META_LAST_COUNT:-0}"
    uci set "mole.${_ss_id}.last_error=${META_LAST_ERROR:-}"
}

# ─── Main-menu subscription list ─────────────────────────────────────

# display_subs — emit numbered subscription lines grouped by group.
# Writes menu-order count into $_MENU_SUB_COUNT (global, read by dispatcher).
_MENU_SUB_COUNT=0
_MENU_SUB_IDS=""  # space-separated in menu order

display_subs() {
    _MENU_SUB_COUNT=0
    _MENU_SUB_IDS=""
    _MENU_GROUP_COUNT=0
    _MENU_GROUP_IDS=""

    for _g in $(iterate_group_names); do
        _subs="$(subs_in_group "$_g")"
        [ -z "$_subs" ] && continue
        _MENU_GROUP_COUNT=$((_MENU_GROUP_COUNT + 1))
        _MENU_GROUP_IDS="${_MENU_GROUP_IDS} ${_g}"
        _dn="$(group_get "$_g" display_name)"
        [ -z "$_dn" ] && _dn="$_g"
        echo ""
        echo -e "  ${W}${_dn}${NC}"
        echo -e "      ${B}s${_MENU_GROUP_COUNT}${NC} ${DIM2}›${NC} ${W}Settings${NC}"
        for _s in $_subs; do
            _MENU_SUB_COUNT=$((_MENU_SUB_COUNT + 1))
            _MENU_SUB_IDS="${_MENU_SUB_IDS} ${_s}"
            _url="$(sub_get "$_s" url)"
            _custom="$(sub_get "$_s" custom_name)"
            _pt="$(sub_get "$_s" profile_title)"
            _c="$(sub_get "$_s" last_count 0)"
            _http="$(sub_get "$_s" last_http_status 0)"
            _last_ts="$(sub_get "$_s" last_fetch_ts 0)"
            _en="$(sub_get "$_s" enabled 1)"
            _tot="$(sub_get "$_s" traffic_total 0)"
            _up_b="$(sub_get "$_s" traffic_upload 0)"
            _dn_b="$(sub_get "$_s" traffic_download 0)"
            _exp="$(sub_get "$_s" traffic_expire 0)"

            # Defensive sanitize: older saves may contain "0\n0" multi-line
            # garbage from a past count_uri_schemes bug.
            for _nv in _c _http _last_ts _tot _up_b _dn_b _exp; do
                eval "_tmp=\${$_nv:-0}"
                case "$_tmp" in ''|*[!0-9]*) eval "$_nv=0" ;; esac
            done

            # custom_name > profile-title > URL host
            if [ -n "$_custom" ]; then
                _label="$_custom"
            elif [ -n "$_pt" ]; then
                _label="$_pt"
            else
                _label="$(url_display "$_url" 38)"
            fi

            _meta=""
            if [ "$_tot" != "0" ]; then
                _bw_ov="$(fmt_traffic "$_up_b" "$_dn_b" "$_tot")"
                [ -n "$_bw_ov" ] && _meta="${_meta} · ${_bw_ov}"
            else
                _used_ov="$(awk -v u="${_up_b:-0}" -v d="${_dn_b:-0}" 'BEGIN{print u+d}')"
                [ "${_used_ov:-0}" != "0" ] && _meta="${_meta} · $(fmt_bytes "$_used_ov")"
            fi
            [ "$_exp" != "0" ] && _meta="${_meta} · $(fmt_days_until "$_exp")"
            _meta="${_meta} · $(fmt_age_since "$_last_ts")"

            if [ "$_en" = "0" ]; then
                echo -e "      ${DIM2}$(printf '%2d' "$_MENU_SUB_COUNT") · ${_label}${NC}"
            elif [ "$_http" -ge 400 ]; then
                echo -e "      ${B}$(printf '%2d' "$_MENU_SUB_COUNT")${NC} ${DIM2}›${NC} ${W}${_label}${NC}  ${DIM2}${_c} links${_meta}  ${ERR}err ${_http}${NC}"
            else
                echo -e "      ${B}$(printf '%2d' "$_MENU_SUB_COUNT")${NC} ${DIM2}›${NC} ${W}${_label}${NC}  ${DIM2}${_c} links${_meta}${NC}"
            fi
        done
    done

    # Subscriptions whose group no longer exists
    for _s in $(iterate_sub_names); do
        _g="$(sub_get "$_s" group_id)"
        if [ -z "$_g" ] || ! group_exists "$_g"; then
            _MENU_SUB_COUNT=$((_MENU_SUB_COUNT + 1))
            _MENU_SUB_IDS="${_MENU_SUB_IDS} ${_s}"
            _url="$(sub_get "$_s" url)"
            _custom="$(sub_get "$_s" custom_name)"
            _pt="$(sub_get "$_s" profile_title)"
            _c="$(sub_get "$_s" last_count 0)"
            _en="$(sub_get "$_s" enabled 1)"
            if [ -n "$_custom" ]; then
                _label="$_custom"
            elif [ -n "$_pt" ]; then
                _label="$_pt"
            else
                _label="$(url_display "$_url" 38)"
            fi
            case "$_c" in ''|*[!0-9]*) _c=0 ;; esac
            if [ "$_en" = "0" ]; then
                echo -e "  ${DIM2}$(printf '%2d' "$_MENU_SUB_COUNT") · ${_label} (ungrouped)${NC}"
            else
                echo -e "  ${B}$(printf '%2d' "$_MENU_SUB_COUNT")${NC} ${DIM2}›${NC} ${W}${_label}${NC}  ${DIM2}${_c} links (ungrouped)${NC}"
            fi
        fi
    done
    return 0
}

# nth_displayed_sub N — print UCI name of Nth entry (uses $_MENU_SUB_IDS)
nth_displayed_sub() {
    _nds_n="$1"; _nds_i=0
    for _s in $_MENU_SUB_IDS; do
        _nds_i=$((_nds_i + 1))
        [ "$_nds_i" = "$_nds_n" ] && { echo "$_s"; return 0; }
    done
    return 1
}

# ─── Installer actions ───────────────────────────────────────────────

# install_opkg_deps PKG...
# Installs listed opkg/apk packages, printing progress lines.
install_opkg_deps() {
    echo -e "  ${B}Updating${NC} package list..."
    pkg_update >/dev/null 2>&1 || true
    for _pkg in "$@"; do
        if pkg_is_installed "$_pkg"; then
            echo -e "  ${ICO_OK} ${DIM2}${_pkg}${NC} already installed"
            continue
        fi
        echo -e "  ${B}Installing${NC} ${_pkg}..."
        pkg_install "$_pkg" >/dev/null 2>&1 || {
            warn "Failed to install ${_pkg}"
            continue
        }
        echo -e "  ${ICO_OK} ${OK}${_pkg}${NC}"
    done
}

# install_podkop — run upstream podkop installer script
install_podkop() {
    if ! check_dns; then
        warn "DNS is not working — cannot install Podkop"
        return 1
    fi
    echo -e "  ${B}Installing${NC} Podkop (upstream installer)..."
    sh <(wget -O - https://raw.githubusercontent.com/itdoginfo/podkop/refs/heads/main/install.sh) 2>&1 \
        || { warn "Podkop installer exited with errors"; return 1; }
    return 0
}

# do_install_all — install all missing mole deps + offer podkop
do_install_all() {
    crumb_push "Install"
    echo ""
    crumb_show

    if ! check_dns; then
        warn "DNS is not working — install will fail"
        PAUSE; crumb_pop; return
    fi

    # mole required + recommended deps
    _mole_pkgs="curl ca-bundle jq flock"
    # base64: opkg package is coreutils-base64 (apk: coreutils)
    if [ "$PKG_IS_APK" -eq 1 ]; then
        _mole_pkgs="$_mole_pkgs coreutils"
    else
        _mole_pkgs="$_mole_pkgs coreutils-base64 coreutils-sha256sum util-linux-flock"
    fi
    # dig / nc — different package names across distros; best-effort
    _opt_pkgs="bind-dig"
    if [ "$PKG_IS_APK" -eq 1 ]; then
        _opt_pkgs="bind-tools"
    fi

    echo -e "  ${A}Required${NC}"
    # shellcheck disable=SC2086
    install_opkg_deps $_mole_pkgs
    echo ""
    echo -e "  ${A}Recommended${NC} (ASN enrichment / TCP ping)"
    # shellcheck disable=SC2086
    install_opkg_deps $_opt_pkgs
    echo ""

    if ! podkop_present; then
        if confirm "Install Podkop as well?" "y"; then
            install_podkop || true
        fi
    fi

    echo ""
    echo -e "  ${ICO_OK} ${OK}Done${NC}"
    PAUSE
    crumb_pop
}

# ─── Refresh pipeline ────────────────────────────────────────────────

# refresh_subscription SUB_ID [silent=0]
#   Fetches URL, parses headers, writes pool file, updates UCI metadata.
#   Returns:
#     0  success
#     1  fetch/parse error (error stored in mole.SUB_ID.last_error)
#   Holds a per-subscription flock so concurrent runs (TUI + cron) don't collide.
refresh_subscription() {
    _rs_id="$1"; _rs_silent="${2:-0}"
    _rs_url="$(sub_get "$_rs_id" url)"
    if [ -z "$_rs_url" ]; then
        [ "$_rs_silent" = "0" ] && warn "No URL for ${_rs_id}"
        return 1
    fi

    # Manual subs carry a placeholder URL; skip network fetch and just rebuild
    # the metadata sidecar from the user-managed .uris file. No flock, no curl.
    case "$_rs_url" in
        manual://*)
            build_pool_meta "$_rs_id"
            _rs_count="$(compute_filtered_count "$_rs_id")"
            case "$_rs_count" in ''|*[!0-9]*) _rs_count=0 ;; esac
            uci set "mole.${_rs_id}.last_fetch_ts=$(date +%s 2>/dev/null || echo 0)"
            uci set "mole.${_rs_id}.last_http_status=200"
            uci set "mole.${_rs_id}.last_count=${_rs_count}"
            uci set "mole.${_rs_id}.last_error="
            uci commit mole
            log_event "refresh ${_rs_id} ok ${_rs_count} links (manual)"
            return 0
            ;;
    esac

    mkdir -p "$CFG_CACHE_DIR" 2>/dev/null || true
    _rs_lock="${CFG_CACHE_DIR}/refresh.${_rs_id}.lock"
    if ! exec 9>"$_rs_lock" 2>/dev/null; then
        [ "$_rs_silent" = "0" ] && warn "Cannot open lock for ${_rs_id}"
        return 1
    fi
    if ! flock -n 9 2>/dev/null; then
        exec 9>&-
        [ "$_rs_silent" = "0" ] && warn "Another refresh is in progress for ${_rs_id}"
        return 1
    fi

    _rs_hdr="${CFG_CACHE_DIR}/refresh.${_rs_id}.hdr"
    _rs_body="${CFG_CACHE_DIR}/refresh.${_rs_id}.body"

    if ! fetch_subscription "$_rs_url" "$_rs_hdr" "$_rs_body"; then
        uci set "mole.${_rs_id}.last_fetch_ts=$(date +%s 2>/dev/null || echo 0)"
        uci set "mole.${_rs_id}.last_http_status=0"
        uci set "mole.${_rs_id}.last_error=fetch-failed"
        uci commit mole
        rm -f "$_rs_hdr" "$_rs_body"
        exec 9>&-
        log_event "refresh ${_rs_id} fail: fetch-failed"
        return 1
    fi

    _rs_status_line="$(head -n1 "$_rs_hdr" 2>/dev/null | tr -d '\r')"
    _rs_http="$(printf '%s' "$_rs_status_line" | awk '{print $2}')"
    case "$_rs_http" in ''|*[!0-9]*) _rs_http=0 ;; esac

    _rs_pt_raw="$(hdr_get "$_rs_hdr" profile-title)"
    _rs_support="$(hdr_get "$_rs_hdr" support-url)"
    _rs_webpage="$(hdr_get "$_rs_hdr" profile-web-page-url)"
    _rs_interval_h="$(hdr_get "$_rs_hdr" profile-update-interval)"
    _rs_userinfo="$(hdr_get "$_rs_hdr" subscription-userinfo)"
    _rs_refill="$(hdr_get "$_rs_hdr" subscription-refill-date)"
    _rs_ann_raw="$(hdr_get "$_rs_hdr" announce)"
    _rs_routing="$(hdr_get "$_rs_hdr" routing)"
    _rs_account="$(cd_filename "$(hdr_get "$_rs_hdr" content-disposition)")"
    _rs_hwid_warn="0"
    [ "$(hdr_get "$_rs_hdr" x-hwid-max-devices-reached)" = "true" ] && _rs_hwid_warn="1"
    [ "$(hdr_get "$_rs_hdr" x-hwid-limit)" = "true" ] && _rs_hwid_warn="1"

    _rs_pt="$(decode_profile_title "$_rs_pt_raw")"
    _rs_ann="$(decode_announce "$_rs_ann_raw")"

    _rs_up="$(userinfo_field "$_rs_userinfo" upload)"
    _rs_dn="$(userinfo_field "$_rs_userinfo" download)"
    _rs_tot="$(userinfo_field "$_rs_userinfo" total)"
    _rs_exp="$(userinfo_field "$_rs_userinfo" expire)"
    for _rs_nv in _rs_up _rs_dn _rs_tot _rs_exp; do
        eval "_tmp=\${$_rs_nv:-0}"
        case "$_tmp" in ''|*[!0-9]*) eval "$_rs_nv=0" ;; esac
    done

    _rs_interval="$(printf '%s' "$_rs_interval_h" | sed 's/[^0-9].*//')"
    [ -z "$_rs_interval" ] && _rs_interval=0

    # Snapshot excluded lids — capture lid→name from old meta BEFORE pool is overwritten
    _rs_stale_f="$(sub_stale_file "$_rs_id")"
    _rs_excl_snap="${CFG_CACHE_DIR}/excl_snap.${_rs_id}.$$"
    _rs_excl_cur="$(sub_link_excludes "$_rs_id")"
    _rs_old_meta_f="$(sub_meta_file "$_rs_id")"
    if [ -n "$_rs_excl_cur" ] && [ -f "$_rs_old_meta_f" ] && [ -s "$_rs_old_meta_f" ]; then
        awk -v el=" $_rs_excl_cur " -v FS="$META_FS" 'index(el, " " $1 " ") > 0 { print $1 "\t" $10 }' "$_rs_old_meta_f" > "$_rs_excl_snap"
    else
        : > "$_rs_excl_snap"
    fi

    _rs_pool="$(sub_pool_file "$_rs_id")"
    _rs_eu="$(extract_uris "$_rs_body" "$_rs_pool" "$_rs_hdr")"
    case "$_rs_eu" in
        yaml|json-err)
            # Unsupported format — keep existing pool, record error
            _rs_err_code="format-${_rs_eu#format-}"
            [ "$_rs_eu" = "yaml" ] && _rs_err_code="format-yaml"
            [ "$_rs_eu" = "json-err" ] && _rs_err_code="format-json"
            uci set "mole.${_rs_id}.last_fetch_ts=$(date +%s 2>/dev/null || echo 0)"
            uci set "mole.${_rs_id}.last_http_status=${_rs_http}"
            uci set "mole.${_rs_id}.last_error=${_rs_err_code}"
            uci commit mole
            rm -f "$_rs_hdr" "$_rs_body" "$_rs_excl_snap"
            exec 9>&-
            log_event "refresh ${_rs_id} fail: ${_rs_err_code}"
            return 1
            ;;
    esac

    # Rebuild metadata sidecar (full — ALL URIs + enrichment). Exclusions are
    # applied on read, so toggling them later is instant (no re-enrichment).
    build_pool_meta "$_rs_id"

    # Stale exclusion reconciliation: nodes that were manually excluded but
    # have since disappeared from the pool are moved to a sidecar stale file
    # instead of being silently dropped. They are restored to exclude_links
    # if they reappear in a future refresh.
    _rs_new_meta_f="$(sub_meta_file "$_rs_id")"
    _rs_new_lid_set=""
    if [ -f "$_rs_new_meta_f" ] && [ -s "$_rs_new_meta_f" ]; then
        _rs_new_lid_set=" $(awk -v FS="$META_FS" '{printf "%s ", $1}' "$_rs_new_meta_f") "
    fi
    _rs_stale_comb="${CFG_CACHE_DIR}/stale_comb.${_rs_id}.$$"
    cat "$_rs_excl_snap" > "$_rs_stale_comb"
    [ -f "$_rs_stale_f" ] && cat "$_rs_stale_f" >> "$_rs_stale_comb"
    rm -f "$_rs_excl_snap"
    _rs_new_excl="" _rs_new_stale="" _rs_seen="" _rs_stab="$(printf '	')"
    while IFS="$_rs_stab" read -r _rl _rn; do
        [ -z "$_rl" ] && continue
        case " $_rs_seen " in *" $_rl "*) continue ;; esac
        _rs_seen="${_rs_seen} $_rl"
        case "$_rs_new_lid_set" in
            *" $_rl "*) _rs_new_excl="${_rs_new_excl:+${_rs_new_excl} }${_rl}" ;;
            *)          _rs_new_stale="${_rs_new_stale}${_rl}${_rs_stab}${_rn}
" ;;
        esac
    done < "$_rs_stale_comb"
    rm -f "$_rs_stale_comb"
    if [ -n "$_rs_new_stale" ]; then
        printf '%s' "$_rs_new_stale" > "$_rs_stale_f"
    else
        rm -f "$_rs_stale_f"
    fi
    if [ -z "$_rs_new_excl" ]; then
        uci -q delete "mole.${_rs_id}.exclude_links" 2>/dev/null || true
    else
        uci set "mole.${_rs_id}.exclude_links=${_rs_new_excl}"
    fi

    _rs_count="$(compute_filtered_count "$_rs_id")"
    case "$_rs_count" in ''|*[!0-9]*) _rs_count=0 ;; esac

    rm -f "$_rs_hdr" "$_rs_body"

    # ── Auto-migrate group if profile-title changed ──
    # Fully automatic: if the server now advertises a different brand, we move
    # this sub to the matching group (creating it if needed) and garbage-collect
    # the old group if it becomes empty. No user prompt.
    if [ -n "$_rs_pt" ]; then
        _rs_new_slug="$(slugify "$_rs_pt")"
        [ -z "$_rs_new_slug" ] && _rs_new_slug="untitled"
        _rs_old_gid="$(sub_get "$_rs_id" group_id)"
        if [ -n "$_rs_new_slug" ] && [ "$_rs_new_slug" != "$_rs_old_gid" ]; then
            ensure_group "$_rs_new_slug" "$_rs_pt" 0
            uci set "mole.${_rs_id}.group_id=${_rs_new_slug}"
            # Clean up old group if it was auto-created and is now empty
            if [ -n "$_rs_old_gid" ] && group_exists "$_rs_old_gid"; then
                _rs_left="$(subs_in_group "$_rs_old_gid" | awk -v me="$_rs_id" '$0 != me' | awk 'NF' | head -n1)"
                if [ -z "$_rs_left" ]; then
                    uci -q delete "mole.${_rs_old_gid}" || true
                fi
            fi
        fi
    fi

    uci set "mole.${_rs_id}.profile_title=${_rs_pt}"
    uci set "mole.${_rs_id}.support_url=${_rs_support}"
    uci set "mole.${_rs_id}.web_page_url=${_rs_webpage}"
    uci set "mole.${_rs_id}.update_interval=${_rs_interval}"
    uci set "mole.${_rs_id}.announce=${_rs_ann}"
    uci set "mole.${_rs_id}.traffic_upload=${_rs_up}"
    uci set "mole.${_rs_id}.traffic_download=${_rs_dn}"
    uci set "mole.${_rs_id}.traffic_total=${_rs_tot}"
    uci set "mole.${_rs_id}.traffic_expire=${_rs_exp}"
    uci set "mole.${_rs_id}.traffic_refill=${_rs_refill}"
    uci set "mole.${_rs_id}.routing=${_rs_routing}"
    uci set "mole.${_rs_id}.account_name=${_rs_account}"
    uci set "mole.${_rs_id}.hwid_warning=${_rs_hwid_warn}"
    uci set "mole.${_rs_id}.last_fetch_ts=$(date +%s 2>/dev/null || echo 0)"
    uci set "mole.${_rs_id}.last_http_status=${_rs_http}"
    uci set "mole.${_rs_id}.last_count=${_rs_count}"
    uci set "mole.${_rs_id}.last_error="
    uci commit mole

    exec 9>&-
    log_event "refresh ${_rs_id} ok ${_rs_count} links (HTTP ${_rs_http})"
    return 0
}

# refresh_all [silent=0] — iterate enabled subs, call refresh_subscription each
# Returns number of errors (0 = all ok)
# NB: prints `  Title ...` (no newline) before each fetch, then appends the
# result on the same line after the fetch returns. No spinner, no CSI-based
# line-clearing — those are brittle under minimal SSH TERMs (we saw `\033[2K`
# silently ignored, leaving spinner residue on the result line).
refresh_all() {
    _ra_silent="${1:-0}"
    _ra_ok=0; _ra_err=0; _ra_seen=0
    for _ra_s in $(iterate_sub_names); do
        _ra_en="$(sub_get "$_ra_s" enabled 1)"
        [ "$_ra_en" = "0" ] && continue
        _ra_seen=$((_ra_seen + 1))
        _ra_title="$(sub_get "$_ra_s" custom_name)"
        [ -z "$_ra_title" ] && _ra_title="$(sub_get "$_ra_s" profile_title)"
        [ -z "$_ra_title" ] && _ra_title="$_ra_s"
        if [ "$_ra_silent" = "0" ]; then
            printf "  %b%s%b ... " "$W" "$_ra_title" "$NC"
        fi
        _ra_prev="$(sub_get "$_ra_s" last_count 0)"
        case "$_ra_prev" in ''|*[!0-9]*) _ra_prev=0 ;; esac
        if refresh_subscription "$_ra_s" 1; then
            if [ "$_ra_silent" = "0" ]; then
                _ra_count="$(sub_get "$_ra_s" last_count 0)"
                case "$_ra_count" in ''|*[!0-9]*) _ra_count=0 ;; esac
                _ra_delta=$((_ra_count - _ra_prev))
                if [ "$_ra_delta" -gt 0 ]; then
                    _ra_d=" ${DIM2}(+${_ra_delta})${NC}"
                elif [ "$_ra_delta" -lt 0 ]; then
                    _ra_d=" ${DIM2}(${_ra_delta})${NC}"
                else
                    _ra_d=""
                fi
                _ra_bw="$(fmt_traffic \
                    "$(sub_get "$_ra_s" traffic_upload 0)" \
                    "$(sub_get "$_ra_s" traffic_download 0)" \
                    "$(sub_get "$_ra_s" traffic_total 0)")"
                [ -n "$_ra_bw" ] && _ra_bw="  ${DIM2}${_ra_bw}${NC}" || _ra_bw=""
                echo -e "${ICO_OK} ${DIM2}${_ra_count} links${NC}${_ra_d}${_ra_bw}"
            fi
            _ra_ok=$((_ra_ok + 1))
        else
            if [ "$_ra_silent" = "0" ]; then
                _ra_emsg="$(sub_get "$_ra_s" last_error)"
                [ -z "$_ra_emsg" ] && _ra_emsg="unknown error"
                echo -e "${ICO_ERR} ${ERR}${_ra_emsg}${NC}"
            fi
            _ra_err=$((_ra_err + 1))
        fi
    done
    if [ "$_ra_silent" = "0" ]; then
        if [ "$_ra_seen" -eq 0 ]; then
            echo -e "  ${DIM2}No enabled subscriptions to refresh${NC}"
        else
            echo ""
            if [ "$_ra_err" -eq 0 ]; then
                echo -e "  ${DIM2}${_ra_ok} refreshed${NC}"
            else
                echo -e "  ${DIM2}${_ra_ok} refreshed · ${ERR}${_ra_err} failed${NC}"
            fi
        fi
    fi
    return "$_ra_err"
}

# ─── Cron helpers ────────────────────────────────────────────────────

CRON_FILE="/etc/crontabs/root"
CRON_MARKER="# mole auto-refresh (managed)"
INSTALL_PATH="/usr/bin/mole"

is_script_installed() {
    [ -x "$INSTALL_PATH" ] || return 1
    grep -qF 'MOLE_REPO=' "$INSTALL_PATH" 2>/dev/null
}

# cron_is_registered — 0 if our marker line exists in the root crontab
cron_is_registered() {
    [ -f "$CRON_FILE" ] || return 1
    grep -qxF "$CRON_MARKER" "$CRON_FILE" 2>/dev/null
}

# cron_get_schedule — print the mole line currently in crontab (empty if none)
cron_get_schedule() {
    [ -f "$CRON_FILE" ] || return 0
    awk -v m="$CRON_MARKER" '
        $0 == m { want=1; next }
        want { print; exit }
    ' "$CRON_FILE"
}

# _cron_reload — kick the cron service to reread /etc/crontabs/root
_cron_reload() {
    [ -x /etc/init.d/cron ] || return 0
    /etc/init.d/cron enable 2>/dev/null || true
    /etc/init.d/cron restart 2>/dev/null \
        || /etc/init.d/cron start 2>/dev/null \
        || true
}

# cron_register SCHEDULE — write/replace our 2-line block in crontab, kick cron
cron_register() {
    _cr_sched="$1"
    mkdir -p "$(dirname "$CRON_FILE")" 2>/dev/null || true
    touch "$CRON_FILE"
    _cr_tmp="${CFG_CACHE_DIR}/crontab.$$"
    awk -v m="$CRON_MARKER" '
        $0 == m { skip=1; next }
        skip    { skip=0; next }
        { print }
    ' "$CRON_FILE" > "$_cr_tmp" 2>/dev/null || cp "$CRON_FILE" "$_cr_tmp"
    printf '%s\n%s /usr/bin/mole --cron >>%s 2>&1\n' \
        "$CRON_MARKER" "$_cr_sched" "$CFG_LOG_PATH" >> "$_cr_tmp"
    mv "$_cr_tmp" "$CRON_FILE"
    _cron_reload
}

# cron_unregister — strip our block from crontab, kick cron
cron_unregister() {
    [ -f "$CRON_FILE" ] || return 0
    _cr_tmp="${CFG_CACHE_DIR}/crontab.$$"
    awk -v m="$CRON_MARKER" '
        $0 == m { skip=1; next }
        skip    { skip=0; next }
        { print }
    ' "$CRON_FILE" > "$_cr_tmp" 2>/dev/null || cp "$CRON_FILE" "$_cr_tmp"
    mv "$_cr_tmp" "$CRON_FILE"
    _cron_reload
}

# cron_humanize EXPR — render a cron expression as human text (known presets)
cron_humanize() {
    case "$1" in
        "0 * * * *")    echo "every hour" ;;
        "0 */2 * * *")  echo "every 2 hours" ;;
        "0 */3 * * *")  echo "every 3 hours" ;;
        "0 */4 * * *")  echo "every 4 hours" ;;
        "0 */6 * * *")  echo "every 6 hours" ;;
        "0 */8 * * *")  echo "every 8 hours" ;;
        "0 */12 * * *") echo "every 12 hours" ;;
        "0 0 * * *")    echo "daily at 00:00" ;;
        "0 4 * * *")    echo "daily at 04:00" ;;
        "@daily")       echo "daily at 00:00" ;;
        "@hourly")      echo "every hour" ;;
        *)              printf '%s' "$1" ;;
    esac
}

# cron_last_run_info — tail log for the most recent `--cron` completion line
cron_last_run_info() {
    [ -f "$CFG_LOG_PATH" ] || { echo "-"; return; }
    _lri="$(tail -n 200 "$CFG_LOG_PATH" 2>/dev/null \
        | grep -E 'mole --cron (ok|[0-9]+ error)' \
        | tail -n1)"
    [ -z "$_lri" ] && { echo "-"; return; }
    _lri_ts="$(printf '%s' "$_lri" | sed -n 's/^\[\([^]]*\)\].*/\1/p')"
    _lri_status="$(printf '%s' "$_lri" | sed -n 's/.*mole --cron \(.*\)$/\1/p')"
    printf '%s — %s' "${_lri_ts:--}" "${_lri_status:-unknown}"
}

# cron_min_server_hint_h — smallest `update_interval` (in hours) across enabled
# subs; 0 if none advertise a hint. Min is what user wants — cadence tight
# enough to catch any sub's suggested refresh window.
cron_min_server_hint_h() {
    _mh=0
    for _mh_s in $(iterate_sub_names); do
        _mh_en="$(sub_get "$_mh_s" enabled 1)"
        [ "$_mh_en" = "0" ] && continue
        _mh_iv="$(sub_get "$_mh_s" update_interval 0)"
        case "$_mh_iv" in ''|*[!0-9]*) continue ;; esac
        [ "$_mh_iv" = "0" ] && continue
        _mh_h="$(interpret_interval "$_mh_iv")"
        case "$_mh_h" in ''|*[!0-9]*) continue ;; esac
        [ "$_mh_h" -eq 0 ] && continue
        if [ "$_mh" -eq 0 ] || [ "$_mh_h" -lt "$_mh" ]; then
            _mh="$_mh_h"
        fi
    done
    echo "$_mh"
}

# ─── Manual-link editor + add picker ─────────────────────────────────

# do_manual_editor SUB_ID — list URIs with numeric indices; `+` adds, `d`
# removes by index. Used for `sub_manual` and any other subscription whose
# url = manual://*.
do_manual_editor() {
    _me_id="$1"
    crumb_push "Links"
    while true; do
        clear
        crumb_show
        section "Manual links"

        _me_pool="$(sub_pool_file "$_me_id")"
        _me_count=0
        if [ -f "$_me_pool" ]; then
            _me_count="$(wc -l < "$_me_pool" 2>/dev/null | tr -d ' ')"
        fi
        case "$_me_count" in ''|*[!0-9]*) _me_count=0 ;; esac

        echo -e "  ${DIM2}Total: ${W}${_me_count}${NC} ${DIM2}link(s)${NC}"
        echo ""

        if [ "$_me_count" -gt 0 ]; then
            _mi=0
            while IFS= read -r _me_uri; do
                [ -z "$_me_uri" ] && continue
                _mi=$((_mi + 1))
                _me_name="$(uri_display_name "$_me_uri")"
                [ -z "$_me_name" ] && _me_name="(unnamed)"
                _me_idx="$(printf '%3d' "$_mi")"
                echo -e "  ${B}${_me_idx}${NC} ${DIM2}›${NC} ${W}${_me_name}${NC}"
            done < "$_me_pool"
            echo ""
        fi

        echo -e "  ${DIM2}Links${NC}"
        echo -e "  ${B}+${NC} ${DIM2}›${NC} ${W}Add Link${NC}"
        if [ "$_me_count" -gt 0 ]; then
            echo -e "  ${B}d${NC} ${DIM2}›${NC} ${ERR}Remove Link${NC} ${DIM2}(by index)${NC}"
        fi
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "
        read_choice ME_CHOICE

        case "${ME_CHOICE:-}" in
            +)
                prompt URI "Paste node URI" "" || continue
                is_cancelled && continue
                [ -z "${URI:-}" ] && { warn "URI is empty"; PAUSE; continue; }
                case "$URI" in
                    ss://*|vless://*|trojan://*|socks4://*|socks4a://*|socks5://*|hysteria2://*|hy2://*) ;;
                    *) warn "Unsupported scheme — podkop accepts ss/vless/trojan/socks4,5/hy2"; PAUSE; continue ;;
                esac
                if add_link_to_sub "$_me_id" "$URI"; then
                    _me_name="$(uri_display_name "$URI")"
                    [ -z "$_me_name" ] && _me_name="(unnamed)"
                    echo -e "  ${ICO_OK} ${OK}Added${NC} ${DIM2}›${NC} ${W}${_me_name}${NC}"
                else
                    warn "Already present"
                fi
                PAUSE
                ;;
            d|D)
                if [ "$_me_count" -eq 0 ]; then
                    warn "Nothing to remove"; PAUSE; continue
                fi
                prompt IDX "Index to remove" "" || continue
                case "${IDX:-}" in ''|*[!0-9]*) warn "Need numeric index"; PAUSE; continue ;; esac
                if [ "$IDX" -lt 1 ] 2>/dev/null || [ "$IDX" -gt "$_me_count" ] 2>/dev/null; then
                    warn "Out of range (1..${_me_count})"; PAUSE; continue
                fi
                _me_rm_uri="$(awk -v n="$IDX" 'NR==n {print; exit}' "$_me_pool")"
                if [ -n "$_me_rm_uri" ]; then
                    _me_rm_name="$(uri_display_name "$_me_rm_uri")"
                    [ -z "$_me_rm_name" ] && _me_rm_name="(unnamed)"
                    if confirm "Remove '${_me_rm_name}'?" "n"; then
                        remove_link_from_sub "$_me_id" "$_me_rm_uri"
                        echo -e "  ${ICO_OK} ${OK}Removed${NC}"
                        PAUSE
                    fi
                fi
                ;;
            "") crumb_pop; return ;;
            *) warn "Unknown option: ${ME_CHOICE}"; PAUSE ;;
        esac
    done
}

# do_add_menu — picker invoked from the main menu `+` action. Lets the user
# choose between a URL-based subscription (auto-fetched periodically) and a
# manual link (paste a URI, stored in sub_manual).
do_add_menu() {
    clear
    section "Add new"

    echo -e "  ${B}u${NC} ${DIM2}›${NC} ${W}URL Subscription${NC}  ${DIM2}(auto-fetched)${NC}"
    echo -e "  ${B}l${NC} ${DIM2}›${NC} ${W}Manual Link${NC}  ${DIM2}(paste a single node URI)${NC}"
    echo ""
    echo -e "  ${DIM2}Enter › Back${NC}"
    echo ""
    echo -ne "  ${A}>${NC} "
    read_choice ADD_CHOICE
    case "${ADD_CHOICE:-}" in
        u|U) do_add_subscription ;;
        l|L)
            ensure_manual_sub
            do_manual_editor "$SUB_MANUAL_ID"
            ;;
    esac
}

# ─── Add subscription flow ───────────────────────────────────────────

do_add_subscription() {
    crumb_push "New"
    clear
    crumb_show
    section "Add subscription"

    if ! have_cmd curl; then
        warn "curl is required — install dependencies first (main menu › i)"
        PAUSE; crumb_pop; return
    fi

    prompt URL "Subscription URL" "" || { cancelled; crumb_pop; return; }
    is_cancelled && { cancelled; crumb_pop; return; }
    [ -z "${URL:-}" ] && { warn "URL is empty"; PAUSE; crumb_pop; return; }
    case "$URL" in
        http://*|https://*) ;;
        *) warn "URL must start with http:// or https://"; PAUSE; crumb_pop; return ;;
    esac

    _new_id="$(url_to_sub_id "$URL")"
    if uci -q get "mole.${_new_id}" >/dev/null 2>&1; then
        warn "This URL is already registered as subscription ${_new_id}"
        if ! confirm "Refetch and update metadata?" "y"; then
            PAUSE; crumb_pop; return
        fi
    fi

    _hdr="${CFG_CACHE_DIR}/fetch.$$.hdr"
    _body="${CFG_CACHE_DIR}/fetch.$$.body"
    echo ""
    printf "  %bFetching subscription%b ... " "$W" "$NC"
    if ! fetch_subscription "$URL" "$_hdr" "$_body"; then
        echo -e "${ICO_ERR} ${ERR}failed${NC} ${DIM2}(timeout / HTTP error / DNS)${NC}"
        rm -f "$_hdr" "$_body"
        PAUSE; crumb_pop; return
    fi
    echo -e "${ICO_OK}"

    # Parse status + headers
    _status_line="$(head -n1 "$_hdr" 2>/dev/null | tr -d '\r')"
    _http_code="$(printf '%s' "$_status_line" | awk '{print $2}')"
    case "$_http_code" in ''|*[!0-9]*) _http_code=0 ;; esac

    _pt_raw="$(hdr_get "$_hdr" profile-title)"
    _support="$(hdr_get "$_hdr" support-url)"
    _webpage="$(hdr_get "$_hdr" profile-web-page-url)"
    _interval="$(hdr_get "$_hdr" profile-update-interval)"
    _userinfo="$(hdr_get "$_hdr" subscription-userinfo)"
    _refill="$(hdr_get "$_hdr" subscription-refill-date)"
    _announce_raw="$(hdr_get "$_hdr" announce)"

    _pt="$(decode_profile_title "$_pt_raw")"
    _announce="$(decode_announce "$_announce_raw")"

    _up="$(userinfo_field "$_userinfo" upload)";     [ -z "$_up" ]  && _up=0
    _dn="$(userinfo_field "$_userinfo" download)";   [ -z "$_dn" ]  && _dn=0
    _tot="$(userinfo_field "$_userinfo" total)";     [ -z "$_tot" ] && _tot=0
    _exp="$(userinfo_field "$_userinfo" expire)";    [ -z "$_exp" ] && _exp=0

    _pool_file="$(sub_pool_file "$_new_id")"
    extract_uris "$_body" "$_pool_file" >/dev/null
    # Build metadata sidecar (full meta — exclusions applied at read time)
    build_pool_meta "$_new_id"
    _count="$(compute_filtered_count "$_new_id")"
    case "$_count" in ''|*[!0-9]*) _count=0 ;; esac
    _now="$(date +%s 2>/dev/null || echo 0)"

    _interval_num="$(printf '%s' "$_interval" | sed 's/[^0-9].*//')"
    [ -z "$_interval_num" ] && _interval_num=0
    _interval_h="$(interpret_interval "$_interval_num")"

    # Sanitize numeric userinfo values (header garbage shouldn't reach UCI)
    for _nv in _up _dn _tot _exp; do
        eval "_tmp=\${$_nv:-0}"
        case "$_tmp" in ''|*[!0-9]*) eval "$_nv=0" ;; esac
    done

    rm -f "$_hdr" "$_body"

    # ── Metadata preview ──
    _prev_name="$_pt"
    [ -z "$_prev_name" ] && _prev_name="$(url_display "$URL" 40)"
    _prev_ico="${ICO_OK}"
    [ "$_http_code" -ge 400 ] 2>/dev/null && _prev_ico="${ICO_ERR}"

    # Dedupe Web when its host matches the subscription URL host
    if [ -n "$_webpage" ]; then
        _prev_url_host="$(printf '%s' "$URL" | sed 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||; s|/.*||; s|:.*||')"
        _prev_web_host="$(printf '%s' "$_webpage" | sed 's|^[a-zA-Z][a-zA-Z0-9+.-]*://||; s|/.*||; s|:.*||')"
        [ "$_prev_url_host" = "$_prev_web_host" ] && _webpage=""
    fi

    box_buf_reset
    box_buf_line "  ${_prev_ico} ${W}${_prev_name}${NC}"

    box_buf_sep
    box_buf_line "  ${A}Nodes${NC}     ${W}${_count}${NC}"

    box_buf_sep
    box_buf_line "  ${A}URL${NC}       ${W}$(url_display "$URL" 60)${NC}"

    _has_billing=0
    _bw_add="$(fmt_traffic "$_up" "$_dn" "$_tot")"
    [ -n "$_bw_add" ]   && _has_billing=1
    _has_billing=1
    if [ "$_has_billing" = "1" ]; then
        box_buf_sep
        [ -n "$_bw_add" ]   && box_buf_line "  ${A}Traffic${NC}   ${W}${_bw_add}${NC}"
        if [ "$_exp" != "0" ]; then
            box_buf_line "  ${A}Expires${NC}   ${W}$(fmt_ts "$_exp")${NC} ${DIM2}($(fmt_days_until "$_exp"))${NC}"
        else
            box_buf_line "  ${A}Expires${NC}   ${DIM2}Never${NC}"
        fi
    fi

    _has_links=0
    [ -n "$_support" ]       && _has_links=1
    [ -n "$_webpage" ]       && _has_links=1
    [ "$_interval_h" -gt 0 ] && _has_links=1
    if [ "$_has_links" = "1" ]; then
        box_buf_sep
        [ -n "$_support" ]       && box_buf_line "  ${A}Support${NC}   ${DIM2}${_support}${NC}"
        [ -n "$_webpage" ]       && box_buf_line "  ${A}Web${NC}       ${DIM2}${_webpage}${NC}"
        [ "$_interval_h" -gt 0 ] && box_buf_line "  ${A}Interval${NC}  ${DIM2}every ${_interval_h}h${NC}"
    fi

    box_buf_flush 50 88
    echo ""

    if [ -n "$_announce" ]; then
        echo -e "  ${WARN_C}!${NC} ${DIM2}${_announce}${NC}"
        echo ""
    fi

    if [ "$_count" -eq 0 ]; then
        warn "Body contains no recognized node URIs (ss/trojan/vless/vmess/hy2/tuic/socks)"
        confirm "Save anyway?" "n" || { cancelled; crumb_pop; return; }
    fi

    # ── Group assignment (fully automatic by profile-title) ──
    # No prompt: subs with the same profile-title always share one group.
    # Groups auto-materialise on add and auto-vanish on last member removal.
    _group_title="$_pt"
    [ -z "$_group_title" ] && _group_title="$(url_display "$URL" 30)"
    _slug="$(slugify "$_group_title")"
    [ -z "$_slug" ] && _slug="untitled"
    _group_id="$_slug"
    ensure_group "$_group_id" "$_group_title" 0

    # ── Save ──
    META_ENABLED=1
    META_PROFILE_TITLE="$_pt"
    META_SUPPORT_URL="$_support"
    META_WEB_PAGE_URL="$_webpage"
    META_UPDATE_INTERVAL="$_interval_num"
    META_ANNOUNCE="$_announce"
    META_TRAFFIC_UPLOAD="$_up"
    META_TRAFFIC_DOWNLOAD="$_dn"
    META_TRAFFIC_TOTAL="$_tot"
    META_TRAFFIC_EXPIRE="$_exp"
    META_TRAFFIC_REFILL="$_refill"
    META_LAST_FETCH_TS="$_now"
    META_LAST_HTTP_STATUS="$_http_code"
    META_LAST_COUNT="$_count"
    META_LAST_ERROR=""

    save_subscription "$_new_id" "$URL" "$_group_id"
    uci commit mole
    log_event "sub add ${_new_id} group=${_group_id} url=${URL}"

    echo ""
    echo -e "  ${ICO_OK} ${OK}Saved${NC} ${DIM2}›${NC} ${W}${_new_id}${NC} in ${W}$(group_get "$_group_id" display_name)${NC}"

    # Cron hint prompt
    if [ "$_interval_h" -gt 0 ] && [ "$CFG_CRON_ENABLED" != "1" ]; then
        echo ""
        echo -e "  ${DIM2}Server suggests refresh every ${_interval_h}h.${NC}"
        if confirm "Enable cron with this schedule?" "n"; then
            _cron_h="$_interval_h"
            [ "$_cron_h" -gt 23 ] && _cron_h=24
            if [ "$_cron_h" -eq 24 ]; then
                _cron_new="0 0 * * *"
            else
                _cron_new="0 */${_cron_h} * * *"
            fi
            uci set mole.settings.cron_schedule="$_cron_new"
            uci set mole.settings.cron_enabled='1'
            uci commit mole
            mole_config_load
            cron_register "$_cron_new"
            echo -e "  ${ICO_OK} ${OK}Cron enabled${NC} ${DIM2}($(cron_humanize "$_cron_new"))${NC}"
            ! is_script_installed && echo -e "  ${WARN_C}${ICO_WARN} Script not at ${INSTALL_PATH} — cron will fail; use ${B}u${WARN_C} › Install Script from the main menu${NC}"
        fi
    fi

    PAUSE
    crumb_pop
}

# ─── Routing detail screen ────────────────────────────────────────────

do_routing_info() {
    _ri_raw="$1"
    while true; do
        clear
        crumb_show
        echo ""
        echo -e "  ${W}Routing Rules${NC}"
        echo ""
        _ri_json="$(printf '%s' "$_ri_raw" | base64 -d 2>/dev/null || true)"
        if [ -z "$_ri_json" ]; then
            echo -e "  ${DIM2}(could not decode)${NC}"
        elif have_cmd jq; then
            _ri_name="$(printf '%s' "$_ri_json" | jq -r '.name // ""')"
            _ri_strat="$(printf '%s' "$_ri_json" | jq -r '.domainStrategy // ""')"
            _ri_matcher="$(printf '%s' "$_ri_json" | jq -r '.domainMatcher // ""')"
            _ri_rules_n="$(printf '%s' "$_ri_json" | jq '.rules | length' 2>/dev/null || echo 0)"
            [ -n "$_ri_name" ]    && echo -e "  ${A}Name${NC}      ${W}${_ri_name}${NC}"
            [ -n "$_ri_strat" ]   && echo -e "  ${A}Strategy${NC}  ${DIM2}${_ri_strat}${NC}"
            [ -n "$_ri_matcher" ] && echo -e "  ${A}Matcher${NC}   ${DIM2}${_ri_matcher}${NC}"
            echo ""
            echo -e "  ${DIM2}Rules (${_ri_rules_n})${NC}"
            printf '%s' "$_ri_json" | jq -r '
                .rules[] |
                "  \(.outboundTag // "?")\t\((.domain // []) | join(", "))"
            ' 2>/dev/null | while IFS= read -r _ri_rule; do
                echo -e "  ${DIM2}${_ri_rule}${NC}"
            done
        else
            _ri_name="$(printf '%s' "$_ri_json" | \
                awk -F'"name":"' 'NF>1{split($2,a,"\""); print a[1]; exit}')"
            [ -n "$_ri_name" ] && echo -e "  ${A}Name${NC}      ${W}${_ri_name}${NC}"
            echo ""
            echo -e "  ${DIM2}Install jq for full rule display${NC}"
        fi
        echo ""
        echo -e "  ${WARN_C}These rules are not applied by Podkop.${NC}"
        echo -e "  ${DIM2}Podkop uses its own routing configuration.${NC}"
        echo -e "  ${DIM2}This is informational data from the server.${NC}"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "
        read_choice _ri_k
        case "${_ri_k:-}" in
            "") crumb_pop; return ;;
        esac
    done
}

# ─── Subscription view screen ────────────────────────────────────────

do_subscription_view() {
    _sv_idx="$1"
    _sv_id="$(nth_displayed_sub "$_sv_idx" || true)"
    if [ -z "$_sv_id" ]; then
        warn "Invalid selection: $_sv_idx"
        PAUSE; return
    fi

    _title="$(sub_get "$_sv_id" profile_title)"
    [ -z "$_title" ] && _title="$_sv_id"
    crumb_push "$_title"

    while true; do
        clear
        crumb_show

        _url="$(sub_get "$_sv_id" url)"
        _gid="$(sub_get "$_sv_id" group_id)"
        _pt="$(sub_get "$_sv_id" profile_title)"
        _sup="$(sub_get "$_sv_id" support_url)"
        _web="$(sub_get "$_sv_id" web_page_url)"
        _int="$(sub_get "$_sv_id" update_interval 0)"
        # Lazy-decode: tolerate stale `base64:` values that slipped in before
        # v2 migration, or that a future panel may emit without the prefix
        # being unwrapped on save.
        _ann="$(decode_announce "$(sub_get "$_sv_id" announce)")"
        _up="$(sub_get "$_sv_id" traffic_upload 0)"
        _dn="$(sub_get "$_sv_id" traffic_download 0)"
        _tot="$(sub_get "$_sv_id" traffic_total 0)"
        _exp="$(sub_get "$_sv_id" traffic_expire 0)"
        _ref="$(sub_get "$_sv_id" traffic_refill 0)"
        _routing="$(sub_get "$_sv_id" routing)"
        _account="$(sub_get "$_sv_id" account_name)"
        _hwid_warn="$(sub_get "$_sv_id" hwid_warning 0)"
        _last_ts="$(sub_get "$_sv_id" last_fetch_ts 0)"
        _last_http="$(sub_get "$_sv_id" last_http_status 0)"
        _last_n="$(sub_get "$_sv_id" last_count 0)"
        _last_err="$(sub_get "$_sv_id" last_error)"
        _en="$(sub_get "$_sv_id" enabled 1)"

        _siblings="$(subs_in_group "$_gid" | awk 'NF' | grep -cvx "$_sv_id" 2>/dev/null; true)"
        case "$_siblings" in ''|*[!0-9]*) _siblings=0 ;; esac
        _gname="$(group_get "$_gid" display_name)"
        [ -z "$_gname" ] && _gname="$_gid"

        # Defensive sanitize — older saves may have multi-line garbage
        for _nv in _last_http _last_ts _last_n _tot _up _dn _exp _ref _int; do
            eval "_tmp=\${$_nv:-0}"
            case "$_tmp" in ''|*[!0-9]*) eval "$_nv=0" ;; esac
        done

        _int_h="$(interpret_interval "$_int")"

        _status_ico="${ICO_OK}"
        [ "$_last_http" = "0" ] && _status_ico="${ICO_WARN}"
        [ "$_last_http" -ge 400 ] && _status_ico="${ICO_ERR}"

        # Hero — clean: icon + name only. Status details live in box rows.
        # custom_name (user override via rename) wins over server profile-title.
        _hero_name="$(sub_get "$_sv_id" custom_name)"
        [ -z "$_hero_name" ] && _hero_name="$_pt"
        [ -z "$_hero_name" ] && _hero_name="$_gname"
        [ -z "$_hero_name" ] && _hero_name="$_sv_id"

        if [ -n "$_last_err" ] || [ "$_last_http" -ge 400 ]; then
            _hero_state="err"
        elif [ "$_en" = "0" ]; then
            _hero_state="off"
        else
            _hero_state="ok"
        fi

        # Website: prefer profile-web-page-url header; fall back to sub URL
        _website="${_web:-${_url}}" 

        box_buf_reset
        case "$_hero_state" in
            off)  box_buf_line "  ${DIM2}${_hero_name}${NC}" ;;
            err)  box_buf_line "  ${ERR}${_hero_name}${NC}" ;;
            *)    box_buf_line "  ${W}${_hero_name}${NC}" ;;
        esac

        # ── Identity ──
        box_buf_sep
        [ "$_hero_state" = "off" ] && box_buf_line "  ${A}Status${NC}    ${ERR}Disabled${NC}"
        if [ "$_siblings" -gt 0 ]; then
            box_buf_line "  ${A}Group${NC}     ${W}${_gname}${NC} ${DIM2}(+${_siblings} sibling)${NC}"
        else
            box_buf_line "  ${A}Group${NC}     ${W}${_gname}${NC}"
        fi
        box_buf_line "  ${A}Updated${NC}   ${DIM2}$(fmt_age_since "$_last_ts")${NC}"
        [ "$_int_h" != "0" ] && box_buf_line "  ${A}Interval${NC}  ${DIM2}every ${_int_h}h${NC}"

        # ── Billing ──
        _has_billing=0
        _bw_sv="$(fmt_traffic "$_up" "$_dn" "$_tot")"
        [ -n "$_bw_sv" ]   && _has_billing=1
        _has_billing=1
        [ "$_ref" != "0" ] && _has_billing=1
        if [ "$_has_billing" = "1" ]; then
            box_buf_sep
            [ -n "$_account" ] && box_buf_line "  ${A}Username${NC}  ${DIM2}${_account}${NC}"
            [ -n "$_bw_sv" ]   && box_buf_line "  ${A}Traffic${NC}   ${W}${_bw_sv}${NC}"
            if [ "$_exp" != "0" ]; then
                box_buf_line "  ${A}Expires${NC}   ${W}$(fmt_ts "$_exp")${NC} ${DIM2}($(fmt_days_until "$_exp"))${NC}"
            else
                box_buf_line "  ${A}Expires${NC}   ${DIM2}Never${NC}"
            fi
            [ "$_ref" != "0" ] && box_buf_line "  ${A}Refill${NC}    ${DIM2}$(fmt_ts "$_ref")${NC} ${DIM2}($(fmt_days_until "$_ref"))${NC}"
        fi

        # ── Links ── (Interval = server-suggested refresh; separate from Updated)
        box_buf_sep
        [ -n "$_website" ]   && box_buf_line "  ${A}Website${NC}   ${DIM2}$(url_display "$_website" 64)${NC}"
        [ -n "$_sup" ]       && box_buf_line "  ${A}Support${NC}   ${DIM2}${_sup}${NC}"
        if [ -n "$_routing" ]; then
            _routing_name="$(decode_routing_name "$_routing")"
            [ -z "$_routing_name" ] && _routing_name="${_routing%${_routing#??????????}}"
            box_buf_line "  ${A}Routing${NC}   ${DIM2}${_routing_name}${NC}"
        fi

        box_buf_flush 50 88
        echo ""

        # Routing note — server-side only, not applied by Podkop
        if [ -n "$_routing" ]; then
            echo -e "  ${DIM2}Routing rules provided by server — not applied by Podkop${NC}  ${B}i ›${NC}"
            echo ""
        fi

        # Post-box error banner — surfaces the actual fetch failure message
        # without stuffing it into the frame (long reasons would wrap ugly).
        if [ -n "$_last_err" ]; then
            echo -e "  ${ERR}Failed to fetch subscription:${NC} ${DIM2}${_last_err}${NC}"
            echo ""
        fi

        # HWID warning — device limit reached on this subscription
        if [ "$_hwid_warn" = "1" ]; then
            echo -e "  ${WARN_C}${ICO_WARN} Device limit reached${NC} ${DIM2}— subscription may be blocked on other devices${NC}"
            echo ""
        fi

        # Post-box announcement banner
        if [ -n "$_ann" ]; then
            echo -e "  ${WARN_C}!${NC} ${DIM2}${_ann}${NC}"
            echo ""
        fi

        # ── Node list — prefer .meta; fallback to .uris ──
        # Unified numbering: active and excluded share one 1..N index space so
        # typing any number opens the node view (from which you can un-exclude).
        # _SV_NODE_IDS preserves display order for dispatch.
        _meta="$(sub_meta_file "$_sv_id")"
        _pool="$(sub_pool_file "$_sv_id")"
        _sv_read_excl_p="$(compute_effective_excludes "$_sv_id")"
        _sv_read_excl_l="$(sub_link_excludes "$_sv_id")"
        _SV_NODE_IDS=""
        _SV_NODE_COUNT=0
        if [ -f "$_meta" ] && [ -s "$_meta" ]; then
            _pool_n="$(compute_filtered_count "$_sv_id")"
            case "$_pool_n" in ''|*[!0-9]*) _pool_n=0 ;; esac
            echo -e "  ${DIM2}Nodes (${_pool_n})${NC}"
            _sv_ntab="$(printf '\t')"
            _sv_act="${CFG_CACHE_DIR}/sv_act.${_sv_id}.$$"
            _sv_lnk="${CFG_CACHE_DIR}/sv_lnk.${_sv_id}.$$"
            _sv_prt="${CFG_CACHE_DIR}/sv_prt.${_sv_id}.$$"
            _sv_raw="${CFG_CACHE_DIR}/sv_raw.${_sv_id}.$$"
            : > "$_sv_raw"
            while IFS="$META_FS" read -r _lid _proto _host _port _ip _asn _cc _flag _ping _name; do
                [ -z "$_lid" ] && continue
                [ -z "$_name" ] && _name="(unnamed)"
                _is_proto_excl=0
                if [ -n "$_sv_read_excl_p" ]; then
                    case " $_sv_read_excl_p " in *" $_proto "*) _is_proto_excl=1 ;; esac
                fi
                _is_link_excl=0
                if [ "$_is_proto_excl" = "0" ] && [ -n "$_sv_read_excl_l" ]; then
                    case " $_sv_read_excl_l " in *" $_lid "*) _is_link_excl=1 ;; esac
                fi
                if [ "$_is_proto_excl" = "1" ]; then
                    printf '2%s%s%s%s%s%s%s%s\n' "$_sv_ntab" "$_proto" "$_sv_ntab" "$_lid" "$_sv_ntab" "$_flag" "$_sv_ntab" "$_name" >> "$_sv_raw"
                elif [ "$_is_link_excl" = "1" ]; then
                    printf '1%s%s%s%s%s%s%s%s\n' "$_sv_ntab" "$_proto" "$_sv_ntab" "$_lid" "$_sv_ntab" "$_flag" "$_sv_ntab" "$_name" >> "$_sv_raw"
                else
                    printf '0%s%s%s%s%s%s%s%s\n' "$_sv_ntab" "$_proto" "$_sv_ntab" "$_lid" "$_sv_ntab" "$_flag" "$_sv_ntab" "$_name" >> "$_sv_raw"
                fi
            done < "$_meta"

            awk -F'\t' '$1==0' "$_sv_raw" | sort -t"$_sv_ntab" -k2,2 > "$_sv_act"
            awk -F'\t' '$1==1' "$_sv_raw" | sort -t"$_sv_ntab" -k2,2 > "$_sv_lnk"
            awk -F'\t' '$1==2' "$_sv_raw" | sort -t"$_sv_ntab" -k2,2 > "$_sv_prt"
            rm -f "$_sv_raw"

            # Build _SV_NODE_IDS from active + link-excluded only (proto-excluded
            # are informational — no node view needed for them).
            while IFS="$_sv_ntab" read -r _t _p _l _f _n; do
                _SV_NODE_COUNT=$((_SV_NODE_COUNT + 1))
                _SV_NODE_IDS="${_SV_NODE_IDS} ${_l}"
            done < "$_sv_act"
            while IFS="$_sv_ntab" read -r _t _p _l _f _n; do
                _SV_NODE_COUNT=$((_SV_NODE_COUNT + 1))
                _SV_NODE_IDS="${_SV_NODE_IDS} ${_l}"
            done < "$_sv_lnk"

            _active_n="$(wc -l < "$_sv_act" | tr -d ' ')"
            _excl_n="$(wc -l < "$_sv_lnk" | tr -d ' ')"
            _proto_excl_n="$(wc -l < "$_sv_prt" | tr -d ' ')"

            _sv_seq=0
            while IFS="$_sv_ntab" read -r _t _p _l _f _n; do
                _sv_seq=$((_sv_seq + 1))
                echo -e "  ${B}$(printf '%3d' "$_sv_seq")${NC} ${DIM2}›${NC} ${_f:+${_f} }${W}${_n}${NC}  ${DIM2}$(proto_badge "$_p")${NC}"
            done < "$_sv_act"

            if [ "$_excl_n" -gt 0 ]; then
                echo ""
                echo -e "  ${DIM2}Excluded (${_excl_n})${NC}"
                _sv_seq="$_active_n"
                while IFS="$_sv_ntab" read -r _t _p _l _f _n; do
                    _sv_seq=$((_sv_seq + 1))
                    echo -e "  ${DIM2}$(printf '%3d' "$_sv_seq") ›${NC} ${_f:+${_f} }${DIM2}${_n}  $(proto_badge "$_p")${NC}"
                done < "$_sv_lnk"
            fi
            if [ "$_proto_excl_n" -gt 0 ]; then
                echo ""
                echo -e "  ${DIM2}Excluded by protocol (${_proto_excl_n})${NC}"
                while IFS="$_sv_ntab" read -r _t _p _l _f _n; do
                    echo -e "  ${DIM2}  ·   ${_f:+${_f} }${_n}  $(proto_badge "$_p")${NC}"
                done < "$_sv_prt"
            fi
            _sv_stale_f="$(sub_stale_file "$_sv_id")"
            if [ -f "$_sv_stale_f" ] && [ -s "$_sv_stale_f" ]; then
                _sv_stale_n="$(wc -l < "$_sv_stale_f" | tr -d ' ')"
                echo ""
                echo -e "  ${DIM2}Stale (${_sv_stale_n}) — will re-exclude if seen again${NC}"
                _sv_stab="$(printf '	')"
                while IFS="$_sv_stab" read -r _sl _sn; do
                    [ -z "$_sl" ] && continue
                    echo -e "  ${DIM2}  ~   ${_sn}${NC}"
                done < "$_sv_stale_f"
            fi
            rm -f "$_sv_act" "$_sv_lnk" "$_sv_prt"
            echo ""
        elif [ -f "$_pool" ] && [ -s "$_pool" ]; then
            _pool_n="$(wc -l < "$_pool" 2>/dev/null)"
            case "$_pool_n" in ''|*[!0-9]*) _pool_n=0 ;; esac
            echo -e "  ${DIM2}Nodes (${_pool_n})${NC}"
            _ni=0
            while IFS= read -r _uri_line; do
                [ -z "$_uri_line" ] && continue
                _ni=$((_ni + 1))
                _nm="$(uri_display_name "$_uri_line")"
                [ -z "$_nm" ] && _nm="(unnamed)"
                _idx_fmt="$(printf '%3d' "$_ni")"
                echo -e "  ${B}${_idx_fmt}${NC} ${DIM2}›${NC} ${W}${_nm}${NC}"
            done < "$_pool"
            echo ""
        else
            echo -e "  ${DIM2}Nodes${NC}"
            echo -e "  ${DIM2}(pool not built yet — refresh to populate)${NC}"
            echo ""
        fi

        _sv_inherit="$(sub_get "$_sv_id" exclude_inherit 1)"
        _sv_own_excl="$(sub_get "$_sv_id" exclude_protocols)"
        _sv_eff_excl="$(compute_effective_excludes "$_sv_id")"
        if [ "$_sv_inherit" = "1" ]; then
            _sv_excl_label="${DIM2}Inherit${NC}"
        else
            _sv_excl_label="${DIM2}Custom${NC}"
        fi

        _sv_is_manual=0
        case "$_url" in manual://*) _sv_is_manual=1 ;; esac

        # Liminal-style sections: Configuration (how the sub behaves) →
        # Subscription (lifecycle ops on the entity itself).
        echo -e "  ${DIM2}Configuration${NC}"
        echo -e "  ${B}g${NC} ${DIM2}›${NC} ${W}Group Settings${NC}"
        echo -e "  ${B}x${NC} ${DIM2}›${NC} ${W}Exclude Protocols${NC} ${DIM2}[${NC}${_sv_excl_label}${DIM2}]${NC}"
        echo -e "  ${B}b${NC} ${DIM2}›${NC} ${W}Batch Exclude / Include${NC}"
        [ -n "$_routing" ] && echo -e "  ${B}i${NC} ${DIM2}›${NC} ${W}View Routing Rules${NC}"
        if [ "$_sv_is_manual" = "1" ]; then
            echo -e "  ${B}l${NC} ${DIM2}›${NC} ${W}Manage Links${NC}"
        fi
        echo ""
        echo -e "  ${DIM2}Subscription${NC}"
        echo -e "  ${B}r${NC} ${DIM2}›${NC} ${A}Refresh${NC} Subscription"
        echo -e "  ${B}m${NC} ${DIM2}›${NC} ${W}Rename${NC} Subscription"
        if [ "$_en" = "1" ]; then
            echo -e "  ${B}t${NC} ${DIM2}›${NC} ${ERR}Disable${NC} Subscription"
        else
            echo -e "  ${B}t${NC} ${DIM2}›${NC} ${OK}Enable${NC} Subscription"
        fi
        echo -e "  ${B}d${NC} ${DIM2}›${NC} ${ERR}Delete${NC} Subscription"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "
        read_choice CHOICE

        case "${CHOICE:-}" in
            i|I)
                if [ -n "$_routing" ]; then
                    crumb_push "Routing"
                    do_routing_info "$_routing"
                fi
                ;;
            g|G)
                if [ -n "$_gid" ] && group_exists "$_gid"; then
                    do_group_settings "$_gid"
                else
                    warn "This subscription has no group (ungrouped)"
                    PAUSE
                fi
                ;;
            x|X) do_protocol_exclude_screen "sub" "$_sv_id" ;;
            b|B) do_batch_exclude "$_sv_id" ;;
            l|L)
                if [ "$_sv_is_manual" = "1" ]; then
                    do_manual_editor "$_sv_id"
                else
                    warn "Manage links is only available for manual subscriptions"
                    PAUSE
                fi
                ;;
            r|R)
                printf "  %bRefreshing%b ... " "$W" "$NC"
                if refresh_subscription "$_sv_id" 1; then
                    _cnt="$(sub_get "$_sv_id" last_count 0)"
                    echo -e "${ICO_OK} ${DIM2}${_cnt} links${NC}"
                else
                    _emsg="$(sub_get "$_sv_id" last_error)"
                    [ -z "$_emsg" ] && _emsg="unknown error"
                    echo -e "${ICO_ERR} ${ERR}${_emsg}${NC}"
                fi
                PAUSE
                ;;
            t|T)
                if [ "$_en" = "1" ]; then
                    uci set "mole.${_sv_id}.enabled=0"
                else
                    uci set "mole.${_sv_id}.enabled=1"
                fi
                uci commit mole
                ;;
            m|M)
                _cur_custom="$(sub_get "$_sv_id" custom_name)"
                [ -n "$_cur_custom" ] && echo -e "  ${DIM2}Current: ${_cur_custom}${NC}"
                prompt NEW_CUSTOM "New name (empty to clear)" || continue
                if [ -z "${NEW_CUSTOM:-}" ]; then
                    uci -q delete "mole.${_sv_id}.custom_name" || true
                    echo -e "  ${ICO_OK} ${OK}Cleared${NC} ${DIM2}(reverting to profile-title)${NC}"
                else
                    uci set "mole.${_sv_id}.custom_name=$(sanitize_uci_val "${NEW_CUSTOM}")"
                    echo -e "  ${ICO_OK} ${OK}Renamed${NC}"
                fi
                uci commit mole
                PAUSE
                ;;
            d|D)
                if confirm "Delete subscription ${_sv_id}?" "n"; then
                    rm -f "$(sub_pool_file "$_sv_id")" "$(sub_meta_file "$_sv_id")" "$(sub_stale_file "$_sv_id")"
                    uci -q delete "mole.${_sv_id}" || true
                    uci commit mole
                    log_event "sub delete ${_sv_id}"
                    # Orphan group cleanup
                    if [ -z "$(subs_in_group "$_gid")" ] \
                       && [ "$(group_get "$_gid" manual 0)" = "0" ]; then
                        uci -q delete "mole.${_gid}" || true
                        uci commit mole
                    fi
                    # Auto-flush if this sub's group feeds any managed section
                    if podkop_present && [ -n "$_gid" ]; then
                        _af_linked=0
                        for _af_t in $(mole_managed_sections); do
                            case " $(ps_sources "$_af_t") " in
                                *" $_gid "*) _af_linked=1; break ;;
                            esac
                        done
                        if [ "$_af_linked" = "1" ]; then
                            flush_all_auto 1 >/dev/null 2>&1 || true
                        fi
                    fi
                    crumb_pop
                    return
                fi
                ;;
            "") crumb_pop; return ;;
            *)
                # Numeric input = open node view for that entry
                case "$CHOICE" in
                    ''|*[!0-9]*) warn "Unknown option: ${CHOICE}"; PAUSE ;;
                    *)
                        if [ "$CHOICE" -ge 1 ] 2>/dev/null && \
                           [ "$CHOICE" -le "${_SV_NODE_COUNT:-0}" ]; then
                            _i=0; _sel_lid=""
                            for _l in $_SV_NODE_IDS; do
                                _i=$((_i + 1))
                                [ "$_i" = "$CHOICE" ] && { _sel_lid="$_l"; break; }
                            done
                            if [ -n "$_sel_lid" ]; then
                                do_node_view "$_sv_id" "$_sel_lid"
                            fi
                        else
                            warn "No node at index $CHOICE"; PAUSE
                        fi
                        ;;
                esac
                ;;
        esac
    done
}

# parse_index_list INPUT MAX — parse "1 3 5-8" or "1,3,5-8" into resolved
# indices in [1..MAX], one per line. Invalid tokens / out-of-range silently
# dropped.
parse_index_list() {
    _pil_in="$1"; _pil_max="$2"
    _pil_tokens="$(printf '%s' "$_pil_in" | tr ',' ' ')"
    for _pil_t in $_pil_tokens; do
        case "$_pil_t" in
            *-*)
                _pil_a="${_pil_t%%-*}"
                _pil_b="${_pil_t##*-}"
                case "$_pil_a" in ''|*[!0-9]*) continue ;; esac
                case "$_pil_b" in ''|*[!0-9]*) continue ;; esac
                [ "$_pil_a" -gt "$_pil_b" ] && { _pil_tmp="$_pil_a"; _pil_a="$_pil_b"; _pil_b="$_pil_tmp"; }
                _pil_i="$_pil_a"
                while [ "$_pil_i" -le "$_pil_b" ] 2>/dev/null; do
                    [ "$_pil_i" -ge 1 ] 2>/dev/null && [ "$_pil_i" -le "$_pil_max" ] 2>/dev/null && echo "$_pil_i"
                    _pil_i=$((_pil_i + 1))
                done
                ;;
            *)
                case "$_pil_t" in ''|*[!0-9]*) continue ;; esac
                [ "$_pil_t" -ge 1 ] 2>/dev/null && [ "$_pil_t" -le "$_pil_max" ] 2>/dev/null && echo "$_pil_t"
                ;;
        esac
    done
}

# do_batch_exclude SUB_ID — batch include/exclude operations on the sub's
# per-link exclusion list. Three actions:
#   a  Exclude all — adds every link_id from .meta to exclude_links
#   n  Include all — clears the exclude_links list
#   i  Selective   — prompts for indices/ranges and toggles each
# Protocol exclusions are independent and unaffected.
do_batch_exclude() {
    _be_sid="$1"
    _be_meta="$(sub_meta_file "$_be_sid")"
    if [ ! -f "$_be_meta" ] || [ ! -s "$_be_meta" ]; then
        warn "No pool metadata — refresh the subscription first"; PAUSE; return
    fi

    crumb_push "Batch"
    while true; do
        clear
        crumb_show
        section "Batch exclude / include"

        _be_cur="$(sub_link_excludes "$_be_sid")"
        _be_excl_p="$(compute_effective_excludes "$_be_sid")"

        # Enumerate link_ids in .meta order + render the list inline so the
        # user can see what index points to what before typing toggles.
        _be_ids=""
        _be_total=0
        _be_excl_n=0
        _be_proto_n=0
        _be_pw=2
        while IFS="$META_FS" read -r _lid _proto _host _port _ip _asn _cc _flag _ping _name; do
            _pw="${#_proto}"; [ "$_pw" -gt "$_be_pw" ] && _be_pw="$_pw"
            [ -z "$_lid" ] && continue
            [ -z "$_name" ] && _name="(unnamed)"

            _be_is_proto_excl=0
            if [ -n "$_be_excl_p" ]; then
                case " $_be_excl_p " in
                    *" $_proto "*) _be_is_proto_excl=1 ;;
                esac
            fi

            if [ "$_be_is_proto_excl" = "1" ]; then
                _be_proto_n=$((_be_proto_n + 1))
                continue
            fi

            _be_total=$((_be_total + 1))
            _be_ids="${_be_ids}${_be_ids:+ }${_lid}"
            _be_idx_fmt="$(printf '%3d' "$_be_total")"

            _be_is_link_excl=0
            case " $_be_cur " in
                *" $_lid "*) _be_is_link_excl=1 ;;
            esac

            if [ "$_be_is_link_excl" = "1" ]; then
                _be_mark="${ERR}x${NC}"
                _be_excl_n=$((_be_excl_n + 1))
                echo -e "  ${B}${_be_idx_fmt}${NC} [${_be_mark}] ${DIM2}$(printf "%-${_be_pw}s" "$_proto")${NC}  ${DIM2}${_name}${NC}"
            else
                echo -e "  ${B}${_be_idx_fmt}${NC} [ ] ${DIM2}$(printf "%-${_be_pw}s" "$_proto")${NC}  ${W}${_name}${NC}"
            fi
        done < "$_be_meta"
        echo ""

        if [ -n "$_be_excl_p" ]; then
            echo -e "  ${DIM2}── Protocol excludes (${_be_proto_n} nodes hidden) ──${NC}"
            for _be_p in $_be_excl_p; do
                echo -e "  ${DIM2}  ${_be_p}://${NC}"
            done
            echo ""
        fi

        _be_stale_f="$(sub_stale_file "$_be_sid")"
        _be_stale_n=0
        [ -f "$_be_stale_f" ] && [ -s "$_be_stale_f" ] && \
            _be_stale_n="$(wc -l < "$_be_stale_f" | tr -d ' ')"

        box_buf_reset
        box_buf_line "  ${A}Nodes${NC}    ${W}${_be_total}${NC} ${DIM2}toggleable${NC}"
        box_buf_line "  ${A}Excluded${NC} ${ERR}${_be_excl_n}${NC} ${DIM2}per-link${NC}"
        [ "${_be_stale_n:-0}" -gt 0 ] && \
            box_buf_line "  ${A}Stale${NC}    ${DIM2}${_be_stale_n}${NC}"
        box_buf_flush 40 80
        echo ""

        echo -e "  ${B}a${NC} ${DIM2}›${NC} ${ERR}Exclude All${NC}"
        echo -e "  ${B}n${NC} ${DIM2}›${NC} ${OK}Include All${NC} ${DIM2}(clear per-link excludes)${NC}"
        [ "${_be_stale_n:-0}" -gt 0 ] && \
            echo -e "  ${B}s${NC} ${DIM2}›${NC} ${WARN_C}Remove Stale Nodes${NC} ${DIM2}(${_be_stale_n})${NC}"
        echo -e "  ${DIM2}Or type indices to toggle: \"1 3 5-8\"${NC}"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "
        # Raw read — read_choice would strip spaces and '-' (both needed here)
        read -r BE_RAW || true
        BE_RAW="$(printf '%s' "${BE_RAW:-}" | tr -d '\001-\037\177')"
        [ "${_SIGINT:-0}" -eq 1 ] && { crumb_pop; return; }

        case "$BE_RAW" in
            "") crumb_pop; return ;;
            s|S)
                if [ "${_be_stale_n:-0}" -eq 0 ]; then
                    echo -e "  ${DIM2}No stale nodes${NC}"; PAUSE
                else
                    if confirm "Remove ${_be_stale_n} stale node(s)?" "n"; then
                        rm -f "$_be_stale_f"
                        echo -e "  ${ICO_OK} ${OK}Stale list cleared${NC}"
                        PAUSE
                    fi
                fi
                ;;
            a|A)
                if confirm "Exclude all ${_be_total} nodes?" "n"; then
                    if [ -n "$_be_ids" ]; then
                        uci set "mole.${_be_sid}.exclude_links=${_be_ids}"
                    fi
                    update_sub_count "$_be_sid"
                    uci commit mole
                    echo -e "  ${ICO_OK} ${OK}All excluded${NC}"
                    PAUSE
                fi
                ;;
            n|N)
                if [ "$_be_excl_n" -eq 0 ]; then
                    echo -e "  ${DIM2}Already empty${NC}"
                    PAUSE
                else
                    if confirm "Clear all per-link excludes (${_be_excl_n})?" "n"; then
                        uci -q delete "mole.${_be_sid}.exclude_links" 2>/dev/null || true
                        update_sub_count "$_be_sid"
                        uci commit mole
                        echo -e "  ${ICO_OK} ${OK}Cleared${NC}"
                        PAUSE
                    fi
                fi
                ;;
            *)
                # Everything else: try to parse as index list and toggle.
                _be_idx_list="$(parse_index_list "$BE_RAW" "$_be_total")"
                if [ -z "$_be_idx_list" ]; then
                    warn "Unknown option or invalid indices: ${BE_RAW}"; PAUSE
                else
                    _be_toggled=0
                    for _be_idx in $_be_idx_list; do
                        _be_seek=0
                        for _be_l in $_be_ids; do
                            _be_seek=$((_be_seek + 1))
                            if [ "$_be_seek" = "$_be_idx" ]; then
                                toggle_link_exclude "$_be_sid" "$_be_l"
                                _be_toggled=$((_be_toggled + 1))
                                break
                            fi
                        done
                    done
                    update_sub_count "$_be_sid"
                    uci commit mole
                    echo -e "  ${ICO_OK} ${OK}Toggled ${_be_toggled} node(s)${NC}"
                    PAUSE
                fi
                ;;
        esac
    done
}

# ─── Node detail screen ──────────────────────────────────────────────
#
# Opens when the user types a node index in subscription-view. Shows parsed
# fields, the raw URI (for copy/paste), and per-node actions: toggle exclude,
# ping just this node, render QR code.
do_node_view() {
    _nv_sid="$1"; _nv_lid="$2"
    _nv_meta="$(sub_meta_file "$_nv_sid")"
    _nv_pool="$(sub_pool_file "$_nv_sid")"

    if [ ! -f "$_nv_meta" ]; then
        warn "No metadata for ${_nv_sid}"; PAUSE; return
    fi

    # Find the meta row for this link_id
    _nv_row="$(awk -v lid="$_nv_lid" -v FS="$META_FS" '$1 == lid { print; exit }' "$_nv_meta")"
    if [ -z "$_nv_row" ]; then
        warn "Node ${_nv_lid} not found in meta"; PAUSE; return
    fi
    _nv_proto="$(printf '%s' "$_nv_row" | awk -v FS="$META_FS" '{print $2}')"
    _nv_host="$(printf '%s' "$_nv_row" | awk -v FS="$META_FS" '{print $3}')"
    _nv_port="$(printf '%s' "$_nv_row" | awk -v FS="$META_FS" '{print $4}')"
    _nv_ping="$(printf '%s' "$_nv_row" | awk -v FS="$META_FS" '{print $9}')"
    _nv_name="$(printf '%s' "$_nv_row" | awk -v FS="$META_FS" '{print $10}')"
    [ -z "$_nv_name" ] && _nv_name="(unnamed)"

    # Walk the pool to find the matching URI (match by recomputed link_id)
    _nv_uri=""
    if [ -f "$_nv_pool" ]; then
        while IFS= read -r _uri_line; do
            [ -z "$_uri_line" ] && continue
            if [ "$(link_id "$_uri_line")" = "$_nv_lid" ]; then
                _nv_uri="$_uri_line"
                break
            fi
        done < "$_nv_pool"
    fi

    # Parse URI fields once (URI is constant across loop iterations)
    _nv_uid="" _nv_sec="" _nv_sni="" _nv_fp="" _nv_alpn=""
    _nv_pbk="" _nv_sid_r="" _nv_type="" _nv_path="" _nv_hosth=""
    _nv_insecure="" _nv_flow="" _nv_obfs="" _nv_obfs_pw=""
    if [ -n "$_nv_uri" ]; then
        case "$_nv_proto" in
            vless|trojan)
                _nv_uid="$(uri_userinfo "$_nv_uri")"
                _nv_flow="$(uri_param "$_nv_uri" flow)"
                ;;
            ss)
                _ss_ui="$(uri_userinfo "$_nv_uri")"
                _ss_dec="$(printf '%s' "$_ss_ui" | base64 -d 2>/dev/null || true)"
                [ -n "$_ss_dec" ] && _nv_uid="$_ss_dec" || _nv_uid="$_ss_ui"
                ;;
            hysteria2|hy2)
                _nv_uid="$(uri_userinfo "$_nv_uri")"
                _nv_obfs="$(uri_param "$_nv_uri" obfs)"
                _nv_obfs_pw="$(uri_param "$_nv_uri" obfs-password)"
                ;;
        esac
        _nv_sec="$(uri_param "$_nv_uri" security)"
        _nv_sni="$(uri_param "$_nv_uri" sni)"
        _nv_fp="$(uri_param "$_nv_uri" fp)"
        _nv_alpn="$(url_decode "$(uri_param "$_nv_uri" alpn)")"
        _nv_pbk="$(uri_param "$_nv_uri" pbk)"
        _nv_sid_r="$(uri_param "$_nv_uri" sid)"
        _nv_type="$(uri_param "$_nv_uri" type)"
        _nv_path="$(url_decode "$(uri_param "$_nv_uri" path)")"
        _nv_hosth="$(url_decode "$(uri_param "$_nv_uri" host)")"
        _nv_insecure="$(uri_param "$_nv_uri" insecure)"
        [ -z "$_nv_insecure" ] && _nv_insecure="$(uri_param "$_nv_uri" allowInsecure)"
    fi

    crumb_push "$_nv_name"
    while true; do
        clear
        crumb_show

        # Recompute exclusion status each iteration (user may toggle)
        _nv_excl_p_list="$(compute_effective_excludes "$_nv_sid")"
        _nv_excl_l_list="$(sub_link_excludes "$_nv_sid")"
        _nv_excl_reason=""
        case " $_nv_excl_p_list " in
            *" $_nv_proto "*) _nv_excl_reason="protocol ${_nv_proto}" ;;
        esac
        if [ -z "$_nv_excl_reason" ]; then
            case " $_nv_excl_l_list " in
                *" $_nv_lid "*) _nv_excl_reason="manually excluded" ;;
            esac
        fi

        if [ -n "$_nv_excl_reason" ]; then
            _nv_ico="${ICO_DIS}"
            _nv_status="${DIM2}excluded (${_nv_excl_reason})${NC}"
        else
            _nv_ico="${ICO_OK}"
            _nv_status="${OK}included${NC}"
        fi

        box_buf_reset
        box_buf_line "  ${_nv_ico} ${W}${_nv_name}${NC}"
        box_buf_sep
        box_buf_line "  ${A}Protocol${NC}  ${W}${_nv_proto}${NC}"
        box_buf_line "  ${A}Address${NC}   ${W}${_nv_host}${NC}"
        box_buf_line "  ${A}Port${NC}      ${W}${_nv_port}${NC}"
        box_buf_line "  ${A}Status${NC}    ${_nv_status}"
        [ -n "$_nv_uid" ]  && box_buf_line "  ${A}ID${NC}        ${DIM2}${_nv_uid}${NC}"
        [ -n "$_nv_flow" ] && box_buf_line "  ${A}Flow${NC}      ${DIM2}${_nv_flow}${NC}"

        # Transport
        if [ -n "$_nv_type" ] && [ "$_nv_type" != "tcp" ]; then
            box_buf_sep
            box_buf_line "  ${A}Network${NC}   ${W}${_nv_type}${NC}"
            [ -n "$_nv_path" ]  && box_buf_line "  ${A}Path${NC}      ${DIM2}${_nv_path}${NC}"
            [ -n "$_nv_hosth" ] && box_buf_line "  ${A}Host${NC}      ${DIM2}${_nv_hosth}${NC}"
        elif [ -n "$_nv_type" ]; then
            box_buf_sep
            box_buf_line "  ${A}Network${NC}   ${W}${_nv_type}${NC}"
        fi

        # Security
        _nv_has_sec=0
        [ -n "$_nv_sec" ]      && _nv_has_sec=1
        [ -n "$_nv_sni" ]      && _nv_has_sec=1
        [ -n "$_nv_fp" ]       && _nv_has_sec=1
        [ -n "$_nv_pbk" ]      && _nv_has_sec=1
        [ -n "$_nv_obfs" ]     && _nv_has_sec=1
        if [ "$_nv_has_sec" = "1" ]; then
            box_buf_sep
            [ -n "$_nv_sec" ]      && box_buf_line "  ${A}Security${NC}  ${W}${_nv_sec}${NC}"
            [ -n "$_nv_sni" ]      && box_buf_line "  ${A}SNI${NC}       ${DIM2}${_nv_sni}${NC}"
            [ -n "$_nv_fp" ]       && box_buf_line "  ${A}FP${NC}        ${DIM2}${_nv_fp}${NC}"
            [ -n "$_nv_alpn" ]     && box_buf_line "  ${A}ALPN${NC}      ${DIM2}${_nv_alpn}${NC}"
            [ -n "$_nv_pbk" ]      && box_buf_line "  ${A}Public Key${NC} ${DIM2}${_nv_pbk}${NC}"
            [ -n "$_nv_sid_r" ]    && box_buf_line "  ${A}Short ID${NC}  ${DIM2}${_nv_sid_r}${NC}"
            [ -n "$_nv_obfs" ]     && box_buf_line "  ${A}Obfs${NC}      ${DIM2}${_nv_obfs}${NC}"
            [ -n "$_nv_obfs_pw" ]  && box_buf_line "  ${A}Obfs PW${NC}   ${DIM2}${_nv_obfs_pw}${NC}"
            case "$_nv_insecure" in
                1|true|yes) box_buf_line "  ${A}Insecure${NC}  ${WARN_C}yes${NC}" ;;
            esac
        fi

        box_buf_flush 50 88
        echo ""

        # URI block — printed on its own line so mouse-select copies cleanly
        if [ -n "$_nv_uri" ]; then
            echo -e "  ${DIM2}URI${NC}"
            echo "  ${_nv_uri}"
            echo ""
        fi

        # Actions
        _nv_is_protocol_excl=0
        case " $_nv_excl_p_list " in
            *" $_nv_proto "*) _nv_is_protocol_excl=1 ;;
        esac
        _nv_is_link_excl=0
        case " $_nv_excl_l_list " in
            *" $_nv_lid "*) _nv_is_link_excl=1 ;;
        esac

        echo -e "  ${DIM2}Node${NC}"
        if [ "$_nv_is_protocol_excl" = "1" ]; then
            echo -e "  ${DIM2}x › Excluded by protocol (${_nv_proto}) — change in Exclude Protocols${NC}"
        elif [ "$_nv_is_link_excl" = "1" ]; then
            echo -e "  ${B}x${NC} ${DIM2}›${NC} ${W}Include${NC} Node"
        else
            echo -e "  ${B}x${NC} ${DIM2}›${NC} ${W}Exclude${NC} Node"
        fi
        if have_cmd qrencode; then
            echo -e "  ${B}q${NC} ${DIM2}›${NC} ${W}QR Code${NC}"
        else
            echo -e "  ${DIM2}q › QR Code (install qrencode to enable)${NC}"
        fi
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "
        read_choice NV_CHOICE

        case "${NV_CHOICE:-}" in
            x|X)
                if [ "$_nv_is_protocol_excl" = "1" ]; then
                    warn "This protocol is excluded at sub/group level; toggle there instead"
                    PAUSE
                    continue
                fi
                toggle_link_exclude "$_nv_sid" "$_nv_lid"
                update_sub_count "$_nv_sid"
                uci commit mole
                ;;
            q|Q)
                if have_cmd qrencode; then
                    if [ -n "$_nv_uri" ]; then
                        echo ""
                        printf '%s' "$_nv_uri" | qrencode -t ANSIUTF8 -s 1
                        echo ""
                        PAUSE
                    else
                        warn "No URI available"; PAUSE
                    fi
                else
                    warn "qrencode not installed — opkg install qrencode"; PAUSE
                fi
                ;;
            "") crumb_pop; return ;;
            *) warn "Unknown option: ${NV_CHOICE}"; PAUSE ;;
        esac
    done
}

# ─── Stubs for later steps ───────────────────────────────────────────
# These menu entry points print a "not implemented yet" hint so the main
# menu is fully navigable while real handlers land in subsequent commits.

_stub_todo() {
    echo ""
    echo -e "  ${DIM2}${1}${NC}"
    echo -e "  ${DIM2}Not implemented yet — lands in a follow-up step.${NC}"
    PAUSE
}

do_groups_menu() {
    crumb_push "Groups"
    while true; do
        clear
        crumb_show
        section "Groups"

        _gi=0
        _gids=""
        for _g in $(iterate_group_names); do
            _gi=$((_gi + 1))
            _gids="${_gids} ${_g}"
            _dn="$(group_get "$_g" display_name)"
            [ -z "$_dn" ] && _dn="$_g"
            _subs="$(subs_in_group "$_g")"
            _nsubs="$(printf '%s' "$_subs" | awk 'NF' | wc -l | tr -d ' ')"
            _nn=0
            for _s in $_subs; do
                _c="$(sub_get "$_s" last_count 0)"
                case "$_c" in ''|*[!0-9]*) _c=0 ;; esac
                _nn=$((_nn + _c))
            done
            echo -e "  ${B}${_gi}${NC} ${DIM2}›${NC} ${W}${_dn}${NC}  ${DIM2}${_nn} nodes · ${_nsubs} sub(s)${NC}"
        done
        if [ "$_gi" -eq 0 ]; then
            echo -e "  ${DIM2}No groups yet${NC}"
        fi
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "
        read_choice GM_CHOICE
        case "${GM_CHOICE:-}" in
            "") crumb_pop; return ;;
            *)
                case "$GM_CHOICE" in
                    ''|*[!0-9]*) warn "Unknown option: ${GM_CHOICE}"; PAUSE; continue ;;
                esac
                # Resolve index → group id
                _i=0; _sel=""
                for _g in $_gids; do
                    _i=$((_i + 1))
                    [ "$_i" = "$GM_CHOICE" ] && { _sel="$_g"; break; }
                done
                if [ -z "$_sel" ]; then
                    warn "No group at index ${GM_CHOICE}"; PAUSE; continue
                fi
                do_group_view "$_sel"
                ;;
        esac
    done
}

# do_protocol_exclude_screen TYPE ID
#   TYPE: "group" — ID is group_id; toggles update group.exclude_protocols,
#                   rebuilds meta for all subs in the group.
#   TYPE: "sub"   — ID is sub_id;   offers `m` to flip inherit mode, numeric
#                   toggles update sub.exclude_protocols when in custom mode
#                   (or nudges user to flip mode if still inheriting).
do_protocol_exclude_screen() {
    _pe_type="$1"; _pe_id="$2"
    crumb_push "Exclude protocols"

    while true; do
        clear
        crumb_show
        section "Exclude protocols"

        _pe_inherit=""
        _pe_group_excl=""
        if [ "$_pe_type" = "sub" ]; then
            _pe_inherit="$(sub_get "$_pe_id" exclude_inherit 1)"
            _pe_gid="$(sub_get "$_pe_id" group_id)"
            [ -n "$_pe_gid" ] && _pe_group_excl="$(group_get "$_pe_gid" exclude_protocols)"
            if [ "$_pe_inherit" = "1" ]; then
                _pe_effective="$_pe_group_excl"
            else
                _pe_effective="$(sub_get "$_pe_id" exclude_protocols)"
            fi
        else
            _pe_effective="$(group_get "$_pe_id" exclude_protocols)"
        fi

        _pe_max="$(echo "$PROTOCOL_CHOICES" | wc -w | tr -d ' ')"
        _pe_locked=0
        [ "$_pe_type" = "sub" ] && [ "$_pe_inherit" = "1" ] && _pe_locked=1

        # Mode row (sub only)
        if [ "$_pe_type" = "sub" ]; then
            if [ "$_pe_inherit" = "1" ]; then
                echo -e "  ${B}m${NC} ${DIM2}›${NC} ${ICO_OK} ${W}Inherit from Group${NC} ${DIM2}(${_pe_group_excl:-None})${NC}"
            else
                echo -e "  ${B}m${NC} ${DIM2}›${NC} ${ICO_DIS} ${W}Custom Mode${NC} ${DIM2}(subscription-specific)${NC}"
            fi
            echo ""
        fi

        # Protocols list — numbered, [x]/[ ] marker
        _pe_i=0
        for _pe_p in $PROTOCOL_CHOICES; do
            _pe_i=$((_pe_i + 1))
            _pe_mark=" "
            case " $_pe_effective " in
                *" $_pe_p "*) _pe_mark="${ERR}x${NC}" ;;
            esac
            _pe_idx_fmt="$(printf '%2d' "$_pe_i")"
            echo -e "  ${B}${_pe_idx_fmt}${NC} ${DIM2}›${NC} [${_pe_mark}] ${W}${_pe_p}${NC}://"
        done
        echo ""

        echo -e "  ${B}a${NC} ${DIM2}›${NC} ${ERR}Exclude All${NC}"
        echo -e "  ${B}n${NC} ${DIM2}›${NC} ${OK}Include All${NC} ${DIM2}(clear)${NC}"
        echo -e "  ${DIM2}Or type indices to toggle: \"1 3 5-8\"${NC}"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "
        # Raw read to preserve spaces/hyphens for range parsing
        read -r PE_RAW || true
        PE_RAW="$(printf '%s' "${PE_RAW:-}" | tr -d '\001-\037\177')"

        case "$PE_RAW" in
            "") crumb_pop; return ;;
            m|M)
                if [ "$_pe_type" != "sub" ]; then
                    warn "Inherit mode is subscription-specific"; PAUSE; continue
                fi
                if [ "$_pe_inherit" = "1" ]; then
                    # Switch to custom — seed from group's list so the user
                    # doesn't restart from zero
                    if [ -n "$_pe_group_excl" ]; then
                        uci set "mole.${_pe_id}.exclude_protocols=${_pe_group_excl}"
                    fi
                    uci set "mole.${_pe_id}.exclude_inherit=0"
                else
                    uci set "mole.${_pe_id}.exclude_inherit=1"
                fi
                uci commit mole
                rebuild_sub_meta "$_pe_id"
                ;;
            a|A)
                if [ "$_pe_locked" = "1" ]; then
                    [ -n "$_pe_group_excl" ] && uci set "mole.${_pe_id}.exclude_protocols=${_pe_group_excl}"
                    uci set "mole.${_pe_id}.exclude_inherit=0"
                    uci commit mole; rebuild_sub_meta "$_pe_id"
                    _pe_inherit=0; _pe_locked=0
                fi
                if confirm "Exclude all ${_pe_max} protocols?" "n"; then
                    uci set "mole.${_pe_id}.exclude_protocols=${PROTOCOL_CHOICES}"
                    uci commit mole
                    if [ "$_pe_type" = "group" ]; then
                        rebuild_group_metas "$_pe_id"
                    else
                        rebuild_sub_meta "$_pe_id"
                    fi
                    echo -e "  ${ICO_OK} ${OK}All excluded${NC}"; PAUSE
                fi
                ;;
            n|N)
                if [ "$_pe_locked" = "1" ]; then
                    [ -n "$_pe_group_excl" ] && uci set "mole.${_pe_id}.exclude_protocols=${_pe_group_excl}"
                    uci set "mole.${_pe_id}.exclude_inherit=0"
                    uci commit mole; rebuild_sub_meta "$_pe_id"
                    _pe_inherit=0; _pe_locked=0
                fi
                if [ -z "$_pe_effective" ]; then
                    echo -e "  ${DIM2}Already empty${NC}"; PAUSE
                else
                    if confirm "Clear all protocol exclusions?" "n"; then
                        uci -q delete "mole.${_pe_id}.exclude_protocols" 2>/dev/null || true
                        uci commit mole
                        if [ "$_pe_type" = "group" ]; then
                            rebuild_group_metas "$_pe_id"
                        else
                            rebuild_sub_meta "$_pe_id"
                        fi
                        echo -e "  ${ICO_OK} ${OK}Cleared${NC}"; PAUSE
                    fi
                fi
                ;;
            *)
                _pe_idx_list="$(parse_index_list "$PE_RAW" "$_pe_max")"
                if [ -z "$_pe_idx_list" ]; then
                    warn "Unknown option or invalid indices: ${PE_RAW}"; PAUSE; continue
                fi
                if [ "$_pe_locked" = "1" ]; then
                    [ -n "$_pe_group_excl" ] && uci set "mole.${_pe_id}.exclude_protocols=${_pe_group_excl}"
                    uci set "mole.${_pe_id}.exclude_inherit=0"
                    uci commit mole; rebuild_sub_meta "$_pe_id"
                    _pe_inherit=0; _pe_locked=0
                fi
                _pe_toggled=0
                for _pe_idx in $_pe_idx_list; do
                    _pe_seek=0
                    for _pe_p in $PROTOCOL_CHOICES; do
                        _pe_seek=$((_pe_seek + 1))
                        if [ "$_pe_seek" = "$_pe_idx" ]; then
                            toggle_proto_exclude "$_pe_id" "$_pe_p"
                            _pe_toggled=$((_pe_toggled + 1))
                            break
                        fi
                    done
                done
                uci commit mole
                if [ "$_pe_type" = "group" ]; then
                    rebuild_group_metas "$_pe_id"
                else
                    rebuild_sub_meta "$_pe_id"
                fi
                echo -e "  ${ICO_OK} ${OK}Toggled ${_pe_toggled} protocol(s)${NC}"; PAUSE
                ;;
        esac
    done
}

# ─── Podkop Sections screens ─────────────────────────────────────────

do_podkop_sections_menu() {
    crumb_push "Podkop"

    if ! podkop_present; then
        clear
        crumb_show
        section "Podkop Sections"
        echo -e "  ${WARN_C}Podkop is not installed.${NC}"
        echo -e "  ${DIM2}Use main menu › i to install it.${NC}"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "
        read_choice _d
        crumb_pop; return
    fi

    # Auto-jump: exactly one managed section and no unadopted ones — the
    # list view would be a pointless extra keystroke, so dive straight in.
    # Liminal does the same thing for its single-interface case.
    _pmj_managed="$(mole_managed_sections | awk 'NF')"
    _pmj_mgd_count="$(printf '%s\n' "$_pmj_managed" | awk 'NF' | wc -l | tr -d ' ')"
    _pmj_unmgd_count=0
    for _pmj_n in $(podkop_enumerate_sections); do
        [ -z "$(podkop_section_owner "$_pmj_n")" ] && _pmj_unmgd_count=$((_pmj_unmgd_count + 1))
    done
    if [ "$_pmj_mgd_count" = "1" ] && [ "$_pmj_unmgd_count" = "0" ]; then
        _pmj_only="$(printf '%s' "$_pmj_managed" | head -n1)"
        do_podkop_section_view "$_pmj_only"
        crumb_pop; return
    fi

    while true; do
        clear
        crumb_show
        section "Podkop Sections"

        _pm_managed="$(mole_managed_sections)"
        _pm_all="$(podkop_enumerate_sections)"

        _pm_ver="$(pkg_version podkop 2>/dev/null)"
        _pm_run="${ERR}not running${NC}"
        [ -x /etc/init.d/podkop ] && [ -f /var/run/podkop.pid ] 2>/dev/null && _pm_run="${OK}running${NC}"
        pidof sing-box >/dev/null 2>&1 && _pm_run="${OK}running${NC}"

        # Single pass: gather + hash per section, accumulate counts, buffer
        # list lines. Previous version gathered each section twice (once for
        # the status banner, once for the list render) which doubled the cost.
        _pm_list_buf=""
        _pm_managed_n=0
        _pm_dirty=0
        _PM_IDS=""
        _pm_i=0
        _NL="
"
        for _t in $_pm_managed; do
            _pm_i=$((_pm_i + 1))
            _pm_managed_n=$((_pm_managed_n + 1))
            _PM_IDS="${_PM_IDS} m:${_t}"
            _pm_n="$(ps_get "$_t" podkop_name "$_t")"
            _pm_srcs="$(ps_sources "$_t")"
            _pm_src_n="$(printf '%s' "$_pm_srcs" | wc -w | tr -d ' ')"
            _pm_planned_file="${CFG_CACHE_DIR}/pm_planned.${_t}.$$"
            gather_planned_uris "$_t" > "$_pm_planned_file"
            _pm_planned_n="$(wc -l < "$_pm_planned_file" 2>/dev/null | tr -d ' ')"
            case "$_pm_planned_n" in ''|*[!0-9]*) _pm_planned_n=0 ;; esac
            _pm_planned_hash="$(canonical_hash < "$_pm_planned_file")"
            _pm_link_list="$(ps_link_list "$_t")"
            _pm_current_hash="$(podkop_current_uris "$_pm_n" "$_pm_link_list" | canonical_hash)"
            rm -f "$_pm_planned_file"
            if [ "$_pm_planned_hash" != "$_pm_current_hash" ]; then
                _pm_dirty=$((_pm_dirty + 1))
                _pm_ico="${ICO_WARN}"; _pm_status="${WARN_C}Flush Needed${NC}"
            else
                _pm_ico="${ICO_OK}"; _pm_status="${OK}In Sync${NC}"
            fi
            _pm_list_buf="${_pm_list_buf}  ${B}$(printf '%2d' "$_pm_i")${NC} ${DIM2}›${NC} ${_pm_ico} ${W}${_pm_n}${NC}  ${DIM2}${_pm_src_n} src · ${_pm_planned_n} links${NC}  ${_pm_status}${_NL}"
        done

        box_buf_reset
        box_buf_line "  ${A}Podkop${NC}     ${W}${_pm_ver:-unknown}${NC}  ${DIM2}${_pm_run}${NC}"
        box_buf_line "  ${A}Managed${NC}    ${W}${_pm_managed_n}${NC} sections"
        if [ "$_pm_dirty" -gt 0 ]; then
            box_buf_line "  ${A}Status${NC}     ${WARN_C}${_pm_dirty} Need Flush${NC}"
        else
            [ "$_pm_managed_n" -gt 0 ] && box_buf_line "  ${A}Status${NC}     ${OK}In Sync${NC}"
        fi
        box_buf_flush 50 90
        echo ""

        if [ "$_pm_managed_n" -gt 0 ]; then
            echo -e "  ${DIM2}Managed${NC}"
            printf '%b' "$_pm_list_buf"
            echo ""
        fi

        # Unmanaged = in podkop but no _mole_section marker
        _pm_unmanaged=""
        for _n in $_pm_all; do
            _owner="$(podkop_section_owner "$_n")"
            [ -z "$_owner" ] && _pm_unmanaged="${_pm_unmanaged} ${_n}"
        done
        if [ -n "$_pm_unmanaged" ]; then
            echo -e "  ${DIM2}Unmanaged${NC}"
            for _n in $_pm_unmanaged; do
                _pm_i=$((_pm_i + 1))
                _PM_IDS="${_PM_IDS} u:${_n}"
                _pm_t="$(uci -q get "podkop.${_n}.proxy_config_type" 2>/dev/null || echo "?")"
                if [ "$_pm_t" = "selector" ]; then
                    echo -e "  ${B}$(printf '%2d' "$_pm_i")${NC} ${DIM2}›${NC} ${ICO_DIS} ${DIM2}${_n} (selector → will convert to urltest on adopt)${NC}"
                else
                    echo -e "  ${B}$(printf '%2d' "$_pm_i")${NC} ${DIM2}›${NC} ${ICO_DIS} ${DIM2}${_n}  tap to adopt${NC}"
                fi
            done
            echo ""
        fi

        if [ "$_pm_managed_n" = "0" ] && [ -z "$_pm_unmanaged" ]; then
            echo -e "  ${DIM2}No podkop sections exist. Create one in podkop's LuCI,${NC}"
            echo -e "  ${DIM2}then return here to adopt it.${NC}"
            echo ""
        fi
        if [ "$_pm_managed_n" -gt 0 ]; then
            if [ "$_pm_dirty" -gt 0 ]; then
                echo -e "  ${B}f${NC} ${DIM2}›${NC} ${OK}Flush All${NC} ${DIM2}(${_pm_dirty} need flush)${NC}"
            else
                echo -e "  ${DIM2}f › Flush All (all in sync)${NC}"
            fi
            echo ""
        fi
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "
        read_choice PM_CHOICE

        case "${PM_CHOICE:-}" in
            "") crumb_pop; return ;;
            f|F)
                if [ "$_pm_dirty" = "0" ]; then
                    echo -e "  ${DIM2}All managed sections already in sync${NC}"
                    PAUSE
                else
                    echo ""
                    flush_all_auto 0
                    echo ""
                    PAUSE
                fi
                ;;
            *)
                case "$PM_CHOICE" in
                    ''|*[!0-9]*) warn "Unknown option: ${PM_CHOICE}"; PAUSE ;;
                    *)
                        _sel_entry=""
                        _si=0
                        for _e in $_PM_IDS; do
                            _si=$((_si + 1))
                            [ "$_si" = "$PM_CHOICE" ] && { _sel_entry="$_e"; break; }
                        done
                        if [ -z "$_sel_entry" ]; then
                            warn "No entry at index ${PM_CHOICE}"; PAUSE
                            continue
                        fi
                        case "$_sel_entry" in
                            m:*)
                                _sel_tag="${_sel_entry#m:}"
                                do_podkop_section_view "$_sel_tag"
                                ;;
                            u:*)
                                _sel_name="${_sel_entry#u:}"
                                if confirm "Adopt podkop section '${_sel_name}'?" "y"; then
                                    _new_tag="$(adopt_podkop_section "$_sel_name")"
                                    if [ -n "$_new_tag" ]; then
                                        do_podkop_section_view "$_new_tag"
                                    else
                                        warn "Failed to adopt '${_sel_name}'"; PAUSE
                                    fi
                                fi
                                ;;
                        esac
                        ;;
                esac
                ;;
        esac
    done
}

do_podkop_section_view() {
    _psv_tag="$1"
    _psv_title="$(ps_get "$_psv_tag" podkop_name "$_psv_tag")"
    crumb_push "$_psv_title"
    while true; do
        clear
        crumb_show

        if ! uci -q get "mole.${_psv_tag}" >/dev/null 2>&1; then
            warn "Section tag '${_psv_tag}' no longer exists"; PAUSE
            crumb_pop; return
        fi

        _psv_name="$(ps_get "$_psv_tag" podkop_name "$_psv_tag")"
        _psv_srcs="$(ps_sources "$_psv_tag")"
        _psv_last_ts="$(ps_get "$_psv_tag" last_flush_ts 0)"
        _psv_mode="$(ps_get "$_psv_tag" proxy_mode "urltest")"
        case "$_psv_mode" in urltest|selector) ;; *) _psv_mode="urltest" ;; esac
        _psv_link_list="${_psv_mode}_proxy_links"

        # Single gather — reuse for planned count + dirty check
        _psv_planned_file="${CFG_CACHE_DIR}/psv_planned.${_psv_tag}.$$"
        gather_planned_uris "$_psv_tag" > "$_psv_planned_file"
        _psv_planned_n="$(wc -l < "$_psv_planned_file" 2>/dev/null | tr -d ' ')"
        case "$_psv_planned_n" in ''|*[!0-9]*) _psv_planned_n=0 ;; esac
        _psv_planned_hash="$(canonical_hash < "$_psv_planned_file")"
        rm -f "$_psv_planned_file"
        _psv_current_n="$(podkop_current_uris "$_psv_name" "$_psv_link_list" | wc -l | tr -d ' ')"
        case "$_psv_current_n" in ''|*[!0-9]*) _psv_current_n=0 ;; esac
        _psv_current_hash="$(podkop_current_uris "$_psv_name" "$_psv_link_list" | canonical_hash)"
        _psv_dirty=0
        [ "$_psv_planned_hash" != "$_psv_current_hash" ] && _psv_dirty=1

        # Does the podkop section still exist?
        _psv_pod_exists=0
        uci -q get "podkop.${_psv_name}" >/dev/null 2>&1 && _psv_pod_exists=1

        if [ "$_psv_pod_exists" = "0" ]; then
            _psv_hero_ico="${ICO_ERR}"
        elif [ "$_psv_dirty" = "1" ]; then
            _psv_hero_ico="${ICO_WARN}"
        else
            _psv_hero_ico="${ICO_OK}"
        fi

        box_buf_reset
        box_buf_line "  ${_psv_hero_ico} ${W}${_psv_name}${NC} ${DIM2}— ${_psv_mode}${NC}"
        box_buf_sep
        box_buf_line "  ${A}Planned${NC}    ${W}${_psv_planned_n}${NC} links ${DIM2}(after exclusions)${NC}"
        box_buf_line "  ${A}In podkop${NC}  ${W}${_psv_current_n}${NC} links"
        if [ "$_psv_pod_exists" = "0" ]; then
            box_buf_line "  ${A}Status${NC}     ${ERR}podkop section is missing${NC}"
        elif [ "$_psv_dirty" = "1" ]; then
            box_buf_line "  ${A}Status${NC}     ${WARN_C}⚠ Flush Needed${NC}"
        else
            box_buf_line "  ${A}Status${NC}     ${OK}In Sync${NC}"
        fi
        box_buf_line "  ${A}Last flush${NC} ${DIM2}$(fmt_age_since "$_psv_last_ts")${NC}"
        box_buf_flush 50 90
        echo ""

        # Sources list — expanded with per-node ms when /proxies has history.
        # Otherwise collapsed to group-summary rows.
        _psv_src_count="$(printf '%s' "$_psv_srcs" | wc -w | tr -d ' ')"

        _psv_uri_ms_file=""
        _psv_fastest_uri=""
        _psv_active_uri=""
        _psv_has_lat=0
        if [ "$_psv_pod_exists" = "1" ] && [ "$_psv_current_n" -gt 0 ] && [ "$_psv_dirty" = "0" ]; then
            _psv_uri_ms_file="${CFG_CACHE_DIR}/psv_uri_ms.${_psv_tag}.$$"
            build_uri_ms_map "$_psv_tag" > "$_psv_uri_ms_file" 2>/dev/null || true
            # Has at least one non-empty ms?
            if awk -F'\t' 'NF>=2 && $2 != "" && $2 != "null" && $2 ~ /^[0-9]+$/ {found=1} END{exit !found}' "$_psv_uri_ms_file" 2>/dev/null; then
                _psv_has_lat=1
                _psv_fastest_uri="$(awk -F'\t' '
                    NF>=2 && $2 != "" && $2 != "null" && $2 ~ /^[0-9]+$/ {
                        if (min == "" || $2 < min) { min = $2; u = $1 }
                    } END { if (u) print u }
                ' "$_psv_uri_ms_file")"
            fi
            _psv_active_uri="$(get_active_uri "$_psv_tag" 2>/dev/null || true)"
        fi

        if [ "$_psv_has_lat" = "1" ]; then
            _psv_cache_ts="$(stat -c %Y "$(latency_cache_file)" 2>/dev/null || echo 0)"
            _psv_tested_age="$(fmt_age_since "$_psv_cache_ts")"
            if [ "$_psv_tested_age" != "-" ]; then
                echo -e "  ${DIM2}Sources${NC}  ${DIM2}· tested ${_psv_tested_age}${NC}"
            else
                echo -e "  ${DIM2}Sources${NC}"
            fi
        elif [ "$_psv_pod_exists" = "1" ] && [ "$_psv_current_n" -gt 0 ] && [ "$_psv_dirty" = "0" ]; then
            echo -e "  ${DIM2}Sources${NC}  ${DIM2}· probing (auto-test every 3m, or press p)${NC}"
        else
            echo -e "  ${DIM2}Sources${NC}"
        fi

        if [ -z "$_psv_srcs" ]; then
            echo -e "  ${DIM2}(none — add via Source Groups below)${NC}"
        else
            for _g in $_psv_srcs; do
                group_exists "$_g" || { echo -e "  ${DIM2}·${NC} ${ERR}${_g}${NC} ${DIM2}(missing)${NC}"; continue; }
                _dn="$(group_get "$_g" display_name)"
                [ -z "$_dn" ] && _dn="$_g"

                if [ "$_psv_has_lat" = "1" ]; then
                    echo -e "  ${DIM2}·${NC} ${W}${_dn}${NC}"
                    _grp_tmp="${CFG_CACHE_DIR}/grp_sort.${_g}.$$"
                    _grp_tab="$(printf '\t')"
                    : > "$_grp_tmp"
                    for _s in $(subs_in_group "$_g"); do
                        _en="$(sub_get "$_s" enabled 1)"
                        [ "$_en" = "0" ] && continue
                        _meta="$(sub_meta_file "$_s")"
                        _uris="$(sub_pool_file "$_s")"
                        [ -f "$_meta" ] && [ -f "$_uris" ] || continue
                        _sub_excl_p="$(compute_effective_excludes "$_s")"
                        _sub_excl_l="$(sub_link_excludes "$_s")"
                        exec 3< "$_uris"
                        exec 4< "$_meta"
                        while IFS= read -r _uri_row <&3 \
                              && IFS="$META_FS" read -r _m_lid _m_proto _m_host _m_port _m_ip _m_asn _m_cc _m_flag _m_ping _m_name <&4; do
                            [ -z "$_uri_row" ] && continue
                            case "$_m_proto" in
                                ss|vless|trojan|socks4|socks4a|socks5|hysteria2|hy2) ;;
                                *) continue ;;
                            esac
                            if [ -n "$_sub_excl_p" ]; then
                                case " $_sub_excl_p " in *" $_m_proto "*) continue ;; esac
                            fi
                            if [ -n "$_sub_excl_l" ]; then
                                case " $_sub_excl_l " in *" $_m_lid "*) continue ;; esac
                            fi
                            [ -z "$_m_name" ] && _m_name="(unnamed)"
                            _ms="$(awk -F'\t' -v u="$_uri_row" '$1==u {print $2; exit}' "$_psv_uri_ms_file" 2>/dev/null)"
                            _is_active=0; _is_fastest=0
                            [ -n "$_psv_active_uri" ]  && [ "$_uri_row" = "$_psv_active_uri" ]  && _is_active=1
                            [ -n "$_psv_fastest_uri" ] && [ "$_uri_row" = "$_psv_fastest_uri" ] && _is_fastest=1
                            if [ -n "$_ms" ] && [ "$_ms" != "null" ]; then
                                if   [ "$_is_active"  = "1" ]; then _prio=0
                                elif [ "$_is_fastest" = "1" ]; then _prio=1
                                else _prio=2
                                fi
                                printf '%d%s%d%s%d%s%d%s%s\n' \
                                    "$_prio" "$_grp_tab" "$_ms" "$_grp_tab" \
                                    "$_is_active" "$_grp_tab" "$_is_fastest" "$_grp_tab" \
                                    "$_m_name" >> "$_grp_tmp"
                            else
                                printf '3%s999999%s0%s0%s%s\n' \
                                    "$_grp_tab" "$_grp_tab" "$_grp_tab" "$_grp_tab" \
                                    "$_m_name" >> "$_grp_tmp"
                            fi
                        done
                        exec 3<&-
                        exec 4<&-
                    done
                    sort -t"$_grp_tab" -k1,1n -k2,2n "$_grp_tmp" 2>/dev/null | \
                    while IFS="$_grp_tab" read -r _sr_prio _sr_ms _sr_act _sr_fast _sr_name; do
                        if [ "$_sr_prio" = "3" ]; then
                            echo -e "      ${DIM2}·${NC} ${DIM2}${_sr_name}  N/A${NC}"
                        else
                            _row_lbl=""
                            [ "$_sr_act"  = "1" ] && _row_lbl="${_row_lbl}  ${B}● Active${NC}"
                            [ "$_sr_fast" = "1" ] && _row_lbl="${_row_lbl}  ${V}★ Fastest${NC}"
                            echo -e "      ${DIM2}·${NC} ${W}${_sr_name}${NC}  ${OK}${_sr_ms}ms${NC}${_row_lbl}"
                        fi
                    done
                    rm -f "$_grp_tmp"
                else
                    _g_links=0
                    for _s in $(subs_in_group "$_g"); do
                        _en="$(sub_get "$_s" enabled 1)"
                        [ "$_en" = "0" ] && continue
                        _c="$(sub_get "$_s" last_count 0)"
                        case "$_c" in ''|*[!0-9]*) _c=0 ;; esac
                        _g_links=$((_g_links + _c))
                    done
                    echo -e "  ${DIM2}·${NC} ${W}${_dn}${NC}  ${DIM2}${_g_links} links${NC}"
                fi
            done
        fi
        echo ""

        # Clean up per-render temp
        [ -n "$_psv_uri_ms_file" ] && rm -f "$_psv_uri_ms_file"

        echo -e "  ${DIM2}Configuration${NC}"
        echo -e "  ${B}m${NC} ${DIM2}›${NC} ${W}Mode${NC} ${DIM2}(${_psv_mode})${NC}"
        echo -e "  ${B}s${NC} ${DIM2}›${NC} ${W}Source Groups${NC}"
        [ "$_psv_mode" = "urltest" ] && echo -e "  ${B}t${NC} ${DIM2}›${NC} ${W}URLTest Settings${NC}"
        echo ""
        echo -e "  ${DIM2}Podkop${NC}"
        if [ "$_psv_dirty" = "1" ]; then
            echo -e "  ${B}f${NC} ${DIM2}›${NC} ${OK}Flush to Podkop${NC}  ${DIM2}(${_psv_planned_n} links)${NC}"
        else
            echo -e "  ${DIM2}f › Flush to Podkop (in sync)${NC}"
        fi
        if [ "$_psv_pod_exists" = "1" ] && [ "$_psv_current_n" -gt 0 ] && [ "$_psv_dirty" = "0" ]; then
            echo -e "  ${B}p${NC} ${DIM2}›${NC} ${W}Test Latency${NC}"
        else
            echo -e "  ${DIM2}p › Test Latency (flush first)${NC}"
        fi
        echo -e "  ${B}u${NC} ${DIM2}›${NC} ${ERR}Unadopt Section${NC}"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "
        read_choice PSV_CHOICE

        case "${PSV_CHOICE:-}" in
            m|M)
                if [ "$_psv_mode" = "urltest" ]; then
                    uci set "mole.${_psv_tag}.proxy_mode=selector"
                    echo -e "  ${ICO_OK} ${OK}Switched to Selector mode${NC} ${DIM2}(manual pick via Clash dashboard)${NC}"
                else
                    uci set "mole.${_psv_tag}.proxy_mode=urltest"
                    echo -e "  ${ICO_OK} ${OK}Switched to URLTest mode${NC} ${DIM2}(auto latency selection)${NC}"
                fi
                uci commit mole
                PAUSE
                ;;
            s|S) do_podkop_source_groups "$_psv_tag" ;;
            t|T) [ "$_psv_mode" = "urltest" ] && do_podkop_urltest_settings "$_psv_tag" ;;
            f|F)
                if [ "$_psv_dirty" = "0" ]; then
                    echo -e "  ${DIM2}Already in sync${NC}"; PAUSE; continue
                fi
                printf "  %bFlushing%b ... " "$W" "$NC"
                if podkop_flush "$_psv_tag"; then
                    podkop_restart
                    _n="$(ps_get "$_psv_tag" last_flush_count 0)"
                    echo -e "${ICO_OK} ${DIM2}${_n} links${NC}"
                else
                    echo -e "${DIM2}no-op${NC}"
                fi
                PAUSE
                ;;
            p|P)
                if [ "$_psv_dirty" = "1" ]; then
                    warn "Section is out of sync — flush first so tags match URIs"
                    PAUSE; continue
                fi
                if [ "$_psv_current_n" = "0" ]; then
                    warn "No URIs in podkop section yet"; PAUSE; continue
                fi
                if ! have_cmd jq; then
                    warn "jq required for latency parsing"; PAUSE; continue
                fi
                printf "  %bRunning latency probe%b ... " "$W" "$NC"
                if trigger_latency_test "$_psv_tag"; then
                    echo -e "${ICO_OK}"
                    echo -e "  ${DIM2}Fresh results will render on refresh${NC}"
                else
                    echo -e "${ICO_ERR}"
                    warn "Probe failed — is podkop running and jq installed?"
                fi
                PAUSE
                ;;
            u|U)
                if confirm "Unadopt '${_psv_name}'? (podkop state untouched)" "n"; then
                    unadopt_podkop_section "$_psv_tag"
                    echo -e "  ${ICO_OK} ${OK}Unadopted${NC}"
                    PAUSE
                    crumb_pop; return
                fi
                ;;
            "") crumb_pop; return ;;
            *) warn "Unknown option: ${PSV_CHOICE}"; PAUSE ;;
        esac
    done
}

do_podkop_urltest_settings() {
    _uts_tag="$1"
    _uts_name="$(ps_get "$_uts_tag" podkop_name "$_uts_tag")"
    crumb_push "URLTest"

    while true; do
        clear
        crumb_show
        section "URLTest Settings"

        _uts_interval="$(uci -q get "podkop.${_uts_name}.urltest_check_interval" 2>/dev/null || true)"
        _uts_tolerance="$(uci -q get "podkop.${_uts_name}.urltest_tolerance" 2>/dev/null || true)"
        _uts_url="$(uci -q get "podkop.${_uts_name}.urltest_testing_url" 2>/dev/null || true)"
        [ -z "$_uts_interval" ] && _uts_interval="3m"
        [ -z "$_uts_tolerance" ] && _uts_tolerance="50"
        [ -z "$_uts_url" ] && _uts_url="https://www.gstatic.com/generate_204"

        box_buf_reset
        box_buf_line "  ${A}Check Interval${NC}  ${W}${_uts_interval}${NC}"
        box_buf_line "  ${A}Tolerance${NC}       ${W}${_uts_tolerance} ms${NC}"
        box_buf_line "  ${A}Testing URL${NC}     ${DIM2}${_uts_url}${NC}"
        box_buf_flush 50 90
        echo ""

        echo -e "  ${B}i${NC} ${DIM2}›${NC} ${W}Check Interval${NC} ${DIM2}(e.g. 3m, 30s)${NC}"
        echo -e "  ${B}t${NC} ${DIM2}›${NC} ${W}Tolerance${NC} ${DIM2}(ms)${NC}"
        echo -e "  ${B}u${NC} ${DIM2}›${NC} ${W}Testing URL${NC}"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "
        read_choice UTS_CHOICE

        case "${UTS_CHOICE:-}" in
            i|I)
                prompt _uts_new "Check Interval" "$_uts_interval" || { cancelled; continue; }
                is_cancelled && { cancelled; continue; }
                [ -z "${_uts_new:-}" ] && continue
                uci set "podkop.${_uts_name}.urltest_check_interval=${_uts_new}"
                uci commit podkop
                echo -e "  ${ICO_OK} ${OK}Saved${NC}"
                PAUSE
                ;;
            t|T)
                prompt _uts_new "Tolerance (ms)" "$_uts_tolerance" || { cancelled; continue; }
                is_cancelled && { cancelled; continue; }
                [ -z "${_uts_new:-}" ] && continue
                case "$_uts_new" in ''|*[!0-9]*) warn "Must be a whole number"; PAUSE; continue ;; esac
                uci set "podkop.${_uts_name}.urltest_tolerance=${_uts_new}"
                uci commit podkop
                echo -e "  ${ICO_OK} ${OK}Saved${NC}"
                PAUSE
                ;;
            u|U)
                prompt _uts_new "Testing URL" "$_uts_url" || { cancelled; continue; }
                is_cancelled && { cancelled; continue; }
                [ -z "${_uts_new:-}" ] && continue
                case "$_uts_new" in
                    http://*|https://*) ;;
                    *) warn "Must start with http:// or https://"; PAUSE; continue ;;
                esac
                uci set "podkop.${_uts_name}.urltest_testing_url=$(sanitize_uci_val "${_uts_new}")"
                uci commit podkop
                echo -e "  ${ICO_OK} ${OK}Saved${NC}"
                PAUSE
                ;;
            "") crumb_pop; return ;;
            *) warn "Unknown option: ${UTS_CHOICE}"; PAUSE ;;
        esac
    done
}

do_podkop_source_groups() {
    _psg_tag="$1"
    crumb_push "Sources"

    while true; do
        clear
        crumb_show
        section "Source Groups"

        _psg_cur="$(ps_sources "$_psg_tag")"
        _psg_all_groups=""
        for _g in $(iterate_group_names); do
            # Only show groups that have at least one sub
            _nsubs="$(subs_in_group "$_g" | awk 'NF' | wc -l | tr -d ' ')"
            [ "$_nsubs" = "0" ] && continue
            _psg_all_groups="${_psg_all_groups}${_psg_all_groups:+ }${_g}"
        done

        if [ -z "$_psg_all_groups" ]; then
            echo -e "  ${DIM2}No groups exist yet${NC}"
            echo ""
            echo -e "  ${DIM2}Enter › Back${NC}"
            echo ""
            echo -ne "  ${A}>${NC} "
            read_choice _d
            crumb_pop; return
        fi

        _psg_i=0
        for _g in $_psg_all_groups; do
            _psg_i=$((_psg_i + 1))
            _dn="$(group_get "$_g" display_name)"
            [ -z "$_dn" ] && _dn="$_g"
            _nsubs="$(subs_in_group "$_g" | awk 'NF' | wc -l | tr -d ' ')"
            _psg_mark=" "
            case " $_psg_cur " in
                *" $_g "*) _psg_mark="${OK}x${NC}" ;;
            esac
            _idx_fmt="$(printf '%2d' "$_psg_i")"
            echo -e "  ${B}${_idx_fmt}${NC} ${DIM2}›${NC} [${_psg_mark}] ${W}${_dn}${NC}  ${DIM2}${_nsubs} sub(s)${NC}"
        done
        echo ""

        echo -e "  ${B}a${NC} ${DIM2}›${NC} ${OK}Include All${NC}"
        echo -e "  ${B}n${NC} ${DIM2}›${NC} ${ERR}Include None${NC}"
        echo -e "  ${DIM2}Or type indices to toggle: \"1 3 5-8\"${NC}"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "
        read -r PSG_RAW || true
        PSG_RAW="$(printf '%s' "${PSG_RAW:-}" | tr -d '\001-\037\177')"

        _psg_max="$_psg_i"

        case "$PSG_RAW" in
            "") crumb_pop; return ;;
            a|A)
                uci set "mole.${_psg_tag}.source_group=${_psg_all_groups}"
                uci commit mole
                echo -e "  ${ICO_OK} ${OK}All groups added${NC}"; PAUSE
                ;;
            n|N)
                uci -q delete "mole.${_psg_tag}.source_group" 2>/dev/null || true
                uci commit mole
                echo -e "  ${ICO_OK} ${OK}Cleared${NC}"; PAUSE
                ;;
            *)
                _psg_idx_list="$(parse_index_list "$PSG_RAW" "$_psg_max")"
                if [ -z "$_psg_idx_list" ]; then
                    warn "Unknown option or invalid indices: ${PSG_RAW}"; PAUSE; continue
                fi
                for _idx in $_psg_idx_list; do
                    _seek=0
                    for _g in $_psg_all_groups; do
                        _seek=$((_seek + 1))
                        if [ "$_seek" = "$_idx" ]; then
                            # Toggle group membership
                            _psg_new=""; _found=0
                            for _cg in $_psg_cur; do
                                if [ "$_cg" = "$_g" ]; then _found=1; continue; fi
                                _psg_new="${_psg_new}${_psg_new:+ }${_cg}"
                            done
                            [ "$_found" = "0" ] && _psg_new="${_psg_new}${_psg_new:+ }${_g}"
                            if [ -z "$_psg_new" ]; then
                                uci -q delete "mole.${_psg_tag}.source_group" 2>/dev/null || true
                            else
                                uci set "mole.${_psg_tag}.source_group=${_psg_new}"
                            fi
                            _psg_cur="$_psg_new"
                            break
                        fi
                    done
                done
                uci commit mole
                ;;
        esac
    done
}

do_group_settings() {
    _gs_id="$1"
    [ -z "$_gs_id" ] && { warn "No group id"; PAUSE; return; }
    if ! group_exists "$_gs_id"; then
        warn "Group '${_gs_id}' not found"; PAUSE; return
    fi
    crumb_push "Settings"
    while true; do
        clear
        crumb_show
        section "Group settings"

        _gs_name="$(group_get "$_gs_id" display_name)"
        [ -z "$_gs_name" ] && _gs_name="$_gs_id"
        _gs_manual="$(group_get "$_gs_id" manual 0)"
        _gs_count="$(subs_in_group "$_gs_id" | awk 'NF' | wc -l | tr -d ' ')"
        _gs_on=0; _gs_off=0
        for _s in $(subs_in_group "$_gs_id"); do
            _en="$(sub_get "$_s" enabled 1)"
            [ "$_en" = "0" ] && _gs_off=$((_gs_off + 1)) || _gs_on=$((_gs_on + 1))
        done

        box_buf_reset
        box_buf_line "  ${A}Group${NC}     ${W}${_gs_name}${NC}"
        box_buf_line "  ${A}Id${NC}        ${DIM2}${_gs_id}${NC}"
        if [ "$_gs_manual" = "1" ]; then
            box_buf_line "  ${A}Name${NC}      ${DIM2}custom override${NC}"
        else
            box_buf_line "  ${A}Name${NC}      ${DIM2}auto (from profile-title)${NC}"
        fi
        box_buf_line "  ${A}Members${NC}   ${W}${_gs_count}${NC}  ${DIM2}(${_gs_on} On · ${_gs_off} Off)${NC}"
        box_buf_flush 50 88
        echo ""

        _gs_excl="$(group_get "$_gs_id" exclude_protocols)"
        if [ -n "$_gs_excl" ]; then
            _gs_excl_label="${DIM2}Custom${NC}"
        else
            _gs_excl_label="${DIM2}None${NC}"
        fi

        echo -e "  ${DIM2}Configuration${NC}"
        echo -e "  ${B}n${NC} ${DIM2}›${NC} ${W}Rename${NC} Group"
        echo -e "  ${B}x${NC} ${DIM2}›${NC} ${W}Exclude Protocols${NC} ${DIM2}[${NC}${_gs_excl_label}${DIM2}]${NC}"
        echo ""
        echo -e "  ${DIM2}Bulk${NC}"
        echo -e "  ${B}e${NC} ${DIM2}›${NC} ${OK}Enable${NC} All Subscriptions"
        echo -e "  ${B}d${NC} ${DIM2}›${NC} ${ERR}Disable${NC} All Subscriptions"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "
        read_choice GS_CHOICE

        case "${GS_CHOICE:-}" in
            n|N)
                echo -e "  ${DIM2}Current: ${_gs_name}${NC}"
                prompt NEW "New name (empty to reset to auto)" || continue
                if [ -n "${NEW:-}" ]; then
                    uci set "mole.${_gs_id}.display_name=${NEW}"
                    uci set "mole.${_gs_id}.manual=1"
                    uci commit mole
                    echo -e "  ${ICO_OK} ${OK}Renamed${NC}"
                    PAUSE
                else
                    uci set "mole.${_gs_id}.manual=0"
                    _first_sub="$(subs_in_group "$_gs_id" | awk 'NF' | head -n1)"
                    if [ -n "$_first_sub" ]; then
                        _pt="$(sub_get "$_first_sub" profile_title)"
                        [ -n "$_pt" ] && uci set "mole.${_gs_id}.display_name=${_pt}"
                    fi
                    uci commit mole
                    echo -e "  ${ICO_OK} ${OK}Reset to auto${NC}"
                    PAUSE
                fi
                ;;
            x|X) do_protocol_exclude_screen "group" "$_gs_id" ;;
            e|E)
                for _s in $(subs_in_group "$_gs_id"); do
                    uci set "mole.${_s}.enabled=1"
                done
                uci commit mole
                echo -e "  ${ICO_OK} ${OK}All enabled${NC} ${DIM2}(${_gs_count} subs)${NC}"
                PAUSE
                ;;
            d|D)
                if confirm "Disable all ${_gs_count} subscriptions in this group?" "n"; then
                    for _s in $(subs_in_group "$_gs_id"); do
                        uci set "mole.${_s}.enabled=0"
                    done
                    uci commit mole
                    echo -e "  ${ICO_OK} ${OK}All disabled${NC}"
                    PAUSE
                fi
                ;;
            "") crumb_pop; return ;;
            *) warn "Unknown option: ${GS_CHOICE}"; PAUSE ;;
        esac
    done
}

do_group_view() {
    _gv_id="$1"
    _gv_title="$(group_get "$_gv_id" display_name)"
    [ -z "$_gv_title" ] && _gv_title="$_gv_id"
    crumb_push "$_gv_title"
    clear
    crumb_show

    _gv_subs="$(subs_in_group "$_gv_id")"
    _gv_dn="$(group_get "$_gv_id" display_name)"
    [ -z "$_gv_dn" ] && _gv_dn="$_gv_id"

    box_buf_reset
    box_buf_line "  ${A}Name${NC}      ${W}${_gv_dn}${NC}"
    box_buf_line "  ${A}Id${NC}        ${DIM2}${_gv_id}${NC}"
    box_buf_line "  ${A}Source${NC}    ${DIM2}auto (from profile-title)${NC}"
    box_buf_flush 50 88
    echo ""

    echo -e "  ${DIM2}Subscriptions${NC}"
    _gvi=0
    for _s in $_gv_subs; do
        _gvi=$((_gvi + 1))
        _custom="$(sub_get "$_s" custom_name)"
        _pt="$(sub_get "$_s" profile_title)"
        if [ -n "$_custom" ]; then
            _label="$_custom"
        elif [ -n "$_pt" ]; then
            _label="$_pt"
        else
            _label="$(sub_get "$_s" url)"
        fi
        _c="$(sub_get "$_s" last_count 0)"
        case "$_c" in ''|*[!0-9]*) _c=0 ;; esac
        _en="$(sub_get "$_s" enabled 1)"
        _ico="${ICO_OK}"; [ "$_en" = "0" ] && _ico="${ICO_DIS}"
        echo -e "  ${B}${_gvi}${NC} ${DIM2}›${NC} ${_ico} ${W}${_label}${NC}  ${DIM2}${_c} links${NC}"
    done
    [ "$_gvi" -eq 0 ] && echo -e "  ${DIM2}(empty)${NC}"
    echo ""

    echo -e "  ${B}s${NC} ${DIM2}›${NC} ${W}Settings${NC}"
    echo ""
    echo -e "  ${DIM2}Grouping is automatic (by profile-title).${NC}"
    echo -e "  ${DIM2}Per-sub rename: use ${NC}${W}m${NC} ${DIM2}in subscription view.${NC}"
    echo ""
    echo -e "  ${DIM2}Enter › Back${NC}"
    echo ""
    echo -ne "  ${A}>${NC} "
    read_choice GV_CHOICE
    case "${GV_CHOICE:-}" in
        s|S) do_group_settings "$_gv_id" ;;
    esac
    crumb_pop
}
do_refresh_all() {
    crumb_push "Refresh"
    clear
    crumb_show
    section "Refresh all subscriptions"
    refresh_all 0 || true
    if podkop_present && mole_any_dirty; then
        echo ""
        echo -e "  ${DIM2}Sections needing flush:${NC}"
        _dra_ntab="$(printf '	')"
        for _dra_tag in $(mole_managed_sections); do
            podkop_needs_flush "$_dra_tag" || continue
            _dra_name="$(ps_get "$_dra_tag" podkop_name "$_dra_tag")"
            _dra_list="$(ps_link_list "$_dra_tag")"
            _dra_srcs="$(ps_sources "$_dra_tag")"
            _dra_grp_labels=""
            for _dra_g in $_dra_srcs; do
                _dra_gl="$(group_get "$_dra_g" display_name)"
                [ -z "$_dra_gl" ] && _dra_gl="$_dra_g"
                _dra_grp_labels="${_dra_grp_labels:+${_dra_grp_labels}, }${_dra_gl}"
            done
            # Build key→uri files for diffing
            _dra_pf="${CFG_CACHE_DIR}/dra_p.${$}.${_dra_tag}"
            _dra_cf="${CFG_CACHE_DIR}/dra_c.${$}.${_dra_tag}"
            _dra_pk="${CFG_CACHE_DIR}/dra_pk.${$}.${_dra_tag}"
            _dra_ck="${CFG_CACHE_DIR}/dra_ck.${$}.${_dra_tag}"
            gather_planned_uris "$_dra_tag" > "$_dra_pf"
            podkop_current_uris "$_dra_name" "$_dra_list" > "$_dra_cf"
            _dra_planned="$(wc -l < "$_dra_pf" | tr -d ' ')"; case "$_dra_planned" in ''|*[!0-9]*) _dra_planned=0 ;; esac
            _dra_current="$(wc -l < "$_dra_cf" | tr -d ' ')"; case "$_dra_current" in ''|*[!0-9]*) _dra_current=0 ;; esac
            awk '{k=$0; sub(/[?#].*/,"",k); print k "	" $0}' "$_dra_pf" | sort > "$_dra_pk"
            awk '{k=$0; sub(/[?#].*/,"",k); print k "	" $0}' "$_dra_cf" | sort > "$_dra_ck"
            _dra_delta=$((_dra_planned - _dra_current))
            if [ "$_dra_delta" -gt 0 ]; then
                _dra_cnt="${_dra_current}→${_dra_planned} (+${_dra_delta})"
            elif [ "$_dra_delta" -lt 0 ]; then
                _dra_cnt="${_dra_current}→${_dra_planned} (${_dra_delta})"
            else
                _dra_cnt="${_dra_planned} nodes"
            fi
            echo -e "  ${W}${_dra_name}${NC} ${DIM2}← ${_dra_grp_labels}  ${_dra_cnt}${NC}"
            # Diff: added (+) then removed (-)
            awk -F'	' '
                NR==FNR { plan[$1]=$2; next }
                { cur[$1]=$2 }
                END {
                    n=0
                    for (k in plan) if (!(k in cur)) {
                        n++; if (n<=8) print "+	" plan[k]
                    }
                    if (n>8) print "+more	" (n-8)
                    n=0
                    for (k in cur) if (!(k in plan)) {
                        n++; if (n<=8) print "-	" cur[k]
                    }
                    if (n>8) print "-more	" (n-8)
                }
            ' "$_dra_pk" "$_dra_ck" | while IFS="$_dra_ntab" read -r _ds _du; do
                case "$_ds" in
                    +) _dn="$(uri_display_name "$_du")"; [ -z "$_dn" ] && _dn="(unnamed)"
                       echo -e "    ${OK}+${NC} ${DIM2}${_dn}${NC}" ;;
                    -) _dn="$(uri_display_name "$_du")"; [ -z "$_dn" ] && _dn="(unnamed)"
                       echo -e "    ${ERR}-${NC} ${DIM2}${_dn}${NC}" ;;
                    +more) echo -e "    ${DIM2}  ... and ${_du} more added${NC}" ;;
                    -more) echo -e "    ${DIM2}  ... and ${_du} more removed${NC}" ;;
                esac
            done
            rm -f "$_dra_pf" "$_dra_cf" "$_dra_pk" "$_dra_ck"
        done
        echo ""
        if confirm "Flush to podkop?" "n"; then
            echo ""
            echo -e "  ${DIM2}Podkop${NC}"
            flush_all_auto 0
        fi
    fi
    echo ""
    PAUSE
    crumb_pop
}
do_link_pool_global() {
    crumb_push "Link pool"
    while true; do
        clear
        crumb_show
        section "Link pool (all subscriptions)"

        _total=0
        # Sum node counts (filtered — excluded protocols don't contribute)
        for _s in $(iterate_sub_names); do
            _meta="$(sub_meta_file "$_s")"
            [ -f "$_meta" ] || continue
            _n="$(compute_filtered_count "$_s")"
            case "$_n" in ''|*[!0-9]*) _n=0 ;; esac
            _total=$((_total + _n))
        done

        if [ "$_total" -eq 0 ]; then
            echo -e "  ${DIM2}No pooled nodes yet — refresh a subscription first${NC}"
            echo ""
            echo -e "  ${DIM2}Enter › Back${NC}"
            echo ""
            echo -ne "  ${A}>${NC} "
            read_choice LP_CHOICE
            case "${LP_CHOICE:-}" in
                "") crumb_pop; return ;;
                *) continue ;;
            esac
        fi

        # Header — fixed-width left-side (# / Proto) aligned by bytes; right
        # side (Node · Subscription) flows since emoji/Cyrillic break byte
        # padding.
        printf "  %b%3s  %-6s  %s%b\n" \
            "$DIM2" "#" "Proto" "Node · Subscription" "$NC"

        _gi=0
        for _s in $(iterate_sub_names); do
            _meta="$(sub_meta_file "$_s")"
            [ -f "$_meta" ] && [ -s "$_meta" ] || continue
            _sub_title="$(sub_get "$_s" profile_title)"
            [ -z "$_sub_title" ] && _sub_title="$_s"
            _lp_excl_p="$(compute_effective_excludes "$_s")"
            _lp_excl_l="$(sub_link_excludes "$_s")"
            while IFS="$META_FS" read -r _lid _proto _host _port _ip _asn _cc _flag _ping _name; do
                [ -z "$_lid" ] && continue
                if [ -n "$_lp_excl_p" ]; then
                    case " $_lp_excl_p " in
                        *" $_proto "*) continue ;;
                    esac
                fi
                if [ -n "$_lp_excl_l" ]; then
                    case " $_lp_excl_l " in
                        *" $_lid "*) continue ;;
                    esac
                fi
                _gi=$((_gi + 1))
                [ -z "$_name" ] && _name="(unnamed)"
                _name_short="$(printf '%s' "$_name" | cut -c1-44)"
                printf "  %b%3d%b  %b%-6s%b  %s  %b·%b  %b%s%b\n" \
                    "$B" "$_gi" "$NC" \
                    "$DIM2" "$_proto" "$NC" \
                    "$_name_short" \
                    "$DIM2" "$NC" \
                    "$DIM2" "$_sub_title" "$NC"
            done < "$_meta"
        done

        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "
        read_choice LP_CHOICE
        case "${LP_CHOICE:-}" in
            "")  crumb_pop; return ;;
            *)   warn "Unknown option: ${LP_CHOICE}"; PAUSE ;;
        esac
    done
}
# parse_duration TOKEN — "7d" / "12h" / "30m" / "3600s" / "3600" → seconds
# Returns empty string on invalid input.
parse_duration() {
    _pd="${1:-}"
    case "$_pd" in
        '') echo ""; return ;;
        *[!0-9dhms]*) echo ""; return ;;
    esac
    case "$_pd" in
        *d) _n="${_pd%d}"; case "$_n" in ''|*[!0-9]*) echo ""; return ;; esac; echo $((_n * 86400)) ;;
        *h) _n="${_pd%h}"; case "$_n" in ''|*[!0-9]*) echo ""; return ;; esac; echo $((_n * 3600)) ;;
        *m) _n="${_pd%m}"; case "$_n" in ''|*[!0-9]*) echo ""; return ;; esac; echo $((_n * 60)) ;;
        *s) _n="${_pd%s}"; case "$_n" in ''|*[!0-9]*) echo ""; return ;; esac; echo "$_n" ;;
        *) echo "$_pd" ;;
    esac
}

# fmt_duration_long SECONDS — "7 days" / "12 hours" / "30 minutes" / "45s"
fmt_duration_long() {
    _fd="${1:-0}"
    case "$_fd" in ''|*[!0-9]*) _fd=0 ;; esac
    if [ "$_fd" -ge 86400 ] && [ $((_fd % 86400)) -eq 0 ]; then
        _n=$((_fd / 86400))
        [ "$_n" = "1" ] && echo "${_n} day" || echo "${_n} days"
    elif [ "$_fd" -ge 3600 ] && [ $((_fd % 3600)) -eq 0 ]; then
        _n=$((_fd / 3600))
        [ "$_n" = "1" ] && echo "${_n} hour" || echo "${_n} hours"
    elif [ "$_fd" -ge 60 ] && [ $((_fd % 60)) -eq 0 ]; then
        _n=$((_fd / 60))
        [ "$_n" = "1" ] && echo "${_n} minute" || echo "${_n} minutes"
    else
        echo "${_fd}s"
    fi
}

do_settings() {
    crumb_push "Settings"
    while true; do
        clear
        crumb_show
        section "Settings"

        _st_ua="$CFG_USER_AGENT"
        _st_ct="$CFG_CONNECT_TIMEOUT"
        _st_dt="$CFG_DOWNLOAD_TIMEOUT"
        _st_log="$CFG_LOG_PATH"

        box_buf_reset
        box_buf_line "  ${A}User-Agent${NC}        ${W}${_st_ua}${NC}"
        box_buf_line "  ${A}Connect timeout${NC}   ${W}${_st_ct}s${NC}"
        box_buf_line "  ${A}Download timeout${NC}  ${W}${_st_dt}s${NC}"
        box_buf_sep
        box_buf_line "  ${A}Log path${NC}          ${DIM2}${_st_log}${NC}"
        box_buf_flush 50 88
        echo ""

        echo -e "  ${DIM2}Fetch${NC}"
        echo -e "  ${B}1${NC} ${DIM2}›${NC} ${W}Edit User-Agent${NC}"
        echo -e "  ${B}2${NC} ${DIM2}›${NC} ${W}Edit Connect Timeout${NC}"
        echo -e "  ${B}3${NC} ${DIM2}›${NC} ${W}Edit Download Timeout${NC}"
        echo ""
        echo -e "  ${DIM2}Log${NC}"
        echo -e "  ${B}8${NC} ${DIM2}›${NC} ${W}Edit Log Path${NC}"
        echo ""
        echo -e "  ${B}r${NC} ${DIM2}›${NC} ${ERR}Reset to Defaults${NC}"
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "
        read_choice ST_CHOICE

        case "${ST_CHOICE:-}" in
            1)
                prompt NEW "User-Agent" "$_st_ua" || continue
                if [ -n "${NEW:-}" ]; then
                    uci set mole.settings.user_agent="$(sanitize_uci_val "${NEW}")"
                    uci commit mole
                    mole_config_load
                fi
                ;;
            2)
                prompt NEW "Connect timeout (seconds)" "$_st_ct" || continue
                case "${NEW:-}" in ''|*[!0-9]*) warn "Must be integer seconds"; PAUSE; continue ;; esac
                [ "$NEW" -lt 1 ] && { warn "Must be ≥ 1"; PAUSE; continue; }
                uci set mole.settings.connect_timeout="$NEW"
                uci commit mole
                mole_config_load
                ;;
            3)
                prompt NEW "Download timeout (seconds)" "$_st_dt" || continue
                case "${NEW:-}" in ''|*[!0-9]*) warn "Must be integer seconds"; PAUSE; continue ;; esac
                [ "$NEW" -lt 1 ] && { warn "Must be ≥ 1"; PAUSE; continue; }
                uci set mole.settings.download_timeout="$NEW"
                uci commit mole
                mole_config_load
                ;;
            8)
                prompt NEW "Log path" "$_st_log" || continue
                [ -z "${NEW:-}" ] && continue
                case "$NEW" in
                    /*) ;;
                    *) warn "Must be absolute path"; PAUSE; continue ;;
                esac
                uci set mole.settings.log_path="$NEW"
                uci commit mole
                mole_config_load
                ;;
            r|R)
                if confirm "Reset all settings to defaults?" "n"; then
                    uci set mole.settings.user_agent='v2raytun/ios'
                    uci set mole.settings.connect_timeout='10'
                    uci set mole.settings.download_timeout='40'
                    uci set mole.settings.log_path='/tmp/mole.log'
                    uci commit mole
                    mole_config_load
                    echo -e "  ${ICO_OK} ${OK}Settings reset${NC}"
                    PAUSE
                fi
                ;;
            "") crumb_pop; return ;;
            *) warn "Unknown option: ${ST_CHOICE}"; PAUSE ;;
        esac
    done
}
do_cron_menu() {
    crumb_push "Cron"
    while true; do
        clear
        crumb_show
        section "Cron"

        _cm_en="$CFG_CRON_ENABLED"
        _cm_expr="$CFG_CRON_SCHEDULE"
        _cm_human="$(cron_humanize "$_cm_expr")"
        _cm_reg=0
        cron_is_registered && _cm_reg=1
        _cm_last="$(cron_last_run_info)"
        _cm_hint_h="$(cron_min_server_hint_h)"

        if [ "$_cm_en" = "1" ] && [ "$_cm_reg" = "1" ]; then
            _cm_state_ico="${ICO_OK}"
            _cm_state="${OK}Enabled${NC}"
        elif [ "$_cm_en" = "1" ] && [ "$_cm_reg" = "0" ]; then
            _cm_state_ico="${ICO_WARN}"
            _cm_state="${WARN_C}Enabled${NC} ${DIM2}— crontab missing, pick a preset to re-apply${NC}"
        elif [ "$_cm_en" = "0" ] && [ "$_cm_reg" = "1" ]; then
            _cm_state_ico="${ICO_WARN}"
            _cm_state="${WARN_C}Disabled${NC} ${DIM2}— stale crontab line, use 'd' to remove${NC}"
        else
            _cm_state_ico="${ICO_DIS}"
            _cm_state="${DIM2}Disabled${NC}"
        fi

        box_buf_reset
        box_buf_line "  ${_cm_state_ico} ${_cm_state}"
        box_buf_sep
        box_buf_line "  ${A}Schedule${NC}   ${W}${_cm_human}${NC}"
        if [ "$_cm_expr" != "$_cm_human" ]; then
            box_buf_line "  ${A}Expression${NC} ${DIM2}${_cm_expr}${NC}"
        fi
        box_buf_sep
        box_buf_line "  ${A}Log${NC}        ${DIM2}${CFG_LOG_PATH}${NC}"
        box_buf_line "  ${A}Last run${NC}   ${DIM2}${_cm_last}${NC}"
        box_buf_flush 50 88
        echo ""

        if ! is_script_installed; then
            echo -e "  ${WARN_C}${ICO_WARN} Script not installed at ${INSTALL_PATH}${NC}"
            echo -e "  ${DIM2}Cron will fail — use ${W}u${DIM2} › Install Script from main menu${NC}"
            echo ""
        fi

        echo -e "  ${DIM2}Presets${NC}"
        echo -e "  ${B}1${NC} ${DIM2}›${NC} ${W}Every hour${NC}"
        echo -e "  ${B}3${NC} ${DIM2}›${NC} ${W}Every 3 hours${NC}"
        echo -e "  ${B}6${NC} ${DIM2}›${NC} ${W}Every 6 hours${NC}"
        echo -e "  ${B}8${NC} ${DIM2}›${NC} ${W}Every 12 hours${NC}"
        echo -e "  ${B}9${NC} ${DIM2}›${NC} ${W}Daily at 04:00${NC}"
        if [ "$_cm_hint_h" -gt 0 ]; then
            echo -e "  ${B}h${NC} ${DIM2}›${NC} ${A}Server hint${NC}  ${DIM2}every ${_cm_hint_h}h (from subscriptions)${NC}"
        fi
        echo ""
        echo -e "  ${B}c${NC} ${DIM2}›${NC} ${W}Custom Cron Expression${NC}"
        echo -e "  ${B}d${NC} ${DIM2}›${NC} ${ERR}Disable / Remove Cron${NC}"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "
        read_choice CM_CHOICE

        _cm_new=""
        case "${CM_CHOICE:-}" in
            1)  _cm_new="0 * * * *" ;;
            3)  _cm_new="0 */3 * * *" ;;
            6)  _cm_new="0 */6 * * *" ;;
            8)  _cm_new="0 */12 * * *" ;;
            9)  _cm_new="0 4 * * *" ;;
            h|H)
                if [ "$_cm_hint_h" -gt 0 ]; then
                    if [ "$_cm_hint_h" -ge 24 ]; then
                        _cm_new="0 0 * * *"
                    else
                        _cm_new="0 */${_cm_hint_h} * * *"
                    fi
                fi
                ;;
            c|C)
                echo ""
                prompt CUSTOM "Cron expression (5 fields)" "$_cm_expr" || continue
                _cm_nf="$(printf '%s' "${CUSTOM:-}" | awk '{print NF}')"
                if [ "$_cm_nf" != "5" ]; then
                    warn "Cron expression needs 5 fields (got ${_cm_nf:-0})"
                    PAUSE; continue
                fi
                _cm_new="$CUSTOM"
                ;;
            d|D)
                if confirm "Remove mole cron entry?" "n"; then
                    cron_unregister
                    uci set mole.settings.cron_enabled='0'
                    uci commit mole
                    mole_config_load
                    echo ""
                    echo -e "  ${ICO_OK} ${OK}Cron entry removed${NC}"
                    PAUSE
                fi
                continue
                ;;
            "") crumb_pop; return ;;
            *)  warn "Unknown option: ${CM_CHOICE}"; PAUSE; continue ;;
        esac

        if [ -n "$_cm_new" ]; then
            uci set mole.settings.cron_schedule="$_cm_new"
            uci set mole.settings.cron_enabled='1'
            uci commit mole
            mole_config_load
            cron_register "$_cm_new"
            echo ""
            echo -e "  ${ICO_OK} ${OK}Applied${NC} ${DIM2}($(cron_humanize "$_cm_new"))${NC}"
            ! is_script_installed && echo -e "  ${WARN_C}${ICO_WARN} Script not at ${INSTALL_PATH} — cron will fail; use ${B}u${WARN_C} › Install Script from the main menu${NC}"
            PAUSE
        fi
    done
}
do_self_update() {
    crumb_push "Update"
    while true; do
        clear
        crumb_show
        section "Install / Update"

        _su_ok=0
        is_script_installed && _su_ok=1

        box_buf_reset
        if [ "$_su_ok" = "1" ]; then
            box_buf_line "  ${ICO_OK} ${OK}Installed${NC}  ${DIM2}${INSTALL_PATH}${NC}"
        else
            box_buf_line "  ${ICO_ERR} ${ERR}Not installed${NC}  ${DIM2}${INSTALL_PATH}${NC}"
        fi
        box_buf_line "  ${A}Running from${NC}  ${DIM2}${SCRIPT_PATH}${NC}"
        box_buf_line "  ${A}Version${NC}       ${W}v${MOLE_VERSION}${NC}"
        box_buf_flush 50 88
        echo ""

        if [ "$_su_ok" = "0" ]; then
            echo -e "  ${WARN_C}Cron requires the script at ${INSTALL_PATH}${NC}"
            echo ""
        fi

        echo -e "  ${B}i${NC} ${DIM2}›${NC} ${W}Install${NC} ${DIM2}— copy current file to ${INSTALL_PATH}${NC}"
        echo -e "  ${B}d${NC} ${DIM2}›${NC} ${W}Download latest${NC} ${DIM2}from GitHub${NC}"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "
        read_choice SU_CHOICE

        case "${SU_CHOICE:-}" in
            i|I)
                printf "  %bInstalling%b ... " "$W" "$NC"
                if cp "$SCRIPT_PATH" "$INSTALL_PATH" 2>/dev/null \
                   && chmod +x "$INSTALL_PATH" 2>/dev/null; then
                    echo -e "${ICO_OK}"
                    echo -e "  ${DIM2}Installed to ${INSTALL_PATH}${NC}"
                else
                    echo -e "${ICO_ERR}"
                    warn "Install failed — run as root"
                fi
                PAUSE
                ;;
            d|D)
                if ! have_cmd curl; then
                    warn "curl required — install dependencies first (main menu › i)"
                    PAUSE; continue
                fi
                printf "  %bDownloading%b ... " "$W" "$NC"
                _su_tmp="${CFG_CACHE_DIR}/mole.update.$$"
                if curl -fsSL --max-time 30 "$MOLE_RAW_URL" -o "$_su_tmp" 2>/dev/null; then
                    echo -e "${ICO_OK}"
                    if cp "$_su_tmp" "$INSTALL_PATH" 2>/dev/null \
                       && chmod +x "$INSTALL_PATH" 2>/dev/null; then
                        echo -e "  ${ICO_OK} ${OK}Updated${NC} ${DIM2}— restart mole to run the new version${NC}"
                    else
                        warn "Download OK but install failed — run as root"
                    fi
                else
                    echo -e "${ICO_ERR}"
                    warn "Download failed — check internet"
                fi
                rm -f "$_su_tmp" 2>/dev/null || true
                PAUSE
                ;;
            "") crumb_pop; return ;;
            *) warn "Unknown option: ${SU_CHOICE}"; PAUSE ;;
        esac
    done
}

# do_full_reset — wipe every bit of mole state: UCI config, pool files,
# cache, log, and the crontab entry. Two-step confirm (yes/no + typed "RESET")
# to avoid accidental nukes. Exits the TUI on completion because continuing
# to run without a config would be undefined.
do_full_reset() {
    crumb_push "Reset"
    clear
    crumb_show
    section "Full Reset"

    echo -e "  ${ERR}This will permanently remove:${NC}"
    echo ""
    echo -e "    ${DIM2}·${NC} ${W}/etc/config/mole${NC}  ${DIM2}— all subscriptions, groups, settings${NC}"
    echo -e "    ${DIM2}·${NC} ${W}${CFG_POOL_DIR}/${NC}    ${DIM2}— pool files (.uris + .meta)${NC}"
    echo -e "    ${DIM2}·${NC} ${W}${CFG_CACHE_DIR}/${NC}    ${DIM2}— cache files${NC}"
    echo -e "    ${DIM2}·${NC} ${W}${CFG_LOG_PATH}${NC}    ${DIM2}— log file${NC}"
    echo -e "    ${DIM2}·${NC} ${W}/tmp/mole-cron.log${NC}    ${DIM2}— cron log${NC}"
    echo -e "    ${DIM2}·${NC} ${W}crontab entry${NC}    ${DIM2}in /etc/crontabs/root${NC}"
    echo ""
    echo -e "  ${DIM2}NB: ${SCRIPT_PATH} itself is NOT removed — delete manually if desired.${NC}"
    echo ""

    if ! confirm "Really wipe ALL mole state?" "n"; then
        cancelled; PAUSE; crumb_pop; return
    fi

    echo ""
    prompt VERIFY "Type RESET to confirm" "" || { cancelled; PAUSE; crumb_pop; return; }
    if [ "${VERIFY:-}" != "RESET" ]; then
        warn "Confirmation text mismatched — abort"
        PAUSE; crumb_pop; return
    fi

    log_event "full reset initiated"

    echo ""
    echo -e "  ${B}Unregistering${NC} cron entry..."
    cron_unregister 2>/dev/null || true

    # Strip every `_mole_section` marker we set in podkop UCI so we leave
    # the podkop config untouched (no ghost owner tags).
    if [ -f /etc/config/podkop ]; then
        echo -e "  ${B}Unlinking${NC} podkop ownership markers..."
        _fr_any=0
        for _fr_sec in $(podkop_enumerate_sections); do
            if [ -n "$(uci -q get "podkop.${_fr_sec}._mole_section" 2>/dev/null)" ]; then
                uci -q delete "podkop.${_fr_sec}._mole_section" || true
                _fr_any=1
            fi
        done
        [ "$_fr_any" = "1" ] && uci commit podkop
    fi

    if [ -f /etc/config/mole ]; then
        echo -e "  ${B}Removing${NC} /etc/config/mole..."
        rm -f /etc/config/mole
    fi

    if [ -d "$CFG_POOL_DIR" ]; then
        echo -e "  ${B}Removing${NC} ${CFG_POOL_DIR}..."
        rm -rf "$CFG_POOL_DIR"
    fi

    if [ -d "$CFG_CACHE_DIR" ]; then
        echo -e "  ${B}Removing${NC} ${CFG_CACHE_DIR}..."
        rm -rf "$CFG_CACHE_DIR"
    fi

    # Try to tidy the /etc/mole parent if it's now empty
    _parent="$(dirname "$CFG_POOL_DIR")"
    [ -d "$_parent" ] && rmdir "$_parent" 2>/dev/null || true

    [ -f "$CFG_LOG_PATH" ] && rm -f "$CFG_LOG_PATH"
    [ -f /tmp/mole-cron.log ] && rm -f /tmp/mole-cron.log

    echo ""
    echo -e "  ${ICO_OK} ${OK}Mole state wiped clean${NC}"
    echo ""
    echo -e "  ${DIM2}To also remove the script:${NC}  ${W}rm ${SCRIPT_PATH}${NC}"
    echo ""
    echo -e "  ${DIM2}Press Enter to exit...${NC}"
    read _dummy || true
    exit 0
}

do_logs_viewer() {
    crumb_push "Logs"
    while true; do
        clear
        crumb_show
        section "Logs"

        if [ ! -f "$CFG_LOG_PATH" ]; then
            echo -e "  ${DIM2}No log at ${CFG_LOG_PATH}${NC}"
            echo -e "  ${DIM2}(Will be created on first --cron run)${NC}"
            echo ""
            echo -e "  ${DIM2}Enter › Back${NC}"
            echo ""
            echo -ne "  ${A}>${NC} "
            read_choice LV_CHOICE
            case "${LV_CHOICE:-}" in "") crumb_pop; return ;; *) continue ;; esac
        fi

        _lv_size="$(wc -c < "$CFG_LOG_PATH" 2>/dev/null)"
        case "$_lv_size" in ''|*[!0-9]*) _lv_size=0 ;; esac
        _lv_lines="$(wc -l < "$CFG_LOG_PATH" 2>/dev/null)"
        case "$_lv_lines" in ''|*[!0-9]*) _lv_lines=0 ;; esac
        echo -e "  ${DIM2}${CFG_LOG_PATH} · $(fmt_bytes "$_lv_size") · ${_lv_lines} lines${NC}"
        echo ""

        if [ "$_lv_lines" -eq 0 ]; then
            echo -e "  ${DIM2}(empty)${NC}"
        else
            # Show last 80 lines; prefix with dim color
            tail -n 80 "$CFG_LOG_PATH" 2>/dev/null | while IFS= read -r _lvl; do
                printf '  %b%s%b\n' "$DIM2" "$_lvl" "$NC"
            done
        fi

        echo ""
        echo -e "  ${B}r${NC} ${DIM2}›${NC} ${A}Refresh View${NC}"
        echo -e "  ${B}c${NC} ${DIM2}›${NC} ${ERR}Clear Log${NC}"
        echo ""
        echo -e "  ${DIM2}Enter › Back${NC}"
        echo ""
        echo -ne "  ${A}>${NC} "
        read_choice LV_CHOICE
        case "${LV_CHOICE:-}" in
            r|R) ;; # re-render on next loop iter
            c|C)
                if confirm "Clear log file ${CFG_LOG_PATH}?" "n"; then
                    : > "$CFG_LOG_PATH" 2>/dev/null || warn "Cannot write to ${CFG_LOG_PATH}"
                    echo -e "  ${ICO_OK} ${OK}Cleared${NC}"
                    PAUSE
                fi
                ;;
            "") crumb_pop; return ;;
            *) warn "Unknown option: ${LV_CHOICE}"; PAUSE ;;
        esac
    done
}

# ─── Main menu ───────────────────────────────────────────────────────

show_menu() {
    crumb_set "Main"
    while true; do
        clear

        _sub_n="$(sub_count)"
        _grp_n="$(group_count)"

        _curl_s="${ICO_ERR}"; have_cmd curl && { _v="$(pkg_version curl 2>/dev/null)"; _curl_s="${ICO_OK} ${DIM2}${_v:-ok}${NC}"; }
        _jq_s="${ICO_ERR}";   have_cmd jq   && { _v="$(pkg_version jq 2>/dev/null)";   _jq_s="${ICO_OK} ${DIM2}${_v:-ok}${NC}"; }
        _b64_s="${ICO_ERR}";  have_cmd base64 && _b64_s="${ICO_OK}"
        _fl_s="${ICO_ERR}";   have_cmd flock && _fl_s="${ICO_OK}"
        _dig_s="${ICO_ERR}";  have_cmd dig   && _dig_s="${ICO_OK}"
        _nc_s="${ICO_ERR}";   have_cmd nc    && _nc_s="${ICO_OK}"
        if podkop_present; then
            _pk_ver="$(pkg_version podkop 2>/dev/null)"
            _pk_s="${ICO_OK} ${OK}${_pk_ver:-ok}${NC}"
        else
            _pk_s="${ICO_ERR} ${DIM2}n/a${NC}"
        fi

        # \033[<col>G = absolute cursor column (exact layout from liminal)
        _C="\\033[48G"
        echo -e "${V}⠀⠀⠀⠀⠀⠀⠀⢀⡄⠀⠀⠀⠀⠀⠀⠀⠀⢸⠳⣄${NC}"
        echo -e "${V}⠀⠀⠀⠀⠀⠀⠀⡏⣧⠀⠀⠀⣀⣀⣀⣀⣀⣈⡀⠣⢧${NC}"
        echo -ne "${V}⠀⠀⠀⠀⠀⠀⣰⠀⡯⣺⠋⢿⣅⠀⠀⠈⠀⠙⢌⠀⢈⣯⡒⠛⣄${NC}" && echo -e "${_C}${W}Mole${NC} ${DIM2}v${MOLE_VERSION}${NC}"
        echo -ne "${B}⠀⠀⠀⢀⠤⣼⢢⠋⠀⠀⠐⡇⠈⡄⠀⠀⠀⠀⢙⠝⠈⠀⣷⠀⠈⣧${NC}" && echo -e "${_C}${DIM2}Powered by Podkop${NC}"
        echo -e "${B}⠀⠀⢰⠁⢠⢾⠃⠀⠀⠀⡆⢿⠀⠙⠀⠀⠀⠀⢋⠓⣾⢿⢿⣶⠀⠈⡆${NC}"
        echo -ne "${B}⠀⠀⢿⠁⣖⣸⠀⠀⢰⣠⣧⠀⠙⠀⢟⢄⢄⠀⣤⠋⠿⣷⢿⢿⠁⢠⢿${NC}" && echo -e "${_C}${DIM2}·${NC} ${A}Developer${NC}  ${W}Salvatore${NC}"
        echo -ne "${A}⠀⠀⣇⠀⢻⢿⠀⠀⡼⠇⠘⣆⠀⠠⣸⢀⣙⣢⣀⢢⣶⣥⢿⣯⠀⢸⢿${NC}" && echo -e "${_C}${DIM2}·${NC} ${A}GitHub${NC}     ${W}@tickcount${NC}"
        echo -ne "${A}⠀⠀⢿⠀⠰⣾⣾⠼⣷⣭⢿⡆⠳⢿⡚⢲⢿⢿⠓⠉⠉⢻⢿⢿⣀⢿⢿${NC}" && echo -e "${_C}${DIM2}·${NC} ${A}Website${NC}    ${W}aemeath.eu${NC}"
        echo -e "${A}⠀⠀⠸⡀⢠⢿⢿⡀⢧⠈⠒⠀⠀⣀⠀⠀⠁⠉⢛⠀⣠⡟⢿⢿⢿⢿⢿${NC}"
        echo -e "${DIM2}⠀⠀⠀⣇⢿⢿⢿⢿⣶⣕⣤⢿⢿⣇⣀⣀⣤⠒⠓⠋⠋⠀⢿⢿⢿⢿⡟${NC}"
        echo -e "${DIM2}⠀⠀⢠⣏⢿⢿⢿⠀⠀⠀⣼⢿⢿⡟⣾⢿⠟⠉⣦⠀⠀⠘⠋⠈⢿⢿⠃${NC}"
        echo -e "${DIM2}⠀⢀⢿⢿⠋⠉⠀⠀⡞⠉⠉⢻⣛⢋⣶⠏⠀⣰⠁⠀⠀⠀⠀⠀⢻⢿⣧${NC}"
        echo ""

        # ── Dependency status box (same visual as liminal) ──
        box_top 56
        box_line "  ${A}curl${NC} ${_curl_s}   ${A}jq${NC} ${_jq_s}   ${A}base64${NC} ${_b64_s}"
        box_line "  ${A}flock${NC} ${_fl_s}   ${A}dig${NC} ${_dig_s}   ${A}nc${NC} ${_nc_s}"
        box_line "  ${A}podkop${NC} ${_pk_s}"
        box_bot 56
        echo ""

        # ── Subscriptions (inline list grouped by group_id) ──
        echo -e "  ${DIM2}Subscriptions${NC}"
        if [ "$_sub_n" -eq 0 ]; then
            echo -e "  ${DIM2}No subscriptions yet${NC}"
            _MENU_SUB_COUNT=0
            _MENU_SUB_IDS=""
        else
            display_subs
        fi
        echo ""
        echo -e "  ${OK}+${NC} ${DIM2}›${NC} ${W}New Subscription${NC}"
        echo ""

        # ── Manage ──
        echo -e "  ${DIM2}Manage${NC}"
        echo -e "  ${B}r${NC} ${DIM2}›${NC} ${A}Refresh All Now${NC}"
        echo -e "  ${B}l${NC} ${DIM2}›${NC} ${W}Link Pool${NC} ${DIM2}(global)${NC}"
        if podkop_present; then
            if mole_any_dirty; then
                echo -e "  ${B}p${NC} ${DIM2}›${NC} ${W}Podkop Sections${NC}  ${WARN_C}⚠ flush needed${NC}"
            else
                echo -e "  ${B}p${NC} ${DIM2}›${NC} ${W}Podkop Sections${NC}"
            fi
        fi
        echo ""

        # ── Maintenance ──
        echo -e "  ${DIM2}Maintenance${NC}"
        if [ "$CFG_CRON_ENABLED" = "1" ]; then
            if is_script_installed; then
                _cron_state="${OK}$(cron_humanize "$CFG_CRON_SCHEDULE")${NC}"
            else
                _cron_state="${WARN_C}$(cron_humanize "$CFG_CRON_SCHEDULE") ⚠${NC}"
            fi
        else
            _cron_state="${DIM2}Disabled${NC}"
        fi
        echo -e "  ${B}s${NC} ${DIM2}›${NC} ${W}Settings${NC}"
        echo -e "  ${B}c${NC} ${DIM2}›${NC} ${W}Cron${NC}  ${DIM2}(${NC}${_cron_state}${DIM2})${NC}"
        echo -e "  ${B}v${NC} ${DIM2}›${NC} ${W}View Logs${NC}"
        if is_script_installed; then
            echo -e "  ${B}u${NC} ${DIM2}›${NC} ${A}Check for Updates${NC}"
        else
            echo -e "  ${B}u${NC} ${DIM2}›${NC} ${A}Install Script${NC}  ${WARN_C}⚠ cron needs this${NC}"
        fi
        echo -e "  ${B}f${NC} ${DIM2}›${NC} ${ERR}Full Reset${NC}"
        echo ""

        # ── Install (only if any required dep missing) ──
        _missing=0
        have_cmd curl   || _missing=$((_missing + 1))
        have_cmd jq     || _missing=$((_missing + 1))
        have_cmd base64 || _missing=$((_missing + 1))
        have_cmd flock  || _missing=$((_missing + 1))
        have_cmd dig    || _missing=$((_missing + 1))
        have_cmd nc     || _missing=$((_missing + 1))

        if [ "$_missing" -gt 0 ] || ! podkop_present; then
            echo -e "  ${DIM2}Install${NC}"
            echo -e "  ${OK}i${NC} ${DIM2}›${NC} ${W}Install Dependencies${NC} ${DIM2}(${_missing} missing)${NC}"
            echo ""
        fi

        echo -e "  ${DIM2}Enter › Exit${NC}"
        echo ""

        echo -ne "  ${A}>${NC} " && read_choice MENU_CHOICE
        if sigint_caught; then
            echo -e "  ${DIM2}Press Ctrl+C again to exit${NC}"
            read -r _confirm_exit || true
            sigint_caught && exit 0
            continue
        fi

        case "${MENU_CHOICE:-}" in
            +)   do_add_menu ;;
            g|G) do_groups_menu ;;
            r|R) do_refresh_all ;;
            l|L) do_link_pool_global ;;
            p|P) do_podkop_sections_menu ;;
            s|S) do_settings ;;
            s[0-9]*|S[0-9]*)
                _gsi="${MENU_CHOICE#?}"
                _i=0; _sel_grp=""
                for _g_iter in $_MENU_GROUP_IDS; do
                    _i=$((_i + 1))
                    [ "$_i" = "$_gsi" ] && { _sel_grp="$_g_iter"; break; }
                done
                if [ -n "$_sel_grp" ]; then
                    do_group_settings "$_sel_grp"
                else
                    warn "No group at index ${_gsi}"; PAUSE
                fi
                ;;
            c|C) do_cron_menu ;;
            v|V) do_logs_viewer ;;
            u|U) do_self_update ;;
            f|F) do_full_reset ;;
            i|I) do_install_all ;;
            "")  echo; exit 0 ;;
            *)
                # numeric = subscription selection from display_subs ordering
                case "$MENU_CHOICE" in
                    ''|*[!0-9]*) warn "Unknown option: $MENU_CHOICE"; PAUSE ;;
                    *)
                        if [ "$MENU_CHOICE" -ge 1 ] 2>/dev/null && \
                           [ "$MENU_CHOICE" -le "${_MENU_SUB_COUNT:-0}" ]; then
                            do_subscription_view "$MENU_CHOICE"
                        else
                            warn "No subscription at index $MENU_CHOICE"; PAUSE
                        fi
                        ;;
                esac
                ;;
        esac
    done
}

# ─── CLI entry point ─────────────────────────────────────────────────

usage() {
    cat <<EOF
mole — OpenWRT subscription manager for Podkop (v${MOLE_VERSION})

Usage:
  mole             Launch interactive TUI
  mole --cron      Refresh all enabled subscriptions (non-interactive, for cron)
  mole --version   Print version
  mole --help      This help

EOF
}

case "${1:-}" in
    --cron)
        # Non-interactive: refresh all enabled subscriptions, auto-flush any
        # managed podkop sections whose URI set changed. Output goes to the
        # cron log via the crontab redirect.
        _cron_ts="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
        echo "[${_cron_ts}] mole --cron start"
        refresh_all 1
        _cron_errs=$?
        if podkop_present; then
            flush_all_auto 1
        fi
        if [ "$_cron_errs" -eq 0 ]; then
            echo "[${_cron_ts}] mole --cron ok"
            exit 0
        else
            echo "[${_cron_ts}] mole --cron ${_cron_errs} error(s)"
            exit "$_cron_errs"
        fi
        ;;
    --version|-V)
        echo "$MOLE_VERSION"
        exit 0
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    "")
        show_menu
        ;;
    *)
        warn "Unknown argument: $1"
        usage
        exit 1
        ;;
esac
