/*
 * Back-edge deadline rewriter (KTD11 mechanism A).
 *
 * Inserts `invokestatic jdk/internal/misc/SourceRunnerDeadline.poll()V`
 * before every backward branch (a jump, or a switch with any target, whose
 * label is bound earlier in the method). Uses only the JDK's
 * java.lang.classfile API, so it runs on the host JDK image built from the
 * same openjdk/mobile tree and understands its class-file version.
 *
 * Usage:
 *   java BackedgeRewriter.java --out OUT.jar [--include PREFIX]...
 *        [--exclude PREFIX]... [--classpath PATH] INPUT(.jar|dir)...
 *
 * Only classes whose internal name starts with an --include prefix (all, if
 * none is given) and with no --exclude prefix are rewritten; other classes
 * from the inputs are copied unchanged unless --only-rewritten is passed.
 * Prints one summary line: classes, methods and back-edges rewritten.
 */

import java.io.IOException;
import java.io.OutputStream;
import java.lang.classfile.ClassFile;
import java.lang.classfile.ClassHierarchyResolver;
import java.lang.classfile.ClassModel;
import java.lang.classfile.ClassTransform;
import java.lang.classfile.CodeBuilder;
import java.lang.classfile.CodeElement;
import java.lang.classfile.CodeTransform;
import java.lang.classfile.Label;
import java.lang.classfile.instruction.BranchInstruction;
import java.lang.classfile.instruction.LabelTarget;
import java.lang.classfile.instruction.LookupSwitchInstruction;
import java.lang.classfile.instruction.SwitchCase;
import java.lang.classfile.instruction.TableSwitchInstruction;
import java.lang.constant.ClassDesc;
import java.lang.constant.ConstantDescs;
import java.lang.constant.MethodTypeDesc;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.jar.JarEntry;
import java.util.jar.JarFile;
import java.util.jar.JarOutputStream;
import java.util.stream.Stream;

public final class BackedgeRewriter {
    static final ClassDesc DEADLINE = ClassDesc.of("jdk.internal.misc.SourceRunnerDeadline");
    static final MethodTypeDesc VOID = MethodTypeDesc.of(ConstantDescs.CD_void);

    public static void main(String[] args) throws Exception {
        Path out = null;
        List<String> include = new ArrayList<>();
        List<String> exclude = new ArrayList<>(List.of("jdk/internal/misc/SourceRunnerDeadline"));
        List<Path> classpath = new ArrayList<>();
        List<Path> inputs = new ArrayList<>();
        boolean onlyRewritten = false;
        for (int i = 0; i < args.length; i++) {
            switch (args[i]) {
                case "--out" -> out = Path.of(args[++i]);
                case "--include" -> include.add(args[++i]);
                case "--exclude" -> exclude.add(args[++i]);
                case "--only-rewritten" -> onlyRewritten = true;
                case "--classpath" -> {
                    for (String p : args[++i].split(":")) {
                        if (!p.isEmpty()) classpath.add(Path.of(p));
                    }
                }
                default -> inputs.add(Path.of(args[i]));
            }
        }
        if (out == null || inputs.isEmpty()) {
            System.err.println("usage: BackedgeRewriter --out OUT.jar [--include P] [--exclude P] [--classpath CP] INPUT...");
            System.exit(2);
        }

        Map<String, byte[]> entries = new LinkedHashMap<>();
        for (Path input : inputs) {
            read(input, entries);
        }

        List<URL> urls = new ArrayList<>();
        for (Path p : classpath) urls.add(p.toUri().toURL());
        for (Path p : inputs) urls.add(p.toUri().toURL());
        ClassLoader loader = new URLClassLoader(urls.toArray(URL[]::new), null);
        ClassFile cf = ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(
                ClassHierarchyResolver.defaultResolver()
                        .orElse(ClassHierarchyResolver.ofResourceParsing(loader))));

        AtomicInteger classes = new AtomicInteger();
        AtomicInteger methods = new AtomicInteger();
        AtomicInteger edges = new AtomicInteger();
        Files.createDirectories(out.toAbsolutePath().getParent());
        try (OutputStream os = Files.newOutputStream(out);
             JarOutputStream jar = new JarOutputStream(os)) {
            for (Map.Entry<String, byte[]> e : entries.entrySet()) {
                String name = e.getKey();
                byte[] bytes = e.getValue();
                boolean isClass = name.endsWith(".class") && !name.endsWith("module-info.class");
                String internal = isClass ? name.substring(0, name.length() - 6) : name;
                boolean selected = isClass
                        && (include.isEmpty() || include.stream().anyMatch(internal::startsWith))
                        && exclude.stream().noneMatch(internal::startsWith);
                if (selected) {
                    ClassModel model = cf.parse(bytes);
                    int before = edges.get();
                    byte[] rewritten = cf.transformClass(model,
                            ClassTransform.transformingMethodBodies(
                                    CodeTransform.ofStateful(() -> new BackedgePolls(edges, methods))));
                    if (edges.get() != before) {
                        classes.incrementAndGet();
                        bytes = rewritten;
                    } else if (onlyRewritten) {
                        continue;
                    }
                } else if (onlyRewritten) {
                    continue;
                }
                jar.putNextEntry(new JarEntry(name));
                jar.write(bytes);
                jar.closeEntry();
            }
        }
        System.out.printf("rewrote classes=%d methods=%d backedges=%d -> %s%n",
                classes.get(), methods.get(), edges.get(), out);
    }

    /** Per-method state: labels already bound at the current position. */
    static final class BackedgePolls implements CodeTransform {
        private final Set<Label> bound = new HashSet<>();
        private final AtomicInteger edges;
        private final AtomicInteger methods;
        private boolean counted;

        BackedgePolls(AtomicInteger edges, AtomicInteger methods) {
            this.edges = edges;
            this.methods = methods;
        }

        @Override
        public void accept(CodeBuilder b, CodeElement e) {
            switch (e) {
                case LabelTarget t -> bound.add(t.label());
                case BranchInstruction br when bound.contains(br.target()) -> poll(b);
                case TableSwitchInstruction ts when isBackward(ts.defaultTarget(), ts.cases()) -> poll(b);
                case LookupSwitchInstruction ls when isBackward(ls.defaultTarget(), ls.cases()) -> poll(b);
                default -> { }
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
            b.invokestatic(DEADLINE, "poll", VOID);
            edges.incrementAndGet();
            if (!counted) {
                counted = true;
                methods.incrementAndGet();
            }
        }
    }

    private static void read(Path input, Map<String, byte[]> entries) throws IOException {
        if (Files.isDirectory(input)) {
            try (Stream<Path> files = Files.walk(input)) {
                for (Path f : (Iterable<Path>) files.filter(Files::isRegularFile)::iterator) {
                    entries.put(input.relativize(f).toString().replace('\\', '/'), Files.readAllBytes(f));
                }
            }
        } else {
            try (JarFile jar = new JarFile(input.toFile())) {
                for (JarEntry je : (Iterable<JarEntry>) jar.stream()::iterator) {
                    if (je.isDirectory()) continue;
                    entries.put(je.getName(), jar.getInputStream(je).readAllBytes());
                }
            }
        }
    }
}
