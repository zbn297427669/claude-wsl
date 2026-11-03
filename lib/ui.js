import chalk from "chalk";
import ora from "ora";
import boxen from "boxen";
import figlet from "figlet";
import gradient from "gradient-string";
import cliProgress from "cli-progress";
import readline from "readline";

// Beautiful gradient themes - fst.wtf inspired (red theme)
export const brandGradient = gradient(["#dc2626", "#ef4444", "#f87171"]); // Red theme
export const successGradient = gradient(["#dc2626", "#ef4444"]); // Red theme
export const infoGradient = gradient(["#dc2626", "#ef4444"]); // Red accent

// Beautiful spinner with custom text
export function createSpinner(text, type = "dots") {
  // Check if running in test environment or spinners should be suppressed
  const isTest = process.env.NODE_ENV === "test" || process.env.CI === "true" || process.env.SUPPRESS_SPINNER === "true";

  if (isTest) {
    // Return a mock spinner that doesn't output anything
    return {
      start: () => {},
      succeed: () => {},
      fail: () => {},
      warn: () => {},
      info: () => {},
      stop: () => {},
      text: text,
    };
  }

  const spinner = ora({
    text: chalk.red(text),
    spinner: type,
    color: "red",
  });

  // Override succeed/fail/warn/info to use red color instead of default colors
  spinner.succeed = (text) => {
    spinner.stopAndPersist({
      symbol: chalk.red('[✓]'),
      text: chalk.red(text)
    });
    return spinner;
  };

  spinner.fail = (text) => {
    spinner.stopAndPersist({
      symbol: chalk.red('[✗]'),
      text: chalk.red(text)
    });
    return spinner;
  };

  spinner.warn = (text) => {
    spinner.stopAndPersist({
      symbol: chalk.red('[!]'),
      text: chalk.red(text)
    });
    return spinner;
  };

  spinner.info = (text) => {
    spinner.stopAndPersist({
      symbol: chalk.red('[i]'),
      text: chalk.red(text)
    });
    return spinner;
  };

  return spinner;
}

export function showSuccess(message) {
  console.log(chalk.red.bold(`[✓] ${message}`));
}

export function showError(message) {
  console.log(chalk.red.bold(`[✗] ${message}`));
}

export function showWarning(message) {
  console.log(chalk.red.bold(`[!] ${message}`));
}

export function showInfo(message) {
  console.log(chalk.red(`[i] ${message}`));
}

// Beautiful header with ASCII art
export async function showHeader(title = "Claude WSL", subtitle = "") {
  return new Promise((resolve) => {
    figlet.text(
      title,
      {
        font: "ANSI Shadow",
        horizontalLayout: "fitted",
        verticalLayout: "default",
        width: 80,
        whitespaceBreak: true,
      },
      function (err, data) {
        if (!err && data) {
          console.log("\n" + chalk.hex("#dc2626")(data));
          if (subtitle) {
            console.log(chalk.white(subtitle));
          }
        }
        resolve();
      }
    );
  });
}

export function showBox(title, content, _type = "info") {
  const boxOptions = {
    padding: 1,
    margin: 1,
    borderStyle: "round",
    borderColor: "red",
    title: title,
    titleAlignment: "center",
  };

  console.log(boxen(content, boxOptions));
}

export function showSection(title) {
  console.log("\n" + chalk.bold(infoGradient(`▸ ${title}`)));
  console.log(chalk.dim("═".repeat(50)));
}

// Progress bar for file operations
export function createProgressBar(title) {
  const bar = new cliProgress.SingleBar(
    {
      format:
        chalk.red("{title}") +
        " |" +
        chalk.red("{bar}") +
        "| {percentage}% | {value}/{total} Files",
      barCompleteChar: "\u2588",
      barIncompleteChar: "\u2591",
      hideCursor: true,
    },
    cliProgress.Presets.shades_classic
  );

  return {
    bar,
    start: (total) => bar.start(total, 0, { title }),
    increment: () => bar.increment(),
    stop: () => bar.stop(),
  };
}

// Unified progress bar with current task display
export function createUnifiedProgress() {
  let currentTask = "";
  let currentValue = 0;
  let totalValue = 0;
  let started = false;

  const renderProgress = () => {
    const percentage = Math.floor((currentValue / totalValue) * 100);
    const barSize = 40;
    const completeSize = Math.floor((currentValue / totalValue) * barSize);
    const incompleteSize = barSize - completeSize;

    const barString =
      chalk.red("\u2588".repeat(completeSize)) +
      chalk.gray("\u2591".repeat(incompleteSize));

    if (started) {
      // Move cursor up 2 lines and clear them
      readline.moveCursor(process.stdout, 0, -2);
      readline.clearScreenDown(process.stdout);
    }

    // Write task name and progress bar
    process.stdout.write(chalk.red(currentTask) + '\n');
    process.stdout.write('|' + barString + '| ' + percentage + '%\n');

    started = true;
  };

  return {
    start: (total) => {
      totalValue = total;
      currentValue = 0;
      started = false;
      // Hide cursor
      process.stdout.write('\x1B[?25l');
    },
    setTask: (task) => {
      currentTask = task;
      renderProgress();
    },
    increment: () => {
      currentValue++;
      renderProgress();
    },
    stop: () => {
      // Show cursor again
      process.stdout.write('\x1B[?25h');
      process.stdout.write('\n');
    },
  };
}
