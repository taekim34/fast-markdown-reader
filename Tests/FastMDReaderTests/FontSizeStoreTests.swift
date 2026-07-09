import XCTest
@testable import FastMDReader

final class FontSizeStoreTests: XCTestCase {
    override func setUp() { UserDefaults.standard.removeObject(forKey: "baseFontSize") }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: "baseFontSize") }

    func testDefaultIs15() { XCTAssertEqual(FontSizeStore.size, 15) }

    func testIncreaseAndPersist() {
        FontSizeStore.increase()
        XCTAssertEqual(FontSizeStore.size, 16)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "baseFontSize"), 16)
    }

    func testClampUpper() {
        FontSizeStore.size = 100
        XCTAssertEqual(FontSizeStore.size, 36)
    }

    func testClampLower() {
        FontSizeStore.size = 1
        XCTAssertEqual(FontSizeStore.size, 10)
    }
}
