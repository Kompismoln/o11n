pkgs: with pkgs; rec {
  all =
    core-cli
    ++ terminal-env
    ++ system-tools
    ++ networking
    ++ data-processing
    ++ archive-utils
    ++ secrets-management
    ++ nix-tools;

  core-cli = [
    bat
    eza
    fd
    file
    fzf
    inxi
    git
    jq
    bc
    lshw
    restic
    ripgrep
    tree
    wget
    python3
  ];

  terminal-env = [
    origin
    osc
    ranger
    reptyr
    tmux
    transmission_4-qt
    xdg-utils
  ];

  system-tools = [
    brightnessctl
    btrfs-progs
    dmidecode
    exfat
    lsof
    openssl
    pciutils
    psmisc
    smartmontools
    memtester
    parted
    strace
    tftp-hpa
    usbutils
    htop
    iotop
    smem
    nvme-cli
  ];

  networking = [
    dig
    ethtool
    iproute2
    nethogs
    nmap
    tcpdump
    traceroute
    wireguard-tools
    nload
    iftop
    vnstat
    mtr
    unixtools.arp
    wakeonlan
  ];

  data-processing = [
    envsubst
    libxml2
    rdfind
    w3m
    xh
  ];

  media-processing = [
    ffmpeg
    imagemagick
  ];

  archive-utils = [
    unzip
    zip
  ];

  secrets-management = [
    age
    bitwarden-cli
    sops
    ssh-to-age
    km-tools
  ];

  nix-tools = [
    nh
    dix
    nix-output-monitor
    nix-fast-build
    nvd
    nixos-facter
    nixos-anywhere
    disko
    nix-serve-ng
    statix
    deadnix
    nixfmt
  ];
}
