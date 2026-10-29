import ClaudeDeckCore

func runClaudePlanTests() {
    suite("ClaudePlan — Plan Units") {
        expectEqual(ClaudePlan.free.sessionPlanUnits,   4_400,   "Free plan units")
        expectEqual(ClaudePlan.pro.sessionPlanUnits,    44_000,  "Pro plan units")
        expectEqual(ClaudePlan.max5x.sessionPlanUnits,  88_000,  "Max 5x plan units")
        expectEqual(ClaudePlan.max20x.sessionPlanUnits, 220_000, "Max 20x plan units")
    }

    suite("ClaudePlan — Output Token Limit (7× multiplier)") {
        for plan in ClaudePlan.allCases {
            expectEqual(plan.sessionOutputTokenLimit, plan.sessionPlanUnits * 7,
                        "\(plan.rawValue) output limit is 7× plan units")
        }
        expectEqual(ClaudePlan.max20x.sessionOutputTokenLimit, 1_540_000, "Max 20x output limit = 1.54M")
    }

    suite("ClaudePlan — Calibration Formula") {
        // Observed: 263K output tokens ≈ 17% of Max 20x (1.54M ceiling)
        let fraction = Double(263_000) / Double(ClaudePlan.max20x.sessionOutputTokenLimit)
        expect(abs(fraction - 0.17) < 0.01, "263K output ≈ 17% of Max 20x limit")
    }

    suite("ClaudePlan — Raw Values") {
        expectEqual(ClaudePlan.free.rawValue,   "Free",   "Free rawValue")
        expectEqual(ClaudePlan.pro.rawValue,    "Pro",    "Pro rawValue")
        expectEqual(ClaudePlan.max5x.rawValue,  "Max 5x", "Max 5x rawValue")
        expectEqual(ClaudePlan.max20x.rawValue, "Max 20x","Max 20x rawValue")
        expectEqual(ClaudePlan(rawValue: "Pro"),     .pro,    "init from Pro")
        expectEqual(ClaudePlan(rawValue: "Max 20x"), .max20x, "init from Max 20x")
        expectNil(ClaudePlan(rawValue: "Unknown"), "nil for unknown rawValue")
        expectEqual(ClaudePlan.allCases.count, 4, "4 plan cases")
    }
}
