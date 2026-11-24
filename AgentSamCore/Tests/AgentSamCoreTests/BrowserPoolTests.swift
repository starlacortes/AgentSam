import XCTest
@testable import AgentSamCore

final class BrowserPoolTests: XCTestCase {
    func testEachAccountGetsItsOwnPortsAndUnit() {
        let first = BrowserPool.ports(uid: 1001)
        let second = BrowserPool.ports(uid: 1002)
        XCTAssertEqual(first.vnc, 32_002)
        XCTAssertEqual(first.agent, 32_003)
        XCTAssertEqual(second.vnc, 32_004)
        XCTAssertNotEqual(first.agent, second.vnc, "neighbours never share a port")
        XCTAssertFalse([first.vnc, first.agent].contains(BrowserConfig.defaultPort), "never Ada's own browser's ports")
        XCTAssertTrue((30_000...49_999).contains(BrowserPool.ports(uid: 9_999).agent))
        XCTAssertEqual(BrowserPool.service(account: "adau0123456789ab"), "ada-browser@adau0123456789ab.service")
        XCTAssertTrue(BrowserConfig.validService(BrowserPool.service(account: "adau0123456789ab")))
    }

    func testPreparedOutputIsReadStrictly() {
        let good = BrowserPool.parsePrepared("__ADA_BROWSER_PASSWORD Ab3dE6gH\n__ADA_BROWSER_UID 1004\nRan on adau0123456789ab@kokofast.")
        XCTAssertEqual(good?.password, "Ab3dE6gH")
        XCTAssertEqual(good?.uid, 1004)
        XCTAssertNil(BrowserPool.parsePrepared("__ADA_BROWSER_UID 1004"), "no password, no browser")
        XCTAssertNil(BrowserPool.parsePrepared("__ADA_BROWSER_PASSWORD a b;c\n__ADA_BROWSER_UID 1004"))
        XCTAssertNil(BrowserPool.parsePrepared("__ADA_BROWSER_PASSWORD Ab3dE6gH\n__ADA_BROWSER_UID root"))
    }

    func testOpenBrowsersAreCounted() {
        let open = BrowserPool.parseOpen("__ADA_BROWSERS_OPEN 3\n__ADA_BROWSER_SELF_ON\nRan on ada@kokofast.")
        XCTAssertEqual(open?.others, 3)
        XCTAssertEqual(open?.selfOn, true)
        XCTAssertEqual(BrowserPool.parseOpen("__ADA_BROWSERS_OPEN 0")?.selfOn, false)
        XCTAssertNil(BrowserPool.parseOpen("ssh: connect to host kokofast port 22: Connection timed out"))
        let script = BrowserPool.openScript(service: "ada-browser@adau0123456789ab.service")
        XCTAssertTrue(script.contains("grep -cvxF 'ada-browser@adau0123456789ab.service'"), script)
    }

    func testAStartRefusedByTheCheckRunsNothing() async {
        let ran = Ran()
        let link = BrowserLink(config: BrowserConfig(enabled: true, service: "ada-browser@adau0123456789ab.service"), run: { script in
            await ran.add(script)
            return ToolOutcome(resultText: BrowserLink.onMarker)
        }, token: "Ab3dE6gH", startCheck: { "3 people's browsers are already open." })
        let outcome = await link.start()
        XCTAssertFalse(outcome.succeeded)
        XCTAssertTrue(outcome.resultText.contains("already open"))
        let scripts = await ran.scripts
        XCTAssertTrue(scripts.isEmpty)
        XCTAssertEqual(link.password, "Ab3dE6gH")
    }
}

private actor Ran {
    var scripts: [String] = []
    func add(_ script: String) { scripts.append(script) }
}
