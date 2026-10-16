# Conservative test-suite trimming

This tranche removes repeated executions and weaker tests while keeping the
production behavior covered by stronger existing scenarios. It changes no
production code or CI execution policy. Counts compare against `2787c834`
(including the inventory transaction fix, #1479).

| Surface | Declarations before → after | Expanded source cases before → after |
| --- | ---: | ---: |
| Control plane | 2,980 → 2,941 | 3,213 → 3,158 |
| Agent | 2,083 → 2,082 | 2,342 + host cases → 2,300 + host cases |
| Shared | 318 → 313 | 418 → 413 |
| CLI | 62 → 60 | 90 → 75 |
| SwiftFirecracker | 74 → 72 | 74 → 72 |
| Web Vitest | 107 → 104 | 123 → 117 |
| Rust guest | 102 → 96 | 102 → 96 |
| **Reduction** | **58 declarations** | **131 cases** |

The Swift API client, Playwright, Python and script scenarios are unchanged.
Counts are the union of source branches, before platform/host gates: for
example, two Rust root-only tests remain explicitly ignored by default.
Parameterized rows count individually; loops are not relabeled as fewer tests.
The five host-dependent libvirt matrices are unchanged.

## Retained coverage owners

Paths below are relative to each package's `Tests` directory.

| Removed or reduced tests | Stronger retained owner |
| --- | --- |
| Eight healthy timestamp/shape/MIME/dependency fixtures in `AppPlatformTests/HealthControllerTests` | `testLivenessHealthy`, `testReadinessHealthy`, `testHealthCarriesIdentity`; timestamps, JSON type, unique complete dependency set and all-up status asserted on the existing requests. Every degraded/drain/session failure remains. |
| Four fixture-only quota/group/VM/path checks in `AppIAMTests/HierarchyIntegrationTests` | Actual quota admission/enforcement, Cedar group authorization, VM create and hierarchy parentage/search suites. The removed checks only inspected rows or paths constructed by `TestDataBuilder`. Both hierarchy search routes remain. |
| Two basic project creates in `AppIAMTests/ProjectTests` | `testCreateProjectPersistsOrganizationParentage`, `testCreateProjectInOUPersistsOUParentage`; response fields/environments now checked alongside durable parentage and creator binding. |
| Two valid-key fixtures in `AppIdentityTests/APIKeyAuthenticatorTests` | `testAPIKeyStorage` checks both stored credential and associated username/email in the same authenticated request. Expiry, inactive/malformed credentials, transport restrictions and denial/audit cases remain. |
| OIDC Base64 passthrough happy tests | Shared `Base64URLTests`; App's malformed-input-to-Abort translation remains tested. |
| `RoleNestingSubsumptionTests` synthetic flat action policies | `CedarSchemaTests.seededRoleChainNested` and `SwiftCedarEngineTests.roleActionEnumeration` check set nesting and actual assembled policies. Conditioned guardrail/write-report solver coverage remains. |
| Registration Boolean grammar 13 rows → 3 | True, false and one invalid value cover App's configuration wiring. Default, endpoint refusal, bootstrap concurrency and username-oracle tests remain. |
| Three repeated `AppResourceTests/ImageControllerTests` uploads, artifact extension rows 3 → 1 | `testCreateImageUploadSuccess` includes persisted QCOW virtual size; `testUploadStoresExactBytes` includes streamed length and independently computed SHA-256; `testUploadWithoutFormatDetectsRaw` remains. Every-format filename validation stays in the leaf validator. |
| Seven one-field/default `VMSpecBuilderTests` | `testCompleteSpec`, `testMinimalSpec`, `testImageBasedSpec`, `testVolumeConfiguration` retain nondefault/default mapping and writable managed boot-volume assertions. |
| Six `ImageValidationServiceTests` declarations / ten cases | Every-format disk/artifact extension contracts, exact VHDX detection, truncated buffer and positive filesystem probes. Unsafe filename/QCOW-reference/boundary cases remain. |
| Two `ImageObjectStoreTests` duplicates, one `ByteConversionTests` roundtrip | Existing nested-path write/read, exact disk/rootfs key contract and direct conversion checks. Atomicity, rollback, terminal races, integer overflow and non-finite bounds remain. |
| Shared metadata NIC/identity and JSONValue duplicate full-fixture roundtrips | `InstanceMetadataTests.metadataRoundTrip` compares the full Equatable envelope; `JSONValueTests.roundTripsEveryJSONKind` covers mixed nested kinds. Custom decode behavior remains. |
| Two identical missing-field reconciliation decodes | `ReconciliationProtocolTests.observedStateResourceTelemetryRoundTrip` checks absent telemetry, guest info, memory stats and applied interface defaults together. |
| Agent log-level wiring 3 rows → 1 at TOML/environment/CLI boundaries | One valid value at each adapter; the authoritative parser still checks all seven supported levels. Invalid inputs and precedence remain. |
| Domain XML `isWellFormed`, root-order 11 → 2, NVRAM matrices 11 → 3 each | `DomainRedefinitionTests.goldensRoundTrip` parses all eleven same documents and checks tree preservation. All eleven exact goldens remain. Root order covers both architectures; NVRAM tests require an element on autoselect/resolved/Secure Boot branches instead of returning without an assertion. |
| Firecracker duplicated argv matcher and value-record readback | `ProcessSupervisionTests.argvMatching` has the same matcher examples plus empty argv. OS inventory, ownership, parsing and lifecycle/concurrency cases remain. |
| CLI common stream/parser/retry/cancel VM/sandbox cross products | Both-resource `multiplexedSession` and authorization cases retain route contracts; shared stream behaviors run once. Sandbox accepted-wake branches remain. All six malformed-session behaviors remain. |
| CLI raw-terminal/refusal/waiter duplicates | `stalledHandshakeCancellation` checks raw terminal restoration through the connector; one 400 plus distinct 403/404/503 remain; `testWaitsForSuccess` now checks volume/create decoding during pending→success. |
| Web nav literal copies and exported warning literal | Storage inventory component test checks the warning, actual confirmation and mutation target. UI permission guards remain. |
| Rust Base64 passthrough, duplicate exec/ping/status self-roundtrips, extra schema rejection sample | Literal wire/default/nonce/limit contracts, real Unix-socket ping/status/exec, and immediately older/newer schema rejection remain. Linux ABI, subprocess/PTY and root admission tests remain. |

The reductions eliminate **21 configured database-backed app lifecycles**:
health 8, hierarchy 4, project 2, authentication 2, duplicate uploads 3,
and artifact extension rows 2. This is a static fixture invocation count;
it is not 21 equal-cost runtime units.

`VMSpecTests.unknownBootSourceCaseThrows` is also repaired: start with an encoded
valid current spec, mutate only its boot case, and require the decoding error
to identify `boot`. Missing unrelated required fields can no longer satisfy it.

Inventory single-connection/production-timeout/nested-transaction cases and
placement retry/generation/replay/cleanup regressions are unchanged.

## Keeping the suite focused

- Name the production branch or failure and its owning test layer.
- Assert related response fields on one rich existing fixture for that state.
- Keep exhaustive leaf validation cheap; retain representative route attachment
  and real persistence/transaction wiring separately.
- Add matrix axes for demonstrated interactions, not every unrelated feature.
- When a stronger regression lands, explicitly retire its weaker predecessor.
- Negative tests start from valid input, mutate one thing and check the intended error.
- Track declarations, expanded cases, fixtures, skips, compilation, execution
  and runner queue separately. Parameterization alone is not a reduction.

Swift PR validation does not compile or run test targets. These cuts primarily
reduce maintenance and local/manual test work; they do not halve ordinary PR
Actions costs. Focused validation and measured timings belong in the PR rather
than treating source counts as runtime predictions.

A single paired local health-suite benchmark used the same package path,
Swift 6.4/macOS and dedicated PostgreSQL 14 cluster: 21 → 13 functions,
8.874s → 5.551s reported test execution (3.323s saved). Build steps were
9.80s and 6.66s; changed-target and cache state differ, so this is not a
compilation benchmark. This small comparison does not predict full-suite
or Actions savings. The production database platform is PostgreSQL 15.
