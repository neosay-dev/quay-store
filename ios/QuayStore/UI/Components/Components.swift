import SwiftUI

/// An app icon with the iOS corner shape; grey while it loads or when there is none.
struct AppIcon: View {
    let url: String?
    var size: CGFloat = 56

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Group {
            if let url, let u = URL(string: url) {
                AsyncImage(url: u) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }

    private var placeholder: some View {
        ZStack {
            Color(.secondarySystemFill)
            Image(systemName: "app.dashed")
                .font(.system(size: size * 0.4, weight: .light))
                .foregroundStyle(.tertiary)
        }
    }
}

/// The App Store's capsule button: «Загрузить», «Обновить», «Установлено».
struct GetButton: View {
    let app: CatalogApp
    @EnvironmentObject var catalog: Catalog
    @EnvironmentObject var installer: Installer

    var body: some View {
        let record = catalog.installedRecord(for: app)
        let update = record.flatMap { r in app.latest.map { checkUpdate(installed: r.installedState, latest: $0) } }
        let busy = installer.job != nil
        Button {
            Task { await installer.install(app) }
        } label: {
            Text(title(record: record, update: update))
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .frame(minWidth: 84)
                .background(Capsule().fill(Color(.tertiarySystemFill)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(record != nil && update == .upToDate ? Color.secondary : Color.accentColor)
        .disabled(busy || (record != nil && update == .upToDate))
    }

    private func title(record: InstalledRecord?, update: UpdateKind?) -> String {
        guard record != nil else { return "Загрузить" }
        switch update {
        case .newVersion?, .rebuilt?: return "Обновить"
        default: return "Установлено"
        }
    }
}

struct AppRow: View {
    let app: CatalogApp
    var showSource = false

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(url: app.app.iconUrl, size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.app.name).font(.body.weight(.medium)).lineLimit(1)
                Text(app.app.subtitle ?? app.app.developer ?? app.app.bundleId)
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                if showSource {
                    Text(app.source.name).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            GetButton(app: app)
        }
        .padding(.vertical, 4)
    }
}

/// Colors from sources ("#B9A4FF").
extension Color {
    init?(hex: String?) {
        guard let hex else { return nil }
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

/// The progress strip over the tab bar while something installs.
struct InstallBanner: View {
    @EnvironmentObject var installer: Installer

    var body: some View {
        if let job = installer.job {
            HStack(spacing: 12) {
                AppIcon(url: job.iconURL, size: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(job.stage).font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: min(max(job.fraction, 0), 1))
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 56)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// A row with a title and a value, for info lists.
struct InfoRow: View {
    let title: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
        }
        .font(.subheadline)
    }
}
