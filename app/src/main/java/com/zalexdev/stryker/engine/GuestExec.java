package com.zalexdev.stryker.engine;


import com.jcraft.jsch.ChannelExec;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import com.stryker.terminal.bridge.StrykerLog;

public final class GuestExec {

    private static final String TAG = "GuestExec";
    private static final String EXIT_SENTINEL = "__STRYKER_EXIT__";
    private static final String JOB_EOF = "__STRYKER_JOB_EOF__";
    private static final String JOB_DIR = "/tmp";
    private static final java.util.concurrent.atomic.AtomicLong JOB_SEQ =
            new java.util.concurrent.atomic.AtomicLong();
    private static final int READ_TIMEOUT_MS = 90_000;

    private GuestExec() {}

    private static String wrap(String command) {
        return "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin${PATH:+:$PATH}; "
                + "export HOME=/root LANG=C.UTF-8; "
                + command
                + "\nprintf '\\n" + EXIT_SENTINEL + "%s\\n' \"$?\"\n";
    }

    private static String wrapJob(String command, String jobId) {
        String script = JOB_DIR + "/stryker-" + jobId + ".sh";
        String pidFile = JOB_DIR + "/stryker-" + jobId + ".pid";
        return "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/snap/bin${PATH:+:$PATH}; "
                + "export HOME=/root LANG=C.UTF-8; "
                + "cat > " + script + " <<'" + JOB_EOF + "'\n"
                + "echo $$ > " + pidFile + "\n"
                + command + "\n"
                + JOB_EOF + "\n"
                + "if command -v setsid >/dev/null 2>&1; then setsid sh " + script + " & "
                + "else sh " + script + " & fi\n"
                + "__stryker_job=$!\n"
                + "wait $__stryker_job\n"
                + "printf '\\n" + EXIT_SENTINEL + "%s\\n' \"$?\"\n"
                + "rm -f " + script + " " + pidFile + "\n";
    }

    private static void killJob(String jobId) {
        final String pidFile = JOB_DIR + "/stryker-" + jobId + ".pid";
        final String cmd =
                "if [ -f " + pidFile + " ]; then __g=$(cat " + pidFile + " 2>/dev/null); "
                        + "if [ -n \"$__g\" ]; then kill -TERM -$__g 2>/dev/null || kill -TERM $__g 2>/dev/null; "
                        + "sleep 1; kill -KILL -$__g 2>/dev/null || kill -KILL $__g 2>/dev/null; fi; fi; "
                        + "rm -f " + JOB_DIR + "/stryker-" + jobId + ".sh " + pidFile;
        new Thread(() -> run(cmd), "guest-killjob").start();
    }

    private static final long DUPLICATE_WINDOW_MS = 10_000L;
    private static volatile String lastFailure;
    private static volatile long lastFailureAt;

    /**
     * One dead transport makes every caller fail at once. Report the first failure and stay quiet
     * about the repeats instead of filling the log with the same line.
     */
    private static boolean alreadyReported(String what) {
        long now = System.currentTimeMillis();
        if (what.equals(lastFailure) && now - lastFailureAt < DUPLICATE_WINDOW_MS) {
            lastFailureAt = now;
            return true;
        }
        lastFailure = what;
        lastFailureAt = now;
        return false;
    }

    public static ArrayList<String> run(String command) {
        ArrayList<String> out = new ArrayList<>();
        Session s = null;
        boolean transportFailed = false;
        try {
            s = open(command);
            s.setReadTimeout(READ_TIMEOUT_MS);
            String line;
            while ((line = s.reader.readLine()) != null) {
                if (line.startsWith(EXIT_SENTINEL)) {
                    try { s.exitCode = Integer.parseInt(line.substring(EXIT_SENTINEL.length()).trim()); }
                    catch (NumberFormatException ignored) {}
                    break;
                }
                out.add(line);
            }
        } catch (java.net.SocketTimeoutException te) {
            StrykerLog.w(TAG, "run timed out: " + shortCmd(command));
            logToStore("guest command timed out after " + (READ_TIMEOUT_MS / 1000)
                    + "s with no output (hung?) · " + shortCmd(command));
        } catch (IOException e) {
            transportFailed = true;
            StrykerLog.w(TAG, "run failed: " + e.getMessage());
            String what = "guest exec failed — no ssh session to the guest on :"
                    + RootlessPaths.HOST_SSH_PORT + " (" + e.getMessage() + ")";
            if (!alreadyReported(what)) {
                logToStore(what + " · " + shortCmd(command));
            }
        } finally {
            if (s != null) s.close();
        }
        if (!transportFailed && out.isEmpty() && (s == null || s.exitCode != 0)) {
            StrykerLog.w(TAG, "guest command produced no output: " + shortCmd(command));
        }
        return out;
    }

    static void logToStore(String msg) {
        try {
            com.zalexdev.stryker.logger.LogStore st = com.zalexdev.stryker.logger.LogStore.peek();
            if (st != null) st.add(levelOf(msg), "guest", msg);
        } catch (Throwable ignored) {}
    }

    private static int levelOf(String msg) {
        if (msg == null) return com.zalexdev.stryker.logger.LogEntry.INFO;
        String lower = msg.toLowerCase(java.util.Locale.ROOT);
        if (lower.contains("failed") || lower.contains("could not") || lower.contains("cannot")
                || lower.contains("unreachable") || lower.contains("timed out")
                || lower.contains("refused") || lower.contains("no ssh session")) {
            return com.zalexdev.stryker.logger.LogEntry.ERR;
        }
        if (lower.contains("falling back") || lower.contains("retry") || lower.contains("no host")
                || lower.contains("stray") || lower.contains("bootstrapping")) {
            return com.zalexdev.stryker.logger.LogEntry.WARN;
        }
        return com.zalexdev.stryker.logger.LogEntry.INFO;
    }

    private static String shortCmd(String c) {
        if (c == null) return "";
        c = c.replace('\n', ' ').trim();
        return c.length() > 90 ? c.substring(0, 90) + "…" : c;
    }

    public static Session open(String command) throws IOException {
        return connect(command, null);
    }

    public static Session openJob(String command) throws IOException {
        return connect(command, Long.toHexString(System.nanoTime()) + "-" + JOB_SEQ.incrementAndGet());
    }

    private static Session connect(String command, String jobId) throws IOException {
        String payload = jobId == null ? wrap(command) : wrapJob(command, jobId);
        try {
            ChannelExec channel = GuestSsh.exec("sh -c " + singleQuote(payload));
            channel.connect(20_000);
            return new Session(channel, jobId);
        } catch (com.jcraft.jsch.JSchException e) {
            GuestSsh.dropIfDead();
            throw new IOException(e.getMessage(), e);
        }
    }

    private static String singleQuote(String s) {
        return "'" + s.replace("'", "'\\''") + "'";
    }

    public static java.util.List<String> wirelessInterfaces() {
        java.util.List<String> out = new java.util.ArrayList<>();
        for (String l : run("iw dev 2>/dev/null | awk '$1==\"Interface\"{print $2}'")) {
            if (l != null && !l.trim().isEmpty()) out.add(l.trim());
        }
        return out;
    }

    public static boolean ping(int timeoutMs) {
        return GuestSsh.ping(timeoutMs);
    }

    public static final class Session {

        private final ChannelExec channel;
        public final InputStream input;
        public final BufferedReader reader;
        public volatile int exitCode = -1;

        private final String jobId;
        private volatile boolean closed;

        Session(ChannelExec channel, String jobId) throws IOException {
            this.channel = channel;
            this.jobId = jobId;
            this.input = channel.getInputStream();
            this.reader = new BufferedReader(new InputStreamReader(input, StandardCharsets.UTF_8));
        }

        public static final String SENTINEL = EXIT_SENTINEL;

        public void setReadTimeout(int ms) {
            try {
                channel.getSession().setTimeout(ms);
            } catch (Exception ignored) {
            }
        }

        public void close() {
            boolean first = !closed;
            closed = true;
            try { channel.disconnect(); } catch (Exception ignored) {}
            if (first && jobId != null) killJob(jobId);
        }
    }
}
