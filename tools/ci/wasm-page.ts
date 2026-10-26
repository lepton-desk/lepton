// The page of the WebAssembly check (`windows` and `servo-bridge` workflows): the engine's
// WebAssembly features (wasm-feature-detect) and whether `wasm.threads` gives the page
// threads — cross-origin isolation, `SharedArrayBuffer`, a shared `WebAssembly.Memory`
// and a worker answering through `Atomics`. The result goes into the window's title, which
// the workflow reads from outside (WebView2 and Servo print no console), and the console.
import * as detect from "wasm-feature-detect";

const probes: Record<string, () => Promise<boolean>> = {
  bigInt: detect.bigInt,
  bulkMemory: detect.bulkMemory,
  exceptions: detect.exceptions,
  exceptionsFinal: detect.exceptionsFinal,
  extendedConst: detect.extendedConst,
  gc: detect.gc,
  jsStringBuiltins: detect.jsStringBuiltins,
  jspi: detect.jspi,
  memory64: detect.memory64,
  multiMemory: detect.multiMemory,
  multiValue: detect.multiValue,
  mutableGlobals: detect.mutableGlobals,
  referenceTypes: detect.referenceTypes,
  relaxedSimd: detect.relaxedSimd,
  saturatedFloatToInt: detect.saturatedFloatToInt,
  signExtensions: detect.signExtensions,
  simd: detect.simd,
  streamingCompilation: detect.streamingCompilation,
  tailCall: detect.tailCall,
  threads: detect.threads,
  typeReflection: detect.typeReflection,
  typedFunctionReferences: detect.typedFunctionReferences,
  wideArithmetic: detect.wideArithmetic,
};

async function missing(): Promise<string[]> {
  const absent: string[] = [];
  for (const [name, probe] of Object.entries(probes)) {
    const found = await probe().catch(() => false);
    if (!found) absent.push(name);
  }
  return absent;
}

async function threads(): Promise<string> {
  try {
    const memory = new WebAssembly.Memory({ initial: 1, maximum: 1, shared: true });
    const cells = new Int32Array(memory.buffer);
    // The worker writes into the shared memory and says so; the page reads what it wrote.
    const source =
      "onmessage = (e) => { const c = new Int32Array(e.data); Atomics.store(c, 1, Atomics.load(c, 0) + 1); postMessage(0); };";
    const worker = new Worker(URL.createObjectURL(new Blob([source], { type: "text/javascript" })));
    Atomics.store(cells, 0, 41);
    const answered = new Promise<string>((resolve) => {
      worker.onmessage = () => resolve("ok");
      worker.onerror = () => resolve("failed");
      setTimeout(() => resolve("timed-out"), 3000);
    });
    worker.postMessage(memory.buffer);
    const waited = await answered;
    return `worker=${String(waited)} value=${Atomics.load(cells, 1)}`;
  } catch (error) {
    return `worker=${error instanceof Error ? error.name : "error"}`;
  }
}

const absent = await missing();
const result = [
  "WASM",
  `isolated=${String(globalThis.crossOriginIsolated)}`,
  `sab=${typeof SharedArrayBuffer}`,
  await threads(),
  `missing=${absent.length === 0 ? "none" : absent.join(",")}`,
].join(" ");
console.log(result);
document.title = result;
