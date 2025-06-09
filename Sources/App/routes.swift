import Fluent
import Vapor

func routes(_ app: Application) throws {
    // Public routes
    app.get("") { req async throws -> Response in
        req.logger.info("Root route accessed - checking authentication")
        
        // Check if user is authenticated
        if req.auth.has(User.self) {
            req.logger.info("User is authenticated, rendering dashboard")
            return try await req.view.render("index", ["title": "Strato Dashboard"]).encodeResponse(for: req)
        } else {
            req.logger.info("User not authenticated, redirecting to login")
            throw Abort.redirect(to: "/login")
        }
    }

    app.get("hello") { req async -> String in
        "Hello, world!"
    }

    // Authentication views
    app.get("login") { req -> EventLoopFuture<View> in
        return req.view.render("login")
    }

    app.get("register") { req -> EventLoopFuture<View> in
        return req.view.render("register")
    }

    // Register controllers
    try app.register(collection: UserController())
    try app.register(collection: VMController())
}
