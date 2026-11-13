#!/usr/bin/env python3
"""Run the exact Swift core test bodies with CLT, which doesn't ship XCTest.

Full Xcode CI uses swift test. This adapter only supplies assertions and teardown.
"""
from pathlib import Path
import re
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
folder = root / 'artifacts/native-tests'
folder.mkdir(parents=True, exist_ok=True)
source = (root / 'Tests/AgentDeckCoreTests/CoreTests.swift').read_text()
methods = re.findall(r'func (test\w+)\(\)', source)
source = source.replace('import XCTest', 'import Foundation').replace('@testable import AgentDeckCore', '')
compat = r'''
var checkCount = 0
func evaluate<T>(_ body: () throws -> T) -> T { do { return try body() } catch { fatalError("Unexpected error: \(error)") } }
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    let lhs = evaluate(a), rhs = evaluate(b); checkCount += 1
    if lhs != rhs { fatalError("Expected \(rhs); got \(lhs) at \(file):\(line)") }
}
func XCTAssertTrue(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    checkCount += 1; if !evaluate(value) { fatalError("Expected true at \(file):\(line)") }
}
func XCTAssertFalse(_ value: @autoclosure () throws -> Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(!evaluate(value), file: file, line: line) }
func XCTAssertNil<T>(_ value: @autoclosure () throws -> T?, file: StaticString = #filePath, line: UInt = #line) {
    checkCount += 1; if evaluate(value) != nil { fatalError("Expected nil at \(file):\(line)") }
}
func XCTAssertThrowsError<T>(_ body: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    checkCount += 1
    do { _ = try body() } catch { return }; fatalError("Expected error at \(file):\(line)")
}
class XCTestCase {
    var cleanupBlocks: [() throws -> Void] = []
    func addTeardownBlock(_ body: @escaping () throws -> Void) { cleanupBlocks.append(body) }
    func cleanup() throws { for block in cleanupBlocks.reversed() { try block() }; cleanupBlocks = [] }
}
'''
runner = '\n'.join(f'try tests.{name}(); try tests.cleanup(); print("ok - {name}")' for name in methods)
(folder / 'main.swift').write_text('import Foundation\n' + compat + source + '\nlet tests = CoreTests()\n' + runner + '\nprint("Native checks: \\(checkCount)")\n')
cmd = ['swiftc', '-module-cache-path', str(folder / 'cache'), '-o', str(folder / 'checks')]
cmd += [str(p) for p in sorted((root / 'Sources/AgentDeckCore').glob('*.swift'))]
cmd += [str(folder / 'main.swift')]
subprocess.run(cmd, check=True)
subprocess.run([str(folder / 'checks')], check=True)
print(f'PASS: {len(methods)} Swift core tests using Command Line Tools assertion adapter')
