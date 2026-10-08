import XCTest
@testable import PhoneboothApp

final class AgentRunnerTests: XCTestCase {
    func testBuildsWhenNothingIsBuiltYet() {
        XCTAssertTrue(AgentRunner.needsBuild(status: 3, output: "ERROR: WebDriverAgent isn't built yet."))
    }

    func testBuildsWhenThePhoneIsNotCoveredBySigning() {
        XCTAssertTrue(AgentRunner.needsBuild(status: 65, output: "error: The provisioning profile doesn't include the device"))
        XCTAssertTrue(AgentRunner.needsBuild(status: 65, output: "The application could not be verified."))
    }

    func testDoesNotRebuildForOrdinaryStops() {
        XCTAssertFalse(AgentRunner.needsBuild(status: 15, output: "Testing cancelled"))
        XCTAssertFalse(AgentRunner.needsBuild(status: 65, output: "Lost connection to the device"))
    }

    func testSummarisesTheLastErrorLine() {
        let output = "Building...\nerror: first problem\nsomething\nerror: the real problem\ndone"
        XCTAssertEqual(AgentRunner.summary(of: output), "error: the real problem")
        XCTAssertEqual(AgentRunner.summary(of: "just this"), "just this")
        XCTAssertEqual(AgentRunner.summary(of: ""), "The phone helper stopped")
    }

    func testAcceptsAHelperListeningOnTheTunnelAddress() {
        let line = "2026-10-08 20:12:26.123 WebDriverAgentRunner-Runner[412:9081] ServerURLHere->http://fde5:3a75:9ac2::1:8100<-ServerURLHere"
        XCTAssertTrue(AgentRunner.helperListens(onlyOn: "fde5:3a75:9ac2::1", serverURLLine: line))
        XCTAssertTrue(AgentRunner.helperListens(onlyOn: "10.0.0.2", serverURLLine: "ServerURLHere->http://10.0.0.2:8100<-ServerURLHere"))
    }

    func testRejectsAHelperThatIgnoredTheTunnelAddress() {
        // Without USE_IP, WebDriverAgent logs the phone's Wi-Fi address (or loopback) and listens everywhere.
        let wifi = "ServerURLHere->http://192.168.1.23:8100<-ServerURLHere"
        XCTAssertFalse(AgentRunner.helperListens(onlyOn: "fde5:3a75:9ac2::1", serverURLLine: wifi))
        let loopback = "ServerURLHere->http://127.0.0.1:8100<-ServerURLHere"
        XCTAssertFalse(AgentRunner.helperListens(onlyOn: "fde5:3a75:9ac2::1", serverURLLine: loopback))
        let longerAddress = "ServerURLHere->http://fde5:3a75:9ac2::10:8100<-ServerURLHere"
        XCTAssertFalse(AgentRunner.helperListens(onlyOn: "fde5:3a75:9ac2::1", serverURLLine: longerAddress))
        XCTAssertFalse(AgentRunner.helperListens(onlyOn: "fde5:3a75:9ac2::1", serverURLLine: "ServerURLHere->http://fde5:3a75:9ac2::1:8100"))
        XCTAssertFalse(AgentRunner.helperListens(onlyOn: "", serverURLLine: "ServerURLHere->http://:8100<-ServerURLHere"))
    }
}
