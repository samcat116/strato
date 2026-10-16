import StratoAPIClient

public enum GuestConfigurationOutput {
    public static func table(_ value: Components.Schemas.VMGuestConfiguration) -> TextTable {
        var table = TextTable(headers: ["item", "desired", "observed", "state"])
        table.addRow([
            "generation", String(value.desiredGeneration), value.observedGeneration.map(String.init) ?? "unknown",
            value.status.rawValue,
        ])
        for item in value.items {
            table.addRow([
                "\(item.section.rawValue) \(item.identity)", item.desired, item.observed ?? "unknown",
                item.state.rawValue,
            ])
        }
        if let failure = value.failureGeneration {
            table.addRow([
                "failure generation", String(failure), "", failure == value.desiredGeneration ? "current" : "older",
            ])
        }
        if let error = value.error { table.addRow(["failure", error, "", "failed"]) }
        return table
    }
}
