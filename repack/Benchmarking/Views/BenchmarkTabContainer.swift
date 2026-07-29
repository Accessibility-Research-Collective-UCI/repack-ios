#if BENCHMARKING
import SwiftUI

struct BenchmarkTabContainer<REPACKContent: View, BenchmarkContent: View>: View {
    private let repackContent: REPACKContent
    private let benchmarkContent: BenchmarkContent

    init(
        @ViewBuilder repack: () -> REPACKContent,
        @ViewBuilder benchmark: () -> BenchmarkContent
    ) {
        repackContent = repack()
        benchmarkContent = benchmark()
    }

    var body: some View {
        TabView {
            Tab("REPACK", systemImage: "shippingbox") {
                repackContent
            }

            Tab("Benchmark", systemImage: "gauge.open.with.lines.needle.33percent") {
                benchmarkContent
            }
        }
    }
}
#endif
