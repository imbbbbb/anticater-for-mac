import SwiftUI
import AntiCaterCore

/// 诊断信息窗口：把要发出去的内容**先摆给用户看**，再谈拷贝。
///
/// 之前只有「拷贝诊断信息」一个按钮，内容是不可见的——排障的人得绕一趟剪贴板才能读，
/// 而普通用户则是在不知道内容的前提下被要求把一段东西贴给陌生人。
/// 隐私承诺（默认不含按键配置）只有在用户能亲眼核对时才算数。
public struct DiagnosticsView: View {

    @State private var text = ""
    @State private var verbose = EventLog.shared.verbose
    @State private var copied = false

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 620, minHeight: 420)
        // 每次打开都重新生成：窗口关掉再开，看到的必须是当下的状态，
        // 不能是上次打开时的快照。
        .onAppear(perform: refresh)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Toggle("记录详细日志", isOn: Binding(
                get: { verbose },
                set: { on in
                    verbose = on
                    EventLog.shared.verbose = on
                    // 立刻刷新，让顶部那句「详细模式未开启」的说明跟着变，
                    // 否则用户刚打开开关却看到界面说没开，会以为没生效。
                    refresh()
                }))
            .help("额外记录收发报文的十六进制内容。会包含你配置的按键与宏，用完请关掉。")

            // 开关只对打开之后发生的操作生效，已有记录不会被补全。
            // 不写出来的话，用户会开完开关直接拷贝，拿到一份没有报文的日志。
            if verbose {
                Text("现在去复现一次问题，报文才会被记下（含按键配置）")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Spacer()

            Button("刷新", action: refresh)
            Button(copied ? "已拷贝" : "拷贝全部", action: copy)
                .disabled(copied)
            Button("反馈问题…") { NSWorkspace.shared.open(Diagnostics.issuesPage) }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    private var content: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(.caption, design: .monospaced))
                // 等宽 + 可选中：用户要能只摘自己愿意给的那几行，
                // 而不是只能整段拷走。
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func refresh() {
        text = Diagnostics.report()
        copied = false
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        // 按钮变回「拷贝全部」，免得一直停在「已拷贝」上让人以为按钮坏了。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
