import Vapor
import Foundation

func tailwind(_ app: Application) async throws {
    app.logger.info("Setting up TailwindCSS processing...")
    
    // In development, we can run TailwindCSS in watch mode
    // In production, CSS should be pre-built during Docker build
    #if DEBUG
    Task {
        do {
            app.logger.info("Starting TailwindCSS in watch mode...")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["npm", "run", "build-css"]
            
            // Set working directory to project root
            let workingDirectory = app.directory.workingDirectory
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
            
            try process.run()
            app.logger.info("TailwindCSS watch mode started")
        } catch {
            app.logger.warning("Failed to start TailwindCSS watch mode: \(error)")
            app.logger.info("CSS will need to be built manually with 'npm run build-css'")
        }
    }
    #else
    // In production, just verify CSS file exists
    let cssPath = app.directory.publicDirectory + "styles/app.generated.css"
    if !FileManager.default.fileExists(atPath: cssPath) {
        app.logger.warning("Generated CSS file not found at \(cssPath)")
        app.logger.info("Make sure to run 'npm run build-css-prod' during build")
    } else {
        app.logger.info("TailwindCSS generated file found at \(cssPath)")
    }
    #endif
}