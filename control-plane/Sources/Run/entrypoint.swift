import App

@main
enum Entrypoint {
    static func main() async throws {
        try await ControlPlaneMain.run()
    }
}
