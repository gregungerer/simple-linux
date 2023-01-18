#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# build-m68knommu-linux-uclibc-flt.sh -- build really simple linux for m68knommu
#
# (C) Copyright 2022-2023, Greg Ungerer (gerg@kernel.org)
#
# This script carries out a simple build of an m68knommu based user space
# and linux for use with the ColdFire/m5208evb qemu emulated machine.
# This build is designed to make a "flt" execuatble format system.
#
# This is designed to be as absolutely simple and minimal as possible.
# Only the first stage gcc is built (that is all we really need) and
# only the busybox package to provide a very basic user space.
#
# The build starts by building binutils and a first pass minimal gcc,
# then builds uClibc, busybox and finally a kernel. The resulting kernel
# can be run using qemu:
#
#  qemu-system-m68k -nographic -machine mcf5208evb -kernel linux-6.0/vmlinux
#

CPU=m68k
TARGET=m68k-uclinux
FLAVOR=m68knommu-flt
BOARD=m5208evb

BINUTILS_VERSION=2.25.1
GCC_VERSION=8.3.0
ELF2FLT_VERSION=2019.12
UCLIBC_VERSION=0.9.33.2
LINUX_VERSION=6.0
BUSYBOX_VERSION=1.35.0

BINUTILS_URL=https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VERSION}.tar.bz2
GCC_URL=https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz
UCLIBC_URL=https://www.uclibc.org/downloads/uClibc-${UCLIBC_VERSION}.tar.xz
LINUX_URL=https://www.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VERSION}.tar.xz
BUSYBOX_URL=https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2
ELF2FLT_URL=https://github.com/uclinux-dev/elf2flt/archive/refs/tags/v${ELF2FLT_VERSION}.tar.gz

ROOTDIR=$(pwd)
TOOLCHAIN=${ROOTDIR}/toolchain
ROOTFS=${ROOTDIR}/rootfs

PATH=${TOOLCHAIN}/bin:${PATH}

fetch_file()
{
	URL=$1
	PACKAGE=$(basename ${URL})
	mkdir -p downloads
	if [ ! -f downloads/${PACKAGE} ]
	then
		echo "BUILD: fetching ${PACKAGE}"
		cd downloads
		wget ${URL}
		cd ../
	fi
}

build_binutils()
{
	echo "BUILD: building binutils-${BINUTILS_VERSION}"
	fetch_file ${BINUTILS_URL}

	tar xvjf downloads/binutils-${BINUTILS_VERSION}.tar.bz2
	cd binutils-${BINUTILS_VERSION}
	./configure --target=${TARGET} --prefix=${TOOLCHAIN}
	make || exit 1
	make install || exit 1
	cd ../
}

build_gcc()
{
	echo "BUILD: building gcc-${GCC_VERSION}"
	fetch_file ${GCC_URL}

	tar xvJf downloads/gcc-${GCC_VERSION}.tar.xz
	cd gcc-${GCC_VERSION}
	contrib/download_prerequisites
	mkdir ${TARGET}
	cd ${TARGET}
	../configure --target=${TARGET} \
		--prefix=${TOOLCHAIN} \
		--enable-multilib \
		--disable-shared \
		--disable-libssp \
		--disable-threads \
		--disable-libmudflap \
		--disable-libgomp \
		--disable-libatomic \
		--disable-libsanitizer \
		--disable-libquadmath \
		--disable-libmpx \
		--without-headers \
		--with-system-zlib \
		--enable-languages=c
	make -j || exit 1
	make install || exit 1
	cd ../..
}

build_linux_headers()
{
	echo "BUILD: building linux-${LINUX_VERSION} headers"
	fetch_file ${LINUX_URL}

	tar xvJf downloads/linux-${LINUX_VERSION}.tar.xz
	cd linux-${LINUX_VERSION}
	make ARCH=${CPU} defconfig
	make ARCH=${CPU} headers_install || exit 1
	cp -a usr/include ${TOOLCHAIN}/${TARGET}/
	cd ../
}

build_uClibc()
{
	echo "BUILD: building uClibc-${UCLIBC_VERSION}"
	fetch_file ${UCLIBC_URL}

	tar xvJf downloads/uClibc-${UCLIBC_VERSION}.tar.xz
	cp configs/uClibc-${UCLIBC_VERSION}-${FLAVOR}.config uClibc-${UCLIBC_VERSION}/.config
	cd uClibc-${UCLIBC_VERSION}

	TOOLCHAIN_ESCAPED=$(echo ${TOOLCHAIN}/${TARGET} | sed 's/\//\\\//g')
	sed -i "s/^KERNEL_HEADERS=.*\$/KERNEL_HEADERS=\"${TOOLCHAIN_ESCAPED}\/include\"/" .config
	sed -i "s/^RUNTIME_PREFIX=.*\$/RUNTIME_PREFIX=\"${TOOLCHAIN_ESCAPED}\"/" .config
	sed -i "s/^DEVEL_PREFIX=.*\$/DEVEL_PREFIX=\"${TOOLCHAIN_ESCAPED}\"/" .config

	make oldconfig CROSS=${TARGET}- TARGET_ARCH=${CPU} < /dev/null
	make -j install CROSS=${TARGET}- TARGET_ARCH=${CPU} || exit 1
	cd ../
}

build_elf2flt()
{
	echo "BUILD: building elf2flt-${ELF2FLT_VERSION}"
	fetch_file ${ELF2FLT_URL}

	tar xvzf downloads/v${ELF2FLT_VERSION}.tar.gz
	cd elf2flt-${ELF2FLT_VERSION}
	./configure --with-libbfd=${ROOTDIR}/binutils-${BINUTILS_VERSION}/bfd/libbfd.a \
		--with-libiberty=${ROOTDIR}/binutils-${BINUTILS_VERSION}/libiberty/libiberty.a \
		--with-bfd-include-dir=${ROOTDIR}/binutils-${BINUTILS_VERSION}/bfd \
		--with-binutils-include-dir=${ROOTDIR}/binutils-${BINUTILS_VERSION}/include \
		--disable-werror \
		--prefix=${TOOLCHAIN} \
		--target=${TARGET}
	make || exit 1
	make install || exit 1
	cd ../
}

build_busybox()
{
	echo "BUILD: building busybox-${BUSYBOX_VERSION}"
	fetch_file ${BUSYBOX_URL}

	tar xvjf downloads/busybox-${BUSYBOX_VERSION}.tar.bz2
	cp configs/busybox-${BUSYBOX_VERSION}-${FLAVOR}.config busybox-${BUSYBOX_VERSION}/.config
	cd busybox-${BUSYBOX_VERSION}
	make oldconfig
	make -j CROSS_COMPILE=${TARGET}- CONFIG_PREFIX=${ROOTFS} install SKIP_STRIP=y
	cd ../
}

build_finalize_rootfs()
{
	echo "BUILD: finalizing rootfs"

	mkdir -p ${ROOTFS}/etc
	mkdir -p ${ROOTFS}/proc
	mkdir -p ${ROOTFS}/sys

	echo "::sysinit:/etc/rc" > ${ROOTFS}/etc/inittab
	echo "::respawn:/bin/sh" >> ${ROOTFS}/etc/inittab

	echo "#!/bin/sh" > ${ROOTFS}/etc/rc
	echo "mount -t proc proc /proc" >> ${ROOTFS}/etc/rc
	echo "mount -t sysfs sys /sys" >> ${ROOTFS}/etc/rc
	echo "echo -e \"\\nSimple Linux\\n\\n\"" >> ${ROOTFS}/etc/rc
	chmod 755 ${ROOTFS}/etc/rc

	ln -s /sbin/init ${ROOTFS}/init
}

build_linux()
{
	echo "BUILD: building linux-${LINUX_VERSION}"

	cd linux-${LINUX_VERSION}
	make ARCH=${CPU} CROSS_COMPILE=${TARGET}- ${BOARD}_defconfig

	sed -i "s/# CONFIG_BLK_DEV_INITRD is not set/CONFIG_BLK_DEV_INITRD=y/" .config
	echo "CONFIG_INITRAMFS_SOURCE=\"${ROOTFS} ${ROOTDIR}/configs/rootfs.dev\"" >> .config
	echo "CONFIG_INITRAMFS_COMPRESSION_GZIP=y" >> .config

	make ARCH=${CPU} CROSS_COMPILE=${TARGET}- olddefconfig < /dev/null
	make -j ARCH=${CPU} CROSS_COMPILE=${TARGET}- || exit 1

	cd ../
}


#
# Do the real work.
#

if [ "$1" = "clean" ]
then
	rm -rf binutils-${BINUTILS_VERSION}
	rm -rf gcc-${GCC_VERSION}
	rm -rf linux-${LINUX_VERSION}
	rm -rf uClibc-${UCLIBC_VERSION}
	rm -rf elf2flt-${ELF2FLT_VERSION}
	rm -rf busybox-${BUSYBOX_VERSION}
	rm -rf ${TOOLCHAIN}
	rm -rf ${ROOTFS}
	exit 0
fi
if [ "$#" != 0 ]
then
	echo "usage: build-m68knommu-linux-uclibc-flt.sh [clean]"
	exit 1
fi

build_binutils
build_gcc
build_linux_headers
build_uClibc
build_elf2flt
build_busybox
build_finalize_rootfs
build_linux

exit 0
