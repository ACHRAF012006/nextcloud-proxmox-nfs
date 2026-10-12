#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
source src/validation.sh
source src/host.sh
source install.sh

checks=0
accept() { "$@" || { printf 'Expected acceptance: %s\n' "$*" >&2; exit 1; }; checks=$((checks+1)); }
reject() { if "$@"; then printf 'Expected rejection: %s\n' "$*" >&2; exit 1; fi; checks=$((checks+1)); }

accept valid_uint 100 100 999999999
reject valid_uint 099 100 999999999
reject valid_uint '1; touch injected' 1 128
reject valid_uint 9999999999 1 128
accept valid_hostname cloud.example.com
reject valid_hostname '-cloud.example.com'
reject valid_hostname 'cloud..example.com'
reject valid_hostname 'cloud.example.com;id'
accept valid_vlan none
accept valid_vlan 4094
reject valid_vlan 4095
accept valid_ip 192.0.2.12/24 interface
reject valid_ip 192.0.2.12 interface
reject valid_ip 999.0.0.1 ipv4
accept valid_nfs_server nfs.example.com
reject valid_nfs_server 999.0.0.1
accept valid_ip 2001:db8::12
accept valid_ip 192.0.2.2/32 proxy
reject valid_ip 0.0.0.0/0 proxy
reject valid_ip ::/0 proxy
accept valid_mount /mnt/nextcloud
accept valid_mount /srv/team-files
reject valid_mount /etc
reject valid_mount /mnt/x/../etc
reject valid_mount /mnt/x//data
# Deliberate literal command-substitution input: validation must reject it.
# shellcheck disable=SC2016
reject valid_mount '/mnt/$(id)'
reject valid_mount '/mnt/x data'
accept valid_data /mnt/nextcloud /mnt/nextcloud/data
reject valid_data /mnt/nextcloud /mnt/nextcloud-other/data
reject valid_data /mnt/nextcloud /mnt/nextcloud
accept valid_version 35.0.1
reject valid_version latest
reject valid_version '../1.0.0'
[[ $(nfs_source 2001:db8::2 /exports/data) == '[2001:db8::2]:/exports/data' ]]
[[ $(nfs_source nfs.example.com /exports/data) == 'nfs.example.com:/exports/data' ]]
accept guest_result_ok <<< '{"exited":true,"exitcode":0}'
accept guest_result_ok <<< '{"result":{"exited":true,"exitcode":0}}'
reject guest_result_ok <<< '{"pid":123}'
reject guest_result_ok <<< '{"exited":true,"exitcode":1}'

# Cluster VM IDs include both VMs and containers; failures must fail closed.
VMID=321
# Mocks are invoked indirectly, including after export via declare -f in a child shell.
# shellcheck disable=SC2317,SC2329
pvesh() { printf '%s\n' '[{"vmid":322}]'; }
accept assert_vm_unused
# shellcheck disable=SC2317,SC2329
pvesh() { printf '%s\n' '[{"vmid":321,"type":"lxc"}]'; }
reject bash -c "$(declare -f die assert_vm_unused pvesh); VMID=321; assert_vm_unused" 2>/dev/null
# shellcheck disable=SC2317,SC2329
pvesh() { return 1; }
reject bash -c "$(declare -f die assert_vm_unused pvesh); VMID=321; assert_vm_unused" 2>/dev/null
unset -f pvesh

# Help/version must work without root, Linux host discovery, or downloads.
host_preflight() { die 'Host operations reached during help/version'; }
[[ $(main --version) == 1.0.0 ]]
main --help >/dev/null
# The documented curl/bash -c form has an empty BASH_SOURCE array.
[[ $(bash -c "$(< install.sh)" installer --version) == 1.0.0 ]]
bash -c "$(< install.sh)" installer --help >/dev/null
printf 'Passed %s validation/safety checks and CLI smoke checks.\n' "$checks"
