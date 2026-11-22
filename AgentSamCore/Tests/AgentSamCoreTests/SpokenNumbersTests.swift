import XCTest
@testable import AgentSamCore

final class SpokenNumbersTests: XCTestCase {
    private func es(_ text: String) -> String { SpokenNumbers.normalize(text, language: "es") }
    private func en(_ text: String) -> String { SpokenNumbers.normalize(text, language: "en") }

    // MARK: Spanish amounts

    func testCommaDecimalDollarsAreReadAsDollarsNotThousands() {
        XCTAssertEqual(es("Son $10,00 en total."), "Son diez dólares en total.")
        XCTAssertEqual(es("$1.234,56"), "mil doscientos treinta y cuatro dólares con cincuenta y seis centavos")
        XCTAssertEqual(es("$10,50"), "diez dólares con cincuenta centavos")
        XCTAssertEqual(es("$0,99"), "noventa y nueve centavos")
        XCTAssertEqual(es("$0,01"), "un centavo")
    }

    func testPeriodDecimalAmountsInSpanishStillWork() {
        // Mexico and the US write amounts the English way, even in Spanish.
        XCTAssertEqual(es("$1,234.56"), "mil doscientos treinta y cuatro dólares con cincuenta y seis centavos")
        XCTAssertEqual(es("$10.5"), "diez dólares con cincuenta centavos")
    }

    func testThreeDigitsAfterOneMarkGroupThousandsInSpanish() {
        XCTAssertEqual(es("$1.000"), "mil dólares")
        XCTAssertEqual(es("$1,000"), "mil dólares")
        XCTAssertEqual(es("Hubo 1.000 visitas"), "Hubo mil visitas")
        XCTAssertEqual(es("0,125"), "cero coma ciento veinticinco")
    }

    func testOneAndTwentyOneAgreeWithTheCurrency() {
        XCTAssertEqual(es("$1"), "un dólar")
        XCTAssertEqual(es("$21"), "veintiún dólares")
        XCTAssertEqual(es("£21"), "veintiuna libras")
        XCTAssertEqual(es("£200"), "doscientas libras")
        XCTAssertEqual(es("10,50 €"), "diez euros con cincuenta céntimos")
        XCTAssertEqual(es("$200 pesos"), "doscientos pesos")
        XCTAssertEqual(es("25 dólares"), "veinticinco dólares")
        XCTAssertEqual(es("$10 dólares"), "diez dólares")
        XCTAssertEqual(es("USD 5"), "cinco dólares")
    }

    func testMillionsTakeDeOnlyWhenRound() {
        XCTAssertEqual(es("$2.000.000"), "dos millones de dólares")
        XCTAssertEqual(es("$1.200.000"), "un millón doscientos mil dólares")
        XCTAssertEqual(es("$1,5 millones"), "uno coma cinco millones de dólares")
        XCTAssertEqual(es("$1,5 millones de dólares"), "uno coma cinco millones de dólares")
        XCTAssertEqual(es("$3 mil"), "tres mil dólares")
        XCTAssertEqual(es("$5 millas"), "cinco dólares millas")
    }

    // MARK: Spanish numbers

    func testPercentagesAndPlainNumbers() {
        XCTAssertEqual(es("Subió un 12,5 %."), "Subió un doce coma cinco por ciento.")
        XCTAssertEqual(es("50%"), "cincuenta por ciento")
        XCTAssertEqual(es("1,5 millones de personas"), "uno coma cinco millones de personas")
        XCTAssertEqual(es("1 millón"), "un millón")
        XCTAssertEqual(es("21 mil"), "veintiún mil")
        XCTAssertEqual(es("En 2026"), "En dos mil veintiséis")
        XCTAssertEqual(es("0,05"), "cero coma cero cinco")
        XCTAssertEqual(es("3,14159"), "tres coma uno cuatro uno cinco nueve")
    }

    func testSpanishWords() {
        let cases: [(UInt64, String)] = [
            (0, "cero"), (15, "quince"), (16, "dieciséis"), (22, "veintidós"), (31, "treinta y uno"),
            (100, "cien"), (101, "ciento uno"), (115, "ciento quince"), (500, "quinientos"), (999, "novecientos noventa y nueve"),
            (1000, "mil"), (2001, "dos mil uno"), (21000, "veintiún mil"), (100_000, "cien mil"),
            (1_000_000, "un millón"), (1_000_000_000, "mil millones"), (2_500_000, "dos millones quinientos mil"),
        ]
        for (number, words) in cases {
            XCTAssertEqual(SpokenNumbers.spanishWords(number), words, "\(number)")
        }
    }

    func testTimesDatesAndCodesAreLeftAlone() {
        XCTAssertEqual(es("A las 10:30 del 22/11/2026."), "A las 10:30 del 22/11/2026.")
        XCTAssertEqual(es("El 2026-11-22"), "El 2026-11-22")
        XCTAssertEqual(es("Versión 1.2.3 y 192.168.1.1"), "Versión 1.2.3 y 192.168.1.1")
        XCTAssertEqual(es("El 1º y la 2ª"), "El 1º y la 2ª")
        XCTAssertEqual(es("v2 y 10km"), "v2 y 10km")
    }

    // MARK: English

    func testEnglishRewritesOnlyCommaDecimalNumbers() {
        XCTAssertEqual(en("That's $10,00 total."), "That's $10.00 total.")
        XCTAssertEqual(en("€1.234,56"), "€1,234.56")
        XCTAssertEqual(en("about 1.234,56 units"), "about 1,234.56 units")
        XCTAssertEqual(en("1.234.567 people"), "1,234,567 people")
        XCTAssertEqual(en("$1,234.56 and $1,000"), "$1,234.56 and $1,000")
        XCTAssertEqual(en("The ratio is 1.000 and 1,5 more"), "The ratio is 1.000 and 1,5 more")
        XCTAssertEqual(en("No numbers here."), "No numbers here.")
    }

    // MARK: Language and the voice

    func testLanguageComesFromTheWordsThenTheFallback() {
        XCTAssertEqual(SpokenNumbers.language(of: "El total es $10,00", fallback: "en"), "es")
        XCTAssertEqual(SpokenNumbers.language(of: "The total is $10.00", fallback: "es"), "en")
        XCTAssertEqual(SpokenNumbers.language(of: "¿Cuánto?", fallback: "en"), "es")
        XCTAssertEqual(SpokenNumbers.language(of: "$10,00", fallback: "es"), "es")
        XCTAssertEqual(SpokenNumbers.language(of: "$10,00", fallback: nil), "en")
    }

    func testSpokenTextReadsAmountsInTheLanguageGiven() {
        XCTAssertEqual(SpeechClient.spokenText("**Total:** $10,00", language: "es"), "Total: diez dólares")
        XCTAssertEqual(SpeechClient.spokenText("El precio es **$1.234,56**.", language: "en"),
                       "El precio es mil doscientos treinta y cuatro dólares con cincuenta y seis centavos.")
        XCTAssertEqual(SpeechClient.spokenText("Total: $10,00"), "Total: $10,00")
        let once = SpeechClient.spokenText("It costs $1.234,56 today.", language: "en")
        XCTAssertEqual(once, "It costs $1,234.56 today.")
        XCTAssertEqual(SpeechClient.spokenText(once, language: "en"), once)
    }

    func testNumbersAreNeverSplitAcrossSpokenPieces() {
        XCTAssertEqual(SpeechClient.spokenChunks("It costs $1.234,56. Thanks.", firstLimit: 10, limit: 10), ["It costs $1.234,56.", "Thanks."])
        XCTAssertEqual(SpeechClient.cappedSpeech("Pay $10.50 now and more", tail: "T", limit: 12), "Pay $10.50 n T")
        XCTAssertEqual(SpeechClient.cappedSpeech("Pay $10.50 now. And more", tail: "T", limit: 18), "Pay $10.50 now. T")
    }
}
