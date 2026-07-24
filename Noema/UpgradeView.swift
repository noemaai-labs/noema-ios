import SwiftUI

struct UpgradeView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    Image(systemName: "globe")
                        .font(.system(size: 60))
                        .foregroundStyle(.blue)
                        .padding(.top, 40)

                    Text("Web search is included")
                        .font(.title2.weight(.semibold))

                    Text("SearXNG web search is available without limits. There's nothing to purchase—just enable the globe button in chat whenever you need online results.")
                        .multilineTextAlignment(.center)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)

                    Spacer(minLength: 20)
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 40)
            }
            .navigationTitle("Web Search")
        }
    }
}

#Preview {
    UpgradeView()
}
