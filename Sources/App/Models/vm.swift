import Fluent
import Vapor

final class VM: Model {
    static let schema = "vms"

    @ID(key: .id)
    var id: UUID?

    @Field(key: "name")
    var name: String

    @Field(key: "description")
    var description: String

    @Field(key: "image")
    var image: String

    @Field(key: "cpu")
    var cpu: Int

    @Field(key: "memory")
    var memory: Int

    @Field(key: "disk")
    var disk: Int

    init() {}

    init(
        id: UUID? = nil, name: String, description: String, image: String, cpu: Int, memory: Int,
        disk: Int
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.image = image
        self.cpu = cpu
        self.memory = memory
        self.disk = disk
    }
}

extension VM: Content {}
