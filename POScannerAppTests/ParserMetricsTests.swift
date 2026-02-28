import Foundation
import ShopmikeyCoreModels
import Testing

struct ParserMetricsTests {
    @Test func parserMetricsReportIsGeneratedAndThresholdCanGate() throws {
        let fixtures = try ParserFixtureLoader.loadAll()
        #expect(!fixtures.isEmpty, "Parser corpus must include at least one fixture case.")

        let metrics = try ParserMetricsEvaluator.evaluate(fixtures: fixtures)
        let outputs = try ParserMetricsEvaluator.writeReports(metrics: metrics)

        #expect(FileManager.default.fileExists(atPath: outputs.markdownPath.path), "Missing metrics markdown report at \(outputs.markdownPath.path)")
        #expect(FileManager.default.fileExists(atPath: outputs.jsonPath.path), "Missing metrics JSON report at \(outputs.jsonPath.path)")

        if let threshold = ParserMetricsEvaluator.parseThreshold() {
            let overallF1 = String(format: "%.3f", metrics.overall.f1)
            let thresholdText = String(format: "%.3f", threshold)
            #expect(
                metrics.overall.f1 >= threshold,
                "Parser metrics threshold failed. overall_f1=\(overallF1) threshold=\(thresholdText)."
            )
        }
    }

    @Test func fieldMatchCalculatesPrecisionRecallAndF1Deterministically() {
        var match = FieldMatch(truePositive: 2, falsePositive: 1, falseNegative: 1)
        #expect(abs(match.precision - (2.0 / 3.0)) < 0.0001)
        #expect(abs(match.recall - (2.0 / 3.0)) < 0.0001)
        #expect(abs(match.f1 - (2.0 / 3.0)) < 0.0001)

        match.add(FieldMatch(truePositive: 1, falsePositive: 0, falseNegative: 2))
        #expect(match.truePositive == 3)
        #expect(match.falsePositive == 1)
        #expect(match.falseNegative == 3)
    }
}
