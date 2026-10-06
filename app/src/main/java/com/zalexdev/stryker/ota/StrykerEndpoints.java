package com.zalexdev.stryker.ota;

public final class StrykerEndpoints {

    public static final String GITHUB_REPO = "https://github.com/zalexdev/strykerapp";

    // The manifest and every binary it points at are served from this fork's own
    // mirrored releases, so OTA downloads no longer depend on the upstream repo.
    // The sha256/size values in the manifest are unchanged: the mirrored assets
    // are byte-identical, so verification still passes.
    public static final String MANIFEST_URL =
            "https://raw.githubusercontent.com/OPX-Aminul/strykerapp/main/stryker_manifest.json";

    public static final String FALLBACK_CHROOT_64 =
            "https://github.com/OPX-Aminul/strykerapp/releases/download/chroot-main/chroot64-debian.tar.gz";

    private static final String ROOTLESS_BASE =
            "https://github.com/OPX-Aminul/strykerapp/releases/download/rootless-main/";
    public static final String FALLBACK_ROOTLESS_QEMU     = ROOTLESS_BASE + "qemu-system-aarch64";
    public static final String FALLBACK_ROOTLESS_KERNEL   = ROOTLESS_BASE + "Image";
    public static final String FALLBACK_ROOTLESS_LIBSLIRP = ROOTLESS_BASE + "libslirp.so";
    public static final String FALLBACK_ROOTLESS_INITRD   = ROOTLESS_BASE + "initrd.img";
    public static final String FALLBACK_ROOTLESS_ROOTFS   = ROOTLESS_BASE + "rootfs.imgz";

    public static final String PREFS = "stryker_ota";

    private StrykerEndpoints() {
    }
}
