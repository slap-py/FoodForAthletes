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

enum ProfilePhotoStore {
    static func image(at path: String) -> UIImage? {
        guard !path.isEmpty else { return nil }
        return UIImage(contentsOfFile: path)
    }

    static func save(_ image: UIImage, replacing oldPath: String) throws -> String {
        guard let data = image.jpegData(compressionQuality: 0.86) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let directory = try profileDirectory()
        let url = directory.appendingPathComponent("profile-\(UUID().uuidString).jpg")
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        remove(oldPath)
        return url.path
    }

    static func remove(_ path: String) {
        guard !path.isEmpty else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func profileDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let directory = base.appendingPathComponent("Profile", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
