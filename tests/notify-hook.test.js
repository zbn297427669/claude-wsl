import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { spawnSync, execFileSync } from "child_process";
import fs from "fs";
import os from "os";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const NOTIFY_DIR = path.join(__dirname, "..", "templates", "notify");
const WRAPPER = path.join(NOTIFY_DIR, "notify-wrapper.sh");

// Every test gets its own scratch dir, state dir and log file. Nothing writes
// to the shared /tmp that other Claude sessions use for their bell markers,
// and no test can pop a real toast.
let tmp, stateDir, logFile, env;

// Git Bash understands `C:\...` but its own paths are `/c/...`, and the two do
// not compare equal. Ask the shell for the form it uses so a marker written by
// notify.sh lands where the test looks for it.
function shellPath(p) {
  try {
    return execFileSync("cygpath", ["-u", p], { encoding: "utf8" }).trim();
  } catch {
    return p;
  }
}

beforeEach(() => {
  tmp = fs.mkdtempSync(path.join(os.tmpdir(), "claude-wsl-test-"));
  stateDir = path.join(tmp, "state");
  logFile = path.join(tmp, "notify.log");
  fs.mkdirSync(stateDir, { recursive: true });
  env = {
    ...process.env,
    CLAUDE_WSL_HOME: shellPath(stateDir),
    CLAUDE_WSL_LOG: shellPath(logFile),
    CLAUDE_WSL_TMP: shellPath(tmp),
    CLAUDE_WSL_DRY_RUN: "1",
    CLAUDE_WSL_DEBUG: "1",
  };
  // Keep the host's terminal-detection vars out of the result.
  delete env.ELYTERMINAL_SESSION;
  delete env.ELY_TERMINAL;
  delete env.WT_SESSION;
});

afterEach(() => {
  fs.rmSync(tmp, { recursive: true, force: true });
});

function runHook(payload, { via = WRAPPER } = {}) {
  const input = typeof payload === "string" ? payload : JSON.stringify(payload);
  const r = spawnSync("bash", [via], {
    input,
    encoding: "utf8",
    env,
    timeout: 20000,
  });
  return { stdout: r.stdout, stderr: r.stderr, status: r.status };
}

function stopPayload(overrides = {}) {
  return {
    session_id: "test-session",
    cwd: "E:/local-ai/claude/claude-wsl",
    hook_event_name: "Stop",
    ...overrides,
  };
}

function log() {
  try {
    return fs.readFileSync(logFile, "utf8");
  } catch {
    return "";
  }
}

describe("hook output contract", () => {
  it("always exits 0 so Claude Code never reports a hook error", () => {
    for (const p of [
      stopPayload(),
      stopPayload({ hook_event_name: "UserPromptSubmit" }),
      "not json at all",
      "",
    ]) {
      const r = runHook(p);
      expect(r.status).toBe(0);
    }
  });

  it("prints exactly one valid JSON object with a terminalSequence", () => {
    const r = runHook(stopPayload());
    const lines = r.stdout.trim().split("\n").filter(Boolean);
    expect(lines).toHaveLength(1);
    const parsed = JSON.parse(lines[0]);
    expect(parsed.terminalSequence).toBe("\u001b]9;4;4;100\u0007\u001b]0;claude-wsl\u0007");
  });

  it("forwards only the terminalSequence line, never diagnostic noise", () => {
    // notify.sh logs freely; none of it may reach Claude Code's output parser.
    const r = runHook(stopPayload());
    expect(r.stdout).not.toContain("===");
    expect(r.stdout).not.toContain("WARNING");
    expect(r.stdout).not.toContain("Tracing");
    for (const line of r.stdout.trim().split("\n").filter(Boolean)) {
      expect(() => JSON.parse(line)).not.toThrow();
    }
  });

  it("still writes the debug log, so a failure is diagnosable", () => {
    runHook(stopPayload());
    const text = log();
    expect(text).toContain("notify.sh called");
    expect(text).toContain("Folder name: claude-wsl");
  });
});

describe("event mapping", () => {
  it.each([
    ["UserPromptSubmit", "\u001b]9;4;3;0"],
    ["Stop", "\u001b]9;4;4;100"],
    ["SessionStart", "\u001b]9;4;4;100"],
    ["Notification", "\u001b]9;4;4;100"],
  ])("emits the right indicator for %s", (event, expected) => {
    const r = runHook(stopPayload({ hook_event_name: event }));
    expect(JSON.parse(r.stdout.trim()).terminalSequence).toContain(expected);
  });

  it("clears the indicator when the session ends normally", () => {
    const r = runHook(
      stopPayload({ hook_event_name: "SessionEnd", reason: "clear" })
    );
    expect(JSON.parse(r.stdout.trim()).terminalSequence).toContain("\u001b]9;4;0;0");
  });

  it("shows an error indicator when the session ends abnormally", () => {
    const r = runHook(
      stopPayload({ hook_event_name: "SessionEnd", reason: "other" })
    );
    expect(JSON.parse(r.stdout.trim()).terminalSequence).toContain("\u001b]9;4;2;100");
  });
});

describe("idle_prompt suppression", () => {
  // Claude fires Notification/idle_prompt about a minute after Stop. That is a
  // second notification for the same turn, so it must stay silent.
  it("skips a Notification carrying notification_type=idle_prompt", () => {
    const r = runHook(
      stopPayload({
        hook_event_name: "Notification",
        notification_type: "idle_prompt",
      })
    );
    expect(r.stdout.trim()).toBe("");
  });

  it("skips a Notification whose message is the idle wait text", () => {
    const r = runHook(
      stopPayload({
        hook_event_name: "Notification",
        message: "Claude is waiting for your input",
      })
    );
    expect(r.stdout.trim()).toBe("");
  });

  it("still notifies for a real permission prompt", () => {
    const r = runHook(
      stopPayload({
        hook_event_name: "Notification",
        notification_type: "permission_prompt",
        message: "Allow Bash?",
      })
    );
    expect(r.stdout.trim()).not.toBe("");
  });
});

describe("runtime toggle", () => {
  it("goes silent when the disabled flag exists", () => {
    fs.writeFileSync(path.join(stateDir, "disabled"), "");
    const r = runHook(stopPayload());
    expect(r.status).toBe(0);
    expect(r.stdout.trim()).toBe("");
  });

  it("resumes once the flag is removed", () => {
    const flag = path.join(stateDir, "disabled");
    fs.writeFileSync(flag, "");
    runHook(stopPayload());
    fs.rmSync(flag);
    const r = runHook(stopPayload());
    expect(r.stdout.trim()).not.toBe("");
  });
});

describe("duplicate toast suppression", () => {
  it("skips a second toast inside the 8 second window", () => {
    runHook(stopPayload());
    runHook(stopPayload());
    const text = log();
    // Exactly one toast is attempted; the second run logs the skip instead.
    expect(text.match(/Calling send-notification/g)).toHaveLength(1);
    expect(text).toMatch(/Skipping duplicate toast/);
  });
});

describe("notification sound", () => {
  it("passes the configured sound to the toast", () => {
    fs.writeFileSync(path.join(stateDir, "sound"), "Mail\n");
    runHook(stopPayload());
    // Dry-run records the command line instead of launching PowerShell.
    const dry = log();
    expect(dry).toContain("Calling send-notification.ps1");
  });

  it("defaults to Default when no sound file exists", () => {
    runHook(stopPayload());
    expect(log()).toContain("Calling send-notification.ps1");
  });
});

describe("pty-less host", () => {
  it("falls back to terminalSequence when no PTY can be found", () => {
    // On a host without /dev/pts the PTY write cannot happen, so the JSON reply
    // has to carry the sequence instead.
    const r = runHook(stopPayload());
    expect(log()).toMatch(
      /MSYS host: no PTY to find|Process tree trace failed|Could not find target PTY|No indicator path/
    );
    expect(r.stdout.trim()).not.toBe("");
    expect(JSON.parse(r.stdout.trim()).terminalSequence).toContain("\u001b]");
  });

  it("never emits a PTY write when there is no PTY", () => {
    // A regression here would print an escape sequence into the hook's own
    // stdout, where Claude Code would show it as text.
    const r = runHook(stopPayload());
    expect(log()).toMatch(/MSYS host: no PTY to find|No indicator path/);
    for (const line of r.stdout.trim().split("\n").filter(Boolean)) {
      expect(line.startsWith("{")).toBe(true);
    }
  });
});
