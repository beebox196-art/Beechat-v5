import Foundation

/// Errors thrown during project scaffolding.
public enum ProjectScaffoldError: LocalizedError {
    case invalidName(String)
    case alreadyExists(String)
    case templateNotFound(String)
    case copyFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let msg):
            return msg
        case .alreadyExists(let msg):
            return msg
        case .templateNotFound(let msg):
            return msg
        case .copyFailed(let msg):
            return msg
        }
    }
}

/// Scaffold a new project directory from the _template directory.
public enum ProjectScaffolder {

    private static let allowedCharacters = CharacterSet.alphanumerics
        .union(CharacterSet(charactersIn: " -"))

    /// Sanitize a project name: alphanumeric, spaces, and hyphens only.
    public static func sanitizeName(_ name: String) -> String {
        let filtered = name.unicodeScalars.filter { allowedCharacters.contains($0) }
        return String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespaces)
    }

    /// Create a new project directory by copying the template and replacing placeholders.
    /// - Parameters:
    ///   - name: The desired project name (will be sanitized)
    ///   - templatePath: Path to the template directory (default: `/Users/openclaw/Projects/_template/`)
    ///   - basePath: Path where the new project will be created (default: `/Users/openclaw/Projects/`)
    /// - Returns: The full path to the newly created project directory
    /// - Throws: ProjectScaffoldError if validation or copy fails
    public static func scaffoldProject(
        named name: String,
        from templatePath: String = "/Users/openclaw/Projects/_template/",
        at basePath: String = "/Users/openclaw/Projects/"
    ) throws -> String {
        let sanitized = sanitizeName(name)
        guard !sanitized.isEmpty else {
            throw ProjectScaffoldError.invalidName("Project name must contain at least one alphanumeric character.")
        }

        let projectDir = (basePath as NSString).appendingPathComponent(sanitized) + "/"

        guard !FileManager.default.fileExists(atPath: projectDir) else {
            throw ProjectScaffoldError.alreadyExists(
                "A project named '\(sanitized)' already exists. Choose a different name or select it from the list."
            )
        }

        guard FileManager.default.fileExists(atPath: templatePath) else {
            throw ProjectScaffoldError.templateNotFound("Template directory not found at \(templatePath)")
        }

        // Copy template directory recursively, filtering out .DS_Store
        try copyDirectory(from: templatePath, to: projectDir)

        // Replace placeholders in STATUS.md and README.md
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let today = dateFormatter.string(from: Date())
        try replacePlaceholders(in: projectDir, projectName: sanitized, date: today)

        return projectDir
    }

    /// Recursively copy a directory, skipping .DS_Store files.
    private static func copyDirectory(from source: String, to dest: String) throws {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dest, withIntermediateDirectories: true, attributes: nil)

        let items = try fm.contentsOfDirectory(atPath: source)
        for item in items {
            if item == ".DS_Store" { continue }
            let srcPath = (source as NSString).appendingPathComponent(item)
            let dstPath = (dest as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: srcPath, isDirectory: &isDir)
            if isDir.boolValue {
                try copyDirectory(from: srcPath, to: dstPath)
            } else {
                try fm.copyItem(atPath: srcPath, toPath: dstPath)
            }
        }
    }

    /// Replace `[Project Name]` and `YYYY-MM-DD` placeholders in text files.
    private static func replacePlaceholders(in projectDir: String, projectName: String, date: String) throws {
        let fm = FileManager.default
        let filesToProcess = [
            (projectDir as NSString).appendingPathComponent("STATUS.md"),
            (projectDir as NSString).appendingPathComponent("README.md"),
        ]

        for filePath in filesToProcess {
            guard fm.fileExists(atPath: filePath) else { continue }
            guard let data = fm.contents(atPath: filePath),
                  var content = String(data: data, encoding: .utf8) else { continue }

            content = content.replacingOccurrences(of: "[Project Name]", with: projectName)
            content = content.replacingOccurrences(of: "YYYY-MM-DD", with: date)

            try content.write(toFile: filePath, atomically: true, encoding: .utf8)
        }
    }
}
