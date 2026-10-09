// Canonical wire shapes come from Soma's generated contract. Importing
// these types does not advertise operations or authorize an API adapter.
import type { TransportError, UnavailableResult } from 'iris-core/contract';

export type {
	Target,
	Revision,
	CellValue,
	Actor,
	Change,
	Conflict,
	Intent,
	PreviewRequest,
	Preview,
	HistoryEvent,
	Proposal,
	ApprovalReceipt,
	MutationErrorCode,
	MutationResolution,
	MutationError,
	ApprovalResult
} from 'iris-core/contract';

// Local presentation helpers also paginate derived lists. API methods use
// their concrete generated result types rather than this generic envelope.
export type ReadResult<T> = { kind: 'success'; value: T } | UnavailableResult | TransportError;
