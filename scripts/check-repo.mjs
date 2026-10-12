import { readFileSync, readdirSync, statSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const required = ['README.md', 'LICENSE', 'CONTRIBUTING.md', 'SECURITY.md', 'CHANGELOG.md',
  '.gitignore', '.gitattributes', '.github/workflows/ci.yml', '.github/workflows/release.yml',
  '.github/ISSUE_TEMPLATE/bug_report.yml', '.github/ISSUE_TEMPLATE/feature_request.yml', 'install.sh'];
for (const file of required) if (!statSync(join(root, file)).isFile()) throw new Error(`Missing ${file}`);
const files = [];
function walk(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (['.git', 'node_modules'].includes(entry.name)) continue;
    const full = join(dir, entry.name);
    if (entry.isSymbolicLink()) throw new Error(`Unexpected symlink: ${full}`);
    if (entry.isDirectory()) walk(full); else files.push(full);
  }
}
walk(root);
const prohibited = [
  /-----BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY-----/,
  /\bgh[pousr]_[A-Za-z0-9]{30,}\b/,
  /\bgithub_pat_[A-Za-z0-9_]{30,}\b/,
  /\bAKIA[A-Z0-9]{16}\b/,
];
for (const full of files) {
  const name = relative(root, full).replaceAll('\\', '/');
  if (/(^|\/)(\.env(?:\..*)?|credentials[^/]*|ssh_key[^/]*|id_rsa[^/]*|id_ed25519[^/]*|.*\.(pem|key|log|img|qcow2|iso))$/.test(name)) {
    throw new Error(`Private/generated artifact in repository: ${name}`);
  }
  const text = readFileSync(full, 'utf8');
  for (const pattern of prohibited) if (pattern.test(text)) throw new Error(`Possible secret in ${name}`);
  if (name.endsWith('.sh') && text.includes('\r')) throw new Error(`Shell script must use LF: ${name}`);
  // Source must not contain private deployment addresses or TrueNAS-specific management.
  if (name.startsWith('src/') || name === 'install.sh') {
    if (/\b(?:10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(?:1[6-9]|2\d|3[01])\.\d+\.\d+)\b/.test(text)) {
      throw new Error(`Private deployment address hardcoded in ${name}`);
    }
    if (/chmod\s+(?:-[a-zA-Z]+\s+)*777\b/.test(text)) throw new Error(`Unsafe permission workaround in ${name}`);
  }
}
const version = readFileSync(join(root, 'src/main.sh'), 'utf8').match(/^VERSION=(\d+\.\d+\.\d+)$/m)?.[1];
if (!version || !readFileSync(join(root, 'CHANGELOG.md'), 'utf8').includes(`[${version}]`)) throw new Error('Version/changelog mismatch');
if (!readFileSync(join(root, 'LICENSE'), 'utf8').startsWith('MIT License')) throw new Error('Expected MIT license');
if (!readFileSync(join(root, 'README.md'), 'utf8').includes(`/${'v' + version}/install.sh`)) throw new Error('Missing stable install command');
console.log(`Repository validation passed (${files.length} files, version ${version}).`);
