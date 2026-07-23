/// Duration expressed as fractional seconds, for feeding swift-metrics timers
/// (which take a floating-point second count) and span attributes.
///
/// `Duration.components` splits into whole seconds plus attoseconds; recombine
/// them into a `Double`. Precision beyond microseconds is irrelevant for the
/// latencies we record, so the attosecond remainder is simply scaled down.
extension Duration {
    var asSeconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
