import Darwin

// Compare the same port before and after sampling; warm up one-time OS initialization first.
let observedHost = mach_host_self()
func referenceCount() -> mach_port_urefs_t {
    var refs: mach_port_urefs_t = 0
    precondition(mach_port_get_refs(mach_task_self_, observedHost,
                                    mach_port_right_t(MACH_PORT_RIGHT_SEND), &refs) == KERN_SUCCESS)
    return refs
}

func sample() {
    precondition(cpuTicks() != nil)
    precondition(memoryUsed() != nil)
}

sample()
let before = referenceCount()
for _ in 0..<1000 { sample() }
let after = referenceCount()
print("Host references before and after 1,000 paired samples:", before, after)
precondition(before == after)
mach_port_deallocate(mach_task_self_, observedHost)
