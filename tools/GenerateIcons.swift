import AppKit

// 图标生成器：把 icons/ 下的 SVG 转成 App 需要的位图与 icns
// 用法: GenerateIcons <icons 目录> <目标 Resources 目录>
//
// macOS 的 NSImage 内置矢量 SVG 支持（_NSSVGImageRep），
// 所以无需额外安装 librsvg/ImageMagick，直接按目标尺寸栅格化即可。

/// 把 SVG 渲染成指定像素尺寸的 PNG
/// - Parameters:
///   - svg: 源 SVG 文件
///   - pixelSize: 输出的正方形边长（像素）
///   - destination: 输出 PNG 路径
/// - Returns: 是否成功
func renderPNG(svg: URL, pixelSize: Int, destination: URL) -> Bool {
    guard let image = NSImage(contentsOf: svg) else {
        FileHandle.standardError.write("无法加载 SVG: \(svg.path)\n".data(using: .utf8)!)
        return false
    }
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize, pixelsHigh: pixelSize,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return false }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
        from: .zero, operation: .sourceOver, fraction: 1.0
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else { return false }
    do {
        try data.write(to: destination)
        return true
    } catch {
        FileHandle.standardError.write("写入失败 \(destination.path): \(error)\n".data(using: .utf8)!)
        return false
    }
}

/// 生成 .icns：先铺出 iconset 要求的全套尺寸，再交给 iconutil 打包
/// - Parameters:
///   - svg: 源 SVG 文件
///   - destination: 输出 icns 路径
/// - Returns: 是否成功
func renderICNS(svg: URL, destination: URL) -> Bool {
    let fileManager = FileManager.default
    let iconset = fileManager.temporaryDirectory
        .appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
    defer { try? fileManager.removeItem(at: iconset) }

    do {
        try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
    } catch {
        FileHandle.standardError.write("无法创建 iconset: \(error)\n".data(using: .utf8)!)
        return false
    }

    // iconset 约定的文件名 → 像素尺寸
    let variants: [(name: String, pixels: Int)] = [
        ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
    ]
    for variant in variants {
        let target = iconset.appendingPathComponent(variant.name)
        guard renderPNG(svg: svg, pixelSize: variant.pixels, destination: target) else { return false }
    }

    let iconutil = Process()
    iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    iconutil.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
    do {
        try iconutil.run()
    } catch {
        FileHandle.standardError.write("iconutil 启动失败: \(error)\n".data(using: .utf8)!)
        return false
    }
    iconutil.waitUntilExit()
    if iconutil.terminationStatus != 0 {
        FileHandle.standardError.write("iconutil 失败，退出码 \(iconutil.terminationStatus)\n".data(using: .utf8)!)
        return false
    }
    return true
}

// MARK: - 入口

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write("用法: GenerateIcons <icons 目录> <目标 Resources 目录>\n".data(using: .utf8)!)
    exit(2)
}
let iconsDir = URL(fileURLWithPath: arguments[1])
let resourcesDir = URL(fileURLWithPath: arguments[2])

let batterySVG = iconsDir.appendingPathComponent("icon-battery.svg")
let adapterSVG = iconsDir.appendingPathComponent("icon-adapter.svg")

var allSucceeded = true

// App 图标使用黄色的电源 SVG
allSucceeded = renderICNS(svg: adapterSVG, destination: resourcesDir.appendingPathComponent("AppIcon.icns")) && allSucceeded

// 状态栏图标：18pt 逻辑尺寸，同时给出 @1x 与 @2x
let statusIcons: [(svg: URL, base: String)] = [
    (batterySVG, "status-battery"),
    (adapterSVG, "status-adapter"),
]
for icon in statusIcons {
    allSucceeded = renderPNG(svg: icon.svg, pixelSize: 18,
                             destination: resourcesDir.appendingPathComponent("\(icon.base).png")) && allSucceeded
    allSucceeded = renderPNG(svg: icon.svg, pixelSize: 36,
                             destination: resourcesDir.appendingPathComponent("\(icon.base)@2x.png")) && allSucceeded
}

exit(allSucceeded ? 0 : 1)
