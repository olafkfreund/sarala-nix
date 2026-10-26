{ pkgs, self }:
pkgs.testers.runNixOSTest {
  name = "sarala";

  nodes.machine =
    { ... }:
    {
      # nixpkgs' own test helper: IceWM with root auto-logged in, so the driver can see windows.
      imports = [
        "${pkgs.path}/nixos/tests/common/x11.nix"
        self.nixosModules.default
      ];

      programs.sarala = {
        enable = true;
        defaultForMarkdown = true;
      };

      virtualisation.memorySize = 2048;
    };

  testScript = ''
    from datetime import timedelta

    machine.wait_for_x()
    machine.succeed("grep -q 'text/markdown=sarala.desktop' /etc/xdg/mimeapps.list")
    machine.succeed("grep -q 'text/x-markdown=sarala.desktop' /etc/xdg/mimeapps.list")
    machine.succeed("test -f /run/current-system/sw/share/applications/sarala.desktop")
    # WebKitGTK cannot allocate GBM buffers under QEMU's software GL.
    machine.execute("WEBKIT_DISABLE_DMABUF_RENDERER=1 WEBKIT_DISABLE_COMPOSITING_MODE=1 sarala >&2 &")
    machine.wait_for_window("Sarala", timeout=timedelta(minutes=5))
    machine.sleep(5)
    # Still alive after start-up, not just a window that flashed.
    machine.succeed("pgrep -f sarala")
    machine.wait_for_window("Sarala")
    machine.screenshot("sarala")
  '';
}
