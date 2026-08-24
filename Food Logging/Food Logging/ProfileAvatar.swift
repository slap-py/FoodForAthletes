import SwiftUI
import PhotosUI
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

/// Owns its own drafts, and loads the saved photo in `init` from the stored
/// reference. A sheet body is built from the presenting view's previous state,
/// so a draft handed in from outside arrives empty on the first render.
struct ProfileEditorSheet: View {
    let photoReference: String
    /// Receives the trimmed name and the framed photo, or nil to remove it.
    let onSave: (String, UIImage?) -> Void
    let onCancel: () -> Void

    @State private var nameDraft: String
    @State private var photo: UIImage?
    @State private var offset: CGSize = .zero
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var loadFailed = false

    init(name: String, photoReference: String, onSave: @escaping (String, UIImage?) -> Void, onCancel: @escaping () -> Void) {
        self.photoReference = photoReference
        self.onSave = onSave
        self.onCancel = onCancel
        _nameDraft = State(initialValue: name)
        _photo = State(initialValue: ProfilePhotoStore.image(at: photoReference))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Profile") {
                    TextField("Name", text: $nameDraft)
                    VStack(spacing: 12) {
                        if let photo {
                            ProfilePhotoCropper(image: photo, offset: $offset)
                                .id(ObjectIdentifier(photo))
                            Text("Drag the photo to choose what your avatar shows.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            ProfileAvatar(name: nameDraft, photoPath: "", size: 68)
                        }
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label(photo == nil ? "Choose photo" : "Change photo", systemImage: "photo")
                        }
                        if photo != nil {
                            Button("Remove photo", role: .destructive) { photo = nil }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .scrollContentBackground(.hidden)
            .background(JournalTheme.paper)
            .navigationTitle("Name & photo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(
                            nameDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                            photo.map { ProfilePhotoCropper.crop($0, offset: offset) }
                        )
                    }
                    .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.large])
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                defer { selectedPhoto = nil }
                guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                    loadFailed = true
                    return
                }
                offset = .zero
                photo = image
            }
        }
        .alert("That photo couldn’t be opened.", isPresented: $loadFailed) {
            Button("OK", role: .cancel) {}
        }
    }
}

/// Lets the user drag to choose which part of a photo fills the round avatar,
/// instead of always taking the centre of the image.
struct ProfilePhotoCropper: View {
    static let viewportSide: CGFloat = 190

    let image: UIImage
    @Binding var offset: CGSize
    @State private var dragStart: CGSize = .zero

    private var displayScale: CGFloat { Self.viewportSide / min(image.size.width, image.size.height) }
    private var displaySize: CGSize {
        CGSize(width: image.size.width * displayScale, height: image.size.height * displayScale)
    }
    private var limit: CGSize {
        CGSize(
            width: max(0, (displaySize.width - Self.viewportSide) / 2),
            height: max(0, (displaySize.height - Self.viewportSide) / 2)
        )
    }

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .frame(width: displaySize.width, height: displaySize.height)
            .offset(offset)
            .frame(width: Self.viewportSide, height: Self.viewportSide)
            .clipShape(Circle())
            .overlay(Circle().stroke(JournalTheme.moss.opacity(0.35), lineWidth: 2))
            .contentShape(Circle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        offset = clamped(CGSize(
                            width: dragStart.width + value.translation.width,
                            height: dragStart.height + value.translation.height
                        ))
                    }
                    .onEnded { _ in dragStart = offset }
            )
            .accessibilityLabel("Photo position")
            .accessibilityHint("Drag to choose which part of the photo fills your avatar")
    }

    private func clamped(_ value: CGSize) -> CGSize {
        CGSize(
            width: min(limit.width, max(-limit.width, value.width)),
            height: min(limit.height, max(-limit.height, value.height))
        )
    }

    /// Renders the square the viewport is showing, so the saved photo already
    /// matches what the user positioned.
    static func crop(_ image: UIImage, offset: CGSize) -> UIImage {
        let side = min(image.size.width, image.size.height)
        let scale = viewportSide / side
        let originX = (image.size.width - side) / 2 - offset.width / scale
        let originY = (image.size.height - side) / 2 - offset.height / scale
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(at: CGPoint(
                x: -min(max(0, originX), image.size.width - side),
                y: -min(max(0, originY), image.size.height - side)
            ))
        }
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
