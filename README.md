# Nextcloud VM Installer for Proxmox VE with NFS Storage

Community software that creates a new Ubuntu VM on Proxmox VE and installs Nextcloud with its data directory on an existing NFS export. Configuration is interactive and reusable across environments. Version: **1.0.0**. Licensed under [MIT](LICENSE).

This project is not affiliated with, sponsored by, or endorsed by Proxmox Server Solutions GmbH, Nextcloud GmbH, or iXsystems / TrueNAS. Product names identify the software and example storage platforms; they do not imply official support.

**Deployment status:** shell syntax, ShellCheck, parsing/validation and mocked-host safety checks are automated. A real Proxmox/guest/NFS deployment has not yet been tested by this project. Start with a disposable VM and an empty dedicated export directory. A release tag identifies a version, not a certification of production readiness.

## What it creates

The installer displays all selected settings and requires `CREATE <VM ID>` before making changes.

| Location | Resources created or configured |
| --- | --- |
| Proxmox host | One new VM with an imported Ubuntu 24.04 LTS amd64 disk, an editable disk size, cloud-init drive, virtual NIC, serial console and enabled guest agent |
| Selected local snippet storage | `nextcloud-<VM ID>-bootstrap.yaml`, containing guest-agent bootstrap instructions and no secrets |
| Proxmox root directory | `/root/nextcloud-vm-installer/<VM ID>/`, mode 0700, containing the downloaded image/checksums, a generated SSH key pair and a mode-0600 `credentials.txt` |
| Guest system disk | Apache, PHP 8.3, MariaDB, Redis, NFS client, Nextcloud application/configuration, systemd background jobs and protected installation log |
| Existing NFS export | Nextcloud application data written by the guest into a pre-existing, dedicated, empty child directory; one temporary write-test file is created and removed |

The installer does not administer the NFS server, change export configuration or permission policies, install host packages, alter host networking/storage definitions, configure an external proxy/DNS/firewall, reuse an existing VM, or delete failed VMs automatically. Existing host packages, bridges and storage must already be prepared. It refuses occupied VM/CT IDs across the cluster.

Nextcloud's database, Redis and application code stay on the guest system disk. NFS contains the data directory. Both need coordinated backups.

## Requirements

- An x86_64 Proxmox VE host, root access and a terminal. The implementation uses standard `qm`, `pvesh` and `pvesm` interfaces; no particular Proxmox release has yet been deployment-tested.
- Active storage supporting VM images/cloud-init and a Linux network bridge. A **non-shared local directory storage with `snippets` enabled** and its snippet directory already created is required. Enable/create this through Proxmox administration; the installer does not alter storage definitions.
- Host commands: `qm`, `pvesh`, `pvesm`, `curl`, `python3`, `sha256sum`, `openssl`, `ssh-keygen`, `flock`, `timeout`, `stat`, and normal GNU/Linux utilities. Missing commands cause a preflight failure. Install dependencies yourself before running.
- Host and guest outbound access to Ubuntu/Nextcloud HTTPS downloads and Ubuntu package repositories; working guest DNS and DHCP or a valid static IPv4 configuration. VM network configuration supports IPv4 DHCP/static in this release; the NFS endpoint may also be IPv6.
- A reachable NFSv3 or NFSv4 server, with the export prepared and the guest authorized. Choose protocol `3`, `4`, `4.1` or `4.2`; the server must support that choice. NFSv4 export paths are relative to the server's NFSv4 namespace and may differ from local filesystem paths.
- A DNS hostname for the service. For public use, an existing HTTPS reverse proxy and a restrictive network policy for guest HTTP port 80 are required. Direct mode is HTTP for initial private-network validation; it does not provision a TLS certificate.
- An explicit Nextcloud `X.Y.Z` release compatible with Ubuntu 24.04's PHP 8.3 and MariaDB. Consult the [upstream system requirements](https://docs.nextcloud.com/server/stable/admin_manual/installation/system_requirements.html) and select a supported maintenance release. No floating Nextcloud version is silently installed.

## Install a stable version

Recommended: download, inspect, then run on the Proxmox host:

```bash
curl -fsSL https://raw.githubusercontent.com/ACHRAF012006/nextcloud-proxmox-nfs/v1.0.0/install.sh -o install.sh
less install.sh
bash install.sh --version
bash install.sh --help
bash install.sh
```

The installer is self-contained: reviewing `install.sh` includes the host logic, validation and guest script. It does not download additional project scripts. Ubuntu and Nextcloud software are downloaded separately from their official HTTPS origins and checked against SHA-256 checksum files fetched from those origins. This detects corrupted/mismatched downloads; it is not independent signature verification. The Ubuntu image is the current 24.04 cloud image, so a pinned installer does not freeze operating-system package versions.

Convenient stable-version command:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ACHRAF012006/nextcloud-proxmox-nfs/v1.0.0/install.sh)"
```

Development/latest installer from `main`:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/ACHRAF012006/nextcloud-proxmox-nfs/main/install.sh)"
```

**Security:** `bash -c "$(curl -fsSL URL)"` is convenient but executes remote code immediately with your privileges. Prefer the download/`less`/`bash` workflow above. Inspect the source and release history. For stronger reproducibility pin a specific reviewed commit; tags can be moved by repository maintainers. Release assets include `install.sh` and `install.sh.sha256`, generated from the same tagged commit. See [SECURITY.md](SECURITY.md).

If you clone/download the repository on a Linux system with executable permissions preserved, these also work:

```bash
./install.sh --version
./install.sh --help
```

## Configuration

Every detected/default value is editable. No storage name, bridge, subnet, NFS endpoint or public domain is assumed.

| Setting | Detection or editable default |
| --- | --- |
| VM image storage | First active image-capable storage, selected from detected choices |
| Snippet storage | Detected snippet-capable storage; must be a non-shared local directory |
| Bridge | First detected Linux bridge, selected from detected choices |
| VLAN | `none`; editable tag 1–4094 |
| VM ID | Detected next available cluster ID, rechecked before creation |
| VM name | `nextcloud` |
| CPU / RAM / system disk | 4 cores / 4096 MiB / 32 GiB, all editable |
| Networking | DHCP, or supplied IPv4/CIDR, gateway and DNS server |
| NFS server / export | Required; no deployment-specific defaults |
| NFS version | `4.1`, editable to 3/4/4.1/4.2 |
| Guest mount / data directory | `/mnt/nextcloud` and `/mnt/nextcloud/data`, both editable |
| Public hostname | Required; no domain default |
| Reverse proxy | Existing HTTPS proxy or direct private HTTP; explicit trusted IP/narrow CIDR for proxy mode |
| Timezone | Detected host timezone, falling back to UTC, editable |
| Nextcloud version | Required explicit compatible `X.Y.Z` |

Paths currently accept portable ASCII letters, digits, underscores, dots and hyphens; whitespace and traversal components are refused. Mount points must be under `/mnt` or `/srv`. The data directory must be a dedicated child of that mount, outside the web root, already present on the server and empty. This release creates a fresh installation and does not migrate or upgrade an existing one.

## NFS preparation and troubleshooting

The storage administrator must prepare the export before installation:

1. Permit the guest's client address/subnet under your storage policy, with the chosen NFS version. For DHCP, use a reservation or another stable client authorization arrangement. NFSv3 may require rpcbind/mountd and additional negotiated ports; NFSv4 normally uses TCP 2049. Check your server's documentation and firewall configuration.
2. Create an empty dedicated data subdirectory within the export. Configure ownership/identity mapping for guest `www-data`, normally UID/GID **33:33** on Ubuntu 24.04, with directory mode **0700 or 0750**. Parent directories must allow traversal, and ACLs must permit that identity to read/write/create/delete. Do not share this directory with other applications or enable write access for untrusted clients.
3. Keep root squash. The installer accesses and checks data as `www-data`, not guest root. Check NFSv4 ID mapping/ACL behavior or numeric UID/GID mapping as appropriate. Restricted root access is expected; the web identity must be able to inspect its directory and traverse its parents.

Mount failures report the failing stage in the protected guest log. Permission failures describe the expected guest identity. **The installer never changes server-side ownership, ACLs, export rules or permissions, and never applies permissive permission workarounds.** It checks that the directory is empty, owned by the guest web identity and mode 0700/0750, then tests file creation/removal as that identity. An export root itself is not accepted as the Nextcloud data directory.

`hard,_netdev,nosuid,nodev,noexec` mounts are used. Apache and the background-job service require the mount, verify it before starting, and stop when systemd observes the mount disappearing. If a server becomes unreachable while the mount remains present, hard-mounted I/O can block until it recovers. The guest will not silently switch to a local data directory. NFS downtime still requires operational monitoring; this is not a high-availability system.

Example storage platforms are **TrueNAS SCALE, TrueNAS CORE, Linux NFS servers, Synology and QNAP**. These are examples of systems that can provide standard NFS exports, not certified compatibility claims. All platform/protocol combinations are currently **untested by this project**. Compatibility depends on standard mount behavior, guest identity mapping, locking and permission semantics; no vendor-specific management API is used. Please contribute sanitized deployment results with software versions and protocol to expand the tested matrix.

## Access, proxy and credentials

After success, inspect guest addressing with `qm agent <VM ID> network-get-interfaces` or the Proxmox console. Point DNS at the VM or proxy. For DHCP, use a reservation if stable addressing is needed. The SSH account is `ncoperator` with key authentication; no guest login password is generated. Its generated private key stays on the Proxmox host in the root-only state directory. The Nextcloud account is `ncadmin`; its random password is in that host directory's `credentials.txt` and is never printed by the installer.

Application secrets necessarily enter the guest during configuration: they are sent over guest-agent stdin, not cloud-init snippets or Proxmox command arguments. The admin password is transient in guest process memory/arguments while `occ` installs Nextcloud; Nextcloud persists its password hash. MariaDB's application password is persisted in Nextcloud's restricted configuration. Protect guest/root access and VM backups accordingly. Root-only guest logs can contain sensitive diagnostics and must not be shared unredacted. There is no GitHub API, telemetry, credential upload or remote callback in the installer.

For proxy mode, configure your existing proxy to terminate HTTPS, forward the hostname and `X-Forwarded-For`/`X-Forwarded-Proto` appropriately, and route WebDAV and discovery paths to the guest. Restrict direct guest port 80 access to trusted clients/proxy addresses using your own firewall. Trust only the actual proxy address or a narrow necessary network; catch-all `/0` ranges are refused. See the [upstream reverse-proxy guide](https://docs.nextcloud.com/server/stable/admin_manual/configuration_server/reverse_proxy_configuration.html). The installer configures Nextcloud's proxy trust and canonical HTTPS URL; it does not modify your external proxy, obtain certificates, or validate public reachability.

## Failure recovery and maintenance

On failure, the VM, disks, bootstrap snippet and private host state are retained. There is no automatic destructive rollback. Inspect the guest console, `cloud-init status --long`, `/var/log/nextcloud-installer.log` (root-only) and `/var/lib/nextcloud-installer/status`. Do not paste credentials or unredacted configuration/logs into issues.

If the host reports a guest-exec timeout, the guest command can still be running. Check `qm guest exec-status <VM ID> <PID>` if a PID was returned, or inspect the guest status/console; never launch a second installer while it is running. The installer refuses automatic guest reruns and occupied IDs. For a failed fresh deployment, correct the cause and create a new VM with a new ID and an empty data directory. Remove failed resources manually through Proxmox administration only after identifying them and confirming no data is needed. The NFS administrator decides how to handle any partial data. Host image/state files and snippets are retained intentionally; identify each exact path before manual cleanup.

Before production use, test a reboot with NFS available, a boot with NFS unavailable, and a restore from backup. Back up the guest database, Nextcloud configuration and NFS data consistently. Schedule supported Nextcloud/PHP/OS updates and monitor NFS availability, service health and storage capacity. The installer is not an upgrade manager, backup manager or complete server-hardening tool.

## Development and releases

`src/validation.sh` contains input/parsing helpers; `src/host.sh` contains Proxmox operations; `src/guest.sh` contains guest setup; `src/main.sh` contains version/CLI orchestration. `scripts/build.mjs` combines them deterministically into the committed self-contained `install.sh`.

```bash
node scripts/build.mjs
node scripts/build.mjs --check
node scripts/check-repo.mjs
find . -type f -name '*.sh' -not -path './.git/*' -print0 | xargs -0 -r -n 1 bash -n
find . -type f -name '*.sh' -not -path './.git/*' -print0 | xargs -0 -r shellcheck
bash tests/validation.sh
```

CI runs on pushes and pull requests without a Proxmox server. Release tags `vX.Y.Z` must match `VERSION=X.Y.Z`, pass the same checks and generate downloadable installer/checksum assets. See [CONTRIBUTING.md](CONTRIBUTING.md), [CHANGELOG.md](CHANGELOG.md) and [SECURITY.md](SECURITY.md).
