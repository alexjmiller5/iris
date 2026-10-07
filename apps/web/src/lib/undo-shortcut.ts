/** Let the focused editor own text undo. Only unhandled workspace shortcuts
 * reach the validated saved-change writer. composedPath also covers shadow DOM. */
export function savedUndoShortcut(event: KeyboardEvent): boolean {
	if (
		event.defaultPrevented ||
		event.isComposing ||
		event.repeat ||
		event.shiftKey ||
		event.altKey ||
		!(event.metaKey || event.ctrlKey) ||
		event.key.toLowerCase() !== 'z'
	)
		return false;
	return !event.composedPath().some((target) => {
		const element = target as Element;
		return (
			element.nodeType === 1 &&
			typeof element.closest === 'function' &&
			element.closest(
				'input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="textbox"]'
			)
		);
	});
}
