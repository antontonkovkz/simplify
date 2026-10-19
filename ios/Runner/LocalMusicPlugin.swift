import AVFoundation
import Flutter
import UniformTypeIdentifiers
import UIKit

/// User-selected Files folders/files only. Imported copies and metadata are
/// processed on a utility queue; originals and other apps' files are untouched.
final class LocalMusicPlugin: NSObject, FlutterPlugin, UIDocumentPickerDelegate {
  private var pending: FlutterResult?
  private var folderMode = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "online.tavhome.simplefy/local_music", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(LocalMusicPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "importFolder" || call.method == "importFiles" else { result(FlutterMethodNotImplemented); return }
    guard pending == nil else { result(FlutterError(code: "busy", message: "Выбор файлов уже открыт", details: nil)); return }
    folderMode = call.method == "importFolder"
    let picker = UIDocumentPickerViewController(forOpeningContentTypes: folderMode ? [.folder] : [.item], asCopy: false)
    picker.allowsMultipleSelection = !folderMode
    picker.delegate = self
    var host = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .flatMap { $0.windows }.first(where: { $0.isKeyWindow })?.rootViewController
    while let presented = host?.presentedViewController { host = presented }
    guard let host else { result(FlutterError(code: "unavailable", message: "Не удалось открыть Файлы", details: nil)); return }
    pending = result
    host.present(picker, animated: true)
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    pending?(nil); pending = nil
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let reply = pending else { return }
    let folder = folderMode
    // Keep the callback reserved until copying has finished.
    DispatchQueue.global(qos: .utility).async {
      do {
        let items = try Self.copySelection(urls, folder: folder)
        DispatchQueue.main.async { self.pending = nil; reply(items) }
      } catch {
        DispatchQueue.main.async {
          self.pending = nil
          reply(FlutterError(code: "import_failed", message: "Не удалось импортировать музыку. Проверьте доступ к файлам и свободное место.", details: nil))
        }
      }
    }
  }

  private static let formats: Set<String> = ["mp3", "m4a", "flac", "wav", "aac", "aiff", "aif", "alac", "caf", "mp4"]

  static func copySelection(_ urls: [URL], folder: Bool) throws -> [[String: Any]] {
    let fm = FileManager.default
    let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let batch = UUID().uuidString
    let base = support.appendingPathComponent("local_music/\(batch)", isDirectory: true)
    try fm.createDirectory(at: base, withIntermediateDirectories: true)
    var items: [[String: Any]] = []
    func node(_ url: URL, relative: String, parent: String, directory: Bool) -> [String: Any] {
      var value: [String: Any] = ["id": "local:\(batch):\(relative)", "name": url.lastPathComponent,
        "kind": directory ? "folder" : "track", "parentId": parent,
        "fileName": directory ? "" : url.lastPathComponent, "path": "local_music/\(batch)/\(relative)"]
      if !directory {
        value["name"] = "" // Missing title must fall back to the filename without its extension.
        let asset = AVURLAsset(url: base.appendingPathComponent(relative))
        let seconds = CMTimeGetSeconds(asset.duration)
        if seconds.isFinite && seconds > 0 { value["durationMs"] = Int(seconds * 1000) }
        for tag in asset.commonMetadata {
          if tag.commonKey == .commonKeyTitle, let title = tag.stringValue { value["name"] = title }
          if tag.commonKey == .commonKeyArtist, let artist = tag.stringValue { value["artist"] = artist }
        }
      }
      return value
    }
    func copy(_ source: URL, relative: String, parent: String) throws {
      let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
      if values.isSymbolicLink == true { return }
      if values.isDirectory == true {
        try fm.createDirectory(at: base.appendingPathComponent(relative), withIntermediateDirectories: true)
        let value = node(source, relative: relative, parent: parent, directory: true)
        items.append(value)
        for child in try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
          try copy(child, relative: relative + "/" + child.lastPathComponent, parent: value["id"] as! String)
        }
      } else if values.isRegularFile == true && formats.contains(source.pathExtension.lowercased()) {
        let destination = base.appendingPathComponent(relative)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var failure: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
          do { try fm.copyItem(at: readable, to: destination) } catch { failure = error }
        }
        if let error = failure ?? coordinationError { throw error }
        items.append(node(source, relative: relative, parent: parent, directory: false))
      }
    }
    do {
      for (index, url) in urls.enumerated() {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        // Individual files receive their own subdirectory to preserve identical filenames.
        let relative = folder ? url.lastPathComponent : "\(index)/\(url.lastPathComponent)"
        try copy(url, relative: relative, parent: "local:root")
      }
      return items
    } catch {
      try? fm.removeItem(at: base)
      throw error
    }
  }
}
