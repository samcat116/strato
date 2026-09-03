# Strato agent tests

The agent package uses Swift Testing for unit, contract, and host-gated
integration coverage. Run the complete package suite from the repository root:

```bash
swift test --package-path agent
```

Use `--filter <suite-or-test>` for a focused run. The suite is split into
`StratoAgentTests` (core planning and protocols), `StratoAgentPlatformTests`,
`StratoAgentStorageTests`, `StratoAgentSPIFFETests`, and
`StratoAgentRuntimeTests`. Runtime tests import `StratoAgentRuntime`; the
`StratoAgent` executable contains only the process entry point. Domain XML
tests import the `StratoAgentDomainXML` leaf directly when they exercise its
package-internal parser.

Shared fakes and fixtures live beside their domain tests. Domain XML golden
files live in `StratoAgentTests/Goldens/DomainXML`.
Some Linux driver suites require their named host tools or services and report
those requirements in the test source.
