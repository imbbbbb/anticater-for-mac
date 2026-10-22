import SwiftUI
import AppKit
import AntiCaterCore

/// 杰理版的灯光：开关、颜色、亮度。改了立刻下发，和老款的灯效选择器一样不进 draft。
///
/// 取色器和亮度条拖动时会连续改值，写入的合并交给 `DeviceModel.setRGBLight`，
/// 这里只管把每次的新值递过去。
struct RGBLightControls: View {
    @ObservedObject var model: DeviceModel
    let light: Proto.RGBLight

    var body: some View {
        Toggle("灯光", isOn: Binding(
            get: { light.isOn },
            set: { on in
                var next = light
                next.isOn = on
                model.setRGBLight(next)
            }))

        ColorPicker("颜色", selection: Binding(
            get: { Self.color(of: light) },
            set: { color in
                guard let rgb = Self.components(of: color) else { return }
                var next = light
                (next.red, next.green, next.blue) = rgb
                model.setRGBLight(next)
            }),
            supportsOpacity: false)
        .disabled(!light.isOn)

        HStack {
            Text("亮度")
            Slider(value: Binding(
                get: { Double(light.brightness) },
                set: { value in
                    var next = light
                    next.brightness = UInt8(value.rounded())
                    model.setRGBLight(next)
                }),
                in: 0...100)
            Text("\(light.brightness)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .disabled(!light.isOn)
    }

    static func color(of light: Proto.RGBLight) -> Color {
        Color(.sRGB, red: Double(light.red) / 255,
              green: Double(light.green) / 255, blue: Double(light.blue) / 255)
    }

    /// 取色器给的颜色可能在别的色彩空间里，先转成 sRGB 再取分量。
    static func components(of color: Color) -> (UInt8, UInt8, UInt8)? {
        guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> UInt8 { UInt8((min(max(v, 0), 1) * 255).rounded()) }
        return (byte(srgb.redComponent), byte(srgb.greenComponent), byte(srgb.blueComponent))
    }
}
