import XCTest
@testable import AgentSamCore

final class DSMLToolCallsTests: XCTestCase {
    private func arguments(_ call: APIToolCall) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8)) as? [String: Any])
    }

    /// The exact shape reported from a long Google Ads reply: two invokes inside a `calls` block, written with
    /// doubled full-width bars and spaces.
    func testParsesReportedGoogleAdsCalls() throws {
        let text = """
        Let me pull the asset group details. <｜｜DSML｜｜ calls> <｜｜DSML｜｜ invoke name="googleads_query"> <｜｜DSML｜｜ parameter name="customer_id" string="true">7569116792</｜｜DSML｜｜ parameter> <｜｜DSML｜｜ parameter name="query" string="true">SELECT asset_group.id, asset_group.name, asset_group.final_urls FROM asset_group WHERE asset_group.id = 6746718365</｜｜DSML｜｜ parameter> </｜｜DSML｜｜ invoke> <｜｜DSML｜｜ invoke name="googleads_query"> <｜｜DSML｜｜ parameter name="customer_id" string="true">7569116792</｜｜DSML｜｜ parameter> <｜｜DSML｜｜ parameter name="query" string="true">SELECT asset.id, asset.type, asset.text_asset.text FROM asset_group_asset WHERE asset_group.id = 6746718365 AND asset.type = 'TEXT' LIMIT 40</｜｜DSML｜｜ parameter> </｜｜DSML｜｜ invoke> </｜｜DSML｜｜ calls>
        """
        let extraction = try XCTUnwrap(DSMLToolCalls.extract(from: text))
        XCTAssertEqual(extraction.text, "Let me pull the asset group details.")
        XCTAssertEqual(extraction.calls.count, 2)
        XCTAssertEqual(extraction.calls.map(\.function.name), ["googleads_query", "googleads_query"])
        XCTAssertNotEqual(extraction.calls[0].id, extraction.calls[1].id)
        let first = try arguments(extraction.calls[0])
        XCTAssertEqual(first["customer_id"] as? String, "7569116792")
        XCTAssertEqual(first["query"] as? String, "SELECT asset_group.id, asset_group.name, asset_group.final_urls FROM asset_group WHERE asset_group.id = 6746718365")
        let second = try arguments(extraction.calls[1])
        XCTAssertEqual(second["query"] as? String, "SELECT asset.id, asset.type, asset.text_asset.text FROM asset_group_asset WHERE asset_group.id = 6746718365 AND asset.type = 'TEXT' LIMIT 40")
    }

    func testParsesCanonicalTemplateAndNonStringValues() throws {
        let text = """
        <｜DSML｜function_calls>
        <｜DSML｜invoke name="search">
        <｜DSML｜parameter name="q" string="true">swift regex</｜DSML｜parameter>
        <｜DSML｜parameter name="limit" string="false">5</｜DSML｜parameter>
        <｜DSML｜parameter name="filters" string="false">{"lang": "en"}</｜DSML｜parameter>
        </｜DSML｜invoke>
        </｜DSML｜function_calls>
        """
        let extraction = try XCTUnwrap(DSMLToolCalls.extract(from: text))
        XCTAssertEqual(extraction.text, "")
        let args = try arguments(try XCTUnwrap(extraction.calls.first))
        XCTAssertEqual(args["q"] as? String, "swift regex")
        XCTAssertEqual(args["limit"] as? Int, 5)
        XCTAssertEqual((args["filters"] as? [String: Any])?["lang"] as? String, "en")
    }

    func testTruncatedInvokeIsDroppedAndHidden() throws {
        let text = "Here is the plan.\n<｜DSML｜function_calls>\n<｜DSML｜invoke name=\"a\">\n<｜DSML｜parameter name=\"x\" string=\"true\">1</｜DSML｜parameter>\n</｜DSML｜invoke>\n<｜DSML｜invoke name=\"b\">\n<｜DSML｜parameter name=\"y\" string=\"true\">SELECT"
        let extraction = try XCTUnwrap(DSMLToolCalls.extract(from: text))
        XCTAssertEqual(extraction.text, "Here is the plan.")
        XCTAssertEqual(extraction.calls.map(\.function.name), ["a"])
    }

    func testTextWithoutMarkupIsUntouched() {
        XCTAssertNil(DSMLToolCalls.extract(from: "A normal answer with <b>html</b>."))
        XCTAssertEqual(DSMLToolCalls.strip("Plain"), "Plain")
    }

    func testNormalizeOnlyCreatesCallsWhenToolsWereOffered() {
        let content = "Checking.<｜DSML｜function_calls><｜DSML｜invoke name=\"t\"></｜DSML｜invoke></｜DSML｜function_calls>"
        let message = APIMessage(role: "assistant", content: content)

        let withTools = DSMLToolCalls.normalize(message, toolsOffered: true)
        XCTAssertEqual(withTools.content, "Checking.")
        XCTAssertEqual(withTools.tool_calls?.first?.function.name, "t")
        XCTAssertEqual(withTools.tool_calls?.first?.function.arguments, "{}")

        let withoutTools = DSMLToolCalls.normalize(message, toolsOffered: false)
        XCTAssertEqual(withoutTools.content, "Checking.")
        XCTAssertNil(withoutTools.tool_calls)
    }

    func testNormalizeKeepsStructuredCalls() {
        let structured = APIToolCall(id: "c1", function: .init(name: "real", arguments: "{}"))
        let message = APIMessage(role: "assistant", content: "<｜DSML｜invoke name=\"t\"></｜DSML｜invoke>", tool_calls: [structured])
        let normalized = DSMLToolCalls.normalize(message, toolsOffered: true)
        XCTAssertNil(normalized.content)
        XCTAssertEqual(normalized.tool_calls, [structured])
    }

    func testStreamFilterHidesMarkupSplitAcrossChunks() {
        final class Sink: @unchecked Sendable { var text = "" }
        let sink = Sink()
        let filter = DSMLStreamFilter { sink.text += $0 }
        for chunk in ["Results for a < b. Fetching", " now <", "｜DS", "ML｜function_calls><｜DSML｜invoke name=\"x\">", "secret</｜DSML｜invoke>", " trailing"] {
            filter.push(chunk)
        }
        XCTAssertEqual(sink.text, "Results for a < b. Fetching now ")
    }

    func testStreamFilterReleasesHeldAngleBracket() {
        final class Sink: @unchecked Sendable { var text = "" }
        let sink = Sink()
        let filter = DSMLStreamFilter { sink.text += $0 }
        filter.push("x <")
        XCTAssertEqual(sink.text, "x ")
        filter.push("= 3")
        XCTAssertEqual(sink.text, "x <= 3")
    }

    func testChatTurnsStripMarkupFromHistory() {
        let history = [
            ConversationMessage(role: .user, text: "Check my ads"),
            ConversationMessage(role: .assistant, text: "On it.<｜DSML｜function_calls><｜DSML｜invoke name=\"q\"></｜DSML｜invoke></｜DSML｜function_calls>"),
        ]
        let turns = ConversationEngine.chatTurns(from: history)
        XCTAssertEqual(turns.last?.content, "On it.")
    }
}
