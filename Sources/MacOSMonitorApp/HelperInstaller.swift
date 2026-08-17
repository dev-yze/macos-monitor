import Foundation
import MonitorCore

enum HelperInstallerError: Error, Equatable {
    case authorizationDenied
    case installFailed(String)
}

/// Installs a root LaunchDaemon that runs `powermetrics` continuously and
/// writes its output to a named pipe. The app reads the pipe, so it never
/// needs administrator privileges at runtime — only once, during install.
enum HelperInstaller {
    private static let helperScriptPath = "/Library/PrivilegedHelperTools/com.zhangenyang.macosmonitor.helper.sh"
    private static let plistPath = "/Library/LaunchDaemons/com.zhangenyang.macosmonitor.helper.plist"

    private static let scriptContent = """
    #!/bin/sh
    FIFO=/tmp/macosmonitor.powermetrics.fifo
    rm -f "$FIFO"
    mkfifo "$FIFO" 2>/dev/null
    chmod 666 "$FIFO" 2>/dev/null
    exec /usr/bin/powermetrics --samplers cpu_power,gpu_power --sample-rate 2000 --sample-count -1 --buffer-size 1 > "$FIFO" 2>/dev/null
    """

    private static let plistContent = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>com.zhangenyang.macosmonitor.helper</string>
        <key>ProgramArguments</key>
        <array>
            <string>/bin/sh</string>
            <string>/Library/PrivilegedHelperTools/com.zhangenyang.macosmonitor.helper.sh</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>StandardErrorPath</key>
        <string>/var/log/macosmonitor-helper.log</string>
    </dict>
    </plist>
    """

    /// Whether the helper's named pipe currently exists (helper is running).
    static func isHelperRunning() -> Bool {
        FileManager.default.fileExists(atPath: PowermetricsStream.fifoPath)
    }

    /// Whether the LaunchDaemon plist is already installed.
    static func isInstalled() -> Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    /// Installs the LaunchDaemon, presenting the administrator password prompt
    /// once. Call off the main thread.
    static func install() throws {
        let tmpScript = "/tmp/macosmonitor-helper.sh"
        let tmpPlist = "/tmp/macosmonitor-helper.plist"
        try scriptContent.write(toFile: tmpScript, atomically: true, encoding: .utf8)
        try plistContent.write(toFile: tmpPlist, atomically: true, encoding: .utf8)

        let shell = """
        mkdir -p /Library/PrivilegedHelperTools
        cp \(tmpScript) \(helperScriptPath)
        chmod +x \(helperScriptPath)
        cp \(tmpPlist) \(plistPath)
        launchctl unload \(plistPath) 2>/dev/null || true
        launchctl load \(plistPath)
        """

        let appleScript = "do shell script \"\(shell)\" with administrator privileges"
        let result = runProcess("/usr/bin/osascript", arguments: ["-e", appleScript])
        guard result.exitCode == 0 else {
            if isUserDenied(result.stderr, result.stdout) {
                throw HelperInstallerError.authorizationDenied
            }
            throw HelperInstallerError.installFailed(firstNonEmpty(result.stderr, result.stdout) ?? "安装失败")
        }
    }

    // MARK: - Helpers

    private static func runProcess(_ executable: String, arguments: [String]) -> (stdout: String, stderr: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return ("", error.localizedDescription, -1)
        }
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            String(data: stdoutData, encoding: .utf8) ?? "",
            String(data: stderrData, encoding: .utf8) ?? "",
            process.terminationStatus
        )
    }

    private static func isUserDenied(_ stderr: String, _ stdout: String) -> Bool {
        let text = "\(stderr) \(stdout)".lowercased()
        return text.contains("user canceled") || text.contains("-128") || text.contains("not authorized")
    }

    private static func firstNonEmpty(_ values: String...) -> String? {
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
