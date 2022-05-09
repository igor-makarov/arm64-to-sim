import Foundation
import MachO

// support checking for Mach-O `cmd` and `cmdsize` properties
extension Data {
    var loadCommand: UInt32 {
        let lc: load_command = withUnsafeBytes { $0.load(as: load_command.self) }
        return lc.cmd
    }

    var commandSize: Int {
        let lc: load_command = withUnsafeBytes { $0.load(as: load_command.self) }
        return Int(lc.cmdsize)
    }

    func asStruct<T>(fromByteOffset offset: Int = 0) -> T {
        return withUnsafeBytes { $0.load(fromByteOffset: offset, as: T.self) }
    }
}

extension Array where Element == Data {
    func merge() -> Data {
        return reduce(into: Data()) { $0.append($1) }
    }
}

// support peeking at Data contents
extension FileHandle {
    func peek(upToCount count: Int) throws -> Data? {
        // persist the current offset, since `upToCount` doesn't guarantee all bytes will be read
        let originalOffset = offsetInFile
        let data = try read(upToCount: count)
        try seek(toOffset: originalOffset)
        return data
    }
}

public enum Fixer {
    private static func readBinary(atPath path: String) -> (Data, [Data], Data) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            fatalError("Cannot open a handle for the file at \(path). Aborting.")
        }

        // chop up the file into a relevant number of segments
        let headerData = try! handle.read(upToCount: MemoryLayout<mach_header_64>.stride)!

        let header: mach_header_64 = headerData.asStruct()
        if header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64 {
            fatalError("The file is not a correct arm64 binary. Try thinning (via lipo) or unarchiving (via ar) first.")
        }

        let loadCommandsData: [Data] = (0..<header.ncmds).map { _ in
            let loadCommandPeekData = try! handle.peek(upToCount: MemoryLayout<load_command>.stride)
            return try! handle.read(upToCount: Int(loadCommandPeekData!.commandSize))!
        }

        let programData = try! handle.readToEnd()!

        try! handle.close()

        return (headerData, loadCommandsData, programData)
    }

    private static func updateSegment64(_ data: Data, _ offset: UInt32) -> Data {
        // decode both the segment_command_64 and the subsequent section_64s
        var segment: segment_command_64 = data.asStruct()

        let sections: [section_64] = (0..<Int(segment.nsects)).map { index in
            let offset = MemoryLayout<segment_command_64>.stride + index * MemoryLayout<section_64>.stride
            return data.asStruct(fromByteOffset: offset)
        }

        // shift segment information by the offset
        segment.fileoff += UInt64(offset)
        segment.filesize += UInt64(offset)
        segment.vmsize += UInt64(offset)

        let offsetSections = sections.map { section -> section_64 in
            var section = section
            let sectionType = section.flags & UInt32(SECTION_TYPE)
            switch Int32(sectionType) {
            case S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL:
                section.offset = 0
            case _:
                section.offset += UInt32(offset)
                section.reloff += section.reloff > 0 ? UInt32(offset) : 0
                break
            }
            return section
        }

        var datas = [Data]()
        datas.append(Data(bytes: &segment, count: MemoryLayout<segment_command_64>.stride))
        datas.append(contentsOf: offsetSections.map { section in
            var section = section
            return Data(bytes: &section, count: MemoryLayout<section_64>.stride)
        })

        return datas.merge()
    }

    static func updateZeroFillOffset(lc: Data) -> Data {
        // `offset` is kind of a magic number here, since we know that's the only meaningful change to binary size
        // having a dynamic `offset` requires two passes over the load commands and is left as an exercise to the reader
        let cmd = Int32(bitPattern: lc.loadCommand)
        switch cmd {
        case LC_SEGMENT_64:
            return updateSegment64(lc, 0)
        default:
            return lc
        }
    }

    public static func processBinary(atPath path: String) {
        let (headerData, loadCommandsData, programData) = readBinary(atPath: path)

        let editedCommandsData = loadCommandsData
            .map { updateZeroFillOffset(lc: $0) }
            .merge()

        var header: mach_header_64 = headerData.asStruct()
        header.sizeofcmds = UInt32(editedCommandsData.count)

        // reassemble the binary
        let reworkedData = [
            Data(bytes: &header, count: MemoryLayout<mach_header_64>.stride),
            editedCommandsData,
            programData
        ].merge()

        // save back to disk
        if ProcessInfo.processInfo.environment["NOT_INPLACE"] != nil {
            try! reworkedData.write(to: URL(fileURLWithPath: path+".out"))
        } else {
            try! reworkedData.write(to: URL(fileURLWithPath: path))
        }
    }
}

guard CommandLine.arguments.count > 1 else {
    fatalError("Please add a path to command!")
}

let binaryPath = CommandLine.arguments[1]

Fixer.processBinary(atPath: binaryPath)
