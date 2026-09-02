import Testing

@testable import App

@Suite("Operation completion budgets")
struct OperationBudgetTests {
    @Test("Every resource and mutation pair has a positive budget")
    func allPairsHavePositiveBudgets() {
        for resource in OperationResourceKind.allCases {
            for mutation in VMOperationKind.allCases {
                #expect(resource.completionBudgetSeconds(for: mutation) > 0)
            }
        }
    }
}
