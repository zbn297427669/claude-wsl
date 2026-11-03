import { describe, it, expect } from "vitest";
import { execFileSync } from "child_process";
import path from "path";
import { fileURLToPath } from "url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const NOTIFY_DIR = path.join(__dirname, "..", "templates", "notify");

// Run a bash snippet with the templates sourced. Each test gets a clean shell,
// so nothing leaks between cases. Extra args become $1, $2, ... in the snippet.
function bash(snippet, { env = {}, args = [] } = {}) {
  return execFileSync(
    "bash",
    [
      "-c",
      `set -u; . "${NOTIFY_DIR}/platform.sh"; . "${NOTIFY_DIR}/indicator.sh"; ${snippet}`,
      "_",
      ...args,
    ],
    { encoding: "utf8", env: { ...process.env, ...env } }
  );
}

describe("indicator state", () => {
  // OSC 9;4 is <9>;<4>;<state>;<percent>. A state-only value like "4;100" is
  // malformed and terminals silently drop it, which is how this shipped once.
  it.each([
    ["UserPromptSubmit", "", "9;4;3;0"],
    ["Stop", "", "9;4;4;100"],
    ["SessionStart", "", "9;4;4;100"],
    ["SessionEnd", "other", "9;4;2;100"],
    ["SessionEnd", "clear", "9;4;0;0"],
    ["SessionEnd", "logout", "9;4;0;0"],
    ["Unknown", "", "9;4;4;100"],
  ])("maps %s (reason=%s) to a full OSC 9;4 body", (event, reason, expected) => {
    const out = bash('claude_wsl_indicator_state "$1" "$2"', {
      args: [event, reason],
    }).trim();
    expect(out).toBe(expected);
  });
});

describe("terminalSequence JSON", () => {
  it("keeps escape bytes as literal JSON escapes, not real control characters", () => {
    const out = bash('claude_wsl_indicator_emit "9;4;4;100"');
    // A raw ESC would make this invalid JSON, which Claude Code rejects.
    expect(out).toBe('{"terminalSequence":"\\u001b]9;4;4;100\\u0007"}\n');
    // Only the trailing newline is allowed to be a control character.
    expect(out.trimEnd()).not.toMatch(/[\u0000-\u001f]/);
    expect(() => JSON.parse(out)).not.toThrow();
    expect(JSON.parse(out).terminalSequence).toBe("\u001b]9;4;4;100\u0007");
  });

  it("emits indicator and title in one line", () => {
    const out = bash('claude_wsl_emit_indicator_and_title "9;4;3;0" "my-project"');
    const parsed = JSON.parse(out);
    expect(parsed.terminalSequence).toBe(
      "\u001b]9;4;3;0\u0007\u001b]0;my-project\u0007"
    );
  });

  it("drops control characters from a title so the OSC cannot end early", () => {
    const out = bash(
      "claude_wsl_emit_indicator_and_title '9;4;3;0' \"$(printf 'a\\007b')\""
    );
    const seq = JSON.parse(out).terminalSequence;
    // The only BELs are the two we put there deliberately.
    expect(seq.match(/\u0007/g)).toHaveLength(2);
    expect(seq).toContain("ab");
  });
});

describe("terminal capability", () => {
  it("skips OSC 9;4 on a terminal that redirects it to a private protocol", () => {
    const out = bash("claude_wsl_indicator_unsupported && echo skip || echo send", {
      env: { ELYTERMINAL_SESSION: "abc" },
    });
    expect(out.trim()).toBe("skip");
  });

  it("sends OSC 9;4 on an ordinary terminal", () => {
    const out = bash("claude_wsl_indicator_unsupported && echo skip || echo send", {
      env: { ELYTERMINAL_SESSION: "", ELY_TERMINAL: "", TERM_PROGRAM: "WezTerm" },
    });
    expect(out.trim()).toBe("send");
  });
});

describe("platform helpers", () => {
  it("converts a POSIX path to a Windows path", () => {
    const out = bash('claude_wsl_winpath "/c/Users" || echo NONE');
    expect(out.trim()).toMatch(/^[A-Za-z]:\\/);
  });

  it("reports MSYS on Git Bash", () => {
    // The suite only runs on the host that invoked it; assert it agrees with
    // uname rather than hard-coding the host OS.
    // Ask the same bash the tests use: native Windows has no `uname` on PATH,
    // only Git Bash's MSYS one.
    const uname = execFileSync("bash", ["-c", "uname -s"], {
      encoding: "utf8",
    }).trim();
    const isMsys = /^(MINGW|MSYS|CYGWIN)/.test(uname);
    const out = bash("claude_wsl_is_msys && echo yes || echo no");
    expect(out.trim()).toBe(isMsys ? "yes" : "no");
  });

  it("prints the PowerShell command in dry-run instead of launching it", () => {
    const out = bash(
      `claude_wsl_ps "${NOTIFY_DIR}/send-notification.ps1" -Title t -Message m`,
      { env: { CLAUDE_WSL_DRY_RUN: "1" } }
    );
    expect(out).toContain("dry-run:");
    expect(out).toContain("send-notification.ps1");
    expect(out).toContain("-Message m");
  });

  it("resolves the script to a Windows path before the time limit", () => {
    // Regression: `timeout 3 claude_wsl_ps ...` passed a shell function name to
    // an external program, which failed with ENOENT, so the helper never ran.
    // Whatever runs under timeout has to be a real executable and a path the
    // Windows side can open.
    const out = bash(
      `claude_wsl_ps_timeout 3 "${NOTIFY_DIR}/capture-hwnd.ps1" -SessionId x`,
      { env: { CLAUDE_WSL_DRY_RUN: "1" } }
    );
    expect(out).toMatch(/^dry-run: timeout 3 powershell\.exe -File .*capture-hwnd\.ps1/m);
    expect(out).not.toContain("claude_wsl_ps -");
  });
});
