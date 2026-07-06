import org.objectweb.asm.ClassReader;
import org.objectweb.asm.ClassVisitor;
import org.objectweb.asm.FieldVisitor;
import org.objectweb.asm.MethodVisitor;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.Type;

import java.io.InputStream;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * MobiVM linkage audit: scans app jars (AFTER pre-pass + JvmDowngrader) for
 * references to java/* / javax/* members that do NOT exist in MobiVM's
 * runtime (robovm-rt.jar) or in the app-supplied java.* classes
 * (java-function-stubs, java.time supply). Every hit is a guaranteed
 * NoClassDefFoundError / NoSuchMethodError if that code path executes on iOS.
 *
 * This replaces the manual CLAUDE.md grep scan: run it after every upstream
 * merge and the output IS the remaining porting workload (usually empty).
 *
 * Usage: MobiVmLinkAudit --rt rt1.jar[,rt2.jar,...] --scan app1.jar[,app2.jar,...]
 * Output: one line per missing member: KIND owner.member(desc) <- count refs [sample referencer]
 */
public class MobiVmLinkAudit {

    static class ClassInfo {
        String superName;
        String[] interfaces;
        final Set<String> methods = new HashSet<>(); // name + desc
        final Set<String> fields = new HashSet<>();  // name
    }

    static final Map<String, ClassInfo> INDEX = new HashMap<>();
    static final Map<String, List<String>> MISSING = new TreeMap<>();

    public static void main(String[] args) throws Exception {
        List<String> rtJars = new ArrayList<>();
        List<String> scanJars = new ArrayList<>();
        for (int i = 0; i < args.length; i++) {
            if ("--rt".equals(args[i])) {
                for (String s : args[++i].split(",")) rtJars.add(s);
            } else if ("--scan".equals(args[i])) {
                for (String s : args[++i].split(",")) scanJars.add(s);
            }
        }
        for (String jar : rtJars) index(jar);
        for (String jar : scanJars) scan(jar);

        if (MISSING.isEmpty()) {
            System.out.println("AUDIT CLEAN: no unresolved java/* references");
            return;
        }
        System.out.println("AUDIT: " + MISSING.size() + " unresolved java/javax references:");
        for (Map.Entry<String, List<String>> e : MISSING.entrySet()) {
            List<String> refs = e.getValue();
            System.out.println(e.getKey() + "  <- " + refs.size() + " refs, e.g. " + refs.get(0));
        }
        System.exit(2);
    }

    // ---- indexing the runtime ----

    static void index(String jarPath) throws Exception {
        try (ZipFile zf = new ZipFile(jarPath)) {
            java.util.Enumeration<? extends ZipEntry> en = zf.entries();
            while (en.hasMoreElements()) {
                ZipEntry e = en.nextElement();
                if (!e.getName().endsWith(".class") || e.getName().startsWith("META-INF/versions/")) continue;
                try (InputStream is = zf.getInputStream(e)) {
                    ClassReader cr = new ClassReader(is);
                    final ClassInfo ci = new ClassInfo();
                    cr.accept(new ClassVisitor(Opcodes.ASM9) {
                        @Override
                        public void visit(int v, int acc, String name, String sig, String sup, String[] ifs) {
                            ci.superName = sup;
                            ci.interfaces = ifs;
                            INDEX.put(name, ci);
                        }
                        @Override
                        public MethodVisitor visitMethod(int acc, String name, String desc, String sig, String[] ex) {
                            ci.methods.add(name + desc);
                            return null;
                        }
                        @Override
                        public FieldVisitor visitField(int acc, String name, String desc, String sig, Object val) {
                            ci.fields.add(name);
                            return null;
                        }
                    }, ClassReader.SKIP_CODE | ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
                }
            }
        }
    }

    // ---- resolution ----

    static boolean isTracked(String owner) {
        // java8/* (streamsupport), forge/compat/* and jvmdg stubs are bridge
        // targets: verifying them catches redirects to nonexistent members
        // (e.g. interface statics absent from streamsupport interfaces)
        return owner.startsWith("java/") || owner.startsWith("javax/")
                || owner.startsWith("java8/") || owner.startsWith("forge/compat/")
                || owner.startsWith("xyz/wagyourtail/jvmdg/")
                || owner.startsWith("io/sentry/");
    }

    static boolean classExists(String name) {
        return INDEX.containsKey(name);
    }

    static boolean methodExists(String owner, String nameDesc) {
        if (owner.startsWith("[")) return true; // arrays: clone() etc.
        Set<String> seen = new HashSet<>();
        List<String> work = new ArrayList<>();
        work.add(owner);
        while (!work.isEmpty()) {
            String c = work.remove(work.size() - 1);
            if (c == null || !seen.add(c)) continue;
            ClassInfo ci = INDEX.get(c);
            if (ci == null) continue;
            if (ci.methods.contains(nameDesc)) return true;
            if (ci.superName != null) work.add(ci.superName);
            if (ci.interfaces != null) for (String i : ci.interfaces) work.add(i);
        }
        return false;
    }

    static boolean fieldExists(String owner, String name) {
        Set<String> seen = new HashSet<>();
        List<String> work = new ArrayList<>();
        work.add(owner);
        while (!work.isEmpty()) {
            String c = work.remove(work.size() - 1);
            if (c == null || !seen.add(c)) continue;
            ClassInfo ci = INDEX.get(c);
            if (ci == null) continue;
            if (ci.fields.contains(name)) return true;
            if (ci.superName != null) work.add(ci.superName);
            if (ci.interfaces != null) for (String i : ci.interfaces) work.add(i);
        }
        return false;
    }

    static void report(String key, String referencer) {
        List<String> l = MISSING.get(key);
        if (l == null) {
            l = new ArrayList<>();
            MISSING.put(key, l);
        }
        l.add(referencer);
    }

    // ---- scanning app jars ----

    static void scan(String jarPath) throws Exception {
        try (ZipFile zf = new ZipFile(jarPath)) {
            java.util.Enumeration<? extends ZipEntry> en = zf.entries();
            while (en.hasMoreElements()) {
                ZipEntry e = en.nextElement();
                if (!e.getName().endsWith(".class") || e.getName().startsWith("META-INF/versions/")) continue;
                try (InputStream is = zf.getInputStream(e)) {
                    ClassReader cr = new ClassReader(is);
                    final String self = cr.getClassName();
                    cr.accept(new ClassVisitor(Opcodes.ASM9) {
                        @Override
                        public MethodVisitor visitMethod(int acc, String mname, String mdesc, String sig, String[] ex) {
                            final String where = self + "." + mname;
                            return new MethodVisitor(Opcodes.ASM9) {
                                @Override
                                public void visitMethodInsn(int op, String owner, String name, String desc, boolean itf) {
                                    if (classExists(owner)) {
                                        // ANY indexed owner: unresolved member = will
                                        // NoSuchMethodError if executed (e.g. Java 8
                                        // default inherited through an app class)
                                        if (!methodExists(owner, name + desc)) {
                                            report("METHOD " + owner + "." + name + desc, where);
                                        }
                                    } else if (isTracked(owner)) {
                                        report("CLASS " + owner, where);
                                        // member-level demand: sizes the supply needed
                                        report("MISSING-MEMBER " + owner + "." + name + desc, where);
                                    }
                                }
                                @Override
                                public void visitFieldInsn(int op, String owner, String name, String desc) {
                                    if (isTracked(owner)) {
                                        if (!classExists(owner)) {
                                            report("CLASS " + owner, where);
                                        } else if (!fieldExists(owner, name)) {
                                            report("FIELD " + owner + "." + name, where);
                                        }
                                    }
                                }
                                @Override
                                public void visitTypeInsn(int op, String type) {
                                    if (isTracked(type) && !type.startsWith("[") && !classExists(type)) {
                                        report("CLASS " + type, where);
                                    }
                                }
                                @Override
                                public void visitLdcInsn(Object v) {
                                    if (v instanceof Type) {
                                        Type t = (Type) v;
                                        if (t.getSort() == Type.OBJECT && isTracked(t.getInternalName())
                                                && !classExists(t.getInternalName())) {
                                            report("CLASS " + t.getInternalName(), where);
                                        }
                                    }
                                }
                            };
                        }
                    }, ClassReader.SKIP_DEBUG | ClassReader.SKIP_FRAMES);
                }
            }
        }
    }
}
