import Foundation

public struct OVSDBUpdate: Codable {
    public let old: OVSDBRow?
    public let new: OVSDBRow?
    
    public init(old: OVSDBRow? = nil, new: OVSDBRow? = nil) {
        self.old = old
        self.new = new
    }
}