/** Only these reserved loopback origins may have their browser storage reset. */
export function disposableOrigin(address: string): string {
	const url = new URL(address);
	const hosts = ['life-ui-incoming.localhost', 'life-ui-write-fixes.localhost', 'life-ui-parent-regressions.localhost', 'life-ui-sql-integrity.localhost', 'life-ui-services.localhost', 'life-ui-markdown.localhost', 'life-ui-relations.localhost', 'life-ui-navigation.localhost', 'life-ui-palette.localhost', 'life-ui-grid.localhost'];
	if (url.protocol !== 'http:' || !(hosts.includes(url.hostname) || ['http://life-ui-enrollment.localhost:5230', 'http://life-ui-grid-enrollment.localhost:5234', 'http://life-ui-recents.localhost:5236'].includes(url.origin)) || url.username || url.password || url.pathname !== '/workspace' || !url.searchParams.has('review')) {
		throw new Error('Refusing reset outside a reserved Life UI test origin');
	}
	return url.origin;
}

/** Select within the caller's exact fixture origin. Storage resets still require disposableOrigin.
 * Keep the returned handles: product navigation intentionally removes observer/review flags.
 */
export function workspacePage<T extends { url(): string }>(pages: readonly T[], address: string): T | undefined {
	const expected = new URL(address);
	if (expected.pathname !== '/workspace' || expected.username || expected.password)
		throw new Error('Expected an owned workspace fixture URL');
	const candidates = pages.filter(page => {
		try {
			const actual = new URL(page.url());
			return actual.origin === expected.origin && actual.pathname === '/workspace' &&
				!actual.username && !actual.password &&
				actual.searchParams.get('observer') === expected.searchParams.get('observer');
		} catch { return false; }
	});
	if (candidates.length > 1) throw new Error('Ambiguous fixture pages. Keep one workspace tab per observer role.');
	return candidates[0];
}
