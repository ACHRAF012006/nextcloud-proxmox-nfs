#!/usr/bin/env bash
# Proxmox operations live here; pure validators live in validation.sh.

host_preflight() {
    [[ $(uname -s) == Linux && $EUID -eq 0 && -d /etc/pve ]] || die 'Run as root on a Proxmox VE host.'
    local command
    for command in qm pvesh pvesm curl python3 sha256sum openssl ssh-keygen flock timeout stat; do
        command -v "$command" >/dev/null || die "Required host command missing: $command (install it before continuing)."
    done
    [[ $(uname -m) == x86_64 ]] || die 'This release uses the Ubuntu amd64 cloud image and requires x86_64.'
    [[ -r /dev/tty ]] || die 'An interactive terminal is required.'
}

discover_storage() {
    pvesm status --content "$1" | awk 'NR > 1 && $3 == "active" {print $1}'
}

discover_bridges() {
    local path
    for path in /sys/class/net/*/bridge; do
        [[ -d $path ]] || continue
        path=${path%/bridge}
        printf '%s\n' "${path##*/}"
    done
}

collect_config() {
    local -a stores snippets bridges
    mapfile -t stores < <(discover_storage images)
    mapfile -t snippets < <(discover_storage snippets)
    mapfile -t bridges < <(discover_bridges)
    ((${#stores[@]})) || die 'No active VM image storage detected.'
    ((${#snippets[@]})) || die 'Enable snippets on a local directory storage in Proxmox before running. The installer will not change storage configuration.'
    ((${#bridges[@]})) || die 'No Linux network bridge detected. Configure one in Proxmox first.'
    printf 'Active VM storage: %s\nSnippet storage: %s\nBridges: %s\n' "${stores[*]}" "${snippets[*]}" "${bridges[*]}"
    ask STORAGE 'VM disk/cloud-init storage' "${stores[0]}" one_of "${stores[@]}"
    ask SNIPPET_STORAGE 'Bootstrap snippet storage (local directory only)' "${snippets[0]}" one_of "${snippets[@]}"
    ask BRIDGE 'Network bridge' "${bridges[0]}" one_of "${bridges[@]}"
    ask VLAN 'VLAN tag (none for untagged; bridge must support it)' none valid_vlan
    local next_id
    next_id=$(pvesh get /cluster/nextid) || die 'Could not detect an unused VM ID.'
    ask VMID 'New VM ID' "$next_id" valid_uint 100 999999999
    ask VM_NAME 'VM name' nextcloud valid_id
    ask CORES 'CPU cores' 4 valid_uint 1 128
    ask MEMORY 'Memory (MiB)' 4096 valid_uint 2048 1048576
    ask DISK 'System disk size (GiB; NFS data is separate)' 32 valid_uint 8 1048576
    ask NETWORK 'Networking: dhcp or static (IPv4)' dhcp one_of dhcp static
    IP_CONFIG=ip=dhcp
    if [[ $NETWORK == static ]]; then
        ask IP_CIDR 'Guest IPv4 address/CIDR' '' valid_ip interface
        ask GATEWAY 'Guest IPv4 gateway' '' valid_ip ipv4
        ask DNS 'Guest DNS server IPv4' '' valid_ip ipv4
        IP_CONFIG="ip=$IP_CIDR,gw=$GATEWAY"
    fi
    ask NFS_SERVER 'NFS server hostname or IP' '' valid_nfs_server
    ask NFS_EXPORT 'NFS export path (NFSv4 uses its server namespace)' '' valid_path
    ask NFS_VERSION 'NFS protocol: 3, 4, 4.1 or 4.2' 4.1 one_of 3 4 4.1 4.2
    ask NFS_MOUNT 'Guest NFS mount point (under /mnt or /srv)' /mnt/nextcloud valid_mount
    while :; do
        ask DATA_DIR 'Nextcloud data directory (dedicated child of mount point)' "$NFS_MOUNT/data" valid_path
        valid_data "$NFS_MOUNT" "$DATA_DIR" && break
        printf 'Data directory must be a child of the NFS mount point.\n' >&2
    done
    ask PUBLIC_HOST 'Nextcloud hostname (DNS must resolve to VM or proxy)' '' valid_hostname
    ask PROXY_MODE 'Use an existing HTTPS reverse proxy? yes or no' yes one_of yes no
    TRUSTED_PROXY=''
    if [[ $PROXY_MODE == yes ]]; then
        ask TRUSTED_PROXY 'Trusted proxy IP or narrow CIDR (never a catch-all)' '' valid_ip proxy
    fi
    local detected_zone=UTC
    if command -v timedatectl >/dev/null; then detected_zone=$(timedatectl show -p Timezone --value) || detected_zone=UTC; fi
    ask TIMEZONE 'Guest timezone' "${detected_zone:-UTC}" valid_timezone
    # An explicit upstream version avoids silently changing the server major release.
    ask NC_VERSION 'Nextcloud server version (X.Y.Z; verify PHP 8.3 compatibility)' '' valid_version
}

assert_vm_unused() {
    local inventory
    inventory=$(pvesh get /cluster/resources --type vm --output-format json) || die 'Cannot check cluster VM IDs.'
    python3 -c 'import json,sys; sys.exit(any(str(v["vmid"]) == sys.argv[1] for v in json.load(sys.stdin)))' "$VMID" <<< "$inventory" || die "VM/CT ID $VMID is already in use. Nothing was overwritten."
}

resolve_snippet() {
    # Require node-local directory storage: no generated bootstrap files on an NFS server.
    local config
    config=$(pvesh get /storage/"$SNIPPET_STORAGE" --output-format json)
    python3 -c 'import json,sys; c=json.load(sys.stdin); sys.exit(c.get("type") != "dir" or bool(c.get("shared",0)))' <<< "$config" || die 'Choose a non-shared local directory snippet storage.'
    SNIPPET_NAME="nextcloud-$VMID-bootstrap.yaml"
    SNIPPET_FILE=$(pvesm path "$SNIPPET_STORAGE:snippets/$SNIPPET_NAME")
    [[ $SNIPPET_FILE == /* && -d ${SNIPPET_FILE%/*} && ! -e $SNIPPET_FILE && ! -L $SNIPPET_FILE ]] || die 'Snippet directory must exist, and the target snippet must not already exist.'
    [[ $(stat -f -c %T "${SNIPPET_FILE%/*}") != nfs ]] || die 'Snippet directory cannot be on an NFS filesystem. Choose local host storage.'
}

show_plan() {
    printf '\nNextcloud VM Installer for Proxmox VE with NFS Storage %s\n' "$VERSION"
    printf 'Create VM %s (%s), %s cores, %s MiB RAM, %s GiB disk on %s.\n' "$VMID" "$VM_NAME" "$CORES" "$MEMORY" "$DISK" "$STORAGE"
    printf 'Bridge %s; VLAN %s; network %s.\n' "$BRIDGE" "$VLAN" "$IP_CONFIG"
    [[ $NETWORK != static ]] || printf 'DNS: %s\n' "$DNS"
    printf 'Guest NFS: %s -> %s (NFS %s, hard mount).\n' "$(nfs_source "$NFS_SERVER" "$NFS_EXPORT")" "$NFS_MOUNT" "$NFS_VERSION"
    printf 'Dedicated data directory: %s (must be empty and prepared by storage administrator).\n' "$DATA_DIR"
    printf 'Nextcloud %s; hostname %s; reverse proxy %s; trusted proxy %s; timezone %s.\n' "$NC_VERSION" "$PUBLIC_HOST" "$PROXY_MODE" "${TRUSTED_PROXY:-none}" "$TIMEZONE"
    printf 'Guest: Ubuntu 24.04 LTS, Apache, PHP 8.3, MariaDB, Redis, NFS client, cron and guest agent.\n'
    printf 'Host: VM disks, cloud-init drive, bootstrap snippet %s, private state directory /root/nextcloud-vm-installer/%s.\n' "$SNIPPET_FILE" "$VMID"
    printf 'No NFS-server management, host package installation, DNS/proxy/firewall changes or existing VM changes.\n'
    printf 'HTTP backend listens on guest port 80. Configure HTTPS and restrict access before use.\n'
    local confirmation
    prompt confirmation "Type CREATE $VMID to proceed" ''
    [[ $confirmation == "CREATE $VMID" ]] || die 'Cancelled before changes.'
}

host_error() {
    printf '\nInstallation failed. Created resources are retained for inspection; nothing is automatically destroyed.\n' >&2
    printf 'VM ID: %s. Private host state: %s. Guest log: /var/log/nextcloud-installer.log.\n' "$VMID" "${STATE_DIR:-not yet created}" >&2
    printf 'See README recovery instructions. Do not publish state files, credentials, or unredacted logs.\n' >&2
}

guest_result_ok() {
    python3 -c 'import json,sys; r=json.load(sys.stdin); r=r.get("result",r); sys.exit(not r.get("exited") or r.get("exitcode") != 0)'
}

prepare_state() {
    STATE_DIR="/root/nextcloud-vm-installer/$VMID"
    [[ ! -e $STATE_DIR && ! -L $STATE_DIR ]] || die 'Host state already exists for this ID; choose a new ID or review it manually.'
    [[ ! -L /root/nextcloud-vm-installer ]] || die 'Host state parent cannot be a symlink.'
    umask 077
    mkdir -p /root/nextcloud-vm-installer
    chmod 700 /root/nextcloud-vm-installer
    mkdir -m 700 "$STATE_DIR"
    ssh-keygen -q -t ed25519 -N '' -C "nextcloud-vm-$VMID" -f "$STATE_DIR/ssh_key"
    ADMIN_PASSWORD=$(openssl rand -hex 24)
    DB_PASSWORD=$(openssl rand -hex 24)
    printf 'VM_ID=%s\nADMIN_USER=ncadmin\nADMIN_PASSWORD=%s\nSSH_USER=ncoperator\nSSH_PRIVATE_KEY=%s/ssh_key\n' "$VMID" "$ADMIN_PASSWORD" "$STATE_DIR" > "$STATE_DIR/credentials.txt"
    chmod 600 "$STATE_DIR/credentials.txt"
}

download_image() {
    local base=https://cloud-images.ubuntu.com/noble/current
    local name=noble-server-cloudimg-amd64.img checksum
    printf 'Downloading Ubuntu cloud image and published SHA-256 checksum over HTTPS...\n'
    curl --fail --show-error --location --proto '=https' --tlsv1.2 "$base/SHA256SUMS" -o "$STATE_DIR/SHA256SUMS"
    checksum=$(awk -v name="$name" '$2 == name || $2 == "*"name {print $1}' "$STATE_DIR/SHA256SUMS")
    [[ $checksum =~ ^[a-f0-9]{64}$ ]] || die 'Cannot identify cloud image checksum.'
    curl --fail --show-error --location --proto '=https' --tlsv1.2 "$base/$name" -o "$STATE_DIR/$name"
    printf '%s  %s\n' "$checksum" "$STATE_DIR/$name" | sha256sum --check --status || die 'Cloud image checksum mismatch (upstream may have rotated; restart with a fresh ID).'
    IMAGE_FILE="$STATE_DIR/$name"
}

create_vm() {
    local net="virtio,bridge=$BRIDGE" imported_disk
    [[ $VLAN == none ]] || net+=",tag=$VLAN"
    # No credentials in this snippet; authentication uses the public key on the seed drive.
    (set -o noclobber; cat > "$SNIPPET_FILE" <<'YAML'
#cloud-config
package_update: true
packages:
  - qemu-guest-agent
runcmd:
  - [systemctl, enable, --now, qemu-guest-agent]
YAML
    )
    chmod 600 "$SNIPPET_FILE"
    qm create "$VMID" --name "$VM_NAME" --memory "$MEMORY" --cores "$CORES" --cpu kvm64 \
        --net0 "$net" --scsihw virtio-scsi-pci --serial0 socket --vga serial0 --agent enabled=1
    qm importdisk "$VMID" "$IMAGE_FILE" "$STORAGE"
    imported_disk=$(qm config "$VMID" | sed -n 's/^unused0: //p')
    [[ -n $imported_disk && $imported_disk == "$STORAGE:"* ]] || die 'Could not identify the imported disk; inspect VM manually.'
    qm set "$VMID" --scsi0 "$imported_disk" --ide2 "$STORAGE:cloudinit" --boot order=scsi0 \
        --ciuser ncoperator --sshkeys "$STATE_DIR/ssh_key.pub" --ipconfig0 "$IP_CONFIG" \
        --cicustom "vendor=$SNIPPET_STORAGE:snippets/$SNIPPET_NAME"
    [[ $NETWORK != static ]] || qm set "$VMID" --nameserver "$DNS"
    qm resize "$VMID" scsi0 "${DISK}G"
    qm start "$VMID"
}

wait_guest() {
    printf 'Waiting up to 15 minutes for guest agent and cloud-init...\n'
    local deadline=$((SECONDS + 900)) result
    while ((SECONDS < deadline)); do
        if timeout 10 qm agent "$VMID" ping >/dev/null 2>&1; then
            result=$(qm guest exec "$VMID" --timeout 10 -- /bin/sh -c 'test -f /var/lib/cloud/instance/boot-finished && cloud-init status --format json >/dev/null' 2>/dev/null) || result='{}'
            if guest_result_ok <<< "$result"; then return; fi
        fi
        sleep 5
    done
    die 'Guest not ready. Check guest DHCP/static settings, DNS, Internet access and cloud-init console.'
}

configure_guest() {
    local result key
    printf 'Configuring guest (up to 30 minutes). Root-only guest log: /var/log/nextcloud-installer.log\n'
    # Pass configuration and generated application secrets in stdin, never CLI arguments or cloud-init.
    result=$({
        printf 'set +x\n'
        for key in NFS_SERVER NFS_EXPORT NFS_VERSION NFS_MOUNT DATA_DIR PUBLIC_HOST PROXY_MODE TRUSTED_PROXY TIMEZONE NC_VERSION ADMIN_PASSWORD DB_PASSWORD; do
            printf '%s=%q\n' "$key" "${!key}"
        done
        render_guest
    } | qm guest exec "$VMID" --timeout 1800 --pass-stdin 1 -- /bin/bash -s)
    # Do not echo guest output, which could contain local information or package diagnostics.
    guest_result_ok <<< "$result" || die 'Guest configuration failed or is still running. Inspect its protected log and README before recovery.'
    unset ADMIN_PASSWORD DB_PASSWORD
    printf '\nGuest configured. URL: %s://%s\n' "$([[ $PROXY_MODE == yes ]] && printf https || printf http)" "$PUBLIC_HOST"
    printf 'Credentials and SSH private key are only in %s (root-only).\n' "$STATE_DIR"
    printf 'Guest address: run qm agent %s network-get-interfaces, or inspect its console.\n' "$VMID"
    printf 'Configure DNS/HTTPS/proxy access and backups before storing real data.\n'
}

install_vm() {
    # Serialize this installer's own invocations; cluster-level ID races still fail at qm create.
    exec 9>/run/lock/nextcloud-vm-installer.lock
    flock -n 9 || die 'Another installation is running on this host.'
    trap host_error ERR
    assert_vm_unused
    prepare_state
    download_image
    assert_vm_unused
    create_vm
    wait_guest
    configure_guest
    trap - ERR
}
