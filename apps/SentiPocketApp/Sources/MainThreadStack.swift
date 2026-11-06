import Darwin
import Foundation
import MachO

/// The main thread's stack, read from another thread while the main thread is stopped for an instant: its registers,
/// then its chain of frame records. A freeze that the system ends leaves no stack of its own (11-04, build 2026110308:
/// the main thread stuck after a room closed, with nothing to say where), so the freeze watch reads one while it lasts.
///
/// Nothing that allocates or takes a lock runs while the main thread is stopped (it may be holding the allocator's or
/// the loader's lock): the return addresses go into a buffer made beforehand, and are named only once it runs again,
/// as "binary +0xoffset" with each binary's UUID, the way iOS's own crash records give them.
enum MainThreadStack {
    static let maximumFrames = 64

    /// The main thread's Mach port, taken on the main thread before any stack is read (the freeze watch's start).
    private static var mainThread: thread_t = 0

    /// Remembers the main thread; on the main thread only, once.
    static func rememberMainThread() {
        guard pthread_main_np() != 0, mainThread == 0 else { return }
        mainThread = mach_thread_self()
    }

    /// The main thread's stack, innermost first; empty when it can't be read (not arm64, called on the main thread, or
    /// before `rememberMainThread`).
    static func capture() -> (frames: [String], binaries: [String]) {
        #if arch(arm64)
        guard pthread_main_np() == 0 else { return ([], []) }
        let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: maximumFrames)
        defer { buffer.deallocate() }
        let count = read(into: buffer)
        return named(Array(UnsafeBufferPointer(start: buffer, count: count)))
        #else
        return ([], [])
        #endif
    }

    #if arch(arm64)
    /// Writes the main thread's return addresses, innermost first, into `buffer`, and says how many.
    private static func read(into buffer: UnsafeMutablePointer<UInt>) -> Int {
        let thread = mainThread
        guard thread != 0 else { return 0 }
        // Everything the stopped window touches is made here, before the thread stops, and reached through raw
        // pointers: no allocation, generic code or type lookup runs while it is stopped (a debug build would otherwise
        // run the generic `withUnsafeMutablePointer` forms there).
        let stateWords = MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<natural_t>.size
        let state = UnsafeMutablePointer<arm_thread_state64_t>.allocate(capacity: 1)
        let stateRaw = UnsafeMutableRawPointer(state).bindMemory(to: natural_t.self, capacity: stateWords)
        let record = UnsafeMutablePointer<UInt>.allocate(capacity: 2)
        let recordAddress = vm_address_t(UInt(bitPattern: record))
        let recordSize = vm_size_t(2 * MemoryLayout<UInt>.size)
        defer {
            state.deallocate()
            record.deallocate()
        }
        var stateCount = mach_msg_type_number_t(stateWords)
        var copiedSize: vm_size_t = 0
        var count = 0

        guard thread_suspend(thread) == KERN_SUCCESS else { return 0 }
        if thread_get_state(thread, ARM_THREAD_STATE64, stateRaw, &stateCount) == KERN_SUCCESS {
            buffer[count] = strip(state.pointee.__pc)
            count += 1
            buffer[count] = strip(state.pointee.__lr)
            count += 1
            // Each frame record is two words at the frame pointer: the caller's frame pointer, then the return address.
            var frame = strip(state.pointee.__fp)
            while count < maximumFrames, frame != 0, frame % 8 == 0 {
                guard vm_read_overwrite(mach_task_self_, vm_address_t(frame), recordSize, recordAddress, &copiedSize)
                        == KERN_SUCCESS else { break }
                let returnAddress = strip(UInt64(record[1]))
                guard returnAddress != 0 else { break }
                buffer[count] = returnAddress
                count += 1
                let caller = strip(UInt64(record[0]))
                // Frames grow toward higher addresses as they unwind; anything else is the end of the chain (or garbage).
                guard caller > frame else { break }
                frame = caller
            }
        }
        thread_resume(thread)
        return count
    }

    /// An address without its pointer-authentication bits: the system's frameworks sign their return addresses.
    private static func strip(_ value: UInt64) -> UInt {
        UInt(value & 0x0000_000F_FFFF_FFFF)
    }
    #endif

    /// "binary +0xoffset" for each address, and each binary once with its UUID, to find its symbols.
    static func named(_ addresses: [UInt]) -> (frames: [String], binaries: [String]) {
        var frames: [String] = []
        var binaries: [String] = []
        for address in addresses {
            var info = Dl_info()
            guard let pointer = UnsafeRawPointer(bitPattern: address), dladdr(pointer, &info) != 0,
                  let base = info.dli_fbase, let path = info.dli_fname else {
                frames.append("? 0x" + String(address, radix: 16))
                continue
            }
            let name = (String(cString: path) as NSString).lastPathComponent
            let start = UInt(bitPattern: base)
            frames.append(address >= start ? "\(name) +0x\(String(address - start, radix: 16))" : "\(name) ? 0x\(String(address, radix: 16))")
            let binary = "\(name) \(uuid(ofImageAt: UnsafeRawPointer(base)) ?? "?")"
            if !binaries.contains(binary) { binaries.append(binary) }
        }
        return (frames, binaries)
    }

    /// The UUID in a loaded image's header (its LC_UUID load command).
    private static func uuid(ofImageAt header: UnsafeRawPointer) -> String? {
        let machHeader = header.assumingMemoryBound(to: mach_header_64.self).pointee
        guard machHeader.magic == MH_MAGIC_64 else { return nil }
        var command = header + MemoryLayout<mach_header_64>.size
        for _ in 0..<machHeader.ncmds {
            let load = command.assumingMemoryBound(to: load_command.self).pointee
            if load.cmd == UInt32(LC_UUID) {
                return UUID(uuid: command.assumingMemoryBound(to: uuid_command.self).pointee.uuid).uuidString
            }
            command += Int(load.cmdsize)
        }
        return nil
    }
}
