/*
 * Copyright (c) 2026, manga_backup_converter contributors.
 * DO NOT ALTER OR REMOVE COPYRIGHT NOTICES OR THIS FILE HEADER.
 *
 * This code is free software; you can redistribute it and/or modify it
 * under the terms of the GNU General Public License version 2 only, as
 * published by the Free Software Foundation.  The copyright holders designate
 * this particular file as subject to the "Classpath" exception as provided
 * in the LICENSE file that accompanied this code.
 *
 * This code is distributed in the hope that it will be useful, but WITHOUT
 * ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
 * FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
 * version 2 for more details (a copy is included in the LICENSE file that
 * accompanied this code).
 */

package jdk.internal.misc;

/**
 * Refuses JNI library loading from anything but the class library (U9, R18).
 *
 * On iOS the only native code the runtime may run is the code linked into
 * the app. The image bake step inserts {@link #check(Class)} at the entry of
 * {@code ClassLoader.loadLibrary(Class, String)} and
 * {@code ClassLoader.loadLibrary(Class, File)}, the funnel for
 * {@code System.load}, {@code System.loadLibrary} and their {@code Runtime}
 * forms (reflective calls included, since the caller class is the source of
 * {@code fromClass}). Library loads requested by boot or platform classes
 * (the class library's own built-in libraries) proceed; everything else,
 * extensions and host-classpath libraries alike, fails with
 * {@link UnsatisfiedLinkError} before any file is opened.
 *
 * Foreign-function library lookups ({@code java.lang.foreign}) are refused
 * separately by starting the VM with {@code --illegal-native-access=deny}.
 */
public final class SourceRunnerNativeGuard {
    private SourceRunnerNativeGuard() {}

    public static void check(Class<?> fromClass) {
        if (fromClass == null) {
            return;
        }
        ClassLoader loader = fromClass.getClassLoader();
        if (loader == null || loader == ClassLoader.getPlatformClassLoader()) {
            return;
        }
        throw new UnsatisfiedLinkError("native libraries are disabled in the source runtime (requested by "
                + fromClass.getName() + ")");
    }
}
