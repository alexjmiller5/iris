import { servicesHub } from './services-hub';

// Disposable actual Worker fixture for native service-row identity regressions.
if (!process.argv[2] || !process.argv[3]) {
	throw new Error('Usage: bun scripts/native-service-identity-hub.ts <soma-checkout> <usage-hub-checkout>');
}
const fixture = await servicesHub(process.argv[2], process.argv[3], 'http://native-services.localhost', Number(process.env.IRIS_TEST_HUB_PORT ?? 0));
await fixture.auth.prepare('DELETE FROM _notifications').run();
await fixture.auth.prepare('DELETE FROM _usage').run();
for (const [index, id] of ['\u00e9', 'e\u0301'].entries()) {
	const word = index === 0 ? 'first' : 'second';
	await fixture.notify({
		id, producer: 'example', type: 'example.notice', severity: 'info',
		title: `Opaque ${word} notice`, body: `The ${word} independent event.`, data: {},
	});
	await fixture.auth.prepare('INSERT INTO _tokens(hash,name,scopes,label) VALUES (?,?,?,?)')
		.bind(`fixture-${word}-usage`, `device:${id}`, 'full', `Opaque ${word} device`).run();
	await fixture.auth.prepare('INSERT INTO _usage(period,principal,rows_read,rows_written,requests,updated_at) VALUES (?,?,?,?,?,?)')
		.bind(fixture.window.start, `device:${id}`, (index + 1) * 101, (index + 1) * 11, (index + 1) * 7, new Date().toISOString()).run();
}
console.log(`Synthetic identity hub: ${fixture.server.url}`);
