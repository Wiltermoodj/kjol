import Cocoa
import CoreGraphics

let fileManager = FileManager.default
let sourceFolder = "/Users/lappier/Downloads/kjol-images"
let projectDir = "/Users/lappier/code/projects/kjol"
let resourcesDir = "\(projectDir)/Kjol/Resources"

try? fileManager.createDirectory(atPath: resourcesDir, withIntermediateDirectories: true)

func cropAndSaveImage(
    sourceName: String,
    destName: String,
    cropMarginThreshold: Int = 35,
    targetWidth: CGFloat? = nil
) {
    let sourcePath = "\(sourceFolder)/\(sourceName)"
    let destPath = "\(resourcesDir)/\(destName)"
    
    guard let img = NSImage(contentsOfFile: sourcePath),
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let cgImage = rep.cgImage else {
        print("Error: Could not load \(sourceName)")
        return
    }
    
    let w = cgImage.width
    let h = cgImage.height
    guard let dataProvider = cgImage.dataProvider,
          let data = dataProvider.data,
          let ptr = CFDataGetBytePtr(data) else { return }
    let bpr = cgImage.bytesPerRow
    let bpp = cgImage.bitsPerPixel / 8
    
    // Sample corner colors
    func getPixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let offset = y * bpr + x * bpp
        return (Int(ptr[offset]), Int(ptr[offset+1]), Int(ptr[offset+2]))
    }
    
    let c00 = getPixel(0, 0)
    let cW0 = getPixel(w - 1, 0)
    let c0H = getPixel(0, h - 1)
    let cWH = getPixel(w - 1, h - 1)
    let bgR = (c00.r + cW0.r + c0H.r + cWH.r) / 4
    let bgG = (c00.g + cW0.g + c0H.g + cWH.g) / 4
    let bgB = (c00.b + cW0.b + c0H.b + cWH.b) / 4
    
    var minX = w, maxX = 0, minY = h, maxY = 0
    for y in 0..<h {
        for x in 0..<w {
            let p = getPixel(x, y)
            let diff = abs(p.r - bgR) + abs(p.g - bgG) + abs(p.b - bgB)
            if diff > cropMarginThreshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    
    // If not found or trivial, use full rect
    if maxX <= minX || maxY <= minY {
        minX = 0; maxX = w - 1; minY = 0; maxY = h - 1
    }
    
    // Add 2px safety padding inside image bounds
    minX = max(0, minX - 2)
    minY = max(0, minY - 2)
    maxX = min(w - 1, maxX + 2)
    maxY = min(h - 1, maxY + 2)
    
    let cropWidth = maxX - minX + 1
    let cropHeight = maxY - minY + 1
    let cropRect = CGRect(x: minX, y: minY, width: cropWidth, height: cropHeight)
    
    print("Cropping \(sourceName) from (\(w)x\(h)) to (\(cropWidth)x\(cropHeight)) at (x:\(minX), y:\(minY))")
    
    guard let croppedCg = cgImage.cropping(to: cropRect) else {
        print("Failed to crop \(sourceName)")
        return
    }
    
    var outWidth = CGFloat(cropWidth)
    var outHeight = CGFloat(cropHeight)
    if let targetW = targetWidth, outWidth > targetW {
        let scale = targetW / outWidth
        outWidth = targetW
        outHeight = round(outHeight * scale)
    }
    
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: Int(outWidth),
        height: Int(outHeight),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    
    ctx.interpolationQuality = .high
    ctx.draw(croppedCg, in: CGRect(x: 0, y: 0, width: outWidth, height: outHeight))
    
    guard let finalCg = ctx.makeImage() else { return }
    let bitmapRep = NSBitmapImageRep(cgImage: finalCg)
    let isPng = destName.hasSuffix(".png")
    let fileType: NSBitmapImageRep.FileType = isPng ? .png : .jpeg
    let props: [NSBitmapImageRep.PropertyKey: Any] = isPng ? [:] : [.compressionFactor: 0.85]
    guard let outData = bitmapRep.representation(using: fileType, properties: props) else { return }
    
    try? outData.write(to: URL(fileURLWithPath: destPath))
    print("✓ Saved \(destName) (\(Int(outWidth))x\(Int(outHeight)))")
}

// 1. Process App Icon & Generate AppIcon.icns
func processAppIcon() {
    let sourcePath = "\(sourceFolder)/kjol-app-icon.jpg"
    guard let img = NSImage(contentsOfFile: sourcePath),
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let cgImage = rep.cgImage else { return }
    
    let w = cgImage.width
    let h = cgImage.height
    guard let dataProvider = cgImage.dataProvider,
          let data = dataProvider.data,
          let ptr = CFDataGetBytePtr(data) else { return }
    let bpr = cgImage.bytesPerRow
    let bpp = cgImage.bitsPerPixel / 8
    
    // Find inner squircle content bounds (ignoring grey/checkerboard border)
    func getPixel(_ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
        let offset = y * bpr + x * bpp
        return (Int(ptr[offset]), Int(ptr[offset+1]), Int(ptr[offset+2]))
    }
    
    // Corner background is ~220
    var minX = w, maxX = 0, minY = h, maxY = 0
    for y in 0..<h {
        for x in 0..<w {
            let p = getPixel(x, y)
            let brightness = (p.r + p.g + p.b) / 3
            // The icon background is dark (<100) or rich colors, canvas is >180
            if brightness < 170 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    
    // Make crop square
    let contentW = maxX - minX + 1
    let contentH = maxY - minY + 1
    let squareSide = max(contentW, contentH)
    let midX = (minX + maxX) / 2
    let midY = (minY + maxY) / 2
    let cropOriginX = max(0, min(w - squareSide, midX - squareSide / 2))
    let cropOriginY = max(0, min(h - squareSide, midY - squareSide / 2))
    let cropRect = CGRect(x: cropOriginX, y: cropOriginY, width: squareSide, height: squareSide)
    
    print("App Icon Crop Rect: \(cropRect) from \(w)x\(h)")
    guard let croppedCg = cgImage.cropping(to: cropRect) else { return }
    
    let iconsetDir = "\(resourcesDir)/AppIcon.iconset"
    try? fileManager.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)
    
    let iconSizes: [(name: String, px: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024)
    ]
    
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    for item in iconSizes {
        guard let ctx = CGContext(
            data: nil,
            width: item.px,
            height: item.px,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { continue }
        
        ctx.interpolationQuality = .high
        ctx.draw(croppedCg, in: CGRect(x: 0, y: 0, width: item.px, height: item.px))
        if let outCg = ctx.makeImage() {
            let outRep = NSBitmapImageRep(cgImage: outCg)
            if let pngData = outRep.representation(using: .png, properties: [:]) {
                try? pngData.write(to: URL(fileURLWithPath: "\(iconsetDir)/\(item.name)"))
            }
        }
    }
    
    // Run iconutil to create .icns
    let icnsPath = "\(resourcesDir)/AppIcon.icns"
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconsetDir, "-o", icnsPath]
    try? task.run()
    task.waitUntilExit()
    
    // Clean up temporary iconset directory
    try? fileManager.removeItem(atPath: iconsetDir)
    print("✓ Generated \(icnsPath)")
}

// 2. Process Menu Bar Status Icon (Monochrome Alpha Mask)
func processStatusBarIcon() {
    let sourcePath = "\(sourceFolder)/menu-bar-status-icon.jpg"
    guard let img = NSImage(contentsOfFile: sourcePath),
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let cgImage = rep.cgImage else { return }
    
    let w = cgImage.width
    let h = cgImage.height
    guard let dataProvider = cgImage.dataProvider,
          let data = dataProvider.data,
          let ptr = CFDataGetBytePtr(data) else { return }
    let bpr = cgImage.bytesPerRow
    let bpp = cgImage.bitsPerPixel / 8
    
    // Find glyph bounds (bright pixels)
    var minX = w, maxX = 0, minY = h, maxY = 0
    for y in 0..<h {
        for x in 0..<w {
            let offset = y * bpr + x * bpp
            let brightness = (Int(ptr[offset]) + Int(ptr[offset+1]) + Int(ptr[offset+2])) / 3
            if brightness > 30 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    
    // Add small breathing margin to the crop
    let pad = 30
    minX = max(0, minX - pad)
    minY = max(0, minY - pad)
    maxX = min(w - 1, maxX + pad)
    maxY = min(h - 1, maxY + pad)
    
    let cropW = maxX - minX + 1
    let cropH = maxY - minY + 1
    let side = max(cropW, cropH)
    let midX = (minX + maxX) / 2
    let midY = (minY + maxY) / 2
    let cropOriginX = max(0, min(w - side, midX - side / 2))
    let cropOriginY = max(0, min(h - side, midY - side / 2))
    let cropRect = CGRect(x: cropOriginX, y: cropOriginY, width: side, height: side)
    
    guard let croppedCg = cgImage.cropping(to: cropRect) else { return }
    
    // Create template alpha mask image (18x18 for 1x, 36x36 for 2x)
    func makeTemplateIcon(size: Int, filename: String) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        // Draw into grayscale / alpha buffer
        guard let ctx = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        
        ctx.interpolationQuality = .high
        ctx.draw(croppedCg, in: CGRect(x: 0, y: 0, width: size, height: size))
        
        guard let renderedCg = ctx.makeImage(),
              let renderedData = renderedCg.dataProvider?.data,
              let renderedPtr = CFDataGetBytePtr(renderedData) else { return }
        
        // Build pure black + alpha mask
        var alphaData = [UInt8](repeating: 0, count: size * size * 4)
        for i in 0..<(size * size) {
            let r = renderedPtr[i * 4]
            let g = renderedPtr[i * 4 + 1]
            let b = renderedPtr[i * 4 + 2]
            let brightness = (Int(r) + Int(g) + Int(b)) / 3
            // Apply slight S-curve contrast for clean edges
            let alpha = UInt8(min(255, max(0, Int(Double(brightness) * 1.15))))
            alphaData[i * 4] = 0       // R (black)
            alphaData[i * 4 + 1] = 0   // G (black)
            alphaData[i * 4 + 2] = 0   // B (black)
            alphaData[i * 4 + 3] = alpha // Alpha
        }
        
        guard let maskCtx = CGContext(
            data: &alphaData,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let finalMaskCg = maskCtx.makeImage() else { return }
        
        let rep = NSBitmapImageRep(cgImage: finalMaskCg)
        if let pngData = rep.representation(using: .png, properties: [:]) {
            let dest = "\(resourcesDir)/\(filename)"
            try? pngData.write(to: URL(fileURLWithPath: dest))
            print("✓ Saved \(filename) (\(size)x\(size))")
        }
    }
    
    makeTemplateIcon(size: 18, filename: "KjolStatusIcon.png")
    makeTemplateIcon(size: 36, filename: "KjolStatusIcon@2x.png")
}

print("=== Starting Asset Optimization & Cropping ===")
processAppIcon()
processStatusBarIcon()

cropAndSaveImage(
    sourceName: "fan-control-header-illustration.jpg",
    destName: "fan-header.jpg",
    cropMarginThreshold: 30,
    targetWidth: 720
)

// Battery card has light canvas border (>220 brightness)
func processBatteryCard() {
    let sourcePath = "\(sourceFolder)/hardware-change-limiter-battery-accent-card.jpg"
    guard let img = NSImage(contentsOfFile: sourcePath),
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let cgImage = rep.cgImage else { return }
    let w = cgImage.width
    let h = cgImage.height
    guard let ptr = CFDataGetBytePtr(cgImage.dataProvider!.data!) else { return }
    let bpr = cgImage.bytesPerRow, bpp = cgImage.bitsPerPixel / 8
    
    var minX = w, maxX = 0, minY = h, maxY = 0
    for y in 0..<h {
        for x in 0..<w {
            let off = y * bpr + x * bpp
            let brightness = (Int(ptr[off]) + Int(ptr[off+1]) + Int(ptr[off+2])) / 3
            if brightness < 210 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
    }
    
    let cropRect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    guard let cropped = cgImage.cropping(to: cropRect) else { return }
    
    let targetW: CGFloat = 720
    let scale = targetW / CGFloat(cropRect.width)
    let targetH = round(CGFloat(cropRect.height) * scale)
    
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: Int(targetW),
        height: Int(targetH),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return }
    ctx.interpolationQuality = .high
    ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
    
    if let outCg = ctx.makeImage() {
        let bitmapRep = NSBitmapImageRep(cgImage: outCg)
        let props: [NSBitmapImageRep.PropertyKey: Any] = [.compressionFactor: 0.85]
        if let outData = bitmapRep.representation(using: .jpeg, properties: props) {
            try? outData.write(to: URL(fileURLWithPath: "\(resourcesDir)/battery-header.jpg"))
            print("✓ Saved battery-header.jpg (\(Int(targetW))x\(Int(targetH)))")
        }
    }
}

processBatteryCard()

cropAndSaveImage(
    sourceName: "clamshell-always-on-accent-motif.jpg",
    destName: "clamshell-motif.jpg",
    cropMarginThreshold: 30,
    targetWidth: 512
)

print("=== Asset Processing Complete ===")
