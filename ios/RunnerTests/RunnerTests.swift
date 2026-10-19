import Flutter
import UIKit
import XCTest
@testable import Runner

class RunnerTests: XCTestCase {

  private func tone() -> Data {
    let samples: UInt32 = 16000
    var data = Data("RIFF".utf8)
    func append(_ value: UInt32) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
    func short(_ value: UInt16) { var n = value.littleEndian; withUnsafeBytes(of: &n) { data.append(contentsOf: $0) } }
    append(36 + samples * 2)
    data.append(Data("WAVEfmt ".utf8)); append(16)
    short(1); short(1); append(8000); append(16000); short(2); short(16)
    data.append(Data("data".utf8)); append(samples * 2)
    data.append(Data(repeating: 0, count: Int(samples * 2)))
    return data
  }

  func testFolderImportPreservesHierarchyAndOriginal() throws {
    let fm = FileManager.default
    let source = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let album = source.appendingPathComponent("Artist/Album")
    try fm.createDirectory(at: album, withIntermediateDirectories: true)
    let audio = album.appendingPathComponent("song.wav")
    try tone().write(to: audio)
    try Data("ignore".utf8).write(to: album.appendingPathComponent("notes.txt"))
    defer { try? fm.removeItem(at: source) }
    let items = try LocalMusicPlugin.copySelection([source], folder: true)
    let tracks = items.filter { $0["kind"] as? String == "track" }
    XCTAssertEqual(tracks.count, 1)
    let track = try XCTUnwrap(tracks.first)
    XCTAssertEqual(track["name"] as? String, "")
    let path = try XCTUnwrap(track["path"] as? String)
    let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let batch = support.appendingPathComponent(path.split(separator: "/").prefix(2).joined(separator: "/"))
    defer { try? fm.removeItem(at: batch) }
    XCTAssertEqual(try Data(contentsOf: support.appendingPathComponent(path)), try Data(contentsOf: audio))
    XCTAssertGreaterThan(track["durationMs"] as? Int ?? 0, 1900)
    let parent = try XCTUnwrap(items.first { $0["id"] as? String == track["parentId"] as? String })
    XCTAssertEqual(parent["name"] as? String, "Album")
    XCTAssertTrue(fm.fileExists(atPath: audio.path))
    XCTAssertEqual(items.filter { $0["fileName"] as? String == "notes.txt" }.count, 0)
  }

  func testSameFilenameFromDifferentSelectionsRemainsDistinct() throws {
    let fm = FileManager.default
    let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? fm.removeItem(at: base) }
    var urls: [URL] = []
    for part in ["one", "two"] {
      let folder = base.appendingPathComponent(part)
      try fm.createDirectory(at: folder, withIntermediateDirectories: true)
      let file = folder.appendingPathComponent("same.wav")
      try tone().write(to: file); urls.append(file)
    }
    let items = try LocalMusicPlugin.copySelection(urls, folder: false)
    XCTAssertEqual(items.count, 2)
    XCTAssertNotEqual(items[0]["id"] as? String, items[1]["id"] as? String)
    XCTAssertEqual(items[0]["parentId"] as? String, "local:root")
    let path = try XCTUnwrap(items[0]["path"] as? String)
    let support = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    try fm.removeItem(at: support.appendingPathComponent(path.split(separator: "/").prefix(2).joined(separator: "/")))
  }

}
