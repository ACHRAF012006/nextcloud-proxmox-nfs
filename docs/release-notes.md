Nextcloud VM Installer for Proxmox VE with NFS Storage.

This release provides a self-contained interactive installer, standard NFSv3/NFSv4 client configuration, root-only host credential storage, validation/safety checks, MIT licensing and public contribution/security documentation.

Read the tagged README and inspect install.sh before running as root on Proxmox. Settings are editable; an explicit Nextcloud version compatible with PHP 8.3 is required. NFS export permissions and a dedicated empty data directory must be prepared by the storage administrator. External HTTPS, DNS and firewall configuration remain the administrator's responsibility.

Validation covers Bash syntax, ShellCheck, generated-source consistency, repository checks and mocked-host tests. Real Proxmox/guest/NFS deployment and platform compatibility have not yet been tested by this project. Test with disposable infrastructure before storing real data.

The installer and its SHA-256 checksum are attached. No generated credentials or private deployment information are included.
