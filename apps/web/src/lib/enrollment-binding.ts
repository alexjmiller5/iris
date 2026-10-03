import type { SqlDriver } from 'life-ui-core/client';

/** Host preflight before showing approval or sending session credentials.
 * Sync remains authoritative and rechecks both bindings before its own HTTP.
 */
export async function enrollmentEndpoint(
	db: Pick<SqlDriver, 'all'>,
	endpoint: string
): Promise<string> {
	const bindings = await db.all(
		"SELECT value FROM main._core_state WHERE key='hub' UNION ALL SELECT value FROM main._sync_state WHERE key='hub_url'"
	);
	if (bindings.some(({ value }) => value != null && value !== '' && value !== endpoint))
		throw Error('hub changed; use a fresh replica');
	return endpoint;
}
