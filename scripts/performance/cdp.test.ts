import { expect, test } from "bun:test";
import { connect, ownedTarget } from "./cdp";

test("target selection never falls back to another tab", () => {
  const target = {
    id: "owned",
    type: "page",
    url: "http://fixture/workspace",
    webSocketDebuggerUrl: "ws://127.0.0.1/owned",
  };
  expect(
    ownedTarget(
      [target, { ...target, id: "other", url: "http://other" }],
      target.url,
    ),
  ).toBe(target);
  expect(() => ownedTarget([target], "http://missing")).toThrow();
  expect(() => ownedTarget([target, target], target.url)).toThrow();
});

test("target connection correlates replies, surfaces protocol errors and times out", async () => {
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(request, server) {
      return server.upgrade(request)
        ? undefined
        : new Response(null, { status: 400 });
    },
    websocket: {
      message(ws, message) {
        const request = JSON.parse(String(message));
        if (request.method === "missing") return;
        setTimeout(
          () =>
            ws.send(
              JSON.stringify(
                request.method === "fail"
                  ? { id: request.id, error: { message: "No such method" } }
                  : {
                      id: request.id,
                      result: {
                        value: request.params.value,
                        sessionId: request.sessionId,
                      },
                    },
              ),
            ),
          request.params.delay ?? 0,
        );
      },
    },
  });
  const client = await connect(`ws://127.0.0.1:${server.port}`, 100);
  try {
    const slow = client.call("echo", { value: 1, delay: 20 });
    const fast = client.call("echo", { value: 2 }, "worker-session");
    expect(await fast).toEqual({ value: 2, sessionId: "worker-session" });
    expect(await slow).toEqual({ value: 1 });
    await expect(client.call("fail")).rejects.toThrow("No such method");
    await expect(client.call("missing")).rejects.toThrow("CDP timeout");
  } finally {
    client.close();
    server.stop(true);
  }
});
