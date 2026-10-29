import Foundation

// Minimal test harness — no XCTest or Testing framework required.

var passCount = 0
var failCount = 0

func expect(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition {
        print("  ✓ \(message)")
        passCount += 1
    } else {
        let filename = URL(fileURLWithPath: file).lastPathComponent
        print("  ✗ \(message)  [\(filename):\(line)]")
        failCount += 1
    }
}

func expectEqual<T: Equatable>(_ a: T, _ b: T, _ message: String, file: String = #file, line: Int = #line) {
    if a == b {
        print("  ✓ \(message)")
        passCount += 1
    } else {
        let filename = URL(fileURLWithPath: file).lastPathComponent
        print("  ✗ \(message): got \(a), expected \(b)  [\(filename):\(line)]")
        failCount += 1
    }
}

func expectNil<T>(_ value: T?, _ message: String, file: String = #file, line: Int = #line) {
    if value == nil {
        print("  ✓ \(message)")
        passCount += 1
    } else {
        let filename = URL(fileURLWithPath: file).lastPathComponent
        print("  ✗ \(message): expected nil but got \(value!)  [\(filename):\(line)]")
        failCount += 1
    }
}

func suite(_ name: String, _ block: () -> Void) {
    print("\n\(name)")
    fflush(stdout)
    block()
    fflush(stdout)
}
