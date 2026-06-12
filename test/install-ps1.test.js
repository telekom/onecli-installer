const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const repoRoot = path.resolve(__dirname, '..');
const installPs1 = path.join(repoRoot, 'install.ps1');
const scriptBytes = fs.readFileSync(installPs1);
const script = scriptBytes.toString('utf8');

function makeTempDir(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'one-installer-test-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    encoding: 'utf8',
    ...options,
    env: {
      ...process.env,
      ...options.env,
    },
  });
  if (result.status !== 0) {
    throw new Error(
      [
        `${command} ${args.join(' ')} failed with status ${result.status}`,
        'stdout:',
        result.stdout,
        'stderr:',
        result.stderr,
      ].join('\n'),
    );
  }
  return result;
}

function makeWindowsTarball(t, root) {
  const fixtureRoot = path.join(root, 'fixture');
  const packageBin = path.join(fixtureRoot, 'one-test', 'bin');
  fs.mkdirSync(packageBin, { recursive: true });
  fs.writeFileSync(path.join(packageBin, 'one.cmd'), '@echo off\r\necho fake one\r\n');
  fs.writeFileSync(path.join(packageBin, 'one'), '#!/bin/sh\necho fake one\n');

  const tarball = path.join(root, 'one-test-win32-x64.tar.gz');
  run('tar', ['-czf', tarball, '-C', fixtureRoot, 'one-test']);
  return tarball;
}

function listTree(root) {
  if (!fs.existsSync(root)) return '<missing>';
  const lines = [];
  function walk(dir, rel) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const childRel = path.join(rel, entry.name);
      lines.push(`${entry.isDirectory() ? 'd' : 'f'} ${childRel}`);
      if (entry.isDirectory()) walk(path.join(dir, entry.name), childRel);
    }
  }
  walk(root, '');
  return lines.join('\n') || '<empty>';
}

test('install.ps1 keeps the Windows shim BOM-free', () => {
  assert.match(script, /\$shimBody = "@echo off`r`n`"\$oneLauncher`" %\*`r`n"/);
  assert.match(script, /\[System\.IO\.File\]::WriteAllText\(\$shimPath, \$shimBody, \(New-Object System\.Text\.UTF8Encoding\(\$false\)\)\)/);
  assert.equal((script.match(/New-Object System\.Text\.UTF8Encoding\(\$false\)/g) || []).length, 2);
  assert.match(script, /Set-ItemProperty -Path \$shimPath -Name IsReadOnly/);
  assert.match(script, /Set-ItemProperty -Path \$shShimPath -Name IsReadOnly/);
});

test('install.ps1 keeps consistent Windows line endings', () => {
  assert.doesNotMatch(script.replace(/\r\n/g, ''), /\n/);
});

test('install.ps1 avoids duplicate user PATH entries', () => {
  assert.match(script, /\$persistedEntries = @\(\)/);
  assert.match(script, /if \(\$userPath\) \{ \$persistedEntries = \$userPath -split ';' \| Where-Object \{ \$_ \} \}/);
  assert.match(script, /\$sessionEntries = @\(\)/);
  assert.match(script, /if \(\$env:Path\) \{ \$sessionEntries = \$env:Path -split ';' \| Where-Object \{ \$_ \} \}/);
  assert.match(script, /\$alreadyOnPath = \(\$persistedEntries -contains \$BinDir\) -or \(\$sessionEntries -contains \$BinDir\)/);
  assert.match(script, /\[Environment\]::SetEnvironmentVariable\('Path', \$newPath, 'User'\)/);
});

test('install.ps1 creates a POSIX-like shim with a WSL guard', () => {
  assert.match(script, /\$shShimPath = Join-Path \$BinDir 'one'/);
  assert.match(script, /if \(\$oneLauncher -like '\*\.cmd'\) \{\s+\$execCmd = "'\$oneLauncherUnix'"/);
  assert.match(script, /node '\$oneLauncherUnix'/);
  assert.match(script, /grep -qiE 'microsoft\|wsl' \/proc\/version/);
  assert.match(script, /WSL detected - please install the Linux version\./);
  assert.match(script, /"exec \$execCmd `"`\$@`""/);
  assert.doesNotMatch(script, /\$shShimBody = @"/);
  assert.doesNotMatch(script, /^"@/m);
});

test('install.ps1 keeps telemetry priming best-effort and creates the data dir', () => {
  assert.doesNotMatch(script, /telemetry-token-check/);
  assert.match(script, /packages\/generic\/telemetry\/current\/otlp-token-prod/);
  assert.match(script, /\$credTarget = "de\.telekom\.one:telemetry-prod"/);
  assert.match(script, /cmdkey \/generic:\$credTarget \/user:telemetry-prod \/pass:\$telemetryToken/);
  assert.match(script, /New-Item -ItemType Directory -Path \$OneDataDir -Force/);
  assert.match(script, /catch \{\s+<# best-effort/);
});

test('install.ps1 forwards HTTPS proxy settings to web requests', () => {
  assert.match(script, /function Add-ProxyArgs\(\[hashtable\]\$RequestArgs\)/);
  assert.match(script, /\$RequestArgs\['Proxy'\] = \$env:HTTPS_PROXY/);
  assert.match(script, /\$RequestArgs\['ProxyUseDefaultCredentials'\] = \$true/);
  assert.ok((script.match(/Add-ProxyArgs/g) || []).length >= 6);
});

test('install.ps1 requires acknowledging the GitLab user code before opening the browser', () => {
  const authStart = script.indexOf('function Invoke-DeviceFlow');
  const authEnd = script.indexOf('function Read-PatPrompt');
  assert.notEqual(authStart, -1);
  assert.notEqual(authEnd, -1);
  const authDeviceFlow = script.slice(authStart, authEnd);

  assert.match(authDeviceFlow, /You will need this code in the browser:/);
  assert.match(authDeviceFlow, /Press Enter to open GitLab in your browser/);
  assert.match(authDeviceFlow, /ONE_AUTH_SKIP_BROWSER_PROMPT/);
  assert.ok(
    authDeviceFlow.indexOf('Press Enter to open GitLab in your browser') <
      authDeviceFlow.indexOf('Start-Process $resp.verification_uri'),
  );
});

test('install.ps1 restores ErrorActionPreference after installer errors', () => {
  assert.match(script, /\$PreviousErrorActionPreference = \$ErrorActionPreference/);
  assert.match(script, /\$ErrorActionPreference = 'Stop'/);
  assert.match(script, /trap \{\s+Write-Host "ERROR \$\(\$_\.Exception\.Message\)"/);
  assert.match(script, /trap \{[\s\S]+return\s+\}/);
  assert.match(script, /\$ErrorActionPreference = \$PreviousErrorActionPreference\s*$/);
});

test('install.ps1 local mode installs a fake package on Windows', { skip: process.platform !== 'win32' }, (t) => {
  const root = makeTempDir(t);
  const tarball = makeWindowsTarball(t, root);
  const home = path.join(root, 'home');
  const installDir = path.join(home, '.one');
  const binDir = path.join(home, '.local', 'bin');
  const dataDir = path.join(home, 'AppData', 'Local', 'onecli');
  fs.mkdirSync(binDir, { recursive: true });

  const powershell = process.env.POWERSHELL_EXE || 'powershell.exe';
  const result = run(powershell, [
    '-NoProfile',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    installPs1,
    '-Tarball',
    tarball,
    '-InstallDir',
    installDir,
    '-BinDir',
    binDir,
  ], {
    cwd: repoRoot,
    env: {
      USERPROFILE: home,
      LOCALAPPDATA: path.join(home, 'AppData', 'Local'),
      ONE_DATA_DIR: dataDir,
      HTTPS_PROXY: '',
      HTTP_PROXY: '',
      Path: `${binDir};${process.env.Path || process.env.PATH}`,
    },
  });
  const output = `${result.stdout}\n${result.stderr}`;
  if (/\bERROR\b/.test(output)) {
    throw new Error(`installer reported failure\nstdout:\n${result.stdout}\nstderr:\n${result.stderr}`);
  }

  const launcher = path.join(installDir, 'bin', 'one.cmd');
  const shim = path.join(binDir, 'one.cmd');
  const shShim = path.join(binDir, 'one');
  const details = [
    `stdout:\n${result.stdout}`,
    `stderr:\n${result.stderr}`,
    `home tree:\n${listTree(home)}`,
  ].join('\n\n');
  assert.ok(fs.existsSync(launcher), details);
  assert.ok(fs.existsSync(shim), details);
  assert.ok(fs.existsSync(shShim), details);
  assert.ok(fs.existsSync(dataDir), details);

  const shimBytes = fs.readFileSync(shim);
  assert.notDeepEqual([...shimBytes.subarray(0, 3)], [0xef, 0xbb, 0xbf]);
  assert.match(shimBytes.toString('utf8'), /^@echo off\r\n/);
  assert.match(fs.readFileSync(shShim, 'utf8'), /WSL detected - please install the Linux version\./);
});
