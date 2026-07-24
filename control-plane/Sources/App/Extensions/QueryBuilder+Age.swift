import Fluent
import Foundation

extension QueryBuilder {
    /// Restricts the query to rows older than `cutoff`, measured by `clock`
    /// when it is set and by `fallback` when it is not.
    ///
    /// Every background sweep ages rows off a timestamp that may be missing on
    /// rows predating the column (`statusChangedAt`) or predating their first
    /// update (`updatedAt`), and each used to express that as
    /// `a ?? b ?? now` *after* loading the whole candidate set. Evaluated in
    /// SQL instead, the sweep loads only what it will act on — which is what
    /// makes the status indexes worth having.
    ///
    /// A row where both timestamps are NULL has no measurable age and is
    /// excluded, matching the `?? now` fallback those loops used to apply.
    @discardableResult
    func filterAged<Clock: QueryableProperty, Fallback: QueryableProperty>(
        before cutoff: Date,
        by clock: KeyPath<Model, Clock>,
        fallingBackTo fallback: KeyPath<Model, Fallback>
    ) -> Self
    where
        Clock.Model == Model, Clock.Value == Date?,
        Fallback.Model == Model, Fallback.Value == Date?
    {
        group(.or) { age in
            age.filter(clock, .lessThan, cutoff)
                .group(.and) { missingClock in
                    missingClock.filter(clock, .equal, nil)
                        .filter(fallback, .lessThan, cutoff)
                }
        }
    }
}
