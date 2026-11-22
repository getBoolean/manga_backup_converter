package mangabackup.tachi.host

/** Desktop [PackageScope.StackResolver]: a JVM StackWalker over frame classes, matched by their [PackageOwned] loader. */
object DesktopPackageScope : PackageScope.StackResolver {
    private val walker: StackWalker = StackWalker.getInstance(StackWalker.Option.RETAIN_CLASS_REFERENCE)

    fun install() {
        if (PackageScope.stackResolver == null) PackageScope.stackResolver = this
    }

    override fun fromStack(): PackageEnvironment? = walker.walk { frames ->
        frames.map { (it.declaringClass.classLoader as? PackageOwned)?.environment }
            .filter { it != null }
            .findFirst()
            .orElse(null)
    }
}
