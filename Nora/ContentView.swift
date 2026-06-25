import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.green)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Nora")
                        .font(.title2.weight(.semibold))
                    Text("Local Gemma launcher")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 12) {
                Text("Alt + G")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

                Text("で入力パネルを開きます")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(width: 420, height: 190)
    }
}

#Preview {
    ContentView()
}
