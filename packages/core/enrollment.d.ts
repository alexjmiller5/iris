import type { EnrollmentApproval, EnrollmentApprovalArgs, EnrollmentPolicy, EnrollmentPollResult, SessionInfo, SessionReply, SessionRevocationResult, EnrollmentProfileExpectation } from './contract.generated.ts';
/** Hosts own clocks, cancellation, cryptography, HTTP and credential storage. */
export declare const ENROLLMENT_POLICY: Readonly<EnrollmentPolicy>;
/** Append this relative path only to the host's validated/canonical endpoint.
 * The only key here is a SHA-256 fingerprint, never the candidate bearer token. */
export declare function enrollmentApproval(args: EnrollmentApprovalArgs): EnrollmentApproval;
/** Identity validation is separate from replica eligibility. Manual dedicated
 * nonadmin names are valid here; only approval polling binds a fingerprint. */
export declare function validateDeviceSession(data: unknown, expectedProfile?: EnrollmentProfileExpectation): SessionInfo;
/** One response only. Hosts retain a monotonic deadline and never accept a late
 * reply from a cancelled, expired or replaced enrollment attempt. */
export declare function enrollmentPollResult(reply: SessionReply, expectedFingerprint: string, expectedProfile?: EnrollmentProfileExpectation): EnrollmentPollResult;
/** A 401 is not revocation proof: the hub cannot cancel a not-yet-approved key. */
export declare function sessionRevocationResult(reply: SessionReply): SessionRevocationResult;
