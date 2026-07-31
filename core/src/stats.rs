//! Usage arithmetic shown in onboarding and the Insights pane.

/// Hours of typing saved per week, given hours spent typing per day.
///
/// Speech runs about 4x the speed of typing, so roughly three quarters of typing
/// time comes back. Ported from `hoursSavedPerWeek` in `OnboardingModel.swift`;
/// both platforms must show the same number.
pub fn hours_saved_per_week(typing_hours_per_day: f64) -> f64 {
    typing_hours_per_day * 0.75 * 7.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn matches_the_swift_implementation() {
        // Same assertion as OnboardingModel.selfTest().
        assert!((hours_saved_per_week(3.0) - 15.75).abs() < 0.001);
    }

    #[test]
    fn zero_typing_saves_nothing() {
        assert_eq!(hours_saved_per_week(0.0), 0.0);
    }
}
