// PolicySignatureVerifier.swift
// v1 ships unsigned policies behind this protocol so real signing (e.g. Ed25519
// over the raw payload, key pinned in the app) can slot in without touching
// EnterprisePolicyManager call sites.
import Foundation

enum EnterprisePolicyError: Error, Equatable {
    case unknownSignatureScheme(String)
    case signatureMismatch
}

protocol PolicySignatureVerifier: Sendable {
    /// Throws when the policy must not be trusted; the manager then enters `.policyInvalid`.
    func verify(policy: EnterprisePolicy, rawPayload: Data) throws
}

struct StubPolicySignatureVerifier: PolicySignatureVerifier {
    func verify(policy: EnterprisePolicy, rawPayload: Data) throws {
        guard policy.signatureMetadata.scheme == "unsigned-v1" else {
            throw EnterprisePolicyError.unknownSignatureScheme(policy.signatureMetadata.scheme)
        }
    }
}
