import SwiftyTailwind
import TSCBasic
import Vapor

func tailwind(_ app: Application) async throws {
    let resourcesDirectory = try AbsolutePath(validating: app.directory.resourcesDirectory)
    let publicDirectory = try AbsolutePath(validating: app.directory.publicDirectory)
    let tailwind = SwiftyTailwind()
    try await tailwind.run(
        input: .init(validating: "styles/app.css", relativeTo: resourcesDirectory),
        output: .init(validating: "styles/app.generated.css", relativeTo: publicDirectory),
        options: .content("\(app.directory.viewsDirectory)**/*.leaf")
    )
}
