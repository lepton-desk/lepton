// What `create-lepton-app` decides before it runs anything: the project name, the
// arguments for `lepton new`, and what the machine still lacks. Pure functions, so the
// tests run them as they are.

/** Flags of `lepton new` that take a value, so their values are not read as the name. */
const valued = new Set([
  "-t",
  "--template",
  "--target",
  "--plugins",
  "--package-manager",
  "--identifier",
  "--directory",
  "--width",
  "--height",
]);

/**
 * Splits the command line: the first word that is neither a flag nor a flag's value is
 * the project name; `--no-install` is this package's own; everything else goes to
 * `lepton new` unchanged.
 *
 * @param {readonly string[]} argv  `process.argv.slice(2)`
 * @returns {{ name: string | undefined, install: boolean, rest: string[] }}
 */
export function parse(argv) {
  let name;
  let install = true;
  const rest = [];
  for (let index = 0; index < argv.length; index += 1) {
    const word = argv[index] ?? "";
    if (word === "--no-install") {
      install = false;
    } else if (valued.has(word)) {
      rest.push(word, argv[index + 1] ?? "");
      index += 1;
    } else if (word.startsWith("-") || name !== undefined) {
      rest.push(word);
    } else {
      name = word;
    }
  }
  return { name, install, rest };
}

/**
 * The arguments for the native `lepton`.
 *
 * @param {string} name
 * @param {{ install: boolean, rest: readonly string[] }} parsed
 * @returns {string[]}
 */
export function newArguments(name, parsed) {
  const args = ["new", name, ...parsed.rest];
  if (parsed.install && !parsed.rest.includes("--install")) args.push("--install");
  return args;
}

/**
 * What `lepton info --json` says is missing, as lines to print; empty when the machine
 * can build and run a webview project.
 *
 * @param {string} json  the output of `lepton info --json`
 * @returns {string[]}
 */
export function missing(json) {
  /** @type {{ tools?: { name: string, problem: unknown }[], engine?: { label: string, package: string, present: boolean }[] }} */
  let report;
  try {
    report = JSON.parse(json);
  } catch {
    return ["could not read `lepton info --json`; run it yourself to see what is missing"];
  }
  const lines = [];
  for (const tool of report.tools ?? []) {
    if (tool.problem !== null) lines.push(`${tool.name}: not usable (${describe(tool.problem)})`);
  }
  for (const part of report.engine ?? []) {
    if (!part.present && part.package.startsWith("wpe")) {
      lines.push(`${part.label}: pkg-config cannot find ${part.package}`);
    }
  }
  return lines;
}

/** @param {unknown} problem */
function describe(problem) {
  if (typeof problem === "string") return problem;
  if (typeof problem === "object" && problem !== null) return Object.keys(problem).join(", ");
  return "unknown";
}

/**
 * The package manager that started this process, from `npm_config_user_agent`
 * (`pnpm/12.10.1 npm/? node/v26.11.1 linux x64`), for messages; `lepton new` reads the
 * same variable itself.
 *
 * @param {string | undefined} agent
 * @returns {string}
 */
export function manager(agent) {
  const first = (agent ?? "").split(" ")[0]?.split("/")[0] ?? "";
  return ["npm", "pnpm", "yarn", "bun"].includes(first) ? first : "npm";
}
