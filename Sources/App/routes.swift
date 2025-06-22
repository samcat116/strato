import Elementary
import ElementaryHTMX
import Fluent
import Vapor

func routes(_ app: Application) throws {
    // Public routes
    app.get("") { req async throws -> Response in
        req.logger.info("Root route accessed - checking authentication")

        // Check if user is authenticated
        if req.auth.has(User.self) {
            req.logger.info("User is authenticated, rendering dashboard")
            let html = DashboardTemplate().render()
            return Response(
                status: .ok, headers: HTTPHeaders([("Content-Type", "text/html")]),
                body: .init(string: html))
        } else {
            req.logger.info("User not authenticated, redirecting to login")
            throw Abort.redirect(to: "/login")
        }
    }

    app.get("hello") { req async -> String in
        "Hello, world!"
    }

    // Authentication views
    app.get("login") { req -> Response in
        let html = LoginTemplate().render()
        return Response(status: .ok, headers: HTTPHeaders([("Content-Type", "text/html")]), body: .init(string: html))
    }

    app.get("register") { req -> Response in
        let html = RegisterTemplate().render()
        return Response(status: .ok, headers: HTTPHeaders([("Content-Type", "text/html")]), body: .init(string: html))
    }

    // Register controllers
    try app.register(collection: UserController())
    try app.register(collection: VMController())
}
