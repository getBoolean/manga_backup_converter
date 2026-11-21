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

package java.lang;

/**
 * Deadline poll for code outside java.base (U9, KTD11 mechanism A).
 *
 * The iOS rewrite pass inserts a call to {@link #poll()} before every
 * backward branch of extension classes and of the rewritten host libraries.
 * Those classes live in unnamed modules, which cannot link against the
 * non-exported {@code jdk.internal.misc.SourceRunnerDeadline}; this class sits
 * in an exported package and forwards to it, so nothing else in
 * {@code jdk.internal.misc} has to be exported to source code. Rewritten
 * java.base classes call {@code SourceRunnerDeadline.poll()} directly.
 *
 * Baked into the runtime image's java.base by
 * {@code tools/tachi-source-runner/ios/scripts/build_runtime.sh image}; not
 * part of the openjdk/mobile source.
 */
public final class SourceRunnerPoll {
    private SourceRunnerPoll() {}

    /** Throws the deadline error when the current thread's deadline has passed. */
    public static void poll() {
        jdk.internal.misc.SourceRunnerDeadline.poll();
    }
}
