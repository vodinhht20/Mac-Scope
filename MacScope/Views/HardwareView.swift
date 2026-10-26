import SwiftUI
@MainActor struct HardwareView: View {
    @EnvironmentObject private var store: AppStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(title: "Hardware details", subtitle: "A readable inventory of what macOS exposes.")
                if let snapshot = store.snapshot {
                    ForEach(Array(Set(snapshot.fields.map(\.category))).sorted(), id: \.self) { category in
                        Surface {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(category).font(.headline)
                                ForEach(snapshot.fields.filter { $0.category == category }) { field in
                                    HStack(alignment: .top) { Text(field.title).foregroundColor(.secondary).frame(width: 180, alignment: .leading); Text(field.value).textSelection(.enabled); Spacer() }
                                    Divider()
                                }
                            }
                        }
                    }
                    Text("Device serial numbers, hardware UUIDs, IP addresses and Wi-Fi names are not collected in the inventory.").font(.caption).foregroundColor(.secondary)
                } else { ProgressView("Reading inventory…") }
            }.padding(28)
        }
    }
}
