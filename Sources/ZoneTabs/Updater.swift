import AppKit

/// GitHub 릴리스에서 새 버전을 확인하고, 받아서 지금 실행 중인 앱을 교체한 뒤 다시 실행한다.
final class Updater {
    struct Release {
        let version: String
        let dmgURL: URL
    }

    enum UpdateError: LocalizedError {
        case badResponse
        case notInstalledApp
        case notWritable

        var errorDescription: String? {
            switch self {
            case .badResponse: return "릴리스 정보를 읽지 못했습니다."
            case .notInstalledApp: return "앱 번들로 실행 중이 아니라서 교체할 수 없습니다."
            case .notWritable: return "앱이 있는 폴더에 쓸 수 없습니다."
            }
        }
    }

    private let latestURL = URL(string: "https://api.github.com/repos/Yoonsik-Shin/ZoneTabs/releases/latest")!

    /// 설치할 수 있는 새 버전. 없으면 nil.
    private(set) var available: Release?
    private(set) var busy = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// 새 버전이 있는지 확인한다. 결과는 메인 스레드에서 알려 준다.
    func check(completion: @escaping (Result<Release?, Error>) -> Void) {
        guard !busy else { return }
        busy = true
        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            let result: Result<Release?, Error>
            if let error = error {
                result = .failure(error)
            } else if let data = data, let release = Updater.parse(data) {
                let newer = Updater.isVersion(release.version, newerThan: self?.currentVersion ?? "0")
                result = .success(newer ? release : nil)
            } else {
                result = .failure(UpdateError.badResponse)
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                if case .success(let release) = result { self.available = release }
                completion(result)
            }
        }.resume()
    }

    private static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]]
        else { return nil }
        for asset in assets where (asset["name"] as? String) == "ZoneTabs.dmg" {
            if let link = asset["browser_download_url"] as? String, let url = URL(string: link) {
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                return Release(version: version, dmgURL: url)
            }
        }
        return nil
    }

    /// "0.1.10"과 "0.1.9"처럼 점으로 나뉜 숫자를 자리별로 비교한다.
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let left = a.split(separator: ".").map { Int($0) ?? 0 }
        let right = b.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// 새 버전을 받아 설치하고 앱을 다시 실행한다. 성공하면 이 앱은 종료되므로 completion은 실패했을 때만 불린다.
    func install(_ release: Release, completion: @escaping (Error) -> Void) {
        guard !busy else { return }
        busy = true
        URLSession.shared.downloadTask(with: release.dmgURL) { [weak self] location, _, error in
            var failure: Error? = error
            var dmgPath: String?
            if let location = location {
                let target = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ZoneTabs-update.dmg")
                try? FileManager.default.removeItem(at: target)
                do {
                    try FileManager.default.moveItem(at: location, to: target)
                    dmgPath = target.path
                } catch {
                    failure = error
                }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                guard let dmgPath = dmgPath else {
                    completion(failure ?? UpdateError.badResponse)
                    return
                }
                do {
                    try self.replaceAndRelaunch(dmgPath: dmgPath)
                } catch {
                    completion(error)
                }
            }
        }.resume()
    }

    private func replaceAndRelaunch(dmgPath: String) throws {
        let appPath = Bundle.main.bundlePath
        guard appPath.hasSuffix(".app") else { throw UpdateError.notInstalledApp }
        let parent = (appPath as NSString).deletingLastPathComponent
        guard FileManager.default.isWritableFile(atPath: parent) else { throw UpdateError.notWritable }

        // 이 앱이 완전히 꺼진 뒤에 교체한다. 단축키용 이벤트 탭이 살아 있는 채로 앱을 바꾸거나
        // 권한을 초기화하면 시스템 입력이 멈출 수 있기 때문이다.
        // 지금 버전과 새 버전이 모두 고정 인증서로 서명돼 있으면 손쉬운 사용 권한이 그대로 유지된다.
        // 그렇지 않으면 서명이 달라 예전 권한이 맞지 않으므로 초기화해서 다시 허용받는다.
        let script = """
        while kill -0 "$OLD_PID" 2>/dev/null; do sleep 0.2; done
        MNT="$(mktemp -d /tmp/zonetabs-update.XXXXXX)"
        if hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MNT" && [ -d "$MNT/ZoneTabs.app" ]; then
            rm -rf "$APP.new"
            if ditto "$MNT/ZoneTabs.app" "$APP.new"; then
                rm -rf "$APP"
                mv "$APP.new" "$APP"
                xattr -dr com.apple.quarantine "$APP" 2>/dev/null
                NEW_STABLE="$(/usr/libexec/PlistBuddy -c "Print :ZTStableSignature" "$APP/Contents/Info.plist" 2>/dev/null)"
                if [ "$OLD_STABLE" != "true" ] || [ "$NEW_STABLE" != "true" ]; then
                    tccutil reset Accessibility dev.zonetabs.app >/dev/null 2>&1
                fi
            fi
        fi
        hdiutil detach "$MNT" -quiet 2>/dev/null
        rmdir "$MNT" 2>/dev/null
        rm -f "$DMG"
        open "$APP"
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        var environment = ProcessInfo.processInfo.environment
        environment["OLD_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        environment["DMG"] = dmgPath
        let stable = Bundle.main.infoDictionary?["ZTStableSignature"] as? Bool ?? false
        environment["OLD_STABLE"] = stable ? "true" : "false"
        environment["APP"] = appPath
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        NSApp.terminate(nil)
    }
}
