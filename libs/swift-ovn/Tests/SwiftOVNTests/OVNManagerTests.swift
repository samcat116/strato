import XCTest
import NIO
@testable import OVNManager

final class OVNManagerTests: XCTestCase {
    
    func testJSONRPCRequest() throws {
        let request = JSONRPCRequest(
            method: "list_dbs",
            params: nil,
            id: .string("test-1")
        )
        
        XCTAssertEqual(request.jsonrpc, "2.0")
        XCTAssertEqual(request.method, "list_dbs")
        XCTAssertNil(request.params)
        
        if case .string(let id) = request.id {
            XCTAssertEqual(id, "test-1")
        } else {
            XCTFail("Expected string ID")
        }
    }
    
    func testJSONValueEncodingDecoding() throws {
        let testCases: [JSONValue] = [
            .null,
            .boolean(true),
            .number(42.5),
            .string("hello"),
            .array([.string("a"), .number(1), .boolean(false)]),
            .object(["key": .string("value"), "number": .number(123)])
        ]
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        for testValue in testCases {
            let encoded = try encoder.encode(testValue)
            let decoded = try decoder.decode(JSONValue.self, from: encoded)
            XCTAssertEqual(testValue, decoded)
        }
    }
    
    func testOVNLogicalSwitchCreation() throws {
        let logicalSwitch = OVNLogicalSwitch(
            name: "test-switch",
            external_ids: ["test": "value"]
        )
        
        XCTAssertEqual(logicalSwitch.name, "test-switch")
        XCTAssertEqual(logicalSwitch.external_ids?["test"], "value")
        XCTAssertNil(logicalSwitch.uuid)
    }
    
    func testOVSBridgeCreation() throws {
        let bridge = OVSBridge(
            name: "br-test",
            fail_mode: "secure",
            external_ids: ["description": "Test bridge"]
        )
        
        XCTAssertEqual(bridge.name, "br-test")
        XCTAssertEqual(bridge.fail_mode, "secure")
        XCTAssertEqual(bridge.external_ids?["description"], "Test bridge")
    }
    
    func testOVSDBConditionCreation() throws {
        let condition = OVSDBCondition.equal(column: "name", to: "test-value")
        
        XCTAssertEqual(condition.column, "name")
        XCTAssertEqual(condition.function, "==")
        
        if case .string(let value) = condition.value {
            XCTAssertEqual(value, "test-value")
        } else {
            XCTFail("Expected string value")
        }
    }
    
    func testOVSDBMutationCreation() throws {
        let mutation = OVSDBMutation.add(column: "count", value: 5)
        
        XCTAssertEqual(mutation.column, "count")
        XCTAssertEqual(mutation.mutator, "+=")
        
        if case .number(let value) = mutation.value {
            XCTAssertEqual(value, 5.0)
        } else {
            XCTFail("Expected number value")
        }
    }
    
    func testJSONValueSetHandling() throws {
        let stringSet = JSONValue.set(["a", "b", "c"])
        let setValues = stringSet.setStringValues
        
        XCTAssertEqual(setValues?.count, 3)
        XCTAssertTrue(setValues?.contains("a") == true)
        XCTAssertTrue(setValues?.contains("b") == true)
        XCTAssertTrue(setValues?.contains("c") == true)
    }
    
    func testJSONValueMapHandling() throws {
        let stringMap = JSONValue.map(["key1": "value1", "key2": "value2"])
        let mapValues = stringMap.mapStringValues
        
        XCTAssertEqual(mapValues?.count, 2)
        XCTAssertEqual(mapValues?["key1"], "value1")
        XCTAssertEqual(mapValues?["key2"], "value2")
    }
    
    func testJSONValueUUIDHandling() throws {
        let uuidValue = JSONValue.uuid("12345678-1234-5678-9abc-123456789012")
        let extractedUUID = uuidValue.uuidValue
        
        XCTAssertEqual(extractedUUID, "12345678-1234-5678-9abc-123456789012")
    }
    
    func testOVNACLCreation() throws {
        let acl = OVNACL(
            priority: 1000,
            direction: "to-lport",
            match: "ip4.src == 192.168.1.0/24",
            action: "allow",
            log: true,
            name: "test-acl"
        )
        
        XCTAssertEqual(acl.priority, 1000)
        XCTAssertEqual(acl.direction, "to-lport")
        XCTAssertEqual(acl.match, "ip4.src == 192.168.1.0/24")
        XCTAssertEqual(acl.action, "allow")
        XCTAssertEqual(acl.log, true)
        XCTAssertEqual(acl.name, "test-acl")
    }
    
    func testOVNLoadBalancerCreation() throws {
        let loadBalancer = OVNLoadBalancer(
            name: "test-lb",
            vips: ["192.168.1.100:80": "192.168.1.10:8080,192.168.1.11:8080"],
            protocolType: "tcp"
        )
        
        XCTAssertEqual(loadBalancer.name, "test-lb")
        XCTAssertEqual(loadBalancer.vips.count, 1)
        XCTAssertEqual(loadBalancer.vips["192.168.1.100:80"], "192.168.1.10:8080,192.168.1.11:8080")
        XCTAssertEqual(loadBalancer.protocolType, "tcp")
    }
    
    func testOVSFlowBuilder() throws {
        let flow = OVSFlowBuilder()
            .table(0)
            .priority(1000)
            .match("in_port=1")
            .actions("output:2")
            .idleTimeout(60)
            .build()
        
        XCTAssertEqual(flow.table, 0)
        XCTAssertEqual(flow.priority, 1000)
        XCTAssertEqual(flow.match, "in_port=1")
        XCTAssertEqual(flow.actions, "output:2")
        XCTAssertEqual(flow.idle_timeout, 60)
    }
    
    func testJSONRPCErrorHandling() throws {
        let error = JSONRPCError(
            code: -32600,
            message: "Invalid Request",
            data: .string("Additional error information")
        )
        
        XCTAssertEqual(error.code, -32600)
        XCTAssertEqual(error.message, "Invalid Request")
        
        if case .string(let data) = error.data {
            XCTAssertEqual(data, "Additional error information")
        } else {
            XCTFail("Expected string data")
        }
    }
    
    func testOVNManagerError() throws {
        let connectionError = OVNManagerError.connectionFailed("Socket not found")
        let timeoutError = OVNManagerError.timeoutError
        
        switch connectionError {
        case .connectionFailed(let message):
            XCTAssertEqual(message, "Socket not found")
        default:
            XCTFail("Expected connection failed error")
        }
        
        switch timeoutError {
        case .timeoutError:
            break // Expected
        default:
            XCTFail("Expected timeout error")
        }
    }
}

// MARK: - Mock Tests

final class JSONRPCClientMockTests: XCTestCase {
    
    func testJSONRPCRequestSerialization() throws {
        let request = JSONRPCRequest(
            method: "transact",
            params: .array([.string("OVN_Northbound"), .object(["op": .string("select"), "table": .string("Logical_Switch")])]),
            id: .number(1)
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        
        // Verify that the JSON can be decoded back
        let decoder = JSONDecoder()
        let decodedRequest = try decoder.decode(JSONRPCRequest.self, from: data)
        
        XCTAssertEqual(decodedRequest.method, request.method)
        XCTAssertEqual(decodedRequest.jsonrpc, request.jsonrpc)
    }
    
    func testOVSDBOperationSerialization() throws {
        let operation = OVSDBOperation(
            op: "select",
            table: "Logical_Switch",
            whereConditions: [OVSDBCondition(column: "name", function: "==", value: .string("test"))],
            columns: ["name", "ports"]
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(operation)
        
        let decoder = JSONDecoder()
        let decodedOperation = try decoder.decode(OVSDBOperation.self, from: data)
        
        XCTAssertEqual(decodedOperation.op, operation.op)
        XCTAssertEqual(decodedOperation.table, operation.table)
        XCTAssertEqual(decodedOperation.columns, operation.columns)
    }
    
    func testMonitorRequestSerialization() throws {
        let monitorRequest = OVSDBMonitorRequest(
            columns: ["name", "ports"],
            select: OVSDBMonitorSelect(initial: true, insert: true, delete: true, modify: true)
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(monitorRequest)
        
        let decoder = JSONDecoder()
        let decodedRequest = try decoder.decode(OVSDBMonitorRequest.self, from: data)
        
        XCTAssertEqual(decodedRequest.columns, monitorRequest.columns)
        XCTAssertEqual(decodedRequest.select?.initial, monitorRequest.select?.initial)
    }
}