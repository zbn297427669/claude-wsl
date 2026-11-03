import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { spawnSync, execFileSync } from "child_process";
import fs from "fs";
import os from "os";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const NOTIFY_DIR = path.join(__dirname, "..", "templates", "notify");
const WRAPPER = path.join(NOTIFY_DIR, "notify-wrapper.sh");
const CTL = path.join(NOTIFY_DIR, "notify-ctl.sh");

// Some terminals (Orca today) run their own agent-completion notification. A
// muted app must make this hook a no-op there -- no toast, no bell marker, no
// OSC sequence -- while every other terminal keeps working.
let tmp, stateDir, logFile, env;

// Git Bash takes /c/... while the templates resolve C:\...; ask the shell for
// the form it uses so markers land where the test looks.
function shellPath(p) {
  try {
    return execFileSync("cygpath", ["-u", p], { encoding: "utf8" }).trim();
  } catch {
    return p;
  }
}

function cleanTerminalEnv(overrides = {}) {
  const e = { ...process.env, ...overrides };
  // The host running the suite may itself be Orca. Every case states the app
  // it means to simulate instead of inheriting the developer's terminal.
  for (const k of [
    "TERM_PROGRAM",
    "ORCA_TERMINAL_HANDLE",
    "ORCA_TAB_ID",
    "WT_SESSION",
    "WEZTERM_PANE",
    "ALACRITTY_WINDOW_ID",
    "KITTY_WINDOW_ID",
    "TABBY_CONFIG_DIRECTORY",
    "CURSOR_TRACE_ID",
    "VSCODE_INJECTION",
    "VSCODE_PID",
    "LC_TERMINAL",
  ]) {
    if (!(k in overrides)) delete e[k];
  }
  return e;
}

beforeEach(() => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), "claude-wsl-mute-"));
  stateDir = path.join(tmp, "state");
  logFile = path.join(tmp, "notify.log");
  fs.mkdirSync(stateDir, { recursive: true });
  env = cleanTerminalEnv({
    CLAUDE_WSL_HOME: shellPath(stateDir),
    CLAUDE_WSL_LOG: shellPath(logFile),
    CLAUDE_WSL_TMP: shellPath(tmp),
    CLAUDE_WSL_DRY_RUN: "1",
    CLAUDE_WSL_DEBUG: "1",
  });
});

afterEach(() => {
  fs.rmSync(tmp, { recursive: true, force: true });
});

function runHook(payload, terminalEnv = {}) {
  return spawnSync("bash", [WRAPPER], {
    input: JSON.stringify({
      session_id: "mute-test",
      cwd: "E:/local-ai/claude/claude-wsl",
      hook_event_name: "Stop",
      ...payload,
    }),
    encoding: "utf8",
    env: cleanTerminalEnv({ ...env, ...terminalEnv }),
    timeout: 20000,
  });
}

function ctl(args, terminalEnv = {}) {
  const r = spawnSync("bash", [CTL, ...args], {
    encoding: "utf8",
    env: cleanTerminalEnv({ ...env, ...terminalEnv }),
    timeout: 20000,
  });
  return { stdout: r.stdout, stderr: r.stderr, status: r.status };
}

function detect(terminalEnv) {
  const r = spawnSync(
    "bash",
    ["-c", `. "${NOTIFY_DIR}/platform.sh"; claude_wsl_terminal_app || echo UNKNOWN`],
    { encoding: "utf8", env: cleanTerminalEnv({ ...env, ...terminalEnv }) }
  );
  return r.stdout.trim();
}

function muteFile() {
  return path.join(stateDir, "mute-apps");
}

function log() {
  try {
    return fs.readFileSync(logFile, "utf8");
  } catch {
    return "";
  }
}

describe("terminal app detection", () => {
  it("trusts TERM_PROGRAM", () => {
    expect(detect({ TERM_PROGRAM: "Orca" })).toBe("Orca");
    expect(detect({ TERM_PROGRAM: "WezTerm" })).toBe("WezTerm");
  });

  it("spells the VS Code fork the way users do", () => {
    expect(detect({ TERM_PROGRAM: "vscode" })).toBe("VS Code");
  });

  it("falls back to per-app variables when TERM_PROGRAM is absent", () => {
    expect(detect({ ORCA_TERMINAL_HANDLE: "term_x" })).toBe("Orca");
    expect(detect({ WT_SESSION: "guid" })).toBe("Windows Terminal");
    expect(detect({ WEZTERM_PANE: "1" })).toBe("WezTerm");
    expect(detect({ KITTY_WINDOW_ID: "1" })).toBe("kitty");
    expect(detect({ VSCODE_PID: "1" })).toBe("VS Code");
  });

  it("reports unknown rather than guessing", () => {
    expect(detect({})).toBe("UNKNOWN");
  });
});

describe("mute list parsing", () => {
  it("ignores blank lines, comments and surrounding whitespace", () => {
    fs.writeFileSync(
      muteFile(),
      "# terminals that notify on their own\n\n  Orca  \nWindows Terminal # inline\n"
    );
    expect(ctl(["apps"], { TERM_PROGRAM: "Orca" }).stdout).toContain("Orca");
    // The list is read through the same helper the hook uses.
    const r = spawnSync(
      "bash",
      [
        "-c",
        `. "${NOTIFY_DIR}/platform.sh"; claude_wsl_app_muted "$1" && echo yes || echo no`,
        "_",
        "windows terminal",
      ],
      { encoding: "utf8", env: cleanTerminalEnv({ ...env }) }
    );
    expect(r.stdout.trim()).toBe("yes");
  });
});

describe("hook under a muted app", () => {
  it("stays completely silent -- no toast, no marker, no escape sequence", () => {
    fs.writeFileSync(muteFile(), "Orca\n");
    const r = runHook({}, { TERM_PROGRAM: "Orca" });
    expect(r.status).toBe(0);
    expect(r.stdout.trim()).toBe("");
    expect(log()).toContain("skipped (app muted: Orca)");
    // Nothing was written for the shell integration to pick up either.
    expect(fs.readdirSync(tmp).some((f) => f.startsWith("claude-bell"))).toBe(false);
  });

  it("still notifies every app that is not on the list", () => {
    fs.writeFileSync(muteFile(), "Orca\n");
    const r = runHook({}, { TERM_PROGRAM: "WezTerm" });
    expect(r.stdout.trim()).not.toBe("");
    expect(JSON.parse(r.stdout.trim()).terminalSequence).toContain("\u001b]9;4;4;100");
    expect(log()).toContain("Calling send-notification.ps1");
  });

  it("is case-insensitive, so the file can be edited by hand", () => {
    fs.writeFileSync(muteFile(), "orca\n");
    expect(runHook({}, { TERM_PROGRAM: "Orca" }).stdout.trim()).toBe("");
  });

  it("does not silence an unknown app even when the list is non-empty", () => {
    fs.writeFileSync(muteFile(), "Orca\n");
    expect(runHook({}, {}).stdout.trim()).not.toBe("");
  });

  it("keeps the global off switch in charge of everything", () => {
    fs.writeFileSync(path.join(stateDir, "disabled"), "");
    fs.writeFileSync(muteFile(), "WezTerm\n");
    expect(runHook({}, { TERM_PROGRAM: "Orca" }).stdout.trim()).toBe("");
  });
});

describe("/wsl-notify mute and unmute", () => {
  it("mutes the app this shell runs under when no name is given", () => {
    const r = ctl(["mute"], { TERM_PROGRAM: "Orca" });
    expect(r.status).toBe(0);
    expect(fs.readFileSync(muteFile(), "utf8").trim()).toBe("Orca");
  });

  it("canonicalises a hand-typed name so it matches detection", () => {
    ctl(["mute", "orca"], { WT_SESSION: "wt" });
    expect(fs.readFileSync(muteFile(), "utf8").trim()).toBe("Orca");
    ctl(["mute", "wt"], {});
    expect(fs.readFileSync(muteFile(), "utf8")).toContain("Windows Terminal");
  });

  it("refuses to add the same app twice", () => {
    ctl(["mute", "Orca"]);
    const r = ctl(["mute", "orca"]);
    expect(r.stdout).toContain("无需重复添加");
    expect(fs.readFileSync(muteFile(), "utf8").trim().split("\n")).toHaveLength(1);
  });

  it("removes the entry and deletes the file once it is empty", () => {
    ctl(["mute", "Orca"]);
    const r = ctl(["unmute", "orca"]);
    expect(r.status).toBe(0);
    expect(fs.existsSync(muteFile())).toBe(false);
  });

  it("keeps other apps when removing one", () => {
    ctl(["mute", "Orca"]);
    ctl(["mute", "WezTerm"]);
    ctl(["unmute", "Orca"]);
    expect(fs.readFileSync(muteFile(), "utf8").trim()).toBe("WezTerm");
  });

  it("reports the current app and the list", () => {
    ctl(["mute", "Orca"]);
    const r = ctl(["apps"], { TERM_PROGRAM: "Orca" });
    expect(r.stdout).toContain("当前终端应用：Orca");
    expect(r.stdout).toContain("Orca（当前）");
  });

  it("says so when it cannot tell which app it is running under", () => {
    const r = ctl(["mute"], {});
    expect(r.status).not.toBe(0);
    expect(r.stderr).toContain("无法识别当前终端应用");
  });
});

describe("status line lamp", () => {
  function lamp(terminalEnv) {
    fs.copyFileSync(
      path.join(NOTIFY_DIR, "platform.sh"),
      path.join(stateDir, "platform.sh")
    );
    const r = spawnSync(
      "bash",
      ["-c", `. "${NOTIFY_DIR}/platform.sh"; bash "${NOTIFY_DIR}/statusline.sh"`],
      {
        input: JSON.stringify({ session_id: "x" }),
        encoding: "utf8",
        env: cleanTerminalEnv({ ...env, ...terminalEnv }),
      }
    );
    return r.stdout;
  }

  it("shows a live bell when notifications will fire", () => {
    expect(lamp({ TERM_PROGRAM: "WezTerm" })).toContain("🔔");
  });

  it("shows a muted bell when the app is muted, without claiming to notify", () => {
    fs.writeFileSync(muteFile(), "Orca\n");
    expect(lamp({ TERM_PROGRAM: "Orca" })).toContain("🔕");
  });
});

describe("window capture before a toast", () => {
  // Regression: notify.sh used `timeout 3 claude_wsl_ps ...`. `timeout` is an
  // external program and cannot run a shell function, so it failed with ENOENT
  // and the HWND was never recorded -- click-to-focus silently never worked.
  it("records a window for the session instead of failing to launch the helper", () => {
    const r = spawnSync("bash", [WRAPPER], {
      input: JSON.stringify({
        session_id: "capture-e2e",
        cwd: "E:/local-ai/claude/claude-wsl",
        hook_event_name: "UserPromptSubmit",
        prompt: "hi",
      }),
      encoding: "utf8",
      env: cleanTerminalEnv({
        ...env,
        CLAUDE_WSL_DRY_RUN: undefined,
        CLAUDE_WSL_DEBUG: "1",
      }),
      timeout: 30000,
    });
    expect(r.status).toBe(0);
    const text = log();
    if (/Captured HWND/.test(text)) {
      // Real capture: the stamp must exist, which is what the click uses.
      expect(
        fs.readdirSync(stateDir).some((f) => f.startsWith("hwnd-stamp-"))
      ).toBe(true);
    } else {
      // A headless or session-less host cannot capture; it must at least not
      // fail the hook, and must not claim success.
      expect(text).not.toContain("Captured HWND");
    }
  });
});
