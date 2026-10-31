{
  stdenv,
  kernel,
  kernelModuleMakeFlags,
}:

stdenv.mkDerivation rec {
  pname = "ax88179-vendor";
  version = "4.1.0";

  src = ./ASIX_USB_NIC_Linux_Driver_Source_v4.1.0.tar.bz2;
  patches = [ ./0001-fix-napi-del-disconnect-warn.patch ];

  nativeBuildInputs = kernel.moduleBuildDependencies;

  hardeningDisable = [
    "pic"
    "format"
    # uncomment if needed on kernel upgrade
    # "fortify"
    # "stackprotector"
  ];

  KDIR = "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build";

  makeFlags = [
    "KDIR=${KDIR}"
    "TOOL_EXTRA_CFLAGS="
  ];

  # Call kbuild's modules_install directly; it signs the module and writes the
  # ax_usb_nic.ko.cer certificate aggregateModules expects. The kernel's make
  # flags (which carry the signing rule) are kept out of the build, where
  # they would point the userspace tools at the kernel's libc-less CC.
  installFlags = kernelModuleMakeFlags ++ [
    "-C"
    KDIR
    "M=$(PWD)"
    "INSTALL_MOD_PATH=${placeholder "out"}"
    "INSTALL_MOD_DIR=kernel/drivers/net/usb"
  ];

  installTargets = [ "modules_install" ];

  postInstall = ''
    mkdir -p "$out/bin"
    cp axcmd *_programmer *_ieee "$out/bin/"
  '';
}
