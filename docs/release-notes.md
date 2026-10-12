Nextcloud VM Installer for Proxmox VE with NFS Storage.

Version 1.0.1 automates local snippet storage setup. If no suitable storage exists, accept the default +create option, review/edit the new ID and local path, and confirm the displayed creation summary. The installer creates a dedicated non-shared directory storage restricted to the detected node. Existing storage definitions and NFS-server configuration are not changed. Shared/remote snippet storage and Proxmox VM firewall bridges are excluded from default choices.

Occupied IDs, existing new-storage directories, symlink paths and network/unrecognized filesystems are refused. Created local storage/directories are retained on failure. Mocked tests cover discovery, cancellation before mutation, creation, missing directories and collisions. The published v1.0.0 tag remains unchanged.

Read the tagged README and inspect install.sh before running as root on Proxmox. Settings are editable; an explicit Nextcloud version compatible with PHP 8.3 is required. NFS export permissions and a dedicated empty data directory must be prepared by the storage administrator. External HTTPS, DNS and firewall configuration remain the administrator's responsibility.

Validation covers Bash syntax, ShellCheck, generated-source consistency, repository checks and mocked-host tests. Real Proxmox/guest/NFS deployment and platform compatibility have not yet been tested by this project. Test with disposable infrastructure before storing real data.

The installer and its SHA-256 checksum are attached. No generated credentials or private deployment information are included.
