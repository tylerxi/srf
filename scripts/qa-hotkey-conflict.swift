// External test helper, not part of the shipping application.
import Carbon
import Foundation
var current: EventHotKeyRef?
let existing = RegisterEventHotKey(38, 6400, EventHotKeyID(signature: 0x51545454, id: 1),
                                   GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &current)
var conflicting: EventHotKeyRef?
let reserved = RegisterEventHotKey(37, 6400, EventHotKeyID(signature: 0x51545454, id: 2),
                                   GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &conflicting)
print("\(existing),\(reserved)"); fflush(stdout)
_ = readLine()
if let current { UnregisterEventHotKey(current) }
if let conflicting { UnregisterEventHotKey(conflicting) }
