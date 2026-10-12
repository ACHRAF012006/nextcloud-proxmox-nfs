#!/usr/bin/env bash
VERSION=1.0.0

usage() {
    printf '%s\n' \
        'Nextcloud VM Installer for Proxmox VE with NFS Storage' \
        'Usage: ./install.sh [--help | --version]' \
        'Without arguments: interactively review and create a new Ubuntu VM on Proxmox.' \
        'Run as root on an x86_64 Proxmox VE host. No NFS server changes are made.' \
        'A local directory storage with snippets enabled is required.' \
        'CPU/RAM/disk, storage, bridge/VLAN, networking, NFS, hostname/proxy and timezone are editable.'
}

main() {
    case ${1:-} in
        --version) [[ $# == 1 ]] || die 'Unexpected arguments.'; printf '%s\n' "$VERSION"; return ;;
        --help|-h) [[ $# == 1 ]] || die 'Unexpected arguments.'; usage; return ;;
        '') ;;
        *) die 'Unknown argument. Use --help.' ;;
    esac
    host_preflight
    collect_config
    assert_vm_unused
    resolve_snippet
    show_plan
    install_vm
}

if [[ -z ${BASH_SOURCE[0]:-} || ${BASH_SOURCE[0]} == "$0" ]]; then
    set +x
    set -Eeuo pipefail
    main "$@"
fi
