Development: Linux Host on ARM
=============

This section shows you how to obtain and build the SDK as well as the samples
and test code that it includes. For an architectural overview see
[ARM TrustZone and SGX deep dive](sgx_trustzone_arch.md).

This document provides steps for developing on Linux. For other environments,
see [Windows Host and SGX](win_sgx_dev.md) or
[Windows Host and SGX Simulation](win_sgx_dev.md#simulation).

To work in a simulated ARM TrustZone environment, see [Debugging OP-TEE TAs with
QEMU](ta_debugging_qemu.md).

**Note**: The only currently supported build environment is Ubuntu 18.04.1.

# Prerequisites

This SDK currently relies on having the Intel SGX SDK installed even if
developing for TrustZone. This is because the Open Enclave SDK requires
using the `sgx_edger8r` utility that comes with that SDK as well as various header files.

**Note**: This dependency is temporary. 

The Intel SGX SDK can be downloaded for free from
[Intel's Open Source Center](https://01.org/intel-softwareguard-extensions).
Once you have it, install it as follows:

```
sudo apt install build-essential

chmod +x ./sgx_linux_x64_sdk_2.3.101.46683.bin
./sgx_linux_x64_sdk_2.3.101.46683.bin
```

Each time that you want to build the Open Enclave SDK or your own TA's,
always execute the following command prior to building to ensure that
the Intel SGX SDK is in your `PATH`:

```
source /path/to/sgxsdk/environment
```

Building applications using this SDK also requires
[oeedger8r](https://github.com/Microsoft/openenclave/tree/master/docs/GettingStartedDocs/Edger8rGettingStarted.md),
the source for
which is part of this SDK. The build script downloads a pre-built binary for
you from [this location](https://oedownload.blob.core.windows.net/binaries/oeedger8r).

# Getting the SDK

Fetching the sources for the Open Enclave SDK on Linux is no different than
doing so on Windows, all you need is Git:

```
git clone https://github.com/Microsoft/openenclave --recurse-submodules -b feature.new_platforms
```

# Building the SDK

The Open Enclave SDK has a top-level CMake-based build system. However, Linux
support is limited to building via GNU Make for this public preview. A Bash
script is also provided that automates the process of installing all
prerequisites and invoking the relevant Makefiles.

## Building for Scalys LS1012 Grapeboard

These steps below assume you are targetting a [Scalys LS1012 Grapeboard](grapeboard.mc).
For details on the build process, and how to build other architectures, see [detailed usage](linux_arm_dev.md#details).

1) Start by setting the following exports:
   * `ARCH` specifies the target architecture. The Grapeboard is ARMv8, so set this to `aarch64`.
   *  `MACHINE` specifies the target board. For the Grapeboard, use `ls1012grapeboard`.
    ```
    export ARCH=aarch64
    export MACHINE=ls1012grapeboard
    ```
2) Next, we can run a batch script that installs all dependencies and builds the Open Enclave SDK and samples. 
   This builds REE and TEE components:
    ```
    ./build_optee.sh
    ```

## Build Artifacts

The `sockets` sample generates three binaries under `new_platforms`:

* `samples/sockets/Untrusted/SampleClientApp/sampleclientapp`
* `samples/sockets/Untrusted/SampleServerApp/sampleserverapp`
* `bin/optee/samples/sockets/aac3129e-c244-4e09-9e61-d4efcf31bca3.ta`

In order to run the sample, you must copy these files to the target. The host
apps may reside anywhere on the target's filesystem. However, the TA file must
be placed in a specific folder where all the TA's are placed. For all
architectures and machines currently supported, this location is:

```
/lib/optee_armtz
```

## Running the Samples

To run the `SampleClient` and `SampleServer` samples, see the [echo socket sample](sample_sockets.md#grapeboard).

# Build Process Details

Due to the design of ARM TrustZone, trusted applications must be compiled once
for each specific board you want to run them on. OP-TEE OS provides a layer of
abstraction atop raw hardware and may either be readily built by your hardware
provider or you may build it yourself. OP-TEE OS has support for a variety of
ARM boards and, when it is built, it produces a TA Development Kit not
dissimilar to an SDK. This kit includes header files with definitions for
standard functions as well as GNU Make rules that specify how TA code is to be
built and packaged. As a result, to build a TrustZone TA, you either must have
access to the TA Dev Kit that corresponds to the version of OP-TEE on your board
or you must build it yourself.

For convenience, the Bash script included with the Open Enclave SDK can build
OP-TEE OS for the purposes of obtaining a TA Dev Kit for certain specific
configurations. The configurations are specified using two variables:

* `ARCH` specifies the target architecture:
    * `aarch32` for ARMv7 targets;
    * `aarch64` for ARMv8 targets.
* `MACHINE` specifies the target board.
    * For ARMv7 targets:
        * `virt` builds OP-TEE OS and creates a TA Dev Kit for running emulated
          in QEMU (`qemu-system-arm`).
    * For ARMv8 targets:
        * `ls1012grapeboard` builds OP-TEE OS and a TA Dev Kit for a Scalys
          LS1012 (Grapeboard) board;
        * `virt` builds OP-TEE OS and a TA Dev Kit for running emulated in QEMU
          (`qemu-system-aarch64`).

## Build Script

`build_optee.sh` performs the following steps:

* Installs all build prerequisites;
* Downloads and extracts the Linaro cross-compilers:
    * For `aarch32`, only the arm-on-x86/64 cross-compiler is necessary;
    * For `aarch64`, the aarch64-onx86/64 is necessary in addition to the
      arm-on-x86/64 cross-compiler.
* Downloads the `oeedger8r` tool;
* Builds OP-TEE OS and the associated TA Dev Kit;
* Builds the Open Enclave SDK with samples and test code;
* Executes Doxygen on the SDK.

## Bring Your Own OP-TEE

If you already have a TA Dev Kit, you may specify it as follows just prior to
invoking the script:

```
export TA_DEV_KIT_DIR=<absolute path to the kit>
```

This precludes the script from building OP-TEE and it instead references your TA
Dev Kit.

## Cleaning the SDK

To remove all output generated by the script, run:

```
export ARCH=<arch to clean>
export MACHINE=<machine to clean>
export TA_DEV_KIT_DIR=<only if you had specified your own before>

./build_optee.sh clean
```

# Next Steps

The easiest way to get started with creating a new host and TA pair is by taking
the existing samples and modifying them to suit your needs. The `sockets` sample
is simple in nature but provides all the structure you need to be well on your
way to creating your own TEE-enabled applications.

* [Building the Sample EchoSockets](sample_sockets.md#grapeboard)
* [Developing your own enclave](new_platform_dev.md)