#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# build-armnommu-linux-uclibc-fdpic.sh -- build really simple linux for armnommu
#
# (C) Copyright 2022-2024, Greg Ungerer (gerg@kernel.org)
#
# This script carries out a simple build of an arm based user space
# and linux for use with the ARM/versatile qemu emulated machine.
#
# This is designed to be as absolutely simple and minimal as possible.
# Only the first stage gcc is built (that is all we really need) and
# only the busybox package to provide a very basic user space.
#
# The build starts by building binutils and a first pass minimal gcc,
# then builds uClibc, busybox and finally a kernel. The resulting kernel
# can be run using qemu:
#
#	qemu-system-arm -M versatilepb \
#		-nographic  \
#		-kernel linux-6.9/arch/arm/boot/zImage \
#		-dtb linux-6.9/arch/arm/boot/dts/arm/versatile-pb.dtb
#

CPU=arm
TARGET=arm-uclinuxfdpiceabi
FLAVOR=armnommu-fdpic
BOARD=versatile

BINUTILS_VERSION=2.42
GCC_VERSION=13.2.0
UCLIBC_NG_VERSION=1.0.48
BUSYBOX_VERSION=1.36.1
LINUX_VERSION=6.9

BINUTILS_URL=https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VERSION}.tar.xz
GCC_URL=https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz
UCLIBC_NG_URL=http://downloads.uclibc-ng.org/releases/${UCLIBC_NG_VERSION}/uClibc-ng-${UCLIBC_NG_VERSION}.tar.xz
BUSYBOX_URL=https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2
LINUX_URL=https://www.kernel.org/pub/linux/kernel/v6.x/linux-${LINUX_VERSION}.tar.xz

ROOTDIR=$(pwd)
TOOLCHAIN=${ROOTDIR}/toolchain
ROOTFS=${ROOTDIR}/rootfs

NCPU=$(grep -c processor /proc/cpuinfo 2> /dev/null)
[ -z "$NCPU" ] && NCPU=1

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

	tar xvJf downloads/binutils-${BINUTILS_VERSION}.tar.xz
	cd binutils-${BINUTILS_VERSION}
	./configure --target=${TARGET} --prefix=${TOOLCHAIN}
	make -j${NCPU} || exit 1
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
	make -j${NCPU} || exit 1
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
	echo "BUILD: building uClibc-${UCLIBC_NG_VERSION}"
	fetch_file ${UCLIBC_NG_URL}

	tar xvJf downloads/uClibc-ng-${UCLIBC_NG_VERSION}.tar.xz
	cp configs/uClibc-ng-${UCLIBC_NG_VERSION}-${FLAVOR}.config uClibc-ng-${UCLIBC_NG_VERSION}/.config
	cd uClibc-ng-${UCLIBC_NG_VERSION}

	TOOLCHAIN_ESCAPED=$(echo ${TOOLCHAIN}/${TARGET} | sed 's/\//\\\//g')
	sed -i "s/^KERNEL_HEADERS=.*\$/KERNEL_HEADERS=\"${TOOLCHAIN_ESCAPED}\/include\"/" .config
	sed -i "s/^RUNTIME_PREFIX=.*\$/RUNTIME_PREFIX=\"${TOOLCHAIN_ESCAPED}\"/" .config
	sed -i "s/^DEVEL_PREFIX=.*\$/DEVEL_PREFIX=\"${TOOLCHAIN_ESCAPED}\"/" .config

	make oldconfig CROSS=${TARGET}- TARGET_ARCH=${CPU} < /dev/null
	make V=1 -j${NCPU} install CROSS=${TARGET}- TARGET_ARCH=${CPU} || exit 1

	cd ../
}

build_busybox()
{
	echo "BUILD: building busybox-${BUSYBOX_VERSION}"
	fetch_file ${BUSYBOX_URL}

	tar xvjf downloads/busybox-${BUSYBOX_VERSION}.tar.bz2
	cp configs/busybox-${BUSYBOX_VERSION}.config busybox-${BUSYBOX_VERSION}/.config
	cd busybox-${BUSYBOX_VERSION}

	sed -i 's/# CONFIG_NOMMU is not set/CONFIG_NOMMU=y/' .config
	sed -i 's/CONFIG_EXTRA_CFLAGS=""/CONFIG_EXTRA_CFLAGS="-mfdpic"/' .config
	sed -i 's/CONFIG_EXTRA_LDFLAGS=""/CONFIG_EXTRA_LDFLAGS="-mfdpic"/' .config

	make oldconfig
	make V=1 -j${NCPU} CROSS_COMPILE=${TARGET}- CONFIG_PREFIX=${ROOTFS} install SKIP_STRIP=y
	cd ../
}

build_finalize_rootfs()
{
	echo "BUILD: finalizing rootfs"

	mkdir -p ${ROOTFS}/etc
	mkdir -p ${ROOTFS}/lib
	mkdir -p ${ROOTFS}/proc
	mkdir -p ${ROOTFS}/sys

	cp uClibc-ng-${UCLIBC_NG_VERSION}/lib/libuClibc-${UCLIBC_NG_VERSION}.so ${ROOTFS}/lib/libc.so.0
	cp uClibc-ng-${UCLIBC_NG_VERSION}/lib/ld-uClibc-${UCLIBC_NG_VERSION}.so ${ROOTFS}/lib/ld-uClibc.so.0

	echo "::sysinit:/etc/rc" > ${ROOTFS}/etc/inittab
	echo "::respawn:-/bin/sh" >> ${ROOTFS}/etc/inittab

	echo "#!/bin/sh" > ${ROOTFS}/etc/rc
	echo "mount -t proc proc /proc" >> ${ROOTFS}/etc/rc
	echo "mount -t sysfs sys /sys" >> ${ROOTFS}/etc/rc
	echo "echo -e \"\\nSimple Linux\\n\\n\"" >> ${ROOTFS}/etc/rc
	chmod 755 ${ROOTFS}/etc/rc

	ln -sf /sbin/init ${ROOTFS}/init
}

build_linux()
{
	echo "BUILD: building linux-${LINUX_VERSION}"

	cd linux-${LINUX_VERSION}
	cp ../configs/linux-${LINUX_VERSION}-armnommu-${BOARD}.config .config

	patch -p1 < ../patches/linux-${LINUX_VERSION}-armnommu-${BOARD}.patch

	make ARCH=${CPU} CROSS_COMPILE=${TARGET}- oldconfig
	make -j${NCPU} ARCH=${CPU} CROSS_COMPILE=${TARGET}- || exit 1

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
	rm -rf uClibc-ng-${UCLIBC_NG_VERSION}
	rm -rf busybox-${BUSYBOX_VERSION}
	rm -rf ${TOOLCHAIN}
	rm -rf ${ROOTFS}
	exit 0
fi
if [ "$#" != 0 ]
then
	echo "usage: build-armnommu-linux-uclibc-fdpic.sh [clean]"
	exit 1
fi

build_binutils
build_gcc
build_linux_headers
build_uClibc
build_busybox
build_finalize_rootfs
build_linux

exit 0
