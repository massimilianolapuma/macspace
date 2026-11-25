/// The context and flags a scan's root inherits from the folders above it.
public enum RootContext {
    /// Walks `rootPath` from `/`, threading the classifier's directory context through each component.
    /// `.insidePackage` is set when an ancestor of the root is a package, `.package` when the root is.
    public static func resolve(rootPath: String, classifier: CategoryClassifier)
        -> (context: FileCategory?, flags: NodeFlags) {
        var context: FileCategory?
        var insidePackage = false
        var isPackage = false
        var current = ""
        for component in rootPath.split(separator: "/", omittingEmptySubsequences: true) {
            if isPackage { insidePackage = true }
            let name = String(component)
            current += "/" + name
            context = classifier.context(forDirectory: name, path: current, parent: context)
            isPackage = classifier.isPackage(directoryName: name)
        }
        var flags: NodeFlags = []
        if insidePackage { flags.insert(.insidePackage) }
        if isPackage { flags.insert(.package) }
        return (context, flags)
    }
}
