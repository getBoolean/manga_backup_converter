package mangabackup.tachi.ios;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.lang.classfile.ClassFile;
import java.lang.classfile.ClassHierarchyResolver;
import java.lang.classfile.ClassModel;
import java.lang.classfile.ClassTransform;
import java.lang.classfile.CodeBuilder;
import java.lang.classfile.CodeElement;
import java.lang.classfile.CodeModel;
import java.lang.classfile.CodeTransform;
import java.lang.classfile.Label;
import java.lang.classfile.MethodModel;
import java.lang.classfile.MethodTransform;
import java.lang.classfile.Opcode;
import java.lang.classfile.instruction.BranchInstruction;
import java.lang.classfile.instruction.LabelTarget;
import java.lang.classfile.instruction.LookupSwitchInstruction;
import java.lang.classfile.instruction.MonitorInstruction;
import java.lang.classfile.instruction.SwitchCase;
import java.lang.classfile.instruction.TableSwitchInstruction;
import java.lang.constant.ClassDesc;
import java.lang.constant.ConstantDescs;
import java.lang.constant.MethodTypeDesc;
import java.lang.reflect.AccessFlag;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;
import java.util.stream.Stream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

/**
 * Back-edge deadline rewrite pass (KTD11 mechanism A; U16 selected it, U9
 * ships it).
 *
 * Inserts a call to a poll method before every backward branch: a jump, or
 * a switch with any target, whose label is bound earlier in the method. The
 * poll throws {@code jdk.internal.misc.SourceRunnerDeadlineError} once the
 * thread's deadline has passed, and keeps throwing at every later back-edge,
 * so code that catches the error and loops again is still stopped.
 *
 * Rules (U9 decisions, see the iOS validation README):
 * <ul>
 *   <li>Class initializers ({@code <clinit>}) are never rewritten: an error
 *       thrown there poisons the class for the life of the VM.</li>
 *   <li>{@link Target#JAVA_BASE} calls {@code SourceRunnerDeadline.poll()}
 *       directly and, for lock safety, skips synchronized methods and
 *       back-edges inside {@code monitorenter}/{@code monitorexit}
 *       regions.</li>
 *   <li>{@link Target#UNNAMED} (extensions and host libraries) calls the
 *       exported {@code java.lang.SourceRunnerPoll.poll()}.</li>
 *   <li>Signature files are dropped from rewritten JARs: the input was
 *       verified before the pass and its signatures no longer apply.</li>
 * </ul>
 *
 * Uses only {@code java.lang.classfile} (JDK 24+), so it runs on the host JDK
 * built from the pinned tree at image build time and inside the embedded VM on
 * the device.
 */
public final class BackedgeRewriter {
    /** Part of every prepared artifact's cache identity (KTD5). Bump on any rule change. */
    public static final String VERSION = "ios-backedge.1";

    private static final MethodTypeDesc VOID = MethodTypeDesc.of(ConstantDescs.CD_void);
    private static final ClassDesc DEADLINE = ClassDesc.of("jdk.internal.misc.SourceRunnerDeadline");
    private static final ClassDesc POLL = ClassDesc.of("java.lang.SourceRunnerPoll");
    private static final ClassDesc NATIVE_GUARD = ClassDesc.of("jdk.internal.misc.SourceRunnerNativeGuard");
    private static final long FIXED_TIME = 315532800000L + 86400000L; // 1980-01-02, inside the zip epoch

    public enum Target { JAVA_BASE, UNNAMED }

    /** Counts of one pass. */
    public record Result(int classes, int methods, int backedges, int guards) {
        @Override
        public String toString() {
            return String.format(Locale.ROOT, "classes=%d methods=%d backedges=%d guards=%d", classes, methods, backedges, guards);
        }
    }

    private final Target target;
    private final List<String> include;
    private final List<String> exclude;
    private final boolean guardNatives;

    public BackedgeRewriter(Target target, List<String> include, List<String> exclude, boolean guardNatives) {
        this.target = target;
        this.include = List.copyOf(include);
        List<String> ex = new ArrayList<>(exclude);
        ex.add("jdk/internal/misc/SourceRunnerDeadline");
        ex.add("jdk/internal/misc/SourceRunnerNativeGuard");
        ex.add("java/lang/SourceRunnerPoll");
        this.exclude = List.copyOf(ex);
        this.guardNatives = guardNatives;
    }

    /** The pass the device applies to every prepared extension JAR. */
    public static BackedgeRewriter forExtensions() {
        return new BackedgeRewriter(Target.UNNAMED, List.of(), List.of(), false);
    }

    /**
     * Rewrites {@code entries} (JAR entry name to bytes) in place of their
     * originals. Returns the rewritten map (same order); unchanged classes are
     * kept unless {@code onlyRewritten}.
     */
    public Map<String, byte[]> rewrite(Map<String, byte[]> entries, ClassLoader hierarchy, boolean onlyRewritten,
                                       int[] counts) {
        ClassFile cf = ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(resolver(entries, hierarchy)));
        Map<String, byte[]> out = new LinkedHashMap<>();
        for (Map.Entry<String, byte[]> e : entries.entrySet()) {
            String name = e.getKey();
            byte[] bytes = e.getValue();
            if (target == Target.UNNAMED && isSignatureFile(name)) {
                continue;
            }
            boolean isClass = name.endsWith(".class") && !name.endsWith("module-info.class");
            String internal = isClass ? versionless(name.substring(0, name.length() - 6)) : name;
            boolean selected = isClass
                    && (include.isEmpty() || include.stream().anyMatch(internal::startsWith))
                    && exclude.stream().noneMatch(internal::startsWith);
            boolean guarded = isClass && guardNatives && internal.equals("java/lang/ClassLoader");
            if (selected || guarded) {
                ClassModel model = cf.parse(bytes);
                int[] local = new int[4];
                byte[] rewritten = cf.transformClass(model, transform(selected, guarded, local));
                if (local[1] > 0 || local[3] > 0) {
                    local[0] = 1;
                    for (int i = 0; i < 4; i++) counts[i] += local[i];
                    bytes = rewritten;
                } else if (onlyRewritten) {
                    continue;
                }
            } else if (onlyRewritten) {
                continue;
            }
            out.put(name, bytes);
        }
        return out;
    }

    /** Rewrites a JAR file. Entries keep their order; timestamps are fixed for reproducible output. */
    public Result rewriteJar(Path input, Path output, ClassLoader hierarchy) throws IOException {
        Map<String, byte[]> entries = new LinkedHashMap<>();
        read(input, entries);
        int[] counts = new int[4];
        Map<String, byte[]> out;
        try (URLClassLoader own = new URLClassLoader(new URL[] {input.toUri().toURL()}, hierarchy)) {
            out = rewrite(entries, own, false, counts);
        }
        write(output, out);
        return new Result(counts[0], counts[1], counts[2], counts[3]);
    }

    private ClassTransform transform(boolean backedges, boolean guarded, int[] counts) {
        return (cb, ce) -> {
            if (ce instanceof MethodModel mm && mm.code().isPresent()) {
                String name = mm.methodName().stringValue();
                String desc = mm.methodType().stringValue();
                boolean guard = guarded && name.equals("loadLibrary")
                        && (desc.equals("(Ljava/lang/Class;Ljava/lang/String;)Ljdk/internal/loader/NativeLibrary;")
                        || desc.equals("(Ljava/lang/Class;Ljava/io/File;)Ljdk/internal/loader/NativeLibrary;"));
                boolean skipLocked = target == Target.JAVA_BASE;
                boolean polls = backedges && !name.equals("<clinit>")
                        && !(skipLocked && mm.flags().has(AccessFlag.SYNCHRONIZED));
                if (guard || polls) {
                    cb.transformMethod(mm, MethodTransform.transformingCode(
                            new Polls(polls, guard, skipLocked, target == Target.JAVA_BASE ? DEADLINE : POLL, counts)));
                    return;
                }
            }
            cb.with(ce);
        };
    }

    /** Per-method state: labels already bound and the monitor depth at the current position. */
    private static final class Polls implements CodeTransform {
        private final Set<Label> bound = new HashSet<>();
        private final boolean polls;
        private final boolean guard;
        private final boolean skipLocked;
        private final ClassDesc owner;
        private final int[] counts;
        private int monitors;
        private boolean counted;

        Polls(boolean polls, boolean guard, boolean skipLocked, ClassDesc owner, int[] counts) {
            this.polls = polls;
            this.guard = guard;
            this.skipLocked = skipLocked;
            this.owner = owner;
            this.counts = counts;
        }

        @Override
        public void atStart(CodeBuilder b) {
            if (guard) {
                b.aload(0);
                b.invokestatic(NATIVE_GUARD, "check", MethodTypeDesc.of(ConstantDescs.CD_void, ConstantDescs.CD_Class));
                counts[3]++;
            }
        }

        @Override
        public void accept(CodeBuilder b, CodeElement e) {
            if (polls) {
                switch (e) {
                    case LabelTarget t -> bound.add(t.label());
                    case MonitorInstruction m -> monitors = Math.max(0, monitors + (m.opcode() == Opcode.MONITORENTER ? 1 : -1));
                    case BranchInstruction br when bound.contains(br.target()) -> poll(b);
                    case TableSwitchInstruction ts when isBackward(ts.defaultTarget(), ts.cases()) -> poll(b);
                    case LookupSwitchInstruction ls when isBackward(ls.defaultTarget(), ls.cases()) -> poll(b);
                    default -> { }
                }
            }
            b.with(e);
        }

        private boolean isBackward(Label dflt, List<SwitchCase> cases) {
            if (bound.contains(dflt)) return true;
            for (SwitchCase c : cases) {
                if (bound.contains(c.target())) return true;
            }
            return false;
        }

        private void poll(CodeBuilder b) {
            if (skipLocked && monitors > 0) return;
            b.invokestatic(owner, "poll", VOID);
            counts[2]++;
            if (!counted) {
                counted = true;
                counts[1]++;
            }
        }
    }

    /**
     * Resolves classes for stack-map generation: the entries being rewritten
     * first, then {@code hierarchy}, then the running class library. A class
     * found nowhere is treated as a direct subclass of Object, as the desktop
     * frame computer does (the verifier fails on it either way).
     */
    private static ClassHierarchyResolver resolver(Map<String, byte[]> entries, ClassLoader hierarchy) {
        ClassHierarchyResolver own = ClassHierarchyResolver.ofResourceParsing(desc -> {
            String internal = desc.descriptorString();
            internal = internal.substring(1, internal.length() - 1);
            byte[] bytes = entries.get(internal + ".class");
            if (bytes != null) return new java.io.ByteArrayInputStream(bytes);
            return hierarchy == null ? null : hierarchy.getResourceAsStream(internal + ".class");
        });
        ClassHierarchyResolver unknown = desc -> ClassHierarchyResolver.ClassHierarchyInfo.ofClass(ConstantDescs.CD_Object);
        return own.orElse(ClassHierarchyResolver.defaultResolver()).cached().orElse(unknown);
    }

    public static boolean isSignatureFile(String name) {
        if (!name.startsWith("META-INF/") || name.indexOf('/', 9) >= 0) return false;
        String upper = name.toUpperCase(Locale.ROOT);
        return upper.endsWith(".SF") || upper.endsWith(".RSA") || upper.endsWith(".DSA") || upper.endsWith(".EC")
                || upper.startsWith("META-INF/SIG-");
    }

    /** {@code META-INF/versions/N/a/B} (multi-release JAR) to {@code a/B}. */
    private static String versionless(String internal) {
        if (!internal.startsWith("META-INF/versions/")) return internal;
        int slash = internal.indexOf('/', "META-INF/versions/".length());
        return slash < 0 ? internal : internal.substring(slash + 1);
    }

    static void read(Path input, Map<String, byte[]> entries) throws IOException {
        if (Files.isDirectory(input)) {
            try (Stream<Path> files = Files.walk(input)) {
                for (Path f : (Iterable<Path>) files.filter(Files::isRegularFile).sorted()::iterator) {
                    entries.put(input.relativize(f).toString().replace('\\', '/'), Files.readAllBytes(f));
                }
            }
        } else {
            try (JarFile jar = new JarFile(input.toFile(), false)) {
                for (JarEntry je : (Iterable<JarEntry>) jar.stream()::iterator) {
                    if (je.isDirectory()) continue;
                    entries.put(je.getName(), jar.getInputStream(je).readAllBytes());
                }
            }
        }
    }

    static void write(Path output, Map<String, byte[]> entries) throws IOException {
        Path parent = output.toAbsolutePath().getParent();
        if (parent != null) Files.createDirectories(parent);
        ByteArrayOutputStream buffer = new ByteArrayOutputStream();
        try (ZipOutputStream zip = new ZipOutputStream(buffer)) {
            for (Map.Entry<String, byte[]> e : entries.entrySet()) {
                ZipEntry ze = new ZipEntry(e.getKey());
                ze.setTime(FIXED_TIME);
                zip.putNextEntry(ze);
                zip.write(e.getValue());
                zip.closeEntry();
            }
        }
        try (OutputStream os = Files.newOutputStream(output)) {
            buffer.writeTo(os);
        }
    }

    /**
     * Build-time CLI.
     *
     * <pre>
     * java -cp ios-host.jar mangabackup.tachi.ios.BackedgeRewriter --out OUT.jar
     *      [--target java.base|unnamed] [--guard-natives] [--only-rewritten]
     *      [--include PREFIX]... [--exclude PREFIX]... [--classpath PATH] INPUT(.jar|dir)...
     * </pre>
     *
     * Prints one summary line with the counts.
     */
    public static void main(String[] args) throws Exception {
        Path out = null;
        Target target = Target.UNNAMED;
        boolean guard = false;
        boolean onlyRewritten = false;
        List<String> include = new ArrayList<>();
        List<String> exclude = new ArrayList<>();
        List<URL> classpath = new ArrayList<>();
        List<Path> inputs = new ArrayList<>();
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--out" -> out = Path.of(args[++i]);
                case "--target" -> target = args[++i].equals("java.base") ? Target.JAVA_BASE : Target.UNNAMED;
                case "--guard-natives" -> guard = true;
                case "--only-rewritten" -> onlyRewritten = true;
                case "--include" -> include.add(args[++i]);
                case "--exclude" -> exclude.add(args[++i]);
                case "--classpath" -> {
                    for (String p : args[++i].split(":")) {
                        if (!p.isEmpty()) classpath.add(Path.of(p).toUri().toURL());
                    }
                }
                default -> inputs.add(Path.of(args[i]));
            }
        }
        if (out == null || inputs.isEmpty()) {
            System.err.println("usage: BackedgeRewriter --out OUT.jar [--target java.base|unnamed] [--guard-natives] "
                    + "[--only-rewritten] [--include P] [--exclude P] [--classpath CP] INPUT...");
            System.exit(2);
        }
        Map<String, byte[]> entries = new LinkedHashMap<>();
        for (Path input : inputs) {
            read(input, entries);
            classpath.add(input.toUri().toURL());
        }
        BackedgeRewriter rewriter = new BackedgeRewriter(target, include, exclude, guard);
        int[] counts = new int[4];
        Map<String, byte[]> result;
        try (URLClassLoader loader = new URLClassLoader(classpath.toArray(URL[]::new), null)) {
            result = rewriter.rewrite(entries, loader, onlyRewritten, counts);
        }
        write(out, result);
        System.out.printf(Locale.ROOT, "rewrote %s -> %s%n", new Result(counts[0], counts[1], counts[2], counts[3]), out);
    }
}
