// Evaluates each expression in the WebView2 page through the DevTools protocol and
// prints `expression => value` (the app runs with
// WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=<port>).
// Usage: node cdp.mjs <port> <expression>...
const [port, ...expressions] = process.argv.slice(2);
const deadline = Date.now() + 30_000;
let page;
while (!page) {
  try {
    const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
    page = list.find((target) => target.type === "page");
  } catch {
    // The browser process has not opened the port yet.
  }
  if (!page) {
    if (Date.now() > deadline) throw new Error(`no page on port ${port} after 30 s`);
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
}
const socket = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((resolve) => socket.addEventListener("open", resolve));
let next = 0;
const call = (method, params) =>
  new Promise((resolve) => {
    const id = ++next;
    const answer = (event) => {
      const message = JSON.parse(event.data);
      if (message.id !== id) return;
      socket.removeEventListener("message", answer);
      resolve(message.result);
    };
    socket.addEventListener("message", answer);
    socket.send(JSON.stringify({ id, method, params }));
  });
for (const expression of expressions) {
  const result = await call("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  console.log(`${expression} => ${JSON.stringify(result.result?.value ?? result.exceptionDetails?.text)}`);
}
socket.close();
