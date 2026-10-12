#!/usr/bin/env bash
# All Proxmox calls are mocks. Filesystem mutations are confined to this fixture.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source install.sh
umask 077
fixture=$(mktemp -d -t nextcloud-storage-test.XXXXXXXX)
cleanup() {
    # Remove only the fixture files/directories that this test created; no recursive deletion.
    rm -f -- "$fixture/calls" "$fixture/symlink" "$fixture/unexpected-mutation"
    rmdir -- "$fixture/new/snippets" "$fixture/new" "$fixture/local/snippets" "$fixture/local" "$fixture" 2>/dev/null || true
}
trap cleanup EXIT
mkdir "$fixture/local"
checks=0
accept() { "$@" || { printf 'Expected acceptance: %s\n' "$*" >&2; exit 1; }; checks=$((checks+1)); }
reject() { if "$@"; then printf 'Expected rejection: %s\n' "$*" >&2; exit 1; fi; checks=$((checks+1)); }
accept valid_snippet_config <<< '{"type":"dir","content":"iso,snippets"}'
accept valid_snippet_config <<< '{"type":"dir","content":"snippets","shared":"0"}'
reject valid_snippet_config <<< '{"type":"dir","content":"snippets","shared":1}'
reject valid_snippet_config <<< '{"type":"nfs","content":"snippets"}'
reject valid_snippet_config <<< '{"type":"cifs","content":"snippets"}'
reject valid_snippet_config <<< '{"type":"dir","content":"iso"}'
reject valid_snippet_config <<< 'invalid json'
accept valid_local_fs ext4
accept valid_local_fs zfs
reject valid_local_fs nfs
reject valid_local_fs nfs4
reject valid_local_fs cifs
reject valid_local_fs ceph
reject valid_local_fs tmpfs

registered=0
fake_filesystem=ext4
# shellcheck disable=SC2317,SC2329
findmnt() { printf '%s\n' "$fake_filesystem"; }
# shellcheck disable=SC2317,SC2329
pvesh() {
    case $2 in
        /storage)
            if ((registered)); then printf '[{"storage":"local"},{"storage":"test-snippets"}]\n'; else printf '[{"storage":"local"}]\n'; fi ;;
        /storage/local|/storage/test-snippets) printf '{"type":"dir","content":"snippets","shared":0}\n' ;;
        /storage/shared) printf '{"type":"dir","content":"snippets","shared":1}\n' ;;
        /storage/remote) printf '{"type":"nfs","content":"snippets"}\n' ;;
        *) return 1 ;;
    esac
}
# shellcheck disable=SC2317,SC2329
pvesm() {
    case $1 in
        path)
            case $2 in
                local:*) printf '%s/local/snippets/%s\n' "$fixture" "${2##*/}" ;;
                test-snippets:*) printf '%s/new/snippets/%s\n' "$fixture" "${2##*/}" ;;
                *) return 1 ;;
            esac ;;
        add)
            [[ $* == "add dir test-snippets --path $fixture/new --content snippets --nodes testnode --shared 0 --create-base-path 0 --create-subdirs 0" ]] || return 1
            printf '%s\n' "$*" >> "$fixture/calls"
            registered=1 ;;
        *) die 'Unexpected Proxmox mutation in test' ;;
    esac
}
# shellcheck disable=SC2317,SC2329
discover_storage() { printf 'remote\nshared\nlocal\n'; }
[[ $(discover_local_snippets 2>/dev/null) == local ]]
[[ ! -e $fixture/calls && ! -e $fixture/local/snippets ]]
checks=$((checks+1))
accept local_directory_path "$fixture/new/snippets"
ln -s "$fixture/local" "$fixture/symlink"
reject local_directory_path "$fixture/symlink/snippets"
fake_filesystem=nfs
reject local_directory_path "$fixture/new"
reject snippet_storage_usable local
fake_filesystem=ext4

VMID=321
SNIPPET_MODE=create
SNIPPET_STORAGE=test-snippets
NEW_SNIPPET_PATH="$fixture/new"
HOST_NODE=testnode
resolve_snippet
[[ ! -e $fixture/new && ! -e $fixture/calls ]]
checks=$((checks+1))

# Cancelling the real main flow must not create directories or register storage.
# shellcheck disable=SC2317,SC2329
host_preflight() { :; }
# shellcheck disable=SC2317,SC2329
assert_vm_unused() { :; }
# shellcheck disable=SC2317,SC2329
collect_config() {
    VM_NAME=nextcloud; CORES=4; MEMORY=4096; DISK=32; STORAGE=local-disk
    BRIDGE=vmbr0; VLAN=none; NETWORK=dhcp; IP_CONFIG=ip=dhcp
    NFS_SERVER=nfs.example.com; NFS_EXPORT=/exports/data; NFS_MOUNT=/mnt/nextcloud; NFS_VERSION=4.1
    DATA_DIR=/mnt/nextcloud/data; NC_VERSION=35.0.1; PUBLIC_HOST=cloud.example.com
    PROXY_MODE=no; TRUSTED_PROXY=''; TIMEZONE=UTC
}
# shellcheck disable=SC2317,SC2329
prompt() { printf -v "$1" '%s' CANCEL; }
# Even a confirmation regression must never reach real host operations in a test.
# shellcheck disable=SC2317,SC2329
install_vm() { printf 'unexpected mutation\n' > "$fixture/unexpected-mutation"; }
if (main) >/dev/null 2>&1; then die 'Cancellation unexpectedly succeeded'; fi
[[ ! -e $fixture/new && ! -e $fixture/calls && ! -e $fixture/unexpected-mutation ]]
checks=$((checks+1))

prepare_snippet_storage
[[ $registered == 1 && $SNIPPET_MODE == existing && -d $fixture/new/snippets && -s $fixture/calls ]]
checks=$((checks+1))

# Occupied IDs and existing directories must fail before reusing or changing them.
if (SNIPPET_MODE=create; NEW_SNIPPET_PATH="$fixture/occupied"; prepare_snippet_storage) >/dev/null 2>&1; then die 'Occupied ID accepted'; fi
[[ ! -e $fixture/occupied && $(wc -l < "$fixture/calls") == 1 ]]
if (SNIPPET_MODE=create; SNIPPET_STORAGE=fresh-id; prepare_snippet_storage) >/dev/null 2>&1; then die 'Existing directory reused'; fi
checks=$((checks+2))

# Existing local storage can acquire its missing snippets directory without changing configuration.
SNIPPET_STORAGE=local
SNIPPET_MODE=existing
prepare_snippet_storage
[[ -d $fixture/local/snippets && $(wc -l < "$fixture/calls") == 1 ]]
if (SNIPPET_STORAGE=remote; prepare_snippet_storage) >/dev/null 2>&1; then die 'Remote storage accepted'; fi
checks=$((checks+2))
printf 'Passed %s storage planning/provisioning safety checks.\n' "$checks"
