import Foundation
import MeterCore

// meter-statusline: Claude Code's status line command. All the logic lives in MeterCore (StatuslineHelper).
FileHandle.standardOutput.write(StatuslineHelper.run(stdin: FileHandle.standardInput.readDataToEndOfFile(),
                                                     environment: ProcessInfo.processInfo.environment))
