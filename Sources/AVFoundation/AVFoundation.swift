// On Linux, `import AVFoundation` resolves to this module, so sources
// written against Apple's compile unchanged: a subset of it, for playing
// media, on the rest of this package. Like Apple's, it brings Foundation and
// CoreMedia in too. This target exists only on Linux; see the manifest.

@_exported import Foundation
@_exported import CoreMedia
