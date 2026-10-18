import SwiftUI

struct HelpView: View {
    @ObservedObject private var localizationPreferences = AppPreferences.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(L10n.tr("发送给身边的人")) {
                    Text(L10n.tr("选择照片与视频，等待打包完成，再点击“AirDrop / 分享”，在系统面板选择接收设备。默认发送 .dropack 照片包；对方没有安装 Dropack 时，可以选择“导出普通 ZIP”。打包不额外压缩画质，每次新发送从本次选择开始；历史照片包可在首页“照片包”中预览、重发或删除。"))
                    Text(L10n.tr("发送的是原件，不包含你在相册里另做的编辑效果。原件中的拍摄时间、位置等信息会随文件保留。"))
                }
                Section(L10n.tr("收到以后")) {
                    Text(L10n.tr("AirDrop 收到照片包后，iOS 可能先打开“文件”预览。选择“在 Dropack 中打开”（或从分享菜单选择 Dropack），App 才会进入接收页并扫描，随后由你确认保存到相册。已确认存过的相同内容会跳过。已有任务时会先保留进度；普通 ZIP 也可以从“文件”中选取。"))
                }
                Section(L10n.tr("从 U 盘读取相机素材")) {
                    Text(L10n.tr("把 U 盘或读卡器接上 iPhone，在选择素材页点左上角的来源图标，切换到“文件 / U 盘”，然后在系统“浏览”的位置列表中找到它。可选择素材文件夹、单个视频或照片，也可选择照片包或 ZIP。原文件会保留。"))
                    Text(L10n.tr("未压缩的文件先按块暂存到手机，暂停后可从已暂存的位置继续读取；重新连接来源时会核对文件。ZIP 按条目解压，未完成的条目需要重新解压。保存到相册由 iOS 整项提交，无法从半个视频继续写入相册。请保持前台和 U 盘连接。"))
                }
                Section(L10n.tr("进度、暂停和恢复")) {
                    Text(L10n.tr("打包会使用 iOS 允许的后台运行时间。锁屏或离开应用后可能继续，也可能被系统暂停。已完成的项目会保留，继续时会重新读取当前未完成的一项。"))
                    Text(L10n.tr("导入时请保持应用在前台。锁屏或进入后台会请求暂停；正在写入相册的文件需要先收尾。重新打开后可继续，已完成的项目会跳过。"))
                    Text(L10n.tr("如果写入相册时应用突然退出，最后一项可能已经保存。Dropack 会将它标记为“待核对”；请先在相册确认，避免重复。"))
                }
                Section(L10n.tr("AirDrop 由系统管理")) {
                    Text(L10n.tr("Dropack 显示打包和相册导入进度。AirDrop 的发现设备、传输速度和传输结果由系统管理；Dropack 无法控制 AirDrop 的断点续传。分享完成也不代表接收端已存入相册。"))
                }
                Section(L10n.tr("空间与格式")) {
                    Text(L10n.tr("打包需要照片包和当前文件缓存的空间；导入需要新增相册内容与当前文件缓存的空间。原文件和原照片始终保留。来自 iCloud 的原文件可能需要先下载。"))
                    Text(L10n.tr("支持 .dropack 照片包、普通未加密 ZIP、单个照片或视频与文件夹。不支持加密或分卷 ZIP，也不会为不兼容的视频转码。照片与视频能否保存取决于 iOS 相册支持的格式。Dropack 自己生成的照片包会携带配对信息；普通 ZIP 中同名的 JPG 和 MOV 不会自动视为 Live Photo。"))
                }
                Section(L10n.tr("权限与隐私")) {
                    Text(L10n.tr("发送时需要读取你选中的照片原文件；导入时需要向相册添加内容。Dropack 在本机处理文件，无需账号。通过系统分享给谁、用哪个应用发送，由你选择。"))
                    Text(L10n.tr("清除导入任务会保留已确认的保存历史，不会删除原件或相册内容。清除照片包只会删除 Dropack 生成的包、ZIP 导出文件、缓存和打包记录。"))
                    Link(L10n.tr("隐私政策"), destination: URL(string: "https://dropack.app/privacy/")!)
                }
                Section {
                    Link("dropack.app", destination: URL(string: "https://dropack.app")!)
                }
            }
            .navigationTitle(L10n.tr("使用说明"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.tr("完成")) { dismiss() } } }
        }
        .tint(RelayTheme.accent)
    }
}
