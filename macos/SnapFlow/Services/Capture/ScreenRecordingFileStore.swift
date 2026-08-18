import Foundation

enum ScreenRecordingFileStore {
    static var directory: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SnapFlow", isDirectory: true)
    }

    /// 固定目录 `~/Movies/SnapFlow/`；按模板生成唯一文件名后移动临时文件。
    static func save(
        temporaryURL: URL,
        format: ScreenRecordingFormat,
        template: String,
        counter: Int,
        date: Date = Date()
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let fileName = RecordingFilenameTemplate.render(
            template: template,
            fileExtension: format.fileExtension,
            date: date,
            counter: counter
        )
        var candidate = directory.appendingPathComponent(fileName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let stem = candidate.deletingPathExtension().lastPathComponent
            candidate = directory.appendingPathComponent(
                "\(stem)-\(suffix).\(format.fileExtension)"
            )
            suffix += 1
        }

        if FileManager.default.fileExists(atPath: candidate.path) {
            try FileManager.default.removeItem(at: candidate)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: candidate)
        return candidate
    }

    /// 兼容旧调用：默认 MP4 与默认模板。
    static func save(_ output: ScreenRecordingOutput, date: Date = Date()) throws -> URL {
        try save(
            temporaryURL: output.url,
            format: .mp4,
            template: RecordingFilenameTemplate.defaultTemplate,
            counter: 1,
            date: date
        )
    }

    static func uniqueDestination(
        format: ScreenRecordingFormat,
        template: String,
        counter: Int,
        date: Date = Date()
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileName = RecordingFilenameTemplate.render(
            template: template,
            fileExtension: format.fileExtension,
            date: date,
            counter: counter
        )
        var candidate = directory.appendingPathComponent(fileName)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let stem = candidate.deletingPathExtension().lastPathComponent
            candidate = directory.appendingPathComponent(
                "\(stem)-\(suffix).\(format.fileExtension)"
            )
            suffix += 1
        }
        return candidate
    }
}
