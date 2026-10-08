package com.zalexdev.stryker.engine;

import java.util.List;
import java.util.Locale;

public final class BootDiagnosis {

    private BootDiagnosis() {
    }

    private static final String PANIC = "Kernel panic - not syncing:";

    private static boolean noise(String lower) {
        if (lower.contains("regulatory.db")) return true;
        if (lower.contains("failed to load") && lower.contains("firmware")) return true;
        if (lower.contains("rss-counter")) return true;
        if (lower.contains("dev fd0") || lower.contains("floppy")) return true;
        if (lower.contains("i8042")) return true;
        // UML prints this and then boots on ("memory hotplug won't be supported"), so it is
        // never the reason a guest died and must not be offered as one.
        if (lower.contains("madv_remove")) return true;
        if (lower.contains("can't release memory to the host")) return true;
        return lower.contains("crng init");
    }

    private static boolean explains(String line) {
        if (line == null || line.trim().isEmpty()) return false;
        String lower = line.toLowerCase(Locale.ROOT);
        if (noise(lower)) return false;
        if (line.contains(PANIC) || line.contains("Aborted")) return true;
        return lower.contains("cannot") || lower.contains("couldn't") || lower.contains("could not")
                || lower.contains("failed") || lower.contains("error")
                || lower.contains("denied") || lower.contains("no such")
                || lower.contains("address already in use") || lower.contains("unable to")
                || lower.contains("out of memory") || lower.contains("no space left");
    }

    private static String signature(List<String> tail) {
        boolean pageSize = false;
        boolean ptrace = false;
        boolean killedInit = false;
        boolean noSpace = false;
        boolean oom = false;
        String passt = null;
        String seccompKill = null;

        for (String raw : tail) {
            if (raw == null) continue;
            String lower = raw.toLowerCase(Locale.ROOT);
            if (lower.contains("host page size") && lower.contains("built for")) pageSize = true;
            if (lower.contains("stepping off a syscall stop")) ptrace = true;
            if (lower.contains("attempted to kill init")) killedInit = true;
            if (lower.contains("no space left")) noSpace = true;
            if (lower.contains("out of memory") || lower.contains("oom-kill")) oom = true;
            if (lower.contains("bad system call") || lower.contains("sigsys")
                    || lower.contains("killed by signal 31")) {
                if (seccompKill == null) seccompKill = raw.trim();
            }
            if (lower.startsWith("passt:") || lower.contains("passt exited")
                    || lower.contains("umnet:")
                    || (lower.contains("couldn't") && lower.contains("port"))) {
                if (passt == null) passt = raw.trim();
            }
        }

        if (pageSize) {
            return "this phone's kernel uses 16 KB memory pages and the guest kernel was built"
                    + " for 4 KB ones. Nothing in the app can bridge that — the guest needs a"
                    + " kernel built for this page size.";
        }
        if (ptrace) {
            return "the host refused the guest's first system call. This phone has no seccomp"
                    + " support for the guest kernel and no working ptrace path, so there is no"
                    + " way to run a guest on it.";
        }
        if (seccompKill != null) {
            return "this phone's seccomp policy answered a syscall with SIGSYS (signal 31) and killed"
                    + " the guest (" + seccompKill + "). The guest kernel and the networking helper it"
                    + " is started with both need syscall 436 (close_range), which this device blocks,"
                    + " so the UML engine cannot run here — the QEMU engine does not need it.";
        }
        if (noSpace) {
            return "the guest ran out of disk. Free some space on the phone and start it again —"
                    + " the disk image grows into whatever is left.";
        }
        if (oom) {
            return "the guest ran out of memory. Give it less RAM in the engine's settings, or"
                    + " close some apps: the guest's memory comes out of the phone's.";
        }
        if (passt != null) {
            return "networking did not start: " + passt;
        }
        if (killedInit) {
            return "the guest kernel killed its own init. Its console is the only account of why.";
        }
        return null;
    }

    public static String reason(List<String> tail, int stage) {
        if (tail == null || tail.isEmpty()) {
            return stage > VmBootStage.START ? stageNote(stage) : "the guest printed nothing at all";
        }

        for (int i = tail.size() - 1; i >= 0; i--) {
            String l = tail.get(i);
            if (l != null && l.contains(PANIC)) {
                String what = l.substring(l.indexOf(PANIC) + PANIC.length()).trim();
                String extra = signature(tail);
                if (what.isEmpty()) what = "the guest kernel panicked";
                return extra == null ? what : what + " — " + extra;
            }
        }

        String known = signature(tail);
        if (known != null) return known;

        for (int i = tail.size() - 1; i >= 0; i--) {
            if (explains(tail.get(i))) {
                String line = tail.get(i).trim();
                if (line.length() > 200) line = line.substring(0, 200) + "…";
                return line;
            }
        }

        if (stage >= VmBootStage.AGENT) return stageNote(stage);
        return stage >= 0
                ? stageNote(stage) + ", and nothing on the console says why"
                : "nothing on the console says why";
    }

    public static String stageNote(int stage) {
        switch (stage) {
            case VmBootStage.KERNEL:
                return "the guest kernel started but never mounted its disk";
            case VmBootStage.ROOTFS:
                return "the guest mounted its disk but its services never started";
            case VmBootStage.SERVICES:
                return "the guest's services started but its agent never answered";
            case VmBootStage.AGENT:
                return "the guest finished booting (its console shows its login prompt) but the app"
                        + " could not run a command in it over ssh";
            case VmBootStage.READY:
                return "the guest reported itself ready";
            default:
                return "the guest kernel never printed anything";
        }
    }
}
