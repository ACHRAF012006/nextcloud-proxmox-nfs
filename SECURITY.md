# Security policy

Use the newest reviewed release. The project currently maintains the latest 1.x installer release; it does not provide a commercial support SLA. A release tag is a distribution version, not proof of a production deployment test. Supported upstream Nextcloud/OS versions and updates remain the administrator's responsibility.

## Reporting vulnerabilities

Use this repository's GitHub **Security → Report a vulnerability** private reporting feature. Include a minimal reproduction and impact with all credentials, keys, tokens, deployment addresses, domains and private details removed. Do not open a public issue for an undisclosed vulnerability. If private reporting is unavailable, open a public issue asking the maintainer to enable it, without publishing vulnerability details.

## Remote execution

The pattern below executes remote code immediately with the calling user's privileges:

```bash
bash -c "$(curl -fsSL URL)"
```

Prefer downloading, reviewing and running a tagged version:

```bash
curl -fsSL URL -o install.sh
less install.sh
bash install.sh
```

Replace `URL` with a reviewed tagged installer URL from README. Review the full self-contained file and repository/release history. Pin a reviewed commit if you require immutable content. SHA-256 assets and upstream HTTPS-fetched checksums detect mismatches but do not establish an independent trust source; this release does not verify upstream GPG signatures.

## Secret handling and boundaries

Generated SSH private keys and the saved Nextcloud admin password remain under `/root/nextcloud-vm-installer/<VM ID>/` on the user's Proxmox host with directory mode 0700/file mode 0600. No installer credentials are uploaded to GitHub, logged to public services or embedded in cloud-init snippets. Necessary application secrets are sent to the guest over guest-agent stdin and briefly used during installation. Nextcloud stores the admin password hash and its database secret in the guest's restricted application configuration. Public-key authentication data goes into the guest/cloud-init drive. Root/host/guest access and backups are therefore sensitive security boundaries.

Do not commit credentials, local deployment files, logs, SSH key material or private addresses/domains. `.gitignore` covers common generated/local artifacts and CI checks for common token/private-key signatures. These safeguards cannot recognize every secret; inspect staged changes and all history before publishing. If a secret is accidentally published, revoke/rotate it immediately; deleting a later copy does not remove it from history or forks.

The installer changes a new guest and creates reviewed host resources. Optional automatic snippet setup adds a new non-shared directory storage restricted to the current node only after confirmation. It refuses occupied IDs, existing new-storage directories, symlink paths and network/unrecognized filesystems; existing storage definitions are not modified. The new storage and its directories are retained on failure for inspection. It never administers the NFS server. A prepared, empty, dedicated data directory, restrictive permissions and a successful `www-data` write test are required; permission failures stop installation. Storage administrators must correct identity mapping/ACL/export policy without broad access or disabling root squash. Standard NFS using AUTH_SYS trusts client identities and does not encrypt traffic; use a trusted isolated storage network or independently secured transport. Kerberos-secured NFS credential provisioning is outside this release's scope.

HTTP is a backend/initial validation endpoint. Configure HTTPS termination and restrict direct guest access before using real accounts/data. The installer does not provision public TLS, alter firewalls or harden every aspect of the server. Trusted proxies must be narrowly specified to avoid client-address spoofing. NFS outages can block hard-mounted I/O; systemd dependencies prevent local fallback but do not provide availability or monitoring.
