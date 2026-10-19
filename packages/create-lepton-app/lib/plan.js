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
 * The arguments for the native `lepton`. Without a name `lepton new` asks for one itself,
 * after its header and in the same style as its other questions.
 *
 * @param {string | undefined} name
 * @param {{ install: boolean, rest: readonly string[] }} parsed
 * @returns {string[]}
 */
export function newArguments(name, parsed) {
  const args = name === undefined ? ["new", ...parsed.rest] : ["new", name, ...parsed.rest];
  if (parsed.install && !parsed.rest.includes("--install")) args.push("--install");
  return args;
}

/**
 * Whether to colour this package's own lines: the rules `lepton` follows (`NO_COLOR`,
 * `FORCE_COLOR`, a terminal, not `TERM=dumb`).
 *
 * @param {Record<string, string | undefined>} env
 * @param {boolean} terminal
 */
export function coloured(env, terminal) {
  if ((env.NO_COLOR ?? "") !== "") return false;
  const force = (env.FORCE_COLOR ?? "") !== "" && env.FORCE_COLOR !== "0";
  if (force) return true;
  return terminal && env.TERM !== "dumb";
}

/**
 * What `lepton info --json` says is missing, as lines to print; empty when the machine
 * can build and run a webview project.
 *
 * @param {string} json  the output of `lepton info --json`
 * @param {string} [platform]  the system it ran on: Windows' engine is WebView2, not WPE
 * @returns {string[]}
 */
export function missing(json, platform = process.platform) {
  /** @type {{ tools?: { name: string, problem: unknown }[], engine?: { webkit: string | null, platform: boolean, legacy: boolean, cairo: boolean, xcb: boolean, webview2?: string | null, ready: boolean } }} */
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
  // The engine as `lepton info --json` reports it (commands/engine.rs `Engine::json`).
  // 0.1.5 read the list this used to be and failed on the object before creating anything.
  const engine = report.engine;
  if (
    engine !== undefined &&
    engine !== null &&
    typeof engine === "object" &&
    !Array.isArray(engine) &&
    !engine.ready
  ) {
    if (platform === "win32") {
      // On Windows the page runs in WebView2, which Windows 10 and 11 install; the core
      // finds the runtime itself (`render/webview/webview2/runtime.zig`).
      lines.push(
        "WebView2 runtime: not found (install it from https://developer.microsoft.com/microsoft-edge/webview2/)",
      );
      return lines;
    }
    if (engine.webkit === null)
      lines.push("WPE WebKit: not installed (`lepton info` says how to get it)");
    else if (!engine.platform && !engine.legacy)
      lines.push(`WPE WebKit ${engine.webkit}: wpe-platform-2.0 is missing`);
    if (!engine.cairo) lines.push("cairo: missing");
    if (!engine.xcb) lines.push("xcb: missing");
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
