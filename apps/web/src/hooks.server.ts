import { dev } from '$app/environment';
import { redirect, type Handle } from '@sveltejs/kit';

// http → https at the Worker, so it holds on any domain with no zone config.
// (Cloudflare's "Always Use HTTPS" zone setting is off by default.)
export const handle: Handle = async ({ event, resolve }) => {
	const url = event.url;
	if (!dev && url.protocol === 'http:') {
		redirect(301, `https://${url.host}${url.pathname}${url.search}`);
	}
	const response = await resolve(event);
	// Baseline security headers on server-rendered responses (static assets
	// bypass the Worker). CSP stays a per-site decision.
	response.headers.set('X-Content-Type-Options', 'nosniff');
	response.headers.set('Referrer-Policy', 'strict-origin-when-cross-origin');
	response.headers.set('Permissions-Policy', 'camera=(), microphone=(), geolocation=()');
	return response;
};
