import { expect, test } from 'bun:test';
const { collectLegacyJournalInventory } = (await import(
	process.env.IRIS_TEST_LEGACY_INVENTORY || '../apps/web/src/lib/workspace-legacy-journals'
)) as typeof import('../apps/web/src/lib/workspace-legacy-journals');
function fixture(
	options: {
		absent?: boolean;
		race?: boolean;
		invalidSchema?: boolean;
		versionChange?: boolean;
		key?: unknown;
	} = {}
) {
	const data = new Map<string, Array<{ key: unknown; value: unknown }>>([
		[
			'iris-governance',
			[
				{
					key: options.key ?? '["deployment-1","session-1","principal-1"]',
					value:
						'{"request":{"idempotencyKey":"uncertain-governance"},"integer":"9223372036854775807"}'
				},
				{ key: 'other-session', value: '{unreadable-but-retained' }
			]
		],
		[
			'iris-changesets',
			[
				{
					key: '["https://example.test","deployment-1","session-1","principal-1"]',
					value: '{"request":{"idempotencyKey":"uncertain-changeset"},"raw":"\\ud800"}'
				}
			]
		]
	]);
	const opened: string[] = [],
		modes: string[] = [];
	let closed = 0,
		aborted = 0;
	const factory = {
		databases: async () =>
			options.absent
				? [{ name: 'unrelated-db', version: 1 }]
				: [...data.keys()].map((name) => ({ name, version: 1 })),
		open: (name: string) => {
			opened.push(name);
			const db = {
				version: 1,
				objectStoreNames: { length: 1, contains: (store: string) => store === 'pending' },
				onversionchange: null as null | (() => void),
				close: () => closed++,
				transaction: (_store: string, mode: string) => {
					modes.push(mode);
					let index = 0,
						failed = false;
					const tx = {
						error: null,
						oncomplete: null as null | (() => void),
						onabort: null as null | (() => void),
						onerror: null,
						abort: () => {
							failed = true;
							aborted++;
							queueMicrotask(() => tx.onabort?.());
						},
						objectStore: () => ({
							keyPath: null,
							autoIncrement: options.invalidSchema ?? false,
							indexNames: { length: 0 },
							openCursor: () => {
								const request = {
									result: null as null | { key: unknown; value: unknown; continue: () => void },
									onsuccess: null as null | (() => void)
								};
								const emit = () => {
									if (failed) return;
									const row = data.get(name)![index++];
									if (options.versionChange && index === 1) {
										db.onversionchange?.();
										if (failed) return;
									}
									request.result = row
										? { ...structuredClone(row), continue: () => queueMicrotask(emit) }
										: null;
									request.onsuccess?.();
									if (!row && !failed) queueMicrotask(() => tx.oncomplete?.());
								};
								queueMicrotask(emit);
								return request;
							}
						})
					};
					return tx;
				}
			};
			let upgradeAborted = false;
			const request = {
				result: db,
				error: new Error('Listed legacy database disappeared'),
				transaction: {
					abort: () => {
						upgradeAborted = true;
						aborted++;
					}
				},
				onupgradeneeded: null as null | (() => void),
				onerror: null as null | (() => void),
				onblocked: null,
				onsuccess: null as null | (() => void)
			};
			queueMicrotask(() => {
				if (options.race) request.onupgradeneeded?.();
				if (upgradeAborted) request.onerror?.();
				else request.onsuccess?.();
			});
			return request;
		}
	};
	return {
		data,
		factory: factory as unknown as IDBFactory,
		opened,
		modes,
		get closed() {
			return closed;
		},
		get aborted() {
			return aborted;
		}
	};
}
test('both actual legacy journal stores retain every scope key and exact raw pending value, including unreadable data', async () => {
	const f = fixture(),
		snapshot = await collectLegacyJournalInventory(f.factory);
	expect(f.opened).toEqual(['iris-governance', 'iris-changesets']);
	expect(f.modes.every((mode) => mode === 'readonly')).toBe(true);
	expect(f.closed).toBe(2);
	for (const [name, domain] of [
		['iris-governance', 'governance-journal'],
		['iris-changesets', 'changeset-journal']
	] as const) {
		const records = snapshot[domain];
		for (const original of f.data.get(name)!) {
			const found = records.find((r) => r.key === JSON.stringify([name, 'pending', original.key]));
			expect(found).toBeDefined();
			expect(JSON.parse(new TextDecoder().decode(found!.value))).toBe(original.value);
		}
	}
});
test('absence is proven by enumeration without opening or creating an empty journal', async () => {
	const f = fixture({ absent: true }),
		snapshot = await collectLegacyJournalInventory(f.factory);
	expect(f.opened).toHaveLength(0);
	expect(snapshot['governance-journal']).toHaveLength(1);
	expect(new TextDecoder().decode(snapshot['governance-journal'][0].value)).toContain('false');
});
test('listed database deletion race aborts upgrade instead of provisioning a replacement', async () => {
	const f = fixture({ race: true });
	await expect(collectLegacyJournalInventory(f.factory)).rejects.toThrow();
	expect(f.aborted).toBe(1);
	expect(f.opened).toHaveLength(1);
});
for (const options of [{ invalidSchema: true }, { versionChange: true }, { key: 123 }])
	test(
		'unknown legacy schema, key type or version retirement never becomes empty: ' +
			JSON.stringify(options),
		async () => {
			const f = fixture(options);
			await expect(collectLegacyJournalInventory(f.factory)).rejects.toThrow();
			expect(f.closed).toBeGreaterThan(0);
			expect(f.data.get('iris-governance')).toHaveLength(2);
		}
	);
test('unavailable enumeration is not accepted as proof of no pending journal', async () => {
	const f = fixture();
	await expect(
		collectLegacyJournalInventory({ ...f.factory, databases: undefined } as unknown as IDBFactory)
	).rejects.toThrow();
	expect(f.opened).toHaveLength(0);
});

test('raw UTF16 scope/value code units survive inventory framing without lossy text replacement', async () => {
	const f = fixture();
	const original = {
		key: 'scope-' + String.fromCharCode(0xd800),
		value: String.fromCharCode(0xd800) + '-retained'
	};
	f.data.get('iris-governance')!.push(original);
	const result = await collectLegacyJournalInventory(f.factory);
	const row = result['governance-journal'].find(
		(r) => r.key === JSON.stringify(['iris-governance', 'pending', original.key])
	)!;
	expect(JSON.parse(new TextDecoder().decode(row.value))).toBe(original.value);
});
test('unknown listed legacy version and pre-cancelled inventory never open source stores', async () => {
	const f = fixture();
	f.factory.databases = async () => [{ name: 'iris-governance', version: 2 }];
	await expect(collectLegacyJournalInventory(f.factory)).rejects.toThrow();
	expect(f.opened).toHaveLength(0);
	const controller = new AbortController();
	controller.abort();
	await expect(
		collectLegacyJournalInventory(f.factory, { signal: controller.signal })
	).rejects.toThrow();
	expect(f.opened).toHaveLength(0);
});
