package com.zalexdev.stryker.engine;

import android.net.LocalSocket;
import android.net.LocalSocketAddress;

import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Locale;
import com.stryker.terminal.bridge.StrykerLog;

final class GuestConsole {

    private static final String TAG = "GuestConsole";
    private static final String MARK = "__STRYKER_CON__";
    private static final int READ_TIMEOUT_MS = 20000;
    private static final int ECHO_FRAGMENT_MIN = 20;

    private GuestConsole() {
    }

    static ArrayList<String> run(String command, String socketPath, int timeoutMs) {
        ArrayList<String> out = new ArrayList<>();
        if (command == null || socketPath == null) return out;
        long budget = timeoutMs > 0 ? timeoutMs : READ_TIMEOUT_MS;
        LocalSocket sock = new LocalSocket();
        try {
            sock.connect(new LocalSocketAddress(socketPath, LocalSocketAddress.Namespace.FILESYSTEM));
            sock.setSoTimeout((int) Math.min(budget, READ_TIMEOUT_MS));
            OutputStream os = sock.getOutputStream();
            os.write(("\n" + command + "\n" + "echo " + MARK + "$?\n")
                    .getBytes(StandardCharsets.UTF_8));
            os.flush();

            InputStream is = sock.getInputStream();
            StringBuilder buf = new StringBuilder();
            byte[] chunk = new byte[4096];
            long deadline = System.currentTimeMillis() + budget;
            while (System.currentTimeMillis() < deadline) {
                int r;
                try {
                    r = is.read(chunk);
                } catch (java.net.SocketTimeoutException te) {
                    // Nothing arrived: either the guest is still working or there is no
                    // shell reading the line at all. Re-check and keep waiting.
                    if (ranToCompletion(buf) || typedIntoLoginPrompt(buf, command)) break;
                    continue;
                }
                if (r <= 0) break;
                buf.append(new String(chunk, 0, r, StandardCharsets.UTF_8));
                if (typedIntoLoginPrompt(buf, command) || ranToCompletion(buf)) break;
            }

            String raw = buf.toString();
            if (typedIntoLoginPrompt(raw, command)) {
                StrykerLog.w(TAG, "the guest console is sitting at a login prompt, so the command was "
                        + "typed into the prompt instead of a shell and nothing ran: " + shortCmd(command));
                return out;
            }
            if (!ranToCompletion(raw)) {
                StrykerLog.w(TAG, "the guest console never ran the command within " + (budget / 1000)
                        + "s — nothing on it proves that a shell is listening: " + shortCmd(command));
                return out;
            }
            collect(raw, command, out);
        } catch (Exception e) {
            StrykerLog.w(TAG, "console command failed: " + e.getMessage());
        } finally {
            try { sock.close(); } catch (Exception ignored) {}
        }
        return out;
    }

    /**
     * True once the console printed the marker followed by the exit status. The echo of the
     * {@code echo __STRYKER_CON__$?} line we send also contains the marker, but followed by a
     * {@code $} rather than a digit, so it cannot be mistaken for real output.
     */
    private static boolean ranToCompletion(CharSequence hay) {
        String s = hay.toString();
        int from = 0;
        while (true) {
            int i = s.indexOf(MARK, from);
            if (i < 0) return false;
            int at = i + MARK.length();
            if (at < s.length() && Character.isDigit(s.charAt(at))) return true;
            from = at;
        }
    }

    /**
     * A getty that wants a login name echoes whatever we write as that name — the guest in this
     * build locks the root password, so a command sent there never runs and its own text comes
     * back looking like output. Detect it instead of pretending the command worked.
     */
    private static boolean typedIntoLoginPrompt(CharSequence hay, String command) {
        String probe = echoProbe(command);
        if (probe == null) return false;
        for (String line : hay.toString().split("\r?\n")) {
            String t = line.replace("\r", "");
            if (t.toLowerCase(Locale.ROOT).contains("login:") && t.contains(probe)) return true;
        }
        return false;
    }

    private static String echoProbe(String command) {
        String c = command == null ? "" : command.trim();
        if (c.isEmpty()) return null;
        return c.length() > 24 ? c.substring(0, 24) : c;
    }

    private static String shortCmd(String c) {
        if (c == null) return "";
        c = c.replace('\n', ' ').trim();
        return c.length() > 90 ? c.substring(0, 90) + "…" : c;
    }

    private static void collect(String raw, String command, ArrayList<String> out) {
        String sent = command == null ? "" : command.trim();
        String probe = echoProbe(command);
        for (String line : raw.split("\r?\n")) {
            String t = line.replace("\r", "").trim();
            if (t.isEmpty()) continue;
            if (t.contains(MARK)) continue;
            if (probe != null && t.contains(probe)) continue;
            if (sent.length() >= ECHO_FRAGMENT_MIN && sent.contains(t)) continue;
            if (t.endsWith("#") && t.contains("@")) continue;
            out.add(t);
        }
    }
}
