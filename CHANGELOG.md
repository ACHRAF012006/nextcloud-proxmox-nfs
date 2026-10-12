# Changelog

## [1.0.0] - 2026-10-12

- Initial community installer for a new Ubuntu 24.04 LTS VM on Proxmox VE, with Nextcloud data on standard NFSv3/NFSv4 storage.
- Interactive detected/validated storage, bridge, VLAN, VM resources, DHCP/static IPv4, NFS paths/protocol, hostname, proxy trust and timezone; explicit upstream Nextcloud version.
- Self-contained installer with version/help, creation summary, occupied-ID protection, root-only host credentials and no NFS-server administration.
- Dedicated empty data directory and identity/permission checks; NFS-dependent Apache and background jobs.
- MIT license, security/contribution guidance, issue forms, offline CI checks and tagged release workflow.
- Deployment status: no actual Proxmox/NFS platform deployment test has yet been performed by this project.
