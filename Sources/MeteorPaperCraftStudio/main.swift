import AppKit
import RealityKit
import ModelIO
import simd
import UniformTypeIdentifiers
import CoreVideo
import ImageIO
import PDFKit

struct Point2: Hashable, Codable {
    var x: Double
    var y: Double
}

struct PhotoItem: Identifiable {
    let id = UUID()
    let url: URL
    let image: NSImage
    let sourceData: Data?

    init(url: URL, image: NSImage, sourceData: Data? = nil) {
        self.url = url; self.image = image; self.sourceData = sourceData
    }
}

private enum MeshExportResult: Sendable {
    case success(faces:Int,pages:Int,cuts:Int,folds:Int)
    case failure(String)
}

private enum LocalAIError: Error, LocalizedError, Sendable {
    case process(String)

    var errorDescription: String? {
        switch self {
        case .process(let message): return message
        }
    }
}

@main
enum AppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = StudioController()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Meteor PaperCraft Studio"
        window.minSize = NSSize(width: 850, height: 620)
        window.contentViewController = controller
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

final class StudioController: NSViewController {
    private var photos: [PhotoItem] = []
    private var selectedID: UUID?
    private var hull: [Point2] = []
    private var manualPoints: [Point2] = []
    private let list = NSStackView()
    private let preview = SilhouettePreview()
    private let pdfPreview=PDFView()
    private let status = NSTextField(labelWithString: "写真を追加してください")
    private let tolerance = NSSlider(value: 0.20, minValue: 0.05, maxValue: 0.65, target: nil, action: nil)
    private let widthSlider = NSSlider(value: 100, minValue: 30, maxValue: 250, target: nil, action: nil)
    private let depthSlider = NSSlider(value: 35, minValue: 10, maxValue: 120, target: nil, action: nil)
    private let toleranceValue = NSTextField(labelWithString: "0.20")
    private let widthValue = NSTextField(labelWithString: "100 mm")
    private let depthValue = NSTextField(labelWithString: "35 mm")
    private var exportButton: NSButton!
    private var modelButton: NSButton!
    private var localAIButton: NSButton!
    private var meshButton: NSButton!
    private var mattePreviewButton: NSButton!
    private var matteExportButton: NSButton!
    private var previewToggleButton:NSButton!
    private var showingNetPreview=false
    private let countLabel = NSTextField(labelWithString: "読み込んだ写真 · 0")
    private var cachedMatte: (photoID:UUID,tolerance:Double,matte:ForegroundMatte)?
    private var manualMaskPolygons:[UUID:[Point2]]=[:]
    private let maxPhotoPixels: Int64 = 120_000_000

    private struct StudioProject: Codable {
        var photoPaths: [String]
        var selectedPath: String?
        var tolerance: Double
        var widthMM: Double
        var depthMM: Double
        var manualMasks: [String:[Point2]]
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root
        buildUI(in: root)
    }

    private func buildUI(in root: NSView) {
        let title = NSTextField(labelWithString: "Meteor PaperCraft Studio")
        title.font = .boldSystemFont(ofSize: 22)
        let subtitle = NSTextField(labelWithString: "写真から、ローカル3D/CADモデルとペーパークラフト展開図を作成")
        subtitle.textColor = .secondaryLabelColor
        let add = NSButton(title: "写真を追加…", target: self, action: #selector(addPhotos))
        add.bezelStyle = .rounded
        let addFolder = NSButton(title: "フォルダから追加…", target: self, action: #selector(addPhotoFolder))
        addFolder.bezelStyle = .rounded
        let addURL = NSButton(title: "画像URLから追加…", target: self, action: #selector(addImageURL))
        addURL.bezelStyle = .rounded
        let openProject = NSButton(title: "プロジェクトを開く…", target: self, action: #selector(openProject))
        let saveProject = NSButton(title: "プロジェクトを保存…", target: self, action: #selector(saveProject))
        let header = NSStackView(views: [vertical(title, subtitle), NSView(), openProject, saveProject, addFolder, addURL, add])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        countLabel.font = .boldSystemFont(ofSize: 14)
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.translatesAutoresizingMaskIntoConstraints = false
        list.widthAnchor.constraint(equalToConstant: 225).isActive = true
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let remove = NSButton(title: "選択した写真を削除", target: self, action: #selector(removeSelected))
        let privacy = NSTextField(wrappingLabelWithString: "写真はこのMac内で処理します。アップロードやAI推論は行いません。")
        privacy.font = .systemFont(ofSize: 11)
        privacy.textColor = .secondaryLabelColor
        let sidebar = NSStackView(views: [countLabel, scroll, remove, privacy])
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 12
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        preview.translatesAutoresizingMaskIntoConstraints = false
        let previewTitle = NSTextField(labelWithString: "輪郭プレビュー")
        previewTitle.font = .boldSystemFont(ofSize: 14)
        let detectButton = NSButton(title: "再検出", target: self, action: #selector(redetect))
        previewToggleButton=NSButton(title:"展開図プレビュー",target:self,action:#selector(toggleNetPreview))
        let previewHeader = NSStackView(views: [previewTitle, NSView(), previewToggleButton, detectButton])
        previewHeader.orientation = .horizontal
        previewHeader.alignment = .centerY
        let previewHost=NSView();previewHost.translatesAutoresizingMaskIntoConstraints=false
        preview.translatesAutoresizingMaskIntoConstraints=false;pdfPreview.translatesAutoresizingMaskIntoConstraints=false
        pdfPreview.isHidden=true;pdfPreview.autoScales=true;pdfPreview.displayMode = .singlePageContinuous;pdfPreview.displaysPageBreaks=true;pdfPreview.backgroundColor = .controlBackgroundColor
        previewHost.addSubview(preview);previewHost.addSubview(pdfPreview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo:previewHost.leadingAnchor),preview.trailingAnchor.constraint(equalTo:previewHost.trailingAnchor),preview.topAnchor.constraint(equalTo:previewHost.topAnchor),preview.bottomAnchor.constraint(equalTo:previewHost.bottomAnchor),
            pdfPreview.leadingAnchor.constraint(equalTo:previewHost.leadingAnchor),pdfPreview.trailingAnchor.constraint(equalTo:previewHost.trailingAnchor),pdfPreview.topAnchor.constraint(equalTo:previewHost.topAnchor),pdfPreview.bottomAnchor.constraint(equalTo:previewHost.bottomAnchor)
        ])
        let manualButton = NSButton(title: "背景マスクを手動でなぞる", target: self, action: #selector(startManualOutline))
        let finishOutlineButton = NSButton(title: "輪郭を確定", target: self, action: #selector(finishManualOutline))
        let autoOutlineButton = NSButton(title: "自動輪郭に戻す", target: self, action: #selector(redetect))
        mattePreviewButton = NSButton(title: "背景透過プレビュー", target: self, action: #selector(toggleMattePreview))
        matteExportButton = NSButton(title: "透過PNGを書き出す…", target: self, action: #selector(exportCutoutPNG))
        let outlineTools = NSStackView(views: [manualButton, finishOutlineButton, autoOutlineButton, mattePreviewButton, matteExportButton])
        outlineTools.orientation = .horizontal; outlineTools.alignment = .centerY; outlineTools.spacing = 8
        preview.onOutlinePoint = { [weak self] point in
            guard let self, self.preview.manualMode else { return }
            self.manualPoints.append(point)
            self.preview.points = self.manualPoints
            self.status.stringValue = "輪郭点 \(self.manualPoints.count) 点 · 被写体の外周をクリックしてください"
        }
        let toleranceRow = sliderRow("背景判定", slider: tolerance, value: toleranceValue)
        let widthRow = sliderRow("仕上がり幅", slider: widthSlider, value: widthValue)
        let depthRow = sliderRow("押し出し奥行き", slider: depthSlider, value: depthValue)
        tolerance.target = self; tolerance.action = #selector(toleranceChanged)
        widthSlider.target = self; widthSlider.action = #selector(widthChanged)
        depthSlider.target = self; depthSlider.action = #selector(depthChanged)
        let help = NSTextField(wrappingLabelWithString: "オレンジ線は選択写真の確認用です。複数視点はローカル3D/CAD経路を使い、単一写真だけがシルエット経路になります。")
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
        let groupTitle = NSTextField(labelWithString: "形状と切り出し")
        groupTitle.font = .boldSystemFont(ofSize: 13)
        let controls = NSStackView(views: [groupTitle, toleranceRow, widthRow, depthRow, help])
        controls.orientation = .vertical; controls.alignment = .leading; controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        let note = NSTextField(wrappingLabelWithString: "複数視点では、まず被写体マスクを作成し、ローカル3D/CAD再構築へ進みます。単一写真の輪郭PDFは簡易確認用です。")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        exportButton = NSButton(title: "PDF展開図を書き出す…", target: self, action: #selector(exportPDF))
        exportButton.bezelStyle = .rounded; exportButton.keyEquivalent = "s"; exportButton.keyEquivalentModifierMask = .command
        status.lineBreakMode = .byTruncatingMiddle; status.textColor = .secondaryLabelColor
        modelButton = NSButton(title: "5視点から3D→展開図…", target: self, action: #selector(createPhotogrammetryModel))
        modelButton.bezelStyle = .rounded
        localAIButton = NSButton(title: "ローカルAIで3D…", target: self, action: #selector(createLocalAIModel))
        localAIButton.bezelStyle = .rounded
        meshButton = NSButton(title: "3Dメッシュから展開図PDF…", target: self, action: #selector(exportMeshNet))
        meshButton.bezelStyle = .rounded
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [status, NSView(), localAIButton, modelButton, meshButton, exportButton])
        footer.orientation = .horizontal; footer.alignment = .centerY; footer.spacing = 10
        let main = NSStackView(views: [previewHeader, previewHost, outlineTools, controls, footer, note])
        main.orientation = .vertical; main.alignment = .leading; main.spacing = 14; main.translatesAutoresizingMaskIntoConstraints = false
        let content = NSStackView(views: [sidebar, main])
        content.orientation = .horizontal; content.alignment = .top; content.spacing = 20; content.translatesAutoresizingMaskIntoConstraints = false
        let rootStack = NSStackView(views: [header, separator(), content])
        rootStack.orientation = .vertical; rootStack.alignment = .leading; rootStack.spacing = 16; rootStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22), rootStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22), rootStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20), rootStack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            header.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            content.widthAnchor.constraint(equalTo: rootStack.widthAnchor), content.heightAnchor.constraint(equalTo: rootStack.heightAnchor, constant: -75),
            sidebar.widthAnchor.constraint(equalToConstant: 240), sidebar.heightAnchor.constraint(equalTo: content.heightAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 238), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            main.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -260), main.heightAnchor.constraint(equalTo: content.heightAnchor),
            previewHost.widthAnchor.constraint(equalTo: main.widthAnchor), previewHost.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
            previewHeader.widthAnchor.constraint(equalTo: main.widthAnchor), outlineTools.widthAnchor.constraint(equalTo: main.widthAnchor), controls.widthAnchor.constraint(equalTo: main.widthAnchor),
            footer.widthAnchor.constraint(equalTo: main.widthAnchor), note.widthAnchor.constraint(equalTo: main.widthAnchor)
        ])
        refreshList()
    }

    private func vertical(_ a: NSView, _ b: NSView) -> NSView {
        let s=NSStackView(views:[a,b]); s.orientation = .vertical; s.alignment = .leading; s.spacing=3; return s
    }
    private func separator() -> NSView { let v=NSBox(); v.boxType = .separator; return v }
    private func sliderRow(_ title: String, slider: NSSlider, value: NSTextField) -> NSView {
        let label=NSTextField(labelWithString:title); label.widthAnchor.constraint(equalToConstant:110).isActive=true
        value.alignment = .right; value.widthAnchor.constraint(equalToConstant:65).isActive=true
        let row=NSStackView(views:[label,slider,value]); row.orientation = .horizontal; row.alignment = .centerY; row.distribution = .fill; row.spacing=10
        row.widthAnchor.constraint(greaterThanOrEqualToConstant:400).isActive=true
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }
    private func refreshList() {
        list.setViews([], in: .top)
        for item in photos {
            let b=NSButton(title: item.url.lastPathComponent, target: self, action: #selector(selectPhoto(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString); b.alignment = .left; b.lineBreakMode = .byTruncatingMiddle
            b.state = item.id == selectedID ? .on : .off
            list.addArrangedSubview(b); b.widthAnchor.constraint(equalToConstant: 215).isActive=true; b.heightAnchor.constraint(equalToConstant:24).isActive=true
        }
        countLabel.stringValue="読み込んだ写真 · \(photos.count)"
        if photos.count >= 3 { exportButton?.title="複数視点から3D展開図を作成…" }
        else { exportButton?.title="単一写真シルエットPDFを書き出す…" }
    }
    @objc private func saveProject() {
        let panel=NSSavePanel(); panel.allowedContentTypes=[UTType(filenameExtension:"meteorcraft") ?? .data]
        panel.nameFieldStringValue="papercraft-project.meteorcraft"
        guard panel.runModal() == .OK, let url=panel.url else{return}
        let project=StudioProject(
            photoPaths: photos.filter { $0.url.isFileURL }.map{ $0.url.path },
            selectedPath: photos.first(where:{$0.id==selectedID})?.url.isFileURL == true ? photos.first(where:{$0.id==selectedID})?.url.path : nil,
            tolerance:tolerance.doubleValue,widthMM:widthSlider.doubleValue,depthMM:depthSlider.doubleValue,
            manualMasks: Dictionary(uniqueKeysWithValues: photos.compactMap { item in
                guard item.url.isFileURL,let polygon=manualMaskPolygons[item.id] else{return nil}
                return (item.url.path,polygon)
            }))
        do {
            let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
            try encoder.encode(project).write(to:url,options:.atomic)
            status.stringValue="プロジェクトを保存しました: \(url.lastPathComponent)"
        } catch { showAlert("プロジェクトを保存できませんでした",error.localizedDescription) }
    }
    @objc private func openProject() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[UTType(filenameExtension:"meteorcraft") ?? .json,.json];panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK, let url=panel.url else{return}
        do {
            let project=try JSONDecoder().decode(StudioProject.self,from:Data(contentsOf:url))
            var loaded:[PhotoItem]=[];var missing:[String]=[]
            for path in project.photoPaths {
                let photoURL=URL(fileURLWithPath:path)
                if let image=NSImage(contentsOf:photoURL),image.size.width>0,image.size.height>0 {loaded.append(PhotoItem(url:photoURL,image:image))}
                else {missing.append((path as NSString).lastPathComponent)}
            }
            photos=loaded;selectedID=loaded.first(where:{$0.url.path==project.selectedPath})?.id ?? loaded.first?.id
            tolerance.doubleValue=max(tolerance.minValue,min(tolerance.maxValue,project.tolerance))
            widthSlider.doubleValue=max(widthSlider.minValue,min(widthSlider.maxValue,project.widthMM))
            depthSlider.doubleValue=max(depthSlider.minValue,min(depthSlider.maxValue,project.depthMM))
            toleranceValue.stringValue=String(format:"%.2f",tolerance.doubleValue)
            widthValue.stringValue="\(Int(widthSlider.doubleValue)) mm";depthValue.stringValue="\(Int(depthSlider.doubleValue)) mm"
            manualMaskPolygons=[:]
            for item in loaded {if let polygon=project.manualMasks[item.url.path] {manualMaskPolygons[item.id]=polygon}}
            cachedMatte=nil;refreshList();detect()
            status.stringValue=missing.isEmpty ? "プロジェクトを開きました: \(url.lastPathComponent)" : "プロジェクトを開きました · 見つからない画像 \(missing.count) 件"
        } catch { showAlert("プロジェクトを開けませんでした",error.localizedDescription) }
    }
    @objc private func addPhotos() {
        let panel=NSOpenPanel(); panel.allowedContentTypes=[.png,.jpeg,.tiff,.heic,.gif]; panel.allowsMultipleSelection=true; panel.canChooseDirectories=false
        guard panel.runModal() == .OK else { return }
        appendPhotos(from: panel.urls)
    }
    @objc private func addPhotoFolder() {
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.allowsMultipleSelection=false
        panel.message="画像フォルダを選択してください"
        guard panel.runModal() == .OK, let folder=panel.url else{return}
        let urls=(FileManager.default.enumerator(at:folder,includingPropertiesForKeys:[.isRegularFileKey],options:[.skipsHiddenFiles])?.compactMap{$0 as? URL} ?? []).filter { url in
            ["png","jpg","jpeg","tif","tiff","heic","heif","gif"].contains(url.pathExtension.lowercased())
        }
        appendPhotos(from:urls)
    }
    private func appendPhotos(from urls:[URL]) {
        var skipped: [String] = []; var acceptedPixels: Int64 = photos.reduce(0) { total,item in
            var rect=CGRect(origin:.zero,size:item.image.size)
            guard let image=item.image.cgImage(forProposedRect:&rect,context:nil,hints:nil) else{return total}
            return total + Int64(image.width) * Int64(image.height)
        }
        for url in urls where !photos.contains(where:{$0.url==url}) {
            if let image=NSImage(contentsOf:url), image.size.width > 0, image.size.height > 0 {
                var rect=CGRect(origin:.zero,size:image.size)
                let pixels=image.cgImage(forProposedRect:&rect,context:nil,hints:nil).map { Int64($0.width) * Int64($0.height) } ?? 0
                if acceptedPixels + pixels > maxPhotoPixels { skipped.append("\(url.lastPathComponent)（画像総量の上限）") }
                else { photos.append(PhotoItem(url:url,image:image));acceptedPixels += pixels }
            }
            else { skipped.append(url.lastPathComponent) }
        }
        if selectedID == nil { selectedID=photos.first?.id }; refreshList(); detect()
        if !skipped.isEmpty { status.stringValue="読み込めた写真 \(photos.count) 枚 · 空または未対応のファイル \(skipped.count) 件をスキップ" }
    }
    @objc private func addImageURL() {
        let alert = NSAlert(); alert.messageText = "ネット上の画像を追加"; alert.informativeText = "直接画像を表示するURL（https://…jpg など）を入力してください。"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24)); field.placeholderString = "https://example.com/photo.jpg"; alert.accessoryView = field
        alert.addButton(withTitle: "読み込む"); alert.addButton(withTitle: "キャンセル")
        guard alert.runModal() == .alertFirstButtonReturn, let url = URL(string: field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        status.stringValue = "画像をダウンロードしています…"
        Task { @MainActor in
            do {
                var request=URLRequest(url:url);request.timeoutInterval=30;request.cachePolicy = .reloadIgnoringLocalCacheData
                let configuration=URLSessionConfiguration.ephemeral;configuration.timeoutIntervalForRequest=30;configuration.timeoutIntervalForResource=45
                let session=URLSession(configuration:configuration)
                let (data, response) = try await session.data(for:request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { throw URLError(.badServerResponse) }
                guard data.count <= 25_000_000 else { throw CocoaError(.fileReadTooLarge) }
                guard let image = NSImage(data: data) else { throw URLError(.cannotDecodeContentData) }
                var rect=CGRect(origin:.zero,size:image.size)
                guard let cg=image.cgImage(forProposedRect:&rect,context:nil,hints:nil),Int64(cg.width)*Int64(cg.height) <= self.maxPhotoPixels else { throw CocoaError(.fileReadTooLarge) }
                let existingPixels=photos.reduce(Int64(0)) { total,item in
                    var existingRect=CGRect(origin:.zero,size:item.image.size)
                    guard let existing=item.image.cgImage(forProposedRect:&existingRect,context:nil,hints:nil) else{return total}
                    return total + Int64(existing.width)*Int64(existing.height)
                }
                guard existingPixels + Int64(cg.width)*Int64(cg.height) <= self.maxPhotoPixels else { throw CocoaError(.fileReadTooLarge) }
                let item = PhotoItem(url: url, image: image, sourceData: data); photos.append(item); selectedID = item.id; refreshList(); detect()
                status.stringValue = "ネット画像を読み込みました（画像処理はこのMac内で実行）"
            } catch { status.stringValue = "画像URLを読み込めませんでした: \(error.localizedDescription)" }
        }
    }
    @objc private func selectPhoto(_ sender: NSButton) {
        guard let id=sender.identifier.flatMap({UUID(uuidString:$0.rawValue)}) else { return }; selectedID=id; refreshList(); detect()
    }
    @objc private func removeSelected() { if let selectedID { manualMaskPolygons.removeValue(forKey:selectedID) };photos.removeAll{$0.id==selectedID};selectedID=photos.first?.id;cachedMatte=nil;refreshList();detect() }
    @objc private func redetect() { cachedMatte=nil;detect() }
    @objc private func startManualOutline() {
        guard preview.image != nil else { return }
        manualPoints = []; preview.points = []; preview.manualMode = true; preview.outlineClosed = false
        status.stringValue = "透明に残したい被写体の外周をクリックし、「輪郭を確定」を押してください"
    }
    @objc private func finishManualOutline() {
        guard manualPoints.count >= 3 else { status.stringValue = "輪郭確定には3点以上必要です"; return }
        hull=manualPoints;preview.points=hull;preview.manualMode=false;preview.outlineClosed=true;exportButton?.isEnabled=true
        if let selectedID { manualMaskPolygons[selectedID]=hull;cachedMatte=nil }
        status.stringValue="手動背景マスクを \(hull.count) 点で確定しました"
    }
    @objc private func toleranceChanged() { toleranceValue.stringValue=String(format:"%.2f",tolerance.doubleValue); cachedMatte=nil;detect() }
    @objc private func widthChanged() { widthValue.stringValue="\(Int(widthSlider.doubleValue)) mm";restorePhotoPreview() }
    @objc private func depthChanged() { depthValue.stringValue="\(Int(depthSlider.doubleValue)) mm";restorePhotoPreview() }
    private func localBackendPython() -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("local3d/.venv/bin/python"))
        }
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Meteor PaperCraft Studio/local3d/.venv/bin/python")
        if let support { candidates.append(support) }
        candidates.append(fm.homeDirectoryForCurrentUser.appendingPathComponent(".meteor-papercraft/local3d/.venv/bin/python"))
        return candidates.first(where: { fm.isExecutableFile(atPath: $0.path) })
    }
    private func localBackendEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let resourceURL = Bundle.main.resourceURL {
            let frameworks = resourceURL.appendingPathComponent("../Frameworks").standardizedFileURL.path
            let existing = environment["DYLD_LIBRARY_PATH"].map { ":\($0)" } ?? ""
            environment["DYLD_LIBRARY_PATH"] = frameworks + existing
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Meteor PaperCraft Studio/Cache")
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        environment["HF_HOME"] = support.appendingPathComponent("huggingface").path
        environment["XDG_CACHE_HOME"] = support.path
        return environment
    }
    @objc private func createLocalAIModel() {
        guard photos.count >= 3 else {
            showAlert("写真が足りません", "ローカル多視点3Dには少なくとも3枚の重なりのある写真が必要です。")
            return
        }
        guard let python=localBackendPython() else {
            showAlert("ローカル3Dバックエンドがありません", "このアプリの配布パッケージにローカル3Dバックエンドが含まれていません。開発用ビルドではなく、バックエンド同梱版のアプリを使用してください。")
            return
        }
        guard let script=Bundle.main.url(forResource:"local_multiview_reconstruct",withExtension:"py") else {
            showAlert("ローカル3Dランナーが見つかりません", "アプリを最新のbuild-app.shで再ビルドしてください。")
            return
        }
        let outputDirectory=FileManager.default.temporaryDirectory.appendingPathComponent("MeteorLocal3D-\(UUID().uuidString)")
        do { try FileManager.default.createDirectory(at:outputDirectory,withIntermediateDirectories:true) } catch { status.stringValue="ローカル3D作業フォルダを作成できませんでした";return }
        let inputURLs=photos.map(\.url)
        let backendEnvironment = localBackendEnvironment()
        localAIButton.isEnabled=false;status.stringValue="ローカルAIで多視点3Dを再構築しています…"
        Task { @MainActor in
            defer { localAIButton.isEnabled=true }
            let result:Result<URL,LocalAIError>=await Task.detached(priority:.userInitiated) {
                let process=Process();process.executableURL=python
                process.arguments=[script.path]+inputURLs.map(\.path)+["--output-dir",outputDirectory.path,"--variant","small","--resolution","336","--output-mesh"]
                process.environment = backendEnvironment
                let pipe=Pipe();process.standardOutput=pipe;process.standardError=pipe
                do { try process.run();process.waitUntilExit() } catch { return .failure(.process(error.localizedDescription)) }
                let output=String(data:pipe.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8) ?? ""
                let logURL = outputDirectory.appendingPathComponent("reconstruction.log")
                try? output.write(to: logURL, atomically: true, encoding: .utf8)
                let diagnostic = output.count > 6000 ? "…\n" + String(output.suffix(6000)) : output
                guard process.terminationStatus == 0 else { return .failure(.process(diagnostic.isEmpty ? "ローカル3D推定に失敗しました" : diagnostic)) }
                let mesh=outputDirectory.appendingPathComponent("reconstruction-repaired.obj")
                guard FileManager.default.fileExists(atPath:mesh.path) else { return .failure(.process("修復済みメッシュが生成されませんでした\n\(diagnostic)")) }
                return .success(mesh)
            }.value
            switch result {
            case .success(let mesh): status.stringValue="ローカル3Dメッシュを生成しました。展開しています…";exportMeshPDF(from:mesh)
            case .failure(let message): status.stringValue="ローカル3Dに失敗しました";showAlert("ローカル3D生成に失敗しました",message.localizedDescription)
            }
        }
    }
    @objc private func createPhotogrammetryModel() {
        guard PhotogrammetrySession.isSupported else {
            showAlert("このMacでは写真測量を利用できません", "Object Captureに対応するGPUを搭載したMacが必要です。")
            return
        }
        guard photos.count >= 2 else {
            showAlert("写真が足りません", "同じ物体を少しずつ角度を変えて撮った写真を追加してください。")
            return
        }
        if photos.count < 12 {
            let alert = NSAlert()
            alert.messageText = "写真が少ない可能性があります"
            alert.informativeText = "現在 \(photos.count) 枚です。写真測量では、物体の周囲を重なりのある角度で撮った写真が必要です。2枚では立体化できない場合があります。"
            alert.addButton(withTitle: "この枚数で試す")
            alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "usdz") ?? .data]
        panel.nameFieldStringValue = "photogrammetry-model.usdz"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        modelButton.isEnabled = false
        status.stringValue = "ローカル写真測量を準備しています…"
        let inputPhotos = photos
        Task { @MainActor in
            defer { modelButton.isEnabled = true }
            do {
                var samples:[PhotogrammetrySample]=[]
                for (index, item) in inputPhotos.enumerated() {
                    self.status.stringValue="背景マスクを作成しています… \(index+1)/\(inputPhotos.count)"
                    var proposed=CGRect(origin:.zero,size:item.image.size)
                    guard let cgImage=item.image.cgImage(forProposedRect:&proposed,context:nil,hints:nil),
                          let imageBuffer=TransparencyProcessor.makeImageBuffer(from:cgImage) else { continue }
                    let matte=try self.currentMatte(for:item,createCutout:false)
                    guard let objectMask=TransparencyProcessor.makeMaskBuffer(matte,width:cgImage.width,height:cgImage.height) else { continue }
                    var sample=PhotogrammetrySample(id:index+1,image:imageBuffer)
                    sample.objectMask=objectMask
                    let source:CGImageSource? = item.sourceData.map{CGImageSourceCreateWithData($0 as CFData,nil)} ?? (item.url.isFileURL ? CGImageSourceCreateWithURL(item.url as CFURL,nil) : nil)
                    if let source,let metadata=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any] { sample.metadata=metadata }
                    samples.append(sample)
                }
                guard samples.count>=2 else { throw CocoaError(.fileReadCorruptFile) }
                var configuration=PhotogrammetrySession.Configuration()
                configuration.isObjectMaskingEnabled=true
                configuration.featureSensitivity = .high
                let session=try PhotogrammetrySession(input:samples,configuration:configuration)
                let request = PhotogrammetrySession.Request.modelFile(url: outputURL, detail: .medium, geometry: nil)
                try session.process(requests: [request])
                var resultURL: URL?
                for try await output in session.outputs {
                    switch output {
                    case .requestProgress(_, let fractionComplete):
                        self.status.stringValue = "ローカル写真測量中… \(Int(fractionComplete * 100))%"
                    case .requestComplete(_, let result):
                        if case .modelFile(let url) = result { resultURL = url }
                    case .requestError(_, let error):
                        throw error
                    case .invalidSample(_, let reason):
                        self.status.stringValue = "使えない写真があります: \(reason)"
                    case .stitchingIncomplete:
                        self.status.stringValue = "写真の重なりが足りず、全画像をつなげられませんでした"
                    case .processingComplete:
                        break
                    default:
                        break
                    }
                    if case .processingComplete = output { break }
                }
                guard resultURL != nil else { throw CocoaError(.fileWriteUnknown) }
                self.status.stringValue = "3Dモデルを保存しました: \(outputURL.lastPathComponent)"
                self.showAlert("3Dモデルを作成しました", "\(outputURL.path)\n続けて、この5視点モデルをA4展開図へ変換します。")
                self.exportMeshPDF(from: outputURL)
            } catch {
                if inputPhotos.count >= 3 {
                    self.status.stringValue = "Object Captureを使えないため、ローカルAI 3Dへ切り替えます…"
                    self.showAlert("標準写真測量を切り替えます", "5枚の画像ではAppleの写真測量が復元できませんでした。外部APIを使わず、ローカルAI多視点3Dへ切り替えます。")
                    self.createLocalAIModel()
                } else {
                    let message = self.photogrammetryErrorMessage(error, photoCount: inputPhotos.count)
                    self.status.stringValue = "写真測量に失敗しました: \(message)"
                    self.showAlert("3Dモデルを作成できませんでした", message)
                }
            }
        }
    }
    private func photogrammetryErrorMessage(_ error: Error, photoCount: Int) -> String {
        if #available(macOS 14.0, *), let captureError = error as? PhotogrammetrySession.Error {
            switch captureError {
                case .insufficientStorage(let requiredBytes):
                    return "保存領域が足りません。必要な容量は約 \(ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file)) です。"
                case .invalidImages(let url):
                    let guidance = photoCount < 12
                        ? "今回の入力は \(photoCount) 枚です。共通する特徴や写真間の重なりが不足している可能性があります。物体の周囲を少しずつ角度を変えて撮った写真を追加してください。"
                        : "画像の形式や写真間の重なりが不足している可能性があります。画像ファイルを確認し、連続する角度の写真を追加してください。"
                    return "写真セットを復元に使えませんでした。入力場所: \(url.lastPathComponent)。\(guidance)"
                case .invalidOutput(let url):
                    return "保存先を使用できませんでした: \(url.lastPathComponent)"
                @unknown default:
                    break
            }
        }
        return "\(error.localizedDescription)\n\(photoCount)枚の画像から復元できませんでした。画像間の重なりや共通点が足りない可能性があります。物体の周囲を少しずつ角度を変えて撮影し、背景や照明をなるべく一定にした写真を追加してください。"
    }
    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message; alert.runModal()
    }
    private func detect() {
        restorePhotoPreview()
        guard let photo=photos.first(where:{$0.id==selectedID}) else { hull=[];cachedMatte=nil;preview.image=nil;preview.cutoutImage=nil;preview.showCutout=false;preview.points=[];status.stringValue="写真を追加してください";exportButton?.isEnabled=false;return }
        do { preview.manualMode=false;preview.outlineClosed=true;preview.showCutout=false;mattePreviewButton?.title="背景透過プレビュー";manualPoints=[]
            let matte=try currentMatte(for:photo,createCutout:false);hull=manualMaskPolygons[photo.id] ?? Silhouette.detect(matte:matte);preview.image=photo.image;preview.cutoutImage=nil;preview.points=hull;preview.needsDisplay=true
            if manualMaskPolygons[photo.id] != nil { status.stringValue="手動輪郭を使用 · \(hull.count)点" }
            else if hull.count>=3 {
                let warning=matte.confidence < 0.6 ? " · 自動判定の信頼度が低いため輪郭を確認してください" : ""
                status.stringValue="輪郭を\(hull.count)点で検出 · 選択中の写真を使用\(warning)"
            } else { status.stringValue="輪郭を検出できません。背景判定を調整してください。" }
            exportButton?.isEnabled=hull.count>=3
        } catch { hull=[]; status.stringValue="画像を解析できませんでした: \(error.localizedDescription)" }
    }
    private func restorePhotoPreview() {
        if showingNetPreview { showingNetPreview=false;pdfPreview.isHidden=true;preview.isHidden=false;previewToggleButton?.title="展開図プレビュー" }
    }
    @objc private func exportPDF() {
        // Never silently turn a multi-view job into the old two-face silhouette
        // template. Multi-view projects must go through masked photogrammetry
        // and the mesh unfolder.
        if photos.count >= 3 { createPhotogrammetryModel(); return }
        guard hull.count>=3 else{return}; let panel=NSSavePanel(); panel.allowedContentTypes=[.pdf]; panel.nameFieldStringValue="papercraft-template.pdf"
        guard panel.runModal() == .OK, let url=panel.url else{return}
        do {
            guard let item=photos.first(where:{$0.id==selectedID}) else{throw SilhouetteError.cannotReadPixels}
            let matte=try currentMatte(for:item,createCutout:true)
            if manualMaskPolygons[item.id] == nil && matte.confidence < 0.6 {
                let alert=NSAlert();alert.messageText="自動輪郭の確認が必要です";alert.informativeText="背景の明るさや反射が複雑なため、販売用出力の前に「背景マスクを手動でなぞる」で輪郭を確定することを推奨します。確認せずに続行しますか？";alert.addButton(withTitle:"確認せず続行");alert.addButton(withTitle:"キャンセル")
                guard alert.runModal() == .alertFirstButtonReturn else{return}
            }
            try NetExporter.writePDF(points:hull,widthMM:widthSlider.doubleValue,depthMM:depthSlider.doubleValue,faceImage:matte.cutout,sideColor:matte.averageColor,to:url)
            status.stringValue="カラーPDF展開図を保存しました: \(url.lastPathComponent)";let alert=NSAlert();alert.messageText="PDF書き出し完了";alert.informativeText=status.stringValue;alert.runModal()
        }
        catch { status.stringValue="書き出しに失敗しました: \(error.localizedDescription)" }
    }
    @objc private func toggleMattePreview() {
        guard let item=photos.first(where:{$0.id==selectedID}) else { status.stringValue="先に写真を読み込んでください";return }
        do {
            let matte=try currentMatte(for:item,createCutout:true)
            guard let cg=matte.cutout else { throw SilhouetteError.cannotReadPixels }
            preview.cutoutImage=NSImage(cgImage:cg,size:item.image.size);preview.showCutout.toggle()
            mattePreviewButton.title=preview.showCutout ? "元画像を表示" : "背景透過プレビュー"
            status.stringValue=preview.showCutout ? "ローカル背景透過プレビュー · 判定値 \(String(format:"%.2f",tolerance.doubleValue))" : "元画像を表示しています"
        } catch { status.stringValue="背景透過に失敗しました: \(error.localizedDescription)" }
    }
    @objc private func toggleNetPreview() {
        if showingNetPreview {
            showingNetPreview=false;pdfPreview.isHidden=true;preview.isHidden=false;previewToggleButton.title="展開図プレビュー";return
        }
        guard hull.count>=3,let item=photos.first(where:{$0.id==selectedID}) else { status.stringValue="写真を読み込み、輪郭を確定してください";return }
        do {
            let matte=try currentMatte(for:item,createCutout:true)
            let url=FileManager.default.temporaryDirectory.appendingPathComponent("MeteorPaperCraft-preview-\(UUID().uuidString).pdf")
            try NetExporter.writePDF(points:hull,widthMM:widthSlider.doubleValue,depthMM:depthSlider.doubleValue,faceImage:matte.cutout,sideColor:matte.averageColor,to:url)
            guard let document=PDFDocument(url:url) else{throw CocoaError(.fileReadCorruptFile)}
            pdfPreview.document=document;pdfPreview.autoScales=true;preview.isHidden=true;pdfPreview.isHidden=false;showingNetPreview=true;previewToggleButton.title="写真プレビューに戻る"
            status.stringValue="アプリ内の展開図プレビュー · カラー・A4実寸"
        } catch { status.stringValue="展開図プレビューを作成できませんでした: \(error.localizedDescription)" }
    }
    @objc private func exportCutoutPNG() {
        guard let item=photos.first(where:{$0.id==selectedID}) else { status.stringValue="先に写真を読み込んでください";return }
        let panel=NSSavePanel();panel.allowedContentTypes=[.png];panel.nameFieldStringValue=item.url.deletingPathExtension().lastPathComponent+"-transparent.png"
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {
            let matte=try currentMatte(for:item,createCutout:true);guard let cg=matte.cutout else{throw SilhouetteError.cannotReadPixels}
            guard let data=NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) else{throw CocoaError(.fileWriteUnknown)}
            try data.write(to:url,options:.atomic);status.stringValue="透過PNGを保存しました: \(url.lastPathComponent)"
            showAlert("背景透過PNGを書き出しました",url.path)
        } catch { status.stringValue="透過PNGを書き出せませんでした: \(error.localizedDescription)" }
    }
    private func currentMatte(for item:PhotoItem,createCutout:Bool)throws->ForegroundMatte {
        if let cachedMatte,cachedMatte.photoID==item.id,cachedMatte.tolerance==tolerance.doubleValue,
           !createCutout || cachedMatte.matte.cutout != nil { return cachedMatte.matte }
        var rect=CGRect(origin:.zero,size:item.image.size)
        guard let cg=item.image.cgImage(forProposedRect:&rect,context:nil,hints:nil) else{throw SilhouetteError.cannotReadPixels}
        var matte=try TransparencyProcessor.makeMatte(from:cg,tolerance:tolerance.doubleValue,createCutout:createCutout)
        if let polygon=manualMaskPolygons[item.id] { matte=try TransparencyProcessor.clipped(matte,to:polygon,original:cg,createCutout:createCutout) }
        cachedMatte=(item.id,tolerance.doubleValue,matte);return matte
    }
    @objc private func exportMeshNet() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [UTType(filenameExtension:"usdz") ?? .data, UTType(filenameExtension:"obj") ?? .data, UTType(filenameExtension:"stl") ?? .data]
        open.allowsMultipleSelection = false; open.canChooseDirectories = false
        guard open.runModal() == .OK, let sourceURL = open.url else { return }
        exportMeshPDF(from: sourceURL)
    }
    private func exportMeshPDF(from sourceURL:URL) {
        let save = NSSavePanel(); save.allowedContentTypes = [.pdf]
        save.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent + "-papercraft.pdf"
        guard save.runModal() == .OK, let outputURL = save.url else { return }
        meshButton.isEnabled = false
        status.stringValue = "3Dメッシュを読み込み、面を展開しています…"
        let width = widthSlider.doubleValue
        Task { @MainActor in
            defer { meshButton.isEnabled = true }
            let result:MeshExportResult = await Task.detached(priority:.userInitiated) {
                do {
                    let model=try MeshNetBuilder.build(from:sourceURL,targetWidthMM:width)
                    try MeshNetPDF.write(model,to:outputURL)
                    return MeshExportResult.success(faces:model.facets.count,pages:model.pageCount,cuts:model.cutEdges,folds:model.foldedEdges)
                } catch { return MeshExportResult.failure(error.localizedDescription) }
            }.value
            switch result {
            case .success(let faces,let pages,let cuts,let folds):
                status.stringValue="3Dメッシュ展開図: \(faces)面 · \(pages)ページ · 切断\(cuts) · 折り\(folds)"
                showAlert("メッシュ展開図を保存しました", "\(outputURL.path)\n\(faces)面を \(pages) ページに配置しました。\n切断辺: \(cuts) · 折り辺: \(folds)\n赤線は切断、青破線は折り線です。")
            case .failure(let message):
                status.stringValue="メッシュ展開に失敗しました: \(message)"
                showAlert("3Dメッシュを展開できませんでした",message)
            }
        }
    }
}

final class SilhouettePreview: NSView {
    var image: NSImage? { didSet { needsDisplay=true } }
    var cutoutImage:NSImage? { didSet { needsDisplay=true } }
    var showCutout=false { didSet { needsDisplay=true } }
    var points: [Point2] = [] { didSet { needsDisplay=true } }
    var manualMode = false { didSet { window?.invalidateCursorRects(for: self); needsDisplay=true } }
    var outlineClosed = true
    var onOutlinePoint: ((Point2) -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: manualMode ? .crosshair : .arrow) }
    override func mouseDown(with event: NSEvent) {
        guard manualMode, let image else { return }
        let fit = image.size.aspectFit(in: bounds.insetBy(dx: 12, dy: 12))
        let p = convert(event.locationInWindow, from: nil)
        guard fit.contains(p) else { return }
            onOutlinePoint?(Point2(x: (p.x-fit.minX)/fit.width, y: 1-(p.y-fit.minY)/fit.height))
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        guard let image else { let s="写真を選ぶと輪郭を表示します" as NSString; s.draw(at:NSPoint(x:20,y:20),withAttributes:[.foregroundColor:NSColor.secondaryLabelColor]); return }
        let fitted=image.size.aspectFit(in:bounds.insetBy(dx:12,dy:12))
        if showCutout,let cutoutImage {
            let step=12.0
            var y=fitted.minY
            while y<fitted.maxY { var x=fitted.minX
                while x<fitted.maxX { let r=NSRect(x:x,y:y,width:min(step,fitted.maxX-x),height:min(step,fitted.maxY-y));((Int((x-fitted.minX)/step)+Int((y-fitted.minY)/step))%2==0 ? NSColor.white:NSColor(calibratedWhite:0.88,alpha:1)).setFill();NSBezierPath(rect:r).fill();x+=step }
                y+=step
            }
            cutoutImage.draw(in:fitted)
        } else { image.draw(in:fitted) }
        guard points.count>2 else{return}
        let path=NSBezierPath()
        for (i,p) in points.enumerated() { let q=NSPoint(x:fitted.minX+p.x*fitted.width,y:fitted.maxY-p.y*fitted.height); i==0 ? path.move(to:q) : path.line(to:q) }
        if outlineClosed { path.close() }
        path.lineWidth=2; path.setLineDash([6,3],count:2,phase:0); NSColor.systemOrange.setStroke(); path.stroke()
        for p in points {
            let dot=NSBezierPath(ovalIn:NSRect(x:fitted.minX+p.x*fitted.width-2.5,y:fitted.maxY-p.y*fitted.height-2.5,width:5,height:5))
            NSColor.systemOrange.setFill(); dot.fill()
        }
    }
}

private extension CGSize {
    func aspectFit(in rect: CGRect) -> CGRect {
        let s=min(rect.width/width,rect.height/height); let w=width*s,h=height*s
        return CGRect(x:rect.midX-w/2,y:rect.midY-h/2,width:w,height:h)
    }
}

enum SilhouetteError: Error { case cannotReadPixels }

enum Silhouette {
    static func detect(matte:ForegroundMatte)->[Point2] {
        let w=matte.width,h=matte.height,mask=matte.alpha.map{$0>=128}
        var boundary:[Point2]=[]
        for y in 0..<h { for x in 0..<w {
            let i=y*w+x
            if mask[i] && (x==0 || x==w-1 || y==0 || y==h-1 || !mask[y*w+max(0,x-1)] || !mask[y*w+min(w-1,x+1)] || !mask[max(0,y-1)*w+x] || !mask[min(h-1,y+1)*w+x]) {
                boundary.append(Point2(x:Double(x)/Double(w-1),y:Double(y)/Double(h-1)))
            }
        }}
        guard boundary.count>=3 else{return []}
        let topOrigin=boundary.map { Point2(x:$0.x,y:1-$0.y) }
        let cx=topOrigin.map(\.x).reduce(0,+)/Double(topOrigin.count),cy=topOrigin.map(\.y).reduce(0,+)/Double(topOrigin.count)
        let ordered=topOrigin.sorted { left,right in
            atan2(left.y-cy,left.x-cx) < atan2(right.y-cy,right.x-cx)
        }
        // Angular ordering retains practical concavities that a convex hull
        // destroys, while reducing pixel noise to a printable vertex count.
        let stride=max(1,Int(ceil(Double(ordered.count)/48.0)))
        return ordered.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
    }
    private static func convexHull(_ points: [Point2]) -> [Point2] {
        let p = Array(Set(points)).sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard p.count > 2 else { return p }
        func cross(_ o: Point2, _ a: Point2, _ b: Point2) -> Double { (a.x-o.x)*(b.y-o.y) - (a.y-o.y)*(b.x-o.x) }
        var lower: [Point2] = []
        for q in p { while lower.count >= 2 && cross(lower[lower.count-2], lower[lower.count-1], q) <= 0 { lower.removeLast() }; lower.append(q) }
        var upper: [Point2] = []
        for q in p.reversed() { while upper.count >= 2 && cross(upper[upper.count-2], upper[upper.count-1], q) <= 0 { upper.removeLast() }; upper.append(q) }
        lower.removeLast(); upper.removeLast()
        let joined = lower + upper
        // Reduce excessive vertices while preserving a usable, printable outline.
        let stride = max(1, Int(ceil(Double(joined.count) / 24.0)))
        return joined.enumerated().compactMap { $0.offset % stride == 0 ? $0.element : nil }
    }
}

enum NetExporter {
    static func writePDF(points: [Point2], widthMM: Double, depthMM: Double, faceImage:CGImage?=nil,sideColor:CGColor=NSColor.lightGray.cgColor,to url: URL) throws {
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!, minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let sourceW = max(0.001, maxX-minX), sourceH = max(0.001, maxY-minY)
        let faceW = widthMM, faceH = widthMM * sourceH / sourceW
        let norm = points.map { Point2(x: ($0.x-minX)/sourceW*faceW, y: ($0.y-minY)/sourceH*faceH) }
        let textureCrop=faceImage.flatMap { image -> CGImage? in
            let crop=CGRect(x:minX*Double(image.width),y:(1-maxY)*Double(image.height),width:sourceW*Double(image.width),height:sourceH*Double(image.height)).integral
            guard crop.width>=1,crop.height>=1 else{return image}
            return image.cropping(to:crop) ?? image
        }
        var perimeter = 0.0
        for i in norm.indices { let a=norm[i], b=norm[(i+1)%norm.count]; perimeter += hypot(b.x-a.x, b.y-a.y) }
        var distances: [Double] = []
        var travelled = 0.0
        for i in norm.indices { distances.append(travelled); let a=norm[i], b=norm[(i+1)%norm.count]; travelled += hypot(b.x-a.x, b.y-a.y) }
        let gap = 10.0, tab = 5.0, left = 10.0, top = 10.0
        let designW = max(perimeter + tab, faceW*2 + gap) + left*2
        let designH = faceH + depthMM + tab*2 + gap + top*2
        // A4 printable area is 277 x 190 mm. Adjacent pages overlap by 10 mm
        // so the user can align and tape tiled patterns without shrinking them.
        let printableW = 277.0, printableH = 190.0, overlap = 10.0
        let stepX = printableW - overlap, stepY = printableH - overlap
        let columns = max(1, Int(ceil(max(0, designW - overlap) / stepX)))
        let rows = max(1, Int(ceil(max(0, designH - overlap) / stepY)))
        let face2X = left + faceW + gap
        let stripX = left, stripY = top + faceH + gap
        let pageW = 297.0 * 72.0 / 25.4, pageH = 210.0 * 72.0 / 25.4
        var mediaBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.saveGState()
        let mmToPoints = 72.0 / 25.4
        context.setLineCap(.round); context.setLineJoin(.round)
        func drawPolygon(_ pts: [Point2], x: Double, y: Double) {
            guard let first = pts.first else { return }
            context.beginPath(); context.move(to: CGPoint(x: x+first.x, y: y+first.y))
            for p in pts.dropFirst() { context.addLine(to: CGPoint(x: x+p.x, y: y+p.y)) }
            context.closePath(); context.strokePath()
        }
        func drawLine(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
            context.beginPath(); context.move(to: CGPoint(x:x1,y:y1)); context.addLine(to: CGPoint(x:x2,y:y2)); context.strokePath()
        }
        func drawTexturedFace(at x:Double,y:Double) {
            guard let textureCrop else{return}
            context.saveGState();context.beginPath();context.move(to:CGPoint(x:x+norm[0].x,y:y+norm[0].y))
            for point in norm.dropFirst(){context.addLine(to:CGPoint(x:x+point.x,y:y+point.y))};context.closePath();context.clip()
            context.translateBy(x:0,y:2*y+faceH);context.scaleBy(x:1,y:-1)
            context.draw(textureCrop,in:CGRect(x:x,y:y,width:faceW,height:faceH));context.restoreGState()
        }
        for row in 0..<rows { for col in 0..<columns {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: left * mmToPoints, y: pageH - top * mmToPoints)
            context.scaleBy(x: mmToPoints, y: -mmToPoints)
            context.translateBy(x: -Double(col) * stepX, y: -Double(row) * stepY)
            context.beginPath(); context.addRect(CGRect(x: Double(col)*stepX, y: Double(row)*stepY, width: printableW, height: printableH)); context.clip()
            context.setStrokeColor(NSColor(calibratedRed:0.82,green:0.16,blue:0.15,alpha:1).cgColor)
            context.setLineWidth(0.35)
            drawTexturedFace(at:left,y:top)
            drawTexturedFace(at:face2X,y:top)
            drawPolygon(norm, x:left, y:top)
            drawPolygon(norm, x:face2X, y:top)
            context.beginPath()
            context.move(to: CGPoint(x:stripX,y:stripY-tab))
            context.addLine(to: CGPoint(x:stripX+perimeter,y:stripY-tab))
            context.addLine(to: CGPoint(x:stripX+perimeter+tab,y:stripY))
            context.addLine(to: CGPoint(x:stripX+perimeter+tab,y:stripY+depthMM))
            context.addLine(to: CGPoint(x:stripX+perimeter,y:stripY+depthMM+tab))
            context.addLine(to: CGPoint(x:stripX,y:stripY+depthMM+tab))
            context.closePath();context.setFillColor(sideColor);context.drawPath(using:.fillStroke)
            // Small glue tabs on each side panel connect the two silhouette faces
            // to the wraparound wall. The dashed boundary remains the crease.
            context.setLineDash(phase:0,lengths:[])
            for i in norm.indices {
                let segmentEnd = norm[(i+1) % norm.count]
                let segment = hypot(segmentEnd.x - norm[i].x, segmentEnd.y - norm[i].y)
                let inset = min(1.5, segment * 0.12)
                let a = distances[i] + inset, b = distances[i] + segment - inset
                guard b-a > 2 else { continue }
                let tabHeight = min(5.0, (b-a) * 0.28)
                for edgeY in [stripY, stripY+depthMM] {
                    let direction = edgeY == stripY ? -1.0 : 1.0
                    context.beginPath()
                    context.move(to: CGPoint(x:stripX+a,y:edgeY))
                    context.addLine(to: CGPoint(x:stripX+b,y:edgeY))
                    context.addLine(to: CGPoint(x:stripX+b-inset,y:edgeY+direction*tabHeight))
                    context.addLine(to: CGPoint(x:stripX+a+inset,y:edgeY+direction*tabHeight))
                    context.closePath(); context.strokePath()
                }
            }
            context.setStrokeColor(NSColor(calibratedRed:0.12,green:0.42,blue:0.74,alpha:1).cgColor)
            context.setLineWidth(0.25); context.setLineDash(phase:0,lengths:[2,1.5])
            drawLine(stripX,stripY,stripX+perimeter,stripY)
            drawLine(stripX,stripY+depthMM,stripX+perimeter,stripY+depthMM)
            for d in distances { drawLine(stripX+d,stripY,stripX+d,stripY+depthMM) }
            context.setLineDash(phase:0,lengths:[])
            context.restoreGState()
            // A physical 100 mm calibration bar lets the maker verify that the
            // printer dialog was set to 100% before cutting a saleable model.
            let barX=10*mmToPoints,barY=12*mmToPoints,barLength=100*mmToPoints
            context.setStrokeColor(NSColor.black.cgColor);context.setLineWidth(0.7)
            context.beginPath();context.move(to:CGPoint(x:barX,y:barY));context.addLine(to:CGPoint(x:barX+barLength,y:barY));context.strokePath()
            for x in [barX,barX+barLength] { context.beginPath();context.move(to:CGPoint(x:x,y:barY-3));context.addLine(to:CGPoint(x:x,y:barY+3));context.strokePath() }
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
            let attrs: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize:8),.foregroundColor:NSColor.darkGray]
            ("CUT: red | FOLD: blue dashed | A4 100% | page \(row*columns+col+1)/\(rows*columns) | overlap 10 mm" as NSString).draw(at:NSPoint(x:10*mmToPoints,y:7*mmToPoints),withAttributes:attrs)
            ("100 mm" as NSString).draw(at:NSPoint(x:barX+barLength/2-12,y:barY+4),withAttributes:attrs)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }}
        context.closePDF()
        try (data as Data).write(to:url,options:.atomic)
    }
}
