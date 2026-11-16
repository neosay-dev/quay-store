import SwiftUI

/// The shared log (core + app), refreshed while open.
struct LogView: View {
    @State var text = ""

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "Пока пусто" : text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                Color.clear.frame(height: 1).id("end")
            }
            .onChange(of: text) { _ in proxy.scrollTo("end") }
        }
        .navigationTitle("Логи")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button { UIPasteboard.general.string = text } label: { Label("Скопировать", systemImage: "doc.on.doc") }
                    ShareLink(item: Log.url) { Label("Отправить файл", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { Log.clear(); text = "" } label: { Label("Очистить", systemImage: "trash") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            while !Task.isCancelled {
                let t = Log.tail()
                if t != text { text = t }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
