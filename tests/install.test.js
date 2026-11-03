import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { spawnSync } from "child_process";
import fs from "fs";
import os from "os";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");

// A throwaway HOME so the install never touches the real one. NODE_ENV=test is
// what makes install.js prefer process.env.HOME over os.homedir().
let home;

function install() {
  return spawnSync("node", ["bin/claude-wsl-integration.js", "install"], {
    cwd: ROOT,
    encoding: "utf8",
    env: {
      ...process.env,
      HOME: home,
      USERPROFILE: home,
      NODE_ENV: "test",
      SUPPRESS_SPINNER: "true",
      CI: "true",
      // Each install otherwise runs PowerShell to register the toast-click
      // protocol, which costs seconds per case and writes to HKCU -- not
      // something a unit test should do. Paths are still exercised.
      CLAUDE_WSL_SKIP_PROTOCOL: "1",
    },
    timeout: 60000,
  });
}

function settings() {
  const p = path.join(home, ".claude", "settings.json");
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

function hookCommands(s) {
  const out = [];
  for (const [event, groups] of Object.entries(s.hooks || {})) {
    for (const g of groups) {
      for (const h of g.hooks || []) {
        out.push({ event, command: h.command });
      }
    }
  }
  return out;
}

beforeEach(() => {
  home = fs.mkdtempSync(path.join(os.tmpdir(), "claude-wsl-home-"));
  fs.mkdirSync(path.join(home, ".claude"), { recursive: true });
  // A pre-existing status line, which the installer must wrap rather than drop.
  fs.writeFileSync(
    path.join(home, ".claude", "settings.json"),
    JSON.stringify({
      theme: "dark",
      statusLine: { type: "command", command: "E:/somewhere/my-statusline.sh" },
    })
  );
});

afterEach(() => {
  fs.rmSync(home, { recursive: true, force: true });
});

describe("installer paths", () => {
  it("writes only forward-slash paths into settings.json", () => {
    // Claude Code hands a .sh hook command to Git Bash on Windows. A backslash
    // is consumed as an escape there, so `C:\...\notify-wrapper.sh` becomes
    // `bash C:...notify-wrapper.sh` and dies with exit 127.
    const r = install();
    expect(r.status).toBe(0);
    for (const { command } of hookCommands(settings())) {
      expect(command).not.toContain("\\");
    }
    expect(settings().statusLine.command).not.toContain("\\");
  });

  it("registers a hook for every lifecycle event it needs", () => {
    install();
    const events = hookCommands(settings()).map((h) => h.event).sort();
    expect(events).toEqual(
      ["Notification", "SessionEnd", "SessionStart", "Stop", "UserPromptSubmit"].sort()
    );
  });

  it("keeps an existing status line by saving it as the inner command", () => {
    install();
    const inner = fs.readFileSync(
      path.join(home, ".local", "share", "claude-wsl", "statusline-inner"),
      "utf8"
    );
    expect(inner.trim()).toBe("E:/somewhere/my-statusline.sh");
    expect(settings().statusLine.command).toMatch(/claude-wsl\/statusline\.sh$/);
  });

  it("preserves unrelated settings", () => {
    install();
    expect(settings().theme).toBe("dark");
  });
});

describe("installer idempotency", () => {
  it("does not add the same hook twice", () => {
    install();
    const first = hookCommands(settings()).length;
    install();
    expect(hookCommands(settings()).length).toBe(first);
  });

  it("recognises an already-wrapped status line instead of nesting it", () => {
    install();
    install();
    // Second run must not treat our own wrapper as the user's inner command.
    const inner = fs.readFileSync(
      path.join(home, ".local", "share", "claude-wsl", "statusline-inner"),
      "utf8"
    );
    expect(inner).not.toMatch(/claude-wsl\/statusline\.sh/);
  });
});

describe("installed files", () => {
  it("copies every runtime helper the hook sources", () => {
    install();
    const dir = path.join(home, ".local", "share", "claude-wsl");
    for (const f of [
      "notify.sh",
      "notify-wrapper.sh",
      "platform.sh",
      "indicator.sh",
      "send-notification.ps1",
      "capture-hwnd.ps1",
      "focus-session.ps1",
      "statusline.sh",
    ]) {
      expect(fs.existsSync(path.join(dir, f)), `${f} missing`).toBe(true);
    }
  });

  it("copies a shell script the host shell can actually run", () => {
    // Not a permission-bit assertion: on Windows the drives mount with
    // noacl,posix=0, so every file reports mode 0 to Node and every file is
    // executable to bash. What matters is that the copy is valid bash.
    install();
    const script = path.join(home, ".local", "share", "claude-wsl", "notify.sh");
    const r = spawnSync("bash", ["-n", script], { encoding: "utf8" });
    expect(r.stderr).toBe("");
    expect(r.status).toBe(0);
  });

  it("installs a wsl-notify command even without symlink permission", () => {
    // Git Bash on Windows returns EPERM for fs.symlinkSync unless Developer
    // Mode is on, so the installer falls back to a small forwarder script.
    install();
    const ctl = path.join(home, ".local", "bin", "wsl-notify");
    expect(fs.existsSync(ctl)).toBe(true);
    expect(fs.readFileSync(ctl, "utf8")).toContain("notify-ctl.sh");
  });

  it("adds the shell integration to the file this host reads", () => {
    install();
    const isWindows = process.platform === "win32";
    const target = path.join(home, isWindows ? ".profile" : ".bashrc");
    expect(fs.existsSync(target), `${target} missing`).toBe(true);
    expect(fs.readFileSync(target, "utf8")).toContain("# @claude-wsl-start");
  });
});
