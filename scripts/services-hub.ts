import { resolve } from 'node:path';
import { regressionHub } from './workspace-regression-hub';

/** Compose the two pending hub branches without modifying either checkout. */
export async function servicesHub(source: string, usageSource: string, origin: string, port = 0) {
	const { D1Shim } = await import(resolve(usageSource, 'worker/test/d1shim.js'));
	const { withUsage, ensureUsage, notify, period } = await import(resolve(usageSource, 'worker/src/usage.js'));
	const { authenticate, allowed, SWEEP_CRON } = await import(resolve(usageSource, 'worker/src/index.js'));
	const { ensureAuthReady, hashToken } = await import(resolve(usageSource, 'worker/src/auth.js'));
	const auth = new D1Shim();
	const requests: { path: string; authenticated: boolean }[] = [];
	await ensureAuthReady(auth);
	await ensureUsage(auth);
	const window = period(new Date(), 1);
	await auth.prepare('INSERT INTO _tokens(hash,name,scopes,label) VALUES (?,?,?,?)')
		.bind('fixture-hash', 'device:example', 'full', 'Example device').run();
	await auth.prepare('INSERT INTO _tokens(hash,name,scopes,label) VALUES (?,?,?,?)')
		.bind(await hashToken('fixture'), 'device:fixture-client', 'full', 'Fixture client').run();
	await auth.prepare('INSERT INTO _usage(period,principal,rows_read,rows_written,requests,updated_at) VALUES (?,?,?,?,?,?)')
		.bind(window.start, 'device:example', 1234, 56, 78, new Date().toISOString()).run();
	for (let i = 1; i <= 205; i++) {
		await notify(auth, { id: `fixture:${i}`, producer: 'example', type: 'example.notice', severity: 'info', title: `Example notice ${i}`, body: 'A synthetic notification.', data: { example: true } });
	}
	const fixture = await regressionHub(source, origin, port, {
		wrap: worker => {
			const wrapped = withUsage(worker, { authenticate, allowed, sweepCron: SWEEP_CRON });
			return { ...wrapped, fetch(request: Request, env: unknown, context: unknown) {
				requests.push({ path: new URL(request.url).pathname, authenticated: request.headers.has('Authorization') });
				return wrapped.fetch(request, env, context);
			} };
		},
		env: { AUTH_DB: auth, HUB_TOKEN: 'operator-fixture' }
	});
	return { ...fixture, auth, window, requests, notify: (n: unknown) => notify(auth, n) };
}

if (import.meta.main) {
	if (!process.argv[2] || !process.argv[3]) throw new Error('Usage: bun scripts/services-hub.ts <soma-checkout> <usage-hub-checkout>');
	const { server } = await servicesHub(process.argv[2], process.argv[3], process.env.IRIS_TEST_ORIGIN ?? 'http://iris-services.localhost:5198', Number(process.env.IRIS_TEST_HUB_PORT ?? 5204));
	console.log(`Synthetic services hub: ${server.url}`);
}
