type Target = {
  id: string;
  type: string;
  url: string;
  webSocketDebuggerUrl: string;
};
export function ownedTarget(targets: Target[], address: string): Target {
  const matches = targets.filter(
    (target) => target.type === "page" && target.url === address,
  );
  if (matches.length !== 1)
    throw new Error(
      "Open exactly one owned fixture tab; refusing a fallback target",
    );
  return matches[0]!;
}

/** A connection to one explicit page target, never the browser/default context. */
export async function connect(url: string, timeoutMs = 10000) {
  const socket = new WebSocket(url);
  let nextId = 0;
  const pending = new Map<
    number,
    {
      resolve: (result: any) => void;
      reject: (error: Error) => void;
      timer: ReturnType<typeof setTimeout>;
    }
  >();
  const listeners = new Set<
    (method: string, params: any, sessionId?: string) => void
  >();
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(String(event.data));
    if (message.id) {
      const waiter = pending.get(message.id);
      if (!waiter) return;
      pending.delete(message.id);
      clearTimeout(waiter.timer);
      if (message.error) waiter.reject(new Error(message.error.message));
      else waiter.resolve(message.result);
    } else
      for (const listener of listeners)
        listener(message.method, message.params, message.sessionId);
  });
  socket.addEventListener("close", () => {
    for (const waiter of pending.values()) {
      clearTimeout(waiter.timer);
      waiter.reject(new Error("Owned CDP target disconnected"));
    }
    pending.clear();
  });
  await new Promise<void>((resolve, reject) => {
    const timer = setTimeout(() => {
      socket.close();
      reject(new Error("CDP connection timeout"));
    }, timeoutMs);
    socket.addEventListener(
      "open",
      () => {
        clearTimeout(timer);
        resolve();
      },
      { once: true },
    );
    socket.addEventListener(
      "error",
      () => {
        clearTimeout(timer);
        reject(new Error("CDP connection failed"));
      },
      { once: true },
    );
  });
  return {
    call(
      method: string,
      params: Record<string, unknown> = {},
      sessionId?: string,
    ): Promise<any> {
      if (socket.readyState !== WebSocket.OPEN)
        return Promise.reject(new Error("Owned CDP target disconnected"));
      const id = ++nextId;
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(new Error(`CDP timeout: ${method}`));
        }, timeoutMs);
        pending.set(id, { resolve, reject, timer });
        socket.send(
          JSON.stringify({
            id,
            method,
            params,
            ...(sessionId ? { sessionId } : {}),
          }),
        );
      });
    },
    onEvent(
      listener: (method: string, params: any, sessionId?: string) => void,
    ) {
      listeners.add(listener);
    },
    close() {
      socket.close();
    },
  };
}
