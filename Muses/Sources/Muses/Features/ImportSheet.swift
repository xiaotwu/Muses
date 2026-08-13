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
            Text(tr("Add Library Folder", "添加资料库文件夹")).font(.title2)
                .foregroundStyle(BrandColors.textPrimary)
            HStack {
                TextField(tr("Folder path", "文件夹路径"), text: $path).textFieldStyle(.roundedBorder)
                Button(tr("Browse", "浏览")) { browse() }
            }
            Toggle(tr("Watch for changes", "监视变化"), isOn: $watch)
            HStack {
                Spacer()
                Button(tr("Cancel", "取消")) { dismiss() }
                Button(tr("Add", "添加")) { add() }.disabled(path.isEmpty || importing)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(.ultraThinMaterial)
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