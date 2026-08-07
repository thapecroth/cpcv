@{
    # An SSH config alias (recommended), hostname, or user@host. This file is
    # an example only; copy it to %LOCALAPPDATA%\imgpaste\config.psd1 or set
    # IMGPASTE_CONFIG to a private file outside this checkout.
    HostAlias = "my-server"

    # Relative to the remote user's HOME. Nested paths are supported.
    RemoteDir = "clipboard-images"

    # Optional absolute remote home, used to form a pasteable path before the
    # first successful upload. Leave blank to use ~/RemoteDir/latest.png.
    RemoteHome = ""

    # Optional local state/cache location. Leave this commented to use
    # %LOCALAPPDATA%\imgpaste. This value may be an absolute Windows path.
    # DataRoot = "C:\Users\you\AppData\Local\imgpaste"

    # Optional tuning. Defaults are conservative and normally need no change.
    # PollIntervalSeconds = 2
    # CommandTimeoutSeconds = 35
    # MaxCommandOutputBytes = 65536
    # WatchdogCheckSeconds = 15
    # WatchdogStaleSeconds = 120 # At least 3 * command timeout + watchdog check.
    # MaxLogBytes = 1048576
    # MaxImageBytes = 52428800 # 50 MiB; must not exceed MaxCacheBytes.
    # MaxCacheBytes = 268435456 # 256 MiB; retained cache-byte cap.
    # MaxCacheFiles = 200 # Set to 0 to disable only count-based pruning.
}
