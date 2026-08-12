import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// 库管理: 扫描根目录列表 + 增删 + 重新扫描 + 清理不可用。
struct ScanRootsSettingsView: View {
    @Environment(LibraryService.self) private var library
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ScanRoot.path) private var scanRoots: [ScanRoot]
    @State private var showingPicker = false

    var body: some View {
        Section("Library 扫描目录") {
            ForEach(scanRoots) { root in
                HStack {
                    VStack(alignment: .leading) {
                        Text(root.path).font(.callout).foregroundStyle(BrandColors.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        if let scanned = root.lastScannedAt {
                            Text("上次扫描: \(scanned.formatted(.dateTime))")
                                .font(.caption).foregroundStyle(BrandColors.textSecondary)
                        } else {
                            Text("未扫描").font(.caption)
                                .foregroundStyle(BrandColors.textSecondary)
                        }
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { root.watch },
                        set: { root.watch = $0; try? modelContext.save() }
                    ))
                    .labelsHidden()
                    .tint(BrandColors.magenta)
                    Button(role: .destructive) {
                        modelContext.delete(root)
                        try? modelContext.save()
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                        .foregroundStyle(BrandColors.textSecondary)
                }
            }

            Button {
                showingPicker = true
            } label: { Label("添加目录", systemImage: "plus.circle") }
                .buttonStyle(.bordered)
                .tint(BrandColors.cyan)

            HStack {
                Button { Task { await library.rescan() } } label: {
                    Label("重新扫描", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .tint(BrandColors.magenta)

                Button { try? library.purgeUnavailable() } label: {
                    Label("清理不可用", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
        }
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                let root = ScanRoot(path: url.path)
                modelContext.insert(root)
                try? modelContext.save()
                Task { await library.rescan() }
            }
        }
    }
}