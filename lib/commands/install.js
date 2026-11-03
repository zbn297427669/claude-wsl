import fs from "fs";
import path from "path";
import { execSync } from "child_process";
import os from "os";
import { fileURLToPath } from "url";
import chalk from "chalk";
import {
  showHeader,
  showSection,
  showError,
  showWarning,
  showInfo,
  showSuccess,
  showBox,
  createSpinner,
} from "../ui.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

// Claude Code runs a `.sh` hook through Git Bash on Windows, and the command
// string goes through the shell before bash sees it -- so a backslash in the
// path is eaten as an escape. `C:\Users\me\h.sh` becomes
// `bash C:Usersmeh.sh` and fails with exit 127. Forward slashes survive.
function toShellPath(p) {
  return p.replace(/\\/g, "/");
}

export async function install() {
  await showHeader("Claude WSL", "Visual notifications and tab indicators for Claude Code");

  // Use process.env.HOME in tests, os.homedir() in production
  const homeDir = process.env.NODE_ENV === 'test' ? process.env.HOME : os.homedir();
  const installDir = path.join(homeDir, ".local/share/claude-wsl");
  const claudeSettingsPath = path.join(homeDir, ".claude/settings.json");
  const bashrcPath = path.join(homeDir, ".bashrc");

  showSection("Installation Steps");

  // Step 1: Create installation directory
  const step1 = createSpinner("Creating installation directory...");
  step1.start();

  try {
    if (!fs.existsSync(installDir)) {
      fs.mkdirSync(installDir, { recursive: true });
    }
    step1.succeed("Installation directory created");
  } catch (error) {
    step1.fail("Failed to create installation directory");
    showError(`Error: ${error.message}`);
    process.exit(1);
  }

  // Step 2: Copy notify scripts
  const step2 = createSpinner("Copying notification scripts...");
  step2.start();

  try {
    const templatesDir = path.join(__dirname, "../../templates/notify");
    const files = fs.readdirSync(templatesDir);

    for (const file of files) {
      const srcPath = path.join(templatesDir, file);
      const destPath = path.join(installDir, file);
      fs.copyFileSync(srcPath, destPath);

      // Make shell scripts executable
      if (file.endsWith(".sh")) {
        fs.chmodSync(destPath, 0o755);
      }
    }

    step2.succeed(`Copied ${files.length} notification scripts`);
  } catch (error) {
    step2.fail("Failed to copy notification scripts");
    showError(`Error: ${error.message}`);
    process.exit(1);
  }

  // Register claude-wsl:// so toast clicks can raise the originating window.
  // wslpath exists only under WSL; cygpath is the Git Bash equivalent.
  try {
    const protocolScript = path.join(installDir, "install-protocol.ps1");
    if (process.env.CLAUDE_WSL_SKIP_PROTOCOL === "1") {
      // Tests set this: registering a URL handler writes to HKCU, and a unit
      // test has no business changing the user's registry.
      showInfo("Toast click protocol registration skipped (CLAUDE_WSL_SKIP_PROTOCOL=1)");
    } else if (fs.existsSync(protocolScript)) {
      let winPath = "";
      for (const conv of ["wslpath -w", "cygpath -w"]) {
        try {
          winPath = execSync(`${conv} "${protocolScript}"`, {
            encoding: "utf8",
            stdio: ["ignore", "pipe", "ignore"],
          }).trim();
          if (winPath) break;
        } catch {
          // try the next converter
        }
      }
      if (winPath) {
        // No -ExecutionPolicy Bypass: installed copies sit on local NTFS with
        // no Zone.Identifier, so the default RemoteSigned policy runs them.
        execSync(`powershell.exe -NoProfile -File "${winPath}"`, {
          stdio: "ignore",
          timeout: 15000,
        });
      } else {
        showWarning("Toast click protocol not registered: no path converter found");
      }
    }
  } catch (error) {
    showWarning(`Toast click protocol not registered: ${error.message}`);
  }

  // Slash command: /wsl-notify on|off in Claude Code
  try {
    const commandSrc = path.join(__dirname, "../../templates/commands/wsl-notify.md");
    const commandDestDir = path.join(homeDir, ".claude/commands");
    if (fs.existsSync(commandSrc)) {
      fs.mkdirSync(commandDestDir, { recursive: true });
      fs.copyFileSync(commandSrc, path.join(commandDestDir, "wsl-notify.md"));
    }
    const binDir = path.join(homeDir, ".local/bin");
    const ctlSrc = path.join(installDir, "notify-ctl.sh");
    const ctlLink = path.join(binDir, "wsl-notify");
    if (fs.existsSync(ctlSrc)) {
      fs.mkdirSync(binDir, { recursive: true });
      try {
        fs.unlinkSync(ctlLink);
      } catch {
        // ignore if missing
      }
      try {
        fs.symlinkSync(ctlSrc, ctlLink);
      } catch (symlinkError) {
        // Git Bash on Windows cannot create symlinks without Developer Mode
        // (EPERM). A tiny forwarder script achieves the same thing.
        if (symlinkError.code === "EPERM" || symlinkError.code === "EACCES") {
          fs.writeFileSync(
            ctlLink,
            `#!/bin/sh\nexec "${toShellPath(ctlSrc)}" "$@"\n`
          );
          fs.chmodSync(ctlLink, 0o755);
        } else {
          throw symlinkError;
        }
      }
    }
  } catch (error) {
    showWarning(`Slash command install skipped: ${error.message}`);
  }

  // Step 3: Update Claude settings.json
  const step3 = createSpinner("Configuring Claude Code hooks...");
  step3.start();

  try {
    const claudeDir = path.dirname(claudeSettingsPath);
    if (!fs.existsSync(claudeDir)) {
      fs.mkdirSync(claudeDir, { recursive: true });
    }

    let settings = {};
    if (fs.existsSync(claudeSettingsPath)) {
      settings = JSON.parse(fs.readFileSync(claudeSettingsPath, "utf8"));
    }

    const wrapperPath = path.join(installDir, "notify-wrapper.sh");
    const hookConfig = {
      type: "command",
      // Forward slashes: the command string is handed to Git Bash on Windows,
      // where backslashes are escape characters (see toShellPath above).
      command: toShellPath(wrapperPath)
    };

    // Initialize hooks if not present
    if (!settings.hooks) {
      settings.hooks = {};
    }

    // Add hooks for all events. SessionEnd clears the indicator when the user
    // leaves, so a stale orange circle never outlives the session.
    const events = ["SessionStart", "UserPromptSubmit", "Notification", "Stop", "SessionEnd"];
    for (const event of events) {
      if (!settings.hooks[event]) {
        settings.hooks[event] = [];
      }

      // Compare on the normalized form: an earlier install may have written
      // either separator, and we must not add the hook twice.
      const hookExists = settings.hooks[event].some(h =>
        h.hooks && h.hooks.some(hook =>
          typeof hook.command === "string" &&
          toShellPath(hook.command).toLowerCase() === toShellPath(wrapperPath).toLowerCase()
        )
      );

      if (!hookExists) {
        settings.hooks[event].push({
          hooks: [hookConfig]
        });
      }
    }

    // Status-line lamp: wrap an existing command; do not nest this wrapper.
    const statuslinePath = path.join(installDir, "statusline.sh");
    const innerPath = path.join(installDir, "statusline-inner");
    const existingCmd =
      settings.statusLine && typeof settings.statusLine.command === "string"
        ? settings.statusLine.command.trim()
        : "";
    const alreadyWrapped =
      toShellPath(existingCmd) === toShellPath(statuslinePath) ||
      existingCmd.endsWith("/claude-wsl/statusline.sh");
    if (existingCmd && !alreadyWrapped) {
      // Keep the user's own status line and run it underneath ours. The shell
      // script reads this file (one command per line).
      fs.writeFileSync(innerPath, `${existingCmd}\n`);
    }
    settings.statusLine = {
      ...(settings.statusLine || {}),
      type: "command",
      command: toShellPath(statuslinePath),
    };

    fs.writeFileSync(claudeSettingsPath, JSON.stringify(settings, null, 2));
    step3.succeed("Claude Code hooks configured");
  } catch (error) {
    step3.fail("Failed to configure Claude hooks");
    showError(`Error: ${error.message}`);
    process.exit(1);
  }

  // Step 4: Add the shell integration to the file this host actually reads.
  //
  // WSL's interactive login shell reads ~/.bashrc. Git Bash on Windows splits
  // it: `bash -lc` reads ~/.profile, `bash -ic` reads ~/.bashrc, and the
  // non-interactive `bash -c` Claude Code uses reads neither. ~/.profile is the
  // file that at least reaches login shells, so that is where we write on
  // Windows -- .bashrc would be silently dead there.
  const shellProfilePath = process.platform === "win32"
    ? path.join(homeDir, ".profile")
    : bashrcPath;
  const shellProfileName = path.basename(shellProfilePath);

  const step4 = createSpinner(`Adding shell integration to ${shellProfileName}...`);
  step4.start();

  // Track if this is an update (integration already exists)
  let isUpdate = false;

  try {
    let bashrc = "";
    if (fs.existsSync(shellProfilePath)) {
      bashrc = fs.readFileSync(shellProfilePath, "utf8");
    }

    const integrationMarker = "# @claude-wsl-start";
    const endMarker = "# @claude-wsl-end";

    // Remove existing integration if present (to re-add at the end for priority)
    if (bashrc.includes(integrationMarker)) {
      isUpdate = true;
      const startIdx = bashrc.indexOf(integrationMarker);
      const endIdx = bashrc.indexOf(endMarker, startIdx);
      if (endIdx !== -1) {
        // Remove old integration
        bashrc = bashrc.slice(0, startIdx) + bashrc.slice(endIdx + endMarker.length);
        // Clean up any extra newlines
        bashrc = bashrc.replace(/\n{3,}/g, '\n\n').trimEnd();
      }
    }

    // Add integration at the very end for highest priority
    const integration = `

${integrationMarker}
# Claude WSL Integration
# Loaded at the end to ensure highest priority for title overrides
# Error handling: Never let this block prevent shell from starting

_NOTIFIER_DIR="${installDir}"

# Comprehensive error handling - silent failures only
if [ -n "$_NOTIFIER_DIR" ] 2>/dev/null; then
    # Check directory exists and is accessible
    if [ -d "$_NOTIFIER_DIR" ] 2>/dev/null && [ -r "$_NOTIFIER_DIR" ] 2>/dev/null; then
        # Source config with error handling (non-critical)
        if [ -f "$_NOTIFIER_DIR/config.sh" ] 2>/dev/null && [ -r "$_NOTIFIER_DIR/config.sh" ] 2>/dev/null; then
            # shellcheck disable=SC1090
            source "$_NOTIFIER_DIR/config.sh" 2>/dev/null || true
        fi

        # Source main wrapper with error handling (critical for functionality)
        if [ -f "$_NOTIFIER_DIR/claude-notify-wrapper.sh" ] 2>/dev/null && [ -r "$_NOTIFIER_DIR/claude-notify-wrapper.sh" ] 2>/dev/null; then
            # shellcheck disable=SC1090
            source "$_NOTIFIER_DIR/claude-notify-wrapper.sh" 2>/dev/null || true
        fi
    fi
fi

# Always cleanup, even if errors occurred
unset _NOTIFIER_DIR 2>/dev/null || true
${endMarker}
`;

    bashrc += integration;
    fs.writeFileSync(shellProfilePath, bashrc);
    step4.succeed(`Shell integration added to ${shellProfileName} (at end for priority)`);
  } catch (error) {
    step4.fail(`Failed to update ${shellProfileName}`);
    showError(`Error: ${error.message}`);
    process.exit(1);
  }

  // Step 5: Test the installation
  showSection("Testing Installation");

  const step6 = createSpinner("Verifying files...");
  step6.start();
  const wrapperPath = path.join(installDir, "claude-notify-wrapper.sh");
  const notifyPath = path.join(installDir, "notify.sh");

  if (fs.existsSync(wrapperPath) && fs.existsSync(notifyPath)) {
    step6.succeed("All required files are in place");
  } else {
    step6.warn("Some files may be missing");
  }

  // Installation complete
  showSection("Installation Complete!");

  // Load the integration into this shell so the next terminal inherits it.
  const step5 = createSpinner("Loading shell integration...");
  step5.start();

  try {
    execSync(`bash -c "source '${toShellPath(shellProfilePath)}'"`, { stdio: 'ignore' });
    step5.succeed("Shell integration loaded");
  } catch (error) {
    // Non-critical error - integration will load on next shell start
    step5.info("Shell integration will load on next terminal start");
  }

  // Different messages for updates vs fresh installs
  const nextSteps = isUpdate
    ? `${chalk.bold("What's New:")}

${chalk.red("✓")} Hook scripts updated
${chalk.red("✓")} Shell integration updated
${chalk.red("✓")} Notifications active immediately in Claude Code

${chalk.bold("Next:")} Integration is ready. Start using Claude Code!`
    : `${chalk.bold("You're all set!")}

${chalk.red("✓")} Visual notifications enabled
${chalk.red("✓")} Tab indicators configured
${chalk.red("✓")} Shell integration loaded

${chalk.bold("What you'll see:")}
- ${chalk.white("Orange circle")} when Claude Code is ready
- ${chalk.white("Orange spinner")} while Claude is thinking
- ${chalk.white("Bell icon 🔔")} when response is ready
- ${chalk.white("Toast notification")} on completion`;

  showBox(
    isUpdate ? "Update Complete" : "Setup Complete",
    `${nextSteps}

${chalk.bold("Installation:")}
${chalk.dim(`  ${installDir}/`)}

${chalk.bold("Need help?")}
${chalk.red("https://github.com/fullstacktard/claude-wsl#readme")}`,
    "info"
  );
}
