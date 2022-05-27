#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
#
# build-riscvnommu-elf-linux.sh -- build really simple nommu linux for RISC-V
#
# (C) Copyright 2022, Greg Ungerer (gerg@kernel.org)
#
# This script carries out a simple build of a RISCV-V based user space
# and linux for use with the standard qemu emulated machine.
#
# This is designed to be as absolutely simple and minimal as possible.
# Only the first stage gcc is built (that is all we really need) and
# only the busybox package to provide a very basic user space.
#
# The build starts by building binutils and a first pass minimal gcc,
# then builds uClibc-ng, busybox and finally a kernel. The resulting kernel
# can be run using qemu:
#
#	qemu-system-riscv64 \
#		-cpu rv64,mmu=false \
#		-nographic \
#		-machine virt \
#		-bios linux-5.16/arch/riscv/boot/Image
#

CPU=riscv
TARGET=riscv64-linux-uclibc
FLAVOR=riscvnommu-elf
BOARD=qemu

BINUTILS_VERSION=2.37
GCC_VERSION=11.2.0
UCLIBC_NG_VERSION=1.0.41
LINUX_VERSION=5.16
BUSYBOX_VERSION=1.34.1

BINUTILS_URL=https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VERSION}.tar.xz
GCC_URL=https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz
UCLIBC_NG_URL=http://downloads.uclibc-ng.org/releases/${UCLIBC_NG_VERSION}/uClibc-ng-${UCLIBC_NG_VERSION}.tar.xz
LINUX_URL=https://www.kernel.org/pub/linux/kernel/v5.x/linux-${LINUX_VERSION}.tar.xz
BUSYBOX_URL=https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2

ROOTDIR=$(pwd)
TOOLCHAIN=${ROOTDIR}/toolchain
ROOTFS=${ROOTDIR}/rootfs

PATH=${TOOLCHAIN}/bin:${PATH}

fetch_file()
{
	URL=$1
	PACKAGE=$(basename ${URL})
	if [ ! -f ${PACKAGE} ]
	then
		echo "BUILD: fetching ${PACKAGE}"
		wget ${URL}
	fi
}

build_binutils()
{
	echo "BUILD: building binutils-${BINUTILS_VERSION}"
	fetch_file ${BINUTILS_URL}

	tar xvJf binutils-${BINUTILS_VERSION}.tar.xz
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

	tar xvJf gcc-${GCC_VERSION}.tar.xz
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

	tar xvJf linux-${LINUX_VERSION}.tar.xz
	cd linux-${LINUX_VERSION}

	patch -p1 < ../patches/linux-${LINUX_VERSION}-${FLAVOR}.patch

	make ARCH=${CPU} defconfig
	make ARCH=${CPU} headers_install || exit 1
	cp -a usr/include ${TOOLCHAIN}/${TARGET}/
	cd ../
}

build_uclibc()
{
	echo "BUILD: building uClibc-${UCLIBC_NG_VERSION}"
	fetch_file ${UCLIBC_NG_URL}

	tar xvJf uClibc-ng-${UCLIBC_NG_VERSION}.tar.xz
	cp configs/uClibc-ng-${UCLIBC_NG_VERSION}-${FLAVOR}.config uClibc-ng-${UCLIBC_NG_VERSION}/.config
	cd uClibc-ng-${UCLIBC_NG_VERSION}

	patch -p1 < ../patches/uClibc-ng-${UCLIBC_NG_VERSION}-${FLAVOR}.patch

	TOOLCHAIN_ESCAPED=$(echo ${TOOLCHAIN}/${TARGET} | sed 's/\//\\\//g')
	sed -i "s/^KERNEL_HEADERS=.*\$/KERNEL_HEADERS=\"${TOOLCHAIN_ESCAPED}\/include\"/" .config
	sed -i "s/^RUNTIME_PREFIX=.*\$/RUNTIME_PREFIX=\"${TOOLCHAIN_ESCAPED}\"/" .config
	sed -i "s/^DEVEL_PREFIX=.*\$/DEVEL_PREFIX=\"${TOOLCHAIN_ESCAPED}\"/" .config

	make oldconfig CROSS=${TARGET}- ARCH=${CPU} < /dev/null
	make -j install CROSS=${TARGET}- ARCH=${CPU} || exit 1

	ln -f ${TOOLCHAIN}/${TARGET}/lib/crt1.o ${TOOLCHAIN}/${TARGET}/lib/Scrt1.o
	echo | ${TARGET}-gcc -o ${TOOLCHAIN}/${TARGET}/lib/crti.o -c
	ln -f ${TOOLCHAIN}/${TARGET}/lib/crti.o ${TOOLCHAIN}/${TARGET}/lib/crtn.o

	cd ../
}

build_busybox()
{
	echo "BUILD: building busybox-${BUSYBOX_VERSION}"
	fetch_file ${BUSYBOX_URL}

	tar xvjf busybox-${BUSYBOX_VERSION}.tar.bz2
	cp configs/busybox-${BUSYBOX_VERSION}-${FLAVOR}.config busybox-${BUSYBOX_VERSION}/.config
	cd busybox-${BUSYBOX_VERSION}
	make oldconfig
	make -j CROSS_COMPILE=${TARGET}- CONFIG_PREFIX=${ROOTFS} install
	cd ../
}

build_finalize_rootfs()
{
	echo "BUILD: finalizing rootfs"

	mkdir -p ${ROOTFS}/etc
	mkdir -p ${ROOTFS}/proc
	mkdir -p ${ROOTFS}/lib

	echo "::sysinit:/etc/rc" > ${ROOTFS}/etc/inittab
	echo "::askfirst:/bin/sh" >> ${ROOTFS}/etc/inittab

	echo "#!/bin/sh" > ${ROOTFS}/etc/rc
	echo "mount -t proc proc /proc" >> ${ROOTFS}/etc/rc
	echo "echo -e \"\\nSimple Linux\\n\\n\"" >> ${ROOTFS}/etc/rc
	chmod 755 ${ROOTFS}/etc/rc

	ln -sf /sbin/init ${ROOTFS}/init
}

build_linux()
{
	echo "BUILD: building linux-${LINUX_VERSION}"

	cd linux-${LINUX_VERSION}
	cp ../configs/linux-${LINUX_VERSION}-${FLAVOR}.config .config

	make ARCH=${CPU} CROSS_COMPILE=${TARGET}- oldconfig < /dev/null
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
	rm -rf uClibc-ng-${UCLIBC_NG_VERSION}
	rm -rf busybox-${BUSYBOX_VERSION}
	rm -rf ${TOOLCHAIN}
	rm -rf ${ROOTFS}
	exit 0
fi
if [ "$#" != 0 ]
then
	echo "usage: build-riscvnommu-elf-linux.sh [clean]"
	exit 1
fi

build_binutils
build_gcc
build_linux_headers
build_uclibc
build_busybox
build_finalize_rootfs
build_linux

exit 0
