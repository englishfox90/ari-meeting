//
//  TranscriptLanguageDetectorTests.swift — the on-device transcript-language detector that lets an
//  English meeting skip SummaryGenerator's redundant normalize-English second pass.
//
import Testing
@testable import AriKit

@Suite("Transcript language detector")
struct TranscriptLanguageDetectorTests {
    @Test("A clearly-English transcript detects as en (→ skips the normalize pass)")
    func detectsEnglish() {
        let text = """
        [00:01] Amy: Good morning, I think the department reorganization is going well.
        [00:12] Paul: Great. Let's make sure the approval screen adds the VIN and the make and model.
        [00:30] Amy: Agreed. I'll email the contact about the sync issue on the daily report tab.
        """
        #expect(TranscriptLanguageDetector.detect(text) == "en")
    }

    @Test("Too little alphabetic text returns nil (→ keeps the safe normalize default)")
    func shortTextIsNil() {
        #expect(TranscriptLanguageDetector.detect("[00:01] ok.") == nil)
        #expect(TranscriptLanguageDetector.detect("") == nil)
    }

    @Test("A clearly-non-English transcript never returns English")
    func nonEnglishIsNotEnglish() {
        let spanish = """
        [00:01] Amy: Buenos días, creo que la reorganización del departamento va muy bien.
        [00:12] Paul: Perfecto. Asegurémonos de que la pantalla de aprobación añada el número de identificación.
        [00:30] Amy: De acuerdo. Enviaré un correo al contacto sobre el problema de sincronización.
        """
        #expect(TranscriptLanguageDetector.detect(spanish) != "en")
    }
}
