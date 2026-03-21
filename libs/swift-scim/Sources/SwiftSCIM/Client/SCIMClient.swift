import Foundation

/// Main SCIM client for interacting with SCIM endpoints
public actor SCIMClient {
    private let baseURL: URL
    private let httpClient: URLSession
    private let authenticationProvider: SCIMAuthenticationProvider?
    private let dateFormatter: ISO8601DateFormatter
    
    /// Default JSON encoder with ISO8601 date formatting
    public let encoder: JSONEncoder
    
    /// Default JSON decoder with ISO8601 date formatting
    public let decoder: JSONDecoder
    
    public init(
        baseURL: URL,
        authenticationProvider: SCIMAuthenticationProvider? = nil,
        httpClient: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.authenticationProvider = authenticationProvider
        self.httpClient = httpClient
        
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.dateFormatter = formatter
        
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .custom { date, encoder in
            let string = formatter.string(from: date)
            var container = encoder.singleValueContainer()
            try container.encode(string)
        }
        
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = formatter.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format")
        }
    }
    
    /// Perform a raw HTTP request
    private func performRequest(
        method: HTTPMethod,
        path: String,
        queryParameters: SCIMQueryParameters? = nil,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> (Data, HTTPURLResponse) {
        
        var urlComponents = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)
        
        if let queryParameters = queryParameters {
            urlComponents?.queryItems = queryParameters.queryItems
        }
        
        guard let url = urlComponents?.url else {
            throw SCIMClientError.invalidURL(baseURL.appendingPathComponent(path).absoluteString)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body
        
        // Set default headers
        request.setValue("application/scim+json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/scim+json", forHTTPHeaderField: "Content-Type")
        }
        
        // Add custom headers
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        // Apply authentication
        if let authProvider = authenticationProvider {
            do {
                try await authProvider.authenticate(request: &request)
            } catch {
                throw SCIMClientError.authenticationFailed
            }
        }
        
        do {
            let (data, response) = try await httpClient.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SCIMClientError.networkError(URLError(.badServerResponse))
            }
            
            // Handle HTTP errors
            switch httpResponse.statusCode {
            case 200...299:
                return (data, httpResponse)
            case 400:
                if let errorResponse = try? decoder.decode(SCIMErrorResponse.self, from: data) {
                    throw SCIMClientError.scimError(errorResponse)
                }
                throw SCIMClientError.httpError(statusCode: httpResponse.statusCode, data: data)
            case 401:
                throw SCIMClientError.authenticationFailed
            case 403:
                throw SCIMClientError.permissionDenied
            case 404:
                throw SCIMClientError.resourceNotFound
            case 409:
                throw SCIMClientError.resourceConflict
            case 429:
                throw SCIMClientError.rateLimitExceeded
            case 500...599:
                throw SCIMClientError.serverError
            default:
                throw SCIMClientError.httpError(statusCode: httpResponse.statusCode, data: data)
            }
            
        } catch let error as SCIMClientError {
            throw error
        } catch {
            throw SCIMClientError.networkError(error)
        }
    }
    
    /// Perform a GET request and decode the response
    internal func get<T: Codable>(
        path: String,
        queryParameters: SCIMQueryParameters? = nil,
        responseType: T.Type
    ) async throws -> T {
        let (data, _) = try await performRequest(
            method: .GET,
            path: path,
            queryParameters: queryParameters
        )
        
        do {
            return try decoder.decode(responseType, from: data)
        } catch {
            throw SCIMClientError.decodingError(error)
        }
    }
    
    /// Perform a POST request with a body and decode the response
    internal func post<T: Codable, R: Codable>(
        path: String,
        body: T,
        responseType: R.Type
    ) async throws -> R {
        let bodyData: Data
        do {
            bodyData = try encoder.encode(body)
        } catch {
            throw SCIMClientError.encodingError(error)
        }
        
        let (data, _) = try await performRequest(
            method: .POST,
            path: path,
            body: bodyData
        )
        
        do {
            return try decoder.decode(responseType, from: data)
        } catch {
            throw SCIMClientError.decodingError(error)
        }
    }
    
    /// Perform a PUT request with a body and decode the response
    internal func put<T: Codable, R: Codable>(
        path: String,
        body: T,
        responseType: R.Type
    ) async throws -> R {
        let bodyData: Data
        do {
            bodyData = try encoder.encode(body)
        } catch {
            throw SCIMClientError.encodingError(error)
        }
        
        let (data, _) = try await performRequest(
            method: .PUT,
            path: path,
            body: bodyData
        )
        
        do {
            return try decoder.decode(responseType, from: data)
        } catch {
            throw SCIMClientError.decodingError(error)
        }
    }
    
    /// Perform a PATCH request with a body and decode the response
    internal func patch<T: Codable, R: Codable>(
        path: String,
        body: T,
        responseType: R.Type
    ) async throws -> R {
        let bodyData: Data
        do {
            bodyData = try encoder.encode(body)
        } catch {
            throw SCIMClientError.encodingError(error)
        }
        
        let (data, _) = try await performRequest(
            method: .PATCH,
            path: path,
            body: bodyData
        )
        
        do {
            return try decoder.decode(responseType, from: data)
        } catch {
            throw SCIMClientError.decodingError(error)
        }
    }
    
    /// Perform a DELETE request
    internal func delete(path: String) async throws {
        let _ = try await performRequest(method: .DELETE, path: path)
    }
}

/// HTTP methods
private enum HTTPMethod: String {
    case GET = "GET"
    case POST = "POST"
    case PUT = "PUT"
    case PATCH = "PATCH"
    case DELETE = "DELETE"
}