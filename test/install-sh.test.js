const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const test = require('node:test');

const repoRoot = path.resolve(__dirname, '..');
const installScript = path.join(repoRoot, 'install.sh');
const installScriptSource = fs.readFileSync(installScript, 'utf8');

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

function makePosixTarball(t, root) {
  const fixtureRoot = path.join(root, 'fixture');
  const packageRoot = path.join(fixtureRoot, 'one-test', 'bin');
  fs.mkdirSync(packageRoot, { recursive: true });
  const oneBinary = path.join(packageRoot, 'one');
  fs.writeFileSync(oneBinary, '#!/usr/bin/env sh\nprintf "fake one\\n"\n');
  fs.chmodSync(oneBinary, 0o755);

  const tarball = path.join(root, 'one-test.tar.gz');
  run('tar', ['-czf', tarball, '-C', fixtureRoot, 'one-test']);
  return tarball;
}

function makeEnv(root, extra = {}) {
  const stubDir = path.join(root, 'stubs');
  fs.mkdirSync(stubDir, { recursive: true });
  const curlStub = path.join(stubDir, 'curl');
  fs.writeFileSync(curlStub, '#!/usr/bin/env sh\necho "curl must not run in local mode" >&2\nexit 44\n');
  fs.chmodSync(curlStub, 0o755);

  const home = path.join(root, 'home');
  fs.mkdirSync(home, { recursive: true });

  return {
    HOME: home,
    SHELL: '/bin/bash',
    TERM: 'dumb',
    PATH: `${stubDir}${path.delimiter}${process.env.PATH}`,
    ...extra,
  };
}

function makeWebEnv(root, extra = {}) {
  const env = makeEnv(root);
  const stubDir = env.PATH.split(path.delimiter)[0];

  fs.writeFileSync(path.join(stubDir, 'curl'), `#!/usr/bin/env sh
set -eu
printf '%s\\n' "$*" >> "$FAKE_CURL_LOG"
out=""
last=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) last="$1"; shift ;;
  esac
done
case "$last" in
  */releases/permalink/latest)
    printf '%s' '{"tag_name":"vtest","assets":{"links":[{"name":"one-test-linux-x64.tar.gz","url":"https://example.invalid/pkg.tar.gz"}]}}'
    ;;
  https://example.invalid/pkg.tar.gz)
    cp "$FAKE_TARBALL" "$out"
    ;;
  */packages/generic/telemetry/current/otlp-token-prod)
    if [ "\${FAKE_TELEMETRY_FAIL:-}" = "1" ]; then exit 56; fi
    printf 'telemetry-token'
    ;;
  *)
    echo "unexpected curl URL: $last" >&2
    exit 45
    ;;
esac
`);
  fs.chmodSync(path.join(stubDir, 'curl'), 0o755);

  fs.writeFileSync(path.join(stubDir, 'uname'), `#!/usr/bin/env sh
case "$1" in
  -s) printf 'Linux\\n' ;;
  -m) printf 'x86_64\\n' ;;
  *) /usr/bin/uname "$@" ;;
esac
`);
  fs.chmodSync(path.join(stubDir, 'uname'), 0o755);

  fs.writeFileSync(path.join(stubDir, 'secret-tool'), `#!/usr/bin/env sh
cat > "$FAKE_SECRET_TOOL_STDIN"
printf '%s\\n' "$*" >> "$FAKE_SECRET_TOOL_LOG"
exit "\${FAKE_SECRET_TOOL_EXIT:-0}"
`);
  fs.chmodSync(path.join(stubDir, 'secret-tool'), 0o755);

  return {
    ...env,
    ONE_TOKEN: 'fake-token',
    FAKE_CURL_LOG: path.join(root, 'curl.log'),
    FAKE_SECRET_TOOL_LOG: path.join(root, 'secret-tool.log'),
    FAKE_SECRET_TOOL_STDIN: path.join(root, 'secret-tool.stdin'),
    ...extra,
  };
}

function runInstallSh(args, env, input) {
  return run('bash', args, {
    cwd: repoRoot,
    env,
    input,
  });
}

test('install.sh passes a bash syntax check', { skip: process.platform === 'win32' }, () => {
  run('bash', ['-n', installScript]);
});

test('install.sh does not reintroduce removed telemetry marker files', () => {
  assert.doesNotMatch(installScriptSource, /telemetry-notice-shown/);
  assert.doesNotMatch(installScriptSource, /telemetry-token-check/);
});

test('install.sh device flow only requests read_api GitLab scope', () => {
  assert.match(installScriptSource, /^GITLAB_SCOPES="read_api openid read_user"$/m);
  assert.doesNotMatch(installScriptSource, /^GITLAB_SCOPES="api\b/m);
});

test('install.sh requires acknowledging the GitLab user code before opening the browser', () => {
  const authStart = installScriptSource.indexOf('auth_device_flow() {');
  const authEnd = installScriptSource.indexOf('auth_pat_prompt() {');
  assert.notEqual(authStart, -1);
  assert.notEqual(authEnd, -1);
  const authDeviceFlow = installScriptSource.slice(authStart, authEnd);

  assert.match(installScriptSource, /Press Enter to open GitLab in your browser/);
  assert.match(installScriptSource, /ONE_AUTH_SKIP_BROWSER_PROMPT/);
  assert.match(authDeviceFlow, /You will need this code in the browser:/);
  assert.match(authDeviceFlow, /wait_for_browser_confirmation/);
  assert.ok(
    authDeviceFlow.indexOf('wait_for_browser_confirmation') <
      authDeviceFlow.indexOf('open_url "$verification_uri"'),
  );
});

test('install.sh local mode installs a fake package and writes PATH once', { skip: process.platform === 'win32' }, (t) => {
  const root = makeTempDir(t);
  const tarball = makePosixTarball(t, root);
  const installDir = path.join(root, 'install', '.one');
  const binDir = path.join(root, 'home', '.local', 'bin');
  const env = makeEnv(root);

  runInstallSh([installScript, tarball, '--install-dir', installDir, '--bin-dir', binDir], env);
  runInstallSh([installScript, tarball, '--install-dir', installDir, '--bin-dir', binDir], env);

  const installedBinary = path.join(installDir, 'bin', 'one');
  const binLink = path.join(binDir, 'one');
  assert.equal(fs.statSync(installedBinary).mode & 0o111, 0o111);
  assert.equal(fs.readlinkSync(binLink), installedBinary);
  assert.ok(fs.existsSync(path.join(root, 'home', '.onecli')));

  const bashrc = fs.readFileSync(path.join(root, 'home', '.bashrc'), 'utf8');
  const expectedPathLine = `export PATH="${binDir}:$PATH"`;
  assert.equal((bashrc.match(new RegExp(binDir.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'g')) || []).length, 1);
  assert.ok(bashrc.includes(expectedPathLine));
});

test('install.sh local mode does not edit rc files when bin dir is already on PATH', { skip: process.platform === 'win32' }, (t) => {
  const root = makeTempDir(t);
  const tarball = makePosixTarball(t, root);
  const installDir = path.join(root, 'install', '.one');
  const binDir = path.join(root, 'home', '.local', 'bin');
  const env = makeEnv(root);
  env.PATH = `${binDir}${path.delimiter}${env.PATH}`;

  runInstallSh([installScript, tarball, '--install-dir', installDir, '--bin-dir', binDir], env);

  assert.ok(fs.existsSync(path.join(binDir, 'one')));
  assert.equal(fs.existsSync(path.join(root, 'home', '.bashrc')), false);
});

test('install.sh writes zsh rc files when zsh users need PATH setup', { skip: process.platform === 'win32' }, (t) => {
  const root = makeTempDir(t);
  const tarball = makePosixTarball(t, root);
  const installDir = path.join(root, 'install', '.one');
  const binDir = path.join(root, 'home', '.local', 'bin');
  const env = makeEnv(root, { SHELL: '/bin/zsh' });

  runInstallSh([installScript, tarball, '--install-dir', installDir, '--bin-dir', binDir], env);

  assert.match(fs.readFileSync(path.join(root, 'home', '.zshrc'), 'utf8'), new RegExp(binDir.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.equal(fs.existsSync(path.join(root, 'home', '.bashrc')), false);
});

test('install.sh warns instead of writing fish config syntax it does not support', { skip: process.platform === 'win32' }, (t) => {
  const root = makeTempDir(t);
  const tarball = makePosixTarball(t, root);
  const installDir = path.join(root, 'install', '.one');
  const binDir = path.join(root, 'home', '.local', 'bin');
  const env = makeEnv(root, { SHELL: '/usr/bin/fish' });

  const result = runInstallSh([installScript, tarball, '--install-dir', installDir, '--bin-dir', binDir], env);

  assert.match(result.stderr, new RegExp(`${binDir.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} is not on your PATH`));
  assert.match(result.stdout, /Add this to your shell rc file:/);
  assert.equal(fs.existsSync(path.join(root, 'home', '.config', 'fish', 'config.fish')), false);
});

test('install.sh local mode still works when the script is piped to bash', { skip: process.platform === 'win32' }, (t) => {
  const root = makeTempDir(t);
  const tarball = makePosixTarball(t, root);
  const installDir = path.join(root, 'install', '.one');
  const binDir = path.join(root, 'home', '.local', 'bin');
  const env = makeEnv(root);
  env.PATH = `${binDir}${path.delimiter}${env.PATH}`;

  runInstallSh(['-s', '--', tarball, '--install-dir', installDir, '--bin-dir', binDir], env, fs.readFileSync(installScript));

  assert.ok(fs.existsSync(path.join(installDir, 'bin', 'one')));
  assert.equal(fs.readlinkSync(path.join(binDir, 'one')), path.join(installDir, 'bin', 'one'));
});

test('install.sh web mode downloads release and primes telemetry token best-effort', { skip: process.platform === 'win32' }, (t) => {
  const root = makeTempDir(t);
  const tarball = makePosixTarball(t, root);
  const installDir = path.join(root, 'install', '.one');
  const binDir = path.join(root, 'home', '.local', 'bin');
  const dataDir = path.join(root, 'data');
  const env = makeWebEnv(root, {
    FAKE_TARBALL: tarball,
    ONE_DATA_DIR: dataDir,
  });
  env.PATH = `${binDir}${path.delimiter}${env.PATH}`;

  runInstallSh([installScript, '--install-dir', installDir, '--bin-dir', binDir], env);

  assert.ok(fs.existsSync(path.join(installDir, 'bin', 'one')));
  assert.equal(fs.readlinkSync(path.join(binDir, 'one')), path.join(installDir, 'bin', 'one'));
  assert.ok(fs.existsSync(dataDir));

  const curlLog = fs.readFileSync(env.FAKE_CURL_LOG, 'utf8');
  assert.match(curlLog, /releases\/permalink\/latest/);
  assert.match(curlLog, /https:\/\/example\.invalid\/pkg\.tar\.gz/);
  assert.match(curlLog, /packages\/generic\/telemetry\/current\/otlp-token-prod/);

  assert.equal(fs.readFileSync(env.FAKE_SECRET_TOOL_STDIN, 'utf8'), 'telemetry-token');
  assert.match(fs.readFileSync(env.FAKE_SECRET_TOOL_LOG, 'utf8'), /account telemetry-prod/);
});

test('install.sh web mode succeeds when telemetry token fetch fails', { skip: process.platform === 'win32' }, (t) => {
  const root = makeTempDir(t);
  const tarball = makePosixTarball(t, root);
  const installDir = path.join(root, 'install', '.one');
  const binDir = path.join(root, 'home', '.local', 'bin');
  const dataDir = path.join(root, 'data');
  const env = makeWebEnv(root, {
    FAKE_TARBALL: tarball,
    FAKE_TELEMETRY_FAIL: '1',
    ONE_DATA_DIR: dataDir,
  });
  env.PATH = `${binDir}${path.delimiter}${env.PATH}`;

  runInstallSh([installScript, '--install-dir', installDir, '--bin-dir', binDir], env);

  assert.ok(fs.existsSync(path.join(installDir, 'bin', 'one')));
  assert.ok(fs.existsSync(dataDir));
  assert.equal(fs.existsSync(env.FAKE_SECRET_TOOL_STDIN), false);
});
