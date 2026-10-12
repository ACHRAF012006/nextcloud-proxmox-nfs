#!/usr/bin/env bash
# Pure input validation. Sourcing this file never changes a host.

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

valid_uint() {
    [[ $1 =~ ^[1-9][0-9]{0,8}$ ]] && (( 10#$1 >= $2 && 10#$1 <= $3 ))
}

valid_id() { [[ $1 =~ ^[A-Za-z][A-Za-z0-9_-]{0,63}$ ]]; }
valid_hostname() {
    local label
    [[ ${#1} -le 253 && $1 != *..* && $1 != *. && $1 != .* ]] || return 1
    local -a labels
    IFS=. read -r -a labels <<< "$1"
    for label in "${labels[@]}"; do
        [[ $label =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || return 1
    done
}

valid_path() {
    [[ $1 =~ ^/[A-Za-z0-9_./-]+$ && $1 != *//* && $1 != */../* && $1 != */.. &&
        $1 != */./* && $1 != */. && $1 != */ ]]
}

valid_mount() { valid_path "$1" && [[ $1 == /mnt/* || $1 == /srv/* ]]; }
valid_snippet_path() { valid_path "$1" && [[ $1 == /var/lib/* || $1 == /srv/* ]]; }
valid_data() { valid_path "$2" && [[ $2 == "$1/"* ]]; }
valid_version() { [[ $1 =~ ^[1-9][0-9]*\.[0-9]+\.[0-9]+$ ]]; }
valid_timezone() { [[ $1 =~ ^[A-Za-z0-9_+/-]+$ && $1 != *..* && -f /usr/share/zoneinfo/$1 ]]; }

valid_ip() {
    python3 - "$1" "${2:-address}" <<'PY'
import ipaddress, sys
try:
    value, kind = sys.argv[1:]
    if kind == 'ipv4':
        assert isinstance(ipaddress.ip_address(value), ipaddress.IPv4Address)
    elif kind == 'interface':
        assert '/' in value
        assert isinstance(ipaddress.ip_interface(value), ipaddress.IPv4Interface)
    elif kind == 'proxy':
        network = ipaddress.ip_network(value, strict=False)
        assert network.prefixlen > 0
    else:
        ipaddress.ip_address(value)
except (ValueError, AssertionError):
    sys.exit(1)
PY
}

valid_nfs_server() {
    if [[ $1 == *:* || $1 =~ ^[0-9.]+$ ]]; then valid_ip "$1"; else valid_hostname "$1"; fi
}
valid_vlan() { [[ $1 == none ]] || valid_uint "$1" 1 4094; }

valid_snippet_config() {
    python3 -c '
import json,sys
try:
    c=json.load(sys.stdin)
    ok=(c.get("type") == "dir" and c.get("shared",0) in (0,False,"0")
        and "snippets" in c.get("content","").split(","))
except (ValueError,AttributeError,TypeError):
    ok=False
sys.exit(not ok)'
}

valid_local_fs() { one_of "$1" ext2 ext3 ext4 xfs btrfs zfs f2fs jfs reiserfs; }

valid_guest_bridge() {
    [[ $1 =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}$ && ! $1 =~ ^(fwbr|fwln|fwpr)[0-9] ]]
}

prompt() {
    local variable=$1 label=$2 default=${3:-} answer
    if [[ -n $default ]]; then
        printf '%s [%s]: ' "$label" "$default" >&2
    else
        printf '%s: ' "$label" >&2
    fi
    IFS= read -r answer < /dev/tty || die 'Input cancelled.'
    printf -v "$variable" '%s' "${answer:-$default}"
}

ask() {
    local variable=$1 label=$2 default=$3 validator=$4
    shift 4
    while :; do
        prompt "$variable" "$label" "$default"
        if "$validator" "${!variable}" "$@"; then return; fi
        printf 'Invalid value. Please try again.\n' >&2
    done
}

one_of() {
    local value=$1 option
    shift
    for option in "$@"; do [[ $value != "$option" ]] || return 0; done
    return 1
}

nfs_source() {
    if [[ $1 == *:* ]]; then printf '[%s]:%s' "$1" "$2"; else printf '%s:%s' "$1" "$2"; fi
}
