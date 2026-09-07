import Foundation
import AntiCaterCore

/// 把一个 Binding 压成文字。窄处用紧凑写法，详情用全名。
enum Summary {
    /// 旋钮图和侧栏一行的紧凑写法
    static func short(_ binding: Proto.Binding) -> String {
        let names = compactNames(binding)
        guard !names.isEmpty else { return "未设置" }
        if binding.type != .keyboard { return names[0] }
        if let combo = Proto.combo(from: binding) {
            return (combo.modifierCodes + [combo.code])
                .map { KeyNames.compactName(for: $0, type: .keyboard) }
                .joined(separator: "+")
        }
        if names.count <= 10 { return names.joined(separator: " ") }
        return names.prefix(8).joined(separator: " ") + " …共 \(names.count) 步"
    }

    /// 完整序列，带每步延时
    static func full(_ binding: Proto.Binding) -> String {
        let steps = binding.activeSteps.filter { !$0.isEmpty }
        guard !steps.isEmpty else { return "未设置" }
        return steps.map { step in
            let name = KeyNames.name(for: step.code, type: binding.type)
            return step.delayMs == 0 ? name : "\(name) +\(step.delayMs)ms"
        }.joined(separator: "  ›  ")
    }

    static func compactNames(_ binding: Proto.Binding) -> [String] {
        binding.activeSteps
            .filter { !$0.isEmpty }
            .map { KeyNames.compactName(for: $0.code, type: binding.type) }
    }
}
