import AppKit
import ColorSync

struct ColorProfile: Hashable {
    let url: URL
    let name: String
}

/// ICC profile assignment per display through the public ColorSync device API.
enum ColorProfiles {
    private static var cache: [ColorProfile]?

    /// Installed display ('mntr') profiles. Scanning the disk is slow, so the result is cached.
    static func installed(reload: Bool = false) -> [ColorProfile] {
        if let cache, !reload { return cache }
        final class Collector {
            var profiles: [ColorProfile] = []
        }
        let collector = Collector()
        var seed: UInt32 = 0
        ColorSyncIterateInstalledProfiles({ info, context in
            guard let info = info as? [String: Any], let context else { return true }
            let collector = Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue()
            guard (info[kColorSyncProfileClass.takeUnretainedValue() as String] as? String) == (kColorSyncSigDisplayClass.takeUnretainedValue() as String),
                  (info[kColorSyncProfileColorSpace.takeUnretainedValue() as String] as? String) == (kColorSyncSigRgbData.takeUnretainedValue() as String),
                  let url = info[kColorSyncProfileURL.takeUnretainedValue() as String] as? URL
            else { return true }
            let name = info[kColorSyncProfileDescription.takeUnretainedValue() as String] as? String ?? url.deletingPathExtension().lastPathComponent
            collector.profiles.append(ColorProfile(url: url, name: name))
            return true
        }, &seed, Unmanaged.passUnretained(collector).toOpaque(), nil)

        var seen = Set<String>()
        let profiles = collector.profiles
            .filter { seen.insert($0.url.path).inserted }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cache = profiles
        return profiles
    }

    private static func deviceInfo(for display: Display) -> (uuid: CFUUID, info: [String: Any])? {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(display.id)?.takeRetainedValue(),
              let info = ColorSyncDeviceCopyDeviceInfo(kColorSyncDisplayDeviceClass.takeUnretainedValue(), uuid)?
                  .takeRetainedValue() as? [String: Any]
        else { return nil }
        return (uuid, info)
    }

    private static func defaultProfileID(_ info: [String: Any]) -> String? {
        let factory = info[kColorSyncFactoryProfiles.takeUnretainedValue() as String] as? [String: Any]
        return factory?[kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String] as? String
    }

    static func currentProfileURL(for display: Display) -> URL? {
        guard let info = deviceInfo(for: display)?.info else { return nil }
        let profileID = defaultProfileID(info)
        if let custom = info[kColorSyncCustomProfiles.takeUnretainedValue() as String] as? [String: Any] {
            if let profileID, let url = custom[profileID] as? URL { return url }
            if let url = custom.values.compactMap({ $0 as? URL }).first { return url }
        }
        let factory = info[kColorSyncFactoryProfiles.takeUnretainedValue() as String] as? [String: Any]
        if let profileID, let entry = factory?[profileID] as? [String: Any] {
            return entry[kColorSyncDeviceProfileURL.takeUnretainedValue() as String] as? URL
        }
        return nil
    }

    static func factoryProfileURL(for display: Display) -> URL? {
        guard let info = deviceInfo(for: display)?.info, let profileID = defaultProfileID(info) else { return nil }
        let factory = info[kColorSyncFactoryProfiles.takeUnretainedValue() as String] as? [String: Any]
        return (factory?[profileID] as? [String: Any])?[kColorSyncDeviceProfileURL.takeUnretainedValue() as String] as? URL
    }

    /// Pass nil to return to the factory profile.
    @discardableResult
    static func setProfile(_ url: URL?, for display: Display) -> Bool {
        guard let device = deviceInfo(for: display) else { return false }
        let value: Any = url.map { $0 as NSURL } ?? kCFNull as Any
        var profiles: [String: Any] = [kColorSyncDeviceDefaultProfileID.takeUnretainedValue() as String: value]
        if let profileID = defaultProfileID(device.info) { profiles[profileID] = value }
        let ok = ColorSyncDeviceSetCustomProfiles(kColorSyncDisplayDeviceClass.takeUnretainedValue(), device.uuid, profiles as CFDictionary)
        if ok {
            // The system rebuilds the gamma tables for the new profile; recompose our adjustments on top.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { GammaController.shared.reloadAll() }
        }
        return ok
    }
}
