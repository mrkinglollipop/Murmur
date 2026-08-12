import Darwin
import Foundation
import ObjectiveC
import UIKit

/// Walks XPC / view-service ivars for a host PID or bundle ID.
/// ChatKit classes are not visible in the keyboard process; `_hostPID` is.
enum HostIvarScanner {
    struct Hit {
        var bundleIDs: [String] = []
        var pids: [pid_t] = []
        var inventory: [String] = []
    }

    static func scan(_ objects: [NSObject]) -> Hit {
        var hit = Hit()
        var seen = Set<ObjectIdentifier>()
        for object in objects {
            scan(object, depth: 0, into: &hit, seen: &seen)
        }
        var uniquePIDs = Set<pid_t>()
        hit.pids = hit.pids.filter { uniquePIDs.insert($0).inserted }
        var uniqueIDs = Set<String>()
        hit.bundleIDs = hit.bundleIDs.filter { uniqueIDs.insert($0).inserted }
        return hit
    }

    private static func scan(
        _ object: NSObject,
        depth: Int,
        into hit: inout Hit,
        seen: inout Set<ObjectIdentifier>
    ) {
        let identity = ObjectIdentifier(object)
        guard seen.insert(identity).inserted else { return }
        let typeName = NSStringFromClass(type(of: object))
        var cls: AnyClass? = object_getClass(object)
        while let current = cls {
            if current == UIViewController.self || current == UIView.self || current == NSObject.self {
                break
            }
            var count: UInt32 = 0
            if let ivars = class_copyIvarList(current, &count) {
                defer { free(ivars) }
                for i in 0..<Int(count) {
                    inspect(ivars[i], object: object, typeName: typeName, depth: depth, into: &hit, seen: &seen)
                }
            }
            cls = class_getSuperclass(current)
        }
        if let connection = object as? NSXPCConnection {
            append(pid: connection.processIdentifier, into: &hit)
            hit.inventory.append("\(typeName).processIdentifier=\(connection.processIdentifier)")
        }
    }

    private static func inspect(
        _ ivar: Ivar,
        object: NSObject,
        typeName: String,
        depth: Int,
        into hit: inout Hit,
        seen: inout Set<ObjectIdentifier>
    ) {
        guard let nameC = ivar_getName(ivar), let encodingC = ivar_getTypeEncoding(ivar) else { return }
        let name = String(cString: nameC)
        let encoding = String(cString: encodingC)
        let lowered = name.lowercased()
        if encoding.hasPrefix("@") {
            guard let value = object_getIvar(object, ivar) else {
                hit.inventory.append("\(typeName).\(name)=nil")
                return
            }
            if let string = value as? String {
                hit.inventory.append("\(typeName).\(name)=str:\(string.prefix(48))")
                if string.contains(".") { hit.bundleIDs.append(string) }
                return
            }
            if let number = value as? NSNumber {
                hit.inventory.append("\(typeName).\(name)=num:\(number)")
                if lowered.contains("pid") || lowered.contains("processid") {
                    append(pid: pid_t(truncatingIfNeeded: number.int64Value), into: &hit)
                }
                return
            }
            if let connection = value as? NSXPCConnection {
                append(pid: connection.processIdentifier, into: &hit)
                hit.inventory.append("\(typeName).\(name)=xpc:\(connection.processIdentifier)")
                return
            }
            let nestedName = NSStringFromClass(type(of: value as AnyObject))
            hit.inventory.append("\(typeName).\(name)=\(nestedName)")
            guard depth < 1, let nested = value as? NSObject else { return }
            if shouldRecurse(nestedName) {
                scan(nested, depth: depth + 1, into: &hit, seen: &seen)
            }
            return
        }
        if looksLikePIDName(lowered), let number = integer(ivar, from: object, encoding: encoding) {
            hit.inventory.append("\(typeName).\(name)=\(number)")
            append(pid: pid_t(truncatingIfNeeded: number), into: &hit)
        }
    }

    private static func looksLikePIDName(_ lowered: String) -> Bool {
        lowered.contains("pid") || lowered.contains("processid") || lowered.contains("processidentifier")
    }

    private static func shouldRecurse(_ className: String) -> Bool {
        if className.hasPrefix("UI") { return false }
        if className.hasPrefix("__NS") || className.hasPrefix("NS") && !className.contains("XPC") { return false }
        if className.contains("XPC") { return true }
        if className.contains("RTI") { return true }
        if className.contains("Operator") { return true }
        if className.contains("Interface") { return true }
        if className.contains("Connection") { return true }
        if className.contains("Host") { return true }
        return false
    }

    private static func integer(_ ivar: Ivar, from object: NSObject, encoding: String) -> Int64? {
        let offset = ivar_getOffset(ivar)
        let pointer = Unmanaged.passUnretained(object).toOpaque().advanced(by: offset)
        switch encoding {
        case "i", "I":
            return Int64(pointer.loadUnaligned(as: Int32.self))
        case "s", "S":
            return Int64(pointer.loadUnaligned(as: Int16.self))
        case "q", "Q", "l", "L":
            return pointer.loadUnaligned(as: Int64.self)
        default:
            return nil
        }
    }

    private static func append(pid: pid_t, into hit: inout Hit) {
        if pid > 1, pid < 1_000_000 { hit.pids.append(pid) }
    }
}
