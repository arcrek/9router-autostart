#!/usr/bin/env node
/**
 * 9router Autostart & CLI Control Panel Attach Patcher
 *
 * Fixes three upstream issues when running 9router under systemd on Linux:
 * 1. Mutual SIGKILL loop between `9router` CLI (`killAllAppProcesses`) and
 *    `systemd` (`Restart=always` / `RestartSec=5`). When port 20128 is already
 *    listening, invoking `9router` now attaches directly to the running server
 *    and opens the CLI Control Panel without killing or restarting the server.
 * 2. Immediate self-exit (`resolve(-1)`) in `src/cli/utils/input.js` when
 *    invoked without a TTY.
 * 3. `npm install --no-save` ping-pong between `better-sqlite3` and `systray2`
 *    in `~/.9router/runtime/package.json`.
 */

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
if (!pkgRoot) {
  process.exit(0);
}

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
