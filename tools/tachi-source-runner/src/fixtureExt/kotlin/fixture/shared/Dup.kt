package fixture.shared

/** Same fully qualified name in fixture-a and fixture-b: proves class-loader namespaces do not collide. */
object Dup {
    const val TAG = "a"
}

