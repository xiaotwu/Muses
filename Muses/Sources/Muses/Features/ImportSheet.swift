import SwiftUI
import AppKit

struct ImportSheet: View {
    @Environment(LibraryService.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var watch = true
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Library Folder").font(.title2)
            HStack {
                TextField("Folder path", text: $path).textFieldStyle(.roundedBorder)
                Button("Browse") { browse() }
            }
            Toggle("Watch for changes", isOn: $watch)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add") { add() }.disabled(path.isEmpty || importing)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }

    private func add() {
        importing = true
        Task {
            try? await library.addScanRoot(URL(fileURLWithPath: path), watch: watch)
            importing = false
            dismiss()
        }
    }
}