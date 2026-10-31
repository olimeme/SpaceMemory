import Foundation

// Keep this file stable: changing it changes the app's signature, and permissions must be granted again.
let library = Bundle.main.bundleURL.deletingLastPathComponent()
    .appendingPathComponent("libSpaceMemoryCore.dylib").path
guard let handle = dlopen(library, RTLD_NOW), let symbol = dlsym(handle, "spacememory_run") else {
    fputs("Could not load \(library): \(String(cString: dlerror()))\n", stderr)
    exit(1)
}
typealias Run = @convention(c) () -> Void
unsafeBitCast(symbol, to: Run.self)()
