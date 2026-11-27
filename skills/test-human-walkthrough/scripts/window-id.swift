// 録画・撮影の対象ウィンドウの CGWindowID を 1 つ出力する(screencapture -l に渡す)。
// 第 1 引数はアプリ名(kCGWindowOwnerName。例: "Google Chrome"、"TextEdit")。
// 第 2 引数を渡すと、ウィンドウ名(Chrome ならアクティブタブのタイトル)の一部で絞り込む。
// タブバーやインフォバーなど細い補助ウィンドウも layer 0 で列挙されるため、面積が最大のものを選ぶ。
// 使い方: swift window-id.swift <アプリ名> [ウィンドウ名の一部]
import CoreGraphics
import Foundation

guard let owner = CommandLine.arguments.dropFirst().first else {
  FileHandle.standardError.write("使い方: swift window-id.swift <アプリ名> [ウィンドウ名の一部]\n".data(using: .utf8)!)
  exit(2)
}
let needle = CommandLine.arguments.dropFirst(2).first
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []

let candidates = windows.compactMap { window -> (id: Int, area: Double, name: String)? in
  guard window[kCGWindowOwnerName as String] as? String == owner,
    window[kCGWindowLayer as String] as? Int == 0,
    let id = window[kCGWindowNumber as String] as? Int,
    let bounds = window[kCGWindowBounds as String] as? [String: Any],
    let width = (bounds["Width"] as? NSNumber)?.doubleValue,
    let height = (bounds["Height"] as? NSNumber)?.doubleValue
  else { return nil }
  let name = window[kCGWindowName as String] as? String ?? ""
  if let needle, !name.contains(needle) { return nil }
  return (id, width * height, name)
}

guard let best = candidates.max(by: { $0.area < $1.area }) else {
  // 別スペースへ移した・最小化したウィンドウ、全画面アプリの裏の Space のウィンドウは onScreenOnly から外れる
  // (2026-10-01 Chrome、2026-10-17 全画面 Ghostty の裏のメニューバー常駐アプリで実測)。
  FileHandle.standardError.write(
    "画面上に \(owner) のウィンドウが見つかりません(ウィンドウ名の指定: \(needle ?? "なし"))。別スペース・最小化なら画面に戻してください\n"
      .data(using: .utf8)!)
  exit(1)
}
FileHandle.standardError.write("window \(best.id): \(best.name)\n".data(using: .utf8)!)
print(best.id)
