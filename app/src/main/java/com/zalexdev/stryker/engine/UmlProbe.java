package com.zalexdev.stryker.engine;

import android.content.Context;

import java.io.BufferedReader;
import java.io.File;
import java.io.InputStreamReader;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import com.stryker.terminal.bridge.StrykerLog;

public final class UmlProbe {

    private static final String TAG = "UmlProbe";

    public static final long DEFAULT_TIMEOUT_MS = 12_000;

    private static final int PROBE_MEM_MB = 64;

    private UmlProbe() {}

    public enum Verdict {
        KERNEL_STARTS,
        UNPROVEN,
        BLOCKED
    }

    public static final class Result {
        public final Verdict verdict;
        public final String detail;
        public final List<String> notes;

        Result(Verdict verdict, String detail, List<String> notes) {
            this.verdict = verdict;
            this.detail = detail;
            this.notes = notes == null ? Collections.emptyList() : notes;
        }

        public boolean ruledOut() {
            return verdict == Verdict.BLOCKED;
        }
    }

    public static Result run(Context context) {
        return run(context, DEFAULT_TIMEOUT_MS);
    }

    public static Result run(Context context, long timeoutMs) {
        return withPageSize(probe(context, timeoutMs));
    }

    private static Result withPageSize(Result r) {
        if (r == null || r.verdict == Verdict.KERNEL_STARTS) return r;
        long page = hostPageSize();
        if (page == 4096L || page <= 0L) return r;
        return new Result(r.verdict,
                r.detail + " · this phone's kernel uses " + (page / 1024) + " KB memory pages",
                r.notes);
    }

    private static long hostPageSize() {
        try {
            return android.system.Os.sysconf(android.system.OsConstants._SC_PAGESIZE);
        } catch (Throwable t) {
            return -1L;
        }
    }

    private static Result probe(Context context, long timeoutMs) {
        UmlEngine uml = Engines.uml(context);

        if (Engines.running(context) != null) {
            return new Result(Verdict.UNPROVEN, "a guest is already running", null);
        }

        File kernel = uml.kernel();
        File stub = uml.stub();
        if (!executable(kernel)) {
            return new Result(Verdict.BLOCKED,
                    "the kernel is missing or will not execute", null);
        }
        if (!stub.exists()) {
            return new Result(Verdict.BLOCKED,
                    "the address-space stub is missing", null);
        }

        Process p = null;
        Scan scan = new Scan();
        try {
            uml.base().mkdirs();

            ProcessBuilder pb = new ProcessBuilder(command(kernel, stub));
            pb.directory(uml.base());
            pb.redirectErrorStream(true);
            pb.environment().put("HOME", uml.base().getAbsolutePath());
            String tmp = uml.fallbackTempDir();
            if (tmp != null) pb.environment().put("TMPDIR", tmp);

            p = pb.start();
            pump(p, scan);

            long deadline = System.currentTimeMillis() + timeoutMs;
            while (System.currentTimeMillis() < deadline) {
                if (scan.decided()) break;
                if (!p.isAlive()) {
                    sleep(250);
                    break;
                }
                sleep(100);
            }
            return scan.verdict(p.isAlive() ? null : exitCode(p));
        } catch (Throwable t) {
            StrykerLog.w(TAG, "uml probe failed to start", t);
            return new Result(Verdict.BLOCKED,
                    "the kernel would not start: " + reason(t), scan.notes());
        } finally {
            kill(p);
        }
    }

    private static List<String> command(File kernel, File stub) {
        List<String> cmd = new ArrayList<>();
        cmd.add(kernel.getAbsolutePath());
        cmd.add("mem=" + PROBE_MEM_MB + "M");
        cmd.add("con=null");
        cmd.add("con0=fd:0,fd:1");
        cmd.add("stub_exe=" + stub.getAbsolutePath());
        cmd.add("seccomp=auto");
        return cmd;
    }

    private static void pump(Process p, Scan scan) {
        Thread t = new Thread(() -> {
            try (BufferedReader in = new BufferedReader(
                    new InputStreamReader(p.getInputStream()))) {
                String line;
                while ((line = in.readLine()) != null) scan.accept(line);
            } catch (Throwable ignored) {
            }
        }, "uml-probe-console");
        t.setDaemon(true);
        t.start();
    }

    private static final class Scan {
        private final List<String> notes = Collections.synchronizedList(new ArrayList<>());
        private volatile boolean banner;
        private volatile boolean completed;
        private volatile String blocker;
        private volatile String mode = "";

        void accept(String raw) {
            if (raw == null) return;
            String line = raw.trim();
            if (line.isEmpty()) return;

            if (line.contains("Linux version")) banner = true;

            if (line.contains("Unable to mount root fs")
                    || line.contains("VFS: Cannot open root device")
                    || line.contains("Kernel panic")) {
                banner = true;
                completed = true;
            }

            if (line.contains("Userspace mode:")) {
                mode = line;
                keep(line);
            }
            if (line.contains("tempdir") || line.contains("PROT_EXEC")
                    || line.startsWith("Checking")) {
                keep(line);
            }

            if (banner) return;
            if (line.contains("none found")) {
                blocked("no writable tempdir for the guest's memory");
            } else if (line.contains("Failed to") || line.contains("failed to")
                    || line.contains("Aborted") || line.contains("Illegal instruction")
                    || line.contains("Permission denied") || line.contains("not permitted")) {
                blocked(line);
                keep(line);
            }
        }

        private void keep(String line) {
            if (notes.size() < 24) notes.add(line);
        }

        private void blocked(String why) {
            if (blocker == null) blocker = why;
        }

        boolean decided() {
            return completed || (blocker != null && !banner);
        }

        List<String> notes() {
            return new ArrayList<>(notes);
        }

        Result verdict(Integer exit) {
            if (completed) {
                String detail = mode.isEmpty()
                        ? "the kernel starts here"
                        : "the kernel starts here · " + shortMode();
                return new Result(Verdict.KERNEL_STARTS, detail, notes());
            }
            if (banner) {
                return new Result(Verdict.KERNEL_STARTS, "the kernel starts here", notes());
            }
            if (blocker != null) {
                return new Result(Verdict.BLOCKED, blocker, notes());
            }
            if (exit != null) {
                return new Result(Verdict.BLOCKED,
                        "the kernel exited immediately (" + exit + ")", notes());
            }
            return new Result(Verdict.UNPROVEN, "the kernel did not answer in time", notes());
        }

        private String shortMode() {
            int at = mode.indexOf("Userspace mode:");
            String tail = at < 0 ? mode : mode.substring(at);
            return tail.length() > 48 ? tail.substring(0, 48) : tail;
        }
    }

    private static boolean executable(File f) {
        if (!f.exists()) return false;
        if (f.canExecute()) return true;
        try {
            f.setExecutable(true, false);
        } catch (Throwable ignored) {
        }
        return f.canExecute();
    }

    private static void kill(Process p) {
        if (p == null) return;
        try {
            p.destroy();
            for (int i = 0; i < 10 && p.isAlive(); i++) sleep(100);
            if (p.isAlive()) p.destroyForcibly();
        } catch (Throwable ignored) {
        }
    }

    private static Integer exitCode(Process p) {
        try {
            return p.exitValue();
        } catch (Throwable t) {
            return null;
        }
    }

    private static String reason(Throwable t) {
        String m = t.getMessage();
        return m == null || m.isEmpty() ? t.getClass().getSimpleName() : m;
    }

    private static void sleep(long ms) {
        try {
            Thread.sleep(ms);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
