import XCTest
@testable import NitidoUI

/// Spec 11: the connect moment's gold ring plays once per connection, and Reduce Motion removes it.
final class ConnectRingTests: XCTestCase {
    /// Spec 11, "accessibilityReduceMotion removes the scale and the ring", and docs/testing.md item 35: no ring at all,
    /// not one drawn without its animation.
    func testReduceMotionRemovesTheRing() {
        XCTAssertEqual(ConnectRing.start(trigger: 1, shownFor: 0, reduceMotion: true), .hidden, "a new connection")
        XCTAssertEqual(ConnectRing.start(trigger: 3, shownFor: 3, reduceMotion: true), .hidden, "a connection shown before")
    }

    /// Spec 11, "it plays once per connection": a connection the ring has played for draws it at rest when the screen is
    /// shown again (⌘⇧V, then ⌘N), and only a new connection (a viewer taking over, a reconnect) plays it again.
    func testTheRingPlaysOncePerConnection() {
        XCTAssertEqual(ConnectRing.start(trigger: 1, shownFor: 0, reduceMotion: false), .animate, "the first connection")
        XCTAssertEqual(ConnectRing.start(trigger: 1, shownFor: 1, reduceMotion: false), .drawn, "the screen shown again")
        XCTAssertEqual(ConnectRing.start(trigger: 2, shownFor: 1, reduceMotion: false), .animate, "a new viewer or a reconnect")
    }
}
