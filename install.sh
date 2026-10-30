#!/usr/bin/env bash
# ==============================================================================
# 9router Autostart & CLI Control Panel Attach Installer (Linux / systemd)
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

PORT="${NINEROUTER_PORT:-20128}"
DATA_DIR="${NINEROUTER_DATA_DIR:-$HOME/.9router}"

echo -e "${YELLOW}>>> Starting 9router Autostart & CLI Attach Patch Installer...${NC}"

# 1. Locate Node.js and 9router package directory
if [ -s "$HOME/.nvm/nvm.sh" ]; then
  # shellcheck disable=SC1090
  . "$HOME/.nvm/nvm.sh" 2>/dev/null || true
fi

NODE_BIN="$(command -v node || true)"
if [ -z "$NODE_BIN" ] && [ -d "$HOME/.nvm/versions/node" ]; then
  LATEST_NODE_DIR="$(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -V | tail -n 1)"
  if [ -n "$LATEST_NODE_DIR" ] && [ -x "$HOME/.nvm/versions/node/$LATEST_NODE_DIR/bin/node" ]; then
    NODE_BIN="$HOME/.nvm/versions/node/$LATEST_NODE_DIR/bin/node"
    export PATH="$HOME/.nvm/versions/node/$LATEST_NODE_DIR/bin:$PATH"
  fi
fi

if [ -z "$NODE_BIN" ]; then
  echo -e "${RED}[!] Node.js binary not found. Please install Node.js >= 18 first.${NC}"
  exit 1
fi
NODE_BIN_DIR="$(dirname "$NODE_BIN")"

NPM_ROOT="$(npm root -g 2>/dev/null || echo "${NODE_BIN_DIR%/bin}/lib/node_modules")"
PKG_ROOT="$NPM_ROOT/9router"

if [ ! -f "$PKG_ROOT/cli.js" ]; then
  echo -e "${RED}[!] 9router global package not found at $PKG_ROOT/cli.js${NC}"
  echo -e "${YELLOW}    Install it first with: npm i -g 9router@latest${NC}"
  exit 1
fi

echo -e "${GREEN}[+] Found Node.js: $NODE_BIN${NC}"
echo -e "${GREEN}[+] Found 9router: $PKG_ROOT${NC}"

# 2. Fix ~/.9router/runtime/package.json so better-sqlite3 & systray2 coexist
mkdir -p "$DATA_DIR/runtime"
cat << 'EOF' > "$DATA_DIR/runtime/package.json"
{
  "name": "9router-runtime",
  "version": "1.0.0",
  "private": true,
  "description": "User-writable runtime deps for 9router (better-sqlite3 native binary)",
  "dependencies": {
    "better-sqlite3": "13.0.3",
    "sql.js": "^1.14.1",
    "systray2": "2.1.4"
  }
}
EOF

if [ ! -d "$DATA_DIR/runtime/node_modules/better-sqlite3" ] || [ ! -d "$DATA_DIR/runtime/node_modules/systray2" ]; then
  echo -e "${YELLOW}[*] Installing runtime dependencies (better-sqlite3, sql.js, systray2)...${NC}"
  (cd "$DATA_DIR/runtime" && npm install --no-audit --no-fund --ignore-scripts >/dev/null 2>&1 || true)
fi
echo -e "${GREEN}[✓] Runtime dependencies pinned in $DATA_DIR/runtime/package.json${NC}"

# 3. Install idempotent patch script at ~/.9router/apply-autostart-patch.js
cat << 'EOF' > "$DATA_DIR/apply-autostart-patch.js"
#!/usr/bin/env node
const fs = require("fs");
const path = require("path");
const os = require("os");
const { execSync } = require("child_process");

function resolvePkgRoot() {
  if (process.env.NINEROUTER_PKG_ROOT && fs.existsSync(process.env.NINEROUTER_PKG_ROOT)) {
    return process.env.NINEROUTER_PKG_ROOT;
  }
  try {
    const npmRoot = execSync("npm root -g", { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }).trim();
    const candidate = path.join(npmRoot, "9router");
    if (fs.existsSync(path.join(candidate, "cli.js"))) return candidate;
  } catch {}
  const nvmDir = path.join(os.homedir(), ".nvm", "versions", "node");
  if (fs.existsSync(nvmDir)) {
    const versions = fs.readdirSync(nvmDir).sort();
    for (let i = versions.length - 1; i >= 0; i--) {
      const candidate = path.join(nvmDir, versions[i], "lib", "node_modules", "9router");
      if (fs.existsSync(path.join(candidate, "cli.js"))) return candidate;
    }
  }
  const globalCandidates = [
    "/usr/local/lib/node_modules/9router",
    "/usr/lib/node_modules/9router",
  ];
  for (const c of globalCandidates) {
    if (fs.existsSync(path.join(c, "cli.js"))) return c;
  }
  return null;
}

const pkgRoot = resolvePkgRoot();
if (!pkgRoot) process.exit(0);

const cliPath = path.join(pkgRoot, "cli.js");
const inputPath = path.join(pkgRoot, "src", "cli", "utils", "input.js");
const runtimePkgPath = path.join(os.homedir(), ".9router", "runtime", "package.json");

// 1. Ensure runtime/package.json keeps both better-sqlite3 and systray2
try {
  if (fs.existsSync(runtimePkgPath)) {
    const pkg = JSON.parse(fs.readFileSync(runtimePkgPath, "utf8"));
    pkg.dependencies = pkg.dependencies || {};
    let changed = false;
    if (!pkg.dependencies["better-sqlite3"]) { pkg.dependencies["better-sqlite3"] = "13.0.3"; changed = true; }
    if (!pkg.dependencies["sql.js"]) { pkg.dependencies["sql.js"] = "^1.14.1"; changed = true; }
    if (!pkg.dependencies["systray2"]) { pkg.dependencies["systray2"] = "2.1.4"; changed = true; }
    if (changed) fs.writeFileSync(runtimePkgPath, JSON.stringify(pkg, null, 2) + "\n");
  }
} catch {}

// 2. Patch input.js so selectMenu renders the CLI Control Panel and stays alive
try {
  if (fs.existsSync(inputPath)) {
    let inputSrc = fs.readFileSync(inputPath, "utf8");
    if (!inputSrc.includes("keepAliveTimer")) {
      inputSrc = inputSrc.replace(
`function primeRawOnce() {
  if (rawPrimed || !process.stdin.isTTY) return;
  try {
    readline.emitKeypressEvents(process.stdin);
    process.stdin.setRawMode(true);
    process.stdin.setEncoding("utf8");
    process.stdin.resume();
    rawPrimed = true;
  } catch {}
}`,
`function primeRawOnce() {
  if (rawPrimed) return;
  try {
    readline.emitKeypressEvents(process.stdin);
    if (process.stdin.isTTY) process.stdin.setRawMode(true);
    process.stdin.setEncoding("utf8");
    process.stdin.resume();
    rawPrimed = true;
  } catch {}
}`
      );
      inputSrc = inputSrc.replace(
        `    primeRawOnce();\n    if (!process.stdin.isTTY) { resolve(-1); return; }`,
        `    primeRawOnce();\n    const keepAliveTimer = !process.stdin.isTTY ? setInterval(() => {}, 60000) : null;`
      );
      inputSrc = inputSrc.replace(
`    const cleanup = () => {
      if (!isActive) return;
      isActive = false;
      process.stdin.removeListener("keypress", onKeypress);
    };`,
`    const cleanup = () => {
      if (!isActive) return;
      isActive = false;
      if (keepAliveTimer) clearInterval(keepAliveTimer);
      process.stdin.removeListener("keypress", onKeypress);
    };`
      );
      fs.writeFileSync(inputPath, inputSrc);
    }
  }
} catch {}

// 3. Patch cli.js so invoking 9router when server is already running attaches to the CLI Control Panel without killing/restarting 9router
try {
  if (fs.existsSync(cliPath)) {
    let cliSrc = fs.readFileSync(cliPath, "utf8");
    cliSrc = cliSrc.replace(/async function attachControlPanel\(updatePromise\) \{[\s\S]*?\n\}\n\nfunction startServer\(updatePromise\) \{/, "function startServer(updatePromise) {");

    const targetBlock = `// Start server immediately; run update check in parallel (not on the critical path).
const updatePromise = checkForUpdate();
killAllAppProcesses(port)
  .then(() => killProcessOnPort(port))
  .then(() => startServer(updatePromise));`;

    const replacementBlock = `// Start server immediately; run update check in parallel (not on the critical path).
const updatePromise = checkForUpdate();
waitServerReady(port, { timeoutMs: 800, intervalMs: 100 }).then((alreadyRunning) => {
  if (alreadyRunning && process.env.SYSTEMD_DAEMON !== "1" && !args.includes("--tray") && !args.includes("-t")) {
    return attachControlPanel(updatePromise);
  }
  return killAllAppProcesses(port)
    .then(() => killProcessOnPort(port))
    .then(() => startServer(updatePromise));
});`;

    const attachFn = `async function attachControlPanel(updatePromise) {
  const displayHost = getDisplayHost();
  const url = \`http://\${displayHost}:\${port}/dashboard\`;
  const latestVersion = await Promise.resolve(updatePromise);

  let isShuttingDown = false;
  const onExitSignal = () => {
    if (isShuttingDown) return;
    isShuttingDown = true;
    console.log("\\nExiting...");
    setTimeout(() => process.exit(0), 50);
  };
  process.on("SIGINT", onExitSignal);
  process.on("SIGTERM", onExitSignal);
  process.on("SIGHUP", onExitSignal);

  try {
    while (true) {
      const choice = await showInterfaceMenu(latestVersion);

      if (choice === "update") {
        isShuttingDown = true;
        const { clearScreen } = require("./src/cli/utils/display");
        clearScreen();
        console.log(\`\\n⬆  Update v\${pkg.version} → v\${latestVersion}\\n\`);
        console.log(\`Run this after exit:\\n\`);
        console.log(\`   \\x1b[33m\${INSTALL_CMD_LATEST}\\x1b[0m\\n\`);
        setTimeout(() => process.exit(0), 100);
        return;
      } else if (choice === "web") {
        openBrowser(url);
        const { pause } = require("./src/cli/utils/input");
        await pause("\\nPress Enter to go back to menu...");
      } else if (choice === "terminal") {
        const { startTerminalUI } = require("./src/cli/terminalUI");
        await startTerminalUI(port);
      } else if (choice === "hide") {
        const { clearScreen } = require("./src/cli/utils/display");
        clearScreen();
        console.log(\`🔔 9Router is now running in background\`);
        console.log(\`   Server: http://\${displayHost}:\${port}\`);
        console.log(\`\\n💡 You can close this terminal. Right-click tray icon to quit.\\n\`);
        process.exit(0);
        return;
      } else if (choice === "exit") {
        isShuttingDown = true;
        console.log("\\nExiting...");
        setTimeout(() => process.exit(0), 50);
        return;
      }
    }
  } catch (err) {
    console.error("Error:", err.message);
    process.exit(1);
  }
}

function startServer(updatePromise) {`;

    if (cliSrc.includes(targetBlock)) {
      cliSrc = cliSrc.replace(targetBlock, replacementBlock);
    }
    if (!cliSrc.includes("async function attachControlPanel")) {
      cliSrc = cliSrc.replace("function startServer(updatePromise) {", attachFn);
    }
    fs.writeFileSync(cliPath, cliSrc);
  }
} catch {}
EOF
chmod +x "$DATA_DIR/apply-autostart-patch.js"
NINEROUTER_PKG_ROOT="$PKG_ROOT" "$NODE_BIN" "$DATA_DIR/apply-autostart-patch.js"
echo -e "${GREEN}[✓] Applied CLI Control Panel attach patch to $PKG_ROOT${NC}"

# 4. Create wrapper scripts so `9router` works across all shells & survives `npm i -g 9router@latest`
mkdir -p "$HOME/.local/bin" /usr/local/bin 2>/dev/null || true
WRAPPER_CONTENT="#!/usr/bin/env bash
export PATH=\"$NODE_BIN_DIR:\$PATH\"
\"$NODE_BIN\" \"$DATA_DIR/apply-autostart-patch.js\" 2>/dev/null || true
exec \"$NODE_BIN\" \"$PKG_ROOT/cli.js\" \"\$@\"
"
echo "$WRAPPER_CONTENT" > "$HOME/.local/bin/9router"
chmod +x "$HOME/.local/bin/9router"
if [ -w /usr/local/bin ]; then
  echo "$WRAPPER_CONTENT" > /usr/local/bin/9router
  chmod +x /usr/local/bin/9router
fi
echo -e "${GREEN}[✓] Installed 9router CLI wrapper (${HOME}/.local/bin/9router)${NC}"

# 5. Configure systemd user service & linger (without killing/restarting if already running!)
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"

cat << EOF > "$SYSTEMD_USER_DIR/9router.service"
[Unit]
Description=9router gateway (OpenAI-compatible API on :${PORT})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=$HOME
Environment=HOME=$HOME
Environment=SYSTEMD_DAEMON=1
Environment=PATH=$NODE_BIN_DIR:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=NODE_OPTIONS=--dns-result-order=ipv4first
ExecStartPre=$NODE_BIN $DATA_DIR/apply-autostart-patch.js
ExecStart=$NODE_BIN $PKG_ROOT/cli.js --tray --no-browser --skip-update -p ${PORT}
Restart=always
RestartSec=5
KillMode=mixed
KillSignal=SIGTERM
TimeoutStopSec=20

[Install]
WantedBy=default.target
EOF

loginctl enable-linger "$(whoami)" 2>/dev/null || true
systemctl --user daemon-reload
systemctl --user enable 9router.service >/dev/null 2>&1 || true

if systemctl --user is-active --quiet 9router.service 2>/dev/null; then
  echo -e "${GREEN}[✓] 9router.service is already active — reloaded unit definition without restarting.${NC}"
elif ss -ltn 2>/dev/null | grep -q ":${PORT} "; then
  echo -e "${GREEN}[✓] Port ${PORT} is already listening — enabled 9router.service for next boot without interrupting running instance.${NC}"
else
  echo -e "${YELLOW}[*] Starting 9router.service...${NC}"
  systemctl --user start 9router.service
  echo -e "${GREEN}[✓] 9router.service started.${NC}"
fi

echo -e "${GREEN}======================================================================${NC}"
echo -e "${GREEN}>>> 9router Autostart & CLI Control Panel patch installed successfully!${NC}"
echo -e "${GREEN}======================================================================${NC}"
