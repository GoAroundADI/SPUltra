import AppKit
import SwiftUI

struct DonationView: View {
    private let address = "TVD3VoqUgqJ9BPV1rCEq2op1SnDRj19Gmi"

    /// 二维码在运行时由地址实时生成，避免资源束查找失败导致空白；
    /// 仅在生成失败时回退到打包的 PNG 资源。
    private static let qrImage: NSImage = {
        if let generated = makeQRCode(from: "TVD3VoqUgqJ9BPV1rCEq2op1SnDRj19Gmi") {
            return generated
        }
        if let url = Bundle.module.url(forResource: "donation-trc20", withExtension: "png"),
            let image = NSImage(contentsOf: url)
        {
            image.isTemplate = false
            return image
        }
        return NSImage(size: NSSize(width: 197, height: 197))
    }()

    private static func makeQRCode(from string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scale: CGFloat = 8
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let representation = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        image.isTemplate = false
        return image
    }
    @Environment(\.dismiss) private var dismiss
    @State private var didCopy = false

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Label("支持 Go Around ADI", systemImage: "heart.fill")
                    .font(.title2.bold())
                    .foregroundStyle(.purple)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.title2)
            }

            VStack(spacing: 10) {
                Image(nsImage: Self.qrImage)
                    .renderingMode(.original)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 8)

                Text("TRC20")
                    .font(.headline)
                Text("请确认转账网络为 TRON (TRC20)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Text(address)
                    .font(.system(.body, design: .monospaced, weight: .medium))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Button(didCopy ? "已复制" : "复制") { copyAddress() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .padding(26)
        .frame(width: 500)
        .background(.ultraThinMaterial)
    }

    private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}
