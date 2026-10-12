# Contributing

Contributions should work for arbitrary users and standard NFS servers. Do not add private network defaults, personal domains, credentials, SSH keys, tokens, generated state, unredacted logs or vendor-specific permission changes. Use reserved example domains and documentation IP ranges in tests/documentation. Follow the MIT license and describe any new dependencies.

Open an issue for bugs or reusable feature proposals, or submit a focused pull request. Security vulnerabilities should be reported privately as described in SECURITY.md. Never request a user's credentials or full unredacted configuration.

Edit files under `src/`, then run `node scripts/build.mjs`; commit both source and generated `install.sh`. Keep validation/parsing logic separate from host/guest operations. Do not bypass validation, automatically destroy existing resources, change NFS-server settings, weaken permissions, or silently consume an existing data directory. Defaults must stay editable. CI cannot require real Proxmox infrastructure.

Run the README development checks with Bash, Python 3, Node.js and ShellCheck. Add focused tests for consequential parsing/safety changes. Describe what was checked, and distinguish mocked checks from actual deployment tests. Test deployment changes using a disposable VM and an empty dedicated NFS directory; report sanitized Proxmox, OS, Nextcloud, storage software and protocol versions, reboot behavior and NFS-unavailable behavior. Do not label a platform tested without evidence.

## Releasing

1. Set `VERSION=X.Y.Z` in `src/main.sh`, add a matching `CHANGELOG.md` entry and update versioned README links and `docs/release-notes.md`.
2. Build `install.sh`, review its full diff, and run all CI checks. Update tests that explicitly check the CLI version. Review the staged files for secrets; automated pattern checks are only a baseline.
3. Commit the reviewed version and create/push a `vX.Y.Z` tag on that exact commit. Do not move published release tags; publish a patch version instead.
4. The tag workflow checks version agreement, shell syntax, ShellCheck, repository structure, generated output and mocked safety tests before publishing the installer and SHA-256 asset.
5. Verify the workflow and raw tagged download, and document deployment-test results honestly. A stable installer URL identifies a release; it does not pin mutable Ubuntu package repositories or certify hardware/storage combinations.

The GitHub release workflow uses GitHub's short-lived workflow token with write access only in the publishing job. No personal GitHub credential belongs in repository files or workflow configuration.
