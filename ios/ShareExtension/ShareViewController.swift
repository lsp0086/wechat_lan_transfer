//
//  ShareViewController.swift
//  ShareExtension
//
//  U2/iOS：实现 receive_sharing_intent 兼容逻辑，
//  收到的图片/视频/文件/文字经 App Group 转交主 App（initialMedia/getMediaStream）。
//  独立内建实现，避免 Extension 依赖 Flutter.framework 与 receive_sharing_intent pod。
//

import UIKit
import Social
import MobileCoreServices
import Photos
import UniformTypeIdentifiers
import AVFoundation

private let kSchemePrefix = "ShareMedia"
private let kUserDefaultsKey = "ShareKey"
private let kUserDefaultsMessageKey = "ShareMessageKey"
private let kAppGroupIdKey = "AppGroupId"

public enum SharedMediaType: String, Codable, CaseIterable {
    case image
    case video
    case text
    case file
    case url

    public var toUTTypeIdentifier: String {
        switch self {
        case .image:
            return UTType.image.identifier
        case .video:
            return UTType.movie.identifier
        case .text:
            return UTType.text.identifier
        case .file:
            return UTType.fileURL.identifier
        case .url:
            return UTType.url.identifier
        }
    }
}

public class SharedMediaFile: Codable {
    var path: String
    var mimeType: String?
    var thumbnail: String?
    var duration: Double?
    var message: String?
    var type: SharedMediaType

    public init(
        path: String,
        mimeType: String? = nil,
        thumbnail: String? = nil,
        duration: Double? = nil,
        message: String? = nil,
        type: SharedMediaType
    ) {
        self.path = path
        self.mimeType = mimeType
        self.thumbnail = thumbnail
        self.duration = duration
        self.message = message
        self.type = type
    }
}

class ShareViewController: SLComposeServiceViewController {
    var hostAppBundleIdentifier = ""
    var appGroupId = ""
    var sharedMedia: [SharedMediaFile] = []

    func shouldAutoRedirect() -> Bool {
        return true
    }

    override func presentationAnimationDidFinish() {
        super.presentationAnimationDidFinish()
        navigationController?.navigationBar.topItem?.rightBarButtonItem?.title = "发送"
    }

    override func isContentValid() -> Bool {
        return true
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        loadIds()
    }

    override func didSelectPost() {
        saveAndRedirect(message: contentText)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if let content = extensionContext!.inputItems[0] as? NSExtensionItem {
            if let contents = content.attachments {
                for (index, attachment) in contents.enumerated() {
                    for type in SharedMediaType.allCases {
                        if attachment.hasItemConformingToTypeIdentifier(type.toUTTypeIdentifier) {
                            attachment.loadItem(forTypeIdentifier: type.toUTTypeIdentifier) { [weak self] data, error in
                                guard let this = self, error == nil else {
                                    self?.dismissWithError()
                                    return
                                }
                                switch type {
                                case .text:
                                    if let text = data as? String {
                                        this.handleMedia(forLiteral: text, type: type, index: index, content: content)
                                    }
                                case .url:
                                    if let url = data as? URL {
                                        this.handleMedia(forLiteral: url.absoluteString, type: type, index: index, content: content)
                                    }
                                default:
                                    if let url = data as? URL {
                                        this.handleMedia(forFile: url, type: type, index: index, content: content)
                                    } else if let image = data as? UIImage {
                                        this.handleMedia(forUIImage: image, type: type, index: index, content: content)
                                    }
                                }
                            }
                            break
                        }
                    }
                }
            }
        }
    }

    override func configurationItems() -> [Any]! {
        return []
    }

    private func loadIds() {
        let shareExtensionAppBundleIdentifier = Bundle.main.bundleIdentifier ?? ""
        if let lastIndexOfPoint = shareExtensionAppBundleIdentifier.lastIndex(of: ".") {
            hostAppBundleIdentifier = String(shareExtensionAppBundleIdentifier[..<lastIndexOfPoint])
        } else {
            hostAppBundleIdentifier = shareExtensionAppBundleIdentifier
        }
        let defaultAppGroupId = "group.\(hostAppBundleIdentifier)"
        let customAppGroupId = Bundle.main.object(forInfoDictionaryKey: kAppGroupIdKey) as? String
        appGroupId = customAppGroupId ?? defaultAppGroupId
    }

    private func handleMedia(forLiteral item: String, type: SharedMediaType, index: Int, content: NSExtensionItem) {
        sharedMedia.append(SharedMediaFile(
            path: item,
            mimeType: type == .text ? "text/plain" : nil,
            type: type
        ))
        if index == (content.attachments?.count ?? 0) - 1 {
            if shouldAutoRedirect() {
                saveAndRedirect()
            }
        }
    }

    private func handleMedia(forUIImage image: UIImage, type: SharedMediaType, index: Int, content: NSExtensionItem) {
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            let tempPath = containerURL.appendingPathComponent("TempImage.png")
            if writeTempFile(image, to: tempPath) {
                let newPathDecoded = tempPath.absoluteString.removingPercentEncoding ?? tempPath.absoluteString
                sharedMedia.append(SharedMediaFile(
                    path: newPathDecoded,
                    mimeType: type == .image ? "image/png" : nil,
                    type: type
                ))
            }
        }
        if index == (content.attachments?.count ?? 0) - 1 {
            if shouldAutoRedirect() {
                saveAndRedirect()
            }
        }
    }

    private func handleMedia(forFile url: URL, type: SharedMediaType, index: Int, content: NSExtensionItem) {
        let fileName = getFileName(from: url, type: type)
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            let newPath = containerURL.appendingPathComponent(fileName)
            if copyFile(at: url, to: newPath) {
                let newPathDecoded = newPath.absoluteString.removingPercentEncoding ?? newPath.absoluteString
                if type == .video {
                    if let videoInfo = getVideoInfo(from: url) {
                        sharedMedia.append(SharedMediaFile(
                            path: newPathDecoded,
                            mimeType: url.mimeType(),
                            thumbnail: videoInfo.thumbnail?.removingPercentEncoding,
                            duration: videoInfo.duration,
                            type: type
                        ))
                    }
                } else {
                    sharedMedia.append(SharedMediaFile(
                        path: newPathDecoded,
                        mimeType: url.mimeType(),
                        type: type
                    ))
                }
            }
        }
        if index == (content.attachments?.count ?? 0) - 1 {
            if shouldAutoRedirect() {
                saveAndRedirect()
            }
        }
    }

    private func saveAndRedirect(message: String? = nil) {
        let userDefaults = UserDefaults(suiteName: appGroupId)
        userDefaults?.set(toData(data: sharedMedia), forKey: kUserDefaultsKey)
        userDefaults?.set(message, forKey: kUserDefaultsMessageKey)
        userDefaults?.synchronize()
        redirectToHostApp()
    }

    private func redirectToHostApp() {
        loadIds()
        let url = URL(string: "\(kSchemePrefix)-\(hostAppBundleIdentifier):share")
        var responder: UIResponder? = self

        if #available(iOS 18.0, *) {
            while responder != nil {
                if let application = responder as? UIApplication {
                    application.open(url!, options: [:], completionHandler: nil)
                    break
                }
                responder = responder?.next
            }
        } else {
            let selectorOpenURL = sel_registerName("openURL:")
            while responder != nil {
                if responder!.responds(to: selectorOpenURL) {
                    _ = responder!.perform(selectorOpenURL, with: url)
                    break
                }
                responder = responder!.next
            }
        }

        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func dismissWithError() {
        let alert = UIAlertController(title: "Error", message: "Error loading data", preferredStyle: .alert)
        let action = UIAlertAction(title: "Error", style: .cancel) { [weak self] _ in
            self?.dismiss(animated: true, completion: nil)
        }
        alert.addAction(action)
        present(alert, animated: true, completion: nil)
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func getFileName(from url: URL, type: SharedMediaType) -> String {
        var name = url.lastPathComponent
        if name.isEmpty {
            switch type {
            case .image:
                name = UUID().uuidString + ".png"
            case .video:
                name = UUID().uuidString + ".mp4"
            case .text:
                name = UUID().uuidString + ".txt"
            default:
                name = UUID().uuidString
            }
        }
        return name
    }

    private func writeTempFile(_ image: UIImage, to dstURL: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: dstURL.path) {
                try FileManager.default.removeItem(at: dstURL)
            }
            let pngData = image.pngData()
            try pngData?.write(to: dstURL)
            return true
        } catch {
            return false
        }
    }

    private func copyFile(at srcURL: URL, to dstURL: URL) -> Bool {
        do {
            if FileManager.default.fileExists(atPath: dstURL.path) {
                try FileManager.default.removeItem(at: dstURL)
            }
            try FileManager.default.copyItem(at: srcURL, to: dstURL)
            return true
        } catch {
            return false
        }
    }

    private func getVideoInfo(from url: URL) -> (thumbnail: String?, duration: Double)? {
        let asset = AVAsset(url: url)
        let duration = (CMTimeGetSeconds(asset.duration) * 1000).rounded()
        let thumbnailPath = getThumbnailPath(for: url)

        if FileManager.default.fileExists(atPath: thumbnailPath.path) {
            return (thumbnail: thumbnailPath.absoluteString, duration: duration)
        }

        var saved = false
        let assetImgGenerate = AVAssetImageGenerator(asset: asset)
        assetImgGenerate.appliesPreferredTrackTransform = true
        assetImgGenerate.maximumSize = CGSize(width: 360, height: 360)
        do {
            let img = try assetImgGenerate.copyCGImage(at: CMTimeMakeWithSeconds(600, preferredTimescale: 1), actualTime: nil)
            try UIImage(cgImage: img).pngData()?.write(to: thumbnailPath)
            saved = true
        } catch {
            saved = false
        }

        return saved ? (thumbnail: thumbnailPath.absoluteString, duration: duration) : nil
    }

    private func getThumbnailPath(for url: URL) -> URL {
        let fileName = Data(url.lastPathComponent.utf8).base64EncodedString().replacingOccurrences(of: "==", with: "")
        let path = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupId)!
            .appendingPathComponent("\(fileName).jpg")
        return path
    }

    private func toData(data: [SharedMediaFile]) -> Data {
        let encodedData = (try? JSONEncoder().encode(data)) ?? Data()
        return encodedData
    }
}

private extension URL {
    func mimeType() -> String {
        if let mimeType = UTType(filenameExtension: self.pathExtension)?.preferredMIMEType {
            return mimeType
        }
        return "application/octet-stream"
    }
}
