import Foundation

/// 全项目唯一的版本号来源。
///
/// `make-app.sh` 打包时会读这里的字面量填进 Info.plist，GitHub 上的 tag 也用它，
/// 三处必须一致——所以只在这一个地方写死，别再往别处抄一份。
public enum AppVersion {
    public static let string = "1.1"
}
