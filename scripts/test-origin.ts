/** Only these reserved loopback origins may have their browser storage reset. */
export function disposableOrigin(address: string): string {
	const url = new URL(address);
	const hosts = ['life-ui-write-fixes.localhost', 'life-ui-parent-regressions.localhost', 'life-ui-sql-integrity.localhost', 'life-ui-services.localhost', 'life-ui-markdown.localhost'];
	if (url.protocol !== 'http:' || !hosts.includes(url.hostname) || url.username || url.password || url.pathname !== '/workspace' || !url.searchParams.has('review')) {
		throw new Error('Refusing reset outside a reserved Life UI test origin');
	}
	return url.origin;
}
