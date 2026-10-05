import SwiftUI

/// The inspector's memory and CPU line for one session. Observes the steward on its own so a
/// tick redraws this row, not the whole inspector.
struct ResourceRow: View {
    @ObservedObject var steward: Steward
    let sessionID: UUID

    var body: some View {
        if let sample = steward.samples[sessionID] {
            HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                Text("Resources").foregroundStyle(Tone.muted).frame(width: 72, alignment: .leading)
                Text(text(sample)).monospacedDigit()
                Spacer(minLength: 0)
            }
            .help(sample.lowered ? "Running at background priority while off screen" : "Memory footprint and CPU of the session's processes")
        }
    }

    private func text(_ sample: Steward.Sample) -> String {
        var parts = [ByteCountFormatter.string(fromByteCount: Int64(sample.footprint), countStyle: .memory)]
        if let cpu = sample.cpuPercent { parts.append("\(Int(cpu.rounded()))% CPU") }
        if sample.lowered { parts.append("background") }
        return parts.joined(separator: " · ")
    }
}
