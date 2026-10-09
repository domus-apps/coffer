import Foundation

/* UI strings pass through here: the English source text is the key, so a
   missing translation (or a language Coffer doesn't ship) falls back to
   English by construction. Translations live in
   Resources/<lang>.lproj/Localizable.strings inside the SPM resource
   bundle, which follows the user's system language. */

/* Resolved by hand instead of `Bundle.module`: the accessor SwiftPM
   generates for executable targets varies by toolchain, and the classic
   build system's version checks only the .app root and the build
   machine's absolute path — never Contents/Resources, where bundle.sh
   puts the bundle — then traps. (Keystone 1.5.0 crashed at launch on
   exactly that.) Checking Resources first also spares `Bundle.module`'s own trap
   from ever being reachable in a bundled app. */
private let localizationBundle: Bundle = {
    let resources: Bundle
    if let url = Bundle.main.resourceURL?
        .appendingPathComponent("Coffer_Coffer.bundle"),
        let bundle = Bundle(url: url)
    {
        resources = bundle
    } else {
        /* `swift run` and Xcode builds: the generated accessor knows the
           build-directory layout for the toolchain that made the binary. */
        resources = .module
    }
    /* Development aid: `--language ko` forces one localization. A bare
       `swift run` binary has no bundle identifier, so neither the
       -AppleLanguages argument nor a per-app language setting reaches
       it; pointing straight at the .lproj does. */
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--language"), index + 1 < arguments.count,
        let url = resources.url(forResource: arguments[index + 1], withExtension: "lproj"),
        let forced = Bundle(url: url)
    {
        return forced
    }
    return resources
}()

func L(_ key: String) -> String {
    NSLocalizedString(key, bundle: localizationBundle, comment: "")
}

func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: L(key), arguments: arguments)
}
