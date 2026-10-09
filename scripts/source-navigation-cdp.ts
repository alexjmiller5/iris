import { expect } from "@playwright/test";
import { disposableOrigin } from "./test-origin";

/** Direct attachment to one owned fixture page; never attaches to unrelated tabs. */
export async function sourceNavigationCDP(address: string) {
  const origin = disposableOrigin(address);
  const targets = await (
    await fetch(
      `${process.env.IRIS_TEST_CDP ?? "http://127.0.0.1:9222"}/json/list`,
    )
  ).json();
  const target = targets.find(
    (entry: { id: string; type: string; url: string }) =>
      entry.id === process.env.IRIS_TEST_TARGET &&
      entry.type === "page" &&
      new URL(entry.url).origin === origin,
  );
  if (!target)
    throw Error("Set IRIS_TEST_TARGET to the owned synthetic page ID");
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise<void>((resolve, reject) => {
    socket.onopen = () => resolve();
    socket.onerror = reject;
  });
  let sequence = 0;
  const pending = new Map<
    number,
    {
      resolve(value: any): void;
      reject(reason: unknown): void;
      timer: ReturnType<typeof setTimeout>;
    }
  >();
  const listeners = new Map<string, ((params: any) => void)[]>();
  socket.onmessage = (event) => {
    const message = JSON.parse(String(event.data));
    const request = pending.get(message.id);
    if (request) {
      pending.delete(message.id);
      clearTimeout(request.timer);
      message.error
        ? request.reject(Error(JSON.stringify(message.error)))
        : request.resolve(message.result);
    } else
      for (const listener of listeners.get(message.method) ?? [])
        listener(message.params);
  };
  function command(method: string, params: object = {}): Promise<any> {
    return new Promise((resolve, reject) => {
      const id = ++sequence;
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(Error(`CDP timeout: ${method}`));
      }, 10000);
      pending.set(id, { resolve, reject, timer });
      socket.send(JSON.stringify({ id, method, params }));
    });
  }
  async function evaluate<T = any>(expression: string): Promise<T> {
    const result = await command("Runtime.evaluate", {
      expression,
      returnByValue: true,
      awaitPromise: true,
      userGesture: true,
    });
    if (result.exceptionDetails)
      throw Error(JSON.stringify(result.exceptionDetails));
    return result.result.value;
  }
  async function until(expression: string, message = expression) {
    await expect
      .poll(() => evaluate(expression), { timeout: 10000, message })
      .toBe(true);
  }
  async function click(expression: string, count = 1) {
    await until(`!!(${expression}) && !(${expression}).disabled`);
    await evaluate(
      `(${expression}).scrollIntoView({block:'center',inline:'center',behavior:'instant'})`,
    );
    let point: { x: number; y: number; hit: boolean } | undefined,
      prior: typeof point;
    let stable = 0;
    for (let attempt = 0; attempt < 40; attempt++) {
      await Bun.sleep(30);
      point = await evaluate(
        `(()=>{const e=${expression};const r=e.getBoundingClientRect();const x=r.x+r.width/2,y=r.y+r.height/2;const hit=document.elementFromPoint(x,y);return {x,y,hit:!!r.width&&!!r.height&&(hit===e||e.contains(hit))};})()`,
      );
      stable =
        point?.hit &&
        prior &&
        Math.abs(point.x - prior.x) < 0.5 &&
        Math.abs(point.y - prior.y) < 0.5
          ? stable + 1
          : 0;
      if (stable >= 2) break;
      prior = point;
    }
    if (!point?.hit || stable < 2)
      throw Error(`Fixture control obscured or moving: ${expression}`);
    await command("Input.dispatchMouseEvent", {
      type: "mouseMoved",
      x: point.x,
      y: point.y,
    });
    for (let clickCount = 1; clickCount <= count; clickCount++) {
      await command("Input.dispatchMouseEvent", {
        type: "mousePressed",
        button: "left",
        clickCount,
        x: point.x,
        y: point.y,
      });
      await command("Input.dispatchMouseEvent", {
        type: "mouseReleased",
        button: "left",
        clickCount,
        x: point.x,
        y: point.y,
      });
    }
  }
  async function key(key: string, modifiers = 0) {
    const code = {
      Enter: 13,
      Escape: 27,
      Tab: 9,
      ArrowDown: 40,
      ArrowRight: 39,
      a: 65,
    }[key];
    await command("Input.dispatchKeyEvent", {
      type: "keyDown",
      key,
      windowsVirtualKeyCode: code,
      modifiers,
      ...(key === "Enter" ? { text: "\r" } : {}),
    });
    await command("Input.dispatchKeyEvent", {
      type: "keyUp",
      key,
      windowsVirtualKeyCode: code,
      modifiers,
    });
  }
  async function fill(expression: string, value: string) {
    await click(expression);
    await evaluate(`(${expression}).select()`);
    await command("Input.insertText", { text: value });
  }
  async function navigate(url: string) {
    if (new URL(url).origin !== origin)
      throw Error("Refusing navigation outside owned fixture origin");
    await command("Page.navigate", { url });
    await until(
      `location.href === ${JSON.stringify(url)} && document.readyState === 'complete'`,
    );
  }
  await command("Page.enable");
  await command("Runtime.enable");
  await command("Network.enable");
  return {
    command,
    evaluate,
    until,
    click,
    key,
    fill,
    navigate,
    on(method: string, handler: (params: any) => void) {
      listeners.set(method, [...(listeners.get(method) ?? []), handler]);
    },
    close() {
      for (const request of pending.values()) {
        clearTimeout(request.timer);
        request.reject(Error("Fixture CDP closed"));
      }
      pending.clear();
      socket.close();
    },
  };
}

export const js = JSON.stringify;
export const element = (selector: string) =>
  `document.querySelector(${js(selector)})`;
export const named = (tag: string, name: string, root = "document") =>
  `[...((${root})?.querySelectorAll(${js(tag)}) ?? [])].find(e => (e.getAttribute('aria-label') || e.textContent.trim()) === ${js(name)})`;
