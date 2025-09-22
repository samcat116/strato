import Vapor
import Fluent
import Foundation
import StratoShared

/// Service for interacting with step-ca Certificate Authority
/// Replaces the custom CertificateAuthorityService with step-ca integration
struct StepCAClient {
    let client: Client
    let logger: Logger
    let database: Database

    private let stepCAURL: String
    private let fingerprint: String
    private let provisionerName: String
    private let provisionerPassword: String

    init(client: Client, logger: Logger, database: Database) throws {
        self.client = client
        self.logger = logger
        self.database = database

        guard let stepCAURL = Environment.get("STEP_CA_URL") else {
            throw StepCAError.missingConfiguration("STEP_CA_URL")
        }
        self.stepCAURL = stepCAURL

        // Fingerprint may be empty initially
        self.fingerprint = Environment.get("STEP_CA_FINGERPRINT") ?? ""

        guard let provisionerName = Environment.get("STEP_CA_PROVISIONER_NAME") else {
            throw StepCAError.missingConfiguration("STEP_CA_PROVISIONER_NAME")
        }
        self.provisionerName = provisionerName

        guard let provisionerPassword = Environment.get("STEP_CA_PROVISIONER_PASSWORD") else {
            throw StepCAError.missingConfiguration("STEP_CA_PROVISIONER_PASSWORD")
        }
        self.provisionerPassword = provisionerPassword
    }

    /// Get CA certificate bundle for agents
    func getCACertificate() async throws -> String {
        let response = try await client.get(URI(string: "\(stepCAURL)/root/\(fingerprint)"))

        guard response.status == .ok else {
            throw StepCAError.httpError(response.status)
        }

        guard let body = response.body else {
            throw StepCAError.invalidResponse("Empty CA certificate response")
        }

        let certificatePEM = String(buffer: body)

        return certificatePEM
    }

    /// Generate a JWK token for agent enrollment
    /// Note: This method is moved to JoinTokenService in AgentEnrollmentController
    /// and should be used through the request context for proper JWT signing
    func generateJoinToken(for agentId: String, validityHours: Int = 1) throws -> String {
        // For now, return a placeholder. Real implementation should use Request.jwt
        throw StepCAError.missingConfiguration("Use JoinTokenService.generateJoinToken instead")
    }

    /// Issue a certificate for an agent using step-ca
    func issueCertificate(
        for agentId: String,
        csr: CertificateSigningRequest,
        joinToken: String,
        validityHours: Int = 24
    ) async throws -> AgentCertificate {

        // Create signing request for step-ca
        let signRequest = StepCASignRequest(
            csr: csr.publicKeyPEM, // Use available field from CertificateSigningRequest
            ott: joinToken
        )

        let requestBody = try JSONEncoder().encode(signRequest)

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")

        let response = try await client.post(
            URI(string: "\(stepCAURL)/1.0/sign"),
            headers: headers
        ) { request in
            request.body = .init(data: requestBody)
        }

        guard response.status == .created else {
            let errorBody = response.body.map { String(buffer: $0) } ?? "Unknown error"
            logger.error("Step-CA sign request failed", metadata: [
                "status": .stringConvertible(response.status.code),
                "body": .string(errorBody)
            ])
            throw StepCAError.signRequestFailed(response.status, errorBody)
        }

        guard let responseBody = response.body,
              let signResponse = try? JSONDecoder().decode(StepCASignResponse.self, from: responseBody) else {
            throw StepCAError.invalidResponse("Invalid sign response")
        }

        // Create SPIFFE URI
        let spiffeURI = "spiffe://strato.local/agent/\(agentId)"

        // Extract serial number from certificate
        let serialNumber = try extractSerialNumber(from: signResponse.crt)

        // Create agent certificate record
        let certificate = AgentCertificate(
            agentId: agentId,
            spiffeURI: spiffeURI,
            certificatePEM: signResponse.crt,
            serialNumber: serialNumber,
            status: .active,
            caId: UUID(), // Will be replaced with actual CA ID
            issuedAt: Date(),
            expiresAt: Date().addingTimeInterval(TimeInterval(validityHours * 3600))
        )

        try await certificate.save(on: database)

        logger.info("Issued certificate via step-ca", metadata: [
            "agentId": .string(agentId),
            "serialNumber": .string(serialNumber),
            "spiffeURI": .string(spiffeURI),
            "certificateId": .string(certificate.id?.uuidString ?? "unknown")
        ])

        return certificate
    }

    /// Revoke a certificate using step-ca
    func revokeCertificate(_ certificate: AgentCertificate, reason: String) async throws {
        let revokeRequest = StepCARevokeRequest(
            serial: certificate.serialNumber,
            reasonCode: 0, // Unspecified
            reason: reason,
            passive: false
        )

        let requestBody = try JSONEncoder().encode(revokeRequest)

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/json")

        let response = try await client.post(
            URI(string: "\(stepCAURL)/1.0/revoke"),
            headers: headers
        ) { request in
            request.body = .init(data: requestBody)
        }

        guard response.status == .ok else {
            let errorBody = response.body.map { String(buffer: $0) } ?? "Unknown error"
            throw StepCAError.revokeRequestFailed(response.status, errorBody)
        }

        // Update certificate status in database
        certificate.status = .revoked
        certificate.revokedAt = Date()
        certificate.revocationReason = reason

        try await certificate.save(on: database)

        logger.info("Revoked certificate via step-ca", metadata: [
            "agentId": .string(certificate.agentId),
            "serialNumber": .string(certificate.serialNumber),
            "reason": .string(reason)
        ])
    }

    /// Get Certificate Revocation List from step-ca
    func getCRL() async throws -> String {
        let response = try await client.get(URI(string: "\(stepCAURL)/1.0/crl"))

        guard response.status == .ok else {
            throw StepCAError.httpError(response.status)
        }

        guard let body = response.body else {
            throw StepCAError.invalidResponse("Empty CRL response")
        }

        let crlData = String(buffer: body)

        return crlData
    }

    /// Check step-ca health
    func healthCheck() async throws -> Bool {
        do {
            let response = try await client.get(URI(string: "\(stepCAURL)/health"))
            return response.status == .ok
        } catch {
            logger.warning("Step-CA health check failed", metadata: [
                "error": .string(error.localizedDescription)
            ])
            return false
        }
    }

    // MARK: - Private Helpers

    private func extractSerialNumber(from certificatePEM: String) throws -> String {
        // For now, generate a serial number
        // In a real implementation, we would parse the X.509 certificate
        // and extract the actual serial number
        return UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    }
}

// MARK: - DTOs

struct StepCASignRequest: Codable {
    let csr: String
    let ott: String
}

struct StepCASignResponse: Codable {
    let crt: String
    let ca: String
    let certChain: [String]

    enum CodingKeys: String, CodingKey {
        case crt
        case ca
        case certChain = "certChain"
    }
}

struct StepCARevokeRequest: Codable {
    let serial: String
    let reasonCode: Int
    let reason: String
    let passive: Bool

    enum CodingKeys: String, CodingKey {
        case serial
        case reasonCode = "reasonCode"
        case reason
        case passive
    }
}

// MARK: - Errors

enum StepCAError: Error, LocalizedError {
    case missingConfiguration(String)
    case httpError(HTTPStatus)
    case signRequestFailed(HTTPStatus, String)
    case revokeRequestFailed(HTTPStatus, String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let key):
            return "Missing step-ca configuration: \(key)"
        case .httpError(let status):
            return "Step-CA HTTP error: \(status)"
        case .signRequestFailed(let status, let message):
            return "Step-CA sign request failed (\(status)): \(message)"
        case .revokeRequestFailed(let status, let message):
            return "Step-CA revoke request failed (\(status)): \(message)"
        case .invalidResponse(let message):
            return "Invalid step-ca response: \(message)"
        }
    }
}

// MARK: - JWT Support

import JWT

struct JoinTokenPayload: JWTPayload {
    let agentId: String
    let validityHours: Int
    let iat: Date
    let exp: Date

    init(agentId: String, validityHours: Int) {
        self.agentId = agentId
        self.validityHours = validityHours
        self.iat = Date()
        self.exp = Date().addingTimeInterval(TimeInterval(validityHours * 3600))
    }

    func verify(using signer: JWTSigner) throws {
        // Verify expiration
        guard exp > Date() else {
            throw JWTError.claimVerificationFailure(name: "exp", reason: "Token has expired")
        }
    }
}