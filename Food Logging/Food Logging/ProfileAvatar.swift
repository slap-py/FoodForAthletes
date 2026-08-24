import SwiftUI
import UIKit

struct ProfileAvatar: View {
    let name: String
    let photoPath: String
    var size: CGFloat = 48

    var body: some View {
        Group {
            if let image = ProfilePhotoStore.image(at: photoPath) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if !initials.isEmpty {
                Text(initials)
                    .font(.system(size: size * 0.32, weight: .bold))
                    .foregroundStyle(JournalTheme.moss)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(JournalTheme.mint)
            } else {
                Image(systemName: "person.fill")
                    .font(.system(size: size * 0.38, weight: .semibold))
                    .foregroundStyle(JournalTheme.moss)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(JournalTheme.mint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(JournalTheme.moss.opacity(0.18)))
        .accessibilityHidden(true)
    }

    private var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

/// Only the file name is stored. The app container path changes between installs
/// and OS upgrades, so an absolute path saved earlier stops resolving and the
/// photo silently disappears while the rest of the profile survives.
enum ProfilePhotoStore {
    static func url(for reference: String) -> URL? {
        guard !reference.isEmpty else { return nil }
        // Absolute paths written by earlier versions still resolve when the
        // container happens to be unchanged.
        guard !reference.hasPrefix("/") else { return URL(fileURLWithPath: reference) }
        return try? profileDirectory().appendingPathComponent(reference)
    }

    static func image(at reference: String) -> UIImage? {
        guard let url = url(for: reference) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    static func save(_ image: UIImage, replacing oldReference: String) throws -> String {
        guard let data = image.jpegData(compressionQuality: 0.86) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let directory = try profileDirectory()
        let name = "profile-\(UUID().uuidString).jpg"
        try data.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        remove(oldReference)
        return name
    }

    static func remove(_ reference: String) {
        guard let url = url(for: reference) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func profileDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("Profile", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
