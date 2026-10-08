import {
	IconAlignLeft,
	IconArrowUpRight,
	IconBraces,
	IconCalendar,
	IconCircleChevronDown,
	IconClock,
	IconFileText,
	IconHash,
	IconLink,
	IconList,
	IconMail,
	IconPaperclip,
	IconPhone,
	IconSquareCheck
} from '@tabler/icons-svelte';

const icons = {
	number: IconHash,
	int: IconHash,
	select: IconCircleChevronDown,
	multi_select: IconList,
	date: IconCalendar,
	datetime: IconClock,
	date_or_datetime: IconCalendar,
	bool: IconSquareCheck,
	ref: IconArrowUpRight,
	multi_ref: IconArrowUpRight,
	url: IconLink,
	email: IconMail,
	phone: IconPhone,
	json: IconBraces,
	markdown: IconFileText,
	file: IconPaperclip
} as const;

/** The Tabler icon that marks a property's type in pickers and chips. */
export function propertyIcon(type: string | null | undefined) {
	return icons[type as keyof typeof icons] ?? IconAlignLeft;
}
