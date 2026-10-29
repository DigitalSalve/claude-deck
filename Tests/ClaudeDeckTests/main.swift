import Darwin
// ClaudeDeck Test Runner
// Run with: swift run ClaudeDeckTests

runClaudeSessionTests()
runClaudePlanTests()
runSessionHistoryTests()
runModelCatalogTests()
runUsageWindowsTests()
runStatusLineTests()
runControlTests()
runCommandLogTests()
runUsageLedgerTests()
runLedgerThrottleTests()
runRealRangeProbe()
runTokenCacheTests()
runTerminalLauncherTests()
runQuotaAnalyzerTests()
runQuotaLiveStoreTests()
runSessionPromptReaderTests()
runSessionNumberRegistryTests()

// Summary
let total = passCount + failCount
print("\n─────────────────────────────────────────")
if failCount == 0 {
    print("✓ All \(total) tests passed")
} else {
    print("✗ \(failCount) failed, \(passCount) passed (\(total) total)")
}

exit(failCount > 0 ? 1 : 0)
